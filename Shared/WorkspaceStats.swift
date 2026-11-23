import Foundation

/// Numbers for the statistics tab, computed the same way on every device.
public struct WorkspaceStats: Codable, Equatable, Sendable {
    public struct Day: Codable, Equatable, Sendable, Identifiable {
        public var date: Date
        public var focusMinutes: Double
        public var pomodoros: Int
        public var todosDone: Int
        public var id: Date { date }
    }
    public var todayFocusMinutes: Double
    public var todayPomodoros: Int
    public var todayTodosDone: Int
    public var openTodos: Int
    public var overdueTodos: Int
    public var weekFocusMinutes: Double
    public var weekTodosDone: Int
    /// Days in a row (ending today, or yesterday if nothing yet today) with a pomodoro or a finished todo.
    public var streakDays: Int
    public var totalPomodoros: Int
    public var notes: Int
    public var chats: Int
    /// Share of on-task checks across Bluey focus sessions (screen checks), last 7 days.
    public var onTaskShare: Double?
    public var focusSessions: Int
    public var days: [Day]

    public init(_ snapshot: WorkspaceSnapshot, focusHistory: [FocusSession] = [], now: Date = Date(), calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        let records = snapshot.pomodoroLog.filter { !$0.deleted }
        let todos = snapshot.visibleTodos
        let doneTodos = todos.filter { $0.done && $0.completedAt != nil }
        let sessions = focusHistory.filter { $0.startedAt >= calendar.date(byAdding: .day, value: -6, to: today)! }

        func focusMinutes(_ day: Date) -> Double {
            let pomodoro = records.filter { calendar.isDate($0.completedAt, inSameDayAs: day) }.map(\.minutes).reduce(0, +)
            let watched = focusHistory.filter { calendar.isDate($0.startedAt, inSameDayAs: day) }
                .map { $0.realActiveElapsed / 60 }.reduce(0, +)
            return pomodoro + watched
        }

        days = (0..<7).reversed().map { offset in
            let day = calendar.date(byAdding: .day, value: -offset, to: today)!
            return Day(date: day,
                       focusMinutes: focusMinutes(day),
                       pomodoros: records.filter { calendar.isDate($0.completedAt, inSameDayAs: day) }.count,
                       todosDone: doneTodos.filter { calendar.isDate($0.completedAt!, inSameDayAs: day) }.count)
        }
        todayFocusMinutes = days.last?.focusMinutes ?? 0
        todayPomodoros = days.last?.pomodoros ?? 0
        todayTodosDone = days.last?.todosDone ?? 0
        weekFocusMinutes = days.map(\.focusMinutes).reduce(0, +)
        weekTodosDone = days.map(\.todosDone).reduce(0, +)
        openTodos = todos.filter { !$0.done }.count
        overdueTodos = todos.filter { !$0.done && ($0.due.map { calendar.startOfDay(for: $0) < today } ?? false) }.count
        totalPomodoros = records.count
        notes = snapshot.visibleNotes.count
        chats = snapshot.visibleThreads.count
        focusSessions = sessions.count

        let checks = sessions.flatMap(\.checks).filter { $0.activity == .onTask || $0.activity == .offTask }
        onTaskShare = checks.isEmpty ? nil : Double(checks.filter { $0.activity == .onTask }.count) / Double(checks.count)

        var activeDays = Set<Date>()
        for r in records { activeDays.insert(calendar.startOfDay(for: r.completedAt)) }
        for t in doneTodos { activeDays.insert(calendar.startOfDay(for: t.completedAt!)) }
        for s in focusHistory where s.realActiveElapsed >= 60 { activeDays.insert(calendar.startOfDay(for: s.startedAt)) }
        var cursor = activeDays.contains(today) ? today : calendar.date(byAdding: .day, value: -1, to: today)!
        var streak = 0
        while activeDays.contains(cursor) {
            streak += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }
        streakDays = streak
    }
}
