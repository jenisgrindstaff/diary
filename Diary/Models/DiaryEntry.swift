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
        self.searchTextStorage = Self.searchText(
            title: title,
            excerpt: excerpt,
            bodyMarkdown: bodyMarkdown,
            tags: tags,
            people: people,
            subjectDetails: subjectDetails
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

    func refreshSearchText() {
        searchTextStorage = Self.searchText(
            title: title,
            excerpt: excerpt,
            bodyMarkdown: bodyMarkdown,
            tags: tags,
            people: people,
            subjectDetails: subjectDetails
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

    private static func searchText(
        title: String,
        excerpt: String,
        bodyMarkdown: String,
        tags: [String],
        people: [String],
        subjectDetails: [DiarySubjectDetail]
    ) -> String {
        let subjectText = subjectDetails
            .flatMap { [$0.name, $0.label, $0.ageText, $0.rawText] }
            .joined(separator: " ")
        return ([title, excerpt, bodyMarkdown, tags.joined(separator: " "), people.joined(separator: " "), subjectText])
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
