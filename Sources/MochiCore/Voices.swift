import Foundation
import CryptoKit

public enum RealtimeVoice: String, CaseIterable, Codable, Identifiable {
    case marin, cedar, alloy, ash, ballad, coral, echo, sage, shimmer, verse
    public var id: String { rawValue }
    public var name: String { rawValue.capitalized }
}
public enum PracticeVoiceMode: String, Codable { case builtIn, personal }
public enum PronunciationTarget: String, CaseIterable, Identifiable {
    case jake = "ev2kMR9ZJZZsemuogS5u", grant = "VC6vCXhVaI8BZefRtXZV"
    public var id: String { rawValue }
    public var name: String { self == .jake ? "Jake · American English" : "Grant · British English" }
}
public struct VoiceProfile: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var providerID: String
    public var createdByApp: Bool
    public var requiresVerification = false
    public var samples: [String] = []
    public var ready: Bool { !requiresVerification && !providerID.isEmpty }
    public var canDeleteRemote: Bool { createdByApp && !providerID.isEmpty }
    public init(id: UUID = UUID(), name: String, providerID: String, createdByApp: Bool) {
        self.id = id; self.name = name; self.providerID = providerID; self.createdByApp = createdByApp
    }
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
public struct VoiceSampleQuality {
    public var duration: Double
    public var warnings: [String] = []
    public var audible = false
    public init(samples: [Float], rate: Double) {
        duration = rate > 0 ? Double(samples.count) / rate : 0
        guard !samples.isEmpty else { warnings = ["This recording is empty."]; return }
        let energy = samples.reduce(0.0) { $0 + ($1.isFinite ? Double($1) * Double($1) : 0) } / Double(samples.count)
        audible = energy >= 0.000001
        let quiet = Double(samples.filter { !($0.isFinite) || abs($0) < 0.005 }.count) / Double(samples.count)
        let clipping = Double(samples.filter { $0.isFinite && abs($0) >= 0.99 }.count) / Double(samples.count)
        if quiet > 0.7 { warnings.append("Most of this recording is very quiet. Check the microphone or choose a clearer sample.") }
        if clipping > 0.01 { warnings.append("This recording has clipping. Move farther from the microphone or lower the input level.") }
    }
}
public struct VoiceUpload {
    public var name: String; public var mime: String; public var data: Data
    public init(name: String, mime: String, data: Data) { self.name = name; self.mime = mime; self.data = data }
}
public struct AccountVoice: Identifiable {
    public let id: String; public let name: String; public let requiresVerification: Bool
    public let verificationKnown: Bool
    public init(id: String, name: String, requiresVerification: Bool = false, verificationKnown: Bool = true) { self.id = id; self.name = name; self.requiresVerification = requiresVerification; self.verificationKnown = verificationKnown }
}
public struct CreatedVoice {
    public let id: String; public let requiresVerification: Bool
    public init(id: String, requiresVerification: Bool) { self.id = id; self.requiresVerification = requiresVerification }
}
public protocol VoiceAccountAPI {
    func list() async throws -> [AccountVoice]
    func create(name: String, samples: [VoiceUpload]) async throws -> CreatedVoice
    func delete(id: String) async throws
}
public struct ElevenLabsVoices: VoiceAccountAPI {
    private let key: () throws -> String
    private let transport: (URLRequest) async throws -> Data
    public init(key: @escaping () throws -> String = {
        guard let value = Credentials.read("ELEVENLABS_API_KEY") else { throw AppFailure("Connect ElevenLabs in Settings to set up your voice.") }; return value
    }, transport: @escaping (URLRequest) async throws -> Data = { try await ServiceHTTP.data($0,provider:"ElevenLabs") }) {
        self.key = key; self.transport = transport
    }
    private func request(_ path: String, method: String = "GET") throws -> URLRequest {
        var request = URLRequest(url:URL(string:"https://api.elevenlabs.io\(path)")!)
        request.httpMethod = method; request.setValue(try key(),forHTTPHeaderField:"xi-api-key"); return request
    }
    public func list() async throws -> [AccountVoice] {
        let data = try await transport(request("/v1/voices"))
        guard let object = try JSONSerialization.jsonObject(with:data) as? [String:Any], let voices = object["voices"] as? [[String:Any]] else { throw AppFailure("ElevenLabs returned an invalid voice list.") }
        return voices.compactMap { voice in
            guard let id = voice["voice_id"] as? String, let name = voice["name"] as? String,
                  ["cloned","professional"].contains(voice["category"] as? String ?? "") else { return nil }
            let verification = voice["voice_verification"] as? [String:Any]
            let verified = verification?["is_verified"] as? Bool == true
            let required = verification?["requires_verification"] as? Bool
            return AccountVoice(id:id,name:name,requiresVerification:(required ?? false) && !verified,verificationKnown:required != nil || verified)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public func create(name: String, samples: [VoiceUpload]) async throws -> CreatedVoice {
        let name = name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80, !samples.isEmpty, samples.count <= 10,
              samples.allSatisfy({ !$0.data.isEmpty && $0.data.count <= 10_000_000 && ["audio/wav","audio/mpeg","audio/mp4","audio/flac","audio/aiff"].contains($0.mime) }),
              samples.reduce(0, { $0 + $1.data.count }) <= 30_000_000 else { throw AppFailure("Choose a name and up to ten samples, at most 10 MB each and 30 MB total.") }
        var request = try request("/v1/voices/add",method:"POST")
        let boundary = "Mochi-\(UUID().uuidString)"
        var body = Data()
        func part(_ text: String) { body.append(contentsOf:text.utf8) }
        part("--\(boundary)\r\nContent-Disposition: form-data; name=\"name\"\r\n\r\n\(name)\r\n")
        for (i,sample) in samples.enumerated() {
            let ext = sample.mime == "audio/mpeg" ? "mp3" : sample.mime == "audio/mp4" ? "m4a" : sample.mime == "audio/flac" ? "flac" : sample.mime == "audio/aiff" ? "aiff" : "wav"
            part("--\(boundary)\r\nContent-Disposition: form-data; name=\"files\"; filename=\"sample-\(i).\(ext)\"\r\nContent-Type: \(sample.mime)\r\n\r\n")
            body.append(sample.data); part("\r\n")
        }
        part("--\(boundary)--\r\n")
        request.setValue("multipart/form-data; boundary=\(boundary)",forHTTPHeaderField:"Content-Type"); request.httpBody = body
        let data = try await transport(request)
        guard let object = try JSONSerialization.jsonObject(with:data) as? [String:Any], let id = object["voice_id"] as? String, validID(id) else { throw AppFailure("ElevenLabs did not return a usable voice profile.") }
        return CreatedVoice(id:id,requiresVerification:object["requires_verification"] as? Bool ?? false)
    }
    public func delete(id: String) async throws {
        guard validID(id) else { throw AppFailure("Invalid voice profile.") }
        _ = try await transport(request("/v1/voices/\(id)",method:"DELETE"))
    }
    private func validID(_ id: String) -> Bool { !id.isEmpty && id.count <= 128 && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.union(CharacterSet(charactersIn:"_-" )).contains($0) } }
}
