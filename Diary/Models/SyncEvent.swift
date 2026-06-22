import Foundation
import SwiftData

@Model
final class SyncEvent {
    @Attribute(.unique) var id: String
    var timestamp: Date
    var kind: String
    var status: String
    var summary: String
    var detail: String?
    var entryID: String?

    init(
        id: String = UUID().uuidString,
        timestamp: Date = .now,
        kind: String,
        status: String,
        summary: String,
        detail: String? = nil,
        entryID: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.status = status
        self.summary = summary
        self.detail = detail
        self.entryID = entryID
    }

    var isFailure: Bool {
        status == SyncEventStatus.failed.rawValue
    }

    var symbolName: String {
        if isFailure {
            return "exclamationmark.triangle.fill"
        }

        switch kind {
        case SyncEventKind.fullSync.rawValue:
            return "arrow.triangle.2.circlepath"
        case SyncEventKind.createEntry.rawValue:
            return "plus.circle.fill"
        case SyncEventKind.updateEntry.rawValue:
            return "square.and.pencil"
        case SyncEventKind.deleteEntry.rawValue:
            return "trash"
        default:
            return "checkmark.circle.fill"
        }
    }
}

enum SyncEventKind: String {
    case fullSync = "full_sync"
    case createEntry = "create_entry"
    case updateEntry = "update_entry"
    case deleteEntry = "delete_entry"
}

enum SyncEventStatus: String {
    case succeeded
    case failed
}
