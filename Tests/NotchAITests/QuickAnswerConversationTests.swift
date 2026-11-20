import XCTest
@testable import NotchAI

@MainActor
final class QuickAnswerConversationTests: XCTestCase {
    func testRepeatedQuickAnswersReuseOneConversation() {
        let suite = "NotchAI.quick.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let chat = ChatManager(
            store: InMemoryChatStore(),
            providers: AIProviderRegistry(deepSeek: FakeProvider(id: .deepSeek), gemini: FakeProvider(id: .gemini)),
            selectionDefaults: defaults
        )
        let before = chat.conversations.count
        chat.selectQuickAnswerConversation()
        let first = chat.selectedConversationID
        chat.newConversation()
        chat.selectQuickAnswerConversation()
        XCTAssertEqual(chat.selectedConversationID, first)
        XCTAssertEqual(chat.conversations.filter { $0.isQuickAnswer == true }.count, 1)
        XCTAssertEqual(chat.conversations.count, before + 2) // quick thread + the manual new chat
        XCTAssertEqual(chat.currentConversation.title, ChatManager.quickAnswerTitle)
    }
}
