import SwiftUI
#if canImport(GooglyShared)
import GooglyShared
#endif

/// Todos, ADHD-friendly: a quick add field, today / important filters and realistic (×3) estimates.
struct TodosTab: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var ui: WorkspaceUI
    var info: HeaderInfo
    @State private var newTitle = ""
    @State private var filter: Filter = .all
    @State private var showDone = false
    @State private var editing: TodoItem?
    @FocusState private var addFocused: Bool

    enum Filter: String, CaseIterable, Identifiable {
        case all = "Alle", today = "Heute", important = "Wichtig"
        var id: String { rawValue }
    }

    private var todos: [TodoItem] {
        let calendar = Calendar.current
        return model.snapshot.visibleTodos.filter { todo in
            guard ui.matches(todo.title, todo.notes) else { return false }
            switch filter {
            case .all: return true
            case .today: return todo.due.map { calendar.isDateInToday($0) || $0 < calendar.startOfDay(for: Date()) } ?? false
            case .important: return todo.important
            }
        }
    }

    private var open: [TodoItem] {
        todos.filter { !$0.done }.sorted {
            ($0.important ? 0 : 1, $0.due ?? .distantFuture, $0.createdAt) < ($1.important ? 0 : 1, $1.due ?? .distantFuture, $1.createdAt)
        }
    }
    private var done: [TodoItem] { todos.filter(\.done).sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) } }

    var body: some View {
        VStack(spacing: 0) {
            TabHeader(ui: ui, model: model, tab: .todos, connectionName: info.connectionName, onSettings: info.onSettings) {
                HStack(spacing: 8) {
                    ForEach(Filter.allCases) { f in
                        FilterChip(title: f.rawValue, selected: filter == f,
                                   icon: f == .today ? "sun.max" : f == .important ? "star" : nil) { filter = f }
                    }
                }
            }
            addField
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            if open.isEmpty && done.isEmpty {
                BlueyEmptyState(title: filter == .all ? "Alles frei!" : "Nichts hier",
                                subtitle: "Schreib oben, was dir im Kopf rumschwirrt. Klein anfangen zählt.", mood: .happy)
            } else {
                List {
                    if open.isEmpty {
                        Text("Alles erledigt. Stark!").font(.plexSans(14)).foregroundStyle(Theme.soft).listRowBackground(Color.clear)
                    }
                    ForEach(open) { todo in row(todo) }
                    if !done.isEmpty {
                        Section {
                            if showDone { ForEach(done) { todo in row(todo) } }
                        } header: {
                            Button { withAnimation { showDone.toggle() } } label: {
                                HStack {
                                    SectionLabel("Erledigt (\(done.count))")
                                    Image(systemName: showDone ? "chevron.down" : "chevron.right").font(.system(size: 10)).foregroundStyle(Theme.soft)
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .background(Theme.background)
        .onChange(of: ui.composeCount) { _, _ in ui.endSearch(); addFocused = true }
        .sheet(item: $editing) { todo in
            TodoEditor(todo: todo, save: { model.update($0) }, delete: { model.delete($0) })
                .preferredColorScheme(.dark)
        }
    }

    private var addField: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.circle.fill").font(.system(size: 20)).foregroundStyle(Theme.accentLight)
            TextField("Neues Todo…", text: $newTitle)
                .textFieldStyle(.plain)
                .font(.plexSans(15))
                .focused($addFocused)
                .onSubmit(add)
            if !newTitle.isEmpty {
                Button("Hinzufügen", action: add).font(.plexSans(13).weight(.semibold)).buttonStyle(.plain).foregroundStyle(Theme.accentLight)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
    }

    private func add() {
        let due: Date? = filter == .today ? Date() : nil
        model.addTodo(newTitle, important: filter == .important, due: due)
        newTitle = ""
        addFocused = true
    }

    private func row(_ todo: TodoItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button { withAnimation { model.toggle(todo) } } label: {
                Image(systemName: todo.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(todo.done ? Theme.green : Theme.soft)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(todo.done ? "Als offen markieren" : "Erledigt")

            VStack(alignment: .leading, spacing: 4) {
                Text(todo.title)
                    .font(.plexSans(15))
                    .foregroundStyle(todo.done ? Theme.soft : .white)
                    .strikethrough(todo.done, color: Theme.soft)
                HStack(spacing: 10) {
                    if let due = todo.due {
                        Label(Self.dueText(due), systemImage: "calendar")
                            .foregroundStyle(!todo.done && Calendar.current.startOfDay(for: due) < Calendar.current.startOfDay(for: Date()) ? Theme.peach : Theme.soft)
                    }
                    if let minutes = todo.estimateMinutes {
                        Label("\(minutes) min · ×3 ≈ \(minutes * 3) min", systemImage: "clock")
                    }
                    if !todo.notes.isEmpty { Image(systemName: "text.alignleft") }
                }
                .font(.plexSans(11))
                .foregroundStyle(Theme.soft)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { editing = todo }

            Button { var t = todo; t.important.toggle(); model.update(t) } label: {
                Image(systemName: todo.important ? "star.fill" : "star")
                    .foregroundStyle(todo.important ? Theme.yellow : Theme.soft.opacity(0.6))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(todo.important ? "Nicht mehr wichtig" : "Wichtig")
        }
        .padding(.vertical, 6)
        .listRowBackground(Color.clear)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { model.delete(todo) } label: { Label("Löschen", systemImage: "trash") }
        }
        .swipeActions(edge: .leading) {
            Button { var t = todo; t.due = Date(); model.update(t) } label: { Label("Heute", systemImage: "sun.max") }.tint(Theme.accent)
            if !todo.done && !model.pomodoro.isRunning {
                Button { startPomodoro(todo) } label: { Label("Pomodoro", systemImage: "timer") }.tint(Theme.red)
            }
        }
        .contextMenu {
            Button { var t = todo; t.due = Date(); model.update(t) } label: { Label("Für heute", systemImage: "sun.max") }
            if !todo.done {
                Button { startPomodoro(todo) } label: { Label("Pomodoro starten", systemImage: "timer") }
            }
            Button { editing = todo } label: { Label("Bearbeiten", systemImage: "pencil") }
            Button(role: .destructive) { model.delete(todo) } label: { Label("Löschen", systemImage: "trash") }
        }
    }

    private func startPomodoro(_ todo: TodoItem) {
        model.startFocus(for: todo)
        ui.requestedTab = .pomodoro
    }

    static func dueText(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Heute" }
        if calendar.isDateInTomorrow(date) { return "Morgen" }
        if calendar.isDateInYesterday(date) { return "Gestern" }
        return date.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "de_DE")))
    }
}

private struct TodoEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var todo: TodoItem
    var save: (TodoItem) -> Void
    var delete: (TodoItem) -> Void
    @State private var hasDue = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Aufgabe") {
                    TextField("Titel", text: $todo.title)
                    TextField("Notizen, erster Schritt…", text: $todo.notes, axis: .vertical).lineLimit(3...8)
                }
                Section("Planung") {
                    Toggle("Wichtig", isOn: $todo.important)
                    Toggle("Fällig", isOn: $hasDue)
                    if hasDue {
                        DatePicker("Datum", selection: Binding(get: { todo.due ?? Date() }, set: { todo.due = $0 }), displayedComponents: .date)
                    }
                    Stepper(value: Binding(get: { todo.estimateMinutes ?? 0 }, set: { todo.estimateMinutes = $0 == 0 ? nil : $0 }), in: 0...480, step: 5) {
                        if let m = todo.estimateMinutes {
                            Text("Schätzung \(m) min · realistisch \(m * 3) min")
                        } else {
                            Text("Keine Zeitschätzung")
                        }
                    }
                }
                Section {
                    Button("Löschen", role: .destructive) { delete(todo); dismiss() }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Todo")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        if !hasDue { todo.due = nil } else if todo.due == nil { todo.due = Date() }
                        save(todo); dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 380, minHeight: 420)
        .onAppear { hasDue = todo.due != nil }
    }
}
