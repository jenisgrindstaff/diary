import CoreTransferable
import Foundation
import Observation
import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct TimelineView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @Query(sort: \PendingChange.createdAt, order: .forward) private var pendingChanges: [PendingChange]

    @State private var syncCoordinator = SyncCoordinator()
    @State private var timelinePager = TimelinePager()
    @State private var composerMode: EntryComposerMode?
    @State private var searchText = ""
    @State private var localSearchEntries: [DiaryEntry] = []
    @State private var selectedSearchFilters: Set<TimelineSearchFilter> = []
    @State private var recentSearches: [String] = []
    @State private var timelineMonths: [TimelineMonthOption] = []
    @State private var navigationSheet: TimelineNavigationSheet?
    @State private var serverSearchState = TimelineServerSearchState.idle
    @State private var isShowingSettings = false

    private let localSearchLimit = 2_000
    private let timelineMonthIndexLimit = 10_000

    private var pendingByEntryID: [String: PendingChange] {
        Dictionary(pendingChanges.map { ($0.entryID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private var sections: [TimelineSection] {
        TimelineSection.group(visibleEntries)
    }

    private var visibleEntries: [DiaryEntry] {
        hasActiveSearch ? searchResults : timelinePager.loadedEntries
    }

    private var searchResults: [DiaryEntry] {
        guard hasActiveSearch else {
            return localSearchEntries
        }

        return localSearchEntries.filter { entry in
            searchTerms.allSatisfy { entry.searchTextStorage.contains($0) }
            && selectedSearchFilters.allSatisfy { $0.matches(entry) }
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

    private var isSearching: Bool {
        !searchTerms.isEmpty
    }

    private var hasActiveSearch: Bool {
        isSearching || !selectedSearchFilters.isEmpty
    }

    private var searchFilterOptions: [TimelineSearchFilter] {
        var filters: [TimelineSearchFilter] = []

        if localSearchEntries.contains(where: { !$0.attachments.isEmpty }) {
            filters.append(.media)
        }

        for filter in selectedSearchFilters where !filters.contains(filter) {
            filters.append(filter)
        }

        return filters
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Group {
                    if visibleEntries.isEmpty && !hasActiveSearch && !timelinePager.isLoadingPage {
                        ContentUnavailableView(
                            "No Entries",
                            systemImage: "book.closed",
                            description: Text("Sync with your Markdown diary server to fill the offline cache.")
                        )
                    } else {
                        List {
                            if hasActiveSearch && !searchFilterOptions.isEmpty {
                                TimelineSearchFilterRow(
                                    filters: searchFilterOptions,
                                    selectedFilters: $selectedSearchFilters
                                )
                                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 8, trailing: 16))
                                .listRowSeparator(.hidden)
                            }

                            if isSearching {
                                TimelineSearchControlRow(
                                    localResultCount: searchResults.count,
                                    totalCount: localSearchEntries.count,
                                    isLocalCacheCapped: localSearchEntries.count == localSearchLimit,
                                    state: serverSearchState,
                                    isDisabled: syncCoordinator.isSyncing
                                ) {
                                    Task {
                                        await searchServer()
                                    }
                                }
                            }

                            if let anchorDate = timelinePager.anchorDate, !hasActiveSearch {
                                TimelineJumpStatusRow(anchorDate: anchorDate) {
                                    jumpToToday()
                                }
                                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 8, trailing: 16))
                                .listRowSeparator(.hidden)
                            }

                            ForEach(sections) { section in
                                Section {
                                    ForEach(section.entries) { entry in
                                        NavigationLink(value: entry.id) {
                                            TimelineEntryRow(
                                                entry: entry,
                                                pendingChange: pendingByEntryID[entry.id],
                                                isToday: Calendar.current.isDateInToday(entry.createdAt)
                                            )
                                        }
                                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                                        .listRowSeparator(.hidden)
                                        .onAppear {
                                            if !hasActiveSearch {
                                                loadMoreIfNeeded(entry)
                                            }
                                        }
                                    }
                                } header: {
                                    TimelineSectionHeader(section: section)
                                }
                            }

                            if timelinePager.hasMore && !hasActiveSearch {
                                ProgressView()
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .listRowSeparator(.hidden)
                                    .onAppear {
                                        Task {
                                            await timelinePager.loadNextPage(modelContext: modelContext)
                                        }
                                    }
                            }
                        }
                        .listStyle(.plain)
                        .contentMargins(.top, 8, for: .scrollContent)
                        .overlay {
                            if hasActiveSearch && searchResults.isEmpty {
                                if isSearching {
                                    ContentUnavailableView.search(text: searchText)
                                } else {
                                    ContentUnavailableView(
                                        "No Matches",
                                        systemImage: "line.3.horizontal.decrease.circle",
                                        description: Text("Try another filter or clear filters to return to the timeline.")
                                    )
                                }
                            }
                        }
                        .refreshable {
                            await syncCoordinator.sync(modelContext: modelContext, appState: appState)
                            await reloadTimeline()
                            DiaryWidgetPublisher.refresh(modelContext: modelContext)
                        }
                    }
                }
            }
            .navigationTitle("Diary")
            .searchable(text: $searchText, placement: .toolbar, prompt: "Search entries")
            .searchSuggestions {
                ForEach(recentSearches, id: \.self) { recentSearch in
                    Text(recentSearch)
                        .searchCompletion(recentSearch)
                }
            }
            .onSubmit(of: .search) {
                recordRecentSearch()
            }
            .navigationDestination(for: String.self) { entryID in
                EntryDetailResolver(entryID: entryID)
            }
            .navigationDestination(isPresented: $isShowingSettings) {
                SettingsView()
            }
            .sheet(item: $navigationSheet) { sheet in
                switch sheet {
                case .jump:
                    TimelineJumpNavigationView(
                        months: timelineMonths,
                        selectedFilters: $selectedSearchFilters,
                        jumpToToday: jumpToToday,
                        jumpToDate: jumpToDate,
                        jumpToMonth: jumpToMonth
                    )
                }
            }
            .sheet(item: $composerMode, onDismiss: {
                Task {
                    await reloadTimeline()
                    DiaryWidgetPublisher.refresh(modelContext: modelContext)
                }
            }) { mode in
                switch mode {
                case .quick:
                    QuickAppendView(syncCoordinator: syncCoordinator)
                case .full:
                    NewEntryView(syncCoordinator: syncCoordinator)
                }
            }
            .task {
                await reloadTimeline()
                recentSearches = RecentSearchStore.load()
                presentNewEntryIfRequested()
                DiaryWidgetPublisher.refresh(modelContext: modelContext)
            }
            .onChange(of: trimmedSearchText) { _, _ in
                serverSearchState = .idle
            }
            .onChange(of: appState.pendingNewEntry) {
                presentNewEntryIfRequested()
            }
            .onChange(of: appState.pendingQuickEntry) {
                presentNewEntryIfRequested()
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Add Today", systemImage: "text.badge.plus") {
                        composerMode = .quick
                    }
                    .accessibilityHint("Quickly appends text to today's diary entry.")

                    Menu {
                        Button("Jump / Filter", systemImage: "calendar.badge.clock") {
                            navigationSheet = .jump
                        }

                        Button("Today", systemImage: "calendar") {
                            jumpToToday()
                        }

                        Divider()

                        Button("Full Entry", systemImage: "square.and.pencil") {
                            composerMode = .full
                        }

                        Button("Sync", systemImage: appState.syncStatus.symbolName) {
                            Task {
                                await syncCoordinator.sync(modelContext: modelContext, appState: appState)
                                await reloadTimeline()
                                DiaryWidgetPublisher.refresh(modelContext: modelContext)
                            }
                        }
                        .disabled(syncCoordinator.isSyncing)

                        Button("Settings", systemImage: "gear") {
                            isShowingSettings = true
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                    .accessibilityHint("Shows full entry, sync, and settings actions.")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if case .failed = appState.syncStatus {
                    SyncStatusBanner(status: appState.syncStatus)
                }
            }
        }
    }

    private func reloadTimeline() async {
        await timelinePager.reload(modelContext: modelContext, anchorDate: timelinePager.anchorDate)
        loadLocalSearchEntries()
        loadTimelineMonths()
    }

    private func searchServer() async {
        guard !trimmedSearchText.isEmpty else {
            return
        }

        recordRecentSearch()
        serverSearchState = .searching

        do {
            let summary = try await syncCoordinator.searchServer(
                query: trimmedSearchText,
                modelContext: modelContext,
                appState: appState
            )
            serverSearchState = .completed(summary.resultCount)
            await reloadTimeline()
        } catch {
            serverSearchState = .failed(error.localizedDescription)
        }
    }

    private func loadLocalSearchEntries() {
        do {
            var descriptor = FetchDescriptor<DiaryEntry>(
                predicate: #Predicate { !$0.isTombstoned },
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
            descriptor.fetchLimit = localSearchLimit
            localSearchEntries = try modelContext.fetch(descriptor)
        } catch {
            localSearchEntries = []
        }
    }

    private func loadTimelineMonths() {
        do {
            var descriptor = FetchDescriptor<DiaryEntry>(
                predicate: #Predicate { !$0.isTombstoned },
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
            descriptor.fetchLimit = timelineMonthIndexLimit
            let entries = try modelContext.fetch(descriptor)
            timelineMonths = TimelineMonthOption.options(from: entries)
        } catch {
            timelineMonths = []
        }
    }

    private func recordRecentSearch() {
        let value = trimmedSearchText
        guard !value.isEmpty else { return }
        recentSearches = RecentSearchStore.record(value, in: recentSearches)
    }

    private func jumpToToday() {
        clearSearchState()
        Task {
            await timelinePager.reload(modelContext: modelContext, anchorDate: nil)
            loadLocalSearchEntries()
            loadTimelineMonths()
        }
    }

    private func jumpToDate(_ date: Date) {
        let anchorDate = Calendar.current.endOfDay(for: date)
        clearSearchState()
        Task {
            await timelinePager.reload(modelContext: modelContext, anchorDate: anchorDate)
            loadLocalSearchEntries()
            loadTimelineMonths()
        }
    }

    private func jumpToMonth(_ month: TimelineMonthOption) {
        clearSearchState()
        Task {
            await timelinePager.reload(modelContext: modelContext, anchorDate: month.anchorDate)
            loadLocalSearchEntries()
            loadTimelineMonths()
        }
    }

    private func clearSearchState() {
        searchText = ""
        selectedSearchFilters.removeAll()
        serverSearchState = .idle
    }

    private func presentNewEntryIfRequested() {
        if appState.pendingQuickEntry {
            appState.pendingQuickEntry = false
            composerMode = .quick
            return
        }

        guard appState.pendingNewEntry else { return }
        appState.pendingNewEntry = false
        composerMode = .full
    }

    private func loadMoreIfNeeded(_ entry: DiaryEntry) {
        guard timelinePager.shouldLoadMore(afterAppearing: entry) else { return }
        Task {
            await timelinePager.loadNextPage(modelContext: modelContext)
        }
    }
}

private enum EntryComposerMode: String, Identifiable {
    case quick
    case full

    var id: String { rawValue }
}

private enum TimelineNavigationSheet: String, Identifiable {
    case jump

    var id: String { rawValue }
}

private enum TimelineServerSearchState: Equatable {
    case idle
    case searching
    case completed(Int)
    case failed(String)
}

private enum TimelineSearchFilter: Hashable, Identifiable {
    case media

    var id: String {
        switch self {
        case .media:
            return "media"
        }
    }

    var label: String {
        switch self {
        case .media:
            return "Media"
        }
    }

    var systemImage: String {
        switch self {
        case .media:
            return "photo.on.rectangle"
        }
    }

    func matches(_ entry: DiaryEntry) -> Bool {
        switch self {
        case .media:
            return !entry.attachments.isEmpty
        }
    }
}

private struct TimelineSearchFilterRow: View {
    let filters: [TimelineSearchFilter]
    @Binding var selectedFilters: Set<TimelineSearchFilter>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                if !selectedFilters.isEmpty {
                    Button("Clear") {
                        selectedFilters.removeAll()
                    }
                    .font(.footnote)
                }
            }

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(filters) { filter in
                        TimelineSearchFilterChip(
                            filter: filter,
                            isSelected: selectedFilters.contains(filter)
                        ) {
                            toggle(filter)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
        }
        .accessibilityElement(children: .contain)
    }

    private func toggle(_ filter: TimelineSearchFilter) {
        if selectedFilters.contains(filter) {
            selectedFilters.remove(filter)
        } else {
            selectedFilters.insert(filter)
        }
    }
}

private struct TimelineSearchFilterChip: View {
    let filter: TimelineSearchFilter
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(filter.label, systemImage: filter.systemImage)
                .font(.footnote.weight(isSelected ? .semibold : .regular))
                .lineLimit(1)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .foregroundStyle(isSelected ? .white : .primary)
                .background(
                    isSelected ? Color.accentColor : Color.secondary.opacity(0.14),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct TimelineJumpStatusRow: View {
    let anchorDate: Date
    let jumpToToday: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Label {
                Text("Showing from \(anchorDate.formatted(date: .abbreviated, time: .omitted))")
            } icon: {
                Image(systemName: "calendar.badge.clock")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            Spacer()

            Button("Today", systemImage: "calendar") {
                jumpToToday()
            }
            .font(.footnote.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.quaternary, in: .rect(cornerRadius: 12))
    }
}

private struct TimelineJumpNavigationView: View {
    @Environment(\.dismiss) private var dismiss

    let months: [TimelineMonthOption]
    @Binding var selectedFilters: Set<TimelineSearchFilter>
    let jumpToToday: () -> Void
    let jumpToDate: (Date) -> Void
    let jumpToMonth: (TimelineMonthOption) -> Void

    @State private var selectedDate = Date()
    @State private var selectedMonthID: String?

    init(
        months: [TimelineMonthOption],
        selectedFilters: Binding<Set<TimelineSearchFilter>>,
        jumpToToday: @escaping () -> Void,
        jumpToDate: @escaping (Date) -> Void,
        jumpToMonth: @escaping (TimelineMonthOption) -> Void
    ) {
        self.months = months
        _selectedFilters = selectedFilters
        self.jumpToToday = jumpToToday
        self.jumpToDate = jumpToDate
        self.jumpToMonth = jumpToMonth
        _selectedMonthID = State(initialValue: months.first?.id)
    }

    private var filterOptions: [TimelineSearchFilter] {
        [.media]
    }

    private var selectedMonth: TimelineMonthOption? {
        guard let selectedMonthID else { return nil }
        return months.first { $0.id == selectedMonthID }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button("Jump to Today", systemImage: "calendar") {
                        jumpToToday()
                        dismiss()
                    }

                    DatePicker("Date", selection: $selectedDate, displayedComponents: .date)

                    Button("Jump to Date", systemImage: "calendar.badge.clock") {
                        jumpToDate(selectedDate)
                        dismiss()
                    }
                } header: {
                    Text("Date")
                }

                if !months.isEmpty {
                    Section {
                        Picker("Month", selection: $selectedMonthID) {
                            ForEach(months) { month in
                                Text(month.pickerTitle)
                                    .tag(Optional(month.id))
                            }
                        }

                        Button("Jump to Month", systemImage: "calendar.circle") {
                            guard let selectedMonth else { return }
                            jumpToMonth(selectedMonth)
                            dismiss()
                        }
                        .disabled(selectedMonth == nil)
                    } header: {
                        Text("Month")
                    } footer: {
                        Text("Months are built from the local offline cache.")
                    }
                }

                if !filterOptions.isEmpty {
                    Section {
                        TimelineSearchFilterRow(
                            filters: filterOptions,
                            selectedFilters: $selectedFilters
                        )
                    } header: {
                        Text("Media")
                    } footer: {
                        Text("Filters apply to cached local entries.")
                    }
                }
            }
            .navigationTitle("Jump / Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct TimelineSearchControlRow: View {
    let localResultCount: Int
    let totalCount: Int
    let isLocalCacheCapped: Bool
    let state: TimelineServerSearchState
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
            Text(isLocalCacheCapped ? "Local cache is capped. Search server for all results." : "Search server for complete Markdown results.")
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

private enum RecentSearchStore {
    private static let key = "timelineRecentSearches"
    private static let limit = 6

    static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func record(_ value: String, in existing: [String]) -> [String] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return existing }

        let normalized = trimmed.diarySearchNormalized
        var searches = existing.filter { $0.diarySearchNormalized != normalized }
        searches.insert(trimmed, at: 0)
        searches = Array(searches.prefix(limit))
        UserDefaults.standard.set(searches, forKey: key)
        return searches
    }
}

private extension String {
    var diarySearchNormalized: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}

private struct TimelineMonthOption: Identifiable, Equatable {
    let id: String
    let title: String
    let entryCount: Int
    let anchorDate: Date

    var pickerTitle: String {
        "\(title) (\(entryCount))"
    }

    static func options(from entries: [DiaryEntry], calendar: Calendar = .current) -> [TimelineMonthOption] {
        var buckets: [String: TimelineMonthBucket] = [:]

        for entry in entries {
            let components = calendar.dateComponents([.year, .month], from: entry.createdAt)
            guard let year = components.year,
                  let month = components.month,
                  let startDate = calendar.date(from: components) else {
                continue
            }

            let id = "\(year)-\(String(format: "%02d", month))"
            var bucket = buckets[id] ?? TimelineMonthBucket(
                id: id,
                startDate: startDate,
                count: 0
            )
            bucket.count += 1
            buckets[id] = bucket
        }

        return buckets.values
            .sorted { $0.startDate > $1.startDate }
            .map { bucket in
                TimelineMonthOption(
                    id: bucket.id,
                    title: bucket.startDate.formatted(.dateTime.month(.wide).year()),
                    entryCount: bucket.count,
                    anchorDate: calendar.endOfMonth(for: bucket.startDate)
                )
            }
    }
}

private struct TimelineMonthBucket {
    let id: String
    let startDate: Date
    var count: Int
}

private extension Calendar {
    func endOfDay(for date: Date) -> Date {
        self.date(bySettingHour: 23, minute: 59, second: 59, of: date) ?? date
    }

    func endOfMonth(for date: Date) -> Date {
        guard let interval = dateInterval(of: .month, for: date) else {
            return endOfDay(for: date)
        }

        return interval.end.addingTimeInterval(-1)
    }
}

@MainActor
@Observable
private final class TimelinePager {
    private let pageSize = 80

    private(set) var loadedEntries: [DiaryEntry] = []
    private(set) var hasMore = true
    private(set) var isLoadingPage = false
    private(set) var anchorDate: Date?

    func reload(modelContext: ModelContext, anchorDate: Date? = nil) async {
        self.anchorDate = anchorDate
        loadedEntries = []
        hasMore = true
        await loadNextPage(modelContext: modelContext)
    }

    func loadNextPage(modelContext: ModelContext) async {
        guard hasMore, !isLoadingPage else { return }
        isLoadingPage = true
        defer { isLoadingPage = false }

        do {
            var descriptor: FetchDescriptor<DiaryEntry>
            if let anchorDate {
                descriptor = FetchDescriptor<DiaryEntry>(
                    predicate: #Predicate { !$0.isTombstoned && $0.createdAt <= anchorDate },
                    sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
                )
            } else {
                descriptor = FetchDescriptor<DiaryEntry>(
                    predicate: #Predicate { !$0.isTombstoned },
                    sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
                )
            }
            descriptor.fetchLimit = pageSize
            descriptor.fetchOffset = loadedEntries.count

            let page = try modelContext.fetch(descriptor)
            loadedEntries.append(contentsOf: page)
            hasMore = page.count == pageSize
        } catch {
            hasMore = false
        }
    }

    func shouldLoadMore(afterAppearing entry: DiaryEntry) -> Bool {
        hasMore && loadedEntries.last?.id == entry.id
    }
}

private struct TimelineSection: Identifiable {
    let id: String
    let title: String
    let entries: [DiaryEntry]

    static func group(_ entries: [DiaryEntry], calendar: Calendar = .current) -> [TimelineSection] {
        var grouped: [DateComponents: [DiaryEntry]] = [:]

        for entry in entries {
            let components = calendar.dateComponents([.year, .month], from: entry.createdAt)
            grouped[components, default: []].append(entry)
        }

        return grouped.compactMap { components, entries in
            guard let year = components.year,
                  let month = components.month,
                  let date = calendar.date(from: components) else {
                return nil
            }

            return TimelineSection(
                id: "\(year)-\(String(format: "%02d", month))",
                title: date.formatted(.dateTime.month(.wide).year()),
                entries: entries.sorted { $0.createdAt > $1.createdAt }
            )
        }
        .sorted { first, second in
            guard let firstEntry = first.entries.first,
                  let secondEntry = second.entries.first else {
                return first.title > second.title
            }

            return firstEntry.createdAt > secondEntry.createdAt
        }
    }
}

private struct TimelineSectionHeader: View {
    let section: TimelineSection

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(section.title)
                    .font(.title3.weight(.semibold))

                Text(section.entries.count == 1 ? "1 entry" : "\(section.entries.count) entries")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Rectangle()
                .fill(Color.secondary.opacity(0.18))
                .frame(height: 1)
                .frame(maxWidth: 96)
        }
        .padding(.top, 12)
        .padding(.bottom, 4)
        .textCase(nil)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(section.title), \(section.entries.count) entries")
    }
}

private struct TimelineEntryRow: View {
    let entry: DiaryEntry
    var pendingChange: PendingChange?
    let isToday: Bool

    private let thumbnailSize: CGFloat = 76

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            TimelineDateRail(date: entry.createdAt, isToday: isToday)

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(entry.displayTitle)
                                .font(.headline)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)

                            PendingChangeBadge(change: pendingChange)
                        }

                        Text(entry.displayExcerpt)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if let leadAttachment {
                        TimelineLeadMedia(attachment: leadAttachment, size: thumbnailSize)
                    }
                }

                TimelineMetadataStrip(entry: entry)
            }
            .padding(.vertical, 12)
            .padding(.trailing, 2)
        }
        .accessibilityElement(children: .combine)
    }

    private var leadAttachment: DiaryAttachment? {
        entry.attachments.first { attachment in
            attachment.localRelativePath != nil && (attachment.isImage || attachment.isVideo)
        }
    }
}

private struct TimelineDateRail: View {
    let date: Date
    let isToday: Bool

    var body: some View {
        VStack(spacing: 5) {
            Text(dayText)
                .font(.title2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(isToday ? Color.accentColor : Color.primary)

            Text(monthWeekdayText)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)

            Circle()
                .fill(isToday ? Color.accentColor : Color.clear)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)

            Rectangle()
                .fill(isToday ? Color.accentColor.opacity(0.38) : Color.secondary.opacity(0.22))
                .frame(width: 2)
                .frame(height: 30)
                .accessibilityHidden(true)
        }
        .frame(width: 56)
        .accessibilityLabel(accessibilityDate)
    }

    private var dayText: String {
        date.formatted(.dateTime.day(.twoDigits))
    }

    private var monthWeekdayText: String {
        date.formatted(.dateTime.month(.abbreviated)) + "\n" + date.formatted(.dateTime.weekday(.abbreviated))
    }

    private var accessibilityDate: String {
        if isToday {
            return "Today, \(date.formatted(date: .complete, time: .omitted))"
        }

        return date.formatted(date: .complete, time: .omitted)
    }
}

private struct TimelineMetadataStrip: View {
    let entry: DiaryEntry

    var body: some View {
        HStack(spacing: 6) {
            if entry.attachments.count > 0 {
                TimelineChip(text: "\(entry.attachments.count)", systemImage: "paperclip")
            }

            ForEach(entry.entryContext.summaryChips.prefix(2), id: \.self) { chip in
                TimelineChip(text: chip, systemImage: "sparkles")
            }
        }
        .lineLimit(1)
    }
}

private struct TimelineChip: View {
    let text: String
    let systemImage: String?

    var body: some View {
        Group {
            if let systemImage {
                Label(text, systemImage: systemImage)
                    .labelStyle(.titleAndIcon)
            } else {
                Text(text)
            }
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary, in: Capsule())
    }
}

private struct TimelineLeadMedia: View {
    let attachment: DiaryAttachment
    let size: CGFloat

    private let mediaStore = LocalMediaStore()

    var body: some View {
        Group {
            if let url = localURL(for: attachment) {
                if attachment.isImage {
                    TimelineImageThumbnail(url: url)
                } else if attachment.isVideo {
                    TimelineVideoThumbnail(url: url)
                }
            } else {
                EmptyView()
            }
        }
        .frame(width: size, height: size)
        .background(.quaternary)
        .clipShape(.rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
        }
        .accessibilityLabel(attachment.filename)
    }

    private func localURL(for attachment: DiaryAttachment) -> URL? {
        guard let path = attachment.localRelativePath else {
            return nil
        }

        return try? mediaStore.fileURL(relativePath: path)
    }
}

private struct TimelineImageThumbnail: View {
    let url: URL

    var body: some View {
        LocalMediaThumbnailView(
            url: url,
            kind: .image,
            maxPixelSize: 240,
            contentMode: .fill,
            placeholderSystemImage: "photo"
        )
    }
}

private struct TimelineVideoThumbnail: View {
    let url: URL

    var body: some View {
        ZStack {
            LocalMediaThumbnailView(
                url: url,
                kind: .video,
                maxPixelSize: 240,
                contentMode: .fill,
                placeholderSystemImage: "video"
            )

            Image(systemName: "play.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .padding(8)
                .background(.black.opacity(0.62), in: Circle())
                .accessibilityHidden(true)
        }
    }
}

private struct QuickAppendView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState

    let syncCoordinator: SyncCoordinator

    @State private var text = ""
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var selectedMedia: [MediaUploadDraft] = []
    @State private var capturedContext: DiaryEntryContext = .empty
    @State private var isLoadingMedia = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var isConfirmingDiscard = false
    @State private var saveConfirmationCount = 0
    @FocusState private var isTextFocused: Bool

    init(syncCoordinator: SyncCoordinator) {
        self.syncCoordinator = syncCoordinator
        let draft = QuickAppendDraftStore.load()
        _text = State(initialValue: draft.text)
    }

    private var canSave: Bool {
        hasDraftContent
        && !isSaving
        && !isLoadingMedia
    }

    private var hasDraftContent: Bool {
        hasSavedDraftFields
        || !selectedMedia.isEmpty
    }

    private var hasSavedDraftFields: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasTemporaryMedia: Bool {
        !selectedMedia.isEmpty
    }

    private var draftSnapshot: QuickAppendDraft {
        QuickAppendDraft(text: text)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 180)
                        .textInputAutocapitalization(.sentences)
                        .focused($isTextFocused)
                        .overlay(alignment: .topLeading) {
                            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text("Add to today...")
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                }

                Section {
                    PhotosPicker(
                        selection: $selectedItems,
                        maxSelectionCount: 5,
                        matching: .any(of: [.images, .videos])
                    ) {
                        Label(
                            selectedMedia.isEmpty ? "Add Photo or Video" : "Replace Photo or Video",
                            systemImage: "camera"
                        )
                    }
                    .buttonStyle(.bordered)
                    .disabled(isSaving)

                    if isLoadingMedia {
                        Label("Preparing media", systemImage: "hourglass")
                            .foregroundStyle(.secondary)
                    }

                    SelectedMediaPreviewGrid(media: selectedMedia, remove: removeSelectedMedia)
                }

                ContextCaptureSection(context: $capturedContext, entryDate: .now)

                Section {
                    if hasSavedDraftFields {
                        Label("Draft saved locally", systemImage: "checkmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Label("Saves locally first, then syncs when the server is reachable.", systemImage: "checkmark.arrow.trianglehead.counterclockwise")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add Today")
            .navigationBarTitleDisplayMode(.inline)
            .defaultFocus($isTextFocused, true)
            .task {
                await Task.yield()
                isTextFocused = true
            }
            .onChange(of: draftSnapshot) { _, draft in
                QuickAppendDraftStore.save(draft)
            }
            .onChange(of: selectedItems) { _, newItems in
                Task {
                    await loadMedia(from: newItems)
                }
            }
            .onDisappear {
                cleanupSelectedMedia()
            }
            .interactiveDismissDisabled(hasTemporaryMedia)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        cancel()
                    }
                    .disabled(isSaving)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await save()
                        }
                    }
                    .disabled(!canSave)
                }
            }
            .alert("Entry Not Saved", isPresented: errorBinding) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(errorMessage ?? "The entry could not be saved.")
            }
            .confirmationDialog(
                "Discard Quick Entry?",
                isPresented: $isConfirmingDiscard,
                titleVisibility: .visible
            ) {
                Button("Discard Draft", role: .destructive) {
                    QuickAppendDraftStore.clear()
                    cleanupSelectedMedia()
                    selectedItems = []
                    dismiss()
                }

                Button("Keep Editing", role: .cancel) { }
            } message: {
                Text("Your text is saved locally. Selected media is temporary until you add the entry.")
            }
            .sensoryFeedback(.success, trigger: saveConfirmationCount)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding {
            errorMessage != nil
        } set: { isPresented in
            if !isPresented {
                errorMessage = nil
            }
        }
    }

    private func save() async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !selectedMedia.isEmpty else { return }

        isSaving = true
        defer { isSaving = false }

        do {
            _ = try await DiaryIntentActions.appendToToday(
                text: trimmed,
                media: selectedMedia,
                entryContext: capturedContext,
                context: modelContext,
                appState: appState,
                coordinator: syncCoordinator,
                syncImmediately: false
            )
            QuickAppendDraftStore.clear()
            text = ""
            capturedContext = .empty
            cleanupSelectedMedia()
            selectedItems = []
            saveConfirmationCount += 1
            dismiss()
            startBackgroundSync()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func cancel() {
        guard hasDraftContent || hasTemporaryMedia else {
            dismiss()
            return
        }

        isConfirmingDiscard = true
    }

    private func loadMedia(from items: [PhotosPickerItem]) async {
        isLoadingMedia = true
        defer { isLoadingMedia = false }

        cleanupSelectedMedia()
        do {
            selectedMedia = try await MediaDraftLoader.loadMedia(from: items)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func removeSelectedMedia(_ media: MediaUploadDraft) {
        try? FileManager.default.removeItem(at: media.fileURL)
        selectedMedia.removeAll { $0.id == media.id }
        selectedItems.removeAll { $0.itemIdentifier == media.id }
    }

    private func cleanupSelectedMedia() {
        for media in selectedMedia {
            try? FileManager.default.removeItem(at: media.fileURL)
        }
        selectedMedia = []
    }

    private func startBackgroundSync() {
        Task {
            await syncCoordinator.sync(modelContext: modelContext, appState: appState)
            DiaryWidgetPublisher.refresh(modelContext: modelContext)
        }
    }
}

private struct NewEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState

    let syncCoordinator: SyncCoordinator

    @State private var createdAt = Date()
    @State private var title = ""
    @State private var bodyMarkdown = ""
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var selectedMedia: [MediaUploadDraft] = []
    @State private var capturedContext: DiaryEntryContext = .empty
    @State private var isLoadingMedia = false
    @State private var errorMessage: String?
    @State private var isConfirmingMediaDiscard = false

    init(syncCoordinator: SyncCoordinator) {
        self.syncCoordinator = syncCoordinator

        if let draft = NewEntryDraftStore.load() {
            _createdAt = State(initialValue: draft.createdAt)
            _title = State(initialValue: draft.title)
            _bodyMarkdown = State(initialValue: draft.bodyMarkdown)
        }
    }

    private var canCreate: Bool {
        !bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !syncCoordinator.isSyncing
        && !isLoadingMedia
    }

    private var draftSnapshot: NewEntryDraft {
        NewEntryDraft(
            createdAt: createdAt,
            title: title,
            bodyMarkdown: bodyMarkdown
        )
    }

    private var hasSavedDraftContent: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasTemporaryMedia: Bool {
        !selectedMedia.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Entry") {
                    DatePicker("Date", selection: $createdAt)
                    TextField("Title", text: $title)
                        .textInputAutocapitalization(.sentences)

                    if hasSavedDraftContent {
                        Label("Draft saved locally", systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Markdown") {
                    MarkdownEditorField(text: $bodyMarkdown, minHeight: 240)
                    #if canImport(JournalingSuggestions)
                    JournalingMomentPicker { moment in
                        appendMoment(moment)
                    }
                    #endif
                }

                Section("Media") {
                    PhotosPicker(
                        selection: $selectedItems,
                        maxSelectionCount: 5,
                        matching: .any(of: [.images, .videos])
                    ) {
                        Label("Add Photos or Videos", systemImage: "photo.on.rectangle.angled")
                    }

                    if isLoadingMedia {
                        Label("Preparing media", systemImage: "hourglass")
                            .foregroundStyle(.secondary)
                    }

                    SelectedMediaPreviewGrid(media: selectedMedia, remove: removeSelectedMedia)
                }

                ContextCaptureSection(context: $capturedContext, entryDate: createdAt)
            }
            .navigationTitle("New Entry")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: draftSnapshot) { _, draft in
                NewEntryDraftStore.save(draft)
            }
            .onChange(of: selectedItems) { _, newItems in
                Task {
                    await loadMedia(from: newItems)
                }
            }
            .onDisappear {
                cleanupSelectedMedia()
            }
            .interactiveDismissDisabled(hasTemporaryMedia)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        cancel()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task {
                            await createEntry()
                        }
                    }
                    .disabled(!canCreate)
                }
            }
            .alert("Entry Not Saved", isPresented: errorBinding) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(errorMessage ?? "The entry could not be saved.")
            }
            .confirmationDialog(
                "Discard Selected Media?",
                isPresented: $isConfirmingMediaDiscard,
                titleVisibility: .visible
            ) {
                Button("Discard Media", role: .destructive) {
                    cleanupSelectedMedia()
                    selectedItems = []
                    dismiss()
                }

                Button("Keep Editing", role: .cancel) { }
            } message: {
                Text("Text and date stay saved locally. Selected media is temporary until you create the entry.")
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding {
            errorMessage != nil
        } set: { isPresented in
            if !isPresented {
                errorMessage = nil
            }
        }
    }

    private func createEntry() async {
        let draft = EntryWriteDraft(
            createdAt: createdAt,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            bodyMarkdown: bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines),
            context: capturedContext
        )

        do {
            _ = try await syncCoordinator.createEntry(
                draft: draft,
                media: selectedMedia,
                modelContext: modelContext,
                appState: appState
            )
            NewEntryDraftStore.clear()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func cancel() {
        guard hasTemporaryMedia else {
            dismiss()
            return
        }

        isConfirmingMediaDiscard = true
    }

    private func appendMoment(_ moment: String) {
        let trimmed = moment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            bodyMarkdown = trimmed
        } else {
            bodyMarkdown += "\n\n" + trimmed
        }
    }

    private func loadMedia(from items: [PhotosPickerItem]) async {
        isLoadingMedia = true
        defer { isLoadingMedia = false }

        cleanupSelectedMedia()
        do {
            selectedMedia = try await MediaDraftLoader.loadMedia(from: items)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func removeSelectedMedia(_ media: MediaUploadDraft) {
        try? FileManager.default.removeItem(at: media.fileURL)
        selectedMedia.removeAll { $0.id == media.id }
        selectedItems.removeAll { $0.itemIdentifier == media.id }
    }

    private func cleanupSelectedMedia() {
        for media in selectedMedia {
            try? FileManager.default.removeItem(at: media.fileURL)
        }
        selectedMedia = []
    }

}

private enum MediaDraftLoader {
    static func loadMedia(from items: [PhotosPickerItem]) async throws -> [MediaUploadDraft] {
        var uploads: [MediaUploadDraft] = []
        for item in items {
            guard let mediaFile = try await item.loadTransferable(type: PickedMediaFile.self) else {
                continue
            }

            let contentType = item.supportedContentTypes.first ?? .data
            uploads.append(
                MediaUploadDraft(
                    id: item.itemIdentifier ?? UUID().uuidString,
                    filename: filename(for: contentType),
                    contentType: contentType.preferredMIMEType ?? "application/octet-stream",
                    fileURL: mediaFile.url,
                    byteCount: byteCount(for: mediaFile.url)
                )
            )
        }

        return uploads
    }

    private static func byteCount(for fileURL: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        return attributes?[.size] as? Int ?? 0
    }

    private static func filename(for contentType: UTType) -> String {
        let prefix = contentType.conforms(to: .movie) ? "video" : "photo"
        let suffix = UUID().uuidString.prefix(8)
        let fileExtension = contentType.preferredFilenameExtension ?? "dat"
        return "\(prefix)-\(suffix).\(fileExtension)"
    }
}

private struct PickedMediaFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .item) { received in
            let copyURL = FileManager.default.temporaryDirectory
                .appending(path: "diary-picked-\(UUID().uuidString)-\(received.file.lastPathComponent)")
            if FileManager.default.fileExists(atPath: copyURL.path) {
                try FileManager.default.removeItem(at: copyURL)
            }
            try FileManager.default.copyItem(at: received.file, to: copyURL)
            return PickedMediaFile(url: copyURL)
        }
    }
}

private struct NewEntryDraft: Codable, Equatable {
    var createdAt: Date
    var title: String
    var bodyMarkdown: String
}

private struct QuickAppendDraft: Codable, Equatable {
    var text: String
}

private enum QuickAppendDraftStore {
    private static let key = "quickAppendDraft"

    static func load() -> QuickAppendDraft {
        if let data = UserDefaults.standard.data(forKey: key),
           let draft = try? JSONDecoder().decode(QuickAppendDraft.self, from: data) {
            return draft
        }

        return QuickAppendDraft(text: UserDefaults.standard.string(forKey: key) ?? "")
    }

    static func save(_ draft: QuickAppendDraft) {
        if draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            clear()
            return
        }

        if let data = try? JSONEncoder().encode(draft) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

private enum NewEntryDraftStore {
    private static let key = "newEntryDraft"

    static func load() -> NewEntryDraft? {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return nil
        }
        return try? JSONDecoder().decode(NewEntryDraft.self, from: data)
    }

    static func save(_ draft: NewEntryDraft) {
        let isEmpty = draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draft.bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isEmpty {
            clear()
            return
        }

        if let data = try? JSONEncoder().encode(draft) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

private struct SyncStatusBanner: View {
    let status: SyncStatus

    var body: some View {
        Label(status.label, systemImage: status.symbolName)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial)
    }
}

#Preview {
    TimelineView()
        .environment(AppState())
        .modelContainer(PreviewData.container)
}
