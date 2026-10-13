import MochiCore
import MochiKernel
import MochiProviders
import XCTest

@testable import MochiApp

/// Start Again (plan W3): the request is the user's message, sent with the conversation's opening as well as its
/// latest messages.
final class StartAgainTests: XCTestCase {
    private let interview = try! XCTUnwrap(ConversationTemplate.builtins.first { $0.title == "Job interview" })

    /// A conversation from the job-interview template with `count` alternating messages, selected.
    @MainActor private func appWithConversation(_ count: Int) -> AppModel {
        let app = makeApp(root: makeTemporaryFolder())
        var chat = Conversation(title: "Interview")
        chat.sourceTemplateID = interview.id
        chat.messages = (1...count).map { Message(role: $0 % 2 == 1 ? "user" : "assistant", text: "m\($0)") }
        app.library.conversations = [chat]
        app.selectedID = chat.id
        app.resume()
        return app
    }
    @MainActor private func capture(_ app: AppModel, failing: Bool = false) -> () -> ConversationRequest? {
        var sent: ConversationRequest?
        app.speech.conversationReply = { _, request, callbacks in
            sent = request
            if failing { throw AppFailure("Offline.") }
            var reply = RealtimeAccumulator()
            reply.text = "We'll redo the interview — is that right?"
            reply.done = true
            try callbacks.response(reply)
        }
        return { sent }
    }

    @MainActor func testStartAgainSendsTheOpeningAndTheLatestWithTheRequestAsItsOwnText() async throws {
        let app = appWithConversation(46)
        let sent = capture(app)
        XCTAssertTrue(app.canStartAgain)
        app.startAgain()
        await waitUntil { !app.busy }
        let request = try XCTUnwrap(sent())
        XCTAssertEqual(request.text, String(localized: "Let's start again from the beginning."))
        XCTAssertEqual(request.history.map(\.text), (1...10).map { "m\($0)" } + (27...46).map { "m\($0)" })
        XCTAssertFalse(request.history.contains { $0.text == request.text }, "The request is never in the history")
        let messages = try XCTUnwrap(app.conversation?.messages)
        XCTAssertEqual(messages.count, 48)
        XCTAssertEqual(messages[46].text, request.text)
        XCTAssertEqual(messages[46].role, "user")
    }
    @MainActor func testAnOrdinaryMessageStillSendsTheWholeHistory() async throws {
        let app = appWithConversation(46)
        let sent = capture(app)
        app.draft = "Next question, please."
        app.send()
        await waitUntil { !app.busy }
        XCTAssertEqual(try XCTUnwrap(sent()).history.count, 46)
    }
    @MainActor func testRetryingAFailedStartAgainSendsTheSameHistory() async throws {
        let app = appWithConversation(46)
        var sent = capture(app, failing: true)
        app.startAgain()
        await waitUntil { !app.busy }
        XCTAssertNotNil(app.error)
        XCTAssertTrue(app.canRetry)
        sent = capture(app)
        app.retryReply()
        await waitUntil { !app.busy }
        let request = try XCTUnwrap(sent())
        XCTAssertEqual(request.text, String(localized: "Let's start again from the beginning."))
        XCTAssertEqual(request.history.count, 30)
        XCTAssertEqual(request.history.first?.text, "m1")
    }
    @MainActor func testStartAgainNeedsSomethingToStartAgainFrom() {
        let app = appWithConversation(1)
        app.library.conversations[0].messages = [Message(role: "assistant", text: "Which job is it for?")]
        XCTAssertFalse(app.canStartAgain, "Only a greeting so far")
        app.startAgain()
        XCTAssertEqual(app.conversation?.messages.count, 1)
    }
    @MainActor func testStartAgainWaitsWhileBusy() {
        let app = appWithConversation(4)
        XCTAssertTrue(app.canStartAgain)
        _ = app.turn.begin(.generating)
        XCTAssertFalse(app.canStartAgain)
        app.startAgain()
        XCTAssertEqual(app.conversation?.messages.count, 4)
    }
    @MainActor func testTheButtonIsForRolePlayConversations() {
        let app = appWithConversation(4)
        XCTAssertTrue(app.isRolePlay)
        app.library.conversations[0].sourceTemplateID =
            ConversationTemplate.builtins.first {
                $0.title == "Brainstorm with me"
            }?.id
        XCTAssertFalse(app.isRolePlay)
        app.library.conversations[0].sourceTemplateID = nil
        XCTAssertFalse(app.isRolePlay)
        XCTAssertTrue(app.canStartAgain, "The menu item works in any conversation")
    }
    func testRolePlayTemplatesAreTheScenarioOnes() {
        XCTAssertEqual(
            Set(ConversationTemplate.builtins.filter(\.isRolePlay).map(\.title)),
            ["Restaurant", "Hotel check-in", "Job interview", "Rehearse a conversation", "Interview my character"])
    }
    func testInstructionsConfirmTheScenarioBeforeRestarting() {
        let text = VoiceIdentity.conversationInstructions(custom: "", preferences: ConversationPreferences())
        XCTAssertTrue(text.contains("When the user asks to start again, do not restart yet"))
        XCTAssertTrue(text.contains("Begin only after they confirm"))
        XCTAssertTrue(text.contains("ask instead of inventing it"))
    }
}
