import XCTest
@testable import NotchAI

final class AnswerLetterParserTests: XCTestCase {
    func testRecognizesBareAndDecoratedLetters() {
        for (input, expected) in [("B", "B"), ("b", "B"), ("(C)", "C"), ("**D**", "D"), ("A.", "A"),
                                  ("Answer: B", "B"), ("  c) \n", "C"), ("Final answer - D", "D")] {
            XCTAssertEqual(AnswerLetterParser.letter(in: input), expected, input)
        }
    }

    func testRejectsExplanationsAndOutOfRangeLetters() {
        XCTAssertNil(AnswerLetterParser.letter(in: ""))
        XCTAssertNil(AnswerLetterParser.letter(in: "B because the function is pure"))
        XCTAssertNil(AnswerLetterParser.letter(in: "The photosynthesis process converts light."))
        XCTAssertNil(AnswerLetterParser.letter(in: "Z"))
        XCTAssertNil(AnswerLetterParser.letter(in: "A\nB"))
    }
}
