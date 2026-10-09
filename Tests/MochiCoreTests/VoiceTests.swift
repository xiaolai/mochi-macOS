import XCTest
@testable import MochiCore
final class VoiceTests: XCTestCase {
    func testCatalogAndExactSentence() {
        XCTAssertEqual(RealtimeVoice.allCases.count,10)
        XCTAssertTrue(ReferenceSpeech.matches("I'm ready to start.","I’m ready to start!"))
        XCTAssertFalse(ReferenceSpeech.matches("I worked slowly.","My progress was slow."))
        XCTAssertFalse(ReferenceSpeech.matches("one thing","one thing. Let us begin."))
        XCTAssertFalse(ReferenceSpeech.matches("We'll start.","Well start."))
    }
    func testReferenceCacheSeparatesModelAndVoice() {
        let a = ReferenceSpeech.cacheName(text:"Hello",model:"gpt-realtime",voice:"marin")
        XCTAssertNotEqual(a,ReferenceSpeech.cacheName(text:"Hello",model:"gpt-realtime",voice:"cedar"))
        XCTAssertNotEqual(a,ReferenceSpeech.cacheName(text:"Hello",model:"other-model",voice:"marin"))
        XCTAssertFalse(ReferenceSpeech.matches("   ",""))
    }
}
