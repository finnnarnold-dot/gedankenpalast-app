import Foundation
import CoreSpotlight
import UniformTypeIdentifiers
import ActivityKit

/// Spotlight: Notizen, Termine (60 Tage) und Dateien der Ablage in der iPhone-Suche.
@MainActor
enum SpotlightIndex {
    private static var last = Date.distantPast

    static func update(_ store: DataStore) {
        guard Date().timeIntervalSince(last) > 60 else { return }   // höchstens einmal pro Minute
        last = Date()
        var items: [CSSearchableItem] = []
        for n in store.all("notes") where !(n["trashed"] as? Bool ?? false) {
            guard let id = n["id"] as? String else { continue }
            let a = CSSearchableItemAttributeSet(contentType: .text)
            let text = NoteText.plain(n["body"] as? String)
            a.title = (n["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? text.components(separatedBy: "\n").first ?? "Notiz"
            a.contentDescription = String(text.prefix(300))
            items.append(CSSearchableItem(uniqueIdentifier: "note:\(id)", domainIdentifier: "notizen", attributeSet: a))
        }
        let today = Planning.today, until = Planning.str(Planning.add(Date(), 60))
        for o in Planning.occurrences(store, from: today, to: until) where o.kind == .event {
            let a = CSSearchableItemAttributeSet(contentType: .calendarEvent)
            a.title = o.title
            a.contentDescription = [Planning.pretty(o.date), o.time, o.room].compactMap { $0 }.joined(separator: " · ")
            a.startDate = Planning.day(o.date)
            items.append(CSSearchableItem(uniqueIdentifier: "event:\(o.docId)", domainIdentifier: "kalender", attributeSet: a))
        }
        for f in store.all("files") {
            guard let id = f["id"] as? String, let name = f["name"] as? String else { continue }
            let a = CSSearchableItemAttributeSet(contentType: UTType(filenameExtension: (name as NSString).pathExtension) ?? .data)
            a.title = name
            a.contentDescription = "Ablage · \(f["folder"] as? String ?? "")"
            items.append(CSSearchableItem(uniqueIdentifier: "file:\(id)", domainIdentifier: "ablage", attributeSet: a))
        }
        let index = CSSearchableIndex.default()
        index.deleteAllSearchableItems { _ in index.indexSearchableItems(items) { _ in } }
    }

    /// Antippen in Spotlight → passender Bereich
    static func route(for identifier: String) -> String {
        if identifier.hasPrefix("note:") { return "notizen" }
        if identifier.hasPrefix("event:") { return "kalender" }
        return "ablage"
    }
}

/// Live-Aktivität für die nächste Veranstaltung: startet 60 Minuten vorher, endet mit der Veranstaltung.
@MainActor
enum LiveLecture {
    static func update(_ store: DataStore) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let now = Date()
        let tf = DateFormatter(); tf.dateFormat = "yyyy-MM-dd HH:mm"; tf.locale = Locale(identifier: "en_US_POSIX")
        let occ = Planning.occurrences(store, from: Planning.today, to: Planning.today)
            .filter { $0.time != nil && !$0.cancelled && ($0.kind == .series || $0.category == "uni") }
        let next = occ.compactMap { o -> (Occ, Date, Date)? in
            guard let s = tf.date(from: "\(o.date) \(o.time!)") else { return nil }
            let e = o.endTime.flatMap { tf.date(from: "\(o.date) \($0)") } ?? s.addingTimeInterval(90 * 60)
            return (o, s, e)
        }.first { $0.2 > now && $0.1.timeIntervalSince(now) < 3600 }

        for a in Activity<LectureAttributes>.activities where a.attributes.key != next?.0.id || a.content.state.end < now {
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
        guard let (o, s, e) = next else { return }
        let state = LectureAttributes.ContentState(start: s, end: e, room: o.room, roomChanged: o.roomChanged)
        if let a = Activity<LectureAttributes>.activities.first(where: { $0.attributes.key == o.id }) {
            Task { await a.update(ActivityContent(state: state, staleDate: e)) }
        } else {
            _ = try? Activity.request(attributes: LectureAttributes(title: o.title, key: o.id), content: ActivityContent(state: state, staleDate: e))
        }
    }
}
