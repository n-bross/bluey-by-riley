import Foundation
import Network
import CryptoKit
import GooglyShared

/// Serves the Bluey web app on this Mac (http://127.0.0.1:4777). Only this Mac can reach it, and every
/// request needs the private token from the menu's "Web-App öffnen" link (kept as a cookie afterwards).
@MainActor
final class WebServer {
    nonisolated static let preferredPort: UInt16 = 4777
    private var listener: NWListener?
    private(set) var port: UInt16 = WebServer.preferredPort
    private let store: WorkspaceStore
    private var streams: [ObjectIdentifier: NWConnection] = [:]
    private var listenerID: UUID?
    private var lastFace: FaceState?
    private var lastFaceSent = Date.distantPast
    let token: String

    /// Hooks into the rest of the app.
    var focusState: () -> FocusSync? = { nil }
    var focusCommand: (String, [String: Any]) -> String = { _, _ in "" }

    init(store: WorkspaceStore) {
        self.store = store
        token = Self.loadToken()
    }

    var url: URL { URL(string: "http://127.0.0.1:\(port)/?token=\(token)")! }

    func start(port: UInt16 = WebServer.preferredPort, attempts: Int = 10) {
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard case .failed = state else { return }
                Task { @MainActor in
                    guard let self else { return }
                    self.listener?.cancel(); self.listener = nil
                    if attempts > 0 { self.start(port: port + 1, attempts: attempts - 1) }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
            self.port = port
        } catch {
            NSLog("Bluey web: could not listen on \(port): \(error)")
            if attempts > 0 { start(port: port + 1, attempts: attempts - 1) }
        }
        if listenerID == nil {
            listenerID = store.listen(snapshot: { [weak self] snapshot in
                self?.broadcast(event: "state", WorkspaceCoding.string(snapshot))
            }, delta: { [weak self] delta in
                self?.broadcast(event: "delta", WorkspaceCoding.string(delta))
            })
        }
    }

    /// Bluey's face from the Mac cursor engine, at most ~15 times a second.
    func send(face: FaceState) {
        guard !streams.isEmpty, face != lastFace || Date().timeIntervalSince(lastFaceSent) > 1,
              Date().timeIntervalSince(lastFaceSent) > 0.066 else { return }
        lastFace = face; lastFaceSent = Date()
        broadcast(event: "face", WorkspaceCoding.string(face))
    }

    func sendFocus(_ sync: FocusSync) {
        broadcast(event: "focus", WorkspaceCoding.string(sync))
    }

    // MARK: Token

    private static func loadToken() -> String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Googly")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = dir.appendingPathComponent("web-token")
        if let saved = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), saved.count >= 32 {
            return saved
        }
        let token = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
        FileManager.default.createFile(atPath: file.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600])
        return token
    }

    // MARK: HTTP

    private struct Request {
        var method: String
        var path: String
        var query: [String: String]
        var headers: [String: String]
        var body: Data
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        read(connection, buffer: Data())
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.streams[ObjectIdentifier(connection)] == nil else { return }
            if connection.state != .cancelled, self.pendingReads.contains(ObjectIdentifier(connection)) { connection.cancel() }
        }
    }

    private var pendingReads = Set<ObjectIdentifier>()

    private func read(_ connection: NWConnection, buffer: Data) {
        pendingReads.insert(ObjectIdentifier(connection))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { return }
                var buffer = buffer
                if let data { buffer.append(data) }
                if buffer.count > 16 * 1024 * 1024 { self.respond(connection, status: 413, text: "Zu groß"); return }
                if let request = Self.parse(buffer) {
                    self.pendingReads.remove(ObjectIdentifier(connection))
                    self.handle(request, connection)
                } else if complete || error != nil {
                    self.pendingReads.remove(ObjectIdentifier(connection))
                    connection.cancel()
                } else {
                    self.read(connection, buffer: buffer)
                }
            }
        }
    }

    private static func parse(_ data: Data) -> Request? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = end.upperBound
        guard data.count - bodyStart >= length else { return nil }
        let target = String(first[1])
        let components = URLComponents(string: target)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return Request(method: String(first[0]), path: components?.path ?? target, query: query, headers: headers,
                       body: data.subdata(in: bodyStart..<(bodyStart + length)))
    }

    private func authorized(_ request: Request) -> Bool {
        let cookies = (request.headers["cookie"] ?? "").split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        let cookie = cookies.first { $0.hasPrefix("bluey_token=") }.map { String($0.dropFirst("bluey_token=".count)) }
        let bearer = request.headers["authorization"].flatMap { $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : nil }
        return [cookie, bearer].contains { $0.map(constantTimeEquals) ?? false }
    }

    private func constantTimeEquals(_ value: String) -> Bool {
        let a = Array(value.utf8), b = Array(token.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// Blocks DNS rebinding (foreign host names) and cross-site posts.
    private func trustedOrigin(_ request: Request) -> Bool {
        let allowed = ["127.0.0.1:\(port)", "localhost:\(port)"]
        guard let host = request.headers["host"], allowed.contains(host) else { return false }
        if let origin = request.headers["origin"], origin != "null" {
            return allowed.contains { origin == "http://\($0)" }
        }
        return true
    }

    private func handle(_ request: Request, _ connection: NWConnection) {
        guard trustedOrigin(request) else { respond(connection, status: 403, text: "Forbidden"); return }

        if request.path == "/", let given = request.query["token"] {
            guard constantTimeEquals(given) else { respond(connection, status: 403, text: "Ungültiger Link. Öffne die Web-App über das Bluey-Menü."); return }
            respond(connection, status: 302, headers: [
                "Location": "/",
                "Set-Cookie": "bluey_token=\(token); Path=/; HttpOnly; SameSite=Strict; Max-Age=31536000",
            ], body: Data())
            return
        }
        guard authorized(request) else {
            respond(connection, status: 401, text: "Öffne die Web-App über „Web-App öffnen“ im Bluey-Menü auf dem Mac.")
            return
        }

        switch (request.method, request.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            respond(connection, status: 200, headers: ["Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store"], body: Self.page())
        case ("GET", "/api/state"):
            json(connection, WorkspaceCoding.string(store.snapshot))
        case ("POST", "/api/put"):
            guard let partial = try? WorkspaceCoding.decoder.decode(WorkspaceSnapshot.self, from: request.body) else {
                respond(connection, status: 400, text: "Ungültige Daten"); return
            }
            store.apply(partial)
            json(connection, WorkspaceCoding.string(store.snapshot))
        case ("POST", "/api/chat"):
            guard let chat = try? WorkspaceCoding.decoder.decode(ChatRequest.self, from: request.body) else {
                respond(connection, status: 400, text: "Ungültige Anfrage"); return
            }
            do {
                let id = try store.send(chat)
                json(connection, "{\"threadID\":\"\(id.uuidString)\"}")
            } catch {
                json(connection, Self.jsonString(["error": error.localizedDescription]), status: 400)
            }
        case ("POST", "/api/chat/stop"):
            if let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
               let id = (body["threadID"] as? String).flatMap(UUID.init(uuidString:)) { store.stop(id) }
            json(connection, "{}")
        case ("POST", "/api/attachments"):
            let name = request.headers["x-filename"].flatMap { $0.removingPercentEncoding } ?? "Datei"
            do {
                let attachment = try store.storeAttachment(request.body, name: name, mime: request.headers["content-type"])
                json(connection, WorkspaceCoding.string(attachment))
            } catch {
                json(connection, Self.jsonString(["error": error.localizedDescription]), status: 400)
            }
        case ("GET", let path) where path.hasPrefix("/api/attachments/"):
            guard let id = UUID(uuidString: String(path.dropFirst("/api/attachments/".count))),
                  let data = store.attachmentData(id) else { respond(connection, status: 404, text: "Nicht gefunden"); return }
            let meta = store.attachment(id)
            let safeName = (meta?.name ?? "Datei").replacingOccurrences(of: "\"", with: "")
            respond(connection, status: 200, headers: [
                "Content-Type": meta?.mime ?? "application/octet-stream",
                "Content-Disposition": "inline; filename=\"\(safeName.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "file")\"",
                "X-Content-Type-Options": "nosniff",
                "Content-Security-Policy": "sandbox",
                "Cache-Control": "private, max-age=86400",
            ], body: data)
        case ("GET", "/api/stats"):
            json(connection, WorkspaceCoding.string(WorkspaceStats(store.snapshot, focusHistory: focusState()?.history ?? [])))
        case ("GET", "/api/focus"):
            json(connection, focusState().flatMap { WorkspaceCoding.string($0) } ?? "null")
        case ("POST", "/api/focus"):
            let body = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]) ?? [:]
            let command = body["command"] as? String ?? ""
            guard ["focusStart", "focusPause", "focusResume", "focusEnd"].contains(command) else {
                respond(connection, status: 400, text: "Unbekannter Befehl"); return
            }
            json(connection, Self.jsonString(["message": focusCommand(command, body)]))
        case ("GET", "/api/events"):
            openStream(connection)
        default:
            respond(connection, status: 404, text: "Nicht gefunden")
        }
    }

    private static func jsonString(_ object: [String: String]) -> String {
        (try? JSONSerialization.data(withJSONObject: object)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private func json(_ connection: NWConnection, _ text: String?, status: Int = 200) {
        respond(connection, status: status, headers: ["Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store"],
                body: Data((text ?? "null").utf8))
    }

    private func respond(_ connection: NWConnection, status: Int, text: String) {
        respond(connection, status: status, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data(text.utf8))
    }

    private func respond(_ connection: NWConnection, status: Int, headers: [String: String], body: Data) {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var data = Data(head.utf8); data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func reason(_ status: Int) -> String {
        [200: "OK", 302: "Found", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 413: "Payload Too Large"][status] ?? "OK"
    }

    // MARK: Server-sent events

    private func openStream(_ connection: NWConnection) {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nConnection: keep-alive\r\nX-Accel-Buffering: no\r\n\r\n"
        let id = ObjectIdentifier(connection)
        streams[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: Task { @MainActor in self?.streams[id] = nil }
            default: break
            }
        }
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        write(connection, event: "state", WorkspaceCoding.string(store.snapshot))
        if let focus = focusState() { write(connection, event: "focus", WorkspaceCoding.string(focus)) }
        keepAlive(connection)
    }

    private func keepAlive(_ connection: NWConnection) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.streams[ObjectIdentifier(connection)] != nil else { return }
            connection.send(content: Data(": ping\n\n".utf8), completion: .contentProcessed { error in
                if error != nil { connection.cancel() }
            })
            self.keepAlive(connection)
        }
    }

    private func broadcast(event: String, _ data: String?) {
        for connection in streams.values { write(connection, event: event, data) }
    }

    private func write(_ connection: NWConnection, event: String, _ data: String?) {
        guard let data else { return }
        let lines = data.split(separator: "\n", omittingEmptySubsequences: false).map { "data: \($0)" }.joined(separator: "\n")
        connection.send(content: Data("event: \(event)\n\(lines)\n\n".utf8), completion: .contentProcessed { error in
            if error != nil { connection.cancel() }
        })
    }

    // MARK: Page

    /// The web app: bundled in the app's Resources, or read from the source tree during development.
    private static func page() -> Data {
        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "web"),
           let data = try? Data(contentsOf: url) { return data }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../Web/index.html").standardized
        return (try? Data(contentsOf: source)) ?? Data("<h1>Bluey</h1><p>Web/index.html fehlt im App-Bundle.</p>".utf8)
    }
}
