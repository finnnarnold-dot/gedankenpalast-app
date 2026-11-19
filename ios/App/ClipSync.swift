import UIKit
import UniformTypeIdentifiers

/// Zwischenablage iPhone/iPad ↔ Laptop beim Öffnen der App (Apple erlaubt Apps keinen Zugriff im Hintergrund).
/// * Laptop → iPhone (immer, ohne Rückfrage von iOS): der neueste Eintrag eines anderen Geräts aus den letzten
///   10 Minuten liegt danach in der iPhone-Zwischenablage – jeder Eintrag nur einmal.
/// * iPhone → Laptop (nur mit Schalter „clipAuto“, weil iOS beim Lesen nachfragen kann): was seit dem letzten Mal neu
///   kopiert wurde, kommt in die Portal-Zwischenablage. Als vertraulich markierte Inhalte (Passwort-Manager) nie.
@MainActor
enum ClipSync {
    static var autoUpload: Bool { UserDefaults.standard.bool(forKey: "clipAuto") }
    private static var running = false
    private static let defaults = UserDefaults.standard

    /// Letztes Ergebnis für Einstellungen → App (damit sichtbar ist, was passiert ist)
    private static func status(_ text: String) {
        let t = Date().formatted(date: .omitted, time: .shortened)
        defaults.set("\(t): \(text)", forKey: "clipStatus")
        let js = "window.portalApp && (portalApp.clipStatus = \(PortalWebView.jsString("\(t): \(text)")))"
        AppModel.shared?.webView?.evaluateJavaScript(js)
    }

    /// force: vom Knopf im Kontrollzentrum – iPhone → Laptop auch ohne Schalter
    static func onForeground(force: Bool = false) async {
        guard !running else { return }
        guard Shared.appKey != nil else { status("Kein Geräte-Schlüssel – App einmal neu öffnen und angemeldet sein"); return }
        running = true
        defer { running = false }
        let pb = UIPasteboard.general
        // 1) iPhone → Laptop: nur wenn sich die Zwischenablage seit dem letzten Mal geändert hat und nicht von uns stammt
        if (force || autoUpload), pb.changeCount != defaults.integer(forKey: "clipSeen"), pb.changeCount != defaults.integer(forKey: "clipOwn") {
            defaults.set(pb.changeCount, forKey: "clipSeen")
            let concealed = pb.types.contains { $0 == "org.nspasteboard.ConcealedType" || $0 == "com.agilebits.onepassword" }
            if concealed { status("iPhone → Laptop übersprungen (vertraulicher Inhalt)") } else { await upload(pb) }
        }
        // 2) Laptop → iPhone
        let data: Data
        do { data = try await PortalAPI.raw(["action": "clipLatest", "other": true, "minutes": 10]) }
        catch { status("Portal nicht erreichbar: \(error.localizedDescription)"); return }
        guard let c = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["clip"] as? [String: Any],
              let id = c["id"] as? String, let kind = c["kind"] as? String else { status("Nichts Neues vom Laptop (letzte 10 Min.)"); return }
        guard id != defaults.string(forKey: "clipApplied") else { status("Neuester Laptop-Eintrag war schon übernommen"); return }
        defaults.set(id, forKey: "clipApplied")
        switch kind {
        case "text": pb.string = c["text"] as? String ?? ""
        case "link": if let u = URL(string: c["text"] as? String ?? "") { pb.url = u } else { pb.string = c["text"] as? String ?? "" }
        default:
            guard let file = try? await PortalAPI.raw(["action": "clipFile", "id": id]) else { return }
            let name = c["name"] as? String ?? "Datei"
            if kind == "image", let img = UIImage(data: file) { pb.image = img }
            else {
                let type = (c["type"] as? String).flatMap { UTType(mimeType: $0) } ?? UTType(filenameExtension: (name as NSString).pathExtension) ?? .data
                pb.setData(file, forPasteboardType: type.identifier)
            }
        }
        defaults.set(pb.changeCount, forKey: "clipOwn")
        defaults.set(pb.changeCount, forKey: "clipSeen")
        let what = kind == "image" ? "Bild" : kind == "file" ? "„\(c["name"] as? String ?? "Datei")“" : "Text"
        AppModel.toast("\(what) vom \(c["device"] as? String ?? "Laptop") liegt in der Zwischenablage – einfach einfügen")
        status("\(what) vom \(c["device"] as? String ?? "Laptop") übernommen")
    }

    private static func upload(_ pb: UIPasteboard) async {
        if pb.hasImages, let img = pb.image, let png = img.pngData() {
            try? await PortalAPI.upload(png, name: "Bild.png", type: "image/png", folder: nil, clip: true)
        } else if pb.hasURLs, let u = pb.url, !u.isFileURL {
            _ = try? await PortalAPI.action(["action": "clip", "text": u.absoluteString])
        } else if pb.hasStrings, let s = pb.string, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = try? await PortalAPI.action(["action": "clip", "text": s])
        } else { status("iPhone-Zwischenablage leer oder nicht lesbar (iOS-Einstellung „Aus anderen Apps einfügen“?)"); return }
        AppModel.toast("iPhone-Zwischenablage ist jetzt auch am Laptop")
        status("iPhone-Zwischenablage zum Laptop gesendet")
    }
}
