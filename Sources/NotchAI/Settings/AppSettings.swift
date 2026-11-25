import Foundation

enum AppearanceMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

enum HoverBehavior: String, Codable, CaseIterable, Identifiable, Sendable {
    case expand, none
    var id: String { rawValue }
    var title: String {
        switch self {
        case .expand: return "Expand on hover"
        case .none: return "Click to expand"
        }
    }
}

enum ScreenshotFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case png, jpeg
    var id: String { rawValue }
    var title: String { self == .png ? "PNG (lossless)" : "JPEG (smaller)" }
    var mimeType: String { self == .png ? "image/png" : "image/jpeg" }
}

enum BrowserSearchEngine: String, Codable, CaseIterable, Identifiable, Sendable {
    case google, duckDuckGo, bing
    var id: String { rawValue }
    var title: String {
        switch self {
        case .google: return "Google"
        case .duckDuckGo: return "DuckDuckGo"
        case .bing: return "Bing"
        }
    }
    var queryTemplate: String {
        switch self {
        case .google: return "https://www.google.com/search?q="
        case .duckDuckGo: return "https://duckduckgo.com/?q="
        case .bing: return "https://www.bing.com/search?q="
        }
    }
}

enum IslandScreenChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case main, active
    var id: String { rawValue }
    var title: String { self == .main ? "Main display" : "Display with pointer" }
}

/// Carbon-style modifier bits, stored in settings without importing Carbon.
struct KeyboardShortcut: Codable, Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let commandModifier: UInt32 = 1 << 8
    static let shiftModifier: UInt32 = 1 << 9
    static let optionModifier: UInt32 = 1 << 11
    static let controlModifier: UInt32 = 1 << 12

    /// ⌃⌥⌘4 (key code 21 is the 4 key).
    static let defaultCapture = KeyboardShortcut(
        keyCode: 21,
        modifiers: controlModifier | optionModifier | commandModifier
    )

    /// ⌃⌥⌘6 (key code 22 is the 6 key): start or stop Watch Region.
    static let defaultWatch = KeyboardShortcut(
        keyCode: 22,
        modifiers: controlModifier | optionModifier | commandModifier
    )

    static let defaultAnswer = KeyboardShortcut(
        keyCode: 23,
        modifiers: controlModifier | optionModifier | commandModifier
    )

    var displayString: String {
        var parts = ""
        if modifiers & KeyboardShortcut.controlModifier != 0 { parts += "⌃" }
        if modifiers & KeyboardShortcut.optionModifier != 0 { parts += "⌥" }
        if modifiers & KeyboardShortcut.shiftModifier != 0 { parts += "⇧" }
        if modifiers & KeyboardShortcut.commandModifier != 0 { parts += "⌘" }
        return parts + KeyboardShortcut.keyName(for: keyCode)
    }

    static func keyName(for keyCode: UInt32) -> String {
        switch keyCode {
        case 0: return "A"
        case 1: return "S"
        case 2: return "D"
        case 3: return "F"
        case 4: return "H"
        case 5: return "G"
        case 6: return "Z"
        case 7: return "X"
        case 8: return "C"
        case 9: return "V"
        case 11: return "B"
        case 12: return "Q"
        case 13: return "W"
        case 14: return "E"
        case 15: return "R"
        case 16: return "Y"
        case 17: return "T"
        case 19: return "2"
        case 20: return "1"
        case 21: return "4"
        case 22: return "6"
        case 23: return "5"
        case 25: return "9"
        case 26: return "7"
        case 28: return "8"
        case 29: return "0"
        case 31: return "O"
        case 32: return "U"
        case 34: return "I"
        case 35: return "P"
        case 37: return "L"
        case 38: return "J"
        case 40: return "K"
        case 45: return "N"
        case 46: return "M"
        case 49: return "Space"
        case 36: return "Return"
        case 48: return "Tab"
        case 51: return "Delete"
        case 53: return "Escape"
        default: return "Key \(keyCode)"
        }
    }
}

/// What kind of question Capture & Answer and Watch Region expect.
enum AnswerMode: String, Codable, CaseIterable, Sendable {
    /// The model decides: a bare letter for multiple choice, a full answer otherwise.
    case auto
    /// Multiple choice: reply with only the option letter.
    case mcq
    /// Free response: always a full written answer.
    case frq

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .mcq: return "MCQ"
        case .frq: return "FRQ"
        }
    }

    var next: AnswerMode {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    var prompt: String {
        switch self {
        case .auto: return AnswerLetterParser.quickAnswerPrompt
        case .mcq: return "Answer this multiple-choice question. Reply with ONLY the letter of the correct option (e.g. B) and nothing else."
        case .frq: return "Answer this free-response question in full, in clear well-organized paragraphs."
        }
    }
}

struct ScreenshotSettings: Codable, Equatable, Sendable {
    var displayID: UInt32?
    var format: ScreenshotFormat = .png
    var attachToChat = true
    var excludeAllAppWindows = false
    var saveLocally = false
    var shortcut: KeyboardShortcut = .defaultCapture
    // Optional stored fields preserve decoding of settings written by older versions.
    var answerShortcut: KeyboardShortcut?
    var answerShortcutEnabled: Bool?
    var answerMode: AnswerMode?
    /// Fast double-tap "hh" (answer) and "jj" (Watch Region). Off by default: it needs Input Monitoring.
    var doubleTapKeysEnabled: Bool?
    var isDoubleTapEnabled: Bool { doubleTapKeysEnabled ?? false }
    var effectiveAnswerMode: AnswerMode { answerMode ?? .auto }
    var effectiveAnswerShortcut: KeyboardShortcut { answerShortcut ?? .defaultAnswer }
    var isAnswerShortcutEnabled: Bool { answerShortcutEnabled ?? true }
}

struct BrowserSettings: Codable, Equatable, Sendable {
    var searchEngine: BrowserSearchEngine = .google
    var homepage: String = "https://www.apple.com"
    var detachedWindowUsesSeparateSession = true
}

struct AppSettings: Codable, Equatable, Sendable {
    var launchAtLogin = false
    var showDockIcon = false
    var hoverBehavior: HoverBehavior = .expand
    var animationsEnabled = true
    var appearance: AppearanceMode = .system
    var islandScreen: IslandScreenChoice = .main
    var defaultProvider: AIProviderID = .deepSeek
    var defaultModelID: String = "deepseek-flash"
    var screenshot = ScreenshotSettings()
    var browser = BrowserSettings()
}
