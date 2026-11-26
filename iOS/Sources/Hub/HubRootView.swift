import SwiftUI

/// The hub: Bluey's phone app without the Mac, in T3 Code's mobile design.
/// A drawer on the left (Threads, Todos, Notes, Browser, Bluey, Settings) and the section on the right.
struct HubRootView: View {
    enum Section: String, CaseIterable, Identifiable {
        case threads, todos, notes, browser
        var id: String { rawValue }
        var title: String {
            switch self {
            case .threads: return "Chats"
            case .todos: return "Todos"
            case .notes: return "Notizen"
            case .browser: return "Browser"
            }
        }
        var symbol: String {
            switch self {
            case .threads: return "bubble.left.and.bubble.right"
            case .todos: return "checklist"
            case .notes: return "note.text"
            case .browser: return "safari"
            }
        }
    }

    @ObservedObject var hub: HubClient
    var openBluey: () -> Void
    @State private var section: Section = .threads
    @State private var drawer = false
    @State private var settings = false
    @State private var browserURL: URL?

    var body: some View {
        ZStack(alignment: .leading) {
            Group {
                switch section {
                case .threads: ThreadsHomeView(hub: hub, openDrawer: openDrawer, openBrowser: openBrowser)
                case .todos: TodosView(hub: hub, openDrawer: openDrawer)
                case .notes: NotesView(hub: hub, openDrawer: openDrawer)
                case .browser: HubBrowserView(hub: hub, openDrawer: openDrawer, start: browserURL)
                }
            }
            .disabled(drawer)

            if drawer {
                Color.black.opacity(0.35).ignoresSafeArea()
                    .onTapGesture { withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { drawer = false } }
                    .transition(.opacity)
                sidebar
                    .transition(.move(edge: .leading))
            }
        }
        .background(T3.screen.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .tint(Theme.accentLight)
        .sheet(isPresented: $settings) { HubSettingsView(hub: hub) }
        .onAppear {
            OrientationLock.set(.portrait)
            hub.startPolling()
            Task { await hub.refreshAll() }
            if hub.config == nil { settings = true }
        }
        .onDisappear { hub.stopPolling() }
    }

    private func openDrawer() { withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { drawer = true } }

    private func openBrowser(_ url: URL) {
        browserURL = url
        section = .browser
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                MiniKeramikBadge()
                VStack(alignment: .leading, spacing: 1) {
                    Text("Bluey").t3Text(.lg, .bold, color: T3.drawerForeground)
                    HStack(spacing: 5) {
                        Circle().fill(hub.online ? T3.success : T3.drawerForegroundMuted).frame(width: 6, height: 6)
                        Text(hub.online ? "Hub verbunden" : (hub.config == nil ? "Nicht eingerichtet" : "Offline"))
                            .t3Text(.xs2, color: T3.drawerForegroundMuted)
                    }
                }
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 22)

            ForEach(Section.allCases) { s in
                Button {
                    section = s
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { drawer = false }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: s.symbol).font(.system(size: 16, weight: .medium)).frame(width: 22)
                        Text(s.title).t3Text(.base, .medium, color: T3.drawerForeground)
                        Spacer()
                        if s == .todos, openTodos > 0 {
                            Text("\(openTodos)").t3Text(.xs2, .medium, color: T3.drawerForegroundMuted)
                        }
                    }
                    .foregroundStyle(T3.drawerForeground)
                    .padding(.horizontal, 14).frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(section == s ? T3.rowActive : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
            }

            Rectangle().fill(T3.drawerBorder).frame(height: 1).padding(.vertical, 12)

            drawerRow("Zu Bluey", "arrow.uturn.backward") {
                drawer = false
                openBluey()
            }
            drawerRow("Einstellungen", "gearshape") { drawer = false; settings = true }
            Spacer()
        }
        .frame(width: 290)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(T3.drawer.ignoresSafeArea())
        .overlay(alignment: .trailing) { Rectangle().fill(T3.drawerBorder).frame(width: 1).ignoresSafeArea() }
    }

    private var openTodos: Int { hub.todos.filter { !$0.done }.count }

    private func drawerRow(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 16, weight: .medium)).frame(width: 22)
                Text(title).t3Text(.base, .medium, color: T3.drawerForeground)
                Spacer()
            }
            .foregroundStyle(T3.drawerForeground)
            .padding(.horizontal, 14).frame(height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }
}

/// A tiny Keramik head for the drawer header.
struct MiniKeramikBadge: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white)
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Color(white: 0.82), lineWidth: 1))
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(white: 0.11)).padding(5)
            HStack(spacing: 5) {
                ForEach(0..<2, id: \.self) { _ in Capsule().fill(Color.white).frame(width: 4, height: 8) }
            }
        }
        .frame(width: 36, height: 34)
    }
}

/// T3's screen header: drawer button, large title, trailing actions.
struct T3Header<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var openDrawer: () -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                T3IconButton(symbol: "sidebar.left", label: "Menü", action: openDrawer)
                Spacer()
                trailing
            }
            Text(title).t3Text(.xl3, .bold)
            if let subtitle { Text(subtitle).t3Text(.sm, color: T3.foregroundSecondary) }
        }
        .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 8)
    }
}

struct T3IconButton: View {
    let symbol: String
    let label: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(prominent ? T3.primaryForeground : T3.icon)
                .frame(width: 44, height: 44)
                .background(Circle().fill(prominent ? T3.primary : T3.subtle))
                .overlay(Circle().stroke(prominent ? Color.clear : T3.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// T3's search field (the mail-style toolbar search).
struct T3SearchField: View {
    @Binding var text: String
    var placeholder = "Search"

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .medium)).foregroundStyle(T3.iconMuted)
            TextField(placeholder, text: $text).font(T3.font(.base)).foregroundStyle(T3.foreground)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(T3.iconMuted) }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(T3.input))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(T3.inputBorder, lineWidth: 1))
        .padding(.horizontal, 16)
    }
}

/// Relative time like T3's list ("jetzt", "5m", "3h", "Tue", "12 Nov").
enum T3Time {
    static func short(_ date: Date) -> String {
        let s = Date().timeIntervalSince(date)
        if s < 60 { return "jetzt" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86400 { return "\(Int(s / 3600))h" }
        if s < 6 * 86400 { return date.formatted(.dateTime.weekday(.abbreviated)) }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}
