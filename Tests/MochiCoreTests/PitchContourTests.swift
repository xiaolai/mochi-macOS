import XCTest
@testable import MochiCore

final class PitchContourTests: XCTestCase {
    private func pitch(_ values: [Double]) -> [PitchPoint] {
        values.enumerated().map { PitchPoint(time:Double($0.offset)*0.015,hz:100*pow(2,$0.element/12)) }
    }
    func testSmoothingReducesJitterWithoutFlatteningIntonation() {
        let ideal = (0..<100).map { 4*sin(2 * .pi * 2 * Double($0)*0.015) }
        let noisy = ideal.enumerated().map { $0.element + ($0.offset.isMultiple(of:2) ? 0.35 : -0.35) }
        let input = pitch(noisy)
        let output = PitchContour.runs(input)[0]
        let error = sqrt(zip(output,ideal).reduce(0) { $0+pow($1.0.value-$1.1,2) }/Double(ideal.count))
        XCTAssertLessThan(error,0.35*0.6)
        XCTAssertGreaterThan(output.map(\.value).max()!,3.8)
        XCTAssertLessThan(output.map(\.value).min()!,-3.8)
        XCTAssertEqual(input[0].semitones!,noisy[0],accuracy:1e-10)
        let raw = PitchContour.runs(input,smoothed:false)[0]
        for (point,value) in zip(raw,noisy) { XCTAssertEqual(point.value,value,accuracy:1e-10) }
    }
    func testRampsKeepTimingAndSlopeIncludingEndpoints() {
        let values = (0..<30).map { 2+Double($0)*0.3 }
        for (point,value) in zip(PitchContour.runs(pitch(values))[0],values) {
            XCTAssertEqual(point.value,value,accuracy:1e-9)
        }
    }
    func testSingleFrameOctaveSpikeIsRemovedButSustainedChangeRemains() {
        var values = [Double](repeating:3,count:30); values[15] = 15
        XCTAssertEqual(PitchContour.runs(pitch(values))[0][15].value,3,accuracy:1e-9)
        values = Array(repeating:3,count:20)+Array(repeating:15,count:20)
        let smoothed = PitchContour.runs(pitch(values))[0]
        XCTAssertEqual(smoothed[5].value,3,accuracy:1e-9)
        XCTAssertEqual(smoothed[30].value,15,accuracy:1e-9)
        XCTAssertTrue(smoothed.allSatisfy { (3-1e-9...15+1e-9).contains($0.value) })
    }
    func testVoicelessAndInvalidFramesStayGaps() {
        let input = [PitchPoint(time:0,hz:150),PitchPoint(time:0.015,hz:151),PitchPoint(time:0.030,hz:nil),PitchPoint(time:0.045,hz:200),PitchPoint(time:0.060,hz:0),PitchPoint(time:0.075,hz:.nan),PitchPoint(time:0.090,hz:-100),PitchPoint(time:0.105,hz:.infinity),PitchPoint(time:0.120,hz:210)]
        let runs = PitchContour.runs(input)
        XCTAssertEqual(runs.map(\.count),[2,1,1])
        XCTAssertEqual(runs[1][0].time,0.045)
        XCTAssertEqual(runs[2][0].time,0.120)
        XCTAssertEqual(runs.flatMap(PitchContour.curves).count,1)
    }
    func testMissingTimestampsAndOutOfOrderSamplesCannotBeBridged() {
        let input = [PitchPoint(time:0,hz:150),PitchPoint(time:0.015,hz:160),PitchPoint(time:0.20,hz:170),PitchPoint(time:0.20,hz:180),PitchPoint(time:.nan,hz:200),PitchPoint(time:0.23,hz:190)]
        XCTAssertEqual(PitchContour.runs(input).map(\.count),[2,1,1,1])
        XCTAssertTrue(PitchContour.runs([]).isEmpty)
        XCTAssertTrue(PitchContour.curves([]).isEmpty)
    }
    func testCubicCurvesNeverOvershootAndHaveContinuousTangents() {
        let points = zip([0.0,0.015,0.030,0.050,0.065,0.080,0.095],[0.0,1,1,6,-2,-1,4]).map { PitchContour.Point(time:$0.0,value:$0.1) }
        let curves = PitchContour.curves(points)
        XCTAssertEqual(curves.count,points.count-1)
        for curve in curves {
            for i in 0...100 {
                let t = Double(i)/100, u = 1-t
                let y = u*u*u*curve.start.value+3*u*u*t*curve.control1.value+3*u*t*t*curve.control2.value+t*t*t*curve.end.value
                XCTAssertGreaterThanOrEqual(y,min(curve.start.value,curve.end.value)-1e-9)
                XCTAssertLessThanOrEqual(y,max(curve.start.value,curve.end.value)+1e-9)
            }
        }
        for i in 1..<curves.count {
            let before = curves[i-1], after = curves[i]
            let incoming = (before.end.value-before.control2.value)/(before.end.time-before.control2.time)
            let outgoing = (after.control1.value-after.start.value)/(after.control1.time-after.start.time)
            XCTAssertEqual(incoming,outgoing,accuracy:1e-8)
        }
    }
    func testTwoPointsAreLinearAndInvalidCurveInputIsRejected() {
        let points = [PitchContour.Point(time:0,value:1),PitchContour.Point(time:0.015,value:4)]
        let curve = PitchContour.curves(points)[0]
        XCTAssertEqual(curve.control1.value,2,accuracy:1e-9)
        XCTAssertEqual(curve.control2.value,3,accuracy:1e-9)
        XCTAssertTrue(PitchContour.curves([points[0],points[0]]).isEmpty)
        XCTAssertTrue(PitchContour.curves([points[0],PitchContour.Point(time:Double.leastNonzeroMagnitude,value:4)]).isEmpty)
    }
}

extension PitchContourTests {
    func testDurationIncludesTrailingUnvoicedFramesAndCenterUsesRawValues() {
        let input = [PitchPoint(time:0,hz:100),PitchPoint(time:0.015,hz:400),PitchPoint(time:0.03,hz:100),PitchPoint(time:2,hz:nil)]
        XCTAssertEqual(PitchContour.duration(input),2)
        XCTAssertEqual(PitchContour.center(input),0,accuracy:1e-10)
        XCTAssertEqual(PitchContour.duration([PitchPoint(time:.infinity,hz:nil),PitchPoint(time:.nan,hz:nil)]),1)
    }
}
