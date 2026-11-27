import Foundation
import GooglyShared
import XCTest
@testable import GooglyMac

final class MeetingWorkflowTests: XCTestCase {
    @available(macOS 15, *)
    func testLegacyMacCallJSONDecodesCleanlyWithFallbackTitleAndDuration() throws {
        let start = Date(timeIntervalSince1970: 1_764_144_900)
        let end = start.addingTimeInterval(3600 + 24 * 60)
        let legacyJSON: [String: Any] = [
            "id": UUID().uuidString,
            "started": start.timeIntervalSinceReferenceDate,
            "ended": end.timeIntervalSinceReferenceDate,
            "captureTargetName": "Microsoft Teams · KI Verantworten",
            "clips": [],
            "messages": [],
            "screenshots": ["slide-001.jpg"],
            "drawings": [],
        ]
        let data = try JSONSerialization.data(withJSONObject: legacyJSON)
        let decoded = try JSONDecoder().decode(MeetingSession.self, from: data)

        XCTAssertEqual(decoded.displayTitle, "Microsoft Teams · KI Verantworten")
        XCTAssertEqual(decoded.manualNotes, "")
        XCTAssertTrue(decoded.tasks.isEmpty)
        XCTAssertEqual(decoded.screenshots.map(\.filename), ["slide-001.jpg"])
        XCTAssertEqual(decoded.trackedDuration(), 3600 + 24 * 60, accuracy: 0.5)
        XCTAssertFalse(decoded.isTimerRunning)
    }

    @available(macOS 15, *)
    func testVisualRecordingRoundTripsWithMeetingWorkflowAndExportsLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bluey-visual-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 1_764_150_000)
        let shot = MeetingAudio.Screenshot(filename: "screenshots/slide.jpg", captured: start.addingTimeInterval(30), manual: true)
        let drawing = MeetingDrawingEvent(timestamp: start.addingTimeInterval(45), videoOffsetSeconds: 45,
                                   source: "Bildschirm", svgFilename: "screen.svg", pngFilename: "screen.png",
                                   strokeCount: 3, ocrText: "Skizze")
        let session = MeetingSession(title: "Planung", captureTargetName: "Teams", started: start,
                                     ended: start.addingTimeInterval(60), drawings: [drawing], screenshots: [shot],
                                     videoFilename: "video.mp4", manualNotes: "Eigene Notizen zur Planung",
                                     tasks: [MeetingTask(title: "Skizze prüfen")])
        let decoded = try JSONDecoder().decode(MeetingSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(decoded.videoFilename, "video.mp4")
        XCTAssertEqual(decoded.drawings, [drawing])
        XCTAssertEqual(decoded.screenshots, [shot])
        XCTAssertEqual(decoded.tasks, session.tasks)
        XCTAssertTrue(decoded.transcript.contains("Skizze"))
        MeetingNotes.exportSessionFiles(decoded, in: root)
        let folder = MeetingNotes.folder(session: decoded.id.uuidString, started: decoded.started, in: root)
        let notes = try String(contentsOf: folder.appendingPathComponent("notes.md"), encoding: .utf8)
        for expected in ["video.mp4", "screenshots/slide.jpg", "drawings/screen.svg", "drawings/screen.png",
                         "Eigene Notizen zur Planung", "Skizze prüfen"] {
            XCTAssertTrue(notes.contains(expected), "Missing \(expected)")
        }
    }

    @available(macOS 15, *)
    func testMeetingTimeTrackingStartPauseResumeAndFinish() {
        let t0 = Date(timeIntervalSince1970: 1_764_150_000)
        var session = MeetingSession(title: "Sprint Sync", started: t0)
        session.startTimer(at: t0)
        XCTAssertTrue(session.isTimerRunning)
        XCTAssertEqual(session.trackedDuration(at: t0.addingTimeInterval(300)), 300, accuracy: 0.1)

        // Pause after 5 minutes
        session.pauseTimer(at: t0.addingTimeInterval(300))
        XCTAssertFalse(session.isTimerRunning)
        // 10 minutes pass while paused; tracked time stays 5 minutes
        XCTAssertEqual(session.trackedDuration(at: t0.addingTimeInterval(900)), 300, accuracy: 0.1)

        // Resume at t+900, finish at t+1500 (+10 min = 15 min total)
        session.startTimer(at: t0.addingTimeInterval(900))
        XCTAssertTrue(session.isTimerRunning)
        session.finishTimer(at: t0.addingTimeInterval(1500))
        XCTAssertFalse(session.isTimerRunning)
        XCTAssertEqual(session.trackedDuration(at: t0.addingTimeInterval(2000)), 900, accuracy: 0.1)
        XCTAssertEqual(session.ended, t0.addingTimeInterval(1500))
    }

    func testMeetingTimeStatsComputesTodayWeekAndLast7Days() {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        cal.timeZone = TimeZone(secondsFromGMT: 0)!

        // Thursday 2026-11-26 15:00 UTC
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: 15, minute: 0))!
        let todayMeeting = MeetingTimeSummaryEntry(
            id: UUID(), title: "Daily", started: cal.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: 9))!,
            ended: nil, duration: 1800, isActive: false, taskCount: 2, sentToT3Count: 1, messageCount: 1, hasNotes: true
        )
        let tuesdayMeeting = MeetingTimeSummaryEntry(
            id: UUID(), title: "Design", started: cal.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: 11))!,
            ended: nil, duration: 3600, isActive: false, taskCount: 1, sentToT3Count: 0, messageCount: 0, hasNotes: true
        )
        let lastWeekMeeting = MeetingTimeSummaryEntry(
            id: UUID(), title: "Retro", started: cal.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 14))!,
            ended: nil, duration: 2400, isActive: false, taskCount: 0, sentToT3Count: 0, messageCount: 0, hasNotes: false
        )

        let stats = MeetingTimeStats.compute(from: [todayMeeting, tuesdayMeeting, lastWeekMeeting], now: now, calendar: cal)
        XCTAssertEqual(stats.todaySeconds, 1800, accuracy: 0.1)
        XCTAssertEqual(stats.todayCount, 1)
        XCTAssertEqual(stats.weekSeconds, 5400, accuracy: 0.1)
        XCTAssertEqual(stats.weekCount, 2)
        XCTAssertEqual(stats.totalSeconds, 7800, accuracy: 0.1)
        XCTAssertEqual(stats.totalCount, 3)
        XCTAssertEqual(stats.last7Days.count, 7)
        XCTAssertEqual(stats.last7Days.last?.seconds ?? -1, 1800, accuracy: 0.1)
    }

    func testDurationFormatting() {
        XCTAssertEqual(MeetingDurationFormatter.stopwatch(65), "01:05")
        XCTAssertEqual(MeetingDurationFormatter.stopwatch(3665), "1:01:05")
        XCTAssertEqual(MeetingDurationFormatter.human(0), "0 Min.")
        XCTAssertEqual(MeetingDurationFormatter.human(45), "45 Sek.")
        XCTAssertEqual(MeetingDurationFormatter.human(900), "15 Min.")
        XCTAssertEqual(MeetingDurationFormatter.human(5400), "1h 30m")
    }

    func testMeetingTaskParserHandlesJSONAndMarkdownBullets() {
        let jsonInput = """
        ```json
        [
          {"title": "Login-Redirect fixen", "details": "Cookie-Expiry prüfen", "quote": "09:18 Wir müssen das bis morgen fixen"},
          {"title": "Doku aktualisieren"}
        ]
        ```
        """
        let parsedJSON = MeetingTaskParser.parse(jsonInput)
        XCTAssertEqual(parsedJSON.count, 2)
        XCTAssertEqual(parsedJSON[0].title, "Login-Redirect fixen")
        XCTAssertEqual(parsedJSON[0].details, "Cookie-Expiry prüfen")
        XCTAssertEqual(parsedJSON[0].sourceQuote, "09:18 Wir müssen das bis morgen fixen")
        XCTAssertEqual(parsedJSON[1].title, "Doku aktualisieren")

        let bulletInput = """
        ## Aufgaben
        - [ ] **API-Endpoint erweitern**
        - Tests für Zeiterfassung ergänzen
        3. PR mergen
        """
        let parsedBullets = MeetingTaskParser.parse(bulletInput)
        XCTAssertEqual(parsedBullets.map(\.title), [
            "API-Endpoint erweitern",
            "Tests für Zeiterfassung ergänzen",
            "PR mergen",
        ])
    }

    @available(macOS 15, *)
    func testEasyAccessFolderExportsAndRenameCleanup() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("bluey-notes-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let start = Date(timeIntervalSince1970: 1_764_150_000)
        var session = MeetingSession(
            title: "Projekt Alpha / Kickoff",
            started: start,
            ended: start.addingTimeInterval(2700),
            clips: [
                MeetingAudio.Clip(source: .system, filename: "system-1.m4a", started: start.addingTimeInterval(60), transcript: "Bitte baue den T3-Button ein.")
            ],
            messages: [
                ChatMessage(role: .user, text: "Was war meine Aufgabe?", now: start.addingTimeInterval(120)),
                ChatMessage(role: .assistant, text: "Du sollst den T3-Button einbauen.", now: start.addingTimeInterval(125)),
            ],
            manualNotes: "Wichtig: Shortcuts nicht vergessen.",
            tasks: [
                MeetingTask(title: "T3-Button bauen", sentToT3At: start.addingTimeInterval(200), t3ProjectName: "bluey-by-riley")
            ]
        )

        MeetingNotes.exportSessionFiles(session, in: tempRoot, now: start.addingTimeInterval(2700))
        MeetingNotes.writeTimeLog([session.timeSummary(at: start.addingTimeInterval(2700))], in: tempRoot, now: start.addingTimeInterval(2700))

        let notesFiles = try FileManager.default.contentsOfDirectory(at: MeetingNotes.notesFolder(in: tempRoot), includingPropertiesForKeys: nil)
        let messageFiles = try FileManager.default.contentsOfDirectory(at: MeetingNotes.messagesFolder(in: tempRoot), includingPropertiesForKeys: nil)
        let taskFiles = try FileManager.default.contentsOfDirectory(at: MeetingNotes.tasksFolder(in: tempRoot), includingPropertiesForKeys: nil)

        XCTAssertEqual(notesFiles.count, 1)
        XCTAssertEqual(messageFiles.count, 1)
        XCTAssertEqual(taskFiles.count, 1)
        XCTAssertTrue(notesFiles[0].lastPathComponent.contains("Projekt Alpha Kickoff"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: MeetingNotes.timeLogFile(in: tempRoot).path))

        let timeLogText = try String(contentsOf: MeetingNotes.timeLogFile(in: tempRoot), encoding: .utf8)
        XCTAssertTrue(timeLogText.contains("45 Min."))
        XCTAssertTrue(timeLogText.contains("Projekt Alpha / Kickoff"))

        // Renaming should replace the flat file instead of leaving duplicates behind.
        session.title = "Projekt Beta"
        MeetingNotes.exportSessionFiles(session, in: tempRoot, now: start.addingTimeInterval(2700))
        let renamedNotesFiles = try FileManager.default.contentsOfDirectory(at: MeetingNotes.notesFolder(in: tempRoot), includingPropertiesForKeys: nil)
        XCTAssertEqual(renamedNotesFiles.count, 1)
        XCTAssertTrue(renamedNotesFiles[0].lastPathComponent.contains("Projekt Beta"))
    }

    func testT3CodeBridgeSendsTaskAndAutoRegistersMissingProject() async throws {
        actor CallRecorder {
            var calls: [(binary: String, args: [String], stdin: String?)] = []
            func append(_ binary: String, _ args: [String], _ stdin: String?) -> Int {
                calls.append((binary, args, stdin))
                return calls.count
            }
        }
        let recorder = CallRecorder()

        let result = try await T3CodeBridge.sendTask(
            title: "Bug im Audio-Export beheben",
            prompt: "Bitte prüfe MeetingAudio.swift",
            projectPath: "/tmp/example-project",
            worktreeBase: "main",
            openApp: false,
            cliOverride: "/opt/homebrew/bin/t3",
            runner: { binary, args, stdin in
                let count = await recorder.append(binary, args, stdin)
                if count == 1 {
                    return T3CodeBridge.CommandOutput(exitCode: 1, stdout: "", stderr: "Project not found for path /tmp/example-project")
                }
                if count == 2 {
                    return T3CodeBridge.CommandOutput(exitCode: 0, stdout: "added", stderr: "")
                }
                return T3CodeBridge.CommandOutput(exitCode: 0, stdout: #"{"threadId":"thr_12345"}"#, stderr: "")
            }
        )

        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls[0].args, ["thread", "start", "--json", "--title", "Bug im Audio-Export beheben", "--worktree", "main", "/tmp/example-project", "-"])
        XCTAssertEqual(calls[0].stdin, "Bitte prüfe MeetingAudio.swift")
        XCTAssertEqual(calls[1].args, ["project", "add", "/tmp/example-project"])
        XCTAssertEqual(calls[2].args, calls[0].args)
        XCTAssertEqual(result.threadID, "thr_12345")
        XCTAssertEqual(result.projectName, "example-project")
    }
}
