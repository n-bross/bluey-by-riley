import ActivityKit
import Foundation
#if canImport(GooglyShared)
import GooglyShared
#endif

/// The Live Activity while a pomodoro runs: countdown, phase and its todo on the Lock Screen and in the Dynamic Island.
/// The countdown runs by itself, so it stays right while the app sleeps.
@MainActor
enum PomodoroLiveActivity {
    private static var current: Activity<BlueyPomodoroAttributes>? { Activity<BlueyPomodoroAttributes>.activities.first }
    private static var last: BlueyPomodoroAttributes.ContentState?

    static var isShowing: Bool { current != nil }

    static func update(from snapshot: WorkspaceSnapshot) {
        guard BlueyLiveActivity.enabled, let state = content(from: snapshot) else { end(); return }
        guard state != last || current == nil else { return }
        last = state
        // Stale once the phase is over: the Lock Screen then says "Runde vorbei".
        let content = ActivityContent(state: state, staleDate: state.endsAt.map { $0.addingTimeInterval(1) })
        if let current {
            Task { await current.update(content) }
        } else if ActivityAuthorizationInfo().areActivitiesEnabled {
            _ = try? Activity.request(attributes: BlueyPomodoroAttributes(), content: content, pushType: nil)
        }
    }

    static func end() {
        last = nil
        for activity in Activity<BlueyPomodoroAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    private static func content(from snapshot: WorkspaceSnapshot) -> BlueyPomodoroAttributes.ContentState? {
        guard let p = snapshot.pomodoro, p.phase != .idle else { return nil }
        let phase: BlueyPomodoroAttributes.ContentState.Phase = p.phase == .focus ? .focus : p.phase == .longBreak ? .longBreak : .shortBreak
        let todo = p.todoID.flatMap { id in snapshot.todos.first { $0.id == id && !$0.deleted }?.title } ?? p.label
        let now = Date()
        return .init(phase: phase, todo: todo.isEmpty ? "Fokus" : todo,
                     endsAt: p.isRunning ? now.addingTimeInterval(p.remaining(at: now)).rounded() : nil,
                     duration: p.duration, remaining: p.remaining(at: now).rounded(),
                     round: p.round, roundsPerLongBreak: p.settings.roundsPerLongBreak)
    }
}

private extension Date {
    /// Whole seconds, so repeated updates for the same phase compare equal.
    func rounded() -> Date { Date(timeIntervalSince1970: timeIntervalSince1970.rounded()) }
}
