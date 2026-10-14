import Foundation

/// Where a transcript marks the time, as Messages does: a divider above the first message, the first message of each
/// day, and the first message after a silence of an hour or more, so each sitting of practice is easy to find.
public enum TranscriptTimeline {
    /// A silence this long or longer starts a new stretch of the conversation.
    public static let sessionGap: TimeInterval = 60 * 60

    /// How a divider names its time, by how long ago it was.
    public enum Label: Equatable, Sendable {
        /// "Today 7:03 PM"
        case today
        /// "Yesterday 9:12 AM"
        case yesterday
        /// Within the last week: "Monday 3:40 PM"
        case thisWeek
        /// Anything older, or dated in the future: "Oct 3, 2026 at 3:40 PM"
        case older
    }

    /// The messages that start a new stretch of time, each shown with a divider above it.
    public static func dividerIDs(_ messages: [Message], calendar: Calendar = .current) -> Set<UUID> {
        var ids = Set<UUID>()
        var previous: Date?
        for message in messages {
            if let previous {
                let gap = message.date.timeIntervalSince(previous)
                if gap >= sessionGap || !calendar.isDate(message.date, inSameDayAs: previous) { ids.insert(message.id) }
            } else {
                ids.insert(message.id)
            }
            previous = message.date
        }
        return ids
    }

    public static func label(for date: Date, now: Date, calendar: Calendar = .current) -> Label {
        let days =
            calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day
            ?? -1
        switch days {
        case 0: return .today
        case 1: return .yesterday
        case 2...6: return .thisWeek
        default: return .older
        }
    }
}
