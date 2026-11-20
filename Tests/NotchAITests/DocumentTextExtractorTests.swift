import XCTest
@testable import NotchAI

final class DocumentTextExtractorTests: XCTestCase {
    private func temp(_ name: String, _ data: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testExtractsPlainTextAndTruncatesLongFiles() throws {
        let doc = try DocumentTextExtractor.extract(from: temp("notes.md", Data("# Hello\nworld".utf8)))
        XCTAssertEqual(doc.name, "notes.md")
        XCTAssertEqual(doc.text, "# Hello\nworld")
        XCTAssertFalse(doc.isTruncated)

        let long = String(repeating: "a", count: DocumentTextExtractor.maxCharacters + 500)
        let big = try DocumentTextExtractor.extract(from: temp("big.txt", Data(long.utf8)))
        XCTAssertEqual(big.text.count, DocumentTextExtractor.maxCharacters)
        XCTAssertTrue(big.isTruncated)
    }

    func testRejectsBinaryAndEmptyFiles() throws {
        XCTAssertThrowsError(try DocumentTextExtractor.extract(from: temp("x.bin", Data([0, 1, 2, 0, 255]))))
        XCTAssertThrowsError(try DocumentTextExtractor.extract(from: temp("empty.txt", Data("  \n".utf8))))
    }

    func testProviderTextPutsDocumentsBeforeQuestion() {
        let message = ChatMessage(
            role: .user, text: "Summarize", documents: [ChatDocument(name: "a.txt", text: "BODY")]
        )
        XCTAssertTrue(message.providerText.contains("<document name=\"a.txt\">"))
        XCTAssertTrue(message.providerText.contains("BODY"))
        XCTAssertTrue(message.providerText.hasSuffix("Summarize"))
        XCTAssertEqual(ChatMessage(role: .user, text: "hi").providerText, "hi")
    }
}
