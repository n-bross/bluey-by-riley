import AppKit
import GooglyShared

/// The Mac owns the clock, check cadence and cancellation. The phone only sends commands
/// and renders authoritative snapshots. Generation guards discard every late callback.
@MainActor
final class FocusCompanion {
    private(set) var current: FocusSession?
    private(set) var history: [FocusSession] = []
    var onChange: ((FocusSync) -> Void)?
    var onNudge: ((String, Target?) -> Void)?
    /// Called every tick while focus runs, and once whenever it pauses or ends (for ActivityWatch).
    var onActivity: ((FocusSession) -> Void)?
    /// Pomodoro moments he should announce: off to a break, break's over.
    var onPomodoro: ((String) -> Void)?

    // MARK: Pomodoro state
    private(set) var pomodoro = PomodoroRhythm()
    /// The break in progress, if any. Breaks need no phone and no screen checks.
    private(set) var rest: PomodoroBreak?
    /// Focus rounds finished (by the timer) in the current cycle; a long break resets it.
    private(set) var completedRounds = 0
    /// The last focus task, so "next round" can pick it up again.
    private(set) var lastTask: String?
    private var lastBreakTick: Double?
    var connected = false
    private(set) var developerMode: Bool
    private let settings: UserDefaults?
    private var lastPing = -Double.infinity
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var lastCheck: Double = 0
    private var lastOnTaskFingerprint: String?
    private var lastOnTaskTime: Double = -Double.infinity
    private var policy = FocusNudgePolicy()
    private var timer: Timer?
    private var work: Task<Void, Never>?
    private var generation = UUID()
    private var revision = 0
    private let countdown = FocusCountdown()
    private var observers: [NSObjectProtocol] = []
    private let file: URL
    private let now: () -> Double
    private let permission: () -> Bool
    private let hasKey: () -> Bool
    private let capture: () async throws -> ScreenSnapshot
    private let classify: (ScreenSnapshot, FocusSession, Double) async throws -> FocusDecision
    private let prepareNudge: (ScreenSnapshot, String) async throws -> FocusAPI.Nudge
    private let screenUnlocked: () -> Bool
    private let showsCountdown: Bool
    private let steering: FocusSteering?

    init(now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
         permission: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
         hasKey: @escaping () -> Bool = { MainActor.assumeIsolated { AIServices.isFocusConfigured } },
         screenUnlocked: @escaping () -> Bool = {
            let session = CGSessionCopyCurrentDictionary() as? [String: Any]
            return session?["CGSSessionScreenIsLocked"] as? Bool != true && session?["kCGSessionOnConsoleKey"] as? Bool != false
         },
         capture: @escaping () async throws -> ScreenSnapshot = { try await ScreenReader.snapshot(preferForegroundDisplay: true) },
         classify: @escaping (ScreenSnapshot, FocusSession, Double) async throws -> FocusDecision = { try await FocusAPI.classify($0, session: $1, idle: $2) },
         prepareNudge: @escaping (ScreenSnapshot, String) async throws -> FocusAPI.Nudge = { try await FocusAPI.nudge($0, task: $1) },
         showsCountdown: Bool = true, steering: FocusSteering? = nil,
         historyFile: URL? = nil, settings: UserDefaults? = .standard) {
        self.now = now; self.permission = permission; self.hasKey = hasKey
        self.capture = capture; self.classify = classify; self.screenUnlocked = screenUnlocked
        self.prepareNudge = prepareNudge
        self.steering = steering
        self.showsCountdown = showsCountdown; self.lastTick = now()
        self.settings = settings; self.developerMode = settings?.bool(forKey: "focusDeveloperMode") ?? false
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Googly")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        file = historyFile ?? dir.appendingPathComponent("focus-history.json")
        history = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([FocusSession].self, from: $0) } ?? []
        if let data = settings?.data(forKey: "pomodoro"), let saved = try? JSONDecoder().decode(PomodoroRhythm.self, from: data) {
            pomodoro = saved.clamped()
        }
    }
    func startService() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        for name in ["com.apple.screenIsLocked"] {
            observers.append(DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name(name), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.pause("Mac locked. Resume when you're ready.") }
            })
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.pause("Mac sleeping or locked. Resume when you're ready.") }
            })
        }
    }
    func shutdown() { pause("Bluey closed"); timer?.invalidate(); cancel() }
    func heartbeat() { lastPing = now(); connected = true; if !monitoring { publish() } }
    func disconnected() { connected = false; pause("Phone disconnected. Reconnect, then resume.") }
    func sync() { publish() }
    var monitoring: Bool { current?.status == .running }
    var hasSession: Bool { current != nil && current?.status != .ended }

    @discardableResult func setDeveloperMode(_ enabled: Bool) -> String {
        guard enabled != developerMode else { return "Developer Mode is already \(enabled ? "on" : "off")." }
        if monitoring { advanceClock() }
        cancel()
        developerMode = enabled; settings?.set(enabled, forKey: "focusDeveloperMode")
        if hasSession {
            current?.setDeveloperMode(enabled)
            current?.detail = enabled ? "Developer Mode: clock 4×, next check in 10 seconds" : "Normal speed. Next check in 15 seconds"
        }
        policy = FocusNudgePolicy(maximumGap: (current?.observationDuration ?? (enabled ? 40 : 15)) * 1.5,
                                  developerMode: enabled)
        lastTick = now(); lastCheck = current?.elapsed ?? 0
        if current?.status == .ended { finish(timeUp: true) } else { publish(); persist() }
        return enabled ? "Developer Mode on: clock 4×, checks every 10 seconds." : "Developer Mode off: normal clock, checks every 15 seconds."
    }

    /// The default focus length: the Pomodoro round when Pomodoro is on, otherwise 30 minutes.
    var defaultMinutes: Double { pomodoro.enabled ? pomodoro.focusMinutes : 30 }

    @discardableResult func start(task: String, minutes requested: Double? = nil) -> String {
        let task = task.trimmingCharacters(in: .whitespacesAndNewlines)
        let minutes = requested ?? defaultMinutes
        guard !task.isEmpty else { return "Tell me the task first." }
        guard minutes.isFinite else { return "Use a duration between 1 and 240 minutes." }
        guard !hasSession else { return "There's already a focus session. End it before starting another." }
        guard freshConnection else { return "Connect the paired phone first." }
        guard permission() else { return "Screen Recording is off. Enable Bluey in System Settings > Privacy & Security > Screen Recording, then reopen Bluey." }
        guard hasKey() else { return AIServices.missingFocusMessage }
        cancel()
        lastOnTaskFingerprint = nil; lastOnTaskTime = -Double.infinity
        let skipped = rest != nil
        rest = nil; lastBreakTick = nil; lastTask = task
        steering?.reset()
        current = FocusSession(task: task, duration: min(240, max(1, minutes)) * 60, developerMode: developerMode)
        policy = FocusNudgePolicy(maximumGap: current!.observationDuration * 1.5, developerMode: developerMode)
        lastTick = now(); lastCheck = 0
        publish(); persist()
        let round = pomodoro.enabled ? " Round \(completedRounds + 1) of \(pomodoro.roundsBeforeLongBreak)." : ""
        return (skipped ? "Break skipped. " : "") + "Focus started: \(task), \(Int(min(240, max(1, minutes)))) minutes.\(round)"
    }
    @discardableResult func pause(_ reason: String = "Paused") -> String {
        // Breaks never pause (lock, sleep, the phone going to the background): being away is the point.
        if current?.status != .running, rest != nil { return "The break keeps running. Say skip to end it early." }
        guard current?.status == .running else { return "Focus is already paused or ended." }
        advanceClock(); current?.pause(reason); cancel(); policy.reset(); publish(); persist()
        if let current { onActivity?(current) }
        return "Focus paused."
    }
    @discardableResult func resume() -> String {
        guard current?.status == .paused else { return "There's no paused focus session." }
        guard freshConnection else { return "Reconnect the paired phone before resuming." }
        guard permission() else { return "Screen Recording permission is missing. Enable it in System Settings, then reopen Bluey." }
        current?.resume(); policy.reset(); cancel()
        lastTick = now(); lastCheck = current?.elapsed ?? 0
        publish(); persist(); return "Focus resumed."
    }
    @discardableResult func end() -> String {
        guard hasSession else { return "There's no running focus session." }
        if !hasSession, rest != nil { return skipBreak() }
        advanceClock(); current?.end(); finish(timeUp: false); return "Focus finished. Your timeline is on the phone."
    }
    @discardableResult func testNudge() -> String {
        guard developerMode, freshConnection else { return "Enable Developer Mode and connect the phone first." }
        onNudge?("Oi, back to the mission. This is your test nudge.", nil)
        return "Test nudge sent to the Mac and phone."
    }
    private var freshConnection: Bool { connected && now() - lastPing < 5 }
    private var unlocked: Bool { screenUnlocked() }
    private var allowed: Bool { monitoring && freshConnection && unlocked && permission() }
    private func cancel() { generation = UUID(); work?.cancel(); work = nil }
    private func advanceClock() {
        let now = now()
        let delta = now - lastTick; lastTick = now
        // A suspended run loop is not evidence of active focus time.
        if delta <= 3 { current?.advance(delta) }
    }
    func tick() {
        tickBreak()
        guard monitoring else { return }
        guard freshConnection else { pause("Phone disconnected. Reconnect, then resume."); return }
        guard unlocked else { pause("Mac locked. Resume when ready."); return }
        guard permission() else { pause("Screen Recording permission lost. Enable it, then reopen Bluey."); return }
        if now() - lastTick > 3 { pause("Mac was inactive. Resume when ready."); return }
        advanceClock()
        if current?.status == .ended { finish(timeUp: true); return }
        publish()
        if let current { onActivity?(current) }
        steering?.enforce()
        if let session = current, session.elapsed - lastCheck >= session.observationDuration, work == nil {
            lastCheck = session.elapsed
            check(session: session)
        }
    }
    private func check(session: FocusSession) {
        let token = generation
        let began = now()
        work = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.work = nil } }
            do {
                guard self.allowed else { return }
                let context = self.steering?.frontContext()
                let screen = try await self.capture()
                guard self.allowed, self.generation == token, !Task.isCancelled else { return }
                let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max) ?? .null)
                let fingerprint = (screen.app ?? "") + "|" + screen.lines.prefix(30).map(\.line.text).joined(separator: "\n")
                let answer: FocusDecision
                if Settings.shared.focusSkipUnchanged,
                   !fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   fingerprint == self.lastOnTaskFingerprint,
                   began - self.lastOnTaskTime < 90 {
                    answer = FocusDecision(activity: .onTask, probability: 0.05, confidence: 0.9, probabilities: ["on_task": 0.9], distraction: nil)
                } else {
                    answer = try await self.classify(screen, session, idle.isFinite ? idle : 0)
                    if answer.activity == .onTask {
                        self.lastOnTaskFingerprint = fingerprint
                        self.lastOnTaskTime = self.now()
                    } else {
                        self.lastOnTaskFingerprint = nil
                    }
                }
                guard self.allowed, self.generation == token, !Task.isCancelled else { return }
                let age = now() - began
                let activity: FocusActivity = age <= 20 ? answer.activity : .unavailable
                let app = screen.app?.trimmingCharacters(in: .whitespacesAndNewlines)
                var check = FocusCheck(elapsed: session.elapsed, activity: activity,
                                       probability: answer.probability, confidence: answer.confidence,
                                       probabilities: age <= 20 ? answer.probabilities : nil,
                                       sampleDuration: session.observationDuration,
                                       distraction: activity == .offTask ? answer.distraction : nil,
                                       distractionApp: activity == .offTask ? app.flatMap { $0.isEmpty ? nil : $0 } : nil)
                let shouldNudge = self.policy.observe(check, age: age)
                if check.activity == .onTask, let context {
                    self.steering?.remember(context)
                }
                self.current?.detail = age > 20 ? "Last check was stale; skipped" : answer.activity == .uncertain ? "Not enough context to judge" : answer.activity == .onTask ? "On task" : "Off task · checking again before nudging"
                self.current?.checks.append(check)
                self.publish(); self.persist()
                if shouldNudge {
                    // Fresh evidence, separate API. Its output can only show a bubble or point.
                    guard self.allowed else { return }
                    var nudge = FocusAPI.Nudge(message: "Are you sure you're on task right now?", target: nil)
                    var target: Target?
                    self.current?.detail = "Off task · preparing a gentle nudge"; self.publish()
                    do {
                        let fresh = try await self.capture()
                        guard self.allowed, self.generation == token, !Task.isCancelled else { return }
                        let capturedAt = now()
                        let app = NSWorkspace.shared.frontmostApplication?.processIdentifier
                        nudge = try await self.prepareNudge(fresh, session.task)
                        if fresh.isOnMainDisplay, let candidate = nudge.target, now() - capturedAt < 15,
                           app == NSWorkspace.shared.frontmostApplication?.processIdentifier {
                            // Re-read locally to reject a stale target after a tab, scroll or layout change.
                            if let verify = try? await self.capture(), verify.isOnMainDisplay {
                                target = verify.lines.map(\.line).first { $0.text == candidate.text &&
                                    abs($0.rect.midX - candidate.rect.midX) < 10 && abs($0.rect.midY - candidate.rect.midY) < 10 }
                            }
                        }
                    } catch {
                        // A failed extra capture or wording request must still deliver the fallback bubble.
                        self.current?.detail = "Off task · using a gentle reminder"
                    }
                    guard self.allowed, self.generation == token, !Task.isCancelled else { return }
                    self.onNudge?(nudge.message, target)
                    if answer.probability >= 0.8, let context { self.steering?.interrupt(context) }
                    self.current?.detail = "Off task · Bluey nudged you"
                    check.nudged = true
                    if let index = self.current?.checks.firstIndex(where: { $0.id == check.id }) { self.current?.checks[index] = check }
                    self.publish(); self.persist()
                }
            } catch {
                guard self.allowed, self.generation == token, !Task.isCancelled else { return }
                self.policy.reset()
                self.current?.checks.append(FocusCheck(elapsed: session.elapsed, activity: .unavailable,
                                                      sampleDuration: session.observationDuration))
                self.current?.detail = "Check unavailable: \(error.localizedDescription.prefix(180))"
                self.publish(); self.persist()
                // Authentication/permission issues need intervention, not repeated paid calls.
                if (error as? FocusAPI.Failure) != nil { self.pause(self.current?.detail ?? "OpenAI unavailable") }
            }
        }
    }
    /// `timeUp`: the timer ran out (a finished Pomodoro round), rather than you ending it early.
    private func finish(timeUp: Bool) {
        cancel(); policy.reset(); steering?.reset()
        if let current {
            history.removeAll { $0.id == current.id }; history.insert(current, at: 0)
            history = Array(history.prefix(30))
        }
        if timeUp, pomodoro.enabled, let session = current {
            completedRounds += 1
            let kind = pomodoro.breakKind(afterRound: completedRounds)
            let minutes = Int(pomodoro.breakMinutes(kind))
            if pomodoro.autoStartBreaks {
                startBreak(kind: kind, task: session.task)
                onPomodoro?(kind == .long
                    ? "Round \(completedRounds) done, that's the set! Proper \(minutes)-minute break now: get up, move about, no screens."
                    : "Time's up, round \(completedRounds) done. Off you pop for \(minutes) minutes: stand up, stretch, have some water.")
            } else {
                onPomodoro?("Round \(completedRounds) done. Fancy a \(minutes)-minute break? Say \"break\" or tap Break.")
            }
        }
        publish(); persist()
        if let current { onActivity?(current) }
    }

    // MARK: Pomodoro

    private func startBreak(kind: PomodoroBreak.Kind, task: String) {
        rest = PomodoroBreak(kind: kind, minutes: pomodoro.breakMinutes(kind), round: completedRounds, task: task,
                             clockRate: developerMode ? 4 : 1)
        lastBreakTick = now()
    }

    /// Starts a break now (after a round, or whenever you ask). Ends a running focus session first.
    @discardableResult func takeBreak() -> String {
        if rest != nil { return "You're already on a break." }
        var task = lastTask ?? current?.task ?? ""
        if hasSession {
            task = current?.task ?? task
            advanceClock(); current?.end(); finish(timeUp: false)
        }
        let kind = pomodoro.breakKind(afterRound: max(completedRounds, 1))
        startBreak(kind: kind, task: task)
        publish()
        return "\(rest?.title ?? "Break") started: \(Int(pomodoro.breakMinutes(kind))) minutes. No screen checks until it's over."
    }

    @discardableResult func skipBreak() -> String {
        guard let r = rest else { return "There's no break to skip." }
        rest = nil; lastBreakTick = nil
        if r.kind == .long { completedRounds = 0 }
        publish()
        if pomodoro.autoStartFocus, !r.task.isEmpty { return "Break skipped. " + start(task: r.task) }
        return "Break skipped. Ready when you are."
    }

    private func tickBreak() {
        guard var r = rest else { return }
        let t = now()
        let delta = t - (lastBreakTick ?? t)
        lastBreakTick = t
        // Long gaps (sleep) still count: you were away, which is the point of a break.
        let finished = r.advance(min(max(delta, 0), 3600))
        rest = r
        guard finished else {
            if Int(t) != Int(t - delta) { publish() }  // about once a second for the countdowns
            return
        }
        rest = nil; lastBreakTick = nil
        if r.kind == .long { completedRounds = 0 }
        let next = completedRounds + 1
        let task = r.task.isEmpty ? nil : r.task
        if pomodoro.autoStartFocus, let task {
            let result = start(task: task)
            onPomodoro?(result.hasPrefix("Focus started")
                ? "Break's over! Round \(next) on \"\(task.prefix(60))\" starts now."
                : "Break's over! I couldn't start round \(next): \(result)")
        } else {
            onPomodoro?(task.map { "Break's over! Ready for round \(next) on \"\($0.prefix(60))\"? Say \"go\" or tap Focus." }
                        ?? "Break's over! Ready for the next round?")
        }
        publish()
    }

    /// Changes the rhythm. Takes effect from the next round or break.
    @discardableResult func setPomodoro(_ settings: PomodoroRhythm) -> String {
        let clean = settings.clamped()
        pomodoro = clean
        if let data = try? JSONEncoder().encode(clean) { self.settings?.set(data, forKey: "pomodoro") }
        if completedRounds >= clean.roundsBeforeLongBreak { completedRounds = 0 }
        publish()
        return clean.enabled ? "Pomodoro set: \(clean.summary)." : "Pomodoro off: focus sessions just end, no breaks."
    }

    /// One line for his status tool and Hermes.
    var pomodoroStatus: String {
        var parts = [pomodoro.summary + "."]
        if pomodoro.enabled { parts.append("Rounds done this cycle: \(completedRounds) of \(pomodoro.roundsBeforeLongBreak).") }
        if let r = rest { parts.append("\(r.title)\(r.paused ? " (paused)" : ""): \(FocusSession.clock(r.remaining)) left.") }
        return parts.joined(separator: " ")
    }

    /// Stores ActivityWatch's summary on the session it belongs to (current or a finished one).
    func attachActivity(_ summary: ActivitySummary, to id: UUID) {
        if current?.id == id { current?.activity = summary }
        if let i = history.firstIndex(where: { $0.id == id }) { history[i].activity = summary }
        publish(); persist()
    }
    private func persist() {
        var saved = history
        if var session = current, session.status != .ended {
            session.status = .ended; session.detail = "App closed or restarted"
            saved.removeAll { $0.id == session.id }; saved.insert(session, at: 0)
        }
        if let data = try? JSONEncoder().encode(Array(saved.prefix(30))) {
            try? data.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }
    private func publish() {
        revision += 1
        if showsCountdown { countdown.update(current, rest: rest) }
        onChange?(FocusSync(current: current, history: history, revision: revision, developerMode: developerMode,
                            pomodoro: pomodoro, rest: rest, completedRounds: completedRounds))
    }
}

@MainActor
private final class FocusCountdown {
    private var window: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private let modeLabel = NSTextField(labelWithString: "")
    func update(_ session: FocusSession?, rest: PomodoroBreak? = nil) {
        let active = session.flatMap { $0.status == .ended ? nil : $0 }
        guard active != nil || rest != nil else { window?.orderOut(nil); return }
        if window == nil, let screen = NSScreen.screens.first {
            let panel = NSPanel(contentRect: CGRect(x: screen.visibleFrame.maxX - 452, y: screen.visibleFrame.minY + 24, width: 420, height: 132),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
            panel.level = .floating; panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            label.frame = CGRect(x: 0, y: 0, width: 420, height: 108)
            label.font = .monospacedDigitSystemFont(ofSize: 76, weight: .semibold)
            label.textColor = .white; label.alignment = .right
            modeLabel.frame = CGRect(x: 0, y: 108, width: 420, height: 20)
            modeLabel.font = .systemFont(ofSize: 12, weight: .medium)
            modeLabel.textColor = .white; modeLabel.alignment = .right
            panel.contentView?.addSubview(label); panel.contentView?.addSubview(modeLabel); window = panel
        }
        if let session = active {
            label.stringValue = (session.status == .paused ? "Ⅱ " : "") + FocusSession.clock(session.remaining)
            label.textColor = .white
            modeLabel.stringValue = session.isDeveloperMode ? "DEVELOPER MODE · 4×" : ""
        } else if let rest {
            // Break: green, so it's clear at a glance this isn't work time.
            label.stringValue = (rest.paused ? "Ⅱ " : "☕︎ ") + FocusSession.clock(rest.remaining)
            label.textColor = NSColor(hex: 0x5BE49B)
            modeLabel.stringValue = rest.kind == .long ? "LONG BREAK" : "BREAK"
        }
        window?.orderFrontRegardless()
    }
}
