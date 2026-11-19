import Foundation
import ActivityKit

/// Live-Aktivität „Nächste Vorlesung“ (Sperrbildschirm und Dynamic Island) – von App und Widgets gemeinsam genutzt.
struct LectureAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var start: Date
        var end: Date
        var room: String?
        var roomChanged: Bool
    }
    var title: String
    var key: String
}
