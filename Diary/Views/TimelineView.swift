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

    private var pendingByEntryID: [String: PendingChange] {
        Dictionary(pendingChanges.map { ($0.entryID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private var sections: [TimelineSection] {
        TimelineSection.group(timelinePager.loadedEntries)
    }

    var body: some View {
        NavigationStack {
            Group {
                if timelinePager.loadedEntries.isEmpty && !timelinePager.isLoadingPage {
                    ContentUnavailableView(
                        "No Entries",
                        systemImage: "book.closed",
                        description: Text("Sync with your Markdown diary server to fill the offline cache.")
                    )
                } else {
                    List {
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
                                        loadMoreIfNeeded(entry)
                                    }
                                }
                            } header: {
                                TimelineSectionHeader(section: section)
                            }
                        }

                        if timelinePager.hasMore {
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
                    .refreshable {
                        await syncCoordinator.sync(modelContext: modelContext, appState: appState)
                        await timelinePager.reload(modelContext: modelContext)
                        DiaryWidgetPublisher.refresh(modelContext: modelContext)
                    }
                }
            }
            .navigationTitle("Diary")
            .navigationDestination(for: String.self) { entryID in
                EntryDetailResolver(entryID: entryID)
            }
            .sheet(item: $composerMode, onDismiss: {
                Task {
                    await timelinePager.reload(modelContext: modelContext)
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
                await timelinePager.reload(modelContext: modelContext)
                presentNewEntryIfRequested()
                DiaryWidgetPublisher.refresh(modelContext: modelContext)
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
                        }
                    }
                    .disabled(syncCoordinator.isSyncing)
                    .accessibilityHint("Downloads the latest entries from the Markdown diary server.")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if case .failed = appState.syncStatus {
                    SyncStatusBanner(status: appState.syncStatus)
                }
            }
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
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var isTextFocused: Bool

    private var canSave: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSaving
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
                    Label("Saves locally first, then syncs when the server is reachable.", systemImage: "checkmark.arrow.trianglehead.counterclockwise")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add Today")
            .navigationBarTitleDisplayMode(.inline)
            .defaultFocus($isTextFocused, true)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isSaving)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
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
        guard !trimmed.isEmpty else { return }

        isSaving = true
        defer { isSaving = false }

        do {
            _ = try await DiaryIntentActions.appendToToday(
                text: trimmed,
                context: modelContext,
                appState: appState,
                coordinator: syncCoordinator
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
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
        var uploads: [MediaUploadDraft] = []
        for item in items {
            do {
                guard let mediaFile = try await item.loadTransferable(type: PickedMediaFile.self) else {
                    continue
                }

                let contentType = item.supportedContentTypes.first ?? .data
                let byteCount = Self.byteCount(for: mediaFile.url)
                uploads.append(
                    MediaUploadDraft(
                        id: item.itemIdentifier ?? UUID().uuidString,
                        filename: Self.filename(for: contentType),
                        contentType: contentType.preferredMIMEType ?? "application/octet-stream",
                        fileURL: mediaFile.url,
                        byteCount: byteCount
                    )
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        selectedMedia = uploads
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
