import Foundation

public struct OpenAIVoiceOptions: Codable, Equatable {
    public var speed: Double = 1
    public init() {}
    public func validate() throws {
        guard speed.isFinite, (0.25...1.5).contains(speed) else { throw AppFailure("OpenAI speech speed must be between 0.25× and 1.5×.") }
    }
    public func output(voice: String) throws -> [String:Any] {
        try validate()
        guard RealtimeVoice(rawValue:voice) != nil else { throw AppFailure("Choose a supported OpenAI voice.") }
        return ["format":["type":"audio/pcm","rate":24000],"voice":voice,"speed":NSDecimalNumber(string:String(format:"%.2f",locale:Locale(identifier:"en_US_POSIX"),speed))]
    }
}
public struct ElevenVoiceOptions: Codable, Equatable {
    public var stability: Double = 0.5
    public var similarity: Double = 0.75
    public var style: Double = 0
    public var speakerBoost = true
    public init() {}
    public func validate() throws {
        guard [stability,similarity,style].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw AppFailure("ElevenLabs voice settings must be between 0 and 1.") }
    }
    public func payload(speed: Double? = nil) throws -> [String:Any] {
        try validate()
        var result: [String:Any] = ["stability":stability,"similarity_boost":similarity,"style":style,"use_speaker_boost":speakerBoost]
        if let speed {
            guard speed.isFinite, (0.7...1.2).contains(speed) else { throw AppFailure("Pronunciation speed must be between 0.7× and 1.2×.") }
            result["speed"] = speed
        }
        return result
    }
}
public struct PersonalVoiceOptions: Codable, Equatable {
    public var speed: Double = 1
    public var pronunciation = ElevenVoiceOptions()
    public var conversion = ElevenVoiceOptions()
    public init() {}
    public func validate() throws { _ = try pronunciation.payload(speed:speed); try conversion.validate() }
    public func identity(text: String, performer: String, clone: String) -> RenderIdentity {
        var value = RenderIdentity(text:text,performer:performer,clone:clone)
        value.speed = speed; value.stability = pronunciation.stability; value.similarity = pronunciation.similarity
        value.style = pronunciation.style; value.speakerBoost = pronunciation.speakerBoost; value.conversion = conversion
        return value
    }
}
