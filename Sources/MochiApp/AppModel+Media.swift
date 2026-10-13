import AppKit
import MochiCore
import MochiKernel

/// Playback and recording, arbitrated by the shared turn machine.
extension AppModel {
    var microphoneLabel: String {
        if turn.activity == .recording { return String(localized: "Finish Recording") }
        if greetingActive { return String(localized: "Skip Greeting and Start Recording") }
        return conversation?.greetsBeforeRecording == false
            ? String(localized: "Record Voice Message") : String(localized: "Start Voice Conversation")
    }
    func cancelRecording() {
        let url = media.stopRecording()
        cancelHelpWork()
        removeUnreferencedRecording(url?.lastPathComponent)
    }
    func togglePlayback(_ file: String, mochi: Bool = false) {
        if playbackFile == file && turn.activity == .playing {
            audio.togglePause()
            return
        }
        play(file, mochi: mochi)
    }
    /// Ends playback the way Stop does, with the view change scheduled after it, but leaves transcriptions,
    /// recordings and the Help draft alone.
    func stopPlayback() {
        guard turn.activity == .playing else { return }
        deferredToolAction = nil
        greetingActive = false
        audio.stop()
        playbackFile = nil
        speaking = false
        turn.stop()
    }
    func seekPlayback(_ file: String, to seconds: Double, mochi: Bool = false) {
        guard seconds.isFinite else { return }
        if playbackFile != file { play(file, mochi: mochi) }
        guard playbackFile == file else { return }
        audio.seek(to: seconds)
    }
    func play(
        _ file: String, mochi: Bool = false, afterPlayback: (() -> Void)? = nil,
        afterPlaybackFailure: (() -> Void)? = nil, settingsTab: SettingsTab? = nil
    ) {
        guard !busy || turn.activity == .playing else { return }
        if afterPlayback == nil { greetingActive = false }
        audio.stop()
        playbackFile = nil
        let token = turn.begin(.playing)
        speaking = mochi
        let finished: () -> Void = { [weak self] in
            guard let self, self.turn.epoch == token else { return }
            self.playbackFile = nil
            self.speaking = false
            _ = self.turn.finish(token)
        }
        do {
            try audio.play(
                url: store.root.appendingPathComponent(file), rate: slow && !mochi ? 0.8 : 1,
                failed: { [weak self] in
                    guard let self, self.turn.epoch == token else { return }
                    finished()
                    self.greetingActive = false
                    self.report(
                        String(localized: "This recording could not be played. Try another recording."), in: settingsTab
                    )
                    afterPlaybackFailure?()
                },
                completed: { [weak self] in
                    guard let self, self.turn.epoch == token else { return }
                    finished()
                    afterPlayback?()
                })
            playbackFile = file
        } catch {
            playbackFile = nil
            fail(error, token: token, context: "Play audio", settingsTab: settingsTab)
            afterPlaybackFailure?()
        }
    }
    func recordMeaning() {
        guard !help.isSavedPractice else {
            notice = String(localized: "Open Help Me Say This from the conversation to record a new thought.")
            return
        }
        beginRecording(forMeaning: true)
    }
    func toggleRecord() {
        guard practice || writableConversation else { return }
        beginRecording(forMeaning: false)
    }
    func beginRecording(forMeaning: Bool) {
        if turn.activity == .recording {
            finishRecording()
            return
        }
        guard !busy, libraryReadable else { return }
        recordingMeaning = forMeaning
        if practice && !recordingMeaning { ensureExpression() }
        let token = turn.begin(.requestingPermission)
        task = Task {
            let allowed = await media.permission()
            guard !Task.isCancelled, turn.epoch == token else { return }
            guard allowed else {
                recordingMeaning = false
                _ = turn.finish(token)
                error = String(
                    localized:
                        "Microphone access is off. Enable Mochi in System Settings → Privacy & Security → Microphone.")
                return
            }
            do {
                let file = store.root.appendingPathComponent("recording-\(UUID().uuidString).wav")
                try media.record(file)
                // The recorder's own time limit runs from here, not from after the save below.
                let started = recordingNow()
                if !practice, let index = library.conversations.firstIndex(where: { $0.id == selectedID }) {
                    library.conversations[index].voiceIntroduced = true
                    save()
                }
                _ = turn.finish(token)
                _ = turn.startRecording()
                recordingRequest = token
                recordingSeconds = 0
                lastAudibleRecordingTime = 0
                recordingWarning = nil
                startRecordingFeedback(token: turn.epoch, started: started)
            } catch { fail(error, token: token, context: "Start recording") }
        }
    }
    func updateRecordingFeedback(elapsed: Double, level: Float) {
        recordingSeconds = Int(max(0, min(Self.recordingLimit, elapsed.isFinite ? elapsed : 0)))
        recordingLevel = level.isFinite ? min(0, max(-80, level)) : -80
        let time = elapsed.isFinite ? elapsed : 0
        if recordingLevel >= -48 { lastAudibleRecordingTime = time }
        // Only sustained silence warns; ordinary pauses in speech would make the warning blink on every word.
        recordingWarning =
            time - lastAudibleRecordingTime >= Self.quietWarningDelay
            ? String(localized: "Input is very quiet. Check your microphone or speak closer.") : nil
    }
    func startRecordingFeedback(token: UUID, started: Date? = nil) {
        recordingClock?.cancel()
        let started = started ?? recordingNow()
        recordingClock = Task {
            while !Task.isCancelled {
                do { try await recordingSleep(100_000_000) } catch { return }
                guard !Task.isCancelled, turn.epoch == token else { return }
                let elapsed = recordingNow().timeIntervalSince(started)
                updateRecordingFeedback(elapsed: elapsed, level: media.meter())
                if elapsed >= Self.recordingLimit || !media.recordingActive() {
                    finishRecording()
                    return
                }
            }
        }
    }
    /// The recorder stopped without being asked. Its outcome arrives asynchronously, so wait briefly for it:
    /// the take is kept only once the recorder confirms a successful stop, and silence counts as an interruption.
    private func awaitStoppedTake() {
        recordingClock?.cancel()
        let token = turn.epoch
        recordingClock = Task {
            for _ in 0..<20 {
                guard !Task.isCancelled, turn.epoch == token else { return }
                if media.recordingInterrupted() { break }
                if media.recordingFinished() {
                    finishRecording()
                    return
                }
                do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
            }
            guard !Task.isCancelled, turn.epoch == token else { return }
            recordingInterrupted()
        }
    }
    /// The microphone stopped mid-take. A partial take is discarded rather than sent as if complete.
    private func recordingInterrupted() {
        cancelRecording()
        error = String(
            localized:
                "Recording stopped because the microphone disconnected or stopped responding. Check your microphone, then record again."
        )
    }
    func finishRecording() {
        // A recorder that already stopped (time limit, disconnect, failure) is judged by its reported outcome,
        // never by elapsed time; Finish can be pressed before that outcome or the clock's next tick arrives.
        if turn.activity == .recording, !media.recordingActive() {
            if media.recordingInterrupted() {
                recordingInterrupted()
                return
            }
            if !media.recordingFinished() {
                awaitStoppedTake()
                return
            }
        }
        guard let url = media.stopRecording() else {
            stop()
            return
        }
        recordingClock?.cancel()
        recordingClock = nil
        turn.stop()
        recordingLevel = -80
        if recordingMeaning {
            recordingMeaning = false
            finishThoughtRecording(url)
        } else if practice {
            finishPracticeAttempt(url)
        } else if let id = selectedID {
            sendRecording(url, conversationID: id)
        } else {
            removeUnreferencedRecording(url.lastPathComponent)
        }
    }
    /// Decodes off the main actor; cancelling the job stops decoding. A take that cannot be decoded, or whose job
    /// was superseded, is removed.
    private func decodeTake<T: Sendable>(
        _ url: URL, job: ExclusiveJob, fallback: String.LocalizationValue,
        _ decode: @escaping @Sendable (URL) throws -> T
    ) async throws -> T? {
        let work = Task.detached(priority: .userInitiated) { try decode(url) }
        let value: T
        do {
            value = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
        } catch {
            removeUnreferencedRecording(url.lastPathComponent)
            guard job.isCurrent() else { return nil }
            throw AppFailure(verbatim: AppFailure.message(for: error, fallback: fallback), underlying: error)
        }
        guard job.isCurrent() else {
            removeUnreferencedRecording(url.lastPathComponent)
            return nil
        }
        return value
    }
    private func finishThoughtRecording(_ url: URL) {
        runExclusive(
            "Read thought recording", progress: "Checking your recording…",
            onFailure: { [weak self] in self?.recordingWarning = nil },
            { [weak self] job in
                guard let self else { return }
                // The signal check runs with the decode, off the main actor.
                guard
                    let quiet = try await decodeTake(
                        url, job: job, fallback: "This recording could not be read. Record your thought again.",
                        { RecordingSignal(samples: try AudioFile.samples($0).samples).isQuiet })
                else { return }
                // Assigning the recording saves the help draft and removes the one it replaces.
                help.thoughtRecording = url.lastPathComponent
                recordingWarning =
                    quiet
                    ? String(localized: "This recording is very quiet. Listen before transcribing, or record it again.")
                    : nil
                job.finish()
                notice = String(localized: "Your thought is recorded locally. Listen, then choose Transcribe.")
            })
    }
    private func finishPracticeAttempt(_ url: URL) {
        runExclusive("Analyse practice attempt") { [weak self] job in
            guard let self else { return }
            guard
                let pitch = try await decodeTake(
                    url, job: job, fallback: "This attempt could not be read. Record it again.",
                    { try AudioFile.pitch($0) })
            else { return }
            help.expression?.attempts.append(Attempt(file: url.lastPathComponent))
            help.attemptPitch = pitch
            help.attemptCheck = .none
            saveExpression()
            if let item = help.expression { await checkAttempt(url.lastPathComponent, of: item, job: job) }
            guard job.isCurrent() else { return }
            job.finish()
            notice =
                pitch.contains(where: { $0.hz != nil })
                ? String(localized: "Try comparing one phrase at a time. These contours are unscored.")
                : String(localized: "No clear voiced pitch detected. Try speaking closer to the microphone.")
        }
    }
    private func sendRecording(_ url: URL, conversationID id: UUID) {
        runExclusive("Read finished recording") { [weak self] job in
            guard let self else { return }
            guard
                let pcm = try await decodeTake(
                    url, job: job, fallback: "This recording could not be read. Record your message again.",
                    { try AudioFile.pcm($0) })
            else { return }
            requestReply(
                history: library.conversations.first(where: { $0.id == id })?.messages ?? [], text: "", pcm: pcm,
                audioFile: url.lastPathComponent, conversationID: id)
        }
    }
}
