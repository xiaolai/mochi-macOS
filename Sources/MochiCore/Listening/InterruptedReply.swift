import Foundation

/// What is kept of a reply the learner interrupted (plan H4): the share of its text spoken in the share of its audio
/// that played, so the conversation goes on from what the learner actually heard. Speech is taken to run at an even
/// pace through the text, and the cut moves back to the last word boundary.
public enum InterruptedReply {
    /// Replies heard this far are kept whole: the interruption came at the very end.
    public static let wholeFrom = 0.97

    /// `text` cut to the part heard in the first `fraction` of its audio, ending in an ellipsis; `text` unchanged
    /// when nearly all of it was heard.
    public static func heard(_ text: String, fraction: Double) -> String {
        let whole = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard fraction.isFinite, fraction < wholeFrom, !whole.isEmpty else { return text }
        let count = Int(Double(whole.count) * max(0, fraction))
        var kept = Substring(whole.prefix(count))
        // Mid-word, back off to the last space, or to nothing within the first word. A cut just before a space or a
        // punctuation mark is already at a word's end. Scripts written without spaces (Chinese, Japanese) are cut
        // where they are.
        let next = whole[kept.endIndex]
        let after = whole.index(after: kept.endIndex) < whole.endIndex ? whole[whole.index(after: kept.endIndex)] : nil
        if count < whole.count, !isWordEnd(next, before: after), !isUnspaced(next),
            !(kept.last.map(isUnspaced) ?? false)
        {
            // Back to the end of the last whole word: a space, a dash or other punctuation, or a move into a script
            // written without spaces; never an apostrophe or hyphen inside a word.
            var boundary = kept.startIndex
            var index = kept.endIndex
            while index > kept.startIndex {
                let previous = kept.index(before: index)
                if isWordEnd(kept[previous], before: kept[index...].first ?? next) || isUnspaced(kept[previous]) {
                    boundary = isUnspaced(kept[previous]) ? index : previous
                    break
                }
                index = previous
            }
            kept = kept[..<boundary]
        }
        // `kept` starts where the trimmed text does. Punctuation is dropped only at its end: an opening mark ("¿", "“",
        // "«") belongs to the words kept.
        let ending = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        let scalars = kept.unicodeScalars
        let end = scalars.lastIndex { !ending.contains($0) }.map(scalars.index(after:)) ?? scalars.startIndex
        return String(scalars[..<end]) + "…"
    }

    /// Whether a word ends before `next`. An apostrophe or hyphen with a letter after it is inside a word: "can't".
    private static func isWordEnd(_ next: Character, before after: Character?) -> Bool {
        if "'’-".contains(next), after?.isLetter == true { return false }
        return next.isWhitespace || next.isPunctuation
    }

    /// A character of a script written without spaces between words: Han, kana.
    private static func isUnspaced(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F: return true
            default: return false
            }
        }
    }
}
