import Foundation
import SwiftData

@Model
final class DiaryEntry {
    @Attribute(.unique) var id: String
    var createdAt: Date
    var updatedAt: Date
    var serverRevision: String
    var title: String
    var excerpt: String
    var bodyMarkdown: String
    var sourcePath: String
    var tagsStorage: String
    var peopleStorage: String
    var subjectDetailsStorage: String = "[]"
    var contextStorage: String = "{}"
    var searchTextStorage: String = ""
    var isTombstoned: Bool
    var syncedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \DiaryAttachment.entry)
    var attachments: [DiaryAttachment]

    init(
        id: String,
        createdAt: Date,
        updatedAt: Date,
        serverRevision: String,
        title: String,
        excerpt: String,
        bodyMarkdown: String,
        sourcePath: String = "",
        tags: [String] = [],
        people: [String] = [],
        subjectDetails: [DiarySubjectDetail] = [],
        context: DiaryEntryContext = .empty,
        isTombstoned: Bool = false,
        syncedAt: Date? = nil,
        attachments: [DiaryAttachment] = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.serverRevision = serverRevision
        self.title = title
        self.excerpt = excerpt
        self.bodyMarkdown = bodyMarkdown
        self.sourcePath = sourcePath
        self.tagsStorage = Self.encodeStrings(tags)
        self.peopleStorage = Self.encodeStrings(people)
        self.subjectDetailsStorage = Self.encodeSubjectDetails(subjectDetails)
        self.contextStorage = Self.encodeContext(context)
        self.searchTextStorage = Self.searchText(
            title: title,
            excerpt: excerpt,
            bodyMarkdown: bodyMarkdown,
            tags: tags,
            people: people,
            subjectDetails: subjectDetails,
            context: context
        )
        self.isTombstoned = isTombstoned
        self.syncedAt = syncedAt
        self.attachments = attachments
    }
}

extension DiaryEntry {
    var tags: [String] {
        get { Self.decodeStrings(tagsStorage) }
        set { tagsStorage = Self.encodeStrings(newValue) }
    }

    var people: [String] {
        get { Self.decodeStrings(peopleStorage) }
        set { peopleStorage = Self.encodeStrings(newValue) }
    }

    var subjectDetails: [DiarySubjectDetail] {
        get { Self.decodeSubjectDetails(subjectDetailsStorage) }
        set { subjectDetailsStorage = Self.encodeSubjectDetails(newValue) }
    }

    var entryContext: DiaryEntryContext {
        get { Self.decodeContext(contextStorage) }
        set { contextStorage = Self.encodeContext(newValue) }
    }

    func refreshSearchText() {
        searchTextStorage = Self.searchText(
            title: title,
            excerpt: excerpt,
            bodyMarkdown: bodyMarkdown,
            tags: tags,
            people: people,
            subjectDetails: subjectDetails,
            context: entryContext
        )
    }

    var displayTitle: String {
        if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }

        return createdAt.formatted(date: .abbreviated, time: .omitted)
    }

    var displayExcerpt: String {
        if !excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return excerpt
        }

        return bodyMarkdown
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func encodeStrings(_ values: [String]) -> String {
        guard let data = try? JSONEncoder().encode(values),
              let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }

        return string
    }

    private static func decodeStrings(_ value: String) -> [String] {
        guard let data = value.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }

        return values
    }

    private static func encodeSubjectDetails(_ values: [DiarySubjectDetail]) -> String {
        guard let data = try? JSONEncoder().encode(values),
              let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }

        return string
    }

    private static func decodeSubjectDetails(_ value: String) -> [DiarySubjectDetail] {
        guard let data = value.data(using: .utf8),
              let values = try? JSONDecoder().decode([DiarySubjectDetail].self, from: data) else {
            return []
        }

        return values
    }

    private static func encodeContext(_ value: DiaryEntryContext) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }

        return string
    }

    private static func decodeContext(_ value: String) -> DiaryEntryContext {
        guard let data = value.data(using: .utf8),
              let context = try? JSONDecoder().decode(DiaryEntryContext.self, from: data) else {
            return .empty
        }

        return context
    }

    private static func searchText(
        title: String,
        excerpt: String,
        bodyMarkdown: String,
        tags: [String],
        people: [String],
        subjectDetails: [DiarySubjectDetail],
        context: DiaryEntryContext
    ) -> String {
        let subjectText = subjectDetails
            .flatMap { [$0.name, $0.label, $0.ageText, $0.rawText] }
            .joined(separator: " ")
        return ([title, excerpt, bodyMarkdown, tags.joined(separator: " "), people.joined(separator: " "), subjectText, context.searchText])
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

struct DiarySubjectDetail: Codable, Hashable, Sendable {
    var name: String
    var label: String
    var ageText: String
    var rawText: String

    var displayText: String {
        if !ageText.isEmpty {
            return ageText
        }

        if !rawText.isEmpty {
            return rawText
        }

        return label
    }

    var stableID: String {
        [name, label, ageText, rawText].joined(separator: "|")
    }
}

struct DiaryEntryContext: Codable, Hashable, Sendable {
    var location: DiaryLocationContext? = nil
    var weather: DiaryWeatherContext? = nil
    var activity: DiaryActivityContext? = nil
    var source: String? = nil

    static let empty = DiaryEntryContext()

    var isEmpty: Bool {
        location == nil
        && weather == nil
        && activity == nil
        && (source ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var summaryChips: [String] {
        var chips: [String] = []
        if let label = location?.label, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chips.append(label)
        }
        if let weather {
            var text = weather.condition ?? ""
            if let temperature = weather.temperatureF {
                let temp = temperature.formatted(.number.precision(.fractionLength(0))) + "F"
                text = text.isEmpty ? temp : "\(text) \(temp)"
            }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                chips.append(text)
            }
        }
        if let activity {
            if let steps = activity.steps {
                chips.append("\(steps) steps")
            }
            if let exerciseMinutes = activity.exerciseMinutes {
                chips.append("\(exerciseMinutes) exercise min")
            }
            chips.append(contentsOf: activity.workouts.map(\.type).filter { !$0.isEmpty })
        }
        return chips
    }

    var searchText: String {
        var values: [String] = [source ?? ""]
        if let location {
            values.append(contentsOf: [location.label ?? "", location.precision ?? ""])
        }
        if let weather {
            values.append(contentsOf: [
                weather.provider ?? "",
                weather.condition ?? "",
                weather.symbol ?? "",
                weather.precipitation ?? "",
                weather.attribution ?? ""
            ])
        }
        if let activity {
            values.append(contentsOf: ["activity", "steps", "exercise"])
            values.append(contentsOf: activity.workouts.map(\.type))
        }
        return values.joined(separator: " ")
    }
}

struct DiaryLocationContext: Codable, Hashable, Sendable {
    var label: String? = nil
    var latitude: Double? = nil
    var longitude: Double? = nil
    var precision: String? = nil
    var capturedAt: Date? = nil

    private enum CodingKeys: String, CodingKey {
        case label
        case latitude
        case longitude
        case precision
        case capturedAt = "captured_at"
    }
}

struct DiaryWeatherContext: Codable, Hashable, Sendable {
    var provider: String? = nil
    var condition: String? = nil
    var symbol: String? = nil
    var temperatureF: Double? = nil
    var precipitation: String? = nil
    var windMph: Double? = nil
    var attribution: String? = nil
    var fetchedAt: Date? = nil

    private enum CodingKeys: String, CodingKey {
        case provider
        case condition
        case symbol
        case temperatureF = "temperature_f"
        case precipitation
        case windMph = "wind_mph"
        case attribution
        case fetchedAt = "fetched_at"
    }
}

struct DiaryActivityContext: Codable, Hashable, Sendable {
    var steps: Int? = nil
    var exerciseMinutes: Int? = nil
    var activeEnergyKcal: Double? = nil
    var workouts: [DiaryWorkoutContext] = []
    var capturedAt: Date? = nil

    init(
        steps: Int? = nil,
        exerciseMinutes: Int? = nil,
        activeEnergyKcal: Double? = nil,
        workouts: [DiaryWorkoutContext] = [],
        capturedAt: Date? = nil
    ) {
        self.steps = steps
        self.exerciseMinutes = exerciseMinutes
        self.activeEnergyKcal = activeEnergyKcal
        self.workouts = workouts
        self.capturedAt = capturedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        steps = try container.decodeIfPresent(Int.self, forKey: .steps)
        exerciseMinutes = try container.decodeIfPresent(Int.self, forKey: .exerciseMinutes)
        activeEnergyKcal = try container.decodeIfPresent(Double.self, forKey: .activeEnergyKcal)
        workouts = try container.decodeIfPresent([DiaryWorkoutContext].self, forKey: .workouts) ?? []
        capturedAt = try container.decodeIfPresent(Date.self, forKey: .capturedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case steps
        case exerciseMinutes = "exercise_minutes"
        case activeEnergyKcal = "active_energy_kcal"
        case workouts
        case capturedAt = "captured_at"
    }
}

struct DiaryWorkoutContext: Codable, Hashable, Sendable {
    var type: String
    var startAt: Date? = nil
    var endAt: Date? = nil
    var durationMinutes: Double? = nil
    var distanceMiles: Double? = nil
    var activeEnergyKcal: Double? = nil

    private enum CodingKeys: String, CodingKey {
        case type
        case startAt = "start_at"
        case endAt = "end_at"
        case durationMinutes = "duration_minutes"
        case distanceMiles = "distance_miles"
        case activeEnergyKcal = "active_energy_kcal"
    }
}

@Model
final class DiarySuggestion {
    @Attribute(.unique) var id: String
    var kind: String
    var value: String
    var normalizedValue: String
    var count: Int
    var latestDate: Date

    init(kind: String, value: String, normalizedValue: String, count: Int, latestDate: Date) {
        self.id = "\(kind):\(normalizedValue)"
        self.kind = kind
        self.value = value
        self.normalizedValue = normalizedValue
        self.count = count
        self.latestDate = latestDate
    }
}

enum DiarySuggestionIndex {
    static func rebuild(modelContext: ModelContext) throws {
        for suggestion in try modelContext.fetch(FetchDescriptor<DiarySuggestion>()) {
            modelContext.delete(suggestion)
        }

        let descriptor = FetchDescriptor<DiaryEntry>(
            predicate: #Predicate { !$0.isTombstoned },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        let entries = try modelContext.fetch(descriptor)
        var scores: [String: SuggestionIndexScore] = [:]

        for entry in entries {
            collect(values: entry.people, kind: "people", entry: entry, scores: &scores)
            collect(values: entry.tags, kind: "tags", entry: entry, scores: &scores)
        }

        for score in scores.values {
            modelContext.insert(DiarySuggestion(
                kind: score.kind,
                value: score.value,
                normalizedValue: score.normalizedValue,
                count: score.count,
                latestDate: score.latestDate
            ))
        }
    }

    private static func collect(
        values: [String],
        kind: String,
        entry: DiaryEntry,
        scores: inout [String: SuggestionIndexScore]
    ) {
        for rawValue in values {
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }

            let normalized = normalize(value)
            let key = "\(kind):\(normalized)"
            if var score = scores[key] {
                score.count += 1
                if entry.updatedAt > score.latestDate {
                    score.latestDate = entry.updatedAt
                    score.value = value
                }
                scores[key] = score
            } else {
                scores[key] = SuggestionIndexScore(
                    kind: kind,
                    value: value,
                    normalizedValue: normalized,
                    count: 1,
                    latestDate: entry.updatedAt
                )
            }
        }
    }

    private static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}

private struct SuggestionIndexScore {
    var kind: String
    var value: String
    var normalizedValue: String
    var count: Int
    var latestDate: Date
}
