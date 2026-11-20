import XCTest
@testable import NotchAI

final class MarkdownListTests: XCTestCase {
    func testBulletsNumbersQuotesAndNestedIndentation() {
        let blocks = MarkdownParser.blocks(from: "Intro\n\n- **One**\n  * Nested\n2. Second\n> Quoted")
        XCTAssertEqual(blocks.map(\.kind), [
            .paragraph("Intro"),
            .listItem("**One**", marker: "•", depth: 0),
            .listItem("Nested", marker: "•", depth: 1),
            .listItem("Second", marker: "2.", depth: 0),
            .quote("Quoted")
        ])
    }

    func testCodeKeepsLiteralListMarkersAndDecimalTextIsNotAList() {
        let blocks = MarkdownParser.blocks(from: "```text\n- keep this\n1. keep this too\n```\n3.14 is pi")
        XCTAssertEqual(blocks.map(\.kind), [
            .code("- keep this\n1. keep this too", language: "text"),
            .paragraph("3.14 is pi")
        ])
    }
}
