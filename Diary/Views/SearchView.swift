import SwiftData
import SwiftUI

struct SearchView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState

    @Query(sort: \PendingChange.createdAt, order: .forward) private var pendingChanges: [PendingChange]

    @State private var syncCoordinator = SyncCoordinator()
    @State private var localEntries: [DiaryEntry] = []
    @State private var searchText = ""
    @State private var serverSearchState = ServerSearchState.idle
    @State private var serverSnippetsByEntryID: [String: String] = [:]

    private let localSearchLimit = 500

    private var pendingByEntryID: [String: PendingChange] {
        Dictionary(pendingChanges.map { ($0.entryID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private var results: [DiaryEntry] {
        guard !searchTerms.isEmpty else {
            return localEntries
        }

        return localEntries.filter { entry in
            searchTerms.allSatisfy { entry.searchTextStorage.contains($0) }
        }
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var searchTerms: [String] {
        trimmedSearchText
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    var body: some View {
        NavigationStack {
            List {
                if !trimmedSearchText.isEmpty && !results.isEmpty {
                    SearchControlRow(
                        localResultCount: results.count,
                        totalCount: localEntries.count,
                        state: serverSearchState,
                        isDisabled: syncCoordinator.isSyncing
                    ) {
                        Task {
                            await searchServer()
                        }
                    }
                } else if !trimmedSearchText.isEmpty {
                    SearchControlRow(
                        localResultCount: 0,
                        totalCount: localEntries.count,
                        state: serverSearchState,
                        isDisabled: syncCoordinator.isSyncing
                    ) {
                        Task {
                            await searchServer()
                        }
                    }
                }

                ForEach(results) { entry in
                    NavigationLink(value: entry.id) {
                        SearchEntryRow(
                            entry: entry,
                            pendingChange: pendingByEntryID[entry.id],
                            snippet: serverSnippetsByEntryID[entry.id]
                        )
                    }
                    .listRowInsets(EdgeInsets(top: 10, leading: 18, bottom: 10, trailing: 18))
                }
            }
            .listStyle(.plain)
            .overlay {
                if localEntries.isEmpty && trimmedSearchText.isEmpty {
                    ContentUnavailableView(
                        "No Entries",
                        systemImage: "book.closed",
                        description: Text("Sync with your Markdown diary server to fill the offline cache.")
                    )
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .navigationTitle("Search")
            .navigationDestination(for: String.self) { entryID in
                EntryDetailResolver(entryID: entryID)
            }
            .searchable(text: $searchText, prompt: "Entries, tags, people")
            .searchToolbarBehavior(.minimize)
            .task {
                loadLocalEntries()
            }
            .onChange(of: trimmedSearchText) { _, _ in
                serverSearchState = .idle
                serverSnippetsByEntryID = [:]
            }
        }
    }

    private func searchServer() async {
        guard !trimmedSearchText.isEmpty else {
            return
        }

        serverSearchState = .searching

        do {
            let summary = try await syncCoordinator.searchServer(
                query: trimmedSearchText,
                modelContext: modelContext,
                appState: appState
            )
            serverSnippetsByEntryID = summary.snippetsByEntryID
            serverSearchState = .completed(summary.resultCount)
            loadLocalEntries()
        } catch {
            serverSearchState = .failed(error.localizedDescription)
        }
    }

    private func loadLocalEntries() {
        do {
            var descriptor = FetchDescriptor<DiaryEntry>(
                predicate: #Predicate { !$0.isTombstoned },
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
            descriptor.fetchLimit = localSearchLimit
            localEntries = try modelContext.fetch(descriptor)
        } catch {
            localEntries = []
        }
    }
}

private struct SearchEntryRow: View {
    let entry: DiaryEntry
    var pendingChange: PendingChange?
    var snippet: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            EntryRow(entry: entry, pendingChange: pendingChange)

            if let snippet, !snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                SearchSnippetText(snippet: snippet)
            }
        }
    }
}

private struct SearchSnippetText: View {
    let snippet: String

    var body: some View {
        Text(attributedSnippet)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .accessibilityLabel(cleanSnippet)
    }

    private var attributedSnippet: AttributedString {
        var output = AttributedString()
        var remaining = snippet[...]

        while let markerStart = remaining.range(of: "[[") {
            output.append(AttributedString(String(remaining[..<markerStart.lowerBound])))
            remaining = remaining[markerStart.upperBound...]

            guard let markerEnd = remaining.range(of: "]]") else {
                output.append(AttributedString(String(remaining)))
                return output
            }

            var highlighted = AttributedString(String(remaining[..<markerEnd.lowerBound]))
            highlighted.foregroundColor = .primary
            highlighted.font = .body.bold()
            output.append(highlighted)
            remaining = remaining[markerEnd.upperBound...]
        }

        output.append(AttributedString(String(remaining)))
        return output
    }

    private var cleanSnippet: String {
        snippet
            .replacingOccurrences(of: "[[", with: "")
            .replacingOccurrences(of: "]]", with: "")
    }
}

private enum ServerSearchState: Equatable {
    case idle
    case searching
    case completed(Int)
    case failed(String)
}

private struct SearchControlRow: View {
    let localResultCount: Int
    let totalCount: Int
    let state: ServerSearchState
    let isDisabled: Bool
    let searchServer: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("\(localResultCount) local result\(localResultCount == 1 ? "" : "s")", systemImage: "magnifyingglass")
                Spacer()
                Text("\(totalCount) cached")
                    .foregroundStyle(.secondary)
            }

            HStack {
                serverStatus
                Spacer()
                Button("Search Server", systemImage: "icloud.and.arrow.down") {
                    searchServer()
                }
                .disabled(isDisabled || state == .searching)
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private var serverStatus: some View {
        switch state {
        case .idle:
            Text("Server search checks canonical Markdown.")
        case .searching:
            Label("Searching server", systemImage: "hourglass")
        case .completed(let count):
            Label("\(count) server result\(count == 1 ? "" : "s") imported", systemImage: "checkmark.circle")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }
}

#Preview {
    SearchView()
        .modelContainer(PreviewData.container)
}
