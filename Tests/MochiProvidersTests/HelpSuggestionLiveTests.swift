import MochiCore
import MochiKernel
import XCTest

@testable import MochiProviders

/// Help Me Say This against the live services: every reply to a text thought must parse as a HelpSuggestion, from
/// Codex's text endpoint (the main path) and from the voice model (the fallback). It uses
/// the network and the user's subscription, so it runs only with MOCHI_LIVE_AUDITION=1. Raw replies are written to
/// build/evidence/help-suggestion/ so a parse failure can be read, not guessed.
final class HelpSuggestionLiveTests: XCTestCase {
    private static let thoughts = [
        "我们家 Shirley 没那么脆弱，这不是什么大不了的事儿。",
        "我昨天和老板谈了加薪的事，但是他说预算还没批下来，让我下个月再问。",
        "我不太确定这个周末能不能去，因为还要看孩子的情况。",
    ]
    private static let runs = 8

    func testEveryCodexReplyParsesFirstTime() async throws {
        guard ProcessInfo.processInfo.environment["MOCHI_LIVE_AUDITION"] == "1" else {
            throw XCTSkip("Live check uses the network and your subscription; set MOCHI_LIVE_AUDITION=1 to run it.")
        }
        let status = await CodexCatalog.status()
        XCTAssertNil(status.signInProblem)
        let model = try XCTUnwrap(CodexModel.resolve(selected: nil, in: status.models), "Codex lists no models")
        print("codex text model: \(model.slug), effort \(model.lightestEffort ?? "default")")
        var failures: [String] = []
        for thought in Self.thoughts {
            for run in 1...Self.runs {
                let request = ConversationRequest(history: [], text: thought, help: true)
                do {
                    let raw = try await CodexTextService(model: model).help(request)
                    _ = try HelpSuggestion.parse(raw)
                } catch {
                    failures.append("run \(run) \(thought.prefix(12)): \(error)")
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testEveryLiveReplyParses() async throws {
        guard ProcessInfo.processInfo.environment["MOCHI_LIVE_AUDITION"] == "1" else {
            throw XCTSkip("Live check uses the network and your subscription; set MOCHI_LIVE_AUDITION=1 to run it.")
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/evidence/help-suggestion/\(stamp)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var rows: [[String: Any]] = []
        var failures: [String] = []
        for thought in Self.thoughts {
            for run in 1...Self.runs {
                let service = RealtimeService()
                let request = ConversationRequest(history: [], text: thought, help: true)
                var row: [String: Any] = ["thought": thought, "run": run]
                do {
                    // The app asks again once when the first reply is unreadable; mirror that.
                    var raw = try await service.reply(request).text
                    var attempts = 1
                    if (try? HelpSuggestion.parse(raw)) == nil {
                        raw = try await service.reply(request).text
                        attempts = 2
                    }
                    row["raw"] = raw
                    row["attempts"] = attempts
                    do {
                        let suggestion = try HelpSuggestion.parse(raw)
                        row["parsed"] = suggestion.kind.rawValue
                    } catch {
                        row["parsed"] = "FAILED"
                        failures.append("run \(run) \(thought.prefix(12)): \(raw.prefix(200))")
                    }
                } catch {
                    row["error"] = String(describing: error)
                    failures.append("run \(run) \(thought.prefix(12)): request failed \(error)")
                }
                rows.append(row)
            }
        }
        let lines = try rows.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        try (lines.joined(separator: "\n") + "\n").write(
            to: folder.appendingPathComponent("replies.jsonl"), atomically: true, encoding: .utf8)
        print("help suggestion: \(rows.count) replies in \(folder.path)")
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }
}
