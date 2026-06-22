import CoreTransferable
import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct EntryDetailResolver: View {
    @Query private var entries: [DiaryEntry]

    init(entryID: String) {
        _entries = Query(filter: #Predicate<DiaryEntry> { $0.id == entryID })
    }

    var body: some View {
        if let entry = entries.first {
            EntryDetailView(entry: entry)
        } else {
            ContentUnavailableView("Entry Missing", systemImage: "doc.questionmark")
        }
    }
}

struct EntryDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState

    let entry: DiaryEntry
    @Query(sort: \PendingChange.createdAt, order: .forward) private var pendingChanges: [PendingChange]

    @State private var syncCoordinator = SyncCoordinator()
    @State private var isPresentingEdit = false
    @State private var isConfirmingDelete = false
    @State private var isDeleting = false
    @State private var deleteErrorMessage: String?

    private var pendingChange: PendingChange? {
        pendingChanges.first { $0.entryID == entry.id }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let pendingChange {
                    PendingDetailBanner(change: pendingChange)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(entry.createdAt, format: .dateTime.weekday(.wide).month(.wide).day().year())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(entry.displayTitle)
                        .font(.largeTitle)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !entry.people.isEmpty || !entry.tags.isEmpty {
                    MetadataSection(entry: entry)
                }

                if !entry.subjectDetails.isEmpty {
                    SubjectDetailsView(subjectDetails: entry.subjectDetails)
                }

                if !entry.attachments.isEmpty {
                    AttachmentGridView(attachments: entry.attachments)
                }

                MarkdownText(markdown: entry.bodyMarkdown)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 96)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(entry.createdAt.formatted(date: .abbreviated, time: .omitted))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Delete", systemImage: "trash", role: .destructive) {
                    isConfirmingDelete = true
                }
                .disabled(isDeleting || syncCoordinator.isSyncing)

                Button("Edit", systemImage: "square.and.pencil") {
                    isPresentingEdit = true
                }
                .disabled(isDeleting || syncCoordinator.isSyncing)
            }
        }
        .sheet(isPresented: $isPresentingEdit) {
            EditEntryView(entry: entry, syncCoordinator: syncCoordinator)
        }
        .confirmationDialog(
            "Delete Entry?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Entry", role: .destructive) {
                Task {
                    await deleteEntry()
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This moves the entry to trash on the server and removes it from this device's timeline.")
        }
        .alert("Entry Not Deleted", isPresented: deleteErrorBinding) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(deleteErrorMessage ?? "The entry could not be deleted.")
        }
    }

    private var deleteErrorBinding: Binding<Bool> {
        Binding {
            deleteErrorMessage != nil
        } set: { isPresented in
            if !isPresented {
                deleteErrorMessage = nil
            }
        }
    }

    private func deleteEntry() async {
        isDeleting = true
        defer { isDeleting = false }

        do {
            try await syncCoordinator.deleteEntry(
                id: entry.id,
                modelContext: modelContext,
                appState: appState
            )
            dismiss()
        } catch {
            deleteErrorMessage = error.localizedDescription
        }
    }
}

private struct PendingDetailBanner: View {
    let change: PendingChange

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: change.isFailed ? "exclamationmark.triangle.fill" : "clock")
                .foregroundStyle(change.isFailed ? .red : .orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(change.isFailed ? "Sync Needs Attention" : "Waiting to Sync")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Text(change.lastError ?? change.summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((change.isFailed ? Color.red : Color.orange).opacity(0.1), in: .rect(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

private struct EditEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState

    @Query private var currentEntries: [DiaryEntry]
    @Query(sort: \DiarySuggestion.count, order: .reverse) private var suggestions: [DiarySuggestion]

    let syncCoordinator: SyncCoordinator

    private let entryID: String

    @State private var createdAt: Date
    @State private var expectedServerRevision: String
    @State private var attachmentsSnapshot: [DiaryAttachment]
    @State private var title: String
    @State private var peopleText: String
    @State private var tagsText: String
    @State private var bodyMarkdown: String
    @State private var removedAttachmentIDs: Set<String> = []
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var selectedMedia: [MediaUploadDraft] = []
    @State private var isLoadingMedia = false
    @State private var errorMessage: String?
    @State private var conflictMessage: String?
    @State private var isShowingConflictAlert = false

    init(entry: DiaryEntry, syncCoordinator: SyncCoordinator) {
        self.syncCoordinator = syncCoordinator
        self.entryID = entry.id
        let entryID = entry.id
        _currentEntries = Query(filter: #Predicate<DiaryEntry> { $0.id == entryID })
        _createdAt = State(initialValue: entry.createdAt)
        _expectedServerRevision = State(initialValue: entry.serverRevision)
        _attachmentsSnapshot = State(initialValue: entry.attachments)
        _title = State(initialValue: entry.title)
        _peopleText = State(initialValue: entry.people.joined(separator: ", "))
        _tagsText = State(initialValue: entry.tags.joined(separator: ", "))
        _bodyMarkdown = State(initialValue: entry.bodyMarkdown)
    }

    private var canSave: Bool {
        !bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !syncCoordinator.isSyncing
        && !isLoadingMedia
    }

    private var visibleAttachments: [DiaryAttachment] {
        attachmentsSnapshot.filter { !removedAttachmentIDs.contains($0.id) }
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
                }

                Section("Markdown") {
                    MarkdownEditorField(text: $bodyMarkdown, minHeight: 280)
                }

                Section("Media") {
                    if !visibleAttachments.isEmpty {
                        ForEach(visibleAttachments) { attachment in
                            HStack {
                                Label(attachment.filename, systemImage: attachment.isVideo ? "video" : "photo")
                                    .lineLimit(1)

                                Spacer()

                                Button("Remove", systemImage: "trash", role: .destructive) {
                                    removedAttachmentIDs.insert(attachment.id)
                                }
                                .labelStyle(.iconOnly)
                                .accessibilityLabel("Remove \(attachment.filename)")
                            }
                        }
                    }

                    if !removedAttachmentIDs.isEmpty {
                        Button("Restore Removed Media", systemImage: "arrow.uturn.backward") {
                            removedAttachmentIDs.removeAll()
                        }
                    }

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

                if let conflictMessage {
                    Section {
                        Label(conflictMessage, systemImage: "arrow.triangle.2.circlepath")
                            .foregroundStyle(.secondary)

                        Button("Reload Server Copy", systemImage: "arrow.clockwise") {
                            reloadDraftFromCurrentEntry()
                        }
                    }
                }
            }
            .navigationTitle("Edit Entry")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: selectedItems) { _, newItems in
                Task {
                    await loadMedia(from: newItems)
                }
            }
            .onDisappear {
                cleanupSelectedMedia()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
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
            .alert("Server Copy Changed", isPresented: conflictBinding) {
                Button("Reload Server Copy") {
                    reloadDraftFromCurrentEntry()
                }

                Button("Keep Editing", role: .cancel) { }
            } message: {
                Text("The server has a newer version of this entry. Reload before saving again.")
            }
        }
    }

    private var currentEntry: DiaryEntry? {
        currentEntries.first
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

    private var conflictBinding: Binding<Bool> {
        Binding {
            isShowingConflictAlert
        } set: { isPresented in
            isShowingConflictAlert = isPresented
        }
    }

    private func save() async {
        let draft = EntryWriteDraft(
            createdAt: createdAt,
            expectedServerRevision: expectedServerRevision,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            bodyMarkdown: bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines),
            people: Self.cleanList(peopleText),
            tags: Self.cleanList(tagsText)
        )

        do {
            try await syncCoordinator.updateEntry(
                id: entryID,
                draft: draft,
                removedAttachmentIDs: Array(removedAttachmentIDs),
                media: selectedMedia,
                modelContext: modelContext,
                appState: appState
            )
            dismiss()
        } catch SyncCoordinatorError.entryConflict(let message) {
            conflictMessage = message
            isShowingConflictAlert = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reloadDraftFromCurrentEntry() {
        guard let currentEntry else {
            errorMessage = "The latest server copy is not available on this device yet."
            return
        }

        cleanupSelectedMedia()
        selectedItems = []
        removedAttachmentIDs = []
        createdAt = currentEntry.createdAt
        expectedServerRevision = currentEntry.serverRevision
        attachmentsSnapshot = currentEntry.attachments
        title = currentEntry.title
        peopleText = currentEntry.people.joined(separator: ", ")
        tagsText = currentEntry.tags.joined(separator: ", ")
        bodyMarkdown = currentEntry.bodyMarkdown
        conflictMessage = nil
        isShowingConflictAlert = false
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
                guard let mediaFile = try await item.loadTransferable(type: EntryEditPickedMediaFile.self) else {
                    continue
                }

                let contentType = item.supportedContentTypes.first ?? .data
                uploads.append(
                    MediaUploadDraft(
                        id: item.itemIdentifier ?? UUID().uuidString,
                        filename: Self.filename(for: contentType),
                        contentType: contentType.preferredMIMEType ?? "application/octet-stream",
                        fileURL: mediaFile.url,
                        byteCount: Self.byteCount(for: mediaFile.url)
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

private struct EntryEditPickedMediaFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .item) { received in
            let copyURL = FileManager.default.temporaryDirectory
                .appending(path: "diary-edit-picked-\(UUID().uuidString)-\(received.file.lastPathComponent)")
            if FileManager.default.fileExists(atPath: copyURL.path) {
                try FileManager.default.removeItem(at: copyURL)
            }
            try FileManager.default.copyItem(at: received.file, to: copyURL)
            return EntryEditPickedMediaFile(url: copyURL)
        }
    }
}

private struct SubjectDetailsView: View {
    let subjectDetails: [DiarySubjectDetail]

    private var visibleDetails: [DiarySubjectDetail] {
        subjectDetails.filter { !$0.displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        if !visibleDetails.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(visibleDetails, id: \.stableID) { detail in
                        SubjectChip(detail: detail)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Subject details")
        }
    }
}

private struct SubjectChip: View {
    let detail: DiarySubjectDetail

    var body: some View {
        HStack(spacing: 6) {
            if !detail.name.isEmpty {
                Text(detail.name)
                    .fontWeight(.semibold)
            }

            Text(detail.displayText)
                .foregroundStyle(.secondary)
        }
        .font(.footnote)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.quaternary, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

private struct MetadataSection: View {
    let entry: DiaryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !entry.people.isEmpty {
                LabeledContent("People") {
                    FlowText(items: entry.people)
                }
            }

            if !entry.tags.isEmpty {
                LabeledContent("Tags") {
                    FlowText(items: entry.tags.map { "#\($0)" })
                }
            }
        }
        .font(.subheadline)
    }
}

private struct FlowText: View {
    let items: [String]

    var body: some View {
        Text(items.joined(separator: ", "))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct MarkdownText: View {
    let markdown: String

    var body: some View {
        Text(attributedString)
            .font(.body)
            .lineSpacing(5)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var attributedString: AttributedString {
        (try? AttributedString(markdown: markdown)) ?? AttributedString(markdown)
    }
}
