import SwiftUI
import WebKit
import UIKit

/// Das Portal in der App. Ergänzt: Brücke für Mitteilungen/Face ID, Herunterladen (Teilen-Menü),
/// externe Links in Safari, Kurzbefehle/Mail-Links, Ziehen zum Aktualisieren, Wischen zurück.
struct PortalWebView: UIViewRepresentable {
    let url: URL
    let model: AppModel
    var tabMode = false          // in der Tab-Leiste der App: Seitenleiste des Portals ausblenden (keine zwei Wege)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()                 // Anmeldung bleibt gespeichert
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let ucc = WKUserContentController()
        ucc.add(context.coordinator, name: "portal")
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let faceID = model.faceID ? "true" : "false"
        let reminders = model.reminders ? "true" : "false"
        let script = "window.portalApp = { platform: 'ios', version: '\(version)', faceID: \(faceID), reminders: \(reminders), widgets: true, music: true, alerts: \(EventAlerts.enabled ? "true" : "false"), icloud: '\(ICloudSync.status())', clipAuto: \(UserDefaults.standard.bool(forKey: "clipAuto")), assistant: \(AssistantAvailability.available) };"
            + "document.documentElement.classList.add('ios-app');"
            + (tabMode ? "document.documentElement.classList.add('ios-tabs');" : "")
        ucc.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController = ucc

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = false   // Zurück-Wischen übernimmt das Portal selbst (Blatt, Ansicht, Seite)
        web.isOpaque = false
        web.backgroundColor = UIColor(red: 0.07, green: 0.067, blue: 0.063, alpha: 1)
        web.scrollView.contentInsetAdjustmentBehavior = .never   // das Portal berücksichtigt Notch und Home-Leiste selbst
        let refresh = UIRefreshControl()
        refresh.addTarget(context.coordinator, action: #selector(Coordinator.refresh(_:)), for: .valueChanged)
        web.scrollView.refreshControl = refresh
        if #available(iOS 16.4, *) { web.isInspectable = true }
        web.load(URLRequest(url: url))
        context.coordinator.pencil.attach(to: web, model: model)   // Apple Pencil auf dem Notiztext → Handschrift
        DispatchQueue.main.async { model.webView = web }
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, WKDownloadDelegate {
        let parent: PortalWebView
        private var downloadURL: URL?
        let pencil = PencilCatcher()

        init(_ parent: PortalWebView) { self.parent = parent }

        @objc func refresh(_ control: UIRefreshControl) {
            parent.model.webView?.reload()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { control.endRefreshing() }
        }

        // Nachrichten vom Portal: window.webkit.messageHandlers.portal.postMessage({ type: … })
        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let data = message.body as? [String: Any], let type = data["type"] as? String else { return }
            switch type {
            case "notify":
                parent.model.notify(title: data["title"] as? String ?? "Gedankenpalast", body: data["body"] as? String ?? "")
            case "badge":
                parent.model.setBadge(data["count"] as? Int ?? 0)
            case "faceid":
                parent.model.setFaceID(data["enabled"] as? Bool ?? false)
            case "changeServer":
                parent.model.resetServer()
            case "icloud":
                if let on = data["enabled"] as? Bool { parent.model.setICloud(on) } else { parent.model.syncICloud(force: true) }
            case "alerts":
                parent.model.setEventAlerts(data["enabled"] as? Bool ?? true)
            case "clipAuto":
                parent.model.setClipAuto(data["enabled"] as? Bool ?? false)
            case "assistant":
                parent.model.showAssistant = true
            case "reminders":
                parent.model.setReminders(data["enabled"] as? Bool ?? false)
            case "refreshWidgets":
                parent.model.refreshWidgets()
            case "perm":
                let web = parent.model.webView
                Task { @MainActor in Permissions.handle(data, web: web) }
            case "noteArea":
                var area = NoteArea()
                func rect(_ o: Any?) -> CGRect? {
                    guard let d = o as? [String: Any], let x = d["x"] as? Double, let y = d["y"] as? Double, let w = d["w"] as? Double, let h = d["h"] as? Double else { return nil }
                    return CGRect(x: x, y: y, width: w, height: h)
                }
                area.editor = rect(data["editor"])
                area.drawings = (data["drawings"] as? [[String: Any]] ?? []).compactMap { d in
                    guard let src = d["src"] as? String, let dd = d["data"] as? String, let r = rect(d) else { return nil }
                    return (src: src, data: dd, rect: r)
                }
                parent.model.noteArea = area
            case "music":
                let web = parent.model.webView
                Task { @MainActor in
                    MusicBridge.shared.webView = web
                    MusicBridge.shared.handle(data)
                }
            case "chess":
                parent.model.embedURL = URL(string: data["url"] as? String ?? "") ?? URL(string: "https://www.chess.com/")
            case "embed":
                if let u = URL(string: data["url"] as? String ?? ""), Coordinator.isEmbedded(u) { parent.model.openEmbedded(u) }
            default:
                break
            }
        }

        func webView(_ web: WKWebView, didFinish navigation: WKNavigation!) {
            parent.model.pageLoaded()
            web.scrollView.refreshControl?.endRefreshing()
        }

        func webView(_ web: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let target = action.request.url else { decisionHandler(.allow); return }
            if action.shouldPerformDownload { decisionHandler(.download); return }
            let scheme = target.scheme?.lowercased() ?? ""
            if ["http", "https"].contains(scheme) {
                if target.host != parent.url.host && action.targetFrame?.isMainFrame != false {
                    if Coordinator.isEmbedded(target) { parent.model.openEmbedded(target); decisionHandler(.cancel); return }
                    UIApplication.shared.open(target)          // fremde Seiten (z. B. chess.com) in Safari
                    decisionHandler(.cancel); return
                }
                decisionHandler(.allow); return
            }
            if ["about", "blob", "data"].contains(scheme) { decisionHandler(.allow); return }
            UIApplication.shared.open(target)                  // shortcuts://, mailto:, tel: …
            decisionHandler(.cancel)
        }

        func webView(_ web: WKWebView, decidePolicyFor response: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            decisionHandler(response.canShowMIMEType ? .allow : .download)
        }

        func webView(_ web: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
        func webView(_ web: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }

        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                      completionHandler: @escaping (URL?) -> Void) {
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(suggestedFilename)
            try? FileManager.default.removeItem(at: dest)
            downloadURL = dest
            completionHandler(dest)
        }

        func downloadDidFinish(_ download: WKDownload) {
            guard let file = downloadURL else { return }
            DispatchQueue.main.async { Coordinator.share(file) }
        }

        // Links mit target=_blank: eigene Seiten in der App, fremde in Safari
        func webView(_ web: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let target = action.request.url {
                if target.host == parent.url.host { web.load(action.request) }
                else if Coordinator.isEmbedded(target) { parent.model.openEmbedded(target) }
                else { UIApplication.shared.open(target) }
            }
            return nil
        }

        static func isChess(_ url: URL) -> Bool {
            let h = url.host?.lowercased() ?? ""
            return h == "chess.com" || h.hasSuffix(".chess.com")
        }
        static func isAppleMusic(_ url: URL) -> Bool { url.host?.lowercased() == "music.apple.com" }
        static func isEmbedded(_ url: URL) -> Bool { isChess(url) || isAppleMusic(url) }

        static func share(_ file: URL) {
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            guard let root = scene?.keyWindow?.rootViewController else { return }
            let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
            if let pop = sheet.popoverPresentationController {           // iPad
                pop.sourceView = root.view
                pop.sourceRect = CGRect(x: root.view.bounds.midX, y: root.view.bounds.midY, width: 1, height: 1)
                pop.permittedArrowDirections = []
            }
            (root.presentedViewController ?? root).present(sheet, animated: true)
        }
    }
}

/// Fremde Dienste als eigener Bereich in der App (bleiben angemeldet, eigene Zurück-Taste):
/// chess.com und Apple Music (Apples eigener Webplayer music.apple.com – das Original, kein Nachbau).
struct EmbedView: View {
    let url: URL
    @EnvironmentObject var model: AppModel

    var isMusic: Bool { PortalWebView.Coordinator.isAppleMusic(url) }

    var body: some View {
        NavigationStack {
            EmbedWebView(url: url, desktop: isMusic)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(isMusic ? "Apple Music" : "Schach")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { model.embedURL = nil } label: { Label("Gedankenpalast", systemImage: "chevron.left") }
                    }
                    if isMusic {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { if let u = URL(string: "music://") { UIApplication.shared.open(u) } } label: {
                                Label("Apple-Music-App", systemImage: "arrow.up.forward.app")
                            }
                        }
                    }
                }
        }
    }
}

struct EmbedWebView: UIViewRepresentable {
    let url: URL
    var desktop = false

    func makeCoordinator() -> Popups { Popups() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        let web = WKWebView(frame: .zero, configuration: config)
        web.allowsBackForwardNavigationGestures = true
        web.uiDelegate = context.coordinator
        // Apples Webplayer zeigt auf dem iPhone sonst nur „In der App öffnen“ – wie Safari auf dem Mac auftreten
        if desktop { web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15" }
        web.load(URLRequest(url: url))
        return web
    }
    func updateUIView(_ web: WKWebView, context: Context) {}

    /// Anmeldefenster (Apple-ID, chess.com-Login) als Fenster über der Seite, damit die Anmeldung zurückgemeldet wird
    final class Popups: NSObject, WKUIDelegate {
        func webView(_ web: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            let popup = WKWebView(frame: web.bounds, configuration: configuration)
            popup.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            popup.customUserAgent = web.customUserAgent
            popup.uiDelegate = self
            web.addSubview(popup)
            return popup
        }
        func webViewDidClose(_ web: WKWebView) { web.removeFromSuperview() }
    }
}
