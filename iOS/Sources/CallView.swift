import SwiftUI
import ReplayKit
import ActivityKit

/// The call screen: Bluey big in the middle, what he says, and glass buttons for mute, screen sharing and hanging up.
struct CallView: View {
    @ObservedObject var call: CallSession
    var close: () -> Void

    private var mood: Mood {
        switch call.phase {
        case .connecting: return .resting
        case .listening: return .listening
        case .hearing: return .listening
        case .thinking: return .thinking
        case .speaking: return .talking
        case .idle, .ended: return .sleepy
        }
    }

    private var status: String {
        switch call.phase {
        case .idle, .connecting: return "Verbinde…"
        case .listening: return call.sharing ? "Sieht deinen Bildschirm · hört zu" : "Hört zu"
        case .hearing: return "Hört dir zu…"
        case .thinking: return "Denkt nach…"
        case .speaking: return "Spricht"
        case .ended: return call.error ?? "Anruf beendet"
        }
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: Palette.berry4).opacity(0.55), .black, .black], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 18) {
                Spacer(minLength: 30)
                BlueyAvatar(mood: mood)
                    .frame(width: 190, height: 170)
                    .scaleEffect(1 + call.level * 0.08)
                    .animation(.easeOut(duration: 0.12), value: call.level)
                Text("Bluey").font(.fredoka(34)).foregroundStyle(.white)
                HStack(spacing: 8) {
                    if call.sharing {
                        Image(systemName: "record.circle").foregroundStyle(Theme.red)
                    }
                    Text(status)
                    if let started = call.startedAt, call.isActive {
                        Text("·")
                        Text(started, style: .timer).monospacedDigit()
                    }
                }
                .font(.plexSans(15))
                .foregroundStyle(Theme.soft)

                // Your voice level: shows the microphone really hears you.
                if call.isActive, !call.muted {
                    HStack(spacing: 4) {
                        ForEach(0..<5, id: \.self) { i in
                            Capsule()
                                .fill(Color.white.opacity(call.micLevel > Double(i) * 0.18 + 0.04 ? 0.9 : 0.2))
                                .frame(width: 5, height: 8 + CGFloat(i % 3) * 6)
                        }
                    }
                    .animation(.easeOut(duration: 0.1), value: call.micLevel)
                    .accessibilityHidden(true)
                }

                ScrollView {
                    VStack(spacing: 10) {
                        if !call.heard.isEmpty {
                            Text(call.heard).font(.plexSans(14)).foregroundStyle(Theme.soft).multilineTextAlignment(.center)
                        }
                        if !call.caption.isEmpty {
                            Text(call.caption).font(.plexSans(18)).foregroundStyle(.white).multilineTextAlignment(.center)
                        }
                    }
                    .padding(.horizontal, 28)
                }
                .frame(maxHeight: 220)

                Spacer()

                if call.isActive, !call.sharing {
                    Text("Tipp auf „Teilen“ und wähle Bluey. Dann kannst du in jede App wechseln und ihm zeigen, was du meinst.")
                        .font(.plexSans(12)).foregroundStyle(Theme.soft).multilineTextAlignment(.center).padding(.horizontal, 34)
                }
                controls
                    .padding(.bottom, 24)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(false)
    }

    private var controls: some View {
        GlassGroup(spacing: 24) {
            HStack(spacing: 26) {
                control(icon: call.muted ? "mic.slash.fill" : "mic.fill", title: call.muted ? "Stumm" : "Mikro",
                        tint: call.muted ? Color.white.opacity(0.85) : nil, foreground: call.muted ? .black : .white) {
                    call.muted.toggle()
                }
                .disabled(!call.isActive)

                VStack(spacing: 8) {
                    ZStack {
                        Image(systemName: "rectangle.inset.filled.and.person.filled")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 74, height: 74)
                            .glassCircle(tint: call.sharing ? Theme.green.opacity(0.7) : nil)
                            .allowsHitTesting(false)
                        BroadcastPicker()
                            .frame(width: 74, height: 74)
                            .opacity(0.02)
                    }
                    Text(call.sharing ? "Geteilt" : "Teilen").font(.plexSans(12)).foregroundStyle(Theme.soft)
                }
                .accessibilityLabel("Bildschirm teilen")

                if call.isActive {
                    control(icon: "phone.down.fill", title: "Auflegen", tint: Theme.red.opacity(0.9)) { call.end() }
                } else {
                    control(icon: "xmark", title: "Schließen") { close() }
                }
            }
        }
    }

    private func control(icon: String, title: String, tint: Color? = nil, foreground: Color = .white, action: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            GlassIconButton(icon: icon, label: title, size: 74, tint: tint, foreground: foreground, action: action)
            Text(title).font(.plexSans(12)).foregroundStyle(Theme.soft)
        }
    }
}

/// The system screen-broadcast button, preset to Bluey's extension (iOS always asks to confirm).
struct BroadcastPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 74, height: 74))
        picker.preferredExtension = Bundle.main.object(forInfoDictionaryKey: "BlueyBroadcastExtension") as? String
        picker.showsMicrophoneButton = false
        for case let button as UIButton in picker.subviews {
            button.frame = picker.bounds
            button.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        }
        return picker
    }
    func updateUIView(_ view: RPSystemBroadcastPickerView, context: Context) {
        for case let button as UIButton in view.subviews { button.frame = view.bounds }
    }
}

/// The Live Activity: "Bluey fragen" when you leave the app, the call's status while one runs.
@MainActor
enum BlueyLiveActivity {
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "liveActivity") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "liveActivity"); if !newValue { endAll() } }
    }

    private static var current: Activity<BlueyCallAttributes>? { Activity<BlueyCallAttributes>.activities.first }

    /// Shows or updates the activity.
    static func show(_ state: BlueyCallAttributes.ContentState) {
        guard enabled, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let content = ActivityContent(state: state, staleDate: nil)
        if let current {
            Task { await current.update(content) }
        } else {
            _ = try? Activity.request(attributes: BlueyCallAttributes(), content: content, pushType: nil)
        }
    }

    static func update(from call: CallSession) {
        guard current != nil || call.isActive else { return }
        let phase: BlueyCallAttributes.ContentState.Phase = {
            switch call.phase {
            case .idle: return .ready
            case .connecting: return .connecting
            case .listening, .hearing: return .listening
            case .thinking: return .thinking
            case .speaking: return .speaking
            case .ended: return .ready
            }
        }()
        let caption = String(call.caption.suffix(120))
        show(BlueyCallAttributes.ContentState(phase: phase, callStarted: call.isActive ? call.startedAt : nil,
                                              sharingScreen: call.sharing, caption: call.isActive ? caption : ""))
    }

    static func endAll() {
        for activity in Activity<BlueyCallAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
