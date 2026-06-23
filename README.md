# Diary

Diary is a Markdown-canonical journal system with a Go home server and an iOS SwiftUI/SwiftData client.

The home server owns the source of truth: Markdown files, relative media assets, tombstones, and the SQLite search/cache index. The iOS app uses SwiftData as an offline cache and sync workspace, with iOS as the primary day-to-day input surface.

## Repository Layout

- `server/`: Go HTTP server, Markdown vault reader/writer, API routes, web UI, SQLite index, and tests.
- `Diary/`: iOS 26 SwiftUI app with SwiftData models and sync coordination.
- `DiaryTests/`: SwiftData, DTO, sync, and suggestion tests.
- `docs/`: deeper server/API notes.
- `demo-vault/`: fake diary content for local development and screenshots.
- `vault/`: real local Markdown diary vault, ignored by Git.
- `imports/`: real legacy import staging area, ignored by Git.
- `server/tmp/`: local binaries, logs, and SQLite data, ignored by Git.

## Quick Start With Demo Data

Use this when you want to test without touching the real diary vault:

```sh
./server/scripts/run-demo-server.sh
```

The demo server listens on:

```text
http://127.0.0.1:18080
```

The local setup token is:

```text
local-dev-token
```

The demo runner copies `demo-vault/` into `server/tmp/demo-vault` on each launch, so edits, creates, deletes, and media tests are disposable.

Health check:

```sh
curl http://127.0.0.1:18080/healthz
```

Fetch demo entries:

```sh
curl http://127.0.0.1:18080/api/v1/entries \
  -H "Authorization: Bearer local-dev-token"
```

## Run With The Real Local Vault

```sh
./server/scripts/run-local-server.sh
```

By default this uses:

- Server URL: `http://127.0.0.1:18080`
- Token: `local-dev-token`
- Vault: `./vault`
- Imports: `./imports`
- SQLite data: `./server/tmp/data`

You can override any of those:

```sh
DIARY_ADDR=127.0.0.1:18081 \
DIARY_VAULT_DIR="$PWD/demo-vault" \
DIARY_DATA_DIR="$PWD/server/tmp/custom-data" \
DIARY_API_TOKEN="local-dev-token" \
./server/scripts/run-local-server.sh
```

## iOS Simulator Setup

1. Open `Diary.xcodeproj` in Xcode.
2. Run the `Diary` scheme on an iOS 26 simulator.
3. Go to Settings in the app.
4. Tap `Use Local Server`.
5. Tap `Check Server Health`.
6. Tap `Register Device`.
7. Tap `Sync Now`.

Registration exchanges the setup token for a per-device token. After that, normal sync uses the device token stored in the app keychain.

## Docker Compose

For the Docker path:

```sh
DIARY_API_TOKEN="replace-with-a-long-random-token" docker compose up --build
```

The compose setup mounts the real local `vault/` and `imports/` paths and stores SQLite in the `diary-data` volume. Keep the public deployment behind HTTPS and real authentication before exposing it outside the home network.

For an nginx + Authelia deployment where the Web UI uses two-factor auth and iOS keeps using bearer-token API sync, see [docs/nginx-authelia.md](docs/nginx-authelia.md).

## Common Development Commands

Run server tests:

```sh
cd server
go test ./...
```

Run iOS tests from the repo root:

```sh
xcodebuild -project Diary.xcodeproj \
  -scheme Diary \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  test
```

Build and launch the local server:

```sh
./server/scripts/run-local-server.sh
```

Build and launch the disposable demo server:

```sh
./server/scripts/run-demo-server.sh
```

## Markdown Vault Shape

Canonical entries live under:

```text
vault/entries/YYYY/MM/YYYY-MM-DD-title.md
```

Media assets live under:

```text
vault/assets/YYYY/MM/<entry-id>/
```

Deleted entries are moved to trash and recorded as tombstones:

```text
vault/trash/YYYY/MM/
vault/deletions/YYYY/MM/<entry-id>.yaml
```

People metadata can be configured in:

```text
vault/people.yaml
```

Example:

```yaml
people:
  - name: Charlotte
    born_at: 2016-10-07T00:56:00Z
  - name: Chase
    born_at: 2019-01-07T17:12:00Z
```

## Git Safety

The repo intentionally ignores:

- `vault/`
- `imports/`
- `server/tmp/`
- local SQLite files
- local server binaries
- Xcode user state
- `.env` files

That keeps real diary content, local logs, generated databases, and secrets out of Git. The committed `demo-vault/` contains only fake sample content.
