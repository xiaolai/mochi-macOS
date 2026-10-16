import AppKit
import MochiCore
import MochiProviders
import MochiTestSupport
import XCTest

@testable import MochiApp

final class DesktopPetTests: XCTestCase {
    func testPoseMirrorsTheConversation() {
        func pose(_ change: (inout PetSituation) -> Void) -> PetPose {
            var situation = PetSituation()
            change(&situation)
            return situation.pose
        }
        XCTAssertEqual(pose { _ in }, .idle)
        XCTAssertEqual(pose { $0.activity = .recording }, .review)
        XCTAssertEqual(pose { $0.activity = .requestingPermission }, .waiting)
        XCTAssertEqual(pose { $0.activity = .generating }, .running)
        XCTAssertEqual(
            pose {
                $0.activity = .generating
                $0.greeting = true
            }, .waving)
        XCTAssertEqual(
            pose {
                $0.activity = .playing
                $0.speaking = true
            }, .jumping)
        XCTAssertEqual(pose { $0.activity = .playing }, .review, "Playing the user's own recording")
        XCTAssertEqual(
            pose {
                $0.activity = .playing
                $0.speaking = true
                $0.paused = true
            }, .idle)
        XCTAssertEqual(pose { $0.failing = true }, .failed)
        XCTAssertEqual(pose { $0.arriving = true }, .waving)
        // Work in progress outranks a recent failure: she shows what is happening now.
        XCTAssertEqual(
            pose {
                $0.activity = .recording
                $0.failing = true
            }, .review)
    }

    func testFramesFollowTheAtlasTimings() {
        XCTAssertEqual(PetPose.idle.durations.count, 6)
        XCTAssertEqual(PetPose.idle.cycle, 1.1, accuracy: 0.0001)
        XCTAssertEqual(PetPose.idle.frame(at: 0), 0)
        XCTAssertEqual(PetPose.idle.frame(at: 0.279), 0)
        XCTAssertEqual(PetPose.idle.frame(at: 0.281), 1)
        XCTAssertEqual(PetPose.idle.frame(at: 1.09), 5)
        XCTAssertEqual(PetPose.idle.frame(at: 1.1 + 0.3), 1, "The loop repeats")
        XCTAssertEqual(PetPose.idle.frame(at: .nan), 0)
        XCTAssertEqual(PetPose.idle.frame(at: -1), 0)
        XCTAssertEqual(PetPose.waving.durations, [0.14, 0.14, 0.14, 0.28])
        XCTAssertEqual(PetPose.failed.durations.count, 8)
        XCTAssertEqual(PetPose.jumping.durations.count, 5)
    }

    func testGazeTurnsClockwiseFromUpAndFacesForwardNearby() {
        XCTAssertNil(PetGaze.cell(dx: 10, dy: 10))
        XCTAssertNil(PetGaze.cell(dx: .nan, dy: 500))
        XCTAssertTrue(PetGaze.cell(dx: 0, dy: 500)! == (9, 0), "Up")
        XCTAssertTrue(PetGaze.cell(dx: 500, dy: 500)! == (9, 2), "Up and right")
        XCTAssertTrue(PetGaze.cell(dx: 500, dy: 0)! == (9, 4), "Right")
        XCTAssertTrue(PetGaze.cell(dx: 0, dy: -500)! == (10, 0), "Down")
        XCTAssertTrue(PetGaze.cell(dx: -500, dy: 0)! == (10, 4), "Left")
        XCTAssertTrue(PetGaze.cell(dx: -10, dy: 500)! == (9, 0), "Just left of up rounds to up, not to 16")
    }

    func testBundledSpriteHasEveryPoseAndABodyToClick() {
        let sprite = PetSprite.shared
        XCTAssertTrue(sprite.isLoaded)
        for pose in PetPose.allCases {
            XCTAssertEqual(sprite.frames(pose).count, pose.durations.count, "\(pose)")
        }
        for column in 0..<8 {
            XCTAssertNotNil(sprite.cell(row: 9, column: column))
            XCTAssertNotNil(sprite.cell(row: 10, column: column))
        }
        XCTAssertNil(sprite.cell(row: 0, column: 8))
        XCTAssertNil(sprite.cell(row: 11, column: 0))
        XCTAssertEqual(sprite.frames(.idle).first?.width, 192)
        let body = PetSprite.BodyMask(sprite)
        XCTAssertFalse(body.isEmpty)
        XCTAssertTrue(body.contains(x: 0.5, y: 0.3), "Her middle")
        XCTAssertFalse(body.contains(x: 0.02, y: 0.98), "The empty corner above her")
        XCTAssertFalse(body.contains(x: 1, y: 0.5))
        XCTAssertFalse(body.contains(x: .nan, y: 0.5))
    }

    func testASheetThatIsNotAFullAtlasIsNotUsed() throws {
        let folder = makeTemporaryFolder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("small.png")
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 192, pixelsHigh: 208, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        let sprite = PetSprite(resource: url)
        XCTAssertFalse(sprite.isLoaded, "One cell is not an 8 by 11 atlas")
        XCTAssertNil(sprite.cell(row: 0, column: 0))
    }

    func testMissingSpriteDrawsNothingAndTakesNoClicks() {
        let sprite = PetSprite(resource: nil)
        XCTAssertFalse(sprite.isLoaded)
        XCTAssertTrue(sprite.frames(.idle).isEmpty)
        XCTAssertFalse(PetSprite.BodyMask(sprite).contains(x: 0.5, y: 0.3))
    }

    @MainActor func testPlacementKeepsHerWhollyOnAScreen() {
        let main = CGRect(x: 0, y: 25, width: 1440, height: 875)
        let side = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let size = DesktopPet.size
        let corner = CGPoint(x: main.maxX - size.width - DesktopPet.margin, y: main.minY + DesktopPet.margin)
        XCTAssertEqual(DesktopPet.origin(stored: nil, screens: [main, side]), corner)
        XCTAssertEqual(DesktopPet.origin(stored: CGPoint(x: 200, y: 300), screens: [main]), CGPoint(x: 200, y: 300))
        XCTAssertEqual(
            DesktopPet.origin(stored: CGPoint(x: 2000, y: 500), screens: [main, side]), CGPoint(x: 2000, y: 500))
        // Half over the bottom edge: pulled up onto the screen that holds her centre.
        XCTAssertEqual(
            DesktopPet.origin(stored: CGPoint(x: 300, y: 25 - 40), screens: [main]), CGPoint(x: 300, y: 25))
        // A disconnected display's spot falls back to the corner of the remaining screen.
        XCTAssertEqual(DesktopPet.origin(stored: CGPoint(x: 2000, y: 500), screens: [main]), corner)
        XCTAssertEqual(DesktopPet.origin(stored: CGPoint(x: CGFloat.infinity, y: 0), screens: [main]), corner)
    }

    @MainActor func testPanelMirrorsTheTurnAndStaysOutOfTheWay() throws {
        _ = NSApplication.shared
        let app = makeApp(demo: true)
        let pet = DesktopPet()
        pet.attach(app)
        defer { app.petVisible = false }
        XCTAssertNil(pet.panel, "Hidden until asked for")
        app.petVisible = true
        let panel = try XCTUnwrap(pet.panel)
        XCTAssertTrue(panel.isVisible)
        XCTAssertFalse(panel.canHide, "Closing the workspace to the tray hides the app; she stays")
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertEqual(panel.frame.size, DesktopPet.size)
        let now = pet.arrived
        pet.tick(now)
        XCTAssertEqual(pet.currentPose, .waving, "She greets when she appears")
        pet.tick(now.addingTimeInterval(5))
        XCTAssertEqual(pet.currentPose, .idle)
        app.turn.begin(.recording)
        pet.tick(now.addingTimeInterval(5.1))
        XCTAssertEqual(pet.currentPose, .review)
        app.turn.begin(.generating)
        pet.tick(now.addingTimeInterval(5.2))
        XCTAssertEqual(pet.currentPose, .running)
        app.turn.stop()
        app.error = "Something went wrong."
        pet.tick(now.addingTimeInterval(5.3))
        XCTAssertEqual(pet.currentPose, .failed)
        pet.tick(now.addingTimeInterval(5.3 + PetPose.failed.cycle * 2 + 0.1))
        XCTAssertEqual(pet.currentPose, .idle, "A failure shows briefly, not for as long as its message stays")
        XCTAssertEqual(panel.contentView?.toolTip, "Something went wrong.")
        app.petVisible = false
        XCTAssertFalse(panel.isVisible)
    }

    @MainActor func testSheBreathesOnlyWhileIdleAndNeverWithReducedMotion() throws {
        _ = NSApplication.shared
        let app = makeApp(demo: true)
        let pet = DesktopPet()
        var reduced = false
        pet.reducesMotion = { reduced }
        pet.attach(app)
        defer { app.petVisible = false }
        app.petVisible = true
        let view = try XCTUnwrap(pet.panel?.contentView as? PetView)
        let idle = pet.arrived.addingTimeInterval(PetPose.waving.cycle + 0.1)
        pet.tick(pet.arrived)
        XCTAssertFalse(view.breathing, "Not while she waves hello")
        pet.tick(idle)
        XCTAssertEqual(pet.currentPose, .idle)
        XCTAssertTrue(view.breathing)
        app.turn.begin(.recording)
        pet.tick(idle.addingTimeInterval(0.1))
        XCTAssertFalse(view.breathing, "Listening has its own animation")
        app.turn.stop()
        pet.tick(idle.addingTimeInterval(0.2))
        XCTAssertTrue(view.breathing)
        let cell = try XCTUnwrap(view.layer?.sublayers?.first)
        XCTAssertNotNil(cell.animation(forKey: "breath"), "The breath is on the layer she is drawn in")
        XCTAssertEqual(cell.anchorPoint, CGPoint(x: 0.5, y: 0), "She breathes from her feet")
        reduced = true
        pet.tick(idle.addingTimeInterval(0.3))
        XCTAssertFalse(view.breathing, "Reduce Motion stops it at once")
        XCTAssertNil(cell.animation(forKey: "breath"))
    }

    @MainActor func testHerEyesFollowThePointerOnlyWhenThatIsOn() throws {
        _ = NSApplication.shared
        let preferences = makePreferences()
        let app = makeApp(demo: true, preferences: preferences)
        XCTAssertFalse(app.settings.petFollowsPointer, "Off by default")
        let pet = DesktopPet()
        pet.attach(app)
        defer { app.petVisible = false }
        app.petVisible = true
        let panel = try XCTUnwrap(pet.panel)
        // Far from the pointer, so any glance would leave the forward-facing idle row.
        let screen = try XCTUnwrap(DesktopPet.screens.first)
        let mouse = NSEvent.mouseLocation
        pet.moved(to: CGPoint(x: mouse.x < screen.midX ? screen.maxX : screen.minX, y: screen.midY))
        XCTAssertGreaterThan(hypot(mouse.x - panel.frame.midX, mouse.y - panel.frame.midY), PetGaze.deadzone)
        // Her first tick saw the pointer as new; this one is after her wave and within the time a glance lasts.
        let soon = pet.arrived.addingTimeInterval(PetPose.waving.cycle + 0.1)
        XCTAssertLessThan(soon.timeIntervalSince(pet.arrived), DesktopPet.gazeLinger)
        pet.tick(soon)
        XCTAssertEqual(pet.currentPose, .idle)
        XCTAssertEqual(pet.currentFrame.row, PetPose.idle.rawValue, "Off: she keeps facing forward")
        app.settings.petFollowsPointer = true
        pet.tick(soon.addingTimeInterval(0.05))
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            XCTAssertGreaterThanOrEqual(pet.currentFrame.row, 9, "On: she glances at the pointer")
        }
        XCTAssertTrue(
            PreferencesStore(preferences, importLegacy: false, allowExternalControl: false).petFollowsPointer)
    }

    @MainActor func testMovingHerIsRemembered() throws {
        _ = NSApplication.shared
        let preferences = makePreferences()
        let app = makeApp(demo: true, preferences: preferences)
        let pet = DesktopPet()
        pet.attach(app)
        defer { app.petVisible = false }
        app.petVisible = true
        let screen = try XCTUnwrap(DesktopPet.screens.first)
        let spot = CGPoint(x: screen.minX + 40, y: screen.minY + 60)
        pet.moved(to: spot)
        XCTAssertEqual(pet.panel?.frame.origin, spot)
        XCTAssertEqual(app.settings.petOrigin, spot)
        let reopened = PreferencesStore(preferences, importLegacy: false, allowExternalControl: false)
        XCTAssertEqual(reopened.petOrigin, spot)
        XCTAssertTrue(reopened.petVisible)
    }

    /// Her context menu is the shared one, with her own settings item; MochiMenuTests covers its states.
    @MainActor func testMenuOffersTalkOpenSettingsAndHide() {
        let app = makeApp(demo: true)
        var revealed = 0
        app.revealWorkspace = { revealed += 1 }
        let pet = DesktopPet()
        pet.attach(app)
        app.petVisible = true
        defer { app.petVisible = false }
        // The preview conversation is in practice, where a click opens the workspace instead of talking.
        XCTAssertTrue(app.practice)
        XCTAssertEqual(
            pet.menu().items.map(\.title),
            [
                app.status, "", app.listeningMenuTitle, "New Conversation", "", "Open Mochi",
                "Desktop Mochi Settings…", "", "Hide Desktop Mochi", "Hide Message Bar", "", "Quit Mochi Completely",
            ])
        app.resume()
        XCTAssertEqual(app.quickTalkPlan, .microphone)
        XCTAssertEqual(pet.menu().items[2].title, app.microphoneLabel)
        app.turn.begin(.generating)
        XCTAssertEqual(pet.menu().items[2].title, app.listeningMenuTitle, "Nothing to say while she prepares a reply")
        app.turn.stop()
        let menu = pet.menu()
        menu.performActionForItem(at: menu.indexOfItem(withTitle: "Desktop Mochi Settings…"))
        XCTAssertEqual(revealed, 1)
        XCTAssertTrue(app.settingsOpen)
        XCTAssertEqual(app.settingsTab, .desktopMochi)
        menu.performActionForItem(at: menu.indexOfItem(withTitle: "Hide Message Bar"))
        XCTAssertFalse(app.petBarVisible)
        let shown = pet.menu()
        shown.performActionForItem(at: shown.indexOfItem(withTitle: "Show Message Bar"))
        XCTAssertTrue(app.petBarVisible)
        let hidden = pet.menu()
        hidden.performActionForItem(at: hidden.indexOfItem(withTitle: "Hide Desktop Mochi"))
        XCTAssertFalse(app.petVisible)
    }

    // MARK: Message bar

    @MainActor func testBarHangsCentredUnderHerAndStaysOnHerScreen() {
        let screen = CGRect(x: 0, y: 25, width: 1440, height: 875)
        let pet = CGRect(origin: CGPoint(x: 600, y: 300), size: DesktopPet.size)
        let pill = PetBar.frame(below: pet, width: PetBar.pillWidth, screen: screen)
        XCTAssertEqual(pill.midX, pet.midX)
        XCTAssertEqual(pill.maxY, pet.minY - PetBar.gap)
        XCTAssertEqual(pill.height, PetBar.height)
        // Wider than her: near the right edge, the field moves left rather than off the screen.
        let corner = CGRect(origin: CGPoint(x: screen.maxX - DesktopPet.size.width, y: 300), size: DesktopPet.size)
        let field = PetBar.frame(below: corner, width: PetBar.fieldWidth, screen: screen)
        XCTAssertEqual(field.maxX, screen.maxX)
        XCTAssertEqual(field.width, PetBar.fieldWidth)
        XCTAssertEqual(PetBar.frame(below: pet, width: 100, screen: nil).midX, pet.midX)
    }

    @MainActor func testPlacementLeavesRoomForTheBar() {
        let main = CGRect(x: 0, y: 25, width: 1440, height: 875)
        let size = DesktopPet.size
        XCTAssertEqual(
            DesktopPet.origin(stored: nil, screens: [main], below: PetBar.reserve),
            CGPoint(x: main.maxX - size.width - DesktopPet.margin, y: main.minY + DesktopPet.margin + PetBar.reserve))
        XCTAssertEqual(
            DesktopPet.origin(stored: CGPoint(x: 300, y: 30), screens: [main], below: PetBar.reserve),
            CGPoint(x: 300, y: main.minY + PetBar.reserve), "Pulled up so the bar stays on the screen")
    }

    @MainActor func testBarFollowsItsPreferenceAndTakesTheKeyboardOnlyWhenOpen() throws {
        _ = NSApplication.shared
        let preferences = makePreferences()
        let app = makeApp(demo: true, preferences: preferences)
        XCTAssertTrue(app.petBarVisible, "On by default")
        let pet = DesktopPet()
        pet.attach(app)
        defer { app.petVisible = false }
        app.petVisible = true
        let panel = try XCTUnwrap(pet.panel)
        let bar = try XCTUnwrap(pet.bar)
        XCTAssertTrue(bar.panel.isVisible)
        XCTAssertTrue(bar.panel.parent === panel, "It moves with her")
        XCTAssertTrue(bar.panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(bar.panel.canHide)
        XCTAssertFalse(bar.panel.canBecomeKey, "A click on the pill leaves the app you are in active")
        XCTAssertEqual(bar.panel.frame.width, PetBar.pillWidth)
        XCTAssertGreaterThanOrEqual(panel.frame.minY, (DesktopPet.screens.first?.minY ?? 0) + PetBar.reserve)
        // Opened without taking the keyboard: this runs on a Mac in use. The smoke run opens it for real.
        bar.state.expanded = true
        bar.layout()
        XCTAssertTrue(bar.panel.canBecomeKey, "The open field takes typing")
        XCTAssertEqual(bar.panel.frame.width, PetBar.fieldWidth)
        bar.state.text = "Half a thought"
        bar.close()
        XCTAssertFalse(bar.state.expanded)
        XCTAssertFalse(bar.panel.canBecomeKey)
        XCTAssertEqual(bar.state.text, "Half a thought", "Putting the field away keeps what was typed")
        XCTAssertTrue(bar.panel.isVisible)
        XCTAssertTrue(bar.panel.parent === panel)
        // Moving her carries the bar along.
        let screen = try XCTUnwrap(DesktopPet.screens.first)
        pet.moved(to: CGPoint(x: screen.midX, y: screen.midY))
        XCTAssertEqual(bar.panel.frame.midX, panel.frame.midX)
        XCTAssertEqual(bar.panel.frame.maxY, panel.frame.minY - PetBar.gap)
        app.petBarVisible = false
        XCTAssertFalse(bar.panel.isVisible)
        XCTAssertNil(bar.panel.parent)
        XCTAssertFalse(
            PreferencesStore(preferences, importLegacy: false, allowExternalControl: false).petBarVisible)
        app.petBarVisible = true
        XCTAssertTrue(bar.panel.isVisible)
        app.petVisible = false
        XCTAssertFalse(bar.panel.isVisible, "It leaves with her")
        XCTAssertFalse(panel.isVisible)
    }
}

final class DesktopMessageTests: XCTestCase {
    @MainActor private func app() -> AppModel {
        let app = makeApp(root: makeTemporaryFolder("mochi-desktop-message"))
        addTeardownBlock { @MainActor in app.stop() }
        return app
    }

    @MainActor func testTypedTextGoesToTheOpenConversationAndTheComposerKeepsItsDraft() async {
        let app = app()
        var requests: [ConversationRequest] = []
        app.speech.conversationReply = { _, request, callbacks in
            requests.append(request)
            var reply = RealtimeAccumulator()
            reply.text = "Hello there."
            try callbacks.response(reply)
        }
        app.draft = "A half-written thought"
        XCTAssertFalse(app.sendFromDesktop("   "), "Nothing to send")
        XCTAssertTrue(app.sendFromDesktop("  How are you?\n"))
        await waitUntil { requests.count == 1 && !app.busy }
        XCTAssertEqual(requests.first?.text, "How are you?")
        XCTAssertEqual(app.conversation?.messages.map(\.text), ["How are you?", "Hello there."])
        XCTAssertEqual(app.draft, "A half-written thought")
    }

    @MainActor func testTextThatCannotBeSentStaysAndAConversationThatNeedsTheWorkspaceOpensIt() {
        let app = app()
        var revealed = 0
        app.revealWorkspace = { revealed += 1 }
        _ = app.turn.begin(.generating)
        XCTAssertFalse(app.sendFromDesktop("Wait for me"), "Not while Mochi prepares a reply")
        XCTAssertEqual(revealed, 0)
        app.turn.stop()
        app.library.conversations[0].archived = true
        XCTAssertFalse(app.sendFromDesktop("Hello"))
        XCTAssertEqual(revealed, 1, "An archived conversation cannot take messages; the workspace shows why")
        XCTAssertEqual(app.conversation?.messages.count, 0)
        app.library.conversations[0].archived = false
        app.library.conversations[0].characterName = "Bad\nName"
        XCTAssertFalse(app.sendFromDesktop("Hello"))
        XCTAssertEqual(revealed, 2, "A character name that needs review is fixed in the workspace")
        XCTAssertEqual(app.error, "Review the character name in Conversation Instructions before sending.")
        XCTAssertEqual(app.conversation?.messages.count, 0)
    }
}

final class QuickTalkTests: XCTestCase {
    @MainActor private func app() -> AppModel {
        let app = makeApp(demo: true)
        app.resume()
        var chat = Conversation()
        chat.voiceIntroduced = true
        app.library.conversations = [chat]
        app.select(chat.id)
        app.media.permission = { true }
        app.media.record = { _ in }
        return app
    }

    @MainActor func testClickStartsAndFinishesAVoiceMessageLikeTheMicrophoneButton() async {
        let app = app()
        XCTAssertEqual(app.quickTalk(), .microphone)
        await waitUntil { app.turn.activity == .recording }
        XCTAssertEqual(app.quickTalk(), .microphone)
        await waitUntil { app.turn.activity != .recording }
        app.stop()
    }

    @MainActor func testWhileMochiThinksNothingChanges() {
        let app = app()
        let epoch = app.turn.begin(.generating)
        XCTAssertEqual(app.quickTalk(), .busy)
        XCTAssertEqual(app.turn.epoch, epoch)
        XCTAssertEqual(app.turn.activity, .generating)
    }

    @MainActor func testWhileMochiSpeaksAClickPausesAndResumes() async {
        let app = app()
        let player = TestPlayer()
        app.audio.makePlayer = { _ in player }
        app.play("reply.wav", mochi: true)
        XCTAssertEqual(app.turn.activity, .playing)
        XCTAssertEqual(app.quickTalk(), .pause)
        XCTAssertTrue(app.audio.paused)
        XCTAssertEqual(app.quickTalk(), .pause)
        XCTAssertFalse(app.audio.paused)
        app.stop()
    }

    @MainActor func testWhatTheMicrophoneCannotDoHereOpensTheWorkspace() {
        let app = app()
        var revealed = 0
        app.revealWorkspace = { revealed += 1 }
        app.turn.pause()
        XCTAssertEqual(app.quickTalk(), .workspace, "Practice needs the expression on screen")
        app.turn.resume()
        app.library.conversations[0].archived = true
        XCTAssertEqual(app.quickTalk(), .workspace, "An archived conversation cannot take new messages")
        app.library.conversations[0].archived = false
        app.library.conversations[0].characterName = "  "
        XCTAssertEqual(app.conversation?.characterNameNeedsReview, true)
        XCTAssertEqual(app.quickTalk(), .workspace, "The name needs review first")
        XCTAssertEqual(revealed, 3)
        XCTAssertEqual(app.turn.activity, .idle)
    }

    @MainActor func testSlowlyLiftedChordIsStillATap() async {
        let app = app()
        var now = Date()
        app.recordingNow = { now }
        app.shortcutTriggered(.talk, pressed: true)
        await waitUntil { app.turn.activity == .recording }
        // Four keys take a moment to let go of; short of the hold time the recording keeps running.
        now = now.addingTimeInterval(AppModel.holdToTalk - 0.1)
        app.shortcutTriggered(.talk, pressed: false)
        XCTAssertEqual(app.turn.activity, .recording)
        app.stop()
    }

    @MainActor func testTapTogglesAndHoldingTheShortcutIsPushToTalk() async {
        let app = app()
        var now = Date()
        app.recordingNow = { now }
        // A tap starts recording, and letting go leaves it running.
        app.shortcutTriggered(.talk, pressed: true)
        await waitUntil { app.turn.activity == .recording }
        app.shortcutTriggered(.talk, pressed: false)
        XCTAssertEqual(app.turn.activity, .recording)
        // The next tap finishes it, and its release does nothing more.
        app.shortcutTriggered(.talk, pressed: true)
        await waitUntil { app.turn.activity != .recording }
        app.shortcutTriggered(.talk, pressed: false)
        app.stop()
        // Held down: letting go sends.
        app.shortcutTriggered(.talk, pressed: true)
        await waitUntil { app.turn.activity == .recording }
        now = now.addingTimeInterval(AppModel.holdToTalk + 0.1)
        app.shortcutTriggered(.talk, pressed: false)
        XCTAssertNotEqual(app.turn.activity, .recording)
        app.stop()
    }

    @MainActor func testLettingGoBeforeTheMicrophoneOpensStartsNothing() async {
        let app = app()
        var now = Date()
        app.recordingNow = { now }
        var grant: CheckedContinuation<Bool, Never>?
        var recorded = 0
        app.media.permission = { await withCheckedContinuation { grant = $0 } }
        app.media.record = { _ in recorded += 1 }
        app.shortcutTriggered(.talk, pressed: true)
        await waitUntil { grant != nil }
        XCTAssertEqual(app.turn.activity, .requestingPermission)
        now = now.addingTimeInterval(AppModel.holdToTalk + 0.1)
        app.shortcutTriggered(.talk, pressed: false)
        XCTAssertEqual(app.turn.activity, .idle)
        grant?.resume(returning: true)
        await Task.yield()
        XCTAssertEqual(recorded, 0, "The late permission answer must not open the microphone")
        XCTAssertEqual(app.turn.activity, .idle)
    }

    @MainActor func testHoldingThroughAGreetingSkipSendsWhenLetGo() async {
        let app = app()
        var now = Date()
        app.recordingNow = { now }
        app.greetingActive = true
        app.shortcutTriggered(.talk, pressed: true)
        await waitUntil { app.turn.activity == .recording }
        now = now.addingTimeInterval(AppModel.holdToTalk + 0.1)
        app.shortcutTriggered(.talk, pressed: false)
        XCTAssertNotEqual(app.turn.activity, .recording)
        app.stop()
    }

    @MainActor func testLettingGoNeverSendsALaterRecording() async {
        let app = app()
        var now = Date()
        app.recordingNow = { now }
        app.shortcutTriggered(.talk, pressed: true)
        await waitUntil { app.turn.activity == .recording }
        // While the key is still down, that recording is cancelled and another one started elsewhere.
        app.stop()
        app.toggleConversationVoice()
        await waitUntil { app.turn.activity == .recording }
        now = now.addingTimeInterval(AppModel.holdToTalk + 0.1)
        app.shortcutTriggered(.talk, pressed: false)
        XCTAssertEqual(app.turn.activity, .recording, "The other recording keeps going")
        app.stop()
    }

    @MainActor func testAPressThatStartsTheGreetingActsAsATap() async {
        let app = app()
        app.library.conversations[0].voiceIntroduced = false
        var now = Date()
        app.recordingNow = { now }
        app.speech.referenceAudio = { _, _, _, _, _ in throw CancellationError() }
        app.shortcutTriggered(.talk, pressed: true)
        XCTAssertTrue(app.greetingActive)
        XCTAssertNil(app.talkPress?.request, "The greeting comes first, so the press owns no recording")
        now = now.addingTimeInterval(AppModel.holdToTalk + 0.1)
        app.shortcutTriggered(.talk, pressed: false)
        XCTAssertTrue(app.greetingActive, "Letting go leaves the greeting to finish")
        app.stop()
    }

    @MainActor func testOneRuleNamesWhatQuickTalkDoes() async {
        let app = app()
        XCTAssertEqual(app.quickTalkPlan, .microphone)
        XCTAssertEqual(app.quickTalkLabel, app.microphoneLabel)
        let player = TestPlayer()
        app.audio.makePlayer = { _ in player }
        app.play("reply.wav", mochi: true)
        XCTAssertEqual(app.quickTalkPlan, .pause)
        XCTAssertEqual(app.quickTalkLabel, "Pause")
        app.audio.togglePause()
        XCTAssertEqual(app.quickTalkLabel, "Resume")
        app.stop()
        app.turn.begin(.generating)
        XCTAssertEqual(app.quickTalkPlan, .busy)
        XCTAssertEqual(app.quickTalkLabel, app.status)
        app.turn.stop()
        app.turn.pause()
        XCTAssertEqual(app.quickTalkPlan, .workspace)
        XCTAssertEqual(app.quickTalkLabel, "Open Mochi")
    }

    @MainActor func testShowOrHideShortcutTogglesTheDesktopMochi() {
        let app = makeApp(demo: true)
        var updates = 0
        app.updateDesktopPet = { updates += 1 }
        app.shortcutTriggered(.togglePet, pressed: true)
        XCTAssertTrue(app.petVisible)
        app.shortcutTriggered(.togglePet, pressed: false)
        XCTAssertTrue(app.petVisible, "Only the key going down counts")
        app.shortcutTriggered(.togglePet, pressed: true)
        XCTAssertFalse(app.petVisible)
        XCTAssertEqual(updates, 2)
    }
}
