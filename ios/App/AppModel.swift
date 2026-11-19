import SwiftUI
import LocalAuthentication
import UserNotifications
import UniformTypeIdentifiers
import WebKit
import WidgetKit
import EventKit
import Photos

/// Zustand der App: Server-Adresse, Face-ID-Sperre, eingehende Dateien („Öffnen in …“), Mitteilungen.
final class AppModel: ObservableObject {
    /// für Siri („Bereich öffnen“), das ohne SwiftUI-Umgebung auf die App zugreift
    static weak var shared: AppModel?

    @Published var serverURL: URL? = UserDefaults.standard.url(forKey: "serverURL")
    @Published var locked = false
    @Published private(set) var faceID = UserDefaults.standard.bool(forKey: "faceID")
    @Published var embedURL: URL?                 // chess.com (und Apple-Webplayer) als eigener Bereich in der App
    @Published var showAppleMusic = false         // Apple Music eins zu eins (MusicKit)
    @Published var pencil: PencilSession?         // Pencil-Handschrift über der Notiz
    @Published var showAssistant = false          // Assistent (Apple Intelligence, iOS 26)
    var noteArea = NoteArea()
    /// false = Design der Website überall (Finns Wunsch); true = native iOS-Ansichten mit Tab-Leiste
    @Published private(set) var reminders = UserDefaults.standard.bool(forKey: "reminders")
    private var pendingImports: [URL] = []
    private var pendingRoute: String?
    weak var webView: WKWebView?

    init() {
        locked = faceID
        if Shared.serverURL == nil, let url = serverURL { Shared.serverURL = url }   // ältere Version: Adresse übernehmen
        AppModel.shared = self
        if let r = QuickAction.pending { pendingRoute = r; QuickAction.pending = nil }
    }

    // MARK: Server
    func setServer(_ url: URL) {
        serverURL = url; UserDefaults.standard.set(url, forKey: "serverURL")
        if Shared.serverURL != url { Shared.appKey = nil }
        Shared.serverURL = url
    }
    func resetServer() {
        serverURL = nil; UserDefaults.standard.removeObject(forKey: "serverURL")
        Shared.serverURL = nil; Shared.appKey = nil; Shared.cached = nil
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Cookie-Kopfzeile der Anmeldung im Portal (für Aufrufe außerhalb der Webansicht)
    private func cookieHeader(_ done: @escaping (String) -> Void) {
        guard let base = serverURL, let web = webView else { return }
        web.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            let host = base.host ?? ""
            done(cookies.filter { host.hasSuffix($0.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))) }
                .map { "\($0.name)=\($0.value)" }.joined(separator: "; "))
        }
    }

    /// Nach der Anmeldung einmal einen Geräte-Schlüssel holen, damit Widgets und Siri ohne Browser-Anmeldung arbeiten
    func ensureAppKey() {
        guard let base = serverURL else { return }
        if Shared.appKey != nil { refreshWidgets(); return }
        cookieHeader { header in
            guard !header.isEmpty else { return }
            var req = URLRequest(url: base.appendingPathComponent("api/app/key"))
            req.httpMethod = "POST"
            req.httpShouldHandleCookies = false
            req.setValue(header, forHTTPHeaderField: "Cookie")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["device": UIDevice.current.name])
            Task {
                guard let (data, resp) = try? await URLSession.shared.data(for: req),
                      (resp as? HTTPURLResponse)?.statusCode == 200,
                      let key = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["key"] as? String else { return }
                Shared.appKey = key
                self.refreshWidgets()
            }
        }
    }

    /// Für Push anmelden, sobald Mitteilungen erlaubt sind und der Geräte-Schlüssel da ist
    func registerPush() {
        guard Shared.appKey != nil else { return }
        UNUserNotificationCenter.current().getNotificationSettings { s in
            guard s.authorizationStatus == .authorized else { return }
            DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    func refreshWidgets() {
        registerPush()
        Task {
            if let s = try? await PortalAPI.summary() {
                WidgetCenter.shared.reloadAllTimelines()
                if reminders { await ReminderSync.sync(s) }
                await EventAlerts.schedule(s)
            }
        }
    }

    func setEventAlerts(_ on: Bool) {
        UserDefaults.standard.set(!on, forKey: "eventAlertsOff")
        if on {
            Task {
                _ = await Permissions.request("notifications")
                refreshWidgets()
            }
        } else { EventAlerts.clear() }
    }

    // MARK: Bereiche (Widgets, Siri, Links gedankenpalast://kalender)
    func open(route: String) {
        let r = route.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let target = r == "heute" ? "studium" : r
        guard let web = webView else { pendingRoute = target; return }
        locationHash(web, target)
    }
    private func locationHash(_ web: WKWebView, _ r: String) {
        let safe = r.filter { $0.isLetter || $0.isNumber || $0 == "/" || $0 == "-" }
        web.evaluateJavaScript("location.hash = '#/\(safe)'")
    }
    func pageLoaded() {
        if let r = pendingRoute, let web = webView { pendingRoute = nil; locationHash(web, r) }
        processImports()
        ensureAppKey()
        syncICloud()
    }

    /// Ablage ↔ iCloud Drive (Ordner „Gedankenpalast“ in der Dateien-App)
    func syncICloud(force: Bool = false) {
        guard let base = serverURL else { return }
        cookieHeader { header in Task { @MainActor in ICloudSync.run(base: base, cookie: header, force: force) } }
    }
    func setICloud(_ on: Bool) {
        UserDefaults.standard.set(!on, forKey: "icloudOff")
        if on { syncICloud(force: true) }
    }

    // MARK: Apple Erinnerungen (Fristen und Lernaufgaben in der Liste „Gedankenpalast“)
    func setReminders(_ on: Bool) {
        reminders = on; UserDefaults.standard.set(on, forKey: "reminders")
        if on {
            Task {
                if await Permissions.request("reminders") == "granted" { refreshWidgets() }
                else {
                    await MainActor.run {
                        self.reminders = false; UserDefaults.standard.set(false, forKey: "reminders")
                        self.webView?.evaluateJavaScript("window.portalToast && portalToast('Kein Zugriff auf Erinnerungen – bitte in den iOS-Einstellungen bei Gedankenpalast erlauben')")
                    }
                }
            }
        }
    }

    static func normalize(_ text: String) -> URL? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if !t.lowercased().hasPrefix("http") { t = "https://" + t }
        guard let c = URLComponents(string: t), c.scheme == "https", var host = c.host?.lowercased(), !host.isEmpty else { return nil }
        // „1-2-3-4“ (ohne Endung) → 1-2-3-4.sslip.io, „1.2.3.4“ → 1-2-3-4.sslip.io
        if host.range(of: #"^\d{1,3}-\d{1,3}-\d{1,3}-\d{1,3}$"#, options: .regularExpression) != nil { host += ".sslip.io" }
        if host.range(of: #"^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$"#, options: .regularExpression) != nil {
            host = host.replacingOccurrences(of: ".", with: "-") + ".sslip.io"
        }
        return URL(string: "https://\(host)\(c.port.map { ":\($0)" } ?? "")/")
    }

    /// nil = Portal gefunden, sonst der Grund in Worten
    static func checkPortal(_ url: URL) async -> String? {
        do {
            let (_, resp) = try await URLSession.shared.data(from: url.appendingPathComponent("login.html"))
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return (200..<400).contains(code) ? nil : "\(url.host ?? "") antwortet, aber nicht wie das Portal (Code \(code))."
        } catch let e as URLError {
            switch e.code {
            case .cannotFindHost, .dnsLookupFailed: return "Die Adresse \(url.host ?? "") gibt es nicht – bitte genau wie in Safari eingeben (z. B. mit .sslip.io am Ende)."
            case .notConnectedToInternet: return "Keine Internetverbindung."
            case .timedOut, .cannotConnectToHost: return "\(url.host ?? "") ist gerade nicht erreichbar (Server aus oder blockiert)."
            case .serverCertificateUntrusted, .secureConnectionFailed, .serverCertificateHasBadDate:
                return "Sichere Verbindung zu \(url.host ?? "") fehlgeschlagen (Zertifikat)."
            default: return "Verbindung zu \(url.host ?? "") fehlgeschlagen: \(e.localizedDescription)"
            }
        } catch { return error.localizedDescription }
    }

    // MARK: Face ID
    /// Apple Music → eins zu eins wie die Apple-Music-App (MusicKit); andere Dienste (chess.com) als eigener Bereich
    func openEmbedded(_ url: URL) {
        if url.host?.lowercased() == "music.apple.com" && !UserDefaults.standard.bool(forKey: "appleMusicWeb") { showAppleMusic = true }
        else { embedURL = url }
    }

    func setClipAuto(_ on: Bool) { UserDefaults.standard.set(on, forKey: "clipAuto") }

    /// Kurze Meldung im Portal (z. B. „liegt in der Zwischenablage“)
    static func toast(_ msg: String) {
        guard let d = try? JSONSerialization.data(withJSONObject: [msg]), let arr = String(data: d, encoding: .utf8) else { return }
        DispatchQueue.main.async { shared?.webView?.evaluateJavaScript("window.portalToast && portalToast(\(arr)[0])") }
    }

    func setFaceID(_ on: Bool) { faceID = on; UserDefaults.standard.set(on, forKey: "faceID") }

    func scenePhaseChanged(_ phase: ScenePhase) {
        if phase == .background && faceID { locked = true }
        if phase == .active && locked { unlock() }
        if phase == .active && Shared.appKey != nil { refreshWidgets() }
        if phase == .active { syncICloud(); Task { await PhotoAlbumSync.run() }; Task { @MainActor in await ClipSync.onForeground() } }
        if phase == .background { WidgetCenter.shared.reloadAllTimelines() }
    }

    func unlock() {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { locked = false; return }
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Gedankenpalast entsperren") { ok, _ in
            DispatchQueue.main.async { if ok { self.locked = false } }
        }
    }

    // MARK: Mitteilungen (vom Portal angestoßen, z. B. „Routine fertig“)
    func notify(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else {
                DispatchQueue.main.async {
                    self.webView?.evaluateJavaScript("window.portalToast && portalToast('Mitteilungen sind aus – Einstellungen → App auf iPhone & iPad → Berechtigungen')")
                }
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    func setBadge(_ count: Int) {
        UNUserNotificationCenter.current().setBadgeCount(count) { _ in }
    }

    // MARK: „Öffnen in …“ / Teilen → Ablage (Eingang) → im Portal „Wohin damit?“
    func handleOpen(_ url: URL) {
        if url.scheme == "gedankenpalast" {       // Widget oder Link: gedankenpalast://kalender
            if url.host == "zwischenablage" && url.query == "abgleich" {   // Knopf im Kontrollzentrum
                Task { @MainActor in await ClipSync.onForeground(force: true) }
            }
            open(route: (url.host ?? "") + url.path)
            return
        }
        guard url.isFileURL else { return }
        pendingImports.append(url)
        processImports()
    }

    func processImports() {
        guard let base = serverURL, let web = webView, !pendingImports.isEmpty else { return }
        let files = pendingImports
        pendingImports = []
        web.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            let host = base.host ?? ""
            let header = cookies
                .filter { host.hasSuffix($0.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))) }
                .map { "\($0.name)=\($0.value)" }
                .joined(separator: "; ")
            Task {
                var ok = 0
                for file in files {
                    let scoped = file.startAccessingSecurityScopedResource()
                    defer { if scoped { file.stopAccessingSecurityScopedResource() } }
                    guard let data = try? Data(contentsOf: file) else { continue }
                    var comps = URLComponents(url: base.appendingPathComponent("api/upload"), resolvingAgainstBaseURL: false)!
                    comps.queryItems = [URLQueryItem(name: "ablage", value: "1"),
                                        URLQueryItem(name: "folder", value: "Eingang"),
                                        URLQueryItem(name: "pending", value: "1")]
                    var req = URLRequest(url: comps.url!)
                    req.httpMethod = "POST"
                    req.httpShouldHandleCookies = false
                    req.setValue(header, forHTTPHeaderField: "Cookie")
                    req.setValue(file.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "datei",
                                 forHTTPHeaderField: "X-Filename")
                    req.setValue(Self.mime(for: file), forHTTPHeaderField: "Content-Type")
                    if let result = try? await URLSession.shared.upload(for: req, from: data),
                       let http = result.1 as? HTTPURLResponse, http.statusCode == 200 { ok += 1 }
                }
                let js = ok > 0
                    ? "location.hash = '#/einordnen'"
                    : "window.portalToast && portalToast('Datei konnte nicht übertragen werden – bitte im Portal angemeldet sein')"
                await MainActor.run { web.evaluateJavaScript(js) }
            }
        }
    }

    static func mime(for url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }
}

/// Einweg-Abgleich: Fristen und offene Lernaufgaben aus dem Portal erscheinen in Apple Erinnerungen
/// (Liste „Gedankenpalast“). Bereits angelegte werden nicht doppelt angelegt; Abhaken in Erinnerungen bleibt dort.
enum ReminderSync {
    static let store = EKEventStore()

    static func requestAccess() async -> Bool {
        if #available(iOS 17.0, *) { return (try? await store.requestFullAccessToReminders()) ?? false }
        return await withCheckedContinuation { c in store.requestAccess(to: .reminder) { ok, _ in c.resume(returning: ok) } }
    }

    private static func list() -> EKCalendar? {
        let id = UserDefaults.standard.string(forKey: "reminderList")
        if let id, let cal = store.calendar(withIdentifier: id) { return cal }
        let cal = EKCalendar(for: .reminder, eventStore: store)
        cal.title = "Gedankenpalast"
        guard let src = store.defaultCalendarForNewReminders()?.source ?? store.sources.first(where: { $0.sourceType == .calDAV || $0.sourceType == .local }) else { return nil }
        cal.source = src
        do { try store.saveCalendar(cal, commit: true) } catch { return nil }
        UserDefaults.standard.set(cal.calendarIdentifier, forKey: "reminderList")
        return cal
    }

    static func sync(_ s: PortalSummary) async {
        guard EKEventStore.authorizationStatus(for: .reminder) == statusFull, let cal = list() else { return }
        var known = Set(UserDefaults.standard.stringArray(forKey: "reminderKeys") ?? [])
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        // Rückweg: in Erinnerungen abgehakte Lernaufgaben → im Portal erledigt
        var links = UserDefaults.standard.dictionary(forKey: "reminderTasks") as? [String: String] ?? [:]   // Erinnerung → Aufgaben-ID
        if !links.isEmpty {
            let pred = store.predicateForCompletedReminders(withCompletionDateStarting: nil, ending: nil, calendars: [cal])
            let done: [EKReminder] = await withCheckedContinuation { c in store.fetchReminders(matching: pred) { c.resume(returning: $0 ?? []) } }
            for r in done {
                guard let tid = links[r.calendarItemIdentifier] else { continue }
                if (try? await PortalAPI.action(["action": "taskDone", "id": tid])) != nil { links[r.calendarItemIdentifier] = nil }
            }
        }
        @discardableResult
        func add(_ key: String, _ title: String, _ due: String?, _ notes: String?) -> EKReminder? {
            guard !known.contains(key) else { return nil }
            let r = EKReminder(eventStore: store)
            r.calendar = cal
            r.title = title
            r.notes = notes
            if let due, let d = f.date(from: String(due.prefix(10))) {
                var c = Calendar.current.dateComponents([.year, .month, .day], from: d)
                c.hour = 9
                r.dueDateComponents = c
                r.addAlarm(EKAlarm(absoluteDate: Calendar.current.date(from: c) ?? d))
            }
            if (try? store.save(r, commit: false)) != nil { known.insert(key); return r }
            return nil
        }
        for d in s.deadlines { add("frist|\(d.titel ?? "")|\(d.datum ?? "")", d.titel ?? "Frist", d.datum, d.kurs) }
        var newLinks: [(EKReminder, String)] = []
        for t in s.tasks {
            if let r = add("aufgabe|\(t.id ?? t.titel ?? "")|\(t.faellig ?? "")", t.titel ?? "Lernaufgabe", t.faellig, t.kurs), let id = t.id { newLinks.append((r, id)) }
        }
        try? store.commit()
        for (r, id) in newLinks { links[r.calendarItemIdentifier] = id }   // Kennung steht erst nach dem Speichern fest
        UserDefaults.standard.set(links, forKey: "reminderTasks")
        UserDefaults.standard.set(Array(Array(known).suffix(500)), forKey: "reminderKeys")   // ArraySlice wäre kein Plist-Typ → Absturz
    }

    private static var statusFull: EKAuthorizationStatus {
        if #available(iOS 17.0, *) { return .fullAccess }
        return .authorized
    }
}

/// Erinnerungen an eigene Termine ohne Apple Kalender: 15 Minuten vor Terminen/Sitzungen, Fristen am Vortag 18 Uhr.
/// Werden bei jedem Öffnen/Wechsel der App für die nächste Woche neu eingeplant (iOS erlaubt höchstens 64).
enum EventAlerts {
    static var enabled: Bool { !UserDefaults.standard.bool(forKey: "eventAlertsOff") }
    static let prefix = "gp-termin-"

    static func clear() {
        let c = UNUserNotificationCenter.current()
        c.getPendingNotificationRequests { reqs in
            c.removePendingNotificationRequests(withIdentifiers: reqs.map(\.identifier).filter { $0.hasPrefix(prefix) })
        }
    }

    static func schedule(_ s: PortalSummary) async {
        let c = UNUserNotificationCenter.current()
        guard enabled, await c.notificationSettings().authorizationStatus == .authorized else { return }
        let pending = await c.pendingNotificationRequests()
        c.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(prefix) })
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; f.locale = Locale(identifier: "en_US_POSIX")
        var plans: [(Date, String, String, String)] = []
        for e in s.events {
            guard let t = e.zeit, let start = f.date(from: "\(e.datum) \(t)") else { continue }
            let at = start.addingTimeInterval(-15 * 60)
            guard at > Date() else { continue }
            let body = [t + (e.ende.map { "–" + $0 } ?? ""), e.raum].compactMap { $0 }.joined(separator: " · ")
            plans.append((at, e.titel ?? "Termin", "In 15 Minuten · " + body, "\(e.datum)|\(t)|\(e.titel ?? "")"))
        }
        for d in s.deadlines {
            guard let day = d.datum, let due = f.date(from: "\(day.prefix(10)) 18:00"),
                  let at = Calendar.current.date(byAdding: .day, value: -1, to: due), at > Date() else { continue }
            plans.append((at, (d.art == "pruefung" ? "Prüfung morgen: " : "Frist morgen: ") + (d.titel ?? ""), d.kurs ?? "", "frist|\(day)|\(d.titel ?? "")"))
        }
        for (at, title, body, key) in plans.sorted(by: { $0.0 < $1.0 }).prefix(50) {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: at)
            let id = prefix + String(key.hashValue, radix: 36)
            try? await c.add(UNNotificationRequest(identifier: id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
        }
    }
}

/// Album „Uni“ in Fotos → Ablage („Wohin damit?“). Nur neue Fotos seit dem letzten Abgleich, nur nach Erlaubnis.
enum PhotoAlbumSync {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "photoAlbumSync") }
    static func set(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "photoAlbumSync")
        if on && UserDefaults.standard.object(forKey: "photoAlbumSince") == nil {
            UserDefaults.standard.set(Date().addingTimeInterval(-7 * 86400), forKey: "photoAlbumSince")   // beim Einschalten: letzte Woche
        }
    }
    private static var running = false

    static func run() async {
        guard enabled, !running, PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized || PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited else { return }
        running = true
        defer { running = false }
        let albums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        var uni: PHAssetCollection?
        albums.enumerateObjects { c, _, stop in if c.localizedTitle?.lowercased() == "uni" { uni = c; stop.pointee = true } }
        guard let album = uni else { return }
        let since = UserDefaults.standard.object(forKey: "photoAlbumSince") as? Date ?? Date()
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "creationDate > %@ AND mediaType == %d", since as NSDate, PHAssetMediaType.image.rawValue)
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let assets = PHAsset.fetchAssets(in: album, options: opts)
        var newest = since
        for i in 0..<assets.count {
            let a = assets.object(at: i)
            let ro = PHImageRequestOptions(); ro.isNetworkAccessAllowed = true; ro.version = .current; ro.deliveryMode = .highQualityFormat
            let data: Data? = await withCheckedContinuation { c in
                PHImageManager.default().requestImageDataAndOrientation(for: a, options: ro) { d, _, _, _ in c.resume(returning: d) }
            }
            guard let data else { continue }
            let name = "Uni-Foto \(a.creationDate.map { $0.formatted(.dateTime.year().month().day().hour().minute().second().locale(Locale(identifier: "de_DE"))) } ?? "").jpg"
            if (try? await PortalAPI.upload(data, name: name, type: "image/jpeg", folder: nil)) != nil, let d = a.creationDate { newest = max(newest, d) }
        }
        UserDefaults.standard.set(newest, forKey: "photoAlbumSince")
    }
}
