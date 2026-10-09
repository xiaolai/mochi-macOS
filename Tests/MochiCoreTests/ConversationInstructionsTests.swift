import XCTest
@testable import MochiCore
final class ConversationInstructionsTests: XCTestCase {
    func testLegacyDefaultsAndRoundtrip() throws {
        var chat = Conversation(); chat.instructions = "Interview me"; chat.preferences.speed = 0.8; chat.preferences.coaching = .direct
        let data = try JSONEncoder().encode(chat)
        let restored = try JSONDecoder().decode(Conversation.self,from:data)
        XCTAssertEqual(restored.instructions,"Interview me"); XCTAssertEqual(restored.preferences.speed,0.8)
        var legacy = try JSONSerialization.jsonObject(with:data) as! [String:Any]
        legacy.removeValue(forKey:"instructions"); legacy.removeValue(forKey:"preferences")
        let old = try JSONDecoder().decode(Conversation.self,from:JSONSerialization.data(withJSONObject:legacy))
        XCTAssertEqual(old.instructions,""); XCTAssertNil(old.preferences.speed)
    }
    func testPromptIsolationAndPrecedence() {
        let chat = ConversationRequest(history:[],text:"hello",instructions:"Give longer answers")
        XCTAssertTrue(chat.resolvedInstructions.contains("Give longer answers"))
        XCTAssertTrue(chat.resolvedInstructions.contains("override"))
        let help = ConversationRequest(history:[],text:"hello",help:true,instructions:"Interview me")
        let reference = ConversationRequest(history:[],text:"hello",reference:true,instructions:"Interview me")
        XCTAssertFalse(help.resolvedInstructions.contains("Interview me")); XCTAssertFalse(reference.resolvedInstructions.contains("Interview me"))
    }
    func testCatalogValidatesArgumentsAndRestrictsVoiceTools() throws {
        XCTAssertFalse(MochiTools.catalog(origin:.voice).contains { $0.name == "set_conversation_instructions" })
        XCTAssertTrue(MochiTools.catalog(origin:.external).contains { $0.name == "set_conversation_instructions" })
        XCTAssertThrowsError(try MochiTools.validate(name:"delete_message",arguments:[:],origin:.external))
        XCTAssertThrowsError(try MochiTools.validate(name:"get_messages",arguments:["conversation_id":"bad"],origin:.external))
        XCTAssertThrowsError(try MochiTools.validate(name:"search_expressions",arguments:["query":"", "limit":101],origin:.voice))
    }
    func testNumericBoundsBooleansAndInstructionLimits() throws {
        let id = UUID().uuidString
        XCTAssertThrowsError(try MochiTools.validate(name:"get_messages",arguments:["conversation_id":id,"limit":0],origin:.voice))
        XCTAssertThrowsError(try MochiTools.validate(name:"get_messages",arguments:["conversation_id":id,"limit":true],origin:.voice))
        XCTAssertThrowsError(try MochiTools.validate(name:"get_messages",arguments:["conversation_id":id,"limit":1.5],origin:.voice))
        _ = try MochiTools.validate(name:"seek_audio",arguments:["conversation_id":id,"message_id":id,"seconds":3600],origin:.voice)
        XCTAssertThrowsError(try MochiTools.validate(name:"seek_audio",arguments:["conversation_id":id,"message_id":id,"seconds":3601],origin:.voice))
        XCTAssertThrowsError(try MochiTools.validateInstructions(String(repeating:"x",count:8001)))
        XCTAssertThrowsError(try MochiTools.validate(name:"play_audio",arguments:["conversation_id":id,"message_id":id,"expression_id":id],origin:.voice))
    }

}
extension ConversationInstructionsTests {
    func testPauseResumeAreExternalOnly() throws {
        for name in ["pause_audio","resume_audio"] {
            XCTAssertFalse(MochiTools.catalog(origin:.voice).contains { $0.name == name })
            XCTAssertTrue(MochiTools.catalog(origin:.external).contains { $0.name == name })
            XCTAssertThrowsError(try MochiTools.validate(name:name,arguments:["conversation_id":UUID().uuidString],origin:.voice))
        }
    }
}
