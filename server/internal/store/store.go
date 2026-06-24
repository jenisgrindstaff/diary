package store

import (
	"database/sql"
	"errors"
	"fmt"
	"regexp"
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
	subject_details_json TEXT NOT NULL DEFAULT '[]',
	context_json TEXT NOT NULL DEFAULT '{}'
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
);
CREATE INDEX IF NOT EXISTS idx_entries_updated_at ON entries(updated_at);
CREATE INDEX IF NOT EXISTS idx_entries_created_at ON entries(created_at);
CREATE INDEX IF NOT EXISTS idx_attachments_entry_id ON attachments(entry_id);
CREATE INDEX IF NOT EXISTS idx_tombstones_deleted_at ON tombstones(deleted_at);`)
	if err != nil {
		return err
	}

	if err := s.ensureColumn("entries", "subject_details_json", "TEXT NOT NULL DEFAULT '[]'"); err != nil {
		return err
	}
	return s.ensureColumn("entries", "context_json", "TEXT NOT NULL DEFAULT '{}'")
}

// identifierPattern guards the few schema-migration statements that interpolate
// table/column names into SQL (which cannot be parameterized). Inputs are
// always compile-time constants today; the allowlist keeps the pattern from
// becoming an injection vector if a caller ever passes dynamic input.
var identifierPattern = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)

func (s *Store) ensureColumn(table string, column string, definition string) error {
	if !identifierPattern.MatchString(table) || !identifierPattern.MatchString(column) {
		return fmt.Errorf("invalid identifier: table=%q column=%q", table, column)
	}
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

// IndexEntry upserts a single entry (and its attachments) into the index,
// replacing any existing rows for that id. It also clears any tombstone for the
// same id so a recreated entry reappears. This is the incremental equivalent of
// ReplaceIndex for one entry, used on the create/update/attach write paths so a
// single mutation does O(1) work instead of re-reading the whole vault.
func (s *Store) IndexEntry(entry diary.Entry) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	if err := deleteEntryRows(tx, entry.ID); err != nil {
		return err
	}
	if _, err := tx.Exec(`DELETE FROM tombstones WHERE entry_id = ?`, entry.ID); err != nil {
		return err
	}
	if err := insertEntry(tx, entry); err != nil {
		return err
	}

	return tx.Commit()
}

// IndexDeletion removes a single entry from the index and records its tombstone,
// the incremental equivalent of a full reindex after a trash operation.
func (s *Store) IndexDeletion(tombstone diary.Tombstone) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	if err := deleteEntryRows(tx, tombstone.EntryID); err != nil {
		return err
	}
	if _, err := tx.Exec(`DELETE FROM tombstones WHERE entry_id = ?`, tombstone.EntryID); err != nil {
		return err
	}
	if err := insertTombstone(tx, tombstone); err != nil {
		return err
	}

	return tx.Commit()
}

// EntriesUpdatedSince returns entries with updated_at greater than cursor in
// ascending order. When limit > 0 the result is paginated to at most ~limit
// entries and hasMore reports whether more remain (clients loop until it is
// false). Pagination never splits a group of entries sharing the same
// updated_at across pages, so no entry is skipped even when timestamps collide.
// limit <= 0 returns every matching entry (unbounded).
func (s *Store) EntriesUpdatedSince(cursor string, limit int) (entries []diary.Entry, nextCursor string, hasMore bool, err error) {
	args := []any{}
	where := ""
	if cursor != "" {
		if _, err := time.Parse(time.RFC3339Nano, cursor); err != nil {
			return nil, "", false, err
		}
		where = "WHERE updated_at > ?"
		args = append(args, cursor)
	}

	limitClause := ""
	if limit > 0 {
		// Fetch one extra row to detect both whether more entries remain and
		// whether the boundary timestamp group continues into the next page.
		limitClause = " LIMIT ?"
		args = append(args, limit+1)
	}

	rows, err := s.db.Query(`
SELECT id, created_at, updated_at, server_revision, title, excerpt, body_markdown, source_path, vault_path, tags_json, people_json, subject_details_json, context_json
FROM entries `+where+`
ORDER BY updated_at ASC`+limitClause, args...)
	if err != nil {
		return nil, "", false, err
	}
	defer rows.Close()

	entries, err = scanEntries(rows, s.attachmentsForEntries)
	if err != nil {
		return nil, "", false, err
	}

	if limit > 0 && len(entries) > limit {
		hasMore = true
		// We fetched limit+1 rows. Keep the first `limit`, but if the boundary
		// row shares its timestamp with the peeked extra row, drop that whole
		// trailing group so it is re-fetched intact next page rather than split.
		boundary := entries[limit-1].UpdatedAt
		page := entries[:limit]
		if boundary.Equal(entries[limit].UpdatedAt) {
			cut := len(page)
			for cut > 0 && page[cut-1].UpdatedAt.Equal(boundary) {
				cut--
			}
			page = page[:cut]
		}
		if len(page) == 0 {
			// A single timestamp group is larger than the page size; return the
			// whole group (unbounded) so the cursor can still advance.
			return s.entriesWithUpdatedAt(boundary)
		}
		entries = page
	}

	nextCursor = cursor
	for _, entry := range entries {
		if ts := entry.UpdatedAt.Format(time.RFC3339Nano); ts > nextCursor {
			nextCursor = ts
		}
	}

	return entries, nextCursor, hasMore, nil
}

// entriesWithUpdatedAt returns every entry sharing the given updated_at
// timestamp. It is the fallback for the rare case where one timestamp group is
// larger than a page, ensuring the sync cursor still makes forward progress.
func (s *Store) entriesWithUpdatedAt(updatedAt time.Time) ([]diary.Entry, string, bool, error) {
	ts := updatedAt.Format(time.RFC3339Nano)

	rows, err := s.db.Query(`
SELECT id, created_at, updated_at, server_revision, title, excerpt, body_markdown, source_path, vault_path, tags_json, people_json, subject_details_json, context_json
FROM entries
WHERE updated_at = ?
ORDER BY id ASC`, ts)
	if err != nil {
		return nil, "", false, err
	}
	defer rows.Close()

	entries, err := scanEntries(rows, s.attachmentsForEntries)
	if err != nil {
		return nil, "", false, err
	}

	var more bool
	if err := s.db.QueryRow(`SELECT EXISTS(SELECT 1 FROM entries WHERE updated_at > ?)`, ts).Scan(&more); err != nil {
		return nil, "", false, err
	}

	return entries, ts, more, nil
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
SELECT id, created_at, updated_at, server_revision, title, excerpt, body_markdown, source_path, vault_path, tags_json, people_json, subject_details_json, context_json
FROM entries
ORDER BY created_at DESC, title ASC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	return scanEntries(rows, s.attachmentsForEntries)
}

func (s *Store) Entry(id string) (diary.Entry, error) {
	rows, err := s.db.Query(`
SELECT id, created_at, updated_at, server_revision, title, excerpt, body_markdown, source_path, vault_path, tags_json, people_json, subject_details_json, context_json
FROM entries
WHERE id = ?`, id)
	if err != nil {
		return diary.Entry{}, err
	}
	defer rows.Close()

	entries, err := scanEntries(rows, s.attachmentsForEntries)
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
