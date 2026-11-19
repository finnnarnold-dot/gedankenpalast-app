import WidgetKit
import SwiftUI
import AppIntents

// Widgets für Home-Bildschirm und Sperrbildschirm: Heute, Fristen & Aufgaben, Mail.
// Daten kommen über den Geräte-Schlüssel vom Portal; ohne Netz wird die letzte Übersicht gezeigt.

struct Entry: TimelineEntry {
    let date: Date
    let summary: PortalSummary?
    let error: String?
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: Date(), summary: .sample, error: nil) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: Date(), summary: context.isPreview ? .sample : (Shared.cached ?? .sample), error: nil))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        Task {
            var entry: Entry
            do { entry = Entry(date: Date(), summary: try await PortalAPI.summary(), error: nil) }
            catch { entry = Entry(date: Date(), summary: Shared.cached, error: error.localizedDescription) }
            // alle 30 Minuten neu; zusätzlich frischt die App die Widgets auf, wenn sich etwas ändert
            completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30 * 60))))
        }
    }
}

// MARK: Farben im Stil des Portals
enum Palette {
    static let bg = Color(red: 0.11, green: 0.105, blue: 0.098)
    static let accent = Color(red: 0.80, green: 0.84, blue: 0.64)
    static let warn = Color(red: 0.93, green: 0.62, blue: 0.45)
}

extension View {
    @ViewBuilder func widgetBackground() -> some View {
        if #available(iOS 17.0, *) { containerBackground(Palette.bg, for: .widget) }
        else { background(Palette.bg) }
    }
}

struct EventRow: View {
    let e: PortalSummary.Event
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(e.kategorie == "stundenplan" ? Palette.accent : Palette.warn).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(e.titel ?? "Termin").font(.caption.bold()).lineLimit(1)
                Text([e.zeit.map { $0 + (e.ende.map { "–" + $0 } ?? "") }, e.raum].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

// MARK: Heute
struct TodayView: View {
    @Environment(\.widgetFamily) var family
    let entry: Entry

    var body: some View {
        let s = entry.summary
        switch family {
        case .accessoryRectangular:
            if let e = s?.nextEvent() {
                VStack(alignment: .leading) {
                    Text(e.zeit ?? "ganztägig").font(.caption.bold())
                    Text(e.titel ?? "").font(.caption).lineLimit(1)
                    if let r = e.raum { Text(r).font(.caption2).lineLimit(1) }
                }
            } else { Text("Heute frei").font(.caption) }
        case .accessoryInline:
            Text(s?.nextEvent().map { "\($0.zeit ?? "") \($0.titel ?? "")" } ?? "Heute frei")
        case .accessoryCircular:
            VStack(spacing: 0) {
                Image(systemName: "calendar")
                Text("\(s?.todayEvents.count ?? 0)").font(.headline)
            }
        default:
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Heute").font(.headline).foregroundStyle(Palette.accent)
                    Spacer()
                    if let w = s?.weather { Label("\(w.temp)°", systemImage: w.symbol).font(.caption.bold()).symbolRenderingMode(.multicolor) }
                    Text(Date(), format: .dateTime.weekday(.abbreviated).day().month()).font(.caption2).foregroundStyle(.secondary)
                }
                let list = s?.todayEvents ?? []
                if s == nil {
                    Text(entry.error ?? "App einmal öffnen").font(.caption).foregroundStyle(.secondary)
                } else if list.isEmpty {
                    Text("Keine Termine heute").font(.caption).foregroundStyle(.secondary)
                    if let m = s?.tomorrowEvents.first { Text("Morgen: \(m.zeit ?? "") \(m.titel ?? "")").font(.caption2).lineLimit(2) }
                } else {
                    ForEach(list.prefix(family == .systemSmall ? 2 : (family == .systemLarge ? 8 : 3)), id: \.self) { EventRow(e: $0) }
                }
                if family == .systemLarge, let s {
                    Divider()
                    Text("Fristen").font(.subheadline.bold()).foregroundStyle(Palette.warn)
                    ForEach(s.deadlines.prefix(3), id: \.self) { d in
                        HStack { Text(d.titel ?? "").font(.caption).lineLimit(1); Spacer(); Text(Fmt.relDay(d.datum, today: s.today)).font(.caption2).foregroundStyle(.secondary) }
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
        }
    }
}

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "heute", provider: Provider()) { entry in
            TodayView(entry: entry).widgetBackground().widgetURL(Shared.link("kalender"))
        }
        .configurationDisplayName("Heute")
        .description("Termine und Stundenplan von heute.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryInline, .accessoryCircular])
    }
}

// MARK: Fristen & Lernaufgaben
struct DeadlinesView: View {
    @Environment(\.widgetFamily) var family
    let entry: Entry
    var body: some View {
        let s = entry.summary
        if family == .accessoryRectangular {
            if let d = s?.deadlines.first {
                VStack(alignment: .leading) {
                    Text("Frist \(Fmt.relDay(d.datum, today: s?.today ?? ""))").font(.caption.bold())
                    Text(d.titel ?? "").font(.caption).lineLimit(2)
                }
            } else { Text("Keine Fristen").font(.caption) }
        } else {
            VStack(alignment: .leading, spacing: 5) {
                Text("Fristen").font(.headline).foregroundStyle(Palette.warn)
                if let s {
                    if s.deadlines.isEmpty { Text("Keine anstehenden Fristen").font(.caption).foregroundStyle(.secondary) }
                    ForEach(s.deadlines.prefix(family == .systemSmall ? 3 : 4), id: \.self) { d in
                        HStack {
                            Text(d.titel ?? "").font(.caption).lineLimit(1)
                            Spacer()
                            Text(Fmt.relDay(d.datum, today: s.today)).font(.caption2.bold()).foregroundStyle(.secondary)
                        }
                    }
                    if family != .systemSmall {
                        Text("Lernaufgaben").font(.subheadline.bold()).foregroundStyle(Palette.accent).padding(.top, 2)
                        if s.tasks.isEmpty { Text("Alles erledigt").font(.caption).foregroundStyle(.secondary) }
                        ForEach(s.tasks.prefix(family == .systemLarge ? 8 : 2), id: \.self) { t in
                            HStack {
                                if let id = t.id {
                                    Button(intent: TaskDoneIntent(id: id)) { Image(systemName: "circle").font(.caption2) }.buttonStyle(.plain)
                                } else { Image(systemName: "circle").font(.caption2) }
                                Text(t.titel ?? "").font(.caption).lineLimit(1)
                                Spacer()
                                if let f = t.faellig { Text(Fmt.relDay(f, today: s.today)).font(.caption2).foregroundStyle(.secondary) }
                            }
                        }
                    }
                } else { Text(entry.error ?? "App einmal öffnen").font(.caption).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
        }
    }
}

struct DeadlinesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "fristen", provider: Provider()) { entry in
            DeadlinesView(entry: entry).widgetBackground().widgetURL(Shared.link("lernen"))
        }
        .configurationDisplayName("Fristen & Lernaufgaben")
        .description("Was als Nächstes fällig ist.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular])
    }
}

// MARK: Mail
struct MailView: View {
    @Environment(\.widgetFamily) var family
    let entry: Entry
    var body: some View {
        let u = entry.summary?.unread
        if family == .accessoryCircular {
            VStack(spacing: 0) { Image(systemName: "envelope"); Text("\(u?.uni ?? 0)").font(.headline) }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Label("Mail", systemImage: "envelope.fill").font(.headline).foregroundStyle(Palette.accent)
                HStack { Text("Uni").font(.caption); Spacer(); Text("\(u?.uni ?? 0)").font(.title3.bold()) }
                HStack { Text("Gmail").font(.caption); Spacer(); Text("\(u?.gmail ?? 0)").font(.title3.bold()) }
                if (u?.important ?? 0) > 0 {
                    Text("\(u!.important) wichtig").font(.caption2.bold()).foregroundStyle(Palette.warn)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
        }
    }
}

struct MailWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "mail", provider: Provider()) { entry in
            MailView(entry: entry).widgetBackground().widgetURL(Shared.link("unimail"))
        }
        .configurationDisplayName("Mail")
        .description("Ungelesene Uni- und Gmail-Nachrichten.")
        .supportedFamilies([.systemSmall, .accessoryCircular])
    }
}

@main
struct GedankenpalastWidgets: WidgetBundle {
    var body: some Widget {
        TodayWidget()
        DeadlinesWidget()
        MailWidget()
        LectureLiveActivity()
        AppleMusicWidget()
        if #available(iOS 18.0, *) { RoutineControl(); ClipControl() }
    }
}

/// Kontrollzentrum / Sperrbildschirm / Aktionstaste: Routine starten
@available(iOS 18.0, *)
struct RoutineControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "routine") {
            ControlWidgetButton(action: StartRoutineIntent()) { Label("Routine starten", systemImage: "play.circle") }
        }
        .displayName("Routine starten")
        .description("Startet die Abendroutine des Gedankenpalasts.")
    }
}

/// Kontrollzentrum: Zwischenablage mit dem Laptop abgleichen (öffnet kurz die App – nur im Vordergrund erlaubt iOS das)
@available(iOS 18.0, *)
struct ClipControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "zwischenablage") {
            ControlWidgetButton(action: OpenURLIntent(URL(string: "gedankenpalast://zwischenablage?abgleich")!)) {
                Label("Zwischenablage abgleichen", systemImage: "doc.on.clipboard")
            }
        }
        .displayName("Zwischenablage abgleichen")
        .description("iPhone-Zwischenablage zum Laptop und den neuesten Laptop-Eintrag aufs iPhone.")
    }
}

/// Apple Music: „Jetzt läuft“ können Widgets ohne die Apple-Music-App nicht anzeigen – daher ein Sprung ins Original.
struct AppleMusicWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "applemusic", provider: Provider()) { _ in
            VStack(spacing: 8) {
                Image(systemName: "music.note").font(.system(size: 34)).foregroundStyle(.white)
                Text("Apple Music").font(.caption.bold()).foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .widgetBackground()
            .widgetURL(URL(string: "music://"))
        }
        .configurationDisplayName("Apple Music")
        .description("Öffnet Apple Music.")
        .supportedFamilies([.systemSmall, .accessoryCircular])
    }
}
