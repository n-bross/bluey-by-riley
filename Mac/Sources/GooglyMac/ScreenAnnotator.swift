import AppKit
import SwiftUI
import ScreenCaptureKit
import GooglyShared

/// Full-screen transparent annotation overlay so you can draw directly on your monitor with the Huion pen
/// (or mouse/trackpad) while screen-sharing, AND send the annotated screen straight to Bluey or Hermes.
@MainActor
final class ScreenAnnotator: NSObject {
    @MainActor
    final class Model: ObservableObject {
        @Published var strokes: [InkStroke] = []
        @Published var activeStroke: InkStroke?
        @Published var hoverPoint: CGPoint?
        @Published var selectedColor: String = "#38BDF8"
        @Published var tool: InkTool = .pen
        @Published var strokeWidth: Double = 0.0026
        @Published var laserFade = false
        @Published var passThrough = false
        @Published var prompt = ""
        @Published var status: String?
        @Published var busy = false
        @Published var recordingStartedAt: Date?

        var currentRecordingOffset: Double? {
            guard let started = recordingStartedAt else { return nil }
            return max(0, Date().timeIntervalSince(started))
        }

        static let palette: [(name: String, hex: String)] = [
            ("Bluey Cyan", "#38BDF8"),
            ("Rot", "#F87171"),
            ("Gelb", "#FACC15"),
            ("Grün", "#4ADE80"),
            ("Weiß", "#F8FAFC"),
        ]

        func undo() {
            guard !strokes.isEmpty else { return }
            strokes.removeLast()
        }

        func clear() {
            strokes.removeAll()
            activeStroke = nil
        }

        func handlePenSample(_ sample: HuionProtocol.PenSample, screenSize: CGSize) {
            guard !passThrough else { return }
            if !sample.hovering {
                hoverPoint = nil
                finishActiveStroke()
                return
            }
            hoverPoint = CGPoint(x: sample.x * screenSize.width, y: sample.y * screenSize.height)
            if sample.touching {
                let pt = InkPoint(x: sample.x, y: sample.y, p: max(0.15, sample.pressure))
                if activeStroke == nil {
                    activeStroke = InkStroke(color: selectedColor, width: strokeWidth, tool: tool, points: [pt],
                                             createdAt: Date(), recordingOffsetSeconds: currentRecordingOffset)
                } else {
                    activeStroke?.points.append(pt)
                }
            } else {
                finishActiveStroke()
            }
        }

        func beginMouseStroke(at point: CGPoint, in size: CGSize) {
            guard size.width > 0, size.height > 0 else { return }
            let pt = InkPoint(x: point.x / size.width, y: point.y / size.height, p: 0.6)
            activeStroke = InkStroke(color: selectedColor, width: strokeWidth, tool: tool, points: [pt],
                                     createdAt: Date(), recordingOffsetSeconds: currentRecordingOffset)
        }

        func continueMouseStroke(to point: CGPoint, in size: CGSize) {
            guard size.width > 0, size.height > 0 else { return }
            let pt = InkPoint(x: point.x / size.width, y: point.y / size.height, p: 0.6)
            if activeStroke == nil {
                activeStroke = InkStroke(color: selectedColor, width: strokeWidth, tool: tool, points: [pt],
                                         createdAt: Date(), recordingOffsetSeconds: currentRecordingOffset)
            } else {
                activeStroke?.points.append(pt)
            }
        }

        func finishActiveStroke() {
            guard let finished = activeStroke else { return }
            activeStroke = nil
            guard !finished.points.isEmpty else { return }
            let simplified = finished.simplified(minDistance: 0.0008)
            strokes.append(simplified)
            if laserFade {
                let id = simplified.id
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(2.4))
                    self?.strokes.removeAll { $0.id == id }
                }
            }
        }
    }

    let model = Model()
    private weak var huion: HuionBridge?
    private var canvasWindow: NSWindow?
    private var toolbarPanel: NSPanel?
    private var activeScreen: NSScreen?
    private var keyMonitor: Any?

    /// Sends the annotated screen PNG + optional question to Bluey's Chat tab.
    var onSendToBluey: ((Data, String) -> Void)?
    /// Sends the annotated screen PNG file path + optional question to Hermes.
    var onSendToHermes: ((URL, String) -> Void)?
    /// Saves the screen drawing (and optional screenshot) as a Bluey Note.
    var onSaveAsNote: ((InkDrawing, Data?) -> Void)?
    /// Automatically invoked during an active meeting/video recording whenever screen annotations are finished/cleared.
    var onMeetingDrawingSnapshot: ((Double, InkDrawing, Data?) -> Void)?

    func setRecordingStartedAt(_ date: Date?) {
        model.recordingStartedAt = date
    }

    /// Snapshots any current screen strokes into the active meeting recording before clearing/closing.
    func snapshotForRecordingIfNeeded() {
        model.finishActiveStroke()
        guard let started = model.recordingStartedAt, !model.strokes.isEmpty else { return }
        let strokes = model.strokes
        let screen = activeScreen ?? NSScreen.main ?? NSScreen.screens.first
        let ratio = screen.map { Double($0.frame.width / max(1, $0.frame.height)) } ?? (16.0 / 9.0)
        let drawing = InkDrawing(aspectRatio: ratio, paper: .dark, strokes: strokes)
        let offset = drawing.videoTimeRange?.start ?? max(0, Date().timeIntervalSince(started))
        Task { @MainActor [weak self] in
            guard let self else { return }
            let png = await self.captureAnnotatedDisplay(screen: screen, strokes: strokes)
            self.onMeetingDrawingSnapshot?(offset, drawing, png)
        }
    }

    var isVisible: Bool { canvasWindow?.isVisible == true }

    init(huion: HuionBridge) {
        self.huion = huion
        super.init()
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        let screen = screenWithMouse() ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        activeScreen = screen
        model.passThrough = false
        model.status = nil

        if canvasWindow == nil {
            let win = NSWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            win.isOpaque = false
            win.backgroundColor = .clear
            win.hasShadow = false
            win.level = .screenSaver
            win.sharingType = .readOnly // Visible during Zoom / Meet / Teams screen sharing!
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            win.contentView = NSHostingView(rootView: ScreenAnnotationCanvasView(model: model))
            canvasWindow = win
        }
        canvasWindow?.setFrame(screen.frame, display: true)
        canvasWindow?.ignoresMouseEvents = false
        canvasWindow?.orderFrontRegardless()

        if toolbarPanel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 56),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.isFloatingPanel = true
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            panel.isMovableByWindowBackground = true
            panel.sharingType = .readOnly
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: ScreenAnnotationToolbarView(
                model: model,
                huionConnected: { [weak huion] in huion?.isAnyDeviceConnected ?? false },
                onTogglePassThrough: { [weak self] in self?.togglePassThrough() },
                onClear: { [weak self] in
                    self?.snapshotForRecordingIfNeeded()
                    self?.model.clear()
                },
                onSendBluey: { [weak self] in self?.captureAndSend(target: .bluey) },
                onSendHermes: { [weak self] in self?.captureAndSend(target: .hermes) },
                onSaveNote: { [weak self] in self?.captureAndSend(target: .note) },
                onClose: { [weak self] in self?.hide() }
            ))
            toolbarPanel = panel
        }
        let topX = screen.frame.midX - 380
        let topY = screen.frame.maxY - 94
        toolbarPanel?.setFrameOrigin(NSPoint(x: topX, y: topY))
        toolbarPanel?.orderFrontRegardless()

        huion?.screenAnnotatorActive = true
        huion?.onScreenPenSample = { [weak self] sample in
            guard let self, let size = self.activeScreen?.frame.size else { return }
            self.model.handlePenSample(sample, screenSize: size)
        }

        installKeyMonitor()
    }

    func hide() {
        snapshotForRecordingIfNeeded()
        huion?.screenAnnotatorActive = false
        huion?.onScreenPenSample = nil
        model.hoverPoint = nil
        model.finishActiveStroke()
        canvasWindow?.orderOut(nil)
        toolbarPanel?.orderOut(nil)
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func togglePassThrough() {
        model.passThrough.toggle()
        canvasWindow?.ignoresMouseEvents = model.passThrough
        model.status = model.passThrough ? "Klick-Durchlass aktiv (Zeichnung bleibt sichtbar)" : nil
    }

    private func installKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible else { return event }
            if event.keyCode == 53 { // Esc
                self.hide()
                return nil
            }
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" {
                self.model.undo()
                return nil
            }
            return event
        }
    }

    private func screenWithMouse() -> NSScreen? {
        let loc = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(loc) }
    }

    private enum SendTarget { case bluey, hermes, note }

    private func captureAndSend(target: SendTarget) {
        guard !model.busy else { return }
        model.busy = true
        model.status = "Erfasse Bildschirm…"
        let prompt = model.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let screen = activeScreen ?? NSScreen.main ?? NSScreen.screens.first
        let strokes = model.strokes

        Task { @MainActor in
            defer { self.model.busy = false }
            let compositePNG = await self.captureAnnotatedDisplay(screen: screen, strokes: strokes)
            if let started = self.model.recordingStartedAt, !strokes.isEmpty {
                let ratio = screen.map { Double($0.frame.width / max(1, $0.frame.height)) } ?? (16.0 / 9.0)
                let drawing = InkDrawing(aspectRatio: ratio, paper: .dark, strokes: strokes)
                let offset = drawing.videoTimeRange?.start ?? max(0, Date().timeIntervalSince(started))
                self.onMeetingDrawingSnapshot?(offset, drawing, compositePNG)
            }

            switch target {
            case .bluey:
                guard let png = compositePNG else {
                    self.model.status = "Bildschirmaufnahme fehlgeschlagen (Berechtigung prüfen)."
                    return
                }
                let text = prompt.isEmpty
                    ? "Schau dir an, was ich auf meinem Bildschirm markiert/geschrieben habe, und hilf mir dabei."
                    : prompt
                self.model.prompt = ""
                self.model.clear()
                self.hide()
                self.onSendToBluey?(png, text)

            case .hermes:
                guard let png = compositePNG else {
                    self.model.status = "Bildschirmaufnahme fehlgeschlagen."
                    return
                }
                let dir = HuionArchive.folder
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
                let fileURL = dir.appendingPathComponent("screen_\(f.string(from: Date())).png")
                try? png.write(to: fileURL, options: .atomic)
                let text = prompt.isEmpty
                    ? "Schau dir meinen annotierten Screenshot an (\(fileURL.path)) und hilf mir bei dem, was ich markiert habe."
                    : "\(prompt)\n\nAnnotierter Screenshot: \(fileURL.path)"
                self.model.prompt = ""
                self.model.clear()
                self.hide()
                self.onSendToHermes?(fileURL, text)

            case .note:
                let ratio = screen.map { Double($0.frame.width / max(1, $0.frame.height)) } ?? (16.0 / 9.0)
                let drawing = InkDrawing(aspectRatio: ratio, paper: .dark, strokes: strokes)
                self.model.clear()
                self.hide()
                self.onSaveAsNote?(drawing, compositePNG)
            }
        }
    }

    /// Captures the underlying display via ScreenCaptureKit (excluding Bluey's toolbar) and composites the vector strokes cleanly on top.
    private func captureAnnotatedDisplay(screen: NSScreen?, strokes: [InkStroke]) async -> Data? {
        guard let screen,
              let screenNum = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return nil
        }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == screenNum }) ?? content.displays.first else {
            return nil
        }
        let me = content.applications.filter {
            $0.processID == ProcessInfo.processInfo.processIdentifier || $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
        let config = SCStreamConfiguration()
        let maxW: CGFloat = 1920
        let scale = min(2.0, maxW / max(1, CGFloat(display.width)))
        config.width = Int(CGFloat(display.width) * scale)
        config.height = Int(CGFloat(display.height) * scale)
        config.showsCursor = false

        guard let baseImage = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else {
            return nil
        }
        let w = baseImage.width
        let h = baseImage.height
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Draw screenshot right-side up in Quartz coordinates, then flip for normalized strokes.
        ctx.draw(baseImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        let fw = CGFloat(w), fh = CGFloat(h)
        for stroke in strokes where !stroke.points.isEmpty {
            let color = InkRenderer.nsColor(hexString: stroke.color).withAlphaComponent(stroke.tool == .highlighter ? 0.36 : 0.96)
            let baseW = max(2.2, CGFloat(stroke.width) * fw)
            ctx.setStrokeColor(color.cgColor)
            if stroke.points.count == 1 {
                let p = stroke.points[0]
                ctx.setFillColor(color.cgColor)
                ctx.fillEllipse(in: CGRect(x: CGFloat(p.x) * fw - baseW / 2, y: CGFloat(p.y) * fh - baseW / 2, width: baseW, height: baseW))
            } else {
                for i in 1..<stroke.points.count {
                    let a = stroke.points[i - 1], b = stroke.points[i]
                    let mult: CGFloat = stroke.tool == .highlighter ? 3.5 : CGFloat(0.55 + 0.95 * ((a.p + b.p) * 0.5))
                    ctx.setLineWidth(max(1.5, baseW * mult))
                    ctx.move(to: CGPoint(x: CGFloat(a.x) * fw, y: CGFloat(a.y) * fh))
                    ctx.addLine(to: CGPoint(x: CGFloat(b.x) * fw, y: CGFloat(b.y) * fh))
                    ctx.strokePath()
                }
            }
        }

        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])
    }
}

// MARK: - Overlay SwiftUI Views

private struct ScreenAnnotationCanvasView: View {
    @ObservedObject var model: ScreenAnnotator.Model

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Barely-visible hit surface when capturing mouse/stylus clicks.
                Color.white.opacity(model.passThrough ? 0.0 : 0.001)
                Canvas { ctx, size in
                    for stroke in model.strokes {
                        draw(stroke: stroke, in: &ctx, size: size)
                    }
                    if let active = model.activeStroke {
                        draw(stroke: active, in: &ctx, size: size)
                    }
                    if let hover = model.hoverPoint, !model.passThrough {
                        let ring = CGRect(x: hover.x - 8, y: hover.y - 8, width: 16, height: 16)
                        ctx.stroke(Path(ellipseIn: ring), with: .color(Color(hexString: model.selectedColor)), lineWidth: 2)
                    }
                }
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard !model.passThrough else { return }
                        if model.activeStroke == nil {
                            model.beginMouseStroke(at: value.startLocation, in: geo.size)
                        }
                        model.continueMouseStroke(to: value.location, in: geo.size)
                    }
                    .onEnded { _ in
                        model.finishActiveStroke()
                    }
            )
        }
        .ignoresSafeArea()
    }

    private func draw(stroke: InkStroke, in ctx: inout GraphicsContext, size: CGSize) {
        guard !stroke.points.isEmpty else { return }
        let color = Color(hexString: stroke.color).opacity(stroke.tool == .highlighter ? 0.36 : 0.96)
        let baseW = max(2.2, stroke.width * size.width)
        if stroke.points.count == 1 {
            let p = stroke.points[0]
            let r = baseW * 0.5
            ctx.fill(Path(ellipseIn: CGRect(x: p.x * size.width - r, y: p.y * size.height - r, width: r * 2, height: r * 2)), with: .color(color))
            return
        }
        if stroke.tool == .highlighter {
            var path = Path()
            path.move(to: CGPoint(x: stroke.points[0].x * size.width, y: stroke.points[0].y * size.height))
            for p in stroke.points.dropFirst() {
                path.addLine(to: CGPoint(x: p.x * size.width, y: p.y * size.height))
            }
            ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: baseW * 3.5, lineCap: .round, lineJoin: .round))
        } else {
            for i in 1..<stroke.points.count {
                let a = stroke.points[i - 1], b = stroke.points[i]
                var seg = Path()
                seg.move(to: CGPoint(x: a.x * size.width, y: a.y * size.height))
                seg.addLine(to: CGPoint(x: b.x * size.width, y: b.y * size.height))
                let w = max(1.4, baseW * (0.5 + 0.95 * ((a.p + b.p) * 0.5)))
                ctx.stroke(seg, with: .color(color), style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

private struct ScreenAnnotationToolbarView: View {
    @ObservedObject var model: ScreenAnnotator.Model
    var huionConnected: () -> Bool
    var onTogglePassThrough: () -> Void
    var onClear: () -> Void
    var onSendBluey: () -> Void
    var onSendHermes: () -> Void
    var onSaveNote: () -> Void
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let started = model.recordingStartedAt {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    HStack(spacing: 5) {
                        Circle().fill(Color(hex: 0xEF4444)).frame(width: 7, height: 7)
                        Text(InkDrawing.formatVideoTime(ctx.date.timeIntervalSince(started)))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(hex: 0xEF4444).opacity(0.24), in: Capsule())
                }
            }
            // Color dots
            HStack(spacing: 6) {
                ForEach(ScreenAnnotator.Model.palette, id: \.hex) { entry in
                    Button {
                        model.selectedColor = entry.hex
                        if model.passThrough { onTogglePassThrough() }
                    } label: {
                        Circle()
                            .fill(Color(hexString: entry.hex))
                            .frame(width: 16, height: 16)
                            .overlay(Circle().stroke(.white, lineWidth: model.selectedColor == entry.hex ? 2.2 : 0))
                    }
                    .buttonStyle(.plain)
                    .help(entry.name)
                }
            }

            Divider().frame(height: 20).overlay(.white.opacity(0.2))

            // Pen / Highlighter / Laser
            toolbarIcon(model.tool == .highlighter ? "highlighter" : "pencil.tip",
                        active: model.tool == .highlighter,
                        help: "Textmarker umschalten") {
                model.tool = model.tool == .pen ? .highlighter : .pen
            }
            toolbarIcon("sparkles", active: model.laserFade, help: "Laser-Modus (Striche blenden nach 2s aus)") {
                model.laserFade.toggle()
            }
            toolbarIcon(model.passThrough ? "cursorarrow.click.2" : "hand.draw",
                        active: model.passThrough,
                        help: "Klick-Durchlass (Apps bedienen, Zeichnung bleibt sichtbar)") {
                onTogglePassThrough()
            }
            toolbarIcon("arrow.uturn.backward", active: false, help: "Rückgängig (⌘Z)") { model.undo() }
            toolbarIcon("trash", active: false, help: "Alles löschen") { onClear() }

            Divider().frame(height: 20).overlay(.white.opacity(0.2))

            // Optional question + Send to Bluey / Hermes / Note
            TextField("Frage an Bluey…", text: $model.prompt)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .frame(width: 150)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
                .onSubmit { onSendBluey() }

            Button {
                onSendBluey()
            } label: {
                Label("Bluey", systemImage: "paperplane.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(hex: 0x2563EB), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(model.busy)
            .help("Markierten Bildschirm direkt an Bluey Chat senden")

            Button {
                onSendHermes()
            } label: {
                Text("✦ Hermes")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(model.busy)
            .help("Annotierten Screenshot an Hermes senden")

            toolbarIcon("note.text.badge.plus", active: false, help: "Als Notiz speichern") { onSaveNote() }

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("Schließen (Esc)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(hex: 0x0F172A).opacity(0.92), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
    }

    private func toolbarIcon(_ name: String, active: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(active ? Color(hex: 0x38BDF8) : .white.opacity(0.85))
                .frame(width: 26, height: 26)
                .background(active ? Color(hex: 0x38BDF8).opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private extension Color {
    init(hexString: String) {
        let cleaned = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if cleaned.count == 6, let val = UInt32(cleaned, radix: 16) {
            self.init(hex: val)
        } else {
            self = .white
        }
    }
}
