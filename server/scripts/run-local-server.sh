#!/bin/sh
set -eu

ROOT="/Users/jg/projects/Diary"
SERVER="$ROOT/server"
GO="/usr/local/go/bin/go"

export PATH="/usr/local/go/bin:/usr/bin:/bin:/usr/sbin:/sbin"

mkdir -p "$ROOT/vault" "$ROOT/imports" "$SERVER/tmp/data"

cd "$SERVER"
"$GO" build -o "$SERVER/tmp/diary-server-local" ./cmd/diary-server

export DIARY_ADDR="127.0.0.1:18080"
export DIARY_VAULT_DIR="$ROOT/vault"
export DIARY_IMPORT_DIR="$ROOT/imports"
export DIARY_DATA_DIR="$SERVER/tmp/data"
export DIARY_API_TOKEN="local-dev-token"

exec "$SERVER/tmp/diary-server-local"
