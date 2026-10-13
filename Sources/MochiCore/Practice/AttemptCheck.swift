import Foundation

/// A word a speech recognizer returned for a practice attempt, with its confidence (0–1).
public struct RecognizedWord: Equatable, Sendable {
    public let text: String
    public let confidence: Double
    public init(text: String, confidence: Double) {
        self.text = text
        self.confidence = confidence
    }
}

/// Which words of the practice sentence a recognizer caught in an attempt. It assumes the learner was reading the
/// target and checks each target word against what was actually recognized, never the other way round, so a word
/// said as another word shows as that word. It is not a pronunciation score: a recognizer also misses words said
/// well (about 1 in 11 in the measurement behind `uncertainBelow`).
///
/// The rules are English: numbers are spelled out and contractions expanded on both sides before comparing.
public struct AttemptCheck: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case heard
        /// Recognized as different words, shown as recognized.
        case heardAs(String)
        case notCaught
        /// Recognized with low confidence; holds what was recognized.
        case uncertain(String)
    }
    public enum Kind: Sendable { case heard, heardAs, notCaught, uncertain }
    public struct Word: Equatable, Sendable {
        /// The target word as written, punctuation included.
        public let text: String
        public let state: State
    }
    /// Below this confidence a recognized word is shown as uncertain. Chosen on the train half of speechocean762
    /// (Mandarin-speaking learners reading English) for at most 8% wrongly flagged well-read words, and checked on
    /// its test half: 8.8% wrongly flagged, 8.3% uncertain, 11% of badly read words shown as heard (plan E5).
    public static let uncertainBelow = 0.43

    public let words: [Word]
    /// Recognized words that match nothing in the target, in order.
    public let extra: [String]

    public var anythingHeard: Bool {
        words.contains {
            if case .notCaught = $0.state { return false }
            return true
        }
    }
    public func count(_ kind: Kind) -> Int {
        words.filter {
            switch ($0.state, kind) {
            case (.heard, .heard), (.heardAs, .heardAs), (.notCaught, .notCaught), (.uncertain, .uncertain): true
            default: false
            }
        }.count
    }

    public init(target: String, recognized: [RecognizedWord]) {
        let targetWords = target.split(whereSeparator: \.isWhitespace).map(String.init)
            .filter { !Self.units(of: $0).isEmpty }
        // Each word becomes one or more comparison units ("don't" → do, not; "2648" → two, six, four, eight).
        var reference: [(unit: String, word: Int)] = []
        for (index, word) in targetWords.enumerated() {
            reference += Self.units(of: word).map { ($0, index) }
        }
        var hypothesis: [(unit: String, word: Int)] = []
        for (index, word) in recognized.enumerated() {
            hypothesis += Self.units(of: word.text).map { ($0, index) }
        }
        let pairs = Self.align(reference.map(\.unit), hypothesis.map(\.unit))

        var matched = Array(repeating: [Int](), count: targetWords.count)  // recognized words per target word
        var substituted = Array(repeating: false, count: targetWords.count)
        var missing = Array(repeating: false, count: targetWords.count)
        var used = Set<Int>()
        for (r, h) in pairs {
            switch (r, h) {
            case (let r?, let h?):
                let word = reference[r].word
                let source = hypothesis[h].word
                if !matched[word].contains(source) { matched[word].append(source) }
                if reference[r].unit != hypothesis[h].unit { substituted[word] = true }
                used.insert(source)
            case (let r?, nil):
                missing[reference[r].word] = true
            default: break
            }
        }
        words = targetWords.indices.map { index in
            let sources = matched[index]
            guard !sources.isEmpty else { return Word(text: targetWords[index], state: .notCaught) }
            let shown = sources.map { recognized[$0].text }.joined(separator: " ")
            if sources.contains(where: { recognized[$0].confidence < Self.uncertainBelow }) {
                return Word(text: targetWords[index], state: .uncertain(shown))
            }
            if substituted[index] || missing[index] {
                return Word(text: targetWords[index], state: .heardAs(shown))
            }
            return Word(text: targetWords[index], state: .heard)
        }
        extra = recognized.indices.filter { !used.contains($0) && !Self.units(of: recognized[$0].text).isEmpty }
            .map { recognized[$0].text }
    }

    // MARK: - Normalisation

    /// True when two spellings compare as the same words, as `"don't"` and `"do not"` do.
    public static func sameWords(_ first: String, _ second: String) -> Bool {
        first.split(whereSeparator: \.isWhitespace).flatMap { units(of: String($0)) }
            == second.split(whereSeparator: \.isWhitespace).flatMap { units(of: String($0)) }
    }

    private static let ones = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
        "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
    ]
    private static let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
    private static let whole: [String: [String]] = [
        "can't": ["can", "not"], "won't": ["will", "not"], "shan't": ["shall", "not"], "let's": ["let", "us"],
        "ain't": ["am", "not"],
    ]
    private static let endings: [(String, String)] = [
        ("n't", "not"), ("'re", "are"), ("'s", "is"), ("'m", "am"), ("'ve", "have"), ("'ll", "will"), ("'d", "would"),
    ]

    /// Lower-case comparison units for one written or recognized word; empty for punctuation alone.
    static func units(of word: String) -> [String] {
        let cleaned = word.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
        return cleaned.split(separator: "-").flatMap { part -> [String] in
            let token = String(part).trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            guard !token.isEmpty else { return [] }
            if token.allSatisfy(\.isNumber) { return spell(token) }
            if let expanded = whole[token] { return expanded }
            for (ending, replacement) in endings where token.hasSuffix(ending) && token.count > ending.count {
                return [String(token.dropLast(ending.count)), replacement]
            }
            return [token]
        }
    }
    /// Up to two digits as one number; longer runs digit by digit, as codes and phone numbers are read.
    private static func spell(_ digits: String) -> [String] {
        guard digits.count <= 2, let value = Int(digits) else {
            return digits.compactMap { $0.wholeNumberValue.map { ones[$0] } }
        }
        if value < 20 { return [ones[value]] }
        return [tens[value / 10]] + (value % 10 == 0 ? [] : [ones[value % 10]])
    }

    // MARK: - Alignment

    /// Minimum-edit alignment; each pair is (reference index, hypothesis index), nil for a deletion or insertion.
    static func align(_ reference: [String], _ hypothesis: [String]) -> [(Int?, Int?)] {
        let n = reference.count
        let m = hypothesis.count
        var cost = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { cost[i][0] = i }
        for j in 0...m { cost[0][j] = j }
        if n > 0 && m > 0 {
            for i in 1...n {
                for j in 1...m {
                    let substitution = cost[i - 1][j - 1] + (reference[i - 1] == hypothesis[j - 1] ? 0 : 1)
                    cost[i][j] = min(substitution, cost[i - 1][j] + 1, cost[i][j - 1] + 1)
                }
            }
        }
        var pairs: [(Int?, Int?)] = []
        var i = n
        var j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0, cost[i][j] == cost[i - 1][j - 1] + (reference[i - 1] == hypothesis[j - 1] ? 0 : 1) {
                pairs.append((i - 1, j - 1))
                i -= 1
                j -= 1
            } else if i > 0, cost[i][j] == cost[i - 1][j] + 1 {
                pairs.append((i - 1, nil))
                i -= 1
            } else {
                pairs.append((nil, j - 1))
                j -= 1
            }
        }
        return pairs.reversed()
    }
}
