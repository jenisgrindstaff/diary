package store

import (
	"database/sql"
	"errors"
	"time"

	"diary/server/internal/diary"
	_ "modernc.org/sqlite"
)

type Store struct {
	db *sql.DB
}

func Open(path string) (*sql.DB, error) {
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	return db, nil
}

func New(db *sql.DB) *Store {
	return &Store{db: db}
}

func (s *Store) Migrate() error {
	_, err := s.db.Exec(`
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS entries (
	id TEXT PRIMARY KEY,
	created_at TEXT NOT NULL,
	updated_at TEXT NOT NULL,
	server_revision TEXT NOT NULL,
	title TEXT NOT NULL,
	excerpt TEXT NOT NULL,
	body_markdown TEXT NOT NULL,
	source_path TEXT NOT NULL,
	vault_path TEXT NOT NULL,
	tags_json TEXT NOT NULL,
	people_json TEXT NOT NULL,
	subject_details_json TEXT NOT NULL DEFAULT '[]'
);
CREATE TABLE IF NOT EXISTS attachments (
	id TEXT PRIMARY KEY,
	entry_id TEXT NOT NULL,
	kind TEXT NOT NULL,
	filename TEXT NOT NULL,
	content_type TEXT NOT NULL,
	remote_path TEXT NOT NULL,
	markdown_path TEXT NOT NULL,
	absolute_path TEXT NOT NULL,
	byte_count INTEGER NOT NULL,
	width INTEGER,
	height INTEGER,
	created_at TEXT,
	FOREIGN KEY(entry_id) REFERENCES entries(id) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS tombstones (
	entry_id TEXT PRIMARY KEY,
	deleted_at TEXT NOT NULL,
	source_path TEXT NOT NULL,
	trash_path TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS sync_devices (
	device_id TEXT PRIMARY KEY,
	display_name TEXT NOT NULL,
	platform TEXT NOT NULL,
	app_version TEXT NOT NULL,
	token_hash TEXT NOT NULL UNIQUE,
	registered_at TEXT NOT NULL,
	last_seen_at TEXT NOT NULL,
	last_sync_cursor TEXT NOT NULL DEFAULT ''
);
CREATE VIRTUAL TABLE IF NOT EXISTS entries_fts USING fts5(
	id UNINDEXED,
	title,
	excerpt,
	body_markdown,
	tags,
	people
);`)
	if err != nil {
		return err
	}

	return s.ensureColumn("entries", "subject_details_json", "TEXT NOT NULL DEFAULT '[]'")
}

func (s *Store) ensureColumn(table string, column string, definition string) error {
	rows, err := s.db.Query(`PRAGMA table_info(` + table + `)`)
	if err != nil {
		return err
	}
	defer rows.Close()

	for rows.Next() {
		var cid int
		var name, columnType string
		var notNull int
		var defaultValue any
		var pk int
		if err := rows.Scan(&cid, &name, &columnType, &notNull, &defaultValue, &pk); err != nil {
			return err
		}
		if name == column {
			return nil
		}
	}
	if err := rows.Err(); err != nil {
		return err
	}

	_, err = s.db.Exec(`ALTER TABLE ` + table + ` ADD COLUMN ` + column + ` ` + definition)
	return err
}

func (s *Store) ReplaceIndex(entries []diary.Entry, tombstones []diary.Tombstone) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	if _, err := tx.Exec(`DELETE FROM entries_fts; DELETE FROM attachments; DELETE FROM entries; DELETE FROM tombstones;`); err != nil {
		return err
	}

	for _, entry := range entries {
		if err := insertEntry(tx, entry); err != nil {
			return err
		}
	}
	for _, tombstone := range tombstones {
		if err := insertTombstone(tx, tombstone); err != nil {
			return err
		}
	}

	return tx.Commit()
}

func (s *Store) EntriesUpdatedSince(cursor string) ([]diary.Entry, string, error) {
	args := []any{}
	where := ""
	if cursor != "" {
		if _, err := time.Parse(time.RFC3339Nano, cursor); err != nil {
			return nil, "", err
		}
		where = "WHERE updated_at > ?"
		args = append(args, cursor)
	}

	rows, err := s.db.Query(`
SELECT id, created_at, updated_at, server_revision, title, excerpt, body_markdown, source_path, vault_path, tags_json, people_json, subject_details_json
FROM entries `+where+`
ORDER BY updated_at ASC`, args...)
	if err != nil {
		return nil, "", err
	}
	defer rows.Close()

	entries, err := scanEntries(rows, s.attachmentsForEntry)
	if err != nil {
		return nil, "", err
	}

	nextCursor := cursor
	for _, entry := range entries {
		if entry.UpdatedAt.Format(time.RFC3339Nano) > nextCursor {
			nextCursor = entry.UpdatedAt.Format(time.RFC3339Nano)
		}
	}

	return entries, nextCursor, nil
}

func (s *Store) TombstonesUpdatedSince(cursor string) ([]diary.Tombstone, string, error) {
	args := []any{}
	where := ""
	if cursor != "" {
		if _, err := time.Parse(time.RFC3339Nano, cursor); err != nil {
			return nil, "", err
		}
		where = "WHERE deleted_at > ?"
		args = append(args, cursor)
	}

	rows, err := s.db.Query(`
SELECT entry_id, deleted_at, source_path, trash_path
FROM tombstones `+where+`
ORDER BY deleted_at ASC`, args...)
	if err != nil {
		return nil, "", err
	}
	defer rows.Close()

	tombstones := []diary.Tombstone{}
	for rows.Next() {
		tombstone, err := scanTombstone(rows)
		if err != nil {
			return nil, "", err
		}
		tombstones = append(tombstones, tombstone)
	}
	if err := rows.Err(); err != nil {
		return nil, "", err
	}

	nextCursor := cursor
	for _, tombstone := range tombstones {
		deletedAt := tombstone.DeletedAt.Format(time.RFC3339Nano)
		if deletedAt > nextCursor {
			nextCursor = deletedAt
		}
	}

	return tombstones, nextCursor, nil
}

func (s *Store) Entries() ([]diary.Entry, error) {
	rows, err := s.db.Query(`
SELECT id, created_at, updated_at, server_revision, title, excerpt, body_markdown, source_path, vault_path, tags_json, people_json, subject_details_json
FROM entries
ORDER BY created_at DESC, title ASC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	return scanEntries(rows, s.attachmentsForEntry)
}

func (s *Store) Entry(id string) (diary.Entry, error) {
	rows, err := s.db.Query(`
SELECT id, created_at, updated_at, server_revision, title, excerpt, body_markdown, source_path, vault_path, tags_json, people_json, subject_details_json
FROM entries
WHERE id = ?`, id)
	if err != nil {
		return diary.Entry{}, err
	}
	defer rows.Close()

	entries, err := scanEntries(rows, s.attachmentsForEntry)
	if err != nil {
		return diary.Entry{}, err
	}
	if len(entries) == 0 {
		return diary.Entry{}, sql.ErrNoRows
	}

	return entries[0], nil
}

func (s *Store) Asset(id string) (diary.Attachment, error) {
	row := s.db.QueryRow(`
SELECT id, entry_id, kind, filename, content_type, remote_path, markdown_path, absolute_path, byte_count, width, height, created_at
FROM attachments
WHERE id = ?`, id)

	attachment, err := scanAttachment(row)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return diary.Attachment{}, err
		}
		return diary.Attachment{}, err
	}

	return attachment, nil
}
