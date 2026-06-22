package diary

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestDerivedTitleUsesFirstNarrativeLine(t *testing.T) {
	body := `**Chase:** 0Y 4M 19D
**Charlotte:** 2Y 6M 20D

* Chase has his first top tooth
* He is also starting to crawl
`

	title := derivedTitle(body, []string{"Chase", "Charlotte"}, time.Date(2019, 8, 14, 0, 0, 0, 0, time.UTC), "Chase, Charlotte")
	if title != "Chase, Charlotte: Chase has his first top tooth" {
		t.Fatalf("unexpected title %q", title)
	}
}

func TestDerivedTitleTrimsRepeatedSubjectLabel(t *testing.T) {
	body := `**Charlotte:** 7 years
**Chase:** 5 years

* Charlotte: Height: 53.5 inches
`

	title := derivedTitle(body, []string{"Charlotte", "Chase"}, time.Date(2024, 1, 1, 0, 0, 0, 0, time.UTC), "Charlotte, Chase")
	if title != "Charlotte, Chase: Height: 53.5 inches" {
		t.Fatalf("unexpected title %q", title)
	}
}

func TestParseMarkdownDerivesGenericSubjectTitle(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "2019-08-14-chase-charlotte.md")
	data := `---
id: test-entry
created_at: 2019-08-14T00:00:00Z
updated_at: 2019-08-14T00:00:00Z
revision: rev
title: Chase, Charlotte
excerpt: old
source_path: source.md
tags: [legacy-import]
people: [Chase, Charlotte]
attachments: []
---

**Chase:** 0Y 7M 7D
**Charlotte:** 2Y 9M 8D

* Chase has his first top tooth
`
	if err := os.WriteFile(path, []byte(data), 0o644); err != nil {
		t.Fatal(err)
	}

	entry, err := ParseMarkdown(path, "")
	if err != nil {
		t.Fatal(err)
	}
	if entry.Title != "Chase, Charlotte: Chase has his first top tooth" {
		t.Fatalf("unexpected title %q", entry.Title)
	}
}

func TestParseMarkdownKeepsSpecificTitle(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "2026-06-22-good-day.md")
	data := `---
id: test-entry
created_at: 2026-06-22T00:00:00Z
updated_at: 2026-06-22T00:00:00Z
revision: rev
title: Good Day
excerpt: old
source_path: source.md
tags: []
people: [Charlotte]
attachments: []
---

**Charlotte**

* She walked across the room.
`
	if err := os.WriteFile(path, []byte(data), 0o644); err != nil {
		t.Fatal(err)
	}

	entry, err := ParseMarkdown(path, "")
	if err != nil {
		t.Fatal(err)
	}
	if entry.Title != "Good Day" {
		t.Fatalf("unexpected title %q", entry.Title)
	}
}
