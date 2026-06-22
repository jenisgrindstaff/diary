import Foundation
import SwiftData

@Model
final class SyncCheckpoint {
    @Attribute(.unique) var id: String
    var cursor: String?
    var deviceID: String
    var serverBaseURL: String
    var lastSuccessfulSyncAt: Date?
    var lastAttemptedSyncAt: Date?
    var lastError: String?

    init(
        id: String = SyncCheckpoint.defaultID,
        cursor: String? = nil,
        deviceID: String,
        serverBaseURL: String,
        lastSuccessfulSyncAt: Date? = nil,
        lastAttemptedSyncAt: Date? = nil,
        lastError: String? = nil
    ) {
        self.id = id
        self.cursor = cursor
        self.deviceID = deviceID
        self.serverBaseURL = serverBaseURL
        self.lastSuccessfulSyncAt = lastSuccessfulSyncAt
        self.lastAttemptedSyncAt = lastAttemptedSyncAt
        self.lastError = lastError
    }

    static let defaultID = "default"
}
