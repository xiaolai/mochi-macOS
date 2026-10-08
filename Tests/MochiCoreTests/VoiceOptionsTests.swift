import XCTest
@testable import MochiCore
final class VoiceOptionsTests: XCTestCase {
    func testProviderPayloadsAndValidation() throws {
        var open = OpenAIVoiceOptions(); open.speed = 0.8
        XCTAssertEqual((try open.output(voice:"marin")["speed"] as? NSNumber)?.doubleValue,0.8)
        let json = String(decoding:try JSONSerialization.data(withJSONObject:open.output(voice:"marin")),as:UTF8.self)
        XCTAssertTrue(json.contains("\"speed\":0.8")); XCTAssertFalse(json.contains("0.800000"))
        open.speed = .nan; XCTAssertThrowsError(try open.validate())
        open.speed = 1.6; XCTAssertThrowsError(try open.validate())
        var eleven = ElevenVoiceOptions(); eleven.style = 0.3; eleven.speakerBoost = false
        XCTAssertEqual(try eleven.payload()["style"] as? Double,0.3)
        XCTAssertEqual(try eleven.payload()["use_speaker_boost"] as? Bool,false)
        XCTAssertNil(try eleven.payload()["speed"])
        XCTAssertEqual(try eleven.payload(speed:0.8)["speed"] as? Double,0.8)
        eleven.stability = -1; XCTAssertThrowsError(try eleven.validate())
    }
    func testCacheTracksEachStageIndependently() {
        let a = RenderIdentity(text:"Hello",performer:PronunciationTarget.jake.rawValue,clone:"one")
        var b = a; b.conversion.style = 0.2
        XCTAssertNotEqual(a.key,b.key); XCTAssertEqual(a.sourceKey,b.sourceKey)
        b = a; b.style = 0.2
        XCTAssertNotEqual(a.key,b.key); XCTAssertNotEqual(a.sourceKey,b.sourceKey)
        var open = OpenAIVoiceOptions(); open.speed = 0.8
        XCTAssertNotEqual(ReferenceSpeech.cacheName(text:"Hello",model:"gpt-realtime",voice:"marin"),ReferenceSpeech.cacheName(text:"Hello",model:"gpt-realtime",voice:"marin",options:open))
    }
    func testElevenTransportReceivesIndependentOptions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        var identity = RenderIdentity(text:"Hello",performer:PronunciationTarget.jake.rawValue,clone:"test-clone")
        identity.speed = 0.8; identity.style = 0.2; identity.conversion.stability = 0.7; identity.conversion.speakerBoost = false
        let renderer = VoiceRenderer(key:{"test"},transport:{ request in
            if request.url!.path.contains("text-to-speech") {
                let object = try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any]
                let settings = object["voice_settings"] as! [String:Any]
                XCTAssertEqual(settings["speed"] as? Double,0.8); XCTAssertEqual(settings["style"] as? Double,0.2)
            } else {
                let body = String(decoding:request.httpBody!,as:UTF8.self)
                let json = body.components(separatedBy:"name=\"voice_settings\"\r\n\r\n")[1].components(separatedBy:"\r\n")[0]
                let settings = try JSONSerialization.jsonObject(with:Data(json.utf8)) as! [String:Any]
                XCTAssertEqual(settings["stability"] as? Double,0.7)
                XCTAssertEqual(settings["use_speaker_boost"] as? Bool,false)
                XCTAssertFalse(body.contains("\"speed\""))
            }
            return Data([1,2,3])
        })
        _ = try await renderer.render(identity,root:root)
    }
}
