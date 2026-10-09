import XCTest
@testable import MochiCore

final class VoiceIdentityTests: XCTestCase {
    func testGreetingExcludesLastThreeAndHasStableName() {
        var recent: [String] = []
        for _ in 0..<100 {
            let text = VoiceIdentity.greeting(excluding:recent)
            XCTAssertTrue(VoiceIdentity.greetings.contains(text))
            XCTAssertFalse(recent.suffix(3).contains(text))
            XCTAssertTrue(text.contains("Mochi"))
            recent.append(text)
        }
    }
    func testIntroductionPersistsAndLegacyVoiceChatsAreAlreadyIntroduced() throws {
        var chat = Conversation(); chat.voiceIntroduced = true
        XCTAssertTrue(try JSONDecoder().decode(Conversation.self,from:JSONEncoder().encode(chat)).voiceIntroduced)
        for hasAudio in [false,true] {
            chat.messages = [Message(role:"user",text:"hello",audio:hasAudio ? "voice.wav" : nil)]
            var json = try JSONSerialization.jsonObject(with:JSONEncoder().encode(chat)) as! [String:Any]
            json.removeValue(forKey:"voiceIntroduced")
            let restored = try JSONDecoder().decode(Conversation.self,from:JSONSerialization.data(withJSONObject:json))
            XCTAssertEqual(restored.voiceIntroduced,hasAudio)
        }
    }
}
