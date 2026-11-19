import Foundation
import WebKit

/// Verbindung der echten App zum eigenen Server: Anmeldung (Sitzung im Schlüsselbund), Abgleich, Schreiben.
/// Die Webansicht (für noch nicht nachgebaute Bereiche) bekommt dieselbe Sitzung.
@MainActor
final class PortalClient: ObservableObject {
    static let shared = PortalClient()
    @Published private(set) var loggedIn = Keychain.get("session") != nil
    @Published var online = true

    var base: URL? { Shared.serverURL }
    private var session: String? {
        get { Keychain.get("session").map { String(decoding: $0, as: UTF8.self) } }
        set { Keychain.set("session", newValue.map { Data($0.utf8) }); loggedIn = newValue != nil }
    }

    enum Failure: LocalizedError {
        case notSetUp, login, server(String)
        var errorDescription: String? {
            switch self {
            case .notSetUp: return "Keine Portal-Adresse."
            case .login: return "Bitte neu anmelden."
            case .server(let m): return m
            }
        }
    }

    // MARK: Anmeldung
    func login(password: String) async throws {
        guard let base else { throw Failure.notSetUp }
        var req = URLRequest(url: base.appendingPathComponent("api/login"))
        req.httpMethod = "POST"
        req.httpShouldHandleCookies = false
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["password": password])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw Failure.server("Keine Antwort") }
        guard http.statusCode == 200 else {
            throw Failure.server((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? "Anmeldung fehlgeschlagen")
        }
        let cookie = (http.value(forHTTPHeaderField: "Set-Cookie") ?? "")
        guard let sid = cookie.components(separatedBy: ";").first?.split(separator: "=", maxSplits: 1),
              sid.count == 2, sid[0] == "portal_session" else { throw Failure.server("Keine Sitzung erhalten") }
        session = String(sid[1])
        await shareWithWeb()
    }

    /// Bereits in der Webansicht angemeldet? Dann diese Sitzung übernehmen.
    func adoptWebSession() async {
        guard session == nil, let host = base?.host else { return }
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        if let c = cookies.first(where: { $0.name == "portal_session" && host.hasSuffix($0.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))) }) {
            session = c.value
        }
    }

    /// Sitzung auch der Webansicht geben, damit noch nicht nachgebaute Bereiche ohne zweite Anmeldung gehen
    func shareWithWeb() async {
        guard let sid = session, let host = base?.host,
              let c = HTTPCookie(properties: [.name: "portal_session", .value: sid, .domain: host, .path: "/", .secure: "TRUE",
                                              .expires: Date().addingTimeInterval(365 * 86400)]) else { return }
        await WKWebsiteDataStore.default().httpCookieStore.setCookie(c)
    }

    func logout() { session = nil }

    // MARK: Anfragen
    func request(_ path: String, query: [URLQueryItem] = [], json: Any? = nil, timeout: TimeInterval = 30) throws -> URLRequest {
        guard let base, let sid = session else { throw Failure.notSetUp }
        var c = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query }
        var req = URLRequest(url: c.url!, timeoutInterval: timeout)
        req.httpShouldHandleCookies = false
        req.setValue("portal_session=\(sid)", forHTTPHeaderField: "Cookie")
        if let json {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        return req
    }

    func send(_ req: URLRequest) async throws -> Any {
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { session = nil; throw Failure.login }
        let obj = (try? JSONSerialization.jsonObject(with: data)) ?? [:]
        guard code == 200 else { throw Failure.server((obj as? [String: Any])?["error"] as? String ?? "Fehler \(code)") }
        return obj
    }
}
