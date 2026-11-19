import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

// Assistent auf dem Gerät (Apples Sprachmodell, iOS 26, Apple Intelligence). Keine Daten verlassen das Gerät.
// Zugriff NUR auf persönliche Daten (wie die Claude-Verbindung): Termine und Fristen lesen, Notizen und Lernaufgaben
// vorschlagen. Uni-Mails, OPAL, „Noch zu prüfen“, Routine und Einstellungen gibt es für ihn nicht.
// Änderungen werden erst nach „Ausführen“ übernommen.

struct ProposedAction: Identifiable, Hashable {
    let id = UUID()
    let kind: String          // "note" | "task"
    let title: String
    let text: String
    let due: String?
    var done = false
}

@MainActor
final class AssistantState: ObservableObject {
    @Published var proposals: [ProposedAction] = []
    static let shared = AssistantState()
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
struct TermineTool: Tool {
    let name = "termineLesen"
    let description = "Liest die eigenen Termine und Stundenplan-Veranstaltungen der nächsten Tage."
    @Generable struct Arguments {
        @Guide(description: "Anzahl Tage ab heute, 1 bis 14") var tage: Int
    }
    func call(arguments: Arguments) async throws -> String {
        let days = max(1, min(arguments.tage, 14))
        return await MainActor.run {
            let occ = Planning.occurrences(DataStore.shared, from: Planning.today, to: Planning.str(Planning.add(Date(), days - 1)))
            if occ.isEmpty { return "Keine Termine." }
            return occ.prefix(40).map { "\(Planning.pretty($0.date)) \($0.time ?? "ganztägig") \($0.title)\($0.room.map { " (\($0))" } ?? "")\($0.cancelled ? " – fällt aus" : "")" }.joined(separator: "\n")
        }
    }
}

@available(iOS 26.0, *)
struct FristenTool: Tool {
    let name = "fristenLesen"
    let description = "Liest anstehende Fristen, Prüfungen und offene Lernaufgaben."
    @Generable struct Arguments {
        @Guide(description: "Immer true") var alle: Bool
    }
    func call(arguments: Arguments) async throws -> String {
        await MainActor.run {
            let s = DataStore.shared, today = Planning.today
            let f = s.all("events").filter { ["frist", "pruefung"].contains($0["typ"] as? String ?? "") && ($0["date"] as? String ?? "") >= today }
                .sorted { ($0["date"] as? String ?? "") < ($1["date"] as? String ?? "") }.prefix(15)
                .map { "Frist \($0["date"] as? String ?? ""): \($0["title"] as? String ?? "")" }
            let t = s.all("tasks").filter { !($0["done"] as? Bool ?? false) }.prefix(15)
                .map { "Lernaufgabe: \($0["title"] as? String ?? "")\(($0["due"] as? String).map { " bis \($0)" } ?? "")" }
            let all = f + t
            return all.isEmpty ? "Keine Fristen oder Lernaufgaben." : all.joined(separator: "\n")
        }
    }
}

@available(iOS 26.0, *)
struct NotizVorschlagTool: Tool {
    let name = "notizVorschlagen"
    let description = "Schlägt eine neue Notiz vor. Sie wird erst angelegt, wenn der Nutzer bestätigt."
    @Generable struct Arguments {
        @Guide(description: "Kurzer Titel") var titel: String
        @Guide(description: "Inhalt der Notiz") var text: String
    }
    func call(arguments: Arguments) async throws -> String {
        await MainActor.run { AssistantState.shared.proposals.append(ProposedAction(kind: "note", title: arguments.titel, text: arguments.text, due: nil)) }
        return "Vorschlag „\(arguments.titel)“ wartet auf Bestätigung durch den Nutzer."
    }
}

@available(iOS 26.0, *)
struct AufgabeVorschlagTool: Tool {
    let name = "lernaufgabeVorschlagen"
    let description = "Schlägt eine neue Lernaufgabe vor. Sie wird erst angelegt, wenn der Nutzer bestätigt."
    @Generable struct Arguments {
        @Guide(description: "Was zu tun ist") var titel: String
        @Guide(description: "Fälligkeit als JJJJ-MM-TT oder leer") var faellig: String
    }
    func call(arguments: Arguments) async throws -> String {
        let due = arguments.faellig.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil ? arguments.faellig : nil
        await MainActor.run { AssistantState.shared.proposals.append(ProposedAction(kind: "task", title: arguments.titel, text: "", due: due)) }
        return "Vorschlag „\(arguments.titel)“ wartet auf Bestätigung durch den Nutzer."
    }
}

@available(iOS 26.0, *)
struct AssistantView: View {
    struct Message: Identifiable { let id = UUID(); let me: Bool; let text: String }
    @EnvironmentObject var store: DataStore
    @ObservedObject private var state = AssistantState.shared
    @State private var messages: [Message] = []
    @State private var input = ""
    @State private var busy = false
    @State private var session: LanguageModelSession?

    var body: some View {
        Group {
            switch SystemLanguageModel.default.availability {
            case .available: chat
            case .unavailable(let reason):
                ContentUnavailableView("Assistent nicht verfügbar", systemImage: "sparkles",
                                       description: Text(Self.reason(reason)))
            }
        }
        .navigationTitle("Assistent")
    }

    private var chat: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                PortalList {
                    if messages.isEmpty {
                        Text("Frag z. B. „Was steht morgen an?“, „Welche Fristen kommen?“ oder „Leg eine Lernaufgabe für Kapitel 4 bis Freitag an“. Ich sehe nur deine Planung und lege Notizen/Lernaufgaben erst nach deiner Bestätigung an – keine Uni-Mails, kein OPAL.")
                            .foregroundStyle(.secondary).font(.callout)
                    }
                    ForEach(messages) { m in
                        HStack {
                            if m.me { Spacer(minLength: 40) }
                            Text(m.text).padding(10)
                                .background(RoundedRectangle(cornerRadius: 14).fill(m.me ? Theme.accent.opacity(0.25) : Color.white.opacity(0.08)))
                            if !m.me { Spacer(minLength: 40) }
                        }.listRowSeparator(.hidden).id(m.id)
                    }
                    ForEach($state.proposals) { $p in
                        if !p.done {
                            VStack(alignment: .leading, spacing: 6) {
                                Label(p.kind == "note" ? "Notiz anlegen" : "Lernaufgabe anlegen", systemImage: p.kind == "note" ? "note.text.badge.plus" : "checklist")
                                    .font(.caption.bold()).foregroundStyle(Theme.accent)
                                Text(p.title).fontWeight(.medium)
                                if !p.text.isEmpty { Text(p.text).font(.caption).foregroundStyle(.secondary).lineLimit(4) }
                                if let d = p.due { Text("bis \(Planning.pretty(d))").font(.caption).foregroundStyle(.secondary) }
                                HStack {
                                    Button("Ausführen") { run(p); p.done = true }.buttonStyle(.borderedProminent).tint(Theme.accent)
                                    Button("Verwerfen", role: .cancel) { p.done = true }.buttonStyle(.bordered)
                                }
                            }
                            .padding(10).background(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.accent.opacity(0.5)))
                            .listRowSeparator(.hidden)
                        }
                    }
                    if busy { ProgressView().listRowSeparator(.hidden) }
                }
                .listStyle(.plain)
                .onChange(of: messages.count) { _ in if let l = messages.last { withAnimation { proxy.scrollTo(l.id) } } }
            }
            HStack {
                TextField("Nachricht", text: $input, axis: .vertical).lineLimit(1...4).onSubmit(send)
                    .padding(10).background(RoundedRectangle(cornerRadius: 18).fill(Color.white.opacity(0.08)))
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title) }.disabled(busy || input.trimmingCharacters(in: .whitespaces).isEmpty)
            }.padding()
        }
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input = ""; messages.append(Message(me: true, text: text)); busy = true
        Task {
            if session == nil {
                session = LanguageModelSession(tools: [TermineTool(), FristenTool(), NotizVorschlagTool(), AufgabeVorschlagTool()], instructions: """
                Du bist der Assistent im Gedankenpalast, dem Studienportal von Finn (PPES, TU Chemnitz). Antworte kurz auf Deutsch.
                Heute ist \(Planning.pretty(Planning.today)) (\(Planning.today)). Nutze die Werkzeuge für Termine, Fristen und Lernaufgaben.
                Du hast keinen Zugriff auf Uni-Mails, OPAL, Prüfpunkte, die Routine oder Einstellungen – sag das, wenn danach gefragt wird.
                Neue Notizen oder Lernaufgaben nur über die Vorschlags-Werkzeuge; der Nutzer bestätigt sie selbst. Nichts löschen.
                """)
            }
            do {
                let r = try await session!.respond(to: text)
                messages.append(Message(me: false, text: r.content))
            } catch {
                messages.append(Message(me: false, text: "Das hat nicht geklappt: \(error.localizedDescription)"))
                session = nil
            }
            busy = false
        }
    }

    private func run(_ p: ProposedAction) {
        let now = ISO8601DateFormatter().string(from: Date())
        if p.kind == "note" {
            let body = "<h1>\(NoteText.escape(p.title))</h1>" + p.text.components(separatedBy: "\n").map { "<p>\(NoteText.escape($0))</p>" }.joined()
            store.patch("notes", nil, ["title": p.title, "body": body, "folder": "fld_allg", "createdAt": now, "updatedAt": now])
        } else {
            store.patch("tasks", nil, ["title": p.title, "due": p.due.map { $0 as Any } ?? NSNull(), "progress": 0, "done": false])
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        messages.append(Message(me: false, text: p.kind == "note" ? "Notiz „\(p.title)“ angelegt." : "Lernaufgabe „\(p.title)“ angelegt."))
    }

    static func reason(_ r: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch r {
        case .deviceNotEligible: return "Dieses Gerät unterstützt Apple Intelligence nicht (iPad mit M1 oder neuer bzw. iPhone 15 Pro oder neuer)."
        case .appleIntelligenceNotEnabled: return "Apple Intelligence ist aus – Einstellungen → Apple Intelligence & Siri einschalten."
        case .modelNotReady: return "Das Sprachmodell wird noch geladen. Bitte später erneut versuchen."
        @unknown default: return "Gerade nicht verfügbar."
        }
    }
}
#endif


/// Ob der Assistent auf diesem Gerät läuft (iOS 26 + Apple Intelligence, z. B. ab iPhone 15 Pro)
enum AssistantAvailability {
    static var available: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), case .available = SystemLanguageModel.default.availability { return true }
        #endif
        return false
    }
}

/// Aus der Website-Ansicht geöffnet (Einstellungen → App): Assistent als Blatt
struct AssistantSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Group {
                #if canImport(FoundationModels)
                if #available(iOS 26.0, *) { AssistantView().environmentObject(DataStore.shared) }
                else { ContentUnavailableView("Assistent nicht verfügbar", systemImage: "sparkles", description: Text("Braucht iOS 26 und Apple Intelligence.")) }
                #else
                ContentUnavailableView("Assistent nicht verfügbar", systemImage: "sparkles", description: Text("Braucht iOS 26 und Apple Intelligence."))
                #endif
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }
}
