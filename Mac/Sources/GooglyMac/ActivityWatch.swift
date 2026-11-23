import Foundation
import CoreGraphics
import GooglyShared

/// Reads and writes ActivityWatch on this Mac (http://localhost:5600, its local REST API).
/// Reads: real active time (aw-watcher-afk "not-afk") and which apps and windows that time went to.
/// Writes: a "bluey-focus" bucket, so focus sessions show up on ActivityWatch's own timeline next to everything else.
/// Nothing leaves the Mac here; ActivityWatch only listens on localhost.
enum ActivityWatch {
    static let base = URL(string: "http://localhost:5600/api/0/")!
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        return URLSession(configuration: config)
    }()

    static var focusBucket: String {
        "bluey-focus_" + (Host.current().localizedName ?? ProcessInfo.processInfo.hostName)
    }

    // MARK: Bluey's own presence (reliable active time)

    /// ActivityWatch's AFK watcher on macOS can miss sleep and lock (one "not-afk" event spanning a night),
    /// so Bluey records presence itself: a heartbeat every 30 s from the real idle time and the lock state.
    /// No heartbeats arrive while the Mac sleeps, so sleep can never count as active.
    static var presenceBucket: String {
        "bluey-presence_" + (Host.current().localizedName ?? ProcessInfo.processInfo.hostName)
    }

    private static var presenceReady = false
    private static var presenceSince: Date?
    private static var presenceChecked = Date.distantPast

    /// Seconds since the last keyboard, mouse or trackpad input.
    static var idleSeconds: Double {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max) ?? .null)
        return idle.isFinite ? idle : 0
    }

    static var screenLocked: Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsLocked"] as? Bool == true || session?["kCGSessionOnConsoleKey"] as? Bool == false
    }

    /// One presence heartbeat. Active = input in the last 3 minutes and the screen not locked.
    static func presenceHeartbeat() async {
        let active = idleSeconds < 180 && !screenLocked
        do {
            if !presenceReady {
                let host = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
                _ = try await call("buckets/\(presenceBucket)", method: "POST",
                                   body: ["client": "bluey", "type": "afkstatus", "hostname": host])
                presenceReady = true
            }
            _ = try await call("buckets/\(presenceBucket)/heartbeat?pulsetime=45", method: "POST",
                               body: ["timestamp": iso.string(from: Date()), "duration": 0,
                                      "data": ["status": active ? "not-afk" : "afk"]])
        } catch {
            presenceReady = false
        }
    }

    /// When Bluey started recording presence (nil if never), cached for ten minutes.
    private static func presenceStart() async -> Date? {
        if Date().timeIntervalSince(presenceChecked) < 600 { return presenceSince }
        presenceChecked = Date()
        guard let info = try? await call("buckets/\(presenceBucket)") as? [String: Any],
              let created = info["created"] as? String else { presenceSince = nil; return nil }
        presenceSince = parseDate(created)
        return presenceSince
    }

    /// The AFK source for a period: Bluey's presence when it covers the period, ActivityWatch's watcher before that.
    private static func afkLine(from: Date) async -> String {
        if let since = await presenceStart(), from >= since.addingTimeInterval(-60) {
            return "afk = flood(query_bucket(\"\(presenceBucket)\"));"
        }
        return "afk = flood(query_bucket(find_bucket(\"aw-watcher-afk_\")));"
    }

    enum AWError: LocalizedError {
        case notRunning, bad(String)
        var errorDescription: String? {
            switch self {
            case .notRunning: return "ActivityWatch isn't running on this Mac."
            case .bad(let why): return "ActivityWatch said: \(why.prefix(160))"
            }
        }
    }

    private static func call(_ path: String, method: String = "GET", body: Any? = nil) async throws -> Any {
        var request = URLRequest(url: URL(string: path, relativeTo: base)!)
        request.httpMethod = method
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch { throw AWError.notRunning }
        guard let http = response as? HTTPURLResponse else { throw AWError.notRunning }
        // 304: "already there" (creating a bucket that exists). Not an error.
        guard (200..<300).contains(http.statusCode) || http.statusCode == 304 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AWError.bad(body.isEmpty ? "HTTP \(http.statusCode)" : body)
        }
        if data.isEmpty { return [:] }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) ?? [:]
    }

    static func isRunning() async -> Bool {
        (try? await call("info")) != nil
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Active time and app use between two dates. Window time only counts while you weren't AFK.
    static func summary(from: Date, to: Date = Date()) async throws -> ActivitySummary {
        let query = [
            await afkLine(from: from),
            "win = flood(query_bucket(find_bucket(\"aw-watcher-window_\")));",
            "active = filter_keyvals(afk, \"status\", [\"not-afk\"]);",
            "away = filter_keyvals(afk, \"status\", [\"afk\"]);",
            "win = filter_period_intersect(win, active);",
            "apps = sort_by_duration(merge_events_by_keys(win, [\"app\"]));",
            "titles = sort_by_duration(merge_events_by_keys(win, [\"app\", \"title\"]));",
            "RETURN = {\"active\": sum_durations(active), \"away\": sum_durations(away), \"apps\": limit_events(apps, 12), \"titles\": limit_events(titles, 10)};",
        ]
        let period = iso.string(from: from) + "/" + iso.string(from: max(to, from.addingTimeInterval(1)))
        let result = try await call("query/", method: "POST", body: ["timeperiods": [period], "query": query])
        guard let first = (result as? [[String: Any]])?.first else { throw AWError.bad("unexpected query result") }
        func times(_ key: String, title: Bool) -> [AppTime] {
            ((first[key] as? [[String: Any]]) ?? []).compactMap { event in
                let data = event["data"] as? [String: Any] ?? [:]
                let app = data["app"] as? String ?? "?"
                var name = app
                if title {
                    let t = (data["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { return nil }
                    name = "\(app): \(t.prefix(70))"
                }
                let seconds = event["duration"] as? Double ?? 0
                return seconds >= 1 ? AppTime(name: name, seconds: seconds) : nil
            }
        }
        return ActivitySummary(from: from, to: to,
                               activeSeconds: first["active"] as? Double ?? 0,
                               afkSeconds: first["away"] as? Double ?? 0,
                               apps: times("apps", title: false), titles: times("titles", title: true))
    }

    /// Raw window events (only while not AFK) and AFK periods, for the journal's timeline.
    static func events(from: Date, to: Date) async throws -> (window: [JournalEvent], away: [(start: Date, duration: Double)]) {
        let query = [
            await afkLine(from: from),
            "win = flood(query_bucket(find_bucket(\"aw-watcher-window_\")));",
            "active = filter_keyvals(afk, \"status\", [\"not-afk\"]);",
            "away = filter_keyvals(afk, \"status\", [\"afk\"]);",
            "win = filter_period_intersect(win, active);",
            "RETURN = {\"win\": sort_by_timestamp(win), \"away\": sort_by_timestamp(away)};",
        ]
        let period = iso.string(from: from) + "/" + iso.string(from: max(to, from.addingTimeInterval(1)))
        let result = try await call("query/", method: "POST", body: ["timeperiods": [period], "query": query])
        guard let first = (result as? [[String: Any]])?.first else { throw AWError.bad("unexpected query result") }
        let window: [JournalEvent] = ((first["win"] as? [[String: Any]]) ?? []).compactMap { e in
            guard let ts = e["timestamp"] as? String, let start = parseDate(ts) else { return nil }
            let data = e["data"] as? [String: Any] ?? [:]
            return JournalEvent(start: start, duration: e["duration"] as? Double ?? 0,
                                app: data["app"] as? String ?? "?", title: data["title"] as? String ?? "")
        }
        let away: [(start: Date, duration: Double)] = ((first["away"] as? [[String: Any]]) ?? []).compactMap { e in
            guard let ts = e["timestamp"] as? String, let start = parseDate(ts) else { return nil }
            return (start, e["duration"] as? Double ?? 0)
        }
        return (window, away)
    }

    /// ActivityWatch timestamps have microseconds ("…45.179000+00:00"), which ISO8601DateFormatter can't read.
    static func parseDate(_ text: String) -> Date? {
        var fraction = 0.0
        var plain = text
        if let r = text.range(of: #"\.\d+"#, options: .regularExpression) {
            fraction = Double("0" + text[r]) ?? 0
            plain.removeSubrange(r)
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: plain)?.addingTimeInterval(fraction)
    }

    static func today() async throws -> ActivitySummary {
        try await summary(from: Calendar.current.startOfDay(for: Date()))
    }

    // MARK: Focus sessions on ActivityWatch's timeline

    private static var bucketReady = false

    private static func ensureFocusBucket() async throws {
        guard !bucketReady else { return }
        let host = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        _ = try await call("buckets/\(focusBucket)", method: "POST",
                           body: ["client": "bluey", "type": "app.bluey.focus", "hostname": host])
        bucketReady = true
    }

    /// One heartbeat while a focus session runs. Equal data within `pulse` seconds merges into one event,
    /// so a session shows as a solid block (split where its status or verdict changes).
    static func focusHeartbeat(task: String, sessionID: UUID, status: String, verdict: String?, pulse: Double) async {
        do {
            try await ensureFocusBucket()
            var data: [String: Any] = ["task": String(task.prefix(200)), "session": sessionID.uuidString, "status": status]
            if let verdict { data["verdict"] = verdict }
            let path = "buckets/\(focusBucket)/heartbeat?pulsetime=\(Int(pulse))"
            _ = try await call(path, method: "POST", body: ["timestamp": iso.string(from: Date()), "duration": 0, "data": data])
        } catch {
            bucketReady = false
        }
    }
}
