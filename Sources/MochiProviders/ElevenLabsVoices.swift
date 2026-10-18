import Foundation
import MochiKernel

/// A voice on the learner's own ElevenLabs account that they made: an instant clone or a professional clone. Library
/// voices are not included, because they belong to ElevenLabs and are not the learner's voice.
public struct OwnedVoice: Equatable, Sendable, Decodable {
    public let voiceID: String
    public let name: String
    public let category: String

    private enum CodingKeys: String, CodingKey {
        case voiceID = "voice_id"
        case name, category
    }
}

/// What the learner's account offers, decided once so the settings view and its tests read the same rule.
public enum VoiceChoice: Equatable, Sendable {
    case none
    case one(OwnedVoice)
    case many([OwnedVoice])

    public init(_ voices: [OwnedVoice]) {
        switch voices.count {
        case 0: self = .none
        case 1: self = .one(voices[0])
        default: self = .many(voices)
        }
    }
}

/// Lists the learner's own voices with their API key, so the voice ID is found rather than typed.
public struct OwnedVoiceList {
    /// The API the list comes from: personal voices only, which keeps the response far below Mochi's response cap.
    static let url = URL(string: "https://api.elevenlabs.io/v2/voices?voice_type=personal&page_size=100")!
    static let ownCategories: Set<String> = ["cloned", "professional"]

    public var credential: () throws -> String
    public var transport: (URLRequest) async throws -> Data

    public init(
        credential: @escaping () throws -> String = ElevenLabsCredential.read,
        transport: @escaping (URLRequest) async throws -> Data = { try await ServiceHTTP.data($0, provider: "ElevenLabs") }
    ) {
        self.credential = credential
        self.transport = transport
    }

    public func fetch() async throws -> [OwnedVoice] {
        var request = URLRequest(url: Self.url)
        request.httpMethod = "GET"
        request.setValue(try credential(), forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await transport(request)
        return try Self.decode(data)
    }

    /// Parses one page. A page that says more follow is refused, because a partial list could hide the right voice.
    static func decode(_ data: Data) throws -> [OwnedVoice] {
        struct Page: Decodable {
            let voices: [OwnedVoice]
            let hasMore: Bool
            private enum CodingKeys: String, CodingKey {
                case voices
                case hasMore = "has_more"
            }
        }
        let page: Page
        do {
            page = try JSONDecoder().decode(Page.self, from: data)
        } catch {
            throw AppFailure("ElevenLabs returned a voice list Mochi could not read.", underlying: error)
        }
        guard !page.hasMore else {
            throw AppFailure("You have more voices than Mochi can list. Enter your voice ID by hand instead.")
        }
        return page.voices.filter { ownCategories.contains($0.category) }
    }
}
