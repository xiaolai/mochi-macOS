import Foundation
import MochiCore
import MochiProviders

enum HelpStage { case thought, english, practice }

/// What the word check says about the latest practice attempt.
enum AttemptCheckStatus: Equatable {
    /// No attempt yet, or its check has not finished.
    case none
    case checked(AttemptCheck)
    /// The check needs Apple's speech model, which downloads only when the learner agrees.
    case needsDownload
    case unavailable(WordRecognition.Reason)
    /// Recognition failed; the attempt itself is saved.
    case failed
}

/// A spoken review of due expressions: the meaning is shown, the learner says it, then reveals and grades it.
struct ReviewRun: Equatable {
    /// Expressions in order; one graded Again comes back once more at the end.
    var queue: [UUID]
    var position = 0
    var revealed = false
    var repeated: Set<UUID> = []
    var graded = 0
    var current: UUID? { queue.indices.contains(position) ? queue[position] : nil }
}

/// Help Me Say This, as it is being worked on: the thought, its English, the example and the practice attempts.
/// Each edit is written to the conversation's help draft through `persist`. Changes made inside `restoring` are
/// not written one by one, so a half-restored draft never reaches the disk and a later single write covers them.
@MainActor @Observable final class HelpSession {
    var meaning = "" { didSet { _ = persist(true) } }
    var english = "" { didSet { _ = persist(true) } }
    var stage: HelpStage = .thought
    var thoughtRecording: String? {
        didSet {
            guard !isRestoring else { return }
            if isSavedPractice {
                if oldValue != thoughtRecording { removeRecording(oldValue) }
                return
            }
            if oldValue != thoughtRecording, recognizedThought != nil {
                // One save below covers both fields, so the previous-copy snapshot keeps the state before this change.
                restoring { recognizedThought = nil }
            }
            // A replaced recording is removed only once the draft that no longer names it is saved.
            if persist(false), oldValue != thoughtRecording { removeRecording(oldValue) }
        }
    }
    var recognizedThought: String? { didSet { _ = persist(false) } }
    /// Practising a saved expression rather than working on this conversation's draft.
    var isSavedPractice = false
    var progress: String?
    var clarification: String?
    var expression: PracticeExpression?
    var referencePitch: [PitchPoint] = []
    var attemptPitch: [PitchPoint] = []
    var attemptCheck: AttemptCheckStatus = .none
    /// Set while practice is a spoken review.
    var review: ReviewRun?
    /// True while `restoring` runs.
    @ObservationIgnored private(set) var isRestoring = false
    /// Writes the help draft; `typing` lets typing in an existing draft be written after a pause.
    /// Returns false when nothing was written.
    @ObservationIgnored var persist: (_ typing: Bool) -> Bool = { _ in false }
    /// Removes a recording if nothing references it any more.
    @ObservationIgnored var removeRecording: (String?) -> Void = { _ in }
    /// Forgets the analysis of the latest attempt, when there is a new sentence or none.
    func clearAttempt() {
        attemptPitch = []
        attemptCheck = .none
    }
    /// Makes several changes as one: none of them is written or cleans up a recording on its own.
    func restoring(_ change: () -> Void) {
        let outer = isRestoring
        isRestoring = true
        change()
        isRestoring = outer
    }
}
