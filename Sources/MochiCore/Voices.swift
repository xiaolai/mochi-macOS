import Foundation
import CryptoKit

public enum RealtimeVoice: String, CaseIterable, Codable, Identifiable {
    case marin, cedar, alloy, ash, ballad, coral, echo, sage, shimmer, verse
    public var id: String { rawValue }
    public var name: String { rawValue.capitalized }
}

public enum ReferenceSpeech {
    public static let preview = "I would like a little more time to think. Then I can explain what I mean."
    public static func matches(_ expected: String, _ actual: String) -> Bool {
        func words(_ text: String) -> String {
            text.lowercased().replacingOccurrences(of:"’",with:"'")
                .replacingOccurrences(of:"[^\\p{L}\\p{N}']+",with:" ",options:.regularExpression)
                .trimmingCharacters(in:.whitespacesAndNewlines)
        }
        let normalized = words(expected)
        return !normalized.isEmpty && normalized == words(actual)
    }
    public static func cacheName(text: String, model: String, voice: String, options: OpenAIVoiceOptions = OpenAIVoiceOptions()) -> String {
        let data = try! JSONSerialization.data(withJSONObject:["text":text,"model":model,"voice":voice,"version":"2","speed":options.speed],options:.sortedKeys)
        return "builtin-\(SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()).wav"
    }
}
