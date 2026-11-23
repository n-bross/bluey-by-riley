import SwiftUI
import Charts
#if canImport(GooglyShared)
import GooglyShared
#endif

/// Statistics: today, the streak and the last seven days. Encouraging, never guilt-tripping.
struct StatsTab: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var ui: WorkspaceUI
    var info: HeaderInfo

    var body: some View {
        let stats = model.stats
        VStack(spacing: 0) {
            TabHeader(ui: ui, model: model, tab: .stats, connectionName: info.connectionName, onSettings: info.onSettings) { EmptyView() }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    cheer(stats)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                        tile("Fokus heute", "\(Int(stats.todayFocusMinutes.rounded())) min", icon: "flame.fill", color: Theme.red)
                        tile("Pomodoros heute", "\(stats.todayPomodoros)", icon: "timer", color: Theme.peach)
                        tile("Todos erledigt", "\(stats.todayTodosDone)", icon: "checkmark.circle.fill", color: Theme.green)
                        tile("Serie", "\(stats.streakDays) \(stats.streakDays == 1 ? "Tag" : "Tage")", icon: "bolt.fill", color: Theme.yellow)
                        tile("Offen", stats.overdueTodos > 0 ? "\(stats.openTodos) · \(stats.overdueTodos) alt" : "\(stats.openTodos)", icon: "tray.full.fill", color: Theme.accentLight)
                        if let share = stats.onTaskShare {
                            tile("On Task (7 Tage)", "\(Int((share * 100).rounded())) %", icon: "eye.fill", color: Theme.accent)
                        } else {
                            tile("Chats", "\(stats.chats)", icon: "bubble.left.fill", color: Theme.accent)
                        }
                    }
                    week(stats)
                    totals(stats)
                }
                .padding(16)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Theme.background)
    }

    private func cheer(_ stats: WorkspaceStats) -> some View {
        HStack(spacing: 14) {
            BlueyAvatar(mood: stats.todayFocusMinutes > 0 || stats.todayTodosDone > 0 ? .happy : .listening)
                .frame(width: 64, height: 57)
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.headline(stats)).font(.fredoka(20)).foregroundStyle(.white)
                Text("Diese Woche: \(Int(stats.weekFocusMinutes.rounded())) Minuten Fokus, \(stats.weekTodosDone) Todos erledigt.")
                    .font(.plexSans(13)).foregroundStyle(Theme.soft)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    static func headline(_ stats: WorkspaceStats) -> String {
        if stats.todayFocusMinutes >= 90 { return "Was für ein Tag. Gönn dir eine Pause!" }
        if stats.todayFocusMinutes > 0 || stats.todayTodosDone > 0 { return "Du bist dran. Lovely!" }
        if stats.streakDays > 0 { return "Deine Serie wartet: eine kleine Runde reicht." }
        return "Jeder Anfang zählt. Fang klein an."
    }

    private func tile(_ title: String, _ value: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            Text(value).font(.system(size: 26, weight: .bold, design: .rounded)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6)
            Text(title).font(.plexSans(12)).foregroundStyle(Theme.soft)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func week(_ stats: WorkspaceStats) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Letzte 7 Tage")
            Chart {
                ForEach(stats.days) { day in
                    BarMark(x: .value("Tag", day.date, unit: .day), y: .value("Minuten", day.focusMinutes))
                        .foregroundStyle(by: .value("Art", "Fokus-Minuten"))
                        .cornerRadius(5)
                    LineMark(x: .value("Tag", day.date, unit: .day), y: .value("Todos", Double(day.todosDone) * 10))
                        .foregroundStyle(by: .value("Art", "Todos ×10"))
                        .symbol(.circle)
                        .interpolationMethod(.monotone)
                }
            }
            .chartForegroundStyleScale(["Fokus-Minuten": Theme.accent, "Todos ×10": Theme.green])
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated).locale(Locale(identifier: "de_DE")))
                        .foregroundStyle(Theme.soft)
                }
            }
            .chartYAxis {
                AxisMarks { _ in
                    AxisGridLine().foregroundStyle(Theme.line)
                    AxisValueLabel().foregroundStyle(Theme.soft)
                }
            }
            .chartLegend(position: .bottom)
            .frame(height: 220)
        }
        .card()
    }

    private func totals(_ stats: WorkspaceStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Insgesamt")
            row("Pomodoros", "\(stats.totalPomodoros)")
            row("Bluey-Fokus-Sessions (7 Tage)", "\(stats.focusSessions)")
            row("Notizen", "\(stats.notes)")
            row("Chats", "\(stats.chats)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.plexSans(14)).foregroundStyle(Theme.soft)
            Spacer()
            Text(value).font(.plexMono(14)).foregroundStyle(.white)
        }
    }
}
