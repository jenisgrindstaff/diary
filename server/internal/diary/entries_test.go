package diary

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestCreateEntryWritesCanonicalMarkdown(t *testing.T) {
	vault := t.TempDir()
	createdAt := time.Date(2026, 6, 22, 4, 0, 0, 0, time.UTC)
	now := time.Date(2026, 6, 22, 12, 0, 0, 0, time.UTC)

	entry, err := CreateEntry(vault, CreateEntryInput{
		CreatedAt:    createdAt,
		Title:        "",
		BodyMarkdown: "**Charlotte:** 9 years\n\n* She wrote a new story.",
		People:       []string{"Charlotte"},
		Tags:         []string{"school", "school"},
		Context: &EntryContext{
			Location: &LocationContext{Label: "Bar Harbor, ME", Precision: "place"},
			Weather:  &WeatherContext{Provider: "apple_weather", Condition: "Cloudy", Attribution: "Weather"},
		},
		Now: now,
	})
	if err != nil {
		t.Fatal(err)
	}

	if entry.ID == "" {
		t.Fatal("expected id")
	}
	if entry.Title != "Charlotte: She wrote a new story." {
		t.Fatalf("unexpected title %q", entry.Title)
	}
	if entry.VaultPath == "" || filepath.Ext(entry.VaultPath) != ".md" {
		t.Fatalf("unexpected vault path %q", entry.VaultPath)
	}
	if len(entry.Tags) != 1 || entry.Tags[0] != "school" {
		t.Fatalf("unexpected tags %+v", entry.Tags)
	}

	data, err := os.ReadFile(entry.VaultPath)
	if err != nil {
		t.Fatal(err)
	}
	text := string(data)
	if !strings.Contains(text, "title: 'Charlotte: She wrote a new story.'") && !strings.Contains(text, "title: \"Charlotte: She wrote a new story.\"") {
		t.Fatalf("canonical markdown missing title:\n%s", text)
	}
	if !strings.Contains(text, "source_path: web") || !strings.Contains(text, "She wrote a new story") {
		t.Fatalf("canonical markdown missing expected content:\n%s", text)
	}
	if !strings.Contains(text, "context:") || !strings.Contains(text, "Bar Harbor, ME") || !strings.Contains(text, "apple_weather") {
		t.Fatalf("canonical markdown missing context:\n%s", text)
	}
}

func TestCreateEntryAppliesBirthdateDetails(t *testing.T) {
	vault := t.TempDir()
	peopleConfig := `people:
  - name: Charlotte
    born_at: 2016-10-07T00:56:00Z
  - name: Chase
    born_at: 2019-01-07T17:12:00Z
`
	if err := os.WriteFile(filepath.Join(vault, "people.yaml"), []byte(peopleConfig), 0o644); err != nil {
		t.Fatal(err)
	}

	entry, err := CreateEntry(vault, CreateEntryInput{
		CreatedAt:    time.Date(2025, 9, 28, 4, 0, 0, 0, time.UTC),
		BodyMarkdown: "* A birthday-aware entry.",
		Now:          time.Date(2025, 9, 28, 5, 0, 0, 0, time.UTC),
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(entry.SubjectDetails) != 2 {
		t.Fatalf("expected configured people details, got %+v", entry.SubjectDetails)
	}
	if entry.SubjectDetails[0].AgeText != "8 years, 11 months, 21 days, 3 hours, 4 minutes" {
		t.Fatalf("unexpected subject detail %+v", entry.SubjectDetails[0])
	}
	if entry.SubjectDetails[1].Name != "Chase" {
		t.Fatalf("expected Chase detail, got %+v", entry.SubjectDetails[1])
	}

	data, err := os.ReadFile(entry.VaultPath)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), "age_text: 8 years, 11 months, 21 days, 3 hours, 4 minutes") {
		t.Fatalf("canonical markdown missing computed age:\n%s", string(data))
	}
}

func TestUpdateEntryRewritesCanonicalMarkdown(t *testing.T) {
	vault := t.TempDir()
	createdAt := time.Date(2026, 6, 22, 4, 0, 0, 0, time.UTC)
	now := time.Date(2026, 6, 22, 12, 0, 0, 0, time.UTC)
	entry, err := CreateEntry(vault, CreateEntryInput{
		CreatedAt:    createdAt,
		Title:        "Original",
		BodyMarkdown: "* Original body.",
		People:       []string{"Charlotte"},
		Now:          now,
	})
	if err != nil {
		t.Fatal(err)
	}
	oldPath := entry.VaultPath
	entry.Attachments = []Attachment{{
		ID:           "asset-1",
		Kind:         "image",
		Filename:     "photo.jpg",
		ContentType:  "image/jpeg",
		RemotePath:   "/api/v1/assets/asset-1",
		MarkdownPath: "assets/2026/06/entry/photo.jpg",
		ByteCount:    123,
	}}
	entry.Context = EntryContext{
		Location: &LocationContext{Label: "Portland, ME", Precision: "place"},
	}

	updated, err := UpdateEntry(vault, entry, UpdateEntryInput{
		CreatedAt:    time.Date(2026, 6, 23, 4, 0, 0, 0, time.UTC),
		Title:        "Updated",
		BodyMarkdown: "* Updated body.",
		People:       []string{"Chase"},
		Tags:         []string{"edited"},
		Now:          now.Add(time.Hour),
	})
	if err != nil {
		t.Fatal(err)
	}

	if updated.Title != "Updated" || updated.Excerpt != "* Updated body." {
		t.Fatalf("unexpected updated entry %+v", updated)
	}
	if updated.VaultPath == oldPath {
		t.Fatalf("expected path to change")
	}
	if len(updated.Attachments) != 1 || updated.Attachments[0].ID != "asset-1" {
		t.Fatalf("attachments not preserved: %+v", updated.Attachments)
	}
	if updated.Context.Location == nil || updated.Context.Location.Label != "Portland, ME" {
		t.Fatalf("context not preserved: %+v", updated.Context)
	}
	if _, err := os.Stat(oldPath); !os.IsNotExist(err) {
		t.Fatalf("expected old path removed, err=%v", err)
	}
	data, err := os.ReadFile(updated.VaultPath)
	if err != nil {
		t.Fatal(err)
	}
	text := string(data)
	if !strings.Contains(text, "title: Updated") || !strings.Contains(text, "Updated body") || !strings.Contains(text, "photo.jpg") {
		t.Fatalf("canonical markdown missing updates:\n%s", text)
	}
}

func TestRemoveAttachmentRewritesCanonicalMarkdown(t *testing.T) {
	vault := t.TempDir()
	entry, err := CreateEntry(vault, CreateEntryInput{
		CreatedAt:    time.Date(2026, 6, 22, 4, 0, 0, 0, time.UTC),
		Title:        "With Media",
		BodyMarkdown: "* Has media.",
		Now:          time.Date(2026, 6, 22, 5, 0, 0, 0, time.UTC),
	})
	if err != nil {
		t.Fatal(err)
	}

	assetPath := filepath.Join(vault, "assets", "2026", "06", entry.ID, "photo.jpg")
	if err := os.MkdirAll(filepath.Dir(assetPath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(assetPath, []byte("image"), 0o644); err != nil {
		t.Fatal(err)
	}
	entry.Attachments = []Attachment{
		{
			ID:           "remove-me",
			Kind:         "image",
			Filename:     "photo.jpg",
			ContentType:  "image/jpeg",
			RemotePath:   "/api/v1/assets/remove-me",
			MarkdownPath: filepath.ToSlash(filepath.Join("assets", "2026", "06", entry.ID, "photo.jpg")),
			ByteCount:    5,
			AbsolutePath: assetPath,
		},
		{
			ID:           "keep-me",
			Kind:         "video",
			Filename:     "clip.mov",
			ContentType:  "video/quicktime",
			RemotePath:   "/api/v1/assets/keep-me",
			MarkdownPath: "assets/2026/06/entry/clip.mov",
			ByteCount:    10,
		},
	}
	data, err := RenderMarkdown(entry)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(entry.VaultPath, data, 0o644); err != nil {
		t.Fatal(err)
	}

	updated, removed, err := RemoveAttachment(vault, entry, "remove-me", time.Date(2026, 6, 22, 6, 0, 0, 0, time.UTC))
	if err != nil {
		t.Fatal(err)
	}

	if removed.ID != "remove-me" {
		t.Fatalf("unexpected removed attachment %+v", removed)
	}
	if len(updated.Attachments) != 1 || updated.Attachments[0].ID != "keep-me" {
		t.Fatalf("unexpected attachments %+v", updated.Attachments)
	}
	if _, err := os.Stat(assetPath); !os.IsNotExist(err) {
		t.Fatalf("expected asset file removed, err=%v", err)
	}
	written, err := os.ReadFile(updated.VaultPath)
	if err != nil {
		t.Fatal(err)
	}
	text := string(written)
	if strings.Contains(text, "remove-me") || !strings.Contains(text, "keep-me") {
		t.Fatalf("canonical markdown has wrong attachments:\n%s", text)
	}
}

func TestTrashEntryMovesCanonicalMarkdown(t *testing.T) {
	vault := t.TempDir()
	entry, err := CreateEntry(vault, CreateEntryInput{
		CreatedAt:    time.Date(2026, 6, 22, 4, 0, 0, 0, time.UTC),
		Title:        "Trash Me",
		BodyMarkdown: "* Temporary.",
		Now:          time.Date(2026, 6, 22, 5, 0, 0, 0, time.UTC),
	})
	if err != nil {
		t.Fatal(err)
	}
	oldPath := entry.VaultPath

	tombstone, err := TrashEntry(vault, entry, time.Date(2026, 7, 2, 10, 0, 0, 0, time.UTC))
	if err != nil {
		t.Fatal(err)
	}
	trashPath := tombstone.TrashPath
	if _, err := os.Stat(oldPath); !os.IsNotExist(err) {
		t.Fatalf("expected old path removed, err=%v", err)
	}
	if _, err := os.Stat(trashPath); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(trashPath, filepath.Join("trash", "2026", "07")) {
		t.Fatalf("unexpected trash path %q", trashPath)
	}
	tombstones, err := ReadTombstones(vault)
	if err != nil {
		t.Fatal(err)
	}
	if len(tombstones) != 1 || tombstones[0].EntryID != entry.ID {
		t.Fatalf("unexpected tombstones %+v", tombstones)
	}
	if !strings.Contains(tombstones[0].TrashPath, filepath.Join("trash", "2026", "07")) {
		t.Fatalf("unexpected tombstone trash path %q", tombstones[0].TrashPath)
	}
}
