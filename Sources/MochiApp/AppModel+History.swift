import AppKit
import MochiCore
import MochiKernel

/// Conversation history: creating, selecting, renaming, archiving, deleting and restoring conversations,
/// deleting messages with undo, and exporting or importing the library.
extension AppModel {
    func newChat() {
        guard libraryReadable, customization.templatePresentation == nil, customization.instructionsID == nil,
            customization.characterPresentation == nil
        else { return }
        if let chat = conversation, writableConversation, chat.isPristine {
            // Reusing it starts it over, in today's default language.
            if chat.preferences.language != settings.defaultLanguage,
                let index = library.conversations.firstIndex(where: { $0.id == chat.id })
            {
                var candidate = library
                candidate.conversations[index].preferences.language = settings.defaultLanguage
                guard commitHistory(candidate) else { return }
            }
            stop()
            leavePractice()
            help.expression = nil
            showExpressions = false
            history.scope = .active
            history.query = ""
            return
        }
        var candidate = library
        let chat = freshConversation()
        candidate.conversations.insert(chat, at: 0)
        candidate.selectedConversationID = chat.id
        guard commitHistory(candidate) else { return }
        select(chat.id)
        history.scope = .active
        history.query = ""
    }
    func select(_ id: UUID) {
        guard let chat = library.conversations.first(where: { $0.id == id }) else { return }
        stop()
        leavePractice()
        help.expression = nil
        selectedID = id
        showExpressions = false
        draft = chat.draft
        notice = nil
        save()
    }
    func showHistory(_ scope: HistoryScope) {
        stop()
        leavePractice()
        help.expression = nil
        showExpressions = false
        history.scope = scope
        history.query = ""
        selectedID = library.history(in: scope).first?.id
        draft = conversation?.draft ?? ""
        save()
    }
    func commitLibraryCandidate(_ candidate: Library) throws { try libraryController.commit(candidate) }
    @discardableResult func commitHistory(_ candidate: Library) -> Bool {
        do {
            try commitLibraryCandidate(candidate)
            error = nil
            return true
        } catch {
            self.error = persistenceMessage(
                error, action: "Commit library change",
                fallback: "The change could not be saved. Your library was not changed.",
                diskFull: "The change could not be saved because the disk is full. Your library was not changed.")
            return false
        }
    }
    func renameChat(_ id: UUID, title: String) {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 160,
            let i = library.conversations.firstIndex(where: { $0.id == id && !$0.isDeleted })
        else { return }
        var candidate = library
        candidate.conversations[i].title = value
        candidate.conversations[i].customTitle = true
        if commitHistory(candidate) { history.renameID = nil }
    }
    var canDeleteMessages: Bool {
        writableConversation && !practice && turn.activity != .recording && turn.activity != .requestingPermission
    }
    var canUndoMessageDeletion: Bool {
        messageDeletionUndo?.conversationID == selectedID && messageDeletionUndo != nil && writableConversation && !busy
            && !practice
    }
    func deleteMessage(_ id: UUID) {
        guard canDeleteMessages, let ci = library.conversations.firstIndex(where: { $0.id == selectedID }),
            let mi = library.conversations[ci].messages.firstIndex(where: { $0.id == id })
        else { return }
        var message = library.conversations[ci].messages[mi]
        if message.transcriptionState == .pending { message.transcriptionState = .interrupted }
        var candidate = library
        candidate.conversations[ci].messages.remove(at: mi)
        refreshAutomaticTitle(&candidate.conversations[ci])
        guard commitHistory(candidate) else { return }
        let previous = messageDeletionUndo
        messageDeletionUndo = MessageDeletionUndo(
            conversationID: library.conversations[ci].id, message: message, index: mi)
        // Commit first. A disk failure must not stop playback or cancel an active reply.
        stop()
        removeUnreferencedRecording(previous?.message.audio)
        showMessageDeletedNotice()
    }
    func undoMessageDeletion() {
        guard canUndoMessageDeletion, let undo = messageDeletionUndo,
            let ci = library.conversations.firstIndex(where: { $0.id == undo.conversationID }),
            !library.conversations[ci].messages.contains(where: { $0.id == undo.message.id })
        else { return }
        var candidate = library
        candidate.conversations[ci].messages.insert(
            undo.message, at: min(undo.index, candidate.conversations[ci].messages.count))
        refreshAutomaticTitle(&candidate.conversations[ci])
        guard commitHistory(candidate) else { return }
        notice = nil  // The restored library now owns its recording again.
    }
    private func refreshAutomaticTitle(_ chat: inout Conversation) {
        guard !chat.customTitle else { return }
        chat.title =
            chat.messages.first(where: { $0.role == "user" && $0.contextText != nil })
            .flatMap(\.contextText).map { String($0.prefix(42)) } ?? Conversation.untitled
    }
    func finishMessageDeletion() {
        let recording = messageDeletionUndo?.message.audio
        messageDeletionUndo = nil
        removeUnreferencedRecording(recording)
    }
    func pinChats(_ ids: Set<UUID>, pinned: Bool) {
        var candidate = library
        for i in candidate.conversations.indices
        where ids.contains(candidate.conversations[i].id) && !candidate.conversations[i].isDeleted {
            candidate.conversations[i].pinned = pinned
        }
        _ = commitHistory(candidate)
    }
    /// False when the change could not be saved; the failure is already reported.
    @discardableResult func archiveChats(_ ids: Set<UUID>) -> Bool {
        var candidate = library
        for i in candidate.conversations.indices
        where ids.contains(candidate.conversations[i].id) && !candidate.conversations[i].isDeleted {
            candidate.conversations[i].archived = true
        }
        guard finishHistoryChange(candidate, affected: ids) else { return false }
        history.feedback = String(localized: "Conversations archived.")
        return true
    }
    func deleteChats(_ ids: Set<UUID>) {
        var candidate = library
        candidate.moveToDeleted(ids)
        if finishHistoryChange(candidate, affected: ids) {
            history.feedback = String(localized: "Moved to Recently Deleted. You can recover them there.")
        }
    }
    func restoreChats(_ ids: Set<UUID>) {
        var candidate = library
        candidate.restore(ids)
        let selectedRestored = selectedID.flatMap { ids.contains($0) ? $0 : nil }
        guard finishHistoryChange(candidate, affected: ids) else { return }
        history.feedback = String(localized: "Conversations restored.")
        if let id = selectedRestored, let chat = library.conversations.first(where: { $0.id == id && !$0.isDeleted }) {
            history.scope = chat.archived ? .archived : .active
            select(id)
        }
    }
    @discardableResult private func finishHistoryChange(_ candidate: Library, affected: Set<UUID>) -> Bool {
        var next = candidate
        if practice, selectedID.map(affected.contains) == true, let item = help.expression, !item.english.isEmpty {
            next.storeExpression(item)
        }
        let selectedAffected = selectedID.map(affected.contains) ?? false
        if selectedAffected {
            next.selectedConversationID = next.history(in: history.scope, query: history.query).first?.id
        }
        guard commitHistory(next) else { return false }
        if selectedAffected {
            stop()
            leavePractice()
            help.expression = nil
            selectedID = next.selectedConversationID
            draft = conversation?.draft ?? ""
            // stop() saved while the old conversation was still selected; record the replacement selection.
            save()
        }
        history.feedback = nil
        return true
    }
    func permanentlyDeleteChats() {
        let ids = history.permanentDeleteIDs
        var candidate = library
        let removedAudio = candidate.removePermanently(ids)
        guard finishHistoryChange(candidate, affected: ids) else { return }
        guard !library.conversations.contains(where: { ids.contains($0.id) && $0.isDeleted }) else { return }
        history.permanentDeleteIDs = []
        var failed = false
        for name in removedAudio {
            // The message held for Undo may share a recording with a deleted conversation; keep it.
            do {
                try libraryController.removeUnreferencedRecording(name, protected: messageDeletionUndo?.message.audio)
            } catch {
                MochiLog.failure(MochiLog.library, "Remove permanently deleted recording", error, level: .info)
                failed = true
            }
        }
        history.feedback =
            failed
            ? String(
                localized: "Conversations deleted. Some unused recordings could not be removed from the data folder.")
            : String(localized: "Conversations permanently deleted. Saved expressions were kept.")
    }
    func exportChats(_ ids: Set<UUID>, json: Bool = false) {
        let count = library.conversations.filter { ids.contains($0.id) }.count
        guard count > 0, let url = chooseFile(.exportTranscript(count: count, json: json)) else { return }
        exportChats(ids, json: json, to: url)
    }
    func exportChats(_ ids: Set<UUID>, json: Bool, to url: URL) {
        let chats = library.conversations.filter { ids.contains($0.id) }
        guard !chats.isEmpty else { return }
        do {
            let data = json ? try HistoryExport.json(chats) : Data(HistoryExport.markdown(chats).utf8)
            try data.write(to: url, options: .atomic)
            history.feedback = String(localized: "Transcript exported.")
        } catch {
            MochiLog.failure(MochiLog.library, "Export transcript", error)
            self.error =
                ErrorChain.isOutOfSpace(error)
                ? String(localized: "The transcript could not be exported because the disk is full.")
                : String(localized: "The transcript could not be exported. Choose another location.")
        }
    }
    func exportLibraryBackup() {
        guard libraryReadable, libraryTransfer == nil, let url = chooseFile(.exportBackup) else { return }
        exportLibraryBackup(to: url)
    }
    @discardableResult func exportLibraryBackup(to url: URL) -> Task<Void, Never>? {
        guard let transfer = libraryController.exportBackup(to: url) else { return nil }
        return Task { [weak self] in
            do {
                try await transfer.value
                self?.history.feedback = String(localized: "Library backup exported.")
            } catch {
                MochiLog.failure(MochiLog.library, "Export library backup", error)
                self?.report(
                    ErrorChain.isOutOfSpace(error)
                        ? String(localized: "Could not export the backup because the disk is full.")
                        : AppFailure.message(
                            for: error,
                            fallback:
                                "Could not export the backup. Use a new filename and check that referenced recordings are present."
                        ), in: .privacy)
            }
        }
    }
    func importLibraryBackup() {
        guard libraryReadable, libraryTransfer == nil, let url = chooseFile(.importBackup) else { return }
        importLibraryBackup(from: url)
    }
    @discardableResult func importLibraryBackup(from url: URL) -> Task<Void, Never>? {
        guard let transfer = libraryController.importBackup(from: url) else { return nil }
        return Task { [weak self] in
            do {
                // Cancelling the returned task cancels the transfer, so a cancelled import never changes the library.
                let summary = try await withTaskCancellationHandler {
                    try await transfer.value
                } onCancel: {
                    transfer.cancel()
                }
                self?.history.feedback = summary
                self?.error = nil
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                self.report(
                    persistenceMessage(
                        error, action: "Import library backup",
                        fallback:
                            "This backup could not be imported. It may contain missing recordings, invalid IDs, or an unsupported schema. Your history was not changed.",
                        diskFull:
                            "This backup could not be imported because the disk is full. Your history was not changed."),
                    in: .privacy)
            }
        }
    }
}
