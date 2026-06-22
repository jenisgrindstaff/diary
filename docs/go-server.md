# Diary Go Home Server

This server is the first source-of-truth milestone. It keeps diary entries as canonical Markdown files under `vault/`, indexes them into SQLite for API/search, and exposes the sync contract the iOS app can consume later.

## Layout

- `vault/entries/YYYY/MM/YYYY-MM-DD-title.md`: normalized canonical Markdown files.
- `vault/assets/YYYY/MM/<entry-id>/...`: copied relative media assets.
- `vault/deletions/YYYY/MM/<entry-id>.yaml`: canonical tombstones for entries moved to trash.
- `vault/people.yaml`: optional people config with birth timestamps for automatic age chips.
- `imports/`: read-only staging folder for existing Markdown diary files.
- Docker volume `diary-data`: SQLite index/cache.

## Run Locally

```sh
export DIARY_API_TOKEN="replace-with-a-long-random-token"
docker-compose up --build
```

Health check:

```sh
curl http://localhost:8080/healthz
```

Import Markdown from `./imports`:

```sh
curl -X POST http://localhost:8080/api/v1/admin/import \
  -H "Authorization: Bearer $DIARY_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{}'
```

The importer supports two Markdown shapes:

- One Markdown file per diary entry.
- A legacy single-file log with repeated `#### date` headings. These files are split into individual canonical Markdown entries automatically when more than one valid date heading is found.

The legacy splitter currently understands dates like `2018-07-09`, `10-5-18`, `9/16/19`, and `2018-07-28 (21.828)`. It removes separator lines such as `____` and `---------------`, preserves the section body, and stores extracted bold/plain subject labels in the `people` metadata field for now.

Relative media links are copied into the canonical vault and indexed as attachments:

```md
![Charlotte at the park](media/charlotte-park.jpg)

[Birthday video](media/birthday.mov)

[Scanned note](media/note.pdf)
```

Images and videos render on the local web entry detail page. The API still serves assets through authenticated `/api/v1/assets/{id}` routes for the future iOS sync client.

You can also attach media from an entry detail page in the local web UI. Uploaded files are copied to `vault/assets/YYYY/MM/<entry-id>/...`, added to the entry's `attachments` frontmatter, and reindexed immediately.

The local web UI also supports creating new entries. Use `New Entry` from the header, enter a date, optional title, optional comma-separated people/tags, Markdown body text, and optional media files. The server writes a canonical Markdown file under `vault/entries/YYYY/MM/...`, copies media into `vault/assets/YYYY/MM/<entry-id>/...`, and reindexes immediately.

Existing entries can be edited from their detail page. The edit flow rewrites the canonical Markdown frontmatter/body, preserves existing attachments, moves the Markdown file if the date/title changes, and reindexes immediately.

Entries can also be moved to trash from their detail page. This moves the canonical Markdown file to `vault/trash/YYYY/MM/...`, writes a tombstone under `vault/deletions/YYYY/MM/...`, and reindexes immediately; it does not permanently delete the Markdown or remove media assets.

Automatic subject ages are configured in `vault/people.yaml`:

```yaml
people:
  - name: Charlotte
    born_at: 2016-10-07T00:56:00Z
  - name: Chase
    born_at: 2019-01-07T17:12:00Z
```

When an entry has matching `people`, the server adds `subject_details` age chips during entry creation and reindexing. Imported entries that already have explicit age text keep their original values.

Fetch entries:

```sh
curl http://localhost:8080/api/v1/entries \
  -H "Authorization: Bearer $DIARY_API_TOKEN"
```

Register an iOS client/device with the setup token:

```sh
curl -X POST http://localhost:8080/api/v1/sync/register-device \
  -H "Authorization: Bearer $DIARY_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "device_id": "ios-device-id",
    "display_name": "Johns iPhone",
    "platform": "ios",
    "app_version": "1.0"
  }'
```

The response includes a `device_token`. Store that token on the client and use it as the bearer token for normal sync/API requests. The server stores only a SHA-256 hash of the device token and records the device's latest sync cursor.

Incremental sync returns live entry updates and deleted entry IDs from the same cursor:

```json
{
  "entries": [],
  "deleted_entry_ids": ["entry-id"],
  "next_cursor": "2026-06-22T14:12:03.123456Z"
}
```

Create or update entries through the API:

```sh
curl -X POST http://localhost:8080/api/v1/entries \
  -H "Authorization: Bearer $DIARY_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "date": "2026-06-27",
    "title": "Optional title",
    "people": ["Charlotte", "Chase"],
    "tags": ["family"],
    "body_markdown": "* Markdown body."
  }'
```

```sh
curl -X PATCH http://localhost:8080/api/v1/entries/<entry-id> \
  -H "Authorization: Bearer $DIARY_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "date": "2026-06-27",
    "expected_server_revision": "revision-returned-by-last-sync",
    "title": "Updated title",
    "people": ["Charlotte"],
    "tags": ["edited"],
    "body_markdown": "* Updated Markdown body."
  }'
```

`expected_server_revision` is optional for simple callers, but iOS sends it to keep sync boring: if the server copy has changed since the app loaded the entry, the server returns `409 Conflict` with the latest entry payload.

Attach media and soft-delete entries:

```sh
curl -X POST http://localhost:8080/api/v1/entries/<entry-id>/attachments \
  -H "Authorization: Bearer $DIARY_API_TOKEN" \
  -F "media=@photo.jpg"

curl -X DELETE http://localhost:8080/api/v1/entries/<entry-id>/attachments/<attachment-id> \
  -H "Authorization: Bearer $DIARY_API_TOKEN"

curl -X DELETE http://localhost:8080/api/v1/entries/<entry-id> \
  -H "Authorization: Bearer $DIARY_API_TOKEN"
```

## Current Security Posture

The Go server implements setup-token protection plus per-device bearer tokens for API/admin routes so the local server can be exercised safely behind Docker Compose. Before exposing this publicly, keep the earlier security plan: Caddy HTTPS, password + TOTP or stronger login, CSRF protection for browser write flows, rate limiting, audit logs, and backups.
