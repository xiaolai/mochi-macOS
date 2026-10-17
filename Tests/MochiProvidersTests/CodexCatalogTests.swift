import CodexAuth
import MochiKernel
import MochiTestSupport
import XCTest

@testable import MochiProviders

final class CodexCatalogTests: XCTestCase {
    private func home(auth: String? = #"{"tokens":{"access_token":"opaque","account_id":"acct"}}"#, cache: String?)
        throws -> URL
    {
        let url = TestScratch.folder("mochi-home")
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        if let auth { try Data(auth.utf8).write(to: url.appendingPathComponent(".codex/auth.json")) }
        if let cache { try Data(cache.utf8).write(to: url.appendingPathComponent(".codex/models_cache.json")) }
        return url
    }

    /// The catalog with Codex's file source reading `home`: the shared package's own sign-in, never the real one.
    private func status(_ home: URL) async throws -> CodexStatus {
        let signIn = try Credentials(
            CodexAuthConfiguration(margin: 600, timeout: 5, source: .file, home: home.path, environment: [:]))
        return try await CodexCatalog.status(signIn: signIn, environment: [:], home: home)
    }

    private let cache = """
        {"models":[
          {"slug":"big","display_name":"Big","visibility":"list","priority":1,"default_reasoning_level":"medium",
           "supported_reasoning_levels":[{"effort":"low"},{"effort":"high"}]},
          {"slug":"hidden","display_name":"Hidden","visibility":"hide","priority":99},
          {"slug":"small","display_name":"Small","visibility":"list","priority":9,"default_reasoning_level":"medium",
           "supported_reasoning_levels":[{"effort":"medium"},{"effort":"high"}]},
          {"slug":"mid","visibility":"list","priority":4,"supported_reasoning_levels":[{"effort":"low"}]}
        ]}
        """

    func testListedModelsAreReadInCodexOrderAndHiddenOnesAreLeftOut() async throws {
        let status = try await status(home(cache: cache))
        XCTAssertNil(status.signInProblem)
        XCTAssertEqual(status.models.map(\.slug), ["big", "mid", "small"])
        XCTAssertEqual(status.models.map(\.name), ["Big", "mid", "Small"])
    }

    func testLowEffortIsUsedWhenSupportedOtherwiseTheModelsDefault() async throws {
        let models = try await status(home(cache: cache)).models
        XCTAssertEqual(models.first { $0.slug == "big" }?.lightestEffort, "low")
        XCTAssertEqual(models.first { $0.slug == "small" }?.lightestEffort, "medium")
    }

    func testAChosenEffortIsUsedOnlyWhileTheModelSupportsIt() async throws {
        let models = try await status(home(cache: cache)).models
        let big = try XCTUnwrap(models.first { $0.slug == "big" })
        XCTAssertEqual(big.effort(selected: "high"), "high")
        XCTAssertEqual(big.effort(selected: "ultra"), "low")
        XCTAssertEqual(big.effort(selected: nil), "low")
    }

    func testTheChosenModelIsUsedWhileListedOtherwiseTheLightest() async throws {
        let models = try await status(home(cache: cache)).models
        XCTAssertEqual(CodexModel.resolve(selected: "mid", in: models)?.slug, "mid")
        XCTAssertEqual(CodexModel.resolve(selected: nil, in: models)?.slug, "small")
        XCTAssertEqual(CodexModel.resolve(selected: "retired", in: models)?.slug, "small")
        XCTAssertNil(CodexModel.resolve(selected: "mid", in: []))
    }

    func testAMissingOrUnreadableCacheListsNothingButStaysSignedIn() async throws {
        for content in [nil, "not json", #"{"models":"x"}"#, String(repeating: "x", count: 5_000_000)] {
            let status = try await status(home(cache: content))
            XCTAssertNil(status.signInProblem)
            XCTAssertEqual(status.models, [])
        }
    }

    /// A check cancelled while Codex was asked for the sign-in found out nothing, so it reports no sign-in problem.
    func testACancelledCheckIsACancellationNotASignInProblem() async throws {
        do {
            let status = try await CodexCatalog.status(
                signIn: CancelledSignIn(), environment: [:], home: home(cache: cache))
            XCTFail("A cancelled check reported \(status)")
        } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
    }

    func testNoSignInReportsTheProblemAndNoModels() async throws {
        let status = try await status(home(auth: nil, cache: cache))
        XCTAssertEqual(status.signInProblem, CodexSignIn.failure(.noSignInFile).message)
        XCTAssertEqual(status.models, [])
    }
}
