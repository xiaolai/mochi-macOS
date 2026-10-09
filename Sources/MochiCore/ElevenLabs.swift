import Foundation
import Security
import CryptoKit
import AVFoundation
import MochiAutomation

public enum PracticeProvider: String, CaseIterable, Identifiable {
    case codex, elevenLabs
    public var id: String { rawValue }
    public var name: String { self == .codex ? "Codex" : "ElevenLabs" }
}

public struct ElevenLabsOptions: Codable, Equatable {
    public var voiceID = ""
    public var voiceName = "My voice"
    public var model = "eleven_multilingual_v2"
    public var speed: Double = 1
    public init() {}
    public func validate() throws {
        guard !voiceID.isEmpty, voiceID.count <= 128,
              voiceID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else {
            throw AppFailure("Enter a valid ElevenLabs voice ID in Settings → Voices.")
        }
        guard ["eleven_multilingual_v2","eleven_flash_v2_5"].contains(model), speed.isFinite, (0.7...1.2).contains(speed) else {
            throw AppFailure("Choose a supported ElevenLabs model and speed between 0.7× and 1.2×.")
        }
    }
    public var label: String { "\(voiceName.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? "Custom voice" : voiceName) · ElevenLabs" }
    public func cacheName(text: String) throws -> String {
        try validate()
        let data = try JSONSerialization.data(withJSONObject:["text":text,"voice":voiceID,"model":model,"speed":NSDecimalNumber(string:String(format:"%.2f",locale:Locale(identifier:"en_US_POSIX"),speed)),"stability":0.5,"similarity_boost":0.75,"style":0,"use_speaker_boost":true,"version":1],options:.sortedKeys)
        return "elevenlabs-\(SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()).mp3"
    }
}

public enum ElevenLabsCredential {
    private static let account = "ELEVENLABS_API_KEY"
    public static func read() throws -> String {
        for service in [AppIdentity.bundleIdentifier] + AppIdentity.legacyBundleIdentifiers {
            let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account,kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary,&result)
            if status == errSecItemNotFound { continue }
            guard status == errSecSuccess, let data = result as? Data, let value = String(data:data,encoding:.utf8), !value.isEmpty else {
                throw AppFailure("Could not read the ElevenLabs key from Keychain. Save it again in Settings → Voices.")
            }
            return value
        }
        throw AppFailure("Save your ElevenLabs API key in Settings → Voices.")
    }
    public static func save(_ value: String) throws {
        let key = value.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !key.isEmpty, key.count < 4096, !key.contains(where: { $0.isNewline }) else { throw AppFailure("Enter a valid ElevenLabs API key.") }
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:AppIdentity.bundleIdentifier,kSecAttrAccount as String:account]
        let attributes = [kSecValueData as String:Data(key.utf8)]
        var status = SecItemUpdate(query as CFDictionary,attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = Data(key.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary,nil)
        }
        guard status == errSecSuccess else { throw AppFailure("Could not save the ElevenLabs key in Keychain.") }
    }
}

public struct ElevenLabsSpeech {
    public var options: ElevenLabsOptions
    public var credential: () throws -> String
    public var transport: (URLRequest) async throws -> Data
    public init(options: ElevenLabsOptions, credential: @escaping () throws -> String = ElevenLabsCredential.read,
                transport: @escaping (URLRequest) async throws -> Data = { try await ServiceHTTP.data($0,provider:"ElevenLabs") }) {
        self.options = options; self.credential = credential; self.transport = transport
    }
    public func referenceAudio(text: String, root: URL, force: Bool = false) async throws -> URL {
        try Task.checkCancellation()
        guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, text.count <= 5000 else { throw AppFailure("Example text must contain between 1 and 5,000 characters.") }
        let destination = root.appendingPathComponent(try options.cacheName(text:text))
        if !force, Self.validAudio(destination) { return destination }
        var request = URLRequest(url:URL(string:"https://api.elevenlabs.io/v1/text-to-speech/\(options.voiceID)?output_format=mp3_44100_128")!)
        request.httpMethod = "POST"
        request.setValue(try credential(),forHTTPHeaderField:"xi-api-key")
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.setValue("audio/mpeg",forHTTPHeaderField:"Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject:["text":text,"model_id":options.model,"voice_settings":["speed":NSDecimalNumber(string:String(format:"%.2f",locale:Locale(identifier:"en_US_POSIX"),options.speed)),"stability":0.5,"similarity_boost":0.75,"style":0,"use_speaker_boost":true]])
        let data = try await transport(request)
        try Task.checkCancellation()
        guard !data.isEmpty, data.count <= 16_000_000 else { throw AppFailure("ElevenLabs returned invalid audio.") }
        let staging = root.appendingPathComponent(".elevenlabs-\(UUID().uuidString).mp3")
        defer { try? FileManager.default.removeItem(at:staging) }
        try data.write(to:staging,options:.atomic)
        guard Self.validAudio(staging) else { throw AppFailure("ElevenLabs returned unreadable audio. Your saved example has not changed.") }
        try Task.checkCancellation()
        try data.write(to:destination,options:.atomic)
        return destination
    }
    private static func validAudio(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size > 0, size <= 16_000_000,
              let file = try? AVAudioFile(forReading:url), file.length > 0,
              Double(file.length) / file.processingFormat.sampleRate <= 65,
              let buffer = AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:AVAudioFrameCount(min(file.length,4096))),
              (try? file.read(into:buffer)) != nil else { return false }
        return buffer.frameLength > 0
    }
}
