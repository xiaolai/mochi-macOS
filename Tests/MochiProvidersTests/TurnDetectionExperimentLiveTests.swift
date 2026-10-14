import Foundation
import MochiCore
import MochiKernel
import XCTest

@testable import MochiProviders

/// Experiment E5 (hands-free plan): turn detection on learner speech, through Mochi's own listening code. Each stream
/// from `e5_turns_prepare.py` starts where the Mac's speech detector hears speech, less 300 ms of pre-roll, and is
/// streamed in real time to a listening session. It uses the network and the user's subscription, so it runs only
/// when MOCHI_LIVE_E5=1 and MOCHI_E5_ITEMS and MOCHI_E5_OUT are set. One JSON line per stream and configuration goes
/// to MOCHI_E5_OUT; pairs already there are skipped, so an interrupted run resumes where it stopped.
/// The `local-*` configurations judge the end on the Mac from silence alone, for practice (plan D7); they use no
/// network.
final class TurnDetectionExperimentLiveTests: XCTestCase {
    private struct Configuration: Sendable {
        let name: String
        let detection: TurnDetection?
        let localSilence: TimeInterval?
    }
    private static let configurations: [Configuration] =
        ["low", "medium", "high"].map {
            Configuration(name: "semantic-\($0)", detection: .semantic(eagerness: $0), localSilence: nil)
        }
        + [800, 1500, 2500].map {
            Configuration(name: "silence-\($0)", detection: .silence(milliseconds: $0), localSilence: nil)
        }
        + [800, 1200, 1500].map {
            Configuration(name: "local-\($0)", detection: nil, localSilence: Double($0) / 1000)
        }
    static let preRollMilliseconds = 300
    /// How long a turn may go on after its reference end before the end counts as missed.
    static let missedAfter: TimeInterval = 10
    /// Sessions in flight at once, 1 to 16; MOCHI_E5_CONCURRENCY overrides it, and a value outside that range fails.
    private static func concurrency(_ environment: [String: String]) throws -> Int {
        guard let value = environment["MOCHI_E5_CONCURRENCY"] else { return 6 }
        guard let count = Int(value), (1...16).contains(count) else {
            throw AppFailure(verbatim: "MOCHI_E5_CONCURRENCY must be a whole number from 1 to 16, not \(value).")
        }
        return count
    }

    /// What the live session reported, with each signal's arrival in stream milliseconds.
    private final class Observation: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Any] = [:]
        func set(_ key: String, _ value: Any) {
            lock.lock()
            values[key] = value
            lock.unlock()
        }
        func get(_ key: String) -> Any? {
            lock.lock()
            defer { lock.unlock() }
            return values[key]
        }
        var all: [String: Any] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    func testTurnDetectionOnLearnerStreams() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MOCHI_LIVE_E5"] == "1", let itemsPath = environment["MOCHI_E5_ITEMS"],
            let outPath = environment["MOCHI_E5_OUT"]
        else {
            throw XCTSkip(
                "E5 uses the network and your subscription; set MOCHI_LIVE_E5=1, MOCHI_E5_ITEMS, MOCHI_E5_OUT.")
        }
        let items = try String(contentsOfFile: itemsPath, encoding: .utf8).split(separator: "\n")
            .filter { !$0.allSatisfy(\.isWhitespace) }
            .map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        // An empty manifest would test nothing and still pass.
        guard !items.isEmpty else { throw AppFailure(verbatim: "MOCHI_E5_ITEMS lists no streams.") }
        let out = URL(fileURLWithPath: outPath)
        if !FileManager.default.fileExists(atPath: out.path) {
            XCTAssertTrue(FileManager.default.createFile(atPath: out.path, contents: nil))
        }
        let concurrency = try Self.concurrency(environment)
        // A run stopped mid-write can leave a torn last line; it is cut off, and that pair runs again.
        var stored = try Data(contentsOf: out)
        if let last = stored.lastIndex(of: UInt8(ascii: "\n")) {
            let tail = stored[(last + 1)...]
            if !tail.isEmpty {
                print("E5: dropping a torn last record of \(tail.count) bytes")
                stored = stored.prefix(last + 1)
                try stored.write(to: out, options: .atomic)
            }
        } else if !stored.isEmpty {
            print("E5: dropping a torn only record of \(stored.count) bytes")
            stored = Data()
            try stored.write(to: out, options: .atomic)
        }
        let done = Set(
            try String(decoding: stored, as: UTF8.self).split(separator: "\n").compactMap { line -> String? in
                guard let row = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                    row["error"] == nil
                else { return nil }
                return "\(row["id"] ?? "")/\(row["configuration"] ?? "")"
            })
        // MOCHI_E5_CONFIGURATIONS (comma-separated names) limits the run to those configurations.
        let only = environment["MOCHI_E5_CONFIGURATIONS"].map { Set($0.split(separator: ",").map(String.init)) }
        let configurations = Self.configurations.filter { only?.contains($0.name) ?? true }
        XCTAssertFalse(configurations.isEmpty, "MOCHI_E5_CONFIGURATIONS names no known configuration")
        var jobs: [([String: Any], Configuration)] = []
        for item in items {
            for configuration in configurations where !done.contains("\(item["id"] ?? "")/\(configuration.name)") {
                jobs.append((item, configuration))
            }
        }
        print("E5: \(jobs.count) streams to run, \(done.count) already done")
        let handle = try FileHandle(forWritingTo: out)
        defer { try? handle.close() }
        try handle.seekToEnd()
        var written = 0
        var failures = 0
        var unresolved: [String] = []
        try await withThrowingTaskGroup(of: [String: Any].self) { group in
            var next = 0
            func enqueue() {
                guard next < jobs.count else { return }
                let (item, configuration) = jobs[next]
                next += 1
                group.addTask { await Self.run(item, configuration) }
            }
            for _ in 0..<concurrency { enqueue() }
            while let row = try await group.next() {
                // One write per record, so a stop between writes cannot join two records.
                handle.write(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) + Data("\n".utf8))
                written += 1
                failures = row["error"] == nil ? 0 : failures + 1
                if row["error"] != nil { unresolved.append("\(row["id"] ?? "")/\(row["configuration"] ?? "")") }
                if failures >= 15 {
                    group.cancelAll()
                    XCTFail("E5 stopped after \(failures) failures in a row; last: \(row["error"] ?? "")")
                    return
                }
                if written % 25 == 0 { print("E5: \(written) of \(jobs.count)") }
                enqueue()
            }
        }
        // Results are kept either way; a failed pair runs again next time, but this run is not complete.
        XCTAssertTrue(
            unresolved.isEmpty,
            "E5: \(unresolved.count) pairs failed and will run again: \(unresolved.prefix(10).joined(separator: ", "))")
    }

    /// E5's billing check: one fixed-length stream sent at once, and the same stream sent after the session sat open
    /// and idle for MOCHI_E5_IDLE_SECONDS (default 30), as hands-free keeps a session ready before speech. The usage
    /// each transcription reports, and every other event carrying usage, go to MOCHI_E5_BILLING_OUT.
    func testIdleSessionAndStreamedAudioUsage() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MOCHI_LIVE_E5"] == "1", let pcmPath = environment["MOCHI_E5_BILLING_PCM"],
            let outPath = environment["MOCHI_E5_BILLING_OUT"]
        else { throw XCTSkip("Set MOCHI_LIVE_E5=1, MOCHI_E5_BILLING_PCM and MOCHI_E5_BILLING_OUT.") }
        let pcm = try Data(contentsOf: URL(fileURLWithPath: pcmPath))
        let idle =
            try environment["MOCHI_E5_IDLE_SECONDS"].map { text in
                guard let seconds = Double(text), seconds.isFinite, (1...600).contains(seconds) else {
                    throw AppFailure(verbatim: "MOCHI_E5_IDLE_SECONDS must be a number of seconds from 1 to 600.")
                }
                return seconds
            } ?? 30
        var rows: [[String: Any]] = []
        for wait in [0, idle] {
            let observation = Observation()
            var usages: [[String: Any]] = []
            let service = RealtimeService()
            let session = try await ListeningSession.open(
                service: service, detection: .semantic(eagerness: "low"),
                transcriptionModel: RealtimeService.transcriptionModel, languages: [],
                credential: { try await service.token() },
                connect: { request in
                    let live = RealtimeChannel.live(request)
                    return RealtimeChannel(
                        send: live.send,
                        receive: {
                            let event = try await live.receive()
                            let usage =
                                event["usage"] ?? (event["response"] as? [String: Any])?["usage"]
                            if let usage {
                                observation.set(
                                    "usage-\(observation.all.count)",
                                    ["event": event["type"] ?? "", "usage": usage])
                            }
                            return event
                        }, close: live.close)
                })
            defer { session.close() }
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            let origin = Date()
            let sender = Task {
                for offset in stride(from: 0, to: pcm.count, by: 4800) {
                    let wait = origin.addingTimeInterval(Double(offset) / 48000).timeIntervalSinceNow
                    if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                    session.append(pcm.subdata(in: offset..<min(offset + 4800, pcm.count)))
                }
            }
            let watchdog = Task {
                // Cancelled once the transcript arrives: then it must not close the session, which still collects
                // the usage that follows.
                do { try await Task.sleep(nanoseconds: UInt64((Double(pcm.count) / 48000 + 8) * 1_000_000_000)) } catch
                {
                    return
                }
                session.close()
            }
            // Stopped on every exit, including a stream that throws.
            defer {
                sender.cancel()
                watchdog.cancel()
            }
            var transcript = ""
            for try await signal in session.signals {
                if case .transcribed(let text) = signal {
                    transcript = text
                    break
                }
            }
            sender.cancel()
            watchdog.cancel()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            for (_, value) in observation.all { if let value = value as? [String: Any] { usages.append(value) } }
            // Missing evidence must not read as evidence of no billing.
            XCTAssertFalse(transcript.isEmpty, "Idle \(wait) s: no transcript arrived; the comparison is not valid")
            XCTAssertTrue(
                usages.contains { $0["event"] as? String == "conversation.item.input_audio_transcription.completed" },
                "Idle \(wait) s: the transcription reported no usage; the comparison is not valid")
            rows.append([
                "idle_seconds": wait, "stream_ms": pcm.count / 48, "transcript": transcript, "usages": usages,
            ])
        }
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: outPath))
    }

    /// Where the Mac's detector hears speech start in `pcm`, fed as capture delivers it, in samples.
    static func detectedStart(_ pcm: Data) -> Int? {
        var detector = SpeechActivityDetector()
        for offset in stride(from: 0, to: pcm.count, by: 2400) {
            if let start = detector.feed(pcm.subdata(in: offset..<min(offset + 2400, pcm.count))) { return start }
        }
        return nil
    }

    /// Where a turn judged on the Mac would end: the first point after speech starts with `silence` of quiet.
    static func localEnd(_ pcm: Data, silence: TimeInterval) -> Int? {
        var detector = SpeechActivityDetector()
        for offset in stride(from: 0, to: pcm.count, by: 960) {
            detector.feed(pcm.subdata(in: offset..<min(offset + 960, pcm.count)))
            if detector.speechStart != nil && detector.trailingSilence >= silence { return (offset + 960) / 2 }
        }
        return nil
    }

    private static func run(_ item: [String: Any], _ configuration: Configuration) async -> [String: Any] {
        var row: [String: Any] = [
            "id": item["id"] ?? "", "kind": item["kind"] ?? "", "configuration": configuration.name,
            "speech_start_ms": item["speech_start_ms"] ?? NSNull(), "speech_end_ms": item["speech_end_ms"] ?? NSNull(),
        ]
        do {
            let pcm = try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(item["pcm"] as? String)))
            guard let start = detectedStart(pcm) else {
                row["detected_start_ms"] = NSNull()
                return row
            }
            row["detected_start_ms"] = start * 1000 / 24000
            if let silence = configuration.localSilence {
                row["stopped_ms"] = localEnd(pcm, silence: silence).map { $0 * 1000 / 24000 } ?? NSNull()
                row["arrived_ms"] = row["stopped_ms"]
                return row
            }
            let from = max(0, start - preRollMilliseconds * 24)
            row["stream_from_ms"] = from * 1000 / 24000
            try await stream(pcm, from: from, configuration: configuration, into: &row)
        } catch {
            row["error"] = String(describing: error)
        }
        return row
    }

    /// Streams `pcm` from sample `from` in real time and records the signals. Stream positions are milliseconds
    /// from the start of the whole stream, so they compare directly with the reference speech span.
    private static func stream(
        _ pcm: Data, from: Int, configuration: Configuration, into row: inout [String: Any]
    ) async throws {
        let detection = try XCTUnwrap(configuration.detection)
        let observation = Observation()
        let fromMilliseconds = from * 1000 / 24000
        let opening = Date()
        let service = RealtimeService()
        let session = try await ListeningSession.open(
            service: service, detection: detection, transcriptionModel: RealtimeService.transcriptionModel,
            languages: [], credential: { try await service.token() },
            connect: { request in
                let live = RealtimeChannel.live(request)
                return RealtimeChannel(
                    send: live.send,
                    receive: {
                        let event = try await live.receive()
                        if event["type"] as? String == "conversation.item.input_audio_transcription.completed",
                            let usage = event["usage"]
                        {
                            observation.set("usage", usage)
                        }
                        return event
                    }, close: live.close)
            })
        defer { session.close() }
        row["handshake_ms"] = Int(Date().timeIntervalSince(opening) * 1000)
        let origin = Date()
        let position = { fromMilliseconds + Int(Date().timeIntervalSince(origin) * 1000) }
        let sender = Task {
            var sent = 0
            for offset in stride(from: from * 2, to: pcm.count, by: 4800) {
                let due = origin.addingTimeInterval(Double(offset - from * 2) / 48000)
                let wait = due.timeIntervalSinceNow
                if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                if observation.get("stopped_ms") != nil { break }
                session.append(pcm.subdata(in: offset..<min(offset + 4800, pcm.count)))
                sent = offset + 4800
            }
            observation.set("streamed_ms", (min(sent, pcm.count) - from * 2) / 48)
        }
        let watchdog = Task {
            // The stream holds 10 s of quiet after the turn; a little longer allows for a late transcript.
            let total = Double(pcm.count - from * 2) / 48000 + 5
            try await Task.sleep(nanoseconds: UInt64(total * 1_000_000_000))
            session.close()
        }
        defer {
            sender.cancel()
            watchdog.cancel()
        }
        signals: for try await signal in session.signals {
            switch signal {
            case .speechStarted(let at):
                if observation.get("started_ms") == nil {
                    observation.set("started_ms", at.map { fromMilliseconds + $0 } ?? NSNull())
                }
            case .speechStopped(let at):
                if observation.get("stopped_ms") == nil {
                    observation.set("stopped_ms", at.map { fromMilliseconds + $0 } ?? NSNull())
                    observation.set("arrived_ms", position())
                    // The transcript follows the end; it is what checks the pre-roll.
                    Task {
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        session.close()
                    }
                }
            case .transcribed(let text):
                observation.set("transcript", text)
                observation.set("transcribed_ms", position())
                break signals
            }
        }
        // An aborted run stops streaming at once instead of after the fixture's remaining audio.
        if Task.isCancelled {
            sender.cancel()
            session.close()
        }
        _ = try? await sender.value
        try Task.checkCancellation()
        for (key, value) in observation.all { row[key] = value }
    }
}
