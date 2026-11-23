import Foundation

// MARK: - Nodo del catalogo
// Formato condiviso con il sito: [nome, byte, mtime(secondi), figli?]
// Una cartella ha l'array dei figli; un file (o un pacchetto tipo .logicx) no.

final class Node {
    let name: String
    let size: Int64
    let mtime: Int64
    let children: [Node]?

    init(name: String, size: Int64, mtime: Int64, children: [Node]?) {
        self.name = name
        self.size = size
        self.mtime = mtime
        self.children = children
    }

    var isDir: Bool { children != nil }

    func toJSON() -> [Any] {
        if let children { return [name, size, mtime, children.map { $0.toJSON() }] }
        return [name, size, mtime]
    }

    func counts() -> (files: Int, folders: Int) {
        var files = 0, folders = 0
        var stack: [Node] = [self]
        while let n = stack.popLast() {
            for c in n.children ?? [] {
                if c.isDir { folders += 1; stack.append(c) } else { files += 1 }
            }
        }
        return (files, folders)
    }
}

// MARK: - Catalogo compresso (JSON + DEFLATE grezzo, letto dal sito con DecompressionStream('deflate-raw'))

enum CatalogCodec {
    static func encode(root: Node, volumeId: String, scannedAt: Date) throws -> Data {
        let object: [String: Any] = [
            "v": 1,
            "volumeId": volumeId,
            "scannedAt": Int(scannedAt.timeIntervalSince1970),
            "root": root.toJSON()
        ]
        let json = try JSONSerialization.data(withJSONObject: object)
        return try (json as NSData).compressed(using: .zlib) as Data
    }
}

// MARK: - Volumi

struct VolumeRecord: Codable {
    let id: String
    var name: String
    var colorKey: String
    var totalBytes: Int64
    var freeBytes: Int64
    var format: String
    var lastSeen: Date?
    var lastScan: Date?
    var fileCount: Int
    var folderCount: Int
}

struct MountedVolume {
    let id: String
    let url: URL
    let name: String
    let total: Int64
    let free: Int64
    let format: String
}

enum Palette {
    static let keys = ["sage", "lavender", "peach", "sky", "rose", "butter", "mint"]
}

enum Fmt {
    private static let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()
    static func bytes(_ b: Int64) -> String { formatter.string(fromByteCount: b) }
}

// MARK: - Lettura dei volumi esterni montati

enum VolumeProbe {
    static let keys: [URLResourceKey] = [
        .volumeNameKey, .volumeUUIDStringKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey, .volumeIsInternalKey, .volumeIsRemovableKey,
        .volumeIsEjectableKey, .volumeIsRootFileSystemKey, .volumeIsLocalKey, .volumeIsBrowsableKey,
        .volumeLocalizedFormatDescriptionKey
    ]

    static func externalVolumes() -> [MountedVolume] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var seen = Set<String>()
        var out: [MountedVolume] = []
        for url in urls {
            if let v = probe(url), !seen.contains(v.id) { seen.insert(v.id); out.append(v) }
        }
        return out
    }

    static func probe(_ url: URL) -> MountedVolume? {
        guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
        if v.volumeIsRootFileSystem == true { return nil }
        if v.volumeIsLocal == false { return nil }
        if v.volumeIsBrowsable == false { return nil }
        if url.path.hasPrefix("/System/Volumes") { return nil }
        let external = v.volumeIsInternal == false || v.volumeIsRemovable == true || v.volumeIsEjectable == true
        guard external else { return nil }

        let name = v.volumeName ?? url.lastPathComponent
        let total = Int64(v.volumeTotalCapacity ?? 0)
        var free: Int64 = v.volumeAvailableCapacityForImportantUsage ?? 0
        if free <= 0 { free = Int64(v.volumeAvailableCapacity ?? 0) }
        let fallback = "\(name)-\(total)".replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: " ", with: "_")
        return MountedVolume(id: v.volumeUUIDString ?? fallback, url: url, name: name, total: total, free: free,
                             format: v.volumeLocalizedFormatDescription ?? "")
    }

    static func isStillMounted(_ url: URL) -> Bool {
        (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? [])
            .contains { $0.standardizedFileURL == url.standardizedFileURL }
    }
}

// MARK: - Scansione

final class Scanner {
    private static let skip: Set<String> = [
        ".Spotlight-V100", ".fseventsd", ".Trashes", ".DocumentRevisions-V100", ".TemporaryItems",
        ".HFS+ Private Directory Data", "System Volume Information", "$RECYCLE.BIN"
    ]
    private let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .fileSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey]
    private var counter = 0
    private let progress: (Int) -> Void

    init(progress: @escaping (Int) -> Void) { self.progress = progress }

    func scan(root url: URL, name: String) -> Node {
        let n = folder(url, name: name, keep: true)
        progress(counter)
        return n
    }

    private func folder(_ url: URL, name: String, keep: Bool) -> Node {
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        var kids: [Node] = []
        var total: Int64 = 0
        var latest: Int64 = 0
        for item in items {
            let n = item.lastPathComponent
            if Self.skip.contains(n) { continue }
            guard let v = try? item.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isSymbolicLink == true { continue }
            let mtime = Int64(v.contentModificationDate?.timeIntervalSince1970 ?? 0)
            let node: Node
            if v.isDirectory == true {
                let pkg = v.isPackage == true   // .logicx, .fcpbundle, .lrdata… come file unici
                let inner = folder(item, name: n, keep: keep && !pkg)
                node = Node(name: n, size: inner.size, mtime: max(mtime, inner.mtime), children: (keep && !pkg) ? (inner.children ?? []) : nil)
            } else {
                node = Node(name: n, size: Int64(v.totalFileAllocatedSize ?? v.fileSize ?? 0), mtime: mtime, children: nil)
                counter += 1
                if counter % 2000 == 0 { progress(counter) }
            }
            total += node.size
            latest = max(latest, node.mtime)
            if keep { kids.append(node) }
        }
        return Node(name: name, size: total, mtime: latest, children: keep ? kids : nil)
    }
}

// MARK: - Archivio locale (~/Library/Application Support/Hangar)

struct LocalStore {
    let base: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        base = support.appendingPathComponent("Hangar", isDirectory: true)
        try? FileManager.default.createDirectory(at: base.appendingPathComponent("catalogs"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: base.appendingPathComponent("ui"), withIntermediateDirectories: true)
    }

    private var registryURL: URL { base.appendingPathComponent("volumes.json") }
    func catalogURL(_ id: String) -> URL { base.appendingPathComponent("catalogs").appendingPathComponent("\(id).catalog") }
    var uiCacheURL: URL { base.appendingPathComponent("ui").appendingPathComponent("index.html") }

    func loadRegistry() -> [String: VolumeRecord] {
        let decoder = JSONDecoder()
        guard let data = try? Data(contentsOf: registryURL), let list = try? decoder.decode([VolumeRecord].self, from: data) else { return [:] }
        var out: [String: VolumeRecord] = [:]
        for r in list { out[r.id] = r }
        return out
    }

    func saveRegistry(_ records: [String: VolumeRecord]) {
        if let data = try? JSONEncoder().encode(Array(records.values)) { try? data.write(to: registryURL, options: .atomic) }
    }

    func saveCatalog(_ data: Data, id: String) { try? data.write(to: catalogURL(id), options: .atomic) }
    func loadCatalog(_ id: String) -> Data? { try? Data(contentsOf: catalogURL(id)) }
    func deleteCatalog(_ id: String) { try? FileManager.default.removeItem(at: catalogURL(id)) }
}
