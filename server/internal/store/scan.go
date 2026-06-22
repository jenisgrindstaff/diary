package store

import (
	"database/sql"
	"encoding/json"
	"time"

	"diary/server/internal/diary"
)

type rowScanner interface {
	Scan(dest ...any) error
}

func insertEntry(tx *sql.Tx, entry diary.Entry) error {
	tagsJSON, _ := json.Marshal(entry.Tags)
	peopleJSON, _ := json.Marshal(entry.People)
	subjectDetailsJSON, _ := json.Marshal(entry.SubjectDetails)

	_, err := tx.Exec(`
INSERT INTO entries (id, created_at, updated_at, server_revision, title, excerpt, body_markdown, source_path, vault_path, tags_json, people_json, subject_details_json)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		entry.ID,
		entry.CreatedAt.Format(time.RFC3339Nano),
		entry.UpdatedAt.Format(time.RFC3339Nano),
		entry.ServerRevision,
		entry.Title,
		entry.Excerpt,
		entry.BodyMarkdown,
		entry.SourcePath,
		entry.VaultPath,
		string(tagsJSON),
		string(peopleJSON),
		string(subjectDetailsJSON),
	)
	if err != nil {
		return err
	}

	_, err = tx.Exec(`
INSERT INTO entries_fts (id, title, excerpt, body_markdown, tags, people)
VALUES (?, ?, ?, ?, ?, ?)`,
		entry.ID,
		entry.Title,
		entry.Excerpt,
		entry.BodyMarkdown,
		join(entry.Tags),
		join(entry.People),
	)
	if err != nil {
		return err
	}

	for _, attachment := range entry.Attachments {
		if err := insertAttachment(tx, entry.ID, attachment); err != nil {
			return err
		}
	}

	return nil
}

func insertAttachment(tx *sql.Tx, entryID string, attachment diary.Attachment) error {
	var createdAt any
	if attachment.CreatedAt != nil {
		createdAt = attachment.CreatedAt.Format(time.RFC3339Nano)
	}

	_, err := tx.Exec(`
INSERT INTO attachments (id, entry_id, kind, filename, content_type, remote_path, markdown_path, absolute_path, byte_count, width, height, created_at)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		attachment.ID,
		entryID,
		attachment.Kind,
		attachment.Filename,
		attachment.ContentType,
		attachment.RemotePath,
		attachment.MarkdownPath,
		attachment.AbsolutePath,
		attachment.ByteCount,
		attachment.Width,
		attachment.Height,
		createdAt,
	)
	return err
}

func insertTombstone(tx *sql.Tx, tombstone diary.Tombstone) error {
	_, err := tx.Exec(`
INSERT INTO tombstones (entry_id, deleted_at, source_path, trash_path)
VALUES (?, ?, ?, ?)`,
		tombstone.EntryID,
		tombstone.DeletedAt.Format(time.RFC3339Nano),
		tombstone.SourcePath,
		tombstone.TrashPath,
	)
	return err
}

func scanEntries(rows *sql.Rows, attachments func(string) ([]diary.Attachment, error)) ([]diary.Entry, error) {
	entries := []diary.Entry{}
	for rows.Next() {
		entry, err := scanEntry(rows)
		if err != nil {
			return nil, err
		}
		entries = append(entries, entry)
	}

	if err := rows.Err(); err != nil {
		return nil, err
	}
	if err := rows.Close(); err != nil {
		return nil, err
	}

	for i := range entries {
		entryAttachments, err := attachments(entries[i].ID)
		if err != nil {
			return nil, err
		}
		entries[i].Attachments = entryAttachments
	}

	return entries, nil
}

func scanEntry(row rowScanner) (diary.Entry, error) {
	var entry diary.Entry
	var createdAt, updatedAt, tagsJSON, peopleJSON, subjectDetailsJSON string
	if err := row.Scan(
		&entry.ID,
		&createdAt,
		&updatedAt,
		&entry.ServerRevision,
		&entry.Title,
		&entry.Excerpt,
		&entry.BodyMarkdown,
		&entry.SourcePath,
		&entry.VaultPath,
		&tagsJSON,
		&peopleJSON,
		&subjectDetailsJSON,
	); err != nil {
		return diary.Entry{}, err
	}

	entry.CreatedAt, _ = time.Parse(time.RFC3339Nano, createdAt)
	entry.UpdatedAt, _ = time.Parse(time.RFC3339Nano, updatedAt)
	_ = json.Unmarshal([]byte(tagsJSON), &entry.Tags)
	_ = json.Unmarshal([]byte(peopleJSON), &entry.People)
	_ = json.Unmarshal([]byte(subjectDetailsJSON), &entry.SubjectDetails)
	if entry.SubjectDetails == nil {
		entry.SubjectDetails = []diary.SubjectDetail{}
	}
	return entry, nil
}

func (s *Store) attachmentsForEntry(entryID string) ([]diary.Attachment, error) {
	rows, err := s.db.Query(`
SELECT id, entry_id, kind, filename, content_type, remote_path, markdown_path, absolute_path, byte_count, width, height, created_at
FROM attachments
WHERE entry_id = ?
ORDER BY filename`, entryID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	attachments := []diary.Attachment{}
	for rows.Next() {
		attachment, err := scanAttachment(rows)
		if err != nil {
			return nil, err
		}
		attachments = append(attachments, attachment)
	}

	return attachments, rows.Err()
}

func scanAttachment(row rowScanner) (diary.Attachment, error) {
	var attachment diary.Attachment
	var entryID string
	var createdAt sql.NullString
	if err := row.Scan(
		&attachment.ID,
		&entryID,
		&attachment.Kind,
		&attachment.Filename,
		&attachment.ContentType,
		&attachment.RemotePath,
		&attachment.MarkdownPath,
		&attachment.AbsolutePath,
		&attachment.ByteCount,
		&attachment.Width,
		&attachment.Height,
		&createdAt,
	); err != nil {
		return diary.Attachment{}, err
	}

	if createdAt.Valid {
		if parsed, err := time.Parse(time.RFC3339Nano, createdAt.String); err == nil {
			attachment.CreatedAt = &parsed
		}
	}

	return attachment, nil
}

func scanTombstone(row rowScanner) (diary.Tombstone, error) {
	var tombstone diary.Tombstone
	var deletedAt string
	if err := row.Scan(
		&tombstone.EntryID,
		&deletedAt,
		&tombstone.SourcePath,
		&tombstone.TrashPath,
	); err != nil {
		return diary.Tombstone{}, err
	}

	tombstone.DeletedAt, _ = time.Parse(time.RFC3339Nano, deletedAt)
	return tombstone, nil
}

func join(values []string) string {
	out := ""
	for i, value := range values {
		if i > 0 {
			out += " "
		}
		out += value
	}
	return out
}
