import Foundation
import MochiCore

/// One animation of the Codex v2 pet atlas: 8 columns × 11 rows of 192 × 208 cells.
/// Rows and frame timings follow that format, so the bundled sprite sheet is the same file Codex shows.
enum PetPose: Int, CaseIterable {
    case idle = 0
    case waving = 3
    /// The atlas calls it jumping; its moving mouth is what Mochi shows while she speaks.
    case jumping = 4
    case failed = 5
    case waiting = 6
    /// The atlas calls it running: busy with work, which is what thinking looks like.
    case running = 7
    /// Focused attention, shown while Mochi listens.
    case review = 8

    /// How long each frame stays on screen, in seconds.
    var durations: [Double] {
        func steps(_ count: Int, _ each: Double, last: Double) -> [Double] {
            Array(repeating: each, count: count - 1) + [last]
        }
        switch self {
        case .idle: return [0.28, 0.11, 0.11, 0.14, 0.14, 0.32]
        case .waving: return steps(4, 0.14, last: 0.28)
        case .jumping: return steps(5, 0.14, last: 0.28)
        case .failed: return steps(8, 0.14, last: 0.24)
        case .waiting: return steps(6, 0.15, last: 0.26)
        case .running: return steps(6, 0.12, last: 0.22)
        case .review: return steps(6, 0.15, last: 0.28)
        }
    }
    var cycle: Double { durations.reduce(0, +) }

    /// The column showing `elapsed` seconds into a loop of this pose.
    func frame(at elapsed: Double) -> Int {
        guard elapsed.isFinite, elapsed > 0 else { return 0 }
        var remaining = elapsed.truncatingRemainder(dividingBy: cycle)
        for (index, duration) in durations.enumerated() {
            if remaining < duration { return index }
            remaining -= duration
        }
        return durations.count - 1
    }
}

/// What the desktop Mochi reflects. Read from the app on every tick; the pet owns none of this state.
struct PetSituation: Equatable {
    var activity: Activity = .idle
    /// True while the audio playing is Mochi's own voice rather than the user's recording.
    var speaking = false
    var paused = false
    var greeting = false
    /// A failure was reported moments ago.
    var failing = false
    /// The pet has just appeared.
    var arriving = false
    /// Hands-free listening has the microphone open.
    var listening = false

    var pose: PetPose {
        switch activity {
        case .recording: return .review
        case .requestingPermission: return .waiting
        case .generating: return greeting ? .waving : .running
        case .playing: return paused ? .idle : speaking ? .jumping : .review
        case .idle: return failing ? .failed : arriving ? .waving : listening ? .review : .idle
        }
    }
}

/// Where Mochi looks: one of the atlas's 16 directions, clockwise from straight up.
enum PetGaze {
    /// The pointer inside this radius, in points from her centre, leaves her facing forward.
    static let deadzone: Double = 70

    /// The look cell for a pointer at `dx`, `dy` points from her centre (y up), or nil to face forward.
    static func cell(dx: Double, dy: Double) -> (row: Int, column: Int)? {
        guard dx.isFinite, dy.isFinite, (dx * dx + dy * dy).squareRoot() > deadzone else { return nil }
        var degrees = atan2(dx, dy) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        let index = Int((degrees / 22.5).rounded()) % 16
        return (9 + index / 8, index % 8)
    }
}
