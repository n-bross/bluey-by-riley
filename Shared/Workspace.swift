import Foundation
import CryptoKit

// The Bluey workspace: todos, notes, chats and the pomodoro, shared by the Mac, the iPhone and the web app.
// The Mac keeps the authoritative copy. Every item carries `updatedAt`; merging keeps the newest version
// of each item (last writer wins), and deletions are tombstones so they sync too.

public struct TodoItem: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var notes: String
    public var done: Bool
    public var important: Bool
    public var due: Date?
    public var estimateMinutes: Int?
    public var createdAt: Date
    public var completedAt: Date?
    public var updatedAt: Date
    public var deleted: Bool

    public init(id: UUID = UUID(), title: String, notes: String = "", done: Bool = false, important: Bool = false,
                due: Date? = nil, estimateMinutes: Int? = nil, now: Date = Date()) {
        self.id = id; self.title = title; self.notes = notes; self.done = done; self.important = important
        self.due = due; self.estimateMinutes = estimateMinutes
        self.createdAt = now; self.completedAt = done ? now : nil; self.updatedAt = now; self.deleted = false
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        important = try c.decodeIfPresent(Bool.self, forKey: .important) ?? false
        due = try c.decodeIfPresent(Date.self, forKey: .due)
        estimateMinutes = try c.decodeIfPresent(Int.self, forKey: .estimateMinutes)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
    }
}

public struct NoteItem: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var body: String
    public var pinned: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var deleted: Bool
    /// Optional vector handwriting / sketch attached directly to this note (Apple Notes style).
    public var drawing: InkDrawing?
    /// Linked note ID in Bluey Hub (`~/bluey-hub/notes/<id>.md`), when synced.
    public var hubNoteID: String?
    /// Origin tag such as "huion-live", "huion-offline", or "screen-annotation".
    public var source: String?

    public init(id: UUID = UUID(), title: String = "", body: String = "", pinned: Bool = false,
                drawing: InkDrawing? = nil, hubNoteID: String? = nil, source: String? = nil, now: Date = Date()) {
        self.id = id; self.title = title; self.body = body; self.pinned = pinned
        self.drawing = drawing; self.hubNoteID = hubNoteID; self.source = source
        self.createdAt = now; self.updatedAt = now; self.deleted = false
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        drawing = try c.decodeIfPresent(InkDrawing.self, forKey: .drawing)
        hubNoteID = try c.decodeIfPresent(String.self, forKey: .hubNoteID)
        source = try c.decodeIfPresent(String.self, forKey: .source)
    }

    public var hasDrawing: Bool {
        if let d = drawing, !d.isEmpty { return true }
        return false
    }

    /// The title, or the first line of the body when there is no title.
    public var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        let first = body.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        if !first.isEmpty { return String(first.prefix(80)) }
        return hasDrawing ? "Handschrift-Notiz" : "Neue Notiz"
    }
}

/// A file attached to a chat message. The bytes live on the Mac; this is what every device sees.
public struct ChatAttachment: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var mime: String
    public var size: Int
    /// Small JPEG preview (base64) for images, so phones and the web can show it without the file.
    public var thumbnail: String?

    public init(id: UUID = UUID(), name: String, mime: String, size: Int, thumbnail: String? = nil) {
        self.id = id; self.name = name; self.mime = mime; self.size = size; self.thumbnail = thumbnail
    }

    public var isImage: Bool { mime.hasPrefix("image/") }
    public var isPDF: Bool { mime == "application/pdf" }
    public var isText: Bool {
        mime.hasPrefix("text/") || ["application/json", "application/xml", "application/x-yaml", "application/javascript"].contains(mime)
    }

    /// Largest file the chat accepts (it travels base64-encoded over the phone link).
    public static let maxBytes = 10 * 1024 * 1024

    /// A MIME type from a file name, for platforms that don't hand one over.
    public static func mime(forName name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "pdf": return "application/pdf"
        case "json": return "application/json"
        case "xml": return "application/xml"
        case "yml", "yaml": return "application/x-yaml"
        case "js": return "application/javascript"
        case "md", "markdown": return "text/markdown"
        case "csv": return "text/csv"
        case "html", "htm": return "text/html"
        case "txt", "log", "swift", "py", "ts", "tsx", "jsx", "css", "sh", "rb", "go", "rs", "java", "kt", "c", "h", "m", "cpp", "sql", "toml", "ini":
            return "text/plain"
        default: return "application/octet-stream"
        }
    }
}

public struct ChatMessage: Codable, Identifiable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable { case user, assistant }
    public enum Status: String, Codable, Sendable { case done, streaming, failed, stopped }
    public var id: UUID
    public var role: Role
    public var text: String
    public var attachments: [ChatAttachment]
    public var model: String?
    public var createdAt: Date
    public var status: Status
    public var error: String?

    public init(id: UUID = UUID(), role: Role, text: String, attachments: [ChatAttachment] = [], model: String? = nil,
                status: Status = .done, now: Date = Date()) {
        self.id = id; self.role = role; self.text = text; self.attachments = attachments; self.model = model
        self.createdAt = now; self.status = status; self.error = nil
    }
}

public struct ChatThread: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var model: String
    public var hermesOptions: HermesChatOptions?
    public var webSearch: Bool
    public var messages: [ChatMessage]
    public var createdAt: Date
    public var updatedAt: Date
    public var deleted: Bool

    public init(id: UUID = UUID(), title: String = "Neuer Chat", model: String, webSearch: Bool = false, now: Date = Date()) {
        self.id = id; self.title = title; self.model = model; self.webSearch = webSearch; self.messages = []
        self.createdAt = now; self.updatedAt = now; self.deleted = false
    }

    public var isStreaming: Bool { messages.last?.status == .streaming }

    /// A short title from the first thing the user asked.
    public static func title(from text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !line.isEmpty else { return "Neuer Chat" }
        return line.count > 48 ? String(line.prefix(47)) + "…" : line
    }
}

/// A model the user can pick for chatting.
public struct ChatModelInfo: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public init(id: String, name: String? = nil) { self.id = id; self.name = name ?? id }
}

// MARK: - Pomodoro

public struct PomodoroSettings: Codable, Equatable, Sendable {
    public var focusMinutes: Double = 25
    public var shortBreakMinutes: Double = 5
    public var longBreakMinutes: Double = 15
    public var roundsPerLongBreak: Int = 4
    /// Starts a Bluey focus session (screen checks on the Mac) with every focus phase.
    public var watchScreen: Bool = false
    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        focusMinutes = try c.decodeIfPresent(Double.self, forKey: .focusMinutes) ?? 25
        shortBreakMinutes = try c.decodeIfPresent(Double.self, forKey: .shortBreakMinutes) ?? 5
        longBreakMinutes = try c.decodeIfPresent(Double.self, forKey: .longBreakMinutes) ?? 15
        roundsPerLongBreak = try c.decodeIfPresent(Int.self, forKey: .roundsPerLongBreak) ?? 4
        watchScreen = try c.decodeIfPresent(Bool.self, forKey: .watchScreen) ?? false
    }
}

/// A finished focus phase.
public struct PomodoroRecord: Codable, Identifiable, Equatable, Sendable {
    /// The id of the phase it came from, so two devices finishing the same phase record it once.
    public var id: UUID
    public var label: String
    public var todoID: UUID?
    public var startedAt: Date
    public var minutes: Double
    public var completedAt: Date
    public var updatedAt: Date
    public var deleted: Bool
    public init(id: UUID, label: String, todoID: UUID?, startedAt: Date, minutes: Double, completedAt: Date) {
        self.id = id; self.label = label; self.todoID = todoID; self.startedAt = startedAt
        self.minutes = minutes; self.completedAt = completedAt; self.updatedAt = completedAt; self.deleted = false
    }
}

public struct PomodoroState: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case idle, focus, shortBreak, longBreak
        public var isBreak: Bool { self == .shortBreak || self == .longBreak }
        public var title: String {
            switch self {
            case .idle: return "Bereit"
            case .focus: return "Fokus"
            case .shortBreak: return "Kurze Pause"
            case .longBreak: return "Lange Pause"
            }
        }
    }
    public var phase: Phase = .idle
    public var phaseID = UUID()
    /// When the current run of the phase started (nil while paused or idle).
    public var startedAt: Date?
    /// Full length of the phase in seconds.
    public var duration: Double = 25 * 60
    /// Seconds left when paused.
    public var pausedRemaining: Double?
    /// When the phase first began (for the record), independent of pauses.
    public var phaseBegan: Date?
    /// Focus phases finished in the current cycle.
    public var round: Int = 0
    public var label: String = ""
    public var todoID: UUID?
    public var settings = PomodoroSettings()
    public var updatedAt: Date = .distantPast

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        phase = try c.decodeIfPresent(Phase.self, forKey: .phase) ?? .idle
        phaseID = try c.decodeIfPresent(UUID.self, forKey: .phaseID) ?? UUID()
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 25 * 60
        pausedRemaining = try c.decodeIfPresent(Double.self, forKey: .pausedRemaining)
        phaseBegan = try c.decodeIfPresent(Date.self, forKey: .phaseBegan)
        round = try c.decodeIfPresent(Int.self, forKey: .round) ?? 0
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        todoID = try c.decodeIfPresent(UUID.self, forKey: .todoID)
        settings = try c.decodeIfPresent(PomodoroSettings.self, forKey: .settings) ?? PomodoroSettings()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
    }

    public var isRunning: Bool { phase != .idle && startedAt != nil }
    public var isPaused: Bool { phase != .idle && startedAt == nil }

    public func remaining(at now: Date) -> Double {
        guard phase != .idle else { return settings.focusMinutes * 60 }
        if let startedAt { return max(0, (pausedRemaining ?? duration) - now.timeIntervalSince(startedAt)) }
        return pausedRemaining ?? duration
    }

    public func progress(at now: Date) -> Double {
        guard phase != .idle, duration > 0 else { return 0 }
        return min(1, max(0, 1 - remaining(at: now) / duration))
    }

    public mutating func startFocus(label: String, todoID: UUID?, now: Date) {
        phase = .focus; phaseID = UUID(); duration = max(60, settings.focusMinutes * 60)
        pausedRemaining = nil; startedAt = now; phaseBegan = now
        self.label = label; self.todoID = todoID; updatedAt = now
    }

    public mutating func startBreak(now: Date) {
        let long = round > 0 && round % max(1, settings.roundsPerLongBreak) == 0
        phase = long ? .longBreak : .shortBreak; phaseID = UUID()
        duration = max(60, (long ? settings.longBreakMinutes : settings.shortBreakMinutes) * 60)
        pausedRemaining = nil; startedAt = now; phaseBegan = now; updatedAt = now
    }

    public mutating func pause(now: Date) {
        guard isRunning else { return }
        pausedRemaining = remaining(at: now); startedAt = nil; updatedAt = now
    }

    public mutating func resume(now: Date) {
        guard isPaused else { return }
        startedAt = now; updatedAt = now
    }

    public mutating func stop(now: Date) {
        phase = .idle; startedAt = nil; pausedRemaining = nil; phaseBegan = nil; updatedAt = now
    }

    /// Skips the rest of the phase. A skipped focus phase is not counted.
    public mutating func skip(now: Date) {
        switch phase {
        case .focus: startBreak(now: now)
        case .shortBreak, .longBreak: stop(now: now)
        case .idle: break
        }
    }

    /// Moves on when the running phase has run out. Deterministic, so the Mac and the phone
    /// reach the same state (and the same record id) even if both notice it at once.
    public mutating func advance(now: Date) -> PomodoroRecord? {
        guard let startedAt, phase != .idle else { return nil }
        let endsAt = startedAt.addingTimeInterval(pausedRemaining ?? duration)
        guard now >= endsAt else { return nil }
        let finished = phaseID
        var record: PomodoroRecord?
        if phase == .focus {
            record = PomodoroRecord(id: finished, label: label, todoID: todoID, startedAt: phaseBegan ?? startedAt,
                                    minutes: duration / 60, completedAt: endsAt)
            round += 1
            startBreak(now: endsAt)
        } else {
            if phase == .longBreak { round = 0 }
            stop(now: endsAt)
        }
        phaseID = Self.derivedID(from: finished)
        updatedAt = endsAt
        return record
    }

    static func derivedID(from id: UUID) -> UUID {
        var bytes = Array(SHA256.hash(data: Data((id.uuidString + ":next").utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40; bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

// MARK: - Snapshot and merging

public struct WorkspaceSnapshot: Codable, Equatable, Sendable {
    public var todos: [TodoItem] = []
    public var notes: [NoteItem] = []
    public var threads: [ChatThread] = []
    public var pomodoro: PomodoroState?
    public var pomodoroLog: [PomodoroRecord] = []
    /// Chat models the Mac can use. Only the Mac fills this in.
    public var models: [ChatModelInfo] = []
    public var defaultModel: String?

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        todos = try c.decodeIfPresent([TodoItem].self, forKey: .todos) ?? []
        notes = try c.decodeIfPresent([NoteItem].self, forKey: .notes) ?? []
        threads = try c.decodeIfPresent([ChatThread].self, forKey: .threads) ?? []
        pomodoro = try c.decodeIfPresent(PomodoroState.self, forKey: .pomodoro)
        pomodoroLog = try c.decodeIfPresent([PomodoroRecord].self, forKey: .pomodoroLog) ?? []
        models = try c.decodeIfPresent([ChatModelInfo].self, forKey: .models) ?? []
        defaultModel = try c.decodeIfPresent(String.self, forKey: .defaultModel)
    }

    public var isEmpty: Bool { todos.isEmpty && notes.isEmpty && threads.isEmpty && pomodoro == nil && pomodoroLog.isEmpty }

    /// Folds `other` in, keeping the newest version of every item. Returns true when anything changed.
    @discardableResult
    public mutating func merge(_ other: WorkspaceSnapshot) -> Bool {
        let before = self
        todos = Self.merged(todos, other.todos, \.updatedAt)
        notes = Self.merged(notes, other.notes, \.updatedAt)
        threads = Self.merged(threads, other.threads, \.updatedAt)
        pomodoroLog = Self.merged(pomodoroLog, other.pomodoroLog, \.updatedAt)
        if let theirs = other.pomodoro, theirs.updatedAt > (pomodoro?.updatedAt ?? .distantPast) { pomodoro = theirs }
        if !other.models.isEmpty { models = other.models }
        if let model = other.defaultModel { defaultModel = model }
        return self != before
    }

    public static func merged<T: Identifiable>(_ mine: [T], _ theirs: [T], _ stamp: KeyPath<T, Date>) -> [T] where T.ID == UUID {
        guard !theirs.isEmpty else { return mine }
        var result = mine
        var index: [UUID: Int] = [:]
        for (i, item) in result.enumerated() { index[item.id] = i }
        for item in theirs {
            if let i = index[item.id] {
                if item[keyPath: stamp] > result[i][keyPath: stamp] { result[i] = item }
            } else {
                index[item.id] = result.count
                result.append(item)
            }
        }
        return result
    }

    /// Drops tombstones older than `age` seconds (every device has had time to see them).
    public mutating func pruneTombstones(olderThan age: Double = 30 * 86400, now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-age)
        todos.removeAll { $0.deleted && $0.updatedAt < cutoff }
        notes.removeAll { $0.deleted && $0.updatedAt < cutoff }
        threads.removeAll { $0.deleted && $0.updatedAt < cutoff }
        pomodoroLog.removeAll { $0.deleted && $0.updatedAt < cutoff }
    }

    public var visibleTodos: [TodoItem] { todos.filter { !$0.deleted } }
    public var visibleNotes: [NoteItem] {
        notes.filter { !$0.deleted }.sorted { ($0.pinned ? 1 : 0, $0.updatedAt) > ($1.pinned ? 1 : 0, $1.updatedAt) }
    }
    public var visibleThreads: [ChatThread] { threads.filter { !$0.deleted }.sorted { $0.updatedAt > $1.updatedAt } }
}

/// Live text of an answer while it streams in.
public struct ChatDelta: Codable, Equatable, Sendable {
    public var threadID: UUID
    public var messageID: UUID
    public var text: String
    public var liveTool: HermesLiveTool?
    public init(threadID: UUID, messageID: UUID, text: String, liveTool: HermesLiveTool? = nil) {
        self.threadID = threadID; self.messageID = messageID; self.text = text; self.liveTool = liveTool
    }
}

/// Asking the Mac to answer in a chat. Attachments must already be uploaded.
public struct ChatRequest: Codable, Equatable, Sendable {
    public var threadID: UUID?
    public var text: String
    public var attachments: [ChatAttachment]
    public var model: String?
    public var webSearch: Bool?
    public var hermesOptions: HermesChatOptions?
    public init(threadID: UUID?, text: String, attachments: [ChatAttachment] = [], model: String? = nil, webSearch: Bool? = nil, hermesOptions: HermesChatOptions? = nil) {
        self.hermesOptions = hermesOptions
        self.threadID = threadID; self.text = text; self.attachments = attachments; self.model = model; self.webSearch = webSearch
    }
}

// MARK: - Coding

/// JSON with ISO 8601 dates (with milliseconds), readable by JavaScript and both apps.
public enum WorkspaceCoding {
    private static func formatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(formatter().string(from: date))
        }
        return e
    }
    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            if let number = try? c.decode(Double.self) { return Date(timeIntervalSince1970: number > 1e11 ? number / 1000 : number) }
            let text = try c.decode(String.self)
            if let date = formatter().date(from: text) { return date }
            let plain = ISO8601DateFormatter()
            if let date = plain.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unreadable date \(text)")
        }
        return d
    }
    public static func string<T: Encodable>(_ value: T) -> String? {
        (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) }
    }
    public static func decode<T: Decodable>(_ type: T.Type, _ text: String?) -> T? {
        guard let text else { return nil }
        return try? decoder.decode(type, from: Data(text.utf8))
    }
}
