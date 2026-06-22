import Foundation
import SwiftData
import WidgetKit

/// Computes the widget summary from the local entries and publishes it to the
/// shared App Group, then asks WidgetKit to reload. Safe to call when no widget
/// is installed.
@MainActor
enum DiaryWidgetPublisher {
    static func refresh(modelContext: ModelContext, now: Date = .now) {
        let descriptor = FetchDescriptor<DiaryEntry>(predicate: #Predicate { !$0.isTombstoned })
        let entries = (try? modelContext.fetch(descriptor)) ?? []
        DiaryWidgetStore.write(summary(from: entries, now: now))
        WidgetCenter.shared.reloadAllTimelines()
    }

    static func summary(from entries: [DiaryEntry], now: Date = .now, calendar: Calendar = .current) -> DiaryWidgetSummary {
        let dates = entries.map(\.createdAt)
        let today = calendar.startOfDay(for: now)
        return DiaryWidgetSummary(
            currentStreak: DiaryStreak.current(entryDates: dates, now: now, calendar: calendar),
            hasEntryToday: dates.contains { calendar.isDate($0, inSameDayAs: today) },
            latestTitle: entries.max { $0.createdAt < $1.createdAt }?.title ?? "",
            updatedAt: now
        )
    }
}
