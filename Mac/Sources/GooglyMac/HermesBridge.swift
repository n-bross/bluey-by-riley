import AppKit
import GooglyShared

/// Glue between Hermes, ActivityWatch, focus sessions, the phone and the menu bar.
/// - Keeps the phone's Hermes screen in sync (`hermesState` broadcasts) and runs its requests.
/// - Gives Hermes context with every request: the focus task and today's real activity.
/// - Puts focus sessions on ActivityWatch's timeline and stores each session's active time and top apps.
@MainActor
final class HermesBridge: NSObject {
    let hermes = HermesGateway()
    let journal = ActivityJournal()
    private let server: PhoneServer
    private let host: RealtimeHost
    private let focus: FocusCompanion

    private(set) var today: ActivitySummary?
    private(set) var activityRunning = false
    private var lastHeartbeat = Date.distantPast
    private var lastSessionSummary = Date.distantPast
    private var timer: Timer?
    private var presenceTimer: Timer?
    private var broadcastWork: DispatchWorkItem?
    /// Hermes changed (for the notch).
    var onHermesChange: (() -> Void)?
    /// Tries to tell him a note out loud on the Mac; returns false if he isn't listening there.
    var deliverNote: ((String) -> Bool)?
    /// Current or most recent meeting notes context for Hermes.
    var meetingContext: (() -> String?)?

    init(server: PhoneServer, host: RealtimeHost, focus: FocusCompanion) {
        self.server = server; self.host = host; self.focus = focus
        super.init()
    }

    func start() {
        host.hermes = hermes
        journal.hermes = hermes
        journal.focusHistory = { [weak self] in
            guard let self else { return [] }
            return self.focus.history + (self.focus.current.map { [$0] } ?? [])
        }
        host.journal = { [weak self] day, from, to in
            guard let self else { return "Bluey is closing." }
            guard let date = ActivityJournal.resolveDay(day) else { return "I couldn't tell which day that is. Use today, yesterday, a weekday or YYYY-MM-DD." }
            do { return try await self.journal.markdown(for: date, from: from, to: to) }
            catch { return "ActivityWatch isn't running on the Mac, so I can't see that. (\(error.localizedDescription))" }
        }
        hermes.context = { [weak self] in await self?.contextForHermes() }
        hermes.onChange = { [weak self] in self?.scheduleBroadcast() }
        hermes.onEvent = { [weak self] event in self?.hermesEvent(event) }
        focus.onActivity = { [weak self] session in self?.focusActivity(session) }

        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshAll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // Bluey's own presence heartbeat (reliable active time), every 30 seconds.
        let presence = Timer(timeInterval: 30, repeats: true) { _ in Task { await ActivityWatch.presenceHeartbeat() } }
        RunLoop.main.add(presence, forMode: .common)
        presenceTimer = presence
        Task { await ActivityWatch.presenceHeartbeat(); await refreshAll() }
    }

    func refreshAll() async {
        await hermes.refresh()
        await refreshActivity()
        scheduleBroadcast()
        await journal.update()
    }

    func refreshActivity() async {
        do {
            today = try await ActivityWatch.today()
            activityRunning = true
        } catch {
            activityRunning = await ActivityWatch.isRunning()
        }
    }

    // MARK: Phone

    var state: HermesSync {
        hermes.sync(today: today, activityAvailable: activityRunning)
    }

    private func scheduleBroadcast() {
        onHermesChange?()
        broadcastWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.broadcast() }
        broadcastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func broadcast() {
        guard let data = try? JSONEncoder().encode(state), let text = String(data: data, encoding: .utf8) else { return }
        server.broadcast(Packet(command: "hermesState", text: text))
    }

    /// Requests from the phone's Hermes screen. Returns false if the packet isn't one of ours.
    func handle(_ packet: Packet, reply: @escaping (Packet) -> Void) -> Bool {
        guard let command = packet.command, command.hasPrefix("hermes") || command == "activityRefresh" else { return false }
        let args = packet.text.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
        Task { @MainActor in
            var result = ""
            switch command {
            case "hermesSync", "activityRefresh":
                await self.refreshAll()
            case "hermesSend":
                let text = (args["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { result = "Type something for Hermes first." }
                else { let run = await self.hermes.send(text); result = run.status == .failed ? (run.output ?? "Failed.") : "Sent to Hermes." }
            case "hermesRespond":
                result = await self.hermes.respond(runID: args["run"] as? String ?? "", promptID: args["prompt"] as? String ?? "",
                                                   choice: args["choice"] as? String ?? "deny")
            case "hermesMode":
                if let mode = HermesApprovalMode(rawValue: args["mode"] as? String ?? "") {
                    self.hermes.mode = mode; result = "Approvals: \(mode.title)."
                }
            case "hermesStop":
                result = await self.hermes.stop(args["run"] as? String)
            default:
                break
            }
            reply(Packet(command: "hermesReply", callID: packet.callID, text: result))
            self.scheduleBroadcast()
        }
        return true
    }

    /// A run finished or needs you. Awake, he hears about it and says it himself; asleep, a bubble and a chirp.
    private func hermesEvent(_ event: HermesGateway.Event) {
        let (note, line, needsYou): (String, String, Bool) = {
            switch event {
            case .finished(let note, let line): return (note, line, false)
            case .needsYou(let note, let line): return (note, line, true)
            }
        }()
        if deliverNote?("Hermes update: " + note) == true { return }
        if host.awake, !server.phoneNames.isEmpty {
            server.broadcast(Packet(command: "codexNote", text: "Hermes update: " + note))
            return
        }
        host.showReply(line)
        server.broadcast(Packet(command: needsYou ? "hermesChirp" : "codexChirp", text: line))
    }

    // MARK: Context for Hermes

    private func contextForHermes() async -> String? {
        var lines: [String] = []
        let f = DateFormatter(); f.dateStyle = .full; f.timeStyle = .short
        lines.append("Now: \(f.string(from: Date())).")
        if let session = focus.current, session.status != .ended {
            lines.append("Current focus session: \"\(session.task)\", \(session.status.rawValue), \(FocusSession.clock(session.remaining)) left.")
        }
        let recent = focus.history.prefix(5).map { s -> String in
            let active = s.activity.map { ", active \(ActivitySummary.duration($0.activeSeconds))" } ?? ""
            return "\"\(s.task.prefix(80))\" \(s.startedAt.formatted(date: .abbreviated, time: .shortened)), \(Int(s.realActiveElapsed / 60)) min\(active)"
        }
        if !recent.isEmpty { lines.append("Recent focus sessions: " + recent.joined(separator: "; ") + ".") }
        if Date().timeIntervalSince(today?.to ?? .distantPast) > 120 { await refreshActivity() }
        if let today { lines.append("ActivityWatch today: " + today.plainText) }
        if let meeting = meetingContext?(), !meeting.isEmpty {
            lines.append(meeting)
        } else {
            lines.append("Meeting notes & transcripts folder: ~/Documents/Bluey Notes/.")
        }
        lines.append("Daily journals of what the user worked on (timeline, focus sessions, apps): ~/Documents/Bluey Journal/YYYY-MM-DD.md (today's is refreshed every 10 minutes).")
        lines.append("Full focus history (JSON): ~/Library/Application Support/Googly/focus-history.json. ActivityWatch API: http://localhost:5600/api/0/ (bucket \(ActivityWatch.focusBucket) holds Bluey's focus sessions).")
        return lines.joined(separator: "\n")
    }

    // MARK: Focus sessions ↔ ActivityWatch

    private func focusActivity(_ session: FocusSession) {
        let now = Date()
        if session.status == .running, now.timeIntervalSince(lastHeartbeat) >= 15 {
            lastHeartbeat = now
            let verdict = session.checks.last(where: { [.onTask, .offTask, .uncertain].contains($0.activity) })?.activity.rawValue
            Task { await ActivityWatch.focusHeartbeat(task: session.task, sessionID: session.id, status: "focus",
                                                      verdict: verdict, pulse: 45) }
        }
        // Active time for the session's window: every minute while it runs, and once when it pauses or ends.
        guard session.status != .running || now.timeIntervalSince(lastSessionSummary) >= 60 else { return }
        lastSessionSummary = now
        let id = session.id, from = session.startedAt
        Task { @MainActor in
            guard let summary = try? await ActivityWatch.summary(from: from, to: now) else { return }
            self.focus.attachActivity(summary, to: id)
        }
    }

    // MARK: Menu

    func menuItem(target: AnyObject) -> NSMenuItem {
        let menu = NSMenu()
        let headline: String
        if HermesGateway.config() == nil { headline = "Not connected" }
        else if hermes.available { headline = "Connected" }
        else { headline = hermes.problem ?? "Not reachable" }
        let status = NSMenuItem(title: headline, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if let today {
            let t = NSMenuItem(title: "Today: active \(ActivitySummary.duration(today.activeSeconds))" +
                               (today.apps.first.map { " · most in \($0.name)" } ?? ""), action: nil, keyEquivalent: "")
            t.isEnabled = false
            menu.addItem(t)
        } else if !activityRunning {
            menu.addItem(action("Start ActivityWatch", #selector(startActivityWatch)))
        }
        menu.addItem(.separator())
        for (run, prompt) in hermes.waitingForYou.prefix(3) {
            let title = NSMenuItem(title: (prompt.kind == .approval ? "Wants to run: " : "Asks: ") + String(prompt.text.prefix(60)), action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)
            let choices = prompt.kind == .approval ? prompt.choices : (prompt.choices.isEmpty ? [] : prompt.choices)
            for choice in choices {
                let c = action("   " + HermesPrompt.choiceTitle(choice), #selector(respondFromMenu(_:)))
                c.representedObject = [run.id, prompt.id, choice]
                menu.addItem(c)
            }
            if prompt.kind == .clarify {
                let c = action("   Answer…", #selector(answerFromMenu(_:)))
                c.representedObject = [run.id, prompt.id]
                menu.addItem(c)
            }
        }
        if !hermes.waitingForYou.isEmpty { menu.addItem(.separator()) }
        menu.addItem(action("Ask Hermes…", #selector(askFromMenu)))
        for run in hermes.runs.suffix(6).reversed() {
            let icon: String
            switch run.status {
            case .completed: icon = "✓"
            case .failed, .cancelled: icon = "✕"
            case .waiting: icon = "⏸"
            default: icon = "…"
            }
            let r = action("\(icon) \(run.prompt.prefix(44))", #selector(showRun(_:)))
            r.representedObject = run.id
            menu.addItem(r)
        }
        menu.addItem(.separator())
        let approvals = NSMenu()
        for mode in HermesApprovalMode.allCases {
            let m = action(mode.title, #selector(setMode(_:)))
            m.representedObject = mode.rawValue
            m.state = hermes.mode == mode ? .on : .off
            approvals.addItem(m)
        }
        let approvalsItem = NSMenuItem(title: "Risky Steps: \(hermes.mode.title)", action: nil, keyEquivalent: "")
        approvalsItem.submenu = approvals
        menu.addItem(approvalsItem)
        menu.addItem(action("Connect…", #selector(connect)))
        let item = NSMenuItem(title: hermes.waitingForYou.isEmpty ? "Hermes" : "Hermes (waiting for you)", action: nil, keyEquivalent: "")
        item.submenu = menu
        Task { await refreshAll() }
        return item
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func respondFromMenu(_ item: NSMenuItem) {
        guard let parts = item.representedObject as? [String], parts.count == 3 else { return }
        Task { _ = await hermes.respond(runID: parts[0], promptID: parts[1], choice: parts[2]) }
    }

    @objc private func answerFromMenu(_ item: NSMenuItem) {
        guard let parts = item.representedObject as? [String], parts.count == 2,
              let answer = ask("Answer Hermes", info: hermes.waitingForYou.first { $0.prompt.id == parts[1] }?.prompt.text ?? "") else { return }
        Task { _ = await hermes.respond(runID: parts[0], promptID: parts[1], choice: answer) }
    }

    @objc private func askFromMenu() {
        guard let text = ask("Ask Hermes", info: "Messages, browser, computer, calendar, to-dos… Hermes does it with its own tools.") else { return }
        Task { await hermes.send(text) }
    }

    @objc private func showRun(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String, let run = hermes.runs.first(where: { $0.id == id }) else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = String(run.prompt.prefix(200))
        alert.informativeText = run.output ?? (run.isActive ? "Hermes is still working on this." : run.status.rawValue)
        alert.addButton(withTitle: "OK")
        if run.isActive { alert.addButton(withTitle: "Stop") }
        if alert.runModal() == .alertSecondButtonReturn { Task { _ = await hermes.stop(run.id) } }
    }

    @objc private func setMode(_ item: NSMenuItem) {
        if let raw = item.representedObject as? String, let mode = HermesApprovalMode(rawValue: raw) { hermes.mode = mode }
    }

    @objc private func startActivityWatch() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/ActivityWatch.app"),
                                           configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func connect() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Connect Hermes"
        alert.informativeText = "Bluey talks to Hermes' API server. Turn it on with `hermes config set API_SERVER_ENABLED true` and `hermes config set API_SERVER_KEY <secret>`, restart the gateway, then paste the same key here. Saved privately on this Mac."
        let url = NSTextField(frame: NSRect(x: 0, y: 30, width: 360, height: 24))
        url.stringValue = HermesGateway.config()?.url.absoluteString ?? "http://127.0.0.1:8642"
        let key = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        key.placeholderString = HermesGateway.config() == nil ? "API_SERVER_KEY" : "Key saved. Paste a new one to replace it."
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 54))
        box.addSubview(url); box.addSubview(key)
        alert.accessoryView = box
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newKey = key.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let finalKey = newKey.isEmpty ? HermesGateway.config()?.key : newKey else { return }
        HermesGateway.saveConfig(url: url.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), key: finalKey)
        Task { await refreshAll() }
    }

    private func ask(_ title: String, info: String) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Send")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

/// `GooglyMac --hermes-test ["request"]`: checks ActivityWatch and runs one real request through Hermes,
/// printing what the phone would see. Approvals in this probe are always denied.
@MainActor
enum HermesProbe {
    static func run(prompt: String) async -> Int32 {
        do {
            let today = try await ActivityWatch.today()
            print("ActivityWatch: " + today.plainText)
        } catch {
            print("ActivityWatch: \(error.localizedDescription)")
        }
        let gateway = HermesGateway()
        await gateway.refresh()
        guard gateway.available else { print("Hermes: \(gateway.problem ?? "unavailable")"); return 1 }
        print("Hermes: connected. Sending: \(prompt)")
        gateway.context = { "Probe from Bluey's --hermes-test; no user is watching." }
        let started = await gateway.send(prompt)
        var run = started
        let deadline = Date().addingTimeInterval(180)
        var handled: Set<String> = []
        while Date() < deadline {
            run = await gateway.wait(for: run.id, seconds: 5) ?? run
            if let (_, prompt) = gateway.waitingForYou.first(where: { $0.run.id == run.id && !handled.contains($0.prompt.id) }) {
                handled.insert(prompt.id)
                print("Hermes waits: \(prompt.kind.rawValue) \(prompt.text) → denying in probe")
                print(await gateway.respond(runID: run.id, promptID: prompt.id, choice: prompt.kind == .approval ? "deny" : "skip"))
            }
            if !run.isActive { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        print("Status: \(run.status.rawValue)\nOutput: \(run.output ?? "-")")
        return run.status == .completed ? 0 : 1
    }
}
