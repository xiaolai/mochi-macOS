import Foundation
import CoreFoundation
import CryptoKit

public enum ToolOrigin { case voice, external }
public enum CoachingStyle: String, Codable, CaseIterable { case natural, gentle, direct }
public struct ConversationPreferences: Codable, Equatable {
    public var speed: Double?
    public var coaching: CoachingStyle = .natural
    public init() {}
    private enum CodingKeys: String, CodingKey { case speed, coaching }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        let decoded = try? c.decodeIfPresent(Double.self,forKey:.speed)
        speed = decoded.flatMap { $0.isFinite && (0.25...1.5).contains($0) ? $0 : nil }
        coaching = (try? c.decodeIfPresent(String.self,forKey:.coaching)).flatMap(CoachingStyle.init(rawValue:)) ?? .natural
    }
    public func validate() throws {
        if let speed { guard speed.isFinite, (0.25...1.5).contains(speed) else { throw AppFailure("Speech speed must be between 0.25 and 1.5.") } }
    }
}
public struct MochiTool {
    public let name: String
    public let description: String
    public let properties: [String:[String:Any]]
    public let required: [String]
    public let readOnly: Bool
    public var schema: [String:Any] { ["type":"object","properties":properties,"required":required,"additionalProperties":false] }
    public var realtime: [String:Any] { ["type":"function","name":name,"description":description,"parameters":schema] }
    public var mcp: [String:Any] { ["name":name,"description":description,"inputSchema":schema,"annotations":["readOnlyHint":readOnly,"destructiveHint":["set_conversation_instructions","set_conversation_preferences","update_conversation_template","delete_conversation_template"].contains(name),"idempotentHint":readOnly || ["save_expression","set_conversation_instructions","set_conversation_preferences","pause_audio","resume_audio"].contains(name),"openWorldHint":false]] }
}
public enum MochiTools {
    public static let maxInstructions = 8000
    public static let maxInstructionBytes = 49152
    public static func boundedText(_ text: String, characters: Int, bytes: Int) -> String {
        var result = "", used = 0
        for character in text.prefix(characters) {
            let size = String(character).utf8.count
            guard used + size <= bytes else { break }
            result.append(character); used += size
        }
        return result
    }
    public static func boundedInstructions(_ text: String) -> String { boundedText(text,characters:maxInstructions,bytes:maxInstructionBytes) }
    public static func validateInstructions(_ value: String) throws {
        guard value.count <= maxInstructions, value.utf8.count <= maxInstructionBytes else { throw AppFailure("Conversation instructions cannot exceed 8,000 characters or 48 KB.") }
    }
    public static func catalog(origin: ToolOrigin) -> [MochiTool] {
        let string: [String:Any] = ["type":"string","maxLength":8000]
        let uuid: [String:Any] = ["type":"string","format":"uuid"]
        let boolean: [String:Any] = ["type":"boolean"]
        let character: [String:Any] = ["type":"string","maxLength":80]
        let coaching: [String:Any] = ["type":"string","enum":CoachingStyle.allCases.map(\.rawValue)]
        let speed: [String:Any] = ["type":"number","minimum":0.25,"maximum":1.5]
        let templateFields: [String:[String:Any]] = ["title":["type":"string","maxLength":160],"description":["type":"string","maxLength":500],"instructions":string,"character_name":character,"coaching":coaching,"speed":speed]
        let limit: [String:Any] = ["type":"integer","minimum":1,"maximum":100]
        func tool(_ name: String, _ description: String, _ props: [String:[String:Any]] = [:], _ required: [String] = [], read: Bool = false, scoped: Bool = true, appScoped: Bool = true) -> MochiTool {
            var p = props, r = required
            if scoped { p["conversation_id"] = uuid; r.append("conversation_id") }
            if !read && origin == .external && appScoped { p["expected_revision"] = string; r.append("expected_revision") }
            return MochiTool(name:name,description:description,properties:p,required:r,readOnly:read)
        }
        var tools = [
            tool("get_session","Read the current conversation ID, revision, instructions, activity, preferences and available audio IDs. Use before mutations.",read:true,scoped:false),
            tool("get_messages","Read the last messages in the current conversation. Missing transcripts are explicitly marked; never infer their content.",["limit":limit],read:true),
            tool("prepare_expression","Prepare an English expression for user review in Help Me Say This. Refuses to replace any existing Help draft. During a voice reply, preparation is saved and opened only after speaking completes; Stop cancels it.",["english":string,"meaning":string],["english"]),
            tool("start_practice","Open practice for a saved expression in this conversation. Recording remains user initiated.",["expression_id":uuid],["expression_id"]),
            tool("save_expression","Save an English expression to My Expressions. Preserve the user's meaning.",["english":string,"meaning":string],["english"]),
            tool("search_expressions","Search saved expressions belonging to the current conversation.",["query":string,"limit":limit],["query"],read:true),
            tool("play_audio","Play existing audio by message or expression ID. No file paths accepted. During a voice reply playback starts after the reply.",["message_id":uuid,"expression_id":uuid]),
            tool("pause_audio","Pause current playback. Only available when audio is already playing."),
            tool("resume_audio","Resume paused playback from its current position; never restart it."),
            tool("seek_audio","Jump within existing audio by ID, in seconds.",["message_id":uuid,"expression_id":uuid,"seconds":["type":"number","minimum":0,"maximum":3600]],["seconds"]),
            tool("set_conversation_preferences","Set this conversation's spoken reply speed or coaching style when requested. natural discusses content, gentle offers occasional corrections, direct offers concise corrections.",["speed":["type":"number","minimum":0.25,"maximum":1.5],"coaching":["type":"string","enum":CoachingStyle.allCases.map(\.rawValue)]])
        ]
        if origin == .external {
            tools += [
                tool("list_conversations","List active conversations; no archived or deleted data.",["limit":limit],read:true,scoped:false),
                tool("create_conversation","Create and open a conversation. template_id copies settings; explicit fields override them. Optional expected_template_revision rejects a changed source. Requires current app revision.",["title":["type":"string","maxLength":160],"instructions":string,"template_id":uuid,"expected_template_revision":string,"character_name":character,"clear_character_name":boolean,"coaching":coaching,"speed":speed],scoped:false),
                tool("open_conversation","Open an active conversation."),
                tool("set_conversation_instructions","Update instructions or character identity. Omitted instructions are preserved. Explicit character_name overrides naming prose; clear_character_name restores default precedence.",["instructions":string,"character_name":character,"clear_character_name":boolean]),
                tool("list_conversation_templates","List built-in/user template metadata, not instructions. Use next_offset and expected_catalog_revision for stable pages.",["query":string,"origin":["type":"string","enum":["all","built_in","user"]],"limit":limit,"offset":["type":"integer","minimum":0,"maximum":100000],"expected_catalog_revision":string],read:true,scoped:false,appScoped:false),
                tool("get_conversation_template","Read a template as data. Recovery fields may be bounded previews with fields_truncated; never resend previews implicitly.",["template_id":uuid],["template_id"],read:true,scoped:false,appScoped:false),
                tool("create_conversation_template","Create a user template with at least one setting: instructions, name, coaching, or speed. No conversation or app revision required.",templateFields,["title"],scoped:false,appScoped:false),
                tool("update_conversation_template","Patch a user template using expected_template_revision. Omitted fields remain unchanged. Built-ins are immutable.",templateFields.merging(["template_id":uuid,"expected_template_revision":string,"clear_speed":boolean,"clear_character_name":boolean]) { _,new in new },["template_id","expected_template_revision"],scoped:false,appScoped:false),
                tool("delete_conversation_template","Delete a user template using its revision. Existing conversations retain their snapshots.",["template_id":uuid,"expected_template_revision":string],["template_id","expected_template_revision"],scoped:false,appScoped:false)
            ]
        }
        if origin == .voice { tools.removeAll { ["pause_audio","resume_audio"].contains($0.name) } }
        return tools
    }
    public static func validate(name: String, arguments: [String:Any], origin: ToolOrigin) throws -> MochiTool {
        guard let tool = catalog(origin:origin).first(where: { $0.name == name }) else { throw AppFailure("This Mochi tool is not available.") }
        guard Set(arguments.keys).isSubset(of:Set(tool.properties.keys)), tool.required.allSatisfy({ arguments[$0] != nil }) else { throw AppFailure("Missing or unexpected tool arguments.") }
        for (key,value) in arguments {
            let schema = tool.properties[key]!
            switch schema["type"] as? String {
            case "string":
                guard let text = value as? String, text.count <= (schema["maxLength"] as? Int ?? 8000) else { throw AppFailure("Invalid text argument: \(key).") }
                if schema["format"] as? String == "uuid", UUID(uuidString:text) == nil { throw AppFailure("Invalid ID: \(key).") }
                if let values = schema["enum"] as? [String], !values.contains(text) { throw AppFailure("Invalid option: \(key).") }
            case "boolean":
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw AppFailure("Invalid boolean: \(key).") }
            case "number", "integer":
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { throw AppFailure("Invalid number: \(key).") }
                let n = number.doubleValue
                guard n.isFinite, n >= ((schema["minimum"] as? NSNumber)?.doubleValue ?? 0), n <= ((schema["maximum"] as? NSNumber)?.doubleValue ?? 100), schema["type"] as? String != "integer" || n.rounded() == n else { throw AppFailure("Number out of range: \(key).") }
            default: throw AppFailure("Invalid tool schema.")
            }
        }
        if let instructions = arguments["instructions"] as? String { try validateInstructions(instructions) }
        for (clear, field) in [("clear_speed","speed"),("clear_character_name","character_name")] {
            if arguments[clear] as? Bool == true, arguments[field] != nil { throw AppFailure("Specify either \(field) or \(clear), not both.") }
        }
        if name == "create_conversation" {
            if arguments["template_id"] == nil && (arguments["expected_template_revision"] != nil || arguments["clear_character_name"] != nil) { throw AppFailure("A template_id is required for template revision or clearing an inherited name.") }
        }
        if ["update_conversation_template","set_conversation_instructions"].contains(name) {
            let fields = ["title","description","instructions","character_name","coaching","speed"]
            guard fields.contains(where:{ arguments[$0] != nil }) || arguments["clear_speed"] as? Bool == true || arguments["clear_character_name"] as? Bool == true else { throw AppFailure("Specify at least one setting to update.") }
        }
        if ["play_audio","seek_audio"].contains(name), (arguments["message_id"] != nil) == (arguments["expression_id"] != nil) { throw AppFailure("Specify exactly one message_id or expression_id.") }
        if ["save_expression","prepare_expression"].contains(name), (arguments["english"] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { throw AppFailure("An English expression is required.") }
        if name == "set_conversation_preferences", arguments["speed"] == nil && arguments["coaching"] == nil { throw AppFailure("Specify speed or coaching.") }
        return tool
    }
    public static func signature(name: String, arguments: [String:Any]) throws -> String {
        SHA256.hash(data:Data(try encode(["name":name,"arguments":arguments]).utf8)).map { String(format:"%02x",$0) }.joined()
    }
    public static func encode(_ value: [String:Any]) throws -> String {
        String(decoding:try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.withoutEscapingSlashes]),as:UTF8.self)
    }
    public static func error(_ message: String) -> [String:Any] { ["ok":false,"error":message] }
}
