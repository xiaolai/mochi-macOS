import Foundation

/// How the learner hands a spoken turn to Mochi.
public enum TalkingMode: String, CaseIterable, Sendable {
    /// Press to start, press again to send: one recording per press.
    case pressToSend
    /// The microphone stays open; each turn is sent when Mochi judges the learner has finished.
    case handsFree
}

/// How long Mochi waits for the learner to finish a hands-free turn, as `semantic_vad` eagerness.
public enum ListeningPatience: String, CaseIterable, Sendable {
    case patient, balanced, quick
    /// `low` lets the learner take their time; `medium` is the API default; `high` ends turns soonest.
    public var eagerness: String {
        switch self {
        case .patient: return "low"
        case .balanced: return "medium"
        case .quick: return "high"
        }
    }
}

/// How long hands-free listening waits in silence before it closes the microphone. There is no "never": an open
/// microphone the learner has forgotten is the failure this exists to prevent.
public enum ListeningSilenceLimit: Int, CaseIterable, Sendable {
    case oneMinute = 1
    case twoMinutes = 2
    case fiveMinutes = 5
    case tenMinutes = 10
    public var seconds: TimeInterval { TimeInterval(rawValue * 60) }
}

/// Hands-free listening as a pure state machine (plan H1). Events come in; the phase, the silence deadline and the
/// effects the app must carry out come out. Audio, network and timers stay outside, so every rule is a unit test.
///
/// `off → listening → hearingSpeech → endOfTurn → waitingForReply → mochiSpeaking → listening`, plus
/// `stoppedBySilence`, `paused` and `failed`. The microphone is open while `listening` or `hearingSpeech`, and while
/// `mochiSpeaking` when `bargeIn` is on (plan H4): speech then interrupts Mochi and becomes the next turn. Mochi never
/// listens while it thinks, and without `bargeIn` never while it speaks (plan D4).
public struct ListeningMachine: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case off, listening, hearingSpeech, endOfTurn, waitingForReply, mochiSpeaking, stoppedBySilence, paused, failed
    }
    /// Why listening is paused. Several can hold at once; listening resumes when the last one ends.
    public enum PauseReason: String, CaseIterable, Sendable {
        case windowHidden, screenLocked, conversationSwitched, expressionsOpen, sheetOpen
    }
    public enum Event: Equatable, Sendable {
        /// The learner turned listening on. `blockers` are the pause reasons that hold right now.
        case start(now: Date, blockers: Set<PauseReason>)
        /// The learner turned listening off.
        case stop
        /// The Mac heard the start of speech.
        case speechStarted
        /// The turn ended: judged by the API, or the learner chose Send Now, or it reached its time limit.
        case endOfTurn
        /// The turn held no speech and was dropped without a message.
        case turnDiscarded(now: Date)
        /// Mochi started working on something: a reply, an attempt check, or anything else that owns the turn.
        case replyStarted
        /// Mochi started playing audio.
        case replyEnded
        /// Mochi is idle again: playback ended, or the work ended without any.
        case playbackEnded(now: Date)
        /// The silence timer woke at `now`.
        case silenceTimer(now: Date)
        /// The listening session failed; hands-free falls back to press to send.
        case networkFailure
        case pause(PauseReason)
        case resume(PauseReason, now: Date)
    }
    public enum Effect: Equatable, Sendable {
        /// Hand the finished turn to the ordinary path (plan D3).
        case sendTurn
        /// Drop the turn in progress without creating anything.
        case discardTurn
        /// Listening stopped after silence; say so once.
        case announceSilenceStop
        /// The session failed; tell the learner that press to send still works.
        case fallBackToPressToSend
        /// The learner started speaking over Mochi: stop its playback; the speech is the next turn.
        case interruptPlayback
    }

    public private(set) var phase: Phase = .off
    public private(set) var pauses: Set<PauseReason> = []
    /// When the silence timer fires; set only while `listening`.
    public private(set) var silenceDeadline: Date?
    /// The deadline that was running when the Mac heard speech start, restored if that turn turns out to be noise.
    private var deadlineBeforeTurn: Date?
    public var silenceLimit: TimeInterval
    /// Whether the learner can interrupt Mochi by speaking: the microphone stays open while Mochi speaks.
    public var bargeIn = false

    public init(silenceLimit: TimeInterval = ListeningSilenceLimit.twoMinutes.seconds) {
        self.silenceLimit = silenceLimit
    }

    /// The microphone is open in these phases only.
    public var microphoneOpen: Bool {
        phase == .listening || phase == .hearingSpeech || (bargeIn && phase == .mochiSpeaking && pauses.isEmpty)
    }
    /// False when listening is off, or ended by itself; the learner turns it on again.
    public var isOn: Bool { ![.off, .stoppedBySilence, .failed].contains(phase) }
    /// Whether turning listening on now would start it; from `paused` it does, clearing the pauses that do not hold.
    public var canStart: Bool { !isOn || phase == .paused }

    @discardableResult public mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .start(let now, let blockers):
            guard canStart else { return [] }
            pauses = blockers
            if blockers.isEmpty { listen(from: now) } else { enterPause() }
            return []
        case .stop:
            guard phase != .off else { return [] }
            let effects = dropTurnInProgress()
            phase = .off
            pauses = []
            silenceDeadline = nil
            return effects
        case .speechStarted:
            if phase == .mochiSpeaking && microphoneOpen {
                // No silence was being counted while Mochi spoke; noise discarded later starts a fresh count.
                phase = .hearingSpeech
                deadlineBeforeTurn = nil
                return [.interruptPlayback]
            }
            guard phase == .listening else { return [] }
            phase = .hearingSpeech
            deadlineBeforeTurn = silenceDeadline
            silenceDeadline = nil
            return []
        case .endOfTurn:
            guard phase == .hearingSpeech else { return [] }
            phase = .endOfTurn
            return [.sendTurn]
        case .turnDiscarded(let now):
            guard phase == .hearingSpeech || phase == .endOfTurn else { return [] }
            // Noise is not speech: the silence that came before it still counts, so noise alone never keeps the
            // microphone open past the limit.
            let kept = deadlineBeforeTurn
            resumeAfterTurn(at: now)
            if phase == .listening, let kept { silenceDeadline = kept }
            return []
        case .replyStarted:
            guard [.listening, .hearingSpeech, .endOfTurn, .mochiSpeaking].contains(phase) else { return [] }
            let effects = dropTurnInProgress()
            phase = .waitingForReply
            silenceDeadline = nil
            return effects
        case .replyEnded:
            guard [.listening, .hearingSpeech, .endOfTurn, .waitingForReply].contains(phase) else { return [] }
            let effects = dropTurnInProgress()
            phase = .mochiSpeaking
            silenceDeadline = nil
            return effects
        case .playbackEnded(let now):
            guard [.endOfTurn, .waitingForReply, .mochiSpeaking].contains(phase) else { return [] }
            resumeAfterTurn(at: now)
            return []
        case .silenceTimer(let now):
            // Only plain listening counts silence: never while a turn, a reply or playback is in progress.
            guard phase == .listening, let silenceDeadline, now >= silenceDeadline else { return [] }
            phase = .stoppedBySilence
            pauses = []
            self.silenceDeadline = nil
            return [.announceSilenceStop]
        case .networkFailure:
            guard isOn else { return [] }
            var effects = dropTurnInProgress()
            phase = .failed
            pauses = []
            silenceDeadline = nil
            effects.append(.fallBackToPressToSend)
            return effects
        case .pause(let reason):
            guard isOn else { return [] }
            pauses.insert(reason)
            // A reply in progress finishes; listening pauses once it has played. The pause closes the microphone
            // Mochi was listening through while it spoke.
            guard phase == .listening || phase == .hearingSpeech else { return [] }
            let effects = dropTurnInProgress()
            enterPause()
            return effects
        case .resume(let reason, let now):
            guard isOn, pauses.remove(reason) != nil, phase == .paused, pauses.isEmpty else { return [] }
            listen(from: now)
            return []
        }
    }

    private mutating func listen(from now: Date) {
        phase = .listening
        silenceDeadline = now.addingTimeInterval(silenceLimit)
    }
    private mutating func enterPause() {
        phase = .paused
        silenceDeadline = nil
    }
    private mutating func resumeAfterTurn(at now: Date) {
        if pauses.isEmpty { listen(from: now) } else { enterPause() }
    }
    /// A turn that is still being heard has nowhere to go once listening leaves it.
    private func dropTurnInProgress() -> [Effect] { phase == .hearingSpeech ? [.discardTurn] : [] }
}
