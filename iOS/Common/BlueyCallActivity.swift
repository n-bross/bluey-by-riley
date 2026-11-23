import Foundation
#if canImport(ActivityKit)
import ActivityKit

/// The Live Activity shown while you're outside the app: "Bluey fragen", or the running call.
struct BlueyCallAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable { case ready, connecting, listening, thinking, speaking, ended }
        var phase: Phase
        /// When the call started (nil while just ready).
        var callStarted: Date?
        var sharingScreen: Bool
        /// The last thing Bluey said, short.
        var caption: String

        static let ready = ContentState(phase: .ready, callStarted: nil, sharingScreen: false, caption: "")

        var title: String {
            switch phase {
            case .ready: return "Bluey fragen"
            case .connecting: return "Verbinde…"
            case .listening: return sharingScreen ? "Schaut mit und hört zu" : "Hört zu"
            case .thinking: return "Denkt nach…"
            case .speaking: return "Spricht"
            case .ended: return "Anruf beendet"
            }
        }
        var isCall: Bool { callStarted != nil && phase != .ended }
    }
}

/// The Live Activity while a pomodoro runs: countdown, phase and the todo it belongs to.
struct BlueyPomodoroAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable { case focus, shortBreak, longBreak }
        var phase: Phase
        var todo: String
        /// When the phase runs out (nil while paused).
        var endsAt: Date?
        /// Full length of the phase in seconds.
        var duration: Double
        /// Seconds left while paused.
        var remaining: Double
        var round: Int
        var roundsPerLongBreak: Int

        var paused: Bool { endsAt == nil }
        var isBreak: Bool { phase != .focus }
        var title: String {
            switch phase {
            case .focus: return paused ? "Fokus pausiert" : "Fokus"
            case .shortBreak: return paused ? "Pause pausiert" : "Kurze Pause"
            case .longBreak: return paused ? "Pause pausiert" : "Lange Pause"
            }
        }
        /// The window the countdown runs over (for the system timer and progress bar).
        var interval: ClosedRange<Date>? {
            guard let endsAt else { return nil }
            return endsAt.addingTimeInterval(-duration)...endsAt
        }
    }
}
#endif

/// Where the screen-sharing extension leaves the latest frame for the app (shared app group).
enum ScreenShareFiles {
    static var groupID: String? {
        Bundle.main.object(forInfoDictionaryKey: "BlueyAppGroup") as? String
    }
    static var folder: URL? {
        groupID.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
    }
    static var frame: URL? { folder?.appendingPathComponent("screen.jpg") }
    static var state: URL? { folder?.appendingPathComponent("screen-state.json") }

    /// True while a broadcast is running and delivering frames.
    static var isSharing: Bool {
        guard let state, let data = try? Data(contentsOf: state),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["active"] as? Bool == true, let updated = json["updatedAt"] as? Double else { return false }
        return Date().timeIntervalSince1970 - updated < 120  // a still screen sends no new frames
    }

    /// The latest frame, if it's fresh.
    static func latestFrame(maxAge: Double = 120) -> Data? {
        guard let frame, let attributes = try? FileManager.default.attributesOfItem(atPath: frame.path),
              let modified = attributes[.modificationDate] as? Date, Date().timeIntervalSince(modified) < maxAge else { return nil }
        return try? Data(contentsOf: frame)
    }
}
