import SwiftData
import XCTest
@testable import Diary

@MainActor
final class SyncImporterTests: XCTestCase {
    func testImporterCreatesEntriesAndAttachments() throws {
        let context = try makeContext()
        let checkpoint = SyncCheckpoint(deviceID: "device", serverBaseURL: "https://diary.example.com")
        context.insert(checkpoint)

        let attachment = AttachmentDTO(
            id: "asset-1",
            kind: "image",
            filename: "photo.jpg",
            contentType: "image/jpeg",
            remotePath: "/api/v1/assets/asset-1",
            markdownPath: "assets/2026/06/photo.jpg",
            byteCount: 128,
            width: 100,
            height: 80,
            createdAt: nil
        )
        let entry = EntryDTO(
            id: "entry-1",
            createdAt: .now,
            updatedAt: .now,
            serverRevision: "rev-1",
            title: "Imported",
            excerpt: "First import",
            bodyMarkdown: "Hello **Markdown**.",
            sourcePath: "entries/2026/06/imported.md",
            tags: ["family"],
            people: ["Charlotte"],
            subjectDetails: [
                SubjectDetailDTO(name: "Charlotte", label: "age", ageText: "9 years", rawText: nil)
            ],
            context: DiaryEntryContext(
                location: DiaryLocationContext(label: "Bar Harbor, ME", latitude: 44.39, longitude: -68.2, precision: "place"),
                weather: DiaryWeatherContext(provider: "apple_weather", condition: "Cloudy", temperatureF: 72, attribution: "Weather"),
                activity: DiaryActivityContext(steps: 8432)
            ),
            attachments: [attachment]
        )
        let envelope = EntrySyncEnvelope(entries: [entry], deletedEntryIDs: [], nextCursor: "cursor-1")

        try SyncImporter.apply(envelope: envelope, checkpoint: checkpoint, modelContext: context)

        let entries = try context.fetch(FetchDescriptor<DiaryEntry>())
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.id, "entry-1")
        XCTAssertEqual(entries.first?.tags, ["family"])
        XCTAssertEqual(entries.first?.subjectDetails.first?.ageText, "9 years")
        XCTAssertEqual(entries.first?.entryContext.location?.label, "Bar Harbor, ME")
        XCTAssertTrue(entries.first?.searchTextStorage.localizedStandardContains("Cloudy") == true)
        XCTAssertTrue(entries.first?.searchTextStorage.localizedStandardContains("Charlotte") == true)
        XCTAssertEqual(entries.first?.attachments.count, 1)
        XCTAssertEqual(checkpoint.cursor, "cursor-1")
    }

    func testImporterMarksDeletedEntriesAsDeleted() throws {
        let context = try makeContext()
        let checkpoint = SyncCheckpoint(deviceID: "device", serverBaseURL: "https://diary.example.com")
        let entry = DiaryEntry(
            id: "deleted-entry",
            createdAt: .now,
            updatedAt: .now,
            serverRevision: "rev-1",
            title: "Entry",
            excerpt: "",
            bodyMarkdown: ""
        )
        context.insert(checkpoint)
        context.insert(entry)
        try context.save()

        let envelope = EntrySyncEnvelope(entries: [], deletedEntryIDs: ["deleted-entry"], nextCursor: "cursor-2")

        try SyncImporter.apply(envelope: envelope, checkpoint: checkpoint, modelContext: context)

        let cachedEntry = try XCTUnwrap(
            context.fetch(FetchDescriptor<DiaryEntry>()).first { $0.id == "deleted-entry" }
        )
        XCTAssertTrue(cachedEntry.isTombstoned)
        XCTAssertEqual(checkpoint.cursor, "cursor-2")
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
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return ModelContext(container)
    }
}
