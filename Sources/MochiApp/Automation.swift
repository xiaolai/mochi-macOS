import Foundation
import MochiCore

extension AppModel {
    var controlSocketPath: String { LocalControl.path(forLibraryRoot:store.root) }
    var mcpExecutablePath: String {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/mochi-mcp").path
        if FileManager.default.isExecutableFile(atPath:bundled) { return bundled }
        return URL(fileURLWithPath:CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent().appendingPathComponent("mochi-mcp").path
    }
    var mcpConfigurationAvailable: Bool { FileManager.default.isExecutableFile(atPath:mcpExecutablePath) && !Bundle.main.bundleURL.path.contains("/AppTranslocation/") }
    var mcpConfiguration: String { (try? MochiTools.encode(["mcpServers":["mochi":["command":mcpExecutablePath,"env":["MOCHI_CONTROL_SOCKET":controlSocketPath]]]])) ?? "" }
    func configureAutomation() {
        InstanceEvidence.record("automation-configured")
        guard externalControlEnabled && (!demo || allowDemoAutomation) else {
            controlHealthTask?.cancel(); controlHealthTask = nil
            controlServer?.stop(); controlServer = nil; toolResultCache = [:]; toolResultOrder = []; automationStatus = "Disabled"; return
        }
        if controlHealthTask == nil {
            controlHealthTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds:30_000_000_000) } catch { return }
                    guard let self, self.externalControlEnabled else { return }
                    self.configureAutomation()
                }
            }
        }
        if let server = controlServer {
            if server.endpointAvailable { return }
            server.stop(); controlServer = nil
        }
        let server = LocalControlServer()
        do {
            try server.start(path:controlSocketPath) { [weak self] data in
                guard let self else { return Data() }
                return self.handleControlRequest(data)
            }
            controlServer = server; automationStatus = "Available locally"
        } catch { automationStatus = (error as? AppFailure)?.message ?? "Could not start external control." }
    }
    func cacheVoiceTool(_ key: String, result: [String:Any]) {
        if voiceToolResults[key] == nil { voiceToolOrder.append(key) }
        voiceToolResults[key] = result
        if voiceToolOrder.count > 128 { voiceToolResults.removeValue(forKey:voiceToolOrder.removeFirst()) }
    }
    func executeVoiceTool(_ name: String, arguments: [String:Any], operationID: UUID) throws -> [String:Any] {
        let tool = try MochiTools.validate(name:name,arguments:arguments,origin:.voice)
        if tool.readOnly { return try executeTool(name,arguments:arguments,origin:.voice) }
        let key = operationID.uuidString + ":" + (try MochiTools.signature(name:name,arguments:arguments))
        if var result = voiceToolResults[key] { result["status"] = "previously_completed"; result["revision"] = controlRevision; return result }
        voiceToolKey = key; defer { voiceToolKey = nil }
        let result = try executeTool(name,arguments:arguments,origin:.voice)
        if result["status"] as? String != "scheduled_after_reply" { cacheVoiceTool(key,result:result) }
        return result
    }
    func handleControlRequest(_ data: Data) -> Data {
        var result: [String:Any]
        do {
            guard externalControlEnabled else { throw AppFailure("External control is disabled.") }
            guard data.count <= LocalControl.maxFrame,
                  let object = try JSONSerialization.jsonObject(with:data) as? [String:Any],
                  let name = object["name"] as? String, let arguments = object["arguments"] as? [String:Any],
                  let requestID = object["request_id"] as? String, !requestID.isEmpty, requestID.count <= 300 else { throw AppFailure("Invalid control request.") }
            let signature = try MochiTools.encode(["name":name,"arguments":arguments])
            if let cached = toolResultCache[requestID] {
                guard cached.0 == signature else { throw AppFailure("A request ID was reused with different arguments.") }
                return cached.1
            }
            do { result = try executeTool(name,arguments:arguments,origin:.external) }
            catch { result = MochiTools.error((error as? AppFailure)?.message ?? "The app action failed.") }
            var response = try JSONSerialization.data(withJSONObject:result)
            if response.count > 120000 { response = try JSONSerialization.data(withJSONObject:MochiTools.error("Result is too large. Request fewer items.")) }
            toolResultCache[requestID] = (signature,response); toolResultOrder.append(requestID)
            if toolResultOrder.count > 128 { toolResultCache.removeValue(forKey:toolResultOrder.removeFirst()) }
            return response
        } catch { result = MochiTools.error((error as? AppFailure)?.message ?? "Invalid control request.") }
        return (try? JSONSerialization.data(withJSONObject:result)) ?? Data()
    }

    var controlRevision: String {
        [libraryRevision.uuidString,selectedID?.uuidString ?? "none",turn.epoch.uuidString,
         String(practice),String(managerOpen),
         instructionsID?.uuidString ?? "none",renameID?.uuidString ?? "none",String(permanentDeleteIDs.count),String(audio.paused),playbackFile ?? "none"].joined(separator:":")
    }
    var automationModal: Bool { practice || managerOpen || instructionsID != nil || renameID != nil || !permanentDeleteIDs.isEmpty }
    var canOpenConversationInstructions: Bool { !busy && !automationModal }
    func openConversationInstructions(_ id: UUID) {
        guard canOpenConversationInstructions, library.conversations.contains(where:{ $0.id == id && !$0.archived && !$0.isDeleted }) else { return }
        instructionsID = id
    }
    @discardableResult func setConversationInstructions(_ id: UUID, instructions: String, preferences: ConversationPreferences) -> Bool {
        do {
            try MochiTools.validateInstructions(instructions); try preferences.validate()
            guard !busy, !practice, !managerOpen, renameID == nil, permanentDeleteIDs.isEmpty, let index = library.conversations.firstIndex(where:{ $0.id == id && !$0.archived && !$0.isDeleted }) else { throw AppFailure("This conversation cannot be edited right now.") }
            var candidate = library
            candidate.conversations[index].instructions = instructions.trimmingCharacters(in:.whitespacesAndNewlines)
            candidate.conversations[index].preferences = preferences
            return commitHistory(candidate)
        } catch { self.error = (error as? AppFailure)?.message ?? "Could not save conversation instructions."; return false }
    }
    func executeTool(_ name: String, arguments: [String:Any], origin: ToolOrigin) throws -> [String:Any] {
        let tool = try MochiTools.validate(name:name,arguments:arguments,origin:origin)
        if origin == .external && !externalControlEnabled { throw AppFailure("External control is disabled in Mochi Settings.") }
        if origin == .voice, turn.activity == .generating, deferredToolAction != nil, ["prepare_expression","start_practice","play_audio","seek_audio"].contains(name) {
            throw AppFailure("A view or playback action is already scheduled for this reply.")
        }
        let requestedID = (arguments["conversation_id"] as? String).flatMap(UUID.init(uuidString:))
        let limit = (arguments["limit"] as? NSNumber)?.intValue ?? 30
        if name == "get_session" {
            var result: [String:Any] = ["ok":true,"revision":controlRevision,"activity":turn.activity.rawValue,"mode":practice ? "practice" : "conversation","modal":automationModal,"paused":audio.paused,"playback_seconds":audio.position,"playback_duration":audio.duration]
            if let chat = conversation {
                result["conversation_id"] = chat.id.uuidString; result["title"] = chat.title
                result["writable"] = !chat.archived && !chat.isDeleted
                if !chat.archived && !chat.isDeleted {
                    result["instructions"] = String(chat.instructions.prefix(origin == .voice ? 1000 : MochiTools.maxInstructions)); result["instructions_truncated"] = chat.instructions.count > (origin == .voice ? 1000 : MochiTools.maxInstructions); result["coaching"] = chat.preferences.coaching.rawValue
                    result["speed"] = chat.preferences.speed ?? conversationVoiceOptions.speed
                    result["audio_message_ids"] = chat.messages.filter { $0.audio != nil }.suffix(origin == .voice ? 20 : 100).map { $0.id.uuidString }
                    result["expression_ids"] = library.expressions.filter { $0.conversationID == chat.id }.sorted { $0.date > $1.date }.prefix(origin == .voice ? 20 : 100).map { $0.id.uuidString }
                }
            }
            if let expression { result["selected_expression_id"] = expression.id.uuidString }
            return result
        }
        if name == "list_conversations" {
            return ["ok":true,"revision":controlRevision,"conversations":library.history(in:.active).prefix(limit).map { ["id":$0.id.uuidString,"title":$0.title] }]
        }
        if name != "create_conversation" {
            guard let requestedID, let chat = library.conversations.first(where: { $0.id == requestedID }), !chat.archived, !chat.isDeleted else { throw AppFailure("An active conversation is required.") }
            if name != "open_conversation", requestedID != selectedID { throw AppFailure("That conversation is not currently open. Read get_session again.") }
        }
        if !tool.readOnly {
            if origin == .external {
                guard arguments["expected_revision"] as? String == controlRevision else { throw AppFailure("Mochi's state changed. Read get_session and retry with the new revision.") }
                guard !automationModal else { throw AppFailure("Finish or close the current conversation editing or practice panel, then retry.") }
                guard !busy || turn.activity == .playing else { throw AppFailure("Mochi is busy. Wait until the current activity finishes.") }
            } else {
                guard !automationModal, turn.mode == .conversation, !busy || turn.activity == .generating || turn.activity == .playing else { throw AppFailure("This action is unavailable during the current activity.") }
            }
        }
        func success(_ fields: [String:Any] = [:]) -> [String:Any] { var result = fields; result["ok"] = true; result["revision"] = controlRevision; return result }
        func persist(_ candidate: Library) throws { guard commitHistory(candidate) else { throw AppFailure("The app action could not be saved; nothing was changed.") } }
        let scheduledConversationID = selectedID
        func schedule(_ action: @escaping () throws -> Void) throws -> [String:Any] {
            if origin == .voice && turn.activity == .generating {
                guard deferredToolAction == nil else { throw AppFailure("A view or playback action is already scheduled for this reply.") }
                let key = voiceToolKey
                deferredToolAction = { [weak self] in
                    do {
                        guard let self else { return }
                        guard self.selectedID == scheduledConversationID, self.writableConversation, !self.automationModal, !self.busy else { throw AppFailure("The conversation or activity changed; the scheduled action was cancelled.") }
                        try action()
                        if let key { self.cacheVoiceTool(key,result:["ok":true,"status":"completed","revision":self.controlRevision]) }
                    } catch { self?.error = (error as? AppFailure)?.message ?? "The scheduled action could not complete." }
                }
                return success(["status":"scheduled_after_reply"])
            }
            if origin == .external && ["prepare_expression","start_practice"].contains(name) { revealWorkspace?() }
            // Existing playback is allowed for an immediate external seek/replay.
            guard selectedID == scheduledConversationID, writableConversation, !automationModal else { throw AppFailure("The conversation changed; the action was cancelled.") }
            try action(); return success(["status":"completed"])
        }
        switch name {
        case "get_messages":
            let source = Array(conversation?.messages.suffix(origin == .voice ? min(limit,10) : limit) ?? [])
            var messages: [[String:Any]] = [], size = 0
            for message in source.reversed() {
                let text = message.contextText ?? ""
                var item: [String:Any] = ["id":message.id.uuidString,"role":message.role,"text":String(text.prefix(2000)),"text_truncated":text.count > 2000,"has_audio":message.audio != nil]
                if message.audio != nil { item["transcription_state"] = message.transcriptionState?.rawValue ?? "not_required" }
                size += try JSONSerialization.data(withJSONObject:item).count
                if size > (origin == .voice ? 6000 : 110000) { break }; messages.append(item)
            }
            return success(["messages":Array(messages.reversed()),"has_more":(conversation?.messages.count ?? 0) > messages.count])
        case "search_expressions":
            let query = arguments["query"] as! String
            let found = library.expressions.filter { $0.conversationID == selectedID && (query.isEmpty || $0.english.localizedCaseInsensitiveContains(query) || $0.meaning.localizedCaseInsensitiveContains(query)) }
            var expressions: [[String:Any]] = [], size = 0
            for item in found.sorted(by:{ $0.date > $1.date }).prefix(origin == .voice ? min(limit,10) : limit) {
                let value: [String:Any] = ["id":item.id.uuidString,"english":String(item.english.prefix(1000)),"meaning":String(item.meaning.prefix(1000)),"text_truncated":item.english.count > 1000 || item.meaning.count > 1000,"has_reference":item.reference != nil,"attempt_count":item.attempts.count]
                size += try JSONSerialization.data(withJSONObject:value).count
                if size > (origin == .voice ? 6000 : 110000) { break }; expressions.append(value)
            }
            return success(["expressions":expressions,"has_more":found.count > expressions.count])
        case "create_conversation":
            var chat = Conversation(title:(arguments["title"] as? String)?.trimmingCharacters(in:.whitespacesAndNewlines) ?? "A new conversation")
            if chat.title.isEmpty { chat.title = "A new conversation" }
            chat.customTitle = !(arguments["title"] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty; chat.instructions = (arguments["instructions"] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
            var candidate = library
            if let current = conversation, !current.archived, !current.isDeleted, current.messages.isEmpty, !current.customTitle,
               current.instructions.isEmpty, current.preferences == ConversationPreferences(), current.draft.isEmpty, current.helpDraft == nil,
               let index = candidate.conversations.firstIndex(where:{ $0.id == current.id }) {
                var reused = current
                reused.title = chat.title; reused.customTitle = chat.customTitle; reused.instructions = chat.instructions
                chat = reused; candidate.conversations[index] = reused
            } else { candidate.conversations.insert(chat,at:0) }
            candidate.selectedConversationID = chat.id
            try persist(candidate); select(chat.id); historyScope = .active; revealWorkspace?()
            return success(["conversation_id":chat.id.uuidString])
        case "open_conversation":
            select(requestedID!); historyScope = .active; revealWorkspace?(); return success(["conversation_id":requestedID!.uuidString])
        case "set_conversation_instructions", "set_conversation_preferences":
            guard let index = library.conversations.firstIndex(where:{ $0.id == requestedID }) else { throw AppFailure("Conversation not found.") }
            var candidate = library
            if name == "set_conversation_instructions" { candidate.conversations[index].instructions = (arguments["instructions"] as! String).trimmingCharacters(in:.whitespacesAndNewlines) }
            if let speed = arguments["speed"] as? NSNumber { candidate.conversations[index].preferences.speed = speed.doubleValue }
            if let coaching = arguments["coaching"] as? String { candidate.conversations[index].preferences.coaching = CoachingStyle(rawValue:coaching)! }
            try candidate.conversations[index].preferences.validate(); try persist(candidate); return success()
        case "save_expression", "prepare_expression":
            let english = (arguments["english"] as! String).trimmingCharacters(in:.whitespacesAndNewlines), meaning = arguments["meaning"] as? String ?? ""
            var candidate = library
            if name == "save_expression" {
                let item = candidate.expressions.first { $0.conversationID == requestedID && $0.english == english && $0.meaning == meaning } ?? PracticeExpression(conversationID:requestedID!,meaning:meaning,english:english)
                if !candidate.expressions.contains(where:{ $0.id == item.id }) { candidate.expressions.insert(item,at:0); try persist(candidate) }
                return success(["expression_id":item.id.uuidString])
            }
            func hasDraft(_ chat: Conversation) -> Bool {
                guard let draft = chat.helpDraft else { return false }
                return !draft.meaning.isEmpty || !draft.english.isEmpty || draft.recording != nil || draft.transcriptReview != nil || draft.expressionID != nil || draft.clarification != nil
            }
            guard let chat = conversation, !hasDraft(chat) else { throw AppFailure("This conversation already has a Help draft. Finish or discard it before preparing another expression.") }
            let chatID = chat.id
            return try schedule { [weak self] in
                guard let self, self.selectedID == chatID, self.writableConversation, !self.automationModal,
                      let ci = self.library.conversations.firstIndex(where:{ $0.id == chatID }), !hasDraft(self.library.conversations[ci]) else { throw AppFailure("The conversation changed; your existing Help draft was kept.") }
                var next = self.library
                next.conversations[ci].helpDraft = HelpDraft(meaning:meaning,english:english)
                guard self.commitHistory(next) else { throw AppFailure("The expression could not be prepared; your draft was kept.") }
                self.startHelp()
            }
        case "start_practice":
            guard let id = (arguments["expression_id"] as? String).flatMap(UUID.init(uuidString:)), let item = library.expressions.first(where:{ $0.id == id && $0.conversationID == selectedID }) else { throw AppFailure("Expression not found in this conversation.") }
            return try schedule { [weak self] in
                guard let self, let current = self.library.expressions.first(where:{ $0.id == item.id && $0.conversationID == self.selectedID }) else { throw AppFailure("The expression is no longer available in this conversation.") }
                self.openExpression(current)
            }
        case "pause_audio", "resume_audio":
            guard playbackFile != nil else { throw AppFailure("No audio is playing.") }
            if (name == "pause_audio" && !audio.paused) || (name == "resume_audio" && audio.paused) { audio.togglePause(); objectWillChange.send() }
            return success()
        case "play_audio", "seek_audio":
            var file: String?, mochi = false
            if let id = (arguments["message_id"] as? String).flatMap(UUID.init(uuidString:)), let message = conversation?.messages.first(where: { $0.id == id }) { file = message.audio; mochi = message.role == "assistant" }
            if let id = (arguments["expression_id"] as? String).flatMap(UUID.init(uuidString:)) { file = library.expressions.first(where:{ $0.id == id && $0.conversationID == selectedID })?.reference }
            guard let file, file == URL(fileURLWithPath:file).lastPathComponent, FileManager.default.fileExists(atPath:store.root.appendingPathComponent(file).path) else { throw AppFailure("Audio is unavailable for that item.") }
            let seconds = (arguments["seconds"] as? NSNumber)?.doubleValue
            return try schedule { [weak self] in
                guard let self else { return }
                if let seconds { self.seekPlayback(file,to:seconds,mochi:mochi) }
                else { self.play(file,mochi:mochi) }
                guard self.playbackFile == file else { throw AppFailure("This recording could not be played.") }
            }
        default: throw AppFailure("Unsupported Mochi action.")
        }
    }
}
