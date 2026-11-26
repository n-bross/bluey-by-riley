import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

@main
struct GooglyApp: App {
    @UIApplicationDelegateAdaptor(OrientationDelegate.self) private var orientation
    var body: some Scene {
        WindowGroup {
            AppShell()
        }
    }
}

/// Controls orientation for the Hub and the explicit avatar preview.
final class OrientationDelegate: NSObject, UIApplicationDelegate {
    static var mask: UIInterfaceOrientationMask = .allButUpsideDown
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.mask
    }

    static func lock(_ mask: UIInterfaceOrientationMask, prefer: UIInterfaceOrientationMask) {
        Self.mask = mask
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: prefer)) { _ in }
        }
    }
}

/// The Bluey app on the iPhone: workspace in portrait, face in landscape.
/// Owns the Mac link, voice, focus and workspace so they keep running whichever screen is showing.
struct AppShell: View {
    @StateObject private var link = MacLink()
    @StateObject private var live = LiveVoice()
    @StateObject private var store = SessionStore()
    @StateObject private var focus = FocusClient()
    @StateObject private var call = CallSession()
    @State private var showCall = false
    @State private var workspace: PhoneWorkspace?
    @State private var animator = FaceAnimator()
    @State private var showFace = false
    @State private var showFocus = false
    @State private var scanPairing = false
    @State private var showSettings = false
    @AppStorage("workspaceTab") private var tabRaw = WorkspaceTab.chat.rawValue
    @StateObject private var hermes = HermesClient()
    @State private var showHermes = false
    @StateObject private var hub = HubClient()
    @State private var showHub = false
    @State private var testingAvatar = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let workspace {
                WorkspaceRootView(
                    model: workspace.model,
                    tab: Binding(get: { workspaceTab }, set: { tabRaw = $0.rawValue }),
                    connectionName: link.macName ?? link.currentMac,
                    face: { Color.black },
                    settings: { settings },
                    showSettings: $showSettings)
            } else {
                Color.black
            }
        }
        .fullScreenCover(isPresented: $showCall) {
            CallView(call: call) { showCall = false; call.reset() }
        }
        .onOpenURL { url in
            guard url.scheme == "bluey" else { return }
            switch url.host {
            case "call":
                // From the Live Activity: open a call (or the running one).
                showFace = false
                startCall(threadID: nil)
            case "pomodoro":
                showFace = false; showSettings = false
                tabRaw = WorkspaceTab.pomodoro.rawValue
            default:
                break
            }
        }
        .fullScreenCover(isPresented: $showFace, onDismiss: { testingAvatar = false }) {
            FaceScreen(link: link, live: live, focus: focus, hermes: hermes, animator: animator,
                       showFocus: $showFocus, scanPairing: $scanPairing, testingAvatar: $testingAvatar,
                       openHermes: { showFace = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showHermes = true } },
                       openHub: { showFace = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showHub = true } },
                       close: { showFace = false })
        }
        // Hermes (through the Mac) and the hub (chats, todos and notes without the Mac).
        .fullScreenCover(isPresented: $showHermes) { HermesView(hermes: hermes, link: link) }
        .fullScreenCover(isPresented: $showHub, onDismiss: { OrientationLock.set(.portrait) }) {
            HubRootView(hub: hub) { showHub = false }
        }
        // While his face is up, it presents these itself.
        .sheet(isPresented: Binding(get: { scanPairing && !showFace }, set: { scanPairing = $0 })) { QRPairingView(link: link) }
        .sheet(isPresented: Binding(get: { showFocus && !showFace }, set: { showFocus = $0 })) { FocusDashboard(focus: focus, link: link) }
        .onAppear {
            start()
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            updateFaceForOrientation()
        }
        .onDisappear {
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            updateFaceForOrientation()
        }
        .onChange(of: link.connected) { _, connected in
            focus.connectionChanged(connected)
            workspace?.connectionChanged(connected)
            if !connected { live.sleep() }
            if connected {
                hermes.sync()
                NotesSync.retryPending(store: store, link: link)
                store.resyncRecent()
            }
        }
        .onChange(of: focus.history.count) { _, _ in workspace?.model.focusHistory = focus.history }
        .onChange(of: focus.current) { _, current in workspace?.model.currentFocus = current }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                link.start()
                updateFaceForOrientation()
                if !call.isActive { BlueyLiveActivity.endAll() }
            } else {
                // Leaving the app: Bluey waits on the Lock Screen and in the Dynamic Island.
                // A running pomodoro has its own Live Activity; one is enough.
                if !call.isActive, !PomodoroLiveActivity.isShowing { BlueyLiveActivity.show(.ready) }
                // A call keeps running (voice, screen sharing and the Mac link) while you're in other apps.
                guard !call.isActive else { return }
                focus.command("focusPause")
                live.sleep()
                if phase == .background { link.stop() }
            }
        }
    }

    private var workspaceTab: WorkspaceTab {
        let tab = WorkspaceTab(rawValue: tabRaw) ?? .chat
        return tab == .face ? .chat : tab
    }

    private func updateFaceForOrientation() {
        let orientation = UIDevice.current.orientation
        if orientation.isPortrait {
            showFace = false
        } else if orientation.isLandscape,
                  !showSettings, !showCall, !showHub, !showHermes, !scanPairing, !showFocus {
            showFace = true
        }
    }

    private var settings: some View {
        BlueyAppView(store: store, live: live, link: link, focus: focus,
                     openHermes: { showSettingsThen { showHermes = true } },
                     openHub: { showSettingsThen { showHub = true } },
                     openFocus: { showSettingsThen { showFocus = true } },
                     pairMac: { showSettingsThen { scanPairing = true } },
                     testAvatar: { showSettingsThen { testingAvatar = true; showFace = true } }) { showSettings = false }
    }

    private func showSettingsThen(_ action: @escaping () -> Void) {
        showSettings = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: action)
    }

    /// Opens the call screen and starts a call for a chat (or shows the call that's already running).
    private func startCall(threadID: UUID?) {
        showCall = true
        guard !call.isActive else { return }
        if live.state != .asleep { live.sleep() }
        let context = workspace?.model.thread(threadID).map { thread in
            thread.messages.suffix(12).map { ($0.role == .user ? "User: " : "Bluey: ") + $0.text.prefix(600) }.joined(separator: "\n")
        }
        call.start(threadID: threadID, context: context)
    }

    private func wireCall(workspace: PhoneWorkspace) {
        call.requestToken = { [link] context, done in
            link.request(Packet(command: "callToken", text: context)) { reply in done(reply?.text) }
        }
        call.runCallTurn = { [link] audioWAV, text, done in
            link.request(Packet(command: "callTurn", audio: audioWAV?.base64EncodedString(), text: text)) { reply in
                let parsed: VoiceTurnReply
                if let raw = reply?.text, let data = raw.data(using: .utf8),
                   let decoded = try? JSONDecoder().decode(VoiceTurnReply.self, from: data) {
                    parsed = decoded
                } else {
                    parsed = VoiceTurnReply(reply: reply?.text ?? "")
                }
                let audio = reply?.audio.flatMap { Data(base64Encoded: $0) }
                done(parsed, audio)
            }
        }
        call.runTool = { [link] name, arguments, done in
            link.request(Packet(command: "tool", tool: name, text: arguments)) { reply in
                done(reply?.text ?? "The Mac didn't answer.", reply?.image)
            }
        }
        call.onChange = { [call] in BlueyLiveActivity.update(from: call) }
        call.onEnded = { [weak model = workspace.model, call] threadID, lines in
            model?.appendCall(threadID: threadID, lines: lines.map { ($0.fromUser, $0.text) }, started: call.startedAt ?? Date())
            BlueyLiveActivity.endAll()
        }
        workspace.model.startCall = { threadID in startCall(threadID: threadID) }
    }

    private func start() {
        guard workspace == nil else { return }
        let workspace = PhoneWorkspace(link: link)
        wireCall(workspace: workspace)
        workspace.model.focusHistory = focus.history
        workspace.model.focusCommand = { [focus] command, task, minutes in
            focus.command(command, task: task, minutes: minutes)
            return ""
        }
        workspace.model.onPomodoro = { [weak model = workspace.model] in
            if let model { PomodoroLiveActivity.update(from: model.snapshot) }
        }
        PomodoroLiveActivity.update(from: workspace.model.snapshot)
        self.workspace = workspace
        focus.attach(link)
        hermes.attach(link)
        focus.onFinished = { showFocus = true; live.sleep() }
        link.onFocusState = { [focus] in focus.receive($0) }
        link.onFace = { [animator] face in animator.receive(face, at: Date().timeIntervalSinceReferenceDate) }
        animator.localTalk = { [live] in live.level }
        wireLiveVoice(workspace: workspace)
        link.start()
    }

    /// Connects the live voice to the Mac: keys, tools, captions and wake/sleep.
    private func wireLiveVoice(workspace: PhoneWorkspace) {
        live.requestToken = { [link] done in
            link.request(Packet(command: "realtimeToken")) { reply in done(reply?.text) }
        }
        live.runVoiceTurn = { [link] audioWAV, text, done in
            link.request(Packet(command: "voiceTurn", audio: audioWAV?.base64EncodedString(), text: text)) { reply in
                if let raw = reply?.text, let data = raw.data(using: .utf8),
                   let decoded = try? JSONDecoder().decode(VoiceTurnReply.self, from: data) {
                    done(decoded)
                } else {
                    done(VoiceTurnReply(reply: reply?.text ?? "Der Mac hat nicht geantwortet."))
                }
            }
        }
        live.runTool = { [link] name, arguments, done in
            link.request(Packet(command: "tool", tool: name, text: arguments)) { reply in
                done(reply?.text ?? "The Mac didn't answer.", reply?.image)
            }
        }
        live.onSessionStart = { [store] in store.start() }
        live.resumeContext = { [store] in store.recentText() }
        live.recorder.onChunk = { [store, link] chunk in
            store.addPending(chunk.sessionID, index: chunk.index, started: chunk.started)
            NotesSync.upload(chunk.sessionID, index: chunk.index, started: chunk.started, store: store, link: link)
        }
        store.onSync = { [store, link] sessions in NotesSync.send(sessions, store: store, link: link) }
        live.onSessionEnd = { [store] in store.end() }
        live.onUserTurn = { [store] item, asked in store.placeholder(itemID: item, asked: asked) }
        live.onUserWords = { [store] item, text, asked in store.heard(itemID: item, text: text, asked: asked) }
        live.onReply = { [store] text in store.reply(text) }
        live.onReport = { [store] text in store.report(text) }
        live.onCaption = { [link] text, finished in
            link.send(Packet(command: finished ? "captionDone" : "caption", text: text))
        }
        live.onStateChange = { [link, animator] state in
            switch state {
            case .asleep:
                animator.awake = false
                animator.localMood = nil
                link.send(Packet(command: "asleep"))
            case .waking:
                animator.awake = true
                animator.localMood = .happy
            case .listening:
                animator.awake = true
                animator.localMood = nil
                link.send(Packet(command: "awake"))
            case .asking:
                animator.awake = true
                animator.localMood = .listening  // all ears while you hold
                link.send(Packet(command: "awake"))
            case .thinking:
                animator.localMood = .thinking
            case .speaking:
                animator.localMood = .talking
            }
        }
        live.onCodexNote = { [store] text in store.codex(text) }
        link.onCommand = { [live, focus, workspace, hermes, hub] command, text in
            if workspace.receive(command: command, text: text) { return }
            switch command {
            case "hermesState": hermes.receive(text ?? "")
            case "hermesChirp": live.focusChirp()
            case "hubConfig":
                // The paired Mac shares where the hub is (over the encrypted link).
                if let data = text?.data(using: .utf8), let config = try? JSONDecoder().decode(HubConfig.self, from: data) {
                    hub.configure(config)
                }
            case "wake": live.wake()
            case "sleep": live.sleep()
            case "codexNote": live.codexNote(text ?? "")
            case "codexChirp": live.chirpAlone()
            case "focusChirp":
                focus.receivedNudge(text ?? "Are you sure you're on task right now?")
                live.focusChirp()
            default: break
            }
        }
    }
}

/// His face, full screen and sideways under the Mac monitor: eyes follow your mouse, hold to talk.
struct FaceScreen: View {
    @ObservedObject var link: MacLink
    @ObservedObject var live: LiveVoice
    @ObservedObject var focus: FocusClient
    @ObservedObject var hermes: HermesClient
    let animator: FaceAnimator
    @Binding var showFocus: Bool
    @Binding var scanPairing: Bool
    @Binding var testingAvatar: Bool
    var openHermes: () -> Void
    var openHub: () -> Void
    var close: () -> Void
    @AppStorage(AvatarStyle.defaultsKey) private var avatar: AvatarStyle = .keramik3D
    @State private var avatarReaction: KeramikReaction?
    @State private var testMood: String?
    @State private var showPairing = true
    @State private var holdStart: DispatchWorkItem?
    @State private var holdingToAsk = false
    @State private var locksPreviewOrientation = false

    var body: some View {
        ZStack {
            Group {
                switch avatar {
                case .bluey: FaceView(animator: animator)
                case .keramik: KeramikFace(animator: animator, reaction: avatarReaction, moodOverride: testMood)
                case .keramik3D: KeramikFace(animator: animator, reaction: avatarReaction, moodOverride: testMood, model3D: true)
                }
            }
            .allowsHitTesting(false)
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { live.toggle() }  // double tap: wake up / back to follow mode
                .simultaneousGesture(holdToAsk)

            if testingAvatar && avatar != .bluey {
                AvatarTestBar(mood: $testMood, react: react) {
                    testingAvatar = false
                    testMood = nil
                }
            }

            ModeIndicator(state: live.state)

            FocusFaceHUD(focus: focus, link: link, live: live, open: { showFocus = true }, pair: { scanPairing = true })
            SoundButton(link: link, live: live)

            // Back to the app: chat, todos, notes, pomodoro and statistics.
            Button(action: close) {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.35))
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.white.opacity(0.06)).frame(width: 34, height: 34))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Zurück zur App")
            .padding(.top, 10)
            .padding(.trailing, 62)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

            // Hermes: turns yellow while Hermes waits for an approval or an answer.
            Button(action: openHermes) {
                let waiting = !hermes.waiting.isEmpty
                Image(systemName: waiting ? "exclamationmark.bubble.fill" : "sparkles")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(waiting ? Color.black : .white.opacity(0.35))
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(waiting ? Color(hex: 0xFFD66B) : Color.white.opacity(0.06)).frame(width: 34, height: 34))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(hermes.waiting.isEmpty ? "Open Hermes" : "Hermes is waiting for you")
            .padding(.top, 10)
            .padding(.trailing, 108)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

            if showPairing && !link.connected {
                PairingView(onPlay: { withAnimation(.easeOut(duration: 0.3)) { showPairing = false; scanPairing = true } },
                            openHub: openHub, openWorkspace: close)
                    .transition(.opacity)
            }
        }
        .background(Color.black)
        .ignoresSafeArea()
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .sheet(isPresented: $showFocus) { FocusDashboard(focus: focus, link: link) }
        .sheet(isPresented: $scanPairing) { QRPairingView(link: link) }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            locksPreviewOrientation = testingAvatar
            if locksPreviewOrientation {
                OrientationDelegate.lock(.landscape, prefer: .landscapeRight)
            }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            if locksPreviewOrientation {
                OrientationDelegate.lock(.allButUpsideDown, prefer: .portrait)
            }
        }
        .onChange(of: link.connected) { _, connected in
            if connected { withAnimation(.easeOut(duration: 0.4)) { showPairing = false } }
        }
        .onChange(of: focus.history.count) { old, new in if new > old { react("confetti") } }
    }

    private func react(_ name: String) {
        avatarReaction = KeramikReaction(name, id: (avatarReaction?.id ?? 0) + 1)
    }

    /// Press and hold the screen to ask him something; let go and he answers.
    private var holdToAsk: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard holdStart == nil, !holdingToAsk else { return }
                let work = DispatchWorkItem {
                    holdingToAsk = true
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    live.beginAsk()
                }
                holdStart = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)  // a quick tap isn't a hold
            }
            .onEnded { _ in
                holdStart?.cancel()
                holdStart = nil
                if holdingToAsk {
                    holdingToAsk = false
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    live.endAsk()
                }
            }
    }
}

/// The user's Keramik avatar, driven by the same animator moods as Bluey's face.
struct KeramikFace: View {
    let animator: FaceAnimator
    var reaction: KeramikReaction?
    /// A mood picked on the test bar wins over the live one.
    var moodOverride: String?
    var model3D = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
            let frame = animator.step(timeline.date.timeIntervalSinceReferenceDate)
            KeramikAvatarView(mood: moodOverride ?? KeramikMapping.mood(frame.mood), gaze: frame.gaze, reaction: reaction,
                              zoom: model3D ? 1.0 : 1.4, model3D: model3D)
        }
        .background(Color.black)
        .ignoresSafeArea()
    }
}

/// Buttons along the bottom of the face to try every mood and reaction of the Keramik avatar.
struct AvatarTestBar: View {
    @Binding var mood: String?
    var react: (String) -> Void
    var close: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            row {
                ForEach(KeramikTest.moods, id: \.id) { item in
                    chip(item.title, on: mood == item.id) { mood = item.id }
                }
                chip("Live", on: mood == nil) { mood = nil }
            }
            row {
                ForEach(KeramikTest.reactions, id: \.id) { item in
                    chip(item.title, on: false) { react(item.id) }
                }
            }
            HStack(spacing: 6) {
                row {
                    ForEach(KeramikTest.activities + KeramikTest.power, id: \.id) { item in
                        chip(item.title, on: false) { react(item.id) }
                    }
                }
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 30, height: 30).background(Circle().fill(Color.white.opacity(0.18)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close avatar test")
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    /// One scrolling row of chips (there are more than fit across the screen).
    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 6) { content() } }
    }

    private func chip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(on ? .black : .white)
                .padding(.horizontal, 10).frame(height: 30)
                .background(Capsule().fill(on ? Color.white : Color.white.opacity(0.18)))
        }
        .buttonStyle(.plain)
    }
}

/// Keeps the existing solid listening border. The compact status icon lives with the controls.
struct ModeIndicator: View {
    let state: LiveVoice.State
    private var color: Color {
        switch state {
        case .asleep: return .clear
        case .waking: return Color(hex: 0xFFD66B)
        case .listening, .asking: return Color(hex: 0x4F8BFF)
        case .thinking: return Color(hex: 0xC79BFF)
        case .speaking: return Color(hex: 0xFF9AD0)
        }
    }
    private var border: CGFloat {
        switch state {
        case .asleep: return 0
        case .waking: return 6
        case .listening: return 10
        case .asking: return 16
        case .thinking, .speaking: return 8
        }
    }
    private var pulse: Double {
        switch state {
        case .waking: return 1.6
        case .asking: return 1.2
        case .thinking: return 1.1
        default: return 0
        }
    }
    private static let screenCornerRadius: CGFloat = {
        if let radius = UIScreen.main.value(forKey: "_displayCornerRadius") as? CGFloat, radius > 0 { return radius }
        return 55
    }()
    var body: some View {
        TimelineView(.animation(paused: pulse == 0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let wave = pulse > 0 ? 0.5 + 0.5 * sin(t * pulse * 2 * .pi) : 1
            RoundedRectangle(cornerRadius: Self.screenCornerRadius, style: .continuous)
                .strokeBorder(color, lineWidth: border)
                .opacity(pulse > 0 ? 0.65 + 0.35 * wave : 1)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.25), value: state)
    }
}
