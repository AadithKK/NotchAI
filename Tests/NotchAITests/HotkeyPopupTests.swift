import CoreGraphics
import XCTest
@testable import NotchAI

@MainActor
final class HotkeyPopupTests: XCTestCase {
    /// Real CGEvents through the same handler the event tap calls (h = keycode 4, j = 38).
    func testRealKeyEventsFireTheShortcuts() {
        let monitor = DoubleTapMonitor()
        var fired: [String] = []
        monitor.onTrigger = { fired.append($0) }
        func tap(_ code: CGKeyCode) {
            monitor.handle(type: .keyDown, event: CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)!)
        }
        tap(4); Thread.sleep(forTimeInterval: 0.1); tap(4)
        Thread.sleep(forTimeInterval: 1.1)
        tap(38); Thread.sleep(forTimeInterval: 0.1); tap(38)
        Thread.sleep(forTimeInterval: 1.1)
        tap(4); Thread.sleep(forTimeInterval: 0.5); tap(4) // slow typing
        XCTAssertEqual(fired, ["h", "j"])
    }

    func testAnswerPopupClosesTwoSecondsAfterPointerLeaves() {
        let start = Date()
        let next = IslandWindowController.nextAnswerPopupDeadline
        let held = next(start, true, start.addingTimeInterval(30))
        XCTAssertEqual(held, start.addingTimeInterval(32))
        XCTAssertEqual(next(held!, false, start.addingTimeInterval(31.9)), held)
        XCTAssertNil(next(held!, false, start.addingTimeInterval(32)))
    }
}
