import Foundation
import SwiftData

enum PreviewData {
    @MainActor
    static var container: ModelContainer = {
        let schema = Schema([
            DiaryEntry.self,
            DiaryAttachment.self,
            DiarySuggestion.self,
            SyncCheckpoint.self,
            PendingChange.self,
            SyncEvent.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: [configuration])

        let entry = DiaryEntry(
            id: "preview-entry",
            createdAt: Date(timeIntervalSinceReferenceDate: 780_000_000),
            updatedAt: Date(timeIntervalSinceReferenceDate: 780_000_000),
            serverRevision: "preview",
            title: "A day worth keeping",
            excerpt: "Breakfast, rain on the windows, and a note I wanted to remember.",
            bodyMarkdown: """
            Breakfast was quiet today.

            The whole house felt slower in a good way, and I wrote down the small parts before they disappeared.
            """,
            sourcePath: "entries/2026/06/2026-06-22-a-day-worth-keeping.md",
            tags: ["family", "home"],
            people: ["Charlotte", "Chase"]
        )
        container.mainContext.insert(entry)
        return container
    }()
}
