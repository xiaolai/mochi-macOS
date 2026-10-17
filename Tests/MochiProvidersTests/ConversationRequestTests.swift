import MochiKernel
import MochiTestSupport
import RealtimeConnection
import XCTest

@testable import MochiCore
@testable import MochiProviders

final class ConversationRequestTests: XCTestCase {
    func testPersonalityReachesTheConversationPromptOnly() {
        let request = ConversationRequest(
            history: [], text: "Hi", instructions: "Tell a story", characterName: "Pip", personality: "Playful.")
        XCTAssertTrue(request.resolvedInstructions.contains("Personality and manner"))
        XCTAssertTrue(request.resolvedInstructions.contains("Playful."))
        var help = request
        help.help = true
        XCTAssertFalse(help.resolvedInstructions.contains("Playful."))
        var reference = request
        reference.reference = true
        XCTAssertFalse(reference.resolvedInstructions.contains("Playful."))
    }
    func testPromptIsolationAndPrecedence() {
        let chat = ConversationRequest(history: [], text: "hello", instructions: "Give longer answers")
        XCTAssertTrue(chat.resolvedInstructions.contains("Give longer answers"))
        XCTAssertTrue(chat.resolvedInstructions.contains("override"))
        let help = ConversationRequest(history: [], text: "hello", help: true, instructions: "Interview me")
        let reference = ConversationRequest(history: [], text: "hello", reference: true, instructions: "Interview me")
        XCTAssertFalse(help.resolvedInstructions.contains("Interview me"))
        XCTAssertFalse(reference.resolvedInstructions.contains("Interview me"))
    }

    func testNamePromptAndReferenceIsolationAndGreetingPatterns() throws {
        var prefs = ConversationPreferences()
        prefs.coaching = .direct
        let prompt = VoiceIdentity.conversationInstructions(
            custom: "Your name is Sam", preferences: prefs, characterName: "Loki")
        XCTAssertTrue(prompt.contains("\"Loki\""))
        XCTAssertTrue(prompt.contains("previous names"))
        XCTAssertFalse(prompt.contains("pronounced MOH-chee"))
        let reference = ConversationRequest(
            history: [], text: "Say this", reference: true, instructions: "Your name is Sam", characterName: "Loki")
        XCTAssertFalse(reference.resolvedInstructions.contains("Loki"))
        var history: [String] = []
        for _ in 0..<30 {
            let greeting = VoiceIdentity.namedGreeting(name: "Loki", excluding: history)
            XCTAssertTrue(greeting.text.contains("Loki"))
            XCTAssertFalse(history.suffix(3).contains(greeting.pattern))
            history.append(greeting.pattern)
        }
    }

    @MainActor func testReplyHandshakeSendsBoundedHistoryAndChunkedAudio() async throws {
        var sent: [[String: Any]] = []
        var events: [[String: Any]] = [
            ["type": "session.created"], ["type": "session.updated"],
            ["type": "input_audio_buffer.committed", "item_id": "one"],
            [
                "type": "conversation.item.input_audio_transcription.completed", "item_id": "one",
                "transcript": "Spoken words",
            ],
            ["type": "response.output_text.delta", "delta": "Hi."],
            ["type": "response.done", "response": ["status": "completed"]],
        ]
        let channel = RealtimeChannel(send: { sent.append($0) }, receive: { events.removeFirst() }, close: {})
        let history = (0..<31).map { Message(role: $0.isMultiple(of: 2) ? "user" : "assistant", text: "Message \($0)") }
        let request = ConversationRequest(history: history, text: "", pcm: Data(count: 100_000), spoken: true)
        let requested = Locked<RealtimeEndpoint?>(nil)
        let reply = try await RealtimeService(model: "test-model").reply(
            request, credential: { testSecret("ek_reply-session") },
            connect: {
                requested.value = $0
                return channel
            })
        XCTAssertEqual(reply.text, "Hi.")
        XCTAssertEqual(reply.inputTranscript, "Spoken words")
        XCTAssertEqual(requested.value?.secret.bearer, "ek_reply-session")
        XCTAssertEqual(requested.value?.url.absoluteString, "wss://api.openai.com/v1/realtime?model=test-model")
        let types = sent.map { $0["type"] as? String ?? "" }
        XCTAssertEqual(types.first, "session.update")
        XCTAssertEqual(types.filter { $0 == "conversation.item.create" }.count, 30)
        XCTAssertEqual(types.filter { $0 == "input_audio_buffer.append" }.count, 3)
        XCTAssertEqual(Array(types.suffix(2)), ["input_audio_buffer.commit", "response.create"])
        XCTAssertEqual(
            (sent.last?["response"] as? [String: Any])?["max_output_tokens"] as? Int,
            RealtimeService.maximumOutputTokens)
    }

    func testInvalidVoiceMessageAudioIsRejectedBeforeSigningIn() async {
        for pcm in [Data(), Data(count: 4799), Data(count: 4801), Data(count: 65 * 48000 + 2)] {
            let signedIn = Locked(false)
            do {
                _ = try await RealtimeService().reply(
                    ConversationRequest(history: [], text: "", pcm: pcm, spoken: true),
                    credential: {
                        signedIn.value = true
                        return testSecret()
                    },
                    connect: { _ in
                        XCTFail("connected")
                        return RealtimeChannel(send: { _ in }, receive: { [:] }, close: {})
                    })
                XCTFail("Accepted \(pcm.count) bytes")
            } catch {
                XCTAssertTrue(error is AppFailure)
            }
            XCTAssertFalse(signedIn.value)
        }
    }
}

extension ConversationRequestTests {
    func testHelpFindsWordsInTheConversationsLanguageAndReadingAloudAssumesNone() {
        var preferences = ConversationPreferences()
        preferences.language = .japanese
        let help = ConversationRequest(history: [], text: "迷っています", help: true, preferences: preferences)
        XCTAssertTrue(help.resolvedInstructions.contains("natural spoken Japanese"))
        XCTAssertFalse(help.resolvedInstructions.contains("English"))
        let reading = ConversationRequest(history: [], text: "こんにちは", reference: true)
        XCTAssertFalse(reading.resolvedInstructions.contains("English"))
        let reply = ConversationRequest(history: [], text: "hi", userName: "Ana", preferences: preferences)
        XCTAssertTrue(reply.resolvedInstructions.contains("Speak only Japanese."))
        XCTAssertTrue(reply.resolvedInstructions.contains(#""Ana""#))
    }

    /// A greeting is usually a question to the listener. Sent as the user's message, the model answers it instead of
    /// saying it, so reading aloud sends no message: the line is in the instructions, marked as the model's own.
    @MainActor func testReadingAloudGivesTheModelALineToSayNotAMessageToAnswer() async throws {
        let line = "What shall we brainstorm? Tell me what the ideas are for."
        for reference in [true, false] {
            var sent: [[String: Any]] = []
            var events: [[String: Any]] = [
                ["type": "session.created"], ["type": "session.updated"],
                ["type": "response.output_text.delta", "delta": line],
                ["type": "response.done", "response": ["status": "completed"]],
            ]
            let channel = RealtimeChannel(send: { sent.append($0) }, receive: { events.removeFirst() }, close: {})
            _ = try await RealtimeService(model: "test-model").reply(
                ConversationRequest(history: [], text: line, reference: reference), credential: { testSecret() },
                connect: { _ in channel })
            let instructions = (sent.first?["session"] as? [String: Any])?["instructions"] as? String ?? ""
            let messages = sent.filter { $0["type"] as? String == "conversation.item.create" }
            XCTAssertEqual(messages.count, reference ? 0 : 1)
            XCTAssertEqual(instructions.contains("«\(line)»"), reference)
            XCTAssertEqual(sent.last?["type"] as? String, "response.create")
        }
    }
}
