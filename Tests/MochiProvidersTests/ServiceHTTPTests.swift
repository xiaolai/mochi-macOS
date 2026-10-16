import MochiKernel
import RealtimeConnection
import XCTest

@testable import MochiProviders

/// Serves one canned response per test without touching the network.
final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var response: (status: Int, body: Data)?
    nonisolated(unsafe) static var failure: URLError?
    /// The last request served, and its body, which URLSession hands a protocol as a stream.
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        Self.lastBody =
            request.httpBody
            ?? request.httpBodyStream.map { stream in
                stream.open()
                defer { stream.close() }
                var body = Data()
                var chunk = [UInt8](repeating: 0, count: 4096)
                while case let count = stream.read(&chunk, maxLength: chunk.count), count > 0 {
                    body.append(chunk, count: count)
                }
                return body
            }
        if let failure = Self.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let (status, body) = Self.response ?? (200, Data())
        client?.urlProtocol(
            self,
            didReceive: HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!,
            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// A sign-in that always hands out one fixed token; refreshing returns it again.
struct FixedSignIn: CredentialSource {
    var bearer = "tok-fixed-sign-in"
    func token() async throws -> Token { Token(bearer: bearer, expires: nil) }
    func refresh(after stale: Token) async throws -> Token { try await token() }
}

/// Mochi's minter over `StubProtocol`, so a mint reply is whatever the test set.
func stubMinter(_ signIn: any CredentialSource = FixedSignIn()) -> Minter {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    return Minter(
        client: HTTPClient(configuration: configuration), credentials: signIn, timeout: 5, lifetimeSeconds: 600)
}

/// Never answers, so a request stays in flight until the task is cancelled.
private final class SilentProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}

final class ServiceHTTPTests: XCTestCase {
    func testHTTPOutcomesAreReportedPrecisely() async throws {
        defer {
            StubProtocol.response = nil
            StubProtocol.failure = nil
        }
        StubProtocol.response = (200, Data("ok".utf8))
        let body = try await fetch().get()
        XCTAssertEqual(body, Data("ok".utf8))
        StubProtocol.response = (302, Data())
        if case .failure(let f) = await fetch() {
            XCTAssertTrue(f.message.contains("redirected"))
        } else {
            XCTFail("Redirect accepted")
        }
        StubProtocol.response = (200, Data(count: ServiceHTTP.maximumResponse + 1))
        if case .failure(let f) = await fetch() {
            XCTAssertTrue(f.message.contains("too large"))
        } else {
            XCTFail("Oversized body accepted")
        }
        StubProtocol.failure = URLError(.notConnectedToInternet)
        if case .failure(let f) = await fetch() {
            XCTAssertTrue(f.message.contains("offline"))
            XCTAssertTrue(f.underlying is URLError)
        } else {
            XCTFail("Offline succeeded")
        }
    }

    func testTransportFailuresAreToldApart() {
        let messages = [
            URLError.Code.notConnectedToInternet, .timedOut, .cannotFindHost, .cannotConnectToHost,
            .serverCertificateUntrusted, .badURL,
        ]
        .map { ServiceHTTP.transportFailure(URLError($0), provider: "OpenAI").message }
        XCTAssertEqual(Set(messages).count, messages.count)
        XCTAssertTrue(messages[4].contains("intercepting"))
    }

    func testStatusMessagesAreExact() {
        XCTAssertEqual(
            ServiceHTTP.failure(status: 401, provider: "OpenAI").message,
            "Your Codex sign-in was rejected. Sign in through Codex again, then retry.")
        XCTAssertEqual(
            ServiceHTTP.failure(status: 401, provider: "Voice").message,
            "Voice credentials were rejected. Update them in Settings.")
        XCTAssertEqual(
            ServiceHTTP.failure(status: 403, provider: "OpenAI").message, "This account does not have access to OpenAI."
        )
        XCTAssertEqual(
            ServiceHTTP.failure(status: 429, provider: "OpenAI").message, "OpenAI usage limit reached. Retry later.")
        XCTAssertEqual(
            ServiceHTTP.failure(status: 500, provider: "OpenAI").message,
            "OpenAI request failed (HTTP 500). Check Settings and retry.")
    }

    func testCancelledHTTPRequestThrowsCancellation() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SilentProtocol.self]
        let request = URLRequest(url: URL(string: "https://example.invalid/never")!)
        let task = Task { try await ServiceHTTP.data(request, provider: "OpenAI", configuration: configuration) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled request returned data")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    private func fetch() async -> Result<Data, AppFailure> {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        do {
            return .success(
                try await ServiceHTTP.data(
                    URLRequest(url: URL(string: "https://api.openai.com/test")!), provider: "OpenAI",
                    configuration: configuration))
        } catch { return .failure(error as! AppFailure) }
    }
}

extension ServiceHTTPTests {
    /// The shared taxonomy reads as Mochi's own words did: a status keeps its message, a broken connection tells
    /// offline, timeout and interception apart, and a class with no words of its own leaves the caller's.
    func testClassifiedFailuresKeepMochisWords() {
        func message(_ error: RealtimeError) -> String? { ServiceHTTP.failure(error, provider: "OpenAI")?.message }
        XCTAssertEqual(
            message(RealtimeError(.authExpired, status: 401)),
            ServiceHTTP.failure(status: 401, provider: "OpenAI").message)
        XCTAssertEqual(
            message(RealtimeError(.routeDenied, status: 401, code: "missing_scope")),
            "This account does not have access to OpenAI.")
        XCTAssertEqual(message(RealtimeError(.rateLimited, status: 429)), "OpenAI usage limit reached. Retry later.")
        XCTAssertEqual(
            message(RealtimeError(.server, status: 503)), "OpenAI request failed (HTTP 503). Check Settings and retry.")
        XCTAssertTrue(message(RealtimeError(.protocol, status: 302))?.contains("redirected") == true)
        XCTAssertEqual(
            message(RealtimeError(.protocol, status: 200, message: "reply exceeds 1048576 bytes")),
            "OpenAI response was too large.")
        XCTAssertEqual(
            message(RealtimeError(.protocol, status: 200, message: "mint reply is not valid JSON")),
            "OpenAI returned an invalid response.")
        let offline = RealtimeError(
            .network, message: "request failed", cause: "URLError \(URLError.Code.notConnectedToInternet.rawValue)")
        XCTAssertEqual(
            message(offline),
            ServiceHTTP.transportFailure(URLError(.notConnectedToInternet), provider: "OpenAI").message)
        XCTAssertEqual(
            message(RealtimeError(.network, message: "request timed out after 45.0 s")),
            ServiceHTTP.transportFailure(URLError(.timedOut), provider: "OpenAI").message)
        for quiet in [ErrorClass.cancelled, .internal, .protocol] {
            XCTAssertNil(message(RealtimeError(quiet, message: "realtime event: not valid JSON")), "\(quiet)")
        }
    }

    /// `ServiceHTTP.failure` tells an oversized reply and a timeout apart by the package's own wording, and a broken
    /// connection by the URL error code it keeps in `cause`. These failures come from the shared minter itself, not
    /// from hand-built errors, so a package release that rewords them fails here instead of quietly turning Mochi's
    /// specific messages into generic ones.
    func testTheSharedPackagesOwnFailuresKeepMochisWords() async throws {
        defer {
            StubProtocol.response = nil
            StubProtocol.failure = nil
        }
        func mintFailure(_ minter: Minter = stubMinter()) async throws -> AppFailure? {
            do {
                _ = try await RealtimeService.secret(model: "gpt-realtime", minter: minter)
                XCTFail("The mint succeeded")
                return nil
            } catch let error as RealtimeError {
                return ServiceHTTP.failure(error, provider: "OpenAI")
            }
        }
        StubProtocol.response = (200, Data(count: Minter.maximumReply + 1))
        let large = try await mintFailure()
        XCTAssertEqual(large?.message, "OpenAI response was too large.")
        StubProtocol.response = nil
        StubProtocol.failure = URLError(.notConnectedToInternet)
        let offline = try await mintFailure()
        XCTAssertEqual(
            offline?.message,
            ServiceHTTP.transportFailure(URLError(.notConnectedToInternet), provider: "OpenAI").message)
        StubProtocol.failure = nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SilentProtocol.self]
        let silent = Minter(
            client: HTTPClient(configuration: configuration), credentials: FixedSignIn(), timeout: 0.2,
            lifetimeSeconds: 600)
        let late = try await mintFailure(silent)
        XCTAssertEqual(late?.message, ServiceHTTP.transportFailure(URLError(.timedOut), provider: "OpenAI").message)
    }

    /// A refused reply's text is the provider's and can hold what the user said; it never reaches Mochi's message or
    /// its diagnostics.
    func testAProvidersRefusalTextIsDropped() throws {
        let failure = try XCTUnwrap(
            ServiceHTTP.failure(
                RealtimeError(.invalidRequest, status: 400, message: "private words", requestID: "req-1"),
                provider: "OpenAI"))
        XCTAssertFalse(failure.message.contains("private words"))
        let kept = try XCTUnwrap(failure.underlying as? RealtimeError)
        XCTAssertEqual(kept.message, "")
        XCTAssertEqual(kept.requestID, "req-1")
    }

    /// Minting goes through the shared minter with Mochi's session object, and its refusal is Mochi's message.
    func testMintingSendsTheModelAndReadsTheSecret() async throws {
        StubProtocol.response = (200, Data(#"{"value":"ek_minted-value","expires_at":1900000000}"#.utf8))
        defer { StubProtocol.response = nil }
        let secret = try await RealtimeService.secret(model: "gpt-realtime", minter: stubMinter())
        XCTAssertEqual(secret.bearer, "ek_minted-value")
        StubProtocol.response = (429, Data())
        do {
            _ = try await RealtimeService.secret(model: "gpt-realtime", minter: stubMinter())
            XCTFail("A refused mint returned a secret")
        } catch let error as RealtimeError {
            XCTAssertEqual(RealtimeService.replyFailure(error).message, "OpenAI usage limit reached. Retry later.")
        }
    }
}
