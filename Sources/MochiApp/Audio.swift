import Foundation
import AVFoundation
import MochiCore

@MainActor final class AudioController: NSObject, AVAudioPlayerDelegate {
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var completion: (() -> Void)?
    private var failure: (() -> Void)?
    var isRecording: Bool { recorder?.isRecording == true }
    var meter: Float { recorder?.updateMeters(); return recorder?.averagePower(forChannel:0) ?? -80 }
    func permission() async -> Bool {
        if AVCaptureDevice.authorizationStatus(for:.audio) == .authorized { return true }
        return await AVCaptureDevice.requestAccess(for:.audio)
    }
    func record(to url: URL, maxDuration: Double = 60) throws {
        stop()
        let r = try AVAudioRecorder(url:url,settings:[AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:24000,AVNumberOfChannelsKey:1,AVLinearPCMBitDepthKey:16,AVLinearPCMIsFloatKey:false,AVLinearPCMIsBigEndianKey:false])
        r.isMeteringEnabled = true
        guard r.record(forDuration:maxDuration) else { throw AppFailure("Could not start the microphone. Check Sound settings and retry.") }
        recorder = r
    }
    func stopRecording() -> URL? { let url = recorder?.url; recorder?.stop(); recorder = nil; return url }
    func play(url: URL, rate: Float = 1, failed: (() -> Void)? = nil, completed: @escaping () -> Void) throws {
        stop()
        let p = try AVAudioPlayer(contentsOf:url); p.delegate = self; p.enableRate = true; p.rate = rate; completion = completed; failure = failed; player = p
        guard p.play() else { stop(); throw AppFailure("This audio file could not be played.") }
    }
    func stop() { recorder?.stop(); recorder = nil; player?.stop(); player = nil; completion = nil; failure = nil }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in guard self.player === player else { return }; let callback = flag ? self.completion : (self.failure ?? self.completion); self.completion = nil; self.failure = nil; self.player = nil; callback?() }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in guard self.player === player else { return }; let callback = self.failure ?? self.completion; self.completion = nil; self.failure = nil; self.player = nil; callback?() }
    }
}
enum AudioFile {
    static func samples(_ url: URL, maxDuration: Double = 65) throws -> (samples:[Float],rate:Double) {
        let file = try AVAudioFile(forReading:url)
        guard file.length > 0, Double(file.length) / file.processingFormat.sampleRate <= maxDuration else { throw AppFailure("Choose a shorter audio clip for this operation.") }
        guard let buffer = AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:AVAudioFrameCount(file.length)) else { throw AppFailure("Cannot decode this recording.") }
        try file.read(into:buffer)
        guard let channels = buffer.floatChannelData else { throw AppFailure("Unsupported recording format.") }
        let count = Int(buffer.frameLength), channelCount = Int(buffer.format.channelCount)
        var samples = [Float](repeating:0,count:count)
        for c in 0..<channelCount { for i in 0..<count { samples[i] += channels[c][i] / Float(channelCount) } }
        return (samples,buffer.format.sampleRate)
    }
    static func pcm(_ url: URL) throws -> Data {
        let (samples,rate) = try samples(url)
        let count = Int(Double(samples.count) * 24000 / rate)
        guard count >= 2400 else { throw AppFailure("That recording was too short. Speak for at least a moment, then finish.") }
        var data = Data(capacity:count*2)
        for i in 0..<count {
            let position = Double(i) * rate / 24000, index = min(Int(position),samples.count-1), next = min(index+1,samples.count-1)
            let fraction = Float(position - Double(index))
            let mixed = samples[index] * (1-fraction) + samples[next] * fraction
            let sample = mixed.isFinite ? mixed : 0
            var value = Int16(max(-32767,min(32767,Int(sample * 32767)))).littleEndian
            withUnsafeBytes(of:&value) { data.append(contentsOf:$0) }
        }
        return data
    }
    static func pitch(_ url: URL) throws -> [PitchPoint] { let (samples,rate) = try samples(url); return PitchAnalyzer.analyze(samples:samples,sampleRate:rate) }
}
