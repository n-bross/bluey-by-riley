import Foundation

/// What Bluey does when Hermes wants to run something risky (a shell command, a click, sending a message).
public enum HermesApprovalMode: String, Codable, CaseIterable, Sendable {
    /// Show a card on the phone and the Mac; you pick.
    case ask
    /// Refuse every risky step; Hermes has to find another way.
    case deny
    /// Allow every risky step once, without asking.
    case allow

    public var title: String {
        switch self {
        case .ask: return "Nachfragen"
        case .deny: return "Ablehnen"
        case .allow: return "Erlauben"
        }
    }
}

/// Something a Hermes run is waiting on: an approval (a command it wants to run) or a question for you.
public struct HermesPrompt: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case approval, clarify }
    public var id: String
    public var kind: Kind
    public var generation: Int
    /// For approvals: the command and why. For questions: the question.
    public var text: String
    public var detail: String?
    /// Approval choices ("once", "session", "always", "deny") or the question's answer options.
    public var choices: [String]

    public init(id: String, kind: Kind, generation: Int, text: String, detail: String? = nil, choices: [String]) {
        self.id = id; self.kind = kind; self.generation = generation
        self.text = text; self.detail = detail; self.choices = choices
    }

    /// Reads one entry of `pending_controls` from `GET /v1/runs/{id}`.
    public init?(control: [String: Any]) {
        guard let id = control["prompt_id"] as? String, let kindText = control["kind"] as? String,
              let kind = Kind(rawValue: kindText) else { return nil }
        let generation = (control["execution_generation"] as? Int) ?? (control["execution_generation"] as? Double).map(Int.init) ?? 0
        let choices = (control["choices"] as? [String]) ?? []
        switch kind {
        case .approval:
            let command = (control["command"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let description = (control["description"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            self.init(id: id, kind: kind, generation: generation,
                      text: String((command.isEmpty ? description : command).prefix(600)),
                      detail: command.isEmpty || description.isEmpty ? nil : String(description.prefix(400)),
                      choices: choices.isEmpty ? ["once", "deny"] : choices)
        case .clarify:
            self.init(id: id, kind: kind, generation: generation,
                      text: String((control["question"] as? String ?? "Hermes has a question.").prefix(600)),
                      choices: choices)
        }
    }

    public static func choiceTitle(_ choice: String) -> String {
        switch choice {
        case "once": return "Erlauben"
        case "session": return "Für Sitzung erlauben"
        case "always": return "Immer erlauben"
        case "deny": return "Ablehnen"
        default: return choice
        }
    }
}

/// One request handed to Hermes, and what came of it.
public struct HermesRun: Codable, Equatable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable { case sending, running, waiting, completed, failed, cancelled }
    public var id: String
    public var prompt: String
    public var status: Status
    public var started: Date
    public var finished: Date?
    /// The final answer, or the error.
    public var output: String?
    /// Latest tool Hermes used, for a live "browsing…" style line.
    public var activity: String?
    public var pending: [HermesPrompt]
    /// Background runs (the daily journal): no bubble, not in the phone's chat.
    public var quiet: Bool?
    /// Workspace runs use the same Hub profile as the live screen.
    public var viaHub: Bool?
    public var workspaceThreadID: UUID?

    public init(id: String, prompt: String, status: Status = .sending, started: Date = Date()) {
        self.id = id; self.prompt = prompt; self.status = status; self.started = started; self.pending = []
    }

    public var isActive: Bool { [.sending, .running, .waiting].contains(status) }
}

/// Time on one app, from ActivityWatch, counting only time you weren't AFK.
public struct AppTime: Codable, Equatable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var seconds: Double
    public init(name: String, seconds: Double) { self.name = name; self.seconds = seconds }
}

/// A slice of ActivityWatch data: real active (not-AFK) time and where it went.
public struct ActivitySummary: Codable, Equatable, Sendable {
    public var from: Date
    public var to: Date
    /// Keyboard or mouse used recently (ActivityWatch's not-afk time).
    public var activeSeconds: Double
    public var afkSeconds: Double
    /// Top apps during active time, longest first.
    public var apps: [AppTime]
    /// Top window titles during active time (trimmed), longest first.
    public var titles: [AppTime]

    public init(from: Date, to: Date, activeSeconds: Double, afkSeconds: Double, apps: [AppTime], titles: [AppTime] = []) {
        self.from = from; self.to = to; self.activeSeconds = activeSeconds; self.afkSeconds = afkSeconds
        self.apps = apps; self.titles = titles
    }

    public static func duration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        return minutes >= 60 ? "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m" : "\(minutes)m"
    }

    /// A short plain-text version for Hermes and for his voice.
    public var plainText: String {
        var lines = ["Active (keyboard/mouse) \(Self.duration(activeSeconds)), away \(Self.duration(afkSeconds))."]
        if !apps.isEmpty {
            lines.append("Apps: " + apps.prefix(8).map { "\($0.name) \(Self.duration($0.seconds))" }.joined(separator: ", ") + ".")
        }
        if !titles.isEmpty {
            lines.append("Windows: " + titles.prefix(6).map { "\($0.name) \(Self.duration($0.seconds))" }.joined(separator: "; ") + ".")
        }
        return lines.joined(separator: " ")
    }
}

/// Everything the phone shows on its Hermes screen. The Mac is authoritative.
public struct HermesSync: Codable, Equatable, Sendable {
    public var available: Bool
    /// Why Hermes isn't reachable, if it isn't.
    public var problem: String?
    public var mode: HermesApprovalMode
    public var runs: [HermesRun]
    public var activityAvailable: Bool
    public var today: ActivitySummary?

    public init(available: Bool, problem: String?, mode: HermesApprovalMode, runs: [HermesRun],
                activityAvailable: Bool, today: ActivitySummary?) {
        self.available = available; self.problem = problem; self.mode = mode; self.runs = runs
        self.activityAvailable = activityAvailable; self.today = today
    }
}

/// Per-turn overrides for Hermes' native API. Missing values use the gateway defaults.
public struct HermesChatOptions: Codable, Equatable, Sendable {
    public var provider: String?
    public var model: String?
    public var thinking: Thinking?

    public init(provider: String? = nil, model: String? = nil, thinking: Thinking? = nil) {
        self.provider = provider
        self.model = model
        self.thinking = thinking
    }

    public enum Thinking: String, CaseIterable, Codable, Sendable {
        case none, minimal, low, medium, high, xhigh, max, ultra

        public var title: String {
            switch self {
            case .none: return "Aus"
            case .xhigh: return "Extra hoch"
            case .low: return "Niedrig"
            case .medium: return "Mittel"
            case .high: return "Hoch"
            default: return rawValue.capitalized
            }
        }
    }

    public var requestFields: [String: Any] {
        var fields: [String: Any] = [:]
        if let model { fields["model"] = model }
        if let provider { fields["provider"] = provider }
        if let thinking { fields["model_options"] = ["reasoning_effort": thinking.rawValue] }
        return fields
    }
}

public struct HermesModelCatalog: Decodable, Sendable {
    public struct Provider: Decodable, Identifiable, Sendable {
        public struct Capability: Decodable, Sendable { public let reasoning: Bool? }

        public let slug: String
        public let name: String
        public let models: [String]
        public let capabilities: [String: Capability]?
        public var id: String { slug }
    }

    public let providers: [Provider]
    public let model: String?
    public let provider: String?
}

public enum HermesLiveTool: String, Codable, Sendable {
    case browser, computer

    public init?(tool: String) {
        if tool.hasPrefix("browser_") { self = .browser }
        else if tool == "computer_use" { self = .computer }
        else { return nil }
    }

    public var title: String { self == .browser ? "Browser Use" : "Computer Use" }
    public var symbol: String { self == .browser ? "globe" : "display" }
}
