import MochiAutomation
import MochiCore
import MochiKernel
import XCTest

@testable import MochiApp

/// External tools as an MCP client meets them: results that match their advertised output schemas, paging,
/// and the conversation and playback tools.
final class ExternalToolTests: XCTestCase {
    /// Every external tool, called through the control bridge, returns a result its output schema describes in
    /// full. A result that gains a field fails here until the schema documents it.
    @MainActor func testEverySuccessfulResultMatchesItsOutputSchema() throws {
        let app = controlledApp()
        var covered = Set<String>()
        func call(_ name: String, _ arguments: [String: Any] = [:]) throws -> [String: Any] {
            let request = try JSONSerialization.data(withJSONObject: [
                "name": name, "arguments": arguments, "request_id": UUID().uuidString,
            ])
            let result = try XCTUnwrap(
                JSONSerialization.jsonObject(with: app.tools.handleControlRequest(request)) as? [String: Any])
            XCTAssertEqual(result["ok"] as? Bool, true, "\(name): \(result["error"] ?? "")")
            let tool = try XCTUnwrap(MochiTools.catalog(origin: .external).first { $0.name.rawValue == name })
            XCTAssertEqual(Self.schemaProblems(result, tool.outputSchema), [], name)
            covered.insert(name)
            return result
        }
        func changing(_ arguments: [String: Any] = [:]) -> [String: Any] {
            arguments.merging(["expected_revision": app.tools.revision]) { _, new in new }
        }
        let id = try XCTUnwrap(app.selectedID).uuidString
        try PCM.wav(Data(repeating: 0, count: 4800)).write(to: app.store.root.appendingPathComponent("fixture.wav"))
        app.append(Message(role: "user", text: "Hello"), to: try XCTUnwrap(app.selectedID))
        app.append(
            Message(role: "assistant", text: "Hi there", audio: "fixture.wav"), to: try XCTUnwrap(app.selectedID))
        app.audio.makePlayer = { _ in TestPlayer() }

        _ = try call("get_session")
        _ = try call("get_messages", ["conversation_id": id])
        let saved = try call(
            "save_expression", changing(["conversation_id": id, "text": "Let me think.", "meaning": "Pause"]))
        let expressionID = try XCTUnwrap(saved["expression_id"] as? String)
        XCTAssertNotNil(
            app.library.expressions.first { $0.id.uuidString == expressionID }?.review,
            "An expression saved by a tool joins spoken review like one saved in the app")
        _ = try call("search_expressions", ["conversation_id": id, "query": ""])
        _ = try call("search_all_expressions", ["query": "think"])
        let message = try XCTUnwrap(app.conversation?.messages.last?.id.uuidString)
        _ = try call("play_audio", changing(["conversation_id": id, "message_id": message]))
        _ = try call("pause_audio", changing(["conversation_id": id]))
        _ = try call("resume_audio", changing(["conversation_id": id]))
        _ = try call("seek_audio", changing(["conversation_id": id, "message_id": message, "seconds": 0.5]))
        _ = try call("stop_audio", changing(["conversation_id": id]))
        _ = try call("set_conversation_preferences", changing(["conversation_id": id, "speed": 0.9]))
        _ = try call(
            "set_conversation_instructions",
            changing(["conversation_id": id, "instructions": "Interview me", "character_name": "Loki"]))
        _ = try call(
            "set_conversation_instructions",
            changing([
                "conversation_id": id, "personality": "Wry", "greeting": "Ready?", "phrases": ["Again."],
                "voice": "ash",
            ]))
        let session = try call("get_session")
        XCTAssertEqual(session["personality"] as? String, "Wry")
        XCTAssertEqual(session["phrases"] as? [String], ["Again."])
        XCTAssertEqual(session["voice"] as? String, "ash")
        XCTAssertEqual(session["effective_voice"] as? String, "ash")
        let characters = try call("list_characters", ["origin": "built_in", "limit": 2])
        XCTAssertEqual((characters["characters"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(characters["next_offset"] as? Int, 2)
        _ = try call("prepare_expression", changing(["conversation_id": id, "text": "One moment, please."]))
        app.leavePractice()
        _ = try call("start_practice", changing(["conversation_id": id, "expression_id": expressionID]))
        app.leavePractice()
        _ = try call("list_conversations")
        _ = try call("list_conversation_templates", ["limit": 2])
        _ = try call("get_conversation_template", ["template_id": ConversationTemplate.builtins[0].id.uuidString])
        let created = try call(
            "create_conversation_template",
            [
                "title": "Book club", "character_name": "Ada", "idempotency_key": "k1", "greeting": "Which book?",
                "phrases": ["Next chapter."], "personality": "Bookish", "voice": "sage",
            ])
        let template = try XCTUnwrap(created["template"] as? [String: Any])
        let templateID = try XCTUnwrap(template["id"] as? String)
        let updated = try call(
            "update_conversation_template",
            [
                "template_id": templateID, "expected_template_revision": template["template_revision"]!,
                "instructions": "Discuss books",
            ])
        let started = try call("create_conversation", changing(["template_id": templateID, "title": "Books"]))
        let startedID = try XCTUnwrap(started["conversation_id"] as? String)
        _ = try call("get_session")
        _ = try call(
            "delete_conversation_template",
            [
                "template_id": templateID,
                "expected_template_revision": (updated["template"] as? [String: Any])?["template_revision"] ?? "",
            ])
        _ = try call("open_conversation", changing(["conversation_id": id]))
        _ = try call("rename_conversation", changing(["conversation_id": startedID, "title": "Reading"]))
        _ = try call("archive_conversation", changing(["conversation_id": startedID]))

        XCTAssertEqual(covered, Set(MochiTools.catalog(origin: .external).map(\.name.rawValue)))
    }

    @MainActor func testListConversationsPagesAndNeverShowsArchivedMatches() throws {
        let app = controlledApp()
        var archived = Conversation(title: "Alpha archived")
        archived.archived = true
        app.library.conversations =
            (1...3).map { Conversation(title: "Alpha \($0)") } + [archived, Conversation(title: "Beta")]
        func titles(_ result: [String: Any]) -> [String] {
            (result["conversations"] as? [[String: Any]] ?? []).compactMap { $0["title"] as? String }
        }
        let first = try app.tools.execute(
            "list_conversations", arguments: ["query": "alpha", "limit": 2], origin: .external)
        XCTAssertEqual(titles(first).count, 2)
        XCTAssertEqual(first["has_more"] as? Bool, true)
        XCTAssertEqual(first["next_offset"] as? Int, 2)
        let second = try app.tools.execute(
            "list_conversations", arguments: ["query": "alpha", "limit": 2, "offset": 2], origin: .external)
        XCTAssertEqual(second["has_more"] as? Bool, false)
        XCTAssertTrue(second["next_offset"] is NSNull)
        XCTAssertEqual(Set(titles(first) + titles(second)), ["Alpha 1", "Alpha 2", "Alpha 3"])
        let all = try app.tools.execute("list_conversations", arguments: [:], origin: .external)
        XCTAssertEqual(Set(titles(all)), ["Alpha 1", "Alpha 2", "Alpha 3", "Beta"])
        XCTAssertEqual(all["has_more"] as? Bool, false)
    }

    @MainActor func testRenameAndArchiveActOnAnyActiveConversation() throws {
        let app = controlledApp()
        let open = try XCTUnwrap(app.selectedID)
        let other = Conversation(title: "Other")
        app.library.conversations.append(other)
        _ = try app.tools.execute(
            "rename_conversation",
            arguments: [
                "conversation_id": other.id.uuidString, "title": "  Renamed  ", "expected_revision": app.tools.revision,
            ], origin: .external)
        let renamed = try XCTUnwrap(app.library.conversations.first { $0.id == other.id })
        XCTAssertEqual(renamed.title, "Renamed")
        XCTAssertTrue(renamed.customTitle)
        XCTAssertEqual(app.selectedID, open)
        XCTAssertEqual(
            try app.store.load().conversations.first { $0.id == other.id }?.title, "Renamed",
            "The rename was not saved")

        let stale = app.tools.revision
        _ = try app.tools.execute(
            "rename_conversation",
            arguments: ["conversation_id": open.uuidString, "title": "Open", "expected_revision": stale],
            origin: .external)
        XCTAssertThrowsError(
            try app.tools.execute(
                "archive_conversation",
                arguments: ["conversation_id": other.id.uuidString, "expected_revision": stale],
                origin: .external))
        _ = try app.tools.execute(
            "archive_conversation",
            arguments: ["conversation_id": other.id.uuidString, "expected_revision": app.tools.revision],
            origin: .external)
        XCTAssertEqual(app.library.conversations.first { $0.id == other.id }?.archived, true)
        XCTAssertEqual(app.selectedID, open)
        XCTAssertThrowsError(
            try app.tools.execute(
                "rename_conversation",
                arguments: [
                    "conversation_id": other.id.uuidString, "title": "Again", "expected_revision": app.tools.revision,
                ], origin: .external)
        ) { XCTAssertEqual(AppFailure.message(for: $0, fallback: ""), "An active conversation is required.") }
    }

    /// Pausing, resuming and finishing audio change no conversation, so a revision read before them still works.
    @MainActor func testPlaybackKeepsTheRevisionAndStopEndsOnlyPlayback() throws {
        let app = controlledApp()
        let id = try XCTUnwrap(app.selectedID).uuidString
        let player = TestPlayer()
        app.audio.makePlayer = { _ in player }
        app.play("fixture.wav")
        let revision = app.tools.revision
        for name in ["pause_audio", "resume_audio"] {
            _ = try app.tools.execute(
                name, arguments: ["conversation_id": id, "expected_revision": revision], origin: .external)
            XCTAssertEqual(app.tools.revision, revision, name)
        }
        app.deferredToolAction = { XCTFail("A view change scheduled after the stopped reply still ran") }
        _ = try app.tools.execute(
            "stop_audio", arguments: ["conversation_id": id, "expected_revision": revision], origin: .external)
        XCTAssertNil(app.playbackFile)
        XCTAssertEqual(app.turn.activity, .idle)
        XCTAssertNil(app.deferredToolAction)
        XCTAssertThrowsError(
            try app.tools.execute(
                "stop_audio", arguments: ["conversation_id": id, "expected_revision": app.tools.revision],
                origin: .external)
        ) { XCTAssertEqual(AppFailure.message(for: $0, fallback: ""), "No audio is playing.") }

        app.play("fixture.wav")
        let playing = app.tools.revision
        app.audio.finishPlayback(player, successfully: true)
        XCTAssertNil(app.playbackFile)
        XCTAssertEqual(app.tools.revision, playing)
    }

    @MainActor func testSearchAllExpressionsSpansConversationsNewestFirst() throws {
        let app = controlledApp()
        let open = try XCTUnwrap(app.selectedID)
        let elsewhere = UUID()
        func expression(_ text: String, in conversation: UUID, at time: TimeInterval) -> PracticeExpression {
            var item = PracticeExpression(conversationID: conversation, meaning: "", english: text, language: .english)
            item.date = Date(timeIntervalSince1970: time)
            return item
        }
        app.library.expressions = [
            expression("Good morning", in: open, at: 1), expression("Good night", in: elsewhere, at: 2),
            expression("Thanks", in: open, at: 3),
        ]
        let first = try app.tools.execute(
            "search_all_expressions", arguments: ["query": "good", "limit": 1], origin: .external)
        let newest = try XCTUnwrap((first["expressions"] as? [[String: Any]])?.first)
        XCTAssertEqual(newest["text"] as? String, "Good night")
        XCTAssertEqual(newest["conversation_id"] as? String, elsewhere.uuidString)
        XCTAssertEqual(first["next_offset"] as? Int, 1)
        let second = try app.tools.execute(
            "search_all_expressions", arguments: ["query": "good", "limit": 1, "offset": 1], origin: .external)
        XCTAssertEqual((second["expressions"] as? [[String: Any]])?.first?["text"] as? String, "Good morning")
        XCTAssertEqual(second["has_more"] as? Bool, false)
        let all = try app.tools.execute("search_all_expressions", arguments: [:], origin: .external)
        XCTAssertEqual((all["expressions"] as? [[String: Any]])?.count, 3)
        XCTAssertEqual(all["untrusted_fields"] as? [String], ["expressions.text", "expressions.meaning"])
    }

    /// The built helper, launched the way an MCP client launches it, reaches this app over the production socket.
    @MainActor func testBundledHelperServesStructuredResultsEndToEnd() async throws {
        let app = controlledApp()
        let helper = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("mochi-mcp")
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: helper.path), "Build the mochi-mcp product before testing")
        let id = try XCTUnwrap(app.selectedID).uuidString
        let save: [String: Any] = [
            "name": "save_expression",
            "arguments": ["conversation_id": id, "expected_revision": app.tools.revision, "text": "Let me think."],
        ]
        let misspelled: [String: Any] = [
            "name": "get_messages", "arguments": ["conversation_id": id, "limt": 1],
        ]
        let messages: [[String: Any]] = [
            [
                "jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": [
                    "protocolVersion": "2025-11-25", "capabilities": [:],
                    "clientInfo": ["name": "test", "version": "1"],
                ],
            ],
            ["jsonrpc": "2.0", "method": "notifications/initialized"],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/list"],
            ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": save],
            ["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": misspelled],
        ]
        let socket = app.controlSocketPath
        let replies = try await Task.detached { try Self.converse(helper: helper, socket: socket, messages) }.value
        XCTAssertEqual(replies.count, 4)
        let results = replies.map { $0["result"] as? [String: Any] ?? [:] }
        XCTAssertEqual(results[0]["protocolVersion"] as? String, "2025-11-25")
        XCTAssertEqual((results[1]["tools"] as? [Any])?.count, MochiTools.catalog(origin: .external).count)

        XCTAssertEqual(results[2]["isError"] as? Bool, false)
        let structured = try XCTUnwrap(results[2]["structuredContent"] as? [String: Any])
        let schema = try XCTUnwrap(MochiTools.catalog(origin: .external).first { $0.name == .saveExpression })
        XCTAssertEqual(Self.schemaProblems(structured, schema.outputSchema), [])
        let text = try XCTUnwrap(((results[2]["content"] as? [[String: Any]])?.first)?["text"] as? String)
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSDictionary, structured as NSDictionary)
        XCTAssertEqual(app.library.expressions.map(\.english), ["Let me think."])

        XCTAssertEqual(results[3]["isError"] as? Bool, true)
        XCTAssertNil(results[3]["structuredContent"])
        let refusal = ((results[3]["content"] as? [[String: Any]])?.first)?["text"] as? String ?? ""
        XCTAssertTrue(refusal.hasPrefix("Unexpected argument limt."), refusal)
    }

    /// Sends `messages` to a helper process and returns its replies to those with an ID, in order.
    /// The helper is killed after ten seconds, so a hung exchange fails instead of stalling the run.
    private nonisolated static func converse(
        helper: URL, socket: String, _ messages: [[String: Any]]
    ) throws -> [[String: Any]] {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = helper
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        process.environment = ["MOCHI_CONTROL_SOCKET": socket]
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { if process.isRunning { process.terminate() } }
        var buffer = Data()
        var replies: [[String: Any]] = []
        for message in messages {
            try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: message) + [10])
            guard message["id"] != nil else { continue }
            while !buffer.contains(10) {
                let chunk = output.fileHandleForReading.availableData
                guard !chunk.isEmpty else { throw AppFailure("The helper ended before answering.") }
                buffer.append(chunk)
            }
            let end = buffer.firstIndex(of: 10)!
            let line = buffer[buffer.startIndex..<end]
            buffer = Data(buffer[buffer.index(after: end)...])
            replies.append(try XCTUnwrap(try JSONSerialization.jsonObject(with: line) as? [String: Any]))
        }
        return replies
    }

    @MainActor private func controlledApp() -> AppModel {
        let app = makeApp(root: makeTemporaryFolder("mochi-external-tools"), preferences: makePreferences())
        app.externalControlEnabled = true
        addTeardownBlock { @MainActor in
            app.externalControlEnabled = false
            app.stop()
        }
        return app
    }

    /// Where `value` departs from `schema`, using the JSON Schema subset the output schemas use: `type` (one or a
    /// list), `const`, `enum`, `properties`, `required` and `items`. Stricter than JSON Schema in one way: an object
    /// field its schema does not declare is a problem, so the schema documents every field a client can receive.
    static func schemaProblems(_ value: Any, _ schema: [String: Any], at path: String = "result") -> [String] {
        let types = schema["type"] as? [String] ?? (schema["type"] as? String).map { [$0] } ?? []
        guard types.isEmpty || types.contains(where: { matches(value, $0) }) else {
            return ["\(path) is not \(types.joined(separator: " or "))"]
        }
        var problems: [String] = []
        if let expected = schema["const"] as? Bool, (value as? NSNumber)?.boolValue != expected {
            problems.append("\(path) is not \(expected)")
        }
        if let options = schema["enum"] as? [String], !options.contains(value as? String ?? "") {
            problems.append("\(path) is not one of \(options)")
        }
        if let object = value as? [String: Any], let properties = schema["properties"] as? [String: [String: Any]] {
            for key in schema["required"] as? [String] ?? [] where object[key] == nil {
                problems.append("\(path).\(key) is missing")
            }
            for (key, field) in object.sorted(by: { $0.key < $1.key }) {
                guard let fieldSchema = properties[key] else {
                    problems.append("\(path).\(key) is not declared")
                    continue
                }
                problems += schemaProblems(field, fieldSchema, at: "\(path).\(key)")
            }
        }
        if let items = value as? [Any], let itemSchema = schema["items"] as? [String: Any] {
            for (index, item) in items.enumerated() {
                problems += schemaProblems(item, itemSchema, at: "\(path)[\(index)]")
            }
        }
        return problems
    }
    private static func matches(_ value: Any, _ type: String) -> Bool {
        let number = value as? NSNumber
        let isBoolean = number.map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
        switch type {
        case "null": return value is NSNull
        case "boolean": return isBoolean
        case "number": return number != nil && !isBoolean
        case "integer": return number != nil && !isBoolean && number!.doubleValue.rounded() == number!.doubleValue
        case "string": return value is String
        case "array": return value is [Any]
        case "object": return value is [String: Any]
        default: return false
        }
    }
}
