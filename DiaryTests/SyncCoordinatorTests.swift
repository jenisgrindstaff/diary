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
