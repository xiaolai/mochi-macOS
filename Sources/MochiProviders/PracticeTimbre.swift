import AVFoundation
import CryptoKit
import Foundation
import MochiKernel

/// The learner's own voice for a practice example. OpenAI speaks the sentence; ElevenLabs speech-to-speech then
/// replaces only the voice, so the words, timing and pronunciation of that take are kept.
public struct PracticeTimbre: Equatable, Sendable {
    /// The speech-to-speech model `myvoice` was validated with.
    public static let model = "eleven_multilingual_sts_v2"
    /// Pinned, so a change to the account's saved voice settings cannot move the output. These are the values the
    /// learner's own clone was used with in `myvoice`. Written with sorted keys, as the request body is.
    static let voiceSettingsJSON = #"{"similarity_boost":0.75,"stability":0.5,"style":0,"use_speaker_boost":true}"#
    /// A practice sentence is seconds long; anything longer is refused before a paid request is made.
    public static let maximumSourceSeconds: Double = 60
    static let maximumSourceBytes = 16_000_000

    public let voiceID: String

    public init(voiceID: String) throws {
        let id = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.count <= 128,
            id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
        else {
            throw AppFailure("Enter your ElevenLabs voice ID in Settings → Voices.")
        }
        self.voiceID = id
    }

    /// The cached file for one source take. The source's bytes, the voice and the model decide the name, so a new
    /// take of the sentence never reuses an earlier conversion. The name matches LibraryStore's cache rule,
    /// `elevenlabs-<64 hex digits>.mp3`, so the library keeps and cleans it like other examples.
    func cacheName(sourceDigest: String) -> String {
        let key = [sourceDigest, voiceID, Self.model, Self.voiceSettingsJSON, "remove_background_noise=false", "v1"]
            .joined(separator: "|")
        return "elevenlabs-\(Self.hex(SHA256.hash(data: Data(key.utf8)))).mp3"
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The multipart form ElevenLabs expects: the model, noise removal off, the pinned settings, and the source audio.
    static func multipartBody(boundary: String, source: Data) -> Data {
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(
                Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model_id", model)
        field("remove_background_noise", "false")
        field("voice_settings", voiceSettingsJSON)
        body.append(
            Data(
                "--\(boundary)\r\nContent-Disposition: form-data; name=\"audio\"; filename=\"source.wav\"\r\n"
                    .utf8))
        body.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
        body.append(source)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }
}

/// Converts a spoken example into the learner's voice. Reads the key from the Keychain and sends only the example's
/// audio; the result is cached beside the library, so a repeated request costs nothing.
public struct PracticeTimbreConverter {
    public var credential: () throws -> String
    public var transport: (URLRequest) async throws -> Data

    public init(
        credential: @escaping () throws -> String = ElevenLabsCredential.read,
        transport: @escaping (URLRequest) async throws -> Data = {
            try await ServiceHTTP.data($0, provider: "ElevenLabs")
        }
    ) {
        self.credential = credential
        self.transport = transport
    }

    /// The converted example in `root`. `source` is the spoken WAV that OpenAI produced for the sentence.
    public func convert(source: URL, timbre: PracticeTimbre, root: URL) async throws -> URL {
        try Task.checkCancellation()
        let audio = try Self.readSource(source)
        let destination = root.appendingPathComponent(
            timbre.cacheName(sourceDigest: PracticeTimbre.hex(SHA256.hash(data: audio))))
        if Self.validAudio(destination) { return destination }

        let boundary = "mochi-\(UUID().uuidString)"
        var request = URLRequest(
            url: URL(
                string:
                    "https://api.elevenlabs.io/v1/speech-to-speech/\(timbre.voiceID)?output_format=mp3_44100_128")!)
        request.httpMethod = "POST"
        request.setValue(try credential(), forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.httpBody = PracticeTimbre.multipartBody(boundary: boundary, source: audio)

        let data = try await transport(request)
        try Task.checkCancellation()
        guard !data.isEmpty else { throw AppFailure("ElevenLabs returned no audio. Your example has not changed.") }

        // Validate before the cache is replaced: a bad response must not overwrite a good earlier conversion.
        let staging = root.appendingPathComponent(".elevenlabs-\(UUID().uuidString).mp3")
        defer { try? FileManager.default.removeItem(at: staging) }
        try data.write(to: staging, options: .atomic)
        guard Self.validAudio(staging) else {
            throw AppFailure("ElevenLabs returned unreadable audio. Your saved example has not changed.")
        }
        try Task.checkCancellation()
        try data.write(to: destination, options: .atomic)
        return destination
    }

    private static func readSource(_ url: URL) throws -> Data {
        guard
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
            values.isRegularFile == true, values.isSymbolicLink != true,
            let size = values.fileSize, size > 0, size <= PracticeTimbre.maximumSourceBytes
        else {
            throw AppFailure("The example's audio is missing or too large to convert. Generate the example again.")
        }
        let file = try AVAudioFile(forReading: url)
        guard Double(file.length) / file.processingFormat.sampleRate <= PracticeTimbre.maximumSourceSeconds else {
            throw AppFailure("The example is too long to convert. Shorten its text, then try again.")
        }
        return try Data(contentsOf: url)
    }

    /// A readable, non-empty audio file that is a regular file, not a symbolic link.
    private static func validAudio(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
            values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size > 0,
            size <= PracticeTimbre.maximumSourceBytes,
            let file = try? AVAudioFile(forReading: url), file.length > 0,
            let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(min(file.length, 4096))),
            (try? file.read(into: buffer)) != nil
        else { return false }
        return buffer.frameLength > 0
    }
}
