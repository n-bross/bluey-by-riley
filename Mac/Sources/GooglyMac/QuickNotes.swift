import AppKit
import SwiftUI

/// Where the Bluey Hub is (e.g. https://shipyard-1.your-tailnet.ts.net:8790). Through `tailscale serve` the
/// Mac's Tailscale login is enough; a key is optional.
enum HubSettings {
    static var url: String {
        get { UserDefaults.standard.string(forKey: "hubURL") ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "hubURL") }
    }
    static var key: String {
        get { UserDefaults.standard.string(forKey: "hubKey") ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "hubKey") }
    }
    static var configured: Bool { !url.isEmpty }

    /// What the phone gets over the paired link.
    static var phonePayload: String? {
        guard configured, let data = try? JSONSerialization.data(withJSONObject: ["url": url, "key": key]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

struct MacNote: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var title: String
    var body: String?
    var preview: String?
    var pinned: Bool
    var updated: Double
}

/// The notes part of the hub's API, for the Mac.
enum HubNotesAPI {
    enum Failure: LocalizedError {
        case notSetUp, failed(String)
        var errorDescription: String? {
            switch self {
            case .notSetUp: return "Add your Bluey Hub address in Settings ▸ Hermes."
            case .failed(let why): return why
            }
        }
    }

    private static func call(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Data {
        guard HubSettings.configured, let url = URL(string: HubSettings.url.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + path) else {
            throw Failure.notSetUp
        }
        var r = URLRequest(url: url, timeoutInterval: 15)
        r.httpMethod = method
        if !HubSettings.key.isEmpty { r.setValue("Bearer \(HubSettings.key)", forHTTPHeaderField: "Authorization") }
        if let body {
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: r) }
        catch { throw Failure.failed("Can't reach the hub (\(error.localizedDescription)). Is Tailscale on?") }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw Failure.failed("Hub said \(code).") }
        return data
    }

    static func health() async -> String {
        guard let data = try? await call("health"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "No answer." }
        if json["authorized"] as? Bool == false { return "Reached the hub, but it doesn't know this login. Add it to tailnet_logins or set a key." }
        return "Connected" + ((json["you"] as? String).map { " as \($0)" } ?? "") + "."
    }

    static func list() async throws -> [MacNote] { try JSONDecoder().decode([MacNote].self, from: try await call("notes")) }
    static func note(_ id: String) async throws -> MacNote { try JSONDecoder().decode(MacNote.self, from: try await call("notes/\(id)")) }
    static func create(_ body: String) async throws -> MacNote {
        try JSONDecoder().decode(MacNote.self, from: try await call("notes", method: "POST", body: ["body": body]))
    }
    static func save(_ id: String, body: String? = nil, pinned: Bool? = nil) async throws {
        var b: [String: Any] = [:]
        if let body { b["body"] = body }
        if let pinned { b["pinned"] = pinned }
        _ = try await call("notes/\(id)", method: "PUT", body: b)
    }
    static func delete(_ id: String) async throws { _ = try await call("notes/\(id)", method: "DELETE") }
}

@MainActor
final class QuickNotesModel: ObservableObject {
    @Published var notes: [MacNote] = []
    @Published var selected: String?
    @Published var text = ""
    @Published var problem: String?
    @Published var status = ""
    @Published var search = ""
    private var saveTask: Task<Void, Never>?
    private var loadedID: String?
    /// The text as last loaded or saved, so opening a note never counts as an edit.
    private var savedText = ""

    func refresh() async {
        do { notes = try await HubNotesAPI.list(); problem = nil } catch { problem = error.localizedDescription }
        if selected == nil { await open(notes.first?.id) }
    }

    func open(_ id: String?) async {
        await flush()
        selected = id
        loadedID = nil
        guard let id else { text = ""; return }
        if let n = try? await HubNotesAPI.note(id) { text = n.body ?? "" }
        savedText = text
        loadedID = id
        status = ""
    }

    func newNote() async {
        await flush()
        do {
            let n = try await HubNotesAPI.create("")
            await refresh()
            await open(n.id)
        } catch { problem = error.localizedDescription }
    }

    func edited() {
        guard let id = loadedID, id == selected, text != savedText else { return }
        status = "Editing"
        saveTask?.cancel()
        let body = text
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await self?.write(id, body)
        }
    }

    private func write(_ id: String, _ body: String) async {
        do {
            try await HubNotesAPI.save(id, body: body)
            savedText = body
            status = "Saved"
            if let i = notes.firstIndex(where: { $0.id == id }) {
                notes[i].title = body.split(separator: "\n").first.map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "# ")) } ?? "Untitled"
            }
        } catch { status = "Not saved"; problem = error.localizedDescription }
    }

    func flush() async {
        saveTask?.cancel()
        if let id = loadedID, id == selected, text != savedText { await write(id, text) }
    }

    func togglePin(_ note: MacNote) async {
        try? await HubNotesAPI.save(note.id, pinned: !note.pinned)
        await refresh()
    }

    func delete(_ note: MacNote) async {
        try? await HubNotesAPI.delete(note.id)
        if selected == note.id { selected = nil; loadedID = nil; text = "" }
        await refresh()
    }
}

/// Raycast-style quick notes: a floating window that stays above everything, toggled by a shortcut.
/// Notes live in the Bluey Hub, so they're the same on the phone and for Hermes.
@MainActor
final class QuickNotesWindow {
    let model = QuickNotesModel()
    private var panel: NSPanel?

    var isVisible: Bool { panel?.isVisible == true }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 440),
                            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.title = "Notes"
            p.titlebarAppearsTransparent = true
            p.titleVisibility = .hidden
            p.isFloatingPanel = true
            p.level = .floating
            p.hidesOnDeactivate = false
            p.isMovableByWindowBackground = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentView = NSHostingView(rootView: QuickNotesView(model: model))
            p.setFrameAutosaveName("BlueyQuickNotes")
            if p.frame.origin == .zero { p.center() }
            panel = p
        }
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
        Task { await model.refresh() }
    }

    func hide() {
        Task { await model.flush() }
        panel?.orderOut(nil)
    }
}


struct QuickNotesView: View {
    @ObservedObject var model: QuickNotesModel

    private var shown: [MacNote] {
        model.notes.filter { model.search.isEmpty || $0.title.localizedCaseInsensitiveContains(model.search)
            || ($0.preview ?? "").localizedCaseInsensitiveContains(model.search) }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search", text: $model.search).textFieldStyle(.plain)
                    Button { Task { await model.newNote() } } label: { Image(systemName: "square.and.pencil") }
                        .buttonStyle(.plain).help("New note (⌘N)").keyboardShortcut("n", modifiers: .command)
                }
                .padding(.horizontal, 12).padding(.top, 34).padding(.bottom, 8)
                List(selection: Binding(get: { model.selected }, set: { id in Task { await model.open(id) } })) {
                    ForEach(shown) { note in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                if note.pinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Color(hex: Keramik.accent)) }
                                Text(note.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            }
                            if let p = note.preview, !p.isEmpty { Text(p).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        .tag(note.id)
                        .contextMenu {
                            Button(note.pinned ? "Unpin" : "Pin") { Task { await model.togglePin(note) } }
                            Button("Delete", role: .destructive) { Task { await model.delete(note) } }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
            .frame(width: 210)
            .background(.ultraThinMaterial)

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                if let problem = model.problem {
                    Text(problem).font(.system(size: 12)).foregroundStyle(Color(hex: Keramik.red)).padding(12)
                }
                if model.selected != nil {
                    TextEditor(text: $model.text)
                        .font(.system(size: 14))
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 14).padding(.top, 30)
                        .onChange(of: model.text) { _, _ in model.edited() }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "note.text").font(.system(size: 28)).foregroundStyle(.secondary)
                        Text(model.notes.isEmpty ? "No notes yet" : "Pick a note").font(.system(size: 14, weight: .medium))
                        Button("New note") { Task { await model.newNote() } }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                HStack {
                    Spacer()
                    Text(model.status).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .padding(8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 520, minHeight: 320)
    }
}
