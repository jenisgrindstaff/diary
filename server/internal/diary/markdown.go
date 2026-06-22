package diary

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io/fs"
	"mime"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

var (
	dateInFilename = regexp.MustCompile(`\d{4}-\d{2}-\d{2}`)
	headingLine    = regexp.MustCompile(`(?m)^#\s+(.+?)\s*$`)
	assetLink      = regexp.MustCompile(`!?\[[^\]]*]\(([^)]+)\)`)
)

type frontmatter struct {
	ID             string          `yaml:"id"`
	CreatedAt      time.Time       `yaml:"created_at"`
	UpdatedAt      time.Time       `yaml:"updated_at"`
	Revision       string          `yaml:"revision"`
	Title          string          `yaml:"title"`
	Excerpt        string          `yaml:"excerpt"`
	SourcePath     string          `yaml:"source_path"`
	Tags           []string        `yaml:"tags"`
	People         []string        `yaml:"people"`
	SubjectDetails []SubjectDetail `yaml:"subject_details"`
	Attachments    []Attachment    `yaml:"attachments"`
}

func ParseMarkdown(path string, vaultDir string) (Entry, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Entry{}, err
	}

	info, err := os.Stat(path)
	if err != nil {
		return Entry{}, err
	}

	meta, body, err := splitFrontmatter(data)
	if err != nil {
		return Entry{}, err
	}

	if meta.ID == "" {
		meta.ID = stableID(path, body)
	}
	if meta.CreatedAt.IsZero() {
		meta.CreatedAt = dateFromFilename(path, info.ModTime())
	}
	if meta.UpdatedAt.IsZero() {
		meta.UpdatedAt = info.ModTime()
	}
	if meta.Excerpt == "" {
		meta.Excerpt = excerpt(body)
	}
	if meta.Revision == "" {
		meta.Revision = stableRevision(body, meta.UpdatedAt)
	}
	if meta.SourcePath == "" {
		meta.SourcePath = path
	}

	subjectDetails := meta.SubjectDetails
	if len(subjectDetails) == 0 {
		subjectDetails = extractSubjectDetails(body)
	}
	people := meta.People
	if len(people) == 0 {
		people = subjectsFromDetails(subjectDetails)
	}
	if meta.Title == "" {
		meta.Title = titleFromBody(body, path)
	}
	if shouldDeriveTitle(meta.Title, people, meta.CreatedAt) {
		meta.Title = derivedTitle(body, people, meta.CreatedAt, meta.Title)
	}

	entry := Entry{
		ID:             meta.ID,
		CreatedAt:      meta.CreatedAt.UTC(),
		UpdatedAt:      meta.UpdatedAt.UTC(),
		ServerRevision: meta.Revision,
		Title:          meta.Title,
		Excerpt:        meta.Excerpt,
		BodyMarkdown:   strings.TrimSpace(body),
		SourcePath:     meta.SourcePath,
		Tags:           meta.Tags,
		People:         people,
		SubjectDetails: subjectDetails,
		Attachments:    meta.Attachments,
		VaultPath:      path,
	}
	entry.Tags = nonNilStrings(entry.Tags)
	entry.People = nonNilStrings(entry.People)
	if entry.SubjectDetails == nil {
		entry.SubjectDetails = []SubjectDetail{}
	}
	if entry.Attachments == nil {
		entry.Attachments = []Attachment{}
	}

	for i := range entry.Attachments {
		if entry.Attachments[i].RemotePath == "" {
			entry.Attachments[i].RemotePath = "/api/v1/assets/" + entry.Attachments[i].ID
		}
		if entry.Attachments[i].AbsolutePath == "" && vaultDir != "" && entry.Attachments[i].MarkdownPath != "" {
			entry.Attachments[i].AbsolutePath = filepath.Join(vaultDir, entry.Attachments[i].MarkdownPath)
		}
	}

	return entry, nil
}

func nonNilStrings(values []string) []string {
	if values == nil {
		return []string{}
	}

	return values
}

func RenderMarkdown(entry Entry) ([]byte, error) {
	meta := frontmatter{
		ID:             entry.ID,
		CreatedAt:      entry.CreatedAt,
		UpdatedAt:      entry.UpdatedAt,
		Revision:       entry.ServerRevision,
		Title:          entry.Title,
		Excerpt:        entry.Excerpt,
		SourcePath:     entry.SourcePath,
		Tags:           entry.Tags,
		People:         entry.People,
		SubjectDetails: entry.SubjectDetails,
		Attachments:    entry.Attachments,
	}

	header, err := yaml.Marshal(meta)
	if err != nil {
		return nil, err
	}

	var out bytes.Buffer
	out.WriteString("---\n")
	out.Write(header)
	out.WriteString("---\n\n")
	out.WriteString(strings.TrimSpace(entry.BodyMarkdown))
	out.WriteString("\n")
	return out.Bytes(), nil
}

func ReadVault(vaultDir string) ([]Entry, error) {
	var entries []Entry
	entriesDir := filepath.Join(vaultDir, "entries")
	people, err := LoadPeople(vaultDir)
	if err != nil {
		return nil, err
	}

	err = filepath.WalkDir(entriesDir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() || !isMarkdown(path) {
			return nil
		}

		entry, err := ParseMarkdown(path, vaultDir)
		if err != nil {
			return err
		}
		entry = ApplyBirthdateDetails(entry, people)
		entries = append(entries, entry)
		return nil
	})
	if err != nil && !os.IsNotExist(err) {
		return nil, err
	}

	sort.Slice(entries, func(i, j int) bool {
		return entries[i].CreatedAt.After(entries[j].CreatedAt)
	})
	return entries, nil
}

func splitFrontmatter(data []byte) (frontmatter, string, error) {
	text := string(data)
	if !strings.HasPrefix(text, "---\n") {
		return frontmatter{}, text, nil
	}

	rest := text[len("---\n"):]
	end := strings.Index(rest, "\n---")
	if end < 0 {
		return frontmatter{}, "", fmt.Errorf("frontmatter is not closed")
	}

	raw := rest[:end]
	body := strings.TrimPrefix(rest[end+len("\n---"):], "\n")

	var meta frontmatter
	if err := yaml.Unmarshal([]byte(raw), &meta); err != nil {
		return frontmatter{}, "", err
	}

	return meta, body, nil
}

func ExtractLocalAssetRefs(body string) []string {
	matches := assetLink.FindAllStringSubmatch(body, -1)
	seen := map[string]bool{}
	var refs []string

	for _, match := range matches {
		if len(match) < 2 {
			continue
		}
		ref := strings.TrimSpace(match[1])
		if ref == "" || strings.HasPrefix(ref, "http://") || strings.HasPrefix(ref, "https://") || strings.HasPrefix(ref, "#") {
			continue
		}
		if decoded, err := url.PathUnescape(ref); err == nil {
			ref = decoded
		}
		if !seen[ref] {
			seen[ref] = true
			refs = append(refs, ref)
		}
	}

	return refs
}

func KindForFilename(filename string) string {
	contentType := mime.TypeByExtension(strings.ToLower(filepath.Ext(filename)))
	switch {
	case strings.HasPrefix(contentType, "image/"):
		return "image"
	case strings.HasPrefix(contentType, "video/"):
		return "video"
	default:
		return "file"
	}
}

func ContentTypeForFilename(filename string) string {
	if contentType := mime.TypeByExtension(strings.ToLower(filepath.Ext(filename))); contentType != "" {
		return contentType
	}

	return "application/octet-stream"
}

func isMarkdown(path string) bool {
	ext := strings.ToLower(filepath.Ext(path))
	return ext == ".md" || ext == ".markdown"
}

func stableID(path, body string) string {
	sum := sha256.Sum256([]byte(path + "\n" + body))
	return hex.EncodeToString(sum[:16])
}

func stableRevision(body string, updatedAt time.Time) string {
	sum := sha256.Sum256([]byte(updatedAt.UTC().Format(time.RFC3339Nano) + "\n" + body))
	return hex.EncodeToString(sum[:16])
}

func dateFromFilename(path string, fallback time.Time) time.Time {
	match := dateInFilename.FindString(filepath.Base(path))
	if match == "" {
		return fallback
	}

	date, err := time.Parse("2006-01-02", match)
	if err != nil {
		return fallback
	}

	return date
}

func titleFromBody(body, path string) string {
	if match := headingLine.FindStringSubmatch(body); len(match) == 2 {
		return strings.TrimSpace(match[1])
	}

	return fallbackTitleFromPath(path)
}

func excerpt(body string) string {
	lines := strings.Fields(strings.TrimSpace(stripHeading(body)))
	if len(lines) > 32 {
		lines = lines[:32]
	}

	return strings.Join(lines, " ")
}

func stripHeading(body string) string {
	return headingLine.ReplaceAllString(body, "")
}
