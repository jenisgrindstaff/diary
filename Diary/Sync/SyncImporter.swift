import Foundation
import SwiftData

enum SyncImporter {
    @MainActor
    static func apply(
        envelope: EntrySyncEnvelope,
        checkpoint: SyncCheckpoint,
        modelContext: ModelContext,
        syncedAt: Date = .now
    ) throws {
        checkpoint.lastAttemptedSyncAt = syncedAt
        checkpoint.lastError = nil

        for entryDTO in envelope.entries {
            let entry = try existingEntry(id: entryDTO.id, modelContext: modelContext)
                ?? DiaryEntry(
                    id: entryDTO.id,
                    createdAt: entryDTO.createdAt,
                    updatedAt: entryDTO.updatedAt,
                    serverRevision: entryDTO.serverRevision,
                    title: entryDTO.title,
                    excerpt: entryDTO.excerpt,
                    bodyMarkdown: entryDTO.bodyMarkdown
                )

            if entry.modelContext == nil {
                modelContext.insert(entry)
            }

            entry.createdAt = entryDTO.createdAt
            entry.updatedAt = entryDTO.updatedAt
            entry.serverRevision = entryDTO.serverRevision
            entry.title = entryDTO.title
            entry.excerpt = entryDTO.excerpt
            entry.bodyMarkdown = entryDTO.bodyMarkdown
            entry.sourcePath = entryDTO.sourcePath
            entry.tags = entryDTO.tags
            entry.people = entryDTO.people
            entry.subjectDetails = entryDTO.subjectDetails.map { DiarySubjectDetail(dto: $0) }
            entry.entryContext = entryDTO.context
            entry.refreshSearchText()
            entry.isTombstoned = false
            entry.syncedAt = syncedAt

            for attachment in entry.attachments {
                modelContext.delete(attachment)
            }
            entry.attachments.removeAll()

            for attachmentDTO in entryDTO.attachments {
                let attachment = DiaryAttachment(
                    id: attachmentDTO.id,
                    kind: attachmentDTO.kind,
                    filename: attachmentDTO.filename,
                    contentType: attachmentDTO.contentType,
                    remotePath: attachmentDTO.remotePath,
                    markdownPath: attachmentDTO.markdownPath,
                    byteCount: attachmentDTO.byteCount,
                    width: attachmentDTO.width,
                    height: attachmentDTO.height,
                    createdAt: attachmentDTO.createdAt,
                    entry: entry
                )
                modelContext.insert(attachment)
                entry.attachments.append(attachment)
            }
        }

        for deletedID in envelope.deletedEntryIDs {
            if let entry = try existingEntry(id: deletedID, modelContext: modelContext) {
                entry.isTombstoned = true
                entry.updatedAt = syncedAt
                entry.syncedAt = syncedAt
            }
        }

        try DiarySuggestionIndex.rebuild(modelContext: modelContext)
        checkpoint.cursor = envelope.nextCursor ?? checkpoint.cursor
        checkpoint.lastSuccessfulSyncAt = syncedAt
        try modelContext.save()
    }

    @MainActor
    static func checkpoint(
        deviceID: String,
        serverBaseURL: String,
        modelContext: ModelContext
    ) throws -> SyncCheckpoint {
        let defaultID = SyncCheckpoint.defaultID
        var descriptor = FetchDescriptor<SyncCheckpoint>(
            predicate: #Predicate { $0.id == defaultID }
        )
        descriptor.fetchLimit = 1

        if let existing = try modelContext.fetch(descriptor).first {
            existing.deviceID = deviceID
            existing.serverBaseURL = serverBaseURL
            return existing
        }

        let checkpoint = SyncCheckpoint(deviceID: deviceID, serverBaseURL: serverBaseURL)
        modelContext.insert(checkpoint)
        return checkpoint
    }

    @MainActor
    private static func existingEntry(id: String, modelContext: ModelContext) throws -> DiaryEntry? {
        // Fetch by predicate rather than loading every entry and filtering in
        // memory — the latter is O(n) per lookup, i.e. O(n²) across a full
        // paginated resync.
        var descriptor = FetchDescriptor<DiaryEntry>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}

private extension DiarySubjectDetail {
    init(dto: SubjectDetailDTO) {
        self.init(
            name: dto.name,
            label: dto.label ?? "",
            ageText: dto.ageText ?? "",
            rawText: dto.rawText ?? ""
        )
    }
}
