import XCTest
import MochiCore
@testable import MochiApp

final class ConversationSearchTests: XCTestCase {
    @MainActor func testSearchIsCurrentConversationOnlyAndIndependentOfSidebarFilter() {
        let app = AppModel(demo:true); app.resume()
        let first = Message(role:"user",text:"The café opens soon")
        let second = Message(role:"assistant",text:"Let's go to the CAFE")
        var unknown = Message(role:"user",text:"",audio:"voice.wav"); unknown.transcriptionState = .failed
        let current = Conversation(title:"Unsearched title")
        let other = Conversation(title:"Other conversation")
        app.library.conversations = [current,other]
        app.select(current.id)
        app.append(first,to:current.id); app.append(second,to:current.id); app.append(unknown,to:current.id)
        app.append(Message(role:"user",text:"cafe"),to:other.id)
        app.search = "Other conversation"
        app.openConversationSearch(); app.conversationQuery = " CAFE "
        XCTAssertEqual(app.conversationMatchIDs,[first.id,second.id])
        XCTAssertEqual(app.search,"Other conversation")
        XCTAssertEqual(app.selectedID,current.id)
        app.conversationQuery = "Unsearched title"; XCTAssertTrue(app.conversationMatchIDs.isEmpty)
        app.conversationQuery = "Voice recording"; XCTAssertTrue(app.conversationMatchIDs.isEmpty)
        app.stop()
    }
    @MainActor func testMatchNavigationWrapsAndQueryChangesResetPosition() {
        let app = AppModel(demo:true); app.resume()
        let chat = Conversation(); app.library.conversations = [chat]; app.select(chat.id)
        let messages = [Message(role:"user",text:"one match"),Message(role:"assistant",text:"another match")]
        for message in messages { app.append(message,to:chat.id) }
        app.conversationQuery = "match"
        XCTAssertEqual(app.conversationMatchID,messages[0].id)
        app.moveConversationMatch(-1); XCTAssertEqual(app.conversationMatchID,messages[1].id)
        app.moveConversationMatch(1); XCTAssertEqual(app.conversationMatchID,messages[0].id)
        app.moveConversationMatch(1)
        app.conversationQuery = "one"; XCTAssertEqual(app.conversationMatchIndex,0)
        XCTAssertEqual(app.conversationMatchID,messages[0].id)
        app.conversationQuery = "missing"; app.moveConversationMatch(1)
        XCTAssertNil(app.conversationMatchID); XCTAssertEqual(app.conversationMatchIndex,0)
        app.stop()
    }
    @MainActor func testSearchClosesOnConversationChangeOrExpressionsAndCanReopen() {
        let app = AppModel(demo:true); app.resume()
        let first = Conversation(), second = Conversation()
        app.library.conversations = [first,second]; app.select(first.id)
        app.openConversationSearch(); app.conversationQuery = "hello"
        app.select(second.id)
        XCTAssertFalse(app.conversationSearchOpen); XCTAssertEqual(app.conversationQuery,"")
        app.openConversationSearch(); app.conversationQuery = "world"
        app.openExpressions()
        XCTAssertFalse(app.conversationSearchOpen); XCTAssertEqual(app.conversationQuery,"")
        app.openConversationSearch(); XCTAssertFalse(app.conversationSearchOpen)
        app.select(first.id); app.openConversationSearch(); XCTAssertTrue(app.conversationSearchOpen)
        app.closeConversationSearch(); XCTAssertFalse(app.conversationSearchOpen)
        app.stop()
    }
}

extension ConversationSearchTests {
    @MainActor func testLateTranscriptKeepsSelectedMessageAndRemovalUsesNearestMatch() {
        let app = AppModel(demo:true); app.resume()
        let chat = Conversation(); app.library.conversations = [chat]; app.select(chat.id)
        let pending = Message(role:"user",text:"",audio:"pending.wav")
        let first = Message(role:"user",text:"match one"), selected = Message(role:"assistant",text:"match two")
        for message in [pending,first,selected] { app.append(message,to:chat.id) }
        app.conversationQuery = "match"; app.moveConversationMatch(1)
        let ci = app.library.conversations.firstIndex { $0.id == chat.id }!
        app.library.conversations[ci].messages[0].text = "late match"
        XCTAssertEqual(app.conversationMatchID,selected.id)
        XCTAssertEqual(app.conversationMatchIndex,2)
        app.library.conversations[ci].messages.removeLast()
        XCTAssertEqual(app.conversationMatchID,first.id)
        XCTAssertEqual(app.conversationMatchSet,Set([pending.id,first.id]))
        app.stop()
    }
    @MainActor func testManagerFindWithoutSelectionOrConversationView() {
        let app = AppModel(demo:true); app.resume(); app.selectedID = nil; app.showExpressions = true
        XCTAssertFalse(app.canFindInConversation)
        app.managerOpen = true; XCTAssertTrue(app.canFindInConversation)
        let before = app.searchFocusRequest
        app.findInConversation(); XCTAssertEqual(app.searchFocusRequest,before+1)
        XCTAssertFalse(app.conversationSearchOpen)
        app.renameID = UUID(); XCTAssertFalse(app.canFindInConversation)
        app.stop()
    }
    @MainActor func testLargeConversationUsesCachedMatchesAcrossReadsAndUpdates() {
        let app = AppModel(demo:true)
        var chat = Conversation()
        chat.messages = (0..<1000).map { Message(role:"user",text:$0.isMultiple(of:2) ? "match" : "other") }
        app.library.conversations = [chat]; app.select(chat.id); app.conversationQuery = "match"
        XCTAssertEqual(app.conversationMatchIDs.count,500)
        for _ in 0..<1000 { XCTAssertEqual(app.conversationMatchSet.count,500); XCTAssertEqual(app.conversationMatchID,chat.messages[0].id) }
        app.library.conversations[0].messages[1].text = "match"
        XCTAssertEqual(app.conversationMatchIDs.count,501)
        app.stop()
    }
}
