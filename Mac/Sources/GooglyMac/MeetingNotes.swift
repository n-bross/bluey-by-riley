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

    static let libraryFolderNames: Set<String> = ["Notizen", "Nachrichten", "Aufgaben"]

    static func notesFolder(in root: URL = MeetingNotes.root) -> URL {
        root.appendingPathComponent("Notizen", isDirectory: true)
    }

    static func messagesFolder(in root: URL = MeetingNotes.root) -> URL {
        root.appendingPathComponent("Nachrichten", isDirectory: true)
    }

    static func tasksFolder(in root: URL = MeetingNotes.root) -> URL {
        root.appendingPathComponent("Aufgaben", isDirectory: true)
    }

    static func timeLogFile(in root: URL = MeetingNotes.root) -> URL {
        root.appendingPathComponent("Zeiterfassung.md")
    }

    /// Creates the top-level easy-access folders (Notizen/, Nachrichten/, Aufgaben/) and README.
    static func ensureLibraryFolders(in root: URL = MeetingNotes.root) {
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        try? fm.createDirectory(at: notesFolder(in: root), withIntermediateDirectories: true)
        try? fm.createDirectory(at: messagesFolder(in: root), withIntermediateDirectories: true)
        try? fm.createDirectory(at: tasksFolder(in: root), withIntermediateDirectories: true)
        writeReadmeIfNeeded(in: root)
    }

    struct Segment {
        var speaker: String
        var start: Double
        var end: Double
        var text: String
    }

    // MARK: Folders

    /// The session's folder, made the first time it's needed.
    static func folder(session: String, started: Date, in root: URL = MeetingNotes.root) -> URL {
        let fm = FileManager.default
        ensureLibraryFolders(in: root)
        let tag = String(session.prefix(8)).lowercased()
        if let existing = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?
            .first(where: { !libraryFolderNames.contains($0.lastPathComponent) && $0.lastPathComponent.hasSuffix(tag) }) {
            return existing
        }
        let name = DateFormatter.folderName.string(from: started) + " " + tag
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? fm.createDirectory(at: url.appendingPathComponent("audio"), withIntermediateDirectories: true)
        return url
    }

    private static func writeReadmeIfNeeded(in root: URL = MeetingNotes.root) {
        let url = root.appendingPathComponent("README.md")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let text = """
        # Bluey Notes

        Meeting notes, messages, tasks, and tracked meeting time recorded by Bluey.

        Quick-access folders:
        - `Notizen/`: Clean Markdown notes for every meeting.
        - `Nachrichten/`: Bluey Q&A messages and transcripts for every meeting.
        - `Aufgaben/`: Action items and tasks (including items sent to T3 Code).
        - `Zeiterfassung.md`: Tracked time summary across meetings.

        Each meeting also keeps its full raw session folder (`<date> <id>/`) with:
        - `notes.md`: Full combined Markdown (title, duration, notes, tasks, Q&A, transcript).
        - `notizen.md`, `nachrichten.md`, `aufgaben.md`, `transkript.txt`: Individual files.
        - `session.json` / `mac-call.json`: Structured session data.
        - `audio/`: Raw audio clips.
        """
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func sanitizeFilename(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Meeting" }
        let forbidden = CharacterSet(charactersIn: "/\\:?*\"<>|\n\r\t")
        let cleaned = trimmed.components(separatedBy: forbidden).joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        guard !cleaned.isEmpty else { return "Meeting" }
        return String(cleaned.prefix(64))
    }

    @available(macOS 15, *)
    static func exportSessionFiles(
        _ session: MeetingSession,
        in root: URL = MeetingNotes.root,
        now: Date = Date()
    ) {
        ensureLibraryFolders(in: root)
        let sessionFolder = folder(session: session.id.uuidString, started: session.started, in: root)
        let dateStamp = DateFormatter.folderName.string(from: session.started)
        let safeTitle = sanitizeFilename(session.displayTitle)
        let flatName = "\(dateStamp) - \(safeTitle) (\(session.shortTag)).md"
        let durationText = MeetingDurationFormatter.human(session.trackedDuration(at: now))
        let dayText = session.started.formatted(.dateTime.weekday(.wide).day().month(.wide).year().hour().minute().locale(Locale(identifier: "de_DE")))

        // 1. Manual notes file (notizen.md + Notizen/<flatName>)
        let cleanNotes = session.manualNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let notesDoc = """
        # \(session.displayTitle)

        - Datum: \(dayText)
        - Dauer: \(durationText)
        - Session-Ordner: `\(sessionFolder.lastPathComponent)`

        ## Notizen

        \(cleanNotes.isEmpty ? "_Noch keine eigenen Notizen eingetragen._" : cleanNotes)
        """
        try? notesDoc.write(to: sessionFolder.appendingPathComponent("notizen.md"), atomically: true, encoding: .utf8)
        replaceFlatFile(in: notesFolder(in: root), tag: session.shortTag, newName: flatName, content: cleanNotes.isEmpty && session.tasks.isEmpty ? nil : notesDoc)

        // 2. Tasks file (aufgaben.md + Aufgaben/<flatName>)
        if !session.tasks.isEmpty {
            var taskLines = [
                "# Aufgaben · \(session.displayTitle)",
                "",
                "- Datum: \(dayText)",
                "- Dauer: \(durationText)",
                "",
            ]
            for task in session.tasks {
                let box = task.done ? "[x]" : "[ ]"
                var line = "- \(box) **\(task.title)**"
                if let project = task.t3ProjectName, task.isSentToT3 {
                    line += " _(an T3 Code → \(project))_"
                }
                taskLines.append(line)
                if !task.details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    taskLines.append("  - \(task.details)")
                }
                if let quote = task.sourceQuote, !quote.isEmpty {
                    taskLines.append("  > \(quote)")
                }
            }
            let tasksDoc = taskLines.joined(separator: "\n") + "\n"
            try? tasksDoc.write(to: sessionFolder.appendingPathComponent("aufgaben.md"), atomically: true, encoding: .utf8)
            replaceFlatFile(in: tasksFolder(in: root), tag: session.shortTag, newName: flatName, content: tasksDoc)
        } else {
            try? FileManager.default.removeItem(at: sessionFolder.appendingPathComponent("aufgaben.md"))
            replaceFlatFile(in: tasksFolder(in: root), tag: session.shortTag, newName: flatName, content: nil)
        }

        // 3. Messages & Transcript file (nachrichten.md + transkript.txt + Nachrichten/<flatName>)
        let transcriptText = session.transcript
        if !transcriptText.isEmpty {
            try? (transcriptText + "\n").write(to: sessionFolder.appendingPathComponent("transkript.txt"), atomically: true, encoding: .utf8)
        }
        var msgLines = [
            "# Nachrichten & Transkript · \(session.displayTitle)",
            "",
            "- Datum: \(dayText)",
            "- Dauer: \(durationText)",
            "",
        ]
        if !session.messages.isEmpty {
            msgLines.append("## Bluey-Nachrichten & Rückfragen")
            msgLines.append("")
            for msg in session.messages {
                let time = msg.createdAt.formatted(date: .omitted, time: .standard)
                let who = msg.role == .user ? "Du" : "Bluey"
                msgLines.append("**[\(time)] \(who):** \(msg.text)")
                msgLines.append("")
            }
        }
        if !transcriptText.isEmpty {
            msgLines.append("## Transkript")
            msgLines.append("")
            msgLines.append(transcriptText)
            msgLines.append("")
        }
        let hasMessagesOrTranscript = !session.messages.isEmpty || !transcriptText.isEmpty
        if hasMessagesOrTranscript {
            let msgDoc = msgLines.joined(separator: "\n")
            try? msgDoc.write(to: sessionFolder.appendingPathComponent("nachrichten.md"), atomically: true, encoding: .utf8)
            replaceFlatFile(in: messagesFolder(in: root), tag: session.shortTag, newName: flatName, content: msgDoc)
        } else {
            replaceFlatFile(in: messagesFolder(in: root), tag: session.shortTag, newName: flatName, content: nil)
        }

        // 4. Combined notes.md inside the session folder (rich overview for agents & humans)
        var combined = [
            "# \(session.displayTitle)",
            "",
            "- Datum: \(dayText)",
            "- Dauer: \(durationText)" + (session.isTimerRunning ? " (läuft)" : ""),
            "- Aufgaben: \(session.tasks.count) (davon \(session.tasks.filter(\.isSentToT3).count) an T3 Code gesendet)",
            "- Nachrichten: \(session.messages.count)",
        ]
        if let target = session.captureTargetName, !target.isEmpty {
            combined.append("- Bildquelle: \(target)")
        }
        if let video = session.videoFilename, !video.isEmpty {
            combined.append("- Video: [\(video)](\(video))")
        }
        combined.append("")
        if !cleanNotes.isEmpty {
            combined += ["## Notizen", "", cleanNotes, ""]
        }
        if !session.tasks.isEmpty {
            combined += ["## Aufgaben", ""]
            for task in session.tasks {
                let box = task.done ? "[x]" : "[ ]"
                let badge = task.isSentToT3 ? " _(T3 Code: \(task.t3ProjectName ?? "gesendet"))_" : ""
                combined.append("- \(box) \(task.title)\(badge)")
            }
            combined.append("")
        }
        if !session.screenshots.isEmpty {
            combined += ["## Screenshots & Folien", ""]
            for shot in session.screenshots {
                let time = shot.captured.formatted(date: .omitted, time: .standard)
                let caption = shot.label ?? (shot.manual ? "Screenshot" : "Folie / Bildschirmänderung")
                combined.append("**[\(time)] \(caption):**")
                combined.append("![\(caption)](\(shot.filename))")
                combined.append("")
            }
        }
        if !session.drawings.isEmpty {
            combined += ["## Zeichnungen", ""]
            for d in session.drawings {
                let detail = (d.ocrText?.isEmpty == false ? d.ocrText! : "\(d.strokeCount) Striche")
                combined.append("**[\(d.timecode)] Zeichnung (\(d.source)):** \(detail) · [SVG](drawings/\(d.svgFilename))")
                if let png = d.pngFilename {
                    combined.append("![Zeichnung \(d.timecode)](drawings/\(png))")
                }
                combined.append("")
            }
        }
        if !session.messages.isEmpty {
            combined += ["## Bluey-Rückfragen", ""]
            for msg in session.messages {
                let time = msg.createdAt.formatted(date: .omitted, time: .standard)
                let who = msg.role == .user ? "Du" : "Bluey"
                combined.append("> **[\(time)] \(who):** \(msg.text)")
                combined.append("")
            }
        }
        if !transcriptText.isEmpty {
            combined += ["## Transkript", "", transcriptText, ""]
        }
        if session.captureTargetName != nil || session.videoFilename != nil ||
            !session.screenshots.isEmpty || !session.drawings.isEmpty {
            combined += ["## Bildschirmaufnahme & Zeichnungen", ""]
            if let source = session.captureTargetName { combined.append("- Bildquelle: \(source)") }
            if let video = session.videoFilename { combined.append("- [Bildschirmvideo](<\(video)>)") }
            for shot in session.screenshots.sorted(by: { $0.captured < $1.captured }) {
                let caption = shot.label ?? (shot.manual ? "Screenshot" : "Folie / Bildschirmänderung")
                let time = shot.captured.formatted(date: .omitted, time: .standard)
                combined.append("- [\(time) · \(caption)](<\(shot.filename)>)")
            }
            for drawing in session.drawings.sorted(by: { $0.timestamp < $1.timestamp }) {
                var line = "- \(drawing.timecode) · Zeichnung (\(drawing.source)) · [SVG](<drawings/\(drawing.svgFilename)>)"
                if let png = drawing.pngFilename { line += " · [PNG](<drawings/\(png)>)" }
                combined.append(line)
            }
            combined.append("")
        }
        try? combined.joined(separator: "\n").write(to: sessionFolder.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
    }

    private static func replaceFlatFile(in folder: URL, tag: String, newName: String, content: String?) {
        let fm = FileManager.default
        let suffix = "(\(tag)).md"
        if let existing = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            for file in existing where file.lastPathComponent.hasSuffix(suffix) && file.lastPathComponent != newName {
                try? fm.removeItem(at: file)
            }
        }
        let target = folder.appendingPathComponent(newName)
        if let content {
            try? content.write(to: target, atomically: true, encoding: .utf8)
        } else {
            try? fm.removeItem(at: target)
        }
    }

    /// Writes ~/Documents/Bluey Notes/Zeiterfassung.md summarizing all tracked meetings.
    static func writeTimeLog(_ entries: [MeetingTimeSummaryEntry], in root: URL = MeetingNotes.root, now: Date = Date()) {
        ensureLibraryFolders(in: root)
        let stats = MeetingTimeStats.compute(from: entries, now: now)
        let sorted = entries.sorted { $0.started > $1.started }
        let updated = now.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().locale(Locale(identifier: "de_DE")))

        var lines = [
            "# Meeting-Zeiterfassung",
            "",
            "_Zuletzt aktualisiert: \(updated)_",
            "",
            "- **Heute:** \(MeetingDurationFormatter.human(stats.todaySeconds)) (\(stats.todayCount) \(stats.todayCount == 1 ? "Meeting" : "Meetings"))",
            "- **Diese Woche:** \(MeetingDurationFormatter.human(stats.weekSeconds)) (\(stats.weekCount) \(stats.weekCount == 1 ? "Meeting" : "Meetings"))",
            "- **Gesamt:** \(MeetingDurationFormatter.human(stats.totalSeconds)) (\(stats.totalCount) \(stats.totalCount == 1 ? "Meeting" : "Meetings"))",
            "",
            "| Datum | Meeting | Dauer | Aufgaben | T3 Code |",
            "| :--- | :--- | ---: | ---: | ---: |",
        ]
        for entry in sorted {
            let date = entry.started.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().locale(Locale(identifier: "de_DE")))
            let title = entry.title.replacingOccurrences(of: "|", with: "/")
            let duration = MeetingDurationFormatter.human(entry.duration) + (entry.isActive ? " (läuft)" : "")
            lines.append("| \(date) | \(title) | \(duration) | \(entry.taskCount) | \(entry.sentToT3Count) |")
        }
        lines.append("")
        try? lines.joined(separator: "\n").write(to: timeLogFile(in: root), atomically: true, encoding: .utf8)
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
