import XCTest
@testable import GooglyShared

final class HermesTests: XCTestCase {
    func testApprovalControlParses() throws {
        let control: [String: Any] = ["kind": "approval", "prompt_id": "p1", "execution_generation": 3,
                                      "command": "rm -rf build", "description": "Delete build folder",
                                      "choices": ["once", "deny", "session", "always"]]
        let prompt = try XCTUnwrap(HermesPrompt(control: control))
        XCTAssertEqual(prompt.id, "p1")
        XCTAssertEqual(prompt.kind, .approval)
        XCTAssertEqual(prompt.generation, 3)
        XCTAssertEqual(prompt.text, "rm -rf build")
        XCTAssertEqual(prompt.detail, "Delete build folder")
        XCTAssertEqual(prompt.choices, ["once", "deny", "session", "always"])
    }

    func testApprovalWithoutChoicesOffersAllowAndDeny() throws {
        let prompt = try XCTUnwrap(HermesPrompt(control: ["kind": "approval", "prompt_id": "p", "description": "Send a message"]))
        XCTAssertEqual(prompt.text, "Send a message")
        XCTAssertNil(prompt.detail)
        XCTAssertEqual(prompt.generation, 0)
        XCTAssertEqual(prompt.choices, ["once", "deny"])
    }

    func testClarifyControlParses() throws {
        let prompt = try XCTUnwrap(HermesPrompt(control: ["kind": "clarify", "prompt_id": "c", "execution_generation": 1,
                                                          "question": "Which Anna?", "choices": ["Anna B.", "Anna K."]]))
        XCTAssertEqual(prompt.kind, .clarify)
        XCTAssertEqual(prompt.text, "Which Anna?")
        XCTAssertEqual(prompt.choices, ["Anna B.", "Anna K."])
    }

    func testUnknownControlIsIgnored() {
        XCTAssertNil(HermesPrompt(control: ["kind": "secret", "prompt_id": "s"]))
        XCTAssertNil(HermesPrompt(control: ["kind": "approval"]))
    }

    func testActivitySummaryText() {
        let summary = ActivitySummary(from: Date(), to: Date(), activeSeconds: 3 * 3600 + 5 * 60, afkSeconds: 20 * 60,
                                      apps: [AppTime(name: "Xcode", seconds: 7200), AppTime(name: "Safari", seconds: 1800)])
        XCTAssertEqual(ActivitySummary.duration(3 * 3600 + 5 * 60), "3h 05m")
        XCTAssertEqual(ActivitySummary.duration(59), "1m")
        XCTAssertTrue(summary.plainText.hasPrefix("Active (keyboard/mouse) 3h 05m, away 20m."))
        XCTAssertTrue(summary.plainText.contains("Xcode 2h 00m, Safari 30m"))
    }

    func testOlderFocusHistoryStillDecodes() throws {
        var session = FocusSession(task: "Write the report")
        session.activity = nil
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
        json.removeValue(forKey: "activity")
        let decoded = try JSONDecoder().decode(FocusSession.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.activity)
        XCTAssertEqual(decoded.task, "Write the report")
    }

    func testSyncRoundTrips() throws {
        var run = HermesRun(id: "run_1", prompt: "What's on my calendar?", status: .waiting)
        run.pending = [HermesPrompt(id: "p", kind: .approval, generation: 1, text: "gcal list", choices: ["once", "deny"])]
        let sync = HermesSync(available: true, problem: nil, mode: .ask, runs: [run], activityAvailable: false, today: nil)
        let back = try JSONDecoder().decode(HermesSync.self, from: JSONEncoder().encode(sync))
        XCTAssertEqual(back, sync)
        XCTAssertTrue(back.runs[0].isActive)
    }
}
