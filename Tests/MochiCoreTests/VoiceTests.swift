import XCTest
@testable import MochiCore
final class VoiceTests: XCTestCase {
    func testCatalogAndExactSentence() {
        XCTAssertEqual(RealtimeVoice.allCases.count,10)
        XCTAssertTrue(ReferenceSpeech.matches("I'm ready to start.","I’m ready to start!"))
        XCTAssertFalse(ReferenceSpeech.matches("I worked slowly.","My progress was slow."))
        XCTAssertFalse(ReferenceSpeech.matches("one thing","one thing. Let us begin."))
        XCTAssertFalse(ReferenceSpeech.matches("We'll start.","Well start."))
        XCTAssertEqual(PronunciationTarget.jake.name,"Jake · American English")
    }
    func testProfileDeletionOwnership() {
        let existing = VoiceProfile(name:"Existing",providerID:"abc",createdByApp:false)
        XCTAssertFalse(existing.canDeleteRemote)
        var created = VoiceProfile(name:"Mine",providerID:"xyz",createdByApp:true)
        XCTAssertTrue(created.canDeleteRemote)
        created.requiresVerification = true
        XCTAssertFalse(created.ready)
    }
    func testSampleQuality() {
        let silence = VoiceSampleQuality(samples:[Float](repeating:0,count:24000),rate:24000)
        XCTAssertTrue(silence.warnings.contains(where:{$0.contains("quiet")}))
        XCTAssertFalse(silence.audible)
        let clipped = VoiceSampleQuality(samples:[Float](repeating:1,count:24000),rate:24000)
        XCTAssertTrue(clipped.warnings.contains(where:{$0.contains("clipping")}))
    }
    func testCloneAPIUsesMultipartAndRetainsVerification() async throws {
        let api = ElevenLabsVoices(key:{"test-key"},transport:{ request in
            XCTAssertEqual(request.url?.path,"/v1/voices/add")
            let body = String(decoding:request.httpBody ?? Data(),as:UTF8.self)
            XCTAssertTrue(body.contains("name=\"files\""))
            XCTAssertTrue(body.contains("name=\"name\""))
            XCTAssertTrue(body.contains("My Voice"))
            return Data(#"{"voice_id":"clone_123","requires_verification":true}"#.utf8)
        })
        let result = try await api.create(name:"My Voice",samples:[VoiceUpload(name:"sample.wav",mime:"audio/wav",data:Data([1,2]))])
        XCTAssertEqual(result.id,"clone_123")
        XCTAssertTrue(result.requiresVerification)
    }
    func testDeletionCannotUseArbitraryPath() async {
        let api = ElevenLabsVoices(key:{"test-key"},transport:{_ in XCTFail("Must not send request"); return Data()})
        do { try await api.delete(id:"../other"); XCTFail("Expected rejection") } catch {}
    }
}

extension VoiceTests {
    func testAccountListFiltersClonesAndPreservesVerification() async throws {
        let api = ElevenLabsVoices(key:{"test-key"},transport:{ request in
            XCTAssertEqual(request.url?.path,"/v1/voices")
            return Data(#"{"voices":[{"voice_id":"preset","name":"Jake","category":"premade"},{"voice_id":"mine","name":"My Voice","category":"cloned","voice_verification":{"requires_verification":true,"is_verified":false}},{"voice_id":"unknown","name":"Another","category":"cloned"}]}"#.utf8)
        })
        let voices = try await api.list()
        XCTAssertEqual(voices.count,2)
        XCTAssertTrue(try XCTUnwrap(voices.first(where:{$0.id == "mine"})).requiresVerification)
        XCTAssertFalse(try XCTUnwrap(voices.first(where:{$0.id == "unknown"})).verificationKnown)
    }
    func testCloneRejectsMalformedResponseAndUnsafeMIME() async {
        let api = ElevenLabsVoices(key:{"test-key"},transport:{_ in Data(#"{"voice_id":"../invalid"}"#.utf8)})
        do { _ = try await api.create(name:"Voice",samples:[VoiceUpload(name:"x",mime:"audio/wav",data:Data([1]))]); XCTFail("Must reject malformed ID") } catch {}
        do { _ = try await api.create(name:"Voice",samples:[VoiceUpload(name:"x",mime:"audio/wav\r\nOther: header",data:Data([1]))]); XCTFail("Must reject MIME injection") } catch {}
    }
    func testReferenceCacheSeparatesModelAndVoice() {
        let a = ReferenceSpeech.cacheName(text:"Hello",model:"gpt-realtime",voice:"marin")
        XCTAssertNotEqual(a,ReferenceSpeech.cacheName(text:"Hello",model:"gpt-realtime",voice:"cedar"))
        XCTAssertNotEqual(a,ReferenceSpeech.cacheName(text:"Hello",model:"other-model",voice:"marin"))
        XCTAssertFalse(ReferenceSpeech.matches("   ",""))
    }
}
