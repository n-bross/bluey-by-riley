import AppKit
import CoreGraphics
import Charts
import GooglyShared
import SwiftUI

@available(macOS 15, *)
@MainActor
final class MeetingWindow: ObservableObject {
    typealias Session = MeetingSession

    struct ToastMessage: Identifiable, Equatable {
        let id = UUID()
        var text: String
        var isError: Bool = false
        var openT3ProjectPath: String?
    }

    struct T3SendDraft: Identifiable {
        let id = UUID()
        var title: String
        var prompt: String
        var projectPath: String
        var worktreeBase: String = ""
        var linkedTaskID: UUID?
        var sourceQuote: String?
    }

    enum CenterTab: String, CaseIterable, Identifiable {
        case transcript = "Transkript"
        case notes = "Notizen"
        case files = "Ordner & Dateien"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .transcript: return "waveform.and.mic"
            case .notes: return "note.text"
            case .files: return "folder"
            }
        }
        var shortcutHint: String {
            switch self {
            case .transcript: return "⌘1"
            case .notes: return "⌘2"
            case .files: return "⌘3"
            }
        }
    }

    enum RailTab: String, CaseIterable, Identifiable {
        case tasks = "Aufgaben"
        case assistant = "Bluey Q&A"
        var id: String { rawValue }
        var icon: String { self == .tasks ? "checklist" : "sparkles" }
    }

    private enum DefaultsKey {
        static let recordVideo = "bluey.meeting.recordVideo"
        static let autoScreenshots = "bluey.meeting.autoScreenshots"
    }

    /// Fires whenever recording starts `(true, startedAt)` or stops `(false, nil)`.
    var onRecordingStateChanged: ((Bool, Date?) -> Void)?
    var onOpenNote: ((UUID) -> Void)?
    var onNewInkNote: (() -> Void)?
    var onOpenScreenAnnotator: (() -> Void)?

    @Published private(set) var session: Session?
    @Published private(set) var archive: [Session] = []
    @Published private(set) var now = Date()
    @Published private(set) var status = ""
    @Published private(set) var error: String?
    @Published private(set) var visualWarning: String?
    @Published private(set) var takingScreenshot = false
    @Published var toast: ToastMessage?
    @Published private(set) var recording = false
    @Published private(set) var changingCapture = false
    @Published private(set) var transcribing = false
    @Published private(set) var answering = false
    @Published private(set) var extractingTasks = false
    @Published private(set) var sendingToT3 = false
    @Published private(set) var sendingTaskID: UUID?
    @Published private(set) var answer = ""
    @Published private(set) var notesSaveState = ""

    @Published var centerTab: CenterTab = .transcript
    @Published var railTab: RailTab = .tasks
    @Published var showSidebar = true
    @Published var projects: [T3CodeProject] = []
    @Published var selectedProjectPath: String = ""
    @Published var openT3AfterSend: Bool = T3CodeBridge.openAppAfterSend {
        didSet { T3CodeBridge.openAppAfterSend = openT3AfterSend }
    }
    @Published var t3Draft: T3SendDraft?
    @Published var showTimeOverview = false
    @Published var showShortcutsHelp = false

    /// Focus triggers for keyboard shortcuts.
    @Published var focusQuestionToken = 0
    @Published var focusTaskToken = 0
    @Published var focusSearchToken = 0

    /// Optional hooks into Bluey's main workspace (wired by AppDelegate).
    var addWorkspaceTodo: ((String, String) -> Void)?
    var addWorkspaceNote: ((String, String) -> Void)?

    @Published var recordVideo: Bool {
        didSet { UserDefaults.standard.set(recordVideo, forKey: DefaultsKey.recordVideo) }
    }
    @Published var autoScreenshots: Bool {
        didSet { UserDefaults.standard.set(autoScreenshots, forKey: DefaultsKey.autoScreenshots) }
    }
    @Published var selectedTarget: MeetingAudio.CaptureTarget = .display
    @Published private(set) var availableTargets: [MeetingAudio.CaptureTarget] = [.display]

    var busy: Bool { recording || changingCapture || transcribing || answering || extractingTasks || sendingToT3 }
    var isTrackingTime: Bool { recording || session?.isTimerRunning == true }

    var activeTimerBadgeText: String? {
        guard let session, recording || session.isTimerRunning else { return nil }
        return MeetingDurationFormatter.stopwatch(session.trackedDuration(at: now))
    }

    var allTimeSummaries: [MeetingTimeSummaryEntry] {
        var list: [MeetingTimeSummaryEntry] = []
        var seen = Set<UUID>()
        if let session {
            list.append(session.timeSummary(at: now))
            seen.insert(session.id)
        }
        for item in archive where !seen.contains(item.id) {
            list.append(item.timeSummary(at: now))
        }
        return list.sorted { $0.started > $1.started }
    }

    var timeStats: MeetingTimeStats {
        MeetingTimeStats.compute(from: allTimeSummaries, now: now)
    }

    var selectedProject: T3CodeProject? {
        projects.first { $0.path == selectedProjectPath } ?? projects.first
    }

    private var window: NSWindow?
    private var recorder: MeetingAudio?
    private var captureTimer: Task<Void, Never>?
    private var clockTimer: Timer?
    private var collecting: Task<Void, Never>?
    private var transcription: Task<Void, Never>?
    private var notesSaveTask: Task<Void, Never>?
    private var toastClearTask: Task<Void, Never>?
    private var failedClips = Set<String>()
    private var hasSyncedLibraryOnce = false

    init() {
        let defaults = UserDefaults.standard
        recordVideo = defaults.object(forKey: DefaultsKey.recordVideo) as? Bool ?? true
        autoScreenshots = defaults.object(forKey: DefaultsKey.autoScreenshots) as? Bool ?? true
        MeetingNotes.ensureLibraryFolders()
        refreshProjects()
        reloadArchive(syncExports: false)
    }

    func show(openT3Composer: Bool = false) {
        if window == nil {
            let controller = NSHostingController(rootView: MeetingView(model: self))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1140, height: 740),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Bluey · Call-Notizen"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(hex: 0x0D0C14)
            window.minSize = NSSize(width: 860, height: 580)
            window.contentViewController = controller
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("BlueyMeetings")
            if !window.setFrameUsingName("BlueyMeetings") { window.center() }
            self.window = window
        }
        ensureEditMenu()
        refreshProjects()
        reloadArchive(syncExports: !hasSyncedLibraryOnce)
        hasSyncedLibraryOnce = true
        if session == nil, let latest = archive.first {
            session = latest
            syncSelectedProjectFromSession()
        }
        startClockIfNeeded()
        Task { await refreshTargets() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if openT3Composer {
            railTab = .tasks
            self.openT3Composer()
        }
    }

    /// Ensures Copy/Paste/Undo/Select All work even when the main workspace window isn't open.
    private func ensureEditMenu() {
        guard NSApp.mainMenu == nil else { return }
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let app = NSMenu()
        app.addItem(withTitle: "Bluey ausblenden", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(.separator())
        app.addItem(withTitle: "Bluey beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Bearbeiten")
        edit.addItem(withTitle: "Widerrufen", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Wiederholen", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Ausschneiden", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Kopieren", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Einsetzen", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Alles auswählen", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        let windowItem = NSMenuItem(); main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Fenster")
        windowMenu.addItem(withTitle: "Schließen", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        NSApp.mainMenu = main
    }

    private func startClockIfNeeded() {
        guard clockTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.isTrackingTime || self.window?.isVisible == true {
                    self.now = Date()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    func refreshProjects() {
        projects = T3CodeBridge.discoverProjects()
        if selectedProjectPath.isEmpty || !projects.contains(where: { $0.path == selectedProjectPath }) {
            selectedProjectPath = session?.t3ProjectPath ?? T3CodeBridge.lastProjectPath ?? projects.first?.path ?? ""
        }
    }

    func selectProject(_ path: String) {
        selectedProjectPath = path
        T3CodeBridge.rememberProject(path)
        if session != nil {
            session?.t3ProjectPath = path
            save()
        }
        refreshProjects()
    }

    func pickCustomProject() {
        guard let project = T3CodeBridge.pickProjectFolder() else { return }
        selectProject(project.path)
        showToast("T3-Projekt gewählt: \(project.name)")
    }

    private func syncSelectedProjectFromSession() {
        if let saved = session?.t3ProjectPath, !saved.isEmpty {
            if !projects.contains(where: { $0.path == saved }) {
                T3CodeBridge.rememberProject(saved)
                refreshProjects()
            }
            selectedProjectPath = saved
        }
    }

    // MARK: Session lifecycle & time tracking

    func refreshTargets(preferWindowID: CGWindowID? = nil) async {
        let targets = await MeetingAudio.availableTargets()
        availableTargets = targets
        if let preferWindowID,
           let matched = targets.first(where: { $0.windowID == preferWindowID }) {
            selectedTarget = matched
        } else {
            selectedTarget = targets.first { $0.id == selectedTarget.id } ?? .display
        }
    }

    func select(_ target: Session?) {
        guard !busy else {
            showToast(recording ? "Stoppe zuerst die laufende Aufnahme." : "Warte, bis der laufende Vorgang abgeschlossen ist.", isError: true)
            return
        }
        flushPendingNoteSave()
        if let current = session, current.isTimerRunning, current.id != target?.id {
            session?.pauseTimer()
            save()
        }
        session = target
        syncSelectedProjectFromSession()
        failedClips.removeAll()
        error = nil
        visualWarning = nil
        status = ""
        notesSaveState = ""
    }

    func toggleRecording() async {
        if recording {
            await stop()
        } else {
            await start()
        }
    }

    /// Starts a new meeting with time tracking + notes without audio capture.
    func startNewTimedMeeting(title: String = "") {
        guard !busy else { return }
        flushPendingNoteSave()
        if session?.isTimerRunning == true {
            session?.pauseTimer()
            save()
        }
        let start = Date()
        var created = Session(
            title: title,
            started: start,
            trackedIntervals: [MeetingTimeInterval(start: start, end: nil)],
            t3ProjectPath: selectedProjectPath.isEmpty ? nil : selectedProjectPath
        )
        created.startTimer(at: start)
        session = created
        centerTab = .notes
        error = nil
        status = ""
        startClockIfNeeded()
        save()
        reloadArchive(syncExports: false)
        showToast("Zeiterfassung gestartet")
    }

    func toggleTimer() {
        guard !changingCapture else { return }
        if recording {
            Task { await stop() }
            return
        }
        if session == nil {
            startNewTimedMeeting()
            return
        }
        let timestamp = Date()
        session?.toggleTimer(at: timestamp)
        now = timestamp
        startClockIfNeeded()
        save()
        reloadArchive(syncExports: false)
        showToast(session?.isTimerRunning == true ? "Timer läuft weiter" : "Timer pausiert")
    }

    func finishTimer() {
        guard !recording, !changingCapture, session != nil else { return }
        let timestamp = Date()
        session?.finishTimer(at: timestamp)
        now = timestamp
        save()
        reloadArchive(syncExports: false)
        showToast("Meeting beendet · \(MeetingDurationFormatter.human(session?.trackedDuration(at: timestamp) ?? 0))")
    }

    func start(preferredWindowID: CGWindowID? = nil) async {
        guard !busy else { return }
        guard Keychain.get(.openai) != nil else {
            error = "Füge deinen OpenAI-Schlüssel im Bluey-Menü hinzu (oder starte „Nur Timer“ ohne Transkription)."
            return
        }
        flushPendingNoteSave()
        changingCapture = true
        error = nil
        visualWarning = nil
        status = "Aufnahme wird gestartet …"
        if let preferredWindowID {
            await refreshTargets(preferWindowID: preferredWindowID)
        }
        let start = Date()
        let newSession = Session(
            started: start,
            trackedIntervals: [MeetingTimeInterval(start: start, end: nil)],
            t3ProjectPath: selectedProjectPath.isEmpty ? nil : selectedProjectPath
        )
        let visual = MeetingAudio.VisualConfig(
            recordVideo: recordVideo,
            autoScreenshots: autoScreenshots,
            target: selectedTarget
        )
        let recorder = MeetingAudio(
            folder: newSession.audioFolder,
            sessionFolder: newSession.folder,
            visual: visual,
            onScreenshot: { [weak self] shot in
                Task { @MainActor in
                    guard let self, self.session?.id == newSession.id else { return }
                    self.session?.screenshots.append(shot)
                    self.save()
                }
            },
            onVisualWarning: { [weak self] message in
                Task { @MainActor in
                    guard let self, self.session?.id == newSession.id || self.changingCapture else { return }
                    self.visualWarning = message
                }
            },
            onFailure: { [weak self] error in
                Task { @MainActor in
                    guard let self, self.session?.id == newSession.id, self.recording else { return }
                    await self.stop(failure: error.localizedDescription)
                }
            }
        )
        do {
            try await recorder.start()
            if session?.isTimerRunning == true {
                session?.pauseTimer(at: start)
                save()
            }
            var activeSession = newSession
            activeSession.captureTargetName = visual.enabled ? recorder.resolvedTargetName : nil
            session = activeSession
            centerTab = .transcript
            failedClips.removeAll()
            self.recorder = recorder
            recording = true
            onRecordingStateChanged?(true, start)
            status = ""
            now = start
            startClockIfNeeded()
            save()
            reloadArchive(syncExports: false)
            captureTimer = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(18)) } catch { return }
                    await self?.collect()
                }
            }
        } catch {
            _ = try? await recorder.stop()
            _ = await recorder.flush(stopping: true)
            self.error = "Aufnahme konnte nicht starten. \(error.localizedDescription)"
            status = ""
        }
        changingCapture = false
    }

    func takeScreenshot() async {
        guard recording, let recorder, let sessionID = session?.id, !takingScreenshot else { return }
        takingScreenshot = true
        defer { takingScreenshot = false }
        let shot = await recorder.captureManualScreenshot()
        guard session?.id == sessionID else { return }
        if let shot {
            session?.screenshots.append(shot)
            save()
            showToast("Screenshot gespeichert")
        } else {
            visualWarning = "Screenshot konnte nicht erstellt werden."
        }
    }

    func stop(failure: String? = nil) async {
        guard recording, let recorder else { return }
        recording = false
        onRecordingStateChanged?(false, nil)
        changingCapture = true
        captureTimer?.cancel()
        captureTimer = nil
        if let failure { error = failure }
        status = "Aufnahme wird gespeichert …"
        do {
            if let videoFilename = try await recorder.stop() {
                session?.videoFilename = videoFilename
            }
        } catch {
            if self.error == nil { self.error = error.localizedDescription }
        }
        await collecting?.value
        await addClips(from: recorder, stopping: true)
        self.recorder = nil
        if session?.clips.contains(where: { $0.source == .system }) != true ||
            session?.clips.contains(where: { $0.source == .microphone }) != true {
            if error == nil {
                error = "Mindestens eine Tonquelle lieferte kein Audio. Prüfe Call-Ausgabe, Mikrofon und macOS-Berechtigungen."
            }
        }
        let finished = Date()
        session?.finishTimer(at: finished)
        now = finished
        save()
        status = ""
        changingCapture = false
        reloadArchive(syncExports: false)
    }

    private func collect() async {
        guard recording, let recorder else { return }
        if let collecting { await collecting.value; return }
        let task = Task { await addClips(from: recorder) }
        collecting = task
        await task.value
        collecting = nil
    }

    private func addClips(from recorder: MeetingAudio, stopping: Bool = false) async {
        let result = await recorder.flush(stopping: stopping)
        if !result.errors.isEmpty { error = result.errors.joined(separator: "\n") }
        guard !result.clips.isEmpty else { return }
        session?.clips.append(contentsOf: result.clips)
        save()
        beginTranscription()
    }

    func retry() async {
        guard !transcribing else { return }
        error = nil
        failedClips.removeAll()
        beginTranscription()
        await transcription?.value
    }

    private func beginTranscription() {
        guard !transcribing, let session,
              session.clips.contains(where: { $0.transcript == nil && !failedClips.contains($0.id) }) else { return }
        transcribing = true
        transcription = Task {
            while let clip = self.session?.clips.first(where: { $0.transcript == nil && !failedClips.contains($0.id) }) {
                do {
                    let url = session.audioFolder.appendingPathComponent(clip.filename)
                    let segments = try await MeetingNotes.plain(Data(contentsOf: url))
                    if let index = self.session?.clips.firstIndex(where: { $0.id == clip.id }) {
                        self.session?.clips[index].transcript = segments.map(\.text).joined(separator: " ")
                        save()
                    }
                } catch {
                    failedClips.insert(clip.id)
                    self.error = "Ein Audioabschnitt konnte nicht transkribiert werden. \(error.localizedDescription)"
                }
            }
            transcription = nil
            transcribing = false
            reloadArchive(syncExports: false)
        }
    }

    // MARK: Notes & metadata editing

    func updateTitle(_ newTitle: String) {
        guard session != nil, session?.title != newTitle else { return }
        session?.title = newTitle
        scheduleNoteSave()
    }

    func updateManualNotes(_ text: String) {
        guard session != nil, session?.manualNotes != text else { return }
        session?.manualNotes = text
        notesSaveState = "Bearbeitet …"
        scheduleNoteSave()
    }

    func insertTimestampIntoNotes() {
        if session == nil { startNewTimedMeeting() }
        guard var current = session else { return }
        let clock = Date().formatted(date: .omitted, time: .shortened)
        let elapsed = MeetingDurationFormatter.stopwatch(current.trackedDuration(at: Date()))
        let prefix = current.manualNotes.isEmpty || current.manualNotes.hasSuffix("\n") ? "" : "\n"
        current.manualNotes += "\(prefix)[\(clock) · \(elapsed)] "
        session = current
        scheduleNoteSave()
    }

    private func scheduleNoteSave() {
        notesSaveTask?.cancel()
        notesSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            self?.save()
            self?.notesSaveState = "Gespeichert"
            self?.reloadArchive(syncExports: false)
        }
    }

    private func flushPendingNoteSave() {
        guard notesSaveTask != nil else { return }
        notesSaveTask?.cancel()
        notesSaveTask = nil
        save()
    }

    // MARK: Tasks & AI extraction

    @discardableResult
    func addTask(title: String, details: String = "", sourceQuote: String? = nil) -> MeetingTask? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if session == nil { startNewTimedMeeting() }
        let task = MeetingTask(title: trimmed, details: details.trimmingCharacters(in: .whitespacesAndNewlines), sourceQuote: sourceQuote)
        session?.tasks.insert(task, at: 0)
        save()
        reloadArchive(syncExports: false)
        return task
    }

    func toggleTask(_ id: UUID) {
        guard let idx = session?.tasks.firstIndex(where: { $0.id == id }) else { return }
        session?.tasks[idx].done.toggle()
        save()
        reloadArchive(syncExports: false)
    }

    func deleteTask(_ id: UUID) {
        session?.tasks.removeAll { $0.id == id }
        save()
        reloadArchive(syncExports: false)
    }

    func sendTaskToBlueyTodos(_ task: MeetingTask) {
        guard let addWorkspaceTodo else {
            showToast("Bluey-Workspace nicht verfügbar.", isError: true)
            return
        }
        let meetingLabel = session?.displayTitle ?? "Meeting"
        let details = [
            "Aus Meeting: \(meetingLabel)",
            task.details.isEmpty ? nil : task.details,
            task.sourceQuote.map { "Zitat: \($0)" },
        ].compactMap { $0 }.joined(separator: "\n")
        addWorkspaceTodo(task.title, details)
        showToast("Als Bluey-Todo gespeichert")
    }

    func saveNotesToBlueyWorkspace() {
        guard let session else { return }
        guard let addWorkspaceNote else {
            showToast("Bluey-Workspace nicht verfügbar.", isError: true)
            return
        }
        var parts: [String] = []
        let duration = MeetingDurationFormatter.human(session.trackedDuration(at: now))
        parts.append("Datum: \(session.started.formatted(date: .abbreviated, time: .shortened)) · Dauer: \(duration)")
        if !session.manualNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("## Notizen\n\(session.manualNotes)")
        }
        if !session.tasks.isEmpty {
            let taskLines = session.tasks.map { "- [\($0.done ? "x" : " ")] \($0.title)" }.joined(separator: "\n")
            parts.append("## Aufgaben\n\(taskLines)")
        }
        if !session.messages.isEmpty {
            let qa = session.messages.map { "\($0.role == .user ? "Du" : "Bluey"): \($0.text)" }.joined(separator: "\n\n")
            parts.append("## Rückfragen\n\(qa)")
        }
        addWorkspaceNote(session.displayTitle, parts.joined(separator: "\n\n"))
        showToast("In Bluey-Notizen gespeichert")
    }

    func extractTasksFromMeeting() async {
        guard !extractingTasks, let session else { return }
        guard Keychain.get(.openai) != nil else {
            error = "Für die automatische Aufgaben-Erkennung wird dein OpenAI-Schlüssel benötigt."
            return
        }
        let sourceText = [
            session.manualNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : "Eigene Notizen:\n\(session.manualNotes)",
            session.transcript.isEmpty ? nil : "Transkript:\n\(String(session.transcript.suffix(120_000)))",
        ].compactMap { $0 }.joined(separator: "\n\n")
        guard !sourceText.isEmpty else {
            showToast("Noch kein Transkript oder Notizen zum Auswerten vorhanden.", isError: true)
            return
        }
        extractingTasks = true
        error = nil
        defer { extractingTasks = false }

        let prompt = ChatMessage(
            role: .user,
            text: "Extrahiere alle konkreten Aufgaben, To-dos und Zusagen aus diesem Meeting. Gib ein JSON-Array zurück: [{\"title\": \"Kurzer klarer Aufgabentitel\", \"details\": \"Kontext oder Akzeptanzkriterien\", \"quote\": \"Kurzes Zitat mit Zeitstempel falls vorhanden\"}]. Nur JSON, keine Erklärung."
        )
        let data = Data(sourceText.utf8)
        let attachment = ChatAttachment(name: "Meeting.txt", mime: "text/plain", size: data.count)
        var messageWithAttachment = prompt
        messageWithAttachment.attachments = [attachment]

        do {
            let response = try await ChatEngine.stream(.init(
                messages: [messageWithAttachment],
                model: ChatEngine.fallbackModel,
                webSearch: false,
                context: "Extrahiere umsetzbare Aufgaben für den Nutzer aus den Meeting-Daten. Antworte ausschließlich mit einem JSON-Array.",
                attachmentData: { $0 == attachment.id ? data : nil }
            ), onText: { _ in })

            let extracted = MeetingTaskParser.parse(response)
            guard !extracted.isEmpty else {
                showToast("Keine konkreten Aufgaben im Meeting erkannt.")
                return
            }
            let existingTitles = Set((self.session?.tasks ?? []).map { $0.title.lowercased() })
            let fresh = extracted.filter { !existingTitles.contains($0.title.lowercased()) }
            guard !fresh.isEmpty else {
                showToast("Alle erkannten Aufgaben stehen schon in deiner Liste.")
                return
            }
            self.session?.tasks.insert(contentsOf: fresh, at: 0)
            save()
            reloadArchive(syncExports: false)
            railTab = .tasks
            showToast("\(fresh.count) \(fresh.count == 1 ? "Aufgabe" : "Aufgaben") aus dem Meeting erkannt")
        } catch {
            self.error = "Aufgaben konnten nicht extrahiert werden: \(error.localizedDescription)"
        }
    }

    // MARK: Sending to T3 Code

    func openT3Composer(for task: MeetingTask? = nil, titleOverride: String? = nil, excerpt: String? = nil) {
        refreshProjects()
        let savedPath = session?.t3ProjectPath
        let projectPath = (savedPath.flatMap { path in projects.contains(where: { $0.path == path }) ? path : nil })
            ?? selectedProject?.path
            ?? projects.first?.path
            ?? ""
        let meetingTitle = session?.displayTitle ?? "Meeting"
        let meetingDate = session?.started ?? Date()
        let durationText = MeetingDurationFormatter.human(session?.trackedDuration(at: now) ?? 0)
        let notesPath = session?.folder.appendingPathComponent("notes.md").path
        let transcriptPath = session.flatMap { s -> String? in
            let url = s.folder.appendingPathComponent("transkript.txt")
            return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
        }

        let title: String
        let prompt: String
        if let task {
            title = task.title
            prompt = T3CodeBridge.buildPrompt(
                taskTitle: task.title,
                taskDetails: task.details,
                meetingTitle: meetingTitle,
                meetingDate: meetingDate,
                durationText: durationText,
                notesFilePath: notesPath,
                transcriptFilePath: transcriptPath,
                excerpt: task.sourceQuote ?? excerpt
            )
        } else if let excerpt, !excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let fallbackTitle = titleOverride ?? String(excerpt.split(whereSeparator: \.isNewline).first ?? "Aufgabe aus Meeting").prefix(72).description
            title = fallbackTitle
            prompt = T3CodeBridge.buildPrompt(
                taskTitle: fallbackTitle,
                meetingTitle: meetingTitle,
                meetingDate: meetingDate,
                durationText: durationText,
                notesFilePath: notesPath,
                transcriptFilePath: transcriptPath,
                excerpt: excerpt
            )
        } else {
            let defaultTitle = titleOverride ?? "Aufgabe aus \(meetingTitle)"
            let openTasks = (session?.tasks ?? []).filter { !$0.done }.map { "- \($0.title)" }.joined(separator: "\n")
            let combinedDetails = [
                session?.manualNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? session?.manualNotes : nil,
                openTasks.isEmpty ? nil : "Offene Aufgaben:\n\(openTasks)",
            ].compactMap { $0 }.joined(separator: "\n\n")
            title = defaultTitle
            prompt = T3CodeBridge.buildPrompt(
                taskTitle: defaultTitle,
                taskDetails: combinedDetails,
                meetingTitle: meetingTitle,
                meetingDate: meetingDate,
                durationText: durationText,
                notesFilePath: notesPath,
                transcriptFilePath: transcriptPath,
                excerpt: session?.transcript.isEmpty == false ? String(session!.transcript.suffix(1800)) : nil
            )
        }

        t3Draft = T3SendDraft(
            title: title,
            prompt: prompt,
            projectPath: projectPath,
            linkedTaskID: task?.id,
            sourceQuote: task?.sourceQuote ?? excerpt
        )
    }

    func sendTaskDirectlyToT3(_ task: MeetingTask) async {
        refreshProjects()
        let projectPath = session?.t3ProjectPath ?? selectedProject?.path ?? ""
        guard !projectPath.isEmpty else {
            openT3Composer(for: task)
            return
        }
        guard let session else { return }
        sendingTaskID = task.id
        sendingToT3 = true
        error = nil
        defer {
            sendingTaskID = nil
            sendingToT3 = false
        }

        let durationText = MeetingDurationFormatter.human(session.trackedDuration(at: now))
        let notesPath = session.folder.appendingPathComponent("notes.md").path
        let transcriptURL = session.folder.appendingPathComponent("transkript.txt")
        let transcriptPath = FileManager.default.fileExists(atPath: transcriptURL.path) ? transcriptURL.path : nil
        let prompt = T3CodeBridge.buildPrompt(
            taskTitle: task.title,
            taskDetails: task.details,
            meetingTitle: session.displayTitle,
            meetingDate: session.started,
            durationText: durationText,
            notesFilePath: notesPath,
            transcriptFilePath: transcriptPath,
            excerpt: task.sourceQuote
        )

        do {
            let result = try await T3CodeBridge.sendTask(
                title: task.title,
                prompt: prompt,
                projectPath: projectPath,
                openApp: openT3AfterSend
            )
            markTaskSent(taskID: task.id, result: result)
            showToast("An T3 Code (\(result.projectName)) gesendet", openT3ProjectPath: result.projectPath)
        } catch {
            self.error = error.localizedDescription
            showToast("Konnte nicht an T3 Code senden", isError: true)
        }
    }

    func sendDraftToT3(_ draft: T3SendDraft) async -> Bool {
        sendingToT3 = true
        error = nil
        defer { sendingToT3 = false }
        do {
            let result = try await T3CodeBridge.sendTask(
                title: draft.title,
                prompt: draft.prompt,
                projectPath: draft.projectPath,
                worktreeBase: draft.worktreeBase.isEmpty ? nil : draft.worktreeBase,
                openApp: openT3AfterSend
            )
            if session == nil { startNewTimedMeeting(title: draft.title) }
            session?.t3ProjectPath = result.projectPath
            selectedProjectPath = result.projectPath
            if let linkedID = draft.linkedTaskID {
                markTaskSent(taskID: linkedID, result: result)
            } else {
                let task = MeetingTask(
                    title: draft.title.isEmpty ? "T3-Code-Aufgabe" : draft.title,
                    details: "",
                    sourceQuote: draft.sourceQuote,
                    sentToT3At: Date(),
                    t3ThreadID: result.threadID,
                    t3ProjectName: result.projectName,
                    t3ProjectPath: result.projectPath
                )
                session?.tasks.insert(task, at: 0)
                save()
                reloadArchive(syncExports: false)
            }
            t3Draft = nil
            showToast("An T3 Code (\(result.projectName)) gesendet", openT3ProjectPath: result.projectPath)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    private func markTaskSent(taskID: UUID, result: T3CodeSendResult) {
        if let idx = session?.tasks.firstIndex(where: { $0.id == taskID }) {
            session?.tasks[idx].sentToT3At = Date()
            session?.tasks[idx].t3ThreadID = result.threadID
            session?.tasks[idx].t3ProjectName = result.projectName
            session?.tasks[idx].t3ProjectPath = result.projectPath
            session?.t3ProjectPath = result.projectPath
            save()
            reloadArchive(syncExports: false)
        }
    }

    func openInT3Code(projectPath: String? = nil) {
        let path = projectPath ?? selectedProject?.path
        Task { await T3CodeBridge.openInT3Code(projectPath: path) }
    }

    // MARK: Bluey Q&A

    func ask(_ question: String) async -> Bool {
        guard !answering, !changingCapture else { return false }
        if session == nil { startNewTimedMeeting() }
        answering = true
        answer = ""
        error = nil
        railTab = .assistant
        defer { answering = false; answer = "" }

        if recording {
            await collecting?.value
            await collect()
        }
        await transcription?.value

        let fullTranscript = session?.transcript ?? ""
        let manual = session?.manualNotes.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let session, !fullTranscript.isEmpty || !manual.isEmpty else {
            error = "Für die Rückfrage sind noch weder Transkript noch Notizen verfügbar."
            return false
        }

        let message = ChatMessage(role: .user, text: question)
        var contextText = ""
        if !manual.isEmpty { contextText += "Eigene Meeting-Notizen:\n\(manual)\n\n" }
        if !fullTranscript.isEmpty { contextText += "Call-Transkript:\n\(String(fullTranscript.suffix(195_000)))" }

        let attachmentBytes = Data(contextText.utf8)
        let attachment = ChatAttachment(name: "Meeting-Kontext.txt", mime: "text/plain", size: attachmentBytes.count)
        var questionWithContext = message
        questionWithContext.attachments = [attachment]

        do {
            let response = try await ChatEngine.stream(.init(
                messages: session.messages + [questionWithContext],
                model: ChatEngine.fallbackModel,
                webSearch: false,
                context: "Beantworte die Rückfrage auf Grundlage des beigefügten Call-Transkripts und der Meeting-Notizen. "
                    + "Nenne die Zeit aus dem Transkript und zitiere die relevante Stelle. "
                    + "Wenn der Call die Frage offenlässt oder das Transkript lückenhaft ist, sage das. "
                    + "Schlage bei einer offenen Frage einen kurzen Satz vor, den der Nutzer im Call sagen kann.",
                attachmentData: { $0 == attachment.id ? attachmentBytes : nil }
            ), onText: { [weak self] in self?.answer = $0 })
            guard !response.isEmpty else { throw ChatEngine.Failure.message("Bluey hat keine Antwort erhalten.") }
            self.session?.messages += [message, ChatMessage(role: .assistant, text: response)]
            save()
            reloadArchive(syncExports: false)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// Context block for Hermes so it can inspect the live meeting transcript and screenshots directly.
    func hermesContextSummary() -> String? {
        if recording, let session {
            let started = session.started.formatted(date: .omitted, time: .shortened)
            var parts = [
                "Active meeting recording in progress (started \(started)).",
                "Live transcript & notes file (updated every ~18s): \(session.notesURL.path)"
            ]
            if let target = session.captureTargetName {
                parts.append("Captured screen source: \(target).")
            }
            if !session.screenshots.isEmpty {
                let recentShots = session.screenshots.suffix(3).map { session.folder.appendingPathComponent($0.filename).path }
                parts.append("Captured meeting screenshots (\(session.screenshots.count) total, latest): \(recentShots.joined(separator: ", "))")
            }
            let tail = session.transcript.suffix(2200)
            if !tail.isEmpty {
                parts.append("Latest transcript excerpt:\n\(tail)")
            }
            return parts.joined(separator: "\n")
        }
        if let recent = session ?? archive.first {
            return "Meeting notes & transcripts folder: ~/Documents/Bluey Notes/ (most recent: \(recent.notesURL.path))."
        }
        return "Meeting notes & transcripts folder: ~/Documents/Bluey Notes/."
    }

    /// Saves a live Huion / screen drawing with its exact video timecode into the active meeting session.
    func recordDrawing(source: String, noteID: UUID?, drawing: InkDrawing, compositePNG: Data? = nil,
                       offsetSeconds: Double? = nil, ocrText: String? = nil) {
        guard recording, var session = self.session, !drawing.isEmpty else { return }
        let now = Date()
        let offset = max(0, offsetSeconds ?? drawing.videoTimeRange?.start ?? now.timeIntervalSince(session.started))
        try? FileManager.default.createDirectory(at: session.drawingsFolder, withIntermediateDirectories: true)

        // Coalesce rapid updates on the same note (within 15s) so one continuous sentence becomes one clean snapshot.
        let updateIndex: Int?
        if let noteID,
           let idx = session.drawings.lastIndex(where: { $0.noteID == noteID && $0.source == source }),
           now.timeIntervalSince(session.drawings[idx].timestamp) < 15 {
            updateIndex = idx
        } else {
            updateIndex = nil
        }

        let eventID = updateIndex.map { session.drawings[$0].id } ?? UUID()
        let timeStamp = InkDrawing.formatFileTime(offset)
        let slug = source.lowercased().replacingOccurrences(of: "[^a-z0-9]", with: "-", options: .regularExpression)
        let stem = "\(timeStamp)_\(slug)_\(eventID.uuidString.prefix(6).lowercased())"
        let svgName = updateIndex.map { session.drawings[$0].svgFilename } ?? "\(stem).svg"
        let pngName = updateIndex.flatMap { session.drawings[$0].pngFilename } ?? "\(stem).png"

        let svg = drawing.toSVG(width: 960, forceLightPaper: false)
        try? svg.write(to: session.drawingsFolder.appendingPathComponent(svgName), atomically: true, encoding: .utf8)

        let pngBytes = compositePNG ?? InkRenderer.pngData(for: drawing, width: 1400, forceLightPaper: false)
        var savedPNG: String?
        if let pngBytes, (try? pngBytes.write(to: session.drawingsFolder.appendingPathComponent(pngName), options: .atomic)) != nil {
            savedPNG = pngName
        }

        if let idx = updateIndex {
            session.drawings[idx].strokeCount = drawing.strokes.count
            session.drawings[idx].pngFilename = savedPNG
            if let ocrText, !ocrText.isEmpty { session.drawings[idx].ocrText = ocrText }
        } else {
            let event = DrawingEvent(
                id: eventID,
                timestamp: now,
                videoOffsetSeconds: offset,
                source: source,
                noteID: noteID,
                svgFilename: svgName,
                pngFilename: savedPNG,
                strokeCount: drawing.strokes.count,
                ocrText: ocrText
            )
            session.drawings.append(event)
        }
        self.session = session
        save()
    }

    // MARK: Folders & files

    func revealSessionFolder() {
        if let session {
            MeetingNotes.exportSessionFiles(session, now: now)
            NSWorkspace.shared.open(session.folder)
        } else {
            revealRootFolder()
        }
    }

    func revealRootFolder() {
        MeetingNotes.ensureLibraryFolders()
        MeetingNotes.writeTimeLog(allTimeSummaries, now: now)
        NSWorkspace.shared.open(MeetingNotes.root)
    }

    func revealNotesFolder() {
        MeetingNotes.ensureLibraryFolders()
        NSWorkspace.shared.open(MeetingNotes.notesFolder())
    }

    func revealMessagesFolder() {
        MeetingNotes.ensureLibraryFolders()
        NSWorkspace.shared.open(MeetingNotes.messagesFolder())
    }

    func revealTasksFolder() {
        MeetingNotes.ensureLibraryFolders()
        NSWorkspace.shared.open(MeetingNotes.tasksFolder())
    }

    func openTimeLog() {
        MeetingNotes.writeTimeLog(allTimeSummaries, now: now)
        NSWorkspace.shared.open(MeetingNotes.timeLogFile())
    }

    func openFile(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func revealFile(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func deleteSession(_ target: Session) {
        guard !busy || session?.id != target.id else {
            showToast(recording ? "Stoppe zuerst die laufende Aufnahme." : "Warte, bis der laufende Vorgang abgeschlossen ist.", isError: true)
            return
        }
        try? FileManager.default.trashItem(at: target.folder, resultingItemURL: nil)
        let suffix = "(\(target.shortTag)).md"
        for folder in [MeetingNotes.notesFolder(), MeetingNotes.messagesFolder(), MeetingNotes.tasksFolder()] {
            if let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                for file in files where file.lastPathComponent.hasSuffix(suffix) {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
        if session?.id == target.id {
            session = archive.first { $0.id != target.id }
        }
        reloadArchive(syncExports: false)
        showToast("Meeting in den Papierkorb gelegt")
    }

    func showToast(_ text: String, isError: Bool = false, openT3ProjectPath: String? = nil) {
        toast = ToastMessage(text: text, isError: isError, openT3ProjectPath: openT3ProjectPath)
        toastClearTask?.cancel()
        toastClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4.5))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: Persistence

    private func save() {
        guard let session else { return }
        do {
            try FileManager.default.createDirectory(at: session.folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(session).write(to: session.folder.appendingPathComponent("mac-call.json"), options: .atomic)
            var entries: [[String: Any]] = session.clips.compactMap { clip in
                guard let text = clip.transcript, !text.isEmpty else { return nil }
                return ["kind": "transcript", "speaker": clip.source.title, "text": text, "time": clip.started.timeIntervalSince1970]
            }
            entries += session.screenshots.map { shot in
                [
                    "kind": "screenshot",
                    "path": shot.filename,
                    "manual": shot.manual,
                    "text": shot.label ?? (shot.manual ? "Screenshot" : "Folie / Bildschirmänderung"),
                    "time": shot.captured.timeIntervalSince1970
                ]
            }
            entries += session.messages.map {
                ["kind": $0.role == .user ? "asked" : "reply", "text": $0.text, "time": $0.createdAt.timeIntervalSince1970]
            }
            entries += session.drawings.map { d in
                var entry: [String: Any] = [
                    "kind": "drawing",
                    "source": d.source,
                    "videoOffset": d.timecode,
                    "videoOffsetSeconds": d.videoOffsetSeconds,
                    "svg": "drawings/\(d.svgFilename)",
                    "text": (d.ocrText?.isEmpty == false ? d.ocrText! : "\(d.strokeCount) Striche"),
                    "time": d.timestamp.timeIntervalSince1970,
                ]
                if let png = d.pngFilename { entry["png"] = "drawings/\(png)" }
                return entry
            }
            var notes: [String: Any] = [
                "id": session.id.uuidString,
                "title": session.displayTitle,
                "started": session.started.timeIntervalSince1970,
                "durationSeconds": session.trackedDuration(at: now),
                "entries": entries.sorted { ($0["time"] as? Double ?? 0) < ($1["time"] as? Double ?? 0) },
                "transcribing": session.clips.filter { $0.transcript == nil }.count,
            ]
            notes["ended"] = session.ended?.timeIntervalSince1970
            notes["video"] = session.videoFilename
            notes["captureTarget"] = session.captureTargetName
            if let data = try? JSONSerialization.data(withJSONObject: notes, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: session.folder.appendingPathComponent("session.json"), options: .atomic)
            }
            MeetingNotes.exportSessionFiles(session, now: now)
            MeetingNotes.writeTimeLog(allTimeSummaries, now: now)
        } catch {
            self.error = "Call-Notizen konnten nicht gespeichert werden. \(error.localizedDescription)"
        }
    }

    func reloadArchive(syncExports: Bool = false) {
        MeetingNotes.ensureLibraryFolders()
        let folders = (try? FileManager.default.contentsOfDirectory(at: MeetingNotes.root, includingPropertiesForKeys: nil)) ?? []
        archive = folders.compactMap { folder in
            guard !MeetingNotes.libraryFolderNames.contains(folder.lastPathComponent) else { return nil }
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("mac-call.json")) else { return nil }
            return try? JSONDecoder().decode(Session.self, from: data)
        }.sorted { $0.started > $1.started }

        if syncExports {
            for item in archive {
                let tagSuffix = "(\(item.shortTag)).md"
                let hasFlatNotes = (try? FileManager.default.contentsOfDirectory(at: MeetingNotes.notesFolder(), includingPropertiesForKeys: nil))?
                    .contains { $0.lastPathComponent.hasSuffix(tagSuffix) } ?? false
                let hasFlatMessages = (try? FileManager.default.contentsOfDirectory(at: MeetingNotes.messagesFolder(), includingPropertiesForKeys: nil))?
                    .contains { $0.lastPathComponent.hasSuffix(tagSuffix) } ?? false
                if !hasFlatNotes && !hasFlatMessages {
                    MeetingNotes.exportSessionFiles(item, now: now)
                }
            }
        }
        MeetingNotes.writeTimeLog(allTimeSummaries, now: now)
    }
}

// MARK: - Studio Palette

private enum MeetingStyle {
    static let canvas = Color(hex: 0x0D0C14)
    static let sidebar = Color(hex: 0x13111D)
    static let surface = Color(hex: 0x1B1827)
    static let surfaceRaised = Color(hex: 0x231F33)
    static let border = Color.white.opacity(0.08)
    static let borderStrong = Color.white.opacity(0.14)
    static let ink = Color.white.opacity(0.94)
    static let inkMuted = Color(hex: Palette.inkSoft)
}

// MARK: - Main Meeting View

@available(macOS 15, *)
private struct MeetingView: View {
    @ObservedObject var model: MeetingWindow
    @State private var sidebarSearch = ""
    @State private var transcriptSearch = ""
    @State private var speakerFilter: SpeakerFilter = .all
    @State private var newTaskTitle = ""
    @State private var question = ""
    @State private var titleDraft = ""
    @State private var notesDraft = ""
    @State private var loadedSessionID: UUID?
    @State private var showCaptureSettings = false

    @FocusState private var questionFocused: Bool
    @FocusState private var taskInputFocused: Bool
    @FocusState private var searchFocused: Bool

    enum SpeakerFilter: String, CaseIterable, Identifiable {
        case all = "Alle"
        case microphone = "Du"
        case system = "Call"
        var id: String { rawValue }
    }

    private var filteredArchive: [MeetingSession] {
        var list = model.archive
        if let active = model.session, !list.contains(where: { $0.id == active.id }) {
            list.insert(active, at: 0)
        }
        let q = sidebarSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return list }
        return list.filter { item in
            item.displayTitle.localizedCaseInsensitiveContains(q)
                || item.manualNotes.localizedCaseInsensitiveContains(q)
                || item.transcript.localizedCaseInsensitiveContains(q)
                || item.tasks.contains { $0.title.localizedCaseInsensitiveContains(q) }
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            HStack(spacing: 0) {
                if model.showSidebar {
                    sidebar
                    Divider().overlay(MeetingStyle.border)
                }
                centerPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider().overlay(MeetingStyle.border)
                rightRail
                    .frame(width: 332)
            }
            .background(MeetingStyle.canvas)
            .preferredColorScheme(.dark)

            if let toast = model.toast {
                toastBanner(toast)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.22), value: model.toast?.id)
        .animation(.snappy(duration: 0.2), value: model.showSidebar)
        .background(shortcutCommands)
        .onAppear { syncDraftsFromSession() }
        .onChange(of: model.session?.id) { _, _ in syncDraftsFromSession() }
        .onChange(of: model.session?.manualNotes) { _, newValue in
            if let newValue, newValue != notesDraft { notesDraft = newValue }
        }
        .onChange(of: model.focusQuestionToken) { _, _ in
            model.railTab = .assistant
            questionFocused = true
        }
        .onChange(of: model.focusTaskToken) { _, _ in
            model.railTab = .tasks
            taskInputFocused = true
        }
        .onChange(of: model.focusSearchToken) { _, _ in
            model.showSidebar = true
            searchFocused = true
        }
        .sheet(item: $model.t3Draft) { draft in
            T3SendSheet(model: model, draft: draft)
        }
        .sheet(isPresented: $model.showTimeOverview) {
            MeetingTimeOverviewSheet(model: model)
        }
        .sheet(isPresented: $model.showShortcutsHelp) {
            MeetingShortcutsSheet()
        }
    }

    private func syncDraftsFromSession() {
        loadedSessionID = model.session?.id
        titleDraft = model.session?.title ?? ""
        notesDraft = model.session?.manualNotes ?? ""
    }

    /// Hidden keyboard shortcut triggers so every meeting workflow is reachable from the keyboard.
    private var shortcutCommands: some View {
        Group {
            Button("") { Task { await model.toggleRecording() } }
                .keyboardShortcut("r", modifiers: .command)
            Button("") { model.startNewTimedMeeting() }
                .keyboardShortcut("n", modifiers: .command)
            Button("") { model.toggleTimer() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("") { model.centerTab = .transcript }
                .keyboardShortcut("1", modifiers: .command)
            Button("") { model.centerTab = .notes }
                .keyboardShortcut("2", modifiers: .command)
            Button("") { model.centerTab = .files }
                .keyboardShortcut("3", modifiers: .command)
            Button("") { model.focusTaskToken += 1 }
                .keyboardShortcut("t", modifiers: .command)
            Button("") { model.openT3Composer() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("") { model.focusQuestionToken += 1 }
                .keyboardShortcut("l", modifiers: .command)
            Button("") { model.focusSearchToken += 1 }
                .keyboardShortcut("f", modifiers: .command)
            Button("") { model.revealRootFolder() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("") { model.showSidebar.toggle() }
                .keyboardShortcut("\\", modifiers: .command)
            Button("") { model.showShortcutsHelp.toggle() }
                .keyboardShortcut("/", modifiers: .command)
        }
        .labelsHidden()
        .frame(width: 0, height: 0)
        .opacity(0.001)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Top bar inset for transparent titlebar traffic lights
            HStack(spacing: 8) {
                BlueyAvatar(mood: model.recording ? .talking : (model.answering || model.extractingTasks ? .thinking : .listening), animated: model.recording || model.answering)
                    .frame(width: 28, height: 25)
                Text("Call-Notizen")
                    .font(.fredoka(19))
                    .foregroundStyle(.white)
                Spacer()
                Button { model.showShortcutsHelp = true } label: {
                    Image(systemName: "keyboard")
                        .font(.system(size: 13))
                        .foregroundStyle(MeetingStyle.inkMuted)
                        .frame(width: 26, height: 26)
                        .background(MeetingStyle.surface, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .help("Shortcuts anzeigen (⌘/)")
            }
            .padding(.top, 26)

            // Primary Capture & Timer Actions
            VStack(spacing: 8) {
                Button {
                    Task { await model.toggleRecording() }
                } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(model.recording ? Color.white : Theme.red)
                            .frame(width: 9, height: 9)
                        Text(model.recording ? "Aufnahme stoppen" : "Aufnahme starten")
                            .font(.plexSans(13).weight(.semibold))
                        Spacer()
                        ShortcutPill(model.recording ? (model.activeTimerBadgeText ?? "⌘R") : "⌘R", light: model.recording)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(model.recording ? Theme.red : Theme.accent)
                    )
                }
                .buttonStyle(.plain)
                .disabled(model.changingCapture || (!model.recording && model.busy))

                Button {
                    model.startNewTimedMeeting()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "stopwatch")
                            .font(.system(size: 12, weight: .medium))
                        Text("Neues Meeting (nur Zeit)")
                            .font(.plexSans(12).weight(.medium))
                        Spacer()
                        ShortcutPill("⌘N")
                    }
                    .foregroundStyle(MeetingStyle.ink)
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(MeetingStyle.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(MeetingStyle.border))
                }
                .buttonStyle(.plain)
                .disabled(model.busy)
            }

            // Compact Time Tracking Card
            Button { model.showTimeOverview = true } label: {
                let stats = model.timeStats
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Meeting-Zeit", systemImage: "clock.badge.checkmark")
                            .font(.plexSans(11).weight(.semibold))
                            .foregroundStyle(Theme.green)
                        Spacer()
                        Text("Details")
                            .font(.plexSans(10))
                            .foregroundStyle(MeetingStyle.inkMuted)
                    }
                    HStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(MeetingDurationFormatter.human(stats.todaySeconds))
                                .font(.plexMono(14).weight(.semibold))
                                .foregroundStyle(.white)
                            Text("Heute (\(stats.todayCount))")
                                .font(.plexSans(10))
                                .foregroundStyle(MeetingStyle.inkMuted)
                        }
                        Spacer()
                        Rectangle().fill(MeetingStyle.border).frame(width: 1, height: 24)
                        Spacer()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(MeetingDurationFormatter.human(stats.weekSeconds))
                                .font(.plexMono(14).weight(.semibold))
                                .foregroundStyle(.white)
                            Text("Woche (\(stats.weekCount))")
                                .font(.plexSans(10))
                                .foregroundStyle(MeetingStyle.inkMuted)
                        }
                    }
                }
                .padding(10)
                .background(MeetingStyle.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(MeetingStyle.border))
            }
            .buttonStyle(.plain)
            .help("Zeitübersicht & 7-Tage-Statistik öffnen")

            // Search Meetings
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(MeetingStyle.inkMuted)
                TextField("Meetings durchsuchen…", text: $sidebarSearch)
                    .textFieldStyle(.plain)
                    .font(.plexSans(12))
                    .focused($searchFocused)
                if !sidebarSearch.isEmpty {
                    Button { sidebarSearch = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(MeetingStyle.inkMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(MeetingStyle.surface, in: RoundedRectangle(cornerRadius: 8))

            // Sessions List
            ScrollView {
                LazyVStack(spacing: 4) {
                    if filteredArchive.isEmpty {
                        Text(sidebarSearch.isEmpty ? "Noch keine Meetings gespeichert." : "Keine Treffer.")
                            .font(.plexSans(12))
                            .foregroundStyle(MeetingStyle.inkMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 12)
                            .padding(.horizontal, 6)
                    } else {
                        ForEach(filteredArchive) { item in
                            sidebarSessionRow(item)
                        }
                    }
                }
            }

            Divider().overlay(MeetingStyle.border)

            // Easy-Access Folder Footer
            VStack(spacing: 6) {
                Button { model.revealRootFolder() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.accentLight)
                        Text("Bluey Notes Ordner")
                            .font(.plexSans(12).weight(.medium))
                            .foregroundStyle(.white)
                        Spacer()
                        ShortcutPill("⌘⇧O")
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(MeetingStyle.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(MeetingStyle.border))
                }
                .buttonStyle(.plain)
                .help("~/Documents/Bluey Notes im Finder öffnen")

                HStack(spacing: 6) {
                    FolderQuickButton(title: "Notizen", icon: "doc.text") { model.revealNotesFolder() }
                    FolderQuickButton(title: "Nachrichten", icon: "bubble.left.and.bubble.right") { model.revealMessagesFolder() }
                    FolderQuickButton(title: "Zeit", icon: "clock") { model.openTimeLog() }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .frame(width: 248)
        .background(MeetingStyle.sidebar)
    }

    private func sidebarSessionRow(_ item: MeetingSession) -> some View {
        let isSelected = model.session?.id == item.id
        let isLiveRecording = isSelected && model.recording
        let isLiveTimer = isSelected && item.isTimerRunning && !model.recording
        let duration = item.trackedDuration(at: isSelected ? model.now : Date())

        return Button {
            model.select(item)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if isLiveRecording {
                        Circle().fill(Theme.red).frame(width: 7, height: 7)
                    } else if isLiveTimer {
                        Circle().fill(Theme.green).frame(width: 7, height: 7)
                    }
                    Text(item.displayTitle)
                        .font(.plexSans(13).weight(isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? .white : MeetingStyle.ink)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(isLiveRecording || isLiveTimer ? MeetingDurationFormatter.stopwatch(duration) : MeetingDurationFormatter.human(duration))
                        .font(.plexMono(10))
                        .foregroundStyle(isLiveRecording ? Theme.red : (isLiveTimer ? Theme.green : MeetingStyle.inkMuted))
                }
                HStack(spacing: 8) {
                    Text(item.started.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(Locale(identifier: "de_DE"))))
                        .font(.plexSans(10.5))
                        .foregroundStyle(MeetingStyle.inkMuted)
                    Spacer()
                    if !item.tasks.isEmpty {
                        Label("\(item.tasks.count)", systemImage: "checklist")
                            .font(.plexMono(10))
                            .foregroundStyle(Theme.accentLight)
                    }
                    if !item.messages.isEmpty {
                        Label("\(item.messages.count)", systemImage: "sparkles")
                            .font(.plexMono(10))
                            .foregroundStyle(MeetingStyle.inkMuted)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? MeetingStyle.surfaceRaised : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(isSelected ? Theme.accent.opacity(0.45) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { model.revealFile(item.folder) } label: { Label("Im Finder öffnen", systemImage: "folder") }
            Button(role: .destructive) { model.deleteSession(item) } label: { Label("In Papierkorb legen", systemImage: "trash") }
        }
    }

    // MARK: Center Pane

    private var centerPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            centerHeader
            Divider().overlay(MeetingStyle.border)
            captureControls
            Divider().overlay(MeetingStyle.border)

            if !model.status.isEmpty || model.transcribing || model.error != nil || model.visualWarning != nil {
                statusStrip
            }

            if model.session == nil {
                emptySessionState
            } else {
                centerTabBar
                switch model.centerTab {
                case .transcript:
                    transcriptView
                case .notes:
                    manualNotesView
                case .files:
                    filesBrowserView
                }
            }
        }
        .background(MeetingStyle.canvas)
    }

    private var captureControls: some View {
        HStack(spacing: 10) {
            if !model.showSidebar {
                Button(model.recording ? "Aufnahme stoppen" : "Aufnahme starten",
                       systemImage: model.recording ? "stop.fill" : "record.circle") {
                    Task { await model.toggleRecording() }
                }
                .disabled(model.changingCapture || (!model.recording && model.busy))
            }
            if model.recording {
                ViewThatFits(in: .horizontal) {
                    recordingActions
                    recordingActions.labelStyle(.iconOnly)
                }
            } else {
                Button("Aufnahmeoptionen", systemImage: "slider.horizontal.3") { showCaptureSettings.toggle() }
                    .disabled(model.changingCapture)
                    .popover(isPresented: $showCaptureSettings) {
                        captureSettings
                    }
                Text(model.recordVideo ? "Mit Bildschirmvideo" : (model.autoScreenshots ? "Mit Folien-Screenshots" : "Nur Audio"))
                    .font(.plexSans(11))
                    .foregroundStyle(MeetingStyle.inkMuted)
            }
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }

    private var recordingActions: some View {
        HStack(spacing: 10) {
            Button("Screenshot", systemImage: "camera") { Task { await model.takeScreenshot() } }
                .disabled(model.takingScreenshot)
                .help("Screenshot speichern")
            Button("Stift-Notiz", systemImage: "pencil.and.scribble") { model.onNewInkNote?() }
                .help("Stift-Notiz öffnen")
            Button("Bildschirm markieren", systemImage: "scribble.variable") { model.onOpenScreenAnnotator?() }
                .help("Bildschirm markieren")
        }
    }

    private var captureSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Bildschirmvideo aufnehmen", isOn: $model.recordVideo)
            Toggle("Folien-Screenshots speichern", isOn: $model.autoScreenshots)
            HStack {
                Picker("Bildquelle", selection: $model.selectedTarget) {
                    ForEach(model.availableTargets) { target in
                        Text(target.displayName).tag(target)
                    }
                }
                Button("Fensterliste aktualisieren", systemImage: "arrow.clockwise") {
                    Task { await model.refreshTargets() }
                }
                .labelStyle(.iconOnly)
                .help("Fensterliste aktualisieren")
            }
            Text("Bluey nimmt Mac-Audio und Mikrofon auf und sendet Audio zur Transkription an OpenAI. Informiere die Teilnehmenden vor dem Start.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 330)
        .disabled(model.recording || model.changingCapture)
    }

    private var centerHeader: some View {
        HStack(spacing: 12) {
            Button { model.showSidebar.toggle() } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 14))
                    .foregroundStyle(MeetingStyle.inkMuted)
                    .frame(width: 30, height: 30)
                    .background(MeetingStyle.surface, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help("Seitenleiste umschalten (⌘\\)")

            if let session = model.session {
                VStack(alignment: .leading, spacing: 2) {
                    TextField(session.displayTitle, text: $titleDraft)
                        .textFieldStyle(.plain)
                        .font(.fredoka(20))
                        .foregroundStyle(.white)
                        .onChange(of: titleDraft) { _, newValue in
                            if loadedSessionID == session.id {
                                model.updateTitle(newValue)
                            }
                        }
                    Text(session.started.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year().hour().minute().locale(Locale(identifier: "de_DE"))))
                        .font(.plexSans(11))
                        .foregroundStyle(MeetingStyle.inkMuted)
                }
            } else {
                Text("Kein Meeting ausgewählt")
                    .font(.fredoka(20))
                    .foregroundStyle(MeetingStyle.inkMuted)
            }

            Spacer(minLength: 8)

            // Live Stopwatch & Pause/Resume Control
            if let session = model.session {
                let elapsed = session.trackedDuration(at: model.now)
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.recording ? Theme.red : (session.isTimerRunning ? Theme.green : MeetingStyle.inkMuted.opacity(0.4)))
                        .frame(width: 7, height: 7)
                    Text(MeetingDurationFormatter.stopwatch(elapsed))
                        .font(.plexMono(13).weight(.semibold))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                    if !model.recording {
                        Button { model.toggleTimer() } label: {
                            Image(systemName: session.isTimerRunning ? "pause.fill" : "play.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(session.isTimerRunning ? Theme.yellow : Theme.green)
                                .frame(width: 22, height: 22)
                                .background(Color.white.opacity(0.07), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .help(session.isTimerRunning ? "Timer pausieren (⌘⇧P)" : "Timer fortsetzen (⌘⇧P)")
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(MeetingStyle.surface, in: Capsule())
                .overlay(Capsule().stroke(model.recording ? Theme.red.opacity(0.45) : (session.isTimerRunning ? Theme.green.opacity(0.4) : MeetingStyle.border)))
            }

            // Direct Send to T3 Code CTA
            Button { model.openT3Composer() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 11))
                    Text("An T3 Code")
                        .font(.plexSans(12.5).weight(.semibold))
                    ShortcutPill("⌘⇧T", light: true)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(Theme.blue, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Aufgabe oder Meeting-Kontext direkt an T3 Code senden (⌘⇧T)")
        }
        .padding(.horizontal, 18)
        .padding(.top, model.showSidebar ? 14 : 30)
        .padding(.bottom, 12)
    }

    private var statusStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.status.isEmpty || model.transcribing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(Theme.accentLight)
                    Text(!model.status.isEmpty ? model.status : "Audio wird im Hintergrund transkribiert …")
                        .font(.plexSans(12))
                        .foregroundStyle(MeetingStyle.inkMuted)
                }
            }
            if let err = model.error {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.peach)
                    Text(err)
                        .font(.plexSans(12))
                        .foregroundStyle(Theme.peach)
                        .textSelection(.enabled)
                    Spacer()
                    if !model.transcribing && model.session?.clips.contains(where: { $0.transcript == nil }) == true {
                        Button("Erneut versuchen") { Task { await model.retry() } }
                            .font(.plexSans(11).weight(.semibold))
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
            if let warning = model.visualWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.plexSans(12))
                    .foregroundStyle(Theme.peach)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(MeetingStyle.surface.opacity(0.65))
        .overlay(alignment: .bottom) { Divider().overlay(MeetingStyle.border) }
    }

    private var centerTabBar: some View {
        HStack(spacing: 6) {
            ForEach(MeetingWindow.CenterTab.allCases) { tab in
                let selected = model.centerTab == tab
                Button { model.centerTab = tab } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.icon).font(.system(size: 12))
                        Text(tab.rawValue).font(.plexSans(12.5).weight(selected ? .semibold : .medium))
                        Text(tab.shortcutHint).font(.plexMono(10)).foregroundStyle(selected ? .white.opacity(0.7) : MeetingStyle.inkMuted.opacity(0.65))
                    }
                    .foregroundStyle(selected ? .white : MeetingStyle.inkMuted)
                    .padding(.horizontal, 11)
                    .frame(height: 30)
                    .background(selected ? MeetingStyle.surfaceRaised : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? MeetingStyle.borderStrong : Color.clear))
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if model.centerTab == .notes, !model.notesSaveState.isEmpty {
                Text(model.notesSaveState)
                    .font(.plexSans(11))
                    .foregroundStyle(MeetingStyle.inkMuted)
            }
            Button { model.revealSessionFolder() } label: {
                Label("Meeting-Ordner", systemImage: "folder")
                    .font(.plexSans(11.5))
                    .foregroundStyle(MeetingStyle.inkMuted)
            }
            .buttonStyle(.plain)
            .help("Aktuellen Meeting-Ordner im Finder öffnen")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    // MARK: Center Tab 1 — Transcript

    private var transcriptView: some View {
        let allClips = model.session?.transcriptClips ?? []
        let filteredClips = allClips.filter { clip in
            switch speakerFilter {
            case .all: break
            case .microphone: if clip.source != .microphone { return false }
            case .system: if clip.source != .system { return false }
            }
            let q = transcriptSearch.trimmingCharacters(in: .whitespacesAndNewlines)
            if !q.isEmpty {
                return (clip.transcript ?? "").localizedCaseInsensitiveContains(q)
            }
            return true
        }

        return VStack(spacing: 0) {
            // Transcript filter & search bar
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(SpeakerFilter.allCases) { f in
                        Button { speakerFilter = f } label: {
                            Text(f.rawValue)
                                .font(.plexSans(11.5).weight(speakerFilter == f ? .semibold : .regular))
                                .foregroundStyle(speakerFilter == f ? .white : MeetingStyle.inkMuted)
                                .padding(.horizontal, 9)
                                .frame(height: 24)
                                .background(speakerFilter == f ? Theme.accent.opacity(0.32) : Color.clear, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(MeetingStyle.surface, in: Capsule())

                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(MeetingStyle.inkMuted)
                    TextField("Im Transkript filtern…", text: $transcriptSearch)
                        .textFieldStyle(.plain)
                        .font(.plexSans(12))
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(MeetingStyle.surface, in: RoundedRectangle(cornerRadius: 7))

                if !allClips.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.session?.transcript ?? "", forType: .string)
                        model.showToast("Transkript kopiert")
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11.5))
                            .foregroundStyle(MeetingStyle.inkMuted)
                            .frame(width: 26, height: 26)
                            .background(MeetingStyle.surface, in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .help("Gesamtes Transkript kopieren")
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 10)

            if allClips.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: model.recording ? "waveform" : "mic.badge.plus")
                        .font(.system(size: 28))
                        .foregroundStyle(model.recording ? Theme.red : Theme.accentLight)
                    Text(model.recording ? "Bluey hört zu …" : "Noch kein Transkript")
                        .font(.fredoka(19))
                        .foregroundStyle(.white)
                    Text(model.recording
                         ? "Audio wird alle 18 Sekunden automatisch gespeichert und transkribiert. Du kannst schon unter „Notizen“ mitschreiben."
                         : "Starte mit ⌘R eine Aufnahme (Mac-Audio + Mikrofon) oder wechsle mit ⌘2 in deine eigenen Notizen. Informiere Teilnehmende vor einer Aufnahme.")
                        .font(.plexSans(13))
                        .foregroundStyle(MeetingStyle.inkMuted)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else if filteredClips.isEmpty {
                VStack(spacing: 8) {
                    Text("Kein Abschnitt passt zu diesem Filter.")
                        .font(.plexSans(13))
                        .foregroundStyle(MeetingStyle.inkMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(filteredClips) { clip in
                            TranscriptBubbleRow(
                                clip: clip,
                                onAddTask: {
                                    let text = clip.transcript ?? ""
                                    let shortTitle = String(text.prefix(88))
                                    _ = model.addTask(title: shortTitle, sourceQuote: "[\(clip.started.formatted(date: .omitted, time: .standard))] \(clip.source.title): \(text)")
                                    model.railTab = .tasks
                                    model.showToast("Als Aufgabe übernommen")
                                },
                                onSendToT3: {
                                    let text = clip.transcript ?? ""
                                    model.openT3Composer(excerpt: "[\(clip.started.formatted(date: .omitted, time: .standard))] \(clip.source.title): \(text)")
                                },
                                onCopy: {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(clip.transcript ?? "", forType: .string)
                                    model.showToast("Abschnitt kopiert")
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 18)
                }
            }
        }
    }

    // MARK: Center Tab 2 — Manual Notes

    private var manualNotesView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button { model.insertTimestampIntoNotes() } label: {
                    Label("Zeitstempel", systemImage: "clock.badge.plus")
                        .font(.plexSans(12))
                        .foregroundStyle(MeetingStyle.ink)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(MeetingStyle.surface, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)

                Button { model.saveNotesToBlueyWorkspace() } label: {
                    Label("In Bluey-Notizen", systemImage: "square.and.arrow.up")
                        .font(.plexSans(12))
                        .foregroundStyle(MeetingStyle.ink)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(MeetingStyle.surface, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    model.openT3Composer(titleOverride: model.session?.displayTitle, excerpt: notesDraft)
                } label: {
                    Label("Notizen an T3 Code", systemImage: "paperplane")
                        .font(.plexSans(12).weight(.medium))
                        .foregroundStyle(Theme.blue)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(Theme.blue.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)

            ZStack(alignment: .topLeading) {
                if notesDraft.isEmpty {
                    Text("Notiere Entscheidungen, Stichpunkte oder offene Fragen …\nAlles wird automatisch in ~/Documents/Bluey Notes/Notizen/ gespeichert.")
                        .font(.plexSans(14))
                        .foregroundStyle(MeetingStyle.inkMuted.opacity(0.55))
                        .padding(.horizontal, 22)
                        .padding(.top, 14)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $notesDraft)
                    .font(.plexSans(14))
                    .lineSpacing(4)
                    .foregroundStyle(MeetingStyle.ink)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .onChange(of: notesDraft) { _, newValue in
                        if loadedSessionID == model.session?.id {
                            model.updateManualNotes(newValue)
                        }
                    }
            }
            .background(MeetingStyle.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(MeetingStyle.border))
            .padding(.horizontal, 18)
            .padding(.bottom, 16)
        }
    }

    // MARK: Center Tab 3 — Easy-Access Folder & Files Browser

    private var filesBrowserView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Quick-Access Library Folders
                VStack(alignment: .leading, spacing: 10) {
                    Text("Schnellzugriff-Ordner")
                        .font(.plexSans(13).weight(.semibold))
                        .foregroundStyle(.white)
                    Text("Alle Nachrichten, Notizen, Aufgaben und deine Meeting-Zeiterfassung liegen automatisch als lesbare Markdown-Dateien in ~/Documents/Bluey Notes.")
                        .font(.plexSans(12))
                        .foregroundStyle(MeetingStyle.inkMuted)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 175), spacing: 10)], spacing: 10) {
                        LibraryFolderTile(
                            title: "Notizen",
                            subtitle: "Bluey Notes/Notizen",
                            icon: "doc.text.fill",
                            color: Theme.accentLight
                        ) { model.revealNotesFolder() }
                        LibraryFolderTile(
                            title: "Nachrichten & Calls",
                            subtitle: "Bluey Notes/Nachrichten",
                            icon: "bubble.left.and.bubble.right.fill",
                            color: Theme.blue
                        ) { model.revealMessagesFolder() }
                        LibraryFolderTile(
                            title: "Aufgaben",
                            subtitle: "Bluey Notes/Aufgaben",
                            icon: "checklist",
                            color: Theme.yellow
                        ) { model.revealTasksFolder() }
                        LibraryFolderTile(
                            title: "Zeiterfassung.md",
                            subtitle: "Gesamtübersicht",
                            icon: "clock.fill",
                            color: Theme.green
                        ) { model.openTimeLog() }
                    }
                }

                // Current Meeting Session Files
                if let session = model.session {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Dateien dieses Meetings")
                                .font(.plexSans(13).weight(.semibold))
                                .foregroundStyle(.white)
                            Spacer()
                            Button("Ordner im Finder öffnen") { model.revealSessionFolder() }
                                .font(.plexSans(12).weight(.medium))
                                .foregroundStyle(Theme.accentLight)
                                .buttonStyle(.plain)
                        }

                        let files = sessionFileRows(for: session)
                        VStack(spacing: 6) {
                            ForEach(files) { item in
                                HStack(spacing: 10) {
                                    Image(systemName: item.icon)
                                        .font(.system(size: 14))
                                        .foregroundStyle(item.exists ? Theme.accentLight : MeetingStyle.inkMuted.opacity(0.45))
                                        .frame(width: 22)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.title)
                                            .font(.plexSans(13).weight(.medium))
                                            .foregroundStyle(item.exists ? .white : MeetingStyle.inkMuted)
                                        Text(item.detail)
                                            .font(.plexSans(11))
                                            .foregroundStyle(MeetingStyle.inkMuted)
                                    }
                                    Spacer()
                                    if item.exists {
                                        Button("Öffnen") { model.openFile(item.url) }
                                            .font(.plexSans(11.5).weight(.medium))
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 9)
                                            .frame(height: 25)
                                            .background(MeetingStyle.surfaceRaised, in: RoundedRectangle(cornerRadius: 6))
                                            .buttonStyle(.plain)
                                        Button { model.revealFile(item.url) } label: {
                                            Image(systemName: "magnifyingglass")
                                                .font(.system(size: 11))
                                                .foregroundStyle(MeetingStyle.inkMuted)
                                                .frame(width: 25, height: 25)
                                                .background(MeetingStyle.surfaceRaised, in: RoundedRectangle(cornerRadius: 6))
                                        }
                                        .buttonStyle(.plain)
                                        .help("Im Finder zeigen")
                                    } else {
                                        Text("Noch leer")
                                            .font(.plexSans(11))
                                            .foregroundStyle(MeetingStyle.inkMuted.opacity(0.6))
                                    }
                                    if let noteID = item.noteID {
                                        Button("Stift-Notiz öffnen", systemImage: "note.text") { model.onOpenNote?(noteID) }
                                            .labelStyle(.iconOnly)
                                            .help("Stift-Notiz öffnen")
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .background(MeetingStyle.surface, in: RoundedRectangle(cornerRadius: 9))
                                .overlay(RoundedRectangle(cornerRadius: 9).stroke(MeetingStyle.border))
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
        }
    }

    private struct SessionFileRow: Identifiable {
        var id: String { url.path }
        var title: String
        var detail: String
        var icon: String
        var url: URL
        var exists: Bool
        var noteID: UUID? = nil
    }

    private func sessionFileRows(for session: MeetingSession) -> [SessionFileRow] {
        let fm = FileManager.default
        let folder = session.folder
        let candidates: [(String, String, String, String)] = [
            ("Gesamt-Notizen (notes.md)", "Titel, Zeit, Notizen, Aufgaben, Q&A & Transkript", "doc.richtext", "notes.md"),
            ("Eigene Notizen (notizen.md)", "Deine manuellen Meeting-Notizen", "note.text", "notizen.md"),
            ("Nachrichten (nachrichten.md)", "Bluey-Rückfragen & Transkript", "bubble.left.and.bubble.right", "nachrichten.md"),
            ("Aufgaben (aufgaben.md)", "To-dos inkl. T3-Code-Status", "checklist", "aufgaben.md"),
            ("Transkript (transkript.txt)", "Reiner Text mit Zeitstempeln", "text.alignleft", "transkript.txt"),
            ("Audio-Aufnahmen (audio/)", "\(session.clips.count) Audio-Abschnitte", "waveform", "audio"),
        ]
        var rows = candidates.map { title, detail, icon, name in
            let url = folder.appendingPathComponent(name)
            return SessionFileRow(title: title, detail: detail, icon: icon, url: url, exists: fm.fileExists(atPath: url.path))
        }
        let video = session.videoURL ?? folder.appendingPathComponent("video.mp4")
        if !(model.changingCapture || model.recording), fm.fileExists(atPath: video.path) {
            rows.insert(SessionFileRow(title: "Bildschirmvideo", detail: video.lastPathComponent, icon: "video", url: video, exists: true), at: 0)
        }
        let screenshotsFolder = folder.appendingPathComponent("screenshots")
        if session.screenshots.isEmpty, fm.fileExists(atPath: screenshotsFolder.path) {
            rows.append(SessionFileRow(title: "Folien / Screenshots", detail: "screenshots/", icon: "photo.on.rectangle", url: screenshotsFolder, exists: true))
        }
        for shot in session.screenshots {
            let url = folder.appendingPathComponent(shot.filename)
            rows.append(SessionFileRow(title: shot.label ?? (shot.manual ? "Screenshot" : "Folie / Bildschirmänderung"),
                                       detail: shot.captured.formatted(date: .omitted, time: .standard),
                                       icon: "photo", url: url, exists: fm.fileExists(atPath: url.path)))
        }
        for drawing in session.drawings {
            let url = session.drawingsFolder.appendingPathComponent(drawing.pngFilename ?? drawing.svgFilename)
            rows.append(SessionFileRow(title: "Zeichnung · \(drawing.source)", detail: drawing.timecode,
                                       icon: "pencil.and.scribble", url: url, exists: fm.fileExists(atPath: url.path),
                                       noteID: drawing.noteID))
        }
        return rows
    }

    private var emptySessionState: some View {
        VStack(spacing: 16) {
            BlueyAvatar(mood: .listening).frame(width: 82, height: 73)
            Text("Bereit fürs nächste Meeting")
                .font(.fredoka(24))
                .foregroundStyle(.white)
            Text("Starte eine Aufnahme mit automatischer Transkription (⌘R) oder einen reinen Meeting-Timer mit Notizen (⌘N). Aufgaben schickst du mit einem Klick direkt an T3 Code.")
                .font(.plexSans(13.5))
                .foregroundStyle(MeetingStyle.inkMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            HStack(spacing: 10) {
                Button { Task { await model.start() } } label: {
                    Label("Aufnahme starten (⌘R)", systemImage: "record.circle")
                        .font(.plexSans(13).weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 38)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                Button { model.startNewTimedMeeting() } label: {
                    Label("Nur Timer & Notizen (⌘N)", systemImage: "stopwatch")
                        .font(.plexSans(13).weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 38)
                        .background(MeetingStyle.surface, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(MeetingStyle.borderStrong))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    // MARK: Right Rail — Tasks (T3 Code) & Bluey Q&A

    private var rightRail: some View {
        VStack(spacing: 0) {
            // Rail Tab Switcher
            HStack(spacing: 6) {
                ForEach(MeetingWindow.RailTab.allCases) { tab in
                    let selected = model.railTab == tab
                    let count = tab == .tasks ? (model.session?.tasks.filter { !$0.done }.count ?? 0) : (model.session?.messages.count ?? 0)
                    Button { model.railTab = tab } label: {
                        HStack(spacing: 6) {
                            Image(systemName: tab.icon).font(.system(size: 11.5))
                            Text(tab.rawValue).font(.plexSans(12.5).weight(selected ? .semibold : .medium))
                            if count > 0 {
                                Text("\(count)")
                                    .font(.plexMono(10))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(selected ? Theme.accent.opacity(0.35) : Color.white.opacity(0.08), in: Capsule())
                            }
                        }
                        .foregroundStyle(selected ? .white : MeetingStyle.inkMuted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background(selected ? MeetingStyle.surfaceRaised : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(MeetingStyle.surface, in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider().overlay(MeetingStyle.border)

            if model.railTab == .tasks {
                tasksRail
            } else {
                assistantRail
            }
        }
        .background(MeetingStyle.sidebar)
    }

    // MARK: Right Rail — Tasks & Direct T3 Code Send

    private var tasksRail: some View {
        VStack(alignment: .leading, spacing: 10) {
            // T3 Code Target Project Bar
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.blue)
                    Text("T3 Code Zielprojekt")
                        .font(.plexSans(11).weight(.semibold))
                        .foregroundStyle(MeetingStyle.inkMuted)
                    Spacer()
                    if !T3CodeBridge.isInstalled {
                        Text("CLI fehlt")
                            .font(.plexMono(10))
                            .foregroundStyle(Theme.peach)
                    } else {
                        Button("T3 öffnen") { model.openInT3Code() }
                            .font(.plexSans(11).weight(.medium))
                            .foregroundStyle(Theme.blue)
                            .buttonStyle(.plain)
                    }
                }

                HStack(spacing: 6) {
                    Menu {
                        ForEach(model.projects) { project in
                            Button {
                                model.selectProject(project.path)
                            } label: {
                                if project.path == model.selectedProjectPath {
                                    Label(project.name, systemImage: "checkmark")
                                } else {
                                    Text(project.name)
                                }
                            }
                        }
                        Divider()
                        Button { model.pickCustomProject() } label: {
                            Label("Anderen Ordner wählen …", systemImage: "folder.badge.plus")
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.blue)
                            Text(model.selectedProject?.name ?? "Projekt wählen…")
                                .font(.plexSans(12).weight(.medium))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 9))
                                .foregroundStyle(MeetingStyle.inkMuted)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(MeetingStyle.surface, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(MeetingStyle.border))
                    }
                    .menuStyle(.borderlessButton)

                    Button { model.pickCustomProject() } label: {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 12))
                            .foregroundStyle(MeetingStyle.inkMuted)
                            .frame(width: 30, height: 30)
                            .background(MeetingStyle.surface, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(MeetingStyle.border))
                    }
                    .buttonStyle(.plain)
                    .help("Projektordner für T3 Code hinzufügen")
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            // Quick Add Task Input
            HStack(spacing: 6) {
                TextField("Neue Aufgabe aus Meeting… (⌘T)", text: $newTaskTitle)
                    .textFieldStyle(.plain)
                    .font(.plexSans(12.5))
                    .focused($taskInputFocused)
                    .onSubmit { submitNewTask(sendImmediately: false) }
                Button { submitNewTask(sendImmediately: false) } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? MeetingStyle.inkMuted.opacity(0.4) : Theme.accentLight)
                }
                .buttonStyle(.plain)
                .disabled(newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Aufgabe zur Liste hinzufügen (↩)")

                Button { submitNewTask(sendImmediately: true) } label: {
                    Image(systemName: "paperplane.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? MeetingStyle.inkMuted.opacity(0.4) : Theme.blue)
                }
                .buttonStyle(.plain)
                .disabled(newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.sendingToT3)
                .help("Hinzufügen und sofort an T3 Code senden")
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(MeetingStyle.surface, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(MeetingStyle.border))
            .padding(.horizontal, 14)

            // AI Extract Action Items Button
            Button {
                Task { await model.extractTasksFromMeeting() }
            } label: {
                HStack(spacing: 6) {
                    if model.extractingTasks {
                        ProgressView().controlSize(.mini).tint(Theme.accentLight)
                    } else {
                        Image(systemName: "wand.and.stars").font(.system(size: 12))
                    }
                    Text(model.extractingTasks ? "Aufgaben werden erkannt …" : "Aufgaben aus Call erkennen")
                        .font(.plexSans(12).weight(.medium))
                    Spacer()
                }
                .foregroundStyle(Theme.accentLight)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(model.extractingTasks || model.session == nil)
            .padding(.horizontal, 14)

            // Task Cards List
            ScrollView {
                LazyVStack(spacing: 8) {
                    let tasks = model.session?.tasks ?? []
                    if tasks.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "paperplane")
                                .font(.system(size: 22))
                                .foregroundStyle(MeetingStyle.inkMuted.opacity(0.6))
                            Text("Noch keine Aufgaben")
                                .font(.plexSans(13).weight(.medium))
                                .foregroundStyle(.white)
                            Text("Tippe oben eine Aufgabe ein (⌘T) oder klicke im Transkript auf „+ Aufgabe“ – und schicke sie mit einem Klick an T3 Code.")
                                .font(.plexSans(11.5))
                                .foregroundStyle(MeetingStyle.inkMuted)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.vertical, 28)
                        .padding(.horizontal, 12)
                    } else {
                        ForEach(tasks) { task in
                            MeetingTaskCard(
                                task: task,
                                isSending: model.sendingTaskID == task.id,
                                onToggle: { model.toggleTask(task.id) },
                                onSendToT3: { Task { await model.sendTaskDirectlyToT3(task) } },
                                onEditAndSendToT3: { model.openT3Composer(for: task) },
                                onOpenT3: { model.openInT3Code(projectPath: task.t3ProjectPath) },
                                onAddToBlueyTodos: { model.sendTaskToBlueyTodos(task) },
                                onDelete: { model.deleteTask(task.id) }
                            )
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        }
    }

    private func submitNewTask(sendImmediately: Bool) {
        let title = newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        newTaskTitle = ""
        guard let created = model.addTask(title: title) else { return }
        if sendImmediately {
            Task { await model.sendTaskDirectlyToT3(created) }
        }
    }

    // MARK: Right Rail — Bluey Q&A

    private var assistantRail: some View {
        let quickPrompts = [
            "Was wurde gerade gesagt?",
            "Welche Aufgaben habe ich?",
            "Kurz zusammenfassen",
            "Was soll ich antworten?",
        ]

        return VStack(spacing: 0) {
            // Quick Prompt Chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(quickPrompts, id: \.self) { prompt in
                        Button {
                            Task { _ = await model.ask(prompt) }
                        } label: {
                            Text(prompt)
                                .font(.plexSans(11.5))
                                .foregroundStyle(MeetingStyle.ink)
                                .padding(.horizontal, 10)
                                .frame(height: 26)
                                .background(MeetingStyle.surface, in: Capsule())
                                .overlay(Capsule().stroke(MeetingStyle.border))
                        }
                        .buttonStyle(.plain)
                        .disabled(model.answering || model.changingCapture)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }

            Divider().overlay(MeetingStyle.border)

            // Conversation Messages
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        let messages = model.session?.messages ?? []
                        if messages.isEmpty && !model.answering {
                            VStack(spacing: 8) {
                                BlueyAvatar(mood: .listening, animated: false).frame(width: 44, height: 39)
                                Text("Private Rückfragen an Bluey")
                                    .font(.plexSans(13).weight(.semibold))
                                    .foregroundStyle(.white)
                                Text("Frag Bluey jederzeit leise nach Details aus dem Call (⌘L). Antworten landen automatisch im Nachrichten-Ordner.")
                                    .font(.plexSans(11.5))
                                    .foregroundStyle(MeetingStyle.inkMuted)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                            .padding(.horizontal, 12)
                        }

                        ForEach(messages) { msg in
                            QABubble(
                                message: msg,
                                onMakeTask: {
                                    let shortTitle = String(msg.text.split(whereSeparator: \.isNewline).first ?? "Aufgabe aus Bluey-Antwort").prefix(84).description
                                    _ = model.addTask(title: shortTitle, details: msg.text)
                                    model.railTab = .tasks
                                    model.showToast("Aufgabe erstellt")
                                },
                                onSendToT3: {
                                    model.openT3Composer(excerpt: msg.text)
                                },
                                onCopy: {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(msg.text, forType: .string)
                                    model.showToast("Nachricht kopiert")
                                }
                            )
                        }

                        if model.answering {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.mini).tint(Theme.accentLight)
                                    Text("Bluey").font(.plexSans(11).weight(.semibold)).foregroundStyle(Theme.accentLight)
                                }
                                Text(model.answer.isEmpty ? "Schaut im Transkript nach …" : model.answer)
                                    .font(.plexSans(12.5))
                                    .foregroundStyle(MeetingStyle.ink)
                                    .textSelection(.enabled)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(MeetingStyle.surface, in: RoundedRectangle(cornerRadius: 10))
                        }
                        Color.clear.frame(height: 1).id("qa-end")
                    }
                    .padding(14)
                }
                .onChange(of: model.answer) { _, _ in proxy.scrollTo("qa-end") }
                .onChange(of: model.session?.messages.count) { _, _ in proxy.scrollTo("qa-end") }
            }

            Divider().overlay(MeetingStyle.border)

            // Ask Input
            HStack(spacing: 8) {
                TextField("Bluey fragen… (⌘L)", text: $question)
                    .textFieldStyle(.plain)
                    .font(.plexSans(12.5))
                    .focused($questionFocused)
                    .onSubmit(submitQuestion)
                Button(action: submitQuestion) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 19))
                        .foregroundStyle(canAsk ? Theme.accentLight : MeetingStyle.inkMuted.opacity(0.35))
                }
                .buttonStyle(.plain)
                .disabled(!canAsk)
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(MeetingStyle.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(MeetingStyle.border))
            .padding(12)
        }
    }

    private var canAsk: Bool {
        !model.answering && !model.changingCapture && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitQuestion() {
        guard canAsk else { return }
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            if await model.ask(text) { question = "" }
        }
    }

    private func toastBanner(_ toast: MeetingWindow.ToastMessage) -> some View {
        HStack(spacing: 10) {
            Image(systemName: toast.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(toast.isError ? Theme.peach : Theme.green)
            Text(toast.text)
                .font(.plexSans(12.5).weight(.medium))
                .foregroundStyle(.white)
            if let path = toast.openT3ProjectPath {
                Button("In T3 Code öffnen") { model.openInT3Code(projectPath: path) }
                    .font(.plexSans(12).weight(.semibold))
                    .foregroundStyle(Theme.blue)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(MeetingStyle.surfaceRaised, in: Capsule())
        .overlay(Capsule().stroke(toast.isError ? Theme.peach.opacity(0.45) : Theme.green.opacity(0.45)))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    }
}

// MARK: - Subcomponents

private struct ShortcutPill: View {
    var text: String
    var light = false
    init(_ text: String, light: Bool = false) {
        self.text = text
        self.light = light
    }
    var body: some View {
        Text(text)
            .font(.plexMono(10).weight(.medium))
            .foregroundStyle(light ? .white.opacity(0.88) : MeetingStyle.inkMuted)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(light ? Color.white.opacity(0.18) : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
    }
}

private struct FolderQuickButton: View {
    var title: String
    var icon: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 11))
                Text(title).font(.plexSans(10)).lineLimit(1)
            }
            .foregroundStyle(MeetingStyle.inkMuted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(MeetingStyle.surface, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(MeetingStyle.border))
        }
        .buttonStyle(.plain)
    }
}

private struct LibraryFolderTile: View {
    var title: String
    var subtitle: String
    var icon: String
    var color: Color
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(color)
                    .frame(width: 32, height: 32)
                    .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.plexSans(13).weight(.semibold)).foregroundStyle(.white)
                    Text(subtitle).font(.plexSans(10.5)).foregroundStyle(MeetingStyle.inkMuted).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(MeetingStyle.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(MeetingStyle.border))
        }
        .buttonStyle(.plain)
    }
}

@available(macOS 15, *)
private struct TranscriptBubbleRow: View {
    let clip: MeetingAudio.Clip
    var onAddTask: () -> Void
    var onSendToT3: () -> Void
    var onCopy: () -> Void
    @State private var hovering = false

    private var isUser: Bool { clip.source == .microphone }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(isUser ? Theme.accentLight : Theme.green)
                        .frame(width: 6, height: 6)
                    Text(isUser ? "Du (Mikrofon)" : "Call (Mac-Audio)")
                        .font(.plexSans(11.5).weight(.semibold))
                        .foregroundStyle(isUser ? Theme.accentLight : Theme.green)
                }
                Text(clip.started.formatted(date: .omitted, time: .standard))
                    .font(.plexMono(10.5))
                    .foregroundStyle(MeetingStyle.inkMuted.opacity(0.8))
                Spacer()
                HStack(spacing: 5) {
                    Button(action: onAddTask) {
                        Label("Aufgabe", systemImage: "plus")
                            .font(.plexSans(10.5).weight(.medium))
                            .foregroundStyle(MeetingStyle.ink)
                            .padding(.horizontal, 7)
                            .frame(height: 22)
                            .background(Color.white.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Button(action: onSendToT3) {
                        Label("T3 Code", systemImage: "paperplane.fill")
                            .font(.plexSans(10.5).weight(.medium))
                            .foregroundStyle(Theme.blue)
                            .padding(.horizontal, 7)
                            .frame(height: 22)
                            .background(Theme.blue.opacity(0.16), in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Button(action: onCopy) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                            .foregroundStyle(MeetingStyle.inkMuted)
                            .frame(width: 22, height: 22)
                            .background(Color.white.opacity(0.06), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                .opacity(hovering ? 1 : 0.45)
            }

            Text(clip.transcript ?? "")
                .font(.plexSans(13.5))
                .lineSpacing(3)
                .foregroundStyle(MeetingStyle.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(isUser ? Theme.accent.opacity(0.11) : MeetingStyle.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(isUser ? Theme.accent.opacity(0.24) : MeetingStyle.border)
        )
        .onHover { hovering = $0 }
    }
}

private struct MeetingTaskCard: View {
    let task: MeetingTask
    let isSending: Bool
    var onToggle: () -> Void
    var onSendToT3: () -> Void
    var onEditAndSendToT3: () -> Void
    var onOpenT3: () -> Void
    var onAddToBlueyTodos: () -> Void
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Button(action: onToggle) {
                    Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(task.done ? Theme.green : MeetingStyle.inkMuted)
                }
                .buttonStyle(.plain)
                .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text(task.title)
                        .font(.plexSans(13).weight(.medium))
                        .foregroundStyle(task.done ? MeetingStyle.inkMuted : .white)
                        .strikethrough(task.done, color: MeetingStyle.inkMuted)
                        .textSelection(.enabled)
                    if !task.details.isEmpty {
                        Text(task.details)
                            .font(.plexSans(11.5))
                            .foregroundStyle(MeetingStyle.inkMuted)
                            .lineLimit(3)
                    }
                    if let quote = task.sourceQuote, !quote.isEmpty {
                        Text("„\(quote)“")
                            .font(.plexSans(11).italic())
                            .foregroundStyle(MeetingStyle.inkMuted.opacity(0.75))
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 4)
            }

            HStack(spacing: 6) {
                if task.isSentToT3 {
                    Button(action: onOpenT3) {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 10.5))
                            Text("In T3 Code\(task.t3ProjectName.map { " · \($0)" } ?? "")")
                                .font(.plexSans(11).weight(.medium))
                                .lineLimit(1)
                        }
                        .foregroundStyle(Theme.green)
                        .padding(.horizontal, 8)
                        .frame(height: 25)
                        .background(Theme.green.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help("Projekt in T3 Code öffnen")
                } else {
                    Button(action: onSendToT3) {
                        HStack(spacing: 5) {
                            if isSending {
                                ProgressView().controlSize(.mini).tint(.white)
                            } else {
                                Image(systemName: "paperplane.fill").font(.system(size: 10))
                            }
                            Text(isSending ? "Sende …" : "An T3 Code")
                                .font(.plexSans(11).weight(.semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .frame(height: 25)
                        .background(Theme.blue, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .disabled(isSending)
                    .help("Sofort an das ausgewählte T3-Code-Projekt senden")
                }

                Button(action: onEditAndSendToT3) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 11))
                        .foregroundStyle(MeetingStyle.inkMuted)
                        .frame(width: 25, height: 25)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("Prompt & Projekt vor dem Senden anpassen")

                Button(action: onAddToBlueyTodos) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 11))
                        .foregroundStyle(MeetingStyle.inkMuted)
                        .frame(width: 25, height: 25)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("Zusätzlich in Bluey-Todos speichern")

                Spacer()

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 10.5))
                        .foregroundStyle(MeetingStyle.inkMuted.opacity(0.75))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(MeetingStyle.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(task.isSentToT3 ? Theme.green.opacity(0.28) : MeetingStyle.border))
    }
}

private struct QABubble: View {
    let message: ChatMessage
    var onMakeTask: () -> Void
    var onSendToT3: () -> Void
    var onCopy: () -> Void

    private var isUser: Bool { message.role == .user }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(isUser ? "Du" : "Bluey")
                    .font(.plexSans(11).weight(.semibold))
                    .foregroundStyle(isUser ? MeetingStyle.inkMuted : Theme.accentLight)
                Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                    .font(.plexMono(10))
                    .foregroundStyle(MeetingStyle.inkMuted.opacity(0.65))
                Spacer()
                if !isUser {
                    HStack(spacing: 4) {
                        Button(action: onMakeTask) {
                            Image(systemName: "checklist.unchecked")
                                .font(.system(size: 10.5))
                                .foregroundStyle(MeetingStyle.inkMuted)
                                .frame(width: 22, height: 22)
                                .background(Color.white.opacity(0.06), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Als Aufgabe speichern")

                        Button(action: onSendToT3) {
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.blue)
                                .frame(width: 22, height: 22)
                                .background(Theme.blue.opacity(0.15), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .help("An T3 Code senden")

                        Button(action: onCopy) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 10))
                                .foregroundStyle(MeetingStyle.inkMuted)
                                .frame(width: 22, height: 22)
                                .background(Color.white.opacity(0.06), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Kopieren")
                    }
                }
            }
            Text(message.text)
                .font(.plexSans(12.5))
                .lineSpacing(2.5)
                .foregroundStyle(MeetingStyle.ink)
                .textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isUser ? Color.white.opacity(0.04) : MeetingStyle.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(isUser ? Color.clear : MeetingStyle.border))
    }
}

// MARK: - Sheets

@available(macOS 15, *)
private struct T3SendSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: MeetingWindow
    @State var draft: MeetingWindow.T3SendDraft
    @State private var localError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "paperplane.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Aufgabe an T3 Code senden")
                        .font(.fredoka(20))
                        .foregroundStyle(.white)
                    Text("Startet direkt einen neuen Thread im gewählten T3-Code-Projekt.")
                        .font(.plexSans(12))
                        .foregroundStyle(MeetingStyle.inkMuted)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 18)).foregroundStyle(MeetingStyle.inkMuted)
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Zielprojekt").font(.plexSans(12).weight(.semibold)).foregroundStyle(MeetingStyle.inkMuted)
                HStack(spacing: 8) {
                    Picker("", selection: $draft.projectPath) {
                        ForEach(model.projects) { project in
                            Text("\(project.name) (\(project.path))").tag(project.path)
                        }
                    }
                    .labelsHidden()
                    Button("Ordner wählen…") {
                        if let picked = T3CodeBridge.pickProjectFolder() {
                            model.refreshProjects()
                            draft.projectPath = picked.path
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Thread-Titel").font(.plexSans(12).weight(.semibold)).foregroundStyle(MeetingStyle.inkMuted)
                TextField("z.B. API-Bug aus Daily beheben", text: $draft.title)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Aufgabe & Meeting-Kontext").font(.plexSans(12).weight(.semibold)).foregroundStyle(MeetingStyle.inkMuted)
                TextEditor(text: $draft.prompt)
                    .font(.plexSans(13))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 190)
                    .background(MeetingStyle.surface, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(MeetingStyle.border))
            }

            HStack(spacing: 16) {
                Toggle("T3 Code nach dem Senden öffnen", isOn: $model.openT3AfterSend)
                    .font(.plexSans(12))
                Spacer()
                HStack(spacing: 6) {
                    Text("Optional Worktree-Basis:").font(.plexSans(11.5)).foregroundStyle(MeetingStyle.inkMuted)
                    TextField("z.B. main", text: $draft.worktreeBase)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }
            }

            if let err = localError ?? model.error {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.peach)
                    Text(err).font(.plexSans(12)).foregroundStyle(Theme.peach).textSelection(.enabled)
                    Spacer()
                    Button("Prompt kopieren") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(draft.prompt, forType: .string)
                        model.showToast("Prompt kopiert")
                    }
                    .controlSize(.small)
                }
                .padding(10)
                .background(Theme.peach.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                Button("Prompt kopieren") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(draft.prompt, forType: .string)
                    model.showToast("Prompt in Zwischenablage kopiert")
                }
                .buttonStyle(.bordered)

                Spacer()
                Button("Abbrechen") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    localError = nil
                    Task {
                        if await model.sendDraftToT3(draft) {
                            dismiss()
                        } else {
                            localError = model.error
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if model.sendingToT3 { ProgressView().controlSize(.small) }
                        Text(model.sendingToT3 ? "Wird gesendet …" : "An T3 Code senden (⌘↩)")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.blue)
                .disabled(model.sendingToT3 || draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.projectPath.isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(22)
        .frame(width: 600, height: 520)
        .background(MeetingStyle.canvas)
        .preferredColorScheme(.dark)
    }
}

@available(macOS 15, *)
private struct MeetingTimeOverviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: MeetingWindow

    var body: some View {
        let stats = model.timeStats
        let summaries = model.allTimeSummaries

        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Meeting-Zeiterfassung")
                        .font(.fredoka(22))
                        .foregroundStyle(.white)
                    Text("Automatisch gespeichert in ~/Documents/Bluey Notes/Zeiterfassung.md")
                        .font(.plexSans(12))
                        .foregroundStyle(MeetingStyle.inkMuted)
                }
                Spacer()
                Button("Zeiterfassung.md öffnen") { model.openTimeLog() }
                    .buttonStyle(.bordered)
                Button("Fertig") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            HStack(spacing: 10) {
                timeKPI("Heute", MeetingDurationFormatter.human(stats.todaySeconds), "\(stats.todayCount) Meetings", Theme.green)
                timeKPI("Diese Woche", MeetingDurationFormatter.human(stats.weekSeconds), "\(stats.weekCount) Meetings", Theme.accentLight)
                timeKPI("Gesamt", MeetingDurationFormatter.human(stats.totalSeconds), "\(stats.totalCount) Meetings", Theme.blue)
                timeKPI("Ø Dauer", MeetingDurationFormatter.human(stats.averageSeconds), "pro Meeting", Theme.yellow)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Letzte 7 Tage (Minuten)")
                    .font(.plexSans(12).weight(.semibold))
                    .foregroundStyle(MeetingStyle.inkMuted)
                Chart(stats.last7Days) { day in
                    BarMark(
                        x: .value("Tag", day.date, unit: .day),
                        y: .value("Minuten", day.minutes)
                    )
                    .foregroundStyle(Theme.accent)
                    .cornerRadius(5)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { _ in
                        AxisValueLabel(format: .dateTime.weekday(.abbreviated).locale(Locale(identifier: "de_DE")))
                            .foregroundStyle(MeetingStyle.inkMuted)
                    }
                }
                .chartYAxis {
                    AxisMarks { _ in
                        AxisGridLine().foregroundStyle(MeetingStyle.border)
                        AxisValueLabel().foregroundStyle(MeetingStyle.inkMuted)
                    }
                }
                .frame(height: 155)
            }
            .padding(14)
            .background(MeetingStyle.surface, in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 6) {
                Text("Letzte Meetings")
                    .font(.plexSans(12).weight(.semibold))
                    .foregroundStyle(MeetingStyle.inkMuted)
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(summaries.prefix(20)) { entry in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.title).font(.plexSans(13).weight(.medium)).foregroundStyle(.white).lineLimit(1)
                                    Text(entry.started.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute().locale(Locale(identifier: "de_DE"))))
                                        .font(.plexSans(11)).foregroundStyle(MeetingStyle.inkMuted)
                                }
                                Spacer()
                                if entry.sentToT3Count > 0 {
                                    Text("\(entry.sentToT3Count) T3")
                                        .font(.plexMono(10.5))
                                        .foregroundStyle(Theme.blue)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2)
                                        .background(Theme.blue.opacity(0.15), in: Capsule())
                                }
                                Text(MeetingDurationFormatter.human(entry.duration))
                                    .font(.plexMono(12.5).weight(.semibold))
                                    .foregroundStyle(entry.isActive ? Theme.green : .white)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(MeetingStyle.surface, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 640, height: 540)
        .background(MeetingStyle.canvas)
        .preferredColorScheme(.dark)
    }

    private func timeKPI(_ title: String, _ value: String, _ sub: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.plexSans(11)).foregroundStyle(MeetingStyle.inkMuted)
            Text(value).font(.plexMono(18).weight(.bold)).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.7)
            Text(sub).font(.plexSans(10.5)).foregroundStyle(MeetingStyle.inkMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(MeetingStyle.surface, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct MeetingShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let windowShortcuts: [(String, String)] = [
        ("⌘R", "Aufnahme starten / stoppen"),
        ("⌘N", "Neues Meeting (nur Zeiterfassung & Notizen)"),
        ("⌘⇧P", "Meeting-Timer pausieren / fortsetzen"),
        ("⌘1 / ⌘2 / ⌘3", "Transkript · Notizen · Ordner & Dateien"),
        ("⌘T", "Neue Aufgabe eingeben"),
        ("⌘⇧T", "Aufgabe / Kontext an T3 Code senden"),
        ("⌘L", "Private Rückfrage an Bluey tippen"),
        ("⌘F", "Meetings durchsuchen"),
        ("⌘⇧O", "Bluey Notes Ordner im Finder öffnen"),
        ("⌘\\", "Seitenleiste ein-/ausblenden"),
        ("⌘/", "Diese Shortcut-Übersicht"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Meeting-Shortcuts")
                    .font(.fredoka(22))
                    .foregroundStyle(.white)
                Spacer()
                Button("Fertig") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Im Meeting-Fenster")
                        .font(.plexSans(12.5).weight(.semibold))
                        .foregroundStyle(Theme.accentLight)
                    ForEach(windowShortcuts, id: \.0) { key, desc in
                        HStack {
                            Text(desc).font(.plexSans(12.5)).foregroundStyle(MeetingStyle.ink)
                            Spacer()
                            ShortcutPill(key)
                        }
                        .padding(.vertical, 3)
                    }
                }
                .frame(maxWidth: .infinity)

                Divider().overlay(MeetingStyle.border)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Global (in jeder App)")
                        .font(.plexSans(12.5).weight(.semibold))
                        .foregroundStyle(Theme.green)
                    ForEach([ShortcutAction.meetingNotes, .meetingRecord, .meetingToT3]) { action in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(action.title).font(.plexSans(12.5)).foregroundStyle(MeetingStyle.ink)
                                Text(action.detail).font(.plexSans(10.5)).foregroundStyle(MeetingStyle.inkMuted)
                            }
                            Spacer()
                            ShortcutPill(ShortcutStore.get(action)?.display ?? "Aus")
                        }
                        .padding(.vertical, 4)
                    }
                    Spacer()
                    Text("Globale Shortcuts kannst du jederzeit in Bluey Settings ▸ Shortcuts ändern.")
                        .font(.plexSans(11))
                        .foregroundStyle(MeetingStyle.inkMuted)
                }
                .frame(width: 240)
            }
        }
        .padding(22)
        .frame(width: 620, height: 420)
        .background(MeetingStyle.canvas)
        .preferredColorScheme(.dark)
    }
}
