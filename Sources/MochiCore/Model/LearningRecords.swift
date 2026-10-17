import Foundation
import MochiKernel

/// How a voice message was transcribed: the model and language hint in use when it was recorded. Retries use the same
/// pair, so a later change of setup never makes a recording's evidence disagree with how it was recorded.
public struct RecordingMetadata: Codable, Equatable, Sendable {
    public var model: String
    /// The transcription language hint, as a `ConversationLanguage` raw value or a code a newer Mochi stored; nil when
    /// none was given.
    public var language: String?
    public init(model: String, language: String? = nil) {
        self.model = model
        self.language = language
    }
    var isValid: Bool {
        !model.isEmpty && model.utf8.count <= 100
            && language.map { ConversationLanguage.isPlausibleCode($0) && $0 != ConversationLanguage.match.rawValue }
                ?? true
    }
}

/// How sure the transcriber was of each piece of a transcript, bound to that exact text: the pieces cover it from its
/// first byte to its last with no gap, so a passage can never look checked when part of it was not.
public struct TranscriptEvidence: Codable, Equatable, Sendable {
    public struct Piece: Codable, Equatable, Sendable {
        /// Where the piece ends in the text, in UTF-8 bytes; it starts where the previous one ended.
        public var end: Int
        public var logprob: Double
    }
    public var text: String
    public var pieces: [Piece]
    public static let maximumPieces = 4000

    /// Evidence for `text` from the transcriber's tokens for `raw`, the transcript before it was trimmed into `text`.
    /// Nil unless the tokens' bytes are exactly `raw`, every log probability is finite and at most 0, and the
    /// result is within the limits a library accepts.
    public init?(text: String, raw: String, tokens: [(bytes: [UInt8], logprob: Double)]) {
        guard !text.isEmpty, tokens.count <= Self.maximumPieces,
            tokens.flatMap(\.bytes) == Array(raw.utf8),
            let range = raw.range(of: text)
        else { return nil }
        let lead = raw.utf8.distance(from: raw.startIndex, to: range.lowerBound)
        let length = text.utf8.count
        // String search matches canonically equivalent text; the offsets need the very same bytes.
        guard Array(raw.utf8).dropFirst(lead).prefix(length).elementsEqual(text.utf8) else { return nil }
        var pieces: [Piece] = []
        var offset = 0
        for token in tokens {
            let start = offset - lead
            offset += token.bytes.count
            let end = min(max(offset - lead, 0), length)
            guard token.logprob.isFinite, token.logprob <= 0 else { return nil }
            // A token wholly in the trimmed lead or tail says nothing about the text.
            guard start < length, offset - lead > 0 else { continue }
            if end > (pieces.last?.end ?? 0) {
                pieces.append(Piece(end: end, logprob: token.logprob))
            } else if end > 0, let last = pieces.indices.last {
                // A token inside the same clipped span keeps the lower confidence of the two.
                pieces[last].logprob = min(pieces[last].logprob, token.logprob)
            }
        }
        self.text = text
        self.pieces = pieces
        guard isValid else { return nil }
    }
    public var isValid: Bool {
        guard !text.isEmpty, !pieces.isEmpty, pieces.count <= Self.maximumPieces,
            pieces.last?.end == text.utf8.count
        else { return false }
        var previous = 0
        for piece in pieces {
            guard piece.end > previous, piece.logprob.isFinite, piece.logprob <= 0 else { return false }
            previous = piece.end
        }
        return true
    }
}

/// Where a saved expression stands in spoken review. Stored here; scheduled by spaced review.
public struct ReviewState: Codable, Equatable, Sendable {
    public enum Grade: String, Codable, Sendable { case again, hard, good }
    public struct Graded: Codable, Equatable, Sendable {
        public var date: Date
        public var grade: Grade
        public init(date: Date, grade: Grade) {
            self.date = date
            self.grade = grade
        }
    }
    public static let boxes = 0...5
    public static let maximumGrades = 100
    public var box: Int
    public var due: Date
    public var enrolled: Date
    /// The most recent grades, oldest first.
    public var grades: [Graded]
    public init(box: Int = 0, due: Date, enrolled: Date, grades: [Graded] = []) {
        self.box = box
        self.due = due
        self.enrolled = enrolled
        self.grades = grades
    }
    var isValid: Bool {
        Self.boxes.contains(box) && due.timeIntervalSince1970.isFinite && enrolled.timeIntervalSince1970.isFinite
            && enrolled <= due && grades.count <= Self.maximumGrades
            && grades.allSatisfy { $0.date.timeIntervalSince1970.isFinite }
    }
}
