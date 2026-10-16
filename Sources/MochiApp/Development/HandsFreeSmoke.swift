#if MOCHI_DEVELOPMENT
    import AVFoundation
    import AppKit
    import CoreAudio
    import MochiCore
    import MochiKernel
    import PCM16

    /// Plays a recorded 24 kHz mono 16-bit stream into hands-free listening in real time, in 100 ms pieces, once
    /// `play()` is called; before that and after it, quiet room noise, for as long as listening keeps the capture open.
    @MainActor final class RecordedStreamFeeder {
        private let stream: Data
        private var offset = 0
        private var playing = false
        private var timer: Timer?
        var running: Bool { timer != nil }
        init(_ stream: Data) { self.stream = stream }
        func play() { playing = true }
        /// Plays the recording again, from 300 ms before its first speech, so the speech arrives at once.
        func replayFromSpeech() {
            offset = max(0, speechOnset - 7200 * 2) & ~1
            playing = true
        }
        /// Where speech starts in the recording, in bytes, as hands-free listening's own detector finds it; zero for
        /// a recording in which it finds none (`hasSpeech` tells).
        private var speechOnset: Int {
            var detector = SpeechActivityDetector()
            return (detector.feed(stream) ?? 0) * 2
        }
        /// Whether the detector finds speech in the recording at all.
        var hasSpeech: Bool {
            var detector = SpeechActivityDetector()
            return detector.feed(stream) != nil
        }
        func start(_ deliver: @escaping @MainActor (Data) -> Void) {
            stop()
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let piece: Data
                    if self.playing && self.offset < self.stream.count {
                        piece = self.stream.subdata(in: self.offset..<min(self.offset + 4800, self.stream.count))
                        self.offset += piece.count
                    } else {
                        piece = Self.quiet
                    }
                    deliver(piece)
                }
            }
        }
        func stop() {
            timer?.invalidate()
            timer = nil
        }
        /// 100 ms of low noise near -65 dBFS.
        static let quiet: Data = {
            var data = Data(capacity: 4800)
            var seed: UInt32 = 99
            for _ in 0..<2400 {
                seed = seed &* 1_103_515_245 &+ 12345
                var sample = Int16(Int(seed >> 16) % 61 - 30).littleEndian
                withUnsafeBytes(of: &sample) { data.append(contentsOf: $0) }
            }
            return data
        }()
    }

    /// Whether any process is using the default input device: the condition behind the menu bar microphone
    /// indicator. Nil when Core Audio cannot say.
    func inputDeviceRunningSomewhere() -> Bool? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
                == noErr, device != kAudioObjectUnknown
        else { return nil }
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else { return nil }
        return running != 0
    }

    /// Whether the default output is the Mac's built-in speakers, unmuted with volume up: the setup in which Mochi
    /// could hear itself. Nil fields are what Core Audio could not say.
    func builtInSpeakersAudible() -> (speakers: Bool?, volume: Float?, muted: Bool?) {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
                == noErr, device != kAudioObjectUnknown
        else { return (nil, nil, nil) }
        func read<T: BitwiseCopyable>(_ selector: AudioObjectPropertySelector, _ element: UInt32, _ initial: T) -> T? {
            var value = initial
            var size = UInt32(MemoryLayout<T>.size)
            var address = AudioObjectPropertyAddress(
                mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
            guard AudioObjectHasProperty(device, &address),
                AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr
            else { return nil }
            return value
        }
        let transport: UInt32? = read(kAudioDevicePropertyTransportType, kAudioObjectPropertyElementMain, 0)
        let source: UInt32? = read(kAudioDevicePropertyDataSource, kAudioObjectPropertyElementMain, 0)
        // Built in, and known to be on the internal speaker rather than headphones in the jack ('ispk').
        let speakers = transport.map { $0 == kAudioDeviceTransportTypeBuiltIn && source == 0x6973_706B }
        let volume: Float? =
            read(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyElementMain, Float(0))
            ?? read(kAudioDevicePropertyVolumeScalar, 1, Float(0))
        let muted: UInt32? = read(kAudioDevicePropertyMute, kAudioObjectPropertyElementMain, 0)
        return (speakers, volume, muted.map { $0 != 0 })
    }

    extension AppDelegate {
        /// Native hands-free check (plan Verification): a recorded learner stream goes into the capture seam, through
        /// a live listening session and a live reply, then listening stops after a shortened silence. When Mochi
        /// already has microphone access, the real capture runs alongside the recording, so the check also proves the
        /// microphone itself opens while listening and is off afterwards. The stream is the argument after the flag.
        func smokeHandsFree(_ model: AppModel) {
            guard !ran else { return }
            ran = true
            let arguments = CommandLine.arguments
            let directory = URL(
                fileURLWithPath: ProcessInfo.processInfo.environment["MOCHI_EVIDENCE_DIR"] ?? "/tmp/mochi-evidence")
            Task {
                var checks: [(String, Bool)] = []
                var notes: [String: Any] = [:]
                // Set only when the real microphone was seen running while listening and seen stopped afterwards.
                var captureRan = false
                var captureReleased = false
                func check(_ name: String, _ passed: Bool) { checks.append((name, passed)) }
                @MainActor func waitFor(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
                    let deadline = Date().addingTimeInterval(timeout)
                    while !condition() {
                        guard Date() < deadline else { return false }
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
                    return true
                }
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let report = directory.appendingPathComponent("hands-free-smoke.json")
                try? FileManager.default.removeItem(at: report)
                try? await Task.sleep(nanoseconds: 700_000_000)
                do {
                    guard let index = arguments.firstIndex(of: "--hands-free-smoke-test"), index + 1 < arguments.count
                    else { throw AppFailure(verbatim: "Pass the recorded stream after --hands-free-smoke-test.") }
                    let feeder = RecordedStreamFeeder(try Data(contentsOf: URL(fileURLWithPath: arguments[index + 1])))
                    let realMicrophone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                    notes["real_microphone"] = realMicrophone
                    let capture = StreamingCapture()
                    let live = model.listeningServices
                    model.listeningServices = ListeningServices(
                        startCapture: { deliver, interrupted in
                            // The microphone's own audio is ignored; the recording stands in for the learner.
                            if realMicrophone { try capture.start(deliver: { _ in }, interrupted: interrupted) }
                            feeder.start(deliver)
                        },
                        stopCapture: {
                            capture.stop()
                            feeder.stop()
                        },
                        capturing: { feeder.running },
                        openSession: live.openSession)
                    model.media.permission = { true }
                    model.resume()
                    model.newChat()
                    guard let id = model.selectedID,
                        let chat = model.library.conversations.firstIndex(where: { $0.id == id })
                    else { throw AppFailure(verbatim: "No conversation to listen in.") }
                    model.library.conversations[chat].voiceIntroduced = true
                    let mode = model.settings.talkingMode
                    model.settings.talkingMode = .handsFree
                    defer { model.settings.talkingMode = mode }

                    // Every 20 ms, what the learner would see: the phase, the microphone and any notice.
                    var timeline: [(time: Date, phase: ListeningMachine.Phase, capturing: Bool, notice: String?)] = []
                    let recorder = Task { @MainActor in
                        while !Task.isCancelled {
                            let entry = (Date(), model.listening.phase, feeder.running, model.notice)
                            if timeline.last.map({
                                $0.phase != entry.1 || $0.capturing != entry.2 || $0.notice != entry.3
                            })
                                ?? true
                            {
                                timeline.append(entry)
                            }
                            try? await Task.sleep(nanoseconds: 20_000_000)
                        }
                    }
                    defer { recorder.cancel() }
                    /// The first entry from `after` on that matches, if any.
                    func first(
                        after: Date,
                        _ match: ((time: Date, phase: ListeningMachine.Phase, capturing: Bool, notice: String?))
                            -> Bool
                    ) -> (time: Date, phase: ListeningMachine.Phase, capturing: Bool, notice: String?)? {
                        timeline.first { $0.time >= after && match($0) }
                    }

                    model.toggleConversationVoice()
                    check(
                        "listening starts with its connection ready",
                        await waitFor(20) { model.listening.phase == .listening && model.listeningRuntime.line != nil })
                    // Shortened only now: the first silence timer covers the handshake with the ordinary limit, and
                    // the short one starts when listening resumes after the reply.
                    model.listening.silenceLimit = 5
                    if realMicrophone {
                        captureRan = capture.isRunning
                        check("Mochi's capture engine runs while listening", captureRan)
                        notes["input_device_running_while_listening"] =
                            inputDeviceRunningSomewhere().map { $0 as Any } ?? NSNull()
                    }
                    let played = Date()
                    feeder.play()
                    check(
                        "the turn ends, Mochi replies and listening resumes",
                        await waitFor(120) {
                            first(after: played, { $0.phase == .mochiSpeaking }).map { speaking in
                                first(after: speaking.time, { $0.phase == .listening && $0.capturing }) != nil
                            } ?? false
                        })
                    check(
                        "listening stops after the shortened silence",
                        await waitFor(20) { model.listening.phase == .stoppedBySilence })
                    // The sampler records the stop on its next pass; let it, so the timeline holds the final state.
                    _ = await waitFor(2) { timeline.contains { $0.phase == .stoppedBySilence } }
                    recorder.cancel()
                    let heard = first(after: played) { $0.phase == .hearingSpeech }
                    check("the recorded speech is heard", heard != nil)
                    let ended = heard.flatMap { heard in first(after: heard.time) { $0.phase != .hearingSpeech } }
                    check(
                        "the API judges the turn ended",
                        ended != nil && ended?.phase != .off && model.listeningRuntime.lastEnd == .api)
                    notes["turn_end_cause"] = model.listeningRuntime.lastEnd.map { String(describing: $0) } ?? NSNull()
                    if let heard, let ended { notes["turn_seconds"] = ended.time.timeIntervalSince(heard.time) }
                    let speaking = first(after: played) { $0.phase == .mochiSpeaking }
                    let resumed = speaking.flatMap { speaking in
                        first(after: speaking.time) { $0.phase == .listening && $0.capturing }
                    }
                    if let ended, let resumed {
                        check(
                            "the microphone is closed from the end of the turn until listening resumes",
                            timeline.filter { $0.time >= ended.time && $0.time < resumed.time }.allSatisfy {
                                !$0.capturing
                            })
                    } else {
                        check("the microphone is closed from the end of the turn until listening resumes", false)
                    }
                    let stopped = first(after: played) { $0.phase == .stoppedBySilence }
                    if let resumed, let stopped {
                        let silence = stopped.time.timeIntervalSince(resumed.time)
                        notes["silence_seconds"] = silence
                        check("the silence timer counts from playback's end", silence >= 4.9 && silence < 8)
                    }
                    check(
                        "the stop is announced",
                        timeline.contains {
                            $0.time >= (stopped?.time ?? .distantFuture) && $0.notice?.contains("silence") == true
                        })
                    let message = model.conversation?.messages.first(where: { $0.role == "user" })
                    check("the turn became a voice message", message?.audio != nil)
                    check(
                        "the voice message is transcribed",
                        await waitFor(30) {
                            model.conversation?.messages.first(where: { $0.role == "user" })?.transcriptionState
                                == .completed
                        })
                    notes["transcript"] = model.conversation?.messages.first(where: { $0.role == "user" })?.text
                    check("the capture is closed after silence", !feeder.running && !capture.isRunning)
                    check("the connection is closed after silence", model.listeningRuntime.line == nil)
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    let indicator = inputDeviceRunningSomewhere()
                    notes["input_device_running_after"] = indicator.map { $0 as Any } ?? NSNull()
                    // Primary: Mochi's own capture is stopped. Auxiliary: no process at all holds the input device,
                    // which also covers what drives the menu bar indicator but is device-wide, not Mochi's alone.
                    check("Mochi's capture engine is stopped", !capture.isRunning && !feeder.running)
                    captureReleased = captureRan && !capture.isRunning
                    // Recorded, not judged: another process may hold the input device for its own reasons.
                    notes["input_device_released_device_wide"] = indicator.map { !$0 as Any } ?? NSNull()
                    check("one message and one reply, nothing else", model.conversation?.messages.count == 2)
                    notes["timeline"] = timeline.map {
                        [
                            "t": $0.time.timeIntervalSince(played), "phase": String(describing: $0.phase),
                            "capturing": $0.capturing, "notice": $0.notice ?? NSNull(),
                        ] as [String: Any]
                    }
                } catch {
                    notes["error"] = AppFailure.message(for: error, fallback: "The hands-free smoke run failed.")
                    check("setup", false)
                }
                notes["error_shown"] = model.error ?? NSNull()
                notes["checks"] = checks.map { ["name": $0.0, "passed": $0.1] }
                let passed = !checks.isEmpty && checks.allSatisfy(\.1)
                notes["passed"] = passed
                // Without microphone access the recording stands in for the microphone, and the checks that it was
                // released pass trivially: the run proves the flow, not the microphone itself.
                notes["microphone_release_verified"] = captureReleased
                let written =
                    (try? JSONSerialization.data(withJSONObject: notes, options: [.prettyPrinted, .sortedKeys]))
                    .map { writeEvidence($0, to: report) } ?? false
                model.stop()
                finishRun(model, passed: passed && written)
            }
        }
    }
#endif

#if MOCHI_DEVELOPMENT
    extension AppDelegate {
        /// Native barge-in check (plan H4). In a hands-free conversation, a reply plays through the listening engine
        /// and the recorded learner speaks over it: playback must stop, the reply keep only what was heard, and the
        /// interruption become the next turn. With microphone access it first lets a reply play to its end with only
        /// the real microphone listening through the speakers: Mochi must not interrupt itself. Without access, that
        /// check is reported as not run and the reply plays the ordinary way, so only the flow is checked.
        func smokeBargeIn(_ model: AppModel) {
            guard !ran else { return }
            ran = true
            let arguments = CommandLine.arguments
            let directory = URL(
                fileURLWithPath: ProcessInfo.processInfo.environment["MOCHI_EVIDENCE_DIR"] ?? "/tmp/mochi-evidence")
            Task {
                var checks: [(String, Bool)] = []
                var notes: [String: Any] = [:]
                func check(_ name: String, _ passed: Bool) { checks.append((name, passed)) }
                @MainActor func waitFor(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
                    let deadline = Date().addingTimeInterval(timeout)
                    while !condition() {
                        guard Date() < deadline else { return false }
                        try? await Task.sleep(nanoseconds: 20_000_000)
                    }
                    return true
                }
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let report = directory.appendingPathComponent("barge-in-smoke.json")
                try? FileManager.default.removeItem(at: report)
                try? await Task.sleep(nanoseconds: 700_000_000)
                let capture = StreamingCapture()
                do {
                    guard let index = arguments.firstIndex(of: "--hands-free-smoke-test"), index + 1 < arguments.count
                    else { throw AppFailure(verbatim: "Pass the recorded stream after --hands-free-smoke-test.") }
                    let stream = try Data(contentsOf: URL(fileURLWithPath: arguments[index + 1]))
                    let feeder = RecordedStreamFeeder(stream)
                    // A recording the detector hears no speech in cannot interrupt anything: the run would fail for
                    // the fixture's sake, not the app's.
                    guard feeder.hasSpeech else {
                        throw AppFailure(verbatim: "The recording holds no speech the listening detector hears.")
                    }
                    let realMicrophone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                    notes["real_microphone"] = realMicrophone
                    // While true, listening hears the real microphone; otherwise the recording.
                    var microphoneLive = false
                    var audibleSpeakers = false
                    var selfCheckRan = false
                    var speechHeard = false
                    defer {
                        // H4's acceptance needs Mochi heard through audible built-in speakers by the real microphone;
                        // without that, a passing flow is reported as incomplete acceptance, never as accepted.
                        notes["h4_acceptance"] =
                            !realMicrophone
                            ? "incomplete: no microphone access"
                            : !speechHeard
                                ? "incomplete: the real microphone did not hear speech through the speakers"
                                : !audibleSpeakers
                                    ? "incomplete: output is not audible built-in speakers"
                                    : !selfCheckRan
                                        ? "incomplete: the self-interruption check did not finish" : "complete"
                    }
                    let live = model.listeningServices
                    model.listeningServices = ListeningServices(
                        startCapture: { deliver, interrupted in
                            if realMicrophone {
                                try capture.start(
                                    deliver: { pcm in if microphoneLive { deliver(pcm) } }, interrupted: interrupted)
                            }
                            feeder.start { pcm in if !microphoneLive { deliver(pcm) } }
                        },
                        stopCapture: {
                            capture.stop()
                            feeder.stop()
                        },
                        capturing: { feeder.running },
                        openSession: live.openSession,
                        makePlayer: { url, finished in
                            if realMicrophone { return try capture.player(url, finished: finished) }
                            return try AVAudioPlayer(contentsOf: url)
                        })
                    model.media.permission = { true }
                    model.resume()
                    model.newChat()
                    guard let id = model.selectedID,
                        let chat = model.library.conversations.firstIndex(where: { $0.id == id })
                    else { throw AppFailure(verbatim: "No conversation to listen in.") }
                    model.library.conversations[chat].voiceIntroduced = true
                    let mode = model.settings.talkingMode
                    model.settings.talkingMode = .handsFree
                    defer { model.settings.talkingMode = mode }

                    var phases: [(time: Date, phase: ListeningMachine.Phase)] = []
                    let recorder = Task { @MainActor in
                        while !Task.isCancelled {
                            if phases.last?.phase != model.listening.phase {
                                phases.append((Date(), model.listening.phase))
                            }
                            try? await Task.sleep(nanoseconds: 10_000_000)
                        }
                    }
                    defer { recorder.cancel() }
                    @MainActor func lastReply() -> Message? {
                        model.conversation?.messages.last { $0.role == "assistant" }
                    }

                    model.toggleConversationVoice()
                    check(
                        "listening starts with its connection ready",
                        await waitFor(20) { model.listening.phase == .listening && model.listeningRuntime.line != nil })

                    // Only a spoken turn gets a spoken reply: the recorded learner speaks first.
                    if realMicrophone {
                        // Positive control: the learner recording plays through the speakers, outside Mochi, and the
                        // real microphone alone must hear speech in it. A microphone delivering silence would pass
                        // the echo check below without proving anything. That turn's reply is the one checked.
                        microphoneLive = true
                        let learner = directory.appendingPathComponent("barge-in-learner.wav")
                        try PCM.wav(stream, rate: PCM.sampleRate).write(to: learner)
                        let speaker = try AVAudioPlayer(contentsOf: learner)
                        guard speaker.play() else { throw AppFailure(verbatim: "The learner recording did not play.") }
                        speechHeard = await waitFor(20) { model.listening.phase == .hearingSpeech }
                        check("the real microphone hears speech played through the speakers", speechHeard)
                        // Mochi speaks through the speakers with only the real microphone listening.
                        let speaking = await waitFor(120) { model.listening.phase == .mochiSpeaking }
                        speaker.stop()
                        let asked = Date()
                        check("a reply plays with only the real microphone listening", speaking)
                        check(
                            "the reply plays through the echo canceller",
                            model.audio.playingRouted && capture.engineRunning)
                        check("the microphone is open while Mochi speaks", model.listening.microphoneOpen)
                        let output = builtInSpeakersAudible()
                        notes["output_built_in_speakers"] = output.speakers ?? NSNull()
                        notes["output_volume"] = output.volume ?? NSNull()
                        notes["output_muted"] = output.muted ?? NSNull()
                        // Unknown counts as not established: only a known, unmuted, audible speaker counts.
                        audibleSpeakers =
                            output.speakers == true && (output.volume ?? 0) >= 0.25 && output.muted == false
                        let ended = await waitFor(90) { model.listening.phase != .mochiSpeaking }
                        let selfHeard = phases.contains { $0.time >= asked && $0.phase == .hearingSpeech }
                        notes["self_interruption"] = selfHeard
                        check("Mochi does not interrupt itself through the speakers", !selfHeard)
                        check(
                            "the reply plays to its end",
                            ended && model.listening.phase == .listening && model.error == nil
                                && !(lastReply()?.text.hasSuffix("…") ?? true))
                        selfCheckRan = speaking && ended
                        microphoneLive = false
                        _ = await waitFor(20) { model.listening.phase == .listening }
                    } else {
                        notes["self_interruption"] = "not run: no microphone access"
                    }
                    feeder.play()

                    // The recorded learner speaks over the reply to their own turn, from the moment it starts: replayed
                    // from just before its speech, so the speech arrives about 0.3 s into the reply.
                    check("a reply plays", await waitFor(120) { model.listening.phase == .mochiSpeaking })
                    check("the reply is interruptible", model.listening.microphoneOpen && model.audio.playingRouted)
                    let userMessagesBefore = model.conversation?.messages.filter { $0.role == "user" }.count ?? 0
                    let reply = lastReply()
                    notes["reply_before"] = reply?.text
                    notes["reply_seconds"] = model.audio.duration
                    check("the reply is long enough to interrupt (over 1 s)", model.audio.duration > 1)
                    let spoke = Date()
                    feeder.replayFromSpeech()
                    let stopped = await waitFor(5) { model.turn.activity != .playing }
                    check("speaking over Mochi stops it", stopped)
                    notes["stop_latency_seconds"] = Date().timeIntervalSince(spoke)
                    // The sampler records the phase on its next pass; let it before judging.
                    check(
                        "the stop is the learner interrupting",
                        await waitFor(1) { phases.contains { $0.time >= spoke && $0.phase == .hearingSpeech } })
                    let kept = model.conversation?.messages.first { $0.id == reply?.id }?.text
                    notes["reply_kept"] = kept
                    check(
                        "the reply keeps only what was heard",
                        kept?.hasSuffix("…") == true && (kept?.count ?? .max) < (reply?.text.count ?? 0))
                    check(
                        "the interruption becomes the next turn and is answered",
                        await waitFor(120) {
                            let messages = model.conversation?.messages ?? []
                            return messages.filter { $0.role == "user" }.count == userMessagesBefore + 1
                                && messages.last?.role == "assistant" && messages.last?.id != reply?.id
                        })
                    check("the API judged the interrupting turn ended", model.listeningRuntime.lastEnd == .api)
                    // Stopping listening while that answer still plays through the listening engine: the reply must
                    // move to an ordinary player and go on, and the engine, the microphone with it, stop at once.
                    let answering = await waitFor(20) {
                        model.listening.phase == .mochiSpeaking && model.audio.playingRouted
                    }
                    check("the answer plays through the listening engine", answering)
                    model.stopListening()
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    check(
                        "stopping listening mid-reply stops the engine while the reply goes on",
                        answering && !capture.engineRunning && !feeder.running && !model.audio.playingRouted
                            && model.turn.activity == .playing)
                    check(
                        "the interrupting turn is transcribed",
                        await waitFor(30) {
                            model.conversation?.messages.last(where: { $0.role == "user" })?.transcriptionState
                                == .completed
                        })
                    notes["transcript"] = model.conversation?.messages.last(where: { $0.role == "user" })?.text
                    _ = await waitFor(90) { model.turn.activity == .idle }
                    model.stopPlayback()
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    check("the listening engine is stopped afterwards", !capture.engineRunning && !feeder.running)
                    notes["phases"] = phases.map { ["t": $0.time.timeIntervalSince(spoke), "phase": "\($0.phase)"] }
                } catch {
                    notes["error"] = AppFailure.message(for: error, fallback: "The barge-in smoke run failed.")
                    check("setup", false)
                }
                notes["error_shown"] = model.error ?? NSNull()
                notes["checks"] = checks.map { ["name": $0.0, "passed": $0.1] }
                let passed = !checks.isEmpty && checks.allSatisfy(\.1)
                notes["passed"] = passed
                let written =
                    (try? JSONSerialization.data(withJSONObject: notes, options: [.prettyPrinted, .sortedKeys]))
                    .map { writeEvidence($0, to: report) } ?? false
                model.stop()
                finishRun(model, passed: passed && written)
            }
        }
    }
#endif
