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
        let status = await CodexCatalog.status(environment: [:], home: try home(cache: cache), now: Date())
        XCTAssertNil(status.signInProblem)
        XCTAssertEqual(status.models.map(\.slug), ["big", "mid", "small"])
        XCTAssertEqual(status.models.map(\.name), ["Big", "mid", "Small"])
    }

    func testLowEffortIsUsedWhenSupportedOtherwiseTheModelsDefault() async throws {
        let models = await CodexCatalog.status(environment: [:], home: try home(cache: cache), now: Date()).models
        XCTAssertEqual(models.first { $0.slug == "big" }?.lightestEffort, "low")
        XCTAssertEqual(models.first { $0.slug == "small" }?.lightestEffort, "medium")
    }

    func testAChosenEffortIsUsedOnlyWhileTheModelSupportsIt() async throws {
        let models = await CodexCatalog.status(environment: [:], home: try home(cache: cache), now: Date()).models
        let big = try XCTUnwrap(models.first { $0.slug == "big" })
        XCTAssertEqual(big.effort(selected: "high"), "high")
        XCTAssertEqual(big.effort(selected: "ultra"), "low")
        XCTAssertEqual(big.effort(selected: nil), "low")
    }

    func testTheChosenModelIsUsedWhileListedOtherwiseTheLightest() async throws {
        let models = await CodexCatalog.status(environment: [:], home: try home(cache: cache), now: Date()).models
        XCTAssertEqual(CodexModel.resolve(selected: "mid", in: models)?.slug, "mid")
        XCTAssertEqual(CodexModel.resolve(selected: nil, in: models)?.slug, "small")
        XCTAssertEqual(CodexModel.resolve(selected: "retired", in: models)?.slug, "small")
        XCTAssertNil(CodexModel.resolve(selected: "mid", in: []))
    }

    func testAMissingOrUnreadableCacheListsNothingButStaysSignedIn() async throws {
        for content in [nil, "not json", #"{"models":"x"}"#, String(repeating: "x", count: 5_000_000)] {
            let status = await CodexCatalog.status(
                environment: [:], home: try home(cache: content), now: Date())
            XCTAssertNil(status.signInProblem)
            XCTAssertEqual(status.models, [])
        }
    }

    func testNoSignInReportsTheProblemAndNoModels() async throws {
        let status = await CodexCatalog.status(
            environment: [:], home: try home(auth: nil, cache: cache), now: Date())
        XCTAssertEqual(status.signInProblem, Credentials.SignIn.missing.failure.message)
        XCTAssertEqual(status.models, [])
    }
}
