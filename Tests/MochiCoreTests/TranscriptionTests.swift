import XCTest
@testable import MochiCore
final class TranscriptionTests: XCTestCase {
    func testLegacyPlaceholdersDecodeAsMetadataAndNeverContext() throws {
        for text in ["Voice message (transcript unavailable)","Voice message · awaiting transcript"] {
            let old = Message(role:"user",text:text,audio:"recording.wav")
            var json = try JSONSerialization.jsonObject(with:JSONEncoder().encode(old)) as! [String:Any]
            json.removeValue(forKey:"transcriptionState")
            let restored = try JSONDecoder().decode(Message.self,from:JSONSerialization.data(withJSONObject:json))
            XCTAssertEqual(restored.text,"")
            XCTAssertNil(restored.contextText)
            XCTAssertNotNil(restored.transcriptionState)
        }
        XCTAssertEqual(Message(role:"user",text:"An actual thought",audio:"recording.wav").contextText,"An actual thought")
        XCTAssertEqual(Message(role:"user",text:"Voice message (transcript unavailable)").contextText,"Voice message (transcript unavailable)")
    }
    func testFailedAndEmptyCompletionAreTerminalAndSanitized() throws {
        var failed = RealtimeAccumulator()
        try failed.accept(["type":"input_audio_buffer.committed","item_id":"expected"])
        try failed.accept(["type":"conversation.item.input_audio_transcription.failed","item_id":"expected","error":["code":"audio_unintelligible","message":"secret-user-speech"]])
        XCTAssertEqual(failed.transcriptionState,.failed)
        XCTAssertFalse(failed.transcriptionError?.contains("secret-user-speech") ?? true)
        var empty = RealtimeAccumulator()
        try empty.accept(["type":"input_audio_buffer.committed","item_id":"empty"])
        try empty.accept(["type":"conversation.item.input_audio_transcription.completed","item_id":"empty","transcript":"  \n "])
        XCTAssertEqual(empty.transcriptionState,.failed)
    }
    func testResponseCompletionAndTranscriptCompletionAreIndependentAndCorrelated() throws {
        var result = RealtimeAccumulator()
        try result.accept(["type":"input_audio_buffer.committed","item_id":"expected"])
        try result.accept(["type":"conversation.item.input_audio_transcription.completed","item_id":"other","transcript":"Wrong"])
        XCTAssertTrue(result.inputTranscript.isEmpty)
        try result.accept(["type":"response.done","response":["status":"completed"]])
        XCTAssertTrue(result.done)
        XCTAssertEqual(result.transcriptionState,.pending)
        try result.accept(["type":"conversation.item.input_audio_transcription.completed","item_id":"expected","transcript":"A late thought"])
        XCTAssertEqual(result.transcriptionState,.completed)
        XCTAssertEqual(result.inputTranscript,"A late thought")
    }
    @MainActor func testReplyDeliveredBeforeLateTranscriptWithoutReadingMoreEvents() async throws {
        let events: [[String:Any]] = [
            ["type":"response.output_text.delta","delta":"The reply is ready"],
            ["type":"response.done","response":["status":"completed"]],
            ["type":"conversation.item.input_audio_transcription.completed","transcript":"Late speech"]
        ]
        var index = 0, responseCount = 0, transcriptCount = 0
        let result = try await RealtimeService.deliverResponse(RealtimeAccumulator(),receive: {
            defer { index += 1 }; return events[index]
        },onResponse: { result in
            responseCount += 1; XCTAssertEqual(result.text,"The reply is ready"); XCTAssertEqual(result.transcriptionState,.pending)
        },onTranscription: { _ in transcriptCount += 1 })
        XCTAssertEqual(index,2); XCTAssertEqual(responseCount,1); XCTAssertEqual(transcriptCount,0)
        XCTAssertTrue(result.done)
    }
    func testHelpSuggestionContractRejectsMalformedOrEmptyResults() throws {
        XCTAssertEqual(try HelpSuggestion.parse(#"{"kind":"expression","text":"A full thought. A qualification."}"#).kind,.expression)
        XCTAssertEqual(try HelpSuggestion.parse(#"{"kind":"clarification","text":"Which one?"}"#).kind,.clarification)
        XCTAssertThrowsError(try HelpSuggestion.parse("Unstructured text"))
        XCTAssertThrowsError(try HelpSuggestion.parse(#"{"kind":"expression","text":" "}"#))
    }
    func testRealtimeRecoveryCommitsAudioWithoutGeneratingAReply() async throws {
        let pcm = Data(repeating:7,count:96000)
        var sent: [[String:Any]] = []
        let events: [[String:Any]] = [
            ["type":"session.created"], ["type":"session.updated"],
            ["type":"conversation.item.input_audio_transcription.completed","item_id":"uncommitted","transcript":"Ignore"],
            ["type":"input_audio_buffer.committed","item_id":"expected"],
            ["type":"conversation.item.input_audio_transcription.completed","item_id":"other","transcript":"Wrong"],
            ["type":"conversation.item.input_audio_transcription.completed","item_id":"expected","transcript":" Recovered thought "]
        ]
        var index = 0
        let text = try await RealtimeService.transcribeTurn(pcm,send: { sent.append($0) },receive: {
            guard index < events.count else { throw AppFailure("Unexpected receive") }
            defer { index += 1 }; return events[index]
        })
        XCTAssertEqual(text,"Recovered thought")
        XCTAssertFalse(sent.contains { $0["type"] as? String == "response.create" })
        XCTAssertEqual(sent.last?["type"] as? String,"input_audio_buffer.commit")
        let session = try XCTUnwrap(sent.first?["session"] as? [String:Any])
        let input = try XCTUnwrap((session["audio"] as? [String:Any])?["input"] as? [String:Any])
        XCTAssertTrue(input["turn_detection"] is NSNull)
        XCTAssertEqual((input["transcription"] as? [String:Any])?["model"] as? String,"gpt-4o-mini-transcribe")
        let chunks = sent.compactMap { $0["audio"] as? String }.compactMap { Data(base64Encoded:$0) }
        XCTAssertEqual(chunks.reduce(into:Data()) { $0.append($1) },pcm)
    }
    func testRealtimeRecoveryFailuresAreSanitizedAndEmptyResultsFail() async throws {
        for terminal: [String:Any] in [
            ["type":"conversation.item.input_audio_transcription.failed","item_id":"expected","error":["message":"private words"]],
            ["type":"conversation.item.input_audio_transcription.completed","item_id":"expected","transcript":"  "]
        ] {
            var events: [[String:Any]] = [["type":"session.created"],["type":"session.updated"],["type":"input_audio_buffer.committed","item_id":"expected"],terminal]
            do {
                _ = try await RealtimeService.transcribeTurn(Data(repeating:0,count:4800),send:{ _ in },receive:{ events.removeFirst() })
                XCTFail("Expected transcription failure")
            } catch { XCTAssertFalse(error.localizedDescription.contains("private words")) }
        }
        do {
            _ = try await RealtimeService.transcribeTurn(Data(),send:{ _ in XCTFail("Invalid audio must not send") },receive:{ XCTFail("Must not receive"); return [:] })
            XCTFail("Expected invalid audio")
        } catch {}
    }
    func testRealtimeCredentialRoutesNeverFallBack() async throws {
        let codex = try await RealtimeService.sessionToken(auth:"codex",model:"gpt-realtime",apiKey:{ XCTFail("Must not read API key"); return nil },codexToken:{ "fake-codex" },transport:{ request in
            XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"),"Bearer fake-codex")
            XCTAssertEqual(request.url?.path,"/v1/realtime/client_secrets")
            return Data(#"{"value":"fake-session"}"#.utf8)
        })
        XCTAssertEqual(codex,"fake-session")
        let api = try await RealtimeService.sessionToken(auth:"api",model:"gpt-realtime",apiKey:{ "fake-api" },codexToken:{ XCTFail("Must not read Codex token"); return "" },transport:{ _ in XCTFail("API key connects directly"); return Data() })
        XCTAssertEqual(api,"fake-api")
    }
    func testRealtimeRecoveryCancellationRejectsLateCompletion() async throws {
        let waiting = expectation(description:"Receive started")
        let task = Task {
            try await RealtimeService.transcribeTurn(Data(repeating:0,count:4800),send:{ _ in XCTFail("Canceled request must not send") },receive:{
                waiting.fulfill(); try? await Task.sleep(nanoseconds:1_000_000_000)
                return ["type":"session.created"]
            })
        }
        await fulfillment(of:[waiting],timeout:2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Canceled recovery must not complete") }
        catch is CancellationError {} catch { XCTFail("Expected cancellation") }
    }
    func testHelpRecordingBackupRemapsAndKeepsAudioOnImport() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:parent) }
        let root = parent.appendingPathComponent("source"), target = parent.appendingPathComponent("target"), package = parent.appendingPathComponent("backup.mochilibrary")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try Data([1,2,3]).write(to:root.appendingPathComponent("thought.wav"))
        var library = Library(); var chat = Conversation()
        chat.helpDraft = HelpDraft(meaning:"Saved thought",recording:"thought.wav"); library.conversations = [chat]
        try LibraryBackup.write(library,from:root,to:package)
        let imported = try LibraryBackup.read(package); var local = Library()
        _ = try LibraryBackup.merge(imported,from:package,into:&local,root:target)
        let name = try XCTUnwrap(local.conversations.first?.helpDraft?.recording)
        XCTAssertNotEqual(name,"thought.wav")
        XCTAssertEqual(try Data(contentsOf:target.appendingPathComponent(name)),Data([1,2,3]))
        XCTAssertTrue(local.referencedAudio.contains(name))
    }
    func testPendingLoadBecomesInterruptedAndMigrationPreservesOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = LibraryStore(root:root)
        var library = Library(); var chat = Conversation()
        var message = Message(role:"user",text:"",audio:"recording.wav"); message.transcriptionState = .pending
        chat.messages = [message]; chat.helpDraft = HelpDraft(meaning:"A thought",english:"A sentence",recording:"thought.wav")
        library.conversations = [chat]; try store.save(library)
        let before = try Data(contentsOf:store.file)
        var loaded = try store.load()
        XCTAssertEqual(loaded.conversations[0].messages[0].transcriptionState,.interrupted)
        XCTAssertTrue(loaded.referencedAudio.contains("thought.wav"))
        loaded.conversations[0].messages[0].text = "Updated"; try store.save(loaded)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("library-before-help-transcription.json")),before)
    }
}
