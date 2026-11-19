import UIKit
import SwiftUI
import UniformTypeIdentifiers

/// „In Gedankenpalast“ im Teilen-Menü jeder App: Ordner wählen oder später einordnen („Wohin damit?“),
/// ohne die App zu öffnen. Nutzt den Geräte-Schlüssel der App (gemeinsamer Schlüsselbund).
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        let host = UIHostingController(rootView: ShareView(providers: providers, done: { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }, cancel: { [weak self] in
            self?.extensionContext?.cancelRequest(withError: NSError(domain: "Gedankenpalast", code: 0))
        }))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }
}

struct ShareView: View {
    let providers: [NSItemProvider]
    let done: () -> Void
    let cancel: () -> Void
    @State private var folders: [String] = Shared.cached?.folders ?? ["Allgemein"]
    @State private var busy = false
    @State private var progress = 0
    @State private var error = ""

    var body: some View {
        NavigationStack {
            List {
                if Shared.appKey == nil {
                    Text("Bitte zuerst die App Gedankenpalast einmal öffnen und anmelden.").foregroundStyle(.secondary)
                } else {
                    Section {
                        Button { send(nil, clip: true) } label: { Label("Zwischenablage (für Laptop & iPad)", systemImage: "doc.on.clipboard") }
                        Button { send(nil) } label: { Label("Später einordnen („Wohin damit?“)", systemImage: "tray.and.arrow.down") }
                    }
                    Section("In Ordner der Ablage") {
                        ForEach(folders, id: \.self) { f in
                            Button { send(f) } label: { Label(f, systemImage: "folder.fill") }
                        }
                    }
                }
                if busy { HStack { ProgressView(); Text("\(progress) von \(providers.count) übertragen …") } }
                if !error.isEmpty { Text(error).foregroundStyle(.red).font(.footnote) }
            }
            .disabled(busy)
            .navigationTitle("In Gedankenpalast")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen", action: cancel) } }
            .task { if let s = try? await PortalAPI.summary(), let f = s.folders, !f.isEmpty { folders = f } }
        }
        .preferredColorScheme(.dark)
    }

    private func send(_ folder: String?, clip: Bool = false) {
        busy = true; error = ""; progress = 0
        Task {
            var ok = 0
            for p in providers {
                if clip, let text = await Self.loadText(p) {   // Links und Text als Text in die Zwischenablage
                    if (try? await PortalAPI.action(["action": "clip", "text": text])) != nil { ok += 1 }
                    progress += 1; continue
                }
                if let (data, name, type) = await Self.load(p), (try? await PortalAPI.upload(data, name: name, type: type, folder: folder, clip: clip)) != nil { ok += 1 }
                progress += 1
            }
            busy = false
            if ok == providers.count { done() } else { error = ok == 0 ? "Übertragen fehlgeschlagen – Internet und Anmeldung prüfen." : "\(providers.count - ok) Datei(en) nicht übertragen." }
        }
    }

    /// Link oder reiner Text (keine Datei) – für die Zwischenablage
    static func loadText(_ p: NSItemProvider) async -> String? {
        if p.hasItemConformingToTypeIdentifier(UTType.url.identifier), !p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let url = try? await p.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL, !url.isFileURL { return url.absoluteString }
        if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier), !p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let t = try? await p.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String { return t }
        return nil
    }

    /// Datei, Bild, Video oder Text aus dem Teilen-Menü lesen
    static func load(_ p: NSItemProvider) async -> (Data, String, String)? {
        let type = p.registeredTypeIdentifiers.compactMap { UTType($0) }.first { $0.conforms(to: .data) || $0.conforms(to: .content) } ?? .data
        if p.hasItemConformingToTypeIdentifier(UTType.url.identifier), !p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let url = try? await p.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL, !url.isFileURL {
            return (Data("[InternetShortcut]\nURL=\(url.absoluteString)\n".utf8), (url.host ?? "Link") + ".url", "text/plain")
        }
        return await withCheckedContinuation { c in
            p.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url, let data = try? Data(contentsOf: url) else { c.resume(returning: nil); return }
                let name = p.suggestedName.map { n in (n as NSString).pathExtension.isEmpty ? n + "." + url.pathExtension : n } ?? url.lastPathComponent
                c.resume(returning: (data, name, type.preferredMIMEType ?? "application/octet-stream"))
            }
        }
    }
}
