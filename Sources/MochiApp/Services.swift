import Foundation
import MochiCore
import MochiKernel
import MochiProviders

/// True inside an XCTest process. Live services must never run there: a test that forgets a fake
/// would otherwise reach the network or the microphone silently.
enum TestEnvironment {
    static let active = NSClassFromString("XCTestCase") != nil
    static func assertNotUnderTest(_ what: String) {
        precondition(
            !active,
            "\(what) must not be used in tests. Pass fakes to AppModel(speech:media:recognition:listeningServices:).")
    }
}

/// Everything AppModel sends to OpenAI. Each call receives the configured voice service.
struct SpeechServices {
    /// One conversation turn: text or speech in, a streamed reply and transcript out.
    var conversationReply: (RealtimeService, ConversationRequest, ReplyCallbacks) async throws -> Void
    /// A text-only reply, used for Help Me Say This and the connection check.
    var textReply: (RealtimeService, ConversationRequest) async throws -> String
    /// Spoken audio for exact text: (text, the language it is written in, service, folder, regenerate).
    var referenceAudio: (String, ConversationLanguage, RealtimeService, URL, Bool) async throws -> URL
    /// Transcribes a saved recording: (file, session model, transcription model).
    var transcribe: (URL, String, String) async throws -> TranscriptResult
    /// Converts a practice example's spoken audio into the learner's voice: (source, timbre, folder). Called only when
    /// the learner has turned practice timbre on.
    var convertTimbre: (URL, PracticeTimbre, URL) async throws -> URL = { _, _, _ in
        throw AppFailure(verbatim: "Practice timbre is not available here.")
    }
    /// Whether Codex is signed in and which models it lists; asks Codex on this Mac and sends nothing of the user's.
    /// Throws only when the check was cancelled.
    var codexStatus: () async throws -> CodexStatus = { CodexStatus() }
    /// Help Me Say This through Codex's text endpoint, which enforces the reply shape; nil where it is not wired.
    var codexHelpReply: ((ConversationRequest, CodexModel, String?) async throws -> String)?

    static var live: SpeechServices {
        TestEnvironment.assertNotUnderTest("SpeechServices.live")
        return SpeechServices(
            conversationReply: { service, request, callbacks in
                _ = try await service.reply(
                    request, onResponse: callbacks.response, onTranscription: callbacks.transcription,
                    onTool: callbacks.tool)
            },
            textReply: { service, request in try await service.reply(request).text },
            referenceAudio: { text, language, service, root, force in
                try await service.referenceAudio(text: text, language: language.readingTag, root: root, force: force)
            },
            transcribe: { url, model, transcriptionModel in
                try await RealtimeService(model: model).transcribe(
                    AudioFile.pcm(url), transcriptionModel: transcriptionModel)
            },
            convertTimbre: { source, timbre, root in
                try await PracticeTimbreConverter().convert(source: source, timbre: timbre, root: root)
            },
            codexStatus: { try await CodexCatalog.status() },
            codexHelpReply: { request, model, effort in
                try await CodexTextService(model: model, effort: effort).help(request)
            })
    }
}

/// On-device recognition of practice attempts, checked against the sentence being practised.
struct RecognitionServices {
    var availability: (ConversationLanguage) async -> WordRecognition.Availability
    /// Downloads Apple's speech model; called only after the learner agreed.
    var download: (ConversationLanguage) async throws -> Void
    var recognize: (URL, ConversationLanguage) async throws -> [RecognizedWord]

    static var live: RecognitionServices {
        TestEnvironment.assertNotUnderTest("RecognitionServices.live")
        return RecognitionServices(
            availability: { await WordRecognition.availability(for: $0) },
            download: { try await WordRecognition.download(for: $0) },
            recognize: { try await WordRecognition.recognize($0, language: $1) })
    }
}

/// Microphone access. Playback goes through `AudioController.makePlayer`.
struct MediaServices {
    var permission: @MainActor () async -> Bool
    var record: @MainActor (URL) throws -> Void
    var stopRecording: @MainActor () -> URL?
    var meter: @MainActor () -> Float
    /// False when the microphone stopped delivering audio before the user finished.
    var recordingActive: @MainActor () -> Bool = { true }
    /// True when the last take ended because the microphone or recorder failed; still valid after `stopRecording`.
    var recordingInterrupted: @MainActor () -> Bool = { false }
    /// True once the recorder confirmed it stopped successfully at its own time limit; reported asynchronously.
    var recordingFinished: @MainActor () -> Bool = { false }

    @MainActor static func live(_ audio: AudioController) -> MediaServices {
        TestEnvironment.assertNotUnderTest("MediaServices.live")
        return MediaServices(
            permission: { await audio.permission() },
            record: { try audio.record(to: $0) },
            stopRecording: { audio.stopRecording() },
            meter: { audio.meter },
            recordingActive: { audio.isRecording },
            recordingInterrupted: { audio.recordingInterrupted },
            recordingFinished: { audio.recordingFinished })
    }
}

/// One hands-free turn's connection: audio goes in, the API's judgement of the turn comes out.
protocol ListeningLine: AnyObject, Sendable {
    var signals: AsyncThrowingStream<ListeningSignal, Error> { get }
    func append(_ pcm: Data)
    func close()
    /// Audio the connection has actually sent, which may trail what was appended.
    var sentBytes: Int { get }
}
extension ListeningSession: ListeningLine {}

/// Hands-free listening: the streaming microphone and the session that judges each turn.
struct ListeningServices {
    /// Starts delivering 24 kHz mono 16-bit PCM on the main actor; the second closure is called if capture stops
    /// by itself.
    var startCapture: @MainActor (@escaping @MainActor (Data) -> Void, @escaping @MainActor () -> Void) throws -> Void
    var stopCapture: @MainActor () -> Void
    /// True while the microphone is in use for listening.
    var capturing: @MainActor () -> Bool
    /// Opens a session: (turn detection, session model).
    var openSession: (TurnDetection, String) async throws -> any ListeningLine
    /// A player for Mochi's speech through the listening microphone's echo canceller, so the learner can interrupt
    /// it; nil plays it the ordinary way. The closure reports the end: reached (`true`) or cut off (`false`).
    var makePlayer:
        @MainActor (URL, @escaping @MainActor (any PlaybackPlayer, Bool) -> Void) throws -> (any PlaybackPlayer)? =
            { _, _ in nil }

    @MainActor static func live(_ capture: StreamingCapture) -> ListeningServices {
        TestEnvironment.assertNotUnderTest("ListeningServices.live")
        return ListeningServices(
            startCapture: { try capture.start(deliver: $0, interrupted: $1) },
            stopCapture: { capture.stop() },
            capturing: { capture.isRunning },
            openSession: { detection, model in try await ListeningSession.open(model: model, detection: detection) },
            makePlayer: { url, finished in try capture.player(url, finished: finished) })
    }
}

struct ReplyCallbacks {
    let response: @MainActor (RealtimeAccumulator) throws -> Void
    let transcription: @MainActor (RealtimeAccumulator) -> Void
    let tool: @MainActor (String, [String: Any], String) throws -> [String: Any]
}
