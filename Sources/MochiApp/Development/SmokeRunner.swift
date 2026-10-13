#if MOCHI_DEVELOPMENT
    import SwiftUI
    import AppKit
    import MochiKernel
    import MochiCore
    import MochiProviders

    /// Scripted development runs: native smoke tests, tray checks and live provider probes.
    /// Compiled only into development builds; the release gate rejects their strings and symbols.
    extension AppDelegate {
        /// Ends a scripted run. A failed or incomplete run exits nonzero so it never looks clean to its launcher.
        private func finishRun(_ model: AppModel, passed: Bool) {
            if passed {
                NSApp.terminate(nil)
            } else {
                model.discardTemporaryLibrary()
                exit(EXIT_FAILURE)
            }
        }
        /// Writes required evidence; a failure is reported on stderr and fails the run.
        private func writeEvidence(_ data: Data, to url: URL) -> Bool {
            do {
                try data.write(to: url, options: .atomic)
                return true
            } catch {
                FileHandle.standardError.write(Data("Could not write \(url.path): \(error)\n".utf8))
                return false
            }
        }
        /// Removes evidence left by an earlier run; false when it is still present.
        private func removeStaleEvidence(_ url: URL) -> Bool {
            do {
                try FileManager.default.removeItem(at: url)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
            } catch {
                FileHandle.standardError.write(Data("Could not remove \(url.path): \(error)\n".utf8))
                return false
            }
            return true
        }
        func smokeTray(_ model: AppModel) {
            guard !ran else { return }
            ran = true
            model.turn.resume()
            Task {
                try? await Task.sleep(nanoseconds: 700_000_000)
                let directory = URL(
                    fileURLWithPath: ProcessInfo.processInfo.environment["MOCHI_EVIDENCE_DIR"]
                        ?? "/tmp/mochi-tray-evidence")
                var passed = false
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    guard let window = tray.window else { throw CocoaError(.fileNoSuchFile) }
                    var checks: [(String, Bool)] = []
                    let selected = model.selectedID
                    model.draft = "Tray smoke draft"
                    var voice = Message(role: "user", text: "", audio: "tray-retained.wav")
                    voice.transcriptionState = .failed
                    if let selected { model.append(voice, to: selected) }
                    var recoveryStarted = false
                    model.speech.transcribe = { _, _ in
                        recoveryStarted = true
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        return "Late tray transcript"
                    }
                    model.retryTranscription(voice.id)
                    let startedDeadline = Date().addingTimeInterval(2)
                    while !recoveryStarted && Date() < startedDeadline { try await Task.sleep(nanoseconds: 1_000_000) }
                    let epoch = model.turn.begin(.generating)
                    window.performClose(nil)
                    checks.append(("Close hides the workspace", !window.isVisible))
                    checks.append(("Close cancels active work", model.turn.epoch != epoch && !model.busy))
                    checks.append(
                        (
                            "Close cancels pending transcription",
                            recoveryStarted && model.transcribingMessageIDs.isEmpty
                                && model.conversation?.messages.first(where: { $0.id == voice.id })?.transcriptionState
                                    == .interrupted
                        ))
                    try await Task.sleep(nanoseconds: 150_000_000)
                    checks.append(
                        (
                            "Late transcript cannot rewrite closed workspace",
                            model.conversation?.messages.first(where: { $0.id == voice.id })?.text == ""
                        ))
                    checks.append(("Tray remains installed", tray.statusItem?.button?.image?.isTemplate == true))
                    tray.showWindow()
                    checks.append(("Open restores the same workspace", window.isVisible && tray.window === window))
                    checks.append(
                        (
                            "Draft and selection survive",
                            model.draft == "Tray smoke draft" && model.selectedID == selected
                        ))
                    window.performClose(nil)
                    _ = applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
                    checks.append(("Dock reopen restores workspace", window.isVisible))
                    checks.append(
                        ("Last window close keeps app running", !applicationShouldTerminateAfterLastWindowClosed(NSApp))
                    )
                    func menuItems(_ menu: NSMenu) -> [NSMenuItem] {
                        menu.items.flatMap { item in [item] + (item.submenu.map(menuItems) ?? []) }
                    }
                    let commands = NSApp.mainMenu.map(menuItems) ?? []
                    let commandQ = commands.first {
                        $0.keyEquivalent == "q" && $0.keyEquivalentModifierMask == .command
                    }
                    checks.append(
                        (
                            "Command-Q is Close Window to Tray",
                            commandQ?.title == String(localized: "Close Window to Tray")
                        ))
                    let quit = tray.menu?.items.first { $0.title == String(localized: "Quit Mochi Completely") }
                    checks.append(("Tray quit has no Command-Q shortcut", quit != nil && quit?.keyEquivalent == ""))
                    let playbackEpoch = model.turn.begin(.playing)
                    if let commandQ, let menu = commandQ.menu {
                        menu.performActionForItem(at: menu.index(of: commandQ))
                    }
                    let hiddenDeadline = Date().addingTimeInterval(2)
                    while !NSApp.isHidden && Date() < hiddenDeadline { try await Task.sleep(nanoseconds: 1_000_000) }
                    checks.append(
                        (
                            "Command-Q hides workspace and keeps tray",
                            !window.isVisible && NSApp.isHidden && tray.statusItem?.button != nil
                        ))
                    checks.append(
                        (
                            "Command-Q removes Dock presence",
                            NSApp.activationPolicy() == .accessory
                                && NSRunningApplication.current.activationPolicy == .accessory
                        ))
                    checks.append(
                        (
                            "Command-Q stops active work and preserves draft",
                            model.turn.epoch != playbackEpoch && !model.busy && model.draft == "Tray smoke draft"
                        ))
                    tray.showWindow()
                    let reopenedDeadline = Date().addingTimeInterval(2)
                    while (NSApp.isHidden || !window.isVisible) && Date() < reopenedDeadline {
                        try await Task.sleep(nanoseconds: 1_000_000)
                    }
                    checks.append(
                        (
                            "Tray reopens workspace after Command-Q",
                            window.isVisible && !NSApp.isHidden && tray.window === window
                        ))
                    checks.append(
                        (
                            "Tray reopen restores Dock presence",
                            NSApp.activationPolicy() == .regular
                                && NSRunningApplication.current.activationPolicy == .regular
                        ))
                    checks.append(
                        (
                            "Tray button handles clicks without an automatic menu",
                            tray.statusItem?.menu == nil && tray.statusItem?.button?.target === tray
                        ))
                    tray.closeToTray()
                    let clickHiddenDeadline = Date().addingTimeInterval(2)
                    while !NSApp.isHidden && Date() < clickHiddenDeadline {
                        try await Task.sleep(nanoseconds: 1_000_000)
                    }
                    let originalPresenter = tray.presentMenu
                    var presented = false
                    tray.presentMenu = { menu, event, button in
                        presented =
                            menu === self.tray.menu && event.type == .rightMouseUp
                            && button === self.tray.statusItem?.button
                    }
                    let rightClick = NSEvent.mouseEvent(
                        with: .rightMouseUp, location: .zero, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, eventNumber: 1,
                        clickCount: 1, pressure: 0)!
                    tray.handleClick(rightClick)
                    // Three conditions, reported apart so a failure names its cause.
                    checks.append(("Right click on the tray: menu presented", presented))
                    checks.append(("Right click on the tray: window stays hidden", !window.isVisible))
                    checks.append(
                        ("Right click on the tray: Dock stays hidden", NSApp.activationPolicy() == .accessory))
                    presented = false
                    tray.presentMenu = { menu, event, button in
                        presented =
                            menu === self.tray.menu && event.modifierFlags.contains(.control)
                            && button === self.tray.statusItem?.button
                    }
                    let controlClick = NSEvent.mouseEvent(
                        with: .leftMouseUp, location: .zero, modifierFlags: [.control],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, eventNumber: 3,
                        clickCount: 1, pressure: 0)!
                    tray.handleClick(controlClick)
                    // Three conditions, reported apart so a failure names its cause.
                    checks.append(("Control-click on the tray: menu presented", presented))
                    checks.append(("Control-click on the tray: window stays hidden", !window.isVisible))
                    checks.append(
                        ("Control-click on the tray: Dock stays hidden", NSApp.activationPolicy() == .accessory))
                    presented = false
                    let leftClick = NSEvent.mouseEvent(
                        with: .leftMouseUp, location: .zero, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, eventNumber: 2,
                        clickCount: 1, pressure: 0)!
                    tray.handleClick(leftClick)
                    let clickReopenedDeadline = Date().addingTimeInterval(2)
                    while (NSApp.isHidden || !window.isVisible) && Date() < clickReopenedDeadline {
                        try await Task.sleep(nanoseconds: 1_000_000)
                    }
                    checks.append(
                        (
                            "Left click restores window and Dock without menu",
                            window.isVisible && !NSApp.isHidden && NSApp.activationPolicy() == .regular && !presented
                        ))
                    if CommandLine.arguments.contains("--single-instance-smoke-test") {
                        tray.closeToTray()
                        let duplicate = Process()
                        duplicate.executableURL = Bundle.main.executableURL
                        duplicate.arguments = ["--single-instance-smoke-test"]
                        try duplicate.run()
                        let deadline = Date().addingTimeInterval(8)
                        while (duplicate.isRunning || !window.isVisible || NSApp.isHidden || !NSApp.isActive
                            || !window.isKeyWindow) && Date() < deadline
                        {
                            try await Task.sleep(nanoseconds: 20_000_000)
                        }
                        checks.append(
                            (
                                "Duplicate launch exits successfully",
                                !duplicate.isRunning && duplicate.terminationStatus == 0
                            ))
                        checks.append(
                            (
                                "Duplicate launch restores existing tray window",
                                window.isVisible && !NSApp.isHidden && tray.window === window
                            ))
                        checks.append(("Duplicate launch restores Dock presence", NSApp.activationPolicy() == .regular))
                        checks.append(
                            ("Duplicate launch restores active key workspace", NSApp.isActive && window.isKeyWindow))
                        SingleInstanceController.shared.enforce()
                        checks.append(("Repeated enforce retains the existing workspace", window.isVisible))
                        if duplicate.isRunning { duplicate.terminate() }
                    }
                    tray.presentMenu = originalPresenter
                    let icon = TrayController.icon()
                    for scale in [1, 2, 4] {
                        let rep = NSBitmapImageRep(
                            bitmapDataPlanes: nil, pixelsWide: 20 * scale, pixelsHigh: 18 * scale, bitsPerSample: 8,
                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                            bytesPerRow: 0, bitsPerPixel: 0)!
                        rep.size = NSSize(width: 20, height: 18)
                        NSGraphicsContext.saveGraphicsState()
                        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                        icon.draw(in: NSRect(x: 0, y: 0, width: 20, height: 18))
                        NSGraphicsContext.restoreGraphicsState()
                        try rep.representation(using: .png, properties: [:])!.write(
                            to: directory.appendingPathComponent("TrayIcon-\(scale)x.png"))
                    }
                    let lines = checks.map { "\($0.1 ? "PASS" : "FAIL"): \($0.0)" }
                    try Data((lines.joined(separator: "\n") + "\n").utf8).write(
                        to: directory.appendingPathComponent("tray-smoke.txt"))
                    let evidence: [String: Any] = [
                        "pid": getpid(), "time": Date().timeIntervalSince1970,
                        "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "unknown",
                        "checks": checks.map { ["name": $0.0, "pass": $0.1] },
                    ]
                    try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(
                        to: directory.appendingPathComponent("tray-smoke.json"))
                    passed = !checks.isEmpty && checks.allSatisfy(\.1)
                } catch {
                    _ = writeEvidence(
                        Data("FAIL: \(error.localizedDescription)\n".utf8),
                        to: directory.appendingPathComponent("tray-smoke.txt"))
                }
                finishRun(model, passed: passed)
            }
        }
        func smoke(_ model: AppModel) {
            guard !ran else { return }
            ran = true
            Task {
                try? await Task.sleep(nanoseconds: 700_000_000)
                let directory = URL(
                    fileURLWithPath: ProcessInfo.processInfo.environment["MOCHI_EVIDENCE_DIR"] ?? ProcessInfo
                        .processInfo.environment["ENJOY_EVIDENCE_DIR"] ?? "/tmp/mochi-evidence")
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var captureFailures: [String] = []
                for stale in [
                    "smoke.txt", "smoke-report.json", "template-minimum-geometry.json", "template-keyboard.json",
                    "phrase-chip.json",
                ] where !removeStaleEvidence(directory.appendingPathComponent(stale)) {
                    captureFailures.append("Stale \(stale) could not be removed")
                }
                var captureCount = 0
                var viewCaptureCount = 0
                let mainWindow = NSApp.windows.first(where: {
                    $0.isVisible && !$0.isSheet && $0.parent == nil && $0.canBecomeMain && $0.frame.width >= 760
                })
                /// Polls until `condition` holds or `timeout` passes; returns whether it held.
                @MainActor func waitFor(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
                    let deadline = Date().addingTimeInterval(timeout)
                    while !condition() {
                        guard Date() < deadline else { return false }
                        try? await Task.sleep(nanoseconds: 20_000_000)
                    }
                    return true
                }
                @MainActor func capture(
                    _ name: String, settings: Bool = false, window explicitWindow: NSWindow? = nil
                ) async {
                    captureCount += 1
                    let target =
                        explicitWindow
                        ?? (settings
                            ? NSApp.windows.first(where: { $0.isVisible && $0 !== mainWindow && $0.canBecomeMain })
                            : mainWindow)
                    guard let window = target else {
                        captureFailures.append(name)
                        return
                    }
                    guard removeStaleEvidence(directory.appendingPathComponent(name)) else {
                        captureFailures.append("\(name): stale capture could not be removed")
                        return
                    }
                    let capture = Process()
                    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    capture.arguments = [
                        "-x", "-o", "-l", String(window.windowNumber), directory.appendingPathComponent(name).path,
                    ]
                    var captured = false
                    do {
                        try capture.run()
                        if await !waitFor(10, { !capture.isRunning }) {
                            capture.terminate()
                            if await !waitFor(2, { !capture.isRunning }) { kill(capture.processIdentifier, SIGKILL) }
                            _ = await waitFor(2, { !capture.isRunning })
                        }
                        // A capture that never exits has no status and no trustworthy file.
                        captured =
                            !capture.isRunning && capture.terminationStatus == 0
                            && FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
                    } catch {}
                    // Capture this app's own view hierarchy when screen recording permission is unavailable.
                    if !captured, let view = window.contentView?.superview ?? window.contentView,
                        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
                    {
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        if let png = bitmap.representation(using: .png, properties: [:]) {
                            do {
                                try png.write(to: directory.appendingPathComponent(name))
                                captured = true
                                viewCaptureCount += 1
                            } catch {}
                        }
                    }
                    if !captured { captureFailures.append(name) }
                }
                /// A snapshot of the sheet attached to the workspace; a missing sheet is a failure, never the window.
                @MainActor func captureSheet(_ name: String) async {
                    guard await waitFor(2, { mainWindow?.attachedSheet != nil }), let sheet = mainWindow?.attachedSheet
                    else {
                        captureCount += 1
                        captureFailures.append("\(name): no sheet attached")
                        return
                    }
                    await capture(name, window: sheet)
                }
                /// Scrolls the attached sheet's form to its end or back to its start, so a capture shows those fields.
                @MainActor func scrollSheet(toEnd: Bool) -> Bool {
                    @MainActor func scrollViews(_ view: NSView) -> [NSScrollView] {
                        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews($0) }
                    }
                    // Lists and text editors scroll too; the form is the tallest of the rest.
                    guard let content = mainWindow?.attachedSheet?.contentView,
                        let scroll = scrollViews(content).filter({
                            !($0.documentView is NSTableView) && !($0.documentView is NSTextView)
                        }).max(by: { $0.frame.height < $1.frame.height }),
                        let document = scroll.documentView
                    else { return false }
                    let end = max(0, document.frame.height - scroll.contentView.bounds.height)
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped == toEnd ? end : 0))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    return end > 0
                }
                /// Clicks the middle of the view marked `identifier` with a mouse down and up, as a person would; SwiftUI
                /// draws its controls without AppKit views or, in this process, accessibility elements. Returns the
                /// point clicked, in window coordinates, or nil when nothing carries the mark.
                @MainActor func click(_ identifier: String, in window: NSWindow) -> NSPoint? {
                    @MainActor func find(_ view: NSView) -> NSView? {
                        view.identifier?.rawValue == identifier ? view : view.subviews.lazy.compactMap(find).first
                    }
                    guard let probe = window.contentView.flatMap(find) else { return nil }
                    let point = probe.convert(NSPoint(x: probe.bounds.midX, y: probe.bounds.midY), to: nil)
                    window.makeKeyAndOrderFront(nil)
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        guard
                            let event = NSEvent.mouseEvent(
                                with: type, location: point, modifierFlags: [],
                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
                        else { return nil }
                        window.sendEvent(event)
                    }
                    return point
                }
                if mainWindow?.titleVisibility != .hidden || mainWindow?.toolbar?.displayMode != .iconOnly {
                    captureFailures.append("Workspace title or toolbar display mode is incorrect")
                }
                if #available(macOS 15.0, *), mainWindow?.toolbar?.allowsDisplayModeCustomization != false {
                    captureFailures.append("Toolbar display-mode customization remains enabled")
                }
                if mainWindow?.titlebarSeparatorStyle != NSTitlebarSeparatorStyle.none {
                    captureFailures.append("Title-bar separator remains enabled")
                }
                // A launch that restored a session ended in the menu bar would have opened no window to test.
                if !UserDefaults.standard.bool(forKey: "ApplePersistenceIgnoreState") {
                    captureFailures.append("Launches restore the last session's windows")
                }
                mainWindow?.attachedSheet?.makeFirstResponder(nil)
                // The practice captures use the default voice; the preview's own choice is put back after them.
                let practiceVoice = model.settings.builtInPracticeVoice
                model.settings.builtInPracticeVoice = RealtimeService.defaultVoice
                await capture("practice.png")
                // The sheet on its own, so the practice pane is visible even when only AppKit view captures work.
                await captureSheet("practice-sheet.png")
                let wordCheckShown: Bool = {
                    if case .checked = model.help.attemptCheck { return true }
                    return false
                }()
                if !wordCheckShown { captureFailures.append("The practice preview shows no word check") }
                NSApp.appearance = NSAppearance(named: .darkAqua)
                try? await Task.sleep(nanoseconds: 250_000_000)
                await capture("practice-dark.png")
                await captureSheet("practice-sheet-dark.png")
                NSApp.appearance = NSAppearance(named: .aqua)
                if let window = mainWindow { window.setContentSize(NSSize(width: 820, height: 700)) }
                try? await Task.sleep(nanoseconds: 300_000_000)
                await capture("practice-compact.png")
                model.settings.builtInPracticeVoice = practiceVoice
                if let window = mainWindow { window.setContentSize(NSSize(width: 1120, height: 840)) }
                model.resume()
                try? await Task.sleep(nanoseconds: 350_000_000)
                if mainWindow?.attachedSheet != nil {
                    captureFailures.append("Practice left a sheet attached to the conversation")
                }
                await capture("conversation.png")
                let toolbarStates: [(Activity, String)] = [
                    (.generating, "generation"), (.playing, "playback"), (.recording, "recording"),
                    (.requestingPermission, "permission"), (.idle, "idle"),
                ]
                for (activity, name) in toolbarStates {
                    _ = model.turn.begin(activity)
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    let stopShown = await waitFor(2) {
                        (mainWindow?.toolbar?.items.contains(where: { $0.label == String(localized: "Stop") }) == true)
                            == (activity == .generating)
                    }
                    if !stopShown {
                        captureFailures.append("Incorrect title-bar Stop visibility: \(name)")
                    }
                    await capture("titlebar-stop-\(name).png")
                }
                model.stop()
                model.newChat()
                try? await Task.sleep(nanoseconds: 300_000_000)
                await capture("welcome.png")
                @MainActor func composerFrame(_ root: Any, depth: Int = 0) -> NSRect? {
                    guard depth < 60 else { return nil }
                    if let window = root as? NSWindow, let content = window.contentView,
                        let frame = composerFrame(content, depth: depth + 1)
                    {
                        return frame
                    }
                    if let view = root as? NSView {
                        if view.identifier?.rawValue == "mochi-composer-geometry-probe", let window = view.window {
                            return window.convertToScreen(view.convert(view.bounds, to: nil))
                        }
                        for child in view.subviews {
                            if let frame = composerFrame(child, depth: depth + 1) { return frame }
                        }
                    }
                    guard let element = root as? any NSAccessibilityProtocol else { return nil }
                    if element.accessibilityIdentifier() == "conversation-composer" {
                        return element.accessibilityFrame()
                    }
                    for child in element.accessibilityChildren() ?? [] {
                        if let frame = composerFrame(child, depth: depth + 1) { return frame }
                    }
                    return nil
                }
                let beforeNotice = mainWindow.flatMap { composerFrame($0) }
                model.notice = "Help draft saved."
                try? await Task.sleep(nanoseconds: 250_000_000)
                await capture("conversation-notice.png")
                let withNotice = mainWindow.flatMap { composerFrame($0) }
                if let beforeNotice, let withNotice {
                    if abs(beforeNotice.minY - withNotice.minY) > 0.5
                        || abs(beforeNotice.height - withNotice.height) > 0.5
                    {
                        captureFailures.append("Notice moved or resized the conversation composer")
                    }
                } else {
                    captureFailures.append("Could not locate the composer for notice geometry verification")
                }
                if await !waitFor(6, { model.notice == nil }) {
                    captureFailures.append("Conversation notice did not automatically dismiss")
                }
                // A reply disables the composer; focus must come back to it when the turn ends.
                @MainActor func composerField(_ view: NSView) -> NSTextField? {
                    if let field = view as? NSTextField, !(field is NSSearchField),
                        (field.placeholderString ?? field.placeholderAttributedString?.string)
                            == String(localized: "Message \(model.displayCharacterName)")
                    {
                        return field
                    }
                    return view.subviews.lazy.compactMap(composerField).first
                }
                @MainActor func composerHasFocus(_ window: NSWindow, _ field: NSTextField) -> Bool {
                    window.firstResponder === field || (window.firstResponder as? NSText)?.delegate === field
                }
                if let window = mainWindow, let content = window.contentView, let field = composerField(content) {
                    window.makeFirstResponder(field)
                    if await !waitFor(2, { composerHasFocus(window, field) }) {
                        captureFailures.append("Composer could not take focus")
                    }
                    // SwiftUI learns of an AppKit focus change on a later pass; a reply that starts before then
                    // looks to the view as if the composer was never focused.
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    let reply = model.turn.begin(.generating)
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    _ = model.turn.finish(reply)
                    if await !waitFor(2, { composerHasFocus(window, field) }) {
                        let responder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
                        captureFailures.append(
                            "Composer did not regain focus after a reply (first responder: \(responder))")
                    }
                } else {
                    captureFailures.append("Could not locate the composer text field for focus verification")
                }
                await capture("conversation-notice-dismissed.png")
                let deletedRecording = "message-delete-fixture.wav"
                try? PCM.wav(Data(repeating: 0, count: 48000)).write(
                    to: model.store.root.appendingPathComponent(deletedRecording))
                let deleteFixture = Message(
                    role: "user", text: "Could we practise this sentence?", audio: deletedRecording)
                model.append(deleteFixture, to: model.selectedID!)
                try? await Task.sleep(nanoseconds: 250_000_000)
                await capture("message-before-deletion.png")
                model.deleteMessage(deleteFixture.id)
                try? await Task.sleep(nanoseconds: 250_000_000)
                if !model.canUndoMessageDeletion
                    || model.conversation?.messages.contains(where: { $0.id == deleteFixture.id }) == true
                {
                    captureFailures.append("Single-message deletion or Undo availability failed")
                }
                await capture("message-deleted-undo.png")
                model.undoMessageDeletion()
                try? await Task.sleep(nanoseconds: 250_000_000)
                if model.conversation?.messages.last?.id != deleteFixture.id
                    || !FileManager.default.fileExists(
                        atPath: model.store.root.appendingPathComponent(deletedRecording).path)
                {
                    captureFailures.append("Undo did not restore the message and recording")
                }
                await capture("message-deletion-undone.png")
                if let chatID = model.selectedID {
                    var preferences = ConversationPreferences()
                    preferences.coaching = .direct
                    preferences.speed = 0.85
                    if !model.setConversationInstructions(
                        chatID,
                        instructions:
                            "Act as a job interviewer. Ask one question at a time and let me finish before offering feedback.",
                        preferences: preferences)
                    {
                        captureFailures.append("Conversation instructions could not be saved")
                    }
                    model.customization.instructionsID = chatID
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    await captureSheet("conversation-instructions.png")
                    NSApp.appearance = NSAppearance(named: .darkAqua)
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    await captureSheet("conversation-instructions-dark.png")
                    NSApp.appearance = NSAppearance(named: .aqua)
                    model.customization.instructionsID = nil
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    model.openTemplatePicker()
                    model.customization.templateDraft = TemplateEditorDraft(
                        value: ConversationTemplate.builtins[0], editingID: nil,
                        expectedRevision: ConversationTemplate.builtins[0].revision)
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    await captureSheet("template-picker.png")
                    // A general built-in previews its greeting and phrases, in the interface language.
                    if let general = ConversationTemplate.builtins.first(where: { $0.title == "Brainstorm with me" }) {
                        model.customization.previewTemplate(general)
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        await captureSheet("template-picker-general.png")
                        if !scrollSheet(toEnd: true) { captureFailures.append("Template preview could not scroll") }
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        await captureSheet("template-picker-general-end.png")
                        _ = scrollSheet(toEnd: false)
                    } else {
                        captureFailures.append("No general built-in template to preview")
                    }
                    model.customization.templateDraft = TemplateEditorDraft(
                        value: ConversationTemplate.builtins[0], editingID: nil,
                        expectedRevision: ConversationTemplate.builtins[0].revision)
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    let previousFrame = mainWindow?.frame
                    mainWindow?.setContentSize(NSSize(width: 760, height: 580))
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    await capture("template-picker-minimum-window.png")
                    await captureSheet("template-picker-minimum-sheet.png")
                    if let window = mainWindow, let sheet = window.attachedSheet {
                        let geometry = try? JSONSerialization.data(
                            withJSONObject: [
                                "requested_content_width": 760, "requested_content_height": 580,
                                "actual_window_width": window.frame.width, "actual_window_height": window.frame.height,
                                "content_width": window.contentLayoutRect.width,
                                "content_height": window.contentLayoutRect.height, "sheet_width": sheet.frame.width,
                                "sheet_height": sheet.frame.height,
                                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                            ], options: [.prettyPrinted, .sortedKeys])
                        if !(geometry.map {
                            writeEvidence($0, to: directory.appendingPathComponent("template-minimum-geometry.json"))
                        } ?? false) {
                            captureFailures.append("Template minimum geometry evidence was not written")
                        }
                        @MainActor func findTable(_ view: NSView) -> NSTableView? {
                            if let table = view as? NSTableView { return table }
                            for child in view.subviews { if let table = findTable(child) { return table } }
                            return nil
                        }
                        let before = model.customization.templateDraft?.value.id
                        if let content = sheet.contentView, let table = findTable(content),
                            sheet.makeFirstResponder(table),
                            let event = NSEvent.keyEvent(
                                with: .keyDown, location: .zero, modifierFlags: [],
                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: sheet.windowNumber,
                                context: nil, characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}",
                                isARepeat: false, keyCode: 125)
                        {
                            table.keyDown(with: event)
                            try? await Task.sleep(nanoseconds: 250_000_000)
                            let moved = model.customization.templateDraft?.value.id != before
                            let keyboard = try? JSONSerialization.data(withJSONObject: [
                                "arrow_key_moved_selection": moved, "native_table": true,
                            ])
                            if !(keyboard.map {
                                writeEvidence($0, to: directory.appendingPathComponent("template-keyboard.json"))
                            } ?? false) {
                                captureFailures.append("Template keyboard evidence was not written")
                            }
                            if !moved { captureFailures.append("Template arrow-key selection did not update preview") }
                        } else {
                            captureFailures.append(
                                "Native template list could not be reached for keyboard verification")
                        }
                    } else {
                        captureFailures.append("No template sheet for minimum geometry and keyboard verification")
                    }
                    if let previousFrame { mainWindow?.setFrame(previousFrame, display: true) }

                    model.customization.templatePresentation = nil
                    model.customization.templateDraft = nil
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    model.openTemplateManager()
                    model.customization.editTemplate(ConversationTemplate.builtins[0], duplicate: true)
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    await captureSheet("template-editor.png")
                    model.customization = CustomizationSheet()
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    if !model.setConversationInstructions(
                        chatID, instructions: "Discuss books", preferences: preferences, characterName: "Loki")
                    {
                        captureFailures.append("Character identity could not be saved")
                    }
                    model.customization.instructionsID = chatID
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    await captureSheet("character-editor.png")
                    model.saveConversationAsTemplate(
                        chatID,
                        draft: ConversationSettingsDraft(
                            id: chatID, instructions: "Unsaved template instructions", characterName: nil,
                            preferences: preferences))
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    await captureSheet("template-save-as.png")
                    model.customization.closeTemplateEditor()
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    if model.customization.retainedInstructionsDraft?.instructions != "Unsaved template instructions" {
                        captureFailures.append("Save-as lost instructions draft")
                    }
                    await captureSheet("instructions-draft-return.png")
                    model.customization.instructionsID = nil
                    model.customization.retainedInstructionsDraft = nil
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    // Characters: the manager, opened with the File menu's command, on the built-ins; then the editor on
                    // a duplicate of one. (The toolbar's menu runs the same action; SwiftUI draws it without views a
                    // run could click.)
                    let pip = ConversationCharacter.builtins.first { $0.name == "Pip" }
                    @MainActor func item(_ title: String, in menu: NSMenu?) -> NSMenuItem? {
                        menu?.items.lazy.compactMap { $0.title == title ? $0 : item(title, in: $0.submenu) }.first
                    }
                    var openedFromMenu = false
                    if let command = item(String(localized: "Manage Characters…"), in: NSApp.mainMenu),
                        let owner = command.menu
                    {
                        // A menu brings its items up to date as it opens; do the same before choosing one.
                        owner.delegate?.menuNeedsUpdate?(owner)
                        owner.update()
                        owner.performActionForItem(at: owner.index(of: command))
                        openedFromMenu = await waitFor(2) { model.customization.characterPresentation == .manager }
                    }
                    if !openedFromMenu {
                        captureFailures.append("File > Manage Characters… did not open the character manager")
                    }
                    if model.customization.characterPresentation != .manager { model.openCharacterManager() }
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    await captureSheet("character-manager.png")
                    NSApp.appearance = NSAppearance(named: .darkAqua)
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    await captureSheet("character-manager-dark.png")
                    NSApp.appearance = NSAppearance(named: .aqua)
                    if let pip {
                        model.customization.editCharacter(pip, duplicate: true)
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        await captureSheet("character-library-editor.png")
                    } else {
                        captureFailures.append("No built-in character Pip")
                    }
                    model.customization = CustomizationSheet()
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    if let pip,
                        var companion = model.library.conversations.first(where: { $0.id == chatID }).map(
                            ConversationSettingsDraft.init)
                    {
                        companion.adoptCharacter(pip)
                        companion.greeting = "Shall we make up a story?"
                        companion.phrases = ["Add a twist.", "Give it an ending."]
                        if !model.saveConversationSettings(chatID, companion) {
                            captureFailures.append("Character, greeting and phrases could not be saved")
                        }
                    }
                    model.customization.instructionsID = chatID
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    await captureSheet("conversation-instructions-companion.png")
                    if !scrollSheet(toEnd: true) {
                        captureFailures.append("Conversation Instructions could not scroll")
                    }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    await captureSheet("conversation-instructions-companion-end.png")
                    model.customization.instructionsID = nil
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    // Real bundled MCP subprocess -> private socket -> shared app command layer.
                    model.allowDemoAutomation = true
                    model.externalControlEnabled = true
                    let socketPath = model.controlSocketPath
                    do {
                        guard model.automation.server != nil else {
                            throw AppFailure("Production automation listener did not start.")
                        }
                        let helper = AutomationController.helperPath
                        let result = try await Task.detached {
                            try AutomationSmokeClient.run(helper: helper, socketPath: socketPath)
                        }.value
                        try result.write(to: directory.appendingPathComponent("mcp-process.json"), options: .atomic)
                        if !model.library.expressions.contains(where: {
                            $0.english == "Could you give me a moment?" && $0.conversationID == chatID
                        }) {
                            captureFailures.append("Bundled MCP helper did not save the expression")
                        }
                        model.externalControlEnabled = false
                        let disabled = try await Task.detached {
                            try AutomationSmokeClient.disabled(helper: helper, socketPath: socketPath)
                        }.value
                        let unlinked = !FileManager.default.fileExists(atPath: socketPath)
                        try JSONSerialization.data(withJSONObject: [
                            "disabled_rejected": disabled, "socket_unlinked": unlinked,
                        ]).write(to: directory.appendingPathComponent("mcp-disabled.json"))
                        if !disabled || !unlinked {
                            captureFailures.append("Production external control shutdown failed")
                        }
                    } catch { captureFailures.append("MCP subprocess smoke failed: \(error)") }
                    model.externalControlEnabled = false
                    model.allowDemoAutomation = false
                } else {
                    captureFailures.append("No selected conversation for instructions, template and MCP checks")
                }
                // A conversation started from a general built-in shows its greeting and phrase chips. Pressing a chip
                // sends exactly its text in the character's voice and manner, and leaves the typed draft alone.
                let liveReply = model.speech.conversationReply
                var phraseRequests: [(text: String, voice: String, personality: String)] = []
                model.speech.conversationReply = { service, request, callbacks in
                    phraseRequests.append((request.text, service.voice, request.personality))
                    var reply = RealtimeAccumulator()
                    reply.text = "Here are three more ideas."
                    try callbacks.response(reply)
                }
                if let general = ConversationTemplate.builtins.first(where: { $0.title == "Brainstorm with me" }),
                    let pip = ConversationCharacter.builtins.first(where: { $0.name == "Pip" }),
                    let id = try? model.startTemplateSnapshot(general),
                    var companion = model.conversation.map(ConversationSettingsDraft.init)
                {
                    companion.adoptCharacter(pip)
                    if !model.saveConversationSettings(id, companion) {
                        captureFailures.append("The character could not be chosen for the new conversation")
                    }
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    await capture("conversation-phrases.png")
                    NSApp.appearance = NSAppearance(named: .darkAqua)
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    await capture("conversation-phrases-dark.png")
                    NSApp.appearance = NSAppearance(named: .aqua)
                    let draft = "A thought I am still typing"
                    model.draft = draft
                    let phrase = model.conversation?.phrases.first ?? ""
                    let clicked = mainWindow.flatMap { click("mochi-phrase-chip-probe-0", in: $0) }
                    let replied = await waitFor(3) { phraseRequests.count == 1 && !model.busy }
                    let sent = phraseRequests.first
                    let checks: [String: Bool] = [
                        "greeting_kept": model.conversation?.greeting == general.withBuiltinTextTranslated().greeting,
                        "chip_clicked": clicked != nil, "reply_received": replied,
                        "sent_exact_text": sent?.text == phrase,
                        "saved_as_user_message": model.conversation?.messages.first?.text == phrase,
                        "character_voice": sent?.voice == pip.voice,
                        "character_personality": sent?.personality == pip.personality,
                        "draft_kept": model.draft == draft,
                    ]
                    let evidence = try? JSONSerialization.data(
                        withJSONObject: [
                            "phrase": phrase, "checks": checks,
                            "click_point": clicked.map { [$0.x, $0.y] } as Any? ?? NSNull(),
                        ], options: [.prettyPrinted, .sortedKeys])
                    if !(evidence.map { writeEvidence($0, to: directory.appendingPathComponent("phrase-chip.json")) }
                        ?? false)
                    {
                        captureFailures.append("Phrase chip evidence was not written")
                    }
                    for (check, passed) in checks.sorted(by: { $0.key < $1.key }) where !passed {
                        captureFailures.append("Phrase chip check failed: \(check)")
                    }
                    await capture("conversation-phrase-sent.png")
                    model.draft = ""
                } else {
                    captureFailures.append("No conversation could be started from a general built-in template")
                }
                // A role-play conversation shows Start Again; pressing it sends the restart request as the user's
                // message, with the conversation so far as history.
                var restartRequests: [(text: String, history: Int)] = []
                model.speech.conversationReply = { _, request, callbacks in
                    restartRequests.append((request.text, request.history.count))
                    var reply = RealtimeAccumulator()
                    reply.text = "We'll redo the interview for the job you named. Is that still right?"
                    try callbacks.response(reply)
                }
                if let rolePlay = ConversationTemplate.builtins.first(where: { $0.title == "Job interview" }),
                    (try? model.startTemplateSnapshot(rolePlay)) != nil
                {
                    model.draft = "A product manager role at a medical software company."
                    model.send()
                    let answered = await waitFor(3) { restartRequests.count == 1 && !model.busy }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    await capture("conversation-start-again.png")
                    let clicked = mainWindow.flatMap { click("mochi-start-again-probe", in: $0) }
                    let restarted = await waitFor(3) { restartRequests.count == 2 && !model.busy }
                    let checks: [String: Bool] = [
                        "first_reply": answered, "button_shown": model.isRolePlay, "button_clicked": clicked != nil,
                        "restart_sent": restarted,
                        "restart_text": restartRequests.last?.text
                            == String(localized: "Let's start again from the beginning."),
                        "history_kept": restartRequests.last?.history == 2,
                    ]
                    for (check, passed) in checks.sorted(by: { $0.key < $1.key }) where !passed {
                        captureFailures.append("Start Again check failed: \(check)")
                    }
                    await capture("conversation-start-again-sent.png")
                } else {
                    captureFailures.append("No conversation could be started from a role-play template")
                }
                model.speech.conversationReply = liveReply
                model.newChat()
                model.startHelp()
                try? await Task.sleep(nanoseconds: 300_000_000)
                await capture("help.png")
                model.help.meaning = "I want to ask for a little more time to think."
                model.editEnglish("I would like a little more time to think.")
                try? await Task.sleep(nanoseconds: 300_000_000)
                await capture("help-english.png")
                NSApp.appearance = NSAppearance(named: .darkAqua)
                try? await Task.sleep(nanoseconds: 250_000_000)
                await capture("help-english-dark.png")
                NSApp.appearance = NSAppearance(named: .aqua)
                model.beginPractice()
                try? await Task.sleep(nanoseconds: 300_000_000)
                await capture("help-practice.png")
                model.editThought()
                let thoughtName = "thought-fixture.wav"
                try? PCM.wav(Data(repeating: 0, count: 144000)).write(
                    to: model.store.root.appendingPathComponent(thoughtName))
                model.help.thoughtRecording = thoughtName
                model.recordingWarning =
                    "This illustrative recording is very quiet. Listen before transcribing, or record it again."
                try? await Task.sleep(nanoseconds: 300_000_000)
                await capture("help-recording-review.png")
                model.help.recognizedThought = "I need a little more time before I can explain my idea."
                try? await Task.sleep(nanoseconds: 300_000_000)
                await capture("help-transcript-review.png")
                model.help.recognizedThought = nil
                _ = model.turn.begin(.recording)
                model.recordingMeaning = true
                model.recordingSeconds = 3
                model.recordingLevel = -54
                try? await Task.sleep(nanoseconds: 250_000_000)
                await capture("help-recording-feedback.png")
                model.stop()
                model.saveExpression()
                model.resume()
                if let id = model.selectedID {
                    try? PCM.wav(Data(repeating: 0, count: 144000)).write(
                        to: model.store.root.appendingPathComponent(thoughtName))
                    var failed = Message(role: "user", text: "", audio: thoughtName)
                    failed.transcriptionState = .failed
                    failed.transcriptionError = "Your recording is saved. We couldn’t transcribe it."
                    model.append(failed, to: id)
                    model.append(
                        Message(role: "assistant", text: "Take your time. What would help you decide?"), to: id)
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    await capture("voice-recovery.png")
                    model.speech.transcribe = { _, _ in
                        try await Task.sleep(nanoseconds: 900_000_000)
                        return "I would like a little more time to think."
                    }
                    model.retryTranscription(failed.id)
                    if await !waitFor(2, { model.transcribingMessageIDs.contains(failed.id) }) {
                        captureFailures.append("Transcription retry did not show progress")
                    }
                    await capture("voice-recovery-progress.png")
                    let recovered = await waitFor(5) {
                        model.conversation?.messages.first(where: { $0.id == failed.id })?.transcriptionState
                            == .completed
                    }
                    if !recovered { captureFailures.append("Transcription retry did not complete") }
                    await capture("voice-recovery-complete.png")
                    let originalPlayer = model.audio.makePlayer
                    model.audio.makePlayer = { _ in SmokePlaybackPlayer() }
                    model.togglePlayback(thoughtName)
                    model.seekPlayback(thoughtName, to: 1)
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    await capture("message-playback-playing.png")
                    model.togglePlayback(thoughtName)
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    await capture("message-playback-paused.png")
                    model.seekPlayback(thoughtName, to: 2)
                    if !model.audio.paused || model.audio.position != 2 {
                        captureFailures.append("Paused seek did not preserve playback state")
                    }
                    NSApp.appearance = NSAppearance(named: .darkAqua)
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    await capture("message-playback-dark.png")
                    NSApp.appearance = NSAppearance(named: .aqua)
                    if let window = mainWindow { window.setContentSize(NSSize(width: 820, height: 700)) }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    await capture("message-playback-compact.png")
                    if let window = mainWindow { window.setContentSize(NSSize(width: 1120, height: 840)) }
                    model.stop()
                    model.audio.makePlayer = originalPlayer
                    model.notice = nil
                    model.history.query = ""
                    model.openConversationSearch()
                    model.find.query = "time"
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    await capture("conversation-search.png")
                    model.find.move(1)
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    await capture("conversation-search-next.png")
                    if model.find.matchIDs.count != 2 {
                        captureFailures.append("Current conversation search did not find both messages")
                    }
                    model.find.query = "no-such-message"
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    await capture("conversation-search-empty.png")
                    @MainActor func searchFields(_ view: NSView) -> [NSSearchField] {
                        (view as? NSSearchField).map { [$0] } ?? view.subviews.flatMap(searchFields)
                    }
                    let fields = mainWindow?.toolbar?.items.flatMap { item in item.view.map(searchFields) ?? [] } ?? []
                    if let field = fields.first(where: {
                        $0.placeholderString == String(localized: "Search this conversation")
                    }) {
                        if field.currentEditor() == nil {
                            captureFailures.append("Conversation search did not acquire keyboard focus")
                        }
                        field.stringValue = ""
                        if let action = field.action { NSApp.sendAction(action, to: field.target, from: field) }
                        if !model.find.query.isEmpty {
                            captureFailures.append("Native search cancel did not clear the query")
                        }
                    } else {
                        captureFailures.append("Native conversation search field was not installed")
                    }

                    if let window = mainWindow { window.setContentSize(NSSize(width: 820, height: 700)) }
                    model.find.query = "time"
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    await capture("conversation-search-compact.png")
                    let escapeCommand = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items).first {
                        $0.title == String(localized: "Stop") && $0.keyEquivalent == "\u{1b}"
                    }
                    let searchEpoch = model.turn.begin(.generating)
                    if let command = escapeCommand, let menu = command.menu {
                        menu.performActionForItem(at: menu.index(of: command))
                    }
                    if escapeCommand == nil || model.find.isOpen || model.turn.epoch != searchEpoch {
                        captureFailures.append("Escape must close search without cancelling a pending reply")
                    }
                    _ = model.turn.finish(searchEpoch)
                    model.find.close()
                    if let window = mainWindow { window.setContentSize(NSSize(width: 1120, height: 840)) }

                    if model.conversation?.messages.first(where: { $0.id == failed.id })?.transcriptionState
                        != .completed
                    {
                        captureFailures.append("Codex fixture recovery did not complete")
                    }
                } else {
                    captureFailures.append("No selected conversation for voice recovery, playback and search checks")
                }
                model.showExpressions = true
                try? await Task.sleep(nanoseconds: 300_000_000)
                await capture("expressions.png")
                model.showExpressions = false
                model.showHistory(.active)
                let ids = model.library.conversations.map(\.id)
                if ids.count >= 3 {
                    model.renameChat(ids[0], title: "A project I want to start")
                    model.pinChats([ids[0]], pinned: true)
                    model.archiveChats([ids[1]])
                    model.deleteChats([ids[2]])
                    model.select(ids[0])
                    model.draft = "I think the first step is…"
                    model.history.query = "project"
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    await capture("search.png")
                    model.showHistory(.archived)
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    await capture("archived.png")
                    model.showHistory(.deleted)
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    await capture("deleted.png")
                    model.history.managerOpen = true
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    await capture("manager.png")
                    model.history.permanentDeleteIDs = [ids[2]]
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    await capture("permanent-delete-confirmation.png")
                    model.history.permanentDeleteIDs = []
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    model.history.managerOpen = false
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    model.showHistory(.active)
                    model.history.renameID = ids[0]
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    await capture("rename.png")
                    model.history.renameID = nil
                    if let window = mainWindow { window.setContentSize(NSSize(width: 820, height: 700)) }
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    await capture("history-compact.png")
                } else {
                    captureFailures.append("History checks need at least three conversations; found \(ids.count)")
                }
                model.settingsTab = .general
                model.settingsOpen = true
                try? await Task.sleep(nanoseconds: 500_000_000)
                await capture("general-settings.png", settings: true)
                model.settingsTab = .automation
                try? await Task.sleep(nanoseconds: 350_000_000)
                await capture("automation-settings.png", settings: true)
                model.settingsTab = .voices
                try? await Task.sleep(nanoseconds: 350_000_000)
                await capture("voice-settings.png", settings: true)
                model.settingsTab = .about
                try? await Task.sleep(nanoseconds: 350_000_000)
                await capture("about-settings.png", settings: true)
                model.settingsTab = .privacy
                try? await Task.sleep(nanoseconds: 350_000_000)
                await capture("privacy-settings.png", settings: true)
                model.settingsTab = .desktopMochi
                try? await Task.sleep(nanoseconds: 350_000_000)
                await capture("desktop-settings.png", settings: true)
                // The desktop Mochi: shown from the preference, mirroring the turn, and gone again when turned off.
                // A capture left by an earlier run must never stand in for this one.
                if !removeStaleEvidence(directory.appendingPathComponent("desktop-pet.png")) {
                    captureFailures.append("desktop-pet.png: stale capture could not be removed")
                }
                // The preference is the preview's own; the check must leave it as it found it.
                let petWasVisible = model.petVisible
                model.petVisible = true
                if await waitFor(2, { self.pet.panel?.isVisible == true }), let petPanel = pet.panel {
                    if petPanel.canHide || petPanel.canBecomeKey || petPanel.frame.size != DesktopPet.size {
                        captureFailures.append("Desktop Mochi window can hide, take focus, or has the wrong size")
                    }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    await capture("desktop-pet.png", window: petPanel)
                    let epoch = model.turn.begin(.recording)
                    // Her own timer has to notice; a tick from here would hide a stopped timer.
                    if await !waitFor(2, { self.pet.currentPose == .review }) {
                        captureFailures.append("Desktop Mochi does not listen while recording")
                    }
                    _ = model.turn.finish(epoch)
                    model.petVisible = false
                    if petPanel.isVisible { captureFailures.append("Desktop Mochi stays after being turned off") }
                } else {
                    captureCount += 1
                    captureFailures.append("desktop-pet.png: Desktop Mochi did not appear")
                }
                model.petVisible = petWasVisible
                let pitchFixture = (0..<150).map { i -> PitchPoint in
                    let t = Double(i) * 0.015
                    let value = 7 + 3 * sin(t * 5) + (i.isMultiple(of: 2) ? 0.45 : -0.45) + (i == 88 ? 12 : 0)
                    return PitchPoint(time: t, hz: (55...65).contains(i) ? nil : 100 * pow(2, value / 12))
                }
                let comparison = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 680, height: 460), styleMask: [.titled, .closable],
                    backing: .buffered, defer: false)
                comparison.title = "Pitch contour · display comparison"
                comparison.isReleasedWhenClosed = false
                comparison.contentView = NSHostingView(
                    rootView: VStack(alignment: .leading, spacing: 14) {
                        Text("Original samples · straight segments").font(.headline)
                        PitchChart(reference: pitchFixture, attempt: [], normalized: false, smoothed: false).frame(
                            height: 150)
                        Text("Light smoothing · shape-preserving cubic curves").font(.headline)
                        PitchChart(reference: pitchFixture, attempt: [], normalized: false, smoothed: true).frame(
                            height: 150)
                        Text("Illustrative pitch data · pauses remain gaps · original analysis stays unchanged").font(
                            .caption
                        ).foregroundStyle(.secondary)
                    }.padding(20).frame(width: 680, height: 460))
                comparison.center()
                comparison.makeKeyAndOrderFront(nil)
                try? await Task.sleep(nanoseconds: 300_000_000)
                await capture("pitch-curves-comparison.png", window: comparison)
                NSApp.appearance = NSAppearance(named: .darkAqua)
                try? await Task.sleep(nanoseconds: 250_000_000)
                await capture("pitch-curves-comparison-dark.png", window: comparison)
                NSApp.appearance = NSAppearance(named: .aqua)
                comparison.orderOut(nil)
                model.settingsOpen = false
                for window in NSApp.windows where window !== mainWindow && window.isVisible && window.canBecomeMain {
                    window.performClose(nil)
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
                model.allowDemoAutomation = true
                model.externalControlEnabled = true
                let controlPath = model.controlSocketPath
                let helper = AutomationController.helperPath
                do {
                    if model.automationModal { throw AppFailure("Closing Settings left a conversation modal active.") }
                    let result = try await Task.detached {
                        try AutomationSmokeClient.run(helper: helper, socketPath: controlPath)
                    }.value
                    try result.write(to: directory.appendingPathComponent("mcp-after-settings.json"))
                    tray.closeToTray()
                    let hidden = await waitFor(2) {
                        mainWindow?.isVisible == false && NSApp.activationPolicy() == .accessory
                    }
                    let trayResult = try await Task.detached {
                        try AutomationSmokeClient.run(helper: helper, socketPath: controlPath)
                    }.value
                    try trayResult.write(to: directory.appendingPathComponent("mcp-in-tray.json"))
                    try JSONSerialization.data(withJSONObject: [
                        "settings_closed": true, "modal": model.automationModal, "tray_accessory": hidden,
                        "control_enabled": model.externalControlEnabled,
                    ]).write(to: directory.appendingPathComponent("mcp-lifecycle.json"))
                    if !hidden { captureFailures.append("MCP tray test did not enter accessory mode") }
                } catch { captureFailures.append("MCP Settings/tray regression failed: \(error)") }
                tray.showWindow()
                model.externalControlEnabled = false
                model.allowDemoAutomation = false
                model.newChat()
                let greetingPlayer = SmokePlaybackPlayer()
                model.audio.makePlayer = { _ in greetingPlayer }
                model.media.permission = { true }
                model.media.record = { _ in }
                model.media.recordingActive = { true }
                model.speech.referenceAudio = { _, _, root, _ in
                    let url = root.appendingPathComponent("greeting-fixture.wav")
                    try PCM.wav(Data(repeating: 0, count: 144000)).write(to: url)
                    return url
                }
                model.toggleConversationVoice()
                let greeting = await waitFor(3) {
                    model.turn.activity == .playing && model.greetingActive && model.conversation?.messages.count == 1
                }
                if !greeting {
                    captureFailures.append("Voice entry did not show its saved greeting")
                }
                await capture("voice-greeting.png")
                model.togglePlayback("greeting-fixture.wav", mochi: true)
                if await !waitFor(2, { model.audio.paused }) { captureFailures.append("Greeting pause failed") }
                await capture("voice-greeting-paused.png")
                model.audio.finishPlayback(greetingPlayer, successfully: true)
                if await !waitFor(3, { model.turn.activity == .recording && !model.greetingActive }) {
                    captureFailures.append(
                        "Greeting did not transition to recording (activity \(model.turn.activity), greeting "
                            + "\(model.greetingActive), error \(model.error ?? "none"))")
                }
                await capture("voice-greeting-listening.png")
                model.stop()
                // A conversation's own greeting is spoken as written, in the conversation's voice.
                model.newChat()
                var greetings: [(text: String, voice: String)] = []
                model.speech.referenceAudio = { text, service, root, _ in
                    greetings.append((text, service.voice))
                    let url = root.appendingPathComponent("greeting-own-fixture.wav")
                    try PCM.wav(Data(repeating: 0, count: 144000)).write(to: url)
                    return url
                }
                if let id = model.selectedID, var own = model.conversation.map(ConversationSettingsDraft.init) {
                    own.greeting = "Shall we begin with your week?"
                    own.preferences.voice = "cedar"
                    if !model.saveConversationSettings(id, own) {
                        captureFailures.append("The conversation's own greeting could not be saved")
                    }
                    model.toggleConversationVoice()
                    let spoken = await waitFor(3) {
                        model.turn.activity == .playing && model.greetingActive
                            && model.conversation?.messages.first?.text == own.greeting
                    }
                    if !spoken || greetings.last?.text != own.greeting || greetings.last?.voice != "cedar" {
                        captureFailures.append(
                            "The conversation's own greeting was not spoken as written in its voice "
                                + "(\(greetings.last.map { "\($0.text) · \($0.voice)" } ?? "nothing spoken"))")
                    }
                    await capture("voice-greeting-own.png")
                    model.audio.finishPlayback(greetingPlayer, successfully: true)
                    if await !waitFor(3, { model.turn.activity == .recording && !model.greetingActive }) {
                        captureFailures.append("The conversation's own greeting did not lead to recording")
                    }
                    model.stop()
                } else {
                    captureFailures.append("No conversation for its own greeting")
                }
                var passed =
                    captureFailures.isEmpty && model.library.expressions.count >= 1 && model.turn.mode == .conversation
                    && model.turn.owner == .none
                let report = try? JSONSerialization.data(
                    withJSONObject: [
                        "capture_count": captureCount, "view_capture_count": viewCaptureCount,
                        "failures": captureFailures,
                    ], options: [.prettyPrinted, .sortedKeys])
                if !(report.map { writeEvidence($0, to: directory.appendingPathComponent("smoke-report.json")) }
                    ?? false)
                {
                    passed = false
                }
                let summary = Data(
                    "Native smoke: \(passed ? "PASS" : "FAIL"). \(captureCount) native window and sheet snapshots (\(viewCaptureCount) AppKit view captures). Capture failures: \(captureFailures.count). No network, microphone or speaker output.\n"
                        .utf8)
                if !writeEvidence(summary, to: directory.appendingPathComponent("smoke.txt")) { passed = false }
                finishRun(model, passed: passed)
            }
        }
        func toolsProbe(_ model: AppModel) {
            guard !ran else { return }
            ran = true
            Task {
                let directory = URL(
                    fileURLWithPath: ProcessInfo.processInfo.environment["MOCHI_EVIDENCE_DIR"]
                        ?? "/tmp/mochi-tools-probe")
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                model.stop()
                model.leavePractice()
                model.newChat()
                let token = model.turn.begin(.generating)
                var calls: [String] = []
                var result = "FAIL"
                do {
                    let service = model.settings.conversationService()
                    let reply = try await service.reply(
                        ConversationRequest(
                            history: [],
                            text:
                                "Use get_session to find the current conversation ID, then use save_expression to save exactly: Could you give me a moment? Once the tool confirms success, say Saved.",
                            spoken: true,
                            instructions:
                                "For this test, execute the requested tools before answering. Reply with the single word Saved after success."
                        ),
                        onTool: { name, args, _ in
                            guard model.turn.epoch == token else { throw CancellationError() }
                            calls.append(name)
                            return try model.tools.execute(name, arguments: args, origin: .voice)
                        })
                    if !reply.audio.isEmpty && calls.contains("get_session") && calls.contains("save_expression")
                        && model.library.expressions.contains(where: {
                            $0.english == "Could you give me a moment?" && $0.conversationID == model.selectedID
                        }) && reply.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("saved")
                    {
                        result = "PASS"
                    }
                    var identityCases: [[String: Any]] = []
                    for (name, custom, expected) in [
                        (Optional("Loki"), "Your name is Sam.", "Loki"),
                        (Optional("Loki"), "Your name is Sam.", "Loki"),
                        (Optional("Loki"), "Your name is Sam.", "Loki"), (Optional("Renée"), "Discuss books.", "Renée"),
                        (Optional<String>.none, "Your name is Sam.", "Sam"),
                    ] {
                        let history = [Message(role: "assistant", text: "Hi, I'm Mochi.")]
                        let response = try await service.reply(
                            ConversationRequest(
                                history: history, text: "What is your name? Reply with only your name.",
                                instructions: custom, characterName: name))
                        identityCases.append([
                            "expected": expected, "response": response.text,
                            "passed": response.text.trimmingCharacters(
                                in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\".!")).union(
                                    CharacterSet(charactersIn: "“”"))
                            ).precomposedStringWithCanonicalMapping == expected.precomposedStringWithCanonicalMapping,
                        ])
                    }
                    var builtinCases: [[String: Any]] = []
                    for t in ConversationTemplate.builtins {
                        let response = try await service.reply(
                            ConversationRequest(
                                history: [], text: "Let's start. Ask me for the information you need.",
                                instructions: t.instructions, characterName: t.characterName, preferences: t.preferences
                            ))
                        builtinCases.append([
                            "title": t.title, "response": response.text,
                            "responded": !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                            "semantic_review_required": true,
                        ])
                    }
                    try JSONSerialization.data(
                        withJSONObject: [
                            "identity_cases": identityCases, "builtin_cases": builtinCases,
                            "audio_bytes": reply.audio.count, "auditioned": false,
                        ], options: [.prettyPrinted, .sortedKeys]
                    ).write(to: directory.appendingPathComponent("live-template-cases.json"))
                    if identityCases.contains(where: { $0["passed"] as? Bool != true })
                        || builtinCases.contains(where: { $0["responded"] as? Bool != true })
                    {
                        result = "FAIL identity/template cases"
                    }

                } catch {
                    result = "UNVERIFIED: " + AppFailure.message(for: error, fallback: "Provider connection failed.")
                }
                _ = model.turn.finish(token)
                let written = writeEvidence(
                    Data(
                        "Live Realtime instructions and tools: \(result). Calls: \(calls.joined(separator:", ")). Synthetic spoken response; audio returned without playback. No real library changes or microphone use.\n"
                            .utf8), to: directory.appendingPathComponent("live-tools-probe.txt"))
                finishRun(model, passed: written && result == "PASS")
            }
        }
        func probe(_ model: AppModel) {
            guard !ran else { return }
            ran = true
            Task {
                let directory = URL(
                    fileURLWithPath: ProcessInfo.processInfo.environment["MOCHI_EVIDENCE_DIR"] ?? ProcessInfo
                        .processInfo.environment["ENJOY_EVIDENCE_DIR"] ?? "/tmp/mochi-evidence")
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var lines: [String] = []
                do {
                    let service = model.settings.conversationService()
                    let result = try await service.reply(
                        ConversationRequest(history: [], text: "Reply with the single word ready."))
                    lines.append("Realtime text: \(!result.text.isEmpty ? "PASS" : "FAIL")")
                    let translation = try await service.reply(
                        ConversationRequest(history: [], text: "我一直拖着不做，因为不知道从哪里开始。", help: true))
                    lines.append(
                        "Help translation: \(!translation.text.isEmpty && translation.audio.isEmpty ? "PASS" : "FAIL")")
                    let spoken = try await service.reply(
                        ConversationRequest(history: [], text: "Say hello briefly.", spoken: true))
                    lines.append("Realtime audio generation: \(!spoken.audio.isEmpty ? "PASS" : "FAIL") (not played)")
                    let reference = try await model.settings.practiceService().referenceAudio(
                        text: "I would like a little more time to think.", root: model.store.root, force: true)
                    let samples = try AudioFile.samples(reference)
                    lines.append(
                        "Exact practice reference and local decode: \(!samples.samples.isEmpty ? "PASS" : "FAIL") (not played)"
                    )
                    if !spoken.audio.isEmpty {
                        let recovered = try await service.transcribe(spoken.audio)
                        lines.append(
                            "Standalone transcription recovery: \(!recovered.isEmpty ? "PASS" : "FAIL") (synthetic audio)"
                        )
                        let heard = try await service.reply(
                            ConversationRequest(history: [], text: "", pcm: spoken.audio))
                        lines.append(
                            "Synthetic audio input and transcription: \(!heard.inputTranscript.isEmpty && !heard.text.isEmpty ? "PASS" : "FAIL") (no microphone)"
                        )
                    }
                } catch { lines.append("Realtime: \(error.localizedDescription)") }
                let written = writeEvidence(
                    Data((lines.joined(separator: "\n") + "\n").utf8),
                    to: directory.appendingPathComponent("live-probe.txt"))
                finishRun(model, passed: written && !lines.isEmpty && lines.allSatisfy { $0.contains(": PASS") })
            }
        }
    }

    // Native layout fixtures never send sound to the speakers.
    final class SmokePlaybackPlayer: PlaybackPlayer {
        let duration: TimeInterval = 3
        var currentTime: TimeInterval = 0
        var enableRate = false
        var rate: Float = 1
        func play() -> Bool { true }
        func pause() {}
        func stop() {}
    }
#endif
