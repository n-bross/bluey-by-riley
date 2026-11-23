import Foundation

/// The Pomodoro rhythm: focus, short break, focus … and a long break after a few rounds.
/// The Mac owns it (and remembers it); the phone and the notch show and change it.
public struct PomodoroSettings: Codable, Equatable, Sendable {
    /// Off: focus sessions just end, like before, with no breaks.
    public var enabled = true
    public var focusMinutes: Double = 25
    public var shortBreakMinutes: Double = 5
    public var longBreakMinutes: Double = 15
    /// After this many focus rounds the break is a long one.
    public var roundsBeforeLongBreak = 4
    /// A finished focus round goes straight into its break (otherwise Bluey suggests one).
    public var autoStartBreaks = true
    /// A finished break starts the next focus round on the same task (otherwise Bluey asks).
    public var autoStartFocus = false

    public init() {}

    public init(focus: Double, shortBreak: Double, longBreak: Double, rounds: Int) {
        focusMinutes = focus; shortBreakMinutes = shortBreak; longBreakMinutes = longBreak; roundsBeforeLongBreak = rounds
    }

    /// Keeps every value in a sensible range.
    public func clamped() -> PomodoroSettings {
        var s = self
        s.focusMinutes = min(240, max(1, focusMinutes.isFinite ? focusMinutes.rounded() : 25))
        s.shortBreakMinutes = min(60, max(1, shortBreakMinutes.isFinite ? shortBreakMinutes.rounded() : 5))
        s.longBreakMinutes = min(120, max(1, longBreakMinutes.isFinite ? longBreakMinutes.rounded() : 15))
        s.roundsBeforeLongBreak = min(12, max(1, roundsBeforeLongBreak))
        return s
    }

    /// Which break follows the given number of finished focus rounds in this cycle (1-based).
    public func breakKind(afterRound round: Int) -> PomodoroBreak.Kind {
        round > 0 && round % max(1, roundsBeforeLongBreak) == 0 ? .long : .short
    }

    public func breakMinutes(_ kind: PomodoroBreak.Kind) -> Double {
        kind == .long ? longBreakMinutes : shortBreakMinutes
    }

    public var summary: String {
        guard enabled else { return "Pomodoro off" }
        return "\(Int(focusMinutes)) min focus · \(Int(shortBreakMinutes)) min break · \(Int(longBreakMinutes)) min after \(roundsBeforeLongBreak) rounds"
    }

    public static let presets: [(name: String, settings: PomodoroSettings)] = [
        ("Classic 25 / 5", PomodoroSettings(focus: 25, shortBreak: 5, longBreak: 15, rounds: 4)),
        ("Deep 50 / 10", PomodoroSettings(focus: 50, shortBreak: 10, longBreak: 30, rounds: 3)),
        ("Long 90 / 20", PomodoroSettings(focus: 90, shortBreak: 20, longBreak: 30, rounds: 2)),
        ("Gentle 15 / 5", PomodoroSettings(focus: 15, shortBreak: 5, longBreak: 15, rounds: 4)),
    ]

    /// True when the rhythm (not the auto-start switches) matches the other settings.
    public func sameRhythm(_ other: PomodoroSettings) -> Bool {
        focusMinutes == other.focusMinutes && shortBreakMinutes == other.shortBreakMinutes
            && longBreakMinutes == other.longBreakMinutes && roundsBeforeLongBreak == other.roundsBeforeLongBreak
    }
}

/// A break between focus rounds. No screen checks happen during it.
public struct PomodoroBreak: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case short, long }
    public var id = UUID()
    public var kind: Kind
    /// Seconds on the (possibly accelerated) clock.
    public var duration: Double
    public var elapsed: Double = 0
    public var paused = false
    /// Focus rounds finished in this cycle when the break began.
    public var round: Int
    /// The task to come back to.
    public var task: String
    /// Developer Mode runs breaks at 4× too.
    public var clockRate: Double = 1

    public init(kind: Kind, minutes: Double, round: Int, task: String, clockRate: Double = 1) {
        self.kind = kind; self.duration = max(60, minutes * 60); self.round = round
        self.task = String(task.prefix(500)); self.clockRate = clockRate
    }

    public var remaining: Double { max(0, duration - elapsed) }
    public var isOver: Bool { elapsed >= duration }

    /// Advances by real seconds; returns true the moment the break is over.
    public mutating func advance(_ seconds: Double) -> Bool {
        guard !paused, !isOver, seconds.isFinite, seconds > 0 else { return false }
        elapsed = min(duration, elapsed + seconds * clockRate)
        return isOver
    }

    public var title: String { kind == .long ? "Long break" : "Break" }
}
