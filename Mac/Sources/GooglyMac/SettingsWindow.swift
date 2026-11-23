import AppKit
import SwiftUI
import GooglyShared

/// Everything the settings window reads and changes. The app wires the actions in.
@MainActor
final class SettingsModel: ObservableObject {
    let settings = Settings.shared
    let focus: FocusCompanion
    let hermes: HermesGateway

    var applyNotchMode: () -> Void = {}
    var setAvatarWindow: (Bool) -> Void = { _ in }
    var registerShortcuts: () -> [ShortcutAction] = { [] }
    var pairPhone: () -> Void = {}
    var editPersonality: () -> Void = {}
    var allowComputerControl: () -> Void = {}
    var computerControlChanged: () -> Void = {}
    var activityRunning: () -> Bool = { false }
    var startActivityWatch: () -> Void = {}

    @Published var recording: ShortcutAction?
    @Published var refused: Set<ShortcutAction> = []
    @Published var shortcutNote = ""
    @Published var hermesNote = ""
    @Published var keyNote = ""
    @Published var journalNote = ""
    var journal: ActivityJournal?
    var sendHubToPhone: () -> String = { "" }
    @Published var hubNote = ""
    private var monitor: Any?

    init(focus: FocusCompanion, hermes: HermesGateway) {
        self.focus = focus; self.hermes = hermes
    }

    /// A binding that writes through and refreshes the window.
    func bind<T>(_ get: @escaping () -> T, _ set: @escaping (T) -> Void) -> Binding<T> {
        Binding(get: get, set: { [weak self] value in set(value); self?.objectWillChange.send() })
    }

    var pomodoro: PomodoroSettings { focus.pomodoro }

    func setPomodoro(_ p: PomodoroSettings) { focus.setPomodoro(p); objectWillChange.send() }

    // MARK: Shortcut recording

    func record(_ action: ShortcutAction) {
        stopRecording(register: false)
        recording = action
        shortcutNote = "Press the new shortcut for “\(action.title)”. Esc cancels, ⌫ turns it off."
        HotKeys.shared.unregisterAll()  // so pressing an existing combination doesn't trigger it
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let action = self.recording else { return event }
            switch Int(event.keyCode) {
            case 53: self.shortcutNote = ""                                  // Esc
            case 51, 117: ShortcutStore.set(action, nil); self.shortcutNote = "\(action.title): off."  // ⌫ / ⌦
            default:
                guard let shortcut = Shortcut(event: event) else {
                    self.shortcutNote = "Use at least one of ⌃ ⌥ ⌘ (or a function key)."
                    return nil
                }
                if let other = ShortcutStore.conflict(shortcut, except: action) {
                    ShortcutStore.set(other, nil)
                    self.shortcutNote = "\(shortcut.display) moved here from “\(other.title)” (now off)."
                } else { self.shortcutNote = "\(action.title): \(shortcut.display)" }
                ShortcutStore.set(action, shortcut)
            }
            self.stopRecording(register: true)
            return nil
        }
    }

    func stopRecording(register: Bool = true) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording != nil || register {
            recording = nil
            refused = Set(registerShortcuts())
            if !refused.isEmpty { shortcutNote = "macOS refused: " + refused.map(\.title).joined(separator: ", ") + ". Another app may own that combination." }
        }
    }

    func resetShortcuts() {
        ShortcutStore.resetAll()
        stopRecording(register: true)
        shortcutNote = "Back to the defaults."
    }
}

final class SettingsWindowController {
    private var window: NSWindow?
    private let model: SettingsModel

    init(model: SettingsModel) { self.model = model }

    @MainActor func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(model: model))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Bluey Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 680, height: 600))
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        model.objectWillChange.send()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Views

private extension Color {
    init(hex: UInt32) { self.init(nsColor: NSColor(hex: hex)) }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    /// GOOGLY_DEMO_SETTINGS=<0…4> opens a tab directly (for screenshots).
    @State private var tab = Int(ProcessInfo.processInfo.environment["GOOGLY_DEMO_SETTINGS"] ?? "") ?? 0

    var body: some View {
        TabView(selection: $tab) {
            GeneralPane(model: model).tabItem { Label("General", systemImage: "gearshape") }.tag(0)
            ShortcutsPane(model: model).tabItem { Label("Shortcuts", systemImage: "command") }.tag(1)
            FocusPane(model: model).tabItem { Label("Focus", systemImage: "timer") }.tag(2)
            JournalPane(model: model).tabItem { Label("Journal", systemImage: "book.closed") }.tag(3)
            HermesPane(model: model).tabItem { Label("Hermes", systemImage: "sparkles") }.tag(4)
            AccountPane(model: model).tabItem { Label("Account", systemImage: "key") }.tag(5)
        }
        .frame(width: 680, height: 600)
        .onDisappear { model.stopRecording(register: model.recording != nil) }
    }
}

private struct GeneralPane: View {
    @ObservedObject var model: SettingsModel
    private var s: Settings { model.settings }

    var body: some View {
        Form {
            Section("Where he lives") {
                Toggle("Bluey in the notch (works without the phone)", isOn: model.bind({ s.notchMode }, { s.notchMode = $0; model.applyNotchMode() }))
                Toggle("Floating Keramik avatar window", isOn: model.bind({ s.showAvatarWindow }, { s.showAvatarWindow = $0; model.setAvatarWindow($0) }))
                Toggle("Eyes follow my mouse when idle", isOn: model.bind({ s.followMouse }, { s.followMouse = $0 }))
                HStack {
                    Text("Phone sits under")
                    Spacer()
                    Picker("", selection: model.bind({ Int((s.phonePosition * 100).rounded()) }, { s.phonePosition = Double($0) / 100 })) {
                        Text("Left").tag(20); Text("Center").tag(50); Text("Right").tag(80)
                    }
                    .pickerStyle(.segmented).frame(width: 220).labelsHidden()
                }
                Button("Pair iPhone (QR)…", action: model.pairPhone)
            }
            Section("Pointer") {
                Picker("Style", selection: model.bind({ s.pointerStyle }, { s.pointerStyle = $0 })) {
                    ForEach(PointerStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Size", selection: model.bind({ Int(s.cursorSize) }, { s.cursorSize = Double($0) })) {
                    Text("Small").tag(48); Text("Medium").tag(72); Text("Large").tag(96); Text("Huge").tag(120)
                }
                .pickerStyle(.segmented)
                if s.pointerStyle == .blueberry {
                    Picker("Trail", selection: model.bind({ s.trail }, { s.trail = $0 })) {
                        ForEach(PointerTrail.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
                Toggle("Show the pointer", isOn: model.bind({ s.showCursor }, { s.showCursor = $0 }))
            }
            Section("Computer control") {
                Toggle("Let him click, type and open things when I ask", isOn: model.bind({ s.computerControl }, { s.computerControl = $0; model.computerControlChanged() }))
                if s.computerControl && !ComputerControl.isTrusted {
                    HStack {
                        Label("Needs Accessibility permission", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Spacer()
                        Button("Allow…", action: model.allowComputerControl)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ShortcutsPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                ForEach(ShortcutAction.allCases) { action in
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(action.title)
                            Text(action.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.refused.contains(action) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                .help("macOS didn't accept this combination. Pick another one.")
                        }
                        Button { model.record(action) } label: {
                            Text(model.recording == action ? "Press keys…" : (ShortcutStore.get(action)?.display ?? "Off"))
                                .font(.system(.body, design: .rounded).weight(.medium))
                                .frame(minWidth: 96)
                        }
                        .buttonStyle(.bordered)
                        .tint(model.recording == action ? Color(hex: Keramik.accent) : nil)
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if !model.shortcutNote.isEmpty { Text(model.shortcutNote).foregroundStyle(.secondary) }
                    Text("Click a shortcut, then press the new combination. Shortcuts work everywhere, even when Bluey isn't in front.")
                        .foregroundStyle(.secondary)
                    Button("Reset to defaults", action: model.resetShortcuts)
                }
                .font(.caption)
            }
        }
        .formStyle(.grouped)
    }
}

private struct FocusPane: View {
    @ObservedObject var model: SettingsModel
    private var p: PomodoroSettings { model.pomodoro }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "timer").font(.title2).foregroundStyle(Color(hex: Keramik.accent))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pomodoro").font(.headline)
                        Text(p.enabled ? "Bluey sends you on a break after every round." : "Off: focus sessions just end.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: model.bind({ p.enabled }, { var s = p; s.enabled = $0; model.setPomodoro(s) }))
                        .toggleStyle(.switch).labelsHidden()
                }
                if p.enabled {
                    HStack(spacing: 10) {
                        ForEach(PomodoroSettings.presets, id: \.name) { preset in PresetCard(preset: preset, model: model) }
                    }
                    .padding(.vertical, 4)
                    CycleBar(settings: p).frame(height: 30).padding(.vertical, 2)
                }
            }
            if p.enabled {
                Section("Times") {
                    MinuteRow(title: "Focus round", value: p.focusMinutes, range: 1...240, step: 5) { var s = p; s.focusMinutes = $0; model.setPomodoro(s) }
                    MinuteRow(title: "Short break", value: p.shortBreakMinutes, range: 1...60, step: 1) { var s = p; s.shortBreakMinutes = $0; model.setPomodoro(s) }
                    MinuteRow(title: "Long break", value: p.longBreakMinutes, range: 1...120, step: 5) { var s = p; s.longBreakMinutes = $0; model.setPomodoro(s) }
                    Stepper(value: model.bind({ p.roundsBeforeLongBreak }, { var s = p; s.roundsBeforeLongBreak = $0; model.setPomodoro(s) }), in: 1...12) {
                        HStack { Text("Long break after"); Spacer(); Text("\(p.roundsBeforeLongBreak) rounds").monospacedDigit().foregroundStyle(.secondary) }
                    }
                }
                Section("Flow") {
                    Toggle("Start breaks automatically", isOn: model.bind({ p.autoStartBreaks }, { var s = p; s.autoStartBreaks = $0; model.setPomodoro(s) }))
                    Toggle("Start the next round automatically", isOn: model.bind({ p.autoStartFocus }, { var s = p; s.autoStartFocus = $0; model.setPomodoro(s) }))
                    Text("Off is gentler: after a break Bluey asks before he starts watching the screen again.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Testing") {
                Toggle("Developer Mode (4× clock, checks every 10 s)", isOn: model.bind({ model.focus.developerMode }, { model.focus.setDeveloperMode($0) }))
            }
        }
        .formStyle(.grouped)
    }
}

/// One preset as a card: big rhythm, small name, highlighted when it's the current one.
private struct PresetCard: View {
    let preset: (name: String, settings: PomodoroSettings)
    @ObservedObject var model: SettingsModel

    var body: some View {
        let selected = model.pomodoro.sameRhythm(preset.settings)
        let parts = preset.name.split(separator: " ", maxSplits: 1).map(String.init)
        Button {
            var s = preset.settings
            s.autoStartBreaks = model.pomodoro.autoStartBreaks; s.autoStartFocus = model.pomodoro.autoStartFocus
            model.setPomodoro(s)
        } label: {
            VStack(spacing: 4) {
                Text(parts.count > 1 ? parts[1] : preset.name).font(.system(size: 17, weight: .semibold, design: .rounded))
                Text(parts.first ?? "").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? Color(hex: Keramik.accent).opacity(0.14) : Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Color(hex: Keramik.accent) : Color.primary.opacity(0.1), lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The whole cycle at a glance: focus rounds in blue, short breaks green, the long break teal.
private struct CycleBar: View {
    let settings: PomodoroSettings

    var body: some View {
        let rounds = settings.roundsBeforeLongBreak
        var segments: [(minutes: Double, color: Color, label: String)] = []
        for i in 1...rounds {
            segments.append((settings.focusMinutes, Color(hex: Keramik.accent), "\(Int(settings.focusMinutes))"))
            segments.append(i == rounds ? (settings.longBreakMinutes, Color(hex: 0x40C8E0), "\(Int(settings.longBreakMinutes))")
                                        : (settings.shortBreakMinutes, Color(hex: Keramik.green), "\(Int(settings.shortBreakMinutes))"))
        }
        let total = segments.map(\.minutes).reduce(0, +)
        return VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                        RoundedRectangle(cornerRadius: 4).fill(seg.color.opacity(0.85))
                            .frame(width: max(3, (geo.size.width - CGFloat(segments.count) * 2) * seg.minutes / total))
                            .overlay(Text(seg.label).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.5))
                    }
                }
            }
            Text("One cycle: \(ActivitySummary.duration(total * 60)) · focus \(ActivitySummary.duration(settings.focusMinutes * Double(rounds) * 60))")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct MinuteRow: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let set: (Double) -> Void

    var body: some View {
        Stepper(value: Binding(get: { value }, set: { set(min(range.upperBound, max(range.lowerBound, $0))) }), in: range, step: step) {
            HStack { Text(title); Spacer(); Text("\(Int(value)) min").monospacedDigit().foregroundStyle(.secondary) }
        }
    }
}

/// What Bluey writes down about your day, and what goes to Hermes.
private struct JournalPane: View {
    @ObservedObject var model: SettingsModel
    private var s: Settings { model.settings }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "book.closed").font(.title2).foregroundStyle(Color(hex: Keramik.accent))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Daily journal").font(.headline)
                        Text("A timeline of what you worked on, built from ActivityWatch, focus sessions and Hermes requests. Ask Bluey “what did I do today?”")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: model.bind({ s.journalEnabled }, { s.journalEnabled = $0 })).toggleStyle(.switch).labelsHidden()
                }
                HStack {
                    Text("Saved in ~/Documents/Bluey Journal, one file per day")
                    Spacer()
                    Button("Open Folder") {
                        try? FileManager.default.createDirectory(at: ActivityJournal.folder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(ActivityJournal.folder)
                    }
                }
            }
            Section {
                Toggle("Send each day to Hermes", isOn: model.bind({ s.journalToHermes }, { s.journalToHermes = $0 }))
                Picker("Send today's journal from", selection: model.bind({ s.journalHour }, { s.journalHour = $0 })) {
                    ForEach(12..<24) { Text(String(format: "%02d:00", $0)).tag($0) }
                }
                .disabled(!s.journalToHermes)
                HStack {
                    Button("Send today now") {
                        Task {
                            model.journalNote = "Sending…"
                            model.journalNote = await model.journal?.send(day: Date()) ?? "Journal unavailable."
                        }
                    }
                    .disabled(!model.hermes.available)
                    if !model.journalNote.isEmpty { Text(model.journalNote).font(.caption).foregroundStyle(.secondary) }
                }
            } header: {
                Text("Hermes")
            } footer: {
                Text("Each day goes to Hermes once, in its own session, so Hermes can answer questions about your days later. Days the Mac was off are sent the next time Bluey runs. Window titles are included; they stay between Bluey, the journal files and your Hermes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct HermesPane: View {
    @ObservedObject var model: SettingsModel
    @State private var url = HermesGateway.config()?.url.absoluteString ?? "http://127.0.0.1:8642"
    @State private var key = ""

    var body: some View {
        Form {
            Section("Connection") {
                HStack {
                    Circle().fill(model.hermes.available ? Color(hex: Keramik.green) : Color(hex: Keramik.amber)).frame(width: 8, height: 8)
                    Text(model.hermes.available ? "Connected" : (model.hermes.problem ?? "Not connected"))
                    Spacer()
                    Button("Test") {
                        Task { await model.hermes.refresh(); model.hermesNote = model.hermes.available ? "Hermes answered." : (model.hermes.problem ?? "No answer."); model.objectWillChange.send() }
                    }
                }
                TextField("API server", text: $url)
                SecureField(HermesGateway.config() == nil ? "API key (API_SERVER_KEY)" : "Key saved. Paste a new one to replace it.", text: $key)
                Button("Save") {
                    let newKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let k = newKey.isEmpty ? HermesGateway.config()?.key : newKey else { model.hermesNote = "Paste the key first."; return }
                    HermesGateway.saveConfig(url: url.trimmingCharacters(in: .whitespacesAndNewlines), key: k)
                    key = ""
                    Task { await model.hermes.refresh(); model.hermesNote = model.hermes.available ? "Saved and connected." : "Saved, but Hermes didn't answer."; model.objectWillChange.send() }
                }
                if !model.hermesNote.isEmpty { Text(model.hermesNote).font(.caption).foregroundStyle(.secondary) }
            }
            Section {
                Picker("Risky steps", selection: model.bind({ model.hermes.mode }, { model.hermes.mode = $0 })) {
                    ForEach(HermesApprovalMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Hermes' own policy runs first (smart mode settles clear cases itself); this decides what happens with the rest.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                TextField("https://shipyard-1.your-tailnet.ts.net:8790", text: model.bind({ HubSettings.url }, { HubSettings.url = $0 }))
                SecureField("Key (optional with Tailscale)", text: model.bind({ HubSettings.key }, { HubSettings.key = $0 }))
                HStack {
                    Button("Test") { Task { model.hubNote = "Testing…"; model.hubNote = await HubNotesAPI.health() } }
                    Button("Send to iPhone") { model.hubNote = model.sendHubToPhone() }
                    Spacer()
                }
                if !model.hubNote.isEmpty { Text(model.hubNote).font(.caption).foregroundStyle(.secondary) }
            } header: { Text("Bluey Hub") } footer: {
                Text("Your hub runs next to Hermes on your server (notes, todos and chats without the laptop). Over Tailscale your login is enough. The phone gets this address automatically when it connects.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("ActivityWatch") {
                HStack {
                    Circle().fill(model.activityRunning() ? Color(hex: Keramik.green) : Color(hex: Keramik.amber)).frame(width: 8, height: 8)
                    Text(model.activityRunning() ? "Tracking active time" : "Not running")
                    Spacer()
                    if !model.activityRunning() { Button("Start", action: model.startActivityWatch) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AccountPane: View {
    @ObservedObject var model: SettingsModel
    @State private var key = ""

    var body: some View {
        Form {
            Section("OpenAI") {
                SecureField(Keychain.get(.openai) == nil ? "sk-…" : "Key saved. Paste a new one to replace it.", text: $key)
                HStack {
                    Button("Save key") {
                        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !k.isEmpty else { return }
                        Keychain.set(.openai, k); key = ""; model.keyNote = "Saved privately on this Mac."
                    }
                    if !model.keyNote.isEmpty { Text(model.keyNote).font(.caption).foregroundStyle(.secondary) }
                }
                Text("Used for his voice, focus checks and research. The phone only ever gets short-lived keys.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Personality") {
                Button("Edit his personality…", action: model.editPersonality)
            }
        }
        .formStyle(.grouped)
    }
}
