import Foundation
import MochiCore

/// What happened when the user asked to talk from outside the workspace.
enum QuickTalk: Equatable {
    /// Started or finished a voice message, or skipped the greeting to record.
    case microphone
    /// Paused or resumed the audio that is playing.
    case pause
    /// Mochi is preparing a reply or waiting for permission; nothing changed.
    case busy
    /// Talking needs the workspace, which is now in front.
    case workspace
}

/// The desktop Mochi and the shortcuts that work in every app.
extension AppModel {
    var petVisible: Bool {
        get { settings.petVisible }
        set {
            settings.petVisible = newValue
            updateDesktopPet?()
        }
    }

    var petBarVisible: Bool {
        get { settings.petBarVisible }
        set {
            settings.petBarVisible = newValue
            updateDesktopPet?()
        }
    }

    /// Sends text typed under the desktop Mochi to the open conversation; the workspace composer and its draft are
    /// left alone. A conversation that cannot take messages here, or whose character name needs review, brings the
    /// workspace forward, as quick talk does. Returns whether the message was added, so text that was not sent stays
    /// in the bar.
    @discardableResult func sendFromDesktop(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        guard !practice, writableConversation, libraryReadable else {
            revealWorkspace?()
            return false
        }
        guard submit(text, fromComposer: false) else {
            // The review's reason is reported in the workspace, where the name can be fixed.
            if conversation?.characterNameNeedsReview == true { revealWorkspace?() }
            return false
        }
        return true
    }

    func setShortcut(_ shortcut: Shortcut?, for action: ShortcutAction) {
        settings.shortcuts[action] = shortcut
        shortcuts.apply()
    }

    /// Registers the stored shortcuts; called once the app has finished launching.
    func configureShortcuts() { shortcuts.apply() }

    /// Whether talking from outside the workspace uses the microphone here. Practice, a conversation that cannot
    /// take messages, and a character name that needs review all need the workspace, where the reason is visible.
    var canQuickTalk: Bool {
        !practice && writableConversation && libraryReadable
            && (turn.activity == .recording || greetingActive || conversation?.characterNameNeedsReview != true)
    }

    /// What quick talk would do now. The click, the menu and the accessibility label all follow this one rule.
    var quickTalkPlan: QuickTalk {
        guard canQuickTalk else { return .workspace }
        if turn.activity == .recording || greetingActive || !busy { return .microphone }
        return turn.activity == .playing ? .pause : .busy
    }

    /// Names what quick talk does now, or what Mochi is busy with when it does nothing.
    var quickTalkLabel: String {
        switch quickTalkPlan {
        case .microphone: return microphoneLabel
        case .pause: return audio.paused ? String(localized: "Resume") : String(localized: "Pause")
        case .workspace: return String(localized: "Open Mochi")
        case .busy: return status
        }
    }

    /// Talks from the desktop Mochi or the Talk shortcut, following the workspace microphone button's rules.
    @discardableResult func quickTalk() -> QuickTalk {
        let plan = quickTalkPlan
        switch plan {
        case .workspace: revealWorkspace?()
        case .microphone: toggleConversationVoice()
        case .pause:
            audio.togglePause()
            if listening.isOn { syncListening() }
        case .busy: break
        }
        return plan
    }

    /// A press held this long is push-to-talk: letting go sends the message.
    static let holdToTalk: TimeInterval = 0.4

    func shortcutTriggered(_ action: ShortcutAction, pressed: Bool) {
        switch action {
        case .togglePet:
            if pressed { petVisible.toggle() }
        case .listen:
            if pressed { toggleListening() }
        case .sendNow:
            if pressed { sendNow() }
        case .talk:
            // Hands-free, Talk to Mochi starts listening instead of recording one message.
            if handsFree {
                guard pressed else { return }
                // Only ever starts: while Mochi plays or thinks, listening starts and waits for it to finish.
                if !canQuickTalk {
                    quickTalk()
                } else if listening.canStart && listeningRequest == nil {
                    startListening()
                }
                return
            }
            if pressed {
                let outcome = quickTalk()
                // A press that asked for the microphone owns that request, including one that skipped the greeting.
                // A conversation's first voice message starts with Mochi's greeting and then listens. Nothing has
                // been said while the key is held, so that press acts as a tap: listening stays on until the next one.
                let started = outcome == .microphone && turn.activity == .requestingPermission && !greetingActive
                talkPress = (recordingNow(), started ? turn.epoch : nil)
            } else if let press = talkPress {
                talkPress = nil
                guard let request = press.request, recordingNow().timeIntervalSince(press.time) >= Self.holdToTalk
                else { return }
                if turn.activity == .recording && recordingRequest == request {
                    // Push-to-talk: letting go sends the recording this press started, never a later one.
                    quickTalk()
                } else if turn.activity == .requestingPermission && turn.epoch == request {
                    // Let go before the microphone opened: nothing was said, so nothing starts.
                    cancelRecording()
                }
            }
        }
    }
}
