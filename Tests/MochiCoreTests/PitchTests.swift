import PCM16
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
    func testWAVContainer() throws {
        let wav = try PCM.wav(Data(repeating: 0, count: 48000), rate: PCM.sampleRate)
        XCTAssertEqual(String(data: wav.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(wav.count, 48044)
    }
}

extension PitchTests {
    func testUnrepresentableSampleRatesReturnNoPitchInsteadOfTrapping() {
        XCTAssertTrue(PitchAnalyzer.analyze(samples: tone(200), sampleRate: .infinity).isEmpty)
        XCTAssertTrue(PitchAnalyzer.analyze(samples: tone(200), sampleRate: 1e300).isEmpty)
        XCTAssertTrue(PitchAnalyzer.analyze(samples: tone(200), sampleRate: .nan).isEmpty)
    }

    func testTonesNearNyquistDoNotAliasIntoSpeechPitch() {
        XCTAssertTrue(PitchAnalyzer.analyze(samples: tone(11800), sampleRate: 24000).allSatisfy { $0.hz == nil })
        XCTAssertTrue(
            PitchAnalyzer.analyze(samples: tone(23800, rate: 48000, count: 48000), sampleRate: 48000)
                .allSatisfy { $0.hz == nil })
    }

    /// #87: the decimation filter must remove tones the analysis rate cannot carry, not merely notch some.
    func testTonesAboveTheAnalysisNyquistNeverYieldPitch() {
        for (hz, rate) in [
            (10800.0, 24000.0), (9000, 24000), (10800, 22050), (21000, 44100), (13000, 48000), (40000, 96000),
        ] {
            let voiced = PitchAnalyzer.analyze(samples: tone(hz, rate: rate), sampleRate: rate).compactMap(\.hz)
            XCTAssertTrue(voiced.isEmpty, "\(hz) Hz at \(rate) Hz produced \(voiced.prefix(3))")
        }
    }

    func testSpeechPitchSurvivesTheFilterAtCommonRates() {
        for rate in [44100.0, 48000] {
            let values = PitchAnalyzer.analyze(samples: tone(220, rate: rate), sampleRate: rate).compactMap(\.hz)
                .sorted()
            XCTAssertEqual(values.isEmpty ? 0 : values[values.count / 2], 220, accuracy: 3, "rate \(rate)")
        }
    }

    func testPitchAtBothEndsOfTheRangeIsFound() {
        XCTAssertEqual(medianPitch(65), 65, accuracy: 1)
        XCTAssertEqual(medianPitch(495), 495, accuracy: 3)
        XCTAssertEqual(medianPitch(500, rate: 48000), 500, accuracy: 3)
    }

    func testAnExactlyOneWindowSignalAndShortLowRateClipsAreAnalysed() {
        XCTAssertEqual(PitchAnalyzer.analyze(samples: tone(200, count: 1080), sampleRate: 24000).count, 1)
        let short = PitchAnalyzer.analyze(samples: tone(200, rate: 8000, count: 400), sampleRate: 8000)
        XCTAssertEqual(short.compactMap(\.hz).first ?? 0, 200, accuracy: 2)
    }

    func testDegenerateSampleRatesAndCancellationReturnNoPitch() async {
        XCTAssertEqual(PitchAnalyzer.analyze(samples: Array(repeating: 0.1, count: 2000), sampleRate: 120).count, 0)
        XCTAssertEqual(PitchAnalyzer.analyze(samples: Array(repeating: 0.1, count: 2000), sampleRate: 60).count, 0)
        let tone = (0..<48000).map { Float(sin(2 * Double.pi * 200 * Double($0) / 24000)) * 0.5 }
        let task = Task.detached { () -> Int in
            withUnsafeCurrentTask { $0?.cancel() }
            return PitchAnalyzer.analyze(samples: tone, sampleRate: 24000).count
        }
        let count = await task.value
        XCTAssertEqual(count, 0)
    }

    /// A sine at `hz`; one second long unless `count` says otherwise.
    private func tone(_ hz: Double, rate: Double = 24000, count: Int? = nil) -> [Float] {
        (0..<(count ?? Int(rate))).map { Float(0.5 * sin(2 * .pi * hz * Double($0) / rate)) }
    }

    private func medianPitch(_ hz: Double, rate: Double = 24000) -> Double {
        let values = PitchAnalyzer.analyze(samples: tone(hz, rate: rate, count: Int(rate)), sampleRate: rate)
            .compactMap(\.hz).sorted()
        return values.isEmpty ? 0 : values[values.count / 2]
    }
}
