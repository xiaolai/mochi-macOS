import MochiAutomation
import Foundation
public struct PitchPoint: Sendable {
    public var time: Double
    public var hz: Double?
    public var semitones: Double? { hz.map { 12 * log2($0 / 100) } }
    public init(time: Double, hz: Double?) { self.time = time; self.hz = hz }
}
public enum PitchAnalyzer {
    // Normalized autocorrelation with the first strong local maximum to avoid subharmonics.
    public static func analyze(samples: [Float], sampleRate: Double) -> [PitchPoint] {
        guard sampleRate > 0, samples.count > 1024 else { return [] }
        let stride = max(1, Int(sampleRate / 12000))
        let signal = Swift.stride(from: 0, to: samples.count, by: stride).map { Double(samples[$0]) }
        let rate = sampleRate / Double(stride), window = Int(rate * 0.045), hop = Int(rate * 0.015)
        guard signal.count > window else { return [] }
        let low = max(2, Int(rate / 500)), high = min(window / 2, Int(rate / 65))
        return Swift.stride(from: 0, to: signal.count - window, by: hop).map { start in
            let segment = Array(signal[start..<start + window])
            let mean = segment.reduce(0, +) / Double(window)
            let x = segment.map { $0 - mean }
            let rms = sqrt(x.reduce(0) { $0 + $1 * $1 } / Double(window))
            let time = Double(start + window / 2) / rate
            guard rms > 0.008 else { return PitchPoint(time: time, hz: nil) }
            var correlations = [Double](repeating: 0, count: high + 2)
            for lag in low...high {
                var sum = 0.0, a = 0.0, b = 0.0
                for i in 0..<(window - lag) { sum += x[i] * x[i + lag]; a += x[i] * x[i]; b += x[i + lag] * x[i + lag] }
                correlations[lag] = sum / max(1e-10, sqrt(a * b))
            }
            guard let peak = (low + 1..<high).first(where: { correlations[$0] > 0.78 && correlations[$0] >= correlations[$0 - 1] && correlations[$0] >= correlations[$0 + 1] }) else { return PitchPoint(time: time, hz: nil) }
            let l = correlations[peak - 1], m = correlations[peak], r = correlations[peak + 1]
            let delta = abs(l - 2 * m + r) > 1e-8 ? 0.5 * (l - r) / (l - 2 * m + r) : 0
            return PitchPoint(time: time, hz: rate / (Double(peak) + delta))
        }
    }
}
public enum PCM {
    public static func wav(_ pcm: Data, sampleRate: UInt32 = 24000) -> Data {
        var data = Data()
        func text(_ s: String) { data.append(contentsOf: s.utf8) }
        func u32(_ n: UInt32) { var v = n.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func u16(_ n: UInt16) { var v = n.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        text("RIFF"); u32(UInt32(pcm.count + 36)); text("WAVEfmt "); u32(16); u16(1); u16(1); u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16); text("data"); u32(UInt32(pcm.count)); data.append(pcm)
        return data
    }
}
