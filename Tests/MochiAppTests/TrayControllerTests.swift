import AppKit
import Darwin
import XCTest

@testable import MochiApp

private final class RecordingDelegate: NSObject, NSWindowDelegate {}

final class TrayControllerTests: XCTestCase {
    @MainActor func testReplacedWindowGetsItsOwnDelegateBack() {
        let app = makeApp(demo: true)
        let tray = TrayController()
        let original = RecordingDelegate()
        let first = window()
        first.delegate = original
        tray.attach(first, model: app)
        XCTAssertTrue(first.delegate === tray)
        let second = window()
        tray.attach(second, model: app)
        XCTAssertTrue(first.delegate === original)
        XCTAssertTrue(second.delegate === tray)
        XCTAssertTrue(tray.window === second)
        // A window the tray no longer manages closes normally rather than being hidden on the new window's behalf.
        XCTAssertTrue(tray.windowShouldClose(first))
    }

    /// A launch that restores a session which ended with the window hidden in the menu bar creates no window at all.
    /// The tray then has SwiftUI open it, as soon as SwiftUI provides the action, and leaves an existing window alone.
    @MainActor func testAWindowNeverOpenedIsOpenedThroughSwiftUI() {
        let tray = TrayController()
        var opened = 0
        XCTAssertFalse(tray.openWorkspaceIfUnopened(), "Without SwiftUI's action there is nothing to open it with yet")
        tray.openWorkspace = { opened += 1 }
        XCTAssertEqual(opened, 1, "The waiting request opens the window once the action arrives")
        tray.openWorkspace = { opened += 1 }
        XCTAssertEqual(opened, 1, "SwiftUI provides the action again with every menu update; one request opens once")
        XCTAssertTrue(tray.openWorkspaceIfUnopened())
        XCTAssertEqual(opened, 2)
        tray.attach(window(), model: makeApp(demo: true))
        XCTAssertFalse(tray.openWorkspaceIfUnopened())
        XCTAssertEqual(opened, 2)
    }

    /// Launches never restore the last session's windows, so one that ended hidden in the menu bar cannot leave the
    /// next launch without a window.
    @MainActor func testLaunchesIgnoreRestoredWindows() {
        MochiApp.ignoreRestoredWindows()
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "ApplePersistenceIgnoreState"))
    }

    /// The menu bar menu is the shared one, filled again as it opens.
    @MainActor func testMenuIsTheSharedMenuFilledAsItOpens() {
        let app = makeApp(demo: true)
        let tray = TrayController()
        tray.follow(app)
        let menu = NSMenu()
        tray.menuNeedsUpdate(menu)
        XCTAssertEqual(menu.items.first?.title, app.status)
        XCTAssertNotNil(menu.items.first { $0.title == "Settings…" })
        XCTAssertNotNil(menu.items.first { $0.title == "New Conversation" })
        XCTAssertEqual(menu.items.last?.title, "Quit Mochi Completely")
        XCTAssertEqual(menu.items.last?.keyEquivalent, "")
        app.petVisible = true
        defer { app.petVisible = false }
        tray.menuNeedsUpdate(menu)
        XCTAssertNotNil(menu.items.first { $0.title == "Hide Desktop Mochi" })
    }

    /// The icon's tooltip follows the error, or else the status, as they change.
    @MainActor func testStatusDescriptionFollowsTheModel() async {
        let app = makeApp(demo: true)
        let tray = TrayController()
        tray.follow(app)
        XCTAssertEqual(tray.statusDescription, app.status)
        app.error = "Mochi couldn’t reach the voice service."
        await waitUntil { tray.statusDescription == "Mochi couldn’t reach the voice service." }
        app.error = nil
        app.resume()
        await waitUntil { tray.statusDescription == app.status }
        XCTAssertEqual(tray.statusDescription, app.status, "The watch re-arms after each change")
    }

    @MainActor func testFinishingWorkReportsAFailedSave() {
        let root = makeTemporaryFolder()
        let app = makeApp(root: root)
        defer { chmod(root.path, 0o700) }
        XCTAssertTrue(app.libraryReadable)
        XCTAssertTrue(TrayController.finishWork(app))
        XCTAssertEqual(chmod(root.path, 0o500), 0)
        app.draft = "Unsaved words"
        XCTAssertFalse(TrayController.finishWork(app))
        XCTAssertNotNil(app.error)
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        XCTAssertTrue(TrayController.finishWork(app))
    }

    @MainActor private func window() -> NSWindow {
        _ = NSApplication.shared
        return NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered,
            defer: true)
    }
}
