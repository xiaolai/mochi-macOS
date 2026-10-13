import MochiCore
import MochiKernel
import XCTest

@testable import MochiProviders

/// Plays learner conversations with planted errors through gentle and direct coaching, with the current instructions
/// and with the earlier one-line ones, and writes every reply with its turn's key for blinded labelling (plan W2,
/// rubric in dev-docs/research/english-learning-2026-10/coaching-rubric.md). It uses the network and the user's
/// subscription, so it runs only with MOCHI_LIVE_AUDITION=1.
final class CoachingAuditionTests: XCTestCase {
    /// What a learner turn is, for scoring; the labeller never sees it.
    private enum Kind: String { case clean, informal, planted, repeated, ambiguous }
    private struct Turn {
        let text: String
        let kind: Kind
        /// The wrong words, for planted and repeated errors.
        var span: String?
        var fix: String?
    }
    private struct Conversation {
        let id: String
        var instructions = ""
        let turns: [Turn]
    }
    private static func clean(_ text: String) -> Turn { Turn(text: text, kind: .clean) }
    private static func informal(_ text: String) -> Turn { Turn(text: text, kind: .informal) }
    private static func ambiguous(_ text: String) -> Turn { Turn(text: text, kind: .ambiguous) }
    private static func planted(_ text: String, _ span: String, _ fix: String) -> Turn {
        Turn(text: text, kind: .planted, span: span, fix: fix)
    }
    private static func repeated(_ text: String, _ span: String, _ fix: String) -> Turn {
        Turn(text: text, kind: .repeated, span: span, fix: fix)
    }
    private static let conversations = [
        Conversation(
            id: "A-trip",
            turns: [
                clean("Hi! I just got back from a short trip."),
                planted("I go to Hangzhou with my sister last weekend.", "go", "went"),
                informal("Yeah, it was kinda rainy but whatever."),
                planted("We eated a lot of local food there.", "eated", "ate"),
                clean("The lake was beautiful in the morning."),
                planted("My sister is more taller than me, so she carried the big bag.", "more taller", "taller"),
                informal("Gonna go back in spring for sure."),
                ambiguous("And then we saw the thing, you know, the long one, at night."),
                repeated("Yesterday I go to the office and told everyone about the trip.", "go", "went"),
                clean("Anyway, what's a good place to visit in autumn?"),
            ]),
        Conversation(
            id: "B-work",
            turns: [
                clean("I want to talk about my new job."),
                planted("I am work in a design company since March.", "am work", "have been working"),
                clean("My team is small but very friendly."),
                planted("My boss give me feedback every Friday.", "give", "gives"),
                informal("Honestly it's a lot, but I'm kinda into it."),
                planted("I am interesting in learning motion design.", "interesting", "interested"),
                clean("Do you think online courses are worth it?"),
                informal("Yeah, fair enough."),
                repeated("I am interesting in user research too.", "interesting", "interested"),
                planted("Maybe I should to ask my boss about training.", "should to ask", "should ask"),
            ]),
        Conversation(
            id: "C-cooking",
            turns: [
                clean("Can we talk about cooking? I started cooking at home."),
                planted("Yesterday I cook tomato and egg noodles for my roommate.", "cook", "cooked"),
                informal("It was pretty good, not gonna lie."),
                planted("She said it is too much salt.", "it is too much salt", "it was too salty"),
                clean("Next time I will use less soy sauce."),
                ambiguous("Do you know the sauce that is black and also sweet, the one for... I forget."),
                planted("I have went to the market this morning to buy vegetables.", "have went", "went"),
                clean("I bought spinach, mushrooms and some tofu."),
                repeated("Last night I cook dinner for my parents too.", "cook", "cooked"),
                informal("Kinda proud of myself, haha."),
            ]),
        Conversation(
            id: "D-no-corrections",
            instructions: "Just chat with me casually. Please do not correct my English, even when I make mistakes.",
            turns: [
                clean("Hi, how are you today?"),
                planted("I watch a very good movie yesterday.", "watch", "watched"),
                planted("It make me cry at the end.", "make", "made"),
                clean("Do you like sad movies?"),
                planted("My friend don't like them at all.", "don't", "doesn't"),
            ]),
    ]
    /// The coaching lines before plan W2, verbatim.
    private static let earlier: [CoachingStyle: String] = [
        .gentle:
            "Speak only English. Offer occasional gentle corrections of their English when useful, without interrupting the conversation.",
        .direct:
            "Speak only English. Offer concise direct corrections of significant English errors, then continue the conversation.",
    ]
    private static let runs = 3
    private static let parallel = 6

    private static func request(
        _ conversation: Conversation, style: CoachingStyle, earlierText: Bool, history: [Message], text: String
    ) throws -> ConversationRequest {
        var preferences = ConversationPreferences()
        preferences.language = .english
        preferences.coaching = style
        var request = ConversationRequest(
            history: history, text: text, instructions: conversation.instructions, preferences: preferences)
        if earlierText {
            let current = request.resolvedInstructions
            var lines = current.components(separatedBy: "\n")
            guard let index = lines.firstIndex(where: { $0.hasPrefix("Speak only English.") }),
                let line = earlier[style]
            else { throw AppFailure(verbatim: "No coaching line to replace") }
            lines[index] = line
            request.instructionsOverride = lines.joined(separator: "\n")
        }
        return request
    }

    func testTheEarlierTextIsWhatTheSeamSends() throws {
        let conversation = Self.conversations[0]
        for style in [CoachingStyle.gentle, .direct] {
            let current = try Self.request(conversation, style: style, earlierText: false, history: [], text: "Hi")
            let earlier = try Self.request(conversation, style: style, earlierText: true, history: [], text: "Hi")
            let service = RealtimeService()
            let sent = try service.sessionConfiguration(current, toolsEnabled: false)["instructions"] as? String
            let sentEarlier = try service.sessionConfiguration(earlier, toolsEnabled: false)["instructions"] as? String
            XCTAssertNotEqual(sent, sentEarlier)
            XCTAssertEqual(sentEarlier?.contains(try XCTUnwrap(Self.earlier[style])), true)
            XCTAssertEqual(sent?.contains("at most once per reply"), true)
            XCTAssertEqual(sentEarlier?.contains("at most once per reply"), false)
            // Everything else in the instructions is the same.
            XCTAssertEqual(
                sent?.components(separatedBy: "\n").filter { !$0.hasPrefix("Speak only") },
                sentEarlier?.components(separatedBy: "\n").filter { !$0.hasPrefix("Speak only") })
        }
    }

    private struct Chain: Sendable {
        let run: Int
        let earlierText: Bool
        let style: CoachingStyle
        let conversation: Int
    }

    func testCoachingAudition() async throws {
        guard ProcessInfo.processInfo.environment["MOCHI_LIVE_AUDITION"] == "1" else {
            throw XCTSkip("Live audition uses the network and your subscription; set MOCHI_LIVE_AUDITION=1 to run it.")
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/evidence/coaching-audition/\(stamp)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // MOCHI_AUDITION_CONDITIONS=current replays only the current text, after the earlier one was measured once.
        let conditions =
            ProcessInfo.processInfo.environment["MOCHI_AUDITION_CONDITIONS"] == "current" ? [false] : [false, true]
        var chains: [Chain] = []
        for run in 1...Self.runs {
            for earlierText in conditions {
                for style in [CoachingStyle.gentle, .direct] {
                    for conversation in Self.conversations.indices {
                        chains.append(
                            Chain(run: run, earlierText: earlierText, style: style, conversation: conversation))
                    }
                }
            }
        }
        var rows: [[String: Any]] = []
        var failures: [String] = []
        try await withThrowingTaskGroup(of: ([[String: Any]], String?).self) { group in
            var next = 0
            func start() {
                guard next < chains.count else { return }
                let chain = chains[next]
                next += 1
                group.addTask { await Self.play(chain) }
            }
            for _ in 0..<Self.parallel { start() }
            while let (played, failure) = try await group.next() {
                rows += played
                if let failure { failures.append(failure) }
                start()
            }
        }
        let lines = try rows.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        try (lines.joined(separator: "\n") + "\n").write(
            to: folder.appendingPathComponent("replies.jsonl"), atomically: true, encoding: .utf8)
        print("coaching audition: \(rows.count) replies in \(folder.path)")
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
        let expected = Self.runs * conditions.count * 2 * Self.conversations.map(\.turns.count).reduce(0, +)
        XCTAssertEqual(rows.count, expected, "Every turn of every chain has a reply")
    }

    /// One conversation played turn by turn; a reply that fails is retried once, then the chain stops.
    private static func play(_ chain: Chain) async -> ([[String: Any]], String?) {
        let conversation = conversations[chain.conversation]
        let service = RealtimeService()
        var history: [Message] = []
        var rows: [[String: Any]] = []
        for (index, turn) in conversation.turns.enumerated() {
            var text: String?
            var lastError: Error?
            for _ in 0..<2 where text == nil {
                do {
                    let request = try Self.request(
                        conversation, style: chain.style, earlierText: chain.earlierText, history: history,
                        text: turn.text)
                    text = try await service.reply(request).text.trimmingCharacters(in: .whitespacesAndNewlines)
                } catch {
                    lastError = error
                }
            }
            guard let text, !text.isEmpty else {
                return (rows, "\(conversation.id) run \(chain.run) turn \(index + 1): \(String(describing: lastError))")
            }
            var row: [String: Any] = [
                "run": chain.run, "condition": chain.earlierText ? "earlier" : "current", "style": chain.style.rawValue,
                "conversation": conversation.id, "turn": index + 1, "kind": turn.kind.rawValue, "user": turn.text,
                "reply": text,
            ]
            if let span = turn.span { row["span"] = span }
            if let fix = turn.fix { row["fix"] = fix }
            rows.append(row)
            history += [Message(role: "user", text: turn.text), Message(role: "assistant", text: text)]
        }
        return (rows, nil)
    }
}
