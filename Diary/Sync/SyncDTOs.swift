import Foundation

struct EntrySyncEnvelope: Decodable, Sendable {
    let entries: [EntryDTO]
    let deletedEntryIDs: [String]
    let nextCursor: String?
    let hasMore: Bool

    init(entries: [EntryDTO], deletedEntryIDs: [String], nextCursor: String?, hasMore: Bool = false) {
        self.entries = entries
        self.deletedEntryIDs = deletedEntryIDs
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entries = try container.decodeIfPresent([EntryDTO].self, forKey: .entries) ?? []
        deletedEntryIDs = try container.decodeIfPresent([String].self, forKey: .deletedEntryIDs) ?? []
        nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
        // Absent on older servers that returned a single unpaginated response.
        hasMore = try container.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case entries
        case deletedEntryIDs = "deleted_entry_ids"
        case nextCursor = "next_cursor"
        case hasMore = "has_more"
    }
}

struct SearchEntriesResponse: Decodable, Sendable {
    let entries: [EntryDTO]
    let query: String
    let snippets: [SearchSnippetDTO]

    var snippetsByEntryID: [String: String] {
        Dictionary(snippets.map { ($0.entryID, $0.text) }, uniquingKeysWith: { first, _ in first })
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entries = try container.decode([EntryDTO].self, forKey: .entries)
        query = try container.decode(String.self, forKey: .query)
        snippets = try container.decodeIfPresent([SearchSnippetDTO].self, forKey: .snippets) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case entries
        case query
        case snippets
    }
}

struct SearchSnippetDTO: Decodable, Sendable {
    let entryID: String
    let text: String

    private enum CodingKeys: String, CodingKey {
        case entryID = "entry_id"
        case text
    }
}

struct EntryDTO: Decodable, Sendable {
    let id: String
    let createdAt: Date
    let updatedAt: Date
    let serverRevision: String
    let title: String
    let excerpt: String
    let bodyMarkdown: String
    let sourcePath: String
    let tags: [String]
    let people: [String]
    let subjectDetails: [SubjectDetailDTO]
    let attachments: [AttachmentDTO]

    init(
        id: String,
        createdAt: Date,
        updatedAt: Date,
        serverRevision: String,
        title: String,
        excerpt: String,
        bodyMarkdown: String,
        sourcePath: String,
        tags: [String],
        people: [String],
        subjectDetails: [SubjectDetailDTO] = [],
        attachments: [AttachmentDTO]
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.serverRevision = serverRevision
        self.title = title
        self.excerpt = excerpt
        self.bodyMarkdown = bodyMarkdown
        self.sourcePath = sourcePath
        self.tags = tags
        self.people = people
        self.subjectDetails = subjectDetails
        self.attachments = attachments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        serverRevision = try container.decode(String.self, forKey: .serverRevision)
        title = try container.decode(String.self, forKey: .title)
        excerpt = try container.decode(String.self, forKey: .excerpt)
        bodyMarkdown = try container.decode(String.self, forKey: .bodyMarkdown)
        sourcePath = try container.decode(String.self, forKey: .sourcePath)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        people = try container.decodeIfPresent([String].self, forKey: .people) ?? []
        subjectDetails = try container.decodeIfPresent([SubjectDetailDTO].self, forKey: .subjectDetails) ?? []
        attachments = try container.decodeIfPresent([AttachmentDTO].self, forKey: .attachments) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case serverRevision = "server_revision"
        case title
        case excerpt
        case bodyMarkdown = "body_markdown"
        case sourcePath = "source_path"
        case tags
        case people
        case subjectDetails = "subject_details"
        case attachments
    }
}

struct SubjectDetailDTO: Decodable, Sendable {
    let name: String
    let label: String?
    let ageText: String?
    let rawText: String?

    init(name: String, label: String? = nil, ageText: String? = nil, rawText: String? = nil) {
        self.name = name
        self.label = label
        self.ageText = ageText
        self.rawText = rawText
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case label
        case ageText = "age_text"
        case rawText = "raw_text"
    }
}

struct AttachmentDTO: Decodable, Sendable {
    let id: String
    let kind: String
    let filename: String
    let contentType: String
    let remotePath: String
    let markdownPath: String
    let byteCount: Int
    let width: Int?
    let height: Int?
    let createdAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case filename
        case contentType = "content_type"
        case remotePath = "remote_path"
        case markdownPath = "markdown_path"
        case byteCount = "byte_count"
        case width
        case height
        case createdAt = "created_at"
    }
}

struct SyncDeviceDTO: Decodable, Sendable {
    let deviceID: String
    let displayName: String
    let platform: String
    let appVersion: String
    let registeredAt: Date
    let lastSeenAt: Date
    let lastSyncCursor: String

    private enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case displayName = "display_name"
        case platform
        case appVersion = "app_version"
        case registeredAt = "registered_at"
        case lastSeenAt = "last_seen_at"
        case lastSyncCursor = "last_sync_cursor"
    }
}

struct RegisterDeviceResponse: Decodable, Sendable {
    let device: SyncDeviceDTO
    let deviceToken: String
    let acceptedAt: Date

    private enum CodingKeys: String, CodingKey {
        case device
        case deviceToken = "device_token"
        case acceptedAt = "accepted_at"
    }
}

struct EntryMutationResponse: Decodable, Sendable {
    let entry: EntryDTO
}

struct EntryMutationConflictResponse: Decodable, Sendable {
    let error: String
    let entry: EntryDTO
}

struct EntryAttachmentMutationResponse: Decodable, Sendable {
    let entry: EntryDTO
}

struct DeleteEntryResponse: Decodable, Sendable {
    let deletedEntryID: String
    let deletedAt: Date
    let trashPath: String

    private enum CodingKeys: String, CodingKey {
        case deletedEntryID = "deleted_entry_id"
        case deletedAt = "deleted_at"
        case trashPath = "trash_path"
    }
}

struct EntryWriteDraft: Codable, Sendable {
    let createdAt: Date
    let expectedServerRevision: String?
    let title: String
    let bodyMarkdown: String
    let people: [String]
    let tags: [String]

    init(
        createdAt: Date,
        expectedServerRevision: String? = nil,
        title: String,
        bodyMarkdown: String,
        people: [String],
        tags: [String]
    ) {
        self.createdAt = createdAt
        self.expectedServerRevision = expectedServerRevision
        self.title = title
        self.bodyMarkdown = bodyMarkdown
        self.people = people
        self.tags = tags
    }
}

struct MediaUploadDraft: Identifiable, Sendable {
    let id: String
    let filename: String
    let contentType: String
    let fileURL: URL
    let byteCount: Int
}

struct EntryWriteRequest: Encodable, Sendable {
    let createdAt: String
    let expectedServerRevision: String?
    let clientMutationID: String?
    let title: String
    let bodyMarkdown: String
    let people: [String]
    let tags: [String]

    private enum CodingKeys: String, CodingKey {
        case createdAt = "created_at"
        case expectedServerRevision = "expected_server_revision"
        case clientMutationID = "client_mutation_id"
        case title
        case bodyMarkdown = "body_markdown"
        case people
        case tags
    }
}
