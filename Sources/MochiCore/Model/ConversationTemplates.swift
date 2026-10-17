import CryptoKit
import Foundation
import MochiKernel

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
    public var personality = ""
    public var greeting = ""
    public var phrases: [String] = []
    public init(
        title: String, description: String = "", characterName: String? = nil, instructions: String = "",
        preferences: ConversationPreferences = ConversationPreferences()
    ) {
        id = UUID()
        revision = UUID().uuidString
        self.title = title
        self.description = description
        self.characterName = characterName
        self.instructions = instructions
        self.preferences = preferences
        createdAt = Date()
        updatedAt = createdAt
    }
    private enum CodingKeys: String, CodingKey {
        case id, revision, title, description, characterName, instructions, preferences, createdAt, updatedAt
        case personality, greeting, phrases
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        revision = try c.decode(String.self, forKey: .revision)
        title = try c.decode(String.self, forKey: .title)
        description = try c.decode(String.self, forKey: .description)
        characterName = try c.decodeIfPresent(String.self, forKey: .characterName)
        instructions = try c.decode(String.self, forKey: .instructions)
        preferences = try c.decode(ConversationPreferences.self, forKey: .preferences)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        personality = try c.decodeIfPresent(String.self, forKey: .personality) ?? ""
        greeting = try c.decodeIfPresent(String.self, forKey: .greeting) ?? ""
        phrases = try c.decodeIfPresent([String].self, forKey: .phrases) ?? []
    }
    /// Settings added after version 3 are written only when set. Built-in revisions hash this encoding, so a built-in
    /// without them keeps the revision it had before they existed.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(revision, forKey: .revision)
        try c.encode(title, forKey: .title)
        try c.encode(description, forKey: .description)
        try c.encodeIfPresent(characterName, forKey: .characterName)
        try c.encode(instructions, forKey: .instructions)
        try c.encode(preferences, forKey: .preferences)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        if !personality.isEmpty { try c.encode(personality, forKey: .personality) }
        if !greeting.isEmpty { try c.encode(greeting, forKey: .greeting) }
        if !phrases.isEmpty { try c.encode(phrases, forKey: .phrases) }
    }
    public var isBuiltin: Bool { Self.reservedIDs.contains(id) }
    public var needsReview: Bool { (try? validateForWrite()) == nil }
    public static let userLimit = 200
    public typealias FieldLimit = (characters: Int, bytes: Int)
    public static let titleLimit: FieldLimit = (160, 2048)
    public static let descriptionLimit: FieldLimit = (500, 4096)
    public static let nameLimit: FieldLimit = (80, 1024)
    public static let instructionsLimit: FieldLimit = (
        ConversationInstructions.maxCharacters, ConversationInstructions.maxBytes
    )
    public static let reservedIDs: Set<UUID> = Set(builtins.map(\.id))
    private static func builtinID(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "DAF3D003-0000-4000-8000-%012d", number))!
    }
    public static func validateName(_ name: String?) throws {
        guard let name else { return }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= nameLimit.characters,
            name.utf8.count <= nameLimit.bytes, !name.unicodeScalars.contains(where: Self.forbiddenInName)
        else {
            throw AppFailure(
                "Character name must contain 1–\(nameLimit.characters) characters, at most \(nameLimit.bytes / 1024) KB, without line breaks, control characters or text-direction overrides."
            )
        }
    }
    /// Control characters, line breaks and bidirectional overrides are refused. Joiners and the emoji variation
    /// selector are format characters that real names need (emoji sequences, Persian spelling), so they are allowed.
    static func forbiddenInName(_ scalar: Unicode.Scalar) -> Bool { SingleLineText.isForbidden(scalar) }
    public static func validateText(
        _ value: String, field: String.LocalizationValue, characters: Int, bytes: Int, required: Bool = false
    )
        throws
    {
        guard value.count <= characters, value.utf8.count <= bytes,
            !required || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            let name = String(localized: field)
            throw required
                ? AppFailure(
                    "\(name) must contain text and fit within \(characters) characters and \(bytes / 1024) KB.")
                : AppFailure("\(name) must fit within \(characters) characters and \(bytes / 1024) KB.")
        }
    }
    public func validateForWrite() throws {
        try Self.validateText(
            title, field: "Template title", characters: Self.titleLimit.characters, bytes: Self.titleLimit.bytes,
            required: true)
        try Self.validateText(
            description, field: "Description", characters: Self.descriptionLimit.characters,
            bytes: Self.descriptionLimit.bytes)
        try validateSettings()
        try validateMeaningful()
        guard try JSONSerialization.data(withJSONObject: fullRepresentation).count < 100000 else {
            throw AppFailure("Encoded template is too large. Shorten its text.")
        }
    }
    /// The settings a conversation copies, as a new one must be. An unknown stored voice is not refused: it is kept,
    /// and the Settings voice speaks instead.
    private func validateSettings() throws {
        try Self.validateName(characterName)
        try ConversationInstructions.validate(instructions)
        try ConversationPersonality.validate(personality)
        try ConversationGreeting.validate(greeting)
        try ConversationPhrases.validate(phrases)
        try preferences.validate()
    }
    private func validateMeaningful() throws {
        guard
            !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || characterName != nil
                || preferences.coaching != .natural || preferences.speed != nil
                || preferences.language != ConversationPreferences().language
                || !personality.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !greeting.isEmpty
                || !phrases.isEmpty || preferences.voice != nil
        else {
            throw AppFailure(
                "Add instructions, a character, a greeting, phrases, a language, coaching, a voice or speech speed to this template."
            )
        }
    }
    /// One edit to a template: its catalog title and description, and the settings a conversation copies from it.
    public struct Patch: Equatable {
        /// nil keeps the field; a value replaces it after trimming and validation.
        public var title: String?
        public var description: String?
        public var settings: ConversationSettingsPatch
        public init(
            title: String? = nil, description: String? = nil,
            settings: ConversationSettingsPatch = ConversationSettingsPatch()
        ) {
            self.title = title
            self.description = description
            self.settings = settings
        }
    }
    /// Shared UI/MCP normalization. Only replaced fields are validated; recovery data is retained.
    public func applying(_ patch: Patch, creation: Bool = false) throws -> ConversationTemplate {
        var next = self
        if let value = patch.title {
            next.title = value.trimmingCharacters(in: .whitespacesAndNewlines)
            try Self.validateText(
                next.title, field: "Template title", characters: Self.titleLimit.characters,
                bytes: Self.titleLimit.bytes, required: true)
        }
        if let value = patch.description {
            next.description = value.trimmingCharacters(in: .whitespacesAndNewlines)
            try Self.validateText(
                next.description, field: "Description", characters: Self.descriptionLimit.characters,
                bytes: Self.descriptionLimit.bytes)
        }
        try patch.settings.apply(to: &next)
        try next.validateMeaningful()
        if creation {
            try next.validateForWrite()
        } else if next != self {
            if !needsReview { try next.validateForWrite() }
            next.revision = UUID().uuidString
            next.updatedAt = Date()
        }
        return next
    }
    /// Recovery feedback: counts only items this import added, and reports the soft caps without blocking recovery.
    public static func importSummary(
        conversations: Int, imported: [ConversationTemplate], merged: [ConversationTemplate], localIDs: Set<UUID>,
        addedCharacters: Int = 0, characterCount: Int = 0, missingRecordings: Int = 0
    ) -> String {
        let added = merged.filter { !localIDs.contains($0.id) }
        var sentences = [
            String(
                localized:
                    "Imported \(conversations) conversations, \(added.count) templates and \(addedCharacters) characters. Existing local items were kept."
            ),
            String(
                localized:
                    "\(imported.count - added.count) duplicate templates skipped. \(added.filter(\.needsReview).count) imported templates need review."
            ),
        ]
        if merged.count > userLimit {
            sentences.append(
                String(
                    localized:
                        "You have \(merged.count) user templates, above the \(userLimit) limit; all remain usable, but remove some before creating more."
                ))
        }
        if characterCount > ConversationCharacter.userLimit {
            sentences.append(
                String(
                    localized:
                        "You have \(characterCount) characters, above the \(ConversationCharacter.userLimit) limit; all remain usable, but remove some before creating more."
                ))
        }
        if missingRecordings > 0 {
            sentences.append(
                String(
                    localized:
                        "\(missingRecordings) recordings named in the backup were not in it, so those messages have no audio."
                ))
        }
        return sentences.joined(separator: " ")
    }
    public func conversation(
        title: String? = nil, interface: String = Bundle.main.preferredLocalizations.first ?? "en"
    ) throws -> Conversation {
        var source = isBuiltin ? withBuiltinTextTranslated() : self
        // An edited preview may hold empty phrase rows or stray spaces; a conversation stores what a save would.
        source.phrases = ConversationPhrases.normalized(source.phrases)
        source.greeting = source.greeting.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only a built-in's own greeting can be refitted; a user template's greeting is its owner's text.
        if isBuiltin, Self.isBuiltinGreeting(source.greeting),
            Greetings.spoken(source.preferences.language, interface: interface).language
                != Greetings.spoken(.match, interface: interface).language
        {
            source.greeting = ""
        }
        // Only settings copied into the conversation are relevant here; catalog metadata stays intact.
        try source.validateSettings()
        var chat = Conversation()
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chat.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            chat.customTitle = true
        }
        chat.adoptSettings(from: source)
        chat.sourceTemplateID = id
        chat.sourceTemplateRevision = revision
        return chat
    }
    /// A copy whose built-in greeting and phrases read in the interface language; other text is unchanged. Built-ins
    /// store English, which their revision hashes; once copied out, the text belongs to the copy.
    public func withBuiltinTextTranslated() -> ConversationTemplate {
        var copy = self
        copy.greeting = Self.localizedGreeting(greeting) ?? greeting
        copy.phrases = phrases.map { Self.localizedPhrase($0) ?? $0 }
        return copy
    }
    /// Whether `text` is a built-in greeting, in English or in the interface language.
    static func isBuiltinGreeting(_ text: String) -> Bool {
        !text.isEmpty
            && definitions.contains { $0.greeting == text || Self.localizedGreeting($0.greeting) == text }
    }
    private var fullRepresentation: [String: Any] {
        [
            "id": id.uuidString, "template_revision": revision, "title": title, "description": description,
            "character_name": characterName as Any? ?? NSNull(), "instructions": instructions,
            "personality": personality, "greeting": greeting, "phrases": phrases,
            "voice": preferences.voice as Any? ?? NSNull(),
            "coaching": preferences.coaching.rawValue, "language": preferences.language.rawValue,
            "speed": preferences.speed as Any? ?? NSNull(), "origin": isBuiltin ? "built_in" : "user",
            "created_at": createdAt.formatted(.iso8601), "updated_at": updatedAt.formatted(.iso8601),
        ]
    }
    public func representation(includeInstructions: Bool = true) -> [String: Any] {
        var value = fullRepresentation
        var truncated: [String: Bool] = [:]
        func bound(_ key: String, _ limit: FieldLimit) {
            guard let original = value[key] as? String else { return }
            let preview = original.bounded(characters: limit.characters, bytes: limit.bytes)
            value[key] = preview
            if preview != original { truncated[key] = true }
        }
        bound("title", Self.titleLimit)
        bound("description", Self.descriptionLimit)
        bound("character_name", Self.nameLimit)
        bound("personality", (ConversationPersonality.maxCharacters, ConversationPersonality.maxBytes))
        bound("greeting", (ConversationGreeting.maxCharacters, ConversationGreeting.maxBytes))
        let shownPhrases = phrases.prefix(ConversationPhrases.maxCount).map {
            $0.bounded(characters: ConversationPhrases.maxCharacters, bytes: ConversationPhrases.maxBytes)
        }
        value["phrases"] = shownPhrases
        if shownPhrases != phrases { truncated["phrases"] = true }
        if includeInstructions {
            bound("instructions", Self.instructionsLimit)
            var byteLimit = Self.instructionsLimit.bytes
            while ((try? JSONSerialization.data(withJSONObject: value).count) ?? Int.max) > 95000 && byteLimit > 0 {
                byteLimit /= 2
                bound("instructions", (Self.instructionsLimit.characters, byteLimit))
            }
        } else {
            // A list carries metadata; long texts that shape replies are read one template at a time.
            value.removeValue(forKey: "instructions")
            value.removeValue(forKey: "personality")
            truncated.removeValue(forKey: "personality")
        }
        value["fields_truncated"] = truncated
        value["needs_review"] = needsReview
        return value
    }
    /// The built-in category a template belongs to; nil for the user's own. Defined in code and never stored, so it
    /// changes no revision.
    public enum Category: Sendable { case general, languagePractice }
    public var category: Category? { Self.builtinNumbers[id].map { Self.definitions[$0 - 1].category } }
    /// True for a built-in where Mochi plays a part in a scenario the user sets up, so Start Again is offered as a
    /// button. Defined in code and never stored, like the category.
    public var isRolePlay: Bool { Self.isRolePlay(id) }
    public static func isRolePlay(_ id: UUID?) -> Bool {
        id.flatMap { builtinNumbers[$0] }.map { definitions[$0 - 1].rolePlay } ?? false
    }
    /// Built-in templates are stored in English, since their revision hashes that text; they are shown translated.
    public var displayTitle: String { Self.builtinNumbers[id].flatMap(Self.localizedText)?.title ?? title }
    public var displayDescription: String {
        Self.builtinNumbers[id].flatMap(Self.localizedText)?.description ?? description
    }
    /// The interface-language title and description of built-in `number`. Each literal is a string-catalog key and
    /// must equal the stored English, which a test checks.
    private static func localizedText(_ number: Int) -> (title: String, description: String)? {
        switch number {
        case 1:
            (String(localized: "Restaurant"), String(localized: "Order a meal and handle follow-up questions."))
        case 2:
            (String(localized: "Hotel check-in"), String(localized: "Practise arrivals, reservations, and requests."))
        case 3:
            (
                String(localized: "Job interview"),
                String(localized: "Practise explaining experience and answering questions.")
            )
        case 4:
            (
                String(localized: "Vocabulary recall"),
                String(localized: "Recall words and use them in your own sentences.")
            )
        case 5:
            (
                String(localized: "Pronunciation and shadowing"),
                String(localized: "Listen, record, and compare selected sentences.")
            )
        case 6:
            (
                String(localized: "Topic discussion"),
                String(localized: "Discuss something interesting at your own pace.")
            )
        case 7:
            (
                String(localized: "Brainstorm with me"),
                String(localized: "Generate lots of ideas together, then choose the best.")
            )
        case 8:
            (
                String(localized: "Think out loud"),
                String(localized: "Talk through a messy thought until it becomes clear.")
            )
        case 9:
            (
                String(localized: "Rehearse a conversation"),
                String(localized: "Practise a difficult talk, pitch or request before the real one.")
            )
        case 10:
            (
                String(localized: "Make a story with me"),
                String(localized: "Build a story together, one turn at a time.")
            )
        case 11:
            (
                String(localized: "Interview my character"),
                String(localized: "Develop a fictional character by answering as them.")
            )
        case 12:
            (
                String(localized: "Learn by teaching"),
                String(localized: "Explain a topic to a curious beginner to find the gaps.")
            )
        case 13:
            (
                String(localized: "Remember a moment"),
                String(localized: "Revisit a memory and keep it as a short vignette.")
            )
        default: nil
        }
    }
    /// The interface-language text of a built-in greeting, or nil for any other text. Each literal is a
    /// string-catalog key and must equal a built-in's English greeting, which a test checks.
    static func localizedGreeting(_ english: String) -> String? {
        switch english {
        case "What shall we brainstorm? Tell me what the ideas are for.":
            String(localized: "What shall we brainstorm? Tell me what the ideas are for.")
        case "What's on your mind? Start with the rough version, however messy.":
            String(localized: "What's on your mind? Start with the rough version, however messy.")
        case "Who will you be talking to, and what do you need to say?":
            String(localized: "Who will you be talking to, and what do you need to say?")
        case "Where does our story begin?": String(localized: "Where does our story begin?")
        case "Who is your character? Tell me their name and one thing they want.":
            String(localized: "Who is your character? Tell me their name and one thing they want.")
        case "What would you like to teach me today?": String(localized: "What would you like to teach me today?")
        case "Which moment would you like to remember?": String(localized: "Which moment would you like to remember?")
        default: nil
        }
    }
    /// The interface-language text of a built-in phrase, or nil for any other text.
    static func localizedPhrase(_ english: String) -> String? {
        switch english {
        case "Give me wilder ideas.": String(localized: "Give me wilder ideas.")
        case "Which idea is strongest?": String(localized: "Which idea is strongest?")
        case "Let's wrap up.": String(localized: "Let's wrap up.")
        case "Ask me something harder.": String(localized: "Ask me something harder.")
        case "What am I missing?": String(localized: "What am I missing?")
        case "Sum it up for me.": String(localized: "Sum it up for me.")
        case "Push back harder.": String(localized: "Push back harder.")
        case "Let's start again.": String(localized: "Let's start again.")
        case "How did I do?": String(localized: "How did I do?")
        case "Add a twist.": String(localized: "Add a twist.")
        case "Let me decide what happens.": String(localized: "Let me decide what happens.")
        case "Give it an ending.": String(localized: "Give it an ending.")
        case "Ask about my past.": String(localized: "Ask about my past.")
        case "Let's finish the interview.": String(localized: "Let's finish the interview.")
        case "Did that make sense?": String(localized: "Did that make sense?")
        case "Ask me a harder question.": String(localized: "Ask me a harder question.")
        case "Sum up what I taught you.": String(localized: "Sum up what I taught you.")
        case "Let's skip that.": String(localized: "Let's skip that.")
        case "Ask me about the people.": String(localized: "Ask me about the people.")
        case "Let's keep it.": String(localized: "Let's keep it.")
        default: nil
        }
    }
    private struct Definition {
        let title: String, description: String, characterName: String?, instructions: String
        var language = ConversationLanguage.english
        let category: Category
        var greeting = ""
        var phrases: [String] = []
        var rolePlay = false
    }
    /// Every built-in, in order: its place is its number, which fixes its ID. Append only, so existing IDs and the
    /// revisions conversations recorded never change.
    private static let definitions: [Definition] = [
        Definition(
            title: "Restaurant", description: "Order a meal and handle follow-up questions.", characterName: "Alex",
            instructions:
                "You are Alex, a restaurant server. The user is a customer. Help them practise ordering a meal and asking about ingredients. Ask one natural question at a time. Stay in role; ask for missing preferences instead of inventing them.",
            category: .languagePractice, rolePlay: true),
        Definition(
            title: "Hotel check-in", description: "Practise arrivals, reservations, and requests.",
            characterName: "Alex",
            instructions:
                "You are Alex at a hotel reception desk. The user is a guest checking in. Practise a realistic check-in and special requests. Ask one question at a time. Ask for reservation details instead of inventing them.",
            category: .languagePractice, rolePlay: true),
        Definition(
            title: "Job interview", description: "Practise explaining experience and answering questions.",
            characterName: "Alex",
            instructions:
                "You are Alex, an interviewer. Ask the user what job they are preparing for, then conduct a realistic interview one question at a time. Ask follow-ups about their own answers; do not invent their experience.",
            category: .languagePractice, rolePlay: true),
        Definition(
            title: "Vocabulary recall", description: "Recall words and use them in your own sentences.",
            characterName: "Mochi",
            instructions:
                "Ask for a word list, then practise active recall, meanings, and original examples one word at a time. Give hints only after the learner attempts an answer or asks. Revisit missed words in this conversation. Do not claim long-term mastery or scheduled spaced repetition.",
            category: .languagePractice),
        Definition(
            title: "Pronunciation and shadowing", description: "Listen, record, and compare selected sentences.",
            characterName: "Mochi",
            instructions:
                "Ask for a word or sentence to practise. Help prepare it for reference playback and shadowing with Mochi's existing practice tools. Recording is always initiated by the user. Discuss listening and comparison; never give a pronunciation score from pitch similarity or uncertain transcription, and do not pretend to have assessed audio you have not received.",
            category: .languagePractice),
        Definition(
            title: "Topic discussion", description: "Discuss something interesting at your own pace.",
            characterName: "Mochi",
            instructions:
                "Ask what topic the user would like to discuss. Explore their ideas with natural follow-up questions, one at a time. Respond to the substance of their answers and give them room to think.",
            category: .languagePractice),
        // General templates follow the user's language, correct nothing, and set no character name, so a role-play
        // can name the person Mochi plays.
        Definition(
            title: "Brainstorm with me", description: "Generate lots of ideas together, then choose the best.",
            characterName: nil,
            instructions:
                "Brainstorm with the user. If they have not said what the ideas are for, ask that first, along with any constraint that matters. Then build ideas together: offer two or three short, varied ideas at a time, build on the user's ideas, and invite them to add more or push back. Favour quantity and range before judging. When the user wants to narrow down, help them compare the strongest few against their goal. When they ask to wrap up, recap the best few ideas and suggest one next step, in under about 60 words. Speak in plain sentences, without lists, numbering or headings.",
            language: .match, category: .general,
            greeting: "What shall we brainstorm? Tell me what the ideas are for.",
            phrases: ["Give me wilder ideas.", "Which idea is strongest?", "Let's wrap up."]),
        Definition(
            title: "Think out loud", description: "Talk through a messy thought until it becomes clear.",
            characterName: nil,
            instructions:
                "Help the user think something through out loud. If they have not shared the thought yet, invite the rough version, however messy. Listen more than you talk: reflect back what you heard in one sentence, then ask one question that makes it more specific, such as an example, a reason, or a difference between two things. Never supply their conclusion or invent what they mean; when unsure, ask. When they ask to sum up, state the clearest version of their idea in their own terms, using only what they said: your questions are not their answers, so leave out anything you asked that they did not answer, then name one question still open for them to think about later, without asking them to continue. Keep it under about 60 words. Speak in plain sentences, without lists, numbering or headings.",
            language: .match, category: .general,
            greeting: "What's on your mind? Start with the rough version, however messy.",
            phrases: ["Ask me something harder.", "What am I missing?", "Sum it up for me."]),
        Definition(
            title: "Rehearse a conversation",
            description: "Practise a difficult talk, pitch or request before the real one.", characterName: nil,
            instructions:
                "Help the user rehearse a conversation they are about to have, such as a difficult talk, a pitch, a negotiation or a request. Unless they have already said, first ask who they will be talking to, what they need to say, and how they expect that person to react. When you have enough, tell the user to begin whenever they are ready; if they start speaking to that person before then, take it as the start and answer in the role. Then play that person realistically, including reasonable pushback, and stay in the role until the user steps out of it. Do not invent facts about the user's situation; ask instead. When the user asks for feedback or to stop, step out of the role and give brief, specific feedback: what worked, one thing to try differently, and a possible opening line, in under about 60 words. Then offer to run it again. Speak in plain sentences, without lists, numbering or headings.",
            language: .match, category: .general,
            greeting: "Who will you be talking to, and what do you need to say?",
            phrases: ["Push back harder.", "Let's start again.", "How did I do?"], rolePlay: true),
        Definition(
            title: "Make a story with me", description: "Build a story together, one turn at a time.",
            characterName: nil,
            instructions:
                "Make up a story together with the user. If they have not set it up, ask where the story begins, or offer two quick premises to choose from. Take turns: add a few vivid sentences, then hand the story back, often with a choice or an open question about what happens next. Keep every detail the user adds and let them steer the big decisions. Keep each turn short enough to enjoy listening to. When the user wants an ending, tell a satisfying final scene in under about 60 words that resolves what the story has set up. Speak in plain sentences, without lists, numbering or headings.",
            language: .match, category: .general,
            greeting: "Where does our story begin?",
            phrases: ["Add a twist.", "Let me decide what happens.", "Give it an ending."]),
        Definition(
            title: "Interview my character", description: "Develop a fictional character by answering as them.",
            characterName: nil,
            instructions:
                "Help the user develop a fictional character by interviewing them. Unless already given, ask for the character's name and one thing they want. From then on the user answers as the character and you are the interviewer, speaking to the character directly as you. Ask one open question at a time about their past, desires, fears, relationships and contradictions, and follow up on surprising answers. Never build a question on something they have not said, never answer for the character, and never invent facts about them. When the user asks to finish, give a character sketch of under about 60 words built only from their answers, then name one question still worth exploring. Speak in plain sentences, without lists, numbering or headings.",
            language: .match, category: .general,
            greeting: "Who is your character? Tell me their name and one thing they want.",
            phrases: ["Ask about my past.", "Ask me something harder.", "Let's finish the interview."], rolePlay: true),
        Definition(
            title: "Learn by teaching", description: "Explain a topic to a curious beginner to find the gaps.",
            characterName: nil,
            instructions:
                "Act as a curious, bright beginner whom the user is teaching. Unless already said, ask what they would like to explain. Then ask the questions a newcomer would: ask for examples, question jargon, and say plainly when a step does not follow. Do not lecture, explain the topic yourself or supply missing answers, and do not grade it; if something looks wrong, ask about it as a genuine question. When the user asks to sum up, restate only what they actually explained, then name the questions they left unanswered, in under about 60 words. Speak in plain sentences, without lists, numbering or headings.",
            language: .match, category: .general,
            greeting: "What would you like to teach me today?",
            phrases: ["Did that make sense?", "Ask me a harder question.", "Sum up what I taught you."]),
        Definition(
            title: "Remember a moment", description: "Revisit a memory and keep it as a short vignette.",
            characterName: nil,
            instructions:
                "Help the user revisit a moment from their life. Unless already said, ask which moment they would like to remember. Ask gentle questions one at a time about the place, the people, what they saw, heard and felt, and what it meant to them. Follow their lead, let them skip anything, and when they share a feeling, acknowledge it warmly before asking anything else. Respond with warmth rather than analysis. Never add details they did not give. When they ask to keep it, write a vignette of under about 60 words in the first person, as the user would tell it, using only details the user said: your questions are not their answers, so leave out anything they did not answer, and add no taste, sound, weather or feeling they did not mention. Speak in plain sentences, without lists, numbering or headings.",
            language: .match, category: .general,
            greeting: "Which moment would you like to remember?",
            phrases: ["Let's skip that.", "Ask me about the people.", "Let's keep it."]),
    ]
    public static let builtins: [ConversationTemplate] = definitions.enumerated().map { index, entry in
        var t = ConversationTemplate(
            title: entry.title, description: entry.description, characterName: entry.characterName,
            instructions: entry.instructions)
        t.preferences.language = entry.language
        t.greeting = entry.greeting
        t.phrases = entry.phrases
        t.id = builtinID(index + 1)
        t.createdAt = Date(timeIntervalSince1970: 0)
        t.updatedAt = t.createdAt
        t.revision = ""
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        t.revision = SHA256.hash(data: try! encoder.encode(t)).map { String(format: "%02x", $0) }.joined()
        return t
    }
    private static let builtinNumbers = Dictionary(
        uniqueKeysWithValues: builtins.enumerated().map { ($1.id, $0 + 1) })
}
