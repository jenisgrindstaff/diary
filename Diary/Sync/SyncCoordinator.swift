import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class SyncCoordinator {
    private(set) var isSyncing = false
    private(set) var lastError: String?
    private(set) var lastCompletedAt: Date?

    @ObservationIgnored private let mediaStore = LocalMediaStore()

    func sync(modelContext: ModelContext, appState: AppState) async {
        guard !isSyncing else { return }

        guard let baseURL = appState.serverURL else {
            lastError = "Enter a valid server URL in Settings."
            appState.syncStatus = .failed(lastError ?? "Invalid server URL")
            return
        }

        isSyncing = true
        lastError = nil
        appState.syncStatus = .syncing

        do {
            let checkpoint = try SyncImporter.checkpoint(
                deviceID: appState.deviceID,
                serverBaseURL: baseURL.absoluteString,
                modelContext: modelContext
            )
            let client = SyncClient(
                baseURL: baseURL,
                bearerToken: appState.accessToken,
                deviceID: appState.deviceID
            )

            try await flushPendingChanges(checkpoint: checkpoint, client: client, modelContext: modelContext)

            // The server paginates entries; drain pages until has_more is false.
            // Each page advances checkpoint.cursor (via SyncImporter.apply), so a
            // failure mid-drain resumes from the last applied page next sync.
            var entryCount = 0
            var deletedCount = 0
            while true {
                let envelope = try await client.fetchEntries(updatedSince: checkpoint.cursor)
                let previousCursor = checkpoint.cursor
                try SyncImporter.apply(envelope: envelope, checkpoint: checkpoint, modelContext: modelContext)
                try await cacheAttachments(from: envelope, client: client, modelContext: modelContext)
                entryCount += envelope.entries.count
                deletedCount += envelope.deletedEntryIDs.count

                guard envelope.hasMore else { break }
                // Defensive: the server guarantees the cursor advances while
                // has_more is true; stop rather than loop forever if it does not.
                if checkpoint.cursor == previousCursor {
                    break
                }
            }

            recordEvent(
                kind: .fullSync,
                status: .succeeded,
                summary: "Sync completed",
                detail: syncSummary(entryCount: entryCount, deletedCount: deletedCount),
                modelContext: modelContext
            )

            lastCompletedAt = .now
            appState.syncStatus = .synced(lastCompletedAt ?? .now)
        } catch {
            recordEvent(
                kind: .fullSync,
                status: .failed,
                summary: "Sync failed",
                detail: error.localizedDescription,
                modelContext: modelContext
            )
            lastError = error.localizedDescription
            appState.syncStatus = .failed(error.localizedDescription)
        }

        isSyncing = false
    }

    func fullSync(modelContext: ModelContext, appState: AppState) async {
        do {
            try resetSyncCursor(modelContext: modelContext)
            try resetLocalServerCache(modelContext: modelContext)
        } catch {
            lastError = error.localizedDescription
            appState.syncStatus = .failed(error.localizedDescription)
            return
        }

        await sync(modelContext: modelContext, appState: appState)
    }

    func searchServer(
        query: String,
        modelContext: ModelContext,
        appState: AppState
    ) async throws -> ServerSearchSummary {
        guard !isSyncing else {
            return ServerSearchSummary(resultCount: 0, snippetsByEntryID: [:])
        }
        guard let baseURL = appState.serverURL else {
            throw SyncCoordinatorError.invalidServerURL
        }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return ServerSearchSummary(resultCount: 0, snippetsByEntryID: [:])
        }

        isSyncing = true
        lastError = nil
        defer { isSyncing = false }

        let checkpoint = try SyncImporter.checkpoint(
            deviceID: appState.deviceID,
            serverBaseURL: baseURL.absoluteString,
            modelContext: modelContext
        )
        let client = SyncClient(
            baseURL: baseURL,
            bearerToken: appState.accessToken,
            deviceID: appState.deviceID
        )
        let response = try await client.searchEntries(query: trimmedQuery)
        let envelope = EntrySyncEnvelope(
            entries: response.entries,
            deletedEntryIDs: [],
            nextCursor: checkpoint.cursor
        )
        try SyncImporter.apply(envelope: envelope, checkpoint: checkpoint, modelContext: modelContext)
        try await cacheAttachments(from: envelope, client: client, modelContext: modelContext)
        return ServerSearchSummary(
            resultCount: response.entries.count,
            snippetsByEntryID: response.snippetsByEntryID
        )
    }

    func registerDevice(appState: AppState) async {
        guard let baseURL = appState.serverURL else {
            appState.syncStatus = .failed("Enter a valid server URL in Settings.")
            return
        }

        do {
            let client = SyncClient(
                baseURL: baseURL,
                bearerToken: appState.accessToken,
                deviceID: appState.deviceID
            )
            let response = try await client.registerDevice()
            appState.markDeviceRegistered(response)
            appState.syncStatus = .idle
        } catch {
            appState.syncStatus = .failed(error.localizedDescription)
        }
    }

    func createEntry(
        draft: EntryWriteDraft,
        media: [MediaUploadDraft] = [],
        modelContext: ModelContext,
        appState: AppState,
        syncImmediately: Bool = true
    ) async throws -> String {
        let change = try enqueueCreate(draft: draft, media: media, modelContext: modelContext)
        if syncImmediately {
            try? await tryFlushPendingChanges(modelContext: modelContext, appState: appState)
        }
        return change.serverEntryID ?? change.entryID
    }

    func updateEntry(
        id: String,
        draft: EntryWriteDraft,
        removedAttachmentIDs: [String] = [],
        media: [MediaUploadDraft] = [],
        modelContext: ModelContext,
        appState: AppState,
        syncImmediately: Bool = true
    ) async throws {
        let change = try enqueueUpdate(
            id: id,
            draft: draft,
            removedAttachmentIDs: removedAttachmentIDs,
            media: media,
            modelContext: modelContext
        )
        if syncImmediately {
            try await tryFlushPendingChanges(modelContext: modelContext, appState: appState, throwingFor: change.id)
        }
    }

    func deleteEntry(
        id: String,
        modelContext: ModelContext,
        appState: AppState
    ) async throws {
        if Self.isLocalEntryID(id) {
            try discardLocalEntry(id: id, modelContext: modelContext)
            appState.syncStatus = .idle
            return
        }

        let change = try enqueueDelete(id: id, modelContext: modelContext)
        try await tryFlushPendingChanges(modelContext: modelContext, appState: appState, throwingFor: change.id)
    }

    func discardPendingChange(
        id changeID: String,
        modelContext: ModelContext
    ) throws {
        guard let change = try pendingChange(id: changeID, modelContext: modelContext) else {
            return
        }

        let entryID = change.entryID
        let kind = SyncEventKind(pendingKind: PendingChangeKind(rawValue: change.kind))
        let summary = change.summary

        cleanupPendingMedia(for: change)

        if PendingChangeKind(rawValue: change.kind) == .createEntry {
            if let entry = try entry(id: entryID, modelContext: modelContext) {
                modelContext.delete(entry)
            }
        } else if PendingChangeKind(rawValue: change.kind) == .deleteEntry,
                  let entry = try entry(id: entryID, modelContext: modelContext) {
            entry.isTombstoned = false
            entry.updatedAt = .now
        }

        modelContext.delete(change)
        try resetSyncCursor(modelContext: modelContext)
        try DiarySuggestionIndex.rebuild(modelContext: modelContext)
        try modelContext.save()

        recordEvent(
            kind: kind,
            status: .succeeded,
            summary: "Queued change discarded",
            detail: discardDetail(kind: kind, summary: summary),
            entryID: entryID,
            modelContext: modelContext
        )
    }

    func conflictResolution(
        for changeID: String,
        modelContext: ModelContext
    ) throws -> PendingConflictResolution? {
        guard let change = try pendingChange(id: changeID, modelContext: modelContext),
              change.canResolveConflict,
              let serverEntry = try entry(id: change.entryID, modelContext: modelContext) else {
            return nil
        }

        let payload: PendingEntryWritePayload = try decodePayload(change.payloadJSON)
        return PendingConflictResolution(
            id: change.id,
            entryID: change.entryID,
            summary: change.summary,
            localDraft: payload.draft,
            serverEntry: serverEntry
        )
    }

    func overwriteServerForConflict(
        id changeID: String,
        modelContext: ModelContext,
        appState: AppState
    ) async throws {
        guard let change = try pendingChange(id: changeID, modelContext: modelContext),
              PendingChangeKind(rawValue: change.kind) == .updateEntry,
              let serverEntry = try entry(id: change.entryID, modelContext: modelContext) else {
            throw SyncCoordinatorError.invalidPendingChange
        }

        var payload: PendingEntryWritePayload = try decodePayload(change.payloadJSON)
        payload.draft = EntryWriteDraft(
            createdAt: payload.draft.createdAt,
            expectedServerRevision: serverEntry.serverRevision,
            title: payload.draft.title,
            bodyMarkdown: payload.draft.bodyMarkdown,
            people: payload.draft.people,
            tags: payload.draft.tags,
            context: payload.draft.context
        )
        change.payloadJSON = try encodePayload(payload)
        change.status = PendingChangeStatus.pending.rawValue
        change.lastError = nil

        applyOptimisticUpdate(
            entry: serverEntry,
            draft: payload.draft,
            removedAttachmentIDs: payload.removedAttachmentIDs
        )
        try DiarySuggestionIndex.rebuild(modelContext: modelContext)
        try modelContext.save()

        try await tryFlushPendingChanges(
            modelContext: modelContext,
            appState: appState,
            throwingFor: change.id
        )
    }

    private func tryFlushPendingChanges(
        modelContext: ModelContext,
        appState: AppState,
        throwingFor changeID: String? = nil
    ) async throws {
        guard !isSyncing else { return }
        guard let baseURL = appState.serverURL else {
            appState.syncStatus = .failed("Pending changes will sync after server settings are saved.")
            return
        }

        isSyncing = true
        lastError = nil
        appState.syncStatus = .syncing
        defer { isSyncing = false }

        do {
            let checkpoint = try SyncImporter.checkpoint(
                deviceID: appState.deviceID,
                serverBaseURL: baseURL.absoluteString,
                modelContext: modelContext
            )
            let client = SyncClient(
                baseURL: baseURL,
                bearerToken: appState.accessToken,
                deviceID: appState.deviceID
            )
            try await flushPendingChanges(checkpoint: checkpoint, client: client, modelContext: modelContext)
            lastCompletedAt = .now
            appState.syncStatus = .synced(lastCompletedAt ?? .now)
        } catch {
            lastError = error.localizedDescription
            appState.syncStatus = .failed(error.localizedDescription)
            if changeID != nil, shouldThrowAfterQueueAttempt(error) {
                throw error
            }
        }
    }

    private func shouldThrowAfterQueueAttempt(_ error: Error) -> Bool {
        if case SyncCoordinatorError.entryConflict = error {
            return true
        }

        return false
    }

    private func enqueueCreate(
        draft: EntryWriteDraft,
        media: [MediaUploadDraft],
        modelContext: ModelContext
    ) throws -> PendingChange {
        let changeID = UUID().uuidString
        let localEntryID = "local-\(changeID)"
        let payload = PendingEntryWritePayload(
            draft: draft,
            removedAttachmentIDs: [],
            media: try stageMedia(media)
        )
        let change = PendingChange(
            id: changeID,
            entryID: localEntryID,
            kind: PendingChangeKind.createEntry.rawValue,
            payloadJSON: try encodePayload(payload),
            summary: mutationSummary(title: draft.title, mediaCount: media.count)
        )
        modelContext.insert(change)
        modelContext.insert(localEntry(id: localEntryID, draft: draft, changeID: changeID))
        try DiarySuggestionIndex.rebuild(modelContext: modelContext)
        try modelContext.save()
        recordEvent(
            kind: .createEntry,
            status: .succeeded,
            summary: "Entry queued",
            detail: change.summary,
            entryID: localEntryID,
            modelContext: modelContext
        )
        return change
    }

    private func enqueueUpdate(
        id: String,
        draft: EntryWriteDraft,
        removedAttachmentIDs: [String],
        media: [MediaUploadDraft],
        modelContext: ModelContext
    ) throws -> PendingChange {
        let payload = PendingEntryWritePayload(
            draft: draft,
            removedAttachmentIDs: removedAttachmentIDs,
            media: try stageMedia(media)
        )
        let change = PendingChange(
            entryID: id,
            kind: PendingChangeKind.updateEntry.rawValue,
            payloadJSON: try encodePayload(payload),
            summary: mutationSummary(title: draft.title, mediaCount: media.count, removedMediaCount: removedAttachmentIDs.count)
        )
        modelContext.insert(change)

        if let entry = try entry(id: id, modelContext: modelContext) {
            applyOptimisticUpdate(entry: entry, draft: draft, removedAttachmentIDs: removedAttachmentIDs)
        }

        try DiarySuggestionIndex.rebuild(modelContext: modelContext)
        try modelContext.save()
        recordEvent(
            kind: .updateEntry,
            status: .succeeded,
            summary: "Update queued",
            detail: change.summary,
            entryID: id,
            modelContext: modelContext
        )
        return change
    }

    private func enqueueDelete(id: String, modelContext: ModelContext) throws -> PendingChange {
        let change = PendingChange(
            entryID: id,
            kind: PendingChangeKind.deleteEntry.rawValue,
            payloadJSON: "{}",
            summary: "Move entry to trash"
        )
        modelContext.insert(change)

        if let entry = try entry(id: id, modelContext: modelContext) {
            entry.isTombstoned = true
            entry.updatedAt = .now
        }

        try DiarySuggestionIndex.rebuild(modelContext: modelContext)
        try modelContext.save()
        recordEvent(
            kind: .deleteEntry,
            status: .succeeded,
            summary: "Delete queued",
            detail: change.summary,
            entryID: id,
            modelContext: modelContext
        )
        return change
    }

    private func flushPendingChanges(
        checkpoint: SyncCheckpoint,
        client: SyncClient,
        modelContext: ModelContext
    ) async throws {
        let changes = try pendingChanges(modelContext: modelContext)
        guard !changes.isEmpty else { return }

        for change in changes {
            change.lastAttemptedAt = .now
            change.attemptCount += 1
            change.status = PendingChangeStatus.pending.rawValue
            change.lastError = nil
            try modelContext.save()

            do {
                switch PendingChangeKind(rawValue: change.kind) {
                case .createEntry:
                    try await flushCreate(change, checkpoint: checkpoint, client: client, modelContext: modelContext)
                case .updateEntry:
                    try await flushUpdate(change, checkpoint: checkpoint, client: client, modelContext: modelContext)
                case .deleteEntry:
                    try await flushDelete(change, checkpoint: checkpoint, modelContext: modelContext, client: client)
                case nil:
                    throw SyncCoordinatorError.invalidPendingChange
                }
            } catch SyncClientError.entryConflict(let message, let serverEntry) {
                try await importEntry(serverEntry, checkpoint: checkpoint, client: client, modelContext: modelContext)
                mark(change: change, failedWith: message, modelContext: modelContext)
                recordPendingFailure(change: change, detail: message, modelContext: modelContext)
                throw SyncCoordinatorError.entryConflict(message)
            } catch {
                mark(change: change, failedWith: error.localizedDescription, modelContext: modelContext)
                recordPendingFailure(change: change, detail: error.localizedDescription, modelContext: modelContext)
                throw error
            }
        }
    }

    private func flushCreate(
        _ change: PendingChange,
        checkpoint: SyncCheckpoint,
        client: SyncClient,
        modelContext: ModelContext
    ) async throws {
        let localEntryID = change.entryID
        let payload: PendingEntryWritePayload = try decodePayload(change.payloadJSON)
        let response = try await client.createEntry(payload.draft, clientMutationID: change.id)
        var latestEntry = response.entry
        try await importEntry(latestEntry, checkpoint: checkpoint, client: client, modelContext: modelContext)

        for mediaItem in payload.media {
            let attachmentResponse = try await client.attachMedia(mediaItem.uploadDraft(from: pendingMediaDirectory()), to: latestEntry.id)
            latestEntry = attachmentResponse.entry
            try await importEntry(latestEntry, checkpoint: checkpoint, client: client, modelContext: modelContext)
        }

        try updateQueuedEntryIDs(from: localEntryID, to: latestEntry.id, modelContext: modelContext)
        if localEntryID != latestEntry.id, let localEntry = try entry(id: localEntryID, modelContext: modelContext) {
            modelContext.delete(localEntry)
        }

        cleanup(media: payload.media)
        modelContext.delete(change)
        try DiarySuggestionIndex.rebuild(modelContext: modelContext)
        try modelContext.save()
        recordEvent(
            kind: .createEntry,
            status: .succeeded,
            summary: "Entry created",
            detail: mutationSummary(title: latestEntry.title, mediaCount: payload.media.count),
            entryID: latestEntry.id,
            modelContext: modelContext
        )
    }

    private func flushUpdate(
        _ change: PendingChange,
        checkpoint: SyncCheckpoint,
        client: SyncClient,
        modelContext: ModelContext
    ) async throws {
        let payload: PendingEntryWritePayload = try decodePayload(change.payloadJSON)
        let response = try await client.updateEntry(id: change.entryID, draft: payload.draft)
        var latestEntry = response.entry
        try await importEntry(latestEntry, checkpoint: checkpoint, client: client, modelContext: modelContext)

        for attachmentID in payload.removedAttachmentIDs {
            let removeResponse = try await client.removeMedia(id: attachmentID, from: latestEntry.id)
            latestEntry = removeResponse.entry
            try await importEntry(latestEntry, checkpoint: checkpoint, client: client, modelContext: modelContext)
            // The server confirmed removal, so the cached file is now dead weight.
            mediaStore.removeAttachment(attachmentID: attachmentID)
        }

        for mediaItem in payload.media {
            let attachmentResponse = try await client.attachMedia(mediaItem.uploadDraft(from: pendingMediaDirectory()), to: latestEntry.id)
            latestEntry = attachmentResponse.entry
            try await importEntry(latestEntry, checkpoint: checkpoint, client: client, modelContext: modelContext)
        }

        cleanup(media: payload.media)
        modelContext.delete(change)
        try DiarySuggestionIndex.rebuild(modelContext: modelContext)
        try modelContext.save()
        recordEvent(
            kind: .updateEntry,
            status: .succeeded,
            summary: "Entry updated",
            detail: mutationSummary(title: payload.draft.title, mediaCount: payload.media.count, removedMediaCount: payload.removedAttachmentIDs.count),
            entryID: latestEntry.id,
            modelContext: modelContext
        )
    }

    private func flushDelete(
        _ change: PendingChange,
        checkpoint: SyncCheckpoint,
        modelContext: ModelContext,
        client: SyncClient
    ) async throws {
        if Self.isLocalEntryID(change.entryID) {
            try discardLocalEntry(id: change.entryID, modelContext: modelContext)
            return
        }

        let response: DeleteEntryResponse
        do {
            response = try await client.deleteEntry(id: change.entryID)
        } catch SyncClientError.httpStatus(404, _) {
            try completeDeleteAlreadyAbsent(change: change, modelContext: modelContext)
            return
        }

        let envelope = EntrySyncEnvelope(
            entries: [],
            deletedEntryIDs: [response.deletedEntryID],
            nextCursor: checkpoint.cursor
        )
        try SyncImporter.apply(
            envelope: envelope,
            checkpoint: checkpoint,
            modelContext: modelContext,
            syncedAt: response.deletedAt
        )
        purgeLocalMedia(forEntryID: response.deletedEntryID, modelContext: modelContext)

        modelContext.delete(change)
        try DiarySuggestionIndex.rebuild(modelContext: modelContext)
        try modelContext.save()
        recordEvent(
            kind: .deleteEntry,
            status: .succeeded,
            summary: "Entry moved to trash",
            detail: response.trashPath,
            entryID: response.deletedEntryID,
            modelContext: modelContext
        )
    }

    private static func isLocalEntryID(_ id: String) -> Bool {
        id.hasPrefix("local-")
    }

    private func discardLocalEntry(id: String, modelContext: ModelContext) throws {
        for change in try pendingChanges(modelContext: modelContext) where change.entryID == id {
            cleanupPendingMedia(for: change)
            modelContext.delete(change)
        }

        if let entry = try entry(id: id, modelContext: modelContext) {
            purgeLocalMedia(forEntryID: id, modelContext: modelContext)
            modelContext.delete(entry)
        }

        try DiarySuggestionIndex.rebuild(modelContext: modelContext)
        try modelContext.save()
        recordEvent(
            kind: .deleteEntry,
            status: .succeeded,
            summary: "Local entry discarded",
            detail: "The entry had not synced to the server yet.",
            entryID: id,
            modelContext: modelContext
        )
    }

    private func completeDeleteAlreadyAbsent(change: PendingChange, modelContext: ModelContext) throws {
        if let entry = try entry(id: change.entryID, modelContext: modelContext) {
            purgeLocalMedia(forEntryID: change.entryID, modelContext: modelContext)
            modelContext.delete(entry)
        }

        modelContext.delete(change)
        try DiarySuggestionIndex.rebuild(modelContext: modelContext)
        try modelContext.save()
        recordEvent(
            kind: .deleteEntry,
            status: .succeeded,
            summary: "Entry already absent on server",
            detail: "The queued delete was cleared.",
            entryID: change.entryID,
            modelContext: modelContext
        )
    }

    private func importEntry(
        _ entry: EntryDTO,
        checkpoint: SyncCheckpoint,
        client: SyncClient,
        modelContext: ModelContext
    ) async throws {
        let envelope = EntrySyncEnvelope(entries: [entry], deletedEntryIDs: [], nextCursor: checkpoint.cursor)
        try SyncImporter.apply(envelope: envelope, checkpoint: checkpoint, modelContext: modelContext)
        try await cacheAttachments(from: envelope, client: client, modelContext: modelContext)
    }

    private func cacheAttachments(
        from envelope: EntrySyncEnvelope,
        client: SyncClient,
        modelContext: ModelContext
    ) async throws {
        var failedDownloads = 0
        for entry in envelope.entries {
            for attachmentDTO in entry.attachments {
                let relativePath = mediaStore.relativePath(attachmentID: attachmentDTO.id, filename: attachmentDTO.filename)
                if mediaStore.fileExists(relativePath: relativePath) {
                    try updateAttachment(id: attachmentDTO.id, localRelativePath: relativePath, modelContext: modelContext)
                    continue
                }

                do {
                    let data = try await client.fetchAsset(id: attachmentDTO.id)
                    try mediaStore.save(data: data, relativePath: relativePath)
                    try updateAttachment(id: attachmentDTO.id, localRelativePath: relativePath, modelContext: modelContext)
                } catch {
                    // The save is atomic, so no partial file is left behind, and
                    // the missing file is retried on the next sync. Surface a
                    // count rather than failing silently with a stuck placeholder.
                    failedDownloads += 1
                    continue
                }
            }
        }

        if failedDownloads > 0 {
            recordEvent(
                kind: .fullSync,
                status: .failed,
                summary: "Some media did not download",
                detail: "\(failedDownloads) attachment\(failedDownloads == 1 ? "" : "s") could not be downloaded and will retry on the next sync.",
                modelContext: modelContext
            )
        }

        try modelContext.save()
    }

    /// Deletes the cached media files for every attachment of an entry. Called
    /// when an entry is permanently removed or its deletion is confirmed by the
    /// server, so cached images/videos don't accumulate on disk indefinitely.
    private func purgeLocalMedia(forEntryID id: String, modelContext: ModelContext) {
        guard let entry = try? entry(id: id, modelContext: modelContext) else { return }
        for attachment in entry.attachments {
            mediaStore.removeAttachment(attachmentID: attachment.id)
        }
    }

    private func updateAttachment(id: String, localRelativePath: String, modelContext: ModelContext) throws {
        var descriptor = FetchDescriptor<DiaryAttachment>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1

        if let attachment = try modelContext.fetch(descriptor).first {
            attachment.localRelativePath = localRelativePath
        }
    }

    private func pendingChanges(modelContext: ModelContext) throws -> [PendingChange] {
        let descriptor = FetchDescriptor<PendingChange>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        return try modelContext.fetch(descriptor)
    }

    private func pendingChange(id changeID: String, modelContext: ModelContext) throws -> PendingChange? {
        var descriptor = FetchDescriptor<PendingChange>(
            predicate: #Predicate { $0.id == changeID }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func resetSyncCursor(modelContext: ModelContext) throws {
        for checkpoint in try modelContext.fetch(FetchDescriptor<SyncCheckpoint>()) {
            checkpoint.cursor = nil
        }
    }

    private func resetLocalServerCache(modelContext: ModelContext) throws {
        let protectedEntryIDs = Set(try pendingChanges(modelContext: modelContext).map(\.entryID))
        let entries = try modelContext.fetch(FetchDescriptor<DiaryEntry>())

        for entry in entries {
            guard !Self.isLocalEntryID(entry.id), !protectedEntryIDs.contains(entry.id) else {
                continue
            }

            purgeLocalMedia(forEntryID: entry.id, modelContext: modelContext)
            modelContext.delete(entry)
        }

        try DiarySuggestionIndex.rebuild(modelContext: modelContext)
        try modelContext.save()
    }

    private func updateQueuedEntryIDs(from localID: String, to serverID: String, modelContext: ModelContext) throws {
        guard localID != serverID else { return }

        for change in try pendingChanges(modelContext: modelContext) where change.entryID == localID {
            change.entryID = serverID
            change.serverEntryID = serverID
        }
    }

    private func mark(change: PendingChange, failedWith message: String, modelContext: ModelContext) {
        change.status = PendingChangeStatus.failed.rawValue
        change.lastError = message
        try? modelContext.save()
    }

    private func recordPendingFailure(change: PendingChange, detail: String, modelContext: ModelContext) {
        let kind = SyncEventKind(pendingKind: PendingChangeKind(rawValue: change.kind))
        recordEvent(
            kind: kind,
            status: .failed,
            summary: "\(change.displayKind) still pending",
            detail: detail,
            entryID: change.entryID,
            modelContext: modelContext
        )
    }

    private func localEntry(id: String, draft: EntryWriteDraft, changeID: String) -> DiaryEntry {
        DiaryEntry(
            id: id,
            createdAt: draft.createdAt,
            updatedAt: .now,
            serverRevision: "pending-\(changeID)",
            title: draft.title,
            excerpt: excerpt(from: draft.bodyMarkdown),
            bodyMarkdown: draft.bodyMarkdown,
            tags: draft.tags,
            people: draft.people,
            context: draft.context,
            syncedAt: nil
        )
    }

    private func applyOptimisticUpdate(
        entry: DiaryEntry,
        draft: EntryWriteDraft,
        removedAttachmentIDs: [String]
    ) {
        entry.createdAt = draft.createdAt
        entry.updatedAt = .now
        entry.title = draft.title
        entry.excerpt = excerpt(from: draft.bodyMarkdown)
        entry.bodyMarkdown = draft.bodyMarkdown
        entry.tags = draft.tags
        entry.people = draft.people
        entry.entryContext = draft.context
        entry.refreshSearchText()

        if !removedAttachmentIDs.isEmpty {
            let removed = Set(removedAttachmentIDs)
            for attachment in entry.attachments where removed.contains(attachment.id) {
                attachment.entry = nil
            }
            entry.attachments.removeAll { removed.contains($0.id) }
        }
    }

    private func entry(id: String, modelContext: ModelContext) throws -> DiaryEntry? {
        var descriptor = FetchDescriptor<DiaryEntry>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func encodePayload(_ payload: PendingEntryWritePayload) throws -> String {
        let data = try JSONEncoder().encode(payload)
        return String(decoding: data, as: UTF8.self)
    }

    private func decodePayload(_ string: String) throws -> PendingEntryWritePayload {
        guard let data = string.data(using: .utf8) else {
            throw SyncCoordinatorError.invalidPendingChange
        }

        return try JSONDecoder().decode(PendingEntryWritePayload.self, from: data)
    }

    private func stageMedia(_ media: [MediaUploadDraft]) throws -> [PendingMediaPayload] {
        try media.map { item in
            let directory = pendingMediaDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let storedFilename = "\(UUID().uuidString)-\(item.filename)"
            let destination = directory.appending(path: storedFilename)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: item.fileURL, to: destination)
            return PendingMediaPayload(
                filename: item.filename,
                contentType: item.contentType,
                storedFilename: storedFilename,
                byteCount: item.byteCount
            )
        }
    }

    private func cleanup(media: [PendingMediaPayload]) {
        for item in media {
            try? FileManager.default.removeItem(at: pendingMediaDirectory().appending(path: item.storedFilename))
        }
    }

    private func cleanupPendingMedia(for change: PendingChange) {
        guard let payload: PendingEntryWritePayload = try? decodePayload(change.payloadJSON) else {
            return
        }

        cleanup(media: payload.media)
    }

    private func pendingMediaDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appending(path: "PendingUploads", directoryHint: .isDirectory)
    }

    private func excerpt(from bodyMarkdown: String) -> String {
        bodyMarkdown
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func recordEvent(
        kind: SyncEventKind,
        status: SyncEventStatus,
        summary: String,
        detail: String? = nil,
        entryID: String? = nil,
        modelContext: ModelContext
    ) {
        modelContext.insert(
            SyncEvent(
                kind: kind.rawValue,
                status: status.rawValue,
                summary: summary,
                detail: detail,
                entryID: entryID
            )
        )
        pruneEvents(modelContext: modelContext)
        try? modelContext.save()
    }

    private func pruneEvents(modelContext: ModelContext) {
        var descriptor = FetchDescriptor<SyncEvent>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 150

        guard let events = try? modelContext.fetch(descriptor), events.count > 100 else {
            return
        }

        for event in events.dropFirst(100) {
            modelContext.delete(event)
        }
    }

    private func syncSummary(entryCount: Int, deletedCount: Int) -> String {
        if entryCount == 0 && deletedCount == 0 {
            return "No server changes"
        }

        let entryText = "\(entryCount) entr\(entryCount == 1 ? "y" : "ies")"
        let deletedText = "\(deletedCount) deleted"
        return "\(entryText), \(deletedText)"
    }

    private func mutationSummary(title: String, mediaCount: Int, removedMediaCount: Int = 0) -> String {
        var parts: [String] = []
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanTitle.isEmpty {
            parts.append(cleanTitle)
        }
        if mediaCount > 0 {
            parts.append("\(mediaCount) media added")
        }
        if removedMediaCount > 0 {
            parts.append("\(removedMediaCount) media removed")
        }

        return parts.isEmpty ? "No title" : parts.joined(separator: " | ")
    }

    private func discardDetail(kind: SyncEventKind, summary: String) -> String {
        let cleanSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: String
        switch kind {
        case .createEntry:
            base = "The unsynced local entry was removed."
        case .deleteEntry:
            base = "The local delete was cancelled. The next sync will reload server truth."
        case .updateEntry:
            base = "The local edit queue was removed. The next sync will reload server truth."
        case .fullSync:
            base = "The local queue item was removed."
        }

        return cleanSummary.isEmpty ? base : "\(base) \(cleanSummary)"
    }
}

private struct PendingEntryWritePayload: Codable {
    var draft: EntryWriteDraft
    var removedAttachmentIDs: [String]
    var media: [PendingMediaPayload]
}

struct PendingConflictResolution: Identifiable {
    let id: String
    let entryID: String
    let summary: String
    let localTitle: String
    let localBodyMarkdown: String
    let localPeople: [String]
    let localTags: [String]
    let localCreatedAt: Date
    let serverTitle: String
    let serverBodyMarkdown: String
    let serverPeople: [String]
    let serverTags: [String]
    let serverUpdatedAt: Date
    let serverRevision: String

    init(id: String, entryID: String, summary: String, localDraft: EntryWriteDraft, serverEntry: DiaryEntry) {
        self.id = id
        self.entryID = entryID
        self.summary = summary
        localTitle = localDraft.title
        localBodyMarkdown = localDraft.bodyMarkdown
        localPeople = localDraft.people
        localTags = localDraft.tags
        localCreatedAt = localDraft.createdAt
        serverTitle = serverEntry.title
        serverBodyMarkdown = serverEntry.bodyMarkdown
        serverPeople = serverEntry.people
        serverTags = serverEntry.tags
        serverUpdatedAt = serverEntry.updatedAt
        serverRevision = serverEntry.serverRevision
    }

    var localClipboardText: String {
        var parts: [String] = []
        let cleanTitle = localTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanTitle.isEmpty {
            parts.append("# \(cleanTitle)")
        }
        parts.append(localBodyMarkdown)
        return parts.joined(separator: "\n\n")
    }
}

struct ServerSearchSummary: Equatable {
    let resultCount: Int
    let snippetsByEntryID: [String: String]
}

private struct PendingMediaPayload: Codable {
    var filename: String
    var contentType: String
    var storedFilename: String
    var byteCount: Int

    func uploadDraft(from directory: URL) -> MediaUploadDraft {
        MediaUploadDraft(
            id: storedFilename,
            filename: filename,
            contentType: contentType,
            fileURL: directory.appending(path: storedFilename),
            byteCount: byteCount
        )
    }
}

enum SyncCoordinatorError: LocalizedError {
    case invalidServerURL
    case invalidPendingChange
    case entryConflict(String)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return "Enter a valid server URL in Settings."
        case .invalidPendingChange:
            return "A queued diary change could not be read."
        case .entryConflict:
            return "This entry changed on the server. Reload the latest copy before saving."
        }
    }
}

private extension SyncEventKind {
    init(pendingKind: PendingChangeKind?) {
        switch pendingKind {
        case .createEntry:
            self = .createEntry
        case .updateEntry:
            self = .updateEntry
        case .deleteEntry:
            self = .deleteEntry
        case nil:
            self = .fullSync
        }
    }
}
