import SwiftUI
import WebKit

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
        let remoteIDs = Set(hub.sessions.map(\.id))
        let pending = hub.pendingSessions.values.filter { !remoteIDs.contains($0.id) }
        let drafts = hub.draftSessions.values.filter { !remoteIDs.contains($0.id) && hub.pendingSessions[$0.id] == nil }
        return (drafts + pending + hub.sessions).filter { session in
            (showJournals || !session.isJournal)
                && (search.isEmpty || session.title.localizedCaseInsensitiveContains(search)
                    || session.preview.localizedCaseInsensitiveContains(search))
        }
        .sorted { $0.lastActive > $1.lastActive }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                T3Header(title: "Chats", subtitle: hub.online ? nil : (hub.problem ?? "Verbindung zum Hub wird aufgebaut …"), openDrawer: openDrawer) {
                    Menu {
                        Toggle("Tagesjournale anzeigen", isOn: $showJournals)
                        Button("Aktualisieren") { Task { await hub.refreshSessions() } }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease")
                            .font(.system(size: 16, weight: .semibold)).foregroundStyle(T3.icon)
                            .frame(width: 38, height: 38).background(Circle().fill(T3.subtle))
                            .overlay(Circle().stroke(T3.border, lineWidth: 1))
                    }
                }
                T3SearchField(text: $search, placeholder: "Chats suchen").padding(.bottom, 8)
                if shown.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(shown) { s in
                            let draft = hub.draftSessions[s.id] != nil && hub.pendingSessions[s.id] == nil
                            Button { open = ChatTarget(id: s.id, title: s.title, writable: s.writable, fresh: draft) } label: {
                                ThreadRow(session: s, running: hub.pendingSessions[s.id] != nil, draft: draft)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                if draft {
                                    Button("Entwurf verwerfen", role: .destructive) { hub.discardDraft(s.id) }
                                }
                            }
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
                    open = ChatTarget(id: hub.newSessionID(), title: "Neuer Chat", writable: true, fresh: true)
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 20, weight: .semibold)).foregroundStyle(T3.primaryForeground)
                        .frame(width: 56, height: 56)
                        .background(Circle().fill(T3.primary))
                        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Neuer Chat")
                .padding(20)
            }
            .navigationDestination(item: $open) { target in
                ThreadDetailView(hub: hub, conversation: hub.conversation(for: target.id, fresh: target.fresh), title: target.title, writable: target.writable,
                                 fresh: target.fresh, openBrowser: openBrowser)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 30)).foregroundStyle(T3.iconMuted)
            Text(hub.config == nil ? "Hub verbinden" : "Noch keine Chats").t3Text(.lg, .medium)
            Text(hub.config == nil ? "Hinterlege Hub-Adresse und Schlüssel in den Einstellungen."
                                   : "Starte einen Chat mit Hermes.")
                .t3Text(.sm, color: T3.foregroundSecondary).multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ThreadRow: View {
    let session: HermesSession
    let running: Bool
    let draft: Bool

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
                    if running {
                        ProgressView().controlSize(.mini).accessibilityLabel("Hermes arbeitet")
                    } else {
                        Text(T3Time.short(session.lastActive)).t3Text(.xs, color: T3.foregroundTertiary)
                    }
                }
                Text(draft ? "Entwurf" : (session.preview.isEmpty ? sourceLabel : session.preview))
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
    @ObservedObject var conversation: HubThreadConversation
    let title: String
    let writable: Bool
    let fresh: Bool
    var openBrowser: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var showHermesScreen = false
    @State private var showModels = false

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if conversation.loading && !fresh { ProgressView().frame(maxWidth: .infinity).padding(.top, 40) }
                        if fresh && conversation.messages.isEmpty && conversation.runID == nil {
                            VStack(spacing: 8) {
                                MiniKeramikBadge().scaleEffect(1.4).padding(.bottom, 8)
                                Text("Wobei kann Hermes dir helfen?").t3Text(.lg, .medium)
                                Text("Nachrichten, Browser, Kalender, Notizen und Aufgaben.").t3Text(.sm, color: T3.foregroundSecondary)
                            }
                            .frame(maxWidth: .infinity).padding(.top, 80)
                        }
                        ForEach(conversation.messages) { m in MessageView(message: m, openBrowser: openBrowser) }
                        if conversation.runID != nil {
                            if let liveTool = conversation.liveTool { HermesLiveToolRow(tool: liveTool) { showHermesScreen = true } }
                            else if let activity = conversation.activity { ToolActivityRow(text: activity, running: true) }
                            if !conversation.streaming.isEmpty { MessageView(message: HermesMessage(id: "live", role: .assistant, text: conversation.streaming), openBrowser: openBrowser) }
                            ForEach(conversation.prompts) { p in approvalCard(p) }
                            if conversation.streaming.isEmpty && conversation.activity == nil { HubTypingDots() }
                        }
                        if let error = conversation.error { Text(error).t3Text(.sm, color: T3.dangerForeground).padding(12)
                            .background(RoundedRectangle(cornerRadius: 12).fill(T3.danger)) }
                        Color.clear.frame(height: 4).id("bottom")
                    }
                    .padding(.horizontal, 16).padding(.top, 8)
                }
                .scrollDismissesKeyboard(.interactively)
                .simultaneousGesture(TapGesture().onEnded { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) })
                .onChange(of: conversation.messages.count) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: conversation.streaming) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: conversation.prompts.count) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            if writable {
                Button { showModels = true } label: {
                    HStack(spacing: 6) {
                        HermesModelIcon(size: 17)
                        Text(conversation.options.model ?? "Hermes").t3Text(.sm, .medium).lineLimit(1)
                        if let thinking = conversation.options.thinking {
                            Text(thinking.title).t3Text(.xs, color: T3.foregroundSecondary)
                        }
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .background(Theme.raised, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.line))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .sheet(isPresented: $showModels) {
                    ChatModelPicker(activeModel: .constant("hermes"), options: $conversation.options,
                                    loadHermesModels: { try await hub.modelCatalog() })
                        .presentationDetents([.large])
                }
                T3Composer(text: $conversation.draft, running: conversation.runID != nil || conversation.submitting,
                           send: conversation.send, stop: conversation.stop)
            } else {
                Text("Dieser Chat gehört zu einer anderen App (\(title)) und ist hier schreibgeschützt.")
                    .t3Text(.xs, color: T3.foregroundSecondary).padding(12)
            }
        }
        .background(T3.screen.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task { await conversation.load(fresh: fresh) }
        .sheet(isPresented: $showHermesScreen) {
            HermesScreenView(request: try? hub.screenRequest(), hasApprovals: !conversation.prompts.isEmpty, activity: {
                if conversation.runID != nil {
                    WorkspaceHermesActivity(
                        title: conversation.prompts.isEmpty ? (conversation.activity ?? conversation.liveTool?.title ?? "Hermes arbeitet …") : "Wartet auf deine Antwort",
                        tool: conversation.liveTool,
                        stop: conversation.stop
                    )
                }
            }, approvals: {
                ForEach(conversation.prompts) { approvalCard($0) }
            })
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            T3IconButton(symbol: "chevron.left", label: "Zurück") { dismiss() }
            Text(conversation.messages.first(where: { $0.role == .user }).map { String($0.text.prefix(40)) } ?? title)
                .t3Text(.base, .medium).lineLimit(1)
            Spacer()
            T3IconButton(symbol: "display", label: "Hermes Live öffnen") {
                showHermesScreen = true
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(T3.separator).frame(height: 1) }
    }

    private func approvalCard(_ prompt: HermesPrompt) -> some View {
        WorkspaceHermesPromptCard(prompt: prompt) { choice in
            try await conversation.respond(to: prompt, choice: choice)
        }
    }
}

/// The Hub owns a conversation's live state while its chat and viewer come and go.
@MainActor
final class HubThreadConversation: ObservableObject {
    private weak var hub: HubClient?
    let sessionID: String
    private(set) var isLocalDraft: Bool
    @Published var draft = "" { didSet { hub?.updateDraft(self) } }
    @Published var options = HermesChatOptions() { didSet { hub?.updateDraft(self) } }
    @Published private(set) var messages: [HermesMessage] = []
    @Published private(set) var runID: String?
    @Published private(set) var streaming = ""
    @Published private(set) var activity: String?
    @Published private(set) var prompts: [HermesPrompt] = []
    @Published private(set) var error: String?
    @Published private(set) var loading = true
    @Published private(set) var liveTool: HermesLiveTool?
    @Published private(set) var submitting = false

    init(hub: HubClient, sessionID: String, fresh: Bool) {
        self.hub = hub
        self.sessionID = sessionID
        self.isLocalDraft = fresh
    }

    func load(fresh: Bool) async {
        defer { loading = false }
        guard !isLocalDraft, !fresh, !submitting, let hub else { return }
        do {
            let saved = try await hub.messages(of: sessionID)
            if !submitting, !Task.isCancelled { messages = saved }
        } catch {
            if !submitting, !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    func send() {
        let submittedDraft = draft
        let text = submittedDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, runID == nil, !submitting, let hub else { return }
        let selection = options
        submitting = true
        hub.markPending(self, text: text)
        draft = ""
        error = nil
        let optimistic = HermesMessage(id: "local-\(UUID())", role: .user, text: text)
        messages.append(optimistic)
        Task {
            defer {
                submitting = false
                hub.clearPending(self)
            }
            do {
                let id = try await hub.send(text, session: sessionID, options: selection)
                runID = id
                isLocalDraft = false
                hub.updateDraft(self)
                streaming = ""
                for try await event in hub.events(of: id) { handle(event, run: id) }
            } catch {
                self.error = error.localizedDescription
                if runID == nil {
                    draft = draft.isEmpty ? submittedDraft : submittedDraft + "\n\n" + draft
                    messages.removeAll { $0.id == optimistic.id }
                    return
                }
            }
            await finish(using: hub)
        }
    }

    private func handle(_ event: [String: Any], run: String) {
        switch event["event"] as? String ?? "" {
        case "message.delta":
            streaming += event["delta"] as? String ?? ""
            activity = nil
        case "tool.started":
            let tool = event["tool"] as? String ?? "a tool"
            liveTool = HermesLiveTool(tool: tool)
            let preview = (event["preview"] as? String).map { ": " + $0.prefix(80) } ?? ""
            activity = ToolActivityRow.label(tool) + preview
        case "tool.completed", "tool.failed":
            liveTool = nil
            activity = nil
        case "approval.request", "clarify.request":
            guard let hub else { return }
            Task {
                let pending = await hub.pending(of: run)
                if runID == run { prompts = pending }
            }
        case "run.failed":
            error = (event["error"] as? String) ?? "Hermes konnte den Auftrag nicht abschließen."
        default:
            break
        }
    }

    private func finish(using hub: HubClient) async {
        runID = nil
        liveTool = nil
        activity = nil
        prompts = []
        // Reload the stored thread so tool steps and the final answer show exactly as saved.
        if let saved = try? await hub.messages(of: sessionID), !saved.isEmpty { messages = saved }
        else if !streaming.isEmpty { messages.append(HermesMessage(id: "done-\(UUID())", role: .assistant, text: streaming)) }
        streaming = ""
        await hub.refreshSessions()
    }

    func stop() {
        guard let runID, let hub else { return }
        Task { await hub.stop(runID: runID) }
    }

    func respond(to prompt: HermesPrompt, choice: String) async throws {
        guard let runID, let hub else { throw HubError.refused(0, "Der Hermes-Lauf ist beendet.") }
        try await hub.respond(runID: runID, prompt: prompt, choice: choice)
        if self.runID == runID {
            prompts.removeAll { $0.id == prompt.id && $0.generation == prompt.generation }
        }
    }
}

struct HermesScreenView<Activity: View, Approvals: View>: View {
    let request: URLRequest?
    let hasApprovals: Bool
    @ViewBuilder var activity: () -> Activity
    @ViewBuilder var approvals: () -> Approvals
    @Environment(\.dismiss) private var dismiss
    @State private var detent: PresentationDetent = .medium
    @State private var connection = UUID()
    @State private var issue: String?

    var body: some View {
        GeometryReader { layout in
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("Hermes Live").font(.plexSans(16).weight(.semibold)).foregroundStyle(Theme.text)
                    Spacer()
                    T3IconButton(symbol: "arrow.clockwise", label: "Neu verbinden") {
                        issue = nil
                        connection = UUID()
                    }
                    T3IconButton(symbol: "xmark", label: "Hermes Live schließen") { dismiss() }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
                Divider().overlay(Theme.line)
                if let request, issue == nil {
                    HermesScreenWebView(request: request) { issue = $0 }
                        .id(connection)
                } else {
                    Text(issue ?? "Verbinde Bluey mit deinem Hub, um Hermes Live zu öffnen.")
                        .font(.plexSans(13)).foregroundStyle(Theme.soft)
                        .multilineTextAlignment(.center)
                        .padding(24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                activity()
                    .padding(.horizontal, 12)
                if hasApprovals {
                    Divider().overlay(Theme.line)
                    Text("Freigaben und Rückfragen")
                        .font(.plexSans(13).weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                    approvalList
                        .frame(maxHeight: min(270, layout.size.height * 0.38), alignment: .top)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }
            }
        }
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large], selection: $detent)
        .onChange(of: hasApprovals, initial: true) { _, waiting in
            if waiting { detent = .large }
        }
    }

    private var approvalList: some View {
        ViewThatFits(in: .vertical) {
            VStack(spacing: 8) { approvals() }
                .fixedSize(horizontal: false, vertical: true)
            ScrollView { VStack(spacing: 8) { approvals() } }
        }
    }
}

private struct HermesScreenWebView: UIViewRepresentable {
    let request: URLRequest
    let onIssue: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(request: request, onIssue: onIssue) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        HermesViewerPresentation.apply(to: config)
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.scrollView.bounces = false
        view.isOpaque = false
        view.backgroundColor = UIColor(Theme.background)
        view.underPageBackgroundColor = UIColor(Theme.background)
        view.load(request)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.evaluateJavaScript("window.dispatchEvent(new Event('pagehide'))")
        view.stopLoading()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let request: URLRequest
        let onIssue: (String) -> Void

        init(request: URLRequest, onIssue: @escaping (String) -> Void) {
            self.request = request
            self.onIssue = onIssue
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.targetFrame?.isMainFrame == true && action.request.url == request.url ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            guard let http = response.response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                decisionHandler(.cancel)
                onIssue("Der Hub konnte Hermes Live nicht öffnen. Prüfe die Bot-Desktop-Einrichtung.")
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { onIssue(error.localizedDescription) }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            onIssue("Der Live-Bildschirm wurde geschlossen. Tippe auf „Neu verbinden“.")
        }
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
        if t.contains("browser") || t.contains("web") || t.contains("navigate") { return "Browser verwendet" }
        if t.contains("terminal") || t.contains("shell") || t.contains("exec") { return "Befehl ausgeführt" }
        if t.contains("file") || t.contains("read") || t.contains("write") { return "Dateien bearbeitet" }
        if t.contains("memory") { return "Erinnerungen aktualisiert" }
        if t.contains("search") { return "Gesucht" }
        if t.contains("skill") { return "Skill verwendet" }
        return "\(tool) verwendet"
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
                TextField("Hermes fragen …", text: $text, axis: .vertical)
                    .lineLimit(1...6)
                    .accessibilityLabel("Nachricht")
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
                .accessibilityLabel(running ? "Stoppen" : "Senden")
                .padding(.trailing, 8).padding(.bottom, 6)
            }
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(T3.composerSurface))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(T3.composerBorder, lineWidth: 1))
        }
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 8)
        .background(T3.composerPanel.ignoresSafeArea(edges: .bottom))
    }
}
