import SwiftUI
#if canImport(GooglyShared)
import GooglyShared
#endif

/// Notes: a searchable list and a plain editor that saves as you type.
struct NotesTab: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var ui: WorkspaceUI
    var info: HeaderInfo
    @State private var selected: UUID?
    @State private var newNoteID: UUID?
    @State private var pinnedOnly = false

    private var notes: [NoteItem] {
        model.snapshot.visibleNotes.filter { (!pinnedOnly || $0.pinned) && ui.matches($0.title, $0.body) }
    }

    private var header: some View {
        TabHeader(ui: ui, model: model, tab: .notes, connectionName: info.connectionName, onSettings: info.onSettings) {
            if model.snapshot.notes.contains(where: { !$0.deleted && $0.pinned }) {
                HStack(spacing: 8) {
                    FilterChip(title: "Alle", selected: !pinnedOnly) { pinnedOnly = false }
                    FilterChip(title: "Angeheftet", selected: pinnedOnly, icon: "pin") { pinnedOnly = true }
                }
            }
        }
    }

    private func newNote() {
        ui.endSearch()
        pinnedOnly = false
        newNoteID = model.addNote()
        selected = newNoteID
    }

    var body: some View {
        #if os(iOS)
        NavigationStack {
            VStack(spacing: 0) {
                header
                list
            }
            .background(Theme.background)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
                if let id = selected {
                    NoteEditor(model: model, id: id, focusTitle: id == newNoteID).id(id)
                        .onAppear { ui.inDetail = true }
                        .onDisappear { ui.inDetail = false }
                }
            }
        }
        .onChange(of: ui.composeCount) { _, _ in newNote() }
        #else
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                list
            }
            .frame(width: 280)
            .background(Theme.panel.opacity(0.35))
            Divider().overlay(Theme.line)
            if let id = selected, model.note(id) != nil {
                NoteEditor(model: model, id: id, focusTitle: id == newNoteID).id(id)
            } else {
                BlueyEmptyState(title: "Notizen", subtitle: "Wähle links eine Notiz oder leg eine neue an.")
            }
        }
        .onChange(of: ui.composeCount) { _, _ in newNote() }
        #endif
    }

    private var list: some View {
        let notes = notes
        return VStack(spacing: 10) {
            if notes.isEmpty {
                BlueyEmptyState(title: ui.search.isEmpty ? "Noch keine Notizen" : "Nichts gefunden",
                                subtitle: ui.search.isEmpty ? "Mit „Neue Notiz“ kannst du einen Gedanken festhalten." : "Versuch ein anderes Wort.")
            } else {
                List {
                    ForEach(notes) { note in
                        Button { newNoteID = nil; selected = note.id } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 5) {
                                    if note.pinned { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(Theme.yellow) }
                                    Text(note.displayTitle).font(.plexSans(14).weight(.medium)).foregroundStyle(.white).lineLimit(1)
                                }
                                Text(Self.preview(note)).font(.plexSans(12)).foregroundStyle(Theme.soft).lineLimit(2)
                                Text(note.updatedAt, format: .relative(presentation: .named)).font(.plexSans(10)).foregroundStyle(Theme.soft.opacity(0.6))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(selected == note.id ? Theme.cardStrong : Color.clear)
                        .swipeActions {
                            Button(role: .destructive) { delete(note) } label: { Label("Löschen", systemImage: "trash") }
                        }
                        .contextMenu {
                            Button { var n = note; n.pinned.toggle(); model.update(n) } label: {
                                Label(note.pinned ? "Lösen" : "Anheften", systemImage: "pin")
                            }
                            Button(role: .destructive) { delete(note) } label: { Label("Löschen", systemImage: "trash") }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func delete(_ note: NoteItem) {
        if selected == note.id { selected = nil }
        model.delete(note)
    }

    static func preview(_ note: NoteItem) -> String {
        let body = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let rest = note.title.isEmpty ? body.split(separator: "\n").dropFirst().joined(separator: " ") : body.replacingOccurrences(of: "\n", with: " ")
        return rest.isEmpty ? "Kein weiterer Text" : rest
    }
}

private struct NoteEditor: View {
    @ObservedObject var model: WorkspaceModel
    let id: UUID
    let focusTitle: Bool
    @FocusState private var titleFocused: Bool
    @State private var title = ""
    @State private var text = ""
    @State private var loaded = false
    @State private var saveWork: DispatchWorkItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Titel", text: $title)
                    .focused($titleFocused)
                    .textFieldStyle(.plain)
                    .font(.fredoka(26))
                    .foregroundStyle(.white)
                if let note = model.note(id) {
                    Button { var n = note; n.pinned.toggle(); model.update(n) } label: {
                        Image(systemName: note.pinned ? "pin.fill" : "pin").foregroundStyle(note.pinned ? Theme.yellow : Theme.soft)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(note.pinned ? "Lösen" : "Anheften")
                }
            }
            if let note = model.note(id) {
                Text("Geändert \(note.updatedAt.formatted(.relative(presentation: .named)))")
                    .font(.plexSans(11)).foregroundStyle(Theme.soft)
            }
            TextEditor(text: $text)
                .font(.plexSans(15))
                .scrollContentBackground(.hidden)
                .foregroundStyle(.white.opacity(0.92))
        }
        .padding(20)
        .background(Theme.background)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            load()
            if focusTitle { titleFocused = true }
        }
        .onChange(of: title) { _, _ in scheduleSave() }
        .onChange(of: text) { _, _ in scheduleSave() }
        .onDisappear { saveWork?.perform() }
        .onChange(of: model.note(id)?.updatedAt) { _, _ in
            // Another device changed it while it's open and we have nothing unsaved: show theirs.
            guard saveWork == nil, let note = model.note(id), note.title != title || note.body != text else { return }
            title = note.title; text = note.body
        }
    }

    private func load() {
        guard !loaded, let note = model.note(id) else { return }
        title = note.title; text = note.body
        loaded = true
    }

    private func scheduleSave() {
        guard loaded, let note = model.note(id), note.title != title || note.body != text else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem {
            saveWork = nil
            guard var n = model.note(id) else { return }
            n.title = title; n.body = text
            model.update(n)
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }
}
