import AppIntents
import WidgetKit

// Aktionen, die App und Widgets gemeinsam nutzen: Lernaufgabe im Widget abhaken, Routine im Kontrollzentrum starten,
// Notizen und Termine als „Dinge“ für Siri und Kurzbefehle (nur persönliche Daten).

struct TaskDoneIntent: AppIntent {
    static var title: LocalizedStringResource = "Lernaufgabe abhaken"
    static var isDiscoverable = false
    @Parameter(title: "Aufgabe") var id: String
    init() {}
    init(id: String) { self.id = id }
    func perform() async throws -> some IntentResult {
        try await PortalAPI.action(["action": "taskDone", "id": id])
        if var s = Shared.cached { s.tasks.removeAll { $0.id == id }; Shared.cached = s }
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

struct StartRoutineIntent: AppIntent {
    static var title: LocalizedStringResource = "Routine starten"
    static var description = IntentDescription("Startet die Abendroutine des Gedankenpalasts.")
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let msg = try await PortalAPI.action(["action": "routine"])
        return .result(dialog: IntentDialog(stringLiteral: msg))
    }
}

// MARK: Notizen und Termine für Siri („Öffne Notiz VWL in Gedankenpalast“)
struct NoteEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Notiz"
    static var defaultQuery = NoteQuery()
    var id: String
    var titel: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(titel)") }
}

struct NoteQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [NoteEntity] {
        try await search("").filter { identifiers.contains($0.id) }
    }
    func entities(matching string: String) async throws -> [NoteEntity] { try await search(string) }
    func suggestedEntities() async throws -> [NoteEntity] { try await search("") }
    private func search(_ q: String) async throws -> [NoteEntity] {
        let res = try await PortalAPI.search(q)
        return (res["notes"] as? [[String: Any]] ?? []).compactMap { n in
            guard let id = n["id"] as? String else { return nil }
            return NoteEntity(id: id, titel: n["titel"] as? String ?? "Notiz")
        }
    }
}

struct EventEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Termin"
    static var defaultQuery = EventQuery()
    var id: String
    var titel: String
    var datum: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(titel)", subtitle: "\(Fmt.day(datum))") }
}

struct EventQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [EventEntity] { try await search("").filter { identifiers.contains($0.id) } }
    func entities(matching string: String) async throws -> [EventEntity] { try await search(string) }
    func suggestedEntities() async throws -> [EventEntity] { try await search("") }
    private func search(_ q: String) async throws -> [EventEntity] {
        let res = try await PortalAPI.search(q)
        return (res["events"] as? [[String: Any]] ?? []).compactMap { e in
            guard let id = e["id"] as? String else { return nil }
            return EventEntity(id: id, titel: e["titel"] as? String ?? "Termin", datum: e["datum"] as? String ?? "")
        }
    }
}

extension PortalAPI {
    static func search(_ q: String) async throws -> [String: Any] {
        let data = try await raw(["action": "search", "q": q])
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
