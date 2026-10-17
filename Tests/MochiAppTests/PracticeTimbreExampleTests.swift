import MochiKernel
import MochiProviders
import XCTest

@testable import MochiApp

/// The example flow with practice timbre: the spoken take is converted only when the learner turned it on, and a bad
/// voice ID stops the example before the spoken request is made. Services are fakes; nothing is sent.
@MainActor final class PracticeTimbreExampleTests: XCTestCase {
    private func practisingApp() -> AppModel {
        let app = makeApp(root: makeTemporaryFolder())
        app.startHelp()
        app.editEnglish("Let me think.")
        return app
    }

    /// The spoken take the fake OpenAI service writes into the folder, as the real one does.
    private func spokenTake(in root: URL) throws -> URL {
        let url = root.appendingPathComponent("builtin-test.mp3")
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.copyItem(at: fixtureURL("reference.mp3"), to: url)
        }
        return url
    }

    func testWithTheSettingOffTheSpokenExampleIsKept() async throws {
        let app = practisingApp()
        var converted = 0
        app.speech.referenceAudio = { _, _, _, root, _ in try self.spokenTake(in: root) }
        app.speech.convertTimbre = { _, _, _ in
            converted += 1
            throw AppFailure(verbatim: "must not run")
        }

        app.render()
        await waitUntil { !app.busy }

        XCTAssertNil(app.error)
        XCTAssertEqual(converted, 0)
        XCTAssertEqual(app.help.expression?.reference, "builtin-test.mp3")
        XCTAssertEqual(app.help.expression?.referenceKind, "\(RealtimeService.defaultVoice.capitalized) · Codex voice")
    }

    func testWithTheSettingOnTheConvertedExampleIsSaved() async throws {
        let app = practisingApp()
        app.settings.practiceTimbreEnabled = true
        app.settings.practiceTimbreVoiceID = "VOICE123"
        var sources: [(URL, String)] = []
        app.speech.referenceAudio = { _, _, _, root, _ in try self.spokenTake(in: root) }
        app.speech.convertTimbre = { source, timbre, root in
            sources.append((source, timbre.voiceID))
            let url = root.appendingPathComponent("elevenlabs-\(String(repeating: "a", count: 64)).mp3")
            try FileManager.default.copyItem(at: self.fixtureURL("reference.mp3"), to: url)
            return url
        }

        app.render()
        await waitUntil { !app.busy }

        XCTAssertNil(app.error)
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources.first?.0.lastPathComponent, "builtin-test.mp3", "the spoken take is what gets converted")
        XCTAssertEqual(sources.first?.1, "VOICE123")
        XCTAssertEqual(app.help.expression?.reference, "elevenlabs-\(String(repeating: "a", count: 64)).mp3")
        XCTAssertEqual(app.help.expression?.referenceKind, "Your voice")
    }

    func testAnInvalidVoiceIDStopsBeforeTheSpokenRequest() async throws {
        let app = practisingApp()
        app.settings.practiceTimbreEnabled = true
        app.settings.practiceTimbreVoiceID = ""
        var spoken = 0
        app.speech.referenceAudio = { _, _, _, root, _ in
            spoken += 1
            return try self.spokenTake(in: root)
        }

        app.render()
        await waitUntil { !app.busy }

        XCTAssertEqual(spoken, 0, "a bad voice ID must cost no sentence")
        XCTAssertEqual(app.error, "Enter your ElevenLabs voice ID in Settings → Voices.")
        XCTAssertNil(app.help.expression?.reference)
    }
}
