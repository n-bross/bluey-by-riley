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
    var servicesChanged: () -> Void = {}

    @Published var recording: ShortcutAction?
    @Published var refused: Set<ShortcutAction> = []
    @Published var shortcutNote = ""
    @Published var hermesNote = ""
    @Published var keyNote = ""
    @Published var customLLMTestNote = ""
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

    var pomodoro: PomodoroRhythm { focus.pomodoro }

    func setPomodoro(_ p: PomodoroRhythm) { focus.setPomodoro(p); objectWillChange.send() }

    // MARK: Shortcut recording

    func record(_ action: ShortcutAction) {
        stopRecording(register: false)
        recording = action
        shortcutNote = "Drücke den neuen Kurzbefehl für „\(action.title)“. Esc bricht ab, ⌫ deaktiviert ihn."
        HotKeys.shared.unregisterAll()  // so pressing an existing combination doesn't trigger it
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let action = self.recording else { return event }
            switch Int(event.keyCode) {
            case 53: self.shortcutNote = ""                                  // Esc
            case 51, 117: ShortcutStore.set(action, nil); self.shortcutNote = "\(action.title) ist deaktiviert."  // ⌫ / ⌦
            default:
                guard let shortcut = Shortcut(event: event) else {
                    self.shortcutNote = "Verwende mindestens ⌃, ⌥, ⌘ oder eine Funktionstaste."
                    return nil
                }
                if let other = ShortcutStore.conflict(shortcut, except: action) {
                    ShortcutStore.set(other, nil)
                    self.shortcutNote = "\(shortcut.display) ist jetzt hier zugeordnet. „\(other.title)“ wurde deaktiviert."
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
            if !refused.isEmpty { shortcutNote = "macOS hat diese Kurzbefehle abgelehnt: " + refused.map(\.title).joined(separator: ", ") + ". Möglicherweise verwendet eine andere App die Tastenkombination." }
        }
    }

    func resetShortcuts() {
        ShortcutStore.resetAll()
        stopRecording(register: true)
        shortcutNote = "Standardeinstellungen wiederhergestellt."
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
            window.title = "Bluey · Einstellungen"
            window.appearance = NSAppearance(named: .darkAqua)
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 700, height: 640))
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


struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    /// GOOGLY_DEMO_SETTINGS=<0…4> opens a tab directly (for screenshots).
    @State private var tab = Int(ProcessInfo.processInfo.environment["GOOGLY_DEMO_SETTINGS"] ?? "") ?? 0

    var body: some View {
        TabView(selection: $tab) {
            GeneralPane(model: model).tabItem { Label("Allgemein", systemImage: "gearshape") }.tag(0)
            ShortcutsPane(model: model).tabItem { Label("Kurzbefehle", systemImage: "command") }.tag(1)
            FocusPane(model: model).tabItem { Label("Fokus", systemImage: "timer") }.tag(2)
            JournalPane(model: model).tabItem { Label("Journal", systemImage: "book.closed") }.tag(3)
            HermesPane(model: model).tabItem { Label("Hermes", systemImage: "sparkles") }.tag(4)
            ServicesPane(model: model).tabItem { Label("Services", systemImage: "cpu") }.tag(5)
        }
        .frame(width: 700, height: 640)
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .tint(Theme.accentLight)
        .onDisappear { model.stopRecording(register: model.recording != nil) }
    }
}

private struct GeneralPane: View {
    @ObservedObject var model: SettingsModel
    private var s: Settings { model.settings }

    var body: some View {
        Form {
            Section("Darstellung") {
                Toggle("Bluey in der Notch (auch ohne iPhone)", isOn: model.bind({ s.notchMode }, { s.notchMode = $0; model.applyNotchMode() }))
                Toggle("Schwebendes Avatarfenster", isOn: model.bind({ s.showAvatarWindow }, { s.showAvatarWindow = $0; model.setAvatarWindow($0) }))
                Toggle("Augen folgen dem Mauszeiger im Leerlauf", isOn: model.bind({ s.followMouse }, { s.followMouse = $0 }))
                HStack {
                    Text("Position des iPhones")
                    Spacer()
                    Picker("", selection: model.bind({ Int((s.phonePosition * 100).rounded()) }, { s.phonePosition = Double($0) / 100 })) {
                        Text("Links").tag(20); Text("Mitte").tag(50); Text("Rechts").tag(80)
                    }
                    .pickerStyle(.segmented).frame(width: 220).labelsHidden()
                }
                Button("iPhone koppeln (QR) …", action: model.pairPhone)
            }
            Section("Mauszeiger") {
                Picker("Stil", selection: model.bind({ s.pointerStyle }, { s.pointerStyle = $0 })) {
                    ForEach(PointerStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Größe", selection: model.bind({ Int(s.cursorSize) }, { s.cursorSize = Double($0) })) {
                    Text("Klein").tag(48); Text("Mittel").tag(72); Text("Groß").tag(96); Text("Sehr groß").tag(120)
                }
                .pickerStyle(.segmented)
                if s.pointerStyle == .blueberry {
                    Picker("Spur", selection: model.bind({ s.trail }, { s.trail = $0 })) {
                        ForEach(PointerTrail.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
                Toggle("Mauszeiger anzeigen", isOn: model.bind({ s.showCursor }, { s.showCursor = $0 }))
            }
            Section("Computersteuerung") {
                Toggle("Bluey darf auf Anfrage klicken, tippen und Apps öffnen", isOn: model.bind({ s.computerControl }, { s.computerControl = $0; model.computerControlChanged() }))
                if s.computerControl && !ComputerControl.isTrusted {
                    HStack {
                        Label("Bedienungshilfen müssen freigegeben sein", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Spacer()
                        Button("Freigeben …", action: model.allowComputerControl)
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
                                .help("macOS akzeptiert diese Tastenkombination nicht. Wähle eine andere.")
                        }
                        Button { model.record(action) } label: {
                            Text(model.recording == action ? "Tasten drücken …" : (ShortcutStore.get(action)?.display ?? "Aus"))
                                .font(.system(.body, design: .rounded).weight(.medium))
                                .frame(minWidth: 96)
                        }
                        .buttonStyle(.bordered)
                        .tint(model.recording == action ? Theme.accentLight : nil)
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if !model.shortcutNote.isEmpty { Text(model.shortcutNote).foregroundStyle(.secondary) }
                    Text("Klicke einen Kurzbefehl an und drücke die neue Tastenkombination. Kurzbefehle funktionieren auch, wenn Bluey im Hintergrund ist.")
                        .foregroundStyle(.secondary)
                    Button("Standardeinstellungen wiederherstellen", action: model.resetShortcuts)
                }
                .font(.caption)
            }
        }
        .formStyle(.grouped)
    }
}

private struct FocusPane: View {
    @ObservedObject var model: SettingsModel
    private var p: PomodoroRhythm { model.pomodoro }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "timer").font(.title2).foregroundStyle(Theme.accentLight)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pomodoro").font(.headline)
                        Text(p.enabled ? "Nach jeder Fokusrunde schlägt Bluey eine Pause vor." : "Ohne Pomodoro endet der Fokus nach Ablauf der Zeit.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: model.bind({ p.enabled }, { var s = p; s.enabled = $0; model.setPomodoro(s) }))
                        .toggleStyle(.switch).labelsHidden()
                }
                if p.enabled {
                    HStack(spacing: 10) {
                        ForEach(PomodoroRhythm.presets, id: \.name) { preset in PresetCard(preset: preset, model: model) }
                    }
                    .padding(.vertical, 4)
                    CycleBar(settings: p).frame(height: 30).padding(.vertical, 2)
                }
            }
            if p.enabled {
                Section("Zeiten") {
                    MinuteRow(title: "Fokusrunde", value: p.focusMinutes, range: 1...240, step: 5) { var s = p; s.focusMinutes = $0; model.setPomodoro(s) }
                    MinuteRow(title: "Kurze Pause", value: p.shortBreakMinutes, range: 1...60, step: 1) { var s = p; s.shortBreakMinutes = $0; model.setPomodoro(s) }
                    MinuteRow(title: "Lange Pause", value: p.longBreakMinutes, range: 1...120, step: 5) { var s = p; s.longBreakMinutes = $0; model.setPomodoro(s) }
                    Stepper(value: model.bind({ p.roundsBeforeLongBreak }, { var s = p; s.roundsBeforeLongBreak = $0; model.setPomodoro(s) }), in: 1...12) {
                        HStack { Text("Lange Pause nach"); Spacer(); Text("\(p.roundsBeforeLongBreak) Runden").monospacedDigit().foregroundStyle(.secondary) }
                    }
                }
                Section("Ablauf") {
                    Toggle("Pausen automatisch starten", isOn: model.bind({ p.autoStartBreaks }, { var s = p; s.autoStartBreaks = $0; model.setPomodoro(s) }))
                    Toggle("Nächste Runde automatisch starten", isOn: model.bind({ p.autoStartFocus }, { var s = p; s.autoStartFocus = $0; model.setPomodoro(s) }))
                    Text("Bei manueller Fortsetzung fragt Bluey nach der Pause, bevor er den Bildschirm wieder prüft.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Entwicklung") {
                Toggle("Entwicklermodus (vierfaches Tempo, Prüfung alle 10 s)", isOn: model.bind({ model.focus.developerMode }, { model.focus.setDeveloperMode($0) }))
            }
        }
        .formStyle(.grouped)
    }
}

/// One preset as a card: big rhythm, small name, highlighted when it's the current one.
private struct PresetCard: View {
    let preset: (name: String, settings: PomodoroRhythm)
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
                .fill(selected ? Theme.accentLight.opacity(0.14) : Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Theme.accentLight : Color.primary.opacity(0.1), lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The whole cycle at a glance: focus rounds in blue, short breaks green, the long break teal.
private struct CycleBar: View {
    let settings: PomodoroRhythm

    var body: some View {
        let rounds = settings.roundsBeforeLongBreak
        var segments: [(minutes: Double, color: Color, label: String)] = []
        for i in 1...rounds {
            segments.append((settings.focusMinutes, Theme.accentLight, "\(Int(settings.focusMinutes))"))
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
            Text("Ein Zyklus: \(ActivitySummary.duration(total * 60)) · Fokus \(ActivitySummary.duration(settings.focusMinutes * Double(rounds) * 60))")
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
                    Image(systemName: "book.closed").font(.title2).foregroundStyle(Theme.accentLight)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tagesjournal").font(.headline)
                        Text("Übersicht deiner Arbeit aus ActivityWatch, Fokus-Sessions und Hermes-Aufträgen. Frag Bluey „Was habe ich heute gemacht?“")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: model.bind({ s.journalEnabled }, { s.journalEnabled = $0 })).toggleStyle(.switch).labelsHidden()
                }
                HStack {
                    Text("Eine Datei pro Tag unter ~/Documents/Bluey Journal")
                    Spacer()
                    Button("Ordner öffnen") {
                        try? FileManager.default.createDirectory(at: ActivityJournal.folder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(ActivityJournal.folder)
                    }
                }
            }
            Section {
                Toggle("Jeden Tag an Hermes senden", isOn: model.bind({ s.journalToHermes }, { s.journalToHermes = $0 }))
                Picker("Tagesjournal senden ab", selection: model.bind({ s.journalHour }, { s.journalHour = $0 })) {
                    ForEach(12..<24) { Text(String(format: "%02d:00", $0)).tag($0) }
                }
                .disabled(!s.journalToHermes)
                HStack {
                    Button("Heutiges Journal jetzt senden") {
                        Task {
                            model.journalNote = "Wird gesendet …"
                            model.journalNote = await model.journal?.send(day: Date()) ?? "Journal nicht verfügbar."
                        }
                    }
                    .disabled(!model.hermes.available)
                    if !model.journalNote.isEmpty { Text(model.journalNote).font(.caption).foregroundStyle(.secondary) }
                }
            } header: {
                Text("Hermes")
            } footer: {
                Text("Hermes erhält pro Tag eine eigene Session, um Fragen zu deiner Arbeit beantworten zu können. Hat der Mac einen Tag verpasst, sendet Bluey das Journal beim nächsten Start. Dazu gehören Fenstertitel. Sie bleiben zwischen Bluey, deinen Journaldateien und Hermes.")
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
            Section("Verbindung") {
                HStack {
                    Circle().fill(model.hermes.available ? Color(hex: Keramik.green) : Color(hex: Keramik.amber)).frame(width: 8, height: 8)
                    Text(model.hermes.available ? "Verbunden" : (model.hermes.problem ?? "Nicht verbunden"))
                    Spacer()
                    Button("Test") {
                        Task { await model.hermes.refresh(); model.hermesNote = model.hermes.available ? "Hermes hat geantwortet." : (model.hermes.problem ?? "Keine Antwort."); model.objectWillChange.send() }
                    }
                }
                TextField("API-Server", text: $url)
                SecureField(HermesGateway.config() == nil ? "API-Schlüssel (API_SERVER_KEY)" : "Schlüssel gespeichert. Zum Ersetzen einen neuen einfügen.", text: $key)
                Button("Speichern") {
                    let newKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let k = newKey.isEmpty ? HermesGateway.config()?.key : newKey else { model.hermesNote = "Füge zuerst den Schlüssel ein."; return }
                    HermesGateway.saveConfig(url: url.trimmingCharacters(in: .whitespacesAndNewlines), key: k)
                    key = ""
                    Task { await model.hermes.refresh(); model.hermesNote = model.hermes.available ? "Gespeichert und verbunden." : "Gespeichert. Hermes hat nicht geantwortet."; model.objectWillChange.send() }
                }
                if !model.hermesNote.isEmpty { Text(model.hermesNote).font(.caption).foregroundStyle(.secondary) }
            }
            Section {
                Picker("Freigaben", selection: model.bind({ model.hermes.mode }, { model.hermes.mode = $0 })) {
                    ForEach(HermesApprovalMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Hermes wendet zuerst seine eigenen Freigaberegeln an. Diese Einstellung gilt, wenn danach noch eine Entscheidung erforderlich ist.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                TextField("https://shipyard-1.your-tailnet.ts.net:8790", text: model.bind({ HubSettings.url }, { HubSettings.url = $0 }))
                SecureField("Schlüssel (mit Tailscale optional)", text: model.bind({ HubSettings.key }, { HubSettings.key = $0 }))
                HStack {
                    Button("Test") { Task { model.hubNote = "Verbindung wird geprüft …"; model.hubNote = await HubNotesAPI.health() } }
                    Button("An iPhone senden") { model.hubNote = model.sendHubToPhone() }
                    Spacer()
                }
                if !model.hubNote.isEmpty { Text(model.hubNote).font(.caption).foregroundStyle(.secondary) }
            } header: { Text("Bluey Hub") } footer: {
                Text("Der Bluey Hub läuft auf demselben Server wie Hermes. So sind Notizen, Todos und Chats auch ohne Mac erreichbar. Über Tailscale reicht dein Login. Das iPhone erhält die Adresse beim Verbinden.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("ActivityWatch") {
                HStack {
                    Circle().fill(model.activityRunning() ? Color(hex: Keramik.green) : Color(hex: Keramik.amber)).frame(width: 8, height: 8)
                    Text(model.activityRunning() ? "Erfasst aktive Zeit" : "Läuft nicht")
                    Spacer()
                    if !model.activityRunning() { Button("Start", action: model.startActivityWatch) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ServicesPane: View {
    @ObservedObject var model: SettingsModel
    private var s: Settings { model.settings }

    @State private var openaiKey = ""
    @State private var geminiKey = ""
    @State private var elevenlabsKey = ""
    @State private var customLLMKey = ""
    @State private var customSTTKey = ""

    var body: some View {
        Form {
            Section {
                Picker("Live Voice & Anrufe", selection: model.bind({ s.voiceProvider }, { s.voiceProvider = $0; model.servicesChanged() })) {
                    ForEach(VoiceProvider.allCases) { Text($0.title).tag($0) }
                }
                Text(s.voiceProvider.detail)
                    .font(.caption).foregroundStyle(.secondary)

                if s.voiceProvider == .localHermes {
                    Picker("Call-Stimme (TTS)", selection: model.bind({ s.ttsProvider }, { s.ttsProvider = $0; model.servicesChanged() })) {
                        ForEach(TTSProvider.allCases) { Text($0.title).tag($0) }
                    }
                    if s.ttsProvider == .elevenlabs {
                        TextField("ElevenLabs Voice-ID", text: model.bind({ s.elevenLabsVoiceID }, { s.elevenLabsVoiceID = $0 }))
                    } else if s.ttsProvider == .localMLX {
                        TextField("Lokale TTS-URL", text: model.bind({ s.localTTSURL }, { s.localTTSURL = $0 }))
                        TextField("TTS-Modell", text: model.bind({ s.localTTSModel }, { s.localTTSModel = $0 }))
                        TextField("Stimme", text: model.bind({ s.localTTSVoice }, { s.localTTSVoice = $0 }))
                    }
                } else if s.voiceProvider == .geminiLive {
                    TextField("Gemini Live Modell", text: model.bind({ s.geminiLiveModel }, { s.geminiLiveModel = $0 }))
                    Picker("Gemini Stimme", selection: model.bind({ s.geminiLiveVoice }, { s.geminiLiveVoice = $0 })) {
                        ForEach(["Aoede", "Puck", "Charon", "Kore", "Fenrir"], id: \.self) { Text($0).tag($0) }
                    }
                }
            } header: {
                Text("Live Voice (Notch & iPhone)")
            }

            Section {
                Picker("Transkriptions-Service", selection: model.bind({ s.transcriptionProvider }, { s.transcriptionProvider = $0; model.servicesChanged() })) {
                    ForEach(TranscriptionProvider.allCases) { Text($0.title).tag($0) }
                }
                Picker("Sprache", selection: model.bind({ s.transcriptionLanguage }, { s.transcriptionLanguage = $0 })) {
                    Text("Automatisch / System").tag("")
                    Text("Deutsch (de-DE)").tag("de-DE")
                    Text("Englisch (en-US)").tag("en-US")
                }
                Toggle("Stille-Filter (leere Clips überspringen)", isOn: model.bind({ s.transcriptionSilenceFilter }, { s.transcriptionSilenceFilter = $0 }))
                Picker("Meeting-Abschnittslänge", selection: model.bind({ s.meetingChunkSeconds }, { s.meetingChunkSeconds = $0 })) {
                    Text("18 Sekunden").tag(18)
                    Text("30 Sekunden (empfohlen)").tag(30)
                    Text("60 Sekunden").tag(60)
                    Text("90 Sekunden").tag(90)
                }
                Picker("Auto-Stopp bei Stille", selection: model.bind({ s.meetingAutoStopSilentMinutes }, { s.meetingAutoStopSilentMinutes = $0 })) {
                    Text("Aus").tag(0)
                    Text("Nach 10 Minuten").tag(10)
                    Text("Nach 15 Minuten").tag(15)
                    Text("Nach 30 Minuten").tag(30)
                }

                switch s.transcriptionProvider {
                case .appleLocal:
                    Text("Läuft komplett offline auf deinem Mac (0 € API-Kosten).")
                        .font(.caption).foregroundStyle(.secondary)
                case .localMLX:
                    TextField("Lokale STT-URL", text: model.bind({ s.localSTTURL }, { s.localSTTURL = $0 }))
                    TextField("Modell", text: model.bind({ s.localSTTModel }, { s.localSTTModel = $0 }))
                    Text("OpenAI-kompatibler lokaler Endpunkt, z. B. mlx_audio.server oder whisper.cpp server (0 €).")
                        .font(.caption).foregroundStyle(.secondary)
                case .groq:
                    TextField("Groq Modell", text: model.bind({ s.groqSTTModel }, { s.groqSTTModel = $0 }))
                case .custom:
                    TextField("STT-Endpunkt URL", text: model.bind({ s.customSTTURL }, { s.customSTTURL = $0 }))
                    TextField("STT-Modell", text: model.bind({ s.customSTTModel }, { s.customSTTModel = $0 }))
                case .openai:
                    TextField("OpenAI STT-Modell", text: model.bind({ s.openAISTTModel }, { s.openAISTTModel = $0 }))
                }
            } header: {
                Text("Meeting-Transkription & Spracherkennung")
            }

            Section {
                Picker("Standard-KI (Chat, Rückfragen, Recherche)", selection: model.bind({ s.llmProvider }, { s.llmProvider = $0; model.servicesChanged() })) {
                    ForEach(LLMProvider.allCases) { Text($0.title).tag($0) }
                }
                if s.llmProvider == .openAICompatible || s.focusProvider == .openAICompatible {
                    HStack(spacing: 6) {
                        Text("Vorlagen:").font(.caption).foregroundStyle(.secondary)
                        ForEach(CustomLLMPreset.all) { preset in
                            Button(preset.name) {
                                s.customLLMBaseURL = preset.baseURL
                                s.customLLMModel = preset.model
                                model.objectWillChange.send()
                                model.servicesChanged()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    TextField("Base-URL", text: model.bind({ s.customLLMBaseURL }, { s.customLLMBaseURL = $0 }))
                    TextField("Modell", text: model.bind({ s.customLLMModel }, { s.customLLMModel = $0 }))
                    HStack {
                        Button("Verbindung testen") {
                            Task {
                                model.customLLMTestNote = "Teste …"
                                model.customLLMTestNote = await LLMService.testCustomConnection()
                            }
                        }
                        if !model.customLLMTestNote.isEmpty {
                            Text(model.customLLMTestNote).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Picker("Focus-Checks", selection: model.bind({ s.focusProvider }, { s.focusProvider = $0; model.servicesChanged() })) {
                    ForEach(FocusProvider.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Unveränderte Screens bei Focus überspringen", isOn: model.bind({ s.focusSkipUnchanged }, { s.focusSkipUnchanged = $0 }))
            } header: {
                Text("KI-Gehirn & Focus")
            }

            Section {
                keyRow(title: "Gemini API-Key", key: .gemini, placeholder: "AIza…", text: $geminiKey)
                keyRow(title: "Custom KI-Key (OpenRouter/Groq/…)", key: .customLLM, placeholder: "sk-or-…", text: $customLLMKey)
                keyRow(title: "STT-Key (Groq/Custom)", key: .customSTT, placeholder: "gsk_…", text: $customSTTKey)
                keyRow(title: "ElevenLabs API-Key", key: .elevenlabs, placeholder: "sk_…", text: $elevenlabsKey)
                keyRow(title: "OpenAI API-Key (optional)", key: .openai, placeholder: "sk-…", text: $openaiKey)
                if !model.keyNote.isEmpty {
                    Text(model.keyNote).font(.caption).foregroundStyle(.secondary)
                }
                Text("Alle Schlüssel werden privat unter ~/Library/Application Support/Googly/keys.json (0600) gespeichert. Ohne OpenAI-Key entstehen garantiert 0 € OpenAI-API-Kosten.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("API-Schlüssel")
            }

            Section("Persönlichkeit") {
                Button("Persönlichkeit bearbeiten …", action: model.editPersonality)
            }
        }
        .formStyle(.grouped)
    }

    private func keyRow(title: String, key: Keychain.Key, placeholder: String, text: Binding<String>) -> some View {
        let saved = Keychain.get(key) != nil
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                SecureField(saved ? "Gespeichert – neuen Key zum Ersetzen einfügen" : placeholder, text: text)
            }
            Button("Speichern") {
                let value = text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { return }
                Keychain.set(key, value)
                text.wrappedValue = ""
                model.keyNote = "\(title) gespeichert."
                model.objectWillChange.send()
                model.servicesChanged()
            }
            .disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if saved {
                Button("Entfernen", role: .destructive) {
                    Keychain.set(key, nil)
                    model.keyNote = "\(title) entfernt."
                    model.objectWillChange.send()
                    model.servicesChanged()
                }
            }
        }
    }
}
