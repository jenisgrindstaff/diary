package diary

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

type CreateEntryInput struct {
	ID           string
	CreatedAt    time.Time
	Title        string
	BodyMarkdown string
	People       []string
	Tags         []string
	Now          time.Time
}

type UpdateEntryInput struct {
	CreatedAt    time.Time
	Title        string
	BodyMarkdown string
	People       []string
	Tags         []string
	Now          time.Time
}

func CreateEntry(vaultDir string, input CreateEntryInput) (Entry, error) {
	body := strings.TrimSpace(input.BodyMarkdown)
	if body == "" {
		return Entry{}, fmt.Errorf("body is required")
	}

	now := input.Now
	if now.IsZero() {
		now = time.Now()
	}
	now = now.UTC()

	createdAt := input.CreatedAt
	if createdAt.IsZero() {
		createdAt = now
	}
	createdAt = createdAt.UTC()

	subjectDetails := extractSubjectDetails(body)
	people := cleanList(input.People)
	if len(people) == 0 {
		people = subjectsFromDetails(subjectDetails)
	}
	tags := cleanList(input.Tags)

	title := strings.TrimSpace(input.Title)
	if shouldDeriveTitle(title, people, createdAt) {
		title = derivedTitle(body, people, createdAt, title)
	}

	id := strings.TrimSpace(input.ID)
	if id == "" {
		generatedID, err := randomID()
		if err != nil {
			generatedID = stableID(createdAt.Format(time.RFC3339Nano), body)
		}
		id = generatedID
	}

	entry := Entry{
		ID:             id,
		CreatedAt:      createdAt,
		UpdatedAt:      now,
		Title:          title,
		Excerpt:        excerpt(body),
		BodyMarkdown:   body,
		SourcePath:     "web",
		Tags:           tags,
		People:         people,
		SubjectDetails: subjectDetails,
		Attachments:    []Attachment{},
	}
	configuredPeople, err := LoadPeople(vaultDir)
	if err != nil {
		return Entry{}, err
	}
	entry = ApplyBirthdateDetails(entry, configuredPeople)
	entry.ServerRevision = stableRevision(entry.BodyMarkdown, entry.UpdatedAt)
	entry.VaultPath = canonicalEntryPath(vaultDir, entry)

	if err := os.MkdirAll(filepath.Dir(entry.VaultPath), 0o755); err != nil {
		return Entry{}, err
	}
	data, err := RenderMarkdown(entry)
	if err != nil {
		return Entry{}, err
	}
	if err := writeEntryFile(entry.VaultPath, data); err != nil {
		return Entry{}, err
	}

	return entry, nil
}

// writeEntryFile writes entry markdown atomically: it writes to a temp file in
// the same directory and renames it into place, so a crash or concurrent write
// mid-update can't leave a truncated entry on disk.
func writeEntryFile(path string, data []byte) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), ".entry-*.tmp")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		_ = os.Remove(tmpName)
		return err
	}
	if err := tmp.Close(); err != nil {
		_ = os.Remove(tmpName)
		return err
	}
	if err := os.Rename(tmpName, path); err != nil {
		_ = os.Remove(tmpName)
		return err
	}
	return nil
}

func UpdateEntry(vaultDir string, existing Entry, input UpdateEntryInput) (Entry, error) {
	body := strings.TrimSpace(input.BodyMarkdown)
	if body == "" {
		return Entry{}, fmt.Errorf("body is required")
	}

	now := input.Now
	if now.IsZero() {
		now = time.Now()
	}
	now = now.UTC()

	createdAt := input.CreatedAt
	if createdAt.IsZero() {
		createdAt = existing.CreatedAt
	}
	createdAt = createdAt.UTC()

	subjectDetails := extractSubjectDetails(body)
	people := cleanList(input.People)
	if len(people) == 0 {
		people = subjectsFromDetails(subjectDetails)
	}

	title := strings.TrimSpace(input.Title)
	if shouldDeriveTitle(title, people, createdAt) {
		title = derivedTitle(body, people, createdAt, title)
	}

	entry := existing
	entry.CreatedAt = createdAt
	entry.UpdatedAt = now
	entry.Title = title
	entry.Excerpt = excerpt(body)
	entry.BodyMarkdown = body
	entry.Tags = cleanList(input.Tags)
	entry.People = people
	entry.SubjectDetails = subjectDetails
	entry.Attachments = existing.Attachments

	configuredPeople, err := LoadPeople(vaultDir)
	if err != nil {
		return Entry{}, err
	}
	entry = ApplyBirthdateDetails(entry, configuredPeople)
	entry.ServerRevision = stableRevision(entry.BodyMarkdown, entry.UpdatedAt)

	oldPath := entry.VaultPath
	if oldPath == "" {
		return Entry{}, fmt.Errorf("entry vault path is required")
	}
	newPath := canonicalEntryPath(vaultDir, entry)
	entry.VaultPath = newPath

	if err := os.MkdirAll(filepath.Dir(newPath), 0o755); err != nil {
		return Entry{}, err
	}
	data, err := RenderMarkdown(entry)
	if err != nil {
		return Entry{}, err
	}
	if err := writeEntryFile(newPath, data); err != nil {
		return Entry{}, err
	}
	if oldPath != newPath {
		if err := os.Remove(oldPath); err != nil && !os.IsNotExist(err) {
			return Entry{}, err
		}
	}

	return entry, nil
}

func TrashEntry(vaultDir string, entry Entry, now time.Time) (Tombstone, error) {
	if entry.VaultPath == "" {
		return Tombstone{}, fmt.Errorf("entry vault path is required")
	}
	if now.IsZero() {
		now = time.Now()
	}
	now = now.UTC()

	trashDir := filepath.Join(vaultDir, "trash", now.Format("2006"), now.Format("01"))
	if err := os.MkdirAll(trashDir, 0o755); err != nil {
		return Tombstone{}, err
	}

	destination := uniqueTrashPath(trashDir, filepath.Base(entry.VaultPath))
	if err := os.Rename(entry.VaultPath, destination); err != nil {
		return Tombstone{}, err
	}

	tombstone := Tombstone{
		EntryID:    entry.ID,
		DeletedAt:  now,
		SourcePath: entry.VaultPath,
		TrashPath:  destination,
	}
	if err := WriteTombstone(vaultDir, tombstone); err != nil {
		if restoreErr := os.Rename(destination, entry.VaultPath); restoreErr != nil {
			return Tombstone{}, fmt.Errorf("tombstone write failed (%w) and entry could not be restored from trash at %s: %v", err, destination, restoreErr)
		}
		return Tombstone{}, err
	}

	return tombstone, nil
}

func WriteTombstone(vaultDir string, tombstone Tombstone) error {
	if strings.TrimSpace(tombstone.EntryID) == "" {
		return fmt.Errorf("entry id is required")
	}
	if tombstone.DeletedAt.IsZero() {
		tombstone.DeletedAt = time.Now().UTC()
	} else {
		tombstone.DeletedAt = tombstone.DeletedAt.UTC()
	}

	dir := filepath.Join(vaultDir, "deletions", tombstone.DeletedAt.Format("2006"), tombstone.DeletedAt.Format("01"))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}

	data, err := yaml.Marshal(tombstone)
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(dir, tombstone.EntryID+".yaml"), data, 0o644)
}

func ReadTombstones(vaultDir string) ([]Tombstone, error) {
	var tombstones []Tombstone
	deletionsDir := filepath.Join(vaultDir, "deletions")
	err := filepath.WalkDir(deletionsDir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() || filepath.Ext(path) != ".yaml" {
			return nil
		}

		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		var tombstone Tombstone
		if err := yaml.Unmarshal(data, &tombstone); err != nil {
			return err
		}
		if strings.TrimSpace(tombstone.EntryID) == "" {
			return fmt.Errorf("tombstone %s is missing entry_id", path)
		}
		tombstone.DeletedAt = tombstone.DeletedAt.UTC()
		tombstones = append(tombstones, tombstone)
		return nil
	})
	if err != nil && !os.IsNotExist(err) {
		return nil, err
	}

	sort.Slice(tombstones, func(i, j int) bool {
		return tombstones[i].DeletedAt.Before(tombstones[j].DeletedAt)
	})
	return tombstones, nil
}

func uniqueTrashPath(dir string, filename string) string {
	ext := filepath.Ext(filename)
	base := strings.TrimSuffix(filename, ext)
	if base == "" {
		base = "entry"
	}

	candidate := filepath.Join(dir, filename)
	for i := 2; ; i++ {
		if _, err := os.Stat(candidate); os.IsNotExist(err) {
			return candidate
		}
		candidate = filepath.Join(dir, fmt.Sprintf("%s-%d%s", base, i, ext))
	}
}

func canonicalEntryPath(vaultDir string, entry Entry) string {
	slug := slugify(entry.Title)
	if slug == "" {
		slug = entry.ID[:min(12, len(entry.ID))]
	}

	name := entry.CreatedAt.Format("2006-01-02") + "-" + slug + "-" + entry.ID[:min(12, len(entry.ID))] + ".md"
	return filepath.Join(vaultDir, "entries", entry.CreatedAt.Format("2006"), entry.CreatedAt.Format("01"), name)
}

func randomID() (string, error) {
	var bytes [16]byte
	if _, err := rand.Read(bytes[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(bytes[:]), nil
}

func cleanList(values []string) []string {
	seen := map[string]bool{}
	out := []string{}
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value == "" || seen[value] {
			continue
		}
		seen[value] = true
		out = append(out, value)
	}
	return out
}
