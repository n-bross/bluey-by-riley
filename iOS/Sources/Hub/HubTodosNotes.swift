import SwiftUI
import WebKit

// MARK: - Todos

/// Todos in T3's list style: a quick-add field, then Overdue / Today / Upcoming / No date / Done.
struct TodosView: View {
    @ObservedObject var hub: HubClient
    var openDrawer: () -> Void
    @State private var newTitle = ""
    @State private var newDue: Date?
    @State private var pickingDate = false
    @FocusState private var adding: Bool

    @State private var isAdding = false
    @State private var addError = false

    private func day(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f.string(from: d)
    }

    private func groups(today: String) -> [(String, [HubTodo])] {
        var overdue: [HubTodo] = [], current: [HubTodo] = [], upcoming: [HubTodo] = []
        var undated: [HubTodo] = [], done: [HubTodo] = []
        for todo in hub.todos {
            if todo.done { done.append(todo) }
            else if let due = todo.due, !due.isEmpty {
                if due < today { overdue.append(todo) }
                else if due == today { current.append(todo) }
                else { upcoming.append(todo) }
            } else {
                undated.append(todo)
            }
        }
        return [("Overdue", overdue), ("Today", current), ("Upcoming", upcoming),
                ("No date", undated), ("Done", done)]
    }

    var body: some View {
        let today = day(Date())
        let groups = groups(today: today)
        let openCount = groups.dropLast().reduce(0) { $0 + $1.1.count }
        return VStack(spacing: 0) {
            T3Header(title: "Todos", subtitle: "\(openCount) open", openDrawer: openDrawer) { EmptyView() }
            quickAdd
            if addError {
                Text("Couldn’t add the todo. Try again.")
                    .t3Text(.sm, color: T3.dangerForeground)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            List {
                ForEach(groups.filter { !$0.1.isEmpty }, id: \.0) { name, items in
                    Section {
                        ForEach(items) { todo in
                            TodoRow(todo: todo, today: today) {
                                Task { await hub.updateTodo(todo.id, ["done": !todo.done]) }
                            }
                            .listRowBackground(T3.screen)
                            .listRowSeparatorTint(T3.separator)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { Task { await hub.deleteTodo(todo.id) } } label: { Label("Delete", systemImage: "trash") }
                                if !todo.done {
                                    Button { Task { await hub.updateTodo(todo.id, ["due": day(tomorrow)]) } } label: {
                                        Label("Tomorrow", systemImage: "arrow.turn.up.right")
                                    }
                                    .tint(T3.primary)
                                }
                            }
                            .swipeActions(edge: .leading) {
                                if todo.due != today, !todo.done {
                                    Button { Task { await hub.updateTodo(todo.id, ["due": today]) } } label: { Label("Today", systemImage: "sun.max") }
                                        .tint(.orange)
                                }
                            }
                        }
                    } header: {
                        Text(name).t3Text(.xs2, .medium, color: name == "Overdue" ? T3.dangerForeground : T3.foregroundSecondary)
                            .textCase(nil)
                            .padding(.top, 6)
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 2, trailing: 16))
                    }
                }
            }
            .listStyle(.plain)
            .listSectionSpacing(4)
            .environment(\.defaultMinListRowHeight, 40)
            .environment(\.defaultMinListHeaderHeight, 24)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .refreshable { await hub.refreshTodos() }
        }
        .background(T3.screen.ignoresSafeArea())
        .sheet(isPresented: $pickingDate) {
            DatePicker("Due", selection: Binding(get: { newDue ?? Date() }, set: { newDue = $0 }), displayedComponents: .date)
                .datePickerStyle(.graphical).padding().presentationDetents([.medium])
        }
    }

    private var quickAdd: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus").font(.system(size: 14, weight: .semibold)).foregroundStyle(T3.iconMuted)
            TextField("Add a todo", text: $newTitle).font(T3.font(.base)).focused($adding).submitLabel(.done)
                .onSubmit(add)
            Menu {
                Button("Today") { newDue = Date() }
                Button("Tomorrow") { newDue = tomorrow }
                Button("Pick a date…") { pickingDate = true }
                if newDue != nil { Button("No date", role: .destructive) { newDue = nil } }
            } label: {
                Text(newDue.map { $0.formatted(.dateTime.day().month(.abbreviated)) } ?? "Date")
                    .t3Text(.xs, .medium, color: newDue == nil ? T3.foregroundSecondary : T3.primaryText)
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(Capsule().fill(T3.subtle)).overlay(Capsule().stroke(T3.border, lineWidth: 1))
            }
            Button(action: add) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 23))
                    .foregroundStyle(canAdd ? T3.primaryText : T3.iconMuted)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canAdd)
            .accessibilityLabel("Add todo")
        }
        .disabled(isAdding)
        .padding(.horizontal, 12).frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(T3.input))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(T3.inputBorder, lineWidth: 1))
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    private var tomorrow: Date { Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date() }
    private var trimmedTitle: String { newTitle.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canAdd: Bool { !isAdding && !trimmedTitle.isEmpty }

    private func add() {
        guard canAdd else { return }
        let title = trimmedTitle
        let due = newDue.map(day)
        isAdding = true
        addError = false
        Task {
            defer { isAdding = false }
            do {
                try await hub.addTodo(title, due: due)
                newTitle = ""
                newDue = nil
            } catch {
                addError = true
            }
        }
    }
}

private struct TodoRow: View {
    let todo: HubTodo
    let today: String
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: toggle) {
                Image(systemName: todo.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20)).foregroundStyle(todo.done ? T3.primary : T3.iconMuted)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text(todo.title).t3Text(.base, color: todo.done ? T3.foregroundTertiary : T3.foreground)
                    .strikethrough(todo.done, color: T3.foregroundTertiary)
                HStack(spacing: 6) {
                    if let date = todo.dueDate, !todo.done {
                        let late = (todo.due ?? "") < today
                        HStack(spacing: 4) {
                            Image(systemName: "calendar").font(.system(size: 10, weight: .medium))
                            Text(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))).font(T3.font(.xs))
                        }
                        .foregroundStyle(late ? T3.dangerForeground : T3.foregroundSecondary)
                    }
                    if todo.list != "Inbox" { Text(todo.list).t3Text(.xs, color: T3.foregroundSecondary) }
                    if !todo.notes.isEmpty { Image(systemName: "text.alignleft").font(.system(size: 10)).foregroundStyle(T3.iconMuted) }
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Notes

/// Notes like Raycast Notes: a list of quick notes (first line is the title), pinned first, open one and type.
struct NotesView: View {
    @ObservedObject var hub: HubClient
    var openDrawer: () -> Void
    @State private var search = ""
    @State private var open: HubNote?

    private var shown: [HubNote] {
        hub.notes.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || ($0.preview ?? "").localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                T3Header(title: "Notes", openDrawer: openDrawer) {
                    T3IconButton(symbol: "square.and.pencil", label: "New note", prominent: true) {
                        Task { if let n = try? await hub.createNote("") { open = n } }
                    }
                }
                T3SearchField(text: $search, placeholder: "Search notes").padding(.bottom, 8)
                List {
                    ForEach(shown) { note in
                        Button { open = note } label: {
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        if note.pinned { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(T3.primaryText) }
                                        Text(note.title).t3Text(.base, .medium).lineLimit(1)
                                    }
                                    if let p = note.preview, !p.isEmpty { Text(p).t3Text(.sm, color: T3.foregroundSecondary).lineLimit(2) }
                                }
                                Spacer()
                                Text(T3Time.short(note.updatedDate)).t3Text(.xs, color: T3.foregroundTertiary)
                            }
                            .padding(.vertical, 8).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(T3.screen)
                        .listRowSeparatorTint(T3.separator)
                        .swipeActions {
                            Button(role: .destructive) { Task { await hub.deleteNote(note.id) } } label: { Label("Delete", systemImage: "trash") }
                            Button { Task { try? await hub.saveNote(note.id, pinned: !note.pinned) } } label: {
                                Label(note.pinned ? "Unpin" : "Pin", systemImage: "pin")
                            }
                            .tint(T3.primary)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .refreshable { await hub.refreshNotes() }
            }
            .background(T3.screen.ignoresSafeArea())
            .navigationDestination(item: $open) { note in HubNoteEditor(hub: hub, noteID: note.id) }
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

extension HubNote: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Plain-text editor that saves as you type (half a second after you stop).
struct HubNoteEditor: View {
    @ObservedObject var hub: HubClient
    let noteID: String
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var loaded = false
    @State private var saveTask: Task<Void, Never>?
    @State private var status = ""
    @State private var savedText = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                T3IconButton(symbol: "chevron.left", label: "Back") { save(now: true); dismiss() }
                Spacer()
                Text(status).t3Text(.xs, color: T3.foregroundTertiary)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            TextEditor(text: $text)
                .font(T3.font(.base))
                .foregroundStyle(T3.foreground)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .focused($focused)
                .onChange(of: text) { _, _ in if loaded { save(now: false) } }
        }
        .background(T3.screen.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task {
            if let n = try? await hub.note(noteID) { text = n.body ?? "" }
            savedText = text
            loaded = true
            if text.isEmpty { focused = true }
        }
        .onDisappear { save(now: true) }
    }

    private func save(now: Bool) {
        guard text != savedText else { return }  // opening a note isn't an edit
        saveTask?.cancel()
        let body = text
        status = "Editing"
        saveTask = Task {
            if !now { try? await Task.sleep(for: .milliseconds(600)) }
            guard !Task.isCancelled else { return }
            do { try await hub.saveNote(noteID, body: body); savedText = body; status = "Saved" } catch { status = "Not saved" }
        }
    }
}

// MARK: - Browser

/// A browser in the app (T3 has one for previews). Ask Hermes about the page, or hand it a browsing job.
struct HubBrowserView: View {
    @ObservedObject var hub: HubClient
    var openDrawer: () -> Void
    var start: URL?
    @State private var address = ""
    @State private var current: URL?
    @State private var loading = false
    @State private var asking = false
    @State private var askText = ""
    @State private var result: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                T3IconButton(symbol: "sidebar.left", label: "Menu", action: openDrawer)
                HStack(spacing: 6) {
                    Image(systemName: loading ? "arrow.triangle.2.circlepath" : "globe").font(.system(size: 13)).foregroundStyle(T3.iconMuted)
                    TextField("Search or enter address", text: $address)
                        .font(T3.font(.sm)).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.webSearch).submitLabel(.go).onSubmit(go)
                }
                .padding(.horizontal, 10).frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(T3.input))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(T3.inputBorder, lineWidth: 1))
                T3IconButton(symbol: "sparkles", label: "Ask Hermes", prominent: true) { asking = true }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            if let current {
                HubWebView(url: current, loading: $loading) { url in address = url.absoluteString }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "safari").font(.system(size: 30)).foregroundStyle(T3.iconMuted)
                    Text("Browse here, or let Hermes browse for you").t3Text(.lg, .medium)
                    Text("Tap ✦ to ask Hermes about this page or give it a browsing job; it uses its own browser on your server.")
                        .t3Text(.sm, color: T3.foregroundSecondary).multilineTextAlignment(.center)
                }
                .padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(T3.screen.ignoresSafeArea())
        .onAppear { if let start, current == nil { current = start; address = start.absoluteString } }
        .sheet(isPresented: $asking) { askSheet.presentationDetents([.medium, .large]) }
    }

    private func go() {
        let text = address.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        if text.contains("."), !text.contains(" ") {
            current = URL(string: text.hasPrefix("http") ? text : "https://" + text)
        } else {
            current = URL(string: "https://duckduckgo.com/?q=" + (text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text))
        }
    }

    private var askSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ask Hermes").t3Text(.xl, .bold)
            if let current { Text(current.absoluteString).t3Text(.xs, color: T3.foregroundSecondary).lineLimit(1) }
            HStack {
                ForEach(["Summarise this page", "Find the key facts", "Open it and do it for me"], id: \.self) { chip in
                    Button(chip) { askText = chip }.font(T3.font(.xs, .medium)).padding(.horizontal, 10).frame(height: 28)
                        .background(Capsule().fill(T3.subtle)).overlay(Capsule().stroke(T3.border, lineWidth: 1)).foregroundStyle(T3.foreground)
                }
            }
            T3Composer(text: $askText, running: result == "…", send: ask, stop: {})
            if let result, result != "…" {
                ScrollView { HubMarkdownText(text: result) { current = $0; address = $0.absoluteString; asking = false } }
            }
            Spacer()
        }
        .padding(20)
        .background(T3.screen.ignoresSafeArea())
    }

    private func ask() {
        let question = askText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        let page = current.map { "\n\nPage: \($0.absoluteString)" } ?? ""
        result = "…"
        Task {
            do {
                let id = try await hub.send("Use your browser tools if you need to. " + question + page, session: "app-browser")
                var text = ""
                for try await e in hub.events(of: id) {
                    if e["event"] as? String == "message.delta" { text += e["delta"] as? String ?? ""; result = text }
                    if e["event"] as? String == "run.completed" { result = (e["output"] as? String) ?? text }
                }
                if result == "…" { result = text.isEmpty ? "Done." : text }
            } catch { result = error.localizedDescription }
        }
    }
}

struct HubWebView: UIViewRepresentable {
    let url: URL
    @Binding var loading: Bool
    var onNavigate: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView()
        web.navigationDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        web.load(URLRequest(url: url))
        context.coordinator.loaded = url
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        if context.coordinator.loaded != url { context.coordinator.loaded = url; web.load(URLRequest(url: url)) }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: HubWebView
        var loaded: URL?
        init(_ parent: HubWebView) { self.parent = parent }
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { parent.loading = true }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.loading = false
            if let url = webView.url { parent.onNavigate(url) }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { parent.loading = false }
    }
}

// MARK: - Settings

struct HubSettingsView: View {
    @ObservedObject var hub: HubClient
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var key = ""
    @State private var status = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://shipyard.your-tailnet.ts.net", text: $url)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    SecureField(hub.config?.key.isEmpty == false ? "Key saved. Paste a new one to replace it." : "Key (optional with Tailscale)", text: $key)
                    Button("Save and test") {
                        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
                        let finalKey = k.isEmpty ? (hub.config?.key ?? "") : k
                        hub.configure(HubConfig(url: url.trimmingCharacters(in: .whitespacesAndNewlines), key: finalKey))
                        key = ""
                        status = "Testing…"
                        Task { status = await hub.health() ? "Connected." : (hub.problem ?? "No answer.") }
                    }
                    if !status.isEmpty { Text(status).font(T3.font(.sm)).foregroundStyle(T3.foregroundSecondary) }
                } header: { Text("Bluey Hub") } footer: {
                    Text("Your hub runs next to Hermes on your server and is reached over Tailscale (keep the Tailscale app on). Through Tailscale your login is enough, no key needed. Your paired Mac can also send this address to the phone.")
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .onAppear { url = hub.config?.url ?? "" }
        }
    }
}
