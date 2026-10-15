import XCTest

@testable import MochiApp

/// Hands-free listening falls back to capture without voice processing where voice processing cannot start (issue #1).
final class StreamingCaptureTests: XCTestCase {
    private struct Refused: Error, Equatable { let mode: Bool }

    /// Runs the fallback with an attempt that fails in the modes given, recording the modes it was tried in.
    private func attempts(skipped: Bool = false, failing: Set<Bool>) -> (tried: [Bool], result: Result<Error?, Error>) {
        var tried: [Bool] = []
        let result = Result {
            try StreamingCapture.preferVoiceProcessing(unless: skipped) { voiceProcessing in
                tried.append(voiceProcessing)
                if failing.contains(voiceProcessing) { throw Refused(mode: voiceProcessing) }
            }
        }
        return (tried, result)
    }

    func testVoiceProcessingThatStartsIsUsedAlone() throws {
        let (tried, result) = attempts(failing: [])
        XCTAssertEqual(tried, [true])
        XCTAssertNil(try result.get())
    }

    func testVoiceProcessingThatFailsFallsBackToPlainCaptureAndReportsWhy() throws {
        let (tried, result) = attempts(failing: [true])
        XCTAssertEqual(tried, [true, false])
        XCTAssertEqual(try result.get() as? Refused, Refused(mode: true))
    }

    func testDevicesItFailedOnGoStraightToPlainCapture() throws {
        let (tried, result) = attempts(skipped: true, failing: [true])
        XCTAssertEqual(tried, [false])
        XCTAssertNil(try result.get())
    }

    /// When plain capture fails too, the microphone itself failed: its error surfaces, and nothing tells the caller
    /// to stop trying voice processing on these devices.
    func testPlainCaptureFailureSurfacesItsOwnError() {
        let (tried, result) = attempts(failing: [true, false])
        XCTAssertEqual(tried, [true, false])
        XCTAssertThrowsError(try result.get()) { XCTAssertEqual($0 as? Refused, Refused(mode: false)) }
    }

    func testPlainCaptureFailureSurfacesWhenSkipped() {
        let (tried, result) = attempts(skipped: true, failing: [false])
        XCTAssertEqual(tried, [false])
        XCTAssertThrowsError(try result.get()) { XCTAssertEqual($0 as? Refused, Refused(mode: false)) }
    }
}
