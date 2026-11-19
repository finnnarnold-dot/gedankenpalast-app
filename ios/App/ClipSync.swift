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

    /// force: vom Knopf im Kontrollzentrum – iPhone → Laptop auch ohne Schalter
    static func onForeground(force: Bool = false) async {
        guard !running, Shared.appKey != nil else { return }
        running = true
        defer { running = false }
        let pb = UIPasteboard.general
        // 1) iPhone → Laptop: nur wenn sich die Zwischenablage seit dem letzten Mal geändert hat und nicht von uns stammt
        if (force || autoUpload), pb.changeCount != defaults.integer(forKey: "clipSeen"), pb.changeCount != defaults.integer(forKey: "clipOwn") {
            defaults.set(pb.changeCount, forKey: "clipSeen")
            let concealed = pb.types.contains { $0 == "org.nspasteboard.ConcealedType" || $0 == "com.agilebits.onepassword" }
            if !concealed { await upload(pb) }
        }
        // 2) Laptop → iPhone
        guard let data = try? await PortalAPI.raw(["action": "clipLatest", "other": true, "minutes": 10]),
              let c = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["clip"] as? [String: Any],
              let id = c["id"] as? String, id != defaults.string(forKey: "clipApplied"), let kind = c["kind"] as? String else { return }
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
    }

    private static func upload(_ pb: UIPasteboard) async {
        if pb.hasImages, let img = pb.image, let png = img.pngData() {
            try? await PortalAPI.upload(png, name: "Bild.png", type: "image/png", folder: nil, clip: true)
        } else if pb.hasURLs, let u = pb.url, !u.isFileURL {
            _ = try? await PortalAPI.action(["action": "clip", "text": u.absoluteString])
        } else if pb.hasStrings, let s = pb.string, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = try? await PortalAPI.action(["action": "clip", "text": s])
        } else { return }
        AppModel.toast("iPhone-Zwischenablage ist jetzt auch am Laptop")
    }
}
