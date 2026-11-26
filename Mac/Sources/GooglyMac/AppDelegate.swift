import AppKit
import Carbon.HIToolbox
import GooglyShared

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = Settings.shared
    private let overlay = CursorOverlay()
    private let server = PhoneServer()
    private var statusItem: NSStatusItem!
    private let codex = CodexController()
    private let focus = FocusCompanion(steering: FocusSteering())
    private let pairingPanel = PairingPanel()
    private let avatarWindow = AvatarWindow()
    private let quickNotes = QuickNotesWindow()
    private lazy var meetingWindow: Any? = {
        if #available(macOS 15, *) { return MeetingWindow() }
        return nil
    }()

    @available(macOS 15, *)
    private var meetings: MeetingWindow? { meetingWindow as? MeetingWindow }
    private lazy var host = RealtimeHost(overlay: overlay, codex: codex)
    private lazy var bridge = HermesBridge(server: server, host: host, focus: focus)
    private lazy var notch = NotchController(host: host, focus: focus, hermes: bridge.hermes)
    private var presence: Timer?
    /// The talk shortcut is being held (talking on the Mac).
    private var macTalkHeld = false
    private let workspace = WorkspaceStore()
    private lazy var web = WebServer(store: workspace)
    private lazy var workspaceWindow = WorkspaceWindow(store: workspace)


    func applicationDidFinishLaunching(_ notification: Notification) {
        Fonts.registerBundled()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = MenuIcon.make()
        statusItem.button?.toolTip = "Bluey"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        overlay.onFace = { [weak self] face in
            guard let self else { return }
            self.server.send(face)
            self.web.send(face: face)
            self.workspaceWindow.animator.receive(face, at: Date().timeIntervalSinceReferenceDate)
            self.avatarWindow.update(face)
            if self.settings.notchMode { self.notch.face(face) }
        }
        overlay.onLook = { [weak self] point in self?.avatarWindow.look(at: point) }
        if settings.showAvatarWindow { avatarWindow.show() }
        overlay.start()
        showDemoBubbleIfAsked()
        checkPermissions()
        if let path = ProcessInfo.processInfo.environment["GOOGLY_DEMO_TRANSCRIBE"], let audio = FileManager.default.contents(atPath: path) {
            // Transcribes an audio file into a throwaway notes folder, prints the lines and quits.
            Task {
                do {
                    let result = try await MeetingNotes.transcribe(audio: audio, session: "demo0000", index: 1, sessionStarted: Date())
                    for s in result.segments { print("[\(s.start)] \(s.speaker): \(s.text)") }
                    try? FileManager.default.removeItem(at: result.folder)
                } catch { print("failed:", error) }
                exit(0)
            }
        }
        if let question = ProcessInfo.processInfo.environment["GOOGLY_DEMO_RESEARCH"] {
            host.demoResearch(question, out: ProcessInfo.processInfo.environment["GOOGLY_DEMO_OUT"] ?? "/tmp/googly-report")
        }
        host.focus = focus
        focus.onChange = { [weak self] state in
            guard let data = try? JSONEncoder().encode(state), let text = String(data: data, encoding: .utf8) else { return }
            self?.server.broadcast(Packet(command: "focusState", text: text))
            self?.notch.update(focus: state.current, sync: state)
            self?.web.sendFocus(state)
            self?.workspaceWindow.model.currentFocus = state.current
            self?.workspaceWindow.model.focusHistory = state.history
        }
        focus.onNudge = { [weak self] message, target in
            guard let self else { return }
            self.host.focusNudge(message, target: target)
            self.server.broadcast(Packet(command: "focusChirp", text: message))
            self.avatarWindow.react("stop")
            if self.server.phoneNames.isEmpty, self.settings.notchMode { self.notch.voice.focusChirp() }
        }
        focus.onPomodoro = { [weak self] message in
            // Off to a break / break's over: his bubble, a chirp on every device, and the notch drops open.
            guard let self else { return }
            self.host.focusNudge(message, target: nil)
            self.server.broadcast(Packet(command: "focusChirp", text: message))
            if self.settings.notchMode {
                self.notch.announce(message)
                if self.server.phoneNames.isEmpty { self.notch.voice.focusChirp() }
            }
        }
        focus.startService()
        AIServices.hermes = bridge.hermes
        bridge.start()
        bridge.onHermesChange = { [weak self] in self?.notch.refreshHermes() }
        bridge.deliverNote = { [weak self] note in self?.notch.deliver(note) ?? false }
        notch.model.openSettings = { [weak self] in self?.openSettings() }
        if ProcessInfo.processInfo.environment["GOOGLY_DEMO_SETTINGS"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.openSettings() }
        }
        applyNotchMode()
        startWorkspace()
        if CommandLine.arguments.contains("--pair") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.pairingPanel.show() }
        }
        server.onPhonesChanged = { [weak self] names in
            self?.refreshIcon()
            guard let self else { return }
            // A newly connected phone learns where the hub is (so it also works away from the Mac).
            if !names.isEmpty, let hub = HubSettings.phonePayload { self.server.broadcast(Packet(command: "hubConfig", text: hub)) }
            // In notch mode the Mac itself keeps focus going; otherwise losing the phone pauses it.
            if names.isEmpty, !self.settings.notchMode { self.focus.disconnected() }
            if names.isEmpty, self.host.awake, !self.notch.isListening { self.host.setAwake(false) }
            self.updateNotchPresence()
        }
        server.onRequest = { [weak self] packet, reply in
            guard let self else { return }
            if WorkspacePhoneLink.handles(packet.command) {
                WorkspacePhoneLink.handle(packet, store: self.workspace, reply: reply)
            } else if packet.command?.hasPrefix("focus") == true {
                self.focus.heartbeat()
                let args = packet.text.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
                var result = ""
                switch packet.command {
                case "focusStart": result = self.focus.start(task: args["task"] as? String ?? "", minutes: args["minutes"] as? Double)
                case "focusBreak": result = self.focus.takeBreak()
                case "focusSkipBreak": result = self.focus.skipBreak()
                case "focusPomodoro":
                    if let json = args["pomodoro"] as? String, let s = try? JSONDecoder().decode(PomodoroRhythm.self, from: Data(json.utf8)) {
                        result = self.focus.setPomodoro(s)
                    } else { result = "Couldn't read those Pomodoro settings." }
                case "focusPause": result = self.focus.pause()
                case "focusResume": result = self.focus.resume()
                case "focusEnd": result = self.focus.end()
                case "focusTestNudge": result = self.focus.testNudge()
                case "focusDeveloperMode":
                    if let enabled = args["developerMode"] as? Bool { result = self.focus.setDeveloperMode(enabled) }
                    else { result = "Specify whether Developer Mode is on or off." }
                case "focusSync": self.focus.sync()
                default: break
                }
                reply(Packet(command: "focusReply", callID: packet.callID, text: result))
            } else if !self.bridge.handle(packet, reply: reply) { self.host.handle(packet, reply: reply) }
        }
        server.start()
        host.onChange = { [weak self] in self?.refreshIcon() }
        codex.onEvent = { [weak self] event in self?.codexEvent(event) }
        codex.warmUp()

        registerShortcuts()
        if settings.hidden { applyHidden() }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateNotchPresence() }
        }
    }

    /// Todos, notes, chats and the pomodoro: shared with the phone, the web app and the Bluey window.
    private func startWorkspace() {
        workspace.chatContext = { [weak self] in
            guard let session = self?.focus.current, session.status != .ended else { return "" }
            return "Laufende Bluey-Fokus-Session: \(session.task) (\(session.status.rawValue), noch \(Int(session.remaining / 60)) Min.)"
        }
        workspace.listen(snapshot: { [weak self] snapshot in
            self?.server.broadcast(Packet(command: "wsState", text: WorkspaceCoding.string(snapshot)))
        }, delta: { [weak self] delta in
            self?.server.broadcast(Packet(command: "chatDelta", text: WorkspaceCoding.string(delta)))
        })
        workspace.onPomodoroChange = { [weak self] old, new in self?.pomodoroChanged(from: old, to: new) }
        workspace.start()
        web.focusState = { [weak self] in
            guard let self else { return nil }
            return FocusSync(current: self.focus.current, history: self.focus.history, revision: 0, developerMode: self.focus.developerMode)
        }
        web.focusCommand = { [weak self] command, args in self?.runFocusCommand(command, args) ?? "" }
        web.start()
        workspaceWindow.phoneName = { [weak self] in self?.server.phoneNames.first }
        workspaceWindow.openWebApp = { [weak self] in self?.openWebApp() }
        workspaceWindow.pairPhone = { [weak self] in self?.pairingPanel.show() }
        workspaceWindow.model.focusCommand = { [weak self] command, task, minutes in
            self?.runFocusCommand(command, ["task": task, "minutes": minutes]) ?? ""
        }
        workspaceWindow.model.currentFocus = focus.current
        workspaceWindow.model.focusHistory = focus.history
        if CommandLine.arguments.contains("--window") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.workspaceWindow.show() }
        }
    }

    private func runFocusCommand(_ command: String, _ args: [String: Any]) -> String {
        switch command {
        case "focusStart": return focus.start(task: args["task"] as? String ?? "", minutes: args["minutes"] as? Double)
        case "focusPause": return focus.pause()
        case "focusResume": return focus.resume()
        case "focusEnd": return focus.end()
        default: return ""
        }
    }

    /// Bluey cheers when a pomodoro phase ends and, if asked, watches the screen during focus phases.
    private func pomodoroChanged(from old: PomodoroState?, to new: PomodoroState?) {
        guard let new else { return }
        let finishedNaturally = old.map { o in
            o.isRunning && o.phase != new.phase &&
                abs(new.updatedAt.timeIntervalSince(o.startedAt!.addingTimeInterval(o.pausedRemaining ?? o.duration))) < 0.01
        } ?? false
        if finishedNaturally, let old {
            let line = old.phase == .focus ? "Runde geschafft! Zeit für eine kleine Pause." : "Pause vorbei. Bereit für die nächste Runde?"
            host.showReply(line)
            server.broadcast(Packet(command: "codexChirp", text: line))
        }
        guard new.settings.watchScreen || focus.hasSession else { return }
        let focusing = new.phase == .focus
        if focusing && new.isRunning && old?.phaseID != new.phaseID && new.settings.watchScreen {
            if focus.hasSession { _ = focus.end() }
            let label = new.label.isEmpty ? "Pomodoro-Fokus" : new.label
            _ = focus.start(task: label, minutes: max(1, new.remaining(at: Date()) / 60))
        } else if focusing && new.isPaused && old?.isRunning == true {
            focus.pause("Pomodoro pausiert")
        } else if focusing && new.isRunning && old?.isPaused == true {
            _ = focus.resume()
        } else if !focusing && old?.phase == .focus && focus.hasSession {
            _ = focus.end()
        }
    }

    @objc private func openWorkspace() { workspaceWindow.show() }

    @objc private func openWebApp() { NSWorkspace.shared.open(web.url) }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        workspaceWindow.show()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if #available(macOS 15, *), let meetings, meetings.recording || meetings.changingCapture {
            Task {
                await meetings.stop()
                while meetings.changingCapture { try? await Task.sleep(for: .milliseconds(50)) }
                await meetings.stop()
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        notch.stop()
        workspace.save()
        focus.shutdown()
        codex.shutdown()
    }

    /// A Codex job finished or wants a yes. Awake, he hears about it and says so himself (bubble, chirp,
    /// and it lands in the phone's session history). Asleep, the bubble shows here and the phone chirps.
    private func codexEvent(_ event: CodexController.Event) {
        let (note, line, isApproval): (String, String, Bool) = {
            switch event {
            case .finished(let note, let line): return (note, line, false)
            case .approval(let note, let line): return (note, line, true)
            }
        }()
        if notch.deliver(note) { return }
        if host.awake, !server.phoneNames.isEmpty {
            server.broadcast(Packet(command: "codexNote", text: note))
            return
        }
        Task { @MainActor in
            // Approvals need the exact ask; finished jobs get a proper one-liner from him.
            let text = isApproval ? line : (await CodexLine.write(note) ?? line)
            self.host.showReply(text)
            self.server.broadcast(Packet(command: "codexChirp", text: text))
        }
    }

    @objc private func addCodexFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Folders Codex can work in when you ask Bluey"
        guard panel.runModal() == .OK else { return }
        CodexProjects.added = CodexProjects.added + panel.urls.map(\.path).filter { !CodexProjects.added.contains($0) }
    }

    @objc private func openCodexJob(_ item: NSMenuItem) {
        if let id = item.representedObject as? String { codex.open(threadID: id) }
    }

    @objc private func openCodex() { NSWorkspace.shared.open(URL(string: "codex://")!) }

    // MARK: Shortcuts and hiding

    /// (Re-)registers every global shortcut from Settings ▸ Shortcuts. Returns the ones macOS refused.
    @discardableResult
    func registerShortcuts() -> [ShortcutAction] {
        HotKeys.shared.unregisterAll()
        var refused: [ShortcutAction] = []
        for action in ShortcutAction.allCases {
            guard let shortcut = ShortcutStore.get(action) else { continue }
            let ok: Bool
            switch action {
            case .talk:
                // Hold to talk on the Mac; with a phone connected it wakes the phone (like double tapping it).
                ok = HotKeys.shared.register(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, onRelease: { [weak self] in
                    guard let self, self.macTalkHeld else { return }
                    self.macTalkHeld = false
                    self.notch.endTalk()
                }) { [weak self] in
                    guard let self else { return }
                    if self.server.phoneNames.isEmpty, self.settings.notchMode {
                        if self.settings.hidden { self.toggleHidden() }
                        self.macTalkHeld = true
                        self.notch.beginTalk()
                    } else { self.toggleAwake() }
                }
            default:
                ok = HotKeys.shared.register(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) { [weak self] in
                    self?.perform(action)
                }
            }
            if !ok { refused.append(action) }
        }
        return refused
    }

    private func perform(_ action: ShortcutAction) {
        switch action {
        case .talk: break
        case .typeToBluey: typeToBluey()
        case .hide: toggleHidden()
        case .wake: toggleAwake()
        case .stop: stopActions()
        case .pointHere: pointHere()
        case .followMouse: toggleFollow()
        case .stopPointing: overlay.goHome()
        case .notes: quickNotes.toggle()
        }
    }

    /// Makes him disappear everywhere (notch, pointer, avatar window) or come back.
    @objc func toggleHidden() {
        settings.hidden.toggle()
        applyHidden()
    }

    private func applyHidden() {
        let hidden = settings.hidden
        overlay.setHidden(hidden)
        notch.setHidden(hidden)
        if hidden {
            avatarWindow.hide()
            if notch.isListening { notch.voice.sleep() }
        } else if settings.showAvatarWindow {
            avatarWindow.show()
        }
        statusItem.button?.alphaValue = hidden ? 0.45 : 1
    }

    private func refreshIcon() {
        statusItem.button?.appearsDisabled = server.phoneNames.isEmpty && !settings.notchMode
    }

    // MARK: Actions

    @objc private func pointHere() {
        let m = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first else { return }
        overlay.mode = .pinned(CGPoint(x: m.x - screen.frame.minX, y: screen.frame.maxY - m.y))
    }

    @objc private func toggleFollow() {
        settings.followMouse.toggle()
        overlay.goHome()
    }


    /// For checking the speech bubble's look: GOOGLY_DEMO_BUBBLE=top|middle|home shows a sample reply.
    private func showDemoBubbleIfAsked() {
        guard let where_ = ProcessInfo.processInfo.environment["GOOGLY_DEMO_BUBBLE"],
              let size = NSScreen.screens.first?.frame.size else { return }
        let y: CGFloat = where_ == "top" ? 40 : size.height * 0.55
        let thing = CGRect(x: size.width * 0.3, y: y, width: 90, height: 22)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if where_ != "home" {
                self.overlay.mode = .pinned(CGPoint(x: thing.midX, y: thing.maxY + 3))
                self.overlay.view.speechTarget = thing
            }
            self.overlay.view.caption = ProcessInfo.processInfo.environment["GOOGLY_DEMO_TEXT"]
                ?? "That's the prompt box, where you type your question. Cheeky little thing."
        }
        // GOOGLY_DEMO_OUT=path.png saves a picture of the overlay (on dark grey) and quits.
        if let out = ProcessInfo.processInfo.environment["GOOGLY_DEMO_OUT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                let view = self.overlay.view
                let scale: CGFloat = 1
                let w = Int(view.bounds.width * scale), h = Int(view.bounds.height * scale)
                guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
                ctx.setFillColor(NSColor(white: 0.12, alpha: 1).cgColor)
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                ctx.setFillColor(NSColor(white: 0.5, alpha: 1).cgColor)
                ctx.fill(CGRect(x: thing.minX, y: view.bounds.height - thing.maxY, width: thing.width, height: thing.height))
                ctx.scaleBy(x: scale, y: scale)
                view.layer?.presentation()?.render(in: ctx) ?? view.layer?.render(in: ctx)
                if let image = ctx.makeImage() {
                    let rep = NSBitmapImageRep(cgImage: image)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                }
                exit(0)
            }
        }
    }
    @objc private func testAvatarMood(_ item: NSMenuItem) {
        if let id = item.representedObject as? String { avatarWindow.test(mood: id) }
    }
    @objc private func testAvatarReaction(_ item: NSMenuItem) {
        if let id = item.representedObject as? String { avatarWindow.react(id) }
    }
    @objc private func pairPhone() { pairingPanel.show() }
    @objc private func pauseFocus() { focus.pause() }
    @objc private func resumeFocus() { _ = focus.resume() }
    @objc private func endFocus() { _ = focus.end() }

    @objc private func toggleAwake() {
        if server.phoneNames.isEmpty, settings.notchMode {
            if notch.isListening { notch.voice.sleep() } else { notch.voice.wake() }
            return
        }
        server.broadcast(Packet(command: host.awake ? "sleep" : "wake"))
    }

    private func pomodoroMenu() -> NSMenuItem {
        let menu = NSMenu()
        let p = focus.pomodoro
        let summary = NSMenuItem(title: p.summary, action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(summary)
        if p.enabled {
            let rounds = NSMenuItem(title: "Rounds done this cycle: \(focus.completedRounds) of \(p.roundsBeforeLongBreak)", action: nil, keyEquivalent: "")
            rounds.isEnabled = false
            menu.addItem(rounds)
        }
        menu.addItem(.separator())
        let on = item("Pomodoro Breaks", #selector(togglePomodoro))
        on.state = p.enabled ? .on : .off
        menu.addItem(on)
        for (index, preset) in PomodoroRhythm.presets.enumerated() {
            let m = item(preset.name, #selector(setPomodoroPreset(_:)))
            m.tag = index
            m.state = p.enabled && p.sameRhythm(preset.settings) ? .on : .off
            menu.addItem(m)
        }
        menu.addItem(item("Custom Times…", #selector(customPomodoro)))
        menu.addItem(.separator())
        let breaks = item("Start Breaks Automatically", #selector(toggleAutoBreaks))
        breaks.state = p.autoStartBreaks ? .on : .off
        menu.addItem(breaks)
        let next = item("Start Next Round Automatically", #selector(toggleAutoNext))
        next.state = p.autoStartFocus ? .on : .off
        menu.addItem(next)
        if focus.rest == nil, p.enabled { menu.addItem(item("Take a Break Now", #selector(takeBreak))) }
        let root = NSMenuItem(title: "Pomodoro", action: nil, keyEquivalent: "")
        root.submenu = menu
        return root
    }

    @objc private func togglePomodoro() { var p = focus.pomodoro; p.enabled.toggle(); focus.setPomodoro(p) }
    @objc private func toggleAutoBreaks() { var p = focus.pomodoro; p.autoStartBreaks.toggle(); focus.setPomodoro(p) }
    @objc private func toggleAutoNext() { var p = focus.pomodoro; p.autoStartFocus.toggle(); focus.setPomodoro(p) }
    @objc private func takeBreak() { host.showReply(focus.takeBreak()) }
    @objc private func skipBreak() { host.showReply(focus.skipBreak()) }
    @objc private func setPomodoroPreset(_ item: NSMenuItem) {
        guard PomodoroRhythm.presets.indices.contains(item.tag) else { return }
        var p = PomodoroRhythm.presets[item.tag].settings
        p.autoStartBreaks = focus.pomodoro.autoStartBreaks
        p.autoStartFocus = focus.pomodoro.autoStartFocus
        focus.setPomodoro(p)
    }

    @objc private func customPomodoro() {
        NSApp.activate(ignoringOtherApps: true)
        let p = focus.pomodoro
        let alert = NSAlert()
        alert.messageText = "Pomodoro Timer"
        alert.informativeText = "Minutes for focus, short break and long break, and how many rounds come before the long break."
        let labels = ["Focus (min)", "Break (min)", "Long break (min)", "Rounds before long break"]
        let values = [p.focusMinutes, p.shortBreakMinutes, p.longBreakMinutes, Double(p.roundsBeforeLongBreak)]
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        var fields: [NSTextField] = []
        for (i, label) in labels.enumerated() {
            let y = CGFloat(90 - i * 30)
            let l = NSTextField(labelWithString: label)
            l.frame = NSRect(x: 0, y: y + 2, width: 200, height: 20)
            let f = NSTextField(string: String(Int(values[i])))
            f.frame = NSRect(x: 210, y: y, width: 80, height: 24)
            box.addSubview(l); box.addSubview(f); fields.append(f)
        }
        alert.accessoryView = box
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var s = p
        s.enabled = true
        s.focusMinutes = Double(fields[0].stringValue) ?? p.focusMinutes
        s.shortBreakMinutes = Double(fields[1].stringValue) ?? p.shortBreakMinutes
        s.longBreakMinutes = Double(fields[2].stringValue) ?? p.longBreakMinutes
        s.roundsBeforeLongBreak = Int(fields[3].stringValue) ?? p.roundsBeforeLongBreak
        host.showReply(focus.setPomodoro(s))
    }

    /// The notch bar is for laptop-only moments: it steps aside while the phone is connected or an
    /// external monitor is in use (he's visible there instead).
    private func updateNotchPresence() {
        let present = settings.notchMode && server.phoneNames.isEmpty && !NotchController.externalDisplayConnected
        notch.setSuppressed(!present)
        overlay.setHome(atTop: present)
    }

    @objc private func typeToBluey() {
        guard settings.notchMode else { return }
        if settings.hidden { toggleHidden() }
        notch.openForTyping()
    }

    /// Notch mode: he sits in the notch, listens on the Mac, and the Mac keeps focus sessions alive itself.
    private func applyNotchMode() {
        presence?.invalidate(); presence = nil
        if settings.notchMode {
            notch.start()
            focus.sync()
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.focus.heartbeat() }
            }
            RunLoop.main.add(timer, forMode: .common)
            presence = timer
            focus.heartbeat()
        } else {
            notch.stop()
            if server.phoneNames.isEmpty { focus.disconnected() }
        }
        updateNotchPresence()
        refreshIcon()
    }

    /// On launch, asks for whatever he still needs (so Bluey shows up in those Settings lists),
    /// and keeps a small status file so it's easy to check what's allowed.
    private func checkPermissions() {
        guard ProcessInfo.processInfo.environment["GOOGLY_DEMO_OUT"] == nil else { return }
        // Focus only needs Screen Recording. Accessibility is optional for explicit computer control.
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        let status = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Googly/status.txt")
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            let text = "accessibility=\(ComputerControl.isTrusted) screenRecording=\(CGPreflightScreenCaptureAccess()) computerControl=\(Settings.shared.computerControl)\n"
            try? text.write(to: status, atomically: true, encoding: .utf8)
        }.fire()
    }

    @objc private func openMeetings() {
        if #available(macOS 15, *) { meetings?.show() }
    }

    @objc private func openNotes() {
        try? FileManager.default.createDirectory(at: MeetingNotes.root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(MeetingNotes.root)
    }

    @objc private func stopActions() {
        focus.pause("Stopped with ⌃⌥S")
        host.stopActions()
    }

    @objc private func allowComputerControl() {
        ComputerControl.askForPermission()
        ComputerControl.openAccessibilitySettings()
    }

    /// Wakes him again so a new personality or set of tools takes effect right away.
    private func restartIfAwake() {
        guard host.awake else { return }
        server.broadcast(Packet(command: "sleep"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.server.broadcast(Packet(command: "wake")) }
    }

    @objc private func editPersonality() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "His Personality"
        alert.informativeText = "Describe who he is and how he talks. How he looks at and points at your screen stays built in."
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 220))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.bounds)
        text.autoresizingMask = [.width]
        text.isRichText = false
        text.font = NSFont.systemFont(ofSize: 13)
        text.string = RealtimeHost.personality
        text.textContainerInset = NSSize(width: 6, height: 6)
        scroll.documentView = text
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Reset to Default")
        alert.window.initialFirstResponder = text
        switch alert.runModal() {
        case .alertFirstButtonReturn: RealtimeHost.personality = text.string
        case .alertThirdButtonReturn: RealtimeHost.personality = ""
        default: return
        }
        restartIfAwake()
    }

    @objc private func editKeys() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "OpenAI API Key"
        alert.informativeText = "Saved privately on this Mac (not in the project files). The phone only ever gets short-lived keys."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = Keychain.get(.openai) == nil ? "sk-…" : "Key saved. Paste a new one to replace it."
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { Keychain.set(.openai, key) }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Where he is.
        let phones = server.phoneNames
        let where_ = phones.isEmpty ? (settings.notchMode ? "Bluey is in the notch" : "Waiting for the phone app…")
                                    : "Phone connected: \(phones.joined(separator: ", "))"
        let status = NSMenuItem(title: settings.hidden ? "Bluey is hidden" : where_, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Bluey öffnen…", action: #selector(openWorkspace), keyEquivalent: "o")
        open.keyEquivalentModifierMask = [.control, .option]
        open.target = self
        menu.addItem(open)
        let webItem = NSMenuItem(title: "Web-App öffnen (\(web.url.host ?? "127.0.0.1"):\(web.port))", action: #selector(openWebApp), keyEquivalent: "")
        webItem.target = self
        menu.addItem(webItem)
        menu.addItem(.separator())

        // Focus and Pomodoro.
        if let session = focus.current, session.status != .ended {
            let title = NSMenuItem(title: "Focus: \(session.task) · \(FocusSession.clock(session.remaining))", action: nil, keyEquivalent: "")
            title.isEnabled = false; menu.addItem(title)
            menu.addItem(item(session.status == .running ? "Pause Focus" : "Resume Focus", session.status == .running ? #selector(pauseFocus) : #selector(resumeFocus)))
            menu.addItem(item("End Focus", #selector(endFocus)))
        }
        if let rest = focus.rest {
            let r = NSMenuItem(title: "\(rest.title): \(FocusSession.clock(rest.remaining)) left", action: nil, keyEquivalent: "")
            r.isEnabled = false; menu.addItem(r)
            menu.addItem(item("Skip Break", #selector(skipBreak)))
        }
        menu.addItem(pomodoroMenu())
        menu.addItem(.separator())

        // Talking to him.
        if settings.notchMode { menu.addItem(shortcutItem("Type to Bluey…", #selector(typeToBluey), .typeToBluey)) }
        let listening = phones.isEmpty ? notch.isListening : host.awake
        let wake = shortcutItem(listening ? "Stop Listening" : "Start Listening", #selector(toggleAwake), .wake)
        wake.isEnabled = !phones.isEmpty || settings.notchMode
        menu.addItem(wake)
        menu.addItem(bridge.menuItem(target: self))
        if CodexController.isInstalled {
            let codexMenu = NSMenu()
            for job in codex.jobs.suffix(8).reversed() {
                let j = item("\(job.project): \(CodexController.short(job.prompt, 40)) (\(job.status))", #selector(openCodexJob(_:)))
                j.representedObject = job.threadID
                codexMenu.addItem(j)
            }
            if !codex.jobs.isEmpty { codexMenu.addItem(.separator()) }
            codexMenu.addItem(item("Add Project Folder…", #selector(addCodexFolder)))
            codexMenu.addItem(item("Open Codex", #selector(openCodex)))
            menu.addItem(submenu(codex.approvals.isEmpty ? "Codex" : "Codex (waiting for you)", codexMenu))
        }
        menu.addItem(shortcutItem("Quick Notes", #selector(toggleQuickNotes), .notes))
        if #available(macOS 15, *), let meetings {
            let title = meetings.recording ? "Call-Notizen · Aufnahme läuft …" : "Call-Notizen …"
            menu.addItem(item(title, #selector(openMeetings)))
        }
        menu.addItem(item("Open Meeting Notes", #selector(openNotes)))
        menu.addItem(.separator())

        // Control.
        menu.addItem(shortcutItem(settings.hidden ? "Show Bluey" : "Hide Bluey", #selector(toggleHidden), .hide))
        menu.addItem(shortcutItem("Stop Him", #selector(stopActions), .stop))
        let testMenu = NSMenu()
        for mood in KeramikTest.moods {
            let m = NSMenuItem(title: mood.title, action: #selector(testAvatarMood(_:)), keyEquivalent: "")
            m.target = self; m.representedObject = mood.id; testMenu.addItem(m)
        }
        testMenu.addItem(.separator())
        for reaction in KeramikTest.reactions + [("", "")] + KeramikTest.activities + [("", "")] + KeramikTest.power {
            if reaction.id.isEmpty { testMenu.addItem(.separator()); continue }
            let r = NSMenuItem(title: reaction.title, action: #selector(testAvatarReaction(_:)), keyEquivalent: "")
            r.target = self; r.representedObject = reaction.id; testMenu.addItem(r)
        }
        menu.addItem(submenu("Test Avatar", testMenu))
        menu.addItem(.separator())
        let prefs = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)
        menu.addItem(NSMenuItem(title: "Quit Bluey", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// A menu item that shows the action's current global shortcut.
    private func shortcutItem(_ title: String, _ action: Selector, _ shortcut: ShortcutAction) -> NSMenuItem {
        let key = ShortcutStore.get(shortcut)?.menuKey
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key?.key ?? "")
        item.keyEquivalentModifierMask = key?.modifiers ?? []
        item.target = self
        return item
    }

    private lazy var settingsModel: SettingsModel = {
        let model = SettingsModel(focus: focus, hermes: bridge.hermes)
        model.journal = bridge.journal
        model.sendHubToPhone = { [weak self] in
            guard let self, let hub = HubSettings.phonePayload else { return "Add the hub address first." }
            guard !self.server.phoneNames.isEmpty else { return "No phone connected right now; it gets the address next time it connects." }
            self.server.broadcast(Packet(command: "hubConfig", text: hub))
            return "Sent to \(self.server.phoneNames.joined(separator: ", "))."
        }
        model.applyNotchMode = { [weak self] in self?.applyNotchMode() }
        model.setAvatarWindow = { [weak self] on in
            guard let self else { return }
            if on, !self.settings.hidden { self.avatarWindow.show() } else { self.avatarWindow.hide() }
        }
        model.registerShortcuts = { [weak self] in self?.registerShortcuts() ?? [] }
        model.pairPhone = { [weak self] in self?.pairPhone() }
        model.editPersonality = { [weak self] in self?.editPersonality() }
        model.allowComputerControl = { [weak self] in self?.allowComputerControl() }
        model.computerControlChanged = { [weak self] in self?.restartIfAwake() }  // his tools change with it
        model.activityRunning = { [weak self] in self?.bridge.activityRunning ?? false }
        model.startActivityWatch = {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/ActivityWatch.app"), configuration: NSWorkspace.OpenConfiguration())
        }
        model.servicesChanged = { [weak self] in
            self?.workspace.refreshModels()
            self?.restartIfAwake()
        }
        return model
    }()
    private lazy var settingsWindow = SettingsWindowController(model: settingsModel)

    @objc func openSettings() { settingsWindow.show() }
    @objc private func toggleQuickNotes() { quickNotes.toggle() }

    /// Menu item that shows its global shortcut (⌃⌥ + key) when given one.
    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = [.control, .option]
        item.target = self
        return item
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}

/// The little blueberry blob with eyes for the menu bar.
enum MenuIcon {
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 18), flipped: true) { rect in
            let body = NSBezierPath(ovalIn: NSRect(x: 1, y: 2, width: 20, height: 16))
            NSGradient(colors: Palette.gradient.map { NSColor(hex: $0) })?.draw(in: body, angle: -60)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: 5, y: 6, width: 5.5, height: 5.5)).fill()
            NSBezierPath(ovalIn: NSRect(x: 11.5, y: 6, width: 5.5, height: 5.5)).fill()
            NSColor(hex: Palette.ink).setFill()
            NSBezierPath(ovalIn: NSRect(x: 6.3, y: 6.8, width: 3, height: 3)).fill()
            NSBezierPath(ovalIn: NSRect(x: 12.8, y: 6.8, width: 3, height: 3)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
