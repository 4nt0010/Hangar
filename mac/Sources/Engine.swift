import AppKit

/// Il "motore" nativo: rileva i dischi, li scansiona, salva gli indici e fa le azioni sui file.
/// Tutto il resto (interfaccia, Firebase) vive nella finestra web.
final class Engine {
    private(set) var records: [String: VolumeRecord] = [:]
    private(set) var mounted: [String: MountedVolume] = [:]
    private(set) var scanning: [String: Int] = [:]
    let store = LocalStore()
    let macName = Host.current().localizedName ?? "Mac"

    /// Chiamato (sul thread principale) quando cambia qualcosa: la finestra e il menu si aggiornano.
    var onChange: (() -> Void)?
    /// Chiamato quando una scansione è finita e salvata (id del volume).
    var onScanned: ((String) -> Void)?

    var autoScan: Bool {
        get { UserDefaults.standard.object(forKey: "autoScan") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoScan") }
    }

    private var timer: Timer?

    func start() {
        records = store.loadRegistry()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.refresh() }
            }
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.refresh() }
    }

    // MARK: Volumi

    func refresh() {
        let now = VolumeProbe.externalVolumes()
        var newMap: [String: MountedVolume] = [:]
        for m in now { newMap[m.id] = m }
        let appeared = Set(newMap.keys).subtracting(mounted.keys)
        let gone = Set(mounted.keys).subtracting(newMap.keys)
        mounted = newMap

        for m in now {
            var r = records[m.id] ?? VolumeRecord(id: m.id, name: m.name, colorKey: nextColor(), totalBytes: m.total, freeBytes: m.free,
                                                  format: m.format, lastSeen: nil, lastScan: nil, fileCount: 0, folderCount: 0)
            r.name = m.name; r.totalBytes = m.total; r.freeBytes = m.free; r.format = m.format; r.lastSeen = Date()
            records[m.id] = r
        }
        for id in gone { records[id]?.lastSeen = Date() }
        store.saveRegistry(records)

        if autoScan {
            for id in appeared {
                if let last = records[id]?.lastScan, Date().timeIntervalSince(last) < 6 * 3600 { continue }
                scan(id)
            }
        }
        onChange?()
    }

    private func nextColor() -> String {
        let used = Set(records.values.map { $0.colorKey })
        return Palette.keys.first { !used.contains($0) } ?? Palette.keys[records.count % Palette.keys.count]
    }

    func setColor(_ key: String, for id: String) {
        guard records[id] != nil, Palette.keys.contains(key) else { return }
        records[id]?.colorKey = key
        store.saveRegistry(records)
        onChange?()
    }

    func forget(_ id: String) {
        records[id] = nil
        store.saveRegistry(records)
        store.deleteCatalog(id)
        onChange?()
    }

    // MARK: Scansione

    func scanAllMounted() { mounted.keys.forEach { scan($0) } }

    func scan(_ id: String) {
        guard scanning[id] == nil, let m = mounted[id] else { return }
        scanning[id] = 0
        onChange?()
        let url = m.url, name = m.name
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let scanner = Scanner { count in
                DispatchQueue.main.async {
                    guard let self, self.scanning[id] != nil else { return }
                    self.scanning[id] = count
                    self.onChange?()
                }
            }
            let root = scanner.scan(root: url, name: name)
            let stillMounted = VolumeProbe.isStillMounted(url)
            let date = Date()
            let data = stillMounted ? (try? CatalogCodec.encode(root: root, volumeId: id, scannedAt: date)) : nil
            let counts = root.counts()
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanning[id] = nil
                if let data {   // se il disco è stato staccato a metà, il catalogo sarebbe incompleto: lo scartiamo
                    self.store.saveCatalog(data, id: id)
                    self.records[id]?.lastScan = date
                    self.records[id]?.fileCount = counts.files
                    self.records[id]?.folderCount = counts.folders
                    self.store.saveRegistry(self.records)
                    self.onScanned?(id)
                }
                self.onChange?()
            }
        }
    }

    func catalogBase64(_ id: String) -> String? { store.loadCatalog(id)?.base64EncodedString() }

    // MARK: Stato per la finestra web

    func stateJSON() -> [String: Any] {
        let ms: (Date?) -> Any = { d in d.map { Int($0.timeIntervalSince1970 * 1000) } ?? NSNull() }
        let vols: [[String: Any]] = records.values.sorted { $0.name < $1.name }.map { r -> [String: Any] in
            [
                "id": r.id, "name": r.name, "color": r.colorKey,
                "totalBytes": r.totalBytes, "freeBytes": r.freeBytes, "format": r.format,
                "online": mounted[r.id] != nil, "lastSeen": ms(r.lastSeen), "lastScan": ms(r.lastScan),
                "fileCount": r.fileCount, "folderCount": r.folderCount, "mac": macName,
                "scanning": scanning[r.id].map { $0 as Any } ?? NSNull(),
                "hasCatalog": FileManager.default.fileExists(atPath: store.catalogURL(r.id).path)
            ]
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        return ["volumes": vols, "mac": macName, "version": version, "autoScan": autoScan]
    }

    // MARK: Azioni sui file

    func reveal(volumeId: String, path: String) -> String? {
        guard let m = mounted[volumeId] else { return "Il disco non è collegato al Mac" }
        guard let url = Engine.resolve(m, path) else { return "Percorso non valido" }
        guard FileManager.default.fileExists(atPath: url.path) else { return "File non trovato: forse è stato spostato" }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return nil
    }

    /// Sposta nel Cestino dopo una conferma esplicita sul Mac. Ritorna nil se riuscito.
    func trash(volumeId: String, paths: [String]) -> String? {
        guard let m = mounted[volumeId] else { return "Il disco non è collegato al Mac" }
        let urls = paths.filter { !$0.isEmpty }.compactMap { Engine.resolve(m, $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return "Elementi non trovati: forse sono già stati spostati" }
        let total = urls.reduce(Int64(0)) { $0 + Engine.sizeOnDisk($1) }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Spostare \(urls.count) elementi nel Cestino?"
        var list = urls.prefix(8).map { "• " + $0.lastPathComponent }.joined(separator: "\n")
        if urls.count > 8 { list += "\n… e altri \(urls.count - 8)" }
        alert.informativeText = "Stai per liberare \(Fmt.bytes(total)) da \(m.name):\n\n\(list)\n\nPotrai recuperarli dal Cestino finché non lo svuoti."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Sposta nel Cestino")
        alert.addButton(withTitle: "Annulla")
        guard alert.runModal() == .alertFirstButtonReturn else { return "Annullato" }

        var failed = 0
        for url in urls {
            do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) } catch { failed += 1 }
        }
        refresh()
        scan(volumeId)
        return failed > 0 ? "\(failed) elementi non spostati (permessi o file in uso)" : nil
    }

    /// Un percorso arriva dalla finestra web o da Firebase: non deve mai uscire dal disco.
    static func resolve(_ m: MountedVolume, _ path: String) -> URL? {
        if path.isEmpty { return m.url }
        let parts = path.split(separator: "/").map(String.init)
        if parts.contains("..") || parts.contains(".") || path.hasPrefix("/") { return nil }
        let url = parts.reduce(m.url) { $0.appendingPathComponent($1) }.standardizedFileURL
        let root = m.url.standardizedFileURL.path
        return url.path.hasPrefix(root.hasSuffix("/") ? root : root + "/") ? url : nil
    }

    static func sizeOnDisk(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let v = try? url.resourceValues(forKeys: keys) else { return 0 }
        if v.isDirectory != true { return Int64(v.totalFileAllocatedSize ?? v.fileSize ?? 0) }
        var sum: Int64 = 0
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) {
            for case let f as URL in e {
                if let fv = try? f.resourceValues(forKeys: keys), fv.isDirectory != true {
                    sum += Int64(fv.totalFileAllocatedSize ?? fv.fileSize ?? 0)
                }
            }
        }
        return sum
    }
}
