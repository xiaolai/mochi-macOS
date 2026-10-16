import Foundation

/// The language a conversation is held in, or `match` to answer in whatever language the user speaks.
/// Stored by its language code, so the list can grow without changing saved conversations.
public enum ConversationLanguage: String, Codable, CaseIterable, Sendable {
    /// Replies follow the user's own language; there is no language to practise, so no corrections.
    case match
    case english = "en"
    case chinese = "zh"
    case japanese = "ja"
    case korean = "ko"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case italian = "it"
    case portuguese = "pt"
    case dutch = "nl"
    case russian = "ru"
    case polish = "pl"
    case turkish = "tr"
    case arabic = "ar"
    case hindi = "hi"
    case vietnamese = "vi"
    case thai = "th"
    case indonesian = "id"

    /// The language's name in English, which is how instructions to the model name it; nil for `match`.
    public var englishName: String? {
        self == .match ? nil : Locale(identifier: "en").localizedString(forLanguageCode: rawValue) ?? rawValue
    }

    /// The name shown in the interface, in the interface's own language.
    public var displayName: String {
        guard self != .match else { return String(localized: "Match Me") }
        let interface = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        return interface.localizedString(forLanguageCode: rawValue) ?? englishName ?? rawValue
    }

    /// Whether there is one language to practise, which corrections and Help Me Say This need.
    public var isPractised: Bool { self != .match }

    /// The language tag a reading of a text in this language is checked with (numbers, symbols, abbreviations); none
    /// for `match`, which names no language, so a text is then matched as written.
    public var readingTag: String { self == .match ? "" : rawValue }
}
