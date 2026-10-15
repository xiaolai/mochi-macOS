import Foundation
import MochiKernel

/// The ChatGPT access token that Codex keeps in `auth.json`. Mochi has no API-key path by design.
public enum Credentials {
    static let maximumFileSize = 65_536
    enum SignIn: Error, Equatable {
        case missing, unreadable, notOwned, unrecognized, apiKeyOnly, expired, untrustedCodexHome
        var failure: AppFailure {
            switch self {
            case .missing:
                return AppFailure(
                    "No Codex sign-in was found on this Mac. Sign in through Codex, then check the connection in Settings."
                )
            case .unreadable:
                return AppFailure(
                    "Codex’s sign-in file could not be read. Check its permissions, or sign in through Codex again.")
            case .notOwned:
                return AppFailure(
                    "Codex’s sign-in file is not a regular file owned by you, so Mochi did not read it. Sign in through Codex again."
                )
            case .unrecognized:
                return AppFailure(
                    "Codex’s sign-in file has a format Mochi doesn’t recognize. Update Codex and sign in again.")
            case .apiKeyOnly:
                return AppFailure(
                    "Codex is signed in with an API key. Mochi uses your ChatGPT sign-in: sign in to Codex with ChatGPT, then retry."
                )
            case .expired:
                return AppFailure(
                    "Your Codex sign-in has expired. Use Codex once so it can renew the sign-in, or sign in again, then retry."
                )
            case .untrustedCodexHome:
                return AppFailure(
                    "Mochi ignored CODEX_HOME because it is not a folder you own inside your home folder. Unset it or point it at your Codex folder."
                )
            }
        }
    }
    public static func codexToken() async throws -> String { try await codexSignIn().token }
    /// The access token with the ChatGPT account it belongs to, which Codex's own text endpoint asks for.
    public struct CodexSignIn: Equatable {
        public let token: String
        public let accountID: String?
    }
    public static func codexSignIn() async throws -> CodexSignIn {
        try await codexSignIn(
            environment: ProcessInfo.processInfo.environment, home: FileManager.default.homeDirectoryForCurrentUser,
            now: Date())
    }
    static func codexToken(environment: [String: String], home: URL, now: Date, retryDelay: UInt64 = 50_000_000)
        async throws -> String
    {
        try await codexSignIn(environment: environment, home: home, now: now, retryDelay: retryDelay).token
    }
    static func codexSignIn(environment: [String: String], home: URL, now: Date, retryDelay: UInt64 = 50_000_000)
        async throws -> CodexSignIn
    {
        do {
            let file = try codexFolder(environment: environment, home: home).appendingPathComponent("auth.json")
            do { return try signIn(in: file, now: now) } catch SignIn.unrecognized {
                // Codex may be rewriting the file; one re-read tells a torn write from a real format change.
                try await Task.sleep(nanoseconds: retryDelay)
                return try signIn(in: file, now: now)
            }
        } catch let problem as SignIn { throw problem.failure }
    }
    /// CODEX_HOME is honoured only when it resolves to a folder the user owns inside their home folder.
    static func codexFolder(environment: [String: String], home: URL) throws -> URL {
        guard let value = environment["CODEX_HOME"], !value.isEmpty else {
            return home.appendingPathComponent(".codex")
        }
        let folder = URL(fileURLWithPath: value).standardizedFileURL.resolvingSymlinksInPath()
        let homePath = home.standardizedFileURL.resolvingSymlinksInPath().path
        var info = stat()
        guard folder.path.hasPrefix(homePath + "/"), lstat(folder.path, &info) == 0,
            info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid()
        else { throw SignIn.untrustedCodexHome }
        return folder
    }
    static func token(in file: URL, now: Date) throws -> String { try signIn(in: file, now: now).token }
    static func signIn(in file: URL, now: Date) throws -> CodexSignIn {
        let data = try signInData(file)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SignIn.unrecognized
        }
        guard let tokens = object["tokens"] as? [String: Any] else {
            if let key = object["OPENAI_API_KEY"] as? String, !key.isEmpty { throw SignIn.apiKeyOnly }
            throw SignIn.unrecognized
        }
        guard let token = tokens["access_token"] as? String, !token.isEmpty else { throw SignIn.unrecognized }
        if let expiry = expiry(of: token), expiry <= now { throw SignIn.expired }
        let account = (tokens["account_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return CodexSignIn(token: token, accountID: account)
    }
    /// Opens once without following symlinks, then checks and reads that same descriptor, so the file
    /// cannot be swapped or grown between the ownership check and the read.
    private static func signInData(_ file: URL) throws -> Data {
        try ownedFileData(file, limit: maximumFileSize)
    }
    /// The contents of a regular file the user owns, smaller than `limit`, read without following symlinks.
    static func ownedFileData(_ file: URL, limit: Int) throws -> Data {
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            switch errno {
            case ENOENT: throw SignIn.missing
            case ELOOP: throw SignIn.notOwned
            default: throw SignIn.unreadable
            }
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw SignIn.unreadable }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else { throw SignIn.notOwned }
        guard info.st_size < limit else { throw SignIn.unreadable }
        var buffer = [UInt8](repeating: 0, count: limit)
        var count = 0
        while count < limit {
            let chunk = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress! + count, limit - count)
            }
            if chunk == 0 { break }
            if chunk < 0 {
                if errno == EINTR { continue }
                throw SignIn.unreadable
            }
            count += chunk
        }
        guard count < limit else { throw SignIn.unreadable }
        return Data(buffer[..<count])
    }
    /// The `exp` claim of a JWT access token; nil for opaque tokens.
    static func expiry(of token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
            let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let exp = (claims["exp"] as? NSNumber)?.doubleValue, exp.isFinite
        else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}
