package store

import (
	"path/filepath"
	"strings"
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
	steps := 8432
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
		Context: diary.EntryContext{
			Location: &diary.LocationContext{Label: "Bar Harbor, ME", Precision: "place"},
			Activity: &diary.ActivityContext{Steps: &steps},
		},
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

	entries, cursor, _, err := st.EntriesUpdatedSince("", 0)
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
	if fetched.Context.Location == nil || fetched.Context.Location.Label != "Bar Harbor, ME" {
		t.Fatalf("unexpected context: %+v", fetched.Context)
	}

	hits, err := st.Search("Bar Harbor")
	if err != nil {
		t.Fatal(err)
	}
	if len(hits) != 1 || hits[0].ID != "entry-1" {
		t.Fatalf("expected context to be searchable, got %+v", hits)
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

func newTestStore(t *testing.T) *Store {
	t.Helper()
	db, err := Open(filepath.Join(t.TempDir(), "diary.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })

	st := New(db)
	if err := st.Migrate(); err != nil {
		t.Fatal(err)
	}
	return st
}

func sampleEntry(id string, updatedAt time.Time, attachments ...diary.Attachment) diary.Entry {
	return diary.Entry{
		ID:             id,
		CreatedAt:      updatedAt.Add(-time.Hour),
		UpdatedAt:      updatedAt,
		ServerRevision: "rev-" + id,
		Title:          "Title " + id,
		Excerpt:        "Excerpt " + id,
		BodyMarkdown:   "Body for " + id,
		SourcePath:     id + ".md",
		VaultPath:      id + ".md",
		Tags:           []string{},
		People:         []string{},
		Attachments:    attachments,
	}
}

func TestIndexEntryUpsertsWithoutFullReindex(t *testing.T) {
	st := newTestStore(t)
	now := time.Now().UTC()

	if err := st.IndexEntry(sampleEntry("entry-1", now)); err != nil {
		t.Fatal(err)
	}
	// Re-indexing the same id must replace, not duplicate.
	updated := sampleEntry("entry-1", now.Add(time.Minute))
	updated.Title = "Renamed"
	if err := st.IndexEntry(updated); err != nil {
		t.Fatal(err)
	}

	entries, _, _, err := st.EntriesUpdatedSince("", 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 {
		t.Fatalf("expected exactly 1 entry after re-index, got %d", len(entries))
	}
	if entries[0].Title != "Renamed" {
		t.Fatalf("expected upserted title, got %q", entries[0].Title)
	}

	// FTS must reflect the new content and drop the old.
	hits, err := st.Search("Renamed")
	if err != nil {
		t.Fatal(err)
	}
	if len(hits) != 1 {
		t.Fatalf("expected FTS to find renamed entry, got %d hits", len(hits))
	}
}

func TestIndexDeletionRemovesEntryAndRecordsTombstone(t *testing.T) {
	st := newTestStore(t)
	now := time.Now().UTC()

	if err := st.IndexEntry(sampleEntry("entry-1", now)); err != nil {
		t.Fatal(err)
	}

	tombstone := diary.Tombstone{EntryID: "entry-1", DeletedAt: now.Add(time.Minute), SourcePath: "entry-1.md", TrashPath: "trash/entry-1.md"}
	if err := st.IndexDeletion(tombstone); err != nil {
		t.Fatal(err)
	}

	if _, err := st.Entry("entry-1"); err == nil {
		t.Fatal("expected entry to be gone after deletion")
	}
	tombstones, _, err := st.TombstonesUpdatedSince("")
	if err != nil {
		t.Fatal(err)
	}
	if len(tombstones) != 1 || tombstones[0].EntryID != "entry-1" {
		t.Fatalf("expected one tombstone for entry-1, got %+v", tombstones)
	}
}

// TestEntriesAttachmentsBatched guards the N+1 fix: each entry's attachments
// must be associated with the correct entry when many are loaded together.
func TestEntriesAttachmentsBatched(t *testing.T) {
	st := newTestStore(t)
	now := time.Now().UTC()

	att := func(id, entry, name string) diary.Attachment {
		return diary.Attachment{
			ID:           id,
			Kind:         "image",
			Filename:     name,
			ContentType:  "image/png",
			RemotePath:   "/api/v1/assets/" + id,
			MarkdownPath: entry + "/" + name,
			AbsolutePath: "/tmp/" + name,
		}
	}

	e1 := sampleEntry("entry-1", now.Add(-2*time.Minute), att("a1", "entry-1", "one.png"), att("a2", "entry-1", "two.png"))
	e2 := sampleEntry("entry-2", now.Add(-time.Minute)) // no attachments
	e3 := sampleEntry("entry-3", now, att("a3", "entry-3", "three.png"))
	for _, e := range []diary.Entry{e1, e2, e3} {
		if err := st.IndexEntry(e); err != nil {
			t.Fatal(err)
		}
	}

	entries, err := st.Entries()
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]int{}
	for _, e := range entries {
		got[e.ID] = len(e.Attachments)
		if e.Attachments == nil {
			t.Fatalf("attachments for %s should be non-nil", e.ID)
		}
	}
	if got["entry-1"] != 2 || got["entry-2"] != 0 || got["entry-3"] != 1 {
		t.Fatalf("attachments misassociated across entries: %+v", got)
	}
}

// drainEntries replays the client loop: it keeps requesting pages until
// has_more is false, returning every entry id seen in order.
func drainEntries(t *testing.T, st *Store, limit int) []string {
	t.Helper()
	var ids []string
	cursor := ""
	for i := 0; i < 1000; i++ {
		entries, next, more, err := st.EntriesUpdatedSince(cursor, limit)
		if err != nil {
			t.Fatal(err)
		}
		for _, e := range entries {
			ids = append(ids, e.ID)
		}
		if !more {
			return ids
		}
		if next == cursor {
			t.Fatalf("cursor failed to advance at %q (possible infinite loop)", cursor)
		}
		cursor = next
	}
	t.Fatal("pagination did not terminate")
	return nil
}

func TestEntriesUpdatedSincePaginationDrainsAll(t *testing.T) {
	st := newTestStore(t)
	base := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)

	const total = 23
	want := make([]string, 0, total)
	for i := 0; i < total; i++ {
		id := "entry-" + string(rune('a'+i/26)) + time.Duration(i).String()
		want = append(want, id)
		if err := st.IndexEntry(sampleEntry(id, base.Add(time.Duration(i)*time.Second))); err != nil {
			t.Fatal(err)
		}
	}

	got := drainEntries(t, st, 5)
	if len(got) != total {
		t.Fatalf("expected %d entries across pages, got %d", total, len(got))
	}
	seen := map[string]int{}
	for _, id := range got {
		seen[id]++
	}
	for _, id := range want {
		if seen[id] != 1 {
			t.Fatalf("entry %s appeared %d times (want exactly once)", id, seen[id])
		}
	}
}

// TestPaginationDoesNotSplitTimestampGroup is the correctness guard: when more
// entries share an updated_at than fit in a page, none may be skipped or
// duplicated as the client drains pages.
func TestPaginationDoesNotSplitTimestampGroup(t *testing.T) {
	st := newTestStore(t)
	t1 := time.Date(2026, 1, 1, 0, 0, 1, 0, time.UTC)
	t2 := time.Date(2026, 1, 1, 0, 0, 2, 0, time.UTC) // shared by three entries
	t3 := time.Date(2026, 1, 1, 0, 0, 3, 0, time.UTC)

	insert := map[string]time.Time{
		"a-t1": t1,
		"b-t2": t2, "c-t2": t2, "d-t2": t2,
		"e-t3": t3,
	}
	for id, ts := range insert {
		if err := st.IndexEntry(sampleEntry(id, ts)); err != nil {
			t.Fatal(err)
		}
	}

	got := drainEntries(t, st, 2)
	seen := map[string]int{}
	for _, id := range got {
		seen[id]++
	}
	if len(seen) != len(insert) {
		t.Fatalf("expected %d distinct entries, saw %d: %v", len(insert), len(seen), got)
	}
	for id := range insert {
		if seen[id] != 1 {
			t.Fatalf("entry %s synced %d times (want exactly once): %v", id, seen[id], got)
		}
	}
}

// TestSyncQueryUsesUpdatedAtIndex proves the sync filter (updated_at > ?) is
// served by an index rather than a full table scan, the goal of the schema
// indexes added for large vaults.
func TestSyncQueryUsesUpdatedAtIndex(t *testing.T) {
	st := newTestStore(t)

	rows, err := st.db.Query(`EXPLAIN QUERY PLAN
SELECT id FROM entries WHERE updated_at > ? ORDER BY updated_at ASC`, "2026-01-01T00:00:00Z")
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()

	plan := ""
	for rows.Next() {
		var id, parent, notUsed int
		var detail string
		if err := rows.Scan(&id, &parent, &notUsed, &detail); err != nil {
			t.Fatal(err)
		}
		plan += detail + "\n"
	}
	if !strings.Contains(plan, "idx_entries_updated_at") {
		t.Fatalf("expected sync query to use idx_entries_updated_at, plan was:\n%s", plan)
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
