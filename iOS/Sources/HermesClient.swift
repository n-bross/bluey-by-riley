import Foundation

/// The phone's copy of the Mac's Hermes state, and the requests the Hermes screen sends.
final class HermesClient: ObservableObject {
    @Published private(set) var state: HermesSync?
    @Published var message = ""
    @Published private(set) var sending = false
    private weak var link: MacLink?

    var waiting: [(run: HermesRun, prompt: HermesPrompt)] {
        (state?.runs ?? []).flatMap { run in run.pending.map { (run, $0) } }
    }

    func attach(_ link: MacLink) { self.link = link }

    func receive(_ text: String) {
        guard let state = try? JSONDecoder().decode(HermesSync.self, from: Data(text.utf8)) else { return }
        self.state = state
    }

    func sync() { request("hermesSync") }

    func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sending = true
        request("hermesSend", ["text": text]) { [weak self] in self?.sending = false }
    }

    func respond(run: String, prompt: String, choice: String) {
        request("hermesRespond", ["run": run, "prompt": prompt, "choice": choice])
    }

    @MainActor
    func answerFromScreen(run: String, prompt: String, choice: String) async throws {
        guard let link, link.connected else {
            throw HubError.unreachable("Der gekoppelte Mac ist nicht verbunden.")
        }
        let data = try JSONSerialization.data(withJSONObject: ["run": run, "prompt": prompt, "choice": choice])
        let reply: String? = await withCheckedContinuation { continuation in
            link.request(Packet(command: "hermesRespond", text: String(decoding: data, as: UTF8.self))) {
                continuation.resume(returning: $0?.text)
            }
        }
        guard let reply, ["Allowed.", "Denied.", "Answer sent to Hermes."].contains(reply) else {
            throw HubError.refused(0, reply ?? "Der Mac hat nicht geantwortet.")
        }
        sync()
    }

    func setMode(_ mode: HermesApprovalMode) {
        request("hermesMode", ["mode": mode.rawValue])
    }

    func stop(_ run: String) { request("hermesStop", ["run": run]) }

    private func request(_ command: String, _ args: [String: Any] = [:], done: (() -> Void)? = nil) {
        guard let link, link.connected else { message = "Connect your paired Mac first."; done?(); return }
        let text = (try? JSONSerialization.data(withJSONObject: args)).flatMap { String(data: $0, encoding: .utf8) }
        link.request(Packet(command: command, text: text)) { [weak self] reply in
            if let text = reply?.text, !text.isEmpty { self?.message = text }
            else if reply == nil { self?.message = "The Mac didn't answer." }
            done?()
        }
    }
}
