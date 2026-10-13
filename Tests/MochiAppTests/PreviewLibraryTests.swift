import MochiCore
import MochiTestSupport
import XCTest

@testable import MochiApp

final class PreviewLibraryTests: XCTestCase {
    @MainActor func testPreviewLibraryIsDiscardedOnQuit() async {
        let app = AppModel(
            demo: true, libraryRoot: nil, preferences: makePreferences(), speech: .unexpected, media: .silent,
            recognition: .absent, applicationSupport: nil)
        let root = app.store.root
        XCTAssertTrue(root.lastPathComponent.hasPrefix("mochi-preview-"))
        await waitUntil { FileManager.default.fileExists(atPath: root.path) }
        app.discardTemporaryLibrary()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
    @MainActor func testSuppliedLibraryIsNeverDiscarded() async {
        let root = TestScratch.folder("supplied-library")
        let app = makeApp(demo: true, root: root)
        await waitUntil { FileManager.default.fileExists(atPath: root.path) }
        app.discardTemporaryLibrary()
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }
}
