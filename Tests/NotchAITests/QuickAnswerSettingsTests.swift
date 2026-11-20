import XCTest
@testable import NotchAI

final class QuickAnswerSettingsTests: XCTestCase {
    func testOldSettingsKeepExistingPreferencesAndGainShortcutDefault() throws {
        var original = AppSettings()
        original.appearance = .dark
        original.screenshot.saveLocally = true
        let data = try JSONEncoder().encode(original)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var capture = try XCTUnwrap(json["screenshot"] as? [String: Any])
        capture.removeValue(forKey: "answerShortcut")
        capture.removeValue(forKey: "answerShortcutEnabled")
        json["screenshot"] = capture
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(restored.appearance, .dark)
        XCTAssertTrue(restored.screenshot.saveLocally)
        XCTAssertTrue(restored.screenshot.isAnswerShortcutEnabled)
        XCTAssertEqual(restored.screenshot.effectiveAnswerShortcut.displayString, "⌃⌥⌘5")
        XCTAssertNotEqual(restored.screenshot.shortcut, restored.screenshot.effectiveAnswerShortcut)
    }

    func testCustomizedShortcutAndDisabledStateSurviveRelaunch() throws {
        var settings = AppSettings()
        let custom = KeyboardShortcut(keyCode: 0, modifiers: KeyboardShortcut.controlModifier | KeyboardShortcut.optionModifier)
        settings.screenshot.answerShortcut = custom
        settings.screenshot.answerShortcutEnabled = false
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored.screenshot.effectiveAnswerShortcut, custom)
        XCTAssertFalse(restored.screenshot.isAnswerShortcutEnabled)
    }
}
