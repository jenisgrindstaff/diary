import AppIntents
import Foundation
import SwiftData

/// Resolves the process-shared diary store for use inside an App Intent.
@MainActor
private func diaryContext() throws -> ModelContext {
    try AppModelContainer.shared.get().mainContext
}

enum DiaryIntentError: Error, CustomLocalizedStringResourceConvertible {
    case emptyText

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .emptyText: return "There was nothing to save."
        }
    }
}

/// The store-facing logic behind the App Intents, factored out of the intent
/// structs so it can be unit-tested with an in-memory context.
enum DiaryIntentActions {
    @MainActor
    static func createEntry(
        text: String,
        title: String?,
        now: Date = .now,
        context: ModelContext,
        appState: AppState,
        coordinator: SyncCoordinator
    ) async throws {
        let draft = EntryWriteDraft(
            createdAt: now,
            title: title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            bodyMarkdown: text,
            people: [],
            tags: []
        )
        _ = try await coordinator.createEntry(draft: draft, modelContext: context, appState: appState)
    }

    /// Appends to today's most recent entry, or starts one if none exists.
    /// Returns true when it appended to an existing entry.
    @MainActor
    @discardableResult
    static func appendToToday(
        text: String,
        now: Date = .now,
        context: ModelContext,
        appState: AppState,
        coordinator: SyncCoordinator
    ) async throws -> Bool {
        let startOfDay = Calendar.current.startOfDay(for: now)
        var descriptor = FetchDescriptor<DiaryEntry>(
            predicate: #Predicate { !$0.isTombstoned && $0.createdAt >= startOfDay },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1

        guard let entry = try context.fetch(descriptor).first else {
            try await createEntry(text: text, title: nil, now: now, context: context, appState: appState, coordinator: coordinator)
            return false
        }

        let draft = EntryWriteDraft(
            createdAt: entry.createdAt,
            expectedServerRevision: entry.serverRevision,
            title: entry.title,
            bodyMarkdown: entry.bodyMarkdown + "\n\n" + text,
            people: entry.people,
            tags: entry.tags
        )
        do {
            try await coordinator.updateEntry(id: entry.id, draft: draft, modelContext: context, appState: appState)
        } catch {
            // enqueueUpdate already persisted the change; a conflict or network
            // error during the immediate flush reconciles on the next sync.
        }
        return true
    }

    /// Mirrors the in-app local search: fold case/diacritics and require every
    /// term to be present in the denormalized search text.
    @MainActor
    static func search(query: String, limit: Int = 10, context: ModelContext) throws -> [String] {
        let terms = query
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !terms.isEmpty else { return [] }

        let entries = try context.fetch(FetchDescriptor<DiaryEntry>(
            predicate: #Predicate { !$0.isTombstoned },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        ))
        return entries
            .filter { entry in terms.allSatisfy { entry.searchTextStorage.contains($0) } }
            .prefix(limit)
            .map(\.title)
    }
}

// MARK: - Create Entry

struct CreateDiaryEntryIntent: AppIntent {
    static let title: LocalizedStringResource = "Create Diary Entry"
    static let description = IntentDescription("Add a new entry to your diary.")

    @Parameter(title: "Entry")
    var text: String

    @Parameter(title: "Title")
    var entryTitle: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$text) to my diary")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DiaryIntentError.emptyText }

        // createEntry durably queues the entry and best-effort syncs, so it
        // succeeds offline. It only throws on a local persistence failure.
        try await DiaryIntentActions.createEntry(
            text: trimmed,
            title: entryTitle,
            context: try diaryContext(),
            appState: AppState(),
            coordinator: SyncCoordinator()
        )
        return .result(dialog: "Saved to your diary.")
    }
}

// MARK: - Append to Today

struct AppendToTodayDiaryIntent: AppIntent {
    static let title: LocalizedStringResource = "Append to Today's Entry"
    static let description = IntentDescription("Add a note to today's diary entry, creating it if there isn't one yet.")

    @Parameter(title: "Text")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Append \(\.$text) to today's diary entry")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DiaryIntentError.emptyText }

        let appended = try await DiaryIntentActions.appendToToday(
            text: trimmed,
            context: try diaryContext(),
            appState: AppState(),
            coordinator: SyncCoordinator()
        )
        return .result(dialog: appended ? "Added to today's entry." : "Started today's entry.")
    }
}

// MARK: - Search

struct SearchDiaryIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Diary"
    static let description = IntentDescription("Find diary entries that match your search.")

    @Parameter(title: "Search")
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("Search my diary for \(\.$query)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[String]> & ProvidesDialog {
        let titles = try DiaryIntentActions.search(query: query, context: try diaryContext())
        let dialog: IntentDialog = titles.isEmpty
            ? "No diary entries matched \u{201C}\(query)\u{201D}."
            : "Found \(titles.count) \(titles.count == 1 ? "entry" : "entries")."
        return .result(value: titles, dialog: dialog)
    }
}

// MARK: - Shortcuts

struct DiaryAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CreateDiaryEntryIntent(),
            phrases: [
                "Create a \(.applicationName) entry",
                "New entry in \(.applicationName)",
                "Write in my \(.applicationName)"
            ],
            shortTitle: "New Entry",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: AppendToTodayDiaryIntent(),
            phrases: [
                "Add to today in \(.applicationName)",
                "Append to my \(.applicationName)"
            ],
            shortTitle: "Add to Today",
            systemImageName: "text.append"
        )
        AppShortcut(
            intent: SearchDiaryIntent(),
            phrases: [
                "Search \(.applicationName)",
                "Search my \(.applicationName)"
            ],
            shortTitle: "Search",
            systemImageName: "magnifyingglass"
        )
    }
}
