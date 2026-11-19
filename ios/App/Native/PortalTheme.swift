import SwiftUI

// Aussehen wie auf der Website: dein Hintergrundbild (Portal → Einstellungen → Darstellung) mit Unschärfe und
// Abdunklung, darüber halbdurchsichtige, abgerundete Karten in den warmen Farben des Portals. Bedienung bleibt iOS.

@MainActor
final class PortalTheme: ObservableObject {
    static let shared = PortalTheme()
    @Published private(set) var image: UIImage?
    @Published private(set) var blur: CGFloat = 0
    @Published private(set) var alpha: Double = 0.62
    private var source: String?

    private var cacheFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("hintergrund.img")
    }

    init() {
        if let d = try? Data(contentsOf: cacheFile) { image = UIImage(data: d) }
        source = UserDefaults.standard.string(forKey: "themeSource")
    }

    func update(_ store: DataStore) {
        let s = store.setting("app")
        blur = CGFloat((s["blur"] as? Double) ?? Double(s["blur"] as? Int ?? 0))
        alpha = (s["moduleOpacity"] as? Double) ?? 0.62
        let bg = s["background"] as? String
        guard bg != source else { return }
        source = bg
        UserDefaults.standard.set(bg, forKey: "themeSource")
        guard let bg, !bg.isEmpty else { image = nil; try? FileManager.default.removeItem(at: cacheFile); return }
        Task {
            guard let base = PortalClient.shared.base, let url = URL(string: bg, relativeTo: base)?.absoluteURL,
                  var req = try? PortalClient.shared.request("api/status") else { return }
            req.url = url
            if bg.hasPrefix("data:"), let comma = bg.firstIndex(of: ","), let d = Data(base64Encoded: String(bg[bg.index(after: comma)...])) {
                image = UIImage(data: d); try? d.write(to: cacheFile); return
            }
            guard let (d, r) = try? await URLSession.shared.data(for: req), (r as? HTTPURLResponse)?.statusCode == 200, let img = UIImage(data: d) else { return }
            image = img
            try? d.write(to: cacheFile)
        }
    }
}

/// Hintergrund hinter allen Bereichen
struct PortalBackdrop: View {
    @ObservedObject private var theme = PortalTheme.shared
    var body: some View {
        ZStack {
            Theme.bg
            if let img = theme.image {
                GeometryReader { g in
                    Image(uiImage: img).resizable().scaledToFill().frame(width: g.size.width, height: g.size.height).clipped()
                        .blur(radius: theme.blur / 2)
                        .scaleEffect(theme.blur > 0 ? 1.04 : 1)
                }
                LinearGradient(colors: [.black.opacity(0.35), .black.opacity(0.15), .black.opacity(0.45)], startPoint: .top, endPoint: .bottom)
            }
        }
        .ignoresSafeArea()
    }
}

/// Karte wie im Portal (Glas mit warmem Ton)
struct PortalCard: View {
    @ObservedObject private var theme = PortalTheme.shared
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Color(red: 26 / 255, green: 23 / 255, blue: 20 / 255).opacity(theme.alpha)
        }
    }
}

/// Liste im Portal-Aussehen: Hintergrundbild, Karten als Glas – sonst wie eine normale iOS-Liste
struct PortalList<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        List { Group { content() }.listRowBackground(PortalCard()) }
            .scrollContentBackground(.hidden)
            .background(PortalBackdrop())
    }
}

extension View {
    /// Hintergrundbild hinter Bereichen ohne Liste (Kalender, Stundenplan, Raster)
    func portalBackground() -> some View { self.background(PortalBackdrop()) }
}


/// Farben der App (früher in NativeRoot.swift; genutzt von Apple Music, Pencil-Dialog, Assistent)
enum Theme {
    static let bg = Color(red: 0.07, green: 0.067, blue: 0.063)
    static let card = Color.white.opacity(0.06)
    static let accent = Color(red: 0.80, green: 0.84, blue: 0.64)
    static let warn = Color(red: 0.93, green: 0.62, blue: 0.45)
    static func category(_ c: String) -> Color {
        switch c {
        case "familie": return Color(red: 0.55, green: 0.72, blue: 0.95)
        case "arbeit": return Color(red: 0.86, green: 0.66, blue: 0.95)
        case "stundenplan": return accent
        default: return accent
        }
    }
}

/// HTML → Text (früher in NotesView.swift; genutzt von Spotlight und Assistent)
enum NoteText {
    /// HTML → reiner Text für Vorschau und Suche (ohne Ausführen)
    static func plain(_ html: String?) -> String {
        guard var s = html else { return "" }
        s = s.replacingOccurrences(of: "<(br|/p|/div|/li|/h[1-6])[^>]*>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (a, b) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")] { s = s.replacingOccurrences(of: a, with: b) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
