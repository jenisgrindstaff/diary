import CoreTransferable
import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct EntryDetailResolver: View {
    @Environment(\.modelContext) private var modelContext

    @State private var currentEntryID: String
    @State private var entry: DiaryEntry?

    init(entryID: String) {
        _currentEntryID = State(initialValue: entryID)
    }

    var body: some View {
        Group {
            if let entry {
                EntryDetailView(entry: entry) { direction in
                    navigate(direction)
                }
            } else {
                ContentUnavailableView("Entry Missing", systemImage: "doc.questionmark")
            }
        }
        .task(id: currentEntryID) {
            loadEntry()
        }
    }

    private func loadEntry() {
        var descriptor = FetchDescriptor<DiaryEntry>(
            predicate: #Predicate { $0.id == currentEntryID }
        )
        descriptor.fetchLimit = 1
        entry = try? modelContext.fetch(descriptor).first
    }

    private func navigate(_ direction: EntryNavigationDirection) {
        guard let entry else { return }

        let descriptor: FetchDescriptor<DiaryEntry>
        switch direction {
        case .newer:
            descriptor = adjacentEntryDescriptor(
                predicateDate: entry.createdAt,
                isNewer: true
            )
        case .older:
            descriptor = adjacentEntryDescriptor(
                predicateDate: entry.createdAt,
                isNewer: false
            )
        }

        guard let nextEntry = try? modelContext.fetch(descriptor).first else { return }
        currentEntryID = nextEntry.id
    }

    private func adjacentEntryDescriptor(predicateDate: Date, isNewer: Bool) -> FetchDescriptor<DiaryEntry> {
        var descriptor = if isNewer {
            FetchDescriptor<DiaryEntry>(
                predicate: #Predicate { !$0.isTombstoned && $0.createdAt > predicateDate },
                sortBy: [SortDescriptor(\.createdAt, order: .forward)]
            )
        } else {
            FetchDescriptor<DiaryEntry>(
                predicate: #Predicate { !$0.isTombstoned && $0.createdAt < predicateDate },
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
        }
        descriptor.fetchLimit = 1
        return descriptor
    }
}

enum EntryNavigationDirection {
    case newer
    case older
}

struct EntryDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState

    let entry: DiaryEntry
    var navigate: ((EntryNavigationDirection) -> Void)?
    @Query(sort: \PendingChange.createdAt, order: .forward) private var pendingChanges: [PendingChange]

    @State private var syncCoordinator = SyncCoordinator()
    @State private var isPresentingEdit = false
    @State private var isConfirmingDelete = false
    @State private var isDeleting = false
    @State private var deleteErrorMessage: String?
    @State private var fullScreenAttachment: FullScreenAttachment?

    private var pendingChange: PendingChange? {
        pendingChanges.first { $0.entryID == entry.id }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let pendingChange {
                    PendingDetailBanner(change: pendingChange)
                }

                EntryDetailHeader(entry: entry)

                if !entry.entryContext.isEmpty {
                    EntryContextSection(context: entry.entryContext)
                }

                if !entry.attachments.isEmpty {
                    AttachmentGridView(attachments: entry.attachments) { attachment in
                        fullScreenAttachment = FullScreenAttachment(id: attachment.id)
                    }
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
        .simultaneousGesture(entrySwipeGesture)
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
        .fullScreenCover(item: $fullScreenAttachment) { selection in
            AttachmentFullScreenGallery(
                attachments: entry.attachments,
                selectedID: selection.id
            )
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

    private var entrySwipeGesture: some Gesture {
        DragGesture(minimumDistance: 44)
            .onEnded { value in
                guard let navigate else { return }
                let width = value.translation.width
                let height = value.translation.height
                guard abs(width) > 90, abs(width) > abs(height) * 1.5 else { return }
                navigate(width < 0 ? .older : .newer)
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

private struct FullScreenAttachment: Identifiable {
    let id: String
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

private struct EntryDetailHeader: View {
    let entry: DiaryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(entry.createdAt, format: .dateTime.day())
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .monospacedDigit()

                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.createdAt, format: .dateTime.month(.wide).year())
                        .font(.title3.weight(.semibold))

                    Text(entry.createdAt, format: .dateTime.weekday(.wide))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)

            Text(entry.displayTitle)
                .font(.largeTitle.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if !entry.subjectDetails.isEmpty {
                SubjectDetailsView(subjectDetails: entry.subjectDetails)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct EditEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState

    @Query private var currentEntries: [DiaryEntry]
    let syncCoordinator: SyncCoordinator

    private let entryID: String

    @State private var createdAt: Date
    @State private var expectedServerRevision: String
    @State private var attachmentsSnapshot: [DiaryAttachment]
    @State private var title: String
    @State private var bodyMarkdown: String
    @State private var capturedContext: DiaryEntryContext
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
        _bodyMarkdown = State(initialValue: entry.bodyMarkdown)
        _capturedContext = State(initialValue: entry.entryContext)
    }

    private var canSave: Bool {
        !bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !syncCoordinator.isSyncing
        && !isLoadingMedia
    }

    private var visibleAttachments: [DiaryAttachment] {
        attachmentsSnapshot.filter { !removedAttachmentIDs.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Entry") {
                    DatePicker("Date", selection: $createdAt)
                    TextField("Title", text: $title)
                        .textInputAutocapitalization(.sentences)
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

                ContextCaptureSection(context: $capturedContext, entryDate: createdAt)

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
            context: capturedContext
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
        bodyMarkdown = currentEntry.bodyMarkdown
        capturedContext = currentEntry.entryContext
        conflictMessage = nil
        isShowingConflictAlert = false
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
            VStack(alignment: .leading, spacing: 8) {
                ForEach(visibleDetails, id: \.stableID) { detail in
                    SubjectChip(detail: detail)
                }
            }
            .padding(.vertical, 2)
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

            Text(shortAgeText)
                .foregroundStyle(.secondary)
        }
        .font(.footnote)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.quaternary, in: Capsule())
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private var shortAgeText: String {
        let parts = detail.displayText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let yearMonthParts = parts.filter { part in
            part.localizedCaseInsensitiveContains("year")
            || part.localizedCaseInsensitiveContains("month")
        }

        let nonZeroParts = yearMonthParts.filter { part in
            !part.hasPrefix("0 ")
        }

        if !nonZeroParts.isEmpty {
            return nonZeroParts.joined(separator: ", ")
        }

        if !yearMonthParts.isEmpty {
            return yearMonthParts.joined(separator: ", ")
        }

        return parts.prefix(2).joined(separator: ", ")
    }
}

private struct EntryContextSection: View {
    let context: DiaryEntryContext

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Context")
                .font(.headline)

            ContextChipFlow(chips: context.summaryChips)

            if context.weather?.attribution == "Weather" {
                Text("Weather")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
