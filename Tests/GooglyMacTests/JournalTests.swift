import XCTest
@testable import GooglyMac

final class JournalTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func e(_ minute: Double, _ seconds: Double, _ app: String, _ title: String = "") -> JournalEvent {
        JournalEvent(start: t0.addingTimeInterval(minute * 60), duration: seconds, app: app, title: title)
    }

    func testGlancesDontSplitABlockAndShortBlocksDrop() {
        let blocks = JournalBuilder.blocks([
            e(0, 600, "Xcode", "NotchBluey.swift — Bluey"),
            e(10, 20, "Messages"),                         // a glance: ignored
            e(10.5, 900, "Xcode", "Settings.swift — Bluey"),
            e(26, 60, "Safari", "Docs"),                   // too short for the timeline
            e(27, 1800, "Safari", "Hermes docs — Google Chrome"),
            e(60, 600, "loginwindow"),                     // not work
        ])
        XCTAssertEqual(blocks.map(\.app), ["Xcode", "Safari"])
        XCTAssertEqual(blocks[0].active, 1500)
        XCTAssertEqual(blocks[0].titles.first, "Settings.swift — Bluey")
        XCTAssertEqual(blocks[1].titles.first, "Hermes docs", "Trailing browser names are trimmed")
        XCTAssertEqual(JournalBuilder.clean("Report.docx — Microsoft Word", app: "Microsoft Word"), "Report.docx")
        XCTAssertEqual(JournalBuilder.clean("Settings.swift — Bluey", app: "Xcode"), "Settings.swift — Bluey", "Project names stay")
    }

    func testHoursInOneUnchangedWindowAreFlaggedIdle() {
        let idle = JournalBuilder.blocks([e(0, 9 * 3600, "System Settings", "Screen Recording")])
        XCTAssertTrue(JournalBuilder.probablyIdle(idle[0]))
        let work = JournalBuilder.blocks([e(0, 3600, "Xcode", "A.swift"), e(60, 3600, "Xcode", "B.swift"), e(120, 3600, "Xcode", "C.swift")])
        XCTAssertFalse(JournalBuilder.probablyIdle(work[0]), "Real work changes windows")
    }

    func testLongGapStartsANewBlock() {
        let blocks = JournalBuilder.blocks([e(0, 600, "Xcode"), e(20, 600, "Xcode")])
        XCTAssertEqual(blocks.count, 2)
    }

    func testAwayPeriodsMergeAndFilter() {
        let away = JournalBuilder.away([(t0, 200), (t0.addingTimeInterval(230), 400), (t0.addingTimeInterval(3600), 120)])
        XCTAssertEqual(away.count, 1)
        XCTAssertEqual(away[0].end.timeIntervalSince(away[0].start), 630)
    }

    @MainActor func testDayWordsAndTimestamps() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        XCTAssertEqual(ActivityJournal.resolveDay("today"), today)
        XCTAssertEqual(ActivityJournal.resolveDay("gestern"), cal.date(byAdding: .day, value: -1, to: today))
        XCTAssertNotNil(ActivityJournal.resolveDay("monday"))
        XCTAssertNil(ActivityJournal.resolveDay("someday"))
        let d = ActivityWatch.parseDate("2026-11-19T16:32:45.179000+00:00")
        XCTAssertEqual(d?.timeIntervalSince1970 ?? 0, 1795105965.179, accuracy: 0.001)
    }
}
