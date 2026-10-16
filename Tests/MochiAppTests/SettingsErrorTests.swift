import XCTest

@testable import MochiApp

/// An error shows in the Settings tab whose action caused it, and in no other tab.
@MainActor final class SettingsErrorTests: XCTestCase {
    private struct Offline: Error {}

    func testAFailedConnectionCheckBelongsToTheGeneralTab() async {
        let app = makeApp(root: makeTemporaryFolder())
        app.speech.textReply = { _, _ in throw Offline() }
        app.checkConnection()
        await waitUntil { !app.busy && app.error != nil }
        XCTAssertEqual(app.errorTab, .general)
        XCTAssertEqual(app.serviceStatus, "Not connected")
    }

    func testAFailedBackupExportBelongsToTheDataAndPrivacyTab() async throws {
        let app = makeApp(root: makeTemporaryFolder())
        // A backup is a new package; an existing one at the chosen place is never overwritten.
        let taken = makeTemporaryFolder().appendingPathComponent("Taken.mochibackup")
        try FileManager.default.createDirectory(at: taken, withIntermediateDirectories: true)
        await app.exportLibraryBackup(to: taken)?.value
        XCTAssertNotNil(app.error)
        XCTAssertEqual(app.errorTab, .privacy)
    }

    func testAnErrorFromOutsideSettingsBelongsToNoTab() {
        let app = makeApp(root: makeTemporaryFolder())
        app.report("Earlier", in: .voices)
        // A later error from the conversation replaces the Settings one and must not inherit its tab.
        app.error = "The microphone is unavailable."
        XCTAssertNil(app.errorTab)
        app.report("Again", in: .privacy)
        app.error = nil
        XCTAssertNil(app.errorTab)
    }
}

extension SettingsErrorTests {
    func testAPreviewThatCannotPlayBelongsToTheVoicesTab() async {
        let app = makeApp(root: makeTemporaryFolder())
        app.audio.makePlayer = { _ in throw Offline() }
        let fixture = fixtureURL("reference.mp3")
        app.speech.referenceAudio = { _, _, _, root, _ in
            let url = root.appendingPathComponent("preview-test.mp3")
            try FileManager.default.copyItem(at: fixture, to: url)
            return url
        }
        app.previewBuiltIn("cedar")
        await waitUntil { !app.busy && app.error != nil }
        XCTAssertEqual(app.errorTab, .voices)
    }
}
