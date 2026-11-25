import AppKit
import GooglyShared
import SwiftUI

@available(macOS 15, *)
@MainActor
final class MeetingWindow: ObservableObject {
    struct DrawingEvent: Codable, Identifiable, Equatable {
        var id = UUID()
        var timestamp = Date()
        /// Elapsed seconds since `session.started` (the exact time in the meeting/video).
        var videoOffsetSeconds: Double
        /// "Notiz" or "Bildschirm"
        var source: String
        var noteID: UUID?
        var svgFilename: String
        var pngFilename: String?
        var strokeCount: Int
        var ocrText: String?

        var timecode: String { InkDrawing.formatVideoTime(videoOffsetSeconds) }
    }

    struct Session: Codable, Identifiable {
        var id = UUID()
        var started = Date()
        var ended: Date?
        var clips: [MeetingAudio.Clip] = []
        var messages: [ChatMessage] = []
        var drawings: [DrawingEvent] = []
        var screenshots: [MeetingAudio.Screenshot] = []
        var videoFilename: String?
        var captureTargetName: String?

        var folder: URL { MeetingNotes.folder(session: id.uuidString, started: started) }
        var audioFolder: URL { folder.appendingPathComponent("audio", isDirectory: true) }
        var notesURL: URL { folder.appendingPathComponent("notes.md") }
        var videoURL: URL? { videoFilename.map { folder.appendingPathComponent($0) } }
        var drawingsFolder: URL { folder.appendingPathComponent("drawings", isDirectory: true) }

        var transcript: String {
            var rows: [(Date, String)] = clips.compactMap { clip in
                guard let text = clip.transcript, !text.isEmpty else { return nil }
                let offset = InkDrawing.formatVideoTime(max(0, clip.started.timeIntervalSince(started)))
                let time = clip.started.formatted(date: .omitted, time: .standard)
                return (clip.started, "[\(offset) · \(time)] \(clip.source.title): \(text)")
            }
            rows += drawings.map { d in
                let detail = (d.ocrText?.isEmpty == false ? d.ocrText! : "\(d.strokeCount) Striche (\(d.svgFilename))")
                return (d.timestamp, "[\(d.timecode)] Zeichnung (\(d.source)): \(detail)")
            }
            return rows.sorted { $0.0 < $1.0 }.map(\.1).joined(separator: "\n\n")
        }

        enum CodingKeys: String, CodingKey {
            case id, started, ended, clips, messages, drawings, screenshots, videoFilename, captureTargetName
        }

        init(
            id: UUID = UUID(),
            started: Date = Date(),
            ended: Date? = nil,
            clips: [MeetingAudio.Clip] = [],
            messages: [ChatMessage] = [],
            drawings: [DrawingEvent] = [],
            screenshots: [MeetingAudio.Screenshot] = [],
            videoFilename: String? = nil,
            captureTargetName: String? = nil
        ) {
            self.id = id
            self.started = started
            self.ended = ended
            self.clips = clips
            self.messages = messages
            self.drawings = drawings
            self.screenshots = screenshots
            self.videoFilename = videoFilename
            self.captureTargetName = captureTargetName
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            started = try c.decodeIfPresent(Date.self, forKey: .started) ?? Date()
            ended = try c.decodeIfPresent(Date.self, forKey: .ended)
            clips = try c.decodeIfPresent([MeetingAudio.Clip].self, forKey: .clips) ?? []
            messages = try c.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
            drawings = try c.decodeIfPresent([DrawingEvent].self, forKey: .drawings) ?? []
            screenshots = try c.decodeIfPresent([MeetingAudio.Screenshot].self, forKey: .screenshots) ?? []
            videoFilename = try c.decodeIfPresent(String.self, forKey: .videoFilename)
            captureTargetName = try c.decodeIfPresent(String.self, forKey: .captureTargetName)
        }
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
    @Published private(set) var status = ""
    @Published private(set) var error: String?
    @Published private(set) var visualWarning: String?
    @Published private(set) var recording = false
    @Published private(set) var changingCapture = false
    @Published private(set) var transcribing = false
    @Published private(set) var answering = false
    @Published private(set) var takingScreenshot = false
    @Published private(set) var answer = ""

    @Published var recordVideo: Bool {
        didSet { UserDefaults.standard.set(recordVideo, forKey: DefaultsKey.recordVideo) }
    }
    @Published var autoScreenshots: Bool {
        didSet { UserDefaults.standard.set(autoScreenshots, forKey: DefaultsKey.autoScreenshots) }
    }
    @Published var selectedTarget: MeetingAudio.CaptureTarget = .display
    @Published private(set) var availableTargets: [MeetingAudio.CaptureTarget] = [.display]

    var busy: Bool { recording || changingCapture || transcribing || answering }

    private var window: NSWindow?
    private var recorder: MeetingAudio?
    private var timer: Task<Void, Never>?
    private var collecting: Task<Void, Never>?
    private var transcription: Task<Void, Never>?
    private var failedClips = Set<String>()

    init() {
        let defaults = UserDefaults.standard
        recordVideo = defaults.object(forKey: DefaultsKey.recordVideo) as? Bool ?? true
        autoScreenshots = defaults.object(forKey: DefaultsKey.autoScreenshots) as? Bool ?? true
        reloadArchive()
    }

    func show() {
        if window == nil {
            let controller = NSHostingController(rootView: MeetingView(model: self).background(Theme.background).preferredColorScheme(.dark).tint(Theme.accentLight))
            let window = NSWindow(contentViewController: controller)
            window.title = "Bluey · Meeting-Aufnahmen"
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(Theme.background)
            window.setContentSize(NSSize(width: 780, height: 700))
            window.minSize = NSSize(width: 580, height: 540)
            window.styleMask.insert(.resizable)
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("BlueyMeetingNotes")
            if !window.setFrameUsingName("BlueyMeetingNotes") { window.center() }
            self.window = window
            reloadArchive()
        }
        Task { await refreshTargets() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func refreshTargets(preferWindowID: CGWindowID? = nil) async {
        let targets = await MeetingAudio.availableTargets()
        availableTargets = targets
        if let preferWindowID,
           let matched = targets.first(where: { $0.windowID == preferWindowID }) {
            selectedTarget = matched
        } else if !targets.contains(selectedTarget) {
            selectedTarget = .display
        }
    }

    func select(_ session: Session?) {
        guard !busy else { return }
        self.session = session
        failedClips.removeAll()
        error = nil
        visualWarning = nil
        status = ""
    }

    func start(preferredWindowID: CGWindowID? = nil) async {
        guard !busy else { return }
        guard Keychain.get(.openai) != nil else {
            error = "Füge deinen OpenAI-Schlüssel im Bluey-Menü hinzu."
            return
        }
        changingCapture = true
        error = nil
        visualWarning = nil
        status = "Aufnahme wird gestartet …"
        if preferredWindowID != nil {
            await refreshTargets(preferWindowID: preferredWindowID)
        }
        let session = Session()
        let visual = MeetingAudio.VisualConfig(
            recordVideo: recordVideo,
            autoScreenshots: autoScreenshots,
            target: selectedTarget
        )
        let recorder = MeetingAudio(
            folder: session.audioFolder,
            sessionFolder: session.folder,
            visual: visual,
            onScreenshot: { [weak self] shot in
                Task { @MainActor in
                    guard let self, self.session?.id == session.id else { return }
                    self.session?.screenshots.append(shot)
                    self.save()
                }
            },
            onVisualWarning: { [weak self] message in
                Task { @MainActor in
                    guard let self, self.session?.id == session.id || self.changingCapture else { return }
                    self.visualWarning = message
                }
            },
            onFailure: { [weak self] error in
                Task { @MainActor in
                    guard let self, self.session?.id == session.id, self.recording else { return }
                    await self.stop(failure: error.localizedDescription)
                }
            }
        )
        do {
            try await recorder.start()
            var activeSession = session
            activeSession.captureTargetName = visual.enabled ? (recorder.resolvedTargetName ?? selectedTarget.displayName) : nil
            self.session = activeSession
            failedClips.removeAll()
            self.recorder = recorder
            recording = true
            onRecordingStateChanged?(true, session.started)
            status = ""
            save()
            timer = Task { [weak self] in
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
        guard recording, let recorder, !takingScreenshot else { return }
        takingScreenshot = true
        defer { takingScreenshot = false }
        if let shot = await recorder.captureManualScreenshot() {
            session?.screenshots.append(shot)
            save()
            status = "Screenshot gespeichert."
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2.5))
                if self?.status == "Screenshot gespeichert." { self?.status = "" }
            }
        } else {
            visualWarning = "Screenshot konnte nicht erstellt werden."
        }
    }

    func stop(failure: String? = nil) async {
        guard recording, let recorder else { return }
        recording = false
        onRecordingStateChanged?(false, nil)
        changingCapture = true
        timer?.cancel()
        timer = nil
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
            if error == nil { error = "Mindestens eine Tonquelle lieferte kein Audio. Prüfe Call-Ausgabe, Mikrofon und macOS-Berechtigungen." }
        }
        session?.ended = Date()
        save()
        status = ""
        changingCapture = false
        reloadArchive()
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
        guard !transcribing, let session, session.clips.contains(where: { $0.transcript == nil && !failedClips.contains($0.id) }) else { return }
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
            reloadArchive()
        }
    }

    func ask(_ question: String) async -> Bool {
        guard !answering, !changingCapture, session != nil else { return false }
        answering = true
        answer = ""
        defer { answering = false; answer = "" }
        // Include the latest audio even if the periodic capture has not flushed yet.
        if recording {
            await collecting?.value
            await collect()
        }
        await transcription?.value
        let fullTranscript = session?.transcript ?? ""
        guard let session, !fullTranscript.isEmpty else {
            error = "Für die Rückfrage ist noch kein Transkript verfügbar."
            return false
        }
        let message = ChatMessage(role: .user, text: question)
        let excerpt = String(fullTranscript.suffix(195_000))
        let transcript = Data(excerpt.utf8)
        let attachment = ChatAttachment(name: "Call-Transkript.txt", mime: "text/plain", size: transcript.count)
        var questionWithTranscript = message
        questionWithTranscript.attachments = [attachment]
        do {
            let response = try await ChatEngine.stream(.init(
                messages: session.messages + [questionWithTranscript],
                model: ChatEngine.fallbackModel, webSearch: false,
                context: "Beantworte die Rückfrage auf Grundlage des beigefügten Call-Transkripts. "
                    + "Nenne die Zeit aus dem Transkript und zitiere die relevante Stelle. "
                    + "Wenn der Call die Frage offenlässt oder das Transkript lückenhaft ist, sage das. "
                    + "Schlage bei einer offenen Frage einen kurzen Satz vor, den der Nutzer im Call sagen kann."
                    + (excerpt == fullTranscript ? "" : " Der Anfang des langen Transkripts fehlt im beigefügten Auszug."),
                attachmentData: { $0 == attachment.id ? transcript : nil }
            ), onText: { [weak self] in self?.answer = $0 })
            guard !response.isEmpty else { throw ChatEngine.Failure.message("Bluey hat keine Antwort erhalten.") }
            self.session?.messages += [message, ChatMessage(role: .assistant, text: response)]
            save()
            reloadArchive()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func reveal() {
        if let session { NSWorkspace.shared.open(session.folder) }
    }

    func openVideo() {
        if let url = session?.videoURL, FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        }
    }

    func openScreenshot(_ shot: MeetingAudio.Screenshot) {
        guard let session else { return }
        NSWorkspace.shared.open(session.folder.appendingPathComponent(shot.filename))
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

    func openDrawingFile(_ filename: String) {
        guard let session else { return }
        let url = session.drawingsFolder.appendingPathComponent(filename)
        NSWorkspace.shared.open(url)
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

    private func save() {
        guard let session else { return }
        do {
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
                "id": session.id.uuidString, "started": session.started.timeIntervalSince1970,
                "entries": entries.sorted { ($0["time"] as? Double ?? 0) < ($1["time"] as? Double ?? 0) },
                "transcribing": session.clips.filter { $0.transcript == nil }.count
            ]
            notes["ended"] = session.ended?.timeIntervalSince1970
            notes["video"] = session.videoFilename
            notes["captureTarget"] = session.captureTargetName
            MeetingNotes.write(session: notes)
        } catch {
            self.error = "Call-Notizen konnten nicht gespeichert werden. \(error.localizedDescription)"
        }
    }

    private func reloadArchive() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: MeetingNotes.root, includingPropertiesForKeys: nil)) ?? []
        archive = folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("mac-call.json")) else { return nil }
            return try? JSONDecoder().decode(Session.self, from: data)
        }.sorted { $0.started > $1.started }
    }
}

@available(macOS 15, *)
private struct MeetingView: View {
    @ObservedObject var model: MeetingWindow
    @State private var question = ""

    private var recordingControls: some View {
        GroupBox("Meeting aufnehmen") {
            VStack(alignment: .leading, spacing: 10) {
                if model.recording {
                    HStack {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let elapsed = model.session.map { max(0, context.date.timeIntervalSince($0.started)) } ?? 0
                            Label("Aufnahme läuft · \(InkDrawing.formatVideoTime(elapsed))", systemImage: "record.circle.fill")
                                .foregroundStyle(.red)
                        }
                        Spacer()
                        Button("Aufnahme stoppen", systemImage: "stop.fill") { Task { await model.stop() } }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                    }
                    HStack {
                        Button("Screenshot", systemImage: "camera") { Task { await model.takeScreenshot() } }
                            .disabled(model.takingScreenshot)
                        Button("Stift-Notiz", systemImage: "pencil.and.scribble") { model.onNewInkNote?() }
                        Button("Auf Bildschirm zeichnen", systemImage: "scribble.variable") { model.onOpenScreenAnnotator?() }
                    }
                } else {
                    HStack {
                        Toggle("Bildschirmvideo aufnehmen", isOn: $model.recordVideo)
                        Toggle("Folien-Screenshots speichern", isOn: $model.autoScreenshots)
                    }
                    .toggleStyle(.checkbox)
                    if model.recordVideo || model.autoScreenshots {
                        HStack {
                            Text("Bildquelle")
                            Picker("Bildquelle", selection: $model.selectedTarget) {
                                ForEach(model.availableTargets) { target in
                                    Text(target.displayName).tag(target)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 280)
                            Button("Fensterliste aktualisieren", systemImage: "arrow.clockwise") {
                                Task { await model.refreshTargets() }
                            }
                            .labelStyle(.iconOnly)
                            .help("Fensterliste aktualisieren")
                        }
                    }
                    Text("Bluey nimmt Mac-Audio und Mikrofon auf und sendet Audio zur Transkription an OpenAI. Informiere die Teilnehmenden vor dem Start.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Aufnahme starten", systemImage: "record.circle") { Task { await model.start() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.busy)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(model.changingCapture)
        }
    }

    private var archiveControls: some View {
        GroupBox("Gespeicherte Aufnahmen") {
            VStack(alignment: .leading, spacing: 8) {
                if model.archive.isEmpty {
                    Text("Hier erscheinen deine Aufnahmen nach dem Stoppen.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Aufnahme auswählen", selection: Binding(
                        get: { model.archive.contains(where: { $0.id == model.session?.id }) ? model.session?.id : nil },
                        set: { id in
                            question = ""
                            model.select(model.archive.first { $0.id == id })
                        }
                    )) {
                        Text("Aufnahme auswählen").tag(nil as UUID?)
                        ForEach(model.archive) { session in
                            let date = session.started.formatted(date: .abbreviated, time: .shortened)
                            Text(session.videoURL == nil ? date : date + " · Video").tag(Optional(session.id))
                        }
                    }
                    .disabled(model.busy)
                    HStack {
                        if model.session?.videoURL != nil {
                            Button("Video ansehen", systemImage: "play.rectangle") { model.openVideo() }
                        }
                        if model.session != nil { Button("Aufnahmeordner öffnen") { model.reveal() } }
                    }
                    if model.session != nil && model.session?.videoURL == nil && !model.recording {
                        Text("Zu dieser Aufnahme gibt es kein Bildschirmvideo.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            recordingControls
            archiveControls
            if !model.status.isEmpty { Text(model.status).foregroundStyle(.secondary) }
            if model.transcribing { Text("Audio wird transkribiert …").foregroundStyle(.secondary) }
            if let warning = model.visualWarning {
                Text(warning).foregroundStyle(.orange).font(.callout).textSelection(.enabled)
            }
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if !model.transcribing && model.session?.clips.contains(where: { $0.transcript == nil }) == true {
                Button("Transkription erneut versuchen") { Task { await model.retry() } }
            }

            if let session = model.session, !session.screenshots.isEmpty {
                GroupBox("Screenshots & Folien (\(session.screenshots.count))") {
                    ScrollView(.horizontal, showsIndicators: true) {
                        HStack(spacing: 10) {
                            ForEach(session.screenshots) { shot in
                                let url = session.folder.appendingPathComponent(shot.filename)
                                Button {
                                    model.openScreenshot(shot)
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        if let nsImage = NSImage(contentsOf: url) {
                                            Image(nsImage: nsImage)
                                                .resizable()
                                                .aspectRatio(contentMode: .fill)
                                                .frame(width: 112, height: 64)
                                                .clipped()
                                                .cornerRadius(6)
                                        }
                                        HStack(spacing: 4) {
                                            Image(systemName: shot.manual ? "camera.fill" : "rectangle.on.rectangle")
                                                .font(.caption2)
                                            Text(shot.captured.formatted(date: .omitted, time: .shortened))
                                                .font(.caption2)
                                        }
                                        .foregroundStyle(.secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            if let drawings = model.session?.drawings, !drawings.isEmpty {
                GroupBox("Zeichnungen im Video (\(drawings.count))") {
                    ScrollView(.horizontal, showsIndicators: true) {
                        HStack(spacing: 10) {
                            ForEach(drawings) { item in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 6) {
                                        Text(item.timecode)
                                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.red.opacity(0.8), in: Capsule())
                                        Text(item.source)
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text("\(item.strokeCount) Str.")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    if let png = item.pngFilename,
                                       let folder = model.session?.drawingsFolder,
                                       let img = NSImage(contentsOf: folder.appendingPathComponent(png)) {
                                        Button { model.openDrawingFile(png) } label: {
                                            Image(nsImage: img)
                                                .resizable()
                                                .scaledToFit()
                                                .frame(width: 150, height: 96)
                                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                        }
                                        .buttonStyle(.plain)
                                        .help("Zeichnung in Vorschau öffnen")
                                    } else {
                                        Button("SVG öffnen") { model.openDrawingFile(item.svgFilename) }
                                            .controlSize(.small)
                                    }
                                    HStack(spacing: 8) {
                                        Button("Öffnen") { model.openDrawingFile(item.pngFilename ?? item.svgFilename) }
                                            .controlSize(.mini)
                                        if let nid = item.noteID {
                                            Button("Zur Notiz") { model.onOpenNote?(nid) }
                                                .controlSize(.mini)
                                        }
                                    }
                                }
                                .padding(8)
                                .frame(width: 170)
                                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            let transcript = model.session?.transcript ?? ""
            GroupBox("Transkript") {
                ScrollView {
                    Text(transcript.isEmpty ? "Hier erscheint das Transkript abschnittsweise." : transcript)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 100)
            }
            GroupBox("Private Rückfragen") {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(model.session?.messages ?? []) { message in
                                Text(message.role == .user ? "Du" : "Bluey").font(.headline)
                                Text(message.text).textSelection(.enabled)
                            }
                            if model.answering {
                                Text(model.answer.isEmpty ? "Bluey schaut im Transkript nach …" : model.answer)
                                    .textSelection(.enabled)
                            }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: model.answer) { _, _ in proxy.scrollTo("end") }
                    .onChange(of: model.session?.messages.count) { _, _ in proxy.scrollTo("end") }
                }
                .frame(minHeight: 75)
            }
            HStack {
                TextField("Was wurde gerade gesagt?", text: $question).onSubmit(submit)
                Button("Bluey fragen", action: submit).disabled(!canAsk)
            }
            .disabled(model.session == nil || model.answering)
        }
        .padding(18)
    }

    private var canAsk: Bool {
        model.session != nil && !model.answering && !model.changingCapture && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        guard canAsk else { return }
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { if await model.ask(text) { question = "" } }
    }
}
