import Foundation
import MusicKit
import WebKit

/// Apple Music im Player des Portals (MusicKit): Mediathek (Playlists, Alben, Titel), Katalogsuche, Wiedergabe.
/// Das Portal fragt über window.webkit.messageHandlers.portal.postMessage({type:'music', op:…, req:…}) an,
/// die App antwortet mit portalNative.reply(req, daten) und meldet den Wiedergabestand mit portalNative.music(stand).
@MainActor
final class MusicBridge {
    static let shared = MusicBridge()
    weak var webView: WKWebView?
    private let player = ApplicationMusicPlayer.shared
    private var items: [String: Any] = [:]        // zuletzt geladene Einträge (für Abspielen ohne neue Anfrage)
    private var timer: Timer?

    func handle(_ msg: [String: Any]) {
        let op = msg["op"] as? String ?? ""
        let req = msg["req"] as? Int ?? 0
        Task {
            do { reply(req, try await run(op, msg)) }
            catch { reply(req, ["error": error.localizedDescription]) }
        }
    }

    private func run(_ op: String, _ m: [String: Any]) async throws -> Any {
        switch op {
        case "status":
            return await status()
        case "auth":
            _ = await MusicAuthorization.request()
            return await status()
        case "library":
            try await requireAuth()
            switch m["kind"] as? String {
            case "albums":
                var r = MusicLibraryRequest<Album>(); r.sort(by: \.title, ascending: true); r.limit = 300
                return try await r.response().items.map { remember($0, album($0)) }
            case "songs":
                var r = MusicLibraryRequest<Song>(); r.sort(by: \.title, ascending: true); r.limit = 500
                return try await r.response().items.map { remember($0, song($0)) }
            default:
                var r = MusicLibraryRequest<Playlist>(); r.limit = 200
                return try await r.response().items.map { remember($0, playlist($0)) }
            }
        case "tracks":
            try await requireAuth()
            let id = m["id"] as? String ?? ""
            if let a = items[id] as? Album {
                let full = try await a.with([.tracks])
                return (full.tracks ?? []).map { remember($0, track($0)) }
            }
            if let p = items[id] as? Playlist {
                let full = try await p.with([.tracks])
                return (full.tracks ?? []).map { remember($0, track($0)) }
            }
            return []
        case "search":
            try await requireAuth()
            let term = (m["q"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty else { return [:] }
            var r = MusicCatalogSearchRequest(term: term, types: [Song.self, Album.self, Playlist.self])
            r.limit = 15
            let res = try await r.response()
            return ["songs": res.songs.map { remember($0, song($0)) },
                    "albums": res.albums.map { remember($0, album($0)) },
                    "playlists": res.playlists.map { remember($0, playlist($0)) }]
        case "play":
            try await requireAuth()
            let ids = m["ids"] as? [String] ?? []
            let start = m["id"] as? String
            if let id = start, ids.isEmpty {
                if let a = items[id] as? Album { player.queue = [a] }
                else if let p = items[id] as? Playlist { player.queue = [p] }
                else if let s = items[id] as? Song { player.queue = [s] }
                else if let t = items[id] as? Track { player.queue = [t] }
            } else {
                let list = ids.compactMap { items[$0] as? PlayableMusicItem }
                guard !list.isEmpty else { throw MusicBridgeError.notFound }
                let songs = list.compactMap { $0 as? Song }, tracks = list.compactMap { $0 as? Track }
                if songs.count == list.count {
                    let first = songs.first { $0.id.rawValue == start } ?? songs[0]
                    player.queue = ApplicationMusicPlayer.Queue(for: songs, startingAt: first)
                } else if tracks.count == list.count {
                    let first = tracks.first { $0.id.rawValue == start } ?? tracks[0]
                    player.queue = ApplicationMusicPlayer.Queue(for: tracks, startingAt: first)
                } else { throw MusicBridgeError.notFound }
            }
            player.state.shuffleMode = (m["shuffle"] as? Bool ?? false) ? .songs : .off
            try await player.prepareToPlay()
            try await player.play()
            startTimer()
            return state()
        case "toggle":
            if player.state.playbackStatus == .playing { player.pause() } else { try await player.play(); startTimer() }
            return state()
        case "pause":
            player.pause(); return state()
        case "next":
            try await player.skipToNextEntry(); return state()
        case "prev":
            if player.playbackTime > 3 { player.restartCurrentEntry() } else { try await player.skipToPreviousEntry() }
            return state()
        case "seek":
            player.playbackTime = m["time"] as? Double ?? 0; return state()
        case "shuffle":
            player.state.shuffleMode = (m["on"] as? Bool ?? false) ? .songs : .off; return state()
        case "repeat":
            let modes: [String: MusicPlayer.RepeatMode] = ["all": .all, "one": .one]
            player.state.repeatMode = modes[m["mode"] as? String ?? ""] ?? MusicPlayer.RepeatMode.none
            return state()
        case "state":
            return state()
        default:
            return ["error": "Unbekannt"]
        }
    }

    // MARK: Zustand
    private func status() async -> [String: Any] {
        let auth = MusicAuthorization.currentStatus
        let name: String
        switch auth {
        case .authorized: name = "authorized"
        case .denied: name = "denied"
        case .restricted: name = "restricted"
        default: name = "notDetermined"
        }
        var out: [String: Any] = ["auth": name]
        if auth == .authorized, let sub = try? await MusicSubscription.current {
            out["catalog"] = sub.canPlayCatalogContent
            out["canSubscribe"] = sub.canBecomeSubscriber
        }
        return out
    }

    private func requireAuth() async throws {
        if MusicAuthorization.currentStatus != .authorized, await MusicAuthorization.request() != .authorized {
            throw MusicBridgeError.denied
        }
    }

    func state() -> [String: Any] {
        var out: [String: Any] = ["playing": player.state.playbackStatus == .playing, "time": player.playbackTime,
                                  "shuffle": player.state.shuffleMode == .songs,
                                  "repeat": player.state.repeatMode == .all ? "all" : player.state.repeatMode == .one ? "one" : "off"]
        if let e = player.queue.currentEntry {
            out["title"] = e.title
            out["artist"] = e.subtitle ?? ""
            out["art"] = web(e.artwork) ?? ""
            switch e.item {
            case .song(let s)?: out["duration"] = s.duration ?? 0; out["album"] = s.albumTitle ?? ""
            case .musicVideo(let v)?: out["duration"] = v.duration ?? 0
            default: break
            }
        }
        return out
    }

    func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.push()
                if self.player.state.playbackStatus != .playing && self.player.state.playbackStatus != .seekingForward
                    && self.player.state.playbackStatus != .seekingBackward { self.timer?.invalidate(); self.timer = nil; self.push() }
            }
        }
    }
    private func push() { call("portalNative.music", state()) }

    // MARK: Umwandeln für das Portal
    private func remember(_ item: Any, _ dict: [String: Any]) -> [String: Any] {
        if let id = dict["id"] as? String { items[id] = item }
        return dict
    }
    /// Nur Bilder mit https-Adresse kann die Webansicht zeigen (Titel aus der eigenen Mediathek haben teils keine)
    private func web(_ art: Artwork?) -> String? {
        guard let u = art?.url(width: 400, height: 400), u.scheme == "https" else { return nil }
        return u.absoluteString
    }
    private func song(_ s: Song) -> [String: Any] {
        ["id": s.id.rawValue, "kind": "song", "title": s.title, "artist": s.artistName, "album": s.albumTitle ?? "",
         "duration": s.duration ?? 0, "art": web(s.artwork) ?? ""]
    }
    private func track(_ t: Track) -> [String: Any] {
        ["id": t.id.rawValue, "kind": "track", "title": t.title, "artist": t.artistName, "album": t.albumTitle ?? "",
         "duration": t.duration ?? 0, "art": web(t.artwork) ?? ""]
    }
    private func album(_ a: Album) -> [String: Any] {
        ["id": a.id.rawValue, "kind": "album", "title": a.title, "artist": a.artistName, "count": a.trackCount, "art": web(a.artwork) ?? ""]
    }
    private func playlist(_ p: Playlist) -> [String: Any] {
        ["id": p.id.rawValue, "kind": "playlist", "title": p.name, "artist": p.curatorName ?? "", "art": web(p.artwork) ?? ""]
    }

    // MARK: Antwort an das Portal
    private func reply(_ req: Int, _ data: Any) {
        guard req > 0 else { return }
        call("portalNative.reply", req, data)
    }
    private func call(_ fn: String, _ args: Any...) {
        let parts = args.map { a -> String in
            if let n = a as? Int { return String(n) }
            guard JSONSerialization.isValidJSONObject(a), let d = try? JSONSerialization.data(withJSONObject: a) else { return "null" }
            return String(decoding: d, as: UTF8.self)
        }
        webView?.evaluateJavaScript("window.portalNative && \(fn)(\(parts.joined(separator: ",")))")
    }
}

enum MusicBridgeError: LocalizedError {
    case denied, notFound
    var errorDescription: String? {
        switch self {
        case .denied: return "Kein Zugriff auf Apple Music – in den iOS-Einstellungen unter Datenschutz → Medien & Apple Music erlauben."
        case .notFound: return "Titel nicht mehr geladen – bitte Liste neu öffnen."
        }
    }
}
