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
    #if os(macOS)
    @Binding var showHermesScreen: Bool
    var openSettingsWindow: (() -> Void)?
    #endif
    @StateObject private var ui = WorkspaceUI()
    #if os(iOS)
    @State private var keyboardVisible = false
    #endif

    private var info: HeaderInfo { HeaderInfo(connectionName: connectionName, onSettings: openSettings) }

    private func openSettings() {
        #if os(macOS)
        if let openSettingsWindow { openSettingsWindow(); return }
        #endif
        showSettings = true
    }

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
                sectionRail
                Divider().overlay(Theme.line)
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            #endif
        }
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .tint(Theme.accentLight)
        .sheet(isPresented: $showSettings) { settings() }
        .onChange(of: tab) { _, next in
            ui.endSearch()
            ui.inDetail = false
            #if os(macOS)
            if next != .chat { showHermesScreen = false }
            #endif
        }
        .onChange(of: ui.requestedTab) { _, requested in
            guard let requested else { return }
            tab = requested
            ui.requestedTab = nil
        }
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .chat:
            #if os(macOS)
            ChatTab(model: model, ui: ui, info: info, liveScreen: $showHermesScreen)
            #else
            ChatTab(model: model, ui: ui, info: info)
            #endif
        case .todos: TodosTab(model: model, ui: ui, info: info)
        case .notes: NotesTab(model: model, ui: ui, info: info)
        case .pomodoro: PomodoroTab(model: model, ui: ui, info: info)
        case .stats: StatsTab(model: model, ui: ui, info: info)
        case .face: face()
        }
    }

    #if os(macOS)
    private var sectionRail: some View {
        VStack(spacing: 8) {
            MiniBluey().frame(width: 24, height: 22)
                .frame(height: 36)
                .accessibilityHidden(true)
            ForEach(WorkspaceTab.allCases) { item in
                Button { tab = item } label: {
                    Image(systemName: item.icon)
                        .frame(width: 32, height: 30)
                        .foregroundStyle(tab == item ? Theme.accentLight : Theme.soft)
                        .background(tab == item ? Theme.raised : .clear, in: RoundedRectangle(cornerRadius: 8))
                }
                .help(item.title)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(tab == item ? .isSelected : [])
            }
            Spacer()
            if let openMeetings {
                Button(action: openMeetings) {
                    Image(systemName: "waveform.and.mic").frame(width: 32, height: 30)
                }
                .help("Call-Notizen öffnen (⌃⌥M)").accessibilityLabel("Call-Notizen öffnen")
            }
            Button(action: openSettings) {
                Image(systemName: "gearshape").frame(width: 32, height: 30)
            }
            .help("Einstellungen").accessibilityLabel("Einstellungen")
        }
        .buttonStyle(.plain)
        .font(.system(size: 14))
        .foregroundStyle(Theme.soft)
        .padding(.vertical, 4)
        .frame(width: 46)
        .background(Theme.panel)
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
