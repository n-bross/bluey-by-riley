import Foundation
import Security

// MARK: - Models

struct HubNote: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var body: String?
    var preview: String?
    var pinned: Bool
    var created: Double
    var updated: Double
    var updatedDate: Date { Date(timeIntervalSince1970: updated) }
}

struct HubTodo: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var notes: String
    var due: String?
    var list: String
    var done: Bool
    var created: Double
    var updated: Double
    var completed: Double?

    var dueDate: Date? {
        guard let due else { return nil }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: due)
    }
}

/// A Hermes conversation (any surface: this app, Bluey, Discord, the CLI…).
struct HermesSession: Identifiable, Equatable {
    var id: String
    var title: String
    var preview: String
    var source: String
    var lastActive: Date
    var messageCount: Int
    var pinned: Bool

    init?(_ json: [String: Any]) {
        guard let id = json["id"] as? String else { return nil }
        if json["hidden"] as? Bool == true || json["is_internal_child"] as? Bool == true { return nil }
        self.id = id
        let title = (json["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let preview = (json["preview"] as? String ?? "").replacingOccurrences(of: "\n", with: " ")
        self.title = title.isEmpty ? (preview.isEmpty ? "Neuer Chat" : String(preview.prefix(60))) : title
        self.preview = preview
        self.source = json["source"] as? String ?? "api_server"
        let last = (json["last_active"] as? Double) ?? (json["started_at"] as? Double) ?? 0
        self.lastActive = Date(timeIntervalSince1970: last)
        self.messageCount = json["message_count"] as? Int ?? 0
        self.pinned = json["pinned"] as? Bool ?? false
    }

    /// Chats started from this app or Bluey can be continued here; other surfaces (Discord…) are read-only.
    var writable: Bool { source == "api_server" }
    var isJournal: Bool { id.hasPrefix("bluey-journal-") }
}

struct HermesMessage: Identifiable, Equatable {
    enum Role: String { case user, assistant, tool, system }
    var id: String
    var role: Role
    var text: String
    var toolName: String?
    var date: Date

    init?(_ json: [String: Any]) {
        guard let roleText = json["role"] as? String, let role = Role(rawValue: roleText) else { return nil }
        if json["display_kind"] as? String == "internal_notification", role == .user {
            // Bluey's own probe/background prompts: still the user's words, keep them.
        }
        let content = json["content"] as? String ?? ""
        let tool = json["tool_name"] as? String
        if role == .assistant, content.isEmpty, json["tool_calls"] != nil, !(json["tool_calls"] is NSNull) {
            // The assistant only called tools here; the tool rows show that.
            return nil
        }
        if role == .system { return nil }
        self.id = "\(json["id"] ?? UUID().uuidString)"
        self.role = role
        self.text = content
        self.toolName = tool
        self.date = Date(timeIntervalSince1970: json["timestamp"] as? Double ?? 0)
    }

    init(id: String, role: Role, text: String, toolName: String? = nil, date: Date = Date()) {
        self.id = id; self.role = role; self.text = text; self.toolName = toolName; self.date = date
    }
}

// MARK: - Config

/// Where the hub is and its key. Saved in the phone's Keychain; the Mac can send it over the paired link.
struct HubConfig: Codable, Equatable {
    var url: String
    var key: String

    private static let account = "bluey-hub"

    static func load() -> HubConfig? {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: "co.visionairy.googly.hub", kSecAttrAccount as String: account,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        q = [:]
        return try? JSONDecoder().decode(HubConfig.self, from: data)
    }

    func save() {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: "co.visionairy.googly.hub", kSecAttrAccount as String: Self.account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = try? JSONEncoder().encode(self)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}

// MARK: - Client

enum HubError: LocalizedError {
    case notConfigured, unreachable(String), refused(Int, String)
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Verbinde den Hub zuerst in den Einstellungen."
        case .unreachable(let why): return "Hub nicht erreichbar (\(why)). Ist Tailscale aktiv?"
        case .refused(let code, let why): return "Hub-Fehler \(code): \(why.prefix(160))"
        }
    }
}

@MainActor
final class HubClient: ObservableObject {
    @Published private(set) var config: HubConfig? = HubClient.initialConfig()

    /// Saved config; debug builds also accept `-hubURL … -hubKey …` launch arguments (simulator tests).
    private static func initialConfig() -> HubConfig? {
        #if DEBUG
        if let url = UserDefaults.standard.string(forKey: "hubURL") {
            return HubConfig(url: url, key: UserDefaults.standard.string(forKey: "hubKey") ?? "")
        }
        #endif
        return HubConfig.load()
    }
    @Published private(set) var online = false
    @Published private(set) var problem: String?
    @Published var sessions: [HermesSession] = []
    @Published private(set) var pendingSessions: [String: HermesSession] = [:]
    @Published private(set) var draftSessions: [String: HermesSession] = [:]
    @Published var notes: [HubNote] = []
    @Published var todos: [HubTodo] = []

    private var conversations: [String: HubThreadConversation] = [:]
    private var todoAddRevision = 0
    private var lastChanges: [String: Double] = [:]
    private var poller: Task<Void, Never>?

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    func configure(_ config: HubConfig) {
        config.save()
        if self.config?.url != config.url {
            conversations.removeAll()
            pendingSessions.removeAll()
            draftSessions.removeAll()
        }
        self.config = config
        Task { await refreshAll() }
    }

    // MARK: Plumbing

    private func request(_ path: String, method: String = "GET", body: Any? = nil) throws -> URLRequest {
        // Built as text so query strings ("?limit=…") survive.
        guard let config, let url = URL(string: config.url.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + path) else {
            throw HubError.notConfigured
        }
        var r = URLRequest(url: url)
        r.httpMethod = method
        // Through `tailscale serve` your Tailscale identity is enough; a key is only needed otherwise.
        if !config.key.isEmpty { r.setValue("Bearer \(config.key)", forHTTPHeaderField: "Authorization") }
        if let body {
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    private func call(_ path: String, method: String = "GET", body: Any? = nil) async throws -> Any {
        let r = try request(path, method: method, body: body)
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: r) }
        catch { online = false; problem = HubError.unreachable(error.localizedDescription).localizedDescription; throw HubError.unreachable(error.localizedDescription) }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        online = true; problem = nil
        let json = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) ?? [:]
        guard (200..<300).contains(code) else {
            let message = ((json as? [String: Any])?["error"] as? [String: Any])?["message"] as? String
                ?? (json as? [String: Any])?["error"] as? String ?? String(data: data, encoding: .utf8) ?? ""
            throw HubError.refused(code, message)
        }
        return json
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: Any) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: json, options: [.fragmentsAllowed]))
    }

    // MARK: Sync

    func refreshAll() async {
        guard config != nil else { return }
        async let a: Void = refreshSessions()
        async let b: Void = refreshNotes()
        async let c: Void = refreshTodos()
        _ = await (a, b, c)
    }

    /// Light polling while the hub is on screen: only reloads what changed.
    func startPolling() {
        poller?.cancel()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                guard let self, self.config != nil else { continue }
                if let changes = try? await self.call("changes") as? [String: Double] {
                    if changes["notes"] != self.lastChanges["notes"] { await self.refreshNotes() }
                    if changes["todos"] != self.lastChanges["todos"] { await self.refreshTodos() }
                    self.lastChanges = changes
                }
                await self.refreshSessions()
            }
        }
    }

    func stopPolling() { poller?.cancel(); poller = nil }

    // MARK: Hermes threads

    func conversation(for sessionID: String, fresh: Bool) -> HubThreadConversation {
        if let conversation = conversations[sessionID] { return conversation }
        let conversation = HubThreadConversation(hub: self, sessionID: sessionID, fresh: fresh)
        conversations[sessionID] = conversation
        return conversation
    }

    func updateDraft(_ conversation: HubThreadConversation) {
        let id = conversation.sessionID
        guard conversations[id] === conversation else { return }
        let text = conversation.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if conversation.isLocalDraft, !text.isEmpty || conversation.options != HermesChatOptions() {
            draftSessions[id] = HermesSession([
                "id": id,
                "preview": text,
                "last_active": Date().timeIntervalSince1970
            ])
        } else {
            draftSessions[id] = nil
        }
    }

    func discardDraft(_ id: String) {
        guard draftSessions[id] != nil, pendingSessions[id] == nil else { return }
        conversations[id] = nil
        draftSessions[id] = nil
    }

    func markPending(_ conversation: HubThreadConversation, text: String) {
        let id = conversation.sessionID
        guard conversations[id] === conversation, let row = HermesSession([
            "id": id,
            "source": "api_server",
            "preview": text,
            "last_active": Date().timeIntervalSince1970
        ]) else { return }
        pendingSessions[id] = row
    }

    func clearPending(_ conversation: HubThreadConversation) {
        let id = conversation.sessionID
        guard conversations[id] === conversation else { return }
        pendingSessions[id] = nil
    }

    func refreshSessions() async {
        guard let json = try? await call("hermes/api/sessions", body: nil) as? [String: Any],
              let data = json["data"] as? [[String: Any]] else { return }
        sessions = data.compactMap(HermesSession.init).sorted { $0.lastActive > $1.lastActive }
    }

    func messages(of sessionID: String) async throws -> [HermesMessage] {
        let encoded = sessionID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionID
        guard let json = try await call("hermes/api/sessions/\(encoded)/messages?limit=200&order=latest") as? [String: Any],
              let data = json["data"] as? [[String: Any]] else { return [] }
        return data.compactMap(HermesMessage.init).sorted { $0.date < $1.date }
    }

    func modelCatalog() async throws -> HermesModelCatalog {
        try decode(HermesModelCatalog.self, try await call("hermes/api/model/options?include_unconfigured=false"))
    }

    /// Starts a Hermes run in a thread. Returns the run id.
    func send(_ text: String, session sessionID: String, options: HermesChatOptions = HermesChatOptions()) async throws -> String {
        let instructions = """
        The user is writing from the Bluey app on their iPhone (a chat like T3 Code's, with their notes and todos). \
        Answer in Markdown, concise. Their notes and todos live in Bluey Hub: use the `bluey-hub` command \
        (see the bluey-hub skill) to read or change them when asked.
        """
        var body = options.requestFields
        body["input"] = text
        body["session_id"] = sessionID
        body["instructions"] = instructions
        guard let json = try await call("hermes/v1/runs", method: "POST", body: body) as? [String: Any],
              let id = json["run_id"] as? String else { throw HubError.refused(0, "no run id") }
        return id
    }

    /// Live events of a run (`message.delta`, `tool.started`, `run.completed`, …) as dictionaries.
    func events(of runID: String) -> AsyncThrowingStream<[String: Any], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var r = try request("hermes/v1/runs/\(runID)/events")
                    r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    r.timeoutInterval = 900
                    let (bytes, _) = try await session.bytes(for: r)
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] {
                            continuation.yield(obj)
                            let event = obj["event"] as? String ?? ""
                            if ["run.completed", "run.failed", "run.cancelled", "run.interrupted"].contains(event) { break }
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The run's waiting approvals/questions (same shape as the Mac's).
    func pending(of runID: String) async -> [HermesPrompt] {
        guard let json = try? await call("hermes/v1/runs/\(runID)") as? [String: Any] else { return [] }
        return ((json["pending_controls"] as? [[String: Any]]) ?? []).compactMap(HermesPrompt.init(control:))
    }

    func respond(runID: String, prompt: HermesPrompt, choice: String) async throws {
        var body: [String: Any] = ["request_id": prompt.id]
        if prompt.generation > 0 { body["execution_generation"] = prompt.generation }
        body[prompt.kind == .approval ? "choice" : "answer"] = choice
        _ = try await call("hermes/v1/runs/\(runID)/\(prompt.kind == .approval ? "approval" : "clarify")", method: "POST", body: body)
    }

    func stop(runID: String) async {
        _ = try? await call("hermes/v1/runs/\(runID)/stop", method: "POST", body: [:])
    }

    func newSessionID() -> String { "app-" + UUID().uuidString.prefix(8).lowercased() }

    // MARK: Notes

    func refreshNotes() async {
        if let json = try? await call("notes"), let list = try? decode([HubNote].self, json) { notes = list }
    }

    func note(_ id: String) async throws -> HubNote { try decode(HubNote.self, try await call("notes/\(id)")) }

    @discardableResult
    func createNote(_ body: String) async throws -> HubNote {
        let n = try decode(HubNote.self, try await call("notes", method: "POST", body: ["body": body]))
        await refreshNotes()
        return n
    }

    func saveNote(_ id: String, body: String? = nil, pinned: Bool? = nil) async throws {
        var b: [String: Any] = [:]
        if let body { b["body"] = body }
        if let pinned { b["pinned"] = pinned }
        _ = try await call("notes/\(id)", method: "PUT", body: b)
        await refreshNotes()
    }

    func deleteNote(_ id: String) async {
        _ = try? await call("notes/\(id)", method: "DELETE")
        notes.removeAll { $0.id == id }
    }

    // MARK: Todos

    func refreshTodos() async {
        let revision = todoAddRevision
        guard let json = try? await call("todos"),
              revision == todoAddRevision,
              let list = try? decode([HubTodo].self, json) else { return }
        todos = list
    }

    func addTodo(_ title: String, due: String? = nil, list: String = "Inbox") async throws {
        var b: [String: Any] = ["title": title, "list": list]
        if let due { b["due"] = due }
        let json = try await call("todos", method: "POST", body: b)
        let todo = try decode(HubTodo.self, json)
        todoAddRevision += 1
        todos = (todos.filter { $0.id != todo.id } + [todo]).sorted {
            ($0.done ? 1 : 0, $0.due ?? "9999", $0.created) < ($1.done ? 1 : 0, $1.due ?? "9999", $1.created)
        }
    }

    func updateTodo(_ id: String, _ changes: [String: Any]) async {
        if let i = todos.firstIndex(where: { $0.id == id }), let done = changes["done"] as? Bool { todos[i].done = done }  // instant tick
        _ = try? await call("todos/\(id)", method: "PATCH", body: changes)
        await refreshTodos()
    }

    func deleteTodo(_ id: String) async {
        todos.removeAll { $0.id == id }
        _ = try? await call("todos/\(id)", method: "DELETE")
    }

    func screenRequest() throws -> URLRequest {
        var screen = try request("screen")
        screen.cachePolicy = .reloadIgnoringLocalCacheData
        return screen
    }

    func health() async -> Bool {
        (try? await call("health")) != nil
    }
}
