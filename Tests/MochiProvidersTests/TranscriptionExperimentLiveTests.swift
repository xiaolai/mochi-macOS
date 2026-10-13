import Foundation
import MochiCore
import MochiKernel
import XCTest

@testable import MochiProviders

/// Experiment E1 (plan): every transcription configuration over the fixed learner and ASCEND samples, through Mochi's
/// own transcription path. It uses the network and the user's subscription, so it runs only when MOCHI_LIVE_E1 names
/// an items file (from `e1_prepare.py`). One JSON line per item and configuration goes to MOCHI_E1_OUT; pairs already
/// there are skipped, so an interrupted run resumes where it stopped. A clip with no recognizable speech is a result,
/// not a failure: it is recorded with empty text and `no_speech`.
final class TranscriptionExperimentLiveTests: XCTestCase {
    private struct Configuration {
        let name: String
        let model: String
        let languages: [String]
    }
    /// The configurations the API accepts: `gpt-4o-mini-transcribe` refuses a list of languages.
    private static let configurations = [
        Configuration(name: "mini", model: "gpt-4o-mini-transcribe", languages: []),
        Configuration(name: "mini-en", model: "gpt-4o-mini-transcribe", languages: ["en"]),
        Configuration(name: "transcribe", model: "gpt-transcribe", languages: []),
        Configuration(name: "transcribe-en", model: "gpt-transcribe", languages: ["en"]),
        Configuration(name: "transcribe-en-zh", model: "gpt-transcribe", languages: ["en", "zh"]),
    ]
    /// Sessions in flight at once; MOCHI_E1_CONCURRENCY overrides it.
    private static let concurrency = ProcessInfo.processInfo.environment["MOCHI_E1_CONCURRENCY"].flatMap(Int.init) ?? 4
    private static let consecutiveFailureLimit = 20

    /// What one session showed besides the transcript: the transcription settings it echoed, and the time from
    /// commit to the completed transcript.
    private final class Observation: @unchecked Sendable {
        var echoed: Any = NSNull()
        var committed: Date?
        var completed: Date?
    }

    func testTranscriptionConfigurations() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let itemsPath = environment["MOCHI_LIVE_E1"], let outPath = environment["MOCHI_E1_OUT"] else {
            throw XCTSkip("E1 uses the network and your subscription; set MOCHI_LIVE_E1 and MOCHI_E1_OUT to run it.")
        }
        let items = try String(contentsOfFile: itemsPath, encoding: .utf8).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        let out = URL(fileURLWithPath: outPath)
        if !FileManager.default.fileExists(atPath: out.path) {
            XCTAssertTrue(FileManager.default.createFile(atPath: out.path, contents: nil))
        }
        let done = Set(
            try String(contentsOf: out, encoding: .utf8).split(separator: "\n").compactMap { line -> String? in
                guard let row = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                    row["error"] == nil
                else { return nil }
                return "\(row["arm"] ?? "")/\(row["id"] ?? "")/\(row["configuration"] ?? "")"
            })
        var jobs: [([String: Any], Configuration)] = []
        for item in items {
            for configuration in Self.configurations
            where !done.contains("\(item["arm"] ?? "")/\(item["id"] ?? "")/\(configuration.name)") {
                jobs.append((item, configuration))
            }
        }
        print("E1: \(jobs.count) transcriptions to run, \(done.count) already done")
        let handle = try FileHandle(forWritingTo: out)
        defer { try? handle.close() }
        try handle.seekToEnd()
        var consecutiveFailures = 0
        var written = 0
        try await withThrowingTaskGroup(of: [String: Any].self) { group in
            var next = 0
            func enqueue() {
                guard next < jobs.count else { return }
                let (item, configuration) = jobs[next]
                next += 1
                group.addTask { await Self.run(item, configuration) }
            }
            for _ in 0..<Self.concurrency { enqueue() }
            while let row = try await group.next() {
                handle.write(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
                handle.write(Data("\n".utf8))
                written += 1
                consecutiveFailures = row["error"] == nil ? 0 : consecutiveFailures + 1
                if consecutiveFailures >= Self.consecutiveFailureLimit {
                    group.cancelAll()
                    XCTFail("E1 stopped after \(consecutiveFailures) failures in a row; last: \(row["error"] ?? "")")
                    return
                }
                if written % 100 == 0 { print("E1: \(written) of \(jobs.count)") }
                enqueue()
            }
        }
    }

    /// E1's conversation path, for D2: items sent as spoken turns with today's transcription settings and a reply.
    /// Runs only when MOCHI_LIVE_E1_TURNS names an items file; one JSON line per item goes to MOCHI_E1_TURNS_OUT with
    /// the time from commit to the transcript and to the reply's first text, and whether evidence arrived.
    func testConversationTurnTranscriptionTiming() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let itemsPath = environment["MOCHI_LIVE_E1_TURNS"], let outPath = environment["MOCHI_E1_TURNS_OUT"] else {
            throw XCTSkip("Uses the network and your subscription; set MOCHI_LIVE_E1_TURNS and MOCHI_E1_TURNS_OUT.")
        }
        let items = try String(contentsOfFile: itemsPath, encoding: .utf8).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        var lines: [String] = []
        for item in items {
            let pcm = try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(item["pcm"] as? String)))
            let observation = Observation()
            var firstText: Date?
            var row: [String: Any] = ["arm": item["arm"] ?? "", "id": item["id"] ?? ""]
            do {
                let service = RealtimeService()
                let request = ConversationRequest(history: [], text: "", pcm: pcm)
                let result = try await service.reply(
                    request, credential: { try await service.token() },
                    connect: { request in
                        let live = RealtimeChannel.live(request)
                        return RealtimeChannel(
                            send: { event in
                                if event["type"] as? String == "input_audio_buffer.commit" {
                                    observation.committed = Date()
                                }
                                try await live.send(event)
                            },
                            receive: {
                                let event = try await live.receive()
                                switch event["type"] as? String {
                                case "conversation.item.input_audio_transcription.completed":
                                    observation.completed = Date()
                                case "response.output_text.delta", "response.text.delta":
                                    if firstText == nil { firstText = Date() }
                                default: break
                                }
                                return event
                            }, close: live.close)
                    }, onResponse: nil, onTranscription: nil, onTool: nil)
                row["text"] = result.inputTranscript
                row["evidence"] = result.inputEvidence != nil
            } catch {
                row["error"] = String(describing: error)
            }
            if let committed = observation.committed {
                if let completed = observation.completed {
                    row["commit_to_transcript_ms"] = Int(completed.timeIntervalSince(committed) * 1000)
                }
                if let firstText { row["commit_to_reply_ms"] = Int(firstText.timeIntervalSince(committed) * 1000) }
            }
            lines.append(
                String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self)
            )
        }
        try (lines.joined(separator: "\n") + "\n").write(toFile: outPath, atomically: true, encoding: .utf8)
    }

    private static func run(_ item: [String: Any], _ configuration: Configuration) async -> [String: Any] {
        var row: [String: Any] = [
            "arm": item["arm"] ?? "", "id": item["id"] ?? "", "configuration": configuration.name,
            "model": configuration.model, "languages": configuration.languages,
        ]
        let observation = Observation()
        do {
            let pcm = try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(item["pcm"] as? String)))
            let service = RealtimeService()
            let result = try await service.transcribe(
                pcm, transcriptionModel: configuration.model, languages: configuration.languages,
                credential: { try await service.token() },
                connect: { request in
                    let live = RealtimeChannel.live(request)
                    return RealtimeChannel(
                        send: { event in
                            if event["type"] as? String == "input_audio_buffer.commit" {
                                observation.committed = Date()
                            }
                            try await live.send(event)
                        },
                        receive: {
                            let event = try await live.receive()
                            switch event["type"] as? String {
                            case "session.updated":
                                let session = event["session"] as? [String: Any]
                                let input = (session?["audio"] as? [String: Any])?["input"] as? [String: Any]
                                observation.echoed = input?["transcription"] ?? NSNull()
                            case "conversation.item.input_audio_transcription.completed":
                                observation.completed = Date()
                            default: break
                            }
                            return event
                        }, close: live.close)
                })
            row["text"] = result.text
            if let evidence = result.evidence {
                row["evidence"] = evidence.pieces.map { ["end": $0.end, "logprob": $0.logprob] }
            }
        } catch let failure as AppFailure where failure.message.hasPrefix("No clear speech was recognized") {
            row["text"] = ""
            row["no_speech"] = true
        } catch {
            row["error"] = String(describing: error)
        }
        row["echoed"] = observation.echoed
        if let committed = observation.committed, let completed = observation.completed {
            row["commit_to_transcript_ms"] = Int(completed.timeIntervalSince(committed) * 1000)
        }
        return row
    }
}
