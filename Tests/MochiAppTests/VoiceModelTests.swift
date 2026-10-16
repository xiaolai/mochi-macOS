import Darwin
import MochiTestSupport
import XCTest

@testable import MochiApp

final class VoiceModelTests: XCTestCase {
    @MainActor func testSelectingVoiceDoesNotRelabelSavedReference() {
        let app = makeApp(demo: true)
        app.startHelp()
        app.editEnglish("A sentence")
        app.ensureExpression()
        app.help.expression?.referenceKind = "Marin · Saved voice"
        app.settings.builtInPracticeVoice = "cedar"
        XCTAssertEqual(app.help.expression?.referenceKind, "Marin · Saved voice")
    }
    @MainActor func testVoiceOptionsPersistAndRejectInvalidPreferences() throws {
        let suite = "mochi-options-test-\(UUID())"
        let root = TestScratch.folder()
        let prefs = TestScratch.preferences(named: suite)
        defer {
            prefs.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let app = makeApp(root: root, preferences: prefs)
        app.settings.conversationVoiceOptions.speed = 1.2
        app.settings.practiceVoiceOptions.speed = 0.8
        let loaded = makeApp(root: root, preferences: prefs)
        XCTAssertEqual(loaded.settings.conversationVoiceOptions.speed, 1.2)
        XCTAssertEqual(loaded.settings.practiceVoiceOptions.speed, 0.8)
        prefs.set(Data("{\"speed\":9}".utf8), forKey: "practiceVoiceOptions")
        XCTAssertEqual(makeApp(root: root, preferences: prefs).settings.practiceVoiceOptions.speed, 1)
    }
}

extension VoiceModelTests {
    @MainActor func testStopPreviewControlsOnlyThePreviewsOwnTurn() async throws {
        let app = makeApp(root: makeTemporaryFolder())
        let player = TestPlayer()
        app.audio.makePlayer = { _ in player }
        let fixture = fixtureURL("reference.mp3")
        app.speech.referenceAudio = { _, _, _, root, _ in
            let url = root.appendingPathComponent("preview-test.mp3")
            if !FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.copyItem(at: fixture, to: url)
            }
            return url
        }
        try FileManager.default.copyItem(at: fixture, to: app.store.root.appendingPathComponent("message.mp3"))
        XCTAssertFalse(app.previewActive)

        app.previewBuiltIn("cedar")
        XCTAssertTrue(app.previewActive, "Generating the preview belongs to the preview")
        await waitUntil { app.playbackFile == "preview-test.mp3" }
        XCTAssertTrue(app.previewActive)
        app.stopPreview()
        XCTAssertFalse(app.previewActive)
        XCTAssertEqual(app.turn.activity, .idle)
        XCTAssertNil(app.playbackFile)

        app.previewBuiltIn("cedar")
        await waitUntil { app.playbackFile == "preview-test.mp3" }
        // Message playback replaces the preview, so Stop Preview no longer reaches it.
        app.play("message.mp3")
        XCTAssertEqual(app.playbackFile, "message.mp3")
        XCTAssertFalse(app.previewActive)
        app.stopPreview()
        XCTAssertEqual(app.turn.activity, .playing)
        XCTAssertEqual(app.playbackFile, "message.mp3")
    }
}
