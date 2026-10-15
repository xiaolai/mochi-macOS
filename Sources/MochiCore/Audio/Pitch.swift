import Accelerate
import Foundation

public struct PitchPoint: Sendable {
    public var time: Double
    public var hz: Double?
    public var semitones: Double? { hz.map { 12 * log2($0 / 100) } }
    public init(time: Double, hz: Double?) {
        self.time = time
        self.hz = hz
    }
}
public enum PitchAnalyzer {
    // Normalized autocorrelation with the first strong local maximum to avoid subharmonics.
    public static func analyze(samples: [Float], sampleRate: Double) -> [PitchPoint] {
        guard sampleRate.isFinite, sampleRate > 0, sampleRate / 12000 < Double(Int.max), !samples.isEmpty else {
            return []
        }
        let stride = max(1, Int(sampleRate / 12000))
        let rate = sampleRate / Double(stride)
        let window = Int(rate * 0.045)
        let hop = Int(rate * 0.015)
        let low = max(2, Int(rate / 500))
        let high = min(window / 2, Int((rate / 65).rounded(.up)))
        // Very low sample rates leave no usable lag range or hop; such audio has no measurable speech pitch.
        guard hop > 0, high > low + 1, (samples.count - 1) / stride + 1 >= window else { return [] }
        let signal = decimate(samples, by: stride)
        func point(at start: Int) -> PitchPoint {
            var x = Array(signal[start..<start + window])
            var mean = 0.0
            vDSP_meanvD(x, 1, &mean, vDSP_Length(window))
            var offset = -mean
            vDSP_vsaddD(x, 1, &offset, &x, 1, vDSP_Length(window))
            var energy = 0.0
            vDSP_dotprD(x, 1, x, 1, &energy, vDSP_Length(window))
            let rms = sqrt(energy / Double(window))
            let time = Double(start + window / 2) / rate
            guard rms > 0.008 else { return PitchPoint(time: time, hz: nil) }
            // head[k] is the energy of x[0..<k]: the first factor of every lag's normalisation. The second factor is
            // the energy of the lag's tail, the total less the energy before it.
            var head = [Double](repeating: 0, count: window + 1)
            for i in 0..<window { head[i + 1] = head[i] + x[i] * x[i] }
            // Neighbours outside low...high are computed too, so peaks at either end of the range count.
            var correlations = [Double](repeating: 0, count: high + 2)
            x.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                for lag in (low - 1)...(high + 1) {
                    var sum = 0.0
                    vDSP_dotprD(base, 1, base + lag, 1, &sum, vDSP_Length(window - lag))
                    let a = head[window - lag]
                    let b = head[window] - head[lag]
                    correlations[lag] = sum / max(1e-10, sqrt(a * b))
                }
            }
            guard
                let peak = (low...high).first(where: {
                    correlations[$0] > 0.78 && correlations[$0] >= correlations[$0 - 1]
                        && correlations[$0] >= correlations[$0 + 1]
                })
            else { return PitchPoint(time: time, hz: nil) }
            let l = correlations[peak - 1]
            let m = correlations[peak]
            let r = correlations[peak + 1]
            let delta = abs(l - 2 * m + r) > 1e-8 ? 0.5 * (l - r) / (l - 2 * m + r) : 0
            return PitchPoint(time: time, hz: rate / (Double(peak) + delta))
        }
        var points: [PitchPoint] = []
        for start in Swift.stride(from: 0, through: signal.count - window, by: hop) {
            if Task.isCancelled { return [] }
            points.append(point(at: start))
        }
        return points
    }
    /// Keeps every `factor`th sample after a Blackman-windowed sinc low-pass (about 74 dB of stopband attenuation)
    /// whose stopband starts at 80% of the new Nyquist frequency. Tones the analysis rate cannot carry, or that sit
    /// so close to its Nyquist frequency that they beat like a voice, are removed instead of read as speech pitch.
    /// Runs even without decimation for that reason. Samples beyond either end count as silence.
    static func decimate(_ samples: [Float], by factor: Int) -> [Double] {
        let half = 28 * factor
        let cutoff = 0.35 / Double(factor)
        var taps = (-half...half).map { k -> Float in
            let x = Double(k)
            let sinc = k == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * x) / (.pi * x)
            let phase = .pi * Double(k + half) / Double(half)
            return Float(sinc * (0.42 - 0.5 * cos(phase) + 0.08 * cos(2 * phase)))
        }
        let gain = taps.reduce(0, +)
        taps = taps.map { $0 / gain }
        let count = (samples.count - 1) / factor + 1
        var padded = [Float](repeating: 0, count: (count - 1) * factor + taps.count)
        padded.replaceSubrange(half..<half + samples.count, with: samples)
        var output = [Float](repeating: 0, count: count)
        vDSP_desamp(padded, vDSP_Stride(factor), taps, &output, vDSP_Length(count), vDSP_Length(taps.count))
        return output.map(Double.init)
    }
}
public enum PCM {
    public static func wav(_ pcm: Data, sampleRate: UInt32 = 24000) -> Data {
        var data = Data()
        func text(_ s: String) { data.append(contentsOf: s.utf8) }
        func u32(_ n: UInt32) {
            var v = n.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        func u16(_ n: UInt16) {
            var v = n.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        text("RIFF")
        u32(UInt32(pcm.count + 36))
        text("WAVEfmt ")
        u32(16)
        u16(1)
        u16(1)
        u32(sampleRate)
        u32(sampleRate * 2)
        u16(2)
        u16(16)
        text("data")
        u32(UInt32(pcm.count))
        data.append(pcm)
        return data
    }
}
