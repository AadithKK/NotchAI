import Foundation

/// Recognizes a reply that is just a multiple-choice option letter, so Capture & Answer can show the
/// letter at the notch instead of opening the full chat.
enum AnswerLetterParser {
    /// Prompt used by Capture & Answer. The model decides per screenshot whether it is multiple choice.
    static let quickAnswerPrompt =
        "Answer this. If it is a multiple-choice question, reply with ONLY the letter of the correct option (e.g. B) and nothing else. Otherwise answer fully."

    /// Returns the uppercase option letter for replies like `B`, `(b)`, `**C**`, `D.` or `Answer: A`.
    /// Longer replies (explanations, paragraphs) return nil.
    static func letter(in reply: String) -> String? {
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 24 else { return nil }
        text = text.replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "_", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^(?:(?:final\s+)?answer\s*[\-:]?\s*)?\(?([A-Za-z])\)?[\.\):]?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        let letter = String(text[range]).uppercased()
        // Only A–J are plausible option labels; this also avoids treating a stray "I"/"a" oddity as a
        // choice when the model returned something else single-lettered.
        guard let scalar = letter.unicodeScalars.first, scalar.value >= 65, scalar.value <= 74 else { return nil }
        return letter
    }
}
