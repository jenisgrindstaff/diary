import Foundation
#if os(iOS)
import UIKit
#endif

actor SyncClient {
    private let baseURL: URL
    private let bearerToken: String?
    private let deviceID: String
    private let session: URLSession
    private let decoder: JSONDecoder

    init(baseURL: URL, bearerToken: String?, deviceID: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.bearerToken = bearerToken?.isEmpty == true ? nil : bearerToken
        self.deviceID = deviceID
        self.session = session

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601WithFractionalSeconds
        self.decoder = decoder
    }

    func fetchEntries(updatedSince cursor: String?) async throws -> EntrySyncEnvelope {
        var components = URLComponents(url: baseURL.appending(path: "/api/v1/entries"), resolvingAgainstBaseURL: false)
        if let cursor, !cursor.isEmpty {
            components?.queryItems = [URLQueryItem(name: "updated_since", value: cursor)]
        }

        guard let url = components?.url else {
            throw SyncClientError.invalidURL
        }

        let data = try await data(for: url, method: "GET")
        return try decoder.decode(EntrySyncEnvelope.self, from: data)
    }

    func searchEntries(query: String) async throws -> SearchEntriesResponse {
        var components = URLComponents(url: baseURL.appending(path: "/api/v1/search"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "q", value: query)]

        guard let url = components?.url else {
            throw SyncClientError.invalidURL
        }

        let data = try await data(for: url, method: "GET")
        return try decoder.decode(SearchEntriesResponse.self, from: data)
    }

    func registerDevice() async throws -> RegisterDeviceResponse {
        let url = baseURL.appending(path: "/api/v1/sync/register-device")
        let body = try JSONEncoder().encode([
            "device_id": deviceID,
            "display_name": DeviceMetadata.displayName,
            "platform": "ios",
            "app_version": DeviceMetadata.appVersion
        ])
        let data = try await data(for: url, method: "POST", body: body, contentType: "application/json")
        return try decoder.decode(RegisterDeviceResponse.self, from: data)
    }

    func createEntry(_ draft: EntryWriteDraft, clientMutationID: String) async throws -> EntryMutationResponse {
        let url = baseURL.appending(path: "/api/v1/entries")
        let request = EntryWriteRequest(
            createdAt: ISO8601DateFormatter.withFractionalSeconds.string(from: draft.createdAt),
            expectedServerRevision: nil,
            clientMutationID: clientMutationID,
            title: draft.title,
            bodyMarkdown: draft.bodyMarkdown,
            people: draft.people,
            tags: draft.tags
        )
        let body = try JSONEncoder().encode(request)
        let data = try await data(for: url, method: "POST", body: body, contentType: "application/json")
        return try decoder.decode(EntryMutationResponse.self, from: data)
    }

    func updateEntry(id: String, draft: EntryWriteDraft) async throws -> EntryMutationResponse {
        let url = baseURL.appending(path: "/api/v1/entries/\(id)")
        let request = EntryWriteRequest(
            createdAt: ISO8601DateFormatter.withFractionalSeconds.string(from: draft.createdAt),
            expectedServerRevision: draft.expectedServerRevision,
            clientMutationID: nil,
            title: draft.title,
            bodyMarkdown: draft.bodyMarkdown,
            people: draft.people,
            tags: draft.tags
        )
        let body = try JSONEncoder().encode(request)
        let data = try await data(for: url, method: "PATCH", body: body, contentType: "application/json")
        return try decoder.decode(EntryMutationResponse.self, from: data)
    }

    func attachMedia(_ media: MediaUploadDraft, to entryID: String) async throws -> EntryAttachmentMutationResponse {
        let url = baseURL.appending(path: "/api/v1/entries/\(entryID)/attachments")
        let boundary = "DiaryBoundary-\(UUID().uuidString)"
        let uploadFile = try multipartFile(media: media, boundary: boundary)
        defer { try? FileManager.default.removeItem(at: uploadFile) }

        let data = try await upload(
            for: url,
            method: "POST",
            fileURL: uploadFile,
            contentType: "multipart/form-data; boundary=\(boundary)"
        )
        return try decoder.decode(EntryAttachmentMutationResponse.self, from: data)
    }

    func removeMedia(id attachmentID: String, from entryID: String) async throws -> EntryAttachmentMutationResponse {
        let url = baseURL.appending(path: "/api/v1/entries/\(entryID)/attachments/\(attachmentID)")
        let data = try await data(for: url, method: "DELETE")
        return try decoder.decode(EntryAttachmentMutationResponse.self, from: data)
    }

    func deleteEntry(id entryID: String) async throws -> DeleteEntryResponse {
        let url = baseURL.appending(path: "/api/v1/entries/\(entryID)")
        let data = try await data(for: url, method: "DELETE")
        return try decoder.decode(DeleteEntryResponse.self, from: data)
    }

    func fetchAsset(id: String) async throws -> Data {
        let url = baseURL.appending(path: "/api/v1/assets/\(id)")
        return try await data(for: url, method: "GET")
    }

    private func data(for url: URL, method: String, body: Data? = nil, contentType: String? = nil) async throws -> Data {
        var request = request(for: url, method: method, contentType: contentType)
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        return try validate(data: data, response: response)
    }

    private func upload(for url: URL, method: String, fileURL: URL, contentType: String) async throws -> Data {
        let request = request(for: url, method: method, contentType: contentType)
        let (data, response) = try await session.upload(for: request, fromFile: fileURL)
        return try validate(data: data, response: response)
    }

    private func request(for url: URL, method: String, contentType: String?) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(deviceID, forHTTPHeaderField: "X-Diary-Device-ID")

        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }

        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }

        return request
    }

    private func validate(data: Data, response: URLResponse) throws -> Data {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SyncClientError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200..<300:
            return data
        case 401:
            throw SyncClientError.unauthorized
        case 409:
            if let conflict = try? decoder.decode(EntryMutationConflictResponse.self, from: data) {
                throw SyncClientError.entryConflict(conflict.error, conflict.entry)
            }

            fallthrough
        default:
            let message = (try? decoder.decode(ServerErrorResponse.self, from: data).error)
                ?? String(data: data, encoding: .utf8)
            throw SyncClientError.httpStatus(httpResponse.statusCode, message)
        }
    }

    private func multipartFile(media: MediaUploadDraft, boundary: String) throws -> URL {
        let uploadFile = FileManager.default.temporaryDirectory
            .appending(path: "diary-upload-\(UUID().uuidString).multipart")
        FileManager.default.createFile(atPath: uploadFile.path, contents: nil)

        let output = try FileHandle(forWritingTo: uploadFile)
        do {
            try output.write(contentsOf: Data("--\(boundary)\r\n".utf8))
            try output.write(contentsOf: Data("Content-Disposition: form-data; name=\"media\"; filename=\"\(media.filename.quotedForMultipart)\"\r\n".utf8))
            try output.write(contentsOf: Data("Content-Type: \(media.contentType)\r\n\r\n".utf8))
            try appendFile(at: media.fileURL, to: output)
            try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
            try output.close()
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(at: uploadFile)
            throw error
        }

        return uploadFile
    }

    private func appendFile(at fileURL: URL, to output: FileHandle) throws {
        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }

        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
    }
}

private struct ServerErrorResponse: Decodable {
    let error: String
}

private extension String {
    var quotedForMultipart: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

private enum DeviceMetadata {
    static var displayName: String {
        #if os(iOS)
        UIDevice.current.name
        #else
        "Diary Client"
        #endif
    }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}

enum SyncClientError: LocalizedError, Equatable {
    case invalidURL
    case invalidResponse
    case unauthorized
    case entryConflict(String, EntryDTO)
    case httpStatus(Int, String?)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The diary server URL is invalid."
        case .invalidResponse:
            return "The diary server returned an invalid response."
        case .unauthorized:
            return "The diary server rejected the saved access token."
        case .entryConflict:
            return "This entry changed on the server. Reload the latest copy before saving."
        case .httpStatus(let status, let message):
            if let message, !message.isEmpty {
                return "Server returned HTTP \(status): \(message)"
            }

            return "Server returned HTTP \(status)."
        }
    }

    static func == (lhs: SyncClientError, rhs: SyncClientError) -> Bool {
        switch (lhs, rhs) {
        case (.invalidURL, .invalidURL),
            (.invalidResponse, .invalidResponse),
            (.unauthorized, .unauthorized):
            return true
        case (.entryConflict(let lhsMessage, let lhsEntry), .entryConflict(let rhsMessage, let rhsEntry)):
            return lhsMessage == rhsMessage
                && lhsEntry.id == rhsEntry.id
                && lhsEntry.serverRevision == rhsEntry.serverRevision
        case (.httpStatus(let lhsStatus, let lhsMessage), .httpStatus(let rhsStatus, let rhsMessage)):
            return lhsStatus == rhsStatus && lhsMessage == rhsMessage
        default:
            return false
        }
    }
}

extension JSONDecoder.DateDecodingStrategy {
    static let iso8601WithFractionalSeconds = custom { decoder in
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)

        if let date = ISO8601DateFormatter.withFractionalSeconds.date(from: value) {
            return date
        }

        if let date = ISO8601DateFormatter.withInternetDateTime.date(from: value) {
            return date
        }

        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date: \(value)")
    }
}

private extension ISO8601DateFormatter {
    static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let withInternetDateTime: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
