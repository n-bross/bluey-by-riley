import SwiftUI
#if canImport(GooglyShared)
import GooglyShared
#endif

/// Notes: a searchable list and an Apple-Notes-style editor that combines typed Markdown text
/// with an embedded pressure-sensitive handwriting canvas (Huion Note USB/BLE + Trackpad/Touch),
/// offline BLE sync, AI handwriting OCR, todo extraction, and Bluey Hub sync.
struct NotesTab: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var ui: WorkspaceUI
    var info: HeaderInfo
    @State private var selected: UUID?
    @State private var newNoteID: UUID?
    @State private var filter: NoteFilter = .all
    @State private var showHuionPopover = false
    @State private var pinInput = ""

    private enum NoteFilter: String { case all, handwriting, pinned }

    private var notes: [NoteItem] {
        model.snapshot.visibleNotes.filter { note in
            let filterOK: Bool
            switch filter {
            case .all: filterOK = true
            case .handwriting: filterOK = note.hasDrawing
            case .pinned: filterOK = note.pinned
            }
            return filterOK && ui.matches(note.title, note.body)
        }
    }

    private var header: some View {
        TabHeader(ui: ui, model: model, tab: .notes, connectionName: info.connectionName, onSettings: info.onSettings) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    FilterChip(title: "Alle", selected: filter == .all) { filter = .all }
                    if model.snapshot.visibleNotes.contains(where: \.hasDrawing) {
                        FilterChip(title: "Stift", selected: filter == .handwriting, icon: "scribble") { filter = .handwriting }
                    }
                    if model.snapshot.visibleNotes.contains(where: \.pinned) {
                        FilterChip(title: "Angeheftet", selected: filter == .pinned, icon: "pin") { filter = .pinned }
                    }
                }
                if model.huion.isAvailable {
                    huionBar
                }
            }
        }
    }

    private var huionBar: some View {
        HuionSidebarBar(
            huion: model.huion,
            showPopover: $showHuionPopover,
            pinInput: $pinInput,
            onNewInkNote: { newInkNote() }
        )
    }

    private func newNote() {
        ui.endSearch()
        filter = .all
        newNoteID = model.addNote()
        selected = newNoteID
    }

    private func newInkNote(paper: InkPaperStyle = .paper) {
        ui.endSearch()
        filter = .all
        newNoteID = model.addNote(drawing: InkDrawing(paper: paper), source: "huion-live")
        selected = newNoteID
    }

    private func consumePendingNoteSelection() {
        guard let pending = model.huion.pendingSelectNoteID else { return }
        model.huion.pendingSelectNoteID = nil
        ui.endSearch()
        filter = .all
        newNoteID = pending
        selected = pending
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
                    NoteEditor(model: model, huion: model.huion, id: id, focusTitle: id == newNoteID).id(id)
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
            .frame(width: 292)
            .background(Theme.panel.opacity(0.35))
            Divider().overlay(Theme.line)
            if let id = selected, model.note(id) != nil {
                NoteEditor(model: model, huion: model.huion, id: id, focusTitle: id == newNoteID).id(id)
            } else {
                VStack(spacing: 14) {
                    BlueyEmptyState(
                        title: "Notizen",
                        subtitle: model.huion.isConnected
                            ? "Schreib einfach mit deinem Huion-Stift los oder wähle links eine Notiz."
                            : "Wähle links eine Notiz oder leg eine neue an."
                    )
                    if model.huion.isAvailable {
                        HStack(spacing: 10) {
                            Button { newInkNote() } label: {
                                Label("Neue Handschrift-Notiz", systemImage: "pencil.and.scribble")
                            }
                            .buttonStyle(.borderedProminent)
                            Button { model.huion.syncOffline?(nil) } label: {
                                Label("Offline-Seiten holen", systemImage: "arrow.down.doc")
                            }
                            .buttonStyle(.bordered)
                            Button { model.huion.openScreenAnnotator?() } label: {
                                Label("Auf Bildschirm zeichnen", systemImage: "scribble.variable")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: ui.composeCount) { _, _ in newNote() }
        .onAppear { consumePendingNoteSelection() }
        .onChange(of: model.huion.pendingSelectNoteID) { _, _ in consumePendingNoteSelection() }
        // Apple-Notes magic: touching the Huion pen when no note is open automatically starts a fresh ink note!
        .onChange(of: model.huion.liveSampleSeq) { _, _ in
            if selected == nil, model.huion.liveSample?.touching == true {
                newInkNote()
            }
        }
        #endif
    }

    private var list: some View {
        let notes = notes
        return VStack(spacing: 10) {
            if notes.isEmpty {
                BlueyEmptyState(title: ui.search.isEmpty ? "Noch keine Notizen" : "Nichts gefunden",
                                subtitle: ui.search.isEmpty ? "Mit „Neue Notiz“ oder dem Huion-Stift kannst du loslegen." : "Versuch ein anderes Wort.")
            } else {
                List {
                    ForEach(notes) { note in
                        Button { newNoteID = nil; selected = note.id } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 5) {
                                    if note.pinned {
                                        Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(Theme.yellow)
                                    }
                                    if note.hasDrawing {
                                        Image(systemName: "scribble").font(.system(size: 10)).foregroundStyle(Theme.accentLight)
                                    }
                                    Text(note.displayTitle).font(.plexSans(14).weight(.medium)).foregroundStyle(.white).lineLimit(1)
                                    Spacer(minLength: 4)
                                    if note.hubNoteID != nil {
                                        Image(systemName: "network").font(.system(size: 9)).foregroundStyle(Theme.green.opacity(0.8))
                                            .help("Im Bluey Hub / für Hermes synchronisiert")
                                    }
                                }
                                Text(Self.preview(note)).font(.plexSans(12)).foregroundStyle(Theme.soft).lineLimit(2)
                                HStack(spacing: 6) {
                                    Text(note.updatedAt, format: .relative(presentation: .named))
                                    if let range = note.drawing?.videoTimeRange {
                                        Text("·")
                                        Text("Video \(InkDrawing.formatVideoTime(range.start))")
                                            .foregroundStyle(Theme.red.opacity(0.9))
                                    }
                                }
                                .font(.plexSans(10))
                                .foregroundStyle(Theme.soft.opacity(0.6))
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
        if !rest.isEmpty { return rest }
        if let d = note.drawing, !d.isEmpty { return "Handschrift (\(d.strokes.count) Striche)" }
        return "Kein weiterer Text"
    }
}

// MARK: - Huion Sidebar Control Bar

private struct HuionSidebarBar: View {
    @ObservedObject var huion: HuionIntegration
    @Binding var showPopover: Bool
    @Binding var pinInput: String
    var onNewInkNote: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(huion.isSyncingOffline ? Theme.accentLight : (huion.isConnected ? Theme.green : Theme.soft.opacity(0.4)))
                    .frame(width: 7, height: 7)
                Text(huion.statusText)
                    .font(.plexSans(11).weight(.medium))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
                Spacer()

                Button(action: onNewInkNote) {
                    Image(systemName: "pencil.and.scribble")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accentLight)
                .help("Neue Handschrift-Notiz")

                Button { huion.syncOffline?(nil) } label: {
                    if huion.isSyncingOffline {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.down.doc")
                            .font(.system(size: 12))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.85))
                .disabled(huion.isSyncingOffline)
                .help("Offline-Seiten per Bluetooth vom Huion Note holen")

                Button { huion.openScreenAnnotator?() } label: {
                    Image(systemName: "scribble.variable")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.85))
                .help("Auf Bildschirm zeichnen (⌃⌥A)")

                Button { showPopover.toggle() } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.soft)
                .help("Huion-Einstellungen")
                .popover(isPresented: $showPopover) {
                    huionSettingsPopover
                }
            }

            if let started = huion.recordingStartedAt {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let elapsed = max(0, ctx.date.timeIntervalSince(started))
                    HStack(spacing: 6) {
                        Circle().fill(Theme.red).frame(width: 6, height: 6)
                        Text("\(huion.recordingLabel ?? "Aufnahme") · \(InkDrawing.formatVideoTime(elapsed))")
                            .font(.plexMono(10).weight(.semibold))
                            .foregroundStyle(.white.opacity(0.92))
                        Spacer()
                        if huion.recordingLabel == "Video-Timer" {
                            Button("Stopp") { huion.toggleVideoTimer?() }
                                .font(.plexSans(10).weight(.medium))
                                .buttonStyle(.plain)
                                .foregroundStyle(Theme.red)
                        } else if huion.openMeetingWindow != nil {
                            Button("Call") { huion.openMeetingWindow?() }
                                .font(.plexSans(10).weight(.medium))
                                .buttonStyle(.plain)
                                .foregroundStyle(Theme.accentLight)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.red.opacity(0.16), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }

            if let msg = huion.syncMessage, !msg.isEmpty {
                Text(msg)
                    .font(.plexSans(10))
                    .foregroundStyle(Theme.soft)
                    .lineLimit(2)
            }

            if huion.pinRequired {
                HStack(spacing: 6) {
                    SecureField("6-stellige PIN", text: $pinInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.plexMono(11))
                    Button("OK") {
                        let p = pinInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        pinInput = ""
                        huion.syncOffline?(p)
                    }
                    .controlSize(.small)
                    .disabled(pinInput.count != 6)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.line, lineWidth: 1))
    }

    private var huionSettingsPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Huion Note X10").font(.fredoka(17)).foregroundStyle(.white)

            HStack {
                Text("USB:").foregroundStyle(Theme.soft)
                Text(huion.usbConnected ? "Verbunden (Live-Stift aktiv)" : "Nicht angeschlossen")
                    .foregroundStyle(huion.usbConnected ? Theme.green : Theme.soft)
            }
            .font(.plexSans(12))

            HStack(spacing: 8) {
                Button(huion.bleConnected ? "BLE trennen" : "Per Bluetooth verbinden") {
                    if huion.bleConnected { huion.disconnectBLE?() } else { huion.connectBLE?() }
                }
                .controlSize(.small)
                if huion.bleConnected {
                    Button("BLE Live-Stift") { huion.startBLELivePen?() }
                        .controlSize(.small)
                }
            }

            Picker("Notizbuch-Ausrichtung", selection: Binding(
                get: { huion.orientation },
                set: { huion.setOrientation?($0) }
            )) {
                ForEach(HuionProtocol.Orientation.allCases, id: \.self) { o in
                    Text(o.title).tag(o)
                }
            }
            .font(.plexSans(12))

            Toggle("Offline-Seiten nach Import vom Gerät löschen", isOn: Binding(
                get: { huion.deleteAfterSync },
                set: { huion.setDeleteAfterSync?($0) }
            ))
            .font(.plexSans(12))

            Divider()

            HStack(spacing: 8) {
                Button(huion.recordingStartedAt != nil && huion.recordingLabel == "Video-Timer" ? "Video-Timer stoppen" : "Video-Timer starten") {
                    huion.toggleVideoTimer?()
                }
                .controlSize(.small)
                if huion.openMeetingWindow != nil {
                    Button("Call-Notizen…") {
                        showPopover = false
                        huion.openMeetingWindow?()
                    }
                    .controlSize(.small)
                }
            }

            HStack {
                Button("Offline-Seiten synchronisieren") {
                    showPopover = false
                    huion.syncOffline?(nil)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Spacer()
                Button("Ordner öffnen") {
                    showPopover = false
                    huion.openArchiveFolder?()
                }
                .controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}

// MARK: - Integrated Text + Ink Note Editor

private struct NoteEditor: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var huion: HuionIntegration
    let id: UUID
    let focusTitle: Bool

    @FocusState private var titleFocused: Bool
    @State private var title = ""
    @State private var text = ""
    @State private var drawing = InkDrawing()
    @State private var showCanvas = false
    @State private var loaded = false
    @State private var saveWork: DispatchWorkItem?
    @State private var ocrBusy = false
    @State private var hubBusy = false
    @State private var feedback: String?
    @State private var extractedTodos: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            topRow
            metaRow

            if let feedback {
                Text(feedback)
                    .font(.plexSans(12))
                    .foregroundStyle(Theme.accentLight)
            }

            if !extractedTodos.isEmpty {
                extractedTodosBanner
            }

            // Apple-Notes-style layout: seamless ink canvas + Markdown editor together!
            if showCanvas {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        InkCanvasView(
                            drawing: $drawing,
                            liveSample: huion.liveSample,
                            liveSampleSeq: huion.liveSampleSeq,
                            recordingOffsetProvider: { huion.currentRecordingOffset },
                            onStrokeCommitted: { scheduleSave() }
                        )
                        .frame(maxHeight: 540)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Notiztext / Transkription (Markdown)")
                                .font(.plexSans(11).weight(.medium))
                                .foregroundStyle(Theme.soft)
                            TextEditor(text: $text)
                                .font(.plexSans(14))
                                .scrollContentBackground(.hidden)
                                .foregroundStyle(.white.opacity(0.92))
                                .frame(minHeight: 150)
                                .padding(10)
                                .background(Theme.card.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.line, lineWidth: 1))
                        }
                    }
                    .padding(.bottom, 12)
                }
            } else {
                TextEditor(text: $text)
                    .font(.plexSans(15))
                    .scrollContentBackground(.hidden)
                    .foregroundStyle(.white.opacity(0.92))
            }
        }
        .padding(20)
        .background(Theme.background)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            load()
            if focusTitle && !showCanvas { titleFocused = true }
        }
        .onChange(of: title) { _, _ in scheduleSave() }
        .onChange(of: text) { _, _ in scheduleSave() }
        .onDisappear { saveWork?.perform() }
        // Auto-open the ink canvas the instant the user starts writing with the Huion pen!
        .onChange(of: huion.liveSampleSeq) { _, _ in
            if !showCanvas, huion.liveSample?.touching == true {
                showCanvas = true
            }
        }
        .onChange(of: model.note(id)?.updatedAt) { _, _ in
            guard saveWork == nil, let note = model.note(id) else { return }
            let noteDrawing = note.drawing ?? InkDrawing()
            if note.title != title || note.body != text || noteDrawing != drawing {
                title = note.title
                text = note.body
                drawing = noteDrawing
                if !noteDrawing.isEmpty { showCanvas = true }
            }
        }
    }

    private var topRow: some View {
        HStack(spacing: 10) {
            TextField("Titel", text: $title)
                .focused($titleFocused)
                .textFieldStyle(.plain)
                .font(.fredoka(26))
                .foregroundStyle(.white)

            // Toggle embedded Apple-Notes-style ink canvas
            Button {
                withAnimation(.snappy(duration: 0.2)) { showCanvas.toggle() }
            } label: {
                Label(showCanvas ? "Stift aktiv" : "Stift", systemImage: showCanvas ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
                    .font(.plexSans(12).weight(.medium))
                    .foregroundStyle(showCanvas ? .white : Theme.soft)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(showCanvas ? Theme.blue.opacity(0.75) : Theme.card, in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Handschrift-Zeichenfläche ein-/ausblenden")

            // AI Handwriting OCR -> Markdown + Todos + Hub Sync
            if !drawing.isEmpty, huion.transcribeDrawing != nil {
                Button { runOCR() } label: {
                    HStack(spacing: 5) {
                        if ocrBusy {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "sparkles")
                        }
                        Text("Handschrift → Text")
                    }
                    .font(.plexSans(12).weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.cardStrong, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(ocrBusy)
                .help("Handschrift mit KI in Markdown umwandeln & nach Bluey Hub syncen")
            }

            // Bluey Hub / Hermes Sync button
            if huion.syncNoteToHub != nil {
                let synced = model.note(id)?.hubNoteID != nil
                Button { pushToHub() } label: {
                    HStack(spacing: 4) {
                        if hubBusy {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: synced ? "checkmark.icloud" : "icloud.and.arrow.up")
                        }
                        Text(synced ? "Hub ✓" : "An Hub")
                    }
                    .font(.plexSans(11).weight(.medium))
                    .foregroundStyle(synced ? Theme.green : Theme.soft)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Theme.card, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(hubBusy)
                .help("Notiz mit Bluey Hub (iPhone & Hermes) synchronisieren")
            }

            // Export local SVG/PNG
            if !drawing.isEmpty, huion.exportDrawing != nil {
                Button { exportLocal() } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.soft)
                }
                .buttonStyle(.plain)
                .help("Als SVG & PNG lokal speichern (~/Documents/Bluey Notes/Huion)")
            }

            if let note = model.note(id) {
                Button { var n = note; n.pinned.toggle(); model.update(n) } label: {
                    Image(systemName: note.pinned ? "pin.fill" : "pin")
                        .foregroundStyle(note.pinned ? Theme.yellow : Theme.soft)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(note.pinned ? "Lösen" : "Anheften")
            }
        }
    }

    @ViewBuilder
    private var metaRow: some View {
        if let note = model.note(id) {
            HStack(spacing: 10) {
                Text("Geändert \(note.updatedAt.formatted(.relative(presentation: .named)))")
                if let src = note.source {
                    Text("·")
                    Text(src == "huion-offline" ? "Huion Offline-Sync" : src == "screen-annotation" ? "Bildschirm-Notiz" : "Huion Live")
                }
                if !drawing.isEmpty {
                    Text("· \(drawing.strokes.count) Striche")
                }
                if let range = drawing.videoTimeRange {
                    let startStr = InkDrawing.formatVideoTime(range.start)
                    let endStr = InkDrawing.formatVideoTime(range.end)
                    let label = abs(range.end - range.start) < 2 ? "Video \(startStr)" : "Video \(startStr)–\(endStr)"
                    Text("·")
                    Label(label, systemImage: "record.circle")
                        .foregroundStyle(Theme.red.opacity(0.92))
                }
            }
            .font(.plexSans(11))
            .foregroundStyle(Theme.soft)
        }
    }

    private var extractedTodosBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "checklist").foregroundStyle(Theme.green)
            Text("\(extractedTodos.count) Aufgabe\(extractedTodos.count == 1 ? "" : "n") in deiner Handschrift erkannt:")
                .font(.plexSans(12).weight(.medium))
                .foregroundStyle(.white)
            Spacer()
            Button("Zu Todos hinzufügen") {
                for todo in extractedTodos {
                    _ = model.addTodo(todo)
                }
                feedback = "\(extractedTodos.count) Aufgabe(n) zu deinen Bluey-Todos hinzugefügt."
                extractedTodos = []
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Button { extractedTodos = [] } label: {
                Image(systemName: "xmark").font(.system(size: 11)).foregroundStyle(Theme.soft)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.cardStrong, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func load() {
        guard !loaded, let note = model.note(id) else { return }
        title = note.title
        text = note.body
        drawing = note.drawing ?? InkDrawing()
        showCanvas = !drawing.isEmpty || note.source == "huion-live" || note.source == "huion-offline"
        loaded = true
    }

    private func scheduleSave() {
        guard loaded, let note = model.note(id) else { return }
        let nextDrawing: InkDrawing? = drawing.isEmpty ? nil : drawing
        guard note.title != title || note.body != text || note.drawing != nextDrawing else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem {
            saveWork = nil
            guard var n = model.note(id) else { return }
            n.title = title
            n.body = text
            n.drawing = drawing.isEmpty ? nil : drawing
            model.update(n)
            // If a meeting/video recording is active, snapshot timestamped drawings into the meeting timeline.
            if n.drawing != nil, huion.recordingStartedAt != nil {
                huion.onNoteDrawingUpdated?(n)
            }
            // Keep already-linked Bluey Hub notes up to date automatically.
            if n.hubNoteID != nil, let sync = huion.syncNoteToHub {
                Task { _ = try? await sync(n) }
            }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func runOCR() {
        guard !ocrBusy, !drawing.isEmpty, let transcribe = huion.transcribeDrawing else { return }
        ocrBusy = true
        feedback = "Erkenne Handschrift…"
        let currentDrawing = drawing
        Task {
            defer { ocrBusy = false }
            do {
                let res = try await transcribe(currentDrawing)
                if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !res.title.isEmpty {
                    title = res.title
                }
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    text = res.markdown
                } else {
                    text = text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n---\n\n" + res.markdown
                }
                extractedTodos = res.todos
                saveWork?.perform()
                // Save immediately and sync to Bluey Hub so Hermes knows the recognized text!
                if var n = model.note(id) {
                    n.title = title
                    n.body = text
                    n.drawing = drawing.isEmpty ? nil : drawing
                    model.update(n)
                    if let sync = huion.syncNoteToHub {
                        if let hubID = try? await sync(n) {
                            n.hubNoteID = hubID
                            model.update(n)
                            feedback = "Handschrift erkannt & mit Bluey Hub / Hermes synchronisiert."
                        } else {
                            feedback = "Handschrift erkannt (Bluey Hub aktuell nicht erreichbar)."
                        }
                    } else {
                        feedback = "Handschrift erkannt."
                    }
                }
            } catch {
                feedback = error.localizedDescription
            }
        }
    }

    private func pushToHub() {
        guard !hubBusy, let sync = huion.syncNoteToHub, var note = model.note(id) else { return }
        hubBusy = true
        note.title = title
        note.body = text
        note.drawing = drawing.isEmpty ? nil : drawing
        model.update(note)
        Task {
            defer { hubBusy = false }
            do {
                let hubID = try await sync(note)
                note.hubNoteID = hubID
                model.update(note)
                feedback = "Mit Bluey Hub synchronisiert (für iPhone & Hermes verfügbar)."
            } catch {
                feedback = "Hub-Sync fehlgeschlagen: \(error.localizedDescription)"
            }
        }
    }

    private func exportLocal() {
        guard let export = huion.exportDrawing else { return }
        let name = title.isEmpty ? "huion-note" : title
        if let url = export(drawing, name) {
            feedback = "Gespeichert: \(url.lastPathComponent)"
        }
    }
}
