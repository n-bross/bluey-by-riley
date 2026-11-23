import AppKit
import SwiftUI
import GooglyShared

/// Bluey without the phone: he sits in the MacBook's notch. Collapsed, his little face peeks out to the left
/// of the notch (eyes on your mouse) and the right side shows what's going on (focus countdown, listening,
/// Hermes waiting). Hover and it drops open: type or talk to him, start focus, see Hermes.
/// Voice runs right here on the Mac with the same Realtime session the phone uses; his tools run locally.
@MainActor
final class NotchModel: ObservableObject {
    @Published var gazeX = 0.0
    @Published var gazeY = 0.0
    @Published var talk = 0.0
    @Published var mood: Mood = .listening
    @Published var voice: LiveVoice.State = .asleep
    @Published var inputLevel = 0.0
    @Published var caption = ""
    @Published var heard = ""
    @Published var focus: FocusSession?
    @Published var rest: PomodoroBreak?
    @Published var pomodoro = PomodoroRhythm()
    @Published var completedRounds = 0
    @Published var showSettings = false
    /// Bumped to put the cursor in the text field (the type shortcut).
    @Published var focusRequest = 0
    @Published var hermesWaiting: [(run: HermesRun, prompt: HermesPrompt)] = []
    @Published var hermesBusy = false
    @Published var expanded = false
    /// 0 = slim bar, 1 = open panel. Driven by NotchController's own spring at 60 fps (SwiftUI animations
    /// don't play reliably in this menu-bar-level panel), so opening and closing always morph smoothly.
    @Published var progress: CGFloat = 0
    @Published var draft = ""
    @Published var notchWidth: CGFloat = 180
    @Published var notchHeight: CGFloat = 32
    /// Width to keep clear in the middle: the notch, or another app's island in it (e.g. Vorssaint).
    @Published var islandWidth: CGFloat = 180

    /// Another app already sits in the notch, so Bluey sits beside it instead of over it.
    var sharesNotch: Bool { islandWidth > notchWidth + 4 }

    /// Width of each wing beside the notch: room for the face, wider while a timer shows.
    var sideWidth: CGFloat { (focus.map { $0.status != .ended } == true || rest != nil) ? 76 : 50 }
    /// The collapsed bar: notch (or another app's island) plus a wing on each side.
    var collapsedWidth: CGFloat { islandWidth + sideWidth * 2 }

    /// Something worth showing on the right (otherwise that wing stays away).
    /// Only things worth covering menu bar icons for: a timer, a break, Hermes waiting, you talking.
    var hasStatus: Bool {
        !hermesWaiting.isEmpty || voice == .asking || rest != nil || focus.map { $0.status != .ended } == true
    }

    /// Small dot on his face: listening (cyan) or thinking / Hermes working (pulsing white).
    var faceBadge: Color? {
        if voice == .thinking || voice == .waking || hermesBusy { return .white }
        if voice != .asleep { return Color(nsColor: NSColor(hex: Keramik.glow)) }
        return nil
    }

    var send: ((String) -> Void)?
    var toggleTalk: (() -> Void)?
    var focusAction: ((String) -> Void)?
    var respondHermes: ((String, String, String) -> Void)?
    var sleepVoice: (() -> Void)?
    var setPomodoro: ((PomodoroRhythm) -> Void)?
    var openSettings: (() -> Void)?
    var close: (() -> Void)?

    static let wing: CGFloat = 38
    /// The window's size; the black panel inside it is only as tall as its content.
    static let expandedSize = CGSize(width: 520, height: 340)
    /// How tall the open panel draws: room for a Hermes card only when one is waiting.
    var expandedHeight: CGFloat { notchHeight + 140 + (hermesWaiting.isEmpty ? 0 : 52) + (showSettings ? 46 : 0) }
}

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class NotchController {
    let model = NotchModel()
    let voice = LiveVoice()
    private var panel: NotchPanel?
    private var hover: Timer?
    private var hoverSince: Date?
    private var leftSince: Date?
    private var lastActivity = Date()

    private let host: RealtimeHost
    private let focus: FocusCompanion
    private let hermes: HermesGateway

    init(host: RealtimeHost, focus: FocusCompanion, hermes: HermesGateway) {
        self.host = host; self.focus = focus; self.hermes = hermes
    }

    var isListening: Bool { voice.state != .asleep }
    /// Hidden with the hide shortcut.
    private var hidden = false
    /// Not needed right now: he's on the phone or the external monitor instead.
    private var suppressed = false

    /// True when an external display is connected (you're at your desk, not just on the laptop).
    static var externalDisplayConnected: Bool {
        NSScreen.screens.contains { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
            return CGDisplayIsBuiltin(id) == 0
        }
    }

    /// Hidden: the notch goes back to a plain notch. Pomodoro announcements still drop it open briefly.
    func setHidden(_ hidden: Bool) {
        self.hidden = hidden
        applyVisibility()
    }

    /// The bar only shows when he isn't visible elsewhere (phone connected or external monitor in use).
    func setSuppressed(_ suppressed: Bool) {
        guard self.suppressed != suppressed else { return }
        self.suppressed = suppressed
        applyVisibility()
    }

    private func applyVisibility() {
        if hidden || suppressed { setExpanded(false); panel?.orderOut(nil) } else { panel?.orderFrontRegardless() }
    }

    func start() {
        wireVoice()
        model.send = { [weak self] text in self?.ask(text) }
        model.toggleTalk = { [weak self] in self?.toggleTalk() }
        model.sleepVoice = { [weak self] in self?.voice.sleep() }
        model.close = { [weak self] in self?.setExpanded(false) }
        model.setPomodoro = { [weak self] settings in
            guard let self else { return }
            self.model.pomodoro = settings
            self.focus.setPomodoro(settings)
        }
        model.focusAction = { [weak self] action in self?.focusAction(action) }
        model.respondHermes = { [weak self] run, prompt, choice in
            Task { _ = await self?.hermes.respond(runID: run, promptID: prompt, choice: choice) }
        }
        makePanel()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.makePanel() }
        }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        hover = timer
        if ProcessInfo.processInfo.environment["GOOGLY_DEMO_POMODORO"] != nil {
            // Demo: a break in progress with the timer settings open.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                _ = self.focus.takeBreak()
                self.model.showSettings = true
            }
        }
        if let demo = ProcessInfo.processInfo.environment["GOOGLY_DEMO_NOTCH_ASK"] {
            // Demo: asks a typed question a moment after launch.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.ask(demo) }
        }
    }

    func stop() {
        hover?.invalidate(); hover = nil
        panel?.orderOut(nil); panel = nil
        voice.sleep()
    }

    // MARK: Feeding him

    func face(_ face: FaceState) {
        model.gazeX = face.gazeX; model.gazeY = face.gazeY; model.talk = face.talk; model.mood = face.mood
    }

    func update(focus session: FocusSession?, sync: FocusSync? = nil) {
        model.focus = session
        guard let sync else { return }
        model.rest = sync.rest
        if let p = sync.pomodoro, p != model.pomodoro { model.pomodoro = p }
        model.completedRounds = sync.completedRounds ?? 0
    }

    /// A Pomodoro moment: show it in the notch and drop it open for a few seconds.
    func announce(_ text: String) {
        model.caption = text
        guard !suppressed else { return }  // the phone or the monitor shows it
        if hidden {
            // Timers matter even while he's hidden: show it, then tuck away again.
            panel?.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard let self, self.hidden else { return }
                self.setExpanded(false); self.panel?.orderOut(nil)
            }
        }
        setExpanded(true)
        leftSince = Date().addingTimeInterval(6)
    }

    func refreshHermes() {
        model.hermesWaiting = hermes.waitingForYou
        model.hermesBusy = hermes.runs.contains { $0.isActive }
    }

    /// News from Codex or Hermes: he says it himself if he's awake. Returns false if he isn't.
    func deliver(_ note: String) -> Bool {
        guard isListening else { return false }
        voice.codexNote(note)
        return true
    }

    // MARK: Voice on the Mac

    private func wireVoice() {
        voice.requestToken = { [weak self] done in
            guard let self else { done(nil); return }
            self.host.handle(Packet(command: "realtimeToken")) { reply in done(reply.text) }
        }
        voice.runTool = { [weak self] name, arguments, done in
            guard let self else { done("Bluey closed.", nil); return }
            self.host.handle(Packet(command: "tool", tool: name, text: arguments)) { reply in
                done(reply.text ?? "No result.", reply.image)
            }
        }
        voice.onCaption = { [weak self] text, finished in
            guard let self else { return }
            self.host.handle(Packet(command: finished ? "captionDone" : "caption", text: text)) { _ in }
            if !text.isEmpty { self.model.caption = text }
            self.lastActivity = Date()
        }
        voice.onUserWords = { [weak self] _, text, _ in self?.model.heard = text }
        voice.onStateChange = { [weak self] state in
            guard let self else { return }
            self.model.voice = state
            self.lastActivity = Date()
            switch state {
            case .asleep: self.host.handle(Packet(command: "asleep")) { _ in }
            case .listening, .asking: self.host.handle(Packet(command: "awake")) { _ in }
            default: break
            }
        }
    }

    /// Push to talk: start holding (the talk shortcut, or the mic button) …
    func beginTalk() {
        lastActivity = Date()
        voice.beginAsk()
    }

    /// … and let go to send.
    func endTalk() { voice.endAsk() }

    private func toggleTalk() {
        if voice.state == .asking { endTalk() } else { beginTalk() }
    }

    func ask(_ text: String) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        lastActivity = Date()
        model.heard = words
        model.caption = ""
        voice.askText(words)
    }

    private func focusAction(_ action: String) {
        let result: String
        switch action {
        case "break": result = focus.takeBreak()
        case "skipBreak": result = focus.skipBreak()
        case "next":
            guard let task = focus.lastTask else { model.caption = "Type what you're working on, then press Focus."; return }
            result = focus.start(task: task)
        case "pause": result = focus.pause()
        case "resume": result = focus.resume()
        case "end": result = focus.end()
        default:
            // Start: a typed task goes through him, so durations ("for 45 minutes") are understood.
            let task = model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
            if task.isEmpty { model.caption = "Type what you're working on, then press Focus."; return }
            model.draft = ""
            ask("Start a focus session: " + task)
            return
        }
        model.caption = result
    }

    // MARK: The panel

    private func screenGeometry() -> (screen: NSScreen, notch: CGRect)? {
        guard let screen = NSScreen.screens.first else { return nil }
        let f = screen.frame
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea, screen.safeAreaInsets.top > 0 {
            // AppKit coordinates (origin bottom-left).
            let width = right.minX - left.maxX
            let height = screen.safeAreaInsets.top
            return (screen, CGRect(x: f.minX + left.maxX, y: f.maxY - height, width: width, height: height))
        }
        // No notch (external display): pretend there's a small one in the middle of the menu bar.
        let height = NSStatusBar.system.thickness
        return (screen, CGRect(x: f.midX - 90, y: f.maxY - height, width: 180, height: height))
    }

    private func makePanel() {
        guard let (_, notch) = screenGeometry() else { return }
        model.notchWidth = notch.width
        model.islandWidth = max(model.islandWidth, notch.width)
        model.notchHeight = notch.height
        let size = NotchModel.expandedSize
        let frame = CGRect(x: notch.midX - size.width / 2, y: notch.maxY - size.height, width: size.width, height: size.height)
        if let panel { panel.setFrame(frame, display: true); return }
        let panel = NotchPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Above the menu bar, but just below other notch apps (Vorssaint's island draws over the middle of the bar).
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        let hosting = NSHostingView(rootView: NotchView(model: model))
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private var lastIslandScan = Date.distantPast

    /// Other apps' windows sitting in the notch (an island like Vorssaint's), as one width centred on it.
    private func scanIsland(notch: CGRect, screen: NSScreen) {
        guard Date().timeIntervalSince(lastIslandScan) > 2 else { return }
        lastIslandScan = Date()
        let me = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var reach = notch.width / 2
        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? Int32) != me,
                  (w[kCGWindowLayer as String] as? Int ?? 0) >= 25,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let width = b["Width"], let height = b["Height"],
                  y <= 1, height <= notch.height + 12, width < screen.frame.width * 0.6 else { continue }
            let midX = notch.midX - screen.frame.minX
            guard x < midX + notch.width, x + width > midX - notch.width else { continue }
            reach = max(reach, midX - x, x + width - midX)
        }
        let width = min(reach * 2, 420)
        if abs(width - model.islandWidth) > 1 { model.islandWidth = width }
    }

    /// Hover tracking (20 Hz): opens when the mouse rests on him, closes a moment after it leaves.
    private func tick() {
        guard let panel, panel.isVisible, let (screen, notch) = screenGeometry() else { return }
        scanIsland(notch: notch, screen: screen)
        let mouse = NSEvent.mouseLocation
        // Only Bluey's own wings count, so the notch (or another app's island) stays clickable.
        let half = model.islandWidth / 2
        let leftWing = CGRect(x: notch.midX - half - model.sideWidth, y: notch.minY, width: model.sideWidth, height: notch.height)
        let rightWing = CGRect(x: notch.midX + half, y: notch.minY, width: model.sideWidth, height: notch.height)
        let overWing = leftWing.contains(mouse) || rightWing.contains(mouse)
        let collapsed = overWing ? notch.insetBy(dx: -500, dy: 0) : .zero
        var open = panel.frame.insetBy(dx: 6, dy: 0)
        open.origin.y = open.maxY - model.expandedHeight
        open.size.height = model.expandedHeight
        let inside = model.expanded ? open.contains(mouse) : collapsed.contains(mouse) && mouse.y >= notch.minY - 2
        let now = Date()
        if inside {
            leftSince = nil
            if !model.expanded {
                if hoverSince == nil { hoverSince = now }
                if now.timeIntervalSince(hoverSince!) > 0.18 { setExpanded(true) }
            }
        } else {
            hoverSince = nil
            if model.expanded {
                if leftSince == nil { leftSince = now }
                if panel.isKeyWindow {
                    // Typing (like Spotlight): stays open until you click elsewhere or press Esc.
                    leftSince = now
                } else if now.timeIntervalSince(leftSince!) > 0.7, voice.state != .asking {
                    setExpanded(false)
                }
            }
        }
        if ProcessInfo.processInfo.environment["GOOGLY_DEMO_NOTCH_OPEN"] != nil {
            // Screenshot demo: stays open with a sample reply.
            if !model.expanded { setExpanded(true); model.heard = "What's on my calendar today?"; model.caption = "Two things: stand-up at 10 and a dentist at 4. Plenty of room to focus in between." }
            leftSince = nil
        }
        panel.ignoresMouseEvents = !(model.expanded || inside)
        model.inputLevel = voice.inputLevel
        // Mic off again when he's been idle for a while, so the Mac's mic light doesn't stay on.
        if voice.state == .listening, now.timeIntervalSince(lastActivity) > 180 { voice.sleep() }
    }

    // MARK: The morph

    private var springTimer: Timer?
    private var velocity: CGFloat = 0
    private var lastSpringTick = CACurrentMediaTime()

    /// A slightly bouncy spring (like Apple's notch animations) from the current progress to the target.
    private func animateProgress() {
        guard springTimer == nil else { return }
        lastSpringTick = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.stepSpring() }
        }
        RunLoop.main.add(timer, forMode: .common)
        springTimer = timer
    }

    private func stepSpring() {
        let now = CACurrentMediaTime()
        var dt = CGFloat(min(1.0 / 30, now - lastSpringTick))
        lastSpringTick = now
        let target: CGFloat = model.expanded ? 1 : 0
        let stiffness: CGFloat = model.expanded ? 260 : 340   // closing is a touch quicker
        let damping: CGFloat = model.expanded ? 24 : 34       // opening overshoots a hair, closing doesn't
        var x = model.progress
        // Small sub-steps keep the integration stable.
        while dt > 0 {
            let h = min(dt, 1.0 / 240)
            let accel = stiffness * (target - x) - damping * velocity
            velocity += accel * h
            x += velocity * h
            dt -= h
        }
        if abs(target - x) < 0.001, abs(velocity) < 0.01 {
            x = target; velocity = 0
            springTimer?.invalidate(); springTimer = nil
        }
        model.progress = max(-0.02, min(1.04, x))
    }

    private func setExpanded(_ open: Bool) {
        guard model.expanded != open else { return }
        model.expanded = open
        animateProgress()
        if open { refreshHermes() } else {
            panel?.resignKey()
            // Opened on purpose while he's hidden or elsewhere: tuck away again once the close animation ran.
            if hidden || suppressed {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                    guard let self, !self.model.expanded, self.hidden || self.suppressed else { return }
                    self.panel?.orderOut(nil)
                }
            }
        }
    }

    /// Opens the panel and puts the cursor in the text field (menu item / hotkey).
    func openForTyping() {
        panel?.orderFrontRegardless()  // also while the bar is stepped aside for the phone or monitor
        setExpanded(true)
        leftSince = Date().addingTimeInterval(8)
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
        // After the panel is key and the field exists (it appears with the open animation).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.panel?.makeKey()
            self?.model.focusRequest += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self?.writeStatus() }
        }
    }

    /// ~/Library/Application Support/Googly/notch-status.json: whether his field has the keyboard (for checks).
    private func writeStatus() {
        let info: [String: Any] = ["expanded": model.expanded, "panelIsKey": panel?.isKeyWindow == true,
                                   "firstResponder": String(describing: type(of: panel?.firstResponder as Any)),
                                   "hidden": hidden, "updatedAt": Date().timeIntervalSince1970]
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Googly/notch-status.json")
        if let data = try? JSONSerialization.data(withJSONObject: info) { try? data.write(to: url, options: .atomic) }
    }

    /// True while his text field has the keyboard (for tests and the hover logic).
    var isTyping: Bool { panel?.isKeyWindow == true && model.expanded }
}

// MARK: - SwiftUI

// Color(hex:) and Font.fredoka come from App/BlobShape.swift (shared with the phone).

/// The notch's own shape: square top (it merges into the bezel), rounded bottom corners.
private struct NotchShape: Shape {
    var radius: CGFloat
    var animatableData: CGFloat { get { radius } set { radius = newValue } }
    func path(in r: CGRect) -> Path {
        var p = Path()
        let top: CGFloat = 6  // tiny outward flare where it meets the bezel, like the real notch
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + top, y: r.minY + top), control: CGPoint(x: r.minX + top, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + top, y: r.maxY - radius))
        p.addQuadCurve(to: CGPoint(x: r.minX + top + radius, y: r.maxY), control: CGPoint(x: r.minX + top, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - top - radius, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - top, y: r.maxY - radius), control: CGPoint(x: r.maxX - top, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - top, y: r.minY + top))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - top, y: r.minY))
        p.closeSubpath()
        return p
    }
}

/// His face in the Keramik look: a white ceramic head, a black visor and two softly glowing eyes that
/// follow the gaze and blink. Talking adds a little smile; thinking narrows the eyes.
struct KeramikFace: View {
    var gazeX: Double
    var gazeY: Double
    var talk: Double
    var mood: Mood

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let blink = t.truncatingRemainder(dividingBy: 4.6) < 0.12
            Canvas { ctx, size in
                let w = size.width, h = size.height
                let bounce = 1 + talk * 0.05 * (0.5 + 0.5 * sin(t * 16))
                let head = CGRect(x: w * 0.04, y: h * 0.04, width: w * 0.92, height: h * 0.92 * bounce)
                let shell = Path(roundedRect: head, cornerRadius: min(head.width, head.height) * 0.42, style: .continuous)
                ctx.fill(shell, with: .linearGradient(Gradient(colors: [Color(hex: Keramik.ceramic), Color(hex: Keramik.ceramicShade)]),
                                                      startPoint: CGPoint(x: head.midX, y: head.minY), endPoint: CGPoint(x: head.midX, y: head.maxY)))
                ctx.stroke(shell, with: .color(Color(hex: Keramik.rim)), lineWidth: max(0.6, w * 0.02))
                let visor = head.insetBy(dx: head.width * 0.11, dy: head.height * 0.17)
                ctx.fill(Path(roundedRect: visor, cornerRadius: visor.height * 0.45, style: .continuous), with: .color(Color(hex: Keramik.visor)))
                let eyeW = visor.width * 0.16
                let eyeH = visor.height * (mood == .thinking ? 0.32 : 0.5) * (blink ? 0.14 : 1)
                for cx in [visor.minX + visor.width * 0.34, visor.minX + visor.width * 0.66] {
                    let x = cx + CGFloat(gazeX) * visor.width * 0.06 - eyeW / 2
                    let y = visor.midY - visor.height * 0.06 + CGFloat(gazeY) * visor.height * 0.08 - eyeH / 2
                    let eye = Path(roundedRect: CGRect(x: x, y: y, width: eyeW, height: eyeH), cornerRadius: eyeW / 2)
                    var glow = ctx
                    glow.addFilter(.blur(radius: max(1, w * 0.04)))
                    glow.fill(eye, with: .color(Color(hex: Keramik.glowSoft).opacity(0.9)))
                    ctx.fill(eye, with: .color(.white))
                }
                if mood == .happy || talk > 0.05 {
                    var smile = Path()
                    let sw = visor.width * 0.16 * (1 + talk * 0.3)
                    smile.move(to: CGPoint(x: visor.midX - sw / 2, y: visor.maxY - visor.height * 0.24))
                    smile.addQuadCurve(to: CGPoint(x: visor.midX + sw / 2, y: visor.maxY - visor.height * 0.24),
                                       control: CGPoint(x: visor.midX, y: visor.maxY - visor.height * 0.06))
                    ctx.stroke(smile, with: .color(.white), style: StrokeStyle(lineWidth: max(0.8, w * 0.03), lineCap: .round))
                }
            }
        }
    }
}

struct NotchView: View {
    @ObservedObject var model: NotchModel
    @FocusState private var typing: Bool

    var body: some View {
        // One continuous black shape that morphs between the slim bar and the open panel, so opening and closing
        // is a single fluid spring instead of swapping views. Collapsed it is symmetric around the notch: the face
        // on the left wing, the status on the right. Another app's island (Vorssaint) sits above the middle.
        let p = model.progress
        let width = model.collapsedWidth + (NotchModel.expandedSize.width - model.collapsedWidth) * p
        let height = model.notchHeight + (model.expandedHeight - model.notchHeight) * max(0, p)
        let radius = model.notchHeight * 0.36 + (24 - model.notchHeight * 0.36) * min(1, max(0, p))
        ZStack(alignment: .top) {
            NotchShape(radius: radius)
                .fill(Color.black)
                .frame(width: width, height: height)
                .shadow(color: .black.opacity(0.35 * Double(min(1, max(0, p)))), radius: 18, y: 8)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    face
                        .frame(width: model.sideWidth, alignment: .leading)
                    Spacer(minLength: 0)
                    status
                        .frame(width: model.sideWidth - 10, alignment: .trailing)
                        .padding(.trailing, 10)
                }
                .frame(width: width, height: model.notchHeight)
                if p > 0.45 {
                    // The content fades and slides in during the second half of the morph.
                    let t = Double(min(1, (p - 0.45) / 0.5))
                    panel
                        .frame(width: NotchModel.expandedSize.width)
                        .opacity(t)
                        .offset(y: CGFloat(1 - t) * -10)
                }
            }
            .frame(width: width, height: height, alignment: .top)
            .clipShape(NotchShape(radius: radius))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
    }

    /// His face, fully inside the left wing.
    private var face: some View {
        KeramikFace(gazeX: model.gazeX, gazeY: model.gazeY, talk: model.talk, mood: model.mood)
            .frame(width: 28, height: model.notchHeight - 8)
            .overlay(alignment: .bottomTrailing) {
                if let badge = model.faceBadge {
                    Circle().fill(badge).frame(width: 6, height: 6)
                        .overlay(Circle().stroke(Color.black, lineWidth: 1.5))
                        .offset(x: 2, y: 1)
                }
            }
            .padding(.leading, 12)
    }

    @ViewBuilder private var status: some View {
        if !model.hermesWaiting.isEmpty {
            Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(Color(hex: Keramik.amber))
                .font(.system(size: 13, weight: .bold))
        } else if model.voice == .asking {
            HStack(spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule().fill(Color.white)
                        .frame(width: 3, height: 4 + CGFloat(model.inputLevel) * CGFloat([10, 14, 12, 8][i]))
                }
            }
        } else if let rest = model.rest {
            HStack(spacing: 3) {
                Image(systemName: "cup.and.saucer.fill").font(.system(size: 9, weight: .bold))
                Text(FocusSession.clock(rest.remaining)).font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            .foregroundStyle(Color(hex: Keramik.green))
        } else if let session = model.focus, session.status != .ended {
            Text((session.status == .paused ? "Ⅱ " : "") + FocusSession.clock(session.remaining))
                .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(.white)
        }
    }

    // MARK: Expanded

    private var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                KeramikFace(gazeX: model.gazeX, gazeY: model.gazeY, talk: model.talk, mood: model.mood)
                    .frame(width: 70, height: 60)
                VStack(alignment: .leading, spacing: 4) {
                    if !model.heard.isEmpty {
                        Text(model.heard).font(.system(size: 11)).foregroundStyle(Color(hex: 0xAEAEB2)).lineLimit(1)
                    }
                    Text(model.caption.isEmpty ? greeting : model.caption)
                        .font(.fredoka(15)).foregroundStyle(.white)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Text(statusLine).font(.system(size: 10, design: .monospaced)).foregroundStyle(Color(hex: 0xAEAEB2))
                }
                Spacer(minLength: 0)
            }
            ForEach(model.hermesWaiting.prefix(1), id: \.prompt.id) { item in hermesCard(item.run, item.prompt) }
            if model.showSettings {
                PomodoroControls(settings: model.pomodoro, change: { model.setPomodoro?($0) }, openSettings: { model.openSettings?() })
            }
            HStack(spacing: 8) {
                TextField("Ask Bluey, tell Hermes, or type a task…", text: $model.draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .focused($typing)
                    .onChange(of: model.focusRequest) { _, _ in typing = true }
                    .onExitCommand { model.close?() }
                    .onSubmit { let t = model.draft; model.draft = ""; model.send?(t) }
                circle(model.voice == .asking ? "stop.fill" : "mic.fill", tint: model.voice == .asking ? Color(hex: Keramik.red) : Color(hex: Keramik.accent),
                       help: "Talk" + (ShortcutStore.get(.talk).map { " (or hold \($0.display))" } ?? "")) { model.toggleTalk?() }
                focusButtons
                circle("timer", tint: model.showSettings ? Color(hex: Keramik.accent) : Color.white.opacity(0.12), help: "Pomodoro timer settings") {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { model.showSettings.toggle() }
                }
                if model.voice != .asleep {
                    circle("moon.zzz.fill", tint: Color.white.opacity(0.12), help: "Stop listening") { model.sleepVoice?() }
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 4)
        .padding(.bottom, 16)
        .frame(width: NotchModel.expandedSize.width)
    }

    private var greeting: String {
        if model.voice == .thinking || model.voice == .waking { return "Hmm, one moment…" }
        let talk = ShortcutStore.get(.talk)?.display
        if model.voice == .asleep { return talk.map { "Hiya! Type below, or hold \($0) and talk." } ?? "Hiya! Type below, or tap the mic." }
        return talk.map { "I'm listening. Hold \($0) or tap the mic." } ?? "I'm listening. Tap the mic to talk."
    }

    private var statusLine: String {
        var parts: [String] = []
        if let s = model.focus, s.status != .ended {
            let round = model.pomodoro.enabled ? " · round \(model.completedRounds + 1)/\(model.pomodoro.roundsBeforeLongBreak)" : ""
            parts.append("\(s.status == .paused ? "Paused" : "Focus"): \(s.task.prefix(34)) · \(FocusSession.clock(s.remaining))\(round)")
        } else if let r = model.rest {
            parts.append("\(r.title) · \(FocusSession.clock(r.remaining))" + (r.task.isEmpty ? "" : " · then \(r.task.prefix(30))"))
        } else if model.pomodoro.enabled {
            parts.append("Pomodoro \(Int(model.pomodoro.focusMinutes))/\(Int(model.pomodoro.shortBreakMinutes))")
        }
        if model.hermesBusy { parts.append("Hermes working…") }
        switch model.voice {
        case .asking: parts.append("Listening…")
        case .thinking: parts.append("Thinking…")
        case .waking: parts.append("Waking up…")
        default: break
        }
        return parts.joined(separator: "  ·  ")
    }

    @ViewBuilder private var focusButtons: some View {
        if let s = model.focus, s.status != .ended {
            circle(s.status == .running ? "pause.fill" : "play.fill", tint: Color.white.opacity(0.12),
                   help: s.status == .running ? "Pause focus" : "Resume focus") { model.focusAction?(s.status == .running ? "pause" : "resume") }
            circle("stop.circle.fill", tint: Color.white.opacity(0.12), help: "End focus") { model.focusAction?("end") }
            if model.pomodoro.enabled {
                circle("cup.and.saucer.fill", tint: Color.white.opacity(0.12), help: "Take a break now") { model.focusAction?("break") }
            }
        } else if model.rest != nil {
            circle("forward.end.fill", tint: Color(hex: Keramik.green).opacity(0.75), help: "Skip the break") { model.focusAction?("skipBreak") }
        } else {
            circle("scope", tint: Color.white.opacity(0.12), help: "Start focus on the typed task (empty: next round of the last task)") {
                model.focusAction?(model.draft.trimmingCharacters(in: .whitespaces).isEmpty ? "next" : "start")
            }
        }
    }

    private func circle(_ icon: String, tint: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                .frame(width: 34, height: 34).background(Circle().fill(tint))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func hermesCard(_ run: HermesRun, _ prompt: HermesPrompt) -> some View {
        HStack(spacing: 8) {
            Image(systemName: prompt.kind == .approval ? "exclamationmark.shield.fill" : "questionmark.bubble.fill")
                .foregroundStyle(Color(hex: Keramik.amber))
            Text((prompt.kind == .approval ? "Hermes wants to run: " : "Hermes asks: ") + prompt.text)
                .font(.system(size: 11)).foregroundStyle(.white).lineLimit(2)
            Spacer(minLength: 4)
            if prompt.kind == .approval {
                Button("Allow") { model.respondHermes?(run.id, prompt.id, prompt.choices.contains("once") ? "once" : "session") }
                Button("Deny") { model.respondHermes?(run.id, prompt.id, "deny") }
            } else {
                Text("Answer below").font(.system(size: 10)).foregroundStyle(Color(hex: 0xAEAEB2))
            }
        }
        .controlSize(.small)
        .padding(8)
        .background(Color(hex: 0x2C2C2E), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Pomodoro in the notch, kept simple: on/off and the rhythm as chips. Everything else is in Settings.
struct PomodoroControls: View {
    let settings: PomodoroRhythm
    let change: (PomodoroRhythm) -> Void
    var openSettings: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { settings.enabled }, set: { var s = settings; s.enabled = $0; change(s) }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
            Text("Pomodoro").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
            Spacer(minLength: 4)
            ForEach(PomodoroRhythm.presets, id: \.name) { preset in
                let on = settings.enabled && settings.sameRhythm(preset.settings)
                Button {
                    var s = preset.settings
                    s.autoStartBreaks = settings.autoStartBreaks; s.autoStartFocus = settings.autoStartFocus
                    change(s)
                } label: {
                    Text(preset.name.split(separator: " ", maxSplits: 1).last.map(String.init) ?? preset.name)
                        .font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(on ? Color(hex: Keramik.visor) : .white)
                        .padding(.horizontal, 9).frame(height: 24)
                        .background(Capsule().fill(on ? Color.white : Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .disabled(!settings.enabled)
            }
            Button(action: openSettings) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 24, height: 24).background(Circle().fill(Color.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .help("All timer settings")
        }
        .padding(.horizontal, 10).frame(height: 38)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
