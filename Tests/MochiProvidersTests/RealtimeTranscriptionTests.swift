import MochiKernel
import XCTest

@testable import MochiProviders

final class RealtimeTranscriptionTests: XCTestCase {
    func testFailedAndEmptyCompletionAreTerminalAndSanitized() throws {
        var failed = RealtimeAccumulator()
        try failed.accept(["type": "input_audio_buffer.committed", "item_id": "expected"])
        try failed.accept([
            "type": "conversation.item.input_audio_transcription.failed", "item_id": "expected",
            "error": ["code": "audio_unintelligible", "message": "secret-user-speech"],
        ])
        XCTAssertEqual(failed.transcriptionState, .failed)
        XCTAssertFalse(failed.transcriptionError?.contains("secret-user-speech") ?? true)
        var empty = RealtimeAccumulator()
        try empty.accept(["type": "input_audio_buffer.committed", "item_id": "empty"])
        try empty.accept([
            "type": "conversation.item.input_audio_transcription.completed", "item_id": "empty", "transcript": "  \n ",
        ])
        XCTAssertEqual(empty.transcriptionState, .failed)
    }

    func testResponseCompletionAndTranscriptCompletionAreIndependentAndCorrelated() throws {
        var result = RealtimeAccumulator()
        try result.accept(["type": "input_audio_buffer.committed", "item_id": "expected"])
        try result.accept([
            "type": "conversation.item.input_audio_transcription.completed", "item_id": "other", "transcript": "Wrong",
        ])
        XCTAssertTrue(result.inputTranscript.isEmpty)
        try result.accept(["type": "response.done", "response": ["status": "completed"]])
        XCTAssertTrue(result.done)
        XCTAssertEqual(result.transcriptionState, .pending)
        try result.accept([
            "type": "conversation.item.input_audio_transcription.completed", "item_id": "expected",
            "transcript": "A late thought",
        ])
        XCTAssertEqual(result.transcriptionState, .completed)
        XCTAssertEqual(result.inputTranscript, "A late thought")
    }

    @MainActor func testReplyDeliveredBeforeLateTranscriptWithoutReadingMoreEvents() async throws {
        let events: [[String: Any]] = [
            ["type": "response.output_text.delta", "delta": "The reply is ready"],
            ["type": "response.done", "response": ["status": "completed"]],
            ["type": "conversation.item.input_audio_transcription.completed", "transcript": "Late speech"],
        ]
        var index = 0
        var responseCount = 0
        var transcriptCount = 0
        let result = try await RealtimeService.deliverResponse(
            RealtimeAccumulator(),
            receive: {
                defer { index += 1 }
                return events[index]
            },
            onResponse: { result in
                responseCount += 1
                XCTAssertEqual(result.text, "The reply is ready")
                XCTAssertEqual(result.transcriptionState, .pending)
            }, onTranscription: { _ in transcriptCount += 1 })
        XCTAssertEqual(index, 2)
        XCTAssertEqual(responseCount, 1)
        XCTAssertEqual(transcriptCount, 0)
        XCTAssertTrue(result.done)
    }

    func testHelpSuggestionContractRejectsMalformedOrEmptyResults() throws {
        XCTAssertEqual(
            try HelpSuggestion.parse(#"{"kind":"expression","text":"A full thought. A qualification."}"#).kind,
            .expression)
        XCTAssertEqual(try HelpSuggestion.parse(#"{"kind":"clarification","text":"Which one?"}"#).kind, .clarification)
        XCTAssertThrowsError(try HelpSuggestion.parse("Unstructured text"))
        XCTAssertThrowsError(try HelpSuggestion.parse(#"{"kind":"expression","text":" "}"#))
    }

    func testRealtimeRecoveryCommitsAudioWithoutGeneratingAReply() async throws {
        let pcm = Data(repeating: 7, count: 96000)
        var sent: [[String: Any]] = []
        let events: [[String: Any]] = [
            ["type": "session.created"], ["type": "session.updated"],
            [
                "type": "conversation.item.input_audio_transcription.completed", "item_id": "uncommitted",
                "transcript": "Ignore",
            ],
            ["type": "input_audio_buffer.committed", "item_id": "expected"],
            [
                "type": "conversation.item.input_audio_transcription.completed", "item_id": "other",
                "transcript": "Wrong",
            ],
            [
                "type": "conversation.item.input_audio_transcription.completed", "item_id": "expected",
                "transcript": " Recovered thought ",
            ],
        ]
        var index = 0
        let text = try await RealtimeService.transcribeTurn(
            pcm, send: { sent.append($0) },
            receive: {
                guard index < events.count else { throw AppFailure("Unexpected receive") }
                defer { index += 1 }
                return events[index]
            })
        XCTAssertEqual(text.text, "Recovered thought")
        XCTAssertNil(text.evidence, "No logprobs came back")
        XCTAssertFalse(sent.contains { $0["type"] as? String == "response.create" })
        XCTAssertEqual(sent.last?["type"] as? String, "input_audio_buffer.commit")
        let session = try XCTUnwrap(sent.first?["session"] as? [String: Any])
        let input = try XCTUnwrap((session["audio"] as? [String: Any])?["input"] as? [String: Any])
        XCTAssertTrue(input["turn_detection"] is NSNull)
        XCTAssertEqual((input["transcription"] as? [String: Any])?["model"] as? String, "gpt-4o-mini-transcribe")
        XCTAssertEqual(session["include"] as? [String], ["item.input_audio_transcription.logprobs"])
        let chunks = sent.compactMap { $0["audio"] as? String }.compactMap { Data(base64Encoded: $0) }
        XCTAssertEqual(chunks.reduce(into: Data()) { $0.append($1) }, pcm)
    }

    func testRealtimeRecoveryFailuresAreSanitizedAndEmptyResultsFail() async throws {
        for terminal: [String: Any] in [
            [
                "type": "conversation.item.input_audio_transcription.failed", "item_id": "expected",
                "error": ["message": "private words"],
            ],
            [
                "type": "conversation.item.input_audio_transcription.completed", "item_id": "expected",
                "transcript": "  ",
            ],
        ] {
            var events: [[String: Any]] = [
                ["type": "session.created"], ["type": "session.updated"],
                ["type": "input_audio_buffer.committed", "item_id": "expected"], terminal,
            ]
            do {
                _ = try await RealtimeService.transcribeTurn(
                    Data(repeating: 0, count: 4800), send: { _ in }, receive: { events.removeFirst() })
                XCTFail("Expected transcription failure")
            } catch { XCTAssertFalse(error.localizedDescription.contains("private words")) }
        }
        do {
            _ = try await RealtimeService.transcribeTurn(
                Data(), send: { _ in XCTFail("Invalid audio must not send") },
                receive: {
                    XCTFail("Must not receive")
                    return [:]
                })
            XCTFail("Expected invalid audio")
        } catch {}
    }

    func testRealtimeCredentialRoutesNeverFallBack() async throws {
        let codex = try await RealtimeService.sessionToken(
            model: "gpt-realtime", codexToken: { "fake-codex" },
            transport: { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fake-codex")
                XCTAssertEqual(request.url?.path, "/v1/realtime/client_secrets")
                return Data(#"{"value":"fake-session"}"#.utf8)
            })
        XCTAssertEqual(codex, "fake-session")
    }

    func testRealtimeRecoveryCancellationRejectsLateCompletion() async throws {
        let waiting = expectation(description: "Receive started")
        let task = Task {
            try await RealtimeService.transcribeTurn(
                Data(repeating: 0, count: 4800), send: { _ in XCTFail("Canceled request must not send") },
                receive: {
                    waiting.fulfill()
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    return ["type": "session.created"]
                })
        }
        await fulfillment(of: [waiting], timeout: 2)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Canceled recovery must not complete")
        } catch is CancellationError {} catch { XCTFail("Expected cancellation") }
    }

    // MARK: Transcript evidence (plan W4)

    private func completed(_ transcript: String, logprobs: Any?) -> [[String: Any]] {
        var done: [String: Any] = [
            "type": "conversation.item.input_audio_transcription.completed", "item_id": "item",
            "transcript": transcript,
        ]
        if let logprobs { done["logprobs"] = logprobs }
        return [
            ["type": "session.created"], ["type": "session.updated"],
            ["type": "input_audio_buffer.committed", "item_id": "item"], done,
        ]
    }
    private func run(
        _ events: [[String: Any]], model: String = RealtimeService.transcriptionModel, languages: [String] = []
    ) async throws -> (TranscriptResult, [[String: Any]]) {
        var sent: [[String: Any]] = []
        var index = 0
        let result = try await RealtimeService.transcribeTurn(
            Data(repeating: 0, count: 4800), transcriptionModel: model, languages: languages,
            send: { sent.append($0) },
            receive: {
                defer { index += 1 }
                return events[index]
            })
        return (result, sent)
    }
    private func token(_ text: String, _ logprob: Double) -> [String: Any] {
        ["token": text, "logprob": logprob, "bytes": Array(text.utf8).map(Int.init)]
    }

    func testLogprobsCoveringTheTranscriptBecomeItsEvidence() async throws {
        let (result, _) = try await run(
            completed(" I go home.", logprobs: [token(" I", -0.01), token(" go", -1.2), token(" home.", -0.05)]))
        XCTAssertEqual(result.text, "I go home.")
        let evidence = try XCTUnwrap(result.evidence)
        XCTAssertEqual(evidence.text, "I go home.")
        XCTAssertEqual(evidence.pieces.map(\.end), [1, 4, 10])
        XCTAssertEqual(evidence.pieces.map(\.logprob), [-0.01, -1.2, -0.05])
    }
    func testMalformedLogprobsKeepTheTranscriptWithoutEvidence() async throws {
        let cases: [Any] = [
            [token("I go", -0.1)],  // does not cover the transcript
            [["token": "I go home.", "logprob": -0.1]],  // no bytes
            [["token": "I go home.", "logprob": "low", "bytes": Array("I go home.".utf8).map(Int.init)]],
            [["token": "x", "logprob": -0.1, "bytes": [300]]],  // not a byte
            "not a list",
        ]
        for logprobs in cases {
            let (result, _) = try await run(completed("I go home.", logprobs: logprobs))
            XCTAssertEqual(result.text, "I go home.")
            XCTAssertNil(result.evidence, "\(logprobs)")
        }
    }
    func testRoundingAboveZeroCountsAsCertainButALargerValueIsMalformed() async throws {
        // gpt-transcribe's own shape: some logprobs a rounding step above 0.
        let rounded: [[String: Any]] = [
            token("I", -0.2), token(" go", 9.1552734375e-05), token(" home.", 3.0517578125e-05),
        ]
        let (result, _) = try await run(completed("I go home.", logprobs: rounded))
        XCTAssertEqual(result.evidence?.pieces.map(\.logprob), [-0.2, 0, 0])
        let (malformed, _) = try await run(completed("I go home.", logprobs: [token("I go home.", 0.01)]))
        XCTAssertEqual(malformed.text, "I go home.")
        XCTAssertNil(malformed.evidence, "A logprob well above 0 is not rounding")
    }
    func testTheRecordingsOwnTranscriptionModelIsUsed() async throws {
        let (_, sent) = try await run(completed("Hi", logprobs: nil), model: "gpt-transcribe")
        let session = try XCTUnwrap(sent.first?["session"] as? [String: Any])
        let input = try XCTUnwrap((session["audio"] as? [String: Any])?["input"] as? [String: Any])
        XCTAssertEqual((input["transcription"] as? [String: Any])?["model"] as? String, "gpt-transcribe")
    }
    func testALanguageHintGoesAsLanguageForOneAndLanguagesForSeveral() async throws {
        func transcription(_ languages: [String]) async throws -> NSDictionary {
            let (_, sent) = try await run(completed("Hi", logprobs: nil), model: "gpt-transcribe", languages: languages)
            let session = try XCTUnwrap(sent.first?["session"] as? [String: Any])
            let input = try XCTUnwrap((session["audio"] as? [String: Any])?["input"] as? [String: Any])
            return try XCTUnwrap(input["transcription"] as? NSDictionary)
        }
        let none = try await transcription([])
        XCTAssertEqual(none, ["model": "gpt-transcribe"])
        let one = try await transcription(["en"])
        XCTAssertEqual(one, ["model": "gpt-transcribe", "language": "en"])
        let several = try await transcription(["en", "zh"])
        XCTAssertEqual(several, ["model": "gpt-transcribe", "languages": ["en", "zh"]])
    }
    func testConversationTurnsAskForLogprobsWithTheRequestsTranscriptionModel() throws {
        var request = ConversationRequest(history: [], text: "")
        request.transcriptionModel = "gpt-transcribe"
        let session = try RealtimeService().sessionConfiguration(request, toolsEnabled: false)
        XCTAssertEqual(session["include"] as? [String], ["item.input_audio_transcription.logprobs"])
        let input = try XCTUnwrap((session["audio"] as? [String: Any])?["input"] as? [String: Any])
        XCTAssertEqual((input["transcription"] as? [String: Any])?["model"] as? String, "gpt-transcribe")
    }
}
