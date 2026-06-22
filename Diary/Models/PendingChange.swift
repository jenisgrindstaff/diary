import Foundation
import SwiftData

@Model
final class PendingChange {
    @Attribute(.unique) var id: String
    var entryID: String
    var serverEntryID: String?
    var kind: String
    var payloadJSON: String
    var summary: String = ""
    var createdAt: Date
    var lastAttemptedAt: Date?
    var attemptCount: Int
    var status: String = PendingChangeStatus.pending.rawValue
    var lastError: String?

    init(
        id: String = UUID().uuidString,
        entryID: String,
        serverEntryID: String? = nil,
        kind: String,
        payloadJSON: String,
        summary: String,
        createdAt: Date = .now,
        lastAttemptedAt: Date? = nil,
        attemptCount: Int = 0,
        status: String = PendingChangeStatus.pending.rawValue,
        lastError: String? = nil
    ) {
        self.id = id
        self.entryID = entryID
        self.serverEntryID = serverEntryID
        self.kind = kind
        self.payloadJSON = payloadJSON
        self.summary = summary
        self.createdAt = createdAt
        self.lastAttemptedAt = lastAttemptedAt
        self.attemptCount = attemptCount
        self.status = status
        self.lastError = lastError
    }
}

extension PendingChange {
    var isFailed: Bool {
        status == PendingChangeStatus.failed.rawValue
    }

    var displayKind: String {
        switch kind {
        case PendingChangeKind.createEntry.rawValue:
            return "Create"
        case PendingChangeKind.updateEntry.rawValue:
            return "Update"
        case PendingChangeKind.deleteEntry.rawValue:
            return "Delete"
        default:
            return "Change"
        }
    }

    var symbolName: String {
        if isFailed {
            return "exclamationmark.triangle.fill"
        }

        switch kind {
        case PendingChangeKind.createEntry.rawValue:
            return "plus.circle.fill"
        case PendingChangeKind.updateEntry.rawValue:
            return "square.and.pencil"
        case PendingChangeKind.deleteEntry.rawValue:
            return "trash"
        default:
            return "clock"
        }
    }

    var displayError: String? {
        guard let lastError = lastError?.trimmingCharacters(in: .whitespacesAndNewlines),
              !lastError.isEmpty else {
            return nil
        }

        if canResolveConflict {
            return "The server copy changed before this edit synced. Resolve lets you compare both versions."
        }

        if lastError.localizedCaseInsensitiveContains("HTTP 404") {
            switch kind {
            case PendingChangeKind.deleteEntry.rawValue:
                return "The server no longer has this entry. Retry will clear the queued delete."
            default:
                return "The server could not find this entry. Retry after a sync, or discard this local queued change."
            }
        }

        if lastError.localizedCaseInsensitiveContains("access token")
            || lastError.localizedCaseInsensitiveContains("unauthorized") {
            return "The server rejected the saved access token. Re-register this device in Settings."
        }

        if lastError.localizedCaseInsensitiveContains("could not connect")
            || lastError.localizedCaseInsensitiveContains("offline")
            || lastError.localizedCaseInsensitiveContains("network") {
            return "The server is not reachable. Check the server URL and try again."
        }

        return lastError
    }

    var canResolveConflict: Bool {
        guard kind == PendingChangeKind.updateEntry.rawValue,
              isFailed,
              let lastError = lastError?.trimmingCharacters(in: .whitespacesAndNewlines),
              !lastError.isEmpty else {
            return false
        }

        return lastError.localizedCaseInsensitiveContains("changed on the server")
            || lastError.localizedCaseInsensitiveContains("conflict")
    }

    var recoveryHint: String {
        switch kind {
        case PendingChangeKind.createEntry.rawValue:
            return "Discard removes the unsynced local entry."
        case PendingChangeKind.updateEntry.rawValue:
            return "Discard removes the queued edit and reloads server truth on the next sync."
        case PendingChangeKind.deleteEntry.rawValue:
            return "Discard cancels the queued delete and reloads server truth on the next sync."
        default:
            return "Discard removes this queued local change."
        }
    }
}

enum PendingChangeKind: String, Codable {
    case createEntry = "create_entry"
    case updateEntry = "update_entry"
    case deleteEntry = "delete_entry"
}

enum PendingChangeStatus: String, Codable {
    case pending
    case failed
}
