import Foundation
import WebKit

/// Ablage in der Dateien-App: Ordner „Gedankenpalast“ in iCloud Drive oder – ohne iCloud-Container – unter
/// „Auf meinem iPhone/iPad“.
/// * Dateien der Ablage erscheinen dort in ihren Ordnern (ohne Musik, bis 100 MB).
/// * Neue Dateien, die du dort hineinlegst, kommen in die Ablage – direkt im Ordner „Gedankenpalast“ landen sie
///   im Eingang mit „Wohin damit?“, in einem Unterordner in diesem Ordner.
/// * Gelöscht wird nie automatisch (weder im Portal noch in iCloud) – sicher gegen Versehen.
@MainActor
enum ICloudSync {
    /// nil = erster iCloud-Container aus den Berechtigungen (der Bau übernimmt den Namen aus Apples Profil)
    static let container: String? = nil
    private static var running = false
    private static var lastRun = Date.distantPast
    /// Portal-Datei-ID → Pfad relativ zum Ordner (was schon abgeglichen ist)
    private static var map: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "icloudMap-" + kind) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "icloudMap-" + kind) }
    }
    static var enabled: Bool { !UserDefaults.standard.bool(forKey: "icloudOff") }

    /// Ort des Ordners: iCloud Drive, wenn der Container bei Apple eingerichtet ist – sonst „Auf meinem iPhone/iPad“
    /// → Gedankenpalast (eigener Dokumente-Ordner der App, in der Dateien-App sichtbar; abgeglichen über den Server).
    static func root() -> URL? {
        if let u = FileManager.default.url(forUbiquityContainerIdentifier: container) {
            let docs = u.appendingPathComponent("Documents", isDirectory: true)
            try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
            return docs
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }
    static var kind: String { FileManager.default.url(forUbiquityContainerIdentifier: container) != nil ? "icloud" : "local" }

    static func status() -> String {
        if !enabled { return "off" }
        return kind == "icloud" ? "on" : "local"
    }

    /// Abgleich (höchstens alle 2 Minuten, außer force)
    static func run(base: URL, cookie: String, force: Bool = false) {
        guard enabled, !running, force || Date().timeIntervalSince(lastRun) > 120, !cookie.isEmpty else { return }
        running = true; lastRun = Date()
        Task.detached(priority: .utility) {
            defer { Task { @MainActor in running = false } }
            guard let dir = await MainActor.run(body: { root() }) else { return }
            await sync(base: base, cookie: cookie, dir: dir)
        }
    }

    nonisolated private static func safe(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?*\"<>|").union(.newlines)
        let t = s.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "Datei" : String(t.prefix(120))
    }

    nonisolated private static func sync(base: URL, cookie: String, dir: URL) async {
        func req(_ path: String, _ query: [URLQueryItem] = []) -> URLRequest {
            var c = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
            if !query.isEmpty { c.queryItems = query }
            var r = URLRequest(url: c.url!, timeoutInterval: 60)
            r.httpShouldHandleCookies = false
            r.setValue(cookie, forHTTPHeaderField: "Cookie")
            return r
        }
        // 1. Dateien der Ablage holen
        guard let (data, resp) = try? await URLSession.shared.data(for: req("api/sync", [URLQueryItem(name: "since", value: "0")])),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        var files: [String: [String: Any]] = [:]
        for c in obj["changes"] as? [[String: Any]] ?? [] where c["coll"] as? String == "files" {
            guard let id = c["id"] as? String else { continue }
            if c["deleted"] as? Bool == true { files[id] = nil } else if let d = c["doc"] as? [String: Any] { files[id] = d }
        }
        var known = await MainActor.run { map }
        let fm = FileManager.default
        // 2. Portal → iCloud (fehlende Dateien anlegen)
        for (id, f) in files {
            guard known[id] == nil, let name = f["name"] as? String, let url = f["url"] as? String,
                  (f["size"] as? Int ?? 0) < 100_000_000 else { continue }
            let folder = safe(f["folder"] as? String ?? "Allgemein")
            if folder == "Musik" || (f["pending"] as? Bool ?? false) { continue }
            let rel = folder + "/" + safe(name)
            let dest = dir.appendingPathComponent(rel)
            if fm.fileExists(atPath: dest.path) { known[id] = rel; continue }
            guard let src = URL(string: url, relativeTo: base),
                  let (tmp, r2) = try? await URLSession.shared.download(for: { var r = URLRequest(url: src.absoluteURL); r.setValue(cookie, forHTTPHeaderField: "Cookie"); r.httpShouldHandleCookies = false; return r }()),
                  (r2 as? HTTPURLResponse)?.statusCode == 200 else { continue }
            try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? fm.moveItem(at: tmp, to: dest)) != nil { known[id] = rel }
        }
        // 3. iCloud → Portal (neue Dateien hochladen)
        let have = Set(known.values)
        let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles])
        var uploaded = 0
        while let u = en?.nextObject() as? URL {
            guard (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let rel = String(u.path.dropFirst(dir.path.count + 1))
            guard !have.contains(rel) else { continue }
            let parts = rel.split(separator: "/")
            guard let fdata = try? Data(contentsOf: u), fdata.count < 200_000_000 else { continue }
            var q = [URLQueryItem(name: "ablage", value: "1")]
            if parts.count > 1 { q.append(URLQueryItem(name: "folder", value: String(parts[0]))) }
            else { q += [URLQueryItem(name: "folder", value: "Eingang"), URLQueryItem(name: "pending", value: "1")] }
            var r = req("api/upload", q)
            r.httpMethod = "POST"
            r.setValue(u.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "datei", forHTTPHeaderField: "X-Filename")
            r.setValue(AppModel.mime(for: u), forHTTPHeaderField: "Content-Type")
            guard let (rd, rr) = try? await URLSession.shared.upload(for: r, from: fdata), (rr as? HTTPURLResponse)?.statusCode == 200,
                  let res = try? JSONSerialization.jsonObject(with: rd) as? [String: Any],
                  let fid = (res["file"] as? [String: Any])?["id"] as? String else { continue }
            if parts.count == 1 {   // aus dem Hauptordner: nach dem Einordnen gehört sie in den Zielordner
                try? fm.removeItem(at: u)
            } else { known[fid] = rel }
            uploaded += 1
        }
        let final = known
        await MainActor.run { map = final }
        if uploaded > 0 {
            await MainActor.run {
                AppModel.shared?.webView?.evaluateJavaScript("window.portalToast && portalToast('\(uploaded) Datei(en) aus iCloud Drive in der Ablage')", completionHandler: nil)
            }
        }
    }
}
