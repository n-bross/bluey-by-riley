import XCTest
@testable import GooglyShared

final class WorkspaceTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testMergeKeepsNewestVersionOfEachItem() {
        var mac = WorkspaceSnapshot()
        var todo = TodoItem(title: "Steuer", now: t0)
        mac.todos = [todo]

        var phone = mac
        todo.title = "Steuer: Belege suchen"
        todo.updatedAt = t0.addingTimeInterval(5)
        phone.todos = [todo]

        var stale = mac
        stale.todos[0].title = "alt"
        stale.todos[0].updatedAt = t0.addingTimeInterval(1)

        XCTAssertTrue(mac.merge(phone))
        XCTAssertFalse(mac.merge(stale))
        XCTAssertEqual(mac.todos.map(\.title), ["Steuer: Belege suchen"])
    }

    func testDeletionsSyncAsTombstonesAndArePrunedLater() {
        var mac = WorkspaceSnapshot()
        var note = NoteItem(title: "Idee", now: t0)
        mac.notes = [note]
        note.deleted = true
        note.updatedAt = t0.addingTimeInterval(1)
        var partial = WorkspaceSnapshot()
        partial.notes = [note]
        mac.merge(partial)
        XCTAssertTrue(mac.visibleNotes.isEmpty)
        XCTAssertEqual(mac.notes.count, 1)
        mac.pruneTombstones(olderThan: 60, now: t0.addingTimeInterval(120))
        XCTAssertTrue(mac.notes.isEmpty)
    }

    func testClientsCannotReplaceModelsWithEmptyList() {
        var mac = WorkspaceSnapshot()
        mac.models = [ChatModelInfo(id: "gpt-5.5")]
        mac.merge(WorkspaceSnapshot())
        XCTAssertEqual(mac.models.map(\.id), ["gpt-5.5"])
    }

    func testCodingRoundTripsWithMilliseconds() throws {
        var snapshot = WorkspaceSnapshot()
        snapshot.todos = [TodoItem(title: "A", now: Date(timeIntervalSince1970: 1_800_000_000.123))]
        let text = try XCTUnwrap(WorkspaceCoding.string(snapshot))
        XCTAssertTrue(text.contains("2027-01-15T08:00:00.123Z"))
        let back = try XCTUnwrap(WorkspaceCoding.decode(WorkspaceSnapshot.self, text))
        XCTAssertEqual(back.todos[0].updatedAt.timeIntervalSince1970, 1_800_000_000.123, accuracy: 0.001)
        // Partial JSON from the web app decodes with defaults.
        let partial = try XCTUnwrap(WorkspaceCoding.decode(WorkspaceSnapshot.self, #"{"notes":[{"id":"\#(UUID().uuidString)","title":"x","updatedAt":"2027-01-15T08:00:00.000Z"}]}"#))
        XCTAssertEqual(partial.notes.first?.title, "x")
        XCTAssertTrue(partial.todos.isEmpty)
    }

    func testPomodoroAdvanceIsDeterministicAcrossDevices() {
        var state = PomodoroState()
        state.settings.focusMinutes = 25
        state.startFocus(label: "Schreiben", todoID: nil, now: t0)
        var phone = state, mac = state
        let later = t0.addingTimeInterval(25 * 60 + 3)
        let a = phone.advance(now: later)
        let b = mac.advance(now: later.addingTimeInterval(0.7))
        XCTAssertEqual(a, b)
        XCTAssertEqual(phone, mac)
        XCTAssertEqual(a?.minutes, 25)
        XCTAssertEqual(phone.phase, .shortBreak)
        XCTAssertEqual(phone.round, 1)
        XCTAssertEqual(phone.startedAt, t0.addingTimeInterval(25 * 60))
    }

    func testPomodoroPauseKeepsRemainingTimeAndLongBreakAfterRounds() {
        var state = PomodoroState()
        state.settings.roundsPerLongBreak = 2
        state.startFocus(label: "", todoID: nil, now: t0)
        state.pause(now: t0.addingTimeInterval(60))
        XCTAssertEqual(state.remaining(at: t0.addingTimeInterval(600)), 24 * 60, accuracy: 0.001)
        XCTAssertNil(state.advance(now: t0.addingTimeInterval(10_000)))
        state.resume(now: t0.addingTimeInterval(600))
        XCTAssertNotNil(state.advance(now: t0.addingTimeInterval(600 + 24 * 60)))
        XCTAssertEqual(state.phase, .shortBreak)
        state.skip(now: t0.addingTimeInterval(3000))
        XCTAssertEqual(state.phase, .idle)
        state.startFocus(label: "", todoID: nil, now: t0.addingTimeInterval(4000))
        _ = state.advance(now: t0.addingTimeInterval(4000 + 25 * 60))
        XCTAssertEqual(state.phase, .longBreak)
    }

    func testStatsCountTodayAndStreak() {
        let calendar = Calendar(identifier: .gregorian)
        let now = t0
        var snapshot = WorkspaceSnapshot()
        var done = TodoItem(title: "Fertig", now: now)
        done.done = true; done.completedAt = now
        snapshot.todos = [done, TodoItem(title: "Offen", due: now.addingTimeInterval(-3 * 86400), now: now)]
        let yesterday = now.addingTimeInterval(-86400)
        snapshot.pomodoroLog = [PomodoroRecord(id: UUID(), label: "", todoID: nil, startedAt: yesterday, minutes: 25, completedAt: yesterday)]
        let stats = WorkspaceStats(snapshot, now: now, calendar: calendar)
        XCTAssertEqual(stats.todayTodosDone, 1)
        XCTAssertEqual(stats.openTodos, 1)
        XCTAssertEqual(stats.overdueTodos, 1)
        XCTAssertEqual(stats.streakDays, 2)
        XCTAssertEqual(stats.weekFocusMinutes, 25)
        XCTAssertEqual(stats.days.count, 7)
    }
}
