import MochiKernel
import MochiTestSupport
import RealtimeConnection
import XCTest

@testable import MochiProviders

private final class SocketFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [[String: Any]]
    private var waiting: CheckedContinuation<[String: Any], Error>?
    private var closed = false
    private var closes = 0
    /// How many times the channel was closed, read under the lock: closes come from the service's own tasks.
    var closeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return closes
    }
    var onWait: (() -> Void)?
    init(_ events: [[String: Any]] = []) { self.events = events }
    func receive() async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if closed {
                lock.unlock()
                continuation.resume(throwing: URLError(.networkConnectionLost))
                return
            }
            if !events.isEmpty {
                let event = events.removeFirst()
                lock.unlock()
                continuation.resume(returning: event)
                return
            }
            waiting = continuation
            lock.unlock()
            onWait?()
        }
    }
    func close() {
        lock.lock()
        closed = true
        closes += 1
        let continuation = waiting
        waiting = nil
        lock.unlock()
        continuation?.resume(throwing: URLError(.networkConnectionLost))
    }
    var channel: RealtimeChannel {
        RealtimeChannel(send: { _ in }, receive: { try await self.receive() }, close: { self.close() })
    }
}
/// Waits on a semaphore off the cooperative pool, so cancellation cannot stop it: a sign-in or handshake stuck in
/// the network. Each test lets both of its waiters through after three seconds, so a request that still waited for
/// one fails the time assertion instead of hanging.
private func stuck(until release: DispatchSemaphore) async {
    await withCheckedContinuation { done in
        DispatchQueue.global().async {
            release.wait()
            done.resume()
        }
    }
}
final class RealtimeLifecycleTests: XCTestCase {
    /// A reply and a transcription, each with its sign-in and connection under a 100 ms deadline.
    private func requests(
        credential: @escaping @Sendable () async throws -> ClientSecret,
        connect: @escaping @Sendable (RealtimeEndpoint) async throws -> RealtimeChannel
    ) -> [(String, () async throws -> Void)] {
        [
            (
                "reply",
                {
                    _ = try await RealtimeService().reply(
                        ConversationRequest(history: [], text: "Hello"), credential: credential, connect: connect,
                        connectTimeout: 100_000_000)
                }
            ),
            (
                "transcription",
                {
                    _ = try await RealtimeService().transcribe(
                        Data(repeating: 0, count: 4800), credential: credential, connect: connect,
                        connectTimeout: 100_000_000)
                }
            ),
        ]
    }
    func testASignInThatNeverFinishesIsBoundedByTheConnectDeadline() async throws {
        let release = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            release.signal()
            release.signal()
        }
        let connected = SocketFixture()
        for (name, request) in requests(
            credential: {
                await stuck(until: release)
                return testSecret("ek_late")
            }, connect: { _ in connected.channel })
        {
            let started = Date()
            do {
                try await request()
                XCTFail("\(name) waited for the sign-in")
            } catch { XCTAssertTrue(error.localizedDescription.contains("timed out"), "\(name): \(error)") }
            XCTAssertLessThan(Date().timeIntervalSince(started), 1, "\(name) does not wait for the sign-in")
        }
        release.signal()
        release.signal()
    }
    func testAHandshakeThatNeverFinishesIsBoundedAndItsLateConnectionClosed() async throws {
        let release = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            release.signal()
            release.signal()
        }
        let late = SocketFixture()
        for (name, request) in requests(
            credential: { testSecret() },
            connect: { _ in
                await stuck(until: release)
                return late.channel
            })
        {
            let started = Date()
            do {
                try await request()
                XCTFail("\(name) waited for the handshake")
            } catch { XCTAssertTrue(error.localizedDescription.contains("timed out"), "\(name): \(error)") }
            XCTAssertLessThan(Date().timeIntervalSince(started), 1, "\(name) does not wait for the handshake")
        }
        release.signal()
        release.signal()
        for _ in 0..<100 where late.closeCount < 2 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(late.closeCount, 2, "Each handshake that completed late was closed")
    }
    func testWholeRecoveryBuildsSelectedModelRequestAndClosesTransport() async throws {
        let socket = SocketFixture([
            ["type": "session.created"], ["type": "session.updated"],
            ["type": "input_audio_buffer.committed", "item_id": "one"],
            [
                "type": "conversation.item.input_audio_transcription.completed", "item_id": "one",
                "transcript": "Known speech",
            ],
        ])
        let service = RealtimeService(model: "selected-model")
        let text = try await service.transcribe(
            Data(repeating: 0, count: 4800), credential: { testSecret("ek_test-session") },
            connect: { endpoint in
                XCTAssertEqual(endpoint.url.absoluteString, "wss://api.openai.com/v1/realtime?model=selected-model")
                XCTAssertEqual(endpoint.secret.bearer, "ek_test-session")
                return socket.channel
            })
        XCTAssertEqual(text.text, "Known speech")
        XCTAssertGreaterThan(socket.closeCount, 0)
    }
    func testRecoveryDeadlineClosesSuspendedReceiveAndReportsTimeout() async throws {
        let socket = SocketFixture()
        do {
            _ = try await RealtimeService().transcribe(
                Data(repeating: 0, count: 4800), credential: { testSecret() }, connect: { _ in socket.channel },
                timeoutNanoseconds: 10_000_000)
            XCTFail("Expected timeout")
        } catch { XCTAssertTrue(error.localizedDescription.contains("timed out")) }
        XCTAssertGreaterThan(socket.closeCount, 0)
    }
    func testRecoveryCancellationClosesSuspendedSocket() async throws {
        let socket = SocketFixture()
        let waiting = expectation(description: "Suspended receive")
        socket.onWait = { waiting.fulfill() }
        let task = Task {
            try await RealtimeService().transcribe(
                Data(repeating: 0, count: 4800), credential: { testSecret() }, connect: { _ in socket.channel })
        }
        await fulfillment(of: [waiting], timeout: 2)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch { XCTFail("Wrong error") }
        XCTAssertGreaterThan(socket.closeCount, 0)
    }
    func testCodexCredentialFailureNeverConnectsOrReadsApiKey() async throws {
        StubProtocol.response = (403, Data())
        defer { StubProtocol.response = nil }
        do {
            _ = try await RealtimeService().transcribe(
                Data(repeating: 0, count: 4800),
                credential: { try await RealtimeService.secret(model: "gpt-realtime", minter: stubMinter()) },
                connect: { _ in
                    XCTFail("Must not connect with rejected credentials")
                    return SocketFixture().channel
                })
            XCTFail("Expected credential failure")
        } catch { XCTAssertEqual(error.localizedDescription, "This account does not have access to OpenAI.") }
    }
    func testPostReplyProviderErrorAndConnectionLossAreFailedNotTimedOut() async throws {
        var initial = RealtimeAccumulator()
        try initial.accept(["type": "input_audio_buffer.committed", "item_id": "one"])
        initial.done = true
        initial.text = "Reply already delivered"
        let failed = try await RealtimeService.finishTranscription(
            initial,
            receive: { ["type": "error", "error": ["code": "invalid_request_error", "message": "private speech"]] },
            close: {})
        XCTAssertEqual(failed.transcriptionState, .failed)
        XCTAssertFalse(failed.transcriptionError?.contains("private speech") ?? true)
        let lost = try await RealtimeService.finishTranscription(
            initial, receive: { throw URLError(.networkConnectionLost) }, close: {})
        XCTAssertEqual(lost.transcriptionState, .failed)
        XCTAssertEqual(lost.text, initial.text)
    }
    func testPostReplyGraceHasItsOwnTimeoutAndPreservesReply() async throws {
        var initial = RealtimeAccumulator()
        initial.done = true
        initial.text = "Delivered"
        let socket = SocketFixture()
        let result = try await RealtimeService.finishTranscription(
            initial, receive: { try await socket.receive() }, close: { socket.close() }, timeoutNanoseconds: 10_000_000)
        XCTAssertEqual(result.transcriptionState, .timedOut)
        XCTAssertEqual(result.text, "Delivered")
        XCTAssertGreaterThan(socket.closeCount, 0)
    }
    func testReplyDeadlineClosesReceiveAndMapsTypedTimeout() async throws {
        let socket = SocketFixture()
        do {
            _ = try await RealtimeDeadline.run(
                seconds: 0.01, close: { socket.close() },
                operation: {
                    try await RealtimeService.deliverResponse(
                        RealtimeAccumulator(), receive: { try await socket.receive() }, onResponse: nil,
                        onTranscription: nil)
                })
            XCTFail("Expected reply timeout")
        } catch {
            XCTAssertTrue(error is RealtimeDeadline.Expired)
            XCTAssertTrue(RealtimeService.replyFailure(error).message.contains("reply timed out"))
        }
        XCTAssertGreaterThan(socket.closeCount, 0)
    }
    /// A connection that closes underneath can surface as a CancellationError although nothing cancelled the reply.
    /// Taken for the user's cancellation, it would end a greeting or a reply without a word; it is a failed
    /// connection. A reply that was cancelled still ends as cancelled.
    func testAConnectionCancelledUnderneathFailsInsteadOfPassingForCancellation() async throws {
        do {
            _ = try await RealtimeService(model: "test-model").reply(
                ConversationRequest(history: [], text: "Hello", reference: true), credential: { testSecret() },
                connect: { _ in
                    RealtimeChannel(
                        send: { _ in },
                        receive: {
                            try await RealtimeChannel.surfacing { () async throws -> [String: Any] in
                                throw CancellationError()
                            }
                        }, close: {})
                })
            XCTFail("A dropped connection passed silently")
        } catch {
            XCTAssertTrue(error is AppFailure, "\(error)")
        }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await RealtimeChannel.surfacing { () async throws -> Int in throw CancellationError() }
        }
        do {
            _ = try await cancelled.value
            XCTFail("A cancelled reply was not reported as cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }
    func testPreCommitAndMismatchedEventsCannotCompleteReplyTranscript() throws {
        var accumulator = RealtimeAccumulator()
        try accumulator.accept([
            "type": "conversation.item.input_audio_transcription.completed", "item_id": "old", "transcript": "Wrong",
        ])
        XCTAssertEqual(accumulator.transcriptionState, .pending)
        try accumulator.accept(["type": "input_audio_buffer.committed", "item_id": "new"])
        try accumulator.accept([
            "type": "conversation.item.input_audio_transcription.completed", "item_id": "old", "transcript": "Wrong",
        ])
        XCTAssertEqual(accumulator.transcriptionState, .pending)
        try accumulator.accept([
            "type": "conversation.item.input_audio_transcription.completed", "item_id": "new", "transcript": "Right",
        ])
        XCTAssertEqual(accumulator.inputTranscript, "Right")
    }
}
