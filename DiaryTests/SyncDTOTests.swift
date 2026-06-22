import XCTest
@testable import Diary

final class SyncDTOTests: XCTestCase {
    func testDecodesRegisterDeviceResponseFromServerJSON() throws {
        let json = """
        {
          "accepted_at": "2026-06-22T14:31:33.70067Z",
          "device": {
            "device_id": "device-1",
            "display_name": "iPhone",
            "platform": "ios",
            "app_version": "1.0",
            "registered_at": "2026-06-22T14:31:33.70067Z",
            "last_seen_at": "2026-06-22T14:31:33.70067Z",
            "last_sync_cursor": ""
          },
          "device_token": "device-token"
        }
        """.data(using: .utf8)!

        let response = try makeDecoder().decode(RegisterDeviceResponse.self, from: json)

        XCTAssertEqual(response.device.deviceID, "device-1")
        XCTAssertEqual(response.deviceToken, "device-token")
        XCTAssertEqual(response.device.lastSyncCursor, "")
    }

    func testDecodesEntryEnvelopeFromServerJSON() throws {
        let json = """
        {
          "entries": [
            {
              "id": "entry-1",
              "created_at": "2017-09-11T04:00:00Z",
              "updated_at": "2026-06-22T12:51:08.62125Z",
              "server_revision": "revision-1",
              "title": "Charlotte: She walked!!",
              "excerpt": "**Charlotte** * She walked!!",
              "body_markdown": "**Charlotte**\\n* She walked!!",
              "source_path": "/Users/jg/projects/Diary/imports/legacy-diary.md:1",
              "tags": ["legacy-import"],
              "people": ["Charlotte"],
              "subject_details": [
                {
                  "name": "Charlotte",
                  "raw_text": "**Charlotte**"
                }
              ],
              "attachments": []
            }
          ],
          "deleted_entry_ids": ["entry-2"],
          "next_cursor": "2026-06-22T13:44:00.48969Z"
        }
        """.data(using: .utf8)!

        let envelope = try makeDecoder().decode(EntrySyncEnvelope.self, from: json)

        XCTAssertEqual(envelope.entries.first?.id, "entry-1")
        XCTAssertEqual(envelope.deletedEntryIDs, ["entry-2"])
        XCTAssertEqual(envelope.nextCursor, "2026-06-22T13:44:00.48969Z")
    }

    func testDecodesDeleteEntryResponseFromServerJSON() throws {
        let json = """
        {
          "deleted_entry_id": "entry-1",
          "deleted_at": "2026-06-22T15:44:19.123456Z",
          "trash_path": "/vault/trash/2026/06/entry.md"
        }
        """.data(using: .utf8)!

        let response = try makeDecoder().decode(DeleteEntryResponse.self, from: json)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        XCTAssertEqual(response.deletedEntryID, "entry-1")
        XCTAssertEqual(response.trashPath, "/vault/trash/2026/06/entry.md")
        XCTAssertEqual(response.deletedAt, formatter.date(from: "2026-06-22T15:44:19.123456Z"))
    }

    func testDecodesEntryMutationConflictResponseFromServerJSON() throws {
        let json = """
        {
          "error": "entry has changed on the server",
          "entry": {
            "id": "entry-1",
            "created_at": "2026-06-22T15:24:19.123Z",
            "updated_at": "2026-06-22T15:30:00.000Z",
            "server_revision": "fresh-revision",
            "title": "Server Copy",
            "excerpt": "Latest text",
            "body_markdown": "Latest text",
            "source_path": "entries/2026/06/server-copy.md",
            "tags": [],
            "people": [],
            "attachments": []
          }
        }
        """.data(using: .utf8)!

        let response = try makeDecoder().decode(EntryMutationConflictResponse.self, from: json)

        XCTAssertEqual(response.error, "entry has changed on the server")
        XCTAssertEqual(response.entry.id, "entry-1")
        XCTAssertEqual(response.entry.serverRevision, "fresh-revision")
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601WithFractionalSeconds
        return decoder
    }
}
