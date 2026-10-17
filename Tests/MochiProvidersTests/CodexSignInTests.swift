import MochiKernel
import MochiTestSupport
import RealtimeConnection
import XCTest

@testable import CodexAuth
@testable import MochiProviders

/// A sign-in whose fetch or renewal the caller cancelled, as the shared package reports it: the state it stopped in,
/// with the class cancelled.
struct CancelledSignIn: CredentialSource {
    var state = CodexAuthState.expired
    var error: CodexAuthError {
        var error = CodexAuthError(state, message: "the refresh was cancelled")
        error.errorClass = .cancelled
        return error
    }
    func token() async throws -> Token { throw error }
    func refresh(after stale: Token) async throws -> Token { throw error }
}

final class CodexSignInTests: XCTestCase {
    /// Every state the shared sign-in reports has words the user can act on, and the three Mochi lacked before (a
    /// sign-in in the keychain, a Codex too old, a Codex that cannot share its sign-in) are told apart.
    func testEveryStateHasWordsTheUserCanActOn() {
        let unusable = CodexAuthState.allCases.filter { $0 != .ready }
        let messages = unusable.map { CodexSignIn.failure($0).message }
        XCTAssertFalse(messages.contains(where: \.isEmpty))
        // Missing Codex and a Codex that is not signed in ask for the same thing: a sign-in through Codex.
        XCTAssertEqual(CodexSignIn.failure(.noCodex).message, CodexSignIn.failure(.notSignedIn).message)
        XCTAssertEqual(Set(messages).count, unusable.count - 1)
        XCTAssertTrue(CodexSignIn.failure(.codexTooOld).message.contains(minimumCodexVersion))
        XCTAssertTrue(CodexSignIn.failure(.noSignInFile).message.contains("keychain"))
        XCTAssertTrue(CodexSignIn.failure(.appServerAuthUnavailable).message.contains("Update Codex"))
        XCTAssertTrue(CodexSignIn.failure(.apiKey).message.contains("API key"))
    }

    /// The states come from the shared package's own reading of a Codex folder, here its file source.
    func testFileSignInsReadThroughTheSharedPackage() async throws {
        let home = try home()
        let cases: [(String?, CodexAuthState)] = [
            (nil, .noSignInFile),
            (#"{"OPENAI_API_KEY":"sk-test","tokens":null}"#, .apiKey),
            (#"{"tokens":{"access_token":"\#(jwt(expiring: Date(timeIntervalSinceNow: -60)))"}}"#, .expired),
        ]
        for (content, state) in cases {
            try? FileManager.default.removeItem(at: home.appendingPathComponent(".codex/auth.json"))
            if let content { try write(content, to: home) }
            do {
                _ = try await CodexSignIn.account(fileSignIn(home))
                XCTFail("\(state) was accepted")
            } catch {
                XCTAssertEqual((error as? AppFailure)?.message, CodexSignIn.failure(state).message, "\(state)")
                XCTAssertEqual(CodexAuthError.state(of: (error as? AppFailure)?.underlying), state)
            }
        }
        let fresh = jwt(expiring: Date(timeIntervalSinceNow: 3600), account: "account-7")
        try write(#"{"tokens":{"access_token":"\#(fresh)"}}"#, to: home)
        let account = try await CodexSignIn.account(fileSignIn(home))
        XCTAssertEqual(account, CodexAccount(token: fresh, accountID: "account-7"))
    }

    /// A fetch or renewal the caller cancelled is that cancellation, never a sign-in that expired or failed.
    func testACancelledFetchOrRenewalIsACancellation() async {
        for state in [CodexAuthState.expired, .codexError] {
            XCTAssertTrue(CodexSignIn.failure(CancelledSignIn(state: state).error) is CancellationError, "\(state)")
            do {
                _ = try await CodexSignIn.account(CancelledSignIn(state: state))
                XCTFail("A cancelled sign-in was accepted")
            } catch {
                XCTAssertTrue(error is CancellationError, "\(state): \(error)")
            }
        }
        XCTAssertTrue(CodexSignIn.failure(CancellationError()) is CancellationError)
        // The same state, not cancelled, is still the sign-in's own failure.
        XCTAssertEqual(
            (CodexSignIn.failure(CodexAuthError(.expired)) as? AppFailure)?.message,
            CodexSignIn.failure(.expired).message)
    }

    /// A Codex folder outside the home folder, or a sign-in file that is a link, is never read.
    func testAFolderOutsideTheHomeFolderOrALinkedFileIsNotRead() async throws {
        let home = try home()
        let outside = try self.home()
        try write(#"{"tokens":{"access_token":"planted"}}"#, to: outside)
        let confined = try Credentials(
            CodexAuthConfiguration(
                margin: 600, timeout: 5, source: .file, home: home.path, confineCodexHome: home.path,
                environment: ["CODEX_HOME": outside.appendingPathComponent(".codex").path]))
        await assertRefused(confined, as: .codexError)
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent(".codex/auth.json"),
            withDestinationURL: outside.appendingPathComponent(".codex/auth.json"))
        await assertRefused(try fileSignIn(home), as: .codexError)
    }

    /// The account Codex's text endpoint asks for is the token's own claim, as sayso reads it; a token without
    /// the claim names no account.
    func testTheAccountIsTheTokensClaim() async throws {
        let home = try home()
        let named = jwt(expiring: Date(timeIntervalSinceNow: 3600), account: "acct-1")
        try write(#"{"tokens":{"access_token":"\#(named)"}}"#, to: home)
        let account = try await CodexSignIn.account(fileSignIn(home))
        XCTAssertEqual(account.accountID, "acct-1")
        let unnamed = jwt(expiring: Date(timeIntervalSinceNow: 3600))
        try write(#"{"tokens":{"access_token":"\#(unnamed)"}}"#, to: home)
        let anonymous = try await CodexSignIn.account(fileSignIn(home))
        XCTAssertNil(anonymous.accountID)
    }

    /// Mochi's own sign-in asks Codex first, keeps a sandboxed CODEX_HOME inside the home folder, renews ten minutes
    /// ahead, and refuses the real Codex inside a unit test.
    func testTheSharedSignInIsConfinedAndRefusedToUnitTests() throws {
        let configuration = CodexSignIn.configuration()
        XCTAssertEqual(configuration.source, .auto)
        XCTAssertEqual(configuration.confineCodexHome, NSHomeDirectory())
        XCTAssertEqual(configuration.margin, 600)
        XCTAssertEqual(configuration.clientName, "mochi")
        XCTAssertNotNil(LiveAccess.refusal(environment: [:]))
        XCTAssertNotNil(LiveAccess.refusal(environment: ["MOCHI_LIVE_AUDITION": ""]))
        XCTAssertNil(LiveAccess.refusal(environment: ["MOCHI_LIVE_AUDITION": "1"]))
        try XCTSkipIf(LiveAccess.refusal() == nil, "A live run may use the real sign-in.")
        XCTAssertThrowsError(try configuration.guardAccess?("/usr/local/bin/codex"))
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/realtime/client_secrets")!)
        request.setValue("Bearer tok-unit-test", forHTTPHeaderField: "Authorization")
        XCTAssertThrowsError(try OpenAIConnection.policy.check(request)) {
            XCTAssertEqual(($0 as? RealtimeError)?.errorClass, .internal)
        }
    }

    private func assertRefused(_ credentials: Credentials, as state: CodexAuthState) async {
        do {
            _ = try await CodexSignIn.account(credentials)
            XCTFail("The sign-in was read")
        } catch {
            XCTAssertEqual((error as? AppFailure)?.message, CodexSignIn.failure(state).message)
        }
    }

    private func fileSignIn(_ home: URL) throws -> Credentials {
        try Credentials(
            CodexAuthConfiguration(margin: 600, timeout: 5, source: .file, home: home.path, environment: [:]))
    }

    private func home() throws -> URL {
        let url = TestScratch.folder("mochi-home")
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func write(_ text: String, to home: URL) throws {
        try Data(text.utf8).write(to: home.appendingPathComponent(".codex/auth.json"))
    }

    private func jwt(expiring date: Date, account: String? = nil) -> String {
        func part(_ object: [String: Any]) -> String {
            try! JSONSerialization.data(withJSONObject: object).base64EncodedString().replacingOccurrences(
                of: "=", with: ""
            ).replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        }
        var claims: [String: Any] = ["exp": Int(date.timeIntervalSince1970)]
        if let account { claims["https://api.openai.com/auth"] = ["chatgpt_account_id": account] }
        return part(["alg": "none"]) + "." + part(claims) + ".signature"
    }
}
