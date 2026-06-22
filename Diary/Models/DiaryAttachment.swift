import Foundation
import SwiftData

@Model
final class DiaryAttachment {
    @Attribute(.unique) var id: String
    var kind: String
    var filename: String
    var contentType: String
    var remotePath: String
    var markdownPath: String
    var localRelativePath: String?
    var byteCount: Int
    var width: Int?
    var height: Int?
    var createdAt: Date?

    var entry: DiaryEntry?

    init(
        id: String,
        kind: String,
        filename: String,
        contentType: String = "",
        remotePath: String = "",
        markdownPath: String = "",
        localRelativePath: String? = nil,
        byteCount: Int = 0,
        width: Int? = nil,
        height: Int? = nil,
        createdAt: Date? = nil,
        entry: DiaryEntry? = nil
    ) {
        self.id = id
        self.kind = kind
        self.filename = filename
        self.contentType = contentType
        self.remotePath = remotePath
        self.markdownPath = markdownPath
        self.localRelativePath = localRelativePath
        self.byteCount = byteCount
        self.width = width
        self.height = height
        self.createdAt = createdAt
        self.entry = entry
    }
}

extension DiaryAttachment {
    var isImage: Bool {
        kind == "image" || contentType.hasPrefix("image/")
    }

    var isVideo: Bool {
        kind == "video" || contentType.hasPrefix("video/")
    }
}
