import SwiftUI
import WidgetKit

struct DiaryWidgetEntry: TimelineEntry {
    let date: Date
    let summary: DiaryWidgetSummary
}

struct DiaryTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> DiaryWidgetEntry {
        DiaryWidgetEntry(
            date: .now,
            summary: DiaryWidgetSummary(currentStreak: 5, hasEntryToday: true, latestTitle: "A good day", updatedAt: .now)
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (DiaryWidgetEntry) -> Void) {
        completion(DiaryWidgetEntry(date: .now, summary: DiaryWidgetStore.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DiaryWidgetEntry>) -> Void) {
        let entry = DiaryWidgetEntry(date: .now, summary: DiaryWidgetStore.read())
        // Refresh just after the next local midnight so "today" and the streak
        // roll over even if the app isn't opened.
        let nextMidnight = Calendar.current.nextDate(
            after: .now,
            matching: DateComponents(hour: 0, minute: 1),
            matchingPolicy: .nextTime
        ) ?? Date(timeIntervalSinceNow: 3600)
        completion(Timeline(entries: [entry], policy: .after(nextMidnight)))
    }
}

struct DiaryStreakWidget: Widget {
    let kind = "DiaryStreakWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: DiaryTimelineProvider()) { entry in
            DiaryWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "diary://new"))
        }
        .configurationDisplayName("Journal Streak")
        .description("Your writing streak with a quick way to add today's entry.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct DiaryWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: DiaryWidgetEntry

    private var streak: Int { entry.summary.currentStreak }

    var body: some View {
        switch family {
        case .accessoryInline:
            Label("\(streak) day streak", systemImage: "flame.fill")

        case .accessoryCircular:
            Gauge(value: Double(min(streak, 30)), in: 0...30) {
                Image(systemName: "flame.fill")
            } currentValueLabel: {
                Text("\(streak)")
            }
            .gaugeStyle(.accessoryCircular)

        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Label("\(streak)-day streak", systemImage: "flame.fill")
                    .font(.headline)
                Text(entry.summary.hasEntryToday ? "Written today" : "Tap to write today")
                    .font(.caption)
            }

        default: // systemSmall
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "flame.fill").foregroundStyle(.orange)
                    Spacer()
                    Text("Diary").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(streak)")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                Text("day streak").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Label(
                    entry.summary.hasEntryToday ? "Written today" : "New entry",
                    systemImage: entry.summary.hasEntryToday ? "checkmark.circle.fill" : "square.and.pencil"
                )
                .font(.caption2)
                .foregroundStyle(entry.summary.hasEntryToday ? Color.green : Color.accentColor)
            }
        }
    }
}
