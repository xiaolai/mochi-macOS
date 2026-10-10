import Foundation
import CryptoKit
import MochiAutomation

public struct ConversationTemplate: Codable, Identifiable, Equatable {
    public var id: UUID
    public var revision: String
    public var title: String
    public var description: String
    public var characterName: String?
    public var instructions: String
    public var preferences: ConversationPreferences
    public var createdAt: Date
    public var updatedAt: Date
    public init(title: String, description: String = "", characterName: String? = nil, instructions: String = "", preferences: ConversationPreferences = ConversationPreferences()) {
        id = UUID(); revision = UUID().uuidString; self.title = title; self.description = description
        self.characterName = characterName; self.instructions = instructions; self.preferences = preferences
        createdAt = Date(); updatedAt = createdAt
    }
    public var isBuiltin: Bool { Self.reservedIDs.contains(id) }
    public var needsReview: Bool { (try? validateForWrite()) == nil }
    public static let userLimit = 200
    public static let reservedIDs: Set<UUID> = Set((1...6).map { UUID(uuidString:String(format:"DAF3D003-0000-4000-8000-%012d",$0))! })
    public static func validateName(_ name: String?) throws {
        guard let name else { return }
        guard !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, name.count <= 80, name.utf8.count <= 1024,
              !name.unicodeScalars.contains(where:{ CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }) else {
            throw AppFailure("Character name must contain 1–80 characters, at most 1 KB, without line breaks or control characters.")
        }
    }
    public static func validateText(_ value: String, field: String, characters: Int, bytes: Int, required: Bool = false) throws {
        guard value.count <= characters, value.utf8.count <= bytes, !required || !value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {
            throw AppFailure("\(field) must \(required ? "contain text and " : "")fit within \(characters) characters and \(bytes / 1024) KB.")
        }
    }
    public func validateForWrite() throws {
        try Self.validateText(title,field:"Template title",characters:160,bytes:2048,required:true)
        try Self.validateText(description,field:"Description",characters:500,bytes:4096)
        try Self.validateName(characterName); try MochiTools.validateInstructions(instructions); try preferences.validate()
        try validateMeaningful()
        guard try JSONSerialization.data(withJSONObject:fullRepresentation).count < 100000 else { throw AppFailure("Encoded template is too large. Shorten its text.") }
    }
    private func validateMeaningful() throws {
        guard !instructions.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || characterName != nil || preferences.coaching != .natural || preferences.speed != nil else {
            throw AppFailure("Add instructions, a character name, coaching, or speech speed to this template.")
        }
    }
    /// Shared UI/MCP normalization. Only replaced fields are validated; recovery data is retained.
    public func applying(_ fields: [String:Any], creation: Bool = false) throws -> ConversationTemplate {
        let args = creation ? fields : fields.merging(["template_id":id.uuidString,"expected_template_revision":revision]) { _,trusted in trusted }
        _ = try MochiTools.validate(name:creation ? "create_conversation_template" : "update_conversation_template",arguments:args,origin:.external)
        var next = self
        if let value = fields["title"] as? String { next.title = value.trimmingCharacters(in:.whitespacesAndNewlines); try Self.validateText(next.title,field:"Template title",characters:160,bytes:2048,required:true) }
        if let value = fields["description"] as? String { next.description = value.trimmingCharacters(in:.whitespacesAndNewlines); try Self.validateText(next.description,field:"Description",characters:500,bytes:4096) }
        if let value = fields["instructions"] as? String { try MochiTools.validateInstructions(value); next.instructions = value.trimmingCharacters(in:.whitespacesAndNewlines) }
        if let value = fields["character_name"] as? String { next.characterName = value.trimmingCharacters(in:.whitespacesAndNewlines); try Self.validateName(next.characterName) }
        if fields["clear_character_name"] as? Bool == true { next.characterName = nil }
        if let value = fields["coaching"] as? String { guard let style = CoachingStyle(rawValue:value) else { throw AppFailure("Invalid coaching style.") }; next.preferences.coaching = style }
        if let value = fields["speed"] as? NSNumber { next.preferences.speed = value.doubleValue }
        if fields["clear_speed"] as? Bool == true { next.preferences.speed = nil }
        try next.preferences.validate(); try next.validateMeaningful()
        if creation { try next.validateForWrite() }
        else if next != self {
            if !needsReview { try next.validateForWrite() }
            next.revision = UUID().uuidString; next.updatedAt = Date()
        }
        return next
    }
    /// Recovery feedback: counts only templates this import added, and reports the soft cap without blocking recovery.
    public static func importSummary(conversations: Int, imported: [ConversationTemplate], merged: [ConversationTemplate], localIDs: Set<UUID>) -> String {
        let added = merged.filter { !localIDs.contains($0.id) }
        var text = "Imported \(conversations) conversations and \(added.count) templates. Existing local items were kept. \(imported.count - added.count) duplicate templates skipped. \(added.filter(\.needsReview).count) imported templates need review."
        if merged.count > userLimit { text += " You have \(merged.count) user templates, above the \(userLimit) limit; all remain usable, but remove some before creating more." }
        return text
    }
    public func conversation(title: String? = nil) throws -> Conversation {
        // Only settings copied into the conversation are relevant here; catalog metadata stays intact.
        try MochiTools.validateInstructions(instructions); try Self.validateName(characterName); try preferences.validate()
        var chat = Conversation()
        if let title, !title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { chat.title = title.trimmingCharacters(in:.whitespacesAndNewlines); chat.customTitle = true }
        chat.instructions = instructions; chat.characterName = characterName; chat.preferences = preferences
        chat.sourceTemplateID = id; chat.sourceTemplateRevision = revision
        return chat
    }
    private var fullRepresentation: [String:Any] {
        ["id":id.uuidString,"template_revision":revision,"title":title,"description":description,
         "character_name":characterName as Any? ?? NSNull(),"instructions":instructions,"coaching":preferences.coaching.rawValue,
         "speed":preferences.speed as Any? ?? NSNull(),"origin":isBuiltin ? "built_in" : "user",
         "created_at":createdAt.formatted(.iso8601),"updated_at":updatedAt.formatted(.iso8601)]
    }
    public func representation(includeInstructions: Bool = true) -> [String:Any] {
        var value = fullRepresentation, truncated: [String:Bool] = [:]
        func bound(_ key: String, characters: Int, bytes: Int) {
            guard let original = value[key] as? String else { return }
            let preview = MochiTools.boundedText(original,characters:characters,bytes:bytes)
            value[key] = preview; if preview != original { truncated[key] = true }
        }
        bound("title",characters:160,bytes:2048); bound("description",characters:500,bytes:4096); bound("character_name",characters:80,bytes:1024)
        if includeInstructions {
            bound("instructions",characters:8000,bytes:49152)
            var byteLimit = 49152
            while ((try? JSONSerialization.data(withJSONObject:value).count) ?? Int.max) > 95000 && byteLimit > 0 {
                byteLimit /= 2; bound("instructions",characters:8000,bytes:byteLimit)
            }
        } else { value.removeValue(forKey:"instructions") }
        value["fields_truncated"] = truncated; value["needs_review"] = needsReview
        return value
    }
    public static let builtins: [ConversationTemplate] = {
        let entries: [(String,String,String,String)] = [
            ("Restaurant","Order a meal and handle follow-up questions.","Alex","You are Alex, a restaurant server. The user is a customer. Help them practise ordering a meal and asking about ingredients. Ask one natural question at a time. Stay in role; ask for missing preferences instead of inventing them."),
            ("Hotel check-in","Practise arrivals, reservations, and requests.","Alex","You are Alex at a hotel reception desk. The user is a guest checking in. Practise a realistic check-in and special requests. Ask one question at a time. Ask for reservation details instead of inventing them."),
            ("Job interview","Practise explaining experience and answering questions.","Alex","You are Alex, an interviewer. Ask the user what job they are preparing for, then conduct a realistic interview one question at a time. Ask follow-ups about their own answers; do not invent their experience."),
            ("Vocabulary recall","Recall words and use them in your own sentences.","Mochi","Ask for a word list, then practise active recall, meanings, and original examples one word at a time. Give hints only after the learner attempts an answer or asks. Revisit missed words in this conversation. Do not claim long-term mastery or scheduled spaced repetition."),
            ("Pronunciation and shadowing","Listen, record, and compare selected sentences.","Mochi","Ask for a word or sentence to practise. Help prepare it for reference playback and shadowing with Mochi's existing practice tools. Recording is always initiated by the user. Discuss listening and comparison; never give a pronunciation score from pitch similarity or uncertain transcription, and do not pretend to have assessed audio you have not received."),
            ("Topic discussion","Discuss something interesting at your own pace.","Mochi","Ask what topic the user would like to discuss. Explore their ideas with natural follow-up questions, one at a time. Respond to the substance of their answers and give them room to think.")
        ]
        return entries.enumerated().map { index, entry in
            var t = ConversationTemplate(title:entry.0,description:entry.1,characterName:entry.2,instructions:entry.3)
            t.id = UUID(uuidString:String(format:"DAF3D003-0000-4000-8000-%012d",index+1))!
            t.createdAt = Date(timeIntervalSince1970:0); t.updatedAt = t.createdAt; t.revision = ""
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            t.revision = SHA256.hash(data:try! encoder.encode(t)).map { String(format:"%02x",$0) }.joined()
            return t
        }
    }()
}
