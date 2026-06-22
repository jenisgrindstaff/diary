package diary

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestImporterCopiesAndNormalizesMarkdown(t *testing.T) {
	root := t.TempDir()
	imports := filepath.Join(root, "imports")
	vault := filepath.Join(root, "vault")
	if err := os.MkdirAll(imports, 0o755); err != nil {
		t.Fatal(err)
	}

	source := filepath.Join(imports, "2026-06-22-good-day.md")
	if err := os.WriteFile(source, []byte("# Good Day\n\nA little rain and a lot of notes.\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	importer := NewImporter(vault, imports)
	result, err := importer.Import(imports)
	if err != nil {
		t.Fatal(err)
	}

	if result.ImportedEntries != 1 {
		t.Fatalf("expected 1 imported entry, got %d", result.ImportedEntries)
	}
	if len(result.Entries) != 1 {
		t.Fatalf("expected one destination path")
	}

	data, err := os.ReadFile(result.Entries[0])
	if err != nil {
		t.Fatal(err)
	}
	text := string(data)
	if !strings.Contains(text, "id:") || !strings.Contains(text, "title: Good Day") {
		t.Fatalf("normalized frontmatter missing: %s", text)
	}
	if !strings.Contains(text, "A little rain") {
		t.Fatalf("body missing: %s", text)
	}
}

func TestImporterCopiesRelativeAssets(t *testing.T) {
	root := t.TempDir()
	imports := filepath.Join(root, "imports")
	vault := filepath.Join(root, "vault")
	if err := os.MkdirAll(filepath.Join(imports, "media"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(imports, "media", "photo.jpg"), []byte("fake image"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(imports, "2026-06-22-photo.md"), []byte("# Photo\n\n![photo](media/photo.jpg)\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	importer := NewImporter(vault, imports)
	result, err := importer.Import(imports)
	if err != nil {
		t.Fatal(err)
	}

	if result.ImportedAssets != 1 {
		t.Fatalf("expected 1 imported asset, got %d", result.ImportedAssets)
	}
}

func TestImporterSplitsLegacySingleFileLog(t *testing.T) {
	root := t.TempDir()
	imports := filepath.Join(root, "imports")
	vault := filepath.Join(root, "vault")
	if err := os.MkdirAll(imports, 0o755); err != nil {
		t.Fatal(err)
	}

	source := filepath.Join(imports, "legacy.md")
	legacy := `#### 2018-07-12
**Charlotte**
* Charity forgot bottle parts so we are trying nights without bottles.

____

#### 2018-07-12
**Charlotte**
Charlotte is working her new puzzles.

____

#### 10-13-19

Charlotte: 3 years 7 days 3 hours 8 minutes 57 seconds
Chase: 9 months 6 days 9 hours 29 minutes 57 seconds

* Chase had his dedication today at Providence.

----------------------

#### 2/5/25  
**Charlotte:** 8 years, 4 months, 1 day, 22 hours, 4 minutes
**Chase:** 6 years, 29 days, 23 hours, 48 minutes

* Tonight we asked Chase if he talked to God.

---------------`
	if err := os.WriteFile(source, []byte(legacy), 0o644); err != nil {
		t.Fatal(err)
	}

	importer := NewImporter(vault, imports)
	result, err := importer.Import(imports)
	if err != nil {
		t.Fatal(err)
	}

	if result.ImportedEntries != 4 {
		t.Fatalf("expected 4 imported entries, got %d", result.ImportedEntries)
	}
	if len(result.Entries) != 4 {
		t.Fatalf("expected 4 entry paths, got %d", len(result.Entries))
	}

	seen := map[string]bool{}
	foundSubjectDetails := false
	for _, path := range result.Entries {
		if seen[path] {
			t.Fatalf("duplicate destination path %s", path)
		}
		seen[path] = true

		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		text := string(data)
		if !strings.Contains(text, "legacy-import") {
			t.Fatalf("legacy tag missing from %s:\n%s", path, text)
		}
		if strings.Contains(text, "____") || strings.Contains(text, "---------------") {
			t.Fatalf("separator should not be preserved in %s:\n%s", path, text)
		}
		if strings.Contains(text, "subject_details:") && strings.Contains(text, "age_text: 8 years") {
			foundSubjectDetails = true
		}
	}
	if !foundSubjectDetails {
		t.Fatalf("expected subject details with age text in imported frontmatter")
	}
}

func TestExtractSubjectDetails(t *testing.T) {
	body := `**Charlotte:** 8 years, 4 months, 1 day
**Chase:** 6 years, 29 days

* They both told stories.
`

	details := extractSubjectDetails(body)
	if len(details) != 2 {
		t.Fatalf("expected 2 subject details, got %+v", details)
	}
	if details[0].Name != "Charlotte" || details[0].AgeText != "8 years, 4 months, 1 day" || details[0].Label != "age" {
		t.Fatalf("unexpected Charlotte detail: %+v", details[0])
	}
	if details[1].Name != "Chase" || details[1].AgeText != "6 years, 29 days" || details[1].Label != "age" {
		t.Fatalf("unexpected Chase detail: %+v", details[1])
	}
}
