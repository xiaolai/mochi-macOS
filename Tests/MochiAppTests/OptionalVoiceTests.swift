import XCTest
import MochiCore
@testable import MochiApp

final class OptionalVoiceTests: XCTestCase {
    @MainActor func testOptInPersistsAndRetainsLegacyCloneAndProfiles() throws {
        let suite = "mochi-optional-\(UUID())", prefs = UserDefaults(suiteName:suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { prefs.removePersistentDomain(forName:suite); try? FileManager.default.removeItem(at:root) }
        let bytes = try JSONSerialization.data(withJSONObject:[["name":"Xiaolai","providerID":"savedclone","requiresVerification":false]])
        prefs.set(bytes,forKey:"voiceProfiles"); prefs.set("savedclone",forKey:"clone"); prefs.set("personal",forKey:"practiceVoiceMode")
        let app = AppModel(libraryRoot:root,preferences:prefs)
        XCTAssertEqual(app.practiceProvider,.codex); XCTAssertEqual(app.auth,"codex")
        XCTAssertEqual(app.elevenLabsOptions.voiceID,"savedclone"); XCTAssertEqual(app.elevenLabsOptions.voiceName,"Xiaolai")
        app.practiceProvider = .elevenLabs; app.elevenLabsOptions.speed = 0.8
        let loaded = AppModel(libraryRoot:root,preferences:prefs)
        XCTAssertEqual(loaded.practiceProvider,.elevenLabs); XCTAssertEqual(loaded.elevenLabsOptions.speed,0.8)
        XCTAssertEqual(prefs.data(forKey:"voiceProfiles"),bytes); XCTAssertEqual(prefs.string(forKey:"clone"),"savedclone")
    }
    @MainActor func testRenderUsesChosenVoiceAndCachedAudioWithoutReplacingOnFailure() async throws {
        let suite = "mochi-render-\(UUID())", prefs = UserDefaults(suiteName:suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { prefs.removePersistentDomain(forName:suite); try? FileManager.default.removeItem(at:root) }
        let app = AppModel(libraryRoot:root,preferences:prefs)
        app.startHelp(); app.editEnglish("Let me think."); app.practiceProvider = .elevenLabs
        app.elevenLabsOptions.voiceID = "custom123"; app.elevenLabsOptions.voiceName = "Xiaolai"
        var calls = 0
        app.elevenLabsSpeech = { options in ElevenLabsSpeech(options:options,credential:{ "fixture" },transport:{ _ in calls += 1; return try Data(contentsOf:URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/reference.mp3")) }) }
        app.render()
        try await waitUntil { !app.busy }
        XCTAssertNil(app.error); XCTAssertEqual(calls,1)
        let saved = try XCTUnwrap(app.expression?.reference)
        XCTAssertEqual(app.expression?.referenceKind,"Xiaolai · ElevenLabs")
        app.render(); try await waitUntil { !app.busy }; XCTAssertEqual(calls,1)
        app.elevenLabsSpeech = { options in ElevenLabsSpeech(options:options,credential:{ "fixture" },transport:{ _ in Data("bad".utf8) }) }
        app.render(force:true); try await waitUntil { !app.busy }
        XCTAssertNotNil(app.error); XCTAssertEqual(app.expression?.reference,saved)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(saved)),try Data(contentsOf:URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/reference.mp3")))
        app.practiceProvider = .codex
        XCTAssertEqual(app.expression?.referenceKind,"Xiaolai · ElevenLabs")
    }
    @MainActor func testInvalidStoredOptionsAreRepairedAndStoppingCannotReplaceReference() async throws {
        let suite = "mochi-cancel-\(UUID())", prefs = UserDefaults(suiteName:suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { prefs.removePersistentDomain(forName:suite); try? FileManager.default.removeItem(at:root) }
        var options = ElevenLabsOptions(); options.voiceID = "custom123"; options.speed = 9; options.model = "unknown"
        prefs.set(try JSONEncoder().encode(options),forKey:"elevenLabsOptions")
        let app = AppModel(libraryRoot:root,preferences:prefs)
        XCTAssertEqual(app.elevenLabsOptions.speed,1); XCTAssertEqual(app.elevenLabsOptions.model,"eleven_multilingual_v2")
        app.startHelp(); app.editEnglish("Hello."); app.practiceProvider = .elevenLabs
        app.ensureExpression(); app.expression?.reference = "saved.wav"; app.expression?.referenceKind = "Original"
        let started = expectation(description:"request started")
        app.elevenLabsSpeech = { options in ElevenLabsSpeech(options:options,credential:{ "fixture" },transport:{ _ in
            started.fulfill(); try await Task.sleep(nanoseconds:5_000_000_000); return Data()
        }) }
        app.render(force:true); await fulfillment(of:[started],timeout:2); app.stop()
        try await Task.sleep(nanoseconds:10_000_000)
        XCTAssertFalse(app.busy); XCTAssertEqual(app.expression?.reference,"saved.wav"); XCTAssertEqual(app.expression?.referenceKind,"Original")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:root.path).contains { $0.hasPrefix("elevenlabs-") })
    }
    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds:1_000_000) }
        XCTAssertTrue(condition())
    }
}
