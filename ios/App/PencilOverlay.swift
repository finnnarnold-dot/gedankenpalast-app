import SwiftUI
import PencilKit
import WebKit
import Vision

// Apple Pencil direkt in der Notiz (Website-Design): Pencil auf den Notiztext → Apples Zeichenfläche liegt sofort darüber
// (erster Strich wird übernommen), Pencil auf eine Zeichnung → weiterzeichnen. Fingertipp → Handschrift wird an der
// Ansatzstelle eingefügt, zurück zum Text. In Textfeldern (Suche) bleibt Scribble: Pencil-Schrift wird zu Text.

struct NoteArea {
    var editor: CGRect?
    var drawings: [(src: String, data: String, rect: CGRect)] = []
}

final class PencilSession: ObservableObject, Identifiable {
    let id = UUID()
    let start: CGPoint
    let replaceSrc: String?
    let initial: PKDrawing?
    let initialRect: CGRect?
    @Published var firstStroke: [PKStrokePoint] = []
    @Published var firstStrokeDone = false
    init(start: CGPoint, replaceSrc: String? = nil, initial: PKDrawing? = nil, initialRect: CGRect? = nil) {
        self.start = start; self.replaceSrc = replaceSrc; self.initial = initial; self.initialRect = initialRect
    }
}

/// Erkennt den Pencil auf dem Notiztext; Finger und Textfelder bleiben unberührt
final class PencilCatcher: NSObject, UIGestureRecognizerDelegate {
    weak var model: AppModel?
    private var startTime = Date()

    func attach(to web: WKWebView, model: AppModel) {
        self.model = model
        let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        web.addGestureRecognizer(pan)
    }

    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard let m = model, m.pencil == nil, let ed = m.noteArea.editor else { return false }
        return ed.contains(g.location(in: g.view))
    }
    // Ansetzen auf dem Notiztext geht vor Textauswahl/Scribble der Webansicht
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool { true }

    @objc func pan(_ g: UIPanGestureRecognizer) {
        guard let m = model, let v = g.view else { return }
        let p = g.location(in: v)
        switch g.state {
        case .began:
            startTime = Date()
            if let d = m.noteArea.drawings.first(where: { $0.rect.contains(p) }), let data = Data(base64Encoded: d.data), let dr = try? PKDrawing(data: data) {
                m.pencil = PencilSession(start: p, replaceSrc: d.src, initial: dr, initialRect: d.rect)
            } else {
                m.pencil = PencilSession(start: p)
            }
            m.pencil?.firstStroke = [point(p)]
        case .changed:
            m.pencil?.firstStroke.append(point(p))
        case .ended, .cancelled, .failed:
            m.pencil?.firstStrokeDone = true
        default: break
        }
    }

    private func point(_ p: CGPoint) -> PKStrokePoint {
        PKStrokePoint(location: p, timeOffset: Date().timeIntervalSince(startTime), size: CGSize(width: 3, height: 3),
                      opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
    }
}

struct PencilOverlay: View {
    @ObservedObject var session: PencilSession
    @EnvironmentObject var model: AppModel
    @State private var canvas = PKCanvasView()
    @State private var busy = false
    @AppStorage("pencilMode") private var mode = "zeichnung"   // „zeichnung“ oder „text“ (Handschrift → Schrift)

    var body: some View {
        ZStack(alignment: .topTrailing) {
            OverlayCanvas(canvas: canvas, session: session, onFingerTap: finish)
                .ignoresSafeArea()
            HStack(spacing: 10) {
                if busy { ProgressView() }
                if session.replaceSrc == nil {   // beim Weiterzeichnen bleibt es eine Zeichnung
                    Picker("Einfügen als", selection: $mode) {
                        Text("Zeichnung").tag("zeichnung")
                        Text("Text").tag("text")
                    }
                    .pickerStyle(.segmented).frame(width: 190)
                }
                Button("Abbrechen") { model.pencil = nil }.buttonStyle(.bordered)
                Button("Fertig") { finish() }.buttonStyle(.borderedProminent).tint(Theme.accent)
            }
            .padding(.top, 54).padding(.trailing, 16)
        }
    }

    private func finish() {
        guard !busy else { return }
        let d = canvas.drawing
        guard !d.bounds.isEmpty else { model.pencil = nil; return }
        busy = true
        let rect = d.bounds.insetBy(dx: -12, dy: -12)
        var img = UIImage()
        UITraitCollection(userInterfaceStyle: .dark).performAsCurrent { img = d.image(from: rect, scale: 2) }   // helle Tinte wie auf dem Bildschirm
        let strokes = d.dataRepresentation().base64EncodedString()
        let start = session.replaceSrc == nil ? CGPoint(x: rect.minX + 4, y: rect.minY + 4) : session.start
        let replace = session.replaceSrc
        let asText = mode == "text" && replace == nil
        var ocrImage = UIImage()
        if asText {   // für die Erkennung: dunkle Tinte auf Weiß
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                let ink = d.image(from: rect, scale: 2)
                ocrImage = UIGraphicsImageRenderer(size: ink.size).image { ctx in
                    UIColor.white.setFill(); ctx.fill(CGRect(origin: .zero, size: ink.size)); ink.draw(at: .zero)
                }
            }
        }
        Task {
            defer { busy = false; model.pencil = nil }
            if asText {
                let text = await Self.recognize(ocrImage)
                if !text.isEmpty {
                    let js = "window.portalInsertText && portalInsertText(\(jsString(text)), \(start.x), \(start.y))"
                    _ = try? await model.webView?.evaluateJavaScript(js)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    return
                }
                AppModel.toast("Keine Schrift erkannt – als Zeichnung eingefügt")
            }
            guard let png = img.pngData(), let url = await PencilUpload.upload(png, model: model) else { return }
            let js = "window.portalInsertDrawing && portalInsertDrawing(\(jsString(url)), \(jsString(strokes)), \(start.x), \(start.y), \(replace.map(jsString) ?? "null"))"
            _ = try? await model.webView?.evaluateJavaScript(js)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    /// Handschrift → Text auf dem Gerät (Vision, ohne Internet); Zeilen von oben nach unten
    static func recognize(_ image: UIImage) async -> String {
        guard let cg = image.cgImage else { return "" }
        final class Once: @unchecked Sendable {   // Vision kann bei Fehlern doppelt melden – nur einmal antworten
            private let lock = NSLock(); private var done = false
            func run(_ f: () -> Void) { lock.lock(); defer { lock.unlock() }; if !done { done = true; f() } }
        }
        return await withCheckedContinuation { c in
            let once = Once()
            let req = VNRecognizeTextRequest { r, _ in
                let lines = (r.results as? [VNRecognizedTextObservation] ?? [])
                    .sorted { $0.boundingBox.minY > $1.boundingBox.minY }
                    .compactMap { $0.topCandidates(1).first?.string }
                once.run { c.resume(returning: lines.joined(separator: "\n")) }
            }
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = true
            req.recognitionLanguages = ["de-DE", "en-US"]
            DispatchQueue.global(qos: .userInitiated).async {
                do { try VNImageRequestHandler(cgImage: cg).perform([req]) } catch { once.run { c.resume(returning: "") } }
            }
        }
    }

    private func jsString(_ s: String) -> String {
        let d = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: d, as: UTF8.self).dropFirst().dropLast())
    }
}

enum PencilUpload {
    /// Bild in die Ablage (Ordner „Notizen“) – mit der Anmeldung der Webansicht
    @MainActor static func upload(_ png: Data, model: AppModel) async -> String? {
        guard let base = model.serverURL else { return nil }
        let cookie: String = await withCheckedContinuation { c in
            model.webView?.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let host = base.host ?? ""
                c.resume(returning: cookies.filter { host.hasSuffix($0.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))) }
                    .map { "\($0.name)=\($0.value)" }.joined(separator: "; "))
            } ?? c.resume(returning: "")
        }
        var comps = URLComponents(url: base.appendingPathComponent("api/upload"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "ablage", value: "1"), URLQueryItem(name: "folder", value: "Notizen")]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.httpShouldHandleCookies = false
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        let name = "Handschrift \(Date().formatted(.dateTime.day().month().year().hour().minute().second().locale(Locale(identifier: "de_DE")))).png"
        req.setValue(name.addingPercentEncoding(withAllowedCharacters: .alphanumerics), forHTTPHeaderField: "X-Filename")
        req.setValue("image/png", forHTTPHeaderField: "Content-Type")
        guard let (data, resp) = try? await URLSession.shared.upload(for: req, from: png), (resp as? HTTPURLResponse)?.statusCode == 200,
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return o["url"] as? String
    }
}

struct OverlayCanvas: UIViewRepresentable {
    let canvas: PKCanvasView
    @ObservedObject var session: PencilSession
    let onFingerTap: () -> Void

    func makeCoordinator() -> Coord { Coord(onFingerTap) }

    func makeUIView(context: Context) -> PKCanvasView {
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.overrideUserInterfaceStyle = .dark
        canvas.drawingPolicy = .pencilOnly
        canvas.tool = PKInkingTool(.pen, color: .black, width: 3)
        if let d = session.initial, let r = session.initialRect, !d.bounds.isEmpty {
            // bestehende Zeichnung an ihrer Stelle in der Notiz zeigen
            let target = r.insetBy(dx: 0, dy: 0)
            let src = d.bounds.insetBy(dx: -12, dy: -12)
            let s = target.width / max(src.width, 1)
            canvas.drawing = d.transformed(using: CGAffineTransform(translationX: -src.minX, y: -src.minY).scaledBy(x: 1, y: 1)
                .concatenating(CGAffineTransform(scaleX: s, y: s)).concatenating(CGAffineTransform(translationX: target.minX, y: target.minY)))
        }
        let picker = PKToolPicker()
        context.coordinator.picker = picker
        picker.setVisible(true, forFirstResponder: canvas)
        picker.addObserver(canvas)
        DispatchQueue.main.async { canvas.becomeFirstResponder() }
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coord.tap))
        tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        canvas.addGestureRecognizer(tap)
        return canvas
    }

    func updateUIView(_ v: PKCanvasView, context: Context) {
        // ersten Strich (vor dem Erscheinen der Fläche gezeichnet) übernehmen
        if session.firstStrokeDone, !context.coordinator.addedFirst, session.firstStroke.count > 1 {
            context.coordinator.addedFirst = true
            let ink = (v.tool as? PKInkingTool)?.ink ?? PKInk(.pen, color: .black)
            let path = PKStrokePath(controlPoints: session.firstStroke, creationDate: Date())
            v.drawing.strokes.append(PKStroke(ink: ink, path: path))
        }
    }

    final class Coord: NSObject {
        let onTap: () -> Void
        var picker: PKToolPicker?
        var addedFirst = false
        init(_ t: @escaping () -> Void) { onTap = t }
        @objc func tap() { onTap() }
    }
}
