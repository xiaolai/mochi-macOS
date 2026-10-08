import XCTest
@testable import MochiCore
final class PitchTests: XCTestCase {
    func testSilenceHasNoPitch() {
        let points = PitchAnalyzer.analyze(samples: Array(repeating: 0, count: 24000), sampleRate: 24000)
        XCTAssertTrue(points.allSatisfy { $0.hz == nil })
    }
    func testSineAndOctave() {
        func median(_ hz: Double) -> Double {
            let samples = (0..<24000).map { Float(0.5 * sin(2 * .pi * hz * Double($0) / 24000)) }
            let values = PitchAnalyzer.analyze(samples: samples, sampleRate: 24000).compactMap(\.hz).sorted()
            return values.isEmpty ? 0 : values[values.count / 2]
        }
        XCTAssertEqual(median(150), 150, accuracy: 3)
        XCTAssertEqual(median(300), 300, accuracy: 4)
    }
    func testWAVContainer() {
        let wav = PCM.wav(Data(repeating: 0, count: 48000))
        XCTAssertEqual(String(data: wav.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(wav.count, 48044)
    }
}
