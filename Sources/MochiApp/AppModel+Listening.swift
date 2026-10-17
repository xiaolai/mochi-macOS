import AppKit
import MochiCore
import MochiKernel
import MochiProviders
import PCM16

/// Where a hands-free turn goes: a voice message in a conversation, or a practice attempt.
enum ListeningContext: Equatable {
    case conversation(UUID)
    case practice
}

/// Why a hands-free turn ended.
enum ListeningTurnEnd: Equatable {
    /// The API judged the learner finished.
    case api
    /// The learner chose Send Now.
    case sendNow
    /// The turn reached the recording limit.
    case limit
    /// A practice attempt, judged on the Mac.
    case mac
}

/// What hands-free listening holds between events: the turn being heard, its connection, and its timers. The
/// rules live in `ListeningMachine`; this is only the audio and the tasks that carry them out.
@MainActor final class ListeningRuntime {
    var detector = SpeechActivityDetector()
    var preRoll = PreRollBuffer(milliseconds: 700)
    /// The turn's audio from the pre-roll on; it becomes the message or attempt.
    var turnAudio = Data()
    /// Audio heard before the connection finished opening, sent once it has.
    var unsent = Data()
    /// True once the API reported hearing speech in this turn.
    var apiHeardSpeech = false
    var line: (any ListeningLine)?
    var opening: Task<Void, Never>?
    var signalTask: Task<Void, Never>?
    var silenceTask: Task<Void, Never>?
    var scheduledDeadline: Date?
    /// Changes whenever the connection is dropped, so a late callback from an old one does nothing.
    var lineGeneration = UUID()
    /// Idle connections that dropped and were reopened quietly since the last turn.
    var quietReopens = 0
    /// The context listening was started in; another one pauses it.
    var context: ListeningContext?
    /// Why listening fell back to press to send, for the notice.
    var failure: String?
    /// The capture now running; audio or an interruption from any earlier one is ignored.
    var captureGeneration: UUID?
    /// Audio of this turn sent to an open connection as it was heard, not as a backlog after the handshake.
    var liveBytes = 0
    /// Pending check that Mochi is still idle once a run of activity changes has settled.
    var idleCheck: UUID?
    /// How much audio before the detected start of speech the turn holds, in seconds.
    var turnLead: TimeInterval = 0
    /// The practice sentence when the turn's speech started.
    var practiceTarget = ""
    /// Why the latest turn ended.
    var lastEnd: ListeningTurnEnd?
}

/// Hands-free listening (plan H2): the microphone stays open, each turn is sent when it ends, and the microphone
/// closes after a stretch of silence. `ListeningMachine` decides; this file carries its decisions out.
extension AppModel {
    /// Audio kept from before the detected start of speech, so the first word is not clipped.
    static let listeningPreRollMilliseconds = 300
    /// A turn the API has not heard any speech in after this long is room noise, and is dropped.
    static let listeningNoSpeechLimit: Double = 4
    /// A practice attempt is judged on the Mac (plan D7): it ends after this much quiet.
    static let practiceEndSilence: TimeInterval = 1.2
    /// A sound shorter than this, judged on the Mac, is noise rather than an attempt.
    static let practiceMinimumSpeech: TimeInterval = 0.4

    /// The talking mode the microphone follows now: hands-free, unless a failed session fell back to press to send.
    var handsFree: Bool { settings.talkingMode == .handsFree && !handsFreeFallback }

    /// Where a turn heard now would go, or nil when nothing can take one.
    var listeningContext: ListeningContext? {
        if practice {
            return help.stage == .practice && canRecordAttempt ? .practice : nil
        }
        guard !showExpressions, writableConversation, let id = selectedID else { return nil }
        return .conversation(id)
    }

    /// Conditions that hold right now and keep the microphone closed.
    var listeningBlockers: Set<ListeningMachine.PauseReason> {
        var blockers: Set<ListeningMachine.PauseReason> = []
        if screenLocked { blockers.insert(.screenLocked) }
        if workspaceHidden { blockers.insert(.windowHidden) }
        if showExpressions { blockers.insert(.expressionsOpen) }
        if customization.isPresented || history.isEditing || transcriptEditID != nil || panelOpen
            || (practice && help.stage != .practice)
        {
            blockers.insert(.sheetOpen)
        }
        return blockers
    }

    /// Whether Start Listening can do anything here.
    var canStartListening: Bool {
        libraryReadable && listening.canStart && listeningContext != nil
            && (practice || conversation?.characterNameNeedsReview != true)
    }

    var listeningMenuTitle: String {
        listening.canStart && listeningRequest == nil
            ? String(localized: "Start Listening") : String(localized: "Stop Listening")
    }

    /// What the microphone is doing, for the status line; nil when listening has nothing to say.
    var listeningStatus: String? {
        switch listening.phase {
        case .off, .failed, .waitingForReply, .mochiSpeaking: return nil
        // Hearing speech comes and goes with every pause, so it changes the icon, never the words: a line that
        // rewrote itself on each breath flashed.
        case .listening, .hearingSpeech:
            return String(localized: "Listening · audio is sent only once you speak")
        case .endOfTurn: return String(localized: "Sending your turn…")
        case .paused: return String(localized: "Listening paused · microphone off")
        case .stoppedBySilence: return String(localized: "Stopped listening after silence · microphone off")
        }
    }

    /// The microphone button's symbol while listening is on, or nil to show the press to send symbol.
    var listeningSymbol: String? {
        switch listening.phase {
        case .off, .failed: return nil
        case .listening: return "ear"
        case .hearingSpeech: return "waveform"
        case .endOfTurn, .waitingForReply: return "ellipsis.bubble"
        case .mochiSpeaking: return "speaker.wave.2"
        case .paused: return "pause.circle"
        case .stoppedBySilence: return "mic.slash"
        }
    }

    // MARK: Starting and stopping

    /// Start or Stop Listening: turns hands-free listening on or off in the current conversation or practice sheet.
    func toggleListening() {
        // A start still waiting for microphone permission counts as on: the next toggle cancels it.
        if listening.canStart && listeningRequest == nil { startListening() } else { stopListening() }
    }

    func startListening() {
        guard listening.canStart else { return }
        guard libraryReadable, let context = listeningContext else {
            // From another app, the workspace shows why nothing can listen here.
            if listeningContext == nil { revealWorkspace?() }
            return
        }
        if case .conversation = context, conversation?.characterNameNeedsReview == true {
            error = String(localized: "Review the character name in Conversation Instructions before recording.")
            return
        }
        error = nil
        let request = UUID()
        listeningRequest = request
        Task { [weak self] in
            guard let self else { return }
            let allowed = await media.permission()
            guard listeningRequest == request else { return }
            listeningRequest = nil
            guard listening.canStart, listeningContext == context else { return }
            guard allowed else {
                error = String(
                    localized:
                        "Microphone access is off. Enable Mochi in System Settings → Privacy & Security → Microphone.")
                return
            }
            handsFreeFallback = false
            listeningRuntime.failure = nil
            listeningRuntime.context = context
            listeningRuntime.quietReopens = 0
            listening.silenceLimit = settings.listeningSilenceLimit.seconds
            handleListening(.start(now: listeningNow(), blockers: listeningBlockers))
            // A conversation that greets first greets before its first turn, as press to send does.
            if case .conversation(let id) = context, !busy, let chat = conversation, chat.id == id,
                chat.greetsBeforeRecording
            {
                speakGreeting(chat, afterGreeting: nil)
            }
        }
    }

    func stopListening() {
        listeningRequest = nil
        handleListening(.stop)
    }

    /// Ends the turn being heard at once and sends it.
    var canSendNow: Bool { listening.phase == .hearingSpeech }
    func sendNow() {
        guard canSendNow else { return }
        endListeningTurn(.sendNow)
    }

    // MARK: The machine

    /// Feeds an event to the machine, carries out its effects, then brings the microphone, the connection and the
    /// silence timer in line with the phase it is in.
    func handleListening(_ event: ListeningMachine.Event) {
        let effects = listening.handle(event)
        for effect in effects {
            switch effect {
            case .sendTurn: break  // `endListeningTurn` hands the turn on itself, once the machine agreed.
            case .discardTurn: dropListeningTurn()
            case .announceSilenceStop:
                // The limit this listening ran with, which a change in Settings since it started does not alter.
                let minutes = Int((listening.silenceLimit / 60).rounded())
                notice = String(
                    localized:
                        "Stopped listening after \(minutes) min of silence. Start listening again when you’re ready.")
            case .interruptPlayback: interruptReply()
            case .fallBackToPressToSend:
                handsFreeFallback = true
                let reason = listeningRuntime.failure ?? String(localized: "The listening connection ended.")
                error = String(
                    localized:
                        "Listening stopped: \(reason) The microphone button records one message at a time until you start listening again."
                )
            }
        }
        syncListening()
    }

    /// Reconciles capture, connection and timer with the machine's phase. Safe to call at any time.
    func syncListening() {
        let runtime = listeningRuntime
        // The learner can interrupt Mochi only in a conversation, and only while the speech plays through the
        // listening microphone's echo canceller; anything else playing keeps the microphone closed (D4), so Mochi
        // never hears itself. Practice never listens over the sentence, so an attempt never starts there.
        // Speech plays through the listening engine only while the microphone is open to hear an interruption. Once
        // listening stops or pauses, or the learner pauses the reply, it moves to an ordinary player at the same
        // point, so the engine, and with it the microphone, can stop.
        if audio.playingRouted && (!listening.isOn || !listening.pauses.isEmpty || audio.paused) {
            audio.moveToOrdinaryPlayer()
        }
        listening.bargeIn = runtime.context.map { $0 != .practice } == true && audio.playingRouted
        // The microphone never opens while Mochi works or records, nor while it speaks unless the learner can
        // interrupt it: whatever started or resumed listening, the turn's current activity decides first.
        let speakingWithBargeIn = turn.activity == .playing && listening.phase == .mochiSpeaking
        if listening.microphoneOpen && turn.activity != .idle && !speakingWithBargeIn {
            handleListening(turn.activity == .playing ? .replyEnded : .replyStarted)
            return
        }
        if listening.microphoneOpen && !listeningServices.capturing() {
            let generation = UUID()
            runtime.captureGeneration = generation
            do {
                try listeningServices.startCapture(
                    { [weak self] pcm in
                        guard let self, listeningRuntime.captureGeneration == generation else { return }
                        listeningAudio(pcm)
                    },
                    { [weak self] in
                        guard let self, listeningRuntime.captureGeneration == generation else { return }
                        listeningCaptureStopped()
                    })
            } catch {
                runtime.captureGeneration = nil
                MochiLog.failure(MochiLog.audio, "Start listening capture", error)
                listening.handle(.stop)
                self.error = AppFailure.message(
                    for: error, fallback: "Could not start the microphone. Check Sound settings and retry.")
                // Listening is off now: reconcile again, so a reply still playing through the listening engine moves
                // off it and the engine, and the microphone with it, stops.
                syncListening()
                return
            }
        }
        if !listening.microphoneOpen {
            runtime.captureGeneration = nil
            if listeningServices.capturing() { listeningServices.stopCapture() }
            // A new stream: the detector's positions and the pre-roll's both start again at 0.
            runtime.detector.restart()
            runtime.preRoll = PreRollBuffer(milliseconds: 700)
        }
        // A conversation turn is judged by the API: its connection opens before speech, so no handshake delays
        // the turn, and nothing is streamed until speech starts.
        let wantsLine = listening.microphoneOpen && listeningRuntime.context.map { $0 != .practice } == true
        if !wantsLine && (runtime.line != nil || runtime.opening != nil) { closeListeningLine() }
        if wantsLine && runtime.line == nil && runtime.opening == nil { openListeningLine() }
        scheduleSilenceTimer()
        listeningIndicator?(listening.microphoneOpen)
    }

    private func scheduleSilenceTimer() {
        let runtime = listeningRuntime
        guard let deadline = listening.silenceDeadline else {
            runtime.silenceTask?.cancel()
            runtime.silenceTask = nil
            runtime.scheduledDeadline = nil
            return
        }
        guard runtime.scheduledDeadline != deadline else { return }
        runtime.silenceTask?.cancel()
        runtime.scheduledDeadline = deadline
        let wait = max(0, deadline.timeIntervalSince(listeningNow()))
        let sleep = listeningSleep
        runtime.silenceTask = Task { [weak self] in
            do { try await sleep(UInt64(wait * 1_000_000_000)) } catch { return }
            guard let self, !Task.isCancelled, listening.silenceDeadline == deadline else { return }
            // Cleared first: a wake that came early is rescheduled by the sync the event ends with.
            listeningRuntime.scheduledDeadline = nil
            handleListening(.silenceTimer(now: listeningNow()))
        }
    }

    // MARK: Interrupting Mochi

    /// The learner spoke over Mochi (plan H4): playback stops, and a reply keeps only the share of its text that was
    /// heard, so the conversation goes on from what the learner actually heard. The speech is the next turn.
    private func interruptReply() {
        guard turn.activity == .playing else { return }
        let heard = audio.duration > 0 ? audio.elapsed / audio.duration : 1
        // Only a reply heard for the first time is cut: a replayed or already cut reply keeps what it says.
        let fresh = playbackFile.flatMap { $0 == unheardReply ? $0 : nil }
        // Mochi falls silent first; the save that follows can take a moment.
        stopPlayback()
        MochiLog.audio.notice("The learner interrupted playback at \(Int(heard * 100), privacy: .public)%")
        if let fresh { keepHeardShare(ofReplyIn: fresh, heard: heard) }
    }

    private func keepHeardShare(ofReplyIn file: String, heard: Double) {
        guard let ci = library.conversations.firstIndex(where: { $0.id == selectedID }),
            let mi = library.conversations[ci].messages.lastIndex(where: { $0.role == "assistant" && $0.audio == file })
        else { return }
        let text = library.conversations[ci].messages[mi].text
        let kept = InterruptedReply.heard(text, fraction: heard)
        guard kept != text else { return }
        library.conversations[ci].messages[mi].text = kept
        save()
    }

    /// Mochi's speech while the learner can interrupt it plays through the listening microphone's echo canceller.
    func routeSpeechThroughListening() {
        audio.routedPlayer = { [weak self] url in
            // Only Mochi's own speech can be interrupted; the learner's recordings play as they always did, with the
            // microphone closed (D4).
            // Conditions as they are now, not as the last observer pass saw them: a sheet opened a moment ago keeps
            // the engine, and the microphone, off.
            guard let self, speaking, listening.isOn, listening.pauses.isEmpty, listeningBlockers.isEmpty,
                listeningContext == listeningRuntime.context,
                listeningRuntime.context.map({ $0 != .practice }) == true
            else { return nil }
            return try listeningServices.makePlayer(url) { [weak self] player, reached in
                self?.audio.finishPlayback(player, successfully: reached)
            }
        }
    }

    // MARK: Audio

    /// One piece of captured audio, in order.
    func listeningAudio(_ pcm: Data) {
        guard listening.microphoneOpen else { return }
        let runtime = listeningRuntime
        // Conditions are checked as each piece arrives, not only when an observer next runs: audio captured after
        // a sheet opened or the conversation changed is never heard.
        guard listeningBlockers.isEmpty, listeningContext == runtime.context else {
            refreshListeningConditions()
            return
        }
        runtime.preRoll.append(pcm)
        switch listening.phase {
        case .listening, .mochiSpeaking:
            // While Mochi speaks, the microphone is open only through the echo canceller: speech heard is the
            // learner interrupting.
            guard let start = runtime.detector.feed(pcm) else { return }
            runtime.turnAudio = runtime.preRoll.audio(from: start - Self.listeningPreRollMilliseconds * 24)
            // Less than the full pre-roll exists when speech starts right as the stream does.
            runtime.turnLead = Double(start - (runtime.preRoll.endSample - runtime.turnAudio.count / 2)) / 24000
            runtime.practiceTarget = help.english
            runtime.apiHeardSpeech = false
            runtime.liveBytes = 0
            sendToLine(runtime.turnAudio)
            handleListening(.speechStarted)
        case .hearingSpeech:
            runtime.detector.feed(pcm)
            runtime.turnAudio.append(pcm)
            sendToLine(pcm)
            let seconds = Double(runtime.turnAudio.count) / 48000
            if seconds >= Self.recordingLimit {
                endListeningTurn(.limit)
            } else if runtime.context == .practice {
                guard runtime.detector.trailingSilence >= Self.practiceEndSilence else { return }
                let spoken = seconds - runtime.detector.trailingSilence - runtime.turnLead
                if spoken < Self.practiceMinimumSpeech {
                    discardListeningTurn()
                } else {
                    endListeningTurn(.mac)
                }
            } else if !runtime.apiHeardSpeech, let line = runtime.line,
                Double(runtime.liveBytes) / 48000 >= Self.listeningNoSpeechLimit,
                Double(line.sentBytes) / 48000 >= Self.listeningNoSpeechLimit
            {
                // The Mac heard something, but the API found no speech in it, after enough time on an open
                // connection and enough audio actually sent: a slow handshake or a slow sender is not noise.
                discardListeningTurn()
            }
        default: break
        }
    }

    private func listeningCaptureStopped() {
        guard listening.microphoneOpen else { return }
        listeningRuntime.failure = String(localized: "The microphone changed or stopped.")
        handleListening(.networkFailure)
    }

    private func sendToLine(_ pcm: Data) {
        if let line = listeningRuntime.line {
            line.append(pcm)
            listeningRuntime.liveBytes += pcm.count
        } else {
            listeningRuntime.unsent.append(pcm)
        }
    }

    /// Ends the turn being heard and hands it to the ordinary path (plan D3).
    func endListeningTurn(_ cause: ListeningTurnEnd) {
        // A sheet opened or the conversation changed just now, before any observer ran: the turn is not wanted.
        guard listeningBlockers.isEmpty, listeningContext == listeningRuntime.context else {
            refreshListeningConditions()
            return
        }
        listeningRuntime.lastEnd = cause
        let audio = listeningRuntime.turnAudio
        guard listening.handle(.endOfTurn).contains(.sendTurn), let context = listeningRuntime.context else {
            syncListening()
            return
        }
        listeningRuntime.turnAudio = Data()
        // The quiet reopen allowed since the last turn is available again from here.
        listeningRuntime.quietReopens = 0
        closeListeningLine()
        syncListening()
        deliverListeningTurn(audio, to: context)
        // The hand-off may end without any work starting, as when the message could not be saved.
        if listening.phase == .endOfTurn && !busy { handleListening(.playbackEnded(now: listeningNow())) }
    }

    /// Drops a turn that held no speech; nothing is created and listening goes on.
    private func discardListeningTurn() {
        dropListeningTurn()
        handleListening(.turnDiscarded(now: listeningNow()))
    }

    private func dropListeningTurn() {
        listeningRuntime.turnAudio = Data()
        listeningRuntime.detector.reset()
        // The API may hold the dropped audio; the next turn starts on a fresh connection.
        closeListeningLine()
    }

    private func deliverListeningTurn(_ audio: Data, to context: ListeningContext) {
        guard context == listeningContext else { return }
        // An attempt is scored against the sentence it was spoken to; one edited mid-attempt is not that sentence.
        if context == .practice && help.english != listeningRuntime.practiceTarget {
            MochiLog.audio.notice("Dropped a hands-free attempt: the sentence changed while it was spoken")
            return
        }
        let name = "recording-\(UUID().uuidString).wav"
        let url = store.root.appendingPathComponent(name)
        do { try writeListeningTurn(PCM.wav(audio, rate: PCM.sampleRate), url) } catch {
            MochiLog.failure(MochiLog.library, "Save hands-free turn", error)
            self.error = persistenceMessage(
                error, action: "Save hands-free turn",
                fallback:
                    "Your turn could not be saved, so Mochi did not reply to it. Check the disk, then speak again.",
                diskFull:
                    "Your turn could not be saved because the disk is full, so Mochi did not reply to it. Free some space, then speak again."
            )
            return
        }
        switch context {
        case .practice:
            finishPracticeAttempt(url)
        case .conversation(let id):
            guard let index = library.conversations.firstIndex(where: { $0.id == id }) else {
                removeUnreferencedRecording(name)
                return
            }
            if !library.conversations[index].voiceIntroduced { library.conversations[index].voiceIntroduced = true }
            requestReply(
                history: library.conversations[index].messages, text: "", pcm: audio, audioFile: name,
                conversationID: id)
        }
    }

    // MARK: The connection

    private func openListeningLine() {
        let runtime = listeningRuntime
        let generation = UUID()
        runtime.lineGeneration = generation
        let detection = TurnDetection.semantic(eagerness: settings.listeningPatience.eagerness)
        let model = settings.effectiveModelName
        let open = listeningServices.openSession
        runtime.opening = Task { [weak self] in
            do {
                let line = try await open(detection, model)
                guard let self, listeningRuntime.lineGeneration == generation, !Task.isCancelled else {
                    line.close()
                    return
                }
                listeningRuntime.opening = nil
                listeningRuntime.line = line
                // Conditions may have changed while the connection opened, before any observer ran: nothing heard
                // before a sheet opened or the conversation changed is sent once it is too late to be wanted.
                guard listeningBlockers.isEmpty, listeningContext == listeningRuntime.context else {
                    refreshListeningConditions()
                    return
                }
                if !listeningRuntime.unsent.isEmpty {
                    line.append(listeningRuntime.unsent)
                    listeningRuntime.unsent = Data()
                }
                listenToLine(line, generation: generation)
            } catch {
                guard let self, listeningRuntime.lineGeneration == generation, !Task.isCancelled else { return }
                listeningRuntime.opening = nil
                lineFailed(error)
            }
        }
    }

    private func listenToLine(_ line: any ListeningLine, generation: UUID) {
        listeningRuntime.signalTask = Task { [weak self] in
            do {
                for try await signal in line.signals {
                    guard let self, listeningRuntime.lineGeneration == generation else { return }
                    switch signal {
                    case .speechStarted: listeningRuntime.apiHeardSpeech = true
                    case .speechStopped:
                        if listening.phase == .hearingSpeech && listeningRuntime.apiHeardSpeech {
                            endListeningTurn(.api)
                        }
                    case .transcribed: break
                    }
                }
            } catch {
                guard let self, listeningRuntime.lineGeneration == generation else { return }
                lineFailed(error)
            }
        }
    }

    /// A connection failed. One that dropped while nothing was being said is reopened quietly, once.
    private func lineFailed(_ error: Error) {
        MochiLog.failure(MochiLog.network, "Hands-free listening", error)
        closeListeningLine()
        if listening.phase == .listening && listeningRuntime.quietReopens == 0 {
            listeningRuntime.quietReopens += 1
            syncListening()
            return
        }
        guard listening.microphoneOpen else { return }
        listeningRuntime.failure = AppFailure.message(
            for: error, fallback: "The listening connection ended. Check your connection; press to send still works.")
        handleListening(.networkFailure)
    }

    private func closeListeningLine() {
        let runtime = listeningRuntime
        runtime.lineGeneration = UUID()
        runtime.opening?.cancel()
        runtime.opening = nil
        runtime.signalTask?.cancel()
        runtime.signalTask = nil
        runtime.line?.close()
        runtime.line = nil
        runtime.unsent = Data()
        runtime.apiHeardSpeech = false
        runtime.liveBytes = 0
    }

    // MARK: Outside events

    /// The turn machine changed activity: Mochi started or finished working, or started playing audio.
    func listeningTurnChanged(to activity: Activity) {
        guard listening.isOn else { return }
        switch activity {
        case .idle:
            // A reply finishes its work and starts playing in one step; listening resumes only once Mochi is
            // still idle after it, so the microphone does not open between the two.
            let check = UUID()
            listeningRuntime.idleCheck = check
            Task { @MainActor [weak self] in
                guard let self, listeningRuntime.idleCheck == check, turn.activity == .idle else { return }
                handleListening(.playbackEnded(now: listeningNow()))
            }
        case .playing: handleListening(.replyEnded)
        case .generating, .requestingPermission, .recording: handleListening(.replyStarted)
        }
    }

    /// Pauses or resumes listening as conditions around it change; called whenever they may have.
    func refreshListeningConditions() {
        // A recording that started by itself after a reply never runs on while Mochi is locked or hidden.
        if let unattended = unattendedRecording, recordingRequest == unattended, turn.activity == .recording,
            !listeningBlockers.isEmpty
        {
            unattendedRecording = nil
            MochiLog.audio.notice("Discarded the recording that started after a reply: Mochi was locked or hidden")
            cancelRecording()
        }
        guard listening.isOn else { return }
        let blockers = listeningBlockers
        let reasons: [ListeningMachine.PauseReason] = [.screenLocked, .windowHidden, .expressionsOpen, .sheetOpen]
        // Every new pause is applied before any resume, so ending one never opens the microphone while another,
        // arrived at the same time, is still to be applied.
        for reason in reasons where blockers.contains(reason) && !listening.pauses.contains(reason) {
            handleListening(.pause(reason))
        }
        // Another conversation, a move between a conversation and practice, or nowhere left for a turn to go (the
        // practice sentence was cleared) needs the learner to start again. A pause already explains a missing
        // context while My Expressions covers the conversation; it is judged again once that closes.
        if blockers.isEmpty, listeningContext != listeningRuntime.context,
            !listening.pauses.contains(.conversationSwitched)
        {
            handleListening(.pause(.conversationSwitched))
        }
        for reason in reasons where !blockers.contains(reason) && listening.pauses.contains(reason) {
            handleListening(.resume(reason, now: listeningNow()))
        }
    }

    /// Watches what `refreshListeningConditions` reads, and calls it whenever any of it changes.
    func observeListeningConditions() {
        withObservationTracking {
            _ = listeningBlockers
            _ = listeningContext
            _ = listening.isOn
            _ = settings.talkingMode
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                refreshListeningConditions()
                observeListeningConditions()
            }
        }
    }
}
