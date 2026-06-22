import SwiftData
import XCTest
@testable import Diary

@MainActor
final class SyncCoordinatorTests: XCTestCase {
    func testLocalDevelopmentSettingsUseSetupTokenAndClearRegistration() {
        let appState = makeAppState()
        appState.markDeviceRegistered(makeRegisterDeviceResponse())

        XCTAssertNotNil(appState.registeredAt)
        XCTAssertEqual(appState.tokenStateLabel, "Device token saved")

        appState.configureLocalDevelopmentServer()

        XCTAssertEqual(appState.serverURLString, AppState.localDevelopmentServerURL)
        XCTAssertEqual(appState.accessToken, AppState.localDevelopmentSetupToken)
        XCTAssertNil(appState.registeredAt)
        XCTAssertEqual(appState.registeredDeviceName, "")
        XCTAssertEqual(appState.tokenStateLabel, "Setup token")
        XCTAssertEqual(appState.registrationStateLabel, "Ready to register")
    }

    func testRegisteredDeviceStatePersists() {
        let suiteName = "SyncCoordinatorTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let keychain = KeychainStore(service: suiteName)
        let response = makeRegisterDeviceResponse()

        let firstState = AppState(defaults: defaults, keychain: keychain)
        firstState.markDeviceRegistered(response)

        let restoredState = AppState(defaults: defaults, keychain: keychain)

        XCTAssertEqual(restoredState.accessToken, "device-token-1")
        XCTAssertEqual(restoredState.registeredAt, response.device.registeredAt)
        XCTAssertEqual(restoredState.registeredDeviceName, "iPhone")
        XCTAssertEqual(restoredState.tokenStateLabel, "Device token saved")
    }

    func testCreateEntryQueuesWithoutServerURL() async throws {
        let context = try makeContext()
        let appState = makeAppState()
        let coordinator = SyncCoordinator()
        let draft = EntryWriteDraft(
            createdAt: Date(timeIntervalSinceReferenceDate: 804_000_000),
            title: "Queued",
            bodyMarkdown: "This should be durable before the network works.",
            people: ["Charlotte"],
            tags: ["offline"]
        )

        let entryID = try await coordinator.createEntry(
            draft: draft,
            modelContext: context,
            appState: appState
        )

        let pendingChanges = try context.fetch(FetchDescriptor<PendingChange>())
        let entries = try context.fetch(FetchDescriptor<DiaryEntry>())

        XCTAssertTrue(entryID.hasPrefix("local-"))
        XCTAssertEqual(pendingChanges.count, 1)
        XCTAssertEqual(pendingChanges.first?.kind, PendingChangeKind.createEntry.rawValue)
        XCTAssertEqual(pendingChanges.first?.status, PendingChangeStatus.pending.rawValue)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.title, "Queued")
        XCTAssertEqual(entries.first?.tags, ["offline"])
    }

    func testDeleteLocalQueuedEntryClearsItWithoutCallingServer() async throws {
        let context = try makeContext()
        let appState = makeAppState()
        let coordinator = SyncCoordinator()
        let draft = EntryWriteDraft(
            createdAt: Date(timeIntervalSinceReferenceDate: 804_000_000),
            title: "Queued",
            bodyMarkdown: "Delete this before it syncs.",
            people: [],
            tags: []
        )

        let entryID = try await coordinator.createEntry(
            draft: draft,
            modelContext: context,
            appState: appState
        )

        try await coordinator.deleteEntry(
            id: entryID,
            modelContext: context,
            appState: appState
        )

        let pendingChanges = try context.fetch(FetchDescriptor<PendingChange>())
        let entries = try context.fetch(FetchDescriptor<DiaryEntry>())

        XCTAssertTrue(entryID.hasPrefix("local-"))
        XCTAssertTrue(pendingChanges.isEmpty)
        XCTAssertTrue(entries.isEmpty)
    }

    func testLocalMediaStoreRemovesAttachmentFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "media-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let mediaStore = LocalMediaStore(root: root)

        let keepPath = mediaStore.relativePath(attachmentID: "keep", filename: "a.jpg")
        let dropPath = mediaStore.relativePath(attachmentID: "drop", filename: "b.jpg")
        try mediaStore.save(data: Data("a".utf8), relativePath: keepPath)
        try mediaStore.save(data: Data("b".utf8), relativePath: dropPath)
        XCTAssertTrue(mediaStore.fileExists(relativePath: keepPath))
        XCTAssertTrue(mediaStore.fileExists(relativePath: dropPath))

        mediaStore.removeAttachment(attachmentID: "drop")

        XCTAssertFalse(mediaStore.fileExists(relativePath: dropPath), "removed attachment's file should be gone")
        XCTAssertTrue(mediaStore.fileExists(relativePath: keepPath), "other attachments must be untouched")

        // Removing a non-existent attachment is a safe no-op.
        mediaStore.removeAttachment(attachmentID: "never-existed")
    }

    func testDiscardPendingUpdateClearsQueueAndForcesFullRefresh() async throws {
        let context = try makeContext()
        let appState = makeAppState()
        let coordinator = SyncCoordinator()
        let checkpoint = SyncCheckpoint(
            cursor: "cursor-1",
            deviceID: appState.deviceID,
            serverBaseURL: "http://127.0.0.1:18080"
        )
        let entry = DiaryEntry(
            id: "entry-1",
            createdAt: Date(timeIntervalSinceReferenceDate: 804_000_000),
            updatedAt: Date(timeIntervalSinceReferenceDate: 804_000_100),
            serverRevision: "rev-1",
            title: "Original",
            excerpt: "Original body",
            bodyMarkdown: "Original body"
        )
        context.insert(checkpoint)
        context.insert(entry)
        try context.save()

        let draft = EntryWriteDraft(
            createdAt: entry.createdAt,
            expectedServerRevision: entry.serverRevision,
            title: "Edited",
            bodyMarkdown: "Edited body",
            people: [],
            tags: []
        )

        try await coordinator.updateEntry(
            id: entry.id,
            draft: draft,
            modelContext: context,
            appState: appState
        )

        let change = try XCTUnwrap(context.fetch(FetchDescriptor<PendingChange>()).first)

        try coordinator.discardPendingChange(
            id: change.id,
            modelContext: context
        )

        let pendingChanges = try context.fetch(FetchDescriptor<PendingChange>())
        let events = try context.fetch(FetchDescriptor<SyncEvent>())

        XCTAssertTrue(pendingChanges.isEmpty)
        XCTAssertNil(checkpoint.cursor)
        XCTAssertTrue(events.contains { $0.summary == "Queued change discarded" })
    }

    func testFullSyncClearsCursorBeforeNetworkValidation() async throws {
        let context = try makeContext()
        let appState = makeAppState()
        let coordinator = SyncCoordinator()
        let checkpoint = SyncCheckpoint(
            cursor: "stale-cursor",
            deviceID: appState.deviceID,
            serverBaseURL: "http://127.0.0.1:18080"
        )
        context.insert(checkpoint)
        try context.save()

        await coordinator.fullSync(modelContext: context, appState: appState)

        XCTAssertNil(checkpoint.cursor)
        XCTAssertEqual(appState.syncStatus, .failed("Enter a valid server URL in Settings."))
    }

    func testConflictResolutionShowsLocalAndServerCopiesAndPreparesOverwrite() async throws {
        let context = try makeContext()
        let appState = makeAppState()
        let coordinator = SyncCoordinator()
        let entry = DiaryEntry(
            id: "entry-1",
            createdAt: Date(timeIntervalSinceReferenceDate: 804_000_000),
            updatedAt: Date(timeIntervalSinceReferenceDate: 804_000_100),
            serverRevision: "rev-1",
            title: "Original",
            excerpt: "Original body",
            bodyMarkdown: "Original body"
        )
        context.insert(entry)
        try context.save()

        let draft = EntryWriteDraft(
            createdAt: entry.createdAt,
            expectedServerRevision: entry.serverRevision,
            title: "Local Edit",
            bodyMarkdown: "Local body",
            people: ["Charlotte"],
            tags: ["ios"]
        )

        try await coordinator.updateEntry(
            id: entry.id,
            draft: draft,
            modelContext: context,
            appState: appState
        )

        let change = try XCTUnwrap(context.fetch(FetchDescriptor<PendingChange>()).first)
        entry.serverRevision = "rev-2"
        entry.title = "Server Edit"
        entry.bodyMarkdown = "Server body"
        change.status = PendingChangeStatus.failed.rawValue
        change.lastError = "entry has changed on the server"
        try context.save()

        let resolution = try XCTUnwrap(coordinator.conflictResolution(
            for: change.id,
            modelContext: context
        ))
        XCTAssertEqual(resolution.localTitle, "Local Edit")
        XCTAssertEqual(resolution.serverTitle, "Server Edit")
        XCTAssertEqual(resolution.localPeople, ["Charlotte"])

        try await coordinator.overwriteServerForConflict(
            id: change.id,
            modelContext: context,
            appState: appState
        )

        XCTAssertEqual(entry.title, "Local Edit")
        XCTAssertEqual(entry.bodyMarkdown, "Local body")
        XCTAssertEqual(change.status, PendingChangeStatus.pending.rawValue)
        XCTAssertNil(change.lastError)
    }

    private func makeContext() throws -> ModelContext {
        let schema = Schema([
            DiaryEntry.self,
            DiaryAttachment.self,
            SyncCheckpoint.self,
            PendingChange.self,
            SyncEvent.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return ModelContext(container)
    }

    private func makeAppState() -> AppState {
        let suiteName = "SyncCoordinatorTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return AppState(defaults: defaults, keychain: KeychainStore(service: suiteName))
    }

    private func makeRegisterDeviceResponse() -> RegisterDeviceResponse {
        let date = Date(timeIntervalSinceReferenceDate: 804_100_000)
        let device = SyncDeviceDTO(
            deviceID: "device-1",
            displayName: "iPhone",
            platform: "iOS",
            appVersion: "1.0",
            registeredAt: date,
            lastSeenAt: date,
            lastSyncCursor: ""
        )
        return RegisterDeviceResponse(
            device: device,
            deviceToken: "device-token-1",
            acceptedAt: date
        )
    }
}

@MainActor
final class DiaryIntentActionsTests: XCTestCase {
    func testCreateEntryQueuesLocally() async throws {
        let context = try makeContext()
        try await DiaryIntentActions.createEntry(
            text: "A thought worth keeping.",
            title: "Note",
            context: context,
            appState: makeAppState(),
            coordinator: SyncCoordinator()
        )

        let entries = try context.fetch(FetchDescriptor<DiaryEntry>())
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.bodyMarkdown, "A thought worth keeping.")
        XCTAssertFalse(try context.fetch(FetchDescriptor<PendingChange>()).isEmpty)
    }

    func testAppendToTodayUpdatesExistingEntry() async throws {
        let context = try makeContext()
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let todayEntry = DiaryEntry(
            id: "entry-today",
            createdAt: now,
            updatedAt: now,
            serverRevision: "rev-1",
            title: "Today",
            excerpt: "Morning",
            bodyMarkdown: "Morning."
        )
        context.insert(todayEntry)
        try context.save()

        let appended = try await DiaryIntentActions.appendToToday(
            text: "Afternoon.",
            now: now.addingTimeInterval(3600),
            context: context,
            appState: makeAppState(),
            coordinator: SyncCoordinator()
        )

        XCTAssertTrue(appended, "should append to the existing entry created today")
        XCTAssertTrue(todayEntry.bodyMarkdown.contains("Morning."))
        XCTAssertTrue(todayEntry.bodyMarkdown.contains("Afternoon."))
        XCTAssertEqual(try context.fetch(FetchDescriptor<DiaryEntry>()).count, 1)
    }

    func testAppendToTodayCreatesEntryWhenNoneToday() async throws {
        let context = try makeContext()
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        // An entry from a previous day must not be treated as today's.
        let oldEntry = DiaryEntry(
            id: "entry-old",
            createdAt: now.addingTimeInterval(-2 * 86_400),
            updatedAt: now.addingTimeInterval(-2 * 86_400),
            serverRevision: "rev-old",
            title: "Old",
            excerpt: "Old",
            bodyMarkdown: "Old."
        )
        context.insert(oldEntry)
        try context.save()

        let appended = try await DiaryIntentActions.appendToToday(
            text: "Fresh start.",
            now: now,
            context: context,
            appState: makeAppState(),
            coordinator: SyncCoordinator()
        )

        XCTAssertFalse(appended, "should create a new entry when none exists for today")
        XCTAssertEqual(try context.fetch(FetchDescriptor<DiaryEntry>()).count, 2)
    }

    func testSearchMatchesFoldedTermsAndIgnoresTombstones() async throws {
        let context = try makeContext()
        let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func make(_ id: String, _ title: String, _ body: String, at offset: TimeInterval, tombstoned: Bool = false) {
            let entry = DiaryEntry(
                id: id,
                createdAt: base.addingTimeInterval(offset),
                updatedAt: base.addingTimeInterval(offset),
                serverRevision: "rev-\(id)",
                title: title,
                excerpt: body,
                bodyMarkdown: body
            )
            entry.refreshSearchText()
            entry.isTombstoned = tombstoned
            context.insert(entry)
        }
        make("a", "Beach Day", "We visited the beach with Chase.", at: 0)
        make("b", "Rainy", "Stayed in and read.", at: 1)
        make("c", "Old Beach", "An old beach memory.", at: 2, tombstoned: true)
        try context.save()

        let results = try DiaryIntentActions.search(query: "BEACH", context: context)
        XCTAssertEqual(results, ["Beach Day"], "case-insensitive match, newest first, tombstones excluded")

        XCTAssertTrue(try DiaryIntentActions.search(query: "   ", context: context).isEmpty)
    }

    private func makeContext() throws -> ModelContext {
        let schema = Schema([
            DiaryEntry.self,
            DiaryAttachment.self,
            SyncCheckpoint.self,
            PendingChange.self,
            SyncEvent.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(for: schema, configurations: [configuration]))
    }

    private func makeAppState() -> AppState {
        let suiteName = "DiaryIntentActionsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return AppState(defaults: defaults, keychain: KeychainStore(service: suiteName))
    }
}

@MainActor
final class AppLockTests: XCTestCase {
    func testStartsLockedWhenEnabled() {
        let lock = AppLock(defaults: makeDefaults(enabled: true))
        XCTAssertTrue(lock.isEnabled)
        XCTAssertTrue(lock.isLocked, "an enabled lock should start locked so content never flashes before auth")
    }

    func testStartsUnlockedWhenDisabled() {
        let lock = AppLock(defaults: makeDefaults(enabled: false))
        XCTAssertFalse(lock.isEnabled)
        XCTAssertFalse(lock.isLocked)
    }

    func testEnablingDoesNotInterruptSessionButLocksOnBackground() {
        let lock = AppLock(defaults: makeDefaults(enabled: false))
        lock.isEnabled = true
        XCTAssertFalse(lock.isLocked, "enabling should not lock the active foreground session")

        lock.lock() // simulate moving to the background
        XCTAssertTrue(lock.isLocked)
    }

    func testDisablingUnlocksImmediately() {
        let lock = AppLock(defaults: makeDefaults(enabled: true))
        XCTAssertTrue(lock.isLocked)

        lock.isEnabled = false
        XCTAssertFalse(lock.isLocked)
    }

    func testLockIsNoOpWhenDisabled() {
        let lock = AppLock(defaults: makeDefaults(enabled: false))
        lock.lock()
        XCTAssertFalse(lock.isLocked)
    }

    func testEnabledStatePersistsAcrossLaunches() {
        let defaults = makeDefaults(enabled: false)
        AppLock(defaults: defaults).isEnabled = true

        let relaunched = AppLock(defaults: defaults)
        XCTAssertTrue(relaunched.isEnabled)
        XCTAssertTrue(relaunched.isLocked)
    }

    private func makeDefaults(enabled: Bool) -> UserDefaults {
        let suiteName = "AppLockTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(enabled, forKey: "appLockEnabled")
        return defaults
    }
}
