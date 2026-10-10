import XCTest
@testable import MochiCore
final class CoreTests: XCTestCase {
    func testPauseInvalidatesGenerationAndKeepsMicLocal() {
        var turn = TurnMachine()
        let token = turn.begin(.generating)
        turn.pause()
        XCTAssertFalse(turn.finish(token))
        XCTAssertEqual(turn.mode, .practice)
        XCTAssertTrue(turn.startRecording())
        XCTAssertEqual(turn.owner, .practice)
        XCTAssertFalse(turn.startRecording())
        turn.resume()
        XCTAssertEqual(turn.owner, .none)
        XCTAssertEqual(turn.mode, .conversation)
    }
    func testPlaybackMustFinishBeforeRecording() {
        var turn = TurnMachine()
        let token = turn.begin(.playing)
        XCTAssertFalse(turn.startRecording())
        XCTAssertTrue(turn.finish(token))
        XCTAssertTrue(turn.startRecording())
        XCTAssertEqual(turn.owner, .conversation)
    }
    func testReferenceCacheSeparatesVoiceAndSpeed() {
        let a = ReferenceSpeech.cacheName(text:"Hello",model:"gpt-realtime",voice:"marin")
        let b = ReferenceSpeech.cacheName(text:"Hello",model:"gpt-realtime",voice:"cedar")
        XCTAssertNotEqual(a,b)
        var options = OpenAIVoiceOptions(); options.speed = 0.8
        XCTAssertNotEqual(a,ReferenceSpeech.cacheName(text:"Hello",model:"gpt-realtime",voice:"marin",options:options))
    }
    func testPersistenceRoundTripAndCorruptionDoesNotOverwrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root)
        var library = Library()
        library.conversations = [Conversation(title: "Test")]
        try store.save(library)
        XCTAssertEqual(try store.load().conversations.first?.title, "Test")
        try Data("broken".utf8).write(to: store.file)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try String(contentsOf: store.file), "broken")
    }
    func testLatePermissionCannotFinishNewOperation() {
        var turn = TurnMachine()
        let permission = turn.begin(.requestingPermission)
        turn.pause()
        let generation = turn.begin(.generating)
        XCTAssertFalse(turn.finish(permission))
        XCTAssertEqual(turn.activity, .generating)
        XCTAssertTrue(turn.finish(generation))
        XCTAssertEqual(turn.owner, .none)
    }
    func testFutureLibraryVersionIsPreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = LibraryStore(root:root)
        var library = Library(); library.version = 4
        try store.prepare()
        try JSONEncoder().encode(library).write(to:store.file)
        let before = try Data(contentsOf:store.file)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf:store.file),before)
    }

}
