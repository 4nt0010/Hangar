import AppKit
import WebKit

/// Ponte tra la finestra web e il motore nativo.
/// JS → Swift:  await hangarNative.call('getState')  (risposta come Promise)
/// Swift → JS:  hangarNative.on('state', fn)
final class Bridge: NSObject, WKScriptMessageHandlerWithReply {
    weak var webView: WKWebView?
    let engine: Engine
    let updater: Updater

    init(engine: Engine, updater: Updater) {
        self.engine = engine
        self.updater = updater
    }

    static let bootstrap = """
    (function(){
      if (window.hangarNative) return;
      var L = {};
      window.hangarNative = {
        available: true,
        version: "__VERSION__",
        call: function(cmd, args){ return window.webkit.messageHandlers.hangar.postMessage(Object.assign({cmd: cmd}, args || {})); },
        on: function(e, f){ (L[e] = L[e] || []).push(f); },
        _emit: function(m){ (L[m.e] || []).forEach(function(f){ try { f(m.d); } catch(x){ console.error(x); } }); }
      };
      var mark = function(){ document.documentElement && document.documentElement.classList.add('native'); };
      if (document.documentElement) mark(); else document.addEventListener('DOMContentLoaded', mark);
    })();
    """

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else {
            replyHandler(nil, "Messaggio non valido"); return
        }
        let id = body["id"] as? String ?? ""
        let result: ([String: Any]) -> Void = { replyHandler($0, nil) }

        switch cmd {
        case "getState":
            replyHandler(engine.stateJSON(), nil)

        case "getCatalog":
            replyHandler(engine.catalogBase64(id), nil)

        case "scan":
            if id.isEmpty { engine.scanAllMounted() } else { engine.scan(id) }
            result(["ok": true])

        case "refresh":
            engine.refresh()
            result(["ok": true])

        case "reveal":
            let err = engine.reveal(volumeId: id, path: body["path"] as? String ?? "")
            result(["ok": err == nil, "error": err ?? ""])

        case "trash":
            let paths = body["paths"] as? [String] ?? []
            // Il dialogo di conferma è modale: lo apriamo dopo aver restituito il controllo a WebKit.
            DispatchQueue.main.async {
                let err = self.engine.trash(volumeId: id, paths: paths)
                result(["ok": err == nil, "error": err ?? "", "cancelled": err == "Annullato"])
            }

        case "setColor":
            engine.setColor(body["color"] as? String ?? "", for: id)
            result(["ok": true])

        case "forget":
            engine.forget(id)
            result(["ok": true])

        case "setAutoScan":
            engine.autoScan = body["value"] as? Bool ?? true
            result(["ok": true])

        case "checkUpdates":
            updater.check(interactive: true)
            result(["ok": true])

        case "openURL":
            if let s = body["url"] as? String, let url = URL(string: s), ["https", "http", "mailto"].contains(url.scheme ?? "") {
                NSWorkspace.shared.open(url)
            }
            result(["ok": true])

        default:
            replyHandler(nil, "Comando sconosciuto: \(cmd)")
        }
    }

    func emit(_ event: String, _ payload: Any) {
        guard let webView,
              let data = try? JSONSerialization.data(withJSONObject: ["e": event, "d": payload]),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.hangarNative && window.hangarNative._emit(\(json));", completionHandler: nil)
    }

    func pushState() { emit("state", engine.stateJSON()) }
}
