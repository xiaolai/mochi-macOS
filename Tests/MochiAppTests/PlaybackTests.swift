import XCTest
import MochiCore
@testable import MochiApp

private final class FakePlayer: PlaybackPlayer {
    let duration: TimeInterval = 10
    var currentTime: TimeInterval = 0
    var enableRate = false
    var rate: Float = 1
    var plays = 0
    var pauses = 0
    var stops = 0
    var succeeds = true
    func play() -> Bool { plays += 1; return succeeds }
    func pause() { pauses += 1 }
    func stop() { stops += 1 }
}

final class PlaybackTests: XCTestCase {
    @MainActor func testPauseResumeSeekClampAndStop() throws {
        let audio = AudioController(), player = FakePlayer()
        audio.makePlayer = { _ in player }
        try audio.play(url:URL(fileURLWithPath:"/unused.wav"),completed:{ XCTFail("Stop must not complete playback") })
        XCTAssertEqual(audio.duration,10)
        audio.seek(to:4.5); XCTAssertEqual(player.currentTime,4.5)
        audio.togglePause(); XCTAssertTrue(audio.paused); XCTAssertEqual(player.pauses,1)
        audio.seek(to:7); XCTAssertTrue(audio.paused); XCTAssertEqual(audio.position,7)
        audio.togglePause(); XCTAssertFalse(audio.paused); XCTAssertEqual(player.plays,2)
        audio.seek(to:100); XCTAssertEqual(audio.position,10)
        audio.seek(to:-10); XCTAssertEqual(audio.position,0)
        audio.seek(to:.nan); XCTAssertEqual(audio.position,0)
        audio.stop(); XCTAssertEqual(player.stops,1); XCTAssertEqual(audio.duration,0)
        XCTAssertEqual(audio.position,0); XCTAssertFalse(audio.paused)
    }
    @MainActor func testResumeFailureClearsPlaybackAndReportsFailure() throws {
        let audio = AudioController(), player = FakePlayer()
        audio.makePlayer = { _ in player }
        var failed = false
        try audio.play(url:URL(fileURLWithPath:"/unused.wav"),failed:{ failed = true },completed:{ XCTFail() })
        audio.togglePause(); player.succeeds = false; audio.togglePause()
        XCTAssertTrue(failed); XCTAssertFalse(audio.paused); XCTAssertEqual(audio.duration,0)
    }
    @MainActor func testMessagePlaybackSwitchSeekAndConversationStop() {
        let app = AppModel(demo:true)
        app.resume()
        var players: [FakePlayer] = []
        app.audio.makePlayer = { _ in let player = FakePlayer(); players.append(player); return player }
        app.togglePlayback("one.wav",mochi:true)
        XCTAssertEqual(app.playbackFile,"one.wav"); XCTAssertTrue(app.speaking)
        app.togglePlayback("one.wav"); XCTAssertTrue(app.audio.paused)
        XCTAssertEqual(players.count,1)
        app.seekPlayback("one.wav",to:6); XCTAssertTrue(app.audio.paused)
        XCTAssertEqual(app.audio.position,6)
        app.togglePlayback("two.wav")
        XCTAssertEqual(players[0].stops,1); XCTAssertEqual(app.playbackFile,"two.wav")
        XCTAssertFalse(app.speaking); XCTAssertFalse(app.audio.paused)
        app.stop(); XCTAssertNil(app.playbackFile); XCTAssertEqual(app.turn.activity,.idle)
        XCTAssertEqual(players[1].stops,1)
    }
    @MainActor func testSeekStartsInactiveRecordingButCannotInterruptGeneration() {
        let app = AppModel(demo:true)
        app.resume()
        let player = FakePlayer(); app.audio.makePlayer = { _ in player }
        _ = app.turn.begin(.generating)
        app.seekPlayback("one.wav",to:4); XCTAssertNil(app.playbackFile); XCTAssertEqual(player.plays,0)
        app.stop()
        app.seekPlayback("one.wav",to:4)
        XCTAssertEqual(app.playbackFile,"one.wav"); XCTAssertEqual(app.audio.position,4)
        app.stop()
    }
}
