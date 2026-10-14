import MochiCore
import XCTest

final class ListeningMachineTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
    /// A machine listening since `t0` with a 120-second silence limit.
    private func listening() -> ListeningMachine {
        var machine = ListeningMachine(silenceLimit: 120)
        machine.handle(.start(now: t0, blockers: []))
        return machine
    }

    func testFullTurnCycleReturnsToListening() {
        var machine = listening()
        XCTAssertEqual(machine.phase, .listening)
        XCTAssertTrue(machine.microphoneOpen)
        XCTAssertEqual(machine.handle(.speechStarted), [])
        XCTAssertEqual(machine.phase, .hearingSpeech)
        XCTAssertTrue(machine.microphoneOpen)
        XCTAssertEqual(machine.handle(.endOfTurn), [.sendTurn])
        XCTAssertEqual(machine.phase, .endOfTurn)
        XCTAssertFalse(machine.microphoneOpen)
        machine.handle(.replyStarted)
        XCTAssertEqual(machine.phase, .waitingForReply)
        XCTAssertFalse(machine.microphoneOpen)
        machine.handle(.replyEnded)
        XCTAssertEqual(machine.phase, .mochiSpeaking)
        XCTAssertFalse(machine.microphoneOpen, "Mochi never listens while it speaks (D4)")
        machine.handle(.playbackEnded(now: at(30)))
        XCTAssertEqual(machine.phase, .listening)
        XCTAssertTrue(machine.microphoneOpen)
    }

    // MARK: Interrupting Mochi (H4)

    /// A machine with barge-in on, Mochi speaking its reply.
    private func speaking() -> ListeningMachine {
        var machine = listening()
        machine.bargeIn = true
        machine.handle(.speechStarted)
        machine.handle(.endOfTurn)
        machine.handle(.replyStarted)
        XCTAssertFalse(machine.microphoneOpen, "Mochi never listens while it thinks")
        machine.handle(.replyEnded)
        return machine
    }

    func testWithBargeInSpeechInterruptsMochiAndBecomesTheNextTurn() {
        var machine = speaking()
        XCTAssertEqual(machine.phase, .mochiSpeaking)
        XCTAssertTrue(machine.microphoneOpen, "Listening through Mochi's speech")
        XCTAssertNil(machine.silenceDeadline, "No silence is counted while Mochi speaks")
        XCTAssertEqual(machine.handle(.speechStarted), [.interruptPlayback])
        XCTAssertEqual(machine.phase, .hearingSpeech)
        // The playback the interruption stopped ends quietly; the turn goes on.
        XCTAssertEqual(machine.handle(.playbackEnded(now: at(5))), [])
        XCTAssertEqual(machine.phase, .hearingSpeech)
        XCTAssertEqual(machine.handle(.endOfTurn), [.sendTurn])
    }

    func testAnInterruptionThatWasNoiseStartsAFreshSilenceCount() {
        var machine = speaking()
        machine.handle(.speechStarted)
        machine.handle(.turnDiscarded(now: at(50)))
        XCTAssertEqual(machine.phase, .listening)
        XCTAssertEqual(machine.silenceDeadline, at(170))
    }

    func testAPauseWhileMochiSpeaksClosesTheMicrophoneAndLetsTheReplyFinish() {
        var machine = speaking()
        XCTAssertEqual(machine.handle(.pause(.screenLocked)), [])
        XCTAssertEqual(machine.phase, .mochiSpeaking)
        XCTAssertFalse(machine.microphoneOpen)
        XCTAssertEqual(machine.handle(.speechStarted), [], "Nothing is heard while paused")
        machine.handle(.resume(.screenLocked, now: at(3)))
        XCTAssertTrue(machine.microphoneOpen, "Listening through the rest of the reply again")
        machine.handle(.pause(.sheetOpen))
        machine.handle(.playbackEnded(now: at(4)))
        XCTAssertEqual(machine.phase, .paused, "Once the reply has played, listening pauses")
    }

    func testWithoutBargeInSpeechOverMochiIsNotHeard() {
        var machine = listening()
        machine.handle(.replyEnded)
        XCTAssertEqual(machine.phase, .mochiSpeaking)
        XCTAssertFalse(machine.microphoneOpen)
        XCTAssertEqual(machine.handle(.speechStarted), [])
        XCTAssertEqual(machine.phase, .mochiSpeaking)
    }

    func testStartAndStop() {
        var machine = ListeningMachine()
        XCTAssertEqual(machine.phase, .off)
        XCTAssertFalse(machine.isOn)
        XCTAssertTrue(machine.canStart)
        machine.handle(.start(now: t0, blockers: []))
        XCTAssertTrue(machine.isOn)
        XCTAssertFalse(machine.canStart)
        // A second start while listening changes nothing, including the silence deadline.
        let deadline = machine.silenceDeadline
        machine.handle(.start(now: at(50), blockers: []))
        XCTAssertEqual(machine.silenceDeadline, deadline)
        XCTAssertEqual(machine.handle(.stop), [])
        XCTAssertEqual(machine.phase, .off)
        XCTAssertNil(machine.silenceDeadline)
        XCTAssertEqual(machine.handle(.stop), [], "Stopping twice is harmless")
    }

    func testStoppingWhileHearingSpeechDiscardsTheTurn() {
        var machine = listening()
        machine.handle(.speechStarted)
        XCTAssertEqual(machine.handle(.stop), [.discardTurn])
        XCTAssertEqual(machine.phase, .off)
    }

    func testStoppingWhileWaitingOrSpeakingDiscardsNothing() {
        for setup in [[ListeningMachine.Event.replyStarted], [.replyStarted, .replyEnded]] {
            var machine = listening()
            machine.handle(.speechStarted)
            machine.handle(.endOfTurn)
            for event in setup { machine.handle(event) }
            XCTAssertEqual(machine.handle(.stop), [])
            XCTAssertEqual(machine.phase, .off)
        }
    }

    func testNoiseOnlyTurnReturnsToListeningAndKeepsTheSilenceBudget() {
        var machine = listening()
        machine.handle(.speechStarted)
        XCTAssertEqual(machine.handle(.turnDiscarded(now: at(10))), [])
        XCTAssertEqual(machine.phase, .listening)
        XCTAssertEqual(machine.silenceDeadline, at(120), "Noise is not speech: the earlier silence still counts")
        // A turn found to be noise only after it ended is dropped the same way.
        machine.handle(.speechStarted)
        machine.handle(.endOfTurn)
        machine.handle(.turnDiscarded(now: at(20)))
        XCTAssertEqual(machine.phase, .listening)
        XCTAssertEqual(machine.silenceDeadline, at(120))
    }

    func testRepeatedNoiseCannotKeepTheMicrophoneOpenPastTheLimit() {
        var machine = listening()
        for second in stride(from: 10.0, through: 200, by: 10) {
            machine.handle(.speechStarted)
            machine.handle(.turnDiscarded(now: at(second)))
        }
        XCTAssertEqual(machine.handle(.silenceTimer(now: at(200))), [.announceSilenceStop])
        XCTAssertEqual(machine.phase, .stoppedBySilence)
    }

    func testARealTurnStillRestartsTheSilenceTimer() {
        var machine = listening()
        machine.handle(.speechStarted)
        machine.handle(.endOfTurn)
        machine.handle(.replyStarted)
        machine.handle(.replyEnded)
        machine.handle(.playbackEnded(now: at(300)))
        XCTAssertEqual(machine.silenceDeadline, at(420))
    }

    func testEventsOutOfPlaceAreIgnored() {
        var machine = ListeningMachine()
        for event: ListeningMachine.Event in [
            .speechStarted, .endOfTurn, .turnDiscarded(now: t0), .replyStarted, .replyEnded,
            .playbackEnded(now: t0), .silenceTimer(now: at(10_000)), .networkFailure, .pause(.sheetOpen),
            .resume(.sheetOpen, now: t0),
        ] {
            XCTAssertEqual(machine.handle(event), [], "\(event)")
            XCTAssertEqual(machine.phase, .off, "\(event)")
        }
        XCTAssertTrue(machine.pauses.isEmpty, "Pauses are not remembered while off")
        machine = listening()
        XCTAssertEqual(machine.handle(.endOfTurn), [], "No turn ends before speech starts")
        XCTAssertEqual(machine.phase, .listening)
        machine.handle(.speechStarted)
        machine.handle(.speechStarted)
        XCTAssertEqual(machine.phase, .hearingSpeech)
    }

    // MARK: Silence timer

    func testSilenceTimerStartsWhenListeningStartsAndFiresOnce() {
        var machine = listening()
        XCTAssertEqual(machine.silenceDeadline, at(120))
        XCTAssertEqual(machine.handle(.silenceTimer(now: at(119))), [], "An early wake does nothing")
        XCTAssertEqual(machine.phase, .listening)
        XCTAssertEqual(machine.handle(.silenceTimer(now: at(120))), [.announceSilenceStop])
        XCTAssertEqual(machine.phase, .stoppedBySilence)
        XCTAssertFalse(machine.microphoneOpen)
        XCTAssertFalse(machine.isOn)
        XCTAssertNil(machine.silenceDeadline)
        XCTAssertEqual(machine.handle(.silenceTimer(now: at(500))), [], "It fires once")
        XCTAssertTrue(machine.canStart)
        machine.handle(.start(now: at(600), blockers: []))
        XCTAssertEqual(machine.phase, .listening)
        XCTAssertEqual(machine.silenceDeadline, at(720))
    }

    func testSilenceTimerStartsAtPlaybackEnd() {
        var machine = listening()
        machine.handle(.speechStarted)
        machine.handle(.endOfTurn)
        machine.handle(.replyStarted)
        machine.handle(.replyEnded)
        machine.handle(.playbackEnded(now: at(300)))
        XCTAssertEqual(machine.silenceDeadline, at(420), "Counted from the end of Mochi's reply, not from the turn")
        XCTAssertEqual(machine.handle(.silenceTimer(now: at(419))), [])
        XCTAssertEqual(machine.handle(.silenceTimer(now: at(420))), [.announceSilenceStop])
    }

    func testSilenceTimerResetsOnSpeech() {
        var machine = listening()
        machine.handle(.speechStarted)
        XCTAssertNil(machine.silenceDeadline)
        XCTAssertEqual(machine.handle(.silenceTimer(now: at(10_000))), [])
        XCTAssertEqual(machine.phase, .hearingSpeech)
    }

    func testSilenceTimerNeverFiresDuringATurnOrReply() {
        var machine = listening()
        machine.handle(.speechStarted)
        XCTAssertEqual(machine.handle(.silenceTimer(now: at(10_000))), [])
        machine.handle(.endOfTurn)
        XCTAssertEqual(machine.handle(.silenceTimer(now: at(10_000))), [])
        XCTAssertEqual(machine.phase, .endOfTurn)
        machine.handle(.replyStarted)
        XCTAssertEqual(machine.handle(.silenceTimer(now: at(10_000))), [])
        XCTAssertEqual(machine.phase, .waitingForReply)
        machine.handle(.replyEnded)
        XCTAssertEqual(machine.handle(.silenceTimer(now: at(10_000))), [])
        XCTAssertEqual(machine.phase, .mochiSpeaking)
    }

    func testSilenceTimerNeverFiresWhilePaused() {
        var machine = listening()
        machine.handle(.pause(.sheetOpen))
        XCTAssertNil(machine.silenceDeadline)
        XCTAssertEqual(machine.handle(.silenceTimer(now: at(10_000))), [])
        XCTAssertEqual(machine.phase, .paused)
        machine.handle(.resume(.sheetOpen, now: at(500)))
        XCTAssertEqual(machine.silenceDeadline, at(620), "Resuming starts a fresh wait")
    }

    func testSilenceLimitIsTheChosenSetting() {
        XCTAssertEqual(ListeningSilenceLimit.allCases.map(\.rawValue), [1, 2, 5, 10])
        for limit in ListeningSilenceLimit.allCases {
            var machine = ListeningMachine(silenceLimit: limit.seconds)
            machine.handle(.start(now: t0, blockers: []))
            XCTAssertEqual(machine.silenceDeadline, at(Double(limit.rawValue) * 60))
        }
        XCTAssertEqual(ListeningMachine().silenceLimit, 120, "Two minutes by default")
    }

    // MARK: Pauses

    func testEveryPauseReasonPausesAndResumes() {
        for reason in ListeningMachine.PauseReason.allCases {
            var machine = listening()
            XCTAssertEqual(machine.handle(.pause(reason)), [], "\(reason)")
            XCTAssertEqual(machine.phase, .paused, "\(reason)")
            XCTAssertFalse(machine.microphoneOpen, "\(reason)")
            XCTAssertTrue(machine.isOn, "\(reason)")
            machine.handle(.resume(reason, now: at(5)))
            XCTAssertEqual(machine.phase, .listening, "\(reason)")
        }
    }

    func testPauseWhileHearingSpeechDiscardsTheTurn() {
        for reason in ListeningMachine.PauseReason.allCases {
            var machine = listening()
            machine.handle(.speechStarted)
            XCTAssertEqual(machine.handle(.pause(reason)), [.discardTurn], "\(reason)")
            XCTAssertEqual(machine.phase, .paused, "\(reason)")
        }
    }

    func testListeningResumesOnlyWhenTheLastPauseEnds() {
        var machine = listening()
        machine.handle(.pause(.windowHidden))
        machine.handle(.pause(.screenLocked))
        machine.handle(.resume(.windowHidden, now: at(1)))
        XCTAssertEqual(machine.phase, .paused)
        XCTAssertEqual(machine.pauses, [.screenLocked])
        machine.handle(.resume(.sheetOpen, now: at(2)))
        XCTAssertEqual(machine.phase, .paused, "Ending a pause that never began changes nothing")
        machine.handle(.resume(.screenLocked, now: at(3)))
        XCTAssertEqual(machine.phase, .listening)
    }

    func testPauseDuringAReplyTakesEffectAfterPlayback() {
        var machine = listening()
        machine.handle(.speechStarted)
        machine.handle(.endOfTurn)
        machine.handle(.replyStarted)
        XCTAssertEqual(machine.handle(.pause(.expressionsOpen)), [])
        XCTAssertEqual(machine.phase, .waitingForReply, "The reply in progress finishes")
        machine.handle(.replyEnded)
        machine.handle(.playbackEnded(now: at(9)))
        XCTAssertEqual(machine.phase, .paused)
        XCTAssertFalse(machine.microphoneOpen)
        machine.handle(.resume(.expressionsOpen, now: at(10)))
        XCTAssertEqual(machine.phase, .listening)
    }

    func testStartingWhilePausedClearsReasonsThatNoLongerHold() {
        var machine = listening()
        machine.handle(.pause(.conversationSwitched))
        XCTAssertTrue(machine.canStart)
        machine.handle(.start(now: at(5), blockers: []))
        XCTAssertEqual(machine.phase, .listening)
        XCTAssertTrue(machine.pauses.isEmpty)
    }

    func testStartingWhileSomethingBlocksStartsPaused() {
        var machine = ListeningMachine()
        machine.handle(.start(now: t0, blockers: [.sheetOpen]))
        XCTAssertEqual(machine.phase, .paused)
        XCTAssertTrue(machine.isOn)
        XCTAssertNil(machine.silenceDeadline)
        machine.handle(.resume(.sheetOpen, now: at(4)))
        XCTAssertEqual(machine.phase, .listening)
        XCTAssertEqual(machine.silenceDeadline, at(124))
    }

    func testStopForgetsPauses() {
        var machine = listening()
        machine.handle(.pause(.screenLocked))
        machine.handle(.stop)
        XCTAssertTrue(machine.pauses.isEmpty)
        machine.handle(.start(now: t0, blockers: []))
        XCTAssertEqual(machine.phase, .listening)
    }

    // MARK: Other activity and failures

    func testAReplyStartedFromElsewhereClosesTheMicrophone() {
        // The learner typed a message, or played an earlier recording, while Mochi was listening.
        var machine = listening()
        machine.handle(.replyStarted)
        XCTAssertEqual(machine.phase, .waitingForReply)
        XCTAssertFalse(machine.microphoneOpen)
        machine.handle(.playbackEnded(now: at(5)))
        XCTAssertEqual(machine.phase, .listening)
        machine.handle(.replyEnded)
        XCTAssertEqual(machine.phase, .mochiSpeaking)
        machine.handle(.playbackEnded(now: at(6)))
        XCTAssertEqual(machine.phase, .listening)
    }

    func testOtherActivityDuringSpeechDiscardsTheTurn() {
        var machine = listening()
        machine.handle(.speechStarted)
        XCTAssertEqual(machine.handle(.replyStarted), [.discardTurn])
        machine = listening()
        machine.handle(.speechStarted)
        XCTAssertEqual(machine.handle(.replyEnded), [.discardTurn])
    }

    func testAReplyThatEndsWithoutPlaybackReturnsToListening() {
        var machine = listening()
        machine.handle(.speechStarted)
        machine.handle(.endOfTurn)
        machine.handle(.replyStarted)
        machine.handle(.playbackEnded(now: at(4)))
        XCTAssertEqual(machine.phase, .listening)
        // The turn was handed on but the hand-off ended before any work began.
        machine.handle(.speechStarted)
        machine.handle(.endOfTurn)
        machine.handle(.playbackEnded(now: at(5)))
        XCTAssertEqual(machine.phase, .listening)
    }

    func testNetworkFailureFallsBackToPressToSend() {
        var machine = listening()
        machine.handle(.speechStarted)
        XCTAssertEqual(machine.handle(.networkFailure), [.discardTurn, .fallBackToPressToSend])
        XCTAssertEqual(machine.phase, .failed)
        XCTAssertFalse(machine.microphoneOpen)
        XCTAssertFalse(machine.isOn)
        XCTAssertEqual(machine.handle(.networkFailure), [], "Reported once")
        machine = listening()
        XCTAssertEqual(machine.handle(.networkFailure), [.fallBackToPressToSend])
        XCTAssertTrue(machine.canStart)
        machine.handle(.start(now: t0, blockers: []))
        XCTAssertEqual(machine.phase, .listening)
    }

    func testPatienceMapsToEagerness() {
        XCTAssertEqual(ListeningPatience.patient.eagerness, "low")
        XCTAssertEqual(ListeningPatience.balanced.eagerness, "medium")
        XCTAssertEqual(ListeningPatience.quick.eagerness, "high")
    }
}
