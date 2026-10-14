import MochiCore
import XCTest

final class SpeechActivityTests: XCTestCase {
    /// `seconds` of a 220 Hz tone at `decibels` dBFS, or of low noise when `decibels` is nil.
    private func audio(_ seconds: Double, decibels: Float?) -> Data {
        let count = Int(seconds * 24000)
        var data = Data(capacity: count * 2)
        var seed: UInt32 = 12345
        for i in 0..<count {
            let value: Double
            if let decibels {
                let amplitude = pow(10, Double(decibels) / 20) * 32767 * 2.0.squareRoot()
                value = amplitude * sin(2 * .pi * 220 * Double(i) / 24000)
            } else {
                seed = seed &* 1_103_515_245 &+ 12345
                value = Double(Int(seed >> 16) % 61 - 30)  // about -65 dBFS
            }
            var sample = Int16(max(-32767, min(32767, value))).littleEndian
            withUnsafeBytes(of: &sample) { data.append(contentsOf: $0) }
        }
        return data
    }

    func testSpeechAfterRoomNoiseStartsWhereTheLoudFramesBegin() {
        var detector = SpeechActivityDetector()
        XCTAssertNil(detector.feed(audio(1, decibels: nil)))
        XCTAssertLessThan(detector.noiseFloor, -55)
        var started: Int?
        // Fed in uneven pieces, as capture delivers them.
        let speech = audio(0.5, decibels: -25)
        for offset in stride(from: 0, to: speech.count, by: 1234) {
            if let start = detector.feed(speech.subdata(in: offset..<min(offset + 1234, speech.count))) {
                XCTAssertNil(started, "Speech start is reported once")
                started = start
            }
        }
        XCTAssertEqual(started, 24000, "Speech starts where the tone begins, not where it was confirmed")
        XCTAssertEqual(detector.speechStart, 24000)
    }

    func testAShortClickIsNotSpeech() {
        var detector = SpeechActivityDetector()
        detector.feed(audio(1, decibels: nil))
        XCTAssertNil(detector.feed(audio(0.1, decibels: -10)))
        XCTAssertNil(detector.feed(audio(1, decibels: nil)))
        XCTAssertNil(detector.speechStart)
    }

    func testSteadyNoiseRaisesTheFloorInsteadOfCountingAsSpeech() {
        var detector = SpeechActivityDetector()
        detector.feed(audio(0.5, decibels: nil))
        // A fan starts: steady and quieter than speech. Approached in steps, the floor follows it.
        for level: Float in [-56, -52, -48, -45] { XCTAssertNil(detector.feed(audio(2, decibels: level))) }
        XCTAssertGreaterThan(detector.noiseFloor, -50)
        XCTAssertNotNil(detector.feed(audio(0.5, decibels: -20)), "Speech above the fan is still heard")
    }

    func testQuietSpeechBelowTheMinimumIsIgnored() {
        var detector = SpeechActivityDetector()
        detector.feed(audio(1, decibels: nil))
        XCTAssertNil(detector.feed(audio(1, decibels: -53)))
    }

    func testTrailingSilenceCountsFromTheLastLoudFrame() {
        var detector = SpeechActivityDetector()
        detector.feed(audio(1, decibels: nil))
        detector.feed(audio(0.5, decibels: -25))
        XCTAssertEqual(detector.trailingSilence, 0)
        detector.feed(audio(0.6, decibels: nil))
        XCTAssertEqual(detector.trailingSilence, 0.6, accuracy: 0.021)
        detector.feed(audio(0.2, decibels: -25))
        XCTAssertEqual(detector.trailingSilence, 0)
    }

    func testResetForgetsSpeechButKeepsTheFloor() {
        var detector = SpeechActivityDetector()
        detector.feed(audio(1, decibels: nil))
        detector.feed(audio(0.5, decibels: -25))
        let floor = detector.noiseFloor
        detector.reset()
        XCTAssertNil(detector.speechStart)
        XCTAssertEqual(detector.noiseFloor, floor)
        XCTAssertEqual(detector.feed(audio(0.5, decibels: -25)), 36000, "Positions keep counting from the stream start")
    }

    func testRestartAlignsPositionsWithANewStream() {
        var detector = SpeechActivityDetector()
        detector.feed(audio(1, decibels: nil))
        detector.feed(audio(0.5, decibels: -25))
        detector.feed(Data(count: 300))  // a partial frame left pending
        let floor = detector.noiseFloor
        detector.restart()
        XCTAssertNil(detector.speechStart)
        XCTAssertEqual(detector.noiseFloor, floor)
        var preRoll = PreRollBuffer(milliseconds: 700)
        let quiet = audio(0.5, decibels: nil)
        let speech = audio(0.5, decibels: -25)
        preRoll.append(quiet)
        detector.feed(quiet)
        var start: Int?
        for offset in stride(from: 0, to: speech.count, by: 4800) where start == nil {
            let piece = speech.subdata(in: offset..<offset + 4800)
            preRoll.append(piece)
            start = detector.feed(piece)
        }
        XCTAssertEqual(start, 12000, "Counted from the new stream, not the old one")
        // The pre-roll reaches back the full 300 ms before the start, as the turn needs.
        XCTAssertEqual(preRoll.audio(from: 12000 - 7200).count, (preRoll.endSample - 4800) * 2)
        XCTAssertEqual(preRoll.audio(from: 12000 - 7200).prefix(14400), quiet.suffix(14400))
    }

    func testPreRollKeepsTheLatestAudioByPosition() {
        var buffer = PreRollBuffer(milliseconds: 100)
        XCTAssertEqual(buffer.capacity, 4800)
        let first = Data((0..<4000).map { UInt8($0 % 251) })
        let second = Data((0..<2000).map { UInt8($0 % 13) })
        buffer.append(first)
        buffer.append(second)
        XCTAssertEqual(buffer.endSample, 3000)
        // Only the last 2400 samples are kept: asking for older audio gives what is left.
        XCTAssertEqual(buffer.audio(from: 0), (first + second).suffix(4800))
        XCTAssertEqual(buffer.audio(from: 2000), (first + second).suffix(2000))
        XCTAssertEqual(buffer.audio(from: 3000), Data())
        XCTAssertEqual(buffer.audio(from: 9999), Data())
    }
}
