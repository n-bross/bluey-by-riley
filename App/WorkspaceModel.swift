import Foundation
import SwiftUI
#if canImport(GooglyShared)
import GooglyShared
#endif

/// Where the workspace really lives. On the Mac that's the local store; on the iPhone it's the Mac, over the paired link.
@MainActor
protocol WorkspaceBackend: AnyObject {
    var isConnected: Bool { get }
    func push(_ partial: WorkspaceSnapshot)
    func send(_ request: ChatRequest) async throws -> UUID
    func stop(threadID: UUID)
    func upload(_ data: Data, name: String, mime: String) async throws -> ChatAttachment
    func attachmentData(_ id: UUID) async -> Data?
    func setDefaultModel(_ id: String)
}

struct WorkspaceError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// The app's view of the workspace, shared by the iPhone and Mac apps. Edits apply here at once and
/// are pushed to the backend; snapshots coming back are merged (newest version of each item wins).
@MainActor
final class WorkspaceModel: ObservableObject {
    @Published private(set) var snapshot = WorkspaceSnapshot() {
        didSet { if oldValue.pomodoro != snapshot.pomodoro || oldValue.todos != snapshot.todos { onPomodoro?() } }
    }
    /// Called when the pomodoro (or a todo it might show) changed, e.g. for the Live Activity.
    var onPomodoro: (() -> Void)?
    @Published private(set) var connected = false
    /// Bluey's screen-watching focus sessions, for statistics.
    @Published var focusHistory: [FocusSession] = []
    @Published var currentFocus: FocusSession?
    /// The live answer text while it streams, by message id.
    @Published private(set) var streaming: [UUID: String] = [:]
    weak var backend: WorkspaceBackend?
    /// Called after every change, e.g. to keep an offline copy on the phone.
    var onChange: ((WorkspaceSnapshot) -> Void)?
    /// Called when a pomodoro phase runs out on this device.
    var onPhaseFinished: ((PomodoroState.Phase) -> Void)?
    /// Starts/pauses/ends a Bluey focus session (screen checks on the Mac). Returns a message.
    var focusCommand: ((String, String, Double) async -> String)?
    /// Starts a voice call with Bluey for a chat (iPhone only). Nil where calls aren't available.
    var startCall: ((UUID?) -> Void)?
    /// The phone advances finished pomodoro phases itself so it works offline; the Mac store does it there.
    var advancesPomodoro = false
    private var timer: Timer?

    init(snapshot: WorkspaceSnapshot = WorkspaceSnapshot()) {
        self.snapshot = snapshot
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func setConnected(_ value: Bool) { if connected != value { connected = value } }

    /// A snapshot from the backend.
    func receive(_ incoming: WorkspaceSnapshot) {
        var next = snapshot
        guard next.merge(incoming) else { return }
        let before = snapshot.pomodoro
        snapshot = next
        // Finished answers no longer need their live text.
        for thread in snapshot.threads { for m in thread.messages where m.status != .streaming { streaming[m.id] = nil } }
        if let before, let after = snapshot.pomodoro, before.phase != after.phase, before.isRunning,
           let end = expectedEnd(before), abs(after.updatedAt.timeIntervalSince(end)) < 0.01 {
            onPhaseFinished?(before.phase)
        }
        onChange?(snapshot)
    }

    func receive(_ delta: ChatDelta) {
        streaming[delta.messageID] = delta.text
    }

    private func expectedEnd(_ state: PomodoroState) -> Date? {
        state.startedAt.map { $0.addingTimeInterval(state.pausedRemaining ?? state.duration) }
    }

    private func commit(_ partial: WorkspaceSnapshot) {
        var next = snapshot
        next.merge(partial)
        snapshot = next
        onChange?(snapshot)
        backend?.push(partial)
    }

    private func tick() {
        guard advancesPomodoro, var pomodoro = snapshot.pomodoro else { return }
        let phase = pomodoro.phase
        let record = pomodoro.advance(now: Date())
        guard pomodoro != snapshot.pomodoro else { return }
        var partial = WorkspaceSnapshot()
        partial.pomodoro = pomodoro
        if let record { partial.pomodoroLog = [record] }
        commit(partial)
        onPhaseFinished?(phase)
    }

    // MARK: Todos

    var models: [ChatModelInfo] { snapshot.models }
    var defaultModel: String { snapshot.defaultModel ?? snapshot.models.first?.id ?? "gpt-5.5" }

    @discardableResult
    func addTodo(_ title: String, important: Bool = false, due: Date? = nil) -> UUID? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let todo = TodoItem(title: title, important: important, due: due)
        var partial = WorkspaceSnapshot()
        partial.todos = [todo]
        commit(partial)
        return todo.id
    }

    func update(_ todo: TodoItem) {
        var todo = todo
        todo.updatedAt = Date()
        var partial = WorkspaceSnapshot()
        partial.todos = [todo]
        commit(partial)
    }

    func toggle(_ todo: TodoItem) {
        var todo = todo
        todo.done.toggle()
        todo.completedAt = todo.done ? Date() : nil
        update(todo)
    }

    func delete(_ todo: TodoItem) {
        var todo = todo
        todo.deleted = true
        update(todo)
    }

    // MARK: Notes

    @discardableResult
    func addNote(title: String = "", body: String = "") -> UUID {
        let note = NoteItem(title: title, body: body)
        var partial = WorkspaceSnapshot()
        partial.notes = [note]
        commit(partial)
        return note.id
    }

    func update(_ note: NoteItem) {
        var note = note
        note.updatedAt = Date()
        var partial = WorkspaceSnapshot()
        partial.notes = [note]
        commit(partial)
    }

    func delete(_ note: NoteItem) {
        var note = note
        note.deleted = true
        update(note)
    }

    func note(_ id: UUID) -> NoteItem? { snapshot.notes.first { $0.id == id && !$0.deleted } }

    // MARK: Pomodoro

    var pomodoro: PomodoroState { snapshot.pomodoro ?? PomodoroState() }

    func changePomodoro(_ change: (inout PomodoroState) -> Void) {
        var state = pomodoro
        let before = state
        change(&state)
        guard state != before else { return }
        state.updatedAt = max(Date(), before.updatedAt.addingTimeInterval(0.001))
        var partial = WorkspaceSnapshot()
        partial.pomodoro = state
        commit(partial)
    }

    /// Every focus round belongs to a todo.
    func startFocus(for todo: TodoItem) {
        changePomodoro { $0.startFocus(label: todo.title, todoID: todo.id, now: Date()) }
    }

    func todo(_ id: UUID?) -> TodoItem? {
        guard let id else { return nil }
        return snapshot.todos.first { $0.id == id && !$0.deleted }
    }

    // MARK: Chat

    func thread(_ id: UUID?) -> ChatThread? {
        guard let id else { return nil }
        return snapshot.threads.first { $0.id == id && !$0.deleted }
    }

    func text(of message: ChatMessage) -> String {
        message.status == .streaming ? (streaming[message.id] ?? message.text) : message.text
    }

    func send(threadID: UUID?, text: String, attachments: [ChatAttachment], model: String, webSearch: Bool) async throws -> UUID {
        guard let backend, backend.isConnected else { throw WorkspaceError("Bluey braucht den Mac zum Chatten. Verbinde dich mit deinem gekoppelten Mac.") }
        return try await backend.send(ChatRequest(threadID: threadID, text: text, attachments: attachments, model: model, webSearch: webSearch))
    }

    func stop(threadID: UUID) { backend?.stop(threadID: threadID) }

    func upload(_ data: Data, name: String, mime: String) async throws -> ChatAttachment {
        guard data.count <= ChatAttachment.maxBytes else { throw WorkspaceError("„\(name)“ ist größer als 10 MB.") }
        guard let backend, backend.isConnected else { throw WorkspaceError("Anhänge brauchen die Verbindung zum Mac.") }
        return try await backend.upload(data, name: name, mime: mime)
    }

    func attachmentData(_ id: UUID) async -> Data? { await backend?.attachmentData(id) }

    func rename(_ thread: ChatThread, to title: String) {
        var thread = thread
        thread.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Chat" : title
        thread.updatedAt = Date()
        var partial = WorkspaceSnapshot()
        partial.threads = [thread]
        commit(partial)
    }

    func setModel(_ model: String, for thread: ChatThread?) {
        backend?.setDefaultModel(model)
        guard var thread, thread.model != model, !thread.isStreaming else { return }
        thread.model = model
        thread.updatedAt = Date()
        var partial = WorkspaceSnapshot()
        partial.threads = [thread]
        commit(partial)
    }

    func delete(_ thread: ChatThread) {
        var thread = thread
        thread.deleted = true
        thread.updatedAt = Date()
        var partial = WorkspaceSnapshot()
        partial.threads = [thread]
        commit(partial)
    }

    /// Puts what was said in a call into the chat (creating one if needed). Returns the chat id.
    @discardableResult
    func appendCall(threadID: UUID?, lines: [(fromUser: Bool, text: String)], started: Date) -> UUID? {
        let lines = lines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !lines.isEmpty else { return threadID }
        let now = Date()
        var thread = self.thread(threadID) ?? ChatThread(id: threadID ?? UUID(),
                                                          title: "Anruf: " + ChatThread.title(from: lines.first { $0.fromUser }?.text ?? "Gespräch"),
                                                          model: defaultModel, now: started)
        for (i, line) in lines.enumerated() {
            var message = ChatMessage(role: line.fromUser ? .user : .assistant, text: line.text,
                                      model: line.fromUser ? nil : "Anruf", now: started.addingTimeInterval(Double(i) * 0.001))
            message.status = .done
            thread.messages.append(message)
        }
        thread.updatedAt = now
        var partial = WorkspaceSnapshot()
        partial.threads = [thread]
        commit(partial)
        return thread.id
    }

    // MARK: Stats

    var stats: WorkspaceStats { WorkspaceStats(snapshot, focusHistory: focusHistory) }
}
