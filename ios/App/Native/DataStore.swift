import Foundation
import WidgetKit

/// Alle Daten des Portals in der App: Abgleich mit dem Server (wie die Website), offline gespeichert.
/// Änderungen ohne Netz werden gemerkt und nachgereicht.
@MainActor
final class DataStore: ObservableObject {
    static let shared = DataStore()
    typealias Doc = [String: Any]

    @Published private(set) var revision = 0          // ändert sich bei jeder Änderung (für SwiftUI)
    @Published private(set) var syncing = false
    @Published var routineRunning: String?           // Startzeit der laufenden Routine (vom Server)
    private(set) var docs: [String: [String: Doc]] = [:]
    private var seq = 0
    private var pending: [[String: Any]] = []          // noch nicht übertragene Änderungen
    private var loop: Task<Void, Never>?
    private let client = PortalClient.shared

    private var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("portal-daten.json")
    }

    init() { loadCache() }

    // MARK: Lesen
    func all(_ coll: String) -> [Doc] { Array((docs[coll] ?? [:]).values) }
    func get(_ coll: String, _ id: String) -> Doc? { docs[coll]?[id] }
    func setting(_ id: String) -> Doc { get("settings", id) ?? [:] }

    // MARK: Abgleich
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.flush()
                do {
                    let wait = self.seq == 0 ? "0" : "25"
                    let req = try self.client.request("api/sync", query: [URLQueryItem(name: "since", value: String(self.seq)),
                                                                           URLQueryItem(name: "wait", value: wait)], timeout: 40)
                    let res = try await self.client.send(req) as? [String: Any] ?? [:]
                    self.apply(res)
                    self.client.online = true
                } catch {
                    self.client.online = false
                    if !self.client.loggedIn { self.loop = nil; return }
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
        }
    }
    func stop() { loop?.cancel(); loop = nil }
    func refreshNow() { stop(); start() }

    private func apply(_ res: [String: Any]) {
        let changes = res["changes"] as? [[String: Any]] ?? []
        for c in changes {
            guard let coll = c["coll"] as? String, let id = c["id"] as? String else { continue }
            if c["deleted"] as? Bool == true { docs[coll]?[id] = nil }
            else if var d = c["doc"] as? Doc { d["id"] = id; docs[coll, default: [:]][id] = d }
        }
        if let s = res["seq"] as? Int { seq = s }
        let rr = res["routineRunning"] as? String
        if rr != routineRunning { routineRunning = rr }
        if !changes.isEmpty {
            revision += 1; saveCache(); WidgetCenter.shared.reloadAllTimelines()
            SpotlightIndex.update(self)
            LiveLecture.update(self)
        }
    }

    // MARK: Schreiben (sofort lokal, dann zum Server)
    @discardableResult
    func patch(_ coll: String, _ id: String? = nil, _ fields: Doc) -> String {
        let id = id ?? "\(coll.prefix(4))_\(Int(Date().timeIntervalSince1970 * 1000))\(Int.random(in: 100...999))"
        var d = docs[coll]?[id] ?? ["id": id]
        for (k, v) in fields { if v is NSNull { d[k] = nil } else { d[k] = v } }
        docs[coll, default: [:]][id] = d
        var op: [String: Any] = ["coll": coll, "id": id, "fields": fields, "device": "ios"]
        if let base = docs[coll]?[id]?["_seq"] as? Int { op["baseSeq"] = base }
        pending.append(op)
        revision += 1; saveCache()
        Task { await flush() }
        return id
    }

    func delete(_ coll: String, _ id: String) {
        docs[coll]?[id] = nil
        pending.append(["coll": coll, "id": id, "delete": true])
        revision += 1; saveCache()
        Task { await flush() }
    }

    private var flushing = false
    func flush() async {
        guard !pending.isEmpty, !flushing else { return }
        flushing = true
        defer { flushing = false }
        let ops = pending
        do {
            _ = try await client.send(try client.request("api/batch", json: ["ops": ops]))
            pending.removeFirst(min(ops.count, pending.count))
            saveCache()
        } catch { /* offline: später erneut */ }
    }

    // MARK: Offline-Speicher
    private func saveCache() {
        let obj: [String: Any] = ["seq": seq, "docs": docs, "pending": pending]
        guard JSONSerialization.isValidJSONObject(obj), let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    private func loadCache() {
        guard let data = try? Data(contentsOf: file), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        seq = obj["seq"] as? Int ?? 0
        docs = obj["docs"] as? [String: [String: Doc]] ?? [:]
        pending = obj["pending"] as? [[String: Any]] ?? []
    }
    func reset() { docs = [:]; seq = 0; pending = []; try? FileManager.default.removeItem(at: file); revision += 1 }
}
