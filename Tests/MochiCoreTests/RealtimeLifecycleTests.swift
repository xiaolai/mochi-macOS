import XCTest
@testable import MochiCore

private final class SocketFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [[String:Any]]
    private var waiting: CheckedContinuation<[String:Any],Error>?
    private var closed = false
    private(set) var closeCount = 0
    var onWait: (() -> Void)?
    init(_ events: [[String:Any]] = []) { self.events = events }
    func receive() async throws -> [String:Any] {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if closed { lock.unlock(); continuation.resume(throwing:URLError(.networkConnectionLost)); return }
            if !events.isEmpty { let event = events.removeFirst(); lock.unlock(); continuation.resume(returning:event); return }
            waiting = continuation; lock.unlock(); onWait?()
        }
    }
    func close() {
        lock.lock(); closed = true; closeCount += 1; let continuation = waiting; waiting = nil; lock.unlock()
        continuation?.resume(throwing:URLError(.networkConnectionLost))
    }
    var channel: RealtimeChannel { RealtimeChannel(send:{ _ in },receive:{ try await self.receive() },close:{ self.close() }) }
}
final class RealtimeLifecycleTests: XCTestCase {
    func testWholeRecoveryBuildsSelectedModelRequestAndClosesTransport() async throws {
        let socket = SocketFixture([
            ["type":"session.created"],["type":"session.updated"],["type":"input_audio_buffer.committed","item_id":"one"],
            ["type":"conversation.item.input_audio_transcription.completed","item_id":"one","transcript":"Known speech"]
        ])
        let service = RealtimeService(auth:"codex",model:"selected-model")
        let text = try await service.transcribe(Data(repeating:0,count:4800),credential:{ "test-session" },connect:{ request in
            XCTAssertEqual(request.url?.scheme,"wss")
            XCTAssertEqual(URLComponents(url:request.url!,resolvingAgainstBaseURL:false)?.queryItems?.first?.value,"selected-model")
            XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"),"Bearer test-session")
            return socket.channel
        })
        XCTAssertEqual(text,"Known speech"); XCTAssertGreaterThan(socket.closeCount,0)
    }
    func testRecoveryDeadlineClosesSuspendedReceiveAndReportsTimeout() async throws {
        let socket = SocketFixture()
        do {
            _ = try await RealtimeService().transcribe(Data(repeating:0,count:4800),credential:{ "test" },connect:{ _ in socket.channel },timeoutNanoseconds:10_000_000)
            XCTFail("Expected timeout")
        } catch { XCTAssertTrue(error.localizedDescription.contains("timed out")) }
        XCTAssertGreaterThan(socket.closeCount,0)
    }
    func testRecoveryCancellationClosesSuspendedSocket() async throws {
        let socket = SocketFixture(); let waiting = expectation(description:"Suspended receive")
        socket.onWait = { waiting.fulfill() }
        let task = Task {
            try await RealtimeService().transcribe(Data(repeating:0,count:4800),credential:{ "test" },connect:{ _ in socket.channel })
        }
        await fulfillment(of:[waiting],timeout:2); task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("Wrong error") }
        XCTAssertGreaterThan(socket.closeCount,0)
    }
    func testCodexCredentialFailureNeverConnectsOrReadsApiKey() async throws {
        do {
            _ = try await RealtimeService(auth:"codex").transcribe(Data(repeating:0,count:4800),credential:{
                try await RealtimeService.sessionToken(auth:"codex",model:"gpt-realtime",apiKey:{ XCTFail("No fallback"); return "" },codexToken:{ "fake" },transport:{ _ in throw ServiceHTTP.failure(status:403,provider:"OpenAI") })
            },connect:{ _ in XCTFail("Must not connect with rejected credentials"); return SocketFixture().channel })
            XCTFail("Expected credential failure")
        } catch { XCTAssertEqual(error.localizedDescription,"This account does not have access to OpenAI.") }
    }
    func testPostReplyProviderErrorAndConnectionLossAreFailedNotTimedOut() async throws {
        var initial = RealtimeAccumulator(); try initial.accept(["type":"input_audio_buffer.committed","item_id":"one"])
        initial.done = true; initial.text = "Reply already delivered"
        let failed = try await RealtimeService.finishTranscription(initial,receive:{ ["type":"error","error":["code":"invalid_request_error","message":"private speech"]] },close:{})
        XCTAssertEqual(failed.transcriptionState,.failed); XCTAssertFalse(failed.transcriptionError?.contains("private speech") ?? true)
        let lost = try await RealtimeService.finishTranscription(initial,receive:{ throw URLError(.networkConnectionLost) },close:{})
        XCTAssertEqual(lost.transcriptionState,.failed); XCTAssertEqual(lost.text,initial.text)
    }
    func testPostReplyGraceHasItsOwnTimeoutAndPreservesReply() async throws {
        var initial = RealtimeAccumulator(); initial.done = true; initial.text = "Delivered"
        let socket = SocketFixture()
        let result = try await RealtimeService.finishTranscription(initial,receive:{ try await socket.receive() },close:{ socket.close() },timeoutNanoseconds:10_000_000)
        XCTAssertEqual(result.transcriptionState,.timedOut); XCTAssertEqual(result.text,"Delivered")
        XCTAssertGreaterThan(socket.closeCount,0)
    }
    func testReplyDeadlineClosesReceiveAndMapsTypedTimeout() async throws {
        let socket = SocketFixture()
        do {
            _ = try await RealtimeDeadline.run(nanoseconds:10_000_000,close:{ socket.close() }) {
                try await RealtimeService.deliverResponse(RealtimeAccumulator(),receive:{ try await socket.receive() },onResponse:nil,onTranscription:nil)
            }
            XCTFail("Expected reply timeout")
        } catch {
            XCTAssertTrue(error is RealtimeTimeout)
            XCTAssertTrue(RealtimeService.replyFailure(error).message.contains("reply timed out"))
        }
        XCTAssertGreaterThan(socket.closeCount,0)
    }
    func testPreCommitAndMismatchedEventsCannotCompleteReplyTranscript() throws {
        var accumulator = RealtimeAccumulator()
        try accumulator.accept(["type":"conversation.item.input_audio_transcription.completed","item_id":"old","transcript":"Wrong"])
        XCTAssertEqual(accumulator.transcriptionState,.pending)
        try accumulator.accept(["type":"input_audio_buffer.committed","item_id":"new"])
        try accumulator.accept(["type":"conversation.item.input_audio_transcription.completed","item_id":"old","transcript":"Wrong"])
        XCTAssertEqual(accumulator.transcriptionState,.pending)
        try accumulator.accept(["type":"conversation.item.input_audio_transcription.completed","item_id":"new","transcript":"Right"])
        XCTAssertEqual(accumulator.inputTranscript,"Right")
    }
}
