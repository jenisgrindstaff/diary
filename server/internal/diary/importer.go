package diary

import (
	"crypto/sha256"
	"encoding/hex"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type Importer struct {
	vaultDir  string
	importDir string
}

type ImportResult struct {
	ImportedEntries int      `json:"imported_entries"`
	SkippedEntries  int      `json:"skipped_entries"`
	ImportedAssets  int      `json:"imported_assets"`
	Entries         []string `json:"entries"`
}

func NewImporter(vaultDir, importDir string) *Importer {
	return &Importer{vaultDir: vaultDir, importDir: importDir}
}

func (i *Importer) Import(sourceDir string) (ImportResult, error) {
	if sourceDir == "" {
		sourceDir = i.importDir
	}

	var result ImportResult
	err := filepath.WalkDir(sourceDir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() || !isMarkdown(path) {
			return nil
		}

		legacyEntries, err := ParseLegacyLog(path)
		if err != nil {
			return err
		}
		if len(legacyEntries) > 1 {
			for _, entry := range legacyEntries {
				if err := i.importEntry(path, entry, &result); err != nil {
					return err
				}
			}
			return nil
		}

		entry, err := ParseMarkdown(path, "")
		if err != nil {
			return err
		}
		return i.importEntry(path, entry, &result)
	})

	return result, err
}

func (i *Importer) importEntry(path string, entry Entry, result *ImportResult) error {
	assets, err := i.copyAssets(path, entry)
	if err != nil {
		return err
	}
	entry.Attachments = append(entry.Attachments, assets...)

	destination := i.entryDestination(entry)
	if _, err := os.Stat(destination); err == nil {
		result.SkippedEntries++
		return nil
	}

	entry.VaultPath = destination
	if entry.SourcePath == "" {
		entry.SourcePath = path
	}
	entry.UpdatedAt = time.Now().UTC()
	entry.ServerRevision = stableRevision(entry.BodyMarkdown, entry.UpdatedAt)

	data, err := RenderMarkdown(entry)
	if err != nil {
		return err
	}

	if err := os.MkdirAll(filepath.Dir(destination), 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(destination, data, 0o644); err != nil {
		return err
	}

	result.ImportedEntries++
	result.ImportedAssets += len(assets)
	result.Entries = append(result.Entries, destination)
	return nil
}

func (i *Importer) copyAssets(markdownPath string, entry Entry) ([]Attachment, error) {
	var attachments []Attachment
	sourceDir := filepath.Dir(markdownPath)

	for _, ref := range ExtractLocalAssetRefs(entry.BodyMarkdown) {
		source := filepath.Clean(filepath.Join(sourceDir, ref))
		info, err := os.Stat(source)
		if err != nil || info.IsDir() {
			continue
		}

		filename := filepath.Base(source)
		id := assetID(entry.ID, ref)
		rel := filepath.Join("assets", entry.CreatedAt.Format("2006"), entry.CreatedAt.Format("01"), entry.ID, filename)
		dst := filepath.Join(i.vaultDir, rel)

		if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
			return nil, err
		}
		if err := copyFileIfMissing(source, dst); err != nil {
			return nil, err
		}

		attachments = append(attachments, Attachment{
			ID:           id,
			Kind:         KindForFilename(filename),
			Filename:     filename,
			ContentType:  ContentTypeForFilename(filename),
			RemotePath:   "/api/v1/assets/" + id,
			MarkdownPath: filepath.ToSlash(rel),
			ByteCount:    info.Size(),
			AbsolutePath: dst,
		})
	}

	return attachments, nil
}

func (i *Importer) entryDestination(entry Entry) string {
	return canonicalEntryPath(i.vaultDir, entry)
}

func copyFileIfMissing(src, dst string) error {
	if _, err := os.Stat(dst); err == nil {
		return nil
	}

	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()

	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer out.Close()

	_, err = io.Copy(out, in)
	return err
}

func assetID(entryID, ref string) string {
	sum := sha256.Sum256([]byte(entryID + "\n" + ref))
	return hex.EncodeToString(sum[:16])
}

func slugify(value string) string {
	value = strings.ToLower(value)
	var b strings.Builder
	lastDash := false

	for _, r := range value {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9':
			b.WriteRune(r)
			lastDash = false
		case !lastDash:
			b.WriteRune('-')
			lastDash = true
		}
	}

	return strings.Trim(b.String(), "-")
}
