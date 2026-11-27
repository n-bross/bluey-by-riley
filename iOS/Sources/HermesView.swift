import SwiftUI

/// Bluey as a gateway to Hermes: type or approve things, pick how risky steps are handled,
/// and see today's real activity from ActivityWatch. Hold Bluey's face to ask Hermes by voice.
struct HermesView: View {
    @ObservedObject var hermes: HermesClient
    @ObservedObject var link: MacLink
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var showDetails = false
    @FocusState private var typing: Bool

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 700 {
                HStack(spacing: 0) {
                    sidebar.frame(width: 270).background(Theme.panel)
                    Divider().overlay(Theme.line)
                    chat
                }
            } else {
                VStack(spacing: 0) {
                    HStack {
                        T3IconButton(symbol: "chevron.left", label: "Schließen") { dismiss() }
                        Text("Hermes-Aktivität").font(.plexSans(16).weight(.semibold))
                        Spacer()
                        T3IconButton(symbol: "slider.horizontal.3", label: "Details und Freigaben") {
                            showDetails = true
                        }
                    }
                    .padding(.horizontal, 12)
                    .background(Theme.panel)
                    Divider().overlay(Theme.line)
                    chat
                }
            }
        }
        .sheet(isPresented: $showDetails) {
            sidebar.background(Theme.panel)
        }
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .tint(Theme.accentLight)
        .onAppear { hermes.sync() }
    }

    // MARK: Left: status, approvals, activity

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Button {
                        if showDetails { showDetails = false }
                        else { dismiss() }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 40, height: 40)
                            .background(Color.white.opacity(0.08), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Schließen")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hermes").font(.fredoka(26)).foregroundStyle(.white)
                        HStack(spacing: 6) {
                            Circle().fill(statusColor).frame(width: 7, height: 7)
                            Text(statusText)
                                .font(.plexSans(12))
                                .foregroundStyle(Theme.soft)
                                .lineLimit(2)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    label("Freigaben")
                    Picker("Freigaben", selection: Binding(
                        get: { hermes.state?.mode ?? .ask },
                        set: { hermes.setMode($0) })) {
                        ForEach(HermesApprovalMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(modeHelp)
                        .font(.plexSans(11))
                        .foregroundStyle(Theme.soft)
                }

                Divider().overlay(Color.white.opacity(0.08))
                ActivityCard(state: hermes.state)

                Text("Tippe einen Auftrag oder halte Blueys Gesicht gedrückt und sag „Frag Hermes …“.")
                    .font(.plexSans(11))
                    .foregroundStyle(Theme.soft)
            }
            .padding(22)
        }
    }

    private var statusColor: Color {
        guard link.connected else { return Theme.soft.opacity(0.5) }
        return hermes.state?.available == true ? Color(hex: 0x5BE49B) : Color(hex: 0xEBAC73)
    }

    private var statusText: String {
        guard link.connected else { return "Mac nicht verbunden" }
        guard let state = hermes.state else { return "Verbindung wird geprüft …" }
        return state.available ? "Über deinen Mac verbunden" : (state.problem ?? "Nicht erreichbar")
    }

    private var modeHelp: String {
        switch hermes.state?.mode ?? .ask {
        case .ask: return "Du entscheidest hier oder am Mac über jede Freigabe."
        case .deny: return "Hermes muss bei abgelehnten Schritten einen anderen Weg finden."
        case .allow: return "Hermes führt Schritte ohne Rückfrage aus. Mit „Stoppen“ hältst du einen laufenden Auftrag an."
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.plexMono(11)).textCase(.uppercase).foregroundStyle(Theme.soft)
    }

    // MARK: Right: conversation

    private var chat: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if (hermes.state?.runs ?? []).isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "sparkles").font(.system(size: 30)).foregroundStyle(Theme.accentLight)
                                Text("Noch keine Aufträge").font(.fredoka(18)).foregroundStyle(.white)
                                Text("Frag Hermes zum Beispiel nach deinen heutigen Terminen.")
                                    .font(.plexSans(13)).foregroundStyle(Theme.soft)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                        }
                        ForEach(hermes.state?.runs ?? []) { run in
                            RunView(run: run, hermes: hermes).id(run.id)
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 18)
                }
                .onChange(of: hermes.state?.runs.last?.id) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                }
                .onAppear { if let id = hermes.state?.runs.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
            }
            if !hermes.message.isEmpty {
                Text(hermes.message)
                    .font(.plexSans(12))
                    .foregroundStyle(Theme.soft)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22)
                    .lineLimit(2)
            }
            HStack(spacing: 10) {
                TextField("Hermes fragen …", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($typing)
                    .font(.plexSans(15))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .submitLabel(.send)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: hermes.sending ? "ellipsis" : "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(BlobShape.linear))
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !link.connected)
                .accessibilityLabel("An Hermes senden")
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
        }
    }

    private func send() {
        let text = draft
        draft = ""
        hermes.send(text)
    }
}

private struct RunView: View {
    let run: HermesRun
    @ObservedObject var hermes: HermesClient

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer(minLength: 36)
                Text(run.prompt)
                    .font(.plexSans(15).weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(BlobShape.linear, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            ForEach(run.pending) { prompt in
                WorkspaceHermesPromptCard(prompt: prompt) { value in
                    try await hermes.answerFromScreen(run: run.id, prompt: prompt.id, choice: value)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                MiniBluey().frame(width: 28, height: 25)
                VStack(alignment: .leading, spacing: 6) {
                    switch run.status {
                    case .completed:
                        Text(LocalizedStringKey(run.output ?? "Erledigt."))
                            .font(.plexSans(15))
                            .foregroundStyle(Theme.text)
                            .textSelection(.enabled)
                    case .failed, .cancelled:
                        Text(run.status == .cancelled ? "Gestoppt." : (run.output ?? "Hermes konnte den Auftrag nicht abschließen."))
                            .font(.plexSans(14))
                            .foregroundStyle(Theme.red)
                    default:
                        HStack(spacing: 8) {
                            ProgressView().tint(Theme.accentLight)
                            Text(run.status == .waiting ? "Wartet auf deine Antwort" : (run.activity ?? "Hermes arbeitet …"))
                                .font(.plexSans(14))
                                .foregroundStyle(Theme.text)
                            Button("Stoppen") { hermes.stop(run.id) }
                                .font(.plexSans(13).weight(.semibold))
                                .disabled(run.id.hasPrefix("local-"))
                        }
                    }
                    Text(run.started.formatted(date: .omitted, time: .shortened))
                        .font(.plexMono(10))
                        .foregroundStyle(Theme.soft)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                Spacer(minLength: 14)
            }
        }
    }

}

/// Today's real activity from ActivityWatch: active time, away time, and where it went.
struct ActivityCard: View {
    let state: HermesSync?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Heute").font(.plexMono(11)).textCase(.uppercase).foregroundStyle(Theme.soft)
            if let today = state?.today {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(ActivitySummary.duration(today.activeSeconds)).font(.fredoka(30)).foregroundStyle(.white)
                        Text("Aktiv").font(.plexSans(11)).foregroundStyle(Theme.soft)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(ActivitySummary.duration(today.afkSeconds)).font(.fredoka(20)).foregroundStyle(.white.opacity(0.7))
                        Text("Abwesend").font(.plexSans(11)).foregroundStyle(Theme.soft)
                    }
                }
                let top = today.apps.prefix(6)
                let most = max(top.first?.seconds ?? 1, 1)
                ForEach(Array(top)) { app in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(app.name).font(.plexSans(12)).foregroundStyle(.white).lineLimit(1)
                            Spacer()
                            Text(ActivitySummary.duration(app.seconds)).font(.plexMono(11)).foregroundStyle(Theme.soft)
                        }
                        GeometryReader { geo in
                            Capsule().fill(BlobShape.linear).frame(width: max(4, geo.size.width * app.seconds / most), height: 5)
                        }
                        .frame(height: 5)
                    }
                }
                Text("ActivityWatch zählt Zeit mit Tastatur- oder Mausaktivität.")
                    .font(.plexSans(10)).foregroundStyle(Theme.soft)
            } else {
                Text(state?.activityAvailable == false
                     ? "Starte ActivityWatch am Mac, um aktive Zeit zu erfassen."
                     : "Aktivität wird geladen …")
                    .font(.plexSans(12))
                    .foregroundStyle(Theme.soft)
            }
        }
    }
}
