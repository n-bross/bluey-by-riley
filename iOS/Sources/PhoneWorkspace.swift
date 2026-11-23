import Foundation
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

/// The phone's side of the workspace. It keeps an offline copy, so todos, notes and the pomodoro work
/// without the Mac, and syncs over the paired link when connected (the Mac merges, newest wins).
/// Chat and attachments need the Mac, which holds the API key.
@MainActor
final class PhoneWorkspace: WorkspaceBackend {
    let model: WorkspaceModel
    private let link: MacLink
    private var saveWork: DispatchWorkItem?
    private var file: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("bluey-workspace.json")
    }

    init(link: MacLink) {
        self.link = link
        let saved = (try? Data(contentsOf: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("bluey-workspace.json")))
            .flatMap { try? WorkspaceCoding.decoder.decode(WorkspaceSnapshot.self, from: $0) } ?? WorkspaceSnapshot()
        model = WorkspaceModel(snapshot: saved)
        model.advancesPomodoro = true
        model.backend = self
        model.onChange = { [weak self] snapshot in
            self?.saveSoon()
            PomodoroReminder.schedule(snapshot.pomodoro)
        }
        model.onPhaseFinished = { phase in
            #if canImport(UIKit)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            #endif
            _ = phase
        }
    }

    var isConnected: Bool { link.connected }

    /// Sends the whole offline copy after (re)connecting; the reply is the merged state.
    func connectionChanged(_ connected: Bool) {
        model.setConnected(connected)
        guard connected else { return }
        link.request(Packet(command: "wsSync", text: WorkspaceCoding.string(model.snapshot))) { [weak self] reply in
            if let state = WorkspaceCoding.decode(WorkspaceSnapshot.self, reply?.text) { self?.model.receive(state) }
        }
    }

    /// Broadcasts from the Mac.
    func receive(command: String, text: String?) -> Bool {
        switch command {
        case "wsState":
            if let state = WorkspaceCoding.decode(WorkspaceSnapshot.self, text) { model.receive(state) }
            return true
        case "chatDelta":
            if let delta = WorkspaceCoding.decode(ChatDelta.self, text) { model.receive(delta) }
            return true
        default:
            return false
        }
    }

    private func saveSoon() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let data = try? WorkspaceCoding.encoder.encode(self.model.snapshot) else { return }
            try? data.write(to: self.file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // MARK: WorkspaceBackend

    func push(_ partial: WorkspaceSnapshot) {
        // Offline edits stay in the local copy and go over with the next wsSync.
        guard link.connected else { return }
        link.send(Packet(command: "wsPut", text: WorkspaceCoding.string(partial)))
    }

    private func call(_ command: String, text: String?, image: String? = nil) async throws -> Packet {
        try await withCheckedThrowingContinuation { done in
            link.request(Packet(command: command, text: text, image: image)) { reply in
                guard let reply else { done.resume(throwing: WorkspaceError("Der Mac hat nicht geantwortet.")); return }
                if let error = (reply.text.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] })?["error"] as? String {
                    done.resume(throwing: WorkspaceError(error))
                } else {
                    done.resume(returning: reply)
                }
            }
        }
    }

    func send(_ request: ChatRequest) async throws -> UUID {
        let reply = try await call("chatSend", text: WorkspaceCoding.string(request))
        guard let json = reply.text.flatMap({ try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String] }),
              let id = json["threadID"].flatMap(UUID.init(uuidString:)) else { throw WorkspaceError("Unerwartete Antwort vom Mac.") }
        return id
    }

    func stop(threadID: UUID) {
        link.send(Packet(command: "chatStop", text: threadID.uuidString))
    }

    func upload(_ data: Data, name: String, mime: String) async throws -> ChatAttachment {
        let meta = (try? JSONSerialization.data(withJSONObject: ["name": name, "mime": mime])).flatMap { String(data: $0, encoding: .utf8) }
        let reply = try await call("attachmentPut", text: meta, image: data.base64EncodedString())
        guard let attachment = WorkspaceCoding.decode(ChatAttachment.self, reply.text) else { throw WorkspaceError("Der Anhang kam nicht an.") }
        return attachment
    }

    func attachmentData(_ id: UUID) async -> Data? {
        (try? await call("attachmentGet", text: id.uuidString))?.image.flatMap { Data(base64Encoded: $0) }
    }

    func setDefaultModel(_ id: String) {
        link.send(Packet(command: "chatModel", text: id))
    }
}

/// A local notification when the running pomodoro phase ends, so it reaches you with the app closed.
enum PomodoroReminder {
    private static let id = "bluey.pomodoro"
    private static var lastScheduled: Date?

    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func schedule(_ state: PomodoroState?) {
        let center = UNUserNotificationCenter.current()
        guard let state, let started = state.startedAt, state.phase != .idle else {
            if lastScheduled != nil { center.removePendingNotificationRequests(withIdentifiers: [id]); lastScheduled = nil }
            return
        }
        let end = started.addingTimeInterval(state.pausedRemaining ?? state.duration)
        guard end != lastScheduled else { return }
        lastScheduled = end
        let interval = end.timeIntervalSinceNow
        guard interval > 1 else { return }
        requestPermission()  // asked the first time a pomodoro runs, not at launch
        let content = UNMutableNotificationContent()
        content.title = state.phase == .focus ? "Runde geschafft!" : "Pause vorbei"
        content.body = state.phase == .focus ? "Zeit für eine kleine Pause. Bluey ist stolz auf dich." : "Bereit für die nächste Runde?"
        content.sound = .default
        center.add(UNNotificationRequest(identifier: id, content: content,
                                         trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)))
    }
}
