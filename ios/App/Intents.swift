import AppIntents
import UIKit
import UniformTypeIdentifiers
import WidgetKit

// Siri und Kurzbefehle: „Was steht heute an?“, „Nächste Frist“, Notiz/Lernaufgabe anlegen, Routine starten,
// Bereich öffnen. Erscheinen automatisch in der Kurzbefehle-App und in Spotlight.

@available(iOS 16.0, *)
struct HeuteIntent: AppIntent {
    static var title: LocalizedStringResource = "Was steht heute an?"
    static var description = IntentDescription("Termine und Stundenplan von heute aus dem Gedankenpalast.")

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let s = try await PortalAPI.summary()
        let list = s.todayEvents
        let text = list.isEmpty
            ? "Heute stehen keine Termine an." + (s.tomorrowEvents.first.map { " Morgen: \($0.zeit ?? "") \($0.titel ?? "")." } ?? "")
            : "Heute: " + list.map { [$0.zeit, $0.titel, $0.raum.map { "in \($0)" }].compactMap { $0 }.joined(separator: " ") }.joined(separator: "; ") + "."
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

@available(iOS 16.0, *)
struct FristIntent: AppIntent {
    static var title: LocalizedStringResource = "Nächste Fristen"
    static var description = IntentDescription("Die nächsten Fristen und Prüfungen.")

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let s = try await PortalAPI.summary()
        let text = s.deadlines.isEmpty ? "Keine anstehenden Fristen."
            : s.deadlines.prefix(3).map { "\($0.titel ?? "") \(Fmt.relDay($0.datum, today: s.today))" }.joined(separator: "; ") + "."
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

@available(iOS 16.0, *)
struct NotizIntent: AppIntent {
    static var title: LocalizedStringResource = "Notiz anlegen"
    static var description = IntentDescription("Legt im Gedankenpalast eine neue Notiz an.")
    @Parameter(title: "Text", requestValueDialog: "Was soll in die Notiz?") var text: String
    @Parameter(title: "Ordner", default: "") var ordner: String

    static var parameterSummary: some ParameterSummary { Summary("Notiz \(\.$text) anlegen") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await PortalAPI.action(["action": "note", "text": text, "folder": ordner])
        return .result(dialog: "Notiz angelegt.")
    }
}

@available(iOS 16.0, *)
struct LernaufgabeIntent: AppIntent {
    static var title: LocalizedStringResource = "Lernaufgabe anlegen"
    static var description = IntentDescription("Neue Lernaufgabe, optional mit Fälligkeit.")
    @Parameter(title: "Aufgabe", requestValueDialog: "Welche Lernaufgabe?") var titel: String
    @Parameter(title: "Fällig am") var faellig: Date?

    static var parameterSummary: some ParameterSummary { Summary("Lernaufgabe \(\.$titel) bis \(\.$faellig)") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        var body: [String: Any] = ["action": "task", "title": titel]
        if let faellig {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
            body["due"] = f.string(from: faellig)
        }
        try await PortalAPI.action(body)
        WidgetCenter.shared.reloadAllTimelines()
        return .result(dialog: "Lernaufgabe angelegt.")
    }
}

@available(iOS 16.0, *)
struct AusgabeIntent: AppIntent {
    static var title: LocalizedStringResource = "Ausgabe eintragen"
    static var description = IntentDescription("Trägt eine Ausgabe in den Finanzen des Gedankenpalasts ein.")
    @Parameter(title: "Betrag (€)", requestValueDialog: "Wie viel?") var betrag: Double
    @Parameter(title: "Wofür", default: "") var wofuer: String
    @Parameter(title: "Kategorie", default: "") var kategorie: String

    static var parameterSummary: some ParameterSummary { Summary("Ausgabe \(\.$betrag) € für \(\.$wofuer)") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let msg = try await PortalAPI.action(["action": "expense", "amount": String(betrag), "note": wofuer, "category": kategorie])
        return .result(dialog: IntentDialog(stringLiteral: msg))
    }
}

@available(iOS 16.0, *)
struct EinnahmeIntent: AppIntent {
    static var title: LocalizedStringResource = "Einnahme eintragen"
    static var description = IntentDescription("Trägt eine Einnahme (z. B. Lohn, BAföG) in den Finanzen ein.")
    @Parameter(title: "Betrag (€)", requestValueDialog: "Wie viel?") var betrag: Double
    @Parameter(title: "Von wem / wofür", default: "") var wofuer: String
    @Parameter(title: "Kategorie", default: "") var kategorie: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let msg = try await PortalAPI.action(["action": "income", "amount": String(betrag), "note": wofuer, "category": kategorie])
        return .result(dialog: IntentDialog(stringLiteral: msg))
    }
}

@available(iOS 16.0, *)
struct FinanzenIntent: AppIntent {
    static var title: LocalizedStringResource = "Ausgaben diesen Monat"
    static var description = IntentDescription("Sagt, wie viel du diesen Monat ausgegeben hast.")
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let data = try await PortalAPI.raw(["action": "finance"])
        let o = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let f = NumberFormatter(); f.numberStyle = .currency; f.locale = Locale(identifier: "de_DE")
        let spent = f.string(from: NSNumber(value: o["ausgaben"] as? Double ?? 0)) ?? "0 €"
        let fixed = f.string(from: NSNumber(value: o["festeKostenProMonat"] as? Double ?? 0)) ?? "0 €"
        let earned = f.string(from: NSNumber(value: o["einnahmen"] as? Double ?? 0)) ?? "0 €"
        let saldo = f.string(from: NSNumber(value: o["saldo"] as? Double ?? 0)) ?? "0 €"
        return .result(dialog: IntentDialog(stringLiteral: "Diesen Monat: \(earned) eingenommen, \(spent) ausgegeben – Saldo \(saldo). Laufende Kosten \(fixed) pro Monat."))
    }
}

@available(iOS 16.0, *)
struct RoutineIntent: AppIntent {
    static var title: LocalizedStringResource = "Routine starten"
    static var description = IntentDescription("Startet die Abendroutine (OPAL, Mails, Termine).")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let msg = try await PortalAPI.action(["action": "routine"])
        return .result(dialog: IntentDialog(stringLiteral: msg))
    }
}

@available(iOS 16.0, *)
enum Bereich: String, AppEnum {
    case kalender, stundenplan, lernen, unimail, pruefen, notizen, ablage, mail, musik, schach, portal
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Bereich"
    static var caseDisplayRepresentations: [Bereich: DisplayRepresentation] = [
        .kalender: "Kalender", .stundenplan: "Stundenplan", .lernen: "Lernen", .unimail: "Uni-Mail",
        .pruefen: "Noch zu prüfen", .notizen: "Notizen", .ablage: "Ablage", .mail: "Mail (Workspace)",
        .musik: "Musik", .schach: "Schach", .portal: "Startseite",
    ]
}

@available(iOS 16.0, *)
struct OeffnenIntent: AppIntent {
    static var title: LocalizedStringResource = "Bereich öffnen"
    static var description = IntentDescription("Öffnet den Gedankenpalast direkt im gewählten Bereich.")
    static var openAppWhenRun = true
    @Parameter(title: "Bereich") var bereich: Bereich

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared?.open(route: bereich.rawValue)
        return .result()
    }
}

@available(iOS 16.0, *)
struct NotizOeffnenIntent: AppIntent {
    static var title: LocalizedStringResource = "Notiz öffnen"
    static var description = IntentDescription("Öffnet eine Notiz im Gedankenpalast.")
    static var openAppWhenRun = true
    @Parameter(title: "Notiz") var notiz: NoteEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared?.open(route: "notizen/\(notiz.id)")
        return .result()
    }
}

@available(iOS 16.0, *)
struct TerminIntent: AppIntent {
    static var title: LocalizedStringResource = "Termin anzeigen"
    static var description = IntentDescription("Sagt, wann ein Termin ist.")
    @Parameter(title: "Termin") var termin: EventEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: "\(termin.titel) ist am \(Fmt.day(termin.datum))."))
    }
}

/// Fokus-Filter: in iOS-Einstellungen → Fokus → z. B. „Lernen“ → Fokusfilter → Gedankenpalast
@available(iOS 16.0, *)
struct GedankenpalastFocusFilter: SetFocusFilterIntent {
    static var title: LocalizedStringResource = "Gedankenpalast-Kalender"
    static var description = IntentDescription("Zeigt im Kalender nur die gewählten Bereiche, solange dieser Fokus an ist.")
    @Parameter(title: "Uni", default: true) var uni: Bool
    @Parameter(title: "Familie", default: false) var familie: Bool
    @Parameter(title: "Arbeit", default: false) var arbeit: Bool

    var displayRepresentation: DisplayRepresentation {
        let on = [uni ? "Uni" : nil, familie ? "Familie" : nil, arbeit ? "Arbeit" : nil].compactMap { $0 }
        return DisplayRepresentation(title: "Kalender: \(on.isEmpty ? "nichts" : on.joined(separator: ", "))")
    }

    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(["uni": uni, "familie": familie, "arbeit": arbeit], forKey: "focusLayers")
        await MainActor.run { DataStore.shared.objectWillChange.send() }
        return .result()
    }
}

@available(iOS 16.0, *)
struct GedankenpalastShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: HeuteIntent(), phrases: ["Was steht heute an in \(.applicationName)", "\(.applicationName) heute"],
                    shortTitle: "Heute", systemImageName: "calendar")
        AppShortcut(intent: FristIntent(), phrases: ["Nächste Fristen in \(.applicationName)", "\(.applicationName) Fristen"],
                    shortTitle: "Fristen", systemImageName: "clock.badge.exclamationmark")
        AppShortcut(intent: NotizIntent(), phrases: ["Neue Notiz in \(.applicationName)", "Notiz im \(.applicationName)"],
                    shortTitle: "Notiz", systemImageName: "note.text.badge.plus")
        AppShortcut(intent: LernaufgabeIntent(), phrases: ["Neue Lernaufgabe in \(.applicationName)"],
                    shortTitle: "Lernaufgabe", systemImageName: "checklist")
        AppShortcut(intent: AusgabeIntent(), phrases: ["Ausgabe in \(.applicationName)", "Neue Ausgabe in \(.applicationName)"],
                    shortTitle: "Ausgabe", systemImageName: "eurosign.circle")
        AppShortcut(intent: FinanzenIntent(), phrases: ["Wie viel habe ich ausgegeben in \(.applicationName)", "\(.applicationName) Ausgaben"],
                    shortTitle: "Ausgaben", systemImageName: "chart.bar")
        AppShortcut(intent: RoutineIntent(), phrases: ["Starte die Routine in \(.applicationName)", "\(.applicationName) Routine starten"],
                    shortTitle: "Routine", systemImageName: "play.circle")
        AppShortcut(intent: NotizOeffnenIntent(), phrases: ["Öffne Notiz \(\.$notiz) in \(.applicationName)", "Notiz \(\.$notiz) in \(.applicationName)"],
                    shortTitle: "Notiz öffnen", systemImageName: "note.text")
        AppShortcut(intent: TerminIntent(), phrases: ["Wann ist \(\.$termin) in \(.applicationName)"],
                    shortTitle: "Termin", systemImageName: "calendar.badge.clock")
        AppShortcut(intent: OeffnenIntent(), phrases: ["Öffne \(\.$bereich) in \(.applicationName)", "\(.applicationName) \(\.$bereich)"],
                    shortTitle: "Öffnen", systemImageName: "square.grid.2x2")
    }
}

// MARK: - Apple Notizen abgleichen (Apple lässt Apps nicht direkt an Notizen – nur über Kurzbefehle)
// Kurzbefehl „Apple Notizen abgleichen“: Notizen suchen → je Notiz „Apple-Notiz ins Portal“;
// dann „Portal-Notizen für Apple“ → je Eintrag Notiz erstellen → „Mit Apple-Notiz verknüpfen“.

private func isoDate(_ d: Date) -> String {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f.string(from: d)
}

@available(iOS 16.0, *)
struct NotizUebernehmenIntent: AppIntent {
    static var title: LocalizedStringResource = "Notiz ins Portal übernehmen"
    static var description = IntentDescription("Übernimmt eine Notiz aus der Notizen-App in den Gedankenpalast (neu oder aktualisiert; die neuere Änderung gewinnt).")
    @Parameter(title: "Titel") var titel: String
    @Parameter(title: "Inhalt", description: "Text der Notiz oder HTML") var inhalt: String
    @Parameter(title: "Erstellt") var erstellt: Date?
    @Parameter(title: "Geändert") var geaendert: Date?
    @Parameter(title: "Ordner", default: "") var ordner: String

    static var parameterSummary: some ParameterSummary {
        Summary("Notiz \(\.$titel) ins Portal übernehmen") { \.$inhalt; \.$erstellt; \.$geaendert; \.$ordner }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let msg = try await PortalAPI.action(["action": "appleNote", "title": titel, "content": inhalt,
                                              "created": isoDate(erstellt ?? Date()), "modified": isoDate(geaendert ?? erstellt ?? Date()), "folder": ordner])
        return .result(value: msg)
    }
}

@available(iOS 16.0, *)
struct PortalNotizEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Portal-Notiz"
    static var defaultQuery = PortalNotizQuery()
    var id: String
    @Property(title: "Titel") var titel: String
    @Property(title: "HTML") var html: String
    @Property(title: "Text") var text: String
    @Property(title: "Ordner") var ordner: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(titel)") }

    init(id: String, titel: String, html: String, text: String, ordner: String) {
        self.id = id; self.titel = titel; self.html = html; self.text = text; self.ordner = ordner
    }

    static func ausstehend() async throws -> [PortalNotizEntity] {
        let data = try await PortalAPI.raw(["action": "appleNotesPending"])
        let list = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["notes"] as? [[String: Any]] ?? []
        return list.compactMap { n in
            guard let id = n["id"] as? String else { return nil }
            return PortalNotizEntity(id: id, titel: n["title"] as? String ?? "Notiz", html: n["html"] as? String ?? "",
                                     text: n["text"] as? String ?? "", ordner: n["folder"] as? String ?? "")
        }
    }
}

@available(iOS 16.0, *)
struct PortalNotizQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [PortalNotizEntity] {
        try await PortalNotizEntity.ausstehend().filter { identifiers.contains($0.id) }
    }
    func suggestedEntities() async throws -> [PortalNotizEntity] { try await PortalNotizEntity.ausstehend() }
}

@available(iOS 16.0, *)
struct PortalNotizenExportIntent: AppIntent {
    static var title: LocalizedStringResource = "Portal-Notizen für die Notizen-App"
    static var description = IntentDescription("Notizen aus dem Gedankenpalast, die es in der Notizen-App noch nicht gibt.")

    func perform() async throws -> some IntentResult & ReturnsValue<[PortalNotizEntity]> {
        .result(value: try await PortalNotizEntity.ausstehend())
    }
}

@available(iOS 16.0, *)
struct NotizVerknuepfenIntent: AppIntent {
    static var title: LocalizedStringResource = "Mit Notiz der Notizen-App verknüpfen"
    static var description = IntentDescription("Merkt sich, dass eine Portal-Notiz jetzt auch in der Notizen-App liegt (damit sie nicht doppelt entsteht).")
    @Parameter(title: "Portal-Notiz") var notiz: PortalNotizEntity
    @Parameter(title: "Erstellt (Notizen-App)") var erstellt: Date?

    static var parameterSummary: some ParameterSummary { Summary("\(\.$notiz) mit Notiz der Notizen-App verknüpfen") { \.$erstellt } }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let msg = try await PortalAPI.action(["action": "appleNoteLink", "id": notiz.id, "created": isoDate(erstellt ?? Date())])
        return .result(value: msg)
    }
}


// MARK: - Zwischenablage zwischen iPhone/iPad und Laptop
@available(iOS 16.0, *)
struct InZwischenablageIntent: AppIntent {
    static var title: LocalizedStringResource = "In Gedankenpalast-Zwischenablage"
    static var description = IntentDescription("Legt Text, einen Link oder eine Datei in die Zwischenablage des Portals – am Laptop sofort abrufbar.")
    @Parameter(title: "Text") var text: String?
    @Parameter(title: "Datei") var datei: IntentFile?

    static var parameterSummary: some ParameterSummary { Summary("\(\.$text) in die Gedankenpalast-Zwischenablage") { \.$datei } }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        if let datei {
            try await PortalAPI.upload(datei.data, name: datei.filename, type: datei.type?.preferredMIMEType ?? "application/octet-stream", folder: nil, clip: true)
        } else if let text, !text.isEmpty {
            try await PortalAPI.action(["action": "clip", "text": text])
        } else {
            let pb = UIPasteboard.general   // nichts angegeben → aktuelle iPhone-Zwischenablage übernehmen
            if let img = pb.image, let png = img.pngData() {
                try await PortalAPI.upload(png, name: "Bild.png", type: "image/png", folder: nil, clip: true)
            } else if let s = pb.url?.absoluteString ?? pb.string, !s.isEmpty {
                try await PortalAPI.action(["action": "clip", "text": s])
            } else { return .result(dialog: "Die Zwischenablage ist leer.") }
        }
        return .result(dialog: "In der Zwischenablage – am Laptop unter Workspace → Zwischenablage.")
    }
}

@available(iOS 16.0, *)
struct AusZwischenablageIntent: AppIntent {
    static var title: LocalizedStringResource = "Aus Gedankenpalast-Zwischenablage kopieren"
    static var description = IntentDescription("Holt den neuesten Eintrag der Portal-Zwischenablage (z. B. vom Laptop) und kopiert ihn auf dieses Gerät.")

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile?> & ProvidesDialog {
        let data = try await PortalAPI.raw(["action": "clipLatest"])
        guard let c = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["clip"] as? [String: Any],
              let id = c["id"] as? String, let kind = c["kind"] as? String else {
            return .result(value: nil, dialog: "Die Zwischenablage ist leer.")
        }
        if kind == "text" || kind == "link" {
            let t = c["text"] as? String ?? ""
            if kind == "link", let u = URL(string: t) { UIPasteboard.general.url = u } else { UIPasteboard.general.string = t }
            return .result(value: IntentFile(data: Data(t.utf8), filename: "Text.txt", type: .plainText), dialog: "Kopiert – jetzt einfügen.")
        }
        let file = try await PortalAPI.raw(["action": "clipFile", "id": id])
        let name = c["name"] as? String ?? "Datei"
        let type = (c["type"] as? String).flatMap { UTType(mimeType: $0) } ?? UTType(filenameExtension: (name as NSString).pathExtension) ?? .data
        if kind == "image", let img = UIImage(data: file) { UIPasteboard.general.image = img }
        else { UIPasteboard.general.setData(file, forPasteboardType: type.identifier) }
        return .result(value: IntentFile(data: file, filename: name, type: type), dialog: "„\(name)“ kopiert – jetzt einfügen.")
    }
}
