import WidgetKit
import SwiftUI
import ActivityKit

@main
struct BlueyWidgets: WidgetBundle {
    var body: some Widget {
        BlueyCallLiveActivity()
        BlueyPomodoroLiveActivity()
    }
}

private let berry = LinearGradient(colors: Palette.gradient.map { Color(hex: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing)

extension Color {
    init(hex: UInt32) {
        let c = Palette.rgb(hex)
        self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: 1)
    }
}

/// Tiny Bluey for the Lock Screen and Dynamic Island.
struct WidgetBluey: View {
    var size: CGFloat
    var listening = false
    var body: some View {
        ZStack {
            Ellipse().fill(berry).frame(width: size, height: size * 0.9)
            HStack(spacing: size * 0.1) {
                ForEach(0..<2, id: \.self) { _ in
                    Circle().fill(.white).frame(width: size * 0.27)
                        .overlay(Circle().fill(Color(hex: Palette.ink)).frame(width: size * 0.12).offset(x: size * 0.02, y: size * 0.02))
                }
            }
            .offset(y: -size * 0.04)
        }
        .frame(width: size, height: size)
    }
}

struct BlueyCallLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BlueyCallAttributes.self) { context in
            LockScreenView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.75))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "bluey://call"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    WidgetBluey(size: 44).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let started = context.state.callStarted, context.state.isCall {
                        Text(started, style: .timer).monospacedDigit().font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 60, alignment: .trailing)
                    } else {
                        Image(systemName: "phone.fill").foregroundStyle(Color(hex: Palette.berry1)).font(.system(size: 22))
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.state.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                        if context.state.sharingScreen {
                            Label("Bildschirm geteilt", systemImage: "rectangle.inset.filled.and.person.filled")
                                .font(.system(size: 12)).foregroundStyle(Color(hex: 0x5BE49B))
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.caption.isEmpty ? (context.state.isCall ? "Sprich einfach los." : "Tippen, um mit Bluey zu telefonieren.") : context.state.caption)
                        .font(.system(size: 13)).foregroundStyle(.white.opacity(0.75)).lineLimit(2)
                }
            } compactLeading: {
                WidgetBluey(size: 22)
            } compactTrailing: {
                if let started = context.state.callStarted, context.state.isCall {
                    Text(started, style: .timer).monospacedDigit().font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(context.state.sharingScreen ? Color(hex: 0x5BE49B) : Color(hex: Palette.berry1))
                        .frame(maxWidth: 44)
                } else {
                    Image(systemName: "phone.fill").foregroundStyle(Color(hex: Palette.berry1))
                }
            } minimal: {
                WidgetBluey(size: 20)
            }
            .widgetURL(URL(string: "bluey://call"))
        }
    }
}

private struct LockScreenView: View {
    var state: BlueyCallAttributes.ContentState
    var body: some View {
        HStack(spacing: 14) {
            WidgetBluey(size: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(state.title).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                Text(state.caption.isEmpty ? (state.isCall ? (state.sharingScreen ? "Bluey sieht deinen Bildschirm." : "Sprich einfach los.") : "Tippen und zeigen, was du vorhast.") : state.caption)
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.7)).lineLimit(2)
            }
            Spacer()
            if let started = state.callStarted, state.isCall {
                Text(started, style: .timer).monospacedDigit().font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 56, alignment: .trailing)
            } else {
                Image(systemName: "phone.fill")
                    .font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44).background(Color(hex: 0x34C759), in: Circle())
            }
        }
        .padding(16)
    }
}

// MARK: Pomodoro

private let focusRed = Color(hex: 0xE5547A)
private let breakGreen = Color(hex: 0x5BE49B)

/// Countdown that keeps running on the Lock Screen by itself (the app may be asleep).
private struct PomodoroClock: View {
    var state: BlueyPomodoroAttributes.ContentState
    var size: CGFloat
    var body: some View {
        Group {
            if let interval = state.interval {
                Text(timerInterval: interval, countsDown: true)
            } else {
                Text(Duration.seconds(state.remaining).formatted(.time(pattern: .minuteSecond)))
            }
        }
        .monospacedDigit()
        .font(.system(size: size, weight: .bold, design: .rounded))
        .foregroundStyle(.white)
    }
}

private struct PomodoroBar: View {
    var state: BlueyPomodoroAttributes.ContentState
    var body: some View {
        let tint = state.isBreak ? breakGreen : focusRed
        if let interval = state.interval {
            ProgressView(timerInterval: interval, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                .progressViewStyle(.linear).tint(tint)
        } else {
            ProgressView(value: max(0, min(1, 1 - state.remaining / max(state.duration, 1))))
                .progressViewStyle(.linear).tint(tint.opacity(0.6))
        }
    }
}

struct BlueyPomodoroLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BlueyPomodoroAttributes.self) { context in
            PomodoroLockScreen(state: context.state, stale: context.isStale)
                .activityBackgroundTint(Color.black.opacity(0.75))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "bluey://pomodoro"))
        } dynamicIsland: { context in
            let state = context.state
            let tint = state.isBreak ? breakGreen : focusRed
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    WidgetBluey(size: 44).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    PomodoroClock(state: state, size: 26).frame(width: 84, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
                        Text(state.todo).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    PomodoroBar(state: state).padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: state.isBreak ? "cup.and.saucer.fill" : "timer").foregroundStyle(tint)
            } compactTrailing: {
                PomodoroClock(state: state, size: 13).frame(maxWidth: 46)
            } minimal: {
                Image(systemName: state.isBreak ? "cup.and.saucer.fill" : "timer").foregroundStyle(tint)
            }
            .widgetURL(URL(string: "bluey://pomodoro"))
        }
    }
}

private struct PomodoroLockScreen: View {
    var state: BlueyPomodoroAttributes.ContentState
    var stale: Bool
    var body: some View {
        let tint = state.isBreak ? breakGreen : focusRed
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                WidgetBluey(size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(stale ? "Runde vorbei" : state.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
                    Text(state.todo).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white).lineLimit(2)
                }
                Spacer()
                PomodoroClock(state: state, size: 30)
            }
            PomodoroBar(state: state)
            HStack(spacing: 4) {
                ForEach(0..<max(state.roundsPerLongBreak, 1), id: \.self) { i in
                    Circle().fill(i < state.round % max(state.roundsPerLongBreak, 1) ? focusRed : Color.white.opacity(0.2)).frame(width: 7, height: 7)
                }
                Spacer()
                Text(stale ? "Tippen, um weiterzumachen" : state.isBreak ? "Kurz durchatmen." : "Nur diese eine Sache.")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(16)
    }
}
