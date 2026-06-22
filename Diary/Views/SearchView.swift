import SwiftData
import SwiftUI

struct SearchView: View {
    @Query(
        filter: #Predicate<DiaryEntry> { $0.isTombstoned == false },
        sort: \DiaryEntry.createdAt,
        order: .reverse
    )
    private var entries: [DiaryEntry]
    @Query(sort: \PendingChange.createdAt, order: .forward) private var pendingChanges: [PendingChange]

    @State private var searchText = ""

    private var pendingByEntryID: [String: PendingChange] {
        Dictionary(pendingChanges.map { ($0.entryID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private var results: [DiaryEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return entries
        }

        let normalizedQuery = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return entries.filter { entry in
            entry.searchTextStorage.localizedStandardContains(normalizedQuery)
        }
    }

    var body: some View {
        NavigationStack {
            List(results) { entry in
                NavigationLink(value: entry.id) {
                    EntryRow(entry: entry, pendingChange: pendingByEntryID[entry.id])
                }
                .listRowInsets(EdgeInsets(top: 10, leading: 18, bottom: 10, trailing: 18))
            }
            .overlay {
                if results.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .navigationTitle("Search")
            .navigationDestination(for: String.self) { entryID in
                EntryDetailResolver(entryID: entryID)
            }
            .searchable(text: $searchText, prompt: "Entries, tags, people")
            .searchToolbarBehavior(.minimize)
        }
    }
}

#Preview {
    SearchView()
        .modelContainer(PreviewData.container)
}
