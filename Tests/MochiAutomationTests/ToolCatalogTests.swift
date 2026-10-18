import MochiKernel
import XCTest

@testable import MochiAutomation

final class ToolCatalogTests: XCTestCase {
    func testEveryToolIsDeclaredOnceWithConsistentRouting() {
        let external = MochiTools.catalog(origin: .external)
        let voice = MochiTools.catalog(origin: .voice)
        XCTAssertEqual(external.map(\.name), MochiToolName.allCases)
        XCTAssertEqual(
            Set(voice.map(\.name)),
            [
                .getSession, .getMessages, .prepareExpression, .startPractice, .saveExpression, .searchExpressions,
                .playAudio, .seekAudio, .setConversationPreferences,
            ])
        for tool in external {
            XCTAssertEqual(
                tool.properties["conversation_id"] != nil, tool.scope == .conversation || tool.scope == .history,
                tool.name.rawValue)
            XCTAssertEqual(
                tool.properties["expected_revision"] != nil, !tool.readOnly && tool.scope != .catalog,
                tool.name.rawValue)
            XCTAssertEqual(
                tool.scope == .catalog,
                tool.name.rawValue.hasSuffix("_conversation_template") || tool.name == .listConversationTemplates
                    || tool.name == .listCharacters,
                tool.name.rawValue)
            if tool.readOnly {
                XCTAssertTrue(tool.idempotent, tool.name.rawValue)
                XCTAssertFalse(tool.destructive, tool.name.rawValue)
            }
        }
        XCTAssertEqual(
            Set(external.filter(\.deferredDuringVoiceReply).map(\.name)),
            [.prepareExpression, .startPractice, .playAudio, .seekAudio])
        XCTAssertEqual(
            Set(external.filter(\.destructive).map(\.name)),
            [
                .setConversationInstructions, .setConversationPreferences, .renameConversation, .archiveConversation,
                .updateConversationTemplate, .deleteConversationTemplate,
            ])
        XCTAssertEqual(
            Set(external.filter { $0.scope == .history }.map(\.name)),
            [.openConversation, .renameConversation, .archiveConversation])
    }

    /// Clients show titles; models choose arguments from descriptions and read results through the output schema.
    func testEveryToolDocumentsItselfForClientsAndModels() throws {
        for origin in [ToolOrigin.voice, .external] {
            for tool in MochiTools.catalog(origin: origin) {
                XCTAssertFalse(tool.title.isEmpty, tool.name.rawValue)
                for (key, property) in tool.properties {
                    XCTAssertFalse(
                        (property["description"] as? String ?? "").isEmpty,
                        "\(tool.name.rawValue).\(key) is undescribed")
                }
            }
        }
        for tool in MochiTools.catalog(origin: .external) {
            let mcp = tool.mcp
            XCTAssertEqual(mcp["title"] as? String, tool.title)
            let output = try XCTUnwrap(mcp["outputSchema"] as? [String: Any], tool.name.rawValue)
            XCTAssertEqual(output["type"] as? String, "object")
            XCTAssertEqual(output["required"] as? [String], ["ok", "revision"])
            let fields = try XCTUnwrap(output["properties"] as? [String: [String: Any]])
            XCTAssertEqual(fields["ok"]?["const"] as? Bool, true)
            // A tool's own field never redefines one every result shares.
            XCTAssertTrue(Set(tool.output.keys).isDisjoint(with: ["ok", "revision", "untrusted_fields"]))
        }
    }

    /// A client told only "completed" would retry a request that is still waiting for Mochi's reply.
    func testToolsThatWaitForAReplySayHowToTellAndWhatToReadBeforeRetrying() throws {
        for name in [MochiToolName.prepareExpression, .startPractice, .playAudio] {
            let tool = try XCTUnwrap(MochiTools.catalog(origin: .external).first { $0.name == name })
            XCTAssertTrue(tool.description.contains("scheduled_after_reply"), name.rawValue)
            XCTAssertTrue(tool.description.contains("get_session"), name.rawValue)
            XCTAssertTrue(tool.description.contains("Stop cancels it"), name.rawValue)
            // An external call made while a reply is still being produced is refused, not scheduled.
            XCTAssertFalse(tool.description.contains("about to speak"), name.rawValue)
            XCTAssertTrue(tool.description.contains("refused as busy"), name.rawValue)
        }
    }

    /// A model can only correct a call it was told the problem with.
    func testArgumentErrorsNameTheArgument() {
        func message(_ name: String, _ arguments: [String: Any]) -> String {
            do {
                _ = try MochiTools.validate(name: name, arguments: arguments, origin: .external)
                return ""
            } catch { return AppFailure.message(for: error, fallback: "") }
        }
        let id = UUID().uuidString
        XCTAssertEqual(
            message("get_session", ["verbose": true]), "Unexpected argument verbose. This tool takes no arguments.")
        let misspelled = message("get_messages", ["conversation_id": id, "limt": 5])
        XCTAssertTrue(misspelled.hasPrefix("Unexpected argument limt."), misspelled)
        XCTAssertTrue(misspelled.contains("conversation_id, limit"), misspelled)
        XCTAssertEqual(
            message("save_expression", ["conversation_id": id, "expected_revision": "r"]),
            "Missing required argument: text.")
        XCTAssertEqual(
            message("save_expression", ["conversation_id": id, "expected_revision": "r", "english": "Hi"]),
            "Unexpected argument english. Allowed arguments: conversation_id, expected_revision, meaning, text.")
        XCTAssertEqual(
            message("rename_conversation", ["conversation_id": id, "expected_revision": "r", "title": "  "]),
            "A conversation title is required.")
    }

    func testTypedArgumentsFailAsErrorsNotCrashes() {
        XCTAssertThrowsError(try MochiTools.decode(ConversationSettingsArguments.self, from: ["coaching": "shouting"]))
        { error in
            XCTAssertTrue(error is AppFailure)
        }
        XCTAssertThrowsError(try MochiTools.decode(ExpressionArguments.self, from: [:]))
        let audio = try? MochiTools.decode(
            AudioArguments.self, from: ["message_id": UUID().uuidString, "seconds": 2.5])
        XCTAssertEqual(audio?.seconds, 2.5)
        XCTAssertNotNil(audio?.messageID)
    }

    func testCatalogValidatesArgumentsAndRestrictsVoiceTools() throws {
        XCTAssertFalse(MochiTools.catalog(origin: .voice).contains { $0.name == .setConversationInstructions })
        XCTAssertTrue(MochiTools.catalog(origin: .external).contains { $0.name == .setConversationInstructions })
        XCTAssertThrowsError(try MochiTools.validate(name: "delete_message", arguments: [:], origin: .external))
        XCTAssertThrowsError(
            try MochiTools.validate(name: "get_messages", arguments: ["conversation_id": "bad"], origin: .external))
        XCTAssertThrowsError(
            try MochiTools.validate(name: "search_expressions", arguments: ["query": "", "limit": 101], origin: .voice))
    }

    func testNumericBoundsBooleansAndInstructionLimits() throws {
        let id = UUID().uuidString
        XCTAssertThrowsError(
            try MochiTools.validate(
                name: "get_messages", arguments: ["conversation_id": id, "limit": 0], origin: .voice))
        XCTAssertThrowsError(
            try MochiTools.validate(
                name: "get_messages", arguments: ["conversation_id": id, "limit": true], origin: .voice))
        XCTAssertThrowsError(
            try MochiTools.validate(
                name: "get_messages", arguments: ["conversation_id": id, "limit": 1.5], origin: .voice))
        _ = try MochiTools.validate(
            name: "seek_audio", arguments: ["conversation_id": id, "message_id": id, "seconds": 3600], origin: .voice)
        XCTAssertThrowsError(
            try MochiTools.validate(
                name: "seek_audio", arguments: ["conversation_id": id, "message_id": id, "seconds": 3601],
                origin: .voice))
        XCTAssertThrowsError(try ConversationInstructions.validate(String(repeating: "x", count: 8001)))
        XCTAssertThrowsError(
            try MochiTools.validate(
                name: "play_audio", arguments: ["conversation_id": id, "message_id": id, "expression_id": id],
                origin: .voice))
    }

    func testSchemaLimitsAndRulesStillApplyAfterSplittingValidation() {
        XCTAssertThrowsError(
            try MochiTools.validate(
                name: "save_expression",
                arguments: [
                    "conversation_id": UUID().uuidString,
                    "text": String(repeating: "a", count: ExpressionText.maxCharacters + 1),
                ], origin: .voice))
        XCTAssertThrowsError(
            try MochiTools.validate(
                name: "save_expression", arguments: ["conversation_id": UUID().uuidString, "text": "  "],
                origin: .voice))
        XCTAssertNoThrow(
            try MochiTools.validate(
                name: "save_expression",
                arguments: [
                    "conversation_id": UUID().uuidString,
                    "text": String(repeating: "a", count: ExpressionText.maxCharacters),
                ],
                origin: .voice))
        let advertised = MochiTools.catalog(origin: .external).first { $0.name == .saveExpression }
        XCTAssertEqual(advertised?.properties["text"]?["maxLength"] as? Int, ExpressionText.maxCharacters)
        XCTAssertEqual(
            advertised?.properties["expected_revision"]?["maxLength"] as? Int, ConversationInstructions.maxCharacters)
    }

    func testPauseResumeAreExternalOnly() throws {
        for name in ["pause_audio", "resume_audio"] {
            XCTAssertFalse(MochiTools.catalog(origin: .voice).contains { $0.name.rawValue == name })
            XCTAssertTrue(MochiTools.catalog(origin: .external).contains { $0.name.rawValue == name })
            XCTAssertThrowsError(
                try MochiTools.validate(name: name, arguments: ["conversation_id": UUID().uuidString], origin: .voice))
        }
    }

    func testToolBooleanOriginAndRevisionSchemas() throws {
        for bad: Any in [1, "true", NSNull()] {
            XCTAssertThrowsError(
                try MochiTools.validate(
                    name: "update_conversation_template",
                    arguments: [
                        "template_id": UUID().uuidString, "expected_template_revision": "r", "clear_speed": bad,
                    ], origin: .external))
        }
        let tool = try MochiTools.validate(
            name: "create_conversation_template", arguments: ["title": "Loki", "character_name": "Loki"],
            origin: .external)
        XCTAssertFalse(tool.required.contains("expected_revision"))
        XCTAssertThrowsError(
            try MochiTools.validate(
                name: "create_conversation_template", arguments: ["title": "Loki", "character_name": "Loki"],
                origin: .voice))
        _ = try MochiTools.validate(name: "list_conversation_templates", arguments: ["offset": 200], origin: .external)
        XCTAssertThrowsError(
            try MochiTools.validate(
                name: "update_conversation_template",
                arguments: [
                    "template_id": UUID().uuidString, "expected_template_revision": "r", "clear_speed": true,
                    "speed": 1,
                ], origin: .external))
    }

    func testTemplateMCPAnnotationsAndDiscoveryInstructions() throws {
        let tools = MochiTools.catalog(origin: .external)
        for name in ["update_conversation_template", "delete_conversation_template"] {
            let value = try XCTUnwrap(tools.first(where: { $0.name.rawValue == name }))
            let a = value.mcp["annotations"] as! [String: Any]
            XCTAssertEqual(a["destructiveHint"] as? Bool, true)
            XCTAssertEqual(a["idempotentHint"] as? Bool, false)
        }
        for name in ["list_conversation_templates", "get_conversation_template"] {
            let a = tools.first(where: { $0.name.rawValue == name })!.mcp["annotations"] as! [String: Any]
            XCTAssertEqual(a["readOnlyHint"] as? Bool, true)
        }
    }
}
