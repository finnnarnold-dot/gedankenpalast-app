import Foundation

/// Im Website-Design läuft der native Abgleich unsichtbar im Hintergrund weiter – für Spotlight,
/// Live-Aktivität „Nächste Vorlesung“, Widgets und Siri. Die Anmeldung übernimmt er aus der Webansicht.
@MainActor
enum BackgroundSync {
    static func start() async {
        for _ in 0..<60 {   // warten, bis du in der Webansicht angemeldet bist
            await PortalClient.shared.adoptWebSession()
            if PortalClient.shared.loggedIn { DataStore.shared.start(); return }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }
}
