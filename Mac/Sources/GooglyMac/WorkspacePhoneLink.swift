import Foundation
import GooglyShared

/// Phone requests for the workspace, over the paired, encrypted link:
/// wsSync / wsPut (snapshots), chatSend / chatStop, attachmentPut / attachmentGet.
@MainActor
enum WorkspacePhoneLink {
    static func handles(_ command: String?) -> Bool {
        guard let command else { return false }
        return command.hasPrefix("ws") || command.hasPrefix("chat") || command.hasPrefix("attachment")
    }

    static func handle(_ packet: Packet, store: WorkspaceStore, reply: @escaping (Packet) -> Void) {
        let command = packet.command ?? ""
        func answer(_ text: String?, image: String? = nil) {
            reply(Packet(command: command + "Reply", callID: packet.callID, text: text, image: image))
        }
        func failure(_ message: String) { answer(WorkspaceCoding.string(["error": message])) }

        switch command {
        case "wsSync", "wsPut":
            if let partial = WorkspaceCoding.decode(WorkspaceSnapshot.self, packet.text) { store.apply(partial) }
            answer(WorkspaceCoding.string(store.snapshot))
        case "chatSend":
            guard let request = WorkspaceCoding.decode(ChatRequest.self, packet.text) else { failure("Ungültige Anfrage."); return }
            do { answer(WorkspaceCoding.string(["threadID": try store.send(request).uuidString])) }
            catch { failure(error.localizedDescription) }
        case "chatStop":
            if let id = packet.text.flatMap(UUID.init(uuidString:)) { store.stop(id) }
            answer("{}")
        case "chatModel":
            if let model = packet.text, !model.isEmpty { store.setDefaultModel(model) }
            answer("{}")
        case "attachmentPut":
            let meta = packet.text.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String] } ?? [:]
            guard let data = packet.image.flatMap({ Data(base64Encoded: $0) }) else { failure("Die Datei ist nicht angekommen."); return }
            do { answer(WorkspaceCoding.string(try store.storeAttachment(data, name: meta["name"] ?? "Datei", mime: meta["mime"]))) }
            catch { failure(error.localizedDescription) }
        case "attachmentGet":
            guard let id = packet.text.flatMap(UUID.init(uuidString:)), let data = store.attachmentData(id) else { answer(nil); return }
            answer(nil, image: data.base64EncodedString())
        default:
            failure("Unbekannter Befehl.")
        }
    }
}
