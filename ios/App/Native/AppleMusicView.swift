import SwiftUI
import MusicKit
import MediaPlayer
import AVKit

// Apple Music in der App (MusicKit), so nah wie möglich an der Apple-Music-App (Finn, 05.11.):
// Reiter Start (Empfehlungen, zuletzt gespielt), Neu (Charts), Radio (Live-Sender, Genre-Sender), Mediathek
// (Playlists, Künstler, Alben, Titel, zuletzt hinzugefügt, neue Playlist), Suchen (Apple Music | Deine Mediathek,
// Vorschläge, Top-Treffer, zuletzt gesucht). Künstler-, Album- und Playlist-Seiten wie im Original, Kontextmenüs
// (Mediathek, Playlist, Als Nächstes, Zuletzt, Album, Künstler, Teilen), Wischen, Mini-Player, „Jetzt läuft“ in den
// Farben des Covers mit Warteschlange (sortieren, entfernen). Was MusicKit nicht kann (Songtexte, Downloads,
// Klangeinstellungen) öffnet die Apple-Music-App. Ohne Abo: Hinweis und Apples Abo-Angebot.

private let amPlayer = ApplicationMusicPlayer.shared
let amPink = Color(red: 0.98, green: 0.18, blue: 0.33)

// MARK: Wiedergabe
@MainActor
enum AMPlay {
    static func play<T: PlayableMusicItem>(_ items: [T], start: T? = nil, shuffle: Bool = false) {
        guard !items.isEmpty else { return }
        Task {
            amPlayer.queue = ApplicationMusicPlayer.Queue(for: items, startingAt: start)
            amPlayer.state.shuffleMode = shuffle ? .songs : .off
            try? await amPlayer.play()
            MusicBridge.shared.startTimer()
        }
    }
    static func playAll<T: PlayableMusicItem>(_ item: T, shuffle: Bool = false) {
        Task {
            amPlayer.queue = [item]
            amPlayer.state.shuffleMode = shuffle ? .songs : .off
            try? await amPlayer.play()
            MusicBridge.shared.startTimer()
        }
    }
    static func next<T: PlayableMusicItem>(_ item: T) { Task { try? await amPlayer.queue.insert(item, position: .afterCurrentEntry); AMRouter.shared.note("Wird als Nächstes gespielt") } }
    static func last<T: PlayableMusicItem>(_ item: T) { Task { try? await amPlayer.queue.insert(item, position: .tail); AMRouter.shared.note("Wird zuletzt gespielt") } }
}

// MARK: Navigation (je Reiter ein Pfad – damit Kontextmenüs und „Jetzt läuft“ zu Album/Künstler springen können)
enum AMDest: Hashable {
    case album(Album), artist(Artist), playlist(Playlist), songs, albums, artists, playlists
}

@MainActor
final class AMRouter: ObservableObject {
    static let shared = AMRouter()
    @Published var tab = 0
    @Published var paths: [NavigationPath] = Array(repeating: NavigationPath(), count: 5)
    @Published var message: String?
    @Published var addToPlaylist: Song?
    @Published var openNowPlaying = false   // vom schwebenden Mini-Player außerhalb von Apple Music

    func push(_ d: AMDest) { paths[tab].append(d) }
    func path(_ i: Int) -> Binding<NavigationPath> { Binding(get: { self.paths[i] }, set: { self.paths[i] = $0 }) }
    func note(_ m: String) {
        message = m
        Task { try? await Task.sleep(nanoseconds: 1_800_000_000); if message == m { message = nil } }
    }
    func album(of song: Song) { Task { if let a = try? await song.with([.albums]).albums?.first { push(.album(a)) } } }
    func artist(of song: Song) { Task { if let a = try? await song.with([.artists]).artists?.first { push(.artist(a)) } } }
    func addToLibrary<T: MusicLibraryAddable>(_ item: T) {
        Task {
            do { try await MusicLibrary.shared.add(item); note("Zur Mediathek hinzugefügt") } catch { note("Hinzufügen nicht möglich") }
        }
    }
}

private struct AMDestinations: ViewModifier {
    func body(content: Content) -> some View {
        content.navigationDestination(for: AMDest.self) { d in
            switch d {
            case .album(let a): AMAlbumDetail(album: a)
            case .artist(let a): AMArtistDetail(artist: a)
            case .playlist(let p): AMPlaylistDetail(playlist: p)
            case .songs: AMSongs()
            case .albums: AMAlbums()
            case .artists: AMArtists()
            case .playlists: AMPlaylists()
            }
        }
    }
}

// MARK: Start
struct AppleMusicHome: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var model: AppModel
    @ObservedObject private var router = AMRouter.shared
    @State private var auth = MusicAuthorization.currentStatus
    @State private var showNP = false

    var body: some View {
        Group {
            if auth != .authorized {
                VStack(spacing: 18) {
                    Image(systemName: "music.note").font(.system(size: 52)).foregroundStyle(amPink)
                    Text("Apple Music verbinden").font(.title2.bold())
                    Text("Deine Mediathek, Playlists und der ganze Katalog – direkt in der App.").multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button(auth == .notDetermined ? "Erlauben" : "In Einstellungen erlauben") {
                        Task {
                            if MusicAuthorization.currentStatus == .notDetermined { auth = await MusicAuthorization.request() } else { Permissions.openSettings() }
                        }
                    }.buttonStyle(.borderedProminent).tint(amPink)
                    Button("Schließen") { dismiss() }
                }.padding(32)
            } else {
                TabView(selection: $router.tab) {
                    tab(0, "Start", "house.fill") { AMListenNow() }
                    tab(1, "Neu", "square.grid.2x2.fill") { AMNew() }
                    tab(2, "Radio", "dot.radiowaves.left.and.right") { AMRadio() }
                    tab(3, "Mediathek", "square.stack.fill") { AMLibrary() }
                    tab(4, "Suchen", "magnifyingglass") { AMSearch() }
                }
                .tint(amPink)
                .safeAreaInset(edge: .bottom) { AMMiniPlayer(showNP: $showNP).padding(.bottom, 52) }
                .onAppear { if router.openNowPlaying { router.openNowPlaying = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { showNP = true } } }
                .sheet(isPresented: $showNP) { AMNowPlaying(go: { d in showNP = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { router.push(d) } }) }
                .sheet(item: $router.addToPlaylist) { s in AMAddToPlaylist(song: s) }
                .overlay(alignment: .top) {
                    if let m = router.message {
                        Text(m).font(.subheadline.weight(.semibold)).padding(.horizontal, 16).padding(.vertical, 10)
                            .background(.ultraThinMaterial, in: Capsule()).padding(.top, 8)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.35), value: router.message)
            }
        }
        .preferredColorScheme(.dark)
        .environment(\.amClose, { dismiss() })
    }

    private func tab<V: View>(_ i: Int, _ title: String, _ icon: String, @ViewBuilder _ v: () -> V) -> some View {
        NavigationStack(path: router.path(i)) { v().modifier(AMDestinations()) }
            .tabItem { Label(title, systemImage: icon) }.tag(i)
    }
}

private struct AMCloseKey: EnvironmentKey { static let defaultValue: () -> Void = {} }
extension EnvironmentValues { var amClose: () -> Void { get { self[AMCloseKey.self] } set { self[AMCloseKey.self] = newValue } } }

/// Oben links zurück zum Gedankenpalast, rechts das Menü (Apple-Music-App für Songtexte, Downloads, Einstellungen)
private struct AMToolbar: ViewModifier {
    @Environment(\.amClose) private var close
    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .topBarLeading) { Button { close() } label: { Label("Gedankenpalast", systemImage: "chevron.left") } }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { if let u = URL(string: "music://") { UIApplication.shared.open(u) } } label: { Label("Apple-Music-App öffnen", systemImage: "arrow.up.forward.app") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
    }
}
extension View { fileprivate func amToolbar() -> some View { modifier(AMToolbar()) } }

// MARK: Bausteine
/// Karte für Empfehlungen, Zuletzt gespielt, Charts und Sender
enum AMCard: Identifiable {
    case album(Album), playlist(Playlist), station(Station)
    var id: String {
        switch self { case .album(let a): return "a" + a.id.rawValue; case .playlist(let p): return "p" + p.id.rawValue; case .station(let s): return "s" + s.id.rawValue }
    }
    var title: String { switch self { case .album(let a): return a.title; case .playlist(let p): return p.name; case .station(let s): return s.name } }
    var subtitle: String? {
        switch self { case .album(let a): return a.artistName; case .playlist(let p): return p.curatorName; case .station(let s): return s.isLive ? "Live" : "Sender" }
    }
    var artwork: Artwork? { switch self { case .album(let a): return a.artwork; case .playlist(let p): return p.artwork; case .station(let s): return s.artwork } }
}

struct AMCardView: View {
    let card: AMCard
    var size: CGFloat = 160
    var body: some View {
        Button {
            switch card {
            case .album(let a): AMRouter.shared.push(.album(a))
            case .playlist(let p): AMRouter.shared.push(.playlist(p))
            case .station(let s): AMPlay.playAll(s)
            }
        } label: { AMTile(artwork: card.artwork, title: card.title, subtitle: card.subtitle, size: size) }
            .buttonStyle(.plain)
            .contextMenu {
                switch card {
                case .album(let a):
                    Button { AMPlay.playAll(a) } label: { Label("Abspielen", systemImage: "play") }
                    Button { AMPlay.next(a) } label: { Label("Als Nächstes spielen", systemImage: "text.line.first.and.arrowtriangle.forward") }
                    Button { AMRouter.shared.addToLibrary(a) } label: { Label("Zur Mediathek hinzufügen", systemImage: "plus") }
                    if let u = a.url { ShareLink(item: u) { Label("Teilen", systemImage: "square.and.arrow.up") } }
                case .playlist(let p):
                    Button { AMPlay.playAll(p) } label: { Label("Abspielen", systemImage: "play") }
                    Button { AMPlay.next(p) } label: { Label("Als Nächstes spielen", systemImage: "text.line.first.and.arrowtriangle.forward") }
                    Button { AMRouter.shared.addToLibrary(p) } label: { Label("Zur Mediathek hinzufügen", systemImage: "plus") }
                    if let u = p.url { ShareLink(item: u) { Label("Teilen", systemImage: "square.and.arrow.up") } }
                case .station(let s):
                    Button { AMPlay.playAll(s) } label: { Label("Sender abspielen", systemImage: "play") }
                    if let u = s.url { ShareLink(item: u) { Label("Teilen", systemImage: "square.and.arrow.up") } }
                }
            }
    }
}

/// Waagerechtes Regal mit Überschrift (wie die Reihen in Apple Music)
struct AMShelf: View {
    let title: String
    let cards: [AMCard]
    var size: CGFloat = 160
    var body: some View {
        if !cards.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.title2.bold()).padding(.horizontal)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) { ForEach(cards) { AMCardView(card: $0, size: size) } }.padding(.horizontal)
                }
            }
        }
    }
}

/// Titel-Regal: vier Zeilen je Spalte, seitlich blättern (wie „Top-Titel“)
struct AMSongShelf: View {
    let title: String
    let songs: [Song]
    var body: some View {
        if !songs.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.title2.bold()).padding(.horizontal)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHGrid(rows: Array(repeating: GridItem(.fixed(56), spacing: 6), count: 4), spacing: 18) {
                        ForEach(Array(songs.enumerated()), id: \.element.id) { i, s in
                            AMSongRow(song: s, number: i + 1).frame(width: 300).contentShape(Rectangle())
                                .onTapGesture { AMPlay.play(songs, start: s) }.amSongMenu(s)
                        }
                    }.padding(.horizontal)
                }
            }
        }
    }
}

struct AMTile: View {
    let artwork: Artwork?
    let title: String
    let subtitle: String?
    var size: CGFloat = 160
    var round = false
    var body: some View {
        VStack(alignment: round ? .center : .leading, spacing: 4) {
            AMCover(artwork: artwork, size: size, radius: round ? size / 2 : 8)
            Text(title).font(.subheadline).lineLimit(1)
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }.frame(width: size)
    }
}

struct AMCover: View {
    let artwork: Artwork?
    let size: CGFloat
    var radius: CGFloat = 8
    var body: some View {
        Group {
            if let artwork { ArtworkImage(artwork, width: size, height: size) }
            else {
                ZStack {
                    LinearGradient(colors: [amPink.opacity(0.6), .purple.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note").font(.system(size: size * 0.35)).foregroundStyle(.white.opacity(0.85))
                }.frame(width: size, height: size)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

struct AMSongRow: View {
    let song: Song
    var number: Int? = nil
    var body: some View {
        HStack(spacing: 12) {
            AMCover(artwork: song.artwork, size: 48, radius: 6)
            if let number { Text("\(number)").font(.subheadline.bold()).foregroundStyle(.secondary).frame(width: 22) }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(song.title).lineLimit(1)
                    if song.contentRating == .explicit { Image(systemName: "e.square.fill").font(.caption2).foregroundStyle(.secondary) }
                }
                Text(song.artistName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

struct AMPlayButtons: View {
    let play: () -> Void
    let shuffle: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Button(action: play) { Label("Abspielen", systemImage: "play.fill").fontWeight(.semibold).frame(maxWidth: .infinity) }
            Button(action: shuffle) { Label("Zufällig", systemImage: "shuffle").fontWeight(.semibold).frame(maxWidth: .infinity) }
        }
        .buttonStyle(.bordered).tint(amPink).controlSize(.large).listRowSeparator(.hidden)
    }
}

extension View {
    /// Wischen nach rechts: Als Nächstes, nach links: Zuletzt; Kontextmenü wie in Apple Music
    func amSongMenu(_ song: Song) -> some View {
        self
            .swipeActions(edge: .leading) { Button { AMPlay.next(song) } label: { Label("Als Nächstes", systemImage: "text.line.first.and.arrowtriangle.forward") }.tint(.purple) }
            .swipeActions(edge: .trailing) { Button { AMPlay.last(song) } label: { Label("Zuletzt", systemImage: "text.line.last.and.arrowtriangle.forward") }.tint(.orange) }
            .contextMenu { AMSongMenuItems(song: song) }
    }
    func amTrackMenu(_ track: Track) -> some View {
        Group {
            if case .song(let s) = track { self.amSongMenu(s) } else {
                self.swipeActions(edge: .leading) { Button { AMPlay.next(track) } label: { Label("Als Nächstes", systemImage: "text.line.first.and.arrowtriangle.forward") }.tint(.purple) }
            }
        }
    }
}

struct AMSongMenuItems: View {
    let song: Song
    var body: some View {
        Button { AMRouter.shared.addToLibrary(song) } label: { Label("Zur Mediathek hinzufügen", systemImage: "plus") }
        Button { AMRouter.shared.addToPlaylist = song } label: { Label("Zu einer Playlist hinzufügen …", systemImage: "text.badge.plus") }
        Divider()
        Button { AMPlay.next(song) } label: { Label("Als Nächstes spielen", systemImage: "text.line.first.and.arrowtriangle.forward") }
        Button { AMPlay.last(song) } label: { Label("Zuletzt spielen", systemImage: "text.line.last.and.arrowtriangle.forward") }
        Divider()
        Button { AMRouter.shared.album(of: song) } label: { Label("Zum Album", systemImage: "square.stack") }
        Button { AMRouter.shared.artist(of: song) } label: { Label("Zum Künstler", systemImage: "music.mic") }
        if let u = song.url {
            ShareLink(item: u) { Label("Titel teilen", systemImage: "square.and.arrow.up") }
            Button { UIApplication.shared.open(u) } label: { Label("Songtext in Apple Music", systemImage: "quote.bubble") }
        }
    }
}

// MARK: Start (Empfehlungen)
struct AMListenNow: View {
    @State private var shelves: [(String, [AMCard])] = []
    @State private var recent: [AMCard] = []
    @State private var loaded = false
    @State private var canPlay = true
    @State private var canOffer = false
    @State private var showOffer = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if !canPlay {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Kein Apple-Music-Abo aktiv").font(.headline)
                        Text("Ohne Abo spielen nur Titel, die du gekauft oder selbst in deine Mediathek geladen hast.").font(.subheadline).foregroundStyle(.secondary)
                        if canOffer { Button("Apple Music testen") { showOffer = true }.buttonStyle(.borderedProminent).tint(amPink) }
                    }.padding().frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16)).padding(.horizontal)
                }
                AMShelf(title: "Zuletzt gespielt", cards: recent)
                ForEach(Array(shelves.enumerated()), id: \.offset) { _, s in AMShelf(title: s.0, cards: s.1, size: s.0 == shelves.first?.0 ? 220 : 160) }
                if loaded && shelves.isEmpty && recent.isEmpty {
                    Text("Noch keine Empfehlungen – hör ein paar Titel, dann lernt Apple Music deinen Geschmack.").foregroundStyle(.secondary).padding()
                }
                if !loaded { ProgressView().frame(maxWidth: .infinity).padding(40) }
            }.padding(.vertical)
        }
        .navigationTitle("Start")
        .amToolbar()
        .musicSubscriptionOffer(isPresented: $showOffer)
        .refreshable { await load() }
        .task { if !loaded { await load() } }
    }

    private func load() async {
        if let sub = try? await MusicSubscription.current { canPlay = sub.canPlayCatalogContent; canOffer = sub.canBecomeSubscriber }
        if let r = try? await MusicRecentlyPlayedContainerRequest().response() {
            recent = r.items.compactMap { item -> AMCard? in
                switch item {
                case .album(let a): return .album(a)
                case .playlist(let p): return .playlist(p)
                case .station(let s): return .station(s)
                @unknown default: return nil
                }
            }
        }
        if let r = try? await MusicPersonalRecommendationsRequest().response() {
            shelves = r.recommendations.compactMap { rec in
                let cards = rec.items.compactMap { item -> AMCard? in
                    switch item {
                    case .album(let a): return .album(a)
                    case .playlist(let p): return .playlist(p)
                    case .station(let s): return .station(s)
                    @unknown default: return nil
                    }
                }
                return cards.isEmpty ? nil : (rec.title ?? "Für dich", cards)
            }
        }
        loaded = true
    }
}

// MARK: Neu (Charts)
struct AMNew: View {
    @State private var songCharts: [(String, [Song])] = []
    @State private var cardCharts: [(String, [AMCard])] = []
    @State private var loaded = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ForEach(Array(cardCharts.prefix(1).enumerated()), id: \.offset) { _, c in AMShelf(title: c.0, cards: c.1, size: 220) }
                ForEach(Array(songCharts.enumerated()), id: \.offset) { _, c in AMSongShelf(title: c.0, songs: c.1) }
                ForEach(Array(cardCharts.dropFirst().enumerated()), id: \.offset) { _, c in AMShelf(title: c.0, cards: c.1) }
                if !loaded { ProgressView().frame(maxWidth: .infinity).padding(40) }
            }.padding(.vertical)
        }
        .navigationTitle("Neu")
        .amToolbar()
        .refreshable { await load() }
        .task { if !loaded { await load() } }
    }
    private func load() async {
        let req = MusicCatalogChartsRequest(kinds: [.mostPlayed, .dailyGlobalTop], types: [Song.self, Album.self, Playlist.self])
        if let r = try? await req.response() {
            songCharts = r.songCharts.map { ($0.title, Array($0.items)) }.filter { !$0.1.isEmpty }
            cardCharts = r.albumCharts.map { ($0.title, $0.items.map { AMCard.album($0) }) }.filter { !$0.1.isEmpty }
                + r.playlistCharts.map { ($0.title, $0.items.map { AMCard.playlist($0) }) }.filter { !$0.1.isEmpty }
        }
        loaded = true
    }
}

// MARK: Radio
struct AMRadio: View {
    @State private var live: [AMCard] = []
    @State private var genres: [(String, [AMCard])] = []
    @State private var loaded = false
    private static let liveIDs: [MusicItemID] = ["ra.978194965", "ra.1498155548", "ra.1498157166"]   // Apple Music 1, Hits, Country
    private static let genreTerms = ["Pop", "Hip-Hop", "Deutschrap", "Rock", "Elektronisch", "Chill", "Klassik", "Jazz", "Fokus"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                AMShelf(title: "Live-Radio", cards: live, size: 260)
                ForEach(Array(genres.enumerated()), id: \.offset) { _, g in AMShelf(title: g.0, cards: g.1) }
                if !loaded { ProgressView().frame(maxWidth: .infinity).padding(40) }
            }.padding(.vertical)
        }
        .navigationTitle("Radio")
        .amToolbar()
        .task { if !loaded { await load() } }
    }
    private func load() async {
        if let r = try? await MusicCatalogResourceRequest<Station>(matching: \.id, memberOf: Self.liveIDs).response() {
            live = r.items.map { .station($0) }
        }
        var out: [(String, [AMCard])] = []
        for term in Self.genreTerms {
            var req = MusicCatalogSearchRequest(term: term, types: [Station.self])
            req.limit = 10
            if let r = try? await req.response(), !r.stations.isEmpty { out.append((term, r.stations.map { .station($0) })) }
        }
        genres = out
        loaded = true
    }
}

// MARK: Mediathek
struct AMLibrary: View {
    @State private var recent: [Album] = []
    @State private var newPlaylist = false
    @State private var name = ""
    var body: some View {
        List {
            Section {
                NavigationLink(value: AMDest.playlists) { Label("Playlists", systemImage: "music.note.list") }
                NavigationLink(value: AMDest.artists) { Label("Künstler", systemImage: "music.mic") }
                NavigationLink(value: AMDest.albums) { Label("Alben", systemImage: "square.stack") }
                NavigationLink(value: AMDest.songs) { Label("Titel", systemImage: "music.note") }
            }
            .font(.title3).foregroundStyle(amPink)
            if !recent.isEmpty {
                Section {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 16) {
                        ForEach(recent) { a in AMCardView(card: .album(a), size: 165) }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                } header: { Text("Zuletzt hinzugefügt").font(.title2.bold()).foregroundStyle(.primary).textCase(nil) }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Mediathek")
        .amToolbar()
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { newPlaylist = true } label: { Image(systemName: "plus") } } }
        .alert("Neue Playlist", isPresented: $newPlaylist) {
            TextField("Name", text: $name)
            Button("Abbrechen", role: .cancel) { name = "" }
            Button("Erstellen") {
                let n = name.trimmingCharacters(in: .whitespaces); name = ""
                guard !n.isEmpty else { return }
                Task {
                    if let p = try? await MusicLibrary.shared.createPlaylist(name: n) { AMRouter.shared.push(.playlist(p)) } else { AMRouter.shared.note("Playlist konnte nicht erstellt werden") }
                }
            }
        }
        .task {
            var r = MusicLibraryRequest<Album>()
            r.sort(by: \.libraryAddedDate, ascending: false)
            r.limit = 24
            if let items = try? await r.response().items { recent = Array(items) }
        }
    }
}

struct AMPlaylists: View {
    @State private var items: [Playlist] = []
    @State private var q = ""
    var body: some View {
        List(items.filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) }) { p in
            NavigationLink(value: AMDest.playlist(p)) { HStack(spacing: 12) { AMCover(artwork: p.artwork, size: 56); VStack(alignment: .leading) { Text(p.name); if let c = p.curatorName { Text(c).font(.caption).foregroundStyle(.secondary) } } } }
                .contextMenu { Button { AMPlay.playAll(p) } label: { Label("Abspielen", systemImage: "play") }; Button { AMPlay.playAll(p, shuffle: true) } label: { Label("Zufällig", systemImage: "shuffle") } }
        }
        .listStyle(.plain)
        .searchable(text: $q, prompt: "Playlists durchsuchen")
        .navigationTitle("Playlists")
        .task {
            var r = MusicLibraryRequest<Playlist>(); r.sort(by: \.lastPlayedDate, ascending: false); r.limit = 500
            if let i = try? await r.response().items { items = Array(i) }
        }
    }
}

struct AMAlbums: View {
    @State private var items: [Album] = []
    @State private var q = ""
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 18) {
                ForEach(items.filter { q.isEmpty || "\($0.title) \($0.artistName)".localizedCaseInsensitiveContains(q) }) { a in AMCardView(card: .album(a), size: 165) }
            }.padding()
        }
        .searchable(text: $q, prompt: "Alben durchsuchen")
        .navigationTitle("Alben")
        .task { var r = MusicLibraryRequest<Album>(); r.sort(by: \.title, ascending: true); r.limit = 2000; if let i = try? await r.response().items { items = Array(i) } }
    }
}

struct AMArtists: View {
    @State private var items: [Artist] = []
    @State private var q = ""
    var body: some View {
        List(items.filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) }) { a in
            NavigationLink(value: AMDest.artist(a)) { HStack(spacing: 12) { AMCover(artwork: a.artwork, size: 48, radius: 24); Text(a.name) } }
        }
        .listStyle(.plain)
        .searchable(text: $q, prompt: "Künstler durchsuchen")
        .navigationTitle("Künstler")
        .task { var r = MusicLibraryRequest<Artist>(); r.sort(by: \.name, ascending: true); r.limit = 2000; if let i = try? await r.response().items { items = Array(i) } }
    }
}

struct AMSongs: View {
    @State private var items: [Song] = []
    @State private var q = ""
    var shown: [Song] { items.filter { q.isEmpty || "\($0.title) \($0.artistName)".localizedCaseInsensitiveContains(q) } }
    var body: some View {
        List {
            AMPlayButtons(play: { AMPlay.play(shown) }, shuffle: { AMPlay.play(shown, shuffle: true) })
            ForEach(shown) { s in AMSongRow(song: s).contentShape(Rectangle()).onTapGesture { AMPlay.play(shown, start: s) }.amSongMenu(s) }
        }
        .listStyle(.plain)
        .searchable(text: $q, prompt: "Titel durchsuchen")
        .navigationTitle("Titel")
        .task { var r = MusicLibraryRequest<Song>(); r.sort(by: \.title, ascending: true); r.limit = 10000; if let i = try? await r.response().items { items = Array(i) } }
    }
}

// MARK: Künstler
struct AMArtistDetail: View {
    let artist: Artist
    @State private var full: Artist?
    @State private var libraryAlbums: [Album] = []
    @State private var loaded = false
    private static let props: [PartialMusicAsyncProperty<Artist>] = [.topSongs, .latestRelease, .fullAlbums, .singles, .liveAlbums, .appearsOnAlbums, .featuredPlaylists, .similarArtists, .station]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if let l = full?.latestRelease { latest(l) }
                AMSongShelf(title: "Top-Titel", songs: Array(full?.topSongs ?? []))
                AMShelf(title: "Alben", cards: (full?.fullAlbums.map { Array($0) } ?? libraryAlbums).map { .album($0) })
                AMShelf(title: "Singles & EPs", cards: (full?.singles.map { Array($0) } ?? []).map { .album($0) })
                AMShelf(title: "Live-Alben", cards: (full?.liveAlbums.map { Array($0) } ?? []).map { .album($0) })
                AMShelf(title: "Playlists", cards: (full?.featuredPlaylists.map { Array($0) } ?? []).map { .playlist($0) })
                AMShelf(title: "Enthalten in", cards: (full?.appearsOnAlbums.map { Array($0) } ?? []).map { .album($0) })
                similar
                if !loaded { ProgressView().frame(maxWidth: .infinity).padding(30) }
            }.padding(.bottom, 30)
        }
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { if let u = (full ?? artist).url { ToolbarItem(placement: .topBarTrailing) { ShareLink(item: u) { Image(systemName: "square.and.arrow.up") } } } }
        .task { if !loaded { await load() } }
    }

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            if let art = (full ?? artist).artwork {
                ArtworkImage(art, width: UIScreen.main.bounds.width, height: 360).frame(height: 360).clipped()
            } else { LinearGradient(colors: [amPink.opacity(0.5), .black], startPoint: .top, endPoint: .bottom).frame(height: 300) }
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
            HStack(alignment: .bottom) {
                Text(artist.name).font(.largeTitle.bold()).lineLimit(2)
                Spacer()
                Button {
                    if let st = full?.station { AMPlay.playAll(st) } else if let t = full?.topSongs, !t.isEmpty { AMPlay.play(Array(t)) }
                } label: { Image(systemName: "play.fill").font(.title2).foregroundStyle(.white).frame(width: 54, height: 54).background(amPink, in: Circle()) }
            }.padding()
        }
    }

    private func latest(_ a: Album) -> some View {
        Button { AMRouter.shared.push(.album(a)) } label: {
            HStack(spacing: 14) {
                AMCover(artwork: a.artwork, size: 110, radius: 8)
                VStack(alignment: .leading, spacing: 4) {
                    if let d = a.releaseDate { Text(d.formatted(date: .abbreviated, time: .omitted).uppercased()).font(.caption.bold()).foregroundStyle(.secondary) }
                    Text(a.title).font(.headline).lineLimit(2)
                    if let n = a.trackCount as Int? { Text("\(n) Titel").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
            }.padding(.horizontal)
        }.buttonStyle(.plain)
    }

    @ViewBuilder private var similar: some View {
        if let s = full?.similarArtists, !s.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Ähnliche Künstler").font(.title2.bold()).padding(.horizontal)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 14) {
                        ForEach(Array(s)) { a in
                            Button { AMRouter.shared.push(.artist(a)) } label: { AMTile(artwork: a.artwork, title: a.name, subtitle: nil, size: 130, round: true) }.buttonStyle(.plain)
                        }
                    }.padding(.horizontal)
                }
            }
        }
    }

    private func load() async {
        // Mediathek-Künstler haben keine Katalog-Seite → passenden Künstler im Katalog suchen
        if let a = try? await artist.with(Self.props), a.topSongs != nil { full = a }
        else {
            if let a = try? await artist.with([.albums]).albums { libraryAlbums = Array(a) }
            var req = MusicCatalogSearchRequest(term: artist.name, types: [Artist.self]); req.limit = 5
            if let hit = try? await req.response().artists.first(where: { $0.name.caseInsensitiveCompare(artist.name) == .orderedSame }) {
                full = try? await hit.with(Self.props)
            }
        }
        loaded = true
    }
}

// MARK: Album und Playlist
struct AMAlbumDetail: View {
    let album: Album
    @State private var full: Album?
    @State private var q = ""
    var body: some View {
        let a = full ?? album
        AMTrackList(artwork: a.artwork, title: a.title, subtitle: a.artistName, tracks: Array(a.tracks ?? []), q: q,
                    playAll: { AMPlay.playAll(a) }, shuffle: { AMPlay.playAll(a, shuffle: true) }, numbered: true,
                    subtitleTap: { if let ar = a.artists?.first { AMRouter.shared.push(.artist(ar)) } },
                    info: info(a), notes: a.editorialNotes?.standard,
                    add: { AMRouter.shared.addToLibrary(a) }, url: a.url, more: Array(full?.otherVersions ?? []).map { .album($0) })
            .searchable(text: $q, prompt: "Im Album suchen")
            .task { full = try? await album.with([.tracks, .artists, .otherVersions]) }
    }
    private func info(_ a: Album) -> String {
        var parts: [String] = []
        if let d = a.releaseDate { parts.append(d.formatted(date: .long, time: .omitted)) }
        let n = a.tracks?.count ?? a.trackCount
        parts.append("\(n) Titel")
        let mins = Int((a.tracks ?? []).reduce(0) { $0 + ($1.duration ?? 0) } / 60)
        if mins > 0 { parts.append("\(mins) Minuten") }
        return parts.joined(separator: " · ") + (a.copyright.map { "\n" + $0 } ?? "")
    }
}

struct AMPlaylistDetail: View {
    let playlist: Playlist
    @State private var full: Playlist?
    @State private var q = ""
    var body: some View {
        let p = full ?? playlist
        AMTrackList(artwork: p.artwork, title: p.name, subtitle: p.curatorName, tracks: Array(p.tracks ?? []), q: q,
                    playAll: { AMPlay.playAll(p) }, shuffle: { AMPlay.playAll(p, shuffle: true) }, numbered: false,
                    subtitleTap: nil, info: p.lastModifiedDate.map { "Aktualisiert: " + $0.formatted(date: .abbreviated, time: .omitted) },
                    notes: p.standardDescription, add: { AMRouter.shared.addToLibrary(p) }, url: p.url, more: [])
            .searchable(text: $q, prompt: "In Playlist suchen")
            .task { full = try? await playlist.with([.tracks]) }
    }
}

struct AMTrackList: View {
    let artwork: Artwork?
    let title: String
    let subtitle: String?
    let tracks: [Track]
    let q: String
    let playAll: () -> Void
    let shuffle: () -> Void
    let numbered: Bool
    let subtitleTap: (() -> Void)?
    let info: String?
    let notes: String?
    let add: () -> Void
    let url: URL?
    let more: [AMCard]
    @State private var notesOpen = false

    private var shown: [Track] { tracks.filter { q.isEmpty || "\($0.title) \($0.artistName)".localizedCaseInsensitiveContains(q) } }

    var body: some View {
        List {
            if q.isEmpty { header }
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, t in row(i, t) }
            if !q.isEmpty && shown.isEmpty { Text("Keine Treffer").foregroundStyle(.secondary) }
            if q.isEmpty, let info { Text(info).font(.footnote).foregroundStyle(.secondary).listRowSeparator(.hidden).padding(.top, 8) }
            if q.isEmpty && !more.isEmpty { AMShelf(title: "Weitere Versionen", cards: more).listRowInsets(EdgeInsets()).listRowSeparator(.hidden) }
        }
        .listStyle(.plain)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(action: add) { Image(systemName: "plus") }
                if let url { ShareLink(item: url) { Image(systemName: "square.and.arrow.up") } }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            AMCover(artwork: artwork, size: 250, radius: 12).shadow(color: .black.opacity(0.5), radius: 18, y: 8)
            Text(title).font(.title2.bold()).multilineTextAlignment(.center)
            if let subtitle {
                Button { subtitleTap?() } label: { Text(subtitle).font(.title3).foregroundStyle(amPink) }.buttonStyle(.plain).disabled(subtitleTap == nil)
            }
            if let notes, !notes.isEmpty {
                Text(notes.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(notesOpen ? nil : 3).multilineTextAlignment(.center)
                    .onTapGesture { withAnimation { notesOpen.toggle() } }
            }
            AMPlayButtons(play: playAll, shuffle: shuffle)
        }
        .frame(maxWidth: .infinity).listRowSeparator(.hidden).padding(.vertical, 8)
    }

    private func row(_ i: Int, _ t: Track) -> some View {
        let list = shown
        return HStack(spacing: 12) {
            if numbered { Text("\(i + 1)").foregroundStyle(.secondary).frame(width: 24) } else { AMCover(artwork: t.artwork, size: 44, radius: 6) }
            VStack(alignment: .leading) {
                Text(t.title).lineLimit(1)
                if !numbered || t.artistName != subtitle { Text(t.artistName).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            if case .song(let s) = t {
                Menu { AMSongMenuItems(song: s) } label: { Image(systemName: "ellipsis").foregroundStyle(.secondary).frame(width: 30, height: 30) }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { AMPlay.play(list, start: t) }
        .amTrackMenu(t)
    }
}

// MARK: Zu Playlist hinzufügen
struct AMAddToPlaylist: View {
    let song: Song
    @Environment(\.dismiss) private var dismiss
    @State private var items: [Playlist] = []
    @State private var name = ""
    @State private var newOne = false
    var body: some View {
        NavigationStack {
            List {
                Button { newOne = true } label: { Label("Neue Playlist …", systemImage: "plus").foregroundStyle(amPink) }
                ForEach(items) { p in
                    Button { add(to: p) } label: { HStack(spacing: 12) { AMCover(artwork: p.artwork, size: 44, radius: 6); Text(p.name).foregroundStyle(.primary) } }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Zu Playlist hinzufügen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
            .alert("Neue Playlist", isPresented: $newOne) {
                TextField("Name", text: $name)
                Button("Abbrechen", role: .cancel) {}
                Button("Erstellen") {
                    let n = name.trimmingCharacters(in: .whitespaces)
                    Task {
                        if !n.isEmpty, (try? await MusicLibrary.shared.createPlaylist(name: n, items: [song])) != nil { AMRouter.shared.note("Zu „\(n)“ hinzugefügt") }
                        else { AMRouter.shared.note("Playlist konnte nicht erstellt werden") }
                        dismiss()
                    }
                }
            }
            .task { var r = MusicLibraryRequest<Playlist>(); r.sort(by: \.lastPlayedDate, ascending: false); r.limit = 500; if let i = try? await r.response().items { items = Array(i) } }
        }
        .presentationDetents([.medium, .large])
    }
    private func add(to p: Playlist) {
        Task {
            do { _ = try await MusicLibrary.shared.add(song, to: p); AMRouter.shared.note("Zu „\(p.name)“ hinzugefügt") }
            catch { AMRouter.shared.note("Diese Playlist lässt sich nicht bearbeiten") }
            dismiss()
        }
    }
}

// MARK: Suchen
struct AMSearch: View {
    @State private var q = ""
    @State private var scope = 0   // 0 = Apple Music, 1 = Deine Mediathek
    @State private var top: [AMTop] = []
    @State private var songs: [Song] = []
    @State private var albums: [Album] = []
    @State private var playlists: [Playlist] = []
    @State private var artists: [Artist] = []
    @State private var stations: [Station] = []
    @State private var suggestions: [String] = []
    @AppStorage("amRecentSearches") private var recentRaw = ""
    private var recent: [String] { recentRaw.split(separator: "\n").map(String.init) }

    enum AMTop: Identifiable {
        case song(Song), album(Album), artist(Artist), playlist(Playlist), station(Station)
        var id: String {
            switch self {
            case .song(let x): return "s" + x.id.rawValue
            case .album(let x): return "a" + x.id.rawValue
            case .artist(let x): return "r" + x.id.rawValue
            case .playlist(let x): return "p" + x.id.rawValue
            case .station(let x): return "t" + x.id.rawValue
            }
        }
    }

    var body: some View {
        List {
            if q.trimmingCharacters(in: .whitespaces).isEmpty {
                if !recent.isEmpty {
                    Section {
                        ForEach(recent, id: \.self) { r in Button { q = r } label: { Label(r, systemImage: "clock.arrow.circlepath").foregroundStyle(.primary) } }
                        Button("Verlauf löschen", role: .destructive) { recentRaw = "" }
                    } header: { Text("Zuletzt gesucht") }
                }
            } else {
                if scope == 0 && !suggestions.isEmpty && songs.isEmpty && albums.isEmpty {
                    ForEach(suggestions, id: \.self) { s in Button { q = s } label: { Label(s, systemImage: "magnifyingglass").foregroundStyle(.primary) } }
                }
                if !top.isEmpty { Section("Top-Treffer") { ForEach(top) { topRow($0) } } }
                if !artists.isEmpty { Section("Künstler") { ForEach(artists) { a in NavigationLink(value: AMDest.artist(a)) { HStack { AMCover(artwork: a.artwork, size: 48, radius: 24); Text(a.name) } } } } }
                if !songs.isEmpty {
                    Section("Titel") { ForEach(songs) { s in AMSongRow(song: s).contentShape(Rectangle()).onTapGesture { remember(); AMPlay.play(songs, start: s) }.amSongMenu(s) } }
                }
                if !albums.isEmpty { Section("Alben") { ForEach(albums) { a in NavigationLink(value: AMDest.album(a)) { AMRow(title: a.title, subtitle: a.artistName, artwork: a.artwork) } } } }
                if !playlists.isEmpty { Section("Playlists") { ForEach(playlists) { p in NavigationLink(value: AMDest.playlist(p)) { AMRow(title: p.name, subtitle: p.curatorName ?? "", artwork: p.artwork) } } } }
                if !stations.isEmpty { Section("Sender") { ForEach(stations) { s in Button { AMPlay.playAll(s) } label: { AMRow(title: s.name, subtitle: "Sender", artwork: s.artwork) }.buttonStyle(.plain) } } }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Suchen")
        .amToolbar()
        .searchable(text: $q, placement: .navigationBarDrawer(displayMode: .always), prompt: scope == 0 ? "Künstler, Titel, Texte …" : "Deine Mediathek")
        .searchScopes($scope) { Text("Apple Music").tag(0); Text("Deine Mediathek").tag(1) }
        .onSubmit(of: .search) { remember() }
        .task(id: "\(scope)|\(q)") { await search() }
    }

    @ViewBuilder private func topRow(_ t: AMTop) -> some View {
        switch t {
        case .song(let s): AMSongRow(song: s).contentShape(Rectangle()).onTapGesture { remember(); AMPlay.play([s]) }.amSongMenu(s)
        case .album(let a): NavigationLink(value: AMDest.album(a)) { AMRow(title: a.title, subtitle: "Album · " + a.artistName, artwork: a.artwork) }
        case .artist(let a): NavigationLink(value: AMDest.artist(a)) { HStack { AMCover(artwork: a.artwork, size: 48, radius: 24); VStack(alignment: .leading) { Text(a.name); Text("Künstler").font(.caption).foregroundStyle(.secondary) } } }
        case .playlist(let p): NavigationLink(value: AMDest.playlist(p)) { AMRow(title: p.name, subtitle: "Playlist · " + (p.curatorName ?? ""), artwork: p.artwork) }
        case .station(let s): Button { AMPlay.playAll(s) } label: { AMRow(title: s.name, subtitle: "Sender", artwork: s.artwork) }.buttonStyle(.plain)
        }
    }

    private func remember() {
        let t = q.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        recentRaw = ([t] + recent.filter { $0 != t }).prefix(12).joined(separator: "\n")
    }

    private func clear() { top = []; songs = []; albums = []; playlists = []; artists = []; stations = []; suggestions = [] }

    private func search() async {
        let term = q.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { clear(); return }
        try? await Task.sleep(nanoseconds: 300_000_000)
        if Task.isCancelled { return }
        if scope == 1 {
            var r = MusicLibrarySearchRequest(term: term, types: [Song.self, Album.self, Artist.self, Playlist.self])
            r.limit = 25
            guard let res = try? await r.response() else { return }
            clear()
            songs = Array(res.songs); albums = Array(res.albums); artists = Array(res.artists); playlists = Array(res.playlists)
            return
        }
        if let s = try? await MusicCatalogSearchSuggestionsRequest(term: term).response() { suggestions = s.suggestions.prefix(5).map(\.searchTerm) }
        var r = MusicCatalogSearchRequest(term: term, types: [Song.self, Album.self, Playlist.self, Artist.self, Station.self])
        r.limit = 15
        r.includeTopResults = true
        guard let res = try? await r.response(), !Task.isCancelled else { return }
        top = res.topResults.prefix(4).compactMap { t -> AMTop? in
            switch t {
            case .song(let x): return .song(x)
            case .album(let x): return .album(x)
            case .artist(let x): return .artist(x)
            case .playlist(let x): return .playlist(x)
            case .station(let x): return .station(x)
            default: return nil
            }
        }
        songs = Array(res.songs); albums = Array(res.albums); playlists = Array(res.playlists); artists = Array(res.artists); stations = Array(res.stations)
    }
}

struct AMRow: View {
    let title: String
    let subtitle: String
    let artwork: Artwork?
    var body: some View {
        HStack(spacing: 12) {
            AMCover(artwork: artwork, size: 48, radius: 6)
            VStack(alignment: .leading) { Text(title).lineLimit(1); Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            Spacer()
        }
    }
}

// MARK: Mini-Player (Wischen: links nächster, rechts voriger Titel, hoch „Jetzt läuft“)
struct AMMiniPlayer: View {
    @Binding var showNP: Bool
    @ObservedObject private var state = amPlayer.state
    @ObservedObject private var queue = amPlayer.queue
    var body: some View {
        if let e = queue.currentEntry {
            HStack(spacing: 12) {
                AMCover(artwork: e.artwork, size: 44, radius: 6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(e.title).font(.subheadline.weight(.medium)).lineLimit(1)
                    if let s = e.subtitle { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer()
                Button { toggle() } label: { Image(systemName: state.playbackStatus == .playing ? "pause.fill" : "play.fill").font(.title3).frame(width: 36, height: 36) }
                Button { Task { try? await amPlayer.skipToNextEntry() } } label: { Image(systemName: "forward.fill").font(.title3).frame(width: 36, height: 36) }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
            .onTapGesture { showNP = true }
            .gesture(DragGesture(minimumDistance: 24).onEnded { g in
                if g.translation.height < -40 { showNP = true }
                else if g.translation.width < -60 { Task { try? await amPlayer.skipToNextEntry() } }
                else if g.translation.width > 60 { Task { try? await amPlayer.skipToPreviousEntry() } }
            })
        }
    }
    private func toggle() { if state.playbackStatus == .playing { amPlayer.pause() } else { Task { try? await amPlayer.play() } } }
}

// MARK: Jetzt läuft
struct AMNowPlaying: View {
    let go: (AMDest) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var state = amPlayer.state
    @ObservedObject private var queue = amPlayer.queue
    @State private var showQueue = false
    @State private var scrub: Double?

    private var song: Song? { if case .song(let s)? = queue.currentEntry?.item { return s }; return nil }
    private var duration: Double {
        switch queue.currentEntry?.item {
        case .song(let s)?: return s.duration ?? 0
        case .musicVideo(let v)?: return v.duration ?? 0
        default: return 0
        }
    }
    private var playing: Bool { state.playbackStatus == .playing }
    private var tint: Color { queue.currentEntry?.artwork?.backgroundColor.map { Color(cgColor: $0) } ?? amPink.opacity(0.5) }

    var body: some View {
        VStack(spacing: 20) {
            Capsule().fill(.secondary).frame(width: 40, height: 5).padding(.top, 8)
            if showQueue { queueList } else { cover }
            titleBlock
            timeline
            controls
            HStack { Image(systemName: "speaker.fill").foregroundStyle(.secondary); AMVolume().frame(height: 30); Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary) }
            HStack {
                Button { if let u = song?.url { UIApplication.shared.open(u) } } label: { Image(systemName: "quote.bubble").font(.title3) }
                    .accessibilityLabel("Songtext in Apple Music")
                Spacer()
                AMRoute().frame(width: 36, height: 36)
                Spacer()
                Button { withAnimation(.spring(response: 0.35)) { showQueue.toggle() } } label: { Image(systemName: "list.bullet").font(.title3) }
                    .foregroundStyle(showQueue ? amPink : .primary)
            }.padding(.horizontal, 20)
        }
        .padding(.horizontal, 26).padding(.bottom, 16)
        .background(LinearGradient(colors: [tint, tint.opacity(0.55), Theme.bg], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
        .animation(.easeInOut(duration: 0.6), value: queue.currentEntry?.id)
        .preferredColorScheme(.dark)
    }

    private var cover: some View {
        VStack {
            Spacer(minLength: 0)
            AMCover(artwork: queue.currentEntry?.artwork, size: 330, radius: 14)
                .scaleEffect(playing ? 1 : 0.84).shadow(color: .black.opacity(0.45), radius: 24, y: 12)
                .animation(.spring(response: 0.4, dampingFraction: 0.7), value: playing)
                .gesture(DragGesture(minimumDistance: 30).onEnded { g in
                    if g.translation.width < -60 { Task { try? await amPlayer.skipToNextEntry() } }
                    else if g.translation.width > 60 { Task { try? await amPlayer.skipToPreviousEntry() } }
                })
            Spacer(minLength: 0)
        }
    }

    private var queueList: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Als Nächstes").font(.headline)
                Spacer()
                Button { state.shuffleMode = state.shuffleMode == .songs ? .off : .songs } label: { Image(systemName: "shuffle") }
                    .buttonStyle(.bordered).tint(state.shuffleMode == .songs ? amPink : .secondary)
                Button { cycleRepeat() } label: { Image(systemName: state.repeatMode == .one ? "repeat.1" : "repeat") }
                    .buttonStyle(.bordered).tint(state.repeatMode == MusicPlayer.RepeatMode.none || state.repeatMode == nil ? .secondary : amPink)
            }
            List {
                ForEach(upcoming, id: \.id) { x in
                    HStack { AMCover(artwork: x.artwork, size: 40, radius: 5); VStack(alignment: .leading) { Text(x.title).lineLimit(1); Text(x.subtitle ?? "").font(.caption).foregroundStyle(.secondary) } }
                        .contentShape(Rectangle())
                        .onTapGesture { amPlayer.queue.currentEntry = x; Task { try? await amPlayer.play() } }
                        .listRowBackground(Color.clear)
                }
                .onMove { from, to in
                    let base = currentIndex + 1
                    amPlayer.queue.entries.move(fromOffsets: IndexSet(from.map { $0 + base }), toOffset: to + base)
                }
                .onDelete { idx in
                    let base = currentIndex + 1
                    amPlayer.queue.entries.remove(atOffsets: IndexSet(idx.map { $0 + base }))
                }
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            .environment(\.editMode, .constant(.active))
        }
    }

    private var currentIndex: Int {
        let entries = Array(queue.entries)
        guard let cur = queue.currentEntry, let i = entries.firstIndex(where: { $0.id == cur.id }) else { return -1 }
        return i
    }
    private var upcoming: [ApplicationMusicPlayer.Queue.Entry] { Array(Array(queue.entries).dropFirst(currentIndex + 1)) }

    private func cycleRepeat() {
        switch state.repeatMode {
        case .all?: state.repeatMode = .one
        case .one?: state.repeatMode = MusicPlayer.RepeatMode.none
        default: state.repeatMode = .all
        }
    }

    private var titleBlock: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(queue.currentEntry?.title ?? "Nicht in Wiedergabe").font(.title3.bold()).lineLimit(1)
                Button { if let s = song { Task { if let a = try? await s.with([.artists]).artists?.first { go(.artist(a)) } } } } label: {
                    Text(queue.currentEntry?.subtitle ?? "").foregroundStyle(.secondary).lineLimit(1)
                }.buttonStyle(.plain)
            }
            Spacer()
            if let s = song {
                Menu {
                    Button { AMRouter.shared.addToLibrary(s) } label: { Label("Zur Mediathek hinzufügen", systemImage: "plus") }
                    Button { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { AMRouter.shared.addToPlaylist = s } } label: { Label("Zu einer Playlist hinzufügen …", systemImage: "text.badge.plus") }
                    Divider()
                    Button { Task { if let a = try? await s.with([.albums]).albums?.first { go(.album(a)) } } } label: { Label("Zum Album", systemImage: "square.stack") }
                    Button { Task { if let a = try? await s.with([.artists]).artists?.first { go(.artist(a)) } } } label: { Label("Zum Künstler", systemImage: "music.mic") }
                    if let u = s.url {
                        ShareLink(item: u) { Label("Titel teilen", systemImage: "square.and.arrow.up") }
                        Button { UIApplication.shared.open(u) } label: { Label("Songtext in Apple Music", systemImage: "quote.bubble") }
                    }
                } label: { Image(systemName: "ellipsis").font(.title3).frame(width: 36, height: 36).background(.white.opacity(0.12), in: Circle()) }
            }
        }
    }

    private var timeline: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            VStack(spacing: 4) {
                Slider(value: Binding(get: { scrub ?? amPlayer.playbackTime }, set: { scrub = $0 }), in: 0...max(duration, 1)) { editing in
                    if !editing, let s = scrub { amPlayer.playbackTime = s; scrub = nil }
                }.tint(.white)
                HStack { Text(fmt(scrub ?? amPlayer.playbackTime)); Spacer(); Text("-" + fmt(max(0, duration - (scrub ?? amPlayer.playbackTime)))) }
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 50) {
            Button { Task { if amPlayer.playbackTime > 3 { amPlayer.restartCurrentEntry() } else { try? await amPlayer.skipToPreviousEntry() } } } label: { Image(systemName: "backward.fill") }
            Button { if playing { amPlayer.pause() } else { Task { try? await amPlayer.play() } } } label: { Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 46)) }
            Button { Task { try? await amPlayer.skipToNextEntry() } } label: { Image(systemName: "forward.fill") }
        }.font(.system(size: 30)).foregroundStyle(.primary)
    }

    private func fmt(_ t: Double) -> String { let s = Int(max(0, t.isFinite ? t : 0)); return "\(s / 60):" + String(format: "%02d", s % 60) }
}

struct AMVolume: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView { MPVolumeView() }
    func updateUIView(_ v: MPVolumeView, context: Context) {}
}
struct AMRoute: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView { let v = AVRoutePickerView(); v.tintColor = .white; return v }
    func updateUIView(_ v: AVRoutePickerView, context: Context) {}
}


// MARK: Mini-Player über allen Bereichen der App (ein- und ausklappbar)
struct AMFloatingPlayer: View {
    let open: () -> Void
    @ObservedObject private var state = ApplicationMusicPlayer.shared.state
    @ObservedObject private var queue = ApplicationMusicPlayer.shared.queue
    @AppStorage("amMiniCollapsed") private var collapsed = false

    var body: some View {
        if let e = queue.currentEntry {
            Group {
                if collapsed {
                    Button { withAnimation(.spring(response: 0.35)) { collapsed = false } } label: {
                        ZStack(alignment: .bottomTrailing) {
                            AMCover(artwork: e.artwork, size: 52, radius: 26)
                            Image(systemName: state.playbackStatus == .playing ? "waveform" : "pause.fill")
                                .font(.caption2.bold()).padding(5).background(amPink, in: Circle()).foregroundStyle(.white)
                        }
                        .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
                    }
                    .accessibilityLabel("Mini-Player ausklappen")
                    .frame(maxWidth: .infinity, alignment: .trailing)
                } else {
                    HStack(spacing: 12) {
                        AMCover(artwork: e.artwork, size: 42, radius: 6)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.title).font(.subheadline.weight(.medium)).lineLimit(1)
                            if let s = e.subtitle { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        Spacer(minLength: 4)
                        Button { if state.playbackStatus == .playing { ApplicationMusicPlayer.shared.pause() } else { Task { try? await ApplicationMusicPlayer.shared.play() } } } label: {
                            Image(systemName: state.playbackStatus == .playing ? "pause.fill" : "play.fill").font(.title3).frame(width: 34, height: 34)
                        }
                        Button { Task { try? await ApplicationMusicPlayer.shared.skipToNextEntry() } } label: { Image(systemName: "forward.fill").font(.title3).frame(width: 34, height: 34) }
                        Button { withAnimation(.spring(response: 0.35)) { collapsed = true } } label: { Image(systemName: "chevron.down").font(.subheadline.bold()).frame(width: 28, height: 34) }
                            .accessibilityLabel("Mini-Player einklappen")
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                    .contentShape(Rectangle())
                    .onTapGesture { open() }
                    .gesture(DragGesture(minimumDistance: 24).onEnded { g in
                        if g.translation.height > 30 { withAnimation(.spring(response: 0.35)) { collapsed = true } }
                        else if g.translation.height < -40 { open() }
                        else if g.translation.width < -60 { Task { try? await ApplicationMusicPlayer.shared.skipToNextEntry() } }
                        else if g.translation.width > 60 { Task { try? await ApplicationMusicPlayer.shared.skipToPreviousEntry() } }
                    })
                }
            }
            .padding(.horizontal, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .preferredColorScheme(.dark)
        }
    }
}
