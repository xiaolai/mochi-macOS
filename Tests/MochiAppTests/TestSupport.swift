import MochiCore
import MochiKernel
import MochiTestSupport
import XCTest

@testable import MochiApp

extension SpeechServices {
    /// Fails the test on any network call it did not fake.
    static var unexpected: SpeechServices {
        func refuse(_ what: String) -> AppFailure {
            XCTFail("Unexpected \(what): set app.speech in this test")
            return AppFailure("No speech service in this test.")
        }
        return SpeechServices(
            conversationReply: { _, _, _ in throw refuse("conversation reply") },
            textReply: { _, _ in throw refuse("text reply") },
            referenceAudio: { _, _, _, _, _ in throw refuse("reference audio") },
            transcribe: { _, _, _ in throw refuse("transcription") })
    }
}
extension RecognitionServices {
    /// As on a Mac older than macOS 26: no word check, and never a recognition or a download.
    static var absent: RecognitionServices {
        RecognitionServices(
            availability: { _ in .unavailable(.olderMacOS) },
            download: { _ in
                XCTFail("Unexpected speech model download: set app.recognition")
                throw AppFailure("No speech model in this test.")
            },
            recognize: { _, _ in
                XCTFail("Unexpected recognition: set app.recognition")
                throw AppFailure("No recognizer in this test.")
            })
    }
    /// A recognizer that is ready and always returns `words`.
    static func hearing(_ words: [RecognizedWord]) -> RecognitionServices {
        var services = RecognitionServices.absent
        services.availability = { _ in .ready }
        services.recognize = { _, _ in words }
        return services
    }
}
extension MediaServices {
    /// Stopping and metering are harmless. Asking for the microphone or recording fails the test.
    static var silent: MediaServices {
        MediaServices(
            permission: {
                XCTFail("Unexpected microphone permission request: set app.media.permission")
                return false
            },
            record: { _ in
                XCTFail("Unexpected recording: set app.media.record")
                throw AppFailure("No microphone in this test.")
            },
            stopRecording: { nil },
            meter: { -80 })
    }
}
extension ListeningServices {
    /// Capturing or opening a listening session fails the test; stopping is harmless.
    static var absent: ListeningServices {
        ListeningServices(
            startCapture: { _, _ in
                XCTFail("Unexpected listening capture: set app.listeningServices")
                throw AppFailure("No microphone in this test.")
            },
            stopCapture: {}, capturing: { false },
            openSession: { _, _ in
                XCTFail("Unexpected listening session: set app.listeningServices")
                throw AppFailure("No listening session in this test.")
            })
    }
}
/// A player that starts at once and finishes only when the test says so.
final class TestPlayer: PlaybackPlayer {
    var duration: TimeInterval = 5
    var currentTime: TimeInterval = 0
    var enableRate = false
    var rate: Float = 1
    var playing = false
    func play() -> Bool {
        playing = true
        return true
    }
    func pause() { playing = false }
    func stop() { playing = false }
}

extension XCTestCase {
    /// Preferences private to this test; their file is deleted when the test process exits.
    func makePreferences(_ prefix: String = "mochi-test") -> UserDefaults { TestScratch.preferences(prefix).defaults }
    /// The preferences suite with exactly this name, for tests that relaunch against the same suite.
    func makePreferences(named suite: String) -> UserDefaults { TestScratch.preferences(named: suite) }
    /// A temporary folder inside the test process's scratch folder, removed when the process exits.
    func makeTemporaryFolder(_ prefix: String = "mochi-test") -> URL { TestScratch.folder(prefix) }
    /// An AppModel with private preferences and fake services; playing audio fails the test unless it sets a player.
    /// Demo models get their own temporary folder.
    /// Pass `applicationSupport` without `root` to exercise the managed data folder and its migration.
    @MainActor func makeApp(
        demo: Bool = false, root: URL? = nil, preferences: UserDefaults? = nil,
        speech: SpeechServices = .unexpected, media: MediaServices = .silent,
        recognition: RecognitionServices = .absent, listeningServices: ListeningServices = .absent,
        applicationSupport: URL? = nil
    ) -> AppModel {
        precondition(root != nil || demo || applicationSupport != nil, "A test must never open the real data folder.")
        let app = AppModel(
            demo: demo, libraryRoot: root ?? (demo ? makeTemporaryFolder() : nil),
            preferences: preferences ?? makePreferences(),
            speech: speech, media: media, recognition: recognition, listeningServices: listeningServices,
            applicationSupport: applicationSupport)
        app.audio.makePlayer = { _ in
            XCTFail("Unexpected playback: set app.audio.makePlayer")
            throw AppFailure("No speaker in this test.")
        }
        app.chooseFile = { request in
            XCTFail("Unexpected file panel \(request): call the URL-taking method")
            return nil
        }
        return app
    }
    /// Polls on the main actor until `condition` holds or the timeout passes, then asserts it.
    /// The timeout is a ceiling, not a speed check: a passing wait returns as soon as the condition holds. Audio
    /// decoding and pitch analysis run several times slower under the thread sanitizer and parallel workers.
    @MainActor func waitUntil(
        timeout: TimeInterval = 30, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(condition(), "Condition not met within \(timeout) s", file: file, line: line)
    }
    func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
            "Fixtures"
        ).appendingPathComponent(name)
    }
}
