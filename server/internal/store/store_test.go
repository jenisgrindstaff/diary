package store

import (
	"path/filepath"
	"testing"
	"time"

	"diary/server/internal/diary"
)

func TestReplaceIndexAndFetchEntries(t *testing.T) {
	db, err := Open(filepath.Join(t.TempDir(), "diary.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	st := New(db)
	if err := st.Migrate(); err != nil {
		t.Fatal(err)
	}

	now := time.Now().UTC()
	entry := diary.Entry{
		ID:             "entry-1",
		CreatedAt:      now.Add(-time.Hour),
		UpdatedAt:      now,
		ServerRevision: "rev-1",
		Title:          "Indexed",
		Excerpt:        "Searchable",
		BodyMarkdown:   "Hello from Markdown",
		SourcePath:     "source.md",
		VaultPath:      "vault.md",
		Tags:           []string{"family"},
		People:         []string{"Charlotte"},
		SubjectDetails: []diary.SubjectDetail{{
			Name:    "Charlotte",
			Label:   "age",
			AgeText: "8 years, 4 months",
			RawText: "**Charlotte:** 8 years, 4 months",
		}},
	}

	tombstone := diary.Tombstone{
		EntryID:    "deleted-entry",
		DeletedAt:  now.Add(time.Minute),
		SourcePath: "deleted.md",
		TrashPath:  "trash/deleted.md",
	}

	if err := st.ReplaceIndex([]diary.Entry{entry}, []diary.Tombstone{tombstone}); err != nil {
		t.Fatal(err)
	}

	entries, cursor, err := st.EntriesUpdatedSince("")
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 {
		t.Fatalf("expected 1 entry, got %d", len(entries))
	}
	if cursor == "" {
		t.Fatalf("expected cursor")
	}

	fetched, err := st.Entry("entry-1")
	if err != nil {
		t.Fatal(err)
	}
	if fetched.Title != "Indexed" {
		t.Fatalf("unexpected title %q", fetched.Title)
	}
	if len(fetched.SubjectDetails) != 1 || fetched.SubjectDetails[0].AgeText != "8 years, 4 months" {
		t.Fatalf("unexpected subject details: %+v", fetched.SubjectDetails)
	}

	tombstones, tombstoneCursor, err := st.TombstonesUpdatedSince(cursor)
	if err != nil {
		t.Fatal(err)
	}
	if len(tombstones) != 1 || tombstones[0].EntryID != "deleted-entry" {
		t.Fatalf("unexpected tombstones %+v", tombstones)
	}
	if tombstoneCursor == cursor {
		t.Fatalf("expected tombstone cursor to advance")
	}
}

func TestRegisterDeviceAndUpdateCursor(t *testing.T) {
	db, err := Open(filepath.Join(t.TempDir(), "diary.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	st := New(db)
	if err := st.Migrate(); err != nil {
		t.Fatal(err)
	}

	now := time.Date(2026, 6, 22, 12, 0, 0, 0, time.UTC)
	device, err := st.RegisterDevice(SyncDevice{
		DeviceID:    "device-1",
		DisplayName: "iPhone",
		Platform:    "ios",
		AppVersion:  "1.0",
	}, "token-hash", now)
	if err != nil {
		t.Fatal(err)
	}
	if device.DeviceID != "device-1" || device.RegisteredAt.IsZero() {
		t.Fatalf("unexpected device %+v", device)
	}

	fetched, err := st.DeviceByTokenHash("token-hash")
	if err != nil {
		t.Fatal(err)
	}
	if fetched.DisplayName != "iPhone" {
		t.Fatalf("unexpected fetched device %+v", fetched)
	}

	if err := st.UpdateDeviceSyncCursor("device-1", "2026-06-22T12:05:00Z", now.Add(5*time.Minute)); err != nil {
		t.Fatal(err)
	}
	fetched, err = st.Device("device-1")
	if err != nil {
		t.Fatal(err)
	}
	if fetched.LastSyncCursor != "2026-06-22T12:05:00Z" {
		t.Fatalf("unexpected sync cursor %q", fetched.LastSyncCursor)
	}
}
