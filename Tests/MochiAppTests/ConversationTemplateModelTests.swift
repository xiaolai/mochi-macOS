import XCTest
import MochiCore
@testable import MochiApp

final class ConversationTemplateModelTests: XCTestCase {
    @MainActor func testMCPIndependentCatalogAndImmutableSnapshots() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let app = AppModel(libraryRoot:root,preferences:UserDefaults(suiteName:UUID().uuidString)!)
        app.externalControlEnabled = true; app.selectedID = nil
        _ = app.turn.begin(.generating); app.error = "Keep provider error"; app.notice = "Keep notice"
        let created = try app.executeTool("create_conversation_template",arguments:["title":"Loki","character_name":"Loki"],origin:.external)
        let t = try XCTUnwrap(created["template"] as? [String:Any])
        let id = try XCTUnwrap(t["id"] as? String), rev = try XCTUnwrap(t["template_revision"] as? String)
        XCTAssertEqual(app.error,"Keep provider error"); XCTAssertEqual(app.notice,"Keep notice")
        XCTAssertEqual(app.turn.activity,.generating)
        let updated = try app.executeTool("update_conversation_template",arguments:["template_id":id,"expected_template_revision":rev,"instructions":"Discuss books"],origin:.external)
        XCTAssertThrowsError(try app.executeTool("delete_conversation_template",arguments:["template_id":id,"expected_template_revision":rev],origin:.external))
        let newRev = (updated["template"] as! [String:Any])["template_revision"] as! String
        _ = app.turn.finish(app.turn.epoch)
        let chat = try app.executeTool("create_conversation",arguments:["template_id":id,"expected_revision":app.controlRevision],origin:.external)
        XCTAssertNotNil(chat["conversation_id"]); XCTAssertEqual(app.conversation?.characterName,"Loki")
        _ = try app.executeTool("delete_conversation_template",arguments:["template_id":id,"expected_template_revision":newRev],origin:.external)
        XCTAssertEqual(app.conversation?.instructions,"Discuss books")
        XCTAssertTrue(app.library.conversationTemplates.isEmpty)
    }
    @MainActor func testNameOnlyMutationPreservesOversizedInstructionsAndNoOpRevision() throws {
        let app = AppModel(demo:true); app.resume(); app.externalControlEnabled = true
        let id = try XCTUnwrap(app.selectedID), index = try XCTUnwrap(app.library.conversations.firstIndex(where:{ $0.id == id }))
        app.library.conversations[index].instructions = String(repeating:"x",count:9000)
        _ = try app.executeTool("set_conversation_instructions",arguments:["conversation_id":id.uuidString,"expected_revision":app.controlRevision,"character_name":"Loki"],origin:.external)
        XCTAssertEqual(app.conversation?.instructions.count,9000)
        XCTAssertEqual(app.conversation?.characterName,"Loki")
        let t = try app.createTemplate(fields:["title":"Recall","instructions":"Ask me words"])
        let unchanged = try app.updateTemplate(id:t.id,revision:t.revision,fields:["instructions":"Ask me words"])
        XCTAssertEqual(unchanged.revision,t.revision)
    }
    @MainActor func testFailedTemplateSavePreservesConversationAndDraft() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let app = AppModel(libraryRoot:root,preferences:UserDefaults(suiteName:UUID().uuidString)!)
        app.error = "Existing error"; let before = app.selectedID
        try Data("broken".utf8).write(to:app.store.file)
        XCTAssertThrowsError(try app.createTemplate(fields:["title":"Loki","character_name":"Loki"]))
        XCTAssertTrue(app.library.conversationTemplates.isEmpty)
        XCTAssertEqual(app.error,"Existing error"); XCTAssertEqual(app.selectedID,before)
    }
}

extension ConversationTemplateModelTests {
    @MainActor func testCatalogPagingAndOpenPickerMutation() throws {
        let app = AppModel(demo:true); app.resume(); app.externalControlEnabled = true; app.openTemplatePicker()
        app.library.conversationTemplates = (0..<120).map { ConversationTemplate(title:String(format:"T%03d",$0),instructions:"Discuss topics") }
        var ids: Set<String> = [], offset = 0
        let revision = app.templateCatalogRevision
        repeat {
            let page = try app.executeTool("list_conversation_templates",arguments:["limit":20,"offset":offset,"expected_catalog_revision":revision],origin:.external)
            let items = page["templates"] as! [[String:Any]]
            for item in items { XCTAssertTrue(ids.insert(item["id"] as! String).inserted) }
            if let next = page["next_offset"] as? Int { XCTAssertGreaterThan(next,offset); offset = next } else { break }
        } while true
        XCTAssertEqual(ids.count,126)
        _ = try app.executeTool("create_conversation_template",arguments:["title":"New","character_name":"Loki"],origin:.external)
        XCTAssertEqual(app.templatePresentation,.picker)
        XCTAssertThrowsError(try app.executeTool("list_conversation_templates",arguments:["expected_catalog_revision":revision],origin:.external))
        XCTAssertThrowsError(try app.executeTool("create_conversation",arguments:["expected_revision":app.controlRevision],origin:.external))
    }
    @MainActor func testPreviewSurvivesSourceDeletionAndSaveAsPreservesNilDraft() throws {
        let app = AppModel(demo:true); app.resume()
        let source = try app.createTemplate(fields:["title":"Scenario","instructions":"Your name is Sam"])
        app.openTemplatePicker()
        let snapshot = source
        try app.deleteTemplate(id:source.id,revision:source.revision)
        let id = try app.startTemplateSnapshot(snapshot)
        XCTAssertEqual(app.selectedID,id); XCTAssertNil(app.conversation?.characterName)
        XCTAssertEqual(app.conversation?.sourceTemplateID,source.id)
        app.instructionsID = id
        app.saveConversationAsTemplate(id,draft:ConversationSettingsDraft(id:id,instructions:"Unsaved",characterName:nil,preferences:ConversationPreferences()))
        XCTAssertEqual(app.templateDraft?.value.instructions,"Unsaved"); XCTAssertNil(app.templateDraft?.value.characterName)
        app.closeTemplateEditor(); XCTAssertEqual(app.retainedInstructionsDraft?.instructions,"Unsaved"); XCTAssertEqual(app.instructionsID,id)
    }
    @MainActor func testReplyUsesCapturedSpeakerAndIdentity() async throws {
        let app = AppModel(demo:true), gate = TestGate(); app.resume()
        let id = try XCTUnwrap(app.selectedID)
        XCTAssertTrue(app.setConversationInstructions(id,instructions:"Discuss books",preferences:ConversationPreferences(),characterName:"Loki"))
        var started = false
        app.conversationReply = { request, callbacks in
            XCTAssertEqual(request.characterName,"Loki"); started = true
            await gate.wait()
            var reply = RealtimeAccumulator(); reply.text = "Hello"
            try callbacks.response(reply)
        }
        app.draft = "Hi"; app.send()
        for _ in 0..<100 { if started { break }; await Task.yield() }
        XCTAssertTrue(started)
        let index = try XCTUnwrap(app.library.conversations.firstIndex(where:{ $0.id == id }))
        app.library.conversations[index].characterName = "Sam"
        await gate.release()
        for _ in 0..<100 { if app.conversation?.messages.last?.role == "assistant" { break }; await Task.yield() }
        XCTAssertEqual(app.conversation?.messages.last?.speakerName,"Loki")
        app.stop()
    }
    @MainActor func testTemplateCapAndBuiltInMutationAndNoNetworkOnStart() throws {
        let app = AppModel(demo:true); app.resume()
        app.library.conversationTemplates = (0..<200).map { ConversationTemplate(title:"T\($0)",instructions:"Discuss") }
        XCTAssertThrowsError(try app.createTemplate(fields:["title":"More","character_name":"Loki"]))
        let builtin = ConversationTemplate.builtins[0]
        XCTAssertThrowsError(try app.updateTemplate(id:builtin.id,revision:builtin.revision,fields:["title":"Overwrite"]))
        XCTAssertThrowsError(try app.deleteTemplate(id:builtin.id,revision:builtin.revision))
        app.conversationReply = { _,_ in XCTFail("Starting a template must not send a request") }
        app.microphonePermission = { XCTFail("Starting a template must not request microphone"); return false }
        let before = app.library.conversations.count
        _ = try app.startTemplateSnapshot(builtin)
        XCTAssertEqual(app.library.conversations.count,before+1); XCTAssertTrue(app.conversation!.messages.isEmpty)
    }
}

// Audit regressions (2026-10-10).
extension ConversationTemplateModelTests {
    @MainActor func testEditorTrimsCharacterName() throws {
        let app = AppModel(demo:true); app.resume()
        let id = try XCTUnwrap(app.selectedID)
        XCTAssertTrue(app.setConversationInstructions(id,instructions:"",preferences:ConversationPreferences(),characterName:"  Loki \n"))
        XCTAssertEqual(app.conversation?.characterName,"Loki")
        XCTAssertFalse(app.setConversationInstructions(id,instructions:"",preferences:ConversationPreferences(),characterName:"   "))
        XCTAssertEqual(app.conversation?.characterName,"Loki")
    }
    @MainActor func testPickerPreviewEditsSurviveDuplicateCancel() {
        let app = AppModel(demo:true); app.resume(); app.openTemplatePicker()
        var preview = ConversationTemplate.builtins[1]; preview.instructions = "Customized before duplicating"
        app.templateDraft = TemplateEditorDraft(value:preview,editingID:nil,expectedRevision:preview.revision)
        app.editTemplate(preview,duplicate:true)
        XCTAssertEqual(app.templatePresentation,.editor)
        app.closeTemplateEditor()
        XCTAssertEqual(app.templatePresentation,.picker)
        XCTAssertEqual(app.templateDraft?.value.instructions,"Customized before duplicating")
        app.templatePresentation = nil; app.templateDraft = nil
        app.openTemplateManager(); app.editTemplate(nil); app.closeTemplateEditor()
        XCTAssertEqual(app.templatePresentation,.manager); XCTAssertNil(app.templateDraft)
    }
    @MainActor func testTemplateCreationNeverReusesPristineChatButBlankCreationDoes() throws {
        let app = AppModel(demo:true); app.resume(); app.externalControlEnabled = true
        app.newChat()
        let pristine = try XCTUnwrap(app.selectedID)
        XCTAssertTrue(app.conversation?.isPristine == true)
        let index = try XCTUnwrap(app.library.conversations.firstIndex(where:{ $0.id == pristine })); app.library.conversations[index].pinned = true
        let builtin = ConversationTemplate.builtins[3]
        let created = try app.executeTool("create_conversation",arguments:["template_id":builtin.id.uuidString,"expected_revision":app.controlRevision],origin:.external)
        XCTAssertNotEqual(created["conversation_id"] as? String,pristine.uuidString)
        XCTAssertTrue(app.library.conversations.first { $0.id == pristine }?.isPristine == true)
        XCTAssertEqual(app.conversation?.sourceTemplateID,builtin.id); XCTAssertEqual(app.conversation?.characterName,"Mochi")
        _ = try app.executeTool("open_conversation",arguments:["conversation_id":pristine.uuidString,"expected_revision":app.controlRevision],origin:.external)
        let blank = try app.executeTool("create_conversation",arguments:["character_name":"Loki","coaching":"direct","speed":0.8,"expected_revision":app.controlRevision],origin:.external)
        XCTAssertEqual(blank["conversation_id"] as? String,pristine.uuidString)
        let reused = try XCTUnwrap(app.conversation)
        XCTAssertTrue(reused.pinned); XCTAssertEqual(reused.characterName,"Loki")
        XCTAssertEqual(reused.preferences.coaching,.direct); XCTAssertEqual(reused.preferences.speed,0.8)
    }
}

extension ConversationTemplateModelTests {
    @MainActor func testUIStaleDraftAndSessionMetadataAndOverrideRecovery() throws {
        let app = AppModel(demo:true); app.resume(); app.externalControlEnabled = true
        let original = try app.createTemplate(fields:["title":"Loki","character_name":"Loki"])
        app.openTemplateManager(); app.editTemplate(original)
        app.templateDraft?.value.instructions = "Unsaved editor changes"
        _ = try app.updateTemplate(id:original.id,revision:original.revision,fields:["instructions":"Concurrent update"])
        XCTAssertThrowsError(try app.updateTemplate(id:original.id,revision:app.templateDraft!.expectedRevision!,fields:["instructions":app.templateDraft!.value.instructions]))
        XCTAssertEqual(app.templateDraft?.value.instructions,"Unsaved editor changes")
        app.templatePresentation = nil; app.templateDraft = nil
        let i = app.library.conversationTemplates.firstIndex(where:{ $0.id == original.id })!
        app.library.conversationTemplates[i].instructions = String(repeating:"x",count:9000)
        _ = try app.executeTool("create_conversation",arguments:["template_id":original.id.uuidString,"expected_revision":app.controlRevision,"instructions":"Corrected for this conversation"],origin:.external)
        let session = try app.executeTool("get_session",arguments:[:],origin:.external)
        XCTAssertEqual(session["character_name"] as? String,"Loki"); XCTAssertEqual(session["display_character_name"] as? String,"Loki")
        XCTAssertEqual(session["source_template_id"] as? String,original.id.uuidString)
        XCTAssertEqual(session["source_template_revision"] as? String,app.library.conversationTemplates[i].revision)
        XCTAssertEqual(app.library.conversationTemplates[i].instructions.count,9000)
    }
    @MainActor func testNameOnlyUIEditPreservesOversizedTextAndOmittedName() throws {
        let app = AppModel(demo:true); app.resume()
        let id = try XCTUnwrap(app.selectedID), i = app.library.conversations.firstIndex(where:{ $0.id == id })!
        let text = "  " + String(repeating:"x",count:9000) + "  "
        app.library.conversations[i].instructions = text
        XCTAssertTrue(app.setConversationInstructions(id,instructions:text,preferences:ConversationPreferences(),characterName:"Loki"))
        XCTAssertEqual(app.conversation?.instructions,text)
        XCTAssertTrue(app.setConversationInstructions(id,instructions:"New small instructions",preferences:ConversationPreferences()))
        XCTAssertEqual(app.conversation?.characterName,"Loki")
    }
    @MainActor func testOversizedMetadataPagesStayBoundedAndProgress() throws {
        let app = AppModel(demo:true); app.resume(); app.externalControlEnabled = true
        app.library.conversationTemplates = (0..<80).map { _ in
            var t = ConversationTemplate(title:String(repeating:"\u{0001}",count:160),description:String(repeating:"\u{0001}",count:500),characterName:String(repeating:"\u{0001}",count:80),instructions:"Discuss")
            t.description += String(repeating:"z",count:10000)
            return t
        }
        var offset = 0, seen = 0
        repeat {
            let page = try app.executeTool("list_conversation_templates",arguments:["origin":"user","limit":100,"offset":offset],origin:.external)
            XCTAssertLessThan(try JSONSerialization.data(withJSONObject:page).count,110000)
            seen += (page["templates"] as! [[String:Any]]).count
            if let next = page["next_offset"] as? Int { XCTAssertGreaterThan(next,offset); offset = next } else { break }
        } while true
        XCTAssertEqual(seen,80)
    }
    @MainActor func testInvalidRecoveredNameIsFlaggedWithoutSendingOrLosingDraft() throws {
        let app = AppModel(demo:true); app.resume(); app.externalControlEnabled = true
        let id = try XCTUnwrap(app.selectedID), i = app.library.conversations.firstIndex(where:{ $0.id == id })!
        app.library.conversations[i].characterName = "\nInvalid"
        app.conversationReply = { _,_ in XCTFail("Must not send invalid identity") }
        app.draft = "Keep this"; app.send()
        XCTAssertEqual(app.draft,"Keep this"); XCTAssertNotNil(app.error)
        XCTAssertTrue(app.conversation!.characterNameNeedsReview)
        let session = try app.executeTool("get_session",arguments:[:],origin:.external)
        XCTAssertEqual(session["character_name_needs_review"] as? Bool,true)
        XCTAssertEqual(session["display_character_name"] as? String,"Companion")
        XCTAssertTrue(app.setConversationInstructions(id,instructions:app.conversation!.instructions,preferences:ConversationPreferences(),characterName:"Loki"))
        XCTAssertFalse(app.conversation!.characterNameNeedsReview)
    }
}

// Follow-up audit regressions (2026-10-10).
extension ConversationTemplateModelTests {
    @MainActor func testRetryRejectsNameNeedingReviewBeforeProvider() throws {
        let app = AppModel(demo:true); app.resume()
        let id = try XCTUnwrap(app.selectedID), index = try XCTUnwrap(app.library.conversations.firstIndex(where:{ $0.id == id }))
        app.library.conversations[index].messages = [Message(role:"user",text:"Hello")]
        app.library.conversations[index].characterName = "Bad\nName"
        app.conversationReply = { _,_ in XCTFail("A name needing review must not reach the provider") }
        XCTAssertTrue(app.canRetry)
        app.retryReply()
        XCTAssertEqual(app.turn.activity,.idle); XCTAssertNotNil(app.error)
        XCTAssertEqual(app.conversation?.messages.count,1)
    }
    @MainActor func testPickerValidatesCopiedSettingsWhileEditorRequiresWritableTemplate() {
        let app = AppModel(demo:true); app.resume(); app.openTemplatePicker()
        var recovered = ConversationTemplate(title:"Recovered",instructions:"Discuss books")
        recovered.description = String(repeating:"d",count:600)
        app.templateDraft = TemplateEditorDraft(value:recovered,editingID:nil,expectedRevision:recovered.revision)
        XCTAssertNil(app.templateDraftIssue, "Catalog-only metadata must not block starting from copied settings")
        app.templateDraft?.value.instructions = String(repeating:"x",count:9000)
        XCTAssertNotNil(app.templateDraftIssue)
        app.templateDraft?.value.instructions = "Discuss books"
        app.templatePresentation = .manager
        XCTAssertNotNil(app.templateDraftIssue, "Manager/editor explain why a recovery template needs review")
    }
}
