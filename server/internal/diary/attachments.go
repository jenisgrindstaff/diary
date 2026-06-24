package diary

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
)

func AttachFile(vaultDir string, entry Entry, filename string, contentType string, src io.Reader, now time.Time) (Entry, Attachment, error) {
	if entry.VaultPath == "" {
		return Entry{}, Attachment{}, fmt.Errorf("entry vault path is required")
	}
	if now.IsZero() {
		now = time.Now().UTC()
	}
	now = now.UTC()

	filename = safeAttachmentFilename(filename)
	relDir := filepath.Join("assets", entry.CreatedAt.Format("2006"), entry.CreatedAt.Format("01"), entry.ID)
	absDir := filepath.Join(vaultDir, relDir)
	if err := os.MkdirAll(absDir, 0o755); err != nil {
		return Entry{}, Attachment{}, err
	}

	filename = uniqueAttachmentFilename(absDir, filename)
	relPath := filepath.ToSlash(filepath.Join(relDir, filename))
	absPath := filepath.Join(vaultDir, relPath)

	out, err := os.OpenFile(absPath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
	if err != nil {
		return Entry{}, Attachment{}, err
	}
	byteCount, copyErr := io.Copy(out, src)
	closeErr := out.Close()
	if copyErr != nil {
		_ = os.Remove(absPath)
		return Entry{}, Attachment{}, copyErr
	}
	if closeErr != nil {
		_ = os.Remove(absPath)
		return Entry{}, Attachment{}, closeErr
	}

	if strings.TrimSpace(contentType) == "" || contentType == "application/octet-stream" {
		contentType = ContentTypeForFilename(filename)
	}

	attachment := Attachment{
		ID:           assetID(entry.ID, relPath),
		Kind:         KindForFilename(filename),
		Filename:     filename,
		ContentType:  contentType,
		RemotePath:   "/api/v1/assets/" + assetID(entry.ID, relPath),
		MarkdownPath: relPath,
		ByteCount:    byteCount,
		CreatedAt:    &now,
		AbsolutePath: absPath,
	}

	entry.Attachments = append(entry.Attachments, attachment)
	entry.UpdatedAt = now
	entry, err = ApplyConfiguredBirthdateDetails(vaultDir, entry)
	if err != nil {
		return Entry{}, Attachment{}, err
	}
	entry.ServerRevision = stableRevision(entry.BodyMarkdown, entry.UpdatedAt)
	entry.VaultPath = filepath.Clean(entry.VaultPath)

	data, err := RenderMarkdown(entry)
	if err != nil {
		return Entry{}, Attachment{}, err
	}
	if err := writeEntryFile(entry.VaultPath, data); err != nil {
		return Entry{}, Attachment{}, err
	}

	return entry, attachment, nil
}

func RemoveAttachment(vaultDir string, entry Entry, attachmentID string, now time.Time) (Entry, Attachment, error) {
	if entry.VaultPath == "" {
		return Entry{}, Attachment{}, fmt.Errorf("entry vault path is required")
	}
	if strings.TrimSpace(attachmentID) == "" {
		return Entry{}, Attachment{}, fmt.Errorf("attachment id is required")
	}
	if now.IsZero() {
		now = time.Now().UTC()
	}
	now = now.UTC()

	remaining := make([]Attachment, 0, len(entry.Attachments))
	var removed Attachment
	found := false
	for _, attachment := range entry.Attachments {
		if attachment.ID == attachmentID {
			removed = attachment
			found = true
			continue
		}
		remaining = append(remaining, attachment)
	}
	if !found {
		return Entry{}, Attachment{}, fmt.Errorf("attachment not found")
	}

	entry.Attachments = remaining
	entry.UpdatedAt = now
	entry, err := ApplyConfiguredBirthdateDetails(vaultDir, entry)
	if err != nil {
		return Entry{}, Attachment{}, err
	}
	entry.ServerRevision = stableRevision(entry.BodyMarkdown, entry.UpdatedAt)
	entry.VaultPath = filepath.Clean(entry.VaultPath)

	data, err := RenderMarkdown(entry)
	if err != nil {
		return Entry{}, Attachment{}, err
	}
	if err := writeEntryFile(entry.VaultPath, data); err != nil {
		return Entry{}, Attachment{}, err
	}

	_ = removeAttachmentFile(vaultDir, removed)
	return entry, removed, nil
}

func removeAttachmentFile(vaultDir string, attachment Attachment) error {
	absPath := attachment.AbsolutePath
	if absPath == "" && attachment.MarkdownPath != "" {
		absPath = filepath.Join(vaultDir, filepath.FromSlash(attachment.MarkdownPath))
	}
	if absPath == "" {
		return nil
	}

	cleanVault, err := filepath.Abs(vaultDir)
	if err != nil {
		return err
	}
	cleanPath, err := filepath.Abs(absPath)
	if err != nil {
		return err
	}
	rel, err := filepath.Rel(cleanVault, cleanPath)
	if err != nil {
		return err
	}
	if rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return fmt.Errorf("attachment path is outside vault")
	}

	if err := os.Remove(cleanPath); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

func safeAttachmentFilename(filename string) string {
	filename = strings.TrimSpace(filepath.Base(filename))
	if filename == "." || filename == string(filepath.Separator) || filename == "" {
		return "attachment"
	}

	var b strings.Builder
	lastDash := false
	for _, r := range filename {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '.', r == '_':
			b.WriteRune(r)
			lastDash = false
		default:
			if !lastDash {
				b.WriteRune('-')
				lastDash = true
			}
		}
	}
	cleaned := strings.Trim(b.String(), "-.")
	if cleaned == "" {
		return "attachment"
	}
	return cleaned
}

func uniqueAttachmentFilename(dir string, filename string) string {
	ext := filepath.Ext(filename)
	base := strings.TrimSuffix(filename, ext)
	if base == "" {
		base = "attachment"
	}

	candidate := filename
	for i := 2; ; i++ {
		if _, err := os.Stat(filepath.Join(dir, candidate)); os.IsNotExist(err) {
			return candidate
		}
		candidate = fmt.Sprintf("%s-%d%s", base, i, ext)
	}
}
