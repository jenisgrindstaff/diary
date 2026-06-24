import SwiftData
import XCTest
@testable import Diary

final class DraftSuggestionsTests: XCTestCase {
    func testSuggestionIndexDoesNotAffectQuickCaptureSearchFilters() throws {
        let schema = Schema([
            DiaryEntry.self,
            DiaryAttachment.self,
            DiarySuggestion.self,
            SyncCheckpoint.self,
            PendingChange.self,
            SyncEvent.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)

        context.insert(DiaryEntry(
            id: "1",
            createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
            updatedAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
            serverRevision: "rev-1",
            title: "Plain Entry",
            excerpt: "No manual metadata",
            bodyMarkdown: "No manual metadata"
        ))
        try DiarySuggestionIndex.rebuild(modelContext: context)

        XCTAssertTrue(try context.fetch(FetchDescriptor<DiarySuggestion>()).isEmpty)
    }
}
