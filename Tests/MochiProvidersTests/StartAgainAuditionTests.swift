import MochiCore
import MochiKernel
import XCTest

@testable import MochiProviders

/// Start Again against the live service (plan W3): after a long role-play, the reply must state the scenario the
/// conversation set up and wait, never invent one. It uses the network and the user's subscription, so it runs only
/// with MOCHI_LIVE_AUDITION=1.
final class StartAgainAuditionTests: XCTestCase {
    private static let restart = "Let's start again from the beginning."
    private static let opening = [
        ("assistant", "Hi, I'm Alex. What job are you preparing for?"),
        (
            "user",
            "A product manager role at Lumen Health, a medical software company. The interviewer will be Ms Chen."
        ),
        ("assistant", "Great. I'll play Ms Chen from Lumen Health. Let's begin: tell me about yourself."),
        ("user", "I've been a project coordinator at a logistics firm for four years."),
        ("assistant", "What made you want to move into this kind of role?"),
        ("user", "I like talking to users and deciding what to build next."),
    ]
    /// Interview turns that never name the job, the company or the interviewer.
    private static let middle: [(String, String)] = [
        (
            "Tell me about a time you handled a disagreement.",
            "Two teams wanted the same budget, so I set up a meeting."
        ),
        ("How did that meeting go?", "We agreed to split the work over two quarters."),
        ("What would your manager say is your biggest strength?", "Probably that I stay calm under pressure."),
        ("And a weakness?", "I sometimes take on too much myself."),
        ("How do you decide what matters most?", "I look at what helps the most people soonest."),
        ("Give me an example.", "We fixed a slow login before adding new features."),
        ("How do you work with engineers?", "I ask them early what is hard and what is easy."),
        ("What tools do you use to plan?", "Mostly spreadsheets and a simple board."),
        ("How do you handle a missed deadline?", "I tell people early and agree a new plan."),
        ("Describe a project you're proud of.", "A new tracking page that cut support calls by a third."),
        ("How did you measure that?", "We compared the number of calls before and after."),
        ("What did you learn from it?", "That small changes can matter a lot."),
        ("How do you take feedback?", "I write it down and try one change at a time."),
        ("Tell me about a failure.", "I once launched without enough testing."),
        ("What happened next?", "We rolled it back and added a checklist."),
        ("How do you keep stakeholders informed?", "A short weekly update."),
        ("What motivates you?", "Seeing people actually use what we built."),
        ("Where do you see yourself in five years?", "Leading a small team."),
        ("Do you have questions for me?", "How is success measured in the first year?"),
        ("Good question. Anything else you'd like to add?", "Only that I learn quickly."),
    ]
    private static let change =
        "Actually, change of plan: the interview is now for a data analyst job at Northwind Bank, with Mr Ortiz."
    private static let changeAcknowledged = "Understood, a data analyst job at Northwind Bank with Mr Ortiz."

    private static func conversation(changeAt changeIndex: Int?) -> [Message] {
        var pairs = opening
        for (question, answer) in middle { pairs += [("assistant", question), ("user", answer)] }
        var messages = pairs.map { Message(role: $0.0, text: $0.1) }
        if let changeIndex {
            messages[changeIndex - 1] = Message(role: "user", text: change)
            messages[changeIndex] = Message(role: "assistant", text: changeAcknowledged)
        }
        return messages
    }
    private static func requireLive() throws {
        guard ProcessInfo.processInfo.environment["MOCHI_LIVE_AUDITION"] == "1" else {
            throw XCTSkip("Live audition uses the network and your subscription; set MOCHI_LIVE_AUDITION=1 to run it.")
        }
    }
    private static func restartReply(_ messages: [Message], selected: Bool) async throws -> String {
        let template = try XCTUnwrap(ConversationTemplate.builtins.first { $0.title == "Job interview" })
        let request = ConversationRequest(
            history: selected ? RestartHistory.select(messages) : messages, text: restart,
            instructions: template.instructions, characterName: template.characterName,
            preferences: template.preferences)
        return try await RealtimeService().reply(request).text
    }

    func testTheFixturesHaveTheShapeThePlanDescribes() {
        let plain = Self.conversation(changeAt: nil)
        XCTAssertEqual(plain.count, 46)
        XCTAssertFalse(plain.dropFirst(6).contains { $0.text.contains("Lumen") || $0.text.contains("Chen") })
        XCTAssertFalse(plain.suffix(30).contains { $0.text.contains("Lumen") }, "The latest 30 alone lose the job")
        XCTAssertTrue(RestartHistory.select(plain).contains { $0.text.contains("Lumen") })
        let changed = Self.conversation(changeAt: 30)
        XCTAssertEqual(changed[29].text, Self.change)
        XCTAssertEqual(changed[29].role, "user")
    }

    func testStartAgainStatesTheScenarioAndWaits() async throws {
        try Self.requireLive()
        var lines: [String] = []
        var kept = 0
        var titled = 0
        var changedOK = 0
        var control = 0
        for run in 1...3 {
            let a = try await Self.restartReply(Self.conversation(changeAt: nil), selected: true)
            let b = try await Self.restartReply(Self.conversation(changeAt: 30), selected: true)
            let c = try await Self.restartReply(Self.conversation(changeAt: nil), selected: false)
            let names = { (text: String) in text.contains("Lumen") || text.contains("Chen") }
            let product = { (text: String) in text.localizedCaseInsensitiveContains("product") }
            let invented = { (text: String) in text.contains("Northwind") || text.contains("Ortiz") }
            // (a) the same company or interviewer, as a question, nothing invented. The job title is reported but not
            // required: a reply that restates the people and company without repeating the role has not forgotten the
            // scenario, which is what this check guards against.
            if names(a) && a.contains("?") && !invented(a) { kept += 1 }
            if product(a) { titled += 1 }
            // (b) the new job, or a question that does not assert the old one.
            let new = b.contains("Northwind") || b.contains("Ortiz") || b.localizedCaseInsensitiveContains("analyst")
            if new || (b.contains("?") && !names(b)) { changedOK += 1 }
            if names(c) && product(c) { control += 1 }
            lines += ["run \(run) (a) \(a)", "run \(run) (b) \(b)", "run \(run) control (latest 30) \(c)"]
        }
        print(lines.joined(separator: "\n"))
        print(
            "start again: (a) \(kept) of 3, (a) names the job too \(titled) of 3, (b) \(changedOK) of 3, control kept the job \(control) of 3"
        )
        XCTAssertEqual(
            kept, 3, "(a) The brief names the company or interviewer from the opening, asks, and invents nothing")
        XCTAssertEqual(changedOK, 3, "(b) The brief follows the later change or asks")
    }
}
