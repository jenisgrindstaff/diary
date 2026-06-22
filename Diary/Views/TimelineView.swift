import CoreTransferable
import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct TimelineView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @Query(
        filter: #Predicate<DiaryEntry> { $0.isTombstoned == false },
        sort: \DiaryEntry.createdAt,
        order: .reverse
    )
    private var entries: [DiaryEntry]
    @Query(sort: \PendingChange.createdAt, order: .forward) private var pendingChanges: [PendingChange]

    @State private var syncCoordinator = SyncCoordinator()
    @State private var isPresentingNewEntry = false

    private var pendingByEntryID: [String: PendingChange] {
        Dictionary(pendingChanges.map { ($0.entryID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    ContentUnavailableView(
                        "No Entries",
                        systemImage: "book.closed",
                        description: Text("Sync with your Markdown diary server to fill the offline cache.")
                    )
                } else {
                    List(entries) { entry in
                        NavigationLink(value: entry.id) {
                            EntryRow(entry: entry, pendingChange: pendingByEntryID[entry.id])
                        }
                        .listRowInsets(EdgeInsets(top: 10, leading: 18, bottom: 10, trailing: 18))
                    }
                    .listStyle(.plain)
                    .refreshable {
                        await syncCoordinator.sync(modelContext: modelContext, appState: appState)
                    }
                }
            }
            .navigationTitle("Diary")
            .navigationDestination(for: String.self) { entryID in
                EntryDetailResolver(entryID: entryID)
            }
            .sheet(isPresented: $isPresentingNewEntry) {
                NewEntryView(syncCoordinator: syncCoordinator)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New Entry", systemImage: "square.and.pencil") {
                        isPresentingNewEntry = true
                    }
                    .accessibilityHint("Creates a diary entry on the Markdown diary server.")
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
}

private struct NewEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @Query(
        filter: #Predicate<DiaryEntry> { $0.isTombstoned == false },
        sort: \DiaryEntry.updatedAt,
        order: .reverse
    )
    private var suggestionEntries: [DiaryEntry]

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
        DraftSuggestions(entries: suggestionEntries)
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
