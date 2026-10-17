import Foundation

/// Finds where speech starts in a live 24 kHz mono 16-bit stream, on the Mac (plan D2, H2). It measures energy in
/// 20 ms frames against a noise floor it learns from the room, and reports speech only once enough loud frames come
/// close together, so a click or a knock does not start sending audio. After speech starts it also measures how long the
/// input has been quiet, which a turn judged on the Mac can end on.
public struct SpeechActivityDetector: Sendable {
    public static let sampleRate = 24000
    public static let frameSamples = 480
    /// A frame counts as loud this far above the noise floor...
    public var marginDecibels: Float = 12
    /// ...and never below this level, so a silent room with a very low floor does not hear breathing as speech.
    public var minimumDecibels: Float = -50
    /// Loud frames needed within `windowFrames` before speech counts as started: 160 ms of the last 240 ms.
    public var speechFrames = 8
    public var windowFrames = 12
    /// The floor rises to the quietest frame of the last 3 s. Speech always dips between syllables within that time;
    /// a steady sound (a fan switching on, a café) never does, so it becomes the floor however suddenly it began, or
    /// however loud the room already was when listening started. Until then it cannot be told from speech that starts
    /// with the stream, so it is heard as speech for that long.
    public var floorFrames = 150
    public private(set) var noiseFloor: Float = -60
    /// Where speech started, in samples since the detector was created or restarted; nil until it has.
    public private(set) var speechStart: Int?
    /// How long the input has been below the speech threshold since the last loud frame, once speech has started.
    public var trailingSilence: TimeInterval {
        Double(quietFramesSinceSpeech * Self.frameSamples) / Double(Self.sampleRate)
    }
    /// The level of the last complete frame, in dBFS.
    public private(set) var level: Float = -80

    private var processed = 0
    private var pending: [Int16] = []
    /// The recent frames' loudness and where each began, oldest first.
    private var window: [(loud: Bool, start: Int)] = []
    private var quietFramesSinceSpeech = 0
    /// The levels of the last `floorFrames` frames, oldest first; empty until the first frame.
    private var levels: [Float] = []

    public init() {}

    /// Starts a new stream at sample 0, as a new `PreRollBuffer` does, keeping the noise floor learnt so far. Call it
    /// whenever the pre-roll is recreated, so the positions this reports stay aligned with the buffer's.
    public mutating func restart() {
        reset()
        processed = 0
        pending = []
    }

    /// Forgets speech, keeping the noise floor learnt so far and the stream's positions.
    public mutating func reset() {
        speechStart = nil
        window = []
        quietFramesSinceSpeech = 0
    }

    /// Feeds little-endian 16-bit samples. Returns the sample index where speech started, once, when it starts.
    @discardableResult public mutating func feed(_ pcm: Data) -> Int? {
        pcm.withUnsafeBytes { raw in
            pending.reserveCapacity(pending.count + raw.count / 2)
            for i in stride(from: 0, to: raw.count - 1, by: 2) {
                pending.append(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i, as: Int16.self)))
            }
        }
        var started: Int?
        var offset = 0
        while pending.count - offset >= Self.frameSamples {
            if let start = consume(pending[offset..<offset + Self.frameSamples]) { started = start }
            offset += Self.frameSamples
        }
        pending.removeFirst(offset)
        return started
    }

    private mutating func consume(_ frame: ArraySlice<Int16>) -> Int? {
        var sum: Double = 0
        for sample in frame { sum += Double(sample) * Double(sample) }
        let rms = (sum / Double(frame.count)).squareRoot() / 32768
        level = rms > 0 ? max(-80, Float(20 * log10(rms))) : -80
        let start = processed
        processed += frame.count
        let loud = level >= max(noiseFloor + marginDecibels, minimumDecibels)
        // The floor falls at once to a quieter frame and rises slowly through quiet ones, never through speech. It
        // also rises to sustained sound, while speech is heard too, so a turn heard over a sound that began during it
        // can still end.
        if level < noiseFloor {
            noiseFloor = level
        } else if !loud {
            noiseFloor += 0.05 * (level - noiseFloor)
        }
        levels.append(level)
        if levels.count > floorFrames { levels.removeFirst() }
        var sustained = false
        if levels.count == floorFrames, let quietest = levels.min(), quietest > noiseFloor {
            noiseFloor = quietest
            sustained = true
        }
        if let speechStart {
            quietFramesSinceSpeech = loud ? 0 : quietFramesSinceSpeech + 1
            if sustained {
                // The sound just learnt as the floor was counted as loud while it lasted; under the new floor it is
                // quiet, so a turn it alone started holds no speech.
                let threshold = max(noiseFloor + marginDecibels, minimumDecibels)
                let run = levels.reversed().prefix { $0 < threshold }.count
                quietFramesSinceSpeech = max(
                    quietFramesSinceSpeech, min(run, (processed - speechStart) / Self.frameSamples))
            }
            return nil
        }
        window.append((loud, start))
        if window.count > windowFrames { window.removeFirst() }
        guard window.filter(\.loud).count >= speechFrames, let first = window.first(where: \.loud) else { return nil }
        speechStart = first.start
        quietFramesSinceSpeech = 0
        return first.start
    }
}

/// The last moments of a stream, so a turn can begin a little before the point where speech was detected. Positions
/// are sample indexes since the stream began, as `SpeechActivityDetector` reports them.
public struct PreRollBuffer: Sendable {
    /// How much it keeps, in bytes of 24 kHz 16-bit audio.
    public let capacity: Int
    private var data = Data()
    /// Samples appended since the stream began.
    public private(set) var endSample = 0
    /// - Parameter milliseconds: how much audio to keep; enough for the pre-roll plus the detector's window.
    public init(milliseconds: Int) {
        capacity = milliseconds * SpeechActivityDetector.sampleRate / 1000 * 2
    }
    public mutating func append(_ pcm: Data) {
        data.append(pcm)
        endSample += pcm.count / 2
        if data.count > capacity { data = Data(data.suffix(capacity)) }
    }
    /// The audio from `sample` to now, or from the oldest sample kept when `sample` is older.
    public func audio(from sample: Int) -> Data {
        let kept = data.count / 2
        let from = min(max(sample, endSample - kept), endSample)
        return Data(data.suffix((endSample - from) * 2))
    }
}
