import SwiftUI
#if canImport(GooglyShared)
import GooglyShared
#endif

/// Screen-wide UI state shared by the header, the floating tab bar and the tabs:
/// the search text, the "new" button and whether a detail screen (chat, note) is open.
@MainActor
final class WorkspaceUI: ObservableObject {
    @Published var search = ""
    @Published var searching = false
    /// Bumped by the round "new" button; the visible tab reacts (new chat, new todo, new note…).
    @Published var composeCount = 0
    /// True while a chat or note is open full screen; the tab bar steps aside.
    @Published var inDetail = false
    /// A tab asks to show another one (e.g. a todo starts a pomodoro).
    @Published var requestedTab: WorkspaceTab?

    func endSearch() { search = ""; searching = false }

    /// Matches every word of the search, case and accent insensitive.
    func matches(_ texts: String...) -> Bool {
        let words = search.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return true }
        let haystack = texts.joined(separator: " ")
        return words.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

extension WorkspaceTab {
    var searchable: Bool { self == .chat || self == .todos || self == .notes }
    var composeIcon: String? {
        switch self {
        case .chat, .notes: return "square.and.pencil"
        case .todos: return "plus"
        default: return nil
        }
    }
    var searchPrompt: String {
        switch self {
        case .chat: return "Chats durchsuchen"
        case .todos: return "Todos durchsuchen"
        case .notes: return "Notizen durchsuchen"
        default: return "Suchen"
        }
    }
}

/// The big title row, like T3 Code: title and status on the left, a round search button on the right.
struct TabHeader<Chips: View>: View {
    @ObservedObject var ui: WorkspaceUI
    @ObservedObject var model: WorkspaceModel
    var tab: WorkspaceTab
    var connectionName: String?
    var onSettings: () -> Void
    @ViewBuilder var chips: () -> Chips
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if ui.searching {
                searchField
            } else {
                titleRow
            }
            chips()
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .animation(.snappy(duration: 0.25), value: ui.searching)
    }

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tab.title)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                status
            }
            Spacer()
            GlassGroup(spacing: 10) {
                HStack(spacing: 10) {
                    #if os(macOS)
                    if let icon = tab.composeIcon {
                        GlassIconButton(icon: icon, label: "Neu", size: 44) { ui.composeCount += 1 }
                            .keyboardShortcut("n", modifiers: .command)
                    }
                    #endif
                    #if os(iOS)
                    GlassIconButton(icon: "gearshape", label: "Einstellungen", size: 44, action: onSettings)
                    #endif
                    if tab.searchable {
                        GlassIconButton(icon: "magnifyingglass", label: "Suchen", size: 56) {
                            ui.searching = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { searchFocused = true }
                        }
                        .keyboardShortcut("f", modifiers: .command)
                    }
                }
            }
        }
    }

    @ViewBuilder private var status: some View {
        let busy = model.snapshot.threads.contains(where: \.isStreaming)
        HStack(spacing: 6) {
            if !model.connected {
                ProgressView().controlSize(.mini).tint(Theme.soft)
                Text("Suche deinen Mac…")
            } else if busy {
                BlueyAvatar(mood: .thinking).frame(width: 16, height: 14)
                Text("Bluey schreibt…")
            } else {
                Circle().fill(Theme.green).frame(width: 7, height: 7)
                Text(connectionName ?? "Verbunden")
            }
        }
        .font(.plexSans(13))
        .foregroundStyle(Theme.soft)
        .lineLimit(1)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.soft)
                TextField(tab.searchPrompt, text: $ui.search)
                    .textFieldStyle(.plain)
                    .font(.plexSans(16))
                    .focused($searchFocused)
                    .submitLabel(.search)
                if !ui.search.isEmpty {
                    Button { ui.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.soft) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 56)
            .glassCapsule()
            Button("Fertig") { ui.endSearch() }
                .font(.plexSans(15).weight(.semibold))
                .foregroundStyle(Theme.accentLight)
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.top, 6)
    }
}

/// A rounded filter chip like T3's "All environments".
struct FilterChip: View {
    var title: String
    var selected = false
    var icon: String? = nil
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: 12, weight: .semibold)) }
                Text(title).font(.plexSans(15))
            }
            .foregroundStyle(selected ? .white : .white.opacity(0.75))
            .padding(.horizontal, 18)
            .frame(height: 42)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassCapsule(tint: selected ? Theme.blue.opacity(0.55) : nil)
    }
}

#if os(iOS)
/// The floating tab bar: Liquid Glass capsule with outline icons (filled and blue when selected),
/// and a round glass "new" button beside it, like T3 Code.
struct FloatingTabBar: View {
    @Binding var tab: WorkspaceTab
    @ObservedObject var ui: WorkspaceUI
    var openFace: (() -> Void)?
    @Namespace private var selection

    var body: some View {
        GlassGroup(spacing: 14) {
            HStack(spacing: 14) {
                HStack(spacing: 0) {
                    ForEach(WorkspaceTab.allCases) { item in
                        Button {
                            if item == .face, let openFace { openFace(); return }
                            if tab != item { ui.endSearch() }
                            withAnimation(.snappy(duration: 0.3)) { tab = item }
                        } label: {
                            ZStack {
                                if tab == item {
                                    Capsule().fill(Color.white.opacity(0.14)).matchedGeometryEffect(id: "selected", in: selection)
                                }
                                if item == .face {
                                    MiniBluey().frame(width: 30, height: 27)
                                } else {
                                    Image(systemName: tab == item ? item.selectedIcon : item.icon)
                                        .font(.system(size: 22, weight: .regular))
                                        .foregroundStyle(tab == item ? Theme.blue : .white)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(item.title)
                    }
                }
                .padding(5)
                .glassCapsule()

                if let icon = tab.composeIcon {
                    GlassIconButton(icon: icon, label: tab == .chat ? "Neuer Chat" : tab == .notes ? "Neue Notiz" : "Neues Todo", size: 64) {
                        ui.composeCount += 1
                    }
                    .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        .animation(.snappy(duration: 0.25), value: tab)
    }
}

/// While the keyboard is up: a small glass button that puts it away.
struct KeyboardDismissButton: View {
    @State private var visible = false
    var body: some View {
        Group {
            if visible {
                Button {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 40)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glassCapsule()
                .accessibilityLabel("Tastatur schließen")
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .animation(.snappy(duration: 0.2), value: visible)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in visible = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in visible = false }
    }
}
#endif
