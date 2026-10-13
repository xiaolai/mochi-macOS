/// The history sent with Start Again (plan W3): a long conversation keeps its opening, where a role-play scenario is
/// set up, as well as its latest messages, instead of only the latest. Only messages that are sent at all count:
/// a voice message without a transcript never reaches the model.
public enum RestartHistory {
    public static let total = 30
    public static let opening = 10

    public static func select(_ messages: [Message]) -> [Message] {
        let sent = messages.filter { $0.contextText != nil }
        guard sent.count > total else { return sent }
        return Array(sent.prefix(opening)) + Array(sent.suffix(total - opening))
    }
}
