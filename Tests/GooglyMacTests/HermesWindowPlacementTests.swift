import CoreGraphics
import GooglyShared
import XCTest
@testable import GooglyMac

final class HermesWindowPlacementTests: XCTestCase {
    func testUsesTheVisibleFrameOfAnOffsetMonitor() {
        let screen = CGRect(x: -1440, y: 25, width: 1440, height: 940)
        let initial = CGRect(x: 20, y: 50, width: 600, height: 440)
        XCTAssertEqual(HermesWindowPlacement.left.frame(in: screen, current: initial),
                       CGRect(x: -1440, y: 25, width: 720, height: 940))
        XCTAssertEqual(HermesWindowPlacement.right.frame(in: screen, current: initial),
                       CGRect(x: -720, y: 25, width: 720, height: 940))
        XCTAssertEqual(HermesWindowPlacement.center.frame(in: screen, current: initial),
                       CGRect(x: -1020, y: 275, width: 600, height: 440))
    }

    func testCenterKeepsOversizedWindowsWithinTheDisplay() {
        let screen = CGRect(x: 0, y: 20, width: 900, height: 600)
        let oversized = CGRect(x: 0, y: 0, width: 1300, height: 1000)
        XCTAssertEqual(HermesWindowPlacement.center.frame(in: screen, current: oversized), screen)
    }
}

final class HermesScreenContextTests: XCTestCase {
    func testWaitingHermesRunStaysVisibleAfterSwitchingToAnIdleChat() async {
        await MainActor.run {
            let hermes = ChatThread(title: "Hermes-Auftrag", model: "hermes")
            let other = ChatThread(title: "Anderer Chat", model: "hermes")
            var snapshot = WorkspaceSnapshot()
            snapshot.threads = [hermes, other]
            let workspace = WorkspaceModel(snapshot: snapshot)
            workspace.selectedWorkspaceThread = other.id
            let prompt = HermesPrompt(id: "approval", kind: .approval, generation: 1,
                                      text: "Testaktion", choices: ["once", "deny"])
            workspace.hermesApprovals = [.init(threadID: hermes.id, runID: "run", prompt: prompt)]

            XCTAssertEqual(workspace.hermesScreenThread()?.id, hermes.id)

            workspace.hermesApprovals = []
            XCTAssertEqual(workspace.hermesScreenThread()?.id, other.id)
        }
    }
}
