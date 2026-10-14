import Foundation
import MochiKernel
import XCTest

@testable import MochiProviders

/// A fake Realtime connection: events the test scripts, and a record of what the session sent.
private final class FakeConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [[String: Any]]
    private var waiting: CheckedContinuation<[String: Any], Error>?
    private(set) var sent: [[String: Any]] = []
    private(set) var closed = false
    private(set) var request: URLRequest?

    init(_ events: [[String: Any]]) { queued = events }

    func push(_ event: [String: Any]) {
        lock.lock()
        if let waiting {
            self.waiting = nil
            lock.unlock()
            waiting.resume(returning: event)
            return
        }
        queued.append(event)
        lock.unlock()
    }
    var sentSnapshot: [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return sent
    }
    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }
    func channel(_ request: URLRequest) -> RealtimeChannel {
        lock.lock()
        self.request = request
        lock.unlock()
        return RealtimeChannel(
            send: { [self] event in
                lock.withLock { sent.append(event) }
            },
            receive: { [self] in
                try await withCheckedThrowingContinuation { continuation in
                    lock.lock()
                    if closed {
                        lock.unlock()
                        continuation.resume(throwing: URLError(.cancelled))
                    } else if !queued.isEmpty {
                        let event = queued.removeFirst()
                        lock.unlock()
                        continuation.resume(returning: event)
                    } else {
                        waiting = continuation
                        lock.unlock()
                    }
                }
            },
            close: { [self] in
                lock.lock()
                closed = true
                let pending = waiting
                waiting = nil
                lock.unlock()
                pending?.resume(throwing: URLError(.cancelled))
            })
    }
}

final class ListeningSessionTests: XCTestCase {
    private let handshake: [[String: Any]] = [["type": "session.created"], ["type": "session.updated"]]

    private func open(
        _ connection: FakeConnection, detection: TurnDetection = .semantic(eagerness: "low"),
        timeout: UInt64 = 2_000_000_000
    ) async throws -> ListeningSession {
        try await ListeningSession.open(
            service: RealtimeService(), detection: detection, transcriptionModel: "gpt-4o-mini-transcribe",
            languages: [], credential: { "session-token" }, connect: connection.channel,
            handshakeTimeout: timeout)
    }

    private struct MissingSignals: Error {}
    /// Up to `count` signals, or what arrived before the session ended. Gives up after `timeout` seconds, closing the
    /// session so nothing is left waiting, and fails the test.
    private func signals(_ session: ListeningSession, count: Int, timeout: TimeInterval = 5) async throws
        -> [ListeningSignal]
    {
        let watchdog = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            session.close()
            XCTFail("Signals did not arrive within \(timeout) s")
        }
        defer { watchdog.cancel() }
        var received: [ListeningSignal] = []
        for try await signal in session.signals {
            received.append(signal)
            if received.count == count { break }
        }
        return received
    }
    /// Waits, at most `timeout` seconds, for `condition`.
    private func eventually(_ timeout: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 1_000_000) }
        return condition()
    }

    func testSessionSendsSemanticTurnDetectionWithTheChosenEagernessAndNeverResponds() async throws {
        for eagerness in ["low", "medium", "high"] {
            let connection = FakeConnection(handshake)
            let session = try await open(connection, detection: .semantic(eagerness: eagerness))
            defer { session.close() }
            XCTAssertEqual(
                connection.request?.value(forHTTPHeaderField: "Authorization"), "Bearer session-token")
            let update = try XCTUnwrap(connection.sentSnapshot.first)
            XCTAssertEqual(update["type"] as? String, "session.update")
            let configuration = try XCTUnwrap(update["session"] as? [String: Any])
            XCTAssertEqual(configuration["output_modalities"] as? [String], ["text"])
            let input = try XCTUnwrap((configuration["audio"] as? [String: Any])?["input"] as? [String: Any])
            let detection = try XCTUnwrap(input["turn_detection"] as? [String: Any])
            XCTAssertEqual(detection["type"] as? String, "semantic_vad")
            XCTAssertEqual(detection["eagerness"] as? String, eagerness)
            XCTAssertEqual(detection["create_response"] as? Bool, false)
            XCTAssertEqual(detection["interrupt_response"] as? Bool, false)
            XCTAssertEqual((input["transcription"] as? [String: Any])?["model"] as? String, "gpt-4o-mini-transcribe")
            XCTAssertEqual((input["format"] as? [String: Any])?["rate"] as? Int, 24000)
        }
    }

    func testSilenceBaselineSendsServerTurnDetection() async throws {
        let connection = FakeConnection(handshake)
        let session = try await open(connection, detection: .silence(milliseconds: 1500))
        session.close()
        let configuration = try XCTUnwrap(connection.sentSnapshot.first?["session"] as? [String: Any])
        let input = try XCTUnwrap((configuration["audio"] as? [String: Any])?["input"] as? [String: Any])
        let detection = try XCTUnwrap(input["turn_detection"] as? [String: Any])
        XCTAssertEqual(detection["type"] as? String, "server_vad")
        XCTAssertEqual(detection["silence_duration_ms"] as? Int, 1500)
        XCTAssertEqual(detection["create_response"] as? Bool, false)
    }

    func testAudioIsStreamedInOrderWithoutCommitOrResponse() async throws {
        let connection = FakeConnection(handshake)
        let session = try await open(connection)
        let chunks = (0..<20).map { Data(repeating: UInt8($0), count: 960) }
        for chunk in chunks { session.append(chunk) }
        session.append(Data())
        let deadline = Date().addingTimeInterval(5)
        while connection.sentSnapshot.count < 21 && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        let counted = await eventually { session.sentBytes == 20 * 960 }
        XCTAssertTrue(counted, "Sent audio is counted once the connection takes it: \(session.sentBytes)")
        session.close()
        let appended = connection.sentSnapshot.dropFirst()
        XCTAssertTrue(appended.allSatisfy { $0["type"] as? String == "input_audio_buffer.append" })
        XCTAssertEqual(appended.compactMap { ($0["audio"] as? String).flatMap { Data(base64Encoded: $0) } }, chunks)
        XCTAssertFalse(connection.sentSnapshot.contains { ($0["type"] as? String)?.hasPrefix("response.") == true })
        XCTAssertFalse(connection.sentSnapshot.contains { $0["type"] as? String == "input_audio_buffer.commit" })
    }

    func testSpeechStartStopAndTheCommittedItemsTranscriptAreReported() async throws {
        let connection = FakeConnection(handshake)
        let session = try await open(connection)
        defer { session.close() }
        for event: [String: Any] in [
            ["type": "input_audio_buffer.speech_started", "audio_start_ms": 280, "item_id": "turn"],
            ["type": "rate_limits.updated"],
            ["type": "input_audio_buffer.speech_stopped", "audio_end_ms": 2900, "item_id": "turn"],
            [
                "type": "conversation.item.input_audio_transcription.completed", "item_id": "other",
                "transcript": "Not this one",
            ],
            ["type": "input_audio_buffer.committed", "item_id": "turn"],
            [
                "type": "conversation.item.input_audio_transcription.completed", "item_id": "turn",
                "transcript": " I went to the market. ",
            ],
        ] { connection.push(event) }
        let received = try await signals(session, count: 3)
        XCTAssertEqual(
            received,
            [
                .speechStarted(audioMilliseconds: 280), .speechStopped(audioMilliseconds: 2900),
                .transcribed("I went to the market."),
            ])
    }

    func testAFailedTranscriptionReportsNothingRecognized() throws {
        var item = ListeningItem()
        XCTAssertNil(try item.accept(["type": "input_audio_buffer.committed", "item_id": "turn"]))
        XCTAssertNil(try item.accept(["type": "input_audio_buffer.committed", "item_id": "later"]))
        XCTAssertEqual(
            try item.accept([
                "type": "conversation.item.input_audio_transcription.failed", "item_id": "turn",
                "error": ["code": "audio_unintelligible"],
            ]), .transcribed(""))
        XCTAssertNil(
            try item.accept([
                "type": "conversation.item.input_audio_transcription.completed", "item_id": "turn",
                "transcript": "Again",
            ]), "Only the first result for the turn counts")
    }

    func testProviderErrorEndsTheSignalsWithASanitizedFailure() async throws {
        let connection = FakeConnection(handshake)
        let session = try await open(connection)
        connection.push(["type": "error", "error": ["code": "rate_limit_exceeded", "message": "private words"]])
        do {
            _ = try await signals(session, count: 1)
            XCTFail("Expected the session to fail")
        } catch {
            let message = (error as? AppFailure)?.message ?? ""
            XCTAssertTrue(message.contains("usage limit"), message)
            XCTAssertFalse(message.contains("private words"))
        }
        let closed = await eventually { connection.isClosed }
        XCTAssertTrue(closed, "A failed session closes its connection")
    }

    func testAConnectionThatDropsFailsTheSignals() async throws {
        let connection = FakeConnection(handshake)
        let session = try await open(connection)
        let listening = Task { try await self.signals(session, count: 1) }
        try await Task.sleep(nanoseconds: 50_000_000)
        connection.channel(URLRequest(url: URL(string: "wss://example.invalid")!)).close()
        do {
            _ = try await listening.value
            XCTFail("Expected the session to fail")
        } catch {
            XCTAssertTrue(error is AppFailure, "\(error)")
        }
    }

    func testClosingEndsTheSignalsQuietlyAndClosesTheConnection() async throws {
        let connection = FakeConnection(handshake)
        let session = try await open(connection)
        let listening = Task { try await self.signals(session, count: 1) }
        try await Task.sleep(nanoseconds: 50_000_000)
        session.close()
        session.close()
        let received = try await listening.value
        XCTAssertEqual(received, [], "Closing on purpose is not a failure")
        let closed = await eventually { connection.isClosed }
        XCTAssertTrue(closed)
        session.append(Data([1, 2]))
    }

    func testHandshakeFailuresAreReportedAndCloseTheConnection() async throws {
        let rejected = FakeConnection([
            ["type": "session.created"], ["type": "error", "error": ["code": "invalid_api_key"]],
        ])
        do {
            _ = try await open(rejected)
            XCTFail("Expected the handshake to fail")
        } catch {
            XCTAssertTrue((error as? AppFailure)?.message.contains("sign-in") == true, "\(error)")
        }
        XCTAssertTrue(rejected.isClosed)

        let silent = FakeConnection([["type": "session.created"]])
        // Should the deadline regress, this ends the wait, so the test fails on the time instead of hanging.
        let watchdog = Task {
            try await Task.sleep(nanoseconds: 3_000_000_000)
            silent.channel(URLRequest(url: URL(string: "wss://example.invalid")!)).close()
        }
        defer { watchdog.cancel() }
        let started = Date()
        do {
            _ = try await open(silent, timeout: 100_000_000)
            XCTFail("Expected the handshake to time out")
        } catch {
            XCTAssertTrue((error as? AppFailure)?.message.contains("in time") == true, "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "The deadline, not the watchdog, ended the wait")
        XCTAssertTrue(silent.isClosed)
    }

    func testACredentialArrivingAfterTheDeadlineIsCancelledAndNeverConnects() async throws {
        let connection = FakeConnection(handshake)
        let started = Date()
        do {
            _ = try await ListeningSession.open(
                service: RealtimeService(), detection: .semantic(eagerness: "low"),
                transcriptionModel: "gpt-4o-mini-transcribe", languages: [],
                credential: {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    return "late"
                }, connect: connection.channel, handshakeTimeout: 100_000_000)
            XCTFail("Expected the handshake to time out")
        } catch {
            XCTAssertTrue((error as? AppFailure)?.message.contains("in time") == true, "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "The deadline cancels the slow credential")
        XCTAssertNil(connection.request, "No connection opens after the deadline")
    }

    func testACredentialThatIgnoresCancellationNeverLeavesAConnectionOpen() async throws {
        let connection = FakeConnection(handshake)
        let release = DispatchSemaphore(value: 0)
        // Should the deadline ever wait for the credential again, this lets it through, so the test fails on the
        // time assertion below instead of hanging.
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { release.signal() }
        let started = Date()
        do {
            _ = try await ListeningSession.open(
                service: RealtimeService(), detection: .semantic(eagerness: "low"),
                transcriptionModel: "gpt-4o-mini-transcribe", languages: [],
                credential: {
                    // Arrives only when the test lets it, long after the deadline: cancellation does not stop it.
                    await withCheckedContinuation { done in
                        DispatchQueue.global().async {
                            release.wait()
                            done.resume()
                        }
                    }
                    return "late"
                }, connect: connection.channel, handshakeTimeout: 100_000_000)
            XCTFail("Expected the handshake to time out")
        } catch {
            XCTAssertTrue((error as? AppFailure)?.message.contains("in time") == true, "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "The deadline does not wait for the credential")
        release.signal()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(
            connection.request == nil || connection.isClosed, "A late credential never leaves a connection open")
    }

    func testUnsupportedTranscriptionLanguagesFailBeforeConnecting() async throws {
        do {
            _ = try await ListeningSession.open(
                service: RealtimeService(), detection: .semantic(eagerness: "low"),
                transcriptionModel: "gpt-4o-mini-transcribe", languages: ["en", "zh"],
                credential: {
                    XCTFail("No credential before the settings are valid")
                    return ""
                },
                connect: { _ in
                    XCTFail("No connection before the settings are valid")
                    return RealtimeChannel(send: { _ in }, receive: { [:] }, close: {})
                })
            XCTFail("Expected a settings failure")
        } catch {}
    }
}
