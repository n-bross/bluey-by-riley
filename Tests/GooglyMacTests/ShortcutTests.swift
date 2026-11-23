import XCTest
import Carbon.HIToolbox
@testable import GooglyMac

final class ShortcutTests: XCTestCase {
    override func tearDown() { ShortcutStore.resetAll() }

    func testDefaultsAvoidOptionSpaceAndAreUnique() {
        ShortcutStore.resetAll()
        let all = ShortcutAction.allCases.compactMap { ShortcutStore.get($0) }
        XCTAssertEqual(all.count, ShortcutAction.allCases.count)
        XCTAssertEqual(Set(all.map { "\($0.keyCode)-\($0.modifiers)" }).count, all.count, "No two defaults collide")
        XCTAssertEqual(ShortcutStore.get(.talk)?.display, "⌃⌥Space")
        XCTAssertEqual(ShortcutStore.get(.hide)?.display, "⌃⌥H")
        XCTAssertFalse(all.contains { $0.keyCode == kVK_Space && $0.modifiers == optionKey }, "⌥Space belongs to other apps")
    }

    func testChangeTurnOffAndReset() {
        let custom = Shortcut(keyCode: kVK_ANSI_J, modifiers: cmdKey | shiftKey, key: "J")
        ShortcutStore.set(.typeToBluey, custom)
        XCTAssertEqual(ShortcutStore.get(.typeToBluey), custom)
        XCTAssertEqual(custom.display, "⇧⌘J")
        XCTAssertEqual(custom.menuKey.key, "j")
        XCTAssertEqual(custom.menuKey.modifiers, [.shift, .command])
        ShortcutStore.set(.typeToBluey, nil)
        XCTAssertNil(ShortcutStore.get(.typeToBluey), "Off stays off, it doesn't fall back to the default")
        ShortcutStore.resetAll()
        XCTAssertEqual(ShortcutStore.get(.typeToBluey)?.key, "B")
    }

    func testConflictDetection() {
        ShortcutStore.resetAll()
        let hide = ShortcutStore.get(.hide)!
        XCTAssertEqual(ShortcutStore.conflict(hide, except: .stop), .hide)
        XCTAssertNil(ShortcutStore.conflict(hide, except: .hide))
    }
}
