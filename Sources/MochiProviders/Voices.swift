import CryptoKit
import Foundation
import SaidGuard

public enum ReferenceSpeech {
    /// Generated speech did not read the requested text exactly, or was cut off; retrying may succeed.
    public struct Mismatch: Error { public init() {} }
    public static let preview = "I would like a little more time to think. Then I can explain what I mean."
    /// Whether `actual`, the model's own transcript of a reading, says exactly `expected`, read with `language`'s rules
    /// (numbers, symbols, abbreviations). The shared said guard: an added, dropped or changed word, number or spoken
    /// symbol does not match, and apostrophes count (`We'll` is not `Well`).
    public static func matches(_ expected: String, _ actual: String, language: String) -> Bool {
        saidMatches(actual, expected, language: language)
    }
    /// The cached file for this reading. It keys on the language and the said guard's version too: a cache hit plays
    /// without a check, so audio a looser guard or another language's rules accepted is generated again.
    public static func cacheName(
        text: String, language: String, model: String, voice: String,
        options: OpenAIVoiceOptions = OpenAIVoiceOptions(),
        saidGuard: Int = saidGuardVersion
    ) -> String {
        // JSON has no non-finite numbers; spelling them out keeps the serialization below infallible.
        let speed: Any = options.speed.isFinite ? options.speed : String(options.speed)
        let data = try! JSONSerialization.data(
            withJSONObject: [
                "text": text, "language": language, "model": model, "voice": voice, "version": "2",
                "saidGuard": saidGuard, "speed": speed,
            ], options: .sortedKeys)
        return "builtin-\(SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()).wav"
    }
}
