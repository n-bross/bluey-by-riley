import SwiftUI

/// T3's home: the thread list. Here the threads are Hermes conversations.
struct ThreadsHomeView: View {
    @ObservedObject var hub: HubClient
    var openDrawer: () -> Void
    var openBrowser: (URL) -> Void
    @State private var search = ""
    @State private var open: ChatTarget?
    @State private var showJournals = false

    struct ChatTarget: Identifiable, Hashable {
        let id: String
        let title: String
        let writable: Bool
        let fresh: Bool
    }

    private var shown: [HermesSession] {
        hub.sessions.filter { s in
            (showJournals || !s.isJournal)
                && (search.isEmpty || s.title.localizedCaseInsensitiveContains(search) || s.preview.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                T3Header(title: "Threads", subtitle: hub.online ? nil : (hub.problem ?? "Connecting to your hub…"), openDrawer: openDrawer) {
                    Menu {
                        Toggle("Show daily journals", isOn: $showJournals)
                        Button("Refresh") { Task { await hub.refreshSessions() } }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease")
                            .font(.system(size: 16, weight: .semibold)).foregroundStyle(T3.icon)
                            .frame(width: 38, height: 38).background(Circle().fill(T3.subtle))
                            .overlay(Circle().stroke(T3.border, lineWidth: 1))
                    }
                }
                T3SearchField(text: $search, placeholder: "Search threads").padding(.bottom, 8)
                if shown.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(shown) { s in
                            Button { open = ChatTarget(id: s.id, title: s.title, writable: s.writable, fresh: false) } label: {
                                ThreadRow(session: s)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(T3.screen)
                            .listRowSeparatorTint(T3.separator)
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .refreshable { await hub.refreshSessions() }
                }
            }
            .background(T3.screen.ignoresSafeArea())
            .overlay(alignment: .bottomTrailing) {
                Button {
                    open = ChatTarget(id: hub.newSessionID(), title: "New chat", writable: true, fresh: true)
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 20, weight: .semibold)).foregroundStyle(T3.primaryForeground)
                        .frame(width: 56, height: 56)
                        .background(Circle().fill(T3.primary))
                        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New chat")
                .padding(20)
            }
            .navigationDestination(item: $open) { target in
                ThreadDetailView(hub: hub, sessionID: target.id, title: target.title, writable: target.writable,
                                 fresh: target.fresh, openBrowser: openBrowser)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 30)).foregroundStyle(T3.iconMuted)
            Text(hub.config == nil ? "Connect your hub" : "No threads yet").t3Text(.lg, .medium)
            Text(hub.config == nil ? "Open Settings in the menu and add your hub's address and key."
                                   : "Start a chat with Hermes: messages, browser, notes, todos — from anywhere.")
                .t3Text(.sm, color: T3.foregroundSecondary).multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ThreadRow: View {
    let session: HermesSession

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(T3.iconMuted)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(T3.subtle))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(T3.border, lineWidth: 1))
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(session.title).t3Text(.base, .medium).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(T3Time.short(session.lastActive)).t3Text(.xs, color: T3.foregroundTertiary)
                }
                Text(session.preview.isEmpty ? sourceLabel : session.preview)
                    .t3Text(.sm, color: T3.foregroundSecondary).lineLimit(2)
            }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private var icon: String {
        switch session.source {
        case "discord": return "number"
        case "telegram": return "paperplane"
        case "cli", "tui": return "terminal"
        default: return session.isJournal ? "book.closed" : "bubble.left"
        }
    }

    private var sourceLabel: String { session.source == "api_server" ? "Hermes" : session.source.capitalized }
}

// MARK: - Thread

/// One conversation: T3's feed (your messages in bubbles, Hermes' answers as text, tool rows in between)
/// and the composer at the bottom.
struct ThreadDetailView: View {
    @ObservedObject var hub: HubClient
    let sessionID: String
    let title: String
    let writable: Bool
    let fresh: Bool
    var openBrowser: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var messages: [HermesMessage] = []
    @State private var draft = ""
    @State private var runID: String?
    @State private var streaming = ""
    @State private var activity: String?
    @State private var prompts: [HermesPrompt] = []
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if loading && !fresh { ProgressView().frame(maxWidth: .infinity).padding(.top, 40) }
                        if fresh && messages.isEmpty && runID == nil {
                            VStack(spacing: 8) {
                                MiniKeramikBadge().scaleEffect(1.4).padding(.bottom, 8)
                                Text("What can Hermes do for you?").t3Text(.lg, .medium)
                                Text("Messages, browser, calendar, notes and todos.").t3Text(.sm, color: T3.foregroundSecondary)
                            }
                            .frame(maxWidth: .infinity).padding(.top, 80)
                        }
                        ForEach(messages) { m in MessageView(message: m, openBrowser: openBrowser) }
                        if runID != nil {
                            if let activity { ToolActivityRow(text: activity, running: true) }
                            if !streaming.isEmpty { MessageView(message: HermesMessage(id: "live", role: .assistant, text: streaming), openBrowser: openBrowser) }
                            ForEach(prompts) { p in approvalCard(p) }
                            if streaming.isEmpty && activity == nil { HubTypingDots() }
                        }
                        if let error { Text(error).t3Text(.sm, color: T3.dangerForeground).padding(12)
                            .background(RoundedRectangle(cornerRadius: 12).fill(T3.danger)) }
                        Color.clear.frame(height: 4).id("bottom")
                    }
                    .padding(.horizontal, 16).padding(.top, 8)
                }
                .scrollDismissesKeyboard(.interactively)
                .simultaneousGesture(TapGesture().onEnded { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) })
                .onChange(of: messages.count) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: streaming) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: prompts.count) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            if writable {
                T3Composer(text: $draft, running: runID != nil, send: send, stop: stop)
            } else {
                Text("This thread lives in another app (\(title)). Read-only here.")
                    .t3Text(.xs, color: T3.foregroundSecondary).padding(12)
            }
        }
        .background(T3.screen.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task { await load() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            T3IconButton(symbol: "chevron.left", label: "Back") { dismiss() }
            Text(messages.first(where: { $0.role == .user }).map { String($0.text.prefix(40)) } ?? title)
                .t3Text(.base, .medium).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(T3.separator).frame(height: 1) }
    }

    private func load() async {
        defer { loading = false }
        guard !fresh else { return }
        do { messages = try await hub.messages(of: sessionID) } catch { self.error = error.localizedDescription }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, runID == nil else { return }
        draft = ""
        error = nil
        messages.append(HermesMessage(id: "local-\(UUID())", role: .user, text: text))
        Task {
            do {
                let id = try await hub.send(text, session: sessionID)
                runID = id
                streaming = ""
                for try await event in hub.events(of: id) { handle(event, run: id) }
            } catch {
                self.error = error.localizedDescription
            }
            await finish()
        }
    }

    private func handle(_ event: [String: Any], run: String) {
        switch event["event"] as? String ?? "" {
        case "message.delta":
            streaming += event["delta"] as? String ?? ""
            activity = nil
        case "tool.started":
            let tool = event["tool"] as? String ?? "a tool"
            let preview = (event["preview"] as? String).map { ": " + $0.prefix(80) } ?? ""
            activity = ToolActivityRow.label(tool) + preview
        case "tool.completed":
            activity = nil
        case "approval.request", "clarify.request":
            Task { prompts = await hub.pending(of: run) }
        case "run.failed":
            error = (event["error"] as? String) ?? "Hermes couldn't finish this."
        default:
            break
        }
    }

    private func finish() async {
        runID = nil
        activity = nil
        prompts = []
        // Reload the stored thread so tool steps and the final answer show exactly as saved.
        if let saved = try? await hub.messages(of: sessionID), !saved.isEmpty { messages = saved }
        else if !streaming.isEmpty { messages.append(HermesMessage(id: "done-\(UUID())", role: .assistant, text: streaming)) }
        streaming = ""
        await hub.refreshSessions()
    }

    private func stop() {
        guard let runID else { return }
        Task { await hub.stop(runID: runID) }
    }

    private func approvalCard(_ prompt: HermesPrompt) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(prompt.kind == .approval ? "Hermes wants to run" : "Hermes asks",
                  systemImage: prompt.kind == .approval ? "exclamationmark.shield" : "questionmark.bubble")
                .t3Text(.sm, .medium, color: T3.warningForeground)
            Text(prompt.text).font(prompt.kind == .approval ? T3.mono(.xs) : T3.font(.base)).foregroundStyle(T3.foreground)
            HStack {
                ForEach(prompt.kind == .approval ? prompt.choices : (prompt.choices.isEmpty ? [] : prompt.choices), id: \.self) { choice in
                    Button(prompt.kind == .approval ? HermesPrompt.choiceTitle(choice) : choice) {
                        guard let runID else { return }
                        Task { try? await hub.respond(runID: runID, prompt: prompt, choice: choice); prompts.removeAll { $0.id == prompt.id } }
                    }
                    .font(T3.font(.sm, .medium))
                    .padding(.horizontal, 12).frame(height: 32)
                    .background(Capsule().fill(choice == "deny" ? T3.danger : T3.primary))
                    .foregroundStyle(choice == "deny" ? T3.dangerForeground : T3.primaryForeground)
                }
            }
            if prompt.kind == .clarify { Text("Or type your answer below.").t3Text(.xs, color: T3.foregroundSecondary) }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(T3.warning))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(T3.warningForeground.opacity(0.3), lineWidth: 1))
    }
}

/// One message in T3's style.
struct MessageView: View {
    let message: HermesMessage
    var openBrowser: (URL) -> Void

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 48)
                Text(message.text).t3Text(.base, color: T3.userBubbleForeground)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(T3.userBubble))
                    .textSelection(.enabled)
            }
        case .assistant:
            HubMarkdownText(text: message.text, openBrowser: openBrowser)
        case .tool:
            ToolActivityRow(text: ToolActivityRow.label(message.toolName ?? "tool"), running: false)
        case .system:
            EmptyView()
        }
    }
}

/// T3's compact work rows ("Ran terminal", "Browsed the web").
struct ToolActivityRow: View {
    let text: String
    let running: Bool

    static func label(_ tool: String) -> String {
        let t = tool.lowercased()
        if t.contains("browser") || t.contains("web") || t.contains("navigate") { return "Browsing" }
        if t.contains("terminal") || t.contains("shell") || t.contains("exec") { return "Ran a command" }
        if t.contains("file") || t.contains("read") || t.contains("write") { return "Worked with files" }
        if t.contains("memory") { return "Updated memory" }
        if t.contains("search") { return "Searched" }
        if t.contains("skill") { return "Used a skill" }
        return "Used \(tool)"
    }

    var body: some View {
        HStack(spacing: 8) {
            if running { ProgressView().controlSize(.mini) } else {
                Image(systemName: "checkmark.circle").font(.system(size: 12, weight: .semibold)).foregroundStyle(T3.iconMuted)
            }
            Text(text).t3Text(.xs, color: T3.foregroundSecondary).lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}

struct HubTypingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.2)) { ctx in
            let phase = Int(ctx.date.timeIntervalSinceReferenceDate * 3) % 3
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(T3.iconMuted.opacity(i == phase ? 1 : 0.35)).frame(width: 6, height: 6)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

/// Markdown like T3's feed: paragraphs with inline formatting and links, code blocks in cards.
struct HubMarkdownText: View {
    let text: String
    var openBrowser: (URL) -> Void

    private struct Block: Identifiable { let id: Int; let code: Bool; let text: String }

    private var blocks: [Block] {
        var out: [Block] = []
        var code = false
        var buffer: [String] = []
        func flush(_ isCode: Bool) {
            let t = buffer.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !t.isEmpty { out.append(Block(id: out.count, code: isCode, text: t)) }
            buffer = []
        }
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { flush(code); code.toggle(); continue }
            buffer.append(line)
        }
        flush(code)
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks) { b in
                if b.code {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(b.text).font(T3.mono(.xs)).foregroundStyle(T3.foreground).padding(12)
                    }
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(T3.card))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(T3.border, lineWidth: 1))
                } else {
                    Text(attributed(b.text)).t3Text(.base).textSelection(.enabled)
                        .tint(T3.primaryText)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in
            openBrowser(url)
            return .handled
        })
    }

    private func attributed(_ text: String) -> AttributedString {
        // Headings and bullets read fine as text; inline bold/italic/code/links get rendered.
        let cleaned = text.replacingOccurrences(of: #"(?m)^#{1,6}\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^\s*[-*]\s+"#, with: "• ", options: .regularExpression)
        return (try? AttributedString(markdown: cleaned, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(cleaned)
    }
}

/// T3's composer: a rounded panel with the text field and a round send / stop button.
struct T3Composer: View {
    @Binding var text: String
    let running: Bool
    let send: () -> Void
    let stop: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask Hermes…", text: $text, axis: .vertical)
                    .lineLimit(1...6)
                    .accessibilityLabel("Message")
                    .font(T3.font(.base))
                    .foregroundStyle(T3.foreground)
                    .focused($focused)
                    .padding(.vertical, 10)
                    .padding(.leading, 14)
                Button(action: running ? stop : send) {
                    Image(systemName: running ? "stop.fill" : "arrow.up")
                        .font(.system(size: running ? 12 : 15, weight: .bold))
                        .foregroundStyle(T3.primaryForeground)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(running || !text.trimmingCharacters(in: .whitespaces).isEmpty ? T3.primary : T3.iconMuted.opacity(0.4)))
                }
                .buttonStyle(.plain)
                .disabled(!running && text.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityLabel(running ? "Stop" : "Send")
                .padding(.trailing, 8).padding(.bottom, 6)
            }
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(T3.composerSurface))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(T3.composerBorder, lineWidth: 1))
        }
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 8)
        .background(T3.composerPanel.ignoresSafeArea(edges: .bottom))
    }
}
