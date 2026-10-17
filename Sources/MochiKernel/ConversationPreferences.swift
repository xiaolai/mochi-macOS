import Foundation

public enum CoachingStyle: String, Codable, CaseIterable, Sendable { case natural, gentle, direct }
public struct ConversationPreferences: Codable, Equatable {
    public var speed: Double?
    public var coaching: CoachingStyle = .natural
    /// Conversations saved before languages existed were English, so a missing language reads as English. A stored
    /// language this version does not know reads as English too, and is kept until a language is chosen.
    public var language: ConversationLanguage = .english { didSet { unknownLanguage = nil } }
    /// The stored code of a language this version does not know, written back unchanged so a newer Mochi's choice
    /// survives being opened here; nil once a language is chosen.
    public private(set) var unknownLanguage: String?
    /// The voice replies and greetings use; nil means the conversation voice chosen in Settings. A stored voice this
    /// version does not know is kept, and the Settings voice speaks instead.
    public var voice: String?
    public init() {}
    /// The stored voice when this version supports it.
    public var supportedVoice: RealtimeVoice? { voice.flatMap(RealtimeVoice.init(rawValue:)) }
    public static let speedRange = 0.25...1.5
    public static func isValidSpeed(_ speed: Double) -> Bool { speed.isFinite && speedRange.contains(speed) }
    private enum CodingKeys: String, CodingKey { case speed, coaching, language, voice }
    public init(from decoder: Decoder) throws {
        // Out-of-range or unknown stored values fall back to defaults so an old library still opens; the log says so.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try? c.decodeIfPresent(Double.self, forKey: .speed)
        speed = decoded.flatMap { Self.isValidSpeed($0) ? $0 : nil }
        if c.contains(.speed), (try? c.decodeNil(forKey: .speed)) != true, speed == nil {
            MochiLog.app.notice("A conversation's stored speech speed was invalid; using the default")
        }
        let style = try? c.decodeIfPresent(String.self, forKey: .coaching)
        coaching = style.flatMap(CoachingStyle.init(rawValue:)) ?? .natural
        // A wrong type decodes as nil, so presence is checked separately from the value.
        if c.contains(.coaching), (try? c.decodeNil(forKey: .coaching)) != true,
            style.flatMap(CoachingStyle.init(rawValue:)) == nil
        {
            MochiLog.app.notice("A conversation's stored coaching style was unknown; using natural")
        }
        let code = try? c.decodeIfPresent(String.self, forKey: .language)
        language = code.flatMap(ConversationLanguage.init(rawValue:)) ?? .english
        if c.contains(.language), (try? c.decodeNil(forKey: .language)) != true,
            code.flatMap(ConversationLanguage.init(rawValue:)) == nil
        {
            if let code, ConversationLanguage.isPlausibleCode(code) {
                unknownLanguage = code
                MochiLog.app.notice("A conversation's stored language is unknown to this version; kept, using English")
            } else {
                MochiLog.app.notice("A conversation's stored language was not a language code; using English")
            }
        }
        let storedVoice = try? c.decodeIfPresent(String.self, forKey: .voice)
        voice = storedVoice.flatMap { RealtimeVoice.isPlausibleID($0) ? $0 : nil }
        if c.contains(.voice), (try? c.decodeNil(forKey: .voice)) != true, voice == nil {
            MochiLog.app.notice("A conversation's stored voice was not a voice name; using the Settings voice")
        }
    }
    /// Written as the synthesized encoding was, so the revisions of built-in templates, which hash it, do not change.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(speed, forKey: .speed)
        try c.encode(coaching, forKey: .coaching)
        try c.encode(unknownLanguage ?? language.rawValue, forKey: .language)
        try c.encodeIfPresent(voice, forKey: .voice)
    }
    public func validate() throws {
        if let speed {
            guard Self.isValidSpeed(speed) else {
                throw AppFailure(
                    "Speech speed must be between \(Self.speedRange.lowerBound) and \(Self.speedRange.upperBound).")
            }
        }
    }
}
