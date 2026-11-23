import XCTest
import GooglyShared
@testable import GooglyMac

/// A test clock the companion reads while the test moves it forward.
private final class Clock { var time = 100.0 }

final class PomodoroTests: XCTestCase {
    private var onTask: FocusDecision {
        try! FocusDecision.decode(Data(#"{"answers":[{"name":"activity","type":"choice","choice":"on_task","confidence":0.9,"probabilities":[{"value":"on_task","probability":0.95},{"value":"off_task","probability":0.03},{"value":"uncertain","probability":0.02}]}]}"#.utf8))
    }

    @MainActor private func companion(_ time: @escaping () -> Double) -> FocusCompanion {
        let answer = onTask
        return FocusCompanion(now: time, permission: { true }, hasKey: { true }, screenUnlocked: { true },
            capture: { ScreenSnapshot(jpeg: Data(), lines: [], size: .zero) }, classify: { _, _, _ in answer },
            showsCountdown: false, historyFile: URL(fileURLWithPath: "/tmp/bluey-pomodoro-test-\(UUID()).json"), settings: nil)
    }

    @MainActor private func run(_ app: FocusCompanion, seconds: Int, clock: Clock) async {
        for _ in 0..<seconds { clock.time += 1; app.heartbeat(); app.tick(); await Task.yield() }
    }

    @MainActor func testRoundThenBreakThenLongBreakResetsCycle() async {
        let clock = Clock()
        let app = companion { clock.time }
        var messages: [String] = []
        app.onPomodoro = { messages.append($0) }
        var s = PomodoroRhythm(focus: 1, shortBreak: 1, longBreak: 2, rounds: 2)
        s.autoStartFocus = false
        app.setPomodoro(s)
        app.heartbeat()
        XCTAssertTrue(app.start(task: "Write the report").hasPrefix("Focus started"))
        XCTAssertEqual(app.current?.duration, 60, "No minutes given: the Pomodoro focus length applies")

        await run(app, seconds: 61, clock: clock)
        XCTAssertEqual(app.current?.status, .ended)
        XCTAssertEqual(app.completedRounds, 1)
        XCTAssertEqual(app.rest?.kind, .short)
        XCTAssertEqual(app.rest?.task, "Write the report")
        XCTAssertTrue(messages.last?.contains("Off you pop") == true)

        await run(app, seconds: 61, clock: clock)
        XCTAssertNil(app.rest)
        XCTAssertTrue(messages.last?.hasPrefix("Break's over") == true)
        XCTAssertEqual(app.current?.status, .ended, "The next round waits for the user")

        _ = app.start(task: "Write the report")
        await run(app, seconds: 61, clock: clock)
        XCTAssertEqual(app.completedRounds, 2)
        XCTAssertEqual(app.rest?.kind, .long)
        XCTAssertEqual(app.rest?.duration, 120)
        await run(app, seconds: 121, clock: clock)
        XCTAssertNil(app.rest)
        XCTAssertEqual(app.completedRounds, 0, "A long break starts a fresh cycle")
    }

    @MainActor func testAutoStartNextRoundOnSameTask() async {
        let clock = Clock()
        let app = companion { clock.time }
        var s = PomodoroRhythm(focus: 1, shortBreak: 1, longBreak: 1, rounds: 4)
        s.autoStartFocus = true
        app.setPomodoro(s)
        app.heartbeat()
        _ = app.start(task: "Inbox zero")
        await run(app, seconds: 122, clock: clock)
        XCTAssertNil(app.rest)
        XCTAssertEqual(app.current?.status, .running)
        XCTAssertEqual(app.current?.task, "Inbox zero")
        _ = app.end()
    }

    @MainActor func testEndingEarlyGivesNoBreakAndSkipWorks() async {
        let clock = Clock()
        let app = companion { clock.time }
        app.setPomodoro(PomodoroRhythm(focus: 1, shortBreak: 5, longBreak: 15, rounds: 4))
        app.heartbeat()
        _ = app.start(task: "Emails")
        await run(app, seconds: 10, clock: clock)
        _ = app.end()
        XCTAssertNil(app.rest)
        XCTAssertEqual(app.completedRounds, 0)

        XCTAssertTrue(app.takeBreak().contains("5 minutes"))
        XCTAssertEqual(app.pause("Mac locked"), "The break keeps running. Say skip to end it early.")
        XCTAssertNotNil(app.rest)
        XCTAssertTrue(app.skipBreak().hasPrefix("Break skipped"))
        XCTAssertNil(app.rest)
    }

    @MainActor func testPomodoroOffKeepsOldBehaviour() async {
        let clock = Clock()
        let app = companion { clock.time }
        var s = PomodoroRhythm(); s.enabled = false
        app.setPomodoro(s)
        app.heartbeat()
        _ = app.start(task: "Reading")
        XCTAssertEqual(app.current?.duration, 1800)
        _ = app.start(task: "x")  // refused: one session at a time
        _ = app.end()
        XCTAssertNil(app.rest)
    }

    func testSettingsClampAndBreakKinds() {
        var s = PomodoroRhythm(focus: 999, shortBreak: 0, longBreak: .nan, rounds: 40).clamped()
        XCTAssertEqual(s.focusMinutes, 240)
        XCTAssertEqual(s.shortBreakMinutes, 1)
        XCTAssertEqual(s.longBreakMinutes, 15)
        XCTAssertEqual(s.roundsBeforeLongBreak, 12)
        s = PomodoroRhythm()
        XCTAssertEqual(s.breakKind(afterRound: 1), .short)
        XCTAssertEqual(s.breakKind(afterRound: 4), .long)
        XCTAssertEqual(s.breakKind(afterRound: 8), .long)
        var b = PomodoroBreak(kind: .short, minutes: 5, round: 1, task: "t", clockRate: 4)
        XCTAssertFalse(b.advance(60))
        XCTAssertTrue(b.advance(15))
    }
}
