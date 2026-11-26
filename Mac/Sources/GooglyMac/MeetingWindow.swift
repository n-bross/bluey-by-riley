import AppKit
import GooglyShared
import SwiftUI

@available(macOS 15, *)
@MainActor
final class MeetingWindow: ObservableObject {
    struct Session: Codable, Identifiable {
        var id = UUID()
        var started = Date()
        var ended: Date?
        var clips: [MeetingAudio.Clip] = []
        var messages: [ChatMessage] = []

        var folder: URL { MeetingNotes.folder(session: id.uuidString, started: started) }
        var audioFolder: URL { folder.appendingPathComponent("audio", isDirectory: true) }
        var transcript: String {
            clips.compactMap { clip in
                guard let text = clip.transcript, !text.isEmpty else { return nil }
                let time = clip.started.formatted(date: .omitted, time: .standard)
                return "[\(time)] \(clip.source.title): \(text)"
            }.joined(separator: "\n\n")
        }
    }

    @Published private(set) var session: Session?
    @Published private(set) var archive: [Session] = []
    @Published private(set) var status = ""
    @Published private(set) var error: String?
    @Published private(set) var recording = false
    @Published private(set) var changingCapture = false
    @Published private(set) var transcribing = false
    @Published private(set) var answering = false
    @Published private(set) var answer = ""

    var busy: Bool { recording || changingCapture || transcribing || answering }

    private var window: NSWindow?
    private var recorder: MeetingAudio?
    private var timer: Task<Void, Never>?
    private var collecting: Task<Void, Never>?
    private var transcription: Task<Void, Never>?
    private var failedClips = Set<String>()
    private var lastSpeechDetected = Date()

    func show() {
        if window == nil {
            let controller = NSHostingController(rootView: MeetingView(model: self))
            let window = NSWindow(contentViewController: controller)
            window.title = "Bluey · Call-Notizen"
            window.setContentSize(NSSize(width: 740, height: 650))
            window.minSize = NSSize(width: 560, height: 500)
            window.styleMask.insert(.resizable)
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
            reloadArchive()
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func select(_ session: Session?) {
        guard !busy else { return }
        self.session = session
        failedClips.removeAll()
        error = nil
        status = ""
    }

    func start() async {
        guard !busy else { return }
        if let problem = TranscriptionService.readinessError() {
            error = problem
            return
        }
        changingCapture = true
        error = nil
        status = "Aufnahme wird gestartet …"
        let session = Session()
        let recorder = MeetingAudio(folder: session.audioFolder) { [weak self] error in
            Task { @MainActor in
                guard let self, self.session?.id == session.id, self.recording else { return }
                await self.stop(failure: error.localizedDescription)
            }
        }
        do {
            try await recorder.start()
            self.session = session
            failedClips.removeAll()
            lastSpeechDetected = Date()
            self.recorder = recorder
            recording = true
            status = ""
            save()
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    let seconds = Settings.shared.meetingChunkSeconds
                    do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                    await self?.collect()
                }
            }
        } catch {
            try? await recorder.stop()
            _ = await recorder.flush(stopping: true)
            self.error = "Aufnahme konnte nicht starten. \(error.localizedDescription)"
            status = ""
        }
        changingCapture = false
    }

    func stop(failure: String? = nil) async {
        guard recording, let recorder else { return }
        recording = false
        changingCapture = true
        timer?.cancel()
        timer = nil
        if let failure { error = failure }
        status = "Aufnahme wird gespeichert …"
        do { try await recorder.stop() }
        catch { if self.error == nil { self.error = error.localizedDescription } }
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
                    let segments = try await MeetingNotes.plain(fileURL: url)
                    let text = segments.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { self.lastSpeechDetected = Date() }
                    if let index = self.session?.clips.firstIndex(where: { $0.id == clip.id }) {
                        self.session?.clips[index].transcript = text
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
            let silentLimitMin = Settings.shared.meetingAutoStopSilentMinutes
            if self.recording, silentLimitMin > 0,
               Date().timeIntervalSince(self.lastSpeechDetected) >= Double(silentLimitMin * 60) {
                await self.stop(failure: "Aufnahme automatisch gestoppt nach \(silentLimitMin) Min. Stille.")
            }
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
                model: ChatEngine.defaultModelID, webSearch: false,
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

    private func save() {
        guard let session else { return }
        do {
            try JSONEncoder().encode(session).write(to: session.folder.appendingPathComponent("mac-call.json"), options: .atomic)
            var entries: [[String: Any]] = session.clips.compactMap { clip in
                guard let text = clip.transcript, !text.isEmpty else { return nil }
                return ["kind": "transcript", "speaker": clip.source.title, "text": text, "time": clip.started.timeIntervalSince1970]
            }
            entries += session.messages.map {
                ["kind": $0.role == .user ? "asked" : "reply", "text": $0.text, "time": $0.createdAt.timeIntervalSince1970]
            }
            var notes: [String: Any] = [
                "id": session.id.uuidString, "started": session.started.timeIntervalSince1970,
                "entries": entries.sorted { ($0["time"] as? Double ?? 0) < ($1["time"] as? Double ?? 0) },
                "transcribing": session.clips.filter { $0.transcript == nil }.count
            ]
            notes["ended"] = session.ended?.timeIntervalSince1970
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if model.recording {
                    Label("Aufnahme läuft", systemImage: "record.circle.fill").foregroundStyle(.red)
                    Button("Aufnahme stoppen") { Task { await model.stop() } }
                } else {
                    Button("Aufnahme starten") { Task { await model.start() } }
                        .disabled(model.busy)
                }
                Spacer()
                if model.session != nil { Button("Im Finder öffnen") { model.reveal() } }
            }
            if !model.recording && !model.changingCapture {
                let provider = Settings.shared.transcriptionProvider.shortBadge
                let silence = Settings.shared.transcriptionSilenceFilter ? " · Stille-Filter aktiv" : ""
                Text("Transkription: \(provider)\(silence) · Abschnitte: \(Settings.shared.meetingChunkSeconds)s. Informiere die Teilnehmenden vor dem Start.")
                    .foregroundStyle(.secondary)
            }
            if !model.archive.isEmpty {
                Picker("Gespeicherter Call", selection: Binding(
                    get: { model.archive.contains(where: { $0.id == model.session?.id }) ? model.session?.id : nil },
                    set: { id in
                        question = ""
                        model.select(model.archive.first { $0.id == id })
                    }
                )) {
                    Text("Call auswählen").tag(nil as UUID?)
                    ForEach(model.archive) { session in
                        Text(session.started.formatted(date: .abbreviated, time: .shortened)).tag(Optional(session.id))
                    }
                }
                .disabled(model.busy)
            }
            if !model.status.isEmpty { Text(model.status).foregroundStyle(.secondary) }
            if model.transcribing { Text("Audio wird transkribiert …").foregroundStyle(.secondary) }
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if !model.transcribing && model.session?.clips.contains(where: { $0.transcript == nil }) == true {
                Button("Transkription erneut versuchen") { Task { await model.retry() } }
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
