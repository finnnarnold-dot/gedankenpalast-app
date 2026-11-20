// Gedankenpalast – das Studienportal als App für iPhone und iPad.
// Die Oberfläche kommt vom eigenen Server (Verbesserungen sind sofort da); die App ergänzt, was eine Website nicht kann:
// „Öffnen in …“/Teilen-Ziel, Face ID, Mitteilungen, Musik im Hintergrund, Widgets, Siri/Kurzbefehle,
// Apple Erinnerungen, chess.com in der App.
import SwiftUI
import CoreSpotlight
import AVFoundation
import UserNotifications

@main
struct StudienportalApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    init() {
        // Musik aus dem Portal läuft weiter, wenn die App im Hintergrund ist oder der Bildschirm aus
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .onOpenURL { model.handleOpen($0) }
        }
        .onChange(of: phase) { newPhase in model.scenePhaseChanged(newPhase) }
    }
}

/// Schnellaktionen beim langen Drücken auf das App-Symbol (Kalender, Notizen, Ablage, Uni-Mail)
enum QuickAction {
    static var pending: String?
    static func handle(_ item: UIApplicationShortcutItem) {
        let route = item.type.components(separatedBy: ".").last ?? "portal"
        if let model = AppModel.shared { model.open(route: route) } else { pending = route }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    // Push: Kennung an den eigenen Server melden (er schickt „Routine fertig“, „Wichtige Uni-Mail“ auch bei geschlossener App)
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        let name = UIDevice.current.name
        Task { try? await PortalAPI.registerPush(hex, device: name) }
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {}

    // Mitteilung auch zeigen, wenn die App offen ist
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
    // Antippen öffnet den passenden Bereich (z. B. Uni-Mail)
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if let route = response.notification.request.content.userInfo["route"] as? String, !route.isEmpty {
            await MainActor.run { if let m = AppModel.shared { m.open(route: route) } else { QuickAction.pending = route } }
        }
    }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if let item = options.shortcutItem { QuickAction.handle(item) }
        let config = UISceneConfiguration(name: nil, sessionRole: session.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        QuickAction.handle(shortcutItem)
        completionHandler(true)
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            Color(red: 0.07, green: 0.067, blue: 0.063).ignoresSafeArea()
            if let url = model.serverURL {
                // Finns Wunsch: überall das Design der Website; nur Apple Music eins zu eins wie die Apple-Music-App.
                PortalWebView(url: url, model: model).ignoresSafeArea()
                    .task { await BackgroundSync.start() }
                if let p = model.pencil { PencilOverlay(session: p).id(p.id) }
                if !model.showAppleMusic && model.pencil == nil {   // Musik läuft weiter: Mini-Player in jedem Bereich
                    VStack { Spacer(); AMFloatingPlayer(open: { AMRouter.shared.openNowPlaying = true; model.showAppleMusic = true }).padding(.bottom, 74) }
                }
            } else {
                SetupView()
            }
            if model.locked { LockView() }
        }
        .preferredColorScheme(.dark)
        .onContinueUserActivity(CSSearchableItemActionType) { act in   // Spotlight-Treffer antippen → Bereich im Portal
            if let id = act.userInfo?[CSSearchableItemActivityIdentifier] as? String { model.open(route: SpotlightIndex.route(for: id)) }
        }
        .sheet(isPresented: $model.showAssistant) { AssistantSheet() }
        .fullScreenCover(isPresented: Binding(get: { model.embedURL != nil && !model.locked }, set: { if !$0 { model.embedURL = nil } })) {
            if let url = model.embedURL { EmbedView(url: url).environmentObject(model) }
        }
        // Nach dem Schließen bleibt die Musik-Seite stehen (Reiter Musik | Schach | Rechner) – vorher ging es zurück,
        // dadurch war Schach in der App nicht erreichbar (Finn, Verbesserungsnotiz 20.11.)
        .fullScreenCover(isPresented: Binding(get: { model.showAppleMusic && !model.locked }, set: { model.showAppleMusic = $0 })) {
            AppleMusicHome().environmentObject(model)
        }
    }
}

/// Einmalig: Adresse des eigenen Portals eingeben
struct SetupView: View {
    @EnvironmentObject var model: AppModel
    @State private var address = ""   // Adresse des eigenen Servers – bewusst nicht im (öffentlichen) App-Code
    @State private var error = ""
    @State private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Gedankenpalast").font(.largeTitle.bold())
            Text("Adresse deines Portals – so wie du sie im Browser öffnest. Die Adresse deines Servers ist schon eingetragen: einfach „Verbinden“ tippen.")
                .foregroundStyle(.secondary)
            TextField("https://…", text: $address)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.08)))
                .onSubmit(connect)
            if !error.isEmpty { Text(error).foregroundStyle(.red).font(.footnote) }
            Button(action: connect) {
                HStack { if checking { ProgressView() }; Text("Verbinden").bold() }
                    .frame(maxWidth: .infinity).padding(14)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color(red: 0.80, green: 0.84, blue: 0.64)))
                    .foregroundStyle(Color(red: 0.11, green: 0.13, blue: 0.07))
            }
            .disabled(checking)
        }
        .padding(28)
        .frame(maxWidth: 460)
    }

    private func connect() {
        guard let url = AppModel.normalize(address) else { error = "Bitte eine Adresse mit https eingeben."; return }
        checking = true; error = ""
        Task {
            let problem = await AppModel.checkPortal(url)
            await MainActor.run {
                checking = false
                if let problem { error = problem } else { model.setServer(url) }
            }
        }
    }
}

/// Sperre mit Face ID (in den Einstellungen des Portals einschaltbar)
struct LockView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "lock.fill").font(.system(size: 44))
                Text("Gedankenpalast ist gesperrt").font(.headline)
                Button("Entsperren") { model.unlock() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .onAppear { model.unlock() }
    }
}
