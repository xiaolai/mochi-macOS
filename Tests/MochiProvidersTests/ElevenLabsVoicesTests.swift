import MochiKernel
import XCTest

@testable import MochiProviders

/// Finding the learner's own voice from the API key, offline: a fake transport returns recorded-shape JSON.
final class ElevenLabsVoicesTests: XCTestCase {
    private func page(_ voices: String, hasMore: Bool = false) -> Data {
        Data("{\"voices\":[\(voices)],\"has_more\":\(hasMore),\"total_count\":0}".utf8)
    }

    private let mine = #"{"voice_id":"UUtUC3g8vVxJuCtIdwqg","name":"xl-chinese","category":"professional","extra":1}"#
    private let instant = #"{"voice_id":"iwG4Js1BOcBG1KhQTaEa","name":"Me","category":"cloned"}"#

    func testFetchSendsTheKeyToThePersonalVoicesEndpoint() async throws {
        var sent: URLRequest?
        let list = OwnedVoiceList(
            credential: { "test-key" },
            transport: { request in
                sent = request
                return self.page(self.mine)
            })

        _ = try await list.fetch()

        let request = try XCTUnwrap(sent)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "test-key")
        XCTAssertEqual(request.url?.host, "api.elevenlabs.io")
        XCTAssertEqual(request.url?.path, "/v2/voices")
        XCTAssertTrue(request.url?.query?.contains("voice_type=personal") == true)
    }

    func testOnlyTheLearnersOwnCloneCategoriesAreKept() throws {
        let premade = #"{"voice_id":"abc","name":"Library voice","category":"premade"}"#
        let voices = try OwnedVoiceList.decode(page([premade, mine, instant].joined(separator: ",")))

        XCTAssertEqual(voices.map(\.voiceID), ["UUtUC3g8vVxJuCtIdwqg", "iwG4Js1BOcBG1KhQTaEa"])
        XCTAssertEqual(voices.map(\.name), ["xl-chinese", "Me"])
    }

    func testAPageThatHasMoreIsRefusedRatherThanPickedFrom() {
        XCTAssertThrowsError(try OwnedVoiceList.decode(page(mine, hasMore: true))) { error in
            XCTAssertTrue(error.localizedDescription.contains("more voices"))
        }
    }

    func testAnUnreadableListIsRefused() {
        XCTAssertThrowsError(try OwnedVoiceList.decode(Data("<html>".utf8))) { error in
            XCTAssertTrue(error.localizedDescription.contains("could not read"))
        }
    }

    func testOneVoiceIsChosenAutomaticallyAndSeveralAreOffered() throws {
        let one = try OwnedVoiceList.decode(page(mine))
        XCTAssertEqual(VoiceChoice(one), .one(one[0]))

        let several = try OwnedVoiceList.decode(page([mine, instant].joined(separator: ",")))
        XCTAssertEqual(VoiceChoice(several), .many(several))

        XCTAssertEqual(VoiceChoice([]), .none)
    }
}
