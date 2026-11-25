import SwiftUI
import PhotosUI
import WebKit
import UniformTypeIdentifiers
#if canImport(GooglyShared)
import GooglyShared
#endif

/// Chat with Bluey, like T3 Code: threads, a composer with attachments, model picker and web search.
struct ChatTab: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var ui: WorkspaceUI
    var info: HeaderInfo
    #if os(macOS)
    @Binding var liveScreen: Bool
    @State private var showThreadList = true
    private var selected: UUID? {
        get { model.selectedWorkspaceThread }
        nonmutating set { model.selectedWorkspaceThread = newValue }
    }
    #else
    @State private var selected: UUID?
    #endif
    @State private var composingNew = false
    @State private var modelFilter: String?

    private func matchingThreads(in visibleThreads: [ChatThread]) -> [ChatThread] {
        let searchActive = ui.search.contains { $0 != " " }
        return visibleThreads.filter { thread in
            guard modelFilter == nil || thread.model == modelFilter else { return false }
            return !searchActive || ui.matches(thread.title, thread.messages.suffix(20).map(\.text).joined(separator: " "))
        }
    }

    var body: some View {
        #if os(iOS)
        NavigationStack {
            VStack(spacing: 0) {
                header
                threadList
            }
            .background(Theme.background)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: Binding(get: { selected != nil || composingNew },
                                                        set: { if !$0 { selected = nil; composingNew = false } })) {
                ConversationView(model: model, threadID: $selected, focusOnAppear: composingNew)
                    .toolbarBackground(Theme.panel, for: .navigationBar)
                    .onAppear { ui.inDetail = true }
                    .onDisappear { ui.inDetail = false }
            }
        }
        .onChange(of: ui.composeCount) { _, _ in newChat() }
        #else
        GeometryReader { layout in
            let sidebarBlockedByWidth = liveScreen && layout.size.width < 920
            let showSidebar = showThreadList && !sidebarBlockedByWidth
            HSplitView {
                if showSidebar {
                    VStack(spacing: 0) {
                        macSidebarHeader
                        macSearchBar
                        threadList
                        Spacer(minLength: 0)
                    }
                    .frame(minWidth: 200, idealWidth: 245, maxWidth: 340, maxHeight: .infinity)
                    .background(Theme.panel)
                }
                ConversationView(model: model, threadID: $model.selectedWorkspaceThread, composeCount: ui.composeCount,
                                 leadingControls: showSidebar ? nil : AnyView(sidebarToggle(hiddenForWidth: sidebarBlockedByWidth)),
                                 layoutControls: AnyView(macLayoutControls))
                    .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                if liveScreen {
                    MacHermesScreenPane(model: model, close: { liveScreen = false }, move: model.detachHermesScreen)
                        .frame(minWidth: 260, idealWidth: 360, maxWidth: 540)
                }
            }
        }
        .onChange(of: ui.composeCount) { _, _ in newChat() }
        #endif
    }

    #if os(macOS)
    private func sidebarToggle(hiddenForWidth: Bool = false) -> some View {
        layoutButton("Chats", symbol: "sidebar.left", selected: showThreadList && !hiddenForWidth) {
            if hiddenForWidth {
                showThreadList = true
                liveScreen = false
            } else { showThreadList.toggle() }
        }
    }

    private var macSidebarHeader: some View {
        WorkspacePaneHeader(title: "Chats", leading: { sidebarToggle() }, actions: {})
    }

    private var macSearchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.soft)
            TextField("Chats suchen", text: $ui.search).textFieldStyle(.plain)
            Button { ui.composeCount += 1 } label: { Image(systemName: "square.and.pencil") }
                .help("Neuer Chat").accessibilityLabel("Neuer Chat")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
    }

    private var macLayoutControls: some View {
        HStack(spacing: 5) {
            layoutButton("Live-Bildschirm", symbol: "display", selected: liveScreen || model.hermesScreenDetached) {
                if liveScreen { liveScreen = false }
                else { model.openHermesScreen?(selected) }
            }
            .overlay(alignment: .topTrailing) {
                if let thread = model.hermesScreenThread(), model.screenTool(for: thread) != nil {
                    Circle().fill(Theme.green).frame(width: 6, height: 6).allowsHitTesting(false)
                }
            }
        }
    }

    private func layoutButton(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 29, height: 28)
                .background(selected ? Theme.raised : .clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
    #endif

    private func newChat() {
        ui.endSearch()
        selected = nil
        composingNew = true
    }

    private var header: some View {
        TabHeader(ui: ui, model: model, tab: .chat, connectionName: info.connectionName, onSettings: info.onSettings) {
            let usedModels = Array(Set(model.snapshot.threads.lazy.filter { !$0.deleted }.map(\.model))).sorted()
            if usedModels.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Menu {
                            Button("Alle Modelle") { modelFilter = nil }
                            ForEach(usedModels, id: \.self) { id in
                                Button(model.models.first { $0.id == id }?.name ?? id) { modelFilter = id }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text(modelFilter.map { id in model.models.first { $0.id == id }?.name ?? id } ?? "Alle Modelle")
                                Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                            }
                            .font(.plexSans(15))
                            .foregroundStyle(modelFilter == nil ? Theme.soft : .white)
                            .padding(.horizontal, 16)
                            .frame(height: 38)
                            .background(Color.white.opacity(0.08), in: Capsule())
                            .overlay(Capsule().stroke(Color.white.opacity(0.08)))
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .fixedSize()
                    }
                }
            }
        }
    }

    private var threadList: some View {
        let visibleThreads = model.snapshot.visibleThreads
        let threads = matchingThreads(in: visibleThreads)
        return Group {
            if visibleThreads.isEmpty {
                VStack(spacing: 16) {
                    BlueyEmptyState(title: "Noch keine Chats", subtitle: "Frag Bluey etwas oder häng Bilder, PDFs und Dateien an.")
                    #if os(macOS)
                    Button("Neuer Chat") { ui.composeCount += 1 }.buttonStyle(.borderedProminent)
                    #endif
                }
            } else if threads.isEmpty {
                BlueyEmptyState(title: "Nichts gefunden", subtitle: "Versuch ein anderes Wort.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(threads) { thread in
                            Button { selected = thread.id; composingNew = false } label: {
                                #if os(macOS)
                                macThreadRow(thread)
                                #else
                                ThreadRow(thread: thread, modelName: model.models.first { $0.id == thread.model }?.name ?? thread.model,
                                          selected: selected == thread.id)
                                #endif
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) { delete(thread) } label: { Label("Löschen", systemImage: "trash") }
                            }
                        }
                    }
                    .padding(.bottom, 20)
                }
            }
        }
    }

    #if os(macOS)
    private func macThreadRow(_ thread: ChatThread) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                if thread.model == "hermes" { HermesModelIcon(size: 14) }
                Text(thread.hermesOptions?.model ?? model.models.first { $0.id == thread.model }?.name ?? thread.model)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if thread.isStreaming { ProgressView().controlSize(.mini) }
                else { Text(ThreadRow.age(thread.updatedAt)) }
            }
            .font(.caption)
            .foregroundStyle(Theme.soft)
            Text(thread.title).font(.system(size: 14, weight: .medium)).lineLimit(2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected == thread.id ? Theme.raised : .clear, in: RoundedRectangle(cornerRadius: 9))
        .contentShape(Rectangle())
        .padding(.horizontal, 6)
    }
    #endif

    private func delete(_ thread: ChatThread) {
        if selected == thread.id { selected = nil }
        model.delete(thread)
    }
}

/// A thread row like T3 Code: badge, big title, a subtitle line, time on the right.
private struct ThreadRow: View {
    var thread: ChatThread
    var modelName: String
    var selected = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                BlueyAvatar(mood: thread.isStreaming ? .thinking : .listening, animated: thread.isStreaming)
                    .frame(width: 32, height: 29)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 6) {
                    Text(thread.title)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        if thread.model == "hermes" { HermesModelIcon(size: 14) }
                        else { Image(systemName: "cpu").font(.system(size: 12)) }
                        Text(thread.hermesOptions?.model ?? modelName)
                        if thread.webSearch { Image(systemName: "globe").font(.system(size: 12)) }
                        if thread.messages.contains(where: { !$0.attachments.isEmpty }) { Image(systemName: "paperclip").font(.system(size: 12)) }
                    }
                    .font(.plexSans(14))
                    .foregroundStyle(Theme.soft)
                    .lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 10) {
                    Text(Self.age(thread.updatedAt)).font(.plexSans(14)).foregroundStyle(Theme.soft)
                    if thread.isStreaming {
                        ProgressView().controlSize(.small)
                    } else if thread.messages.last?.status == .failed {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.peach)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(selected ? Theme.cardStrong : Color.clear)
            .contentShape(Rectangle())
            Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 66)
        }
    }

    /// Compact ages like "2m", "5h", "1d".
    static func age(_ date: Date) -> String {
        let s = max(0, Date().timeIntervalSince(date))
        if s < 60 { return "jetzt" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86400 { return "\(Int(s / 3600))h" }
        if s < 86400 * 7 { return "\(Int(s / 86400))d" }
        return "\(Int(s / (86400 * 7)))w"
    }
}

/// One conversation plus the composer.
struct ConversationView: View {
    @ObservedObject var model: WorkspaceModel
    @Binding var threadID: UUID?
    var focusOnAppear = false
    var composeCount = 0
    var leadingControls: AnyView?
    var layoutControls: AnyView?
    #if os(macOS)
    @StateObject private var dictation = MacChatDictation()
    #endif
    @State private var showModelPicker = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var importing = false
    @FocusState private var composerFocused: Bool

    private var thread: ChatThread? { model.thread(threadID) }
    private var composerDraft: WorkspaceChatDraft { model.chatDrafts[threadID] ?? .init() }
    private var draftBinding: Binding<String> {
        let target = threadID
        return Binding(
            get: { model.chatDrafts[target]?.text ?? "" },
            set: { model.chatDrafts[target, default: .init()].text = $0 }
        )
    }
    private var currentModel: String { composerDraft.model ?? thread?.model ?? model.defaultModel }

    private var hermesOptions: HermesChatOptions { composerDraft.hermesOptions ?? thread?.hermesOptions ?? HermesChatOptions() }
    private var webSearch: Bool { composerDraft.webSearch ?? thread?.webSearch ?? false }
    private var currentModelLabel: String {
        if currentModel == "hermes" { return hermesOptions.model ?? "Hermes" }
        return model.models.first { $0.id == currentModel }?.name ?? currentModel
    }

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            WorkspacePaneHeader(title: thread?.title ?? "Neuer Chat", leading: {
                leadingControls
                if currentModel == "hermes" { HermesModelIcon(size: 16) }
                else { MiniBluey().frame(width: 18, height: 16) }
            }, actions: {
                Text(currentModel == "hermes" ? "Hermes" : "Bluey")
                    .font(.caption).foregroundStyle(Theme.soft)
                layoutControls
            })
            #endif
            messages
            composer
        }
        .background(Theme.background)
        #if os(iOS)
        .navigationTitle(thread?.title ?? "Neuer Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let open = model.openHermesScreen {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { open(threadID) } label: { Image(systemName: "display") }
                        .accessibilityLabel("Hermes Live-Bildschirm öffnen")
                }
            }
            if let startCall = model.startCall {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { startCall(threadID) } label: { Image(systemName: "phone") }
                        .accessibilityLabel("Bluey anrufen")
                }
            }
        }
        #endif
        #if os(macOS)
        .sheet(isPresented: $showModelPicker) { modelPicker }
        .onDisappear { dictation.stop() }
        #else
        .sheet(isPresented: $showModelPicker) {
            modelPicker.presentationDetents([.large])
        }
        #endif
        #if os(macOS)
        .onChange(of: threadID) { _, _ in dictation.stop() }
        #endif
        .onAppear {
            if focusOnAppear { composerFocused = true }
        }
        .task(id: composeCount) {
            guard composeCount > 0 else { return }
            composerFocused = false
            await Task.yield()
            guard !Task.isCancelled else { return }
            composerFocused = true
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            let target = threadID
            for item in items { Task { await importPhoto(item, target: target) } }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            let target = threadID
            if case .success(let urls) = result {
                for url in urls { Task { await importFile(url, target: target) } }
            }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
            let target = threadID
            for provider in providers { Task { await importProvider(provider, target: target) } }
            return true
        }
    }

    // MARK: Messages

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if let thread, !thread.messages.isEmpty {
                        ForEach(thread.messages) { message in
                            if let tool = model.liveTools[message.id], let open = model.openHermesScreen {
                                HermesLiveToolRow(tool: tool) { open(threadID) }
                            }
                            MessageBubble(model: model, message: message).id(message.id)
                        }
                    } else {
                        BlueyEmptyState(title: "Worüber wollen wir reden?",
                                        subtitle: model.connected ? "Frag mich was, oder häng ein Bild, PDF oder eine Datei an."
                                                                  : "Zum Chatten brauche ich die Verbindung zu deinem Mac.")
                            .frame(minHeight: 360)
                    }
                    if let threadID, let respond = model.answerHermesApproval {
                        ForEach(model.hermesApprovals.filter { $0.threadID == threadID }) { approval in
                            WorkspaceHermesPromptCard(prompt: approval.prompt) { answer in
                                try await respond(approval, answer)
                            }
                        }
                    }
                    Color.clear.frame(height: 4).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: thread?.messages.count) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: model.streaming) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: model.hermesApprovals.filter { $0.threadID == threadID }) { _, approvals in
                if !approvals.isEmpty { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = composerDraft.error {
                Text(error).font(.plexSans(12)).foregroundStyle(Theme.peach)
            }
            if !composerDraft.attachments.isEmpty || composerDraft.uploads > 0 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(composerDraft.attachments) { attachment in
                            AttachmentChip(attachment: attachment) {
                                model.chatDrafts[threadID, default: .init()].attachments.removeAll { $0.id == attachment.id }
                            }
                        }
                        if composerDraft.uploads > 0 { ProgressView().controlSize(.small).padding(.horizontal, 8) }
                    }
                }
            }
            TextField(currentModel == "hermes" ? "Nachricht an Hermes…" : "Nachricht an Bluey…", text: draftBinding, axis: .vertical)
                .lineLimit(1...8)
                .font(.plexSans(15))
                .textFieldStyle(.plain)
                .focused($composerFocused)
                .onSubmit(send)
                #if os(macOS)
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) { return .ignored }
                    send(); return .handled
                }
                #endif
            HStack(spacing: 10) {
                Menu {
                    PhotosPicker(selection: $photoItems, maxSelectionCount: 6, matching: .images) {
                        Label("Fotos", systemImage: "photo")
                    }
                    Button { importing = true } label: { Label("Datei", systemImage: "doc") }
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .fixedSize()
                .accessibilityLabel("Anhang hinzufügen")

                Spacer(minLength: 0)

                Button { showModelPicker = true } label: {
                    HStack(spacing: 5) {
                        if currentModel == "hermes" { HermesModelIcon(size: 16) }
                        else { ProviderModelIcon(hermes: false, size: 16) }
                        Text(currentModelLabel).lineLimit(1)
                        if currentModel == "hermes", let thinking = hermesOptions.thinking {
                            Text(thinking.title).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Image(systemName: "chevron.down").font(.system(size: 9))
                    }
                    .font(.plexSans(12))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 12)
                    #if os(iOS)
                    .frame(minHeight: 44)
                    #else
                    .frame(minHeight: 30)
                    #endif
                    .background(Theme.raised, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.line))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Modell: \(currentModelLabel)")

                if currentModel != "hermes" {
                    Button { model.chatDrafts[threadID, default: .init()].webSearch = !webSearch } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "globe")
                            Text("Web")
                        }
                        .font(.plexSans(12))
                        .foregroundStyle(webSearch ? .white : .white.opacity(0.85))
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .glassCapsule(tint: webSearch ? Theme.blue.opacity(0.6) : nil)
                    .accessibilityLabel("Websuche")
                    .fixedSize()
                }

                #if os(macOS)
                Button {
                    if dictation.listening || dictation.starting {
                        dictation.stop()
                    } else {
                        let target = threadID
                        let draft = composerDraft.text
                        let prefix = draft.isEmpty || draft.hasSuffix(" ") ? draft : draft + " "
                        Task {
                            await dictation.start(onText: { model.chatDrafts[target, default: .init()].text = prefix + $0 },
                                                  onError: { model.chatDrafts[target, default: .init()].error = $0 })
                        }
                    }
                } label: {
                    Image(systemName: dictation.listening ? "mic.fill" : "mic")
                        .foregroundStyle(dictation.listening ? Theme.red : Theme.soft)
                        .frame(width: 30, height: 34)
                }
                .buttonStyle(.plain)
                .help(dictation.listening ? "Diktat beenden" : "Nachricht diktieren")
                .accessibilityLabel(dictation.listening ? "Diktat beenden" : "Nachricht diktieren")
                #else
                if let startCall = model.startCall {
                    Button { startCall(threadID) } label: {
                        Image(systemName: "mic").frame(width: 30, height: 34)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Sprachanruf starten")
                }
                #endif

                if thread?.isStreaming == true {
                    Button { if let id = threadID { model.stop(threadID: id) } } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .background(Theme.red, in: Circle())
                    .accessibilityLabel("Antwort stoppen")
                } else {
                    Button(action: send) {
                        Group {
                            if composerDraft.sending { ProgressView().controlSize(.small).tint(.white) }
                            else { Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold)) }
                        }
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .contentShape(Circle())
                        .opacity(canSend ? 1 : 0.45)
                    }
                    .buttonStyle(.plain)
                    .background(canSend ? Theme.blue : Color.white.opacity(0.08), in: Circle())
                    .disabled(!canSend)
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityLabel("Senden")
                }
            }
        }
        .padding(14)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 17))
        .overlay {
            RoundedRectangle(cornerRadius: 17).strokeBorder(Color.white.opacity(0.10))
                .allowsHitTesting(false)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: 840)
        .frame(maxWidth: .infinity)
    }

    private var modelPicker: some View {
        ChatModelPicker(
            blueyModels: model.models.filter { $0.id != "hermes" },
            activeModel: Binding(get: { currentModel }, set: { id in
                model.chatDrafts[threadID, default: .init()].model = id
                model.setModel(id, for: thread)
            }),
            options: Binding(get: { hermesOptions }, set: { model.chatDrafts[threadID, default: .init()].hermesOptions = $0 }),
            loadHermesModels: model.loadHermesModels
        )
    }

    private var canSend: Bool {
        let draft = composerDraft
        return !draft.sending && draft.uploads == 0 && thread?.isStreaming != true &&
            (!draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.attachments.isEmpty)
    }

    private func send() {
        guard canSend else { return }
        #if os(macOS)
        dictation.stop()
        #endif
        let target = threadID
        let text = composerDraft.text
        let files = composerDraft.attachments
        let selectedModel = currentModel
        let searchingWeb = webSearch
        let options = selectedModel == "hermes" ? hermesOptions : nil
        model.chatDrafts[target, default: .init()].sending = true
        model.chatDrafts[target, default: .init()].error = nil
        Task {
            defer { model.chatDrafts[target, default: .init()].sending = false }
            do {
                let id = try await model.send(threadID: target, text: text, attachments: files, model: selectedModel,
                                              webSearch: searchingWeb, hermesOptions: options)
                if model.chatDrafts[target]?.text == text { model.chatDrafts[target]?.text = "" }
                let sentFiles = Set(files.map(\.id))
                model.chatDrafts[target]?.attachments.removeAll { sentFiles.contains($0.id) }
                if target == nil, model.chatDrafts[nil]?.text.isEmpty == true, model.chatDrafts[nil]?.attachments.isEmpty == true {
                    model.chatDrafts[nil]?.model = nil
                    model.chatDrafts[nil]?.webSearch = nil
                    model.chatDrafts[nil]?.hermesOptions = nil
                }
                if threadID == target, target == nil { threadID = id }
            } catch {
                model.chatDrafts[target, default: .init()].error = error.localizedDescription
            }
        }
    }

    // MARK: Attachments

    private func add(_ data: Data, name: String, mime: String, target: UUID?) async {
        model.chatDrafts[target, default: .init()].uploads += 1
        defer { model.chatDrafts[target, default: .init()].uploads -= 1 }
        do {
            let attachment = try await model.upload(data, name: name, mime: mime)
            model.chatDrafts[target, default: .init()].attachments.append(attachment)
            model.chatDrafts[target]?.error = nil
        } catch {
            model.chatDrafts[target]?.error = error.localizedDescription
        }
    }

    private func importPhoto(_ item: PhotosPickerItem, target: UUID?) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            model.chatDrafts[target, default: .init()].error = "Das Foto konnte nicht geladen werden."
            return
        }
        let type = item.supportedContentTypes.first
        let ext = type?.preferredFilenameExtension ?? "jpg"
        await add(data, name: "Foto.\(ext)", mime: type?.preferredMIMEType ?? "image/jpeg", target: target)
    }

    private func importFile(_ url: URL, target: UUID?) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            model.chatDrafts[target, default: .init()].error = "„\(url.lastPathComponent)“ konnte nicht gelesen werden."
            return
        }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? ChatAttachment.mime(forName: url.lastPathComponent)
        await add(data, name: url.lastPathComponent, mime: mime, target: target)
    }

    private func importProvider(_ provider: NSItemProvider, target: UUID?) async {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let url: URL? = await withCheckedContinuation { done in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in done.resume(returning: url) }
            }
            if let url { await importFile(url, target: target) }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            let data: Data? = await withCheckedContinuation { done in
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in done.resume(returning: data) }
            }
            if let data { await add(data, name: "Bild.png", mime: "image/png", target: target) }
        }
    }
}

private struct AttachmentChip: View {
    var attachment: ChatAttachment
    var remove: (() -> Void)?
    var body: some View {
        HStack(spacing: 6) {
            AttachmentIcon(attachment: attachment).frame(width: 26, height: 26)
            Text(attachment.name).font(.plexSans(12)).foregroundStyle(.white).lineLimit(1).frame(maxWidth: 140)
            if let remove {
                Button(action: remove) { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.soft) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Anhang entfernen")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Theme.card, in: Capsule())
    }
}

struct AttachmentIcon: View {
    var attachment: ChatAttachment
    var body: some View {
        if let thumb = attachment.thumbnail.flatMap({ Data(base64Encoded: $0) }), let image = PlatformImage.make(thumb) {
            image.resizable().scaledToFill().clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Image(systemName: attachment.isPDF ? "doc.richtext" : attachment.isText ? "doc.text" : attachment.isImage ? "photo" : "doc")
                .foregroundStyle(Theme.accentLight)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.cardStrong, in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

enum PlatformImage {
    static func make(_ data: Data) -> Image? {
        #if canImport(UIKit)
        return UIImage(data: data).map(Image.init(uiImage:))
        #elseif canImport(AppKit)
        return NSImage(data: data).map(Image.init(nsImage:))
        #else
        return nil
        #endif
    }
}

private struct MessageBubble: View {
    @ObservedObject var model: WorkspaceModel
    var message: ChatMessage

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 6) {
                    if !message.attachments.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(message.attachments) { a in
                                if a.thumbnail != nil {
                                    AttachmentIcon(attachment: a).frame(width: 90, height: 90)
                                } else {
                                    AttachmentChip(attachment: a)
                                }
                            }
                        }
                    }
                    if !message.text.isEmpty {
                        Text(message.text)
                            .font(.plexSans(15))
                            .foregroundStyle(.white)
                            .textSelection(.enabled)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Theme.accent.opacity(0.85), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }
            }
        } else {
            HStack(alignment: .top, spacing: 10) {
                BlueyAvatar(mood: message.status == .streaming ? (model.text(of: message).isEmpty ? .thinking : .talking) : .listening)
                    .frame(width: 30, height: 27)
                VStack(alignment: .leading, spacing: 6) {
                    let text = model.text(of: message)
                    if text.isEmpty && message.status == .streaming {
                        TypingDots()
                    } else {
                        MarkdownText(text: text)
                    }
                    switch message.status {
                    case .failed:
                        Label(message.error ?? "Fehlgeschlagen", systemImage: "exclamationmark.triangle")
                            .font(.plexSans(12)).foregroundStyle(Theme.peach)
                    case .stopped:
                        Text("Gestoppt").font(.plexSans(11)).foregroundStyle(Theme.soft)
                    default:
                        EmptyView()
                    }
                    if message.status == .done, let used = message.model {
                        Text(used).font(.plexMono(10)).foregroundStyle(Theme.soft.opacity(0.6))
                    }
                }
                Spacer(minLength: 20)
            }
        }
    }
}

private struct TypingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(Theme.soft)
                        .frame(width: 7, height: 7)
                        .opacity(0.35 + 0.65 * max(0, sin(t * 6 - Double(i) * 0.8)))
                }
            }
            .padding(.vertical, 8)
        }
    }
}

/// Light markdown: inline styles, links, lists and fenced code blocks.
struct MarkdownText: View {
    var text: String

    private enum Block: Hashable { case text(String), code(String) }

    private var blocks: [Block] {
        var result: [Block] = []
        var current: [String] = []
        var inCode = false
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                let chunk = current.joined(separator: "\n")
                if inCode { result.append(.code(chunk)) } else if !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(.text(chunk)) }
                current = []
                inCode.toggle()
            } else {
                current.append(line)
            }
        }
        let rest = current.joined(separator: "\n")
        if inCode { result.append(.code(rest)) } else if !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(.text(rest)) }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let s):
                    Text(Self.attributed(s))
                        .font(.plexSans(15))
                        .foregroundStyle(.white.opacity(0.92))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .code(let s):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(s).font(.plexMono(13)).foregroundStyle(.white).textSelection(.enabled).padding(12)
                    }
                    .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    static func attributed(_ s: String) -> AttributedString {
        // Headings and bullets become plain lines with a bold heading / bullet sign.
        let lines = s.components(separatedBy: "\n").map { line -> String in
            var l = line
            if let match = l.range(of: #"^#{1,6}\s+"#, options: .regularExpression) { l = "**" + l[match.upperBound...] + "**" }
            if let match = l.range(of: #"^\s*[-*]\s+"#, options: .regularExpression) { l = "•  " + l[match.upperBound...] }
            return l
        }
        let joined = lines.joined(separator: "\n")
        return (try? AttributedString(markdown: joined, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(joined)
    }
}

/// Keeps the provider, model and thinking settings together in Bluey's model menu.
struct ChatModelPicker: View {
    var blueyModels: [ChatModelInfo] = []
    @Binding var activeModel: String
    @Binding var options: HermesChatOptions
    var loadHermesModels: (() async throws -> HermesModelCatalog)?
    @State private var showHermes = false
    @State private var catalog: HermesModelCatalog?
    @State private var search = ""
    @State private var loading = false
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss

    private var canChooseHermes: Bool { loadHermesModels != nil }
    private var supportsThinking: Bool {
        guard let model = options.model ?? catalog?.model,
              let provider = options.provider ?? catalog?.provider else { return false }
        return catalog?.providers.first { $0.slug == provider }?.capabilities?[model]?.reasoning == true
    }

    var body: some View {
        VStack(spacing: 0) {
            #if os(iOS)
            if !blueyModels.isEmpty && canChooseHermes {
                HStack(spacing: 8) {
                    providerButton("OpenAI", hermes: false)
                    providerButton("Hermes", hermes: true)
                    Spacer(minLength: 0)
                }
                .padding([.top, .horizontal], 12)
            }
            #endif
            HStack(spacing: 0) {
                #if os(macOS)
                if !blueyModels.isEmpty && canChooseHermes {
                    VStack(spacing: 8) {
                        providerButton("OpenAI", hermes: false)
                        providerButton("Hermes", hermes: true)
                        Spacer(minLength: 0)
                    }
                    .padding(8)
                    Divider().overlay(Theme.line)
                }
                #endif
                modelList
                #if os(macOS)
                if showHermes {
                    Divider().overlay(Theme.line)
                    thinkingColumn.frame(width: 170)
                }
                #endif
            }
            Divider().overlay(Theme.line)
            HStack {
                Spacer()
                Button("Fertig") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(hex: Palette.berry3))
                    #if os(iOS)
                    .controlSize(.large)
                    #else
                    .keyboardShortcut(.cancelAction)
                    #endif
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(Theme.raised)
        }
        .background(Theme.panel)
        .preferredColorScheme(.dark)
        #if os(macOS)
        .frame(width: 620, height: 390)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
        .onAppear { showHermes = canChooseHermes && (activeModel == "hermes" || blueyModels.isEmpty) }
        .task(id: showHermes) {
            if showHermes && catalog == nil { await loadCatalog() }
        }
    }

    private var modelList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.soft)
                TextField("Modelle suchen", text: $search).textFieldStyle(.plain)
            }
            .padding(10)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 8))
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if showHermes { hermesModels }
                    else {
                        ForEach(blueyModels.filter { matches($0.name) }) { entry in
                            row(entry.name, selected: entry.id == activeModel, brand: false) { activeModel = entry.id }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            #if os(iOS)
            if showHermes && supportsThinking {
                Divider().overlay(Theme.line)
                LabeledContent("Denkaufwand") {
                    Picker("Denkaufwand", selection: $options.thinking) {
                        Text("Standard").tag(HermesChatOptions.Thinking?.none)
                        ForEach(HermesChatOptions.Thinking.allCases, id: \.self) { value in
                            Text(value.title).tag(Optional(value))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                .frame(minHeight: 44)
                .onChange(of: options.thinking) { _, _ in activeModel = "hermes" }
            }
            #endif
        }
        .padding(12)
    }

    #if os(macOS)
    private var thinkingColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Denkaufwand").font(.headline)
            Text(options.model ?? catalog?.model ?? "Hermes")
                .font(.caption).foregroundStyle(Theme.soft)
                .fixedSize(horizontal: false, vertical: true)
            Divider().overlay(Theme.line)
            if supportsThinking {
                ScrollView {
                    VStack(spacing: 3) {
                        thinkingRow("Standard", value: nil)
                        ForEach(HermesChatOptions.Thinking.allCases, id: \.self) { value in
                            thinkingRow(value.title, value: value)
                        }
                    }
                }
            } else if catalog != nil {
                Text("Für dieses Modell nicht verfügbar.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private func thinkingRow(_ title: String, value: HermesChatOptions.Thinking?) -> some View {
        row(title, selected: options.thinking == value) {
            options.thinking = value
            activeModel = "hermes"
        }
    }
    #endif

    @ViewBuilder private var hermesModels: some View {
        if search.isEmpty {
            let name = catalog?.model.map { "Hermes-Standard · \($0)" } ?? "Hermes-Standard"
            row(name, selected: activeModel == "hermes" && options.model == nil, brand: true) {
                let effort = options.thinking
                options = HermesChatOptions(thinking: effort)
                if !supportsThinking { options.thinking = nil }
                activeModel = "hermes"
            }
        }
        if loading { ProgressView().padding(8) }
        if let problem {
            Text(problem).font(.caption).foregroundStyle(.secondary)
            Button("Erneut laden") { Task { await loadCatalog() } }
        }
        ForEach(catalog?.providers ?? []) { provider in
            let matches = provider.models.filter { self.matches($0) }
            if !matches.isEmpty {
                Text(provider.name).font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                ForEach(matches, id: \.self) { id in
                    row(id, selected: activeModel == "hermes" && options.provider == provider.slug && options.model == id,
                        brand: provider.slug.hasPrefix("openai") ? false : nil) {
                        let thinking = provider.capabilities?[id]?.reasoning == true ? options.thinking : nil
                        options = HermesChatOptions(provider: provider.slug, model: id, thinking: thinking)
                        activeModel = "hermes"
                    }
                }
            }
        }
    }

    private func matches(_ name: String) -> Bool {
        search.isEmpty || name.localizedCaseInsensitiveContains(search)
    }

    private func providerButton(_ title: String, hermes: Bool) -> some View {
        Button {
            search = ""
            showHermes = hermes
        } label: {
            VStack(spacing: 3) {
                ProviderModelIcon(hermes: hermes, size: 23)
                Text(title).font(.caption2)
            }
            .frame(width: 55, height: 46)
            .background(showHermes == hermes ? Theme.cardStrong : .clear, in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(showHermes == hermes ? .isSelected : [])
    }

    private func row(_ title: String, selected: Bool, brand: Bool? = nil, choose: @escaping () -> Void) -> some View {
        Button(action: choose) {
            HStack(spacing: 8) {
                if let brand { ProviderModelIcon(hermes: brand, size: 17) }
                Text(title).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if selected { Image(systemName: "checkmark").foregroundStyle(Theme.accentLight) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            #if os(iOS)
            .frame(minHeight: 44)
            #endif
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.cardStrong : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .help(title)
        #endif
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func loadCatalog() async {
        guard let loadHermesModels else { return }
        loading = true
        problem = nil
        defer { loading = false }
        do { catalog = try await loadHermesModels() }
        catch { if !Task.isCancelled { problem = error.localizedDescription } }
    }
}

struct HermesLiveToolRow: View {
    let tool: HermesLiveTool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Image(systemName: tool.symbol)
                Text(tool.title).fontWeight(.medium)
                ProgressView().controlSize(.mini)
                Spacer(minLength: 8)
                Text("Live ansehen")
                Image(systemName: "arrow.up.right")
            }
            .font(.caption)
            .padding(10)
            .background(Theme.cardStrong, in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
    }
}

struct HermesModelIcon: View {
    let size: CGFloat
    var body: some View { ProviderModelIcon(hermes: true, size: size) }
}

private struct ProviderModelIcon: View {
    let hermes: Bool
    let size: CGFloat

    var body: some View {
        let name = hermes ? "HermesModelIcon" : "OpenAIModelIcon"
        Group {
            #if os(macOS)
            if let url = Bundle.main.url(forResource: name, withExtension: "png"),
               let icon = NSImage(contentsOf: url) {
                Image(nsImage: icon).resizable().scaledToFit()
            } else { fallback }
            #else
            if let url = Bundle.main.url(forResource: name, withExtension: "png"),
               let icon = UIImage(contentsOfFile: url.path) {
                Image(uiImage: icon).resizable().scaledToFit()
            } else { fallback }
            #endif
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: hermes ? size * 0.17 : 0))
        .accessibilityHidden(true)
    }

    private var fallback: some View {
        Image(systemName: hermes ? "bird" : "cpu").font(.system(size: size))
    }
}

/// Styles the Hub viewer in the app while preserving its connection and control logic.
enum HermesViewerPresentation {
    static func apply(to configuration: WKWebViewConfiguration) {
        #if os(iOS)
        let touchRules = "header button, form button, input { min-height: 44px; }"
        #else
        let touchRules = ""
        #endif
        let source = """
            const display = document.querySelector('#display');
            const controls = document.querySelector('header');
            if (display && controls) {
                document.body.insertBefore(display, controls);
                document.documentElement.lang = 'de';
                document.querySelector('#take').textContent = 'Übernehmen';
                document.querySelector('#release').textContent = 'Zurückgeben';
                document.querySelector('#text').placeholder = 'Text am entfernten Computer';
                document.querySelector('#keyboard button[type=submit]').textContent = 'Eingeben';
                const status = document.querySelector('#status');
                const german = {
                    'Connecting…': 'Verbindung wird aufgebaut …',
                    'Watching Hermes': 'Zuschauen',
                    'You have control': 'Du steuerst',
                    'Control was taken in another viewer. Reconnect to watch.': 'Ein anderes Fenster steuert. Verbinde dich erneut.',
                    'Disconnected. Tap Reconnect to open a new stream.': 'Getrennt. Verbinde dich erneut.',
                    "Couldn't connect to Hermes Bot Desktop.": 'Der Hermes-Desktop konnte nicht verbunden werden.',
                    'Hermes refused the display request.': 'Hermes hat die Bildschirmfreigabe abgelehnt.',
                    'Hermes dashboard token file is empty.': 'Die Anmeldedatei für das Hermes-Dashboard ist leer.'
                };
                const translate = () => {
                    if (german[status.textContent]) status.textContent = german[status.textContent];
                };
                new MutationObserver(translate).observe(status, {childList:true});
                translate();
                const style = document.createElement('style');
                style.textContent = `
                    :root { background: #\(String(format: "%06X", Palette.workspaceCanvas)); color: #\(String(format: "%06X", Palette.workspaceText)); font: 13px system-ui; }
                    body { box-sizing: border-box; padding: 10px 12px; gap: 8px; }
                    main { border: 1px solid #\(String(format: "%06X", Palette.workspaceEdge)); border-radius: 12px; background: #\(String(format: "%06X", Palette.workspaceRaised)); }
                    header, form { background: none; padding: 0; flex-wrap: wrap; }
                    header span { color: #\(String(format: "%06X", Palette.workspaceMuted)); font-size: 12px; }
                    button, input { background: #\(String(format: "%06X", Palette.workspaceRaised)); border-color: #\(String(format: "%06X", Palette.workspaceEdge)); padding: 6px 9px; }
                    header button:hover:not(:disabled) { color: white; text-decoration: underline; }
                    #release:disabled, header:has(#release:not(:disabled)) #take { display: none; }
                    #release:not(:disabled) { background: #264037; }
                    \(touchRules)
                `;
                document.head.appendChild(style);
            }
            """
        configuration.userContentController.addUserScript(WKUserScript(
            source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true
        ))
    }
}

struct WorkspaceHermesActivity: View {
    let title: String
    var tool: HermesLiveTool?
    var stop: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: tool?.symbol ?? "waveform")
                .foregroundStyle(Theme.accentLight)
            Text(title)
                .lineLimit(2)
            Spacer(minLength: 0)
            if let stop {
                Button("Stoppen", systemImage: "stop.circle", action: stop)
                    .buttonStyle(.plain)
                    .tint(Theme.red)
                    .foregroundStyle(Theme.red)
                    #if os(iOS)
                    .frame(minHeight: 44)
                    #endif
            }
        }
        .font(.plexSans(13))
        .foregroundStyle(Theme.text)
    }
}

struct WorkspaceHermesPromptCard: View {
    let prompt: HermesPrompt
    let submit: (String) async throws -> Void
    @State private var text = ""
    @State private var sending = false
    @State private var sent = false
    @State private var issue: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(prompt.kind == .approval ? "Freigabe erforderlich" : "Hermes hat eine Frage",
                  systemImage: prompt.kind == .approval ? "exclamationmark.shield" : "questionmark.bubble")
                .foregroundStyle(Theme.yellow)
            Text(prompt.text).textSelection(.enabled)
            if let detail = prompt.detail, !detail.isEmpty, detail != prompt.text {
                Text(detail).font(.caption.monospaced()).foregroundStyle(Theme.soft)
                    .textSelection(.enabled)
            }
            if prompt.kind == .clarify {
                TextField("Antwort", text: $text).textFieldStyle(.roundedBorder)
                    .onSubmit { send(text) }
                Button("Antwort senden") { send(text) }
                    .buttonStyle(.bordered)
                    #if os(iOS)
                    .controlSize(.large)
                    #endif
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if !prompt.choices.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(prompt.choices, id: \.self) { choice in
                            Button(prompt.kind == .approval ? HermesPrompt.choiceTitle(choice) : choice) { send(choice) }
                                .buttonStyle(.bordered)
                                #if os(iOS)
                                .controlSize(.large)
                                #endif
                                .tint(prompt.kind == .approval && choice == "deny" ? Theme.red : Theme.accentLight)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
            if let issue { Text(issue).foregroundStyle(Theme.red) }
            if sent { Text("An Hermes gesendet").foregroundStyle(Theme.soft) }
        }
        .font(.plexSans(13))
        .disabled(sending || sent)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10))
    }

    private func send(_ choice: String) {
        guard !sending, !sent, !choice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        sending = true
        issue = nil
        Task {
            defer { sending = false }
            do { try await submit(choice); sent = true }
            catch { issue = error.localizedDescription }
        }
    }


}
