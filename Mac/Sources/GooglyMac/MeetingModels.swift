import Foundation
import GooglyShared

/// A concrete task or action item captured during a meeting, ready to send to T3 Code or Bluey Todos.
struct MeetingTask: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var title: String
    var details: String
    var done: Bool
    var createdAt: Date
    var sourceQuote: String?
    var sentToT3At: Date?
    var t3ThreadID: String?
    var t3ProjectName: String?
    var t3ProjectPath: String?

    init(
        id: UUID = UUID(),
        title: String,
        details: String = "",
        done: Bool = false,
        createdAt: Date = Date(),
        sourceQuote: String? = nil,
        sentToT3At: Date? = nil,
        t3ThreadID: String? = nil,
        t3ProjectName: String? = nil,
        t3ProjectPath: String? = nil
    ) {
        self.id = id
        self.title = title
        self.details = details
        self.done = done
        self.createdAt = createdAt
        self.sourceQuote = sourceQuote
        self.sentToT3At = sentToT3At
        self.t3ThreadID = t3ThreadID
        self.t3ProjectName = t3ProjectName
        self.t3ProjectPath = t3ProjectPath
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        details = try c.decodeIfPresent(String.self, forKey: .details) ?? ""
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        sourceQuote = try c.decodeIfPresent(String.self, forKey: .sourceQuote)
        sentToT3At = try c.decodeIfPresent(Date.self, forKey: .sentToT3At)
        t3ThreadID = try c.decodeIfPresent(String.self, forKey: .t3ThreadID)
        t3ProjectName = try c.decodeIfPresent(String.self, forKey: .t3ProjectName)
        t3ProjectPath = try c.decodeIfPresent(String.self, forKey: .t3ProjectPath)
    }

    var isSentToT3: Bool { sentToT3At != nil }
}

/// One active time-tracking segment inside a meeting (supports pausing and resuming).
struct MeetingTimeInterval: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var start: Date
    var end: Date?

    init(id: UUID = UUID(), start: Date = Date(), end: Date? = nil) {
        self.id = id
        self.start = start
        self.end = end
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        start = try c.decode(Date.self, forKey: .start)
        end = try c.decodeIfPresent(Date.self, forKey: .end)
    }

    func duration(at now: Date = Date()) -> TimeInterval {
        max(0, (end ?? now).timeIntervalSince(start))
    }
}

/// Lightweight summary of a meeting for time tracking stats, Zeiterfassung.md, and ActivityJournal.
struct MeetingTimeSummaryEntry: Equatable, Identifiable, Sendable {
    var id: UUID
    var title: String
    var started: Date
    var ended: Date?
    var duration: TimeInterval
    var isActive: Bool
    var taskCount: Int
    var sentToT3Count: Int
    var messageCount: Int
    var hasNotes: Bool
}

/// Aggregated meeting time statistics across today, this week, last 7 days, and all time.
struct MeetingTimeStats: Equatable, Sendable {
    struct DayTotal: Identifiable, Equatable, Sendable {
        var date: Date
        var seconds: TimeInterval
        var count: Int
        var id: Date { date }
        var minutes: Double { seconds / 60 }
    }

    var todaySeconds: TimeInterval
    var todayCount: Int
    var weekSeconds: TimeInterval
    var weekCount: Int
    var totalSeconds: TimeInterval
    var totalCount: Int
    var averageSeconds: TimeInterval
    var last7Days: [DayTotal]

    static func compute(
        from entries: [MeetingTimeSummaryEntry],
        now: Date = Date(),
        calendar: Calendar = {
            var c = Calendar(identifier: .gregorian)
            c.firstWeekday = 2 // Monday
            c.timeZone = .current
            return c
        }()
    ) -> MeetingTimeStats {
        let todayStart = calendar.startOfDay(for: now)
        let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? now
        let weekInterval = calendar.dateInterval(of: .weekOfYear, for: now)
        let weekStart = weekInterval?.start ?? calendar.date(byAdding: .day, value: -6, to: todayStart)!

        var todaySeconds: TimeInterval = 0
        var todayCount = 0
        var weekSeconds: TimeInterval = 0
        var weekCount = 0
        var totalSeconds: TimeInterval = 0

        for entry in entries {
            let duration = max(0, entry.duration)
            totalSeconds += duration
            if entry.started >= todayStart && entry.started < tomorrowStart {
                todaySeconds += duration
                todayCount += 1
            }
            if entry.started >= weekStart && entry.started < tomorrowStart {
                weekSeconds += duration
                weekCount += 1
            }
        }

        let last7Days: [DayTotal] = (0..<7).reversed().compactMap { offset -> DayTotal? in
            guard let dayStart = calendar.date(byAdding: .day, value: -offset, to: todayStart),
                  let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return nil }
            let dayEntries = entries.filter { $0.started >= dayStart && $0.started < dayEnd }
            let secs = dayEntries.reduce(0) { $0 + max(0, $1.duration) }
            return DayTotal(date: dayStart, seconds: secs, count: dayEntries.count)
        }

        let avg = entries.isEmpty ? 0 : totalSeconds / Double(entries.count)
        return MeetingTimeStats(
            todaySeconds: todaySeconds,
            todayCount: todayCount,
            weekSeconds: weekSeconds,
            weekCount: weekCount,
            totalSeconds: totalSeconds,
            totalCount: entries.count,
            averageSeconds: avg,
            last7Days: last7Days
        )
    }
}

/// Consistent German/compact duration formatters for stopwatches, badges, and Markdown logs.
enum MeetingDurationFormatter {
    static func stopwatch(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    static func human(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int((max(0, seconds) / 60).rounded(.down))
        if totalMinutes <= 0 {
            let secs = max(0, Int(seconds.rounded(.down)))
            return secs > 0 ? "\(secs) Sek." : "0 Min."
        }
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        if h > 0 {
            return m > 0 ? "\(h)h \(m)m" : "\(h)h"
        }
        return "\(m) Min."
    }
}

/// Parses tasks returned by AI extraction (either JSON array or bulleted Markdown list).
enum MeetingTaskParser {
    private struct ExtractedItem: Decodable {
        var title: String
        var details: String?
        var quote: String?
    }

    static func parse(_ raw: String) -> [MeetingTask] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // 1. Try JSON array (possibly inside a ```json fenced code block).
        if let jsonRange = extractJSONArray(from: trimmed),
           let data = jsonRange.data(using: .utf8),
           let items = try? JSONDecoder().decode([ExtractedItem].self, from: data) {
            let tasks = items.compactMap { item -> MeetingTask? in
                let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return nil }
                let details = (item.details ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let quote = item.quote?.trimmingCharacters(in: .whitespacesAndNewlines)
                return MeetingTask(
                    title: title,
                    details: details,
                    sourceQuote: quote?.isEmpty == false ? quote : nil
                )
            }
            if !tasks.isEmpty { return tasks }
        }

        // 2. Fall back to Markdown checklist / bullet lines.
        var results: [MeetingTask] = []
        for rawLine in trimmed.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            for prefix in ["- [ ] ", "* [ ] ", "- [x] ", "- [X] ", "- ", "* ", "• "] {
                if line.hasPrefix(prefix) {
                    line = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                    break
                }
            }
            // Strip leading numbered list prefix like "1. " or "2) "
            if let range = line.range(of: #"^\d+[\.\)]\s+"#, options: .regularExpression) {
                line = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            // Skip headings or meta lines
            if line.hasPrefix("#") || line.hasPrefix("```") || line.count < 3 { continue }
            // Strip surrounding bold markers if the whole title was bolded
            if line.hasPrefix("**"), line.hasSuffix("**"), line.count > 4 {
                line = String(line.dropFirst(2).dropLast(2))
            }
            if !line.isEmpty {
                results.append(MeetingTask(title: line))
            }
        }
        return results
    }

    private static func extractJSONArray(from text: String) -> String? {
        guard let start = text.firstIndex(of: "["),
              let end = text.lastIndex(of: "]"),
              start < end else { return nil }
        return String(text[start...end])
    }
}

@available(macOS 15, *)
struct DrawingEvent: Codable, Identifiable, Equatable {
    var id = UUID()
    var timestamp = Date()
    /// Elapsed seconds since `session.started` (the exact time in the meeting/video).
    var videoOffsetSeconds: Double
    /// "Notiz" or "Bildschirm"
    var source: String
    var noteID: UUID?
    var svgFilename: String
    var pngFilename: String?
    var strokeCount: Int
    var ocrText: String?

    var timecode: String { InkDrawing.formatVideoTime(videoOffsetSeconds) }
}

@available(macOS 15, *)
struct MeetingSession: Codable, Identifiable {
    var id = UUID()
    var title = ""
    var captureTargetName: String?
    var started = Date()
    var ended: Date?
    var clips: [MeetingAudio.Clip] = []
    var messages: [ChatMessage] = []
    var drawings: [DrawingEvent] = []
    var screenshots: [MeetingAudio.Screenshot] = []
    var videoFilename: String?
    var manualNotes = ""
    var tasks: [MeetingTask] = []
    var trackedIntervals: [MeetingTimeInterval] = []
    var t3ProjectPath: String?

    init(
        id: UUID = UUID(),
        title: String = "",
        captureTargetName: String? = nil,
        started: Date = Date(),
        ended: Date? = nil,
        clips: [MeetingAudio.Clip] = [],
        messages: [ChatMessage] = [],
        drawings: [DrawingEvent] = [],
        screenshots: [MeetingAudio.Screenshot] = [],
        videoFilename: String? = nil,
        manualNotes: String = "",
        tasks: [MeetingTask] = [],
        trackedIntervals: [MeetingTimeInterval] = [],
        t3ProjectPath: String? = nil
    ) {
        self.id = id
        self.title = title
        self.captureTargetName = captureTargetName
        self.started = started
        self.ended = ended
        self.clips = clips
        self.messages = messages
        self.drawings = drawings
        self.screenshots = screenshots
        self.videoFilename = videoFilename
        self.manualNotes = manualNotes
        self.tasks = tasks
        self.trackedIntervals = trackedIntervals
        self.t3ProjectPath = t3ProjectPath
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        captureTargetName = try c.decodeIfPresent(String.self, forKey: .captureTargetName)
        started = try c.decodeIfPresent(Date.self, forKey: .started) ?? Date()
        ended = try c.decodeIfPresent(Date.self, forKey: .ended)
        clips = try c.decodeIfPresent([MeetingAudio.Clip].self, forKey: .clips) ?? []
        messages = try c.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
        drawings = try c.decodeIfPresent([DrawingEvent].self, forKey: .drawings) ?? []
        if let filenames = try? c.decode([String].self, forKey: .screenshots) {
            let captureStart = started
            screenshots = filenames.map { MeetingAudio.Screenshot(filename: $0, captured: captureStart, manual: false) }
        } else {
            screenshots = try c.decodeIfPresent([MeetingAudio.Screenshot].self, forKey: .screenshots) ?? []
        }
        videoFilename = try c.decodeIfPresent(String.self, forKey: .videoFilename)
        manualNotes = try c.decodeIfPresent(String.self, forKey: .manualNotes) ?? ""
        tasks = try c.decodeIfPresent([MeetingTask].self, forKey: .tasks) ?? []
        trackedIntervals = try c.decodeIfPresent([MeetingTimeInterval].self, forKey: .trackedIntervals) ?? []
        t3ProjectPath = try c.decodeIfPresent(String.self, forKey: .t3ProjectPath)
    }

    var folder: URL { MeetingNotes.folder(session: id.uuidString, started: started) }
    var audioFolder: URL { folder.appendingPathComponent("audio", isDirectory: true) }

    var notesURL: URL { folder.appendingPathComponent("notes.md") }
    var videoURL: URL? { videoFilename.map { folder.appendingPathComponent($0) } }
    var drawingsFolder: URL { folder.appendingPathComponent("drawings", isDirectory: true) }

    var displayTitle: String {
        let custom = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { return custom }
        if let target = captureTargetName?.trimmingCharacters(in: .whitespacesAndNewlines), !target.isEmpty {
            return target
        }
        return "Meeting · \(started.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(Locale(identifier: "de_DE"))))"
    }

    var shortTag: String { String(id.uuidString.prefix(8)).lowercased() }

    var transcriptClips: [MeetingAudio.Clip] {
        clips.filter { clip in
            guard let text = clip.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
            return !text.isEmpty
        }
        .sorted { $0.started < $1.started }
    }

    var transcript: String {
        var rows: [(Date, String)] = transcriptClips.map { clip in
            let offset = InkDrawing.formatVideoTime(max(0, clip.started.timeIntervalSince(started)))
            let time = clip.started.formatted(date: .omitted, time: .standard)
            return (clip.started, "[\(offset) · \(time)] \(clip.source.title): \(clip.transcript ?? "")")
        }
        rows += drawings.map { drawing in
            let detail = drawing.ocrText.flatMap { $0.isEmpty ? nil : $0 } ?? "\(drawing.strokeCount) Striche (\(drawing.svgFilename))"
            return (drawing.timestamp, "[\(drawing.timecode)] Zeichnung (\(drawing.source)): \(detail)")
        }
        return rows.sorted { $0.0 < $1.0 }.map(\.1).joined(separator: "\n\n")
    }

    var isTimerRunning: Bool {
        trackedIntervals.contains { $0.end == nil }
    }

    func trackedDuration(at now: Date = Date()) -> TimeInterval {
        if !trackedIntervals.isEmpty {
            return trackedIntervals.reduce(0) { $0 + $1.duration(at: now) }
        }
        if let ended {
            return max(0, ended.timeIntervalSince(started))
        }
        if let lastClip = clips.map(\.started).max() {
            return max(0, lastClip.timeIntervalSince(started))
        }
        return 0
    }

    mutating func startTimer(at now: Date = Date()) {
        guard !isTimerRunning else { return }
        if trackedIntervals.isEmpty, let previousEnd = ended, previousEnd > started {
            // Preserve the legacy duration before appending a resumed interval.
            trackedIntervals.append(MeetingTimeInterval(start: started, end: previousEnd))
        }
        trackedIntervals.append(MeetingTimeInterval(start: now, end: nil))
        ended = nil
    }

    mutating func pauseTimer(at now: Date = Date()) {
        for index in trackedIntervals.indices where trackedIntervals[index].end == nil {
            trackedIntervals[index].end = max(trackedIntervals[index].start, now)
        }
    }

    mutating func toggleTimer(at now: Date = Date()) {
        if isTimerRunning {
            pauseTimer(at: now)
        } else {
            startTimer(at: now)
        }
    }

    mutating func finishTimer(at now: Date = Date()) {
        pauseTimer(at: now)
        ended = now
    }

    func timeSummary(at now: Date = Date()) -> MeetingTimeSummaryEntry {
        MeetingTimeSummaryEntry(
            id: id,
            title: displayTitle,
            started: started,
            ended: ended,
            duration: trackedDuration(at: now),
            isActive: isTimerRunning,
            taskCount: tasks.count,
            sentToT3Count: tasks.filter(\.isSentToT3).count,
            messageCount: messages.count,
            hasNotes: !manualNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }
}
