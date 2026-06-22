import SwiftData
import XCTest
@testable import Diary

@MainActor
final class DraftSuggestionsTests: XCTestCase {
    func testSuggestionIndexRanksByFrequencyThenRecency() throws {
        let context = try makeContext()
        context.insert(entry(id: "1", updatedAt: Date(timeIntervalSinceReferenceDate: 700_000_000), people: ["Charlotte"], tags: ["family", "school"]))
        context.insert(entry(id: "2", updatedAt: Date(timeIntervalSinceReferenceDate: 800_000_000), people: ["Charlotte", "Chase"], tags: ["family", "funny"]))
        context.insert(entry(id: "3", updatedAt: Date(timeIntervalSinceReferenceDate: 801_000_000), people: ["Chase"], tags: ["milestone"]))
        try DiarySuggestionIndex.rebuild(modelContext: context)
        try context.save()

        let indexed = try context.fetch(FetchDescriptor<DiarySuggestion>())
        let suggestions = DraftSuggestions(suggestions: indexed, limit: 3)

        XCTAssertEqual(suggestions.people.map(\.title), ["Chase", "Charlotte"])
        XCTAssertEqual(suggestions.tags.map(\.title), ["family", "milestone", "funny"])
    }

    func testSuggestionsRankByFrequencyThenRecency() {
        let older = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let newer = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let newest = Date(timeIntervalSinceReferenceDate: 801_000_000)

        let suggestions = DraftSuggestions(
            entries: [
                entry(id: "1", updatedAt: older, people: ["Charlotte"], tags: ["family", "school"]),
                entry(id: "2", updatedAt: newer, people: ["Charlotte", "Chase"], tags: ["family", "funny"]),
                entry(id: "3", updatedAt: newest, people: ["Chase"], tags: ["milestone"])
            ],
            limit: 3
        )

        XCTAssertEqual(suggestions.people.map(\.title), ["Chase", "Charlotte"])
        XCTAssertEqual(suggestions.tags.map(\.title), ["family", "milestone", "funny"])
    }

    func testSuggestionsIgnoreTombstonedEntriesAndDedupeCaseInsensitively() {
        let older = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let newer = Date(timeIntervalSinceReferenceDate: 800_000_000)

        let suggestions = DraftSuggestions(
            entries: [
                entry(id: "1", updatedAt: older, people: ["Charlotte"], tags: ["Family"]),
                entry(id: "2", updatedAt: newer, people: ["charlotte"], tags: ["family"]),
                entry(id: "3", updatedAt: newer, people: ["Deleted"], tags: ["deleted"], isTombstoned: true)
            ],
            limit: 8
        )

        XCTAssertEqual(suggestions.people.map(\.title), ["charlotte"])
        XCTAssertEqual(suggestions.tags.map(\.title), ["family"])
    }

    private func entry(
        id: String,
        updatedAt: Date,
        people: [String],
        tags: [String],
        isTombstoned: Bool = false
    ) -> DiaryEntry {
        DiaryEntry(
            id: id,
            createdAt: updatedAt,
            updatedAt: updatedAt,
            serverRevision: "rev-\(id)",
            title: "Entry \(id)",
            excerpt: "",
            bodyMarkdown: "Body",
            tags: tags,
            people: people,
            isTombstoned: isTombstoned
        )
    }

    private func makeContext() throws -> ModelContext {
        let schema = Schema([
            DiaryEntry.self,
            DiaryAttachment.self,
            DiarySuggestion.self,
            SyncCheckpoint.self,
            PendingChange.self,
            SyncEvent.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(for: schema, configurations: [configuration]))
    }
}
