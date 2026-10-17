import CodexAuth
import Foundation
import MochiKernel
import RealtimeConnection

/// The ChatGPT sign-in Codex holds for this Mac, obtained through Codex itself and, when no Codex is installed, from
/// its `auth.json`. Mochi has no API-key path by design. One shared `Credentials` caches the token in memory and
/// renews it through Codex when less than ten minutes remain; Codex runs only while a token is fetched or renewed.
public enum CodexSignIn {
    /// Mochi's sign-in for the whole process, so every request shares one cached token and one renewal.
    public static let shared: Credentials = {
        do { return try Credentials(configuration()) } catch {
            preconditionFailure("Mochi's Codex sign-in settings are invalid: \(error)")
        }
    }()

    /// A sandboxed `CODEX_HOME` outside the home folder is not read, as before the move to Codex's own sign-in.
    static func configuration() -> CodexAuthConfiguration {
        CodexAuthConfiguration(
            margin: 10 * 60, timeout: 30, source: .auto, confineCodexHome: NSHomeDirectory(), clientName: "mochi",
            guardAccess: { _ in
                if let refusal = LiveAccess.refusal() { throw AppFailure(verbatim: refusal) }
            })
    }

    /// The bearer for Codex's own endpoints, with the ChatGPT account it belongs to: the token's own
    /// `https://api.openai.com/auth` claim as sayso reads it, so it is known whichever source the token came from.
    public static func account(_ credentials: any CredentialSource = shared) async throws -> CodexAccount {
        do {
            let token = try await credentials.token()
            return CodexAccount(token: token.bearer, accountID: token.accountID)
        } catch { throw failure(error) }
    }

    /// The words for a sign-in that cannot be used; any other error is returned as it is.
    public static func failure(_ error: Error) -> Error {
        guard let error = error as? CodexAuthError else { return error }
        return failure(error.state, underlying: error)
    }

    static func failure(_ state: CodexAuthState, underlying: Error? = nil) -> AppFailure {
        switch state {
        case .noCodex, .notSignedIn:
            return AppFailure(
                "No Codex sign-in was found on this Mac. Sign in through Codex, then check the connection in Settings.",
                underlying: underlying)
        case .noSignInFile:
            return AppFailure(
                "Codex’s sign-in file was not found. If Codex keeps your sign-in in the keychain, update Codex so it can share it with Mochi; otherwise sign in through Codex again.",
                underlying: underlying)
        case .apiKey:
            return AppFailure(
                "Codex is signed in with an API key. Mochi uses your ChatGPT sign-in: sign in to Codex with ChatGPT, then retry.",
                underlying: underlying)
        case .unsupportedAuth:
            return AppFailure(
                "Codex is signed in a way Mochi can’t use. Sign in to Codex with ChatGPT, then retry.",
                underlying: underlying)
        case .expired:
            return AppFailure(
                "Your Codex sign-in has expired and Codex could not renew it. Sign in through Codex again, then retry.",
                underlying: underlying)
        case .codexError, .ready:
            return AppFailure(
                "Mochi could not get your sign-in from Codex. Check that Codex works on this Mac, then retry.",
                underlying: underlying)
        case .codexTooOld:
            return AppFailure(
                "Codex on this Mac is too old for Mochi. Update Codex to \(minimumCodexVersion) or later, then retry.",
                underlying: underlying)
        case .appServerAuthUnavailable:
            return AppFailure(
                "This version of Codex can’t share its sign-in with Mochi. Update Codex, then retry.",
                underlying: underlying)
        case .providerWithoutOpenAIAuth:
            return AppFailure(
                "Codex is set to a model provider that doesn’t use your ChatGPT sign-in. Check Codex’s settings, then retry.",
                underlying: underlying)
        }
    }
}

/// A bearer for Codex's own endpoints and the ChatGPT account it belongs to, which they ask for.
public struct CodexAccount: Equatable {
    public let token: String
    public let accountID: String?
    public init(token: String, accountID: String?) {
        self.token = token
        self.accountID = accountID
    }
}

/// Unit tests must never spend the user's sign-in or usage: inside an XCTest process the real Codex, the real
/// `auth.json` and the real OpenAI origin are refused unless a live test was asked for by a `MOCHI_LIVE_*` variable.
enum LiveAccess {
    static func refusal(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard NSClassFromString("XCTestCase") != nil else { return nil }
        if environment.contains(where: { $0.key.hasPrefix("MOCHI_LIVE") && !$0.value.isEmpty }) { return nil }
        return "a unit test reached the real Codex sign-in or OpenAI; set MOCHI_LIVE_* to run a live test"
    }
}
