import Foundation
import MochiKernel

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

    /// Checks the sign-in file and reads Codex's model list. Both are local files: nothing is sent.
    public static func status() async -> CodexStatus {
        await status(
            environment: ProcessInfo.processInfo.environment, home: FileManager.default.homeDirectoryForCurrentUser,
            now: Date())
    }
    static func status(environment: [String: String], home: URL, now: Date) async -> CodexStatus {
        do {
            _ = try await Credentials.codexSignIn(environment: environment, home: home, now: now)
        } catch {
            return CodexStatus(signInProblem: (error as? AppFailure)?.message ?? error.localizedDescription)
        }
        guard let folder = try? Credentials.codexFolder(environment: environment, home: home) else {
            return CodexStatus()
        }
        return CodexStatus(models: models(in: folder.appendingPathComponent("models_cache.json")))
    }
    /// The models Codex shows in its picker, in its order; an unreadable or unrecognised cache lists none.
    static func models(in file: URL) -> [CodexModel] {
        guard let data = try? Credentials.ownedFileData(file, limit: maximumCacheSize),
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
}
