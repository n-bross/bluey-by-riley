import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
#if canImport(GooglyShared)
import GooglyShared
#endif

/// Chat with Bluey, like T3 Code: threads, a composer with attachments, model picker and web search.
struct ChatTab: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var ui: WorkspaceUI
    var info: HeaderInfo
    @State private var selected: UUID?
    @State private var composingNew = false
    @State private var modelFilter: String?

    private var threads: [ChatThread] {
        model.snapshot.visibleThreads.filter { thread in
            (modelFilter == nil || thread.model == modelFilter) &&
                ui.matches(thread.title, thread.messages.suffix(20).map(\.text).joined(separator: " "))
        }
    }

    private var usedModels: [String] {
        Array(Set(model.snapshot.visibleThreads.map(\.model))).sorted()
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
                ConversationView(model: model, threadID: $selected)
                    .toolbarBackground(Theme.panel, for: .navigationBar)
                    .onAppear { ui.inDetail = true }
                    .onDisappear { ui.inDetail = false }
            }
        }
        .onChange(of: ui.composeCount) { _, _ in newChat() }
        #else
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                threadList
            }
            .frame(width: 300)
            .background(Theme.panel.opacity(0.35))
            Divider().overlay(Theme.line)
            ConversationView(model: model, threadID: $selected)
        }
        .onChange(of: ui.composeCount) { _, _ in newChat() }
        #endif
    }

    private func newChat() {
        ui.endSearch()
        selected = nil
        composingNew = true
    }

    private var header: some View {
        TabHeader(ui: ui, model: model, tab: .chat, connectionName: info.connectionName, onSettings: info.onSettings) {
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
        Group {
            if model.snapshot.visibleThreads.isEmpty {
                VStack(spacing: 16) {
                    BlueyEmptyState(title: "Noch keine Chats", subtitle: "Tippe auf den Stift unten rechts und frag Bluey irgendwas. Bilder, PDFs und Dateien kannst du anhängen.")
                    #if os(macOS)
                    Button("Neuer Chat", action: newChat).buttonStyle(.borderedProminent)
                    #endif
                }
            } else if threads.isEmpty {
                BlueyEmptyState(title: "Nichts gefunden", subtitle: "Versuch ein anderes Wort.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(threads) { thread in
                            Button { selected = thread.id; composingNew = false } label: {
                                ThreadRow(thread: thread, modelName: model.models.first { $0.id == thread.model }?.name ?? thread.model,
                                          selected: selected == thread.id)
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
                        Image(systemName: "cpu").font(.system(size: 12))
                        Text(modelName)
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
    @State private var draft = ""
    @State private var attachments: [ChatAttachment] = []
    @State private var uploading = 0
    @State private var sending = false
    @State private var error: String?
    @State private var chosenModel: String?
    @State private var webSearch = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var importing = false
    @FocusState private var composerFocused: Bool

    private var thread: ChatThread? { model.thread(threadID) }
    private var currentModel: String { chosenModel ?? thread?.model ?? model.defaultModel }

    var body: some View {
        VStack(spacing: 0) {
            messages
            composer
        }
        .background(Theme.background)
        #if os(iOS)
        .navigationTitle(thread?.title ?? "Neuer Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let startCall = model.startCall {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { startCall(threadID) } label: { Image(systemName: "phone") }
                        .accessibilityLabel("Bluey anrufen")
                }
            }
        }
        #endif
        .onChange(of: threadID) { _, _ in
            chosenModel = nil
            webSearch = thread?.webSearch ?? false
            error = nil
        }
        .onAppear { webSearch = thread?.webSearch ?? false }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            for item in items { Task { await importPhoto(item) } }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { for url in urls { Task { await importFile(url) } } }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
            for provider in providers { Task { await importProvider(provider) } }
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
                            MessageBubble(model: model, message: message).id(message.id)
                        }
                    } else {
                        BlueyEmptyState(title: "Worüber wollen wir reden?",
                                        subtitle: model.connected ? "Frag mich was, oder häng ein Bild, PDF oder eine Datei an."
                                                                  : "Zum Chatten brauche ich die Verbindung zu deinem Mac.")
                            .frame(minHeight: 360)
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
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error {
                Text(error).font(.plexSans(12)).foregroundStyle(Theme.peach)
            }
            if !attachments.isEmpty || uploading > 0 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments) { attachment in
                            AttachmentChip(attachment: attachment) { attachments.removeAll { $0.id == attachment.id } }
                        }
                        if uploading > 0 { ProgressView().controlSize(.small).padding(.horizontal, 8) }
                    }
                }
            }
            TextField("Nachricht an Bluey…", text: $draft, axis: .vertical)
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
                        .glassCircle()
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .fixedSize()
                .accessibilityLabel("Anhang hinzufügen")

                Menu {
                    ForEach(model.models) { option in
                        Button {
                            chosenModel = option.id
                            model.setModel(option.id, for: thread)
                        } label: {
                            if option.id == currentModel { Label(option.name, systemImage: "checkmark") } else { Text(option.name) }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "cpu")
                        Text(model.models.first { $0.id == currentModel }?.name ?? currentModel).lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
                    }
                    .font(.plexSans(12))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .glassCapsule()
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .fixedSize()

                Button { webSearch.toggle() } label: {
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

                Spacer()

                if thread?.isStreaming == true {
                    Button { if let id = threadID { model.stop(threadID: id) } } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .glassCircle(tint: Theme.red.opacity(0.8))
                    .accessibilityLabel("Antwort stoppen")
                } else {
                    Button(action: send) {
                        Group {
                            if sending { ProgressView().controlSize(.small).tint(.white) }
                            else { Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold)) }
                        }
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .contentShape(Circle())
                        .opacity(canSend ? 1 : 0.45)
                    }
                    .buttonStyle(.plain)
                    .glassCircle(tint: canSend ? Theme.blue.opacity(0.8) : nil)
                    .disabled(!canSend)
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityLabel("Senden")
                }
            }
        }
        .padding(12)
        .glass(in: RoundedRectangle(cornerRadius: 26, style: .continuous), interactive: false)
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: 840)
        .frame(maxWidth: .infinity)
    }

    private var canSend: Bool {
        !sending && uploading == 0 && thread?.isStreaming != true &&
            (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    private func send() {
        guard canSend else { return }
        let text = draft, files = attachments
        sending = true; error = nil
        Task {
            do {
                let id = try await model.send(threadID: threadID, text: text, attachments: files, model: currentModel, webSearch: webSearch)
                draft = ""; attachments = []
                threadID = id
            } catch {
                self.error = error.localizedDescription
            }
            sending = false
        }
    }

    // MARK: Attachments

    private func add(_ data: Data, name: String, mime: String) async {
        uploading += 1
        defer { uploading -= 1 }
        do {
            attachments.append(try await model.upload(data, name: name, mime: mime))
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func importPhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else { error = "Das Foto konnte nicht geladen werden."; return }
        let type = item.supportedContentTypes.first
        let ext = type?.preferredFilenameExtension ?? "jpg"
        await add(data, name: "Foto.\(ext)", mime: type?.preferredMIMEType ?? "image/jpeg")
    }

    private func importFile(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { error = "„\(url.lastPathComponent)“ konnte nicht gelesen werden."; return }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? ChatAttachment.mime(forName: url.lastPathComponent)
        await add(data, name: url.lastPathComponent, mime: mime)
    }

    private func importProvider(_ provider: NSItemProvider) async {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let url: URL? = await withCheckedContinuation { done in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in done.resume(returning: url) }
            }
            if let url { await importFile(url) }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            let data: Data? = await withCheckedContinuation { done in
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in done.resume(returning: data) }
            }
            if let data { await add(data, name: "Bild.png", mime: "image/png") }
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
