import Foundation

/// Termine und Stundenplan-Sitzungen in einem Zeitraum – gleiche Regeln wie im Portal (web/js/util.js occurrences).
struct Occ: Identifiable, Hashable {
    enum Kind: String { case event, series }
    var kind: Kind
    var docId: String
    var date: String
    var title: String
    var time: String?
    var endTime: String?
    var room: String?
    var roomChanged = false
    var cancelled = false
    var typ: String?
    var category: String
    var multi = false
    var unconfirmed = false
    var id: String { "\(kind.rawValue)|\(docId)|\(date)" }
}

enum Planning {
    static let iso: DateFormatter = { let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f }()
    static var cal: Calendar = { var c = Calendar(identifier: .iso8601); c.firstWeekday = 2; return c }()
    static func day(_ s: String) -> Date? { iso.date(from: String(s.prefix(10))) }
    static func str(_ d: Date) -> String { iso.string(from: d) }
    static var today: String { str(Date()) }
    static func add(_ d: Date, _ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: d)! }
    static func isoWeekday(_ d: Date) -> Int { (cal.component(.weekday, from: d) + 5) % 7 + 1 }   // 1 = Montag
    static func isoWeek(_ d: Date) -> Int { cal.component(.weekOfYear, from: d) }
    static func startOfWeek(_ d: Date) -> Date { add(cal.startOfDay(for: d), 1 - isoWeekday(d)) }

    @MainActor static func occurrences(_ store: DataStore, from: String, to: String, layers: [String: Bool]? = nil) -> [Occ] {
        var out: [Occ] = []
        let on = { (c: String) in layers?[c] ?? true }
        for e in store.all("events") {
            guard let date = e["date"] as? String, let start = day(date) else { continue }
            let cat = e["category"] as? String ?? "uni"
            guard on(cat) else { continue }
            let endS = (e["endDate"] as? String) ?? date
            if endS < from || date > to { continue }
            var d = date < from ? day(from)! : start
            let last = endS > to ? to : endS
            while str(d) <= last {
                out.append(Occ(kind: .event, docId: e["id"] as? String ?? "", date: str(d), title: e["title"] as? String ?? "",
                               time: (e["allDay"] as? Bool ?? false) ? nil : e["time"] as? String, endTime: e["endTime"] as? String,
                               room: e["room"] as? String, typ: e["typ"] as? String, category: cat, multi: endS != date,
                               unconfirmed: (e["createdBy"] as? String) == "routine" && !(e["confirmed"] as? Bool ?? false)))
                d = add(d, 1)
            }
        }
        if on("uni"), let f = day(from) {
            for s in store.all("series") {
                guard let wd = s["weekday"] as? Int else { continue }
                var d = add(f, (wd - isoWeekday(f) + 7) % 7)
                while str(d) <= to {
                    let ds = str(d)
                    defer { d = add(d, 7) }
                    if let a = s["from"] as? String, ds < a { continue }
                    if let b = s["until"] as? String, ds > b { continue }
                    let wk = isoWeek(d), rec = s["recurrence"] as? String
                    if (rec == "odd" && wk % 2 == 0) || (rec == "even" && wk % 2 == 1) { continue }
                    let ex = (s["exceptions"] as? [String: Any])?[ds] as? [String: Any] ?? [:]
                    out.append(Occ(kind: .series, docId: s["id"] as? String ?? "", date: ds, title: s["title"] as? String ?? "",
                                   time: s["start"] as? String, endTime: s["end"] as? String,
                                   room: (ex["room"] as? String) ?? (s["room"] as? String), roomChanged: ex["room"] != nil,
                                   cancelled: ex["cancelled"] as? Bool ?? false, typ: s["typ"] as? String, category: "uni",
                                   unconfirmed: (s["createdBy"] as? String) == "routine" && !(s["confirmed"] as? Bool ?? false)))
                }
            }
        }
        out.sort { ($0.date, $0.time == nil ? 0 : 1, $0.time ?? "") < ($1.date, $1.time == nil ? 0 : 1, $1.time ?? "") }
        var seen = Set<String>()
        return out.filter { o in
            let k = "\(o.date)|\(o.category)|\(o.time ?? "")|\(o.title.lowercased().filter { $0.isLetter || $0.isNumber })"
            return seen.insert(k).inserted
        }
    }

    static let weekdays = ["", "Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag", "Sonntag"]
    static func pretty(_ s: String) -> String {
        guard let d = day(s) else { return s }
        let f = DateFormatter(); f.locale = Locale(identifier: "de_DE"); f.dateFormat = "EEEE, d. MMMM"
        if s == today { return "Heute" }
        if s == str(add(Date(), 1)) { return "Morgen" }
        return f.string(from: d)
    }
}
