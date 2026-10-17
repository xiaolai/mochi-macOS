import AVFoundation
import MochiKernel
import XCTest

@testable import MochiProviders

/// The practice-timbre conversion, offline: a fake transport records what would have been sent, so no key, network
/// or paid request is used.
final class PracticeTimbreTests: XCTestCase {
    private final class Calls {
        var requests: [URLRequest] = []
    }

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("timbre-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testVoiceIDIsCheckedBeforeAnythingIsSent() throws {
        XCTAssertThrowsError(try PracticeTimbre(voiceID: "   "))
        XCTAssertThrowsError(try PracticeTimbre(voiceID: "bad/id"))
        XCTAssertThrowsError(try PracticeTimbre(voiceID: String(repeating: "a", count: 129)))
        XCTAssertEqual(try PracticeTimbre(voiceID: " UUtUC3g8vVxJuCtIdwqg ").voiceID, "UUtUC3g8vVxJuCtIdwqg")
    }

    func testRequestGoesToTheClonesSpeechToSpeechEndpointWithPinnedSettings() async throws {
        let calls = Calls()
        let source = try writeSource(try fixtureMP3(), name: "example.mp3")
        let converted = try await converter(calls, reply: { _ in try self.fixtureMP3() }).convert(
            source: source, timbre: try PracticeTimbre(voiceID: "VOICE123"), root: root)

        let request = try XCTUnwrap(calls.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://api.elevenlabs.io/v1/speech-to-speech/VOICE123?output_format=mp3_44100_128")
        XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "test-key")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)

        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"model_id\"\r\n\r\neleven_multilingual_sts_v2\r\n"))
        XCTAssertTrue(body.contains("name=\"remove_background_noise\"\r\n\r\nfalse\r\n"))
        // The values `myvoice` was validated with for the learner's own clone. A change here changes every example.
        XCTAssertTrue(
            body.contains(
                "name=\"voice_settings\"\r\n\r\n{\"similarity_boost\":0.75,\"stability\":0.5,\"style\":0,\"use_speaker_boost\":true}\r\n"))
        XCTAssertTrue(body.contains("name=\"audio\"; filename=\"source.wav\""))
        XCTAssertTrue(FileManager.default.fileExists(atPath: converted.path))
    }

    func testTheCachedFileNameMatchesTheLibraryRule() throws {
        let name = try PracticeTimbre(voiceID: "VOICE123").cacheName(sourceDigest: "abc")
        XCTAssertTrue(name.hasPrefix("elevenlabs-") && name.hasSuffix(".mp3"))
        let digits = name.dropFirst("elevenlabs-".count).dropLast(".mp3".count)
        XCTAssertEqual(digits.count, 64)
        XCTAssertTrue(digits.allSatisfy(\.isHexDigit))
        XCTAssertNotEqual(
            name, try PracticeTimbre(voiceID: "OTHER").cacheName(sourceDigest: "abc"), "a new voice is a new file")
    }

    func testRepeatedConversionOfTheSameTakeIsServedFromTheCache() async throws {
        let calls = Calls()
        let convert = converter(calls, reply: { _ in try self.fixtureMP3() })
        let source = try writeSource(try fixtureMP3(), name: "example.mp3")
        let timbre = try PracticeTimbre(voiceID: "VOICE123")

        let first = try await convert.convert(source: source, timbre: timbre, root: root)
        let second = try await convert.convert(source: source, timbre: timbre, root: root)

        XCTAssertEqual(first, second)
        XCTAssertEqual(calls.requests.count, 1, "a repeated request must not be paid for again")
    }

    func testANewTakeOfTheSentenceIsConvertedAgain() async throws {
        let calls = Calls()
        let convert = converter(calls, reply: { _ in try self.fixtureMP3() })
        let timbre = try PracticeTimbre(voiceID: "VOICE123")

        let first = try await convert.convert(
            source: try writeSource(try silentWAV(seconds: 1.0), name: "first.wav"), timbre: timbre, root: root)
        let second = try await convert.convert(
            source: try writeSource(try silentWAV(seconds: 1.5), name: "second.wav"), timbre: timbre, root: root)

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(calls.requests.count, 2)
    }

    func testUnreadableResponseLeavesNoConversionBehind() async throws {
        let calls = Calls()
        let source = try writeSource(try fixtureMP3(), name: "example.mp3")
        do {
            _ = try await converter(calls, reply: { _ in Data("not audio".utf8) }).convert(
                source: source, timbre: try PracticeTimbre(voiceID: "VOICE123"), root: root)
            XCTFail("unreadable audio must be refused")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("unreadable audio"))
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(leftovers.contains { $0.hasPrefix("elevenlabs-") }, "no example may be cached from a bad reply")
    }

    func testEmptyResponseIsRefused() async throws {
        let calls = Calls()
        await XCTAssertThrowsErrorAsync(
            try await converter(calls, reply: { _ in Data() }).convert(
                source: try writeSource(try fixtureMP3(), name: "example.mp3"), timbre: try PracticeTimbre(voiceID: "VOICE123"), root: root))
    }

    func testMissingKeyFailsBeforeAnyRequest() async throws {
        let calls = Calls()
        await XCTAssertThrowsErrorAsync(
            try await converter(calls, reply: { _ in try self.fixtureMP3() }, key: {
                throw AppFailure(verbatim: "no key")
            }).convert(
                source: try writeSource(try fixtureMP3(), name: "example.mp3"), timbre: try PracticeTimbre(voiceID: "VOICE123"), root: root))
        XCTAssertTrue(calls.requests.isEmpty)
    }

    func testAnOverlongSentenceIsRefusedBeforeAnyRequest() async throws {
        let calls = Calls()
        do {
            _ = try await converter(calls, reply: { _ in try self.fixtureMP3() }).convert(
                source: try writeSource(try silentWAV(seconds: 61, sampleRate: 8_000), name: "long.wav"),
                timbre: try PracticeTimbre(voiceID: "VOICE123"), root: root)
            XCTFail("an overlong sentence must be refused")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("too long"), "refused for another reason: \(error)")
        }
        XCTAssertTrue(calls.requests.isEmpty)
    }

    // MARK: helpers

    private func converter(
        _ calls: Calls, reply: @escaping (URLRequest) throws -> Data, key: @escaping () throws -> String = { "test-key" }
    ) -> PracticeTimbreConverter {
        PracticeTimbreConverter(
            credential: key,
            transport: { request in
                calls.requests.append(request)
                return try reply(request)
            })
    }

    private func fixtureMP3() throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/reference.mp3")
        return try Data(contentsOf: url)
    }

    /// The name sets the reader: AVFoundation chooses a format partly by extension, so an MP3 saved as ".wav" fails.
    private func writeSource(_ bytes: Data, name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    /// A readable silent WAV of the given length, written by AVFoundation so its header is real.
    private func silentWAV(seconds: Double, sampleRate: Double = 8_000) throws -> Data {
        let url = root.appendingPathComponent("silence-\(UUID().uuidString).wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        return try Data(contentsOf: url)
    }

    private func XCTAssertThrowsErrorAsync<T>(
        _ expression: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("expected an error", file: file, line: line)
        } catch {}
    }
}
