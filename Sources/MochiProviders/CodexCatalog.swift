import Foundation
import MochiKernel
import RealtimeConnection

/// A model Codex lists for this ChatGPT account.
public struct CodexModel: Equatable, Identifiable {
    public let slug: String
    public let name: String
    /// Codex's own ordering: a lower number is listed first, so the last model is the lightest.
    public let priority: Int
    public let efforts: [String]
    public let defaultEffort: String?
    public var id: String { slug }
    public init(slug: String, name: String, priority: Int, efforts: [String], defaultEffort: String?) {
        self.slug = slug
        self.name = name
        self.priority = priority
        self.efforts = efforts
        self.defaultEffort = defaultEffort
    }
    /// Low reasoning, which these short, simple requests need; the model's own default when it has no low setting.
    public var lightestEffort: String? { efforts.contains("low") ? "low" : defaultEffort }
    /// The effort a request uses: the user's choice while this model supports it, otherwise the lightest.
    public func effort(selected: String?) -> String? {
        if let selected, efforts.contains(selected) { return selected }
        return lightestEffort
    }
    /// The model a request uses: the one the user chose while Codex still lists it, otherwise the lightest listed.
    public static func resolve(selected: String?, in models: [CodexModel]) -> CodexModel? {
        if let selected, let match = models.first(where: { $0.slug == selected }) { return match }
        return models.max { $0.priority < $1.priority }
    }
}

/// What this Mac knows about Codex: whether it is signed in with ChatGPT, and the models it lists.
public struct CodexStatus: Equatable {
    /// Why Codex cannot be used, in words the user can act on; nil when it is signed in.
    public var signInProblem: String?
    public var models: [CodexModel]
    public init(signInProblem: String? = nil, models: [CodexModel] = []) {
        self.signInProblem = signInProblem
        self.models = models
    }
}

public enum CodexCatalog {
    static let maximumCacheSize = 4_000_000

    /// Asks Codex on this Mac for its ChatGPT sign-in and reads Codex's model list. Nothing of the user's is sent;
    /// Codex may renew a sign-in that is about to expire. Throws only `CancellationError`: a cancelled check found out
    /// nothing about the sign-in.
    public static func status() async throws -> CodexStatus {
        try await status(
            signIn: CodexSignIn.shared, environment: ProcessInfo.processInfo.environment,
            home: FileManager.default.homeDirectoryForCurrentUser)
    }
    static func status(signIn: any CredentialSource, environment: [String: String], home: URL) async throws
        -> CodexStatus
    {
        do { _ = try await signIn.token() } catch {
            let failure = CodexSignIn.failure(error)
            if failure is CancellationError { throw failure }
            return CodexStatus(signInProblem: (failure as? AppFailure)?.message ?? failure.localizedDescription)
        }
        guard let folder = codexFolder(environment: environment, home: home) else { return CodexStatus() }
        return CodexStatus(models: models(in: folder.appendingPathComponent("models_cache.json")))
    }
    /// Codex's folder: `CODEX_HOME` only when it resolves to a folder the user owns inside their home folder, as the
    /// sign-in is confined; nil for any other.
    static func codexFolder(environment: [String: String], home: URL) -> URL? {
        guard let value = environment["CODEX_HOME"], !value.isEmpty else {
            return home.appendingPathComponent(".codex")
        }
        let folder = URL(fileURLWithPath: value).standardizedFileURL.resolvingSymlinksInPath()
        let homePath = home.standardizedFileURL.resolvingSymlinksInPath().path
        var info = stat()
        guard folder.path.hasPrefix(homePath + "/"), lstat(folder.path, &info) == 0,
            info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid()
        else { return nil }
        return folder
    }
    /// The models Codex shows in its picker, in its order; an unreadable or unrecognised cache lists none.
    static func models(in file: URL) -> [CodexModel] {
        guard let data = ownedFileData(file, limit: maximumCacheSize),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let entries = object["models"] as? [[String: Any]]
        else { return [] }
        return entries.compactMap { entry -> CodexModel? in
            guard entry["visibility"] as? String == "list", let slug = entry["slug"] as? String, !slug.isEmpty
            else { return nil }
            let levels = (entry["supported_reasoning_levels"] as? [[String: Any]] ?? []).compactMap {
                $0["effort"] as? String
            }
            return CodexModel(
                slug: slug, name: entry["display_name"] as? String ?? slug,
                priority: (entry["priority"] as? NSNumber)?.intValue ?? Int.max, efforts: levels,
                defaultEffort: entry["default_reasoning_level"] as? String)
        }.sorted { $0.priority < $1.priority }
    }
    /// The contents of a regular file the user owns, smaller than `limit`, opened once without following symlinks and
    /// checked and read through that descriptor, so it cannot be swapped or grown in between; nil for any other.
    static func ownedFileData(_ file: URL, limit: Int) -> Data? {
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
            info.st_size < limit
        else { return nil }
        var buffer = [UInt8](repeating: 0, count: limit)
        var count = 0
        while count < limit {
            let chunk = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress! + count, limit - count)
            }
            if chunk == 0 { break }
            if chunk < 0 {
                if errno == EINTR { continue }
                return nil
            }
            count += chunk
        }
        guard count < limit else { return nil }
        return Data(buffer[..<count])
    }
}
