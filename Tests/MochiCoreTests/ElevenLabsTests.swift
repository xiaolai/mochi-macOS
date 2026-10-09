import XCTest
@testable import MochiCore

final class ElevenLabsTests: XCTestCase {
    private func options() -> ElevenLabsOptions { var value = ElevenLabsOptions(); value.voiceID = "custom_voice123"; return value }
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true); return url
    }
    func testCacheIncludesEverySynthesisChoiceButNotDisplayName() throws {
        let value = options(), key = try value.cacheName(text:"Hello")
        var changed = value; changed.voiceName = "Renamed"; XCTAssertEqual(try changed.cacheName(text:"Hello"),key)
        changed = value; changed.voiceID = "another"; XCTAssertNotEqual(try changed.cacheName(text:"Hello"),key)
        changed = value; changed.speed = 0.8; XCTAssertNotEqual(try changed.cacheName(text:"Hello"),key)
        changed = value; changed.model = "eleven_flash_v2_5"; XCTAssertNotEqual(try changed.cacheName(text:"Hello"),key)
        XCTAssertNotEqual(try value.cacheName(text:"Goodbye"),key)
        for invalid in ["", "../voice", "id?key=value", "id/name", "非ASCII"] {
            changed = value; changed.voiceID = invalid; XCTAssertThrowsError(try changed.validate())
        }
        for speed in [0.69,1.21,Double.nan,Double.infinity] { changed = value; changed.speed = speed; XCTAssertThrowsError(try changed.validate()) }
    }
    func testDirectRequestCacheAndExplicitRegeneration() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        var value = options(); value.speed = 0.8
        var calls = 0
        let audio = try Data(contentsOf:URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/reference.mp3"))
        let service = ElevenLabsSpeech(options:value,credential:{ "fixture-key" },transport:{ request in
            calls += 1
            XCTAssertEqual(request.httpMethod,"POST")
            XCTAssertEqual(request.url?.host,"api.elevenlabs.io")
            XCTAssertEqual(request.url?.path,"/v1/text-to-speech/custom_voice123")
            XCTAssertEqual(request.value(forHTTPHeaderField:"xi-api-key"),"fixture-key")
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with:request.httpBody!) as? [String:Any])
            XCTAssertEqual(object["text"] as? String,"Hello")
            XCTAssertEqual(object["model_id"] as? String,"eleven_multilingual_v2")
            XCTAssertEqual((object["voice_settings"] as? [String:Any])?["speed"] as? Double,0.8)
            XCTAssertFalse(String(decoding:request.httpBody!,as:UTF8.self).contains("0.800000"))
            return audio
        })
        let first = try await service.referenceAudio(text:"Hello",root:root)
        XCTAssertEqual(calls,1)
        let offline = ElevenLabsSpeech(options:value,credential:{ XCTFail("Cache must not read credentials"); throw CancellationError() },transport:{ _ in XCTFail("Cache must not make requests"); throw CancellationError() })
        let cached = try await offline.referenceAudio(text:"Hello",root:root)
        XCTAssertEqual(first,cached)
        _ = try await service.referenceAudio(text:"Hello",root:root,force:true); XCTAssertEqual(calls,2)
        try Data("broken".utf8).write(to:first)
        _ = try await service.referenceAudio(text:"Hello",root:root); XCTAssertEqual(calls,3)
        XCTAssertEqual(try Data(contentsOf:first),audio)
    }
    func testInvalidResponseAndCancellationPreserveSavedCache() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let value = options(), audio = try Data(contentsOf:URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/reference.mp3"))
        let file = root.appendingPathComponent(try value.cacheName(text:"Hello")); try audio.write(to:file)
        for payload in [Data(),Data("not audio".utf8)] {
            let service = ElevenLabsSpeech(options:value,credential:{ "fixture" },transport:{ _ in payload })
            do { _ = try await service.referenceAudio(text:"Hello",root:root,force:true); XCTFail("Invalid audio accepted") } catch {}
            XCTAssertEqual(try Data(contentsOf:file),audio)
        }
        let service = ElevenLabsSpeech(options:value,credential:{ "fixture" },transport:{ _ in
            withUnsafeCurrentTask { $0?.cancel() }; return audio
        })
        let task = Task { try await service.referenceAudio(text:"Hello",root:root,force:true) }
        do { _ = try await task.value; XCTFail("Cancelled request committed") } catch is CancellationError {} catch { XCTFail("Wrong cancellation error") }
        XCTAssertEqual(try Data(contentsOf:file),audio)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:root.path).contains { $0.hasPrefix(".elevenlabs-") })
    }
}
