import MochiAutomation
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
