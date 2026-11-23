import SwiftUI

/// Bluey as a gateway to Hermes: type or approve things, pick how risky steps are handled,
/// and see today's real activity from ActivityWatch. Hold Bluey's face to ask Hermes by voice.
struct HermesView: View {
    @ObservedObject var hermes: HermesClient
    @ObservedObject var link: MacLink
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @FocusState private var typing: Bool

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 290)
                .background(Color(hex: Palette.panel).opacity(0.6))
            chat
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .tint(Color(hex: Palette.berry1))
        .onAppear { hermes.sync() }
    }

    // MARK: Left: status, approvals, activity

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 40, height: 40)
                            .background(Color.white.opacity(0.08), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hermes").font(.fredoka(26)).foregroundStyle(.white)
                        HStack(spacing: 6) {
                            Circle().fill(statusColor).frame(width: 7, height: 7)
                            Text(statusText)
                                .font(.plexSans(12))
                                .foregroundStyle(Color(hex: Palette.inkSoft))
                                .lineLimit(2)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    label("Risky steps")
                    Picker("Risky steps", selection: Binding(
                        get: { hermes.state?.mode ?? .ask },
                        set: { hermes.setMode($0) })) {
                        ForEach(HermesApprovalMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(modeHelp)
                        .font(.plexSans(11))
                        .foregroundStyle(Color(hex: Palette.inkSoft))
                }

                Divider().overlay(Color.white.opacity(0.08))
                ActivityCard(state: hermes.state)

                Text("Hold Bluey's face and say “tell Hermes…”, or type below. Hermes uses its own tools: messages, browser, computer, calendar and to-dos.")
                    .font(.plexSans(11))
                    .foregroundStyle(Color(hex: Palette.inkSoft))
            }
            .padding(22)
        }
    }

    private var statusColor: Color {
        guard link.connected else { return Color(hex: Palette.inkSoft).opacity(0.5) }
        return hermes.state?.available == true ? Color(hex: 0x5BE49B) : Color(hex: 0xEBAC73)
    }

    private var statusText: String {
        guard link.connected else { return "Mac not connected" }
        guard let state = hermes.state else { return "Checking…" }
        return state.available ? "Connected through your Mac" : (state.problem ?? "Not reachable")
    }

    private var modeHelp: String {
        switch hermes.state?.mode ?? .ask {
        case .ask: return "A card appears here and on the Mac; you choose."
        case .deny: return "Hermes is refused anything risky and has to find another way."
        case .allow: return "Hermes goes ahead without asking. ⌃⌥S on the Mac doesn't stop Hermes; use Stop on a request."
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.plexMono(11)).textCase(.uppercase).foregroundStyle(Color(hex: Palette.inkSoft))
    }

    // MARK: Right: conversation

    private var chat: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if (hermes.state?.runs ?? []).isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "sparkles").font(.system(size: 30)).foregroundStyle(Color(hex: Palette.berry2))
                                Text("Nothing asked yet").font(.fredoka(18)).foregroundStyle(.white)
                                Text("Try “What's on my calendar today?” or “Send Anna a message that I'm running late.”")
                                    .font(.plexSans(13)).foregroundStyle(Color(hex: Palette.inkSoft))
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
                    .foregroundStyle(Color(hex: Palette.inkSoft))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22)
                    .lineLimit(2)
            }
            HStack(spacing: 10) {
                TextField("Ask Hermes…", text: $draft, axis: .vertical)
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
                .accessibilityLabel("Send to Hermes")
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
    @State private var answer = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer(minLength: 100)
                Text(run.prompt)
                    .font(.plexSans(15).weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(BlobShape.linear, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            ForEach(run.pending) { prompt in promptCard(prompt) }
            HStack(alignment: .bottom, spacing: 8) {
                MiniBluey().frame(width: 28, height: 25)
                VStack(alignment: .leading, spacing: 6) {
                    switch run.status {
                    case .completed:
                        Text(LocalizedStringKey(run.output ?? "Done."))
                            .font(.plexSans(15))
                            .foregroundStyle(Color(hex: Palette.ink))
                            .textSelection(.enabled)
                    case .failed, .cancelled:
                        Text(run.status == .cancelled ? "Stopped." : (run.output ?? "Hermes couldn't finish this."))
                            .font(.plexSans(14))
                            .foregroundStyle(Color(hex: 0xB0412E))
                    default:
                        HStack(spacing: 8) {
                            ProgressView().tint(Color(hex: Palette.berry2))
                            Text(run.status == .waiting ? "Waiting for you" : (run.activity ?? "Hermes is working…"))
                                .font(.plexSans(14))
                                .foregroundStyle(Color(hex: Palette.ink))
                            Button("Stop") { hermes.stop(run.id) }
                                .font(.plexSans(13).weight(.semibold))
                                .disabled(run.id.hasPrefix("local-"))
                        }
                    }
                    Text(run.started.formatted(date: .omitted, time: .shortened))
                        .font(.plexMono(10))
                        .foregroundStyle(Color(hex: Palette.inkSoft))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                Spacer(minLength: 80)
            }
        }
    }

    @ViewBuilder
    private func promptCard(_ prompt: HermesPrompt) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(prompt.kind == .approval ? "Hermes wants to run" : "Hermes asks",
                  systemImage: prompt.kind == .approval ? "exclamationmark.shield" : "questionmark.bubble")
                .font(.plexSans(13).weight(.semibold))
                .foregroundStyle(Color(hex: 0xFFD66B))
            Text(prompt.text)
                .font(prompt.kind == .approval ? .plexMono(13) : .plexSans(15))
                .foregroundStyle(.white)
                .textSelection(.enabled)
            if let detail = prompt.detail {
                Text(detail).font(.plexSans(12)).foregroundStyle(Color(hex: Palette.inkSoft))
            }
            if prompt.kind == .approval {
                HStack(spacing: 8) {
                    ForEach(prompt.choices.sorted { order($0) < order($1) }, id: \.self) { choice in
                        Button(HermesPrompt.choiceTitle(choice)) {
                            hermes.respond(run: run.id, prompt: prompt.id, choice: choice)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(choice == "deny" ? Color(hex: 0xE5547A) : Color(hex: Palette.berry2))
                    }
                }
            } else {
                if !prompt.choices.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(prompt.choices, id: \.self) { choice in
                            Button(choice) { hermes.respond(run: run.id, prompt: prompt.id, choice: choice) }
                                .buttonStyle(.bordered)
                        }
                    }
                }
                HStack {
                    TextField("Your answer", text: $answer)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(sendAnswer(prompt))
                    Button("Send", action: sendAnswer(prompt))
                        .buttonStyle(.borderedProminent)
                        .disabled(answer.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(14)
        .background(Color(hex: 0x2A2440), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color(hex: 0xFFD66B), lineWidth: 2))
        .padding(.leading, 36)
        .padding(.trailing, 60)
    }

    private func sendAnswer(_ prompt: HermesPrompt) -> () -> Void {
        {
            let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            answer = ""
            hermes.respond(run: run.id, prompt: prompt.id, choice: text)
        }
    }

    private func order(_ choice: String) -> Int {
        ["once", "session", "always", "deny"].firstIndex(of: choice) ?? 9
    }
}

/// Today's real activity from ActivityWatch: active time, away time, and where it went.
struct ActivityCard: View {
    let state: HermesSync?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Today").font(.plexMono(11)).textCase(.uppercase).foregroundStyle(Color(hex: Palette.inkSoft))
            if let today = state?.today {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(ActivitySummary.duration(today.activeSeconds)).font(.fredoka(30)).foregroundStyle(.white)
                        Text("active").font(.plexSans(11)).foregroundStyle(Color(hex: Palette.inkSoft))
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(ActivitySummary.duration(today.afkSeconds)).font(.fredoka(20)).foregroundStyle(.white.opacity(0.7))
                        Text("away").font(.plexSans(11)).foregroundStyle(Color(hex: Palette.inkSoft))
                    }
                }
                let top = today.apps.prefix(6)
                let most = max(top.first?.seconds ?? 1, 1)
                ForEach(Array(top)) { app in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(app.name).font(.plexSans(12)).foregroundStyle(.white).lineLimit(1)
                            Spacer()
                            Text(ActivitySummary.duration(app.seconds)).font(.plexMono(11)).foregroundStyle(Color(hex: Palette.inkSoft))
                        }
                        GeometryReader { geo in
                            Capsule().fill(BlobShape.linear).frame(width: max(4, geo.size.width * app.seconds / most), height: 5)
                        }
                        .frame(height: 5)
                    }
                }
                Text("From ActivityWatch: only time with keyboard or mouse use counts as active.")
                    .font(.plexSans(10)).foregroundStyle(Color(hex: Palette.inkSoft))
            } else {
                Text(state?.activityAvailable == false
                     ? "ActivityWatch isn't running on the Mac. Start it to track real active time."
                     : "Loading activity…")
                    .font(.plexSans(12))
                    .foregroundStyle(Color(hex: Palette.inkSoft))
            }
        }
    }
}
