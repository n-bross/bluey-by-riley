import Foundation

/// Turns recorded audio into a proper transcript (with speaker labels) and keeps each session's
/// meeting notes as plain files any agent can read: ~/Documents/Bluey Notes/<date> <id>/.
enum MeetingNotes {
    static let model = "gpt-4o-transcribe-diarize"
    static let fallbackModel = "gpt-transcribe"

    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bluey Notes", isDirectory: true)
    }

    struct Segment {
        var speaker: String
        var start: Double
        var end: Double
        var text: String
    }

    // MARK: Folders

    /// The session's folder, made the first time it's needed.
    static func folder(session: String, started: Date) -> URL {
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        writeReadmeIfNeeded()
        let tag = String(session.prefix(8)).lowercased()
        if let existing = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?
            .first(where: { $0.lastPathComponent.hasSuffix(tag) }) {
            return existing
        }
        let name = DateFormatter.folderName.string(from: started) + " " + tag
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? fm.createDirectory(at: url.appendingPathComponent("audio"), withIntermediateDirectories: true)
        return url
    }

    private static func writeReadmeIfNeeded() {
        let url = root.appendingPathComponent("README.md")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let text = """
        # Bluey Notes

        Meeting notes recorded by Riley's Bluey app (the blueberry on the iPhone). One folder per listening \
        session, named by start time.

        In each session folder:
        - `notes.md`: the full transcript with timestamps and speaker labels, plus Riley's questions to Bluey, \
        Bluey's replies and any research reports, in time order. Start here.
        - `session.json`: the same data, structured.
        - `audio/`: the raw recording, as five-minute AAC chunks.

        Speaker letters (A, B, …) are assigned per five-minute chunk, so the same letter can mean different people \
        in different chunks. Lines marked "(live)" are a rough live transcript for audio that hasn't been fully \
        transcribed yet.
        """
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Transcription

    /// Saves the chunk's audio into the session folder and transcribes it via the configured TranscriptionService.
    static func transcribe(audio: Data, session: String, index: Int, sessionStarted: Date) async throws -> (segments: [Segment], folder: URL) {
        let folder = folder(session: session, started: sessionStarted)
        let audioURL = folder.appendingPathComponent("audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: audioURL, withIntermediateDirectories: true)
        let chunkURL = audioURL.appendingPathComponent(String(format: "chunk-%03d.m4a", index))
        try audio.write(to: chunkURL)
        let segments = try await TranscriptionService.transcribe(fileURL: chunkURL, rawData: audio, fileExtension: "m4a", preferDiarize: true)
        return (segments, folder)
    }

    static func plain(_ audio: Data, fileExtension: String = "m4a") async throws -> [Segment] {
        try await TranscriptionService.transcribe(audio: audio, fileExtension: fileExtension, preferDiarize: false)
    }

    static func plain(fileURL: URL) async throws -> [Segment] {
        try await TranscriptionService.transcribe(fileURL: fileURL, preferDiarize: false)
    }

    // MARK: Notes files

    /// Writes session.json and notes.md from the phone's copy of the session. Returns the folder.
    @discardableResult
    static func write(session json: [String: Any]) -> URL? {
        guard let id = json["id"] as? String, let startedAt = json["started"] as? Double else { return nil }
        let started = Date(timeIntervalSince1970: startedAt)
        let folder = folder(session: id, started: started)
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("session.json"), options: .atomic)
        }
        try? markdown(json, started: started).write(to: folder.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        return folder
    }

    static func markdown(_ json: [String: Any], started: Date) -> String {
        let ended = (json["ended"] as? Double).map { Date(timeIntervalSince1970: $0) }
        let entries = json["entries"] as? [[String: Any]] ?? []
        let pending = json["transcribing"] as? Int ?? 0
        let day = DateFormatter()
        day.dateStyle = .full
        day.timeStyle = .short
        let clock = DateFormatter()
        clock.dateFormat = "h:mm:ss a"

        var out = ["# Bluey session: \(day.string(from: started))", ""]
        if let ended {
            let minutes = Int(ended.timeIntervalSince(started) / 60)
            out.append("Ended \(clock.string(from: ended)) (\(minutes / 60)h \(minutes % 60)m).")
        } else {
            out.append("Still recording.")
        }
        if let target = json["captureTarget"] as? String, !target.isEmpty {
            out.append("Screen source: \(target).")
        }
        if let video = json["video"] as? String, !video.isEmpty {
            out.append("Video: [\(video)](\(video))")
        }
        if pending > 0 { out.append("\(pending) recording chunk(s) still being transcribed; this file updates when they're done.") }
        let asked = entries.filter { $0["kind"] as? String == "asked" }.count
        if asked > 0 { out.append("Riley asked Bluey \(asked) question(s); they're marked inline below.") }
        out += ["", "## Transcript", ""]

        for entry in entries {
            let kind = entry["kind"] as? String
            let text = (entry["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty || kind == "screenshot" else { continue }
            let time = (entry["time"] as? Double).map { clock.string(from: Date(timeIntervalSince1970: $0)) } ?? ""
            switch kind {
            case "transcript":
                out.append("**[\(time)] Speaker \(entry["speaker"] as? String ?? "?"):** \(text)")
            case "screenshot":
                let path = (entry["path"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !path.isEmpty else { continue }
                let manual = entry["manual"] as? Bool ?? false
                let caption = text.isEmpty ? (manual ? "Screenshot" : "Folie / Bildschirmänderung") : text
                out.append("**[\(time)] \(caption):**")
                out.append("![\(caption)](\(path))")
            case "heard":
                out.append("[\(time)] (live) \(text)")
            case "asked":
                out.append("> **[\(time)] Riley asked Bluey:** \(text)")
            case "reply":
                out.append("> **Bluey:** \(text)")
            case "codex":
                out.append("> **[\(time)] Codex:** \(text)")
            case "report":
                let quoted = text.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
                out.append("> **Research report:**\n" + quoted)
            case "drawing":
                let offset = entry["videoOffset"] as? String ?? ""
                let source = entry["source"] as? String ?? "Zeichnung"
                let img = entry["png"] as? String
                let svg = entry["svg"] as? String
                let stamp = offset.isEmpty ? time : "\(offset) | \(time)"
                var line = "**[\(stamp)] Zeichnung (\(source)):** \(text)"
                if let svg { line += " · [SVG](\(svg))" }
                out.append(line)
                if let img {
                    out.append("![Zeichnung \(offset)](\(img))")
                }
            default:
                out.append("[\(time)] \(text)")
            }
            out.append("")
        }
        return out.joined(separator: "\n")
    }
}

private extension DateFormatter {
    static let folderName: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm"
        return f
    }()
}
