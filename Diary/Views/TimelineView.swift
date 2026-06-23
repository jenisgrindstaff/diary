import CoreTransferable
import Foundation
import AVFoundation
import ImageIO
import Observation
import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct TimelineView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @Query(sort: \PendingChange.createdAt, order: .forward) private var pendingChanges: [PendingChange]

    @State private var syncCoordinator = SyncCoordinator()
    @State private var timelinePager = TimelinePager()
    @State private var composerMode: EntryComposerMode?
    @State private var searchText = ""
    @State private var localSearchEntries: [DiaryEntry] = []
    @State private var serverSearchState = TimelineServerSearchState.idle
    @FocusState private var isSearchFocused: Bool

    private let localSearchLimit = 500

    private var pendingByEntryID: [String: PendingChange] {
        Dictionary(pendingChanges.map { ($0.entryID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private var sections: [TimelineSection] {
        TimelineSection.group(visibleEntries)
    }

    private var visibleEntries: [DiaryEntry] {
        isSearching ? searchResults : timelinePager.loadedEntries
    }

    private var searchResults: [DiaryEntry] {
        guard isSearching else {
            return localSearchEntries
        }

        return localSearchEntries.filter { entry in
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

    private var isSearching: Bool {
        !searchTerms.isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Group {
                    if visibleEntries.isEmpty && !isSearching && !timelinePager.isLoadingPage {
                        ContentUnavailableView(
                            "No Entries",
                            systemImage: "book.closed",
                            description: Text("Sync with your Markdown diary server to fill the offline cache.")
                        )
                    } else {
                        List {
                            if isSearching {
                                TimelineSearchControlRow(
                                    localResultCount: searchResults.count,
                                    totalCount: localSearchEntries.count,
                                    state: serverSearchState,
                                    isDisabled: syncCoordinator.isSyncing
                                ) {
                                    Task {
                                        await searchServer()
                                    }
                                }
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
                                            if !isSearching {
                                                loadMoreIfNeeded(entry)
                                            }
                                        }
                                    }
                                } header: {
                                    TimelineSectionHeader(section: section)
                                }
                            }

                            if timelinePager.hasMore && !isSearching {
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
                            if isSearching && searchResults.isEmpty {
                                ContentUnavailableView.search(text: searchText)
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
            .navigationDestination(for: String.self) { entryID in
                EntryDetailResolver(entryID: entryID)
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add Today", systemImage: "text.badge.plus") {
                        composerMode = .quick
                    }
                    .accessibilityHint("Quickly appends text to today's diary entry.")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Full Entry", systemImage: "square.and.pencil") {
                        composerMode = .full
                    }
                    .accessibilityHint("Creates a diary entry with date, metadata, and media.")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Sync", systemImage: appState.syncStatus.symbolName) {
                        Task {
                            await syncCoordinator.sync(modelContext: modelContext, appState: appState)
                            await reloadTimeline()
                            DiaryWidgetPublisher.refresh(modelContext: modelContext)
                        }
                    }
                    .disabled(syncCoordinator.isSyncing)
                    .accessibilityHint("Downloads the latest entries from the Markdown diary server.")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label("Settings", systemImage: "gear")
                    }
                    .accessibilityHint("Opens diary settings.")
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if case .failed = appState.syncStatus {
                        SyncStatusBanner(status: appState.syncStatus)
                    }

                    TimelineSearchField(text: $searchText, isFocused: $isSearchFocused)
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 8)
                .background(.bar)
            }
        }
    }

    private func reloadTimeline() async {
        await timelinePager.reload(modelContext: modelContext)
        loadLocalSearchEntries()
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

private struct TimelineSearchField: View {
    @Binding var text: String
    @FocusState.Binding var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search entries, tags, people", text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.plain)
                .submitLabel(.search)
                .focused($isFocused)

            if !text.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") {
                    text = ""
                    isFocused = true
                }
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(.quaternary, in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(isFocused ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.15), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }
}

private enum TimelineServerSearchState: Equatable {
    case idle
    case searching
    case completed(Int)
    case failed(String)
}

private struct TimelineSearchControlRow: View {
    let localResultCount: Int
    let totalCount: Int
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

@MainActor
@Observable
private final class TimelinePager {
    private let pageSize = 80

    private(set) var loadedEntries: [DiaryEntry] = []
    private(set) var hasMore = true
    private(set) var isLoadingPage = false

    func reload(modelContext: ModelContext) async {
        loadedEntries = []
        hasMore = true
        await loadNextPage(modelContext: modelContext)
    }

    func loadNextPage(modelContext: ModelContext) async {
        guard hasMore, !isLoadingPage else { return }
        isLoadingPage = true
        defer { isLoadingPage = false }

        do {
            var descriptor = FetchDescriptor<DiaryEntry>(
                predicate: #Predicate { !$0.isTombstoned },
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
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
        VStack(spacing: 6) {
            Text(dayText)
                .font(.title2.weight(.bold))
                .monospacedDigit()

            Text(monthWeekdayText)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)

            if isToday {
                Text("Today")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.accentColor, in: Capsule())
            }

            Rectangle()
                .fill(isToday ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.22))
                .frame(width: 2)
                .frame(height: isToday ? 24 : 36)
                .accessibilityHidden(true)
        }
        .frame(width: 50)
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
            ForEach(entry.people.prefix(2), id: \.self) { person in
                TimelineChip(text: person, systemImage: "person")
            }

            ForEach(entry.tags.prefix(2), id: \.self) { tag in
                TimelineChip(text: "#\(tag)", systemImage: nil)
            }

            if entry.attachments.count > 0 {
                TimelineChip(text: "\(entry.attachments.count)", systemImage: "paperclip")
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

    @State private var thumbnail: UIImage?
    @State private var didFail = false

    var body: some View {
        Group {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                TimelineMediaPlaceholder(systemImage: "photo", isLoading: !didFail)
            }
        }
        .task(id: url) {
            didFail = false
            thumbnail = await TimelineThumbnailLoader.imageThumbnail(for: url)
            didFail = thumbnail == nil
        }
    }
}

private struct TimelineVideoThumbnail: View {
    let url: URL

    @State private var thumbnail: UIImage?
    @State private var didFail = false

    var body: some View {
        ZStack {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                TimelineMediaPlaceholder(systemImage: "video", isLoading: !didFail)
            }

            Image(systemName: "play.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .padding(8)
                .background(.black.opacity(0.62), in: Circle())
                .accessibilityHidden(true)
        }
        .task(id: url) {
            didFail = false
            thumbnail = await TimelineThumbnailLoader.videoThumbnail(for: url)
            didFail = thumbnail == nil
        }
    }
}

private struct TimelineMediaPlaceholder: View {
    let systemImage: String
    let isLoading: Bool

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.quaternary)

            if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private enum TimelineThumbnailLoader {
    static func imageThumbnail(for url: URL) async -> UIImage? {
        await Task.detached(priority: .utility) {
            let sourceOptions: [CFString: Any] = [
                kCGImageSourceShouldCache: false
            ]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
                return nil
            }

            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 180,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return nil
            }

            return UIImage(cgImage: cgImage)
        }.value
    }

    static func videoThumbnail(for url: URL) async -> UIImage? {
        await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 240, height: 240)

            return await withCheckedContinuation { continuation in
                generator.generateCGImageAsynchronously(for: .zero) { cgImage, _, error in
                    guard error == nil, let cgImage else {
                        continuation.resume(returning: nil)
                        return
                    }

                    continuation.resume(returning: UIImage(cgImage: cgImage))
                }
            }
        }.value
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
    @State private var isLoadingMedia = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var isConfirmingDiscard = false
    @State private var savedMessage: String?
    @FocusState private var isTextFocused: Bool

    init(syncCoordinator: SyncCoordinator) {
        self.syncCoordinator = syncCoordinator
        _text = State(initialValue: QuickAppendDraftStore.load())
    }

    private var canSave: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !isSaving
        && !isLoadingMedia
    }

    private var hasDraftContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasTemporaryMedia: Bool {
        !selectedMedia.isEmpty
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

                Section("Media") {
                    PhotosPicker(
                        selection: $selectedItems,
                        maxSelectionCount: 5,
                        matching: .any(of: [.images, .videos])
                    ) {
                        Label("Add Photos or Videos", systemImage: "photo.on.rectangle.angled")
                    }
                    .disabled(isSaving)

                    if isLoadingMedia {
                        Label("Preparing media", systemImage: "hourglass")
                            .foregroundStyle(.secondary)
                    }

                    SelectedMediaPreviewGrid(media: selectedMedia, remove: removeSelectedMedia)
                }

                Section {
                    if let savedMessage {
                        Label(savedMessage, systemImage: "checkmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if hasDraftContent {
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
            .onChange(of: text) { _, newText in
                QuickAppendDraftStore.save(newText)
                if !newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    savedMessage = nil
                }
            }
            .onChange(of: selectedItems) { _, newItems in
                if !newItems.isEmpty {
                    savedMessage = nil
                }
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
                    Button("Add Another") {
                        Task {
                            await save(shouldDismiss: false)
                        }
                    }
                    .disabled(!canSave)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task {
                            await save(shouldDismiss: true)
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

    private func save(shouldDismiss: Bool) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isSaving = true
        defer { isSaving = false }

        do {
            _ = try await DiaryIntentActions.appendToToday(
                text: trimmed,
                media: selectedMedia,
                context: modelContext,
                appState: appState,
                coordinator: syncCoordinator
            )
            QuickAppendDraftStore.clear()
            text = ""
            cleanupSelectedMedia()
            selectedItems = []

            if shouldDismiss {
                dismiss()
            } else {
                savedMessage = "Added to today"
                isTextFocused = true
            }
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
}

private struct NewEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @Query(sort: \DiarySuggestion.count, order: .reverse) private var suggestions: [DiarySuggestion]

    let syncCoordinator: SyncCoordinator

    @State private var createdAt = Date()
    @State private var title = ""
    @State private var peopleText = ""
    @State private var tagsText = ""
    @State private var bodyMarkdown = ""
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var selectedMedia: [MediaUploadDraft] = []
    @State private var isLoadingMedia = false
    @State private var errorMessage: String?
    @State private var isConfirmingMediaDiscard = false

    init(syncCoordinator: SyncCoordinator) {
        self.syncCoordinator = syncCoordinator

        if let draft = NewEntryDraftStore.load() {
            _createdAt = State(initialValue: draft.createdAt)
            _title = State(initialValue: draft.title)
            _peopleText = State(initialValue: draft.peopleText)
            _tagsText = State(initialValue: draft.tagsText)
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
            peopleText: peopleText,
            tagsText: tagsText,
            bodyMarkdown: bodyMarkdown
        )
    }

    private var hasSavedDraftContent: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !peopleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !tagsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasTemporaryMedia: Bool {
        !selectedMedia.isEmpty
    }

    private var draftSuggestions: DraftSuggestions {
        DraftSuggestions(suggestions: suggestions)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Entry") {
                    DatePicker("Date", selection: $createdAt)
                    TextField("Title", text: $title)
                        .textInputAutocapitalization(.sentences)
                    TextField("People", text: $peopleText)
                        .textInputAutocapitalization(.words)
                    TextField("Tags", text: $tagsText)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                    DraftSuggestionStrip(
                        peopleText: $peopleText,
                        tagsText: $tagsText,
                        suggestions: draftSuggestions
                    )
                    DraftTokenPreview(peopleText: peopleText, tagsText: tagsText)

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
                Text("Text, date, people, and tags stay saved locally. Selected media is temporary until you create the entry.")
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
            people: Self.cleanList(peopleText),
            tags: Self.cleanList(tagsText)
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

    private static func cleanList(_ value: String) -> [String] {
        DraftTokenPreview.cleanList(value)
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
    var peopleText: String
    var tagsText: String
    var bodyMarkdown: String
}

private enum QuickAppendDraftStore {
    private static let key = "quickAppendDraft"

    static func load() -> String {
        UserDefaults.standard.string(forKey: key) ?? ""
    }

    static func save(_ text: String) {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            clear()
            return
        }

        UserDefaults.standard.set(text, forKey: key)
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
            && draft.peopleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draft.tagsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
