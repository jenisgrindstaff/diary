import Foundation

/// The small snapshot the app publishes for its widgets. Kept deliberately tiny
/// (no entry bodies) and shared via an App Group so the widget extension can
/// read it without opening the SwiftData store.
struct DiaryWidgetSummary: Codable, Sendable, Equatable {
    var currentStreak: Int
    var hasEntryToday: Bool
    var latestTitle: String
    var updatedAt: Date

    static let empty = DiaryWidgetSummary(currentStreak: 0, hasEntryToday: false, latestTitle: "", updatedAt: .distantPast)
}

/// Reads and writes the widget summary in the App Group's shared defaults.
/// Falls back to standard defaults if the App Group is not yet entitled, so the
/// app keeps working before the widget target/App Group is wired up.
enum DiaryWidgetStore {
    static let appGroupID = "group.grindstaff.us.Diary"
    private static let key = "widgetSummary"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }

    static func write(_ summary: DiaryWidgetSummary) {
        guard let data = try? JSONEncoder().encode(summary) else { return }
        defaults.set(data, forKey: key)
    }

    static func read() -> DiaryWidgetSummary {
        guard let data = defaults.data(forKey: key),
              let summary = try? JSONDecoder().decode(DiaryWidgetSummary.self, from: data) else {
            return .empty
        }
        return summary
    }
}

/// Pure journaling-streak math, shared so it can be unit-tested independently of
/// SwiftData.
enum DiaryStreak {
    /// Counts consecutive days, ending today (or yesterday), that have at least
    /// one entry. Not having written *yet today* does not break a streak that
    /// ran through yesterday.
    static func current(entryDates: [Date], now: Date = .now, calendar: Calendar = .current) -> Int {
        let days = Set(entryDates.map { calendar.startOfDay(for: $0) })
        guard !days.isEmpty else { return 0 }

        let today = calendar.startOfDay(for: now)
        var anchor = today
        if !days.contains(today) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
                  days.contains(yesterday) else {
                return 0
            }
            anchor = yesterday
        }

        var streak = 0
        var day = anchor
        while days.contains(day) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return streak
    }
}
