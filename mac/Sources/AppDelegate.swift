import AppKit
import WebKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate, WKNavigationDelegate, WKUIDelegate {
    let engine = Engine()
    let updater = Updater()
    var bridge: Bridge!
    var window: NSWindow!
    var webView: WKWebView!
    var statusItem: NSStatusItem!

    var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }

    /// Indirizzo dell'interfaccia (GitHub Pages). Scritto in Info.plist dalla build.
    var uiURL: URL? {
        guard let s = Bundle.main.infoDictionary?["HangarUIURL"] as? String, s.hasPrefix("https://") else { return nil }
        return URL(string: s)
    }

    // MARK: Avvio

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMainMenu()
        buildWindow()
        buildStatusItem()

        engine.onChange = { [weak self] in self?.bridge.pushState() }
        engine.onScanned = { [weak self] id in self?.bridge.emit("scanned", id) }
        engine.start()

        loadUI()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        updater.check(interactive: false)
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.updater.check(interactive: false) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    // Chiudere la finestra la nasconde soltanto: Hangar continua a seguire i dischi dalla barra dei menu.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    @objc func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Finestra

    func buildWindow() {
        let config = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        bridge = Bridge(engine: engine, updater: updater)
        let boot = Bridge.bootstrap.replacingOccurrences(of: "__VERSION__", with: version)
        ucc.addUserScript(WKUserScript(source: boot, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ucc.addScriptMessageHandler(bridge, contentWorld: .page, name: "hangar")
        config.userContentController = ucc
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        bridge.webView = webView

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 840),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Hangar"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 900, height: 600)
        window.isReleasedWhenClosed = false
        window.delegate = self
        // La pagina occupa anche la barra del titolo: una striscia invisibile in alto permette di trascinare la finestra.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1320, height: 840))
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        let drag = DragStrip(frame: NSRect(x: 80, y: container.bounds.height - 22, width: container.bounds.width - 80, height: 22))
        drag.autoresizingMask = [.width, .minYMargin]
        container.addSubview(drag)
        window.contentView = container
        window.center()
        window.setFrameAutosaveName("HangarMain")
    }

    // MARK: Interfaccia: online da GitHub Pages, con copia locale per quando manca la rete

    @objc func loadUI() {
        let base = uiURL ?? URL(string: "https://hangar.local/")!
        guard let remote = uiURL else { loadFallback(base: base); return }
        var req = URLRequest(url: remote, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if let data, (response as? HTTPURLResponse)?.statusCode == 200,
                   let html = String(data: data, encoding: .utf8), html.contains("hangarNative") || html.contains("<html") {
                    try? data.write(to: self.engine.store.uiCacheURL, options: .atomic)
                    self.webView.loadHTMLString(html, baseURL: remote)
                } else {
                    self.loadFallback(base: base)
                }
            }
        }.resume()
    }

    private func loadFallback(base: URL) {
        if let data = try? Data(contentsOf: engine.store.uiCacheURL), let html = String(data: data, encoding: .utf8) {
            webView.loadHTMLString(html, baseURL: base); return
        }
        if let url = Bundle.main.url(forResource: "index", withExtension: "html"),
           let html = try? String(contentsOf: url, encoding: .utf8) {
            webView.loadHTMLString(html, baseURL: base); return
        }
        webView.loadHTMLString("<body style='font:15px -apple-system;padding:60px;color:#555'>Interfaccia non disponibile: controlla la connessione e premi ⌘R.</body>", baseURL: nil)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.navigationType == .linkActivated, let url = action.request.url,
           ["http", "https", "mailto"].contains(url.scheme ?? ""), url.host != uiURL?.host {
            NSWorkspace.shared.open(url)   // i link esterni si aprono nel browser
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { NSWorkspace.shared.open(url) }
        return nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { loadUI() }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = NSAlert(); a.messageText = message; a.addButton(withTitle: "OK")
        a.beginSheetModal(for: window) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = NSAlert(); a.messageText = message
        a.addButton(withTitle: "OK"); a.addButton(withTitle: "Annulla")
        a.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    // MARK: Barra dei menu (icona in alto)

    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let img = NSImage(systemSymbolName: "externaldrive.fill", accessibilityDescription: "Hangar")
            img?.isTemplate = true
            button.image = img
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu == statusItem.menu else { return }
        menu.removeAllItems()
        let online = engine.records.values.filter { engine.mounted[$0.id] != nil }.sorted { $0.name < $1.name }
        if online.isEmpty {
            menu.addItem(disabled("Nessun disco esterno collegato"))
        } else {
            for r in online {
                let pct = r.totalBytes > 0 ? Int(Double(r.totalBytes - r.freeBytes) / Double(r.totalBytes) * 100) : 0
                var title = "\(r.name) — \(Fmt.bytes(r.freeBytes)) liberi (\(pct)% pieno)"
                if let n = engine.scanning[r.id] { title += n > 0 ? " · scansione \(n) file" : " · scansione…" }
                let item = NSMenuItem(title: title, action: #selector(showWindow), keyEquivalent: "")
                item.target = self
                item.image = NSImage(systemSymbolName: "externaldrive", accessibilityDescription: nil)
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        menu.addItem(action("Apri Hangar", #selector(showWindow), "o"))
        menu.addItem(action("Scansiona i dischi collegati", #selector(scanAll), ""))
        let auto = action("Scansiona quando colleghi un disco", #selector(toggleAutoScan), "")
        auto.state = engine.autoScan ? .on : .off
        menu.addItem(auto)
        if #available(macOS 13.0, *) {
            let login = action("Apri all'avvio del Mac", #selector(toggleLogin), "")
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(login)
        }
        menu.addItem(.separator())
        menu.addItem(action("Cerca aggiornamenti…", #selector(checkUpdates), ""))
        menu.addItem(disabled("Hangar \(version)"))
        menu.addItem(action("Esci da Hangar", #selector(NSApplication.terminate(_:)), "q", target: NSApp))
    }

    private func action(_ title: String, _ sel: Selector, _ key: String, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        item.target = target ?? self
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc func scanAll() { engine.scanAllMounted() }
    @objc func toggleAutoScan() { engine.autoScan.toggle(); bridge.pushState() }
    @objc func checkUpdates() { updater.check(interactive: true) }

    @objc func toggleLogin() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            let a = NSAlert()
            a.messageText = "Non riesco a cambiare l'avvio automatico"
            a.informativeText = "Puoi farlo da Impostazioni di Sistema › Generali › Elementi login."
            a.runModal()
        }
    }

    // MARK: Menu principale

    func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Informazioni su Hangar", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(action("Cerca aggiornamenti…", #selector(checkUpdates), ""))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Nascondi Hangar", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = appMenu.addItem(withTitle: "Nascondi altre", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Esci da Hangar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Modifica")
        edit.addItem(withTitle: "Annulla", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Ripristina", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Taglia", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copia", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Incolla", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Seleziona tutto", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let viewItem = NSMenuItem(); main.addItem(viewItem)
        let view = NSMenu(title: "Vista")
        view.addItem(action("Ricarica interfaccia", #selector(loadUI), "r"))
        view.addItem(action("Scansiona i dischi collegati", #selector(scanAll), "s"))
        let fs = view.addItem(withTitle: "Schermo intero", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]
        viewItem.submenu = view

        let winItem = NSMenuItem(); main.addItem(winItem)
        let win = NSMenu(title: "Finestra")
        win.addItem(withTitle: "Riduci", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "Chiudi", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        win.addItem(action("Mostra Hangar", #selector(showWindow), "0"))
        winItem.submenu = win
        NSApp.windowsMenu = win

        NSApp.mainMenu = main
    }
}

/// Striscia trasparente sopra la pagina: trascina la finestra, doppio clic la ingrandisce.
final class DragStrip: NSView {
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: event) }
    }
}
