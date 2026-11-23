import Foundation
import ImageIO
import UniformTypeIdentifiers
import GooglyShared

/// The Mac's authoritative workspace: todos, notes, chats and the pomodoro. Phones, the web app and the
/// Mac window all change it through `apply`, and everyone hears about changes through listeners.
@MainActor
final class WorkspaceStore {
    private(set) var snapshot = WorkspaceSnapshot()
    private let file: URL
    let attachmentsFolder: URL
    private var listeners: [UUID: (snapshot: (WorkspaceSnapshot) -> Void, delta: (ChatDelta) -> Void)] = [:]
    private var chats: [UUID: Task<Void, Never>] = [:]
    private var saveWork: DispatchWorkItem?
    private var publishWork: DispatchWorkItem?
    private var timer: Timer?
    /// Called with the old and new pomodoro whenever it changes (to drive Bluey's screen checks).
    var onPomodoroChange: ((PomodoroState?, PomodoroState?) -> Void)?
    /// Extra context for chats, like the current focus session.
    var chatContext: () -> String = { "" }

    init(folder: URL? = nil) {
        let dir = folder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Googly")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        file = dir.appendingPathComponent("workspace.json")
        attachmentsFolder = dir.appendingPathComponent("attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: attachmentsFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let data = try? Data(contentsOf: file), let saved = try? WorkspaceCoding.decoder.decode(WorkspaceSnapshot.self, from: data) {
            snapshot = saved
        }
        // Answers that were streaming when Bluey quit can't continue.
        for t in snapshot.threads.indices {
            for m in snapshot.threads[t].messages.indices where snapshot.threads[t].messages[m].status == .streaming {
                snapshot.threads[t].messages[m].status = .stopped
            }
        }
        snapshot.pruneTombstones()
        if snapshot.defaultModel == nil { snapshot.defaultModel = ChatEngine.fallbackModel }
        if snapshot.models.isEmpty { snapshot.models = [ChatModelInfo(id: ChatEngine.fallbackModel, name: ChatEngine.displayName(ChatEngine.fallbackModel))] }
    }

    func start() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refreshModels()
    }

    // MARK: Listeners

    @discardableResult
    func listen(snapshot: @escaping (WorkspaceSnapshot) -> Void, delta: @escaping (ChatDelta) -> Void) -> UUID {
        let id = UUID()
        listeners[id] = (snapshot, delta)
        return id
    }

    func stopListening(_ id: UUID) { listeners[id] = nil }

    private func publishSoon() {
        publishWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            for l in self.listeners.values { l.snapshot(self.snapshot) }
        }
        publishWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func saveSoon() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func save() {
        guard let data = try? WorkspaceCoding.encoder.encode(snapshot) else { return }
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func changed(pomodoroBefore: PomodoroState?) {
        saveSoon(); publishSoon()
        if pomodoroBefore != snapshot.pomodoro { onPomodoroChange?(pomodoroBefore, snapshot.pomodoro) }
    }

    // MARK: Changes

    /// Merges changes from any device. Models are owned by the Mac and never taken from clients.
    func apply(_ partial: WorkspaceSnapshot) {
        var incoming = partial
        incoming.models = []
        incoming.defaultModel = nil
        let before = snapshot.pomodoro
        // Streaming answers belong to the Mac; a client's stale copy must not overwrite them.
        incoming.threads.removeAll { chats[$0.id] != nil && !$0.deleted }
        for thread in incoming.threads where thread.deleted { stop(thread.id) }
        if snapshot.merge(incoming) { changed(pomodoroBefore: before) }
    }

    func setDefaultModel(_ model: String) {
        snapshot.defaultModel = model
        changed(pomodoroBefore: snapshot.pomodoro)
    }

    private func tick() {
        guard var pomodoro = snapshot.pomodoro else { return }
        let before = pomodoro
        if let record = pomodoro.advance(now: Date()) {
            snapshot.pomodoroLog = WorkspaceSnapshot.merged(snapshot.pomodoroLog, [record], \.updatedAt)
        }
        if pomodoro != before {
            snapshot.pomodoro = pomodoro
            changed(pomodoroBefore: before)
        }
    }

    func refreshModels() {
        Task { @MainActor in
            let models = await ChatEngine.models()
            guard !models.isEmpty else { return }
            snapshot.models = models
            if let current = snapshot.defaultModel, !models.contains(where: { $0.id == current }) {
                snapshot.defaultModel = models.first(where: { $0.id == ChatEngine.fallbackModel })?.id ?? models.first?.id
            }
            publishSoon()
        }
    }

    // MARK: Chat

    /// Starts an answer. Returns the thread id, or throws a message to show.
    @discardableResult
    func send(_ request: ChatRequest) throws -> UUID {
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !request.attachments.isEmpty else { throw ChatEngine.Failure.message("Schreib zuerst eine Nachricht.") }
        let now = Date()
        let model = request.model ?? snapshot.defaultModel ?? ChatEngine.fallbackModel
        var thread: ChatThread
        if let id = request.threadID, let existing = snapshot.threads.first(where: { $0.id == id && !$0.deleted }) {
            guard chats[id] == nil else { throw ChatEngine.Failure.message("Bluey antwortet in diesem Chat noch.") }
            thread = existing
        } else {
            thread = ChatThread(id: request.threadID ?? UUID(), title: ChatThread.title(from: text.isEmpty ? request.attachments.first?.name ?? "" : text),
                                model: model, now: now)
        }
        // Only attachments that really exist on this Mac.
        let attachments = request.attachments.filter { FileManager.default.fileExists(atPath: attachmentURL($0.id).path) }
        thread.model = model
        if let web = request.webSearch { thread.webSearch = web }
        thread.messages.append(ChatMessage(role: .user, text: text, attachments: attachments, now: now))
        let answer = ChatMessage(role: .assistant, text: "", model: model, status: .streaming, now: now.addingTimeInterval(0.001))
        thread.messages.append(answer)
        thread.updatedAt = now
        put(thread)
        if snapshot.defaultModel != model { snapshot.defaultModel = model }

        let input = ChatEngine.Input(messages: Array(thread.messages.dropLast()), model: model, webSearch: thread.webSearch,
                                     context: context(), attachmentData: { [folder = attachmentsFolder] id in
                                         try? Data(contentsOf: folder.appendingPathComponent(id.uuidString)) })
        let threadID = thread.id, messageID = answer.id
        chats[threadID] = Task { @MainActor [weak self] in
            var lastSent = Date.distantPast
            do {
                let final = try await ChatEngine.stream(input) { text in
                    guard let self, Date().timeIntervalSince(lastSent) > 0.06 else { return }
                    lastSent = Date()
                    self.updateAnswer(threadID, messageID) { $0.text = text }
                    let delta = ChatDelta(threadID: threadID, messageID: messageID, text: text)
                    for l in self.listeners.values { l.delta(delta) }
                }
                self?.finish(threadID, messageID) { $0.text = final; $0.status = .done }
            } catch is CancellationError {
                self?.finish(threadID, messageID) { $0.status = .stopped }
            } catch let error as URLError where error.code == .cancelled {
                self?.finish(threadID, messageID) { $0.status = .stopped }
            } catch {
                self?.finish(threadID, messageID) { $0.status = .failed; $0.error = error.localizedDescription }
            }
        }
        return threadID
    }

    func stop(_ threadID: UUID) {
        chats[threadID]?.cancel()
    }

    private func context() -> String {
        var lines: [String] = []
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = "EEEE, d. MMMM yyyy, HH:mm"
        lines.append("Jetzt: \(formatter.string(from: Date()))")
        let open = snapshot.visibleTodos.filter { !$0.done }.prefix(15)
        if !open.isEmpty {
            lines.append("Offene Todos: " + open.map { $0.title + ($0.important ? " (wichtig)" : "") }.joined(separator: "; "))
        }
        if let p = snapshot.pomodoro, p.phase != .idle {
            lines.append("Pomodoro: \(p.phase.title)\(p.label.isEmpty ? "" : " – \(p.label)"), noch \(Int(p.remaining(at: Date()) / 60)) Min.")
        }
        let extra = chatContext()
        if !extra.isEmpty { lines.append(extra) }
        return lines.joined(separator: "\n")
    }

    private func put(_ thread: ChatThread) {
        if let i = snapshot.threads.firstIndex(where: { $0.id == thread.id }) { snapshot.threads[i] = thread }
        else { snapshot.threads.append(thread) }
        changed(pomodoroBefore: snapshot.pomodoro)
    }

    /// Updates the streaming text in memory only (deltas carry it to clients).
    private func updateAnswer(_ threadID: UUID, _ messageID: UUID, _ change: (inout ChatMessage) -> Void) {
        guard let t = snapshot.threads.firstIndex(where: { $0.id == threadID }),
              let m = snapshot.threads[t].messages.firstIndex(where: { $0.id == messageID }) else { return }
        change(&snapshot.threads[t].messages[m])
    }

    private func finish(_ threadID: UUID, _ messageID: UUID, _ change: (inout ChatMessage) -> Void) {
        chats[threadID] = nil
        guard let t = snapshot.threads.firstIndex(where: { $0.id == threadID }) else { return }
        if let m = snapshot.threads[t].messages.firstIndex(where: { $0.id == messageID }) { change(&snapshot.threads[t].messages[m]) }
        snapshot.threads[t].updatedAt = max(Date(), snapshot.threads[t].updatedAt.addingTimeInterval(0.001))
        changed(pomodoroBefore: snapshot.pomodoro)
    }

    // MARK: Attachments

    func attachmentURL(_ id: UUID) -> URL { attachmentsFolder.appendingPathComponent(id.uuidString) }

    func attachmentData(_ id: UUID) -> Data? { try? Data(contentsOf: attachmentURL(id)) }

    func attachment(_ id: UUID) -> ChatAttachment? {
        snapshot.threads.lazy.flatMap(\.messages).flatMap(\.attachments).first { $0.id == id }
    }

    /// Saves an uploaded file. Images are made model-friendly (JPEG/PNG, at most 2048 px) and get a thumbnail.
    func storeAttachment(_ data: Data, name: String, mime: String?) throws -> ChatAttachment {
        guard !data.isEmpty else { throw ChatEngine.Failure.message("Die Datei ist leer.") }
        guard data.count <= ChatAttachment.maxBytes else { throw ChatEngine.Failure.message("Dateien dürfen höchstens 10 MB groß sein.") }
        let cleanName = String((name as NSString).lastPathComponent.prefix(120)).isEmpty ? "Datei" : String((name as NSString).lastPathComponent.prefix(120))
        var mime = (mime?.isEmpty == false && mime != "application/octet-stream") ? mime! : ChatAttachment.mime(forName: cleanName)
        var bytes = data
        var thumbnail: String?
        if mime.hasPrefix("image/") {
            guard let prepared = ImageTools.prepare(data, keepPNG: mime == "image/png") else {
                throw ChatEngine.Failure.message("Das Bild konnte nicht gelesen werden.")
            }
            bytes = prepared.data; mime = prepared.mime
            thumbnail = ImageTools.thumbnail(data, maxPixel: 320)?.base64EncodedString()
        }
        let attachment = ChatAttachment(name: cleanName, mime: mime, size: bytes.count, thumbnail: thumbnail)
        try bytes.write(to: attachmentURL(attachment.id), options: .atomic)
        return attachment
    }
}

enum ImageTools {
    /// Re-encodes an image for the model: PNG stays PNG when small enough, everything else becomes JPEG.
    static func prepare(_ data: Data, keepPNG: Bool, maxPixel: Int = 2048) -> (data: Data, mime: String)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        if keepPNG, max(w, h) <= maxPixel { return (data, "image/png") }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: min(maxPixel, max(w, h, 1))]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return encode(image, type: keepPNG ? .png : .jpeg).map { ($0, keepPNG ? "image/png" : "image/jpeg") }
    }

    static func thumbnail(_ data: Data, maxPixel: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return encode(image, type: .jpeg, quality: 0.7)
    }

    private static func encode(_ image: CGImage, type: UTType, quality: Double = 0.85) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
