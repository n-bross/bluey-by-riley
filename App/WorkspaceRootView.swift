import SwiftUI
#if canImport(GooglyShared)
import GooglyShared
#endif

enum WorkspaceTab: String, CaseIterable, Identifiable {
    case chat, todos, notes, pomodoro, stats, face
    var id: String { rawValue }
    var title: String {
        switch self {
        case .chat: return "Chat"
        case .todos: return "Todos"
        case .notes: return "Notizen"
        case .pomodoro: return "Pomodoro"
        case .stats: return "Statistik"
        case .face: return "Gesicht"
        }
    }
    var icon: String {
        switch self {
        case .chat: return "text.bubble"
        case .todos: return "checklist"
        case .notes: return "note.text"
        case .pomodoro: return "timer"
        case .stats: return "chart.bar.xaxis"
        case .face: return "face.smiling"
        }
    }
    var selectedIcon: String {
        switch self {
        case .chat: return "text.bubble.fill"
        case .todos: return "checklist.checked"
        case .notes: return "note.text"
        case .pomodoro: return "timer"
        case .stats: return "chart.bar.xaxis"
        case .face: return "face.smiling.inverse"
        }
    }
}

/// What every tab header needs from the root.
struct HeaderInfo {
    var connectionName: String?
    var onSettings: () -> Void
}

/// The Bluey app: chat, todos, notes, pomodoro, statistics and his face.
/// iPhone: large titles and a floating tab bar like T3 Code. Mac: a sidebar.
struct WorkspaceRootView<Face: View, Settings: View>: View {
    @ObservedObject var model: WorkspaceModel
    @Binding var tab: WorkspaceTab
    var connectionName: String?
    /// Optional Mac-only action to jump directly to the Call-Notizen window.
    var openMeetings: (() -> Void)? = nil
    /// The face tab in the Mac sidebar.
    @ViewBuilder var face: () -> Face
    @ViewBuilder var settings: () -> Settings
    @Binding var showSettings: Bool
    @StateObject private var ui = WorkspaceUI()
    #if os(iOS)
    @State private var keyboardVisible = false
    #endif

    private var info: HeaderInfo { HeaderInfo(connectionName: connectionName, onSettings: { showSettings = true }) }

    var body: some View {
        Group {
            #if os(iOS)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if !ui.inDetail && !keyboardVisible {
                        FloatingTabBar(tab: $tab, ui: ui)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.snappy(duration: 0.25), value: ui.inDetail)
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                    keyboardVisible = true
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                    keyboardVisible = false
                }
            #else
            HStack(spacing: 0) {
                sidebar
                Divider().overlay(Theme.line)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            #endif
        }
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .tint(Theme.accentLight)
        .sheet(isPresented: $showSettings) { settings() }
        .onChange(of: tab) { _, _ in ui.endSearch(); ui.inDetail = false }
        .onChange(of: ui.requestedTab) { _, requested in
            guard let requested else { return }
            tab = requested
            ui.requestedTab = nil
        }
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .chat: ChatTab(model: model, ui: ui, info: info)
        case .todos: TodosTab(model: model, ui: ui, info: info)
        case .notes: NotesTab(model: model, ui: ui, info: info)
        case .pomodoro: PomodoroTab(model: model, ui: ui, info: info)
        case .stats: StatsTab(model: model, ui: ui, info: info)
        case .face: face()
        }
    }

    #if os(macOS)
    private var sidebar: some View {
        let openTodos = model.snapshot.todos.count { !$0.deleted && !$0.done }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                BlueyAvatar(mood: model.snapshot.threads.contains(where: \.isStreaming) ? .thinking : .listening)
                    .frame(width: 44, height: 39)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bluey").font(.fredoka(24)).foregroundStyle(.white)
                    ConnectionDot(connected: model.connected, name: connectionName)
                }
            }
            .padding(.bottom, 16)
            ForEach(WorkspaceTab.allCases) { item in
                Button { tab = item } label: {
                    HStack(spacing: 10) {
                        if item == .face {
                            MiniBluey().frame(width: 20, height: 18)
                        } else {
                            Image(systemName: item.icon).frame(width: 20)
                        }
                        Text(item.title).font(.plexSans(14))
                        Spacer()
                        if item == .todos, openTodos > 0 {
                            Text("\(openTodos)").font(.plexMono(11)).foregroundStyle(Theme.soft)
                        }
                        if item == .pomodoro, model.pomodoro.isRunning {
                            Circle().fill(model.pomodoro.phase == .focus ? Theme.red : Theme.green).frame(width: 7, height: 7)
                        }
                    }
                    .foregroundStyle(tab == item ? .white : Theme.soft)
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(tab == item ? Theme.cardStrong : .clear, in: RoundedRectangle(cornerRadius: 9))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if let openMeetings {
                Button(action: openMeetings) {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform.and.mic").frame(width: 20)
                        Text("Call-Notizen").font(.plexSans(13.5))
                        Spacer()
                        Text("⌃⌥M").font(.plexMono(10)).foregroundStyle(Theme.soft.opacity(0.7))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 9))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 6)
            }
            Button { showSettings = true } label: {
                Label("Einstellungen", systemImage: "gearshape").font(.plexSans(13)).foregroundStyle(Theme.soft)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(width: 210)
        .frame(maxHeight: .infinity)
        .background(Theme.panel.opacity(0.6))
    }
    #endif
}

struct ConnectionDot: View {
    var connected: Bool
    var name: String?
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(connected ? Theme.green : Theme.soft.opacity(0.5)).frame(width: 6, height: 6)
            Text(connected ? (name ?? "Verbunden") : "Mac nicht verbunden")
                .font(.plexSans(11))
                .foregroundStyle(Theme.soft)
                .lineLimit(1)
        }
    }
}
