import AppKit

/// Aggiornamenti dell'app: controlla l'ultima Release su GitHub, scarica Hangar.zip,
/// sostituisce l'app in Applicazioni e la riapre.
final class Updater {
    private var busy = false
    private var panel: NSPanel?

    private var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }
    private var repo: String? {
        guard let r = info["HangarRepo"] as? String, r.contains("/"), !r.contains("__") else { return nil }
        return r
    }
    private var currentBuild: Int { Int(info["CFBundleVersion"] as? String ?? "") ?? 0 }
    private var currentVersion: String { info["CFBundleShortVersionString"] as? String ?? "dev" }

    func check(interactive: Bool) {
        guard !busy else { return }
        guard let repo, let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            if interactive { alert("Aggiornamenti non disponibili", "Questa copia di Hangar non è stata compilata da GitHub.") }
            return
        }
        busy = true
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            DispatchQueue.main.async {
                self.busy = false
                self.handle(data, interactive: interactive)
            }
        }.resume()
    }

    private func handle(_ data: Data?, interactive: Bool) {
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else {
            if interactive { alert("Non riesco a controllare gli aggiornamenti", "Controlla la connessione e riprova.") }
            return
        }
        // tag "v1.0.42" → build 42
        let build = Int(tag.split(separator: ".").last.map(String.init) ?? "") ?? 0
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard build > currentBuild else {
            if interactive { alert("Hangar è aggiornato", "Hai già l'ultima versione (\(currentVersion)).") }
            return
        }
        if !interactive && UserDefaults.standard.integer(forKey: "skippedBuild") == build { return }

        let assets = json["assets"] as? [[String: Any]] ?? []
        guard let zip = assets.first(where: { ($0["name"] as? String) == "Hangar.zip" }),
              let dl = (zip["browser_download_url"] as? String).flatMap({ URL(string: $0) }) else {
            if interactive { alert("Aggiornamento incompleto", "La versione \(version) non contiene ancora il pacchetto. Riprova tra qualche minuto.") }
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "È disponibile Hangar \(version)"
        var notes = (json["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if notes.count > 600 { notes = String(notes.prefix(600)) + "…" }
        a.informativeText = "Hai la versione \(currentVersion)." + (notes.isEmpty ? "" : "\n\n\(notes)")
        a.addButton(withTitle: "Aggiorna e riavvia")
        a.addButton(withTitle: "Più tardi")
        a.addButton(withTitle: "Salta questa versione")
        switch a.runModal() {
        case .alertFirstButtonReturn: install(from: dl)
        case .alertThirdButtonReturn: UserDefaults.standard.set(build, forKey: "skippedBuild")
        default: break
        }
    }

    private func install(from url: URL) {
        let app = Bundle.main.bundleURL
        let parent = app.deletingLastPathComponent()
        if app.path.contains("/AppTranslocation/") || app.path.hasPrefix("/Volumes/") || !FileManager.default.isWritableFile(atPath: parent.path) {
            alert("Sposta Hangar in Applicazioni",
                  "Per aggiornarsi da solo Hangar deve stare nella cartella Applicazioni. Trascinalo lì dal Finder, riaprilo e riprova.")
            return
        }
        busy = true
        showProgress()
        URLSession.shared.downloadTask(with: url) { tmp, response, error in
            let fm = FileManager.default
            let work = fm.temporaryDirectory.appendingPathComponent("HangarUpdate-\(UUID().uuidString)")
            var newApp: URL?
            var problem: String?
            do {
                guard let tmp, (response as? HTTPURLResponse)?.statusCode == 200 else { throw NSError(domain: "dl", code: 1) }
                try fm.createDirectory(at: work, withIntermediateDirectories: true)
                let zip = work.appendingPathComponent("Hangar.zip")
                try fm.moveItem(at: tmp, to: zip)
                let unzip = Process()
                unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                unzip.arguments = ["-x", "-k", zip.path, work.appendingPathComponent("x").path]
                try unzip.run(); unzip.waitUntilExit()
                let candidate = work.appendingPathComponent("x/Hangar.app")
                guard unzip.terminationStatus == 0,
                      let bundle = Bundle(url: candidate),
                      bundle.bundleIdentifier == Bundle.main.bundleIdentifier else { throw NSError(domain: "zip", code: 2) }
                newApp = candidate
            } catch {
                problem = error.localizedDescription
            }
            DispatchQueue.main.async {
                self.busy = false
                self.hideProgress()
                guard let newApp, problem == nil else {
                    self.alert("Aggiornamento non riuscito", "Non sono riuscito a scaricare o aprire il pacchetto. Riprova più tardi.")
                    return
                }
                self.relaunch(replacing: app, with: newApp, scriptDir: work)
            }
        }.resume()
    }

    /// Uno script aspetta che Hangar si chiuda, sostituisce l'app e la riapre.
    private func relaunch(replacing dest: URL, with newApp: URL, scriptDir: URL) {
        let script = """
        #!/bin/bash
        PID="$1"; NEW="$2"; DEST="$3"
        for i in $(seq 1 100); do kill -0 "$PID" 2>/dev/null || break; sleep 0.2; done
        rm -rf "$DEST.old"
        if mv "$DEST" "$DEST.old" && mv "$NEW" "$DEST"; then rm -rf "$DEST.old"; else rm -rf "$DEST"; mv "$DEST.old" "$DEST"; fi
        xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
        open "$DEST"
        """
        let url = scriptDir.appendingPathComponent("install.sh")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [url.path, String(ProcessInfo.processInfo.processIdentifier), newApp.path, dest.path]
            try p.run()
            NSApp.terminate(nil)
        } catch {
            alert("Aggiornamento non riuscito", error.localizedDescription)
        }
    }

    private func showProgress() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 90), styleMask: [.titled, .hudWindow, .utilityWindow], backing: .buffered, defer: false)
        p.title = "Hangar"
        let label = NSTextField(labelWithString: "Scarico l'aggiornamento…")
        label.frame = NSRect(x: 20, y: 50, width: 280, height: 20)
        let bar = NSProgressIndicator(frame: NSRect(x: 20, y: 22, width: 280, height: 16))
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        p.contentView?.addSubview(label)
        p.contentView?.addSubview(bar)
        p.center()
        p.makeKeyAndOrderFront(nil)
        panel = p
    }

    private func hideProgress() { panel?.orderOut(nil); panel = nil }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}
