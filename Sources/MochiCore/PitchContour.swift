import MochiAutomation
import Foundation

/// Display-only processing. Original PitchPoints remain available for inspection.
public enum PitchContour {
    public struct Point: Sendable {
        public let time: Double
        public let value: Double // semitones
        public init(time: Double, value: Double) { self.time = time; self.value = value }
    }
    public struct Curve: Sendable {
        public let start: Point
        public let control1: Point
        public let control2: Point
        public let end: Point
    }

    /// Keep the time axis and centering independent of display smoothing.
    public static func duration(_ points: [PitchPoint]) -> Double {
        max(1,points.map(\.time).filter { $0.isFinite && $0 >= 0 }.max() ?? 0)
    }
    public static func center(_ points: [PitchPoint]) -> Double {
        let values = runs(points,smoothed:false).flatMap { $0.map(\.value) }.sorted()
        return values.isEmpty ? 0 : values[values.count/2]
    }

    public static func runs(_ points: [PitchPoint], smoothed: Bool = true) -> [[Point]] {
        var runs: [[Point]] = [], run: [Point] = []
        func flush() {
            if !run.isEmpty { runs.append(smoothed ? smooth(run) : run); run = [] }
        }
        for point in points {
            guard point.time.isFinite, point.time >= 0,
                  let hz = point.hz, hz.isFinite, hz > 0,
                  let value = point.semitones, value.isFinite else { flush(); continue }
            if let last = run.last, point.time <= last.time || point.time - last.time > 0.045001 { flush() }
            run.append(Point(time:point.time,value:value))
        }
        flush()
        return runs
    }

    private static func smooth(_ points: [Point]) -> [Point] {
        guard points.count > 2 else { return points }
        var values = points.map(\.value)
        // Suppress only an isolated large spike with agreeing adjacent frames.
        for i in 1..<points.count-1 {
            let before = points[i-1].value, after = points[i+1].value, value = points[i].value
            if abs(before-after) < 1, abs(value-before) > 6, abs(value-after) > 6 {
                values[i] = (before+after)/2
            }
        }
        var lower = 0, upper = 0
        return points.indices.map { i in
            let time = points[i].time
            while lower < i && time-points[lower].time > 0.045 { lower += 1 }
            upper = max(upper,i)
            while upper+1 < points.count && points[upper+1].time-time <= 0.045 { upper += 1 }
            // Local Gaussian-weighted linear fit preserves ramps, including at edges.
            var weight = 0.0, x = 0.0, xx = 0.0, y = 0.0, xy = 0.0
            var minimum = values[i], maximum = values[i]
            for j in lower...upper {
                let dt = points[j].time-time, w = exp(-0.5*pow(dt/0.020,2))
                weight += w; x += w*dt; xx += w*dt*dt; y += w*values[j]; xy += w*dt*values[j]
                minimum = min(minimum,values[j]); maximum = max(maximum,values[j])
            }
            let denominator = weight*xx-x*x
            let fitted = denominator > 1e-12 ? (y*xx-x*xy)/denominator : y/weight
            return Point(time:time,value:min(maximum,max(minimum,fitted)))
        }
    }

    /// PCHIP: continuous tangents without the overshoot of unconstrained splines.
    /// Input is a single run with strictly increasing timestamps from `runs`.
    public static func curves(_ points: [Point]) -> [Curve] {
        guard points.count > 1 else { return [] }
        let h = (1..<points.count).map { points[$0].time-points[$0-1].time }
        guard h.allSatisfy({ $0.isFinite && $0 > 0 }), points.allSatisfy({ $0.time.isFinite && $0.value.isFinite }) else { return [] }
        let d = h.indices.map { (points[$0+1].value-points[$0].value)/h[$0] }
        guard d.allSatisfy({ $0.isFinite }) else { return [] }
        var slopes = [Double](repeating:0,count:points.count)
        if points.count == 2 { slopes = [d[0],d[0]] }
        else {
            for i in 1..<points.count-1 where d[i-1]*d[i] > 0 {
                let w1 = 2*h[i]+h[i-1], w2 = h[i]+2*h[i-1]
                slopes[i] = (w1+w2)/(w1/d[i-1]+w2/d[i])
            }
            func endpoint(_ h0: Double, _ h1: Double, _ d0: Double, _ d1: Double) -> Double {
                let slope = ((2*h0+h1)*d0-h0*d1)/(h0+h1)
                if slope*d0 <= 0 { return 0 }
                if d0*d1 <= 0 && abs(slope) > abs(3*d0) { return 3*d0 }
                return slope
            }
            slopes[0] = endpoint(h[0],h[1],d[0],d[1])
            slopes[points.count-1] = endpoint(h[h.count-1],h[h.count-2],d[d.count-1],d[d.count-2])
        }
        return h.indices.map { i in
            Curve(start:points[i],
                  control1:Point(time:points[i].time+h[i]/3,value:points[i].value+slopes[i]*h[i]/3),
                  control2:Point(time:points[i+1].time-h[i]/3,value:points[i+1].value-slopes[i+1]*h[i]/3),
                  end:points[i+1])
        }
    }
}
