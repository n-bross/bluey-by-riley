import SwiftUI
#if canImport(GooglyShared)
import GooglyShared
#endif

/// Pomodoro: focus and break phases with a big ring, linked to a todo, synced across devices.
/// With "Bluey schaut mit", every focus phase also runs a Bluey focus session with screen checks on the Mac.
struct PomodoroTab: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var ui: WorkspaceUI
    var info: HeaderInfo
    @State private var newTodo = ""
    @State private var todoID: UUID?
    @State private var showAllTodos = false
    @FocusState private var newTodoFocused: Bool
    @State private var showSettings = false

    private var state: PomodoroState { model.pomodoro }

    var body: some View {
        VStack(spacing: 0) {
            TabHeader(ui: ui, model: model, tab: .pomodoro, connectionName: info.connectionName, onSettings: info.onSettings) { EmptyView() }
            ScrollView {
                VStack(spacing: 22) {
                    ring
                    controls
                    if state.phase == .idle { setup }
                    todayLog
                }
                .padding(20)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Theme.background)
        .scrollDismissesKeyboard(.interactively)
        .onAppear { if todoID == nil, let open = model.todo(state.todoID), !open.done { todoID = open.id } }
        .sheet(isPresented: $showSettings) {
            PomodoroSettingsView(settings: state.settings) { new in model.changePomodoro { $0.settings = new } }
                .preferredColorScheme(.dark)
        }
    }

    private var ringColor: Color {
        switch state.phase {
        case .focus: return Theme.red
        case .shortBreak, .longBreak: return Theme.green
        case .idle: return Theme.accent
        }
    }

    private var ring: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let now = context.date
            ZStack {
                Circle().stroke(Theme.card, lineWidth: 16)
                Circle()
                    .trim(from: 0, to: state.progress(at: now))
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 16, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.5), value: state.progress(at: now))
                VStack(spacing: 8) {
                    BlueyAvatar(mood: state.phase == .focus ? (state.isPaused ? .resting : .listening) : state.phase.isBreak ? .happy : .listening)
                        .frame(width: 70, height: 62)
                    Text(FocusSession.clock(state.remaining(at: now)))
                        .font(.system(size: 54, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                    Text(state.isPaused ? "Pausiert" : state.phase.title)
                        .font(.plexMono(12))
                        .textCase(.uppercase)
                        .foregroundStyle(ringColor)
                    if state.phase != .idle, let title = model.todo(state.todoID)?.title ?? (state.label.isEmpty ? nil : state.label) {
                        Label(title, systemImage: "checklist").font(.plexSans(13)).foregroundStyle(Theme.soft).lineLimit(1)
                            .frame(maxWidth: 220)
                    }
                }
            }
            .frame(width: 290, height: 290)
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            switch state.phase {
            case .idle:
                bigButton(selectedTodo == nil ? "Erst ein Todo wählen" : state.round > 0 ? "Nächste Runde" : "Fokus starten",
                          icon: "play.fill", prominent: true) {
                    if let todo = selectedTodo { model.startFocus(for: todo) } else { newTodoFocused = true }
                }
                .opacity(selectedTodo == nil ? 0.55 : 1)
            default:
                if state.isPaused {
                    bigButton("Weiter", icon: "play.fill", prominent: true) { model.changePomodoro { $0.resume(now: Date()) } }
                } else {
                    bigButton("Pause", icon: "pause.fill", prominent: true) { model.changePomodoro { $0.pause(now: Date()) } }
                }
                bigButton(state.phase == .focus ? "Pause machen" : "Überspringen", icon: "forward.fill") {
                    model.changePomodoro { $0.skip(now: Date()) }
                }
                bigButton("Stopp", icon: "stop.fill") { model.changePomodoro { $0.stop(now: Date()) } }
            }
        }
    }

    private func bigButton(_ title: String, icon: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.plexSans(14).weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(minHeight: 46)
                .frame(maxWidth: prominent ? .infinity : nil)
                .background {
                    if prominent { RoundedRectangle(cornerRadius: 14).fill(BlobShape.linear) }
                    else { RoundedRectangle(cornerRadius: 14).fill(Theme.cardStrong) }
                }
        }
        .buttonStyle(.plain)
    }

    private var openTodos: [TodoItem] {
        model.snapshot.visibleTodos.filter { !$0.done }
            .sorted { ($0.important ? 0 : 1, $0.due ?? .distantFuture, $0.createdAt) < ($1.important ? 0 : 1, $1.due ?? .distantFuture, $1.createdAt) }
    }

    private var selectedTodo: TodoItem? { model.todo(todoID).flatMap { $0.done ? nil : $0 } }

    /// Every pomodoro belongs to a todo: pick one, or type a new one.
    private var setup: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Für welches Todo?")
            let todos = openTodos
            let shown = showAllTodos ? todos : Array(todos.prefix(5))
            if todos.isEmpty {
                Text("Noch keine offenen Todos. Schreib unten auf, woran du arbeitest.")
                    .font(.plexSans(13)).foregroundStyle(Theme.soft)
            }
            ForEach(shown) { todo in
                Button {
                    todoID = todo.id
                    newTodoFocused = false
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: todoID == todo.id ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 18))
                            .foregroundStyle(todoID == todo.id ? Theme.blue : Theme.soft)
                        Text(todo.title).font(.plexSans(15)).foregroundStyle(.white).lineLimit(2)
                        Spacer(minLength: 0)
                        if todo.important { Image(systemName: "star.fill").font(.system(size: 11)).foregroundStyle(Theme.yellow) }
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .background(todoID == todo.id ? Theme.blue.opacity(0.18) : Theme.card, in: RoundedRectangle(cornerRadius: 12))
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
            if todos.count > 5 {
                Button(showAllTodos ? "Weniger zeigen" : "Alle \(todos.count) zeigen") { showAllTodos.toggle() }
                    .font(.plexSans(13).weight(.semibold)).foregroundStyle(Theme.accentLight).buttonStyle(.plain)
            }
            HStack(spacing: 8) {
                Image(systemName: "plus").foregroundStyle(Theme.soft)
                TextField("Neues Todo für diese Runde", text: $newTodo)
                    .textFieldStyle(.plain)
                    .font(.plexSans(15))
                    .focused($newTodoFocused)
                    .submitLabel(.done)
                    .onSubmit(addNewTodo)
                if !newTodo.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button("Hinzufügen", action: addNewTodo)
                        .font(.plexSans(13).weight(.semibold)).foregroundStyle(Theme.accentLight).buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))

            if state.round > 0, let todo = selectedTodo {
                Button {
                    model.toggle(todo)
                    todoID = nil
                } label: {
                    Label("„\(todo.title)“ ist erledigt", systemImage: "checkmark.circle")
                        .font(.plexSans(13).weight(.semibold)).foregroundStyle(Theme.green)
                }
                .buttonStyle(.plain)
            }
            HStack {
                Text("\(Int(state.settings.focusMinutes)) min Fokus · \(Int(state.settings.shortBreakMinutes)) min Pause")
                    .font(.plexSans(12)).foregroundStyle(Theme.soft)
                if state.settings.watchScreen {
                    Label("Bluey schaut mit", systemImage: "eye").font(.plexSans(12)).foregroundStyle(Theme.accentLight)
                }
                Spacer()
                Button("Einstellungen") { showSettings = true }.font(.plexSans(12).weight(.semibold)).buttonStyle(.plain).foregroundStyle(Theme.accentLight)
            }
        }
        .card()
    }

    private func addNewTodo() {
        guard let id = model.addTodo(newTodo) else { return }
        todoID = id
        newTodo = ""
        newTodoFocused = false
    }

    private var todayLog: some View {
        let today = model.snapshot.pomodoroLog.filter { !$0.deleted && Calendar.current.isDateInToday($0.completedAt) }
            .sorted { $0.completedAt > $1.completedAt }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel("Heute")
                Spacer()
                HStack(spacing: 3) {
                    ForEach(0..<max(state.settings.roundsPerLongBreak, 1), id: \.self) { i in
                        Circle().fill(i < state.round % max(state.settings.roundsPerLongBreak, 1) ? Theme.red : Theme.card).frame(width: 8, height: 8)
                    }
                }
            }
            if today.isEmpty {
                Text("Noch keine Runde heute. Eine reicht für den Anfang.").font(.plexSans(13)).foregroundStyle(Theme.soft)
            } else {
                Text("\(today.count) \(today.count == 1 ? "Runde" : "Runden") · \(Int(today.map(\.minutes).reduce(0, +))) Minuten Fokus")
                    .font(.plexSans(14).weight(.semibold)).foregroundStyle(.white)
                ForEach(today) { record in
                    HStack {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.green)
                        Text(record.label.isEmpty ? "Fokus" : record.label).font(.plexSans(13)).foregroundStyle(.white).lineLimit(1)
                        Spacer()
                        Text(record.completedAt, style: .time).font(.plexMono(11)).foregroundStyle(Theme.soft)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

private struct PomodoroSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State var settings: PomodoroSettings
    var save: (PomodoroSettings) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Längen") {
                    Stepper("Fokus: \(Int(settings.focusMinutes)) min", value: $settings.focusMinutes, in: 5...120, step: 5)
                    Stepper("Kurze Pause: \(Int(settings.shortBreakMinutes)) min", value: $settings.shortBreakMinutes, in: 1...30)
                    Stepper("Lange Pause: \(Int(settings.longBreakMinutes)) min", value: $settings.longBreakMinutes, in: 5...60, step: 5)
                    Stepper("Lange Pause nach \(settings.roundsPerLongBreak) Runden", value: $settings.roundsPerLongBreak, in: 2...8)
                }
                Section {
                    Toggle("Bluey schaut mit", isOn: $settings.watchScreen)
                } footer: {
                    Text("Startet in jeder Fokus-Runde eine Bluey-Fokus-Session: Der Mac prüft alle 30 Sekunden den Bildschirm und stupst dich an, wenn du abschweifst. Braucht das gekoppelte iPhone.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Pomodoro")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Sichern") { save(settings); dismiss() } }
            }
        }
        .frame(minWidth: 380, minHeight: 380)
    }
}
