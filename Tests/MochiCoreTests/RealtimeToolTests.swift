import XCTest
@testable import MochiCore
final class RealtimeToolTests: XCTestCase {
    @MainActor func testFunctionOnlyTurnContinuesAndKeepsTranscription() async throws {
        var events: [[String:Any]] = [
            ["type":"input_audio_buffer.committed","item_id":"voice"],
            ["type":"response.done","response":["status":"completed","output":[["type":"function_call","call_id":"c1","name":"get_session","arguments":"{}"]]]],
            ["type":"conversation.item.input_audio_transcription.completed","item_id":"voice","transcript":"hello"],
            ["type":"response.output_text.delta","delta":"Ready."],
            ["type":"response.done","response":["status":"completed"]]
        ]
        var sent: [[String:Any]] = []; var calls = 0
        let result = try await RealtimeService.deliverResponse(RealtimeAccumulator(),receive:{events.removeFirst()},onResponse:nil,onTranscription:nil,onTool:{_,_,_ in calls += 1; return ["ok":true]},send:{sent.append($0)})
        XCTAssertEqual(result.text,"Ready."); XCTAssertEqual(result.inputTranscript,"hello"); XCTAssertEqual(calls,1)
        XCTAssertEqual(sent.last?["type"] as? String,"response.create")
    }
    @MainActor func testInvalidAndDuplicateArgumentsDoNotExecuteTwice() async throws {
        let call: [String:Any] = ["type":"function_call","call_id":"same","name":"get_session","arguments":"{}"]
        var events: [[String:Any]] = [
            ["type":"response.done","response":["status":"completed","output":[call,call]]],
            ["type":"response.output_text.delta","delta":"Done"], ["type":"response.done","response":["status":"completed"]]
        ]
        var count = 0
        _ = try await RealtimeService.deliverResponse(RealtimeAccumulator(),receive:{events.removeFirst()},onResponse:nil,onTranscription:nil,onTool:{_,_,_ in count += 1; return ["ok":true]},send:{_ in})
        XCTAssertEqual(count,1)
    }
    @MainActor func testMalformedAndUnavailableToolReturnsErrorWithoutExecution() async throws {
        var events: [[String:Any]] = [
            ["type":"response.done","response":["status":"completed","output":[
                ["type":"function_call","call_id":"a","name":"get_session","arguments":"[]"],
                ["type":"function_call","call_id":"b","name":"set_conversation_instructions","arguments":"{}"]]]],
            ["type":"response.output_text.delta","delta":"Unavailable."], ["type":"response.done","response":["status":"completed"]]
        ]
        var sent: [[String:Any]] = [], count = 0
        _ = try await RealtimeService.deliverResponse(RealtimeAccumulator(),receive:{events.removeFirst()},onResponse:nil,onTranscription:nil,onTool:{_,_,_ in count += 1; return [:]},send:{sent.append($0)})
        XCTAssertEqual(count,0)
        XCTAssertEqual(sent.filter { $0["type"] as? String == "conversation.item.create" }.count,2)
        XCTAssertTrue(sent.dropLast().allSatisfy { (($0["item"] as? [String:Any])?["output"] as? String ?? "").contains("false") })
    }
    @MainActor func testToolRoundLimitAndCancellation() async throws {
        var count = 0
        do {
            _ = try await RealtimeService.deliverResponse(RealtimeAccumulator(),receive:{
                count += 1
                return ["type":"response.done","response":["status":"completed","output":[["type":"function_call","call_id":"call-\(count)","name":"get_session","arguments":"{}"]]]]
            },onResponse:nil,onTranscription:nil,onTool:{_,_,_ in ["ok":true]},send:{_ in})
            XCTFail("Unbounded tools accepted")
        } catch { XCTAssertEqual(count,9) }
        var callbacks = 0
        let task = Task {
            try await RealtimeService.deliverResponse(RealtimeAccumulator(),receive:{ throw CancellationError() },onResponse:{_ in callbacks += 1},onTranscription:nil,onTool:{_,_,_ in callbacks += 1; return [:]},send:{_ in})
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation ignored") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(callbacks,0)
    }

}
extension RealtimeToolTests {
    func testSessionToolsAreOnlyEnabledForChat() throws {
        let service = RealtimeService(model:"gpt-realtime",voice:"marin")
        XCTAssertNotNil(try service.sessionConfiguration(ConversationRequest(history:[],text:"Hello"),toolsEnabled:true)["tools"])
        for input in [ConversationRequest(history:[],text:"Hello",help:true),ConversationRequest(history:[],text:"Hello",reference:true)] {
            XCTAssertNil(try service.sessionConfiguration(input,toolsEnabled:true)["tools"])
        }
        XCTAssertNil(try service.sessionConfiguration(ConversationRequest(history:[],text:"Hello"),toolsEnabled:false)["tools"])
    }
    @MainActor func testMixedAudioToolTurnsDeliverOneAccumulatedResponse() async throws {
        let chunk = Data([0,0,1,0])
        var events: [[String:Any]] = [
            ["type":"response.output_audio.delta","delta":chunk.base64EncodedString()],
            ["type":"response.output_audio_transcript.delta","delta":"First. "],
            ["type":"response.done","response":["status":"completed","output":[["type":"function_call","call_id":"a","name":"get_session","arguments":"{}"]]]],
            ["type":"response.output_audio.delta","delta":chunk.base64EncodedString()],
            ["type":"response.output_audio_transcript.delta","delta":"Second."],
            ["type":"response.done","response":["status":"completed"]]
        ]
        var delivered: [RealtimeAccumulator] = []
        let reply = try await RealtimeService.deliverResponse(RealtimeAccumulator(),receive:{events.removeFirst()},onResponse:{delivered.append($0)},onTranscription:nil,onTool:{_,_,_ in ["ok":true]},send:{_ in})
        XCTAssertEqual(delivered.count,1); XCTAssertEqual(reply.audio,chunk+chunk); XCTAssertEqual(reply.text,"First. Second.")
    }
    @MainActor func testToolOutputContextIsBounded() async throws {
        var round = 0, outputs: [String] = []
        _ = try await RealtimeService.deliverResponse(RealtimeAccumulator(),receive:{
            round += 1
            if round <= 3 { return ["type":"response.done","response":["status":"completed","output":[["type":"function_call","call_id":"c\(round)","name":"get_session","arguments":"{}"]]]] }
            if round == 4 { return ["type":"response.output_text.delta","delta":"Done."] }
            return ["type":"response.done","response":["status":"completed"]]
        },onResponse:nil,onTranscription:nil,onTool:{_,_,_ in ["ok":true,"text":String(repeating:"x",count:20000)]},send:{event in
            if let item = event["item"] as? [String:Any], let output = item["output"] as? String { outputs.append(output) }
        })
        XCTAssertEqual(outputs.count,3); XCTAssertTrue(outputs.allSatisfy { $0.utf8.count <= 8000 })
    }
}
