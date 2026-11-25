import XCTest
@testable import NotchAI

final class RegionWatcherTests: XCTestCase {
    private let flat = [UInt8](repeating: 100, count: 4096)
    private func changed(_ fraction: Double) -> [UInt8] {
        var copy = flat
        for i in 0..<Int(Double(copy.count) * fraction) { copy[i] = 220 }
        return copy
    }
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testFiresOnlyAfterTheChangeSettles() {
        var d = ChangeDetector()
        XCTAssertFalse(d.ingest(flat, now: t0))                    // baseline
        XCTAssertFalse(d.ingest(changed(0.5), now: t0 + 1))        // change seen, still settling
        XCTAssertFalse(d.ingest(changed(0.9), now: t0 + 2))        // still moving
        XCTAssertTrue(d.ingest(changed(0.9), now: t0 + 3))         // stable: fire
        XCTAssertFalse(d.ingest(changed(0.9), now: t0 + 4))        // same content: no refire
    }

    func testIgnoresSmallFlickerAndChangeThatReverts() {
        var d = ChangeDetector()
        _ = d.ingest(flat, now: t0)
        XCTAssertFalse(d.ingest(changed(0.01), now: t0 + 1))       // caret blink
        XCTAssertFalse(d.ingest(changed(0.5), now: t0 + 2))
        XCTAssertFalse(d.ingest(flat, now: t0 + 3))                // changed back
        XCTAssertFalse(d.ingest(flat, now: t0 + 4))
    }

    func testCooldownDelaysTheNextFire() {
        var d = ChangeDetector()
        _ = d.ingest(flat, now: t0)
        _ = d.ingest(changed(0.5), now: t0 + 5)
        XCTAssertTrue(d.ingest(changed(0.5), now: t0 + 6))
        _ = d.ingest(flat, now: t0 + 7)
        XCTAssertFalse(d.ingest(flat, now: t0 + 8))                // too soon after last send
        XCTAssertTrue(d.ingest(flat, now: t0 + 11))                // cooldown over, still pending
    }

    func testDisplayLocalConversionFlipsYAndSubtractsOrigin() {
        let screen = CGRect(x: 1440, y: 0, width: 1920, height: 1080)      // secondary display on the right
        let global = CGRect(x: 1540, y: 880, width: 300, height: 100)       // near the top of that display
        XCTAssertEqual(RegionGeometry.displayLocal(rect: global, screenFrame: screen),
                       CGRect(x: 100, y: 100, width: 300, height: 100))
    }

    func testAnswerModeDefaultsAndOldSettingsStillDecode() throws {
        XCTAssertEqual(ScreenshotSettings().effectiveAnswerMode, .auto)
        let old = try JSONEncoder().encode(ScreenshotSettings())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: old) as? [String: Any])
        object.removeValue(forKey: "answerMode")
        let decoded = try JSONDecoder().decode(ScreenshotSettings.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.effectiveAnswerMode, .auto)
        XCTAssertTrue(AnswerMode.mcq.prompt.contains("ONLY the letter"))
        XCTAssertEqual(AnswerMode.frq.next, .auto)
    }

    func testDoubleTapNeedsSpeedAndAPauseBeforeIt() {
        var d = DoubleTapDetector()
        XCTAssertNil(d.ingest("h", now: 10.0))
        XCTAssertEqual(d.ingest("h", now: 10.15), "h")               // fast pair after a pause
        XCTAssertNil(d.ingest("h", now: 10.25))                       // locked out: no "hhh" refire

        var slow = DoubleTapDetector()
        XCTAssertNil(slow.ingest("j", now: 20.0))
        XCTAssertNil(slow.ingest("j", now: 20.5))                     // too slow

        var word = DoubleTapDetector()
        XCTAssertNil(word.ingest("a", now: 30.0))
        XCTAssertNil(word.ingest("h", now: 30.1))                     // "ahh": h follows another key closely
        XCTAssertNil(word.ingest("h", now: 30.2))

        var other = DoubleTapDetector()
        XCTAssertNil(other.ingest("k", now: 40.0))
        XCTAssertNil(other.ingest("k", now: 40.1))                    // not a trigger letter
        XCTAssertNil(other.ingest("h", now: 50.0))
        XCTAssertEqual(other.ingest("h", now: 50.1), "h")
    }
}
