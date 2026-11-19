import Foundation
import Security

/// Gemeinsam für App, Widgets und Siri: Portal-Adresse, Geräte-Schlüssel und die letzte Übersicht
/// liegen in einem gemeinsamen Schlüsselbund-Bereich (keychain-access-groups, braucht keine App-Gruppe bei Apple),
/// damit Widgets und Kurzbefehle ohne Anmeldung im Browser auskommen.
enum Shared {
    static var serverURL: URL? {
        get { Keychain.get("serverURL").flatMap { URL(string: String(decoding: $0, as: UTF8.self)) } }
        set { Keychain.set("serverURL", newValue.map { Data($0.absoluteString.utf8) }) }
    }
    static var appKey: String? {
        get { Keychain.get("appKey").map { String(decoding: $0, as: UTF8.self) } }
        set { Keychain.set("appKey", newValue.map { Data($0.utf8) }) }
    }
    static var cached: PortalSummary? {
        get { Keychain.get("summary").flatMap { try? JSONDecoder().decode(PortalSummary.self, from: $0) } }
        set { Keychain.set("summary", newValue.flatMap { try? JSONEncoder().encode($0) }) }
    }
    /// Deep Link in einen Bereich des Portals, z. B. gedankenpalast://kalender
    static func link(_ route: String) -> URL { URL(string: "gedankenpalast://\(route)")! }
}

/// Schlüsselbund ohne ausdrückliche Gruppe: Einträge landen in der ersten Gruppe aus keychain-access-groups,
/// die App und Widgets gemeinsam haben. Lesbar nach dem ersten Entsperren (auch für Widgets bei gesperrtem Gerät).
enum Keychain {
    private static func base(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Gedankenpalast", kSecAttrAccount as String: key]
    }
    static func get(_ key: String) -> Data? {
        var q = base(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }
    static func set(_ key: String, _ data: Data?) {
        SecItemDelete(base(key) as CFDictionary)
        guard let data else { return }
        var q = base(key)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }
}

struct PortalSummary: Codable {
    struct Event: Codable, Hashable {
        var datum: String
        var zeit: String?
        var ende: String?
        var titel: String?
        var art: String?
        var kategorie: String?
        var raum: String?
    }
    struct Deadline: Codable, Hashable {
        var datum: String?
        var titel: String?
        var art: String?
        var kurs: String?
    }
    struct Task: Codable, Hashable {
        var id: String?
        var titel: String?
        var faellig: String?
        var kurs: String?
    }
    struct Unread: Codable { var uni: Int; var gmail: Int; var important: Int }

    var today: String
    var updated: String?
    var events: [Event]
    var deadlines: [Deadline]
    var tasks: [Task]
    var unread: Unread
    var folders: [String]?
    var weather: Weather?
    struct Weather: Codable, Hashable {
        struct Day: Codable, Hashable { var datum: String; var max: Int; var min: Int; var regen: Int?; var text: String; var symbol: String }
        var ort: String; var temp: Int; var text: String; var symbol: String; var tage: [Day]
    }

    var todayEvents: [Event] { events.filter { $0.datum == today } }
    var tomorrowEvents: [Event] {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: today), let t = Calendar.current.date(byAdding: .day, value: 1, to: d) else { return [] }
        let tomorrow = f.string(from: t)
        return events.filter { $0.datum == tomorrow }
    }
    /// Nächster Termin heute, der noch nicht vorbei ist (sonst der erste morgen)
    func nextEvent(now: Date = Date()) -> Event? {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        let t = f.string(from: now)
        return todayEvents.first { ($0.ende ?? $0.zeit ?? "23:59") >= t } ?? tomorrowEvents.first
    }

    static let sample = PortalSummary(today: "2026-11-05", updated: nil,
        events: [Event(datum: "2026-11-05", zeit: "09:15", ende: "10:45", titel: "Mikroökonomik", art: "vorlesung", kategorie: "stundenplan", raum: "Hörsaal 2"),
                 Event(datum: "2026-11-05", zeit: "13:00", ende: "14:30", titel: "Seminar Politik", art: "seminar", kategorie: "stundenplan", raum: "1/201")],
        deadlines: [Deadline(datum: "2026-11-12", titel: "Hausarbeit abgeben", art: "frist", kurs: "Politik")],
        tasks: [Task(titel: "Kapitel 3 lesen", faellig: "2026-11-07", kurs: "VWL")],
        unread: Unread(uni: 2, gmail: 1, important: 1))
}

enum PortalAPI {
    enum Failure: LocalizedError {
        case notSetUp, server(String)
        var errorDescription: String? {
            switch self {
            case .notSetUp: return "Bitte die App Gedankenpalast einmal öffnen und anmelden."
            case .server(let m): return m
            }
        }
    }

    private static func request(_ path: String, body: [String: Any]? = nil) throws -> URLRequest {
        guard let base = Shared.serverURL, let key = Shared.appKey else { throw Failure.notSetUp }
        var req = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: 20)
        req.setValue(key, forHTTPHeaderField: "X-App-Key")
        req.httpShouldHandleCookies = false
        if let body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    private static func send(_ req: URLRequest) async throws -> Data {
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw Failure.server(msg ?? "Portal nicht erreichbar (\(code))")
        }
        return data
    }

    /// Übersicht holen; bei Erfolg für Widgets zwischenspeichern
    static func summary() async throws -> PortalSummary {
        let data = try await send(try request("api/app/data"))
        let s = try JSONDecoder().decode(PortalSummary.self, from: data)
        Shared.cached = s
        return s
    }

    /// Teilen-Erweiterung: Datei hochladen (ohne Ordner → Eingang mit „Wohin damit?“)
    static func upload(_ data: Data, name: String, type: String, folder: String?, clip: Bool = false) async throws {
        var req = try request("api/app/upload")
        if clip || folder != nil, var c = URLComponents(url: req.url!, resolvingAgainstBaseURL: false) {
            c.queryItems = clip ? [URLQueryItem(name: "clip", value: "1")] : [URLQueryItem(name: "folder", value: folder)]; req.url = c.url
        }
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue(name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "datei", forHTTPHeaderField: "X-Filename")
        req.setValue(type, forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        _ = try await send(req)
    }

    static func raw(_ body: [String: Any]) async throws -> Data { try await send(try request("api/app/action", body: body)) }

    /// Push-Kennung des Geräts beim eigenen Server anmelden
    static func registerPush(_ token: String, device: String) async throws {
        _ = try await send(try request("api/app/push", body: ["token": token, "device": device, "env": "production"]))
    }


    @discardableResult
    static func action(_ body: [String: Any]) async throws -> String {
        let data = try await raw(body)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String ?? "Erledigt."
    }
}

enum Fmt {
    static func day(_ iso: String?) -> String {
        guard let iso, iso.count >= 10 else { return "" }
        let p = iso.prefix(10).split(separator: "-")
        return p.count == 3 ? "\(p[2]).\(p[1])." : iso
    }
    static func relDay(_ iso: String?, today: String) -> String {
        guard let iso else { return "" }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        guard let a = f.date(from: String(iso.prefix(10))), let b = f.date(from: today) else { return day(iso) }
        let n = Calendar.current.dateComponents([.day], from: b, to: a).day ?? 0
        switch n {
        case 0: return "heute"
        case 1: return "morgen"
        case 2...6: return "in \(n) Tagen"
        default: return day(iso)
        }
    }
}
