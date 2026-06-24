package diary

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestFormatAgeFromConfiguredBirthdates(t *testing.T) {
	at := time.Date(2025, 9, 28, 4, 0, 0, 0, time.UTC)

	charlotte := time.Date(2016, 10, 7, 0, 56, 0, 0, time.UTC)
	if got := FormatAge(charlotte, at); got != "8 years, 11 months, 21 days, 3 hours, 4 minutes" {
		t.Fatalf("unexpected Charlotte age %q", got)
	}

	chase := time.Date(2019, 1, 7, 17, 12, 0, 0, time.UTC)
	if got := FormatAge(chase, at); got != "6 years, 8 months, 20 days, 10 hours, 48 minutes" {
		t.Fatalf("unexpected Chase age %q", got)
	}
}

func TestLoadPeople(t *testing.T) {
	vault := t.TempDir()
	data := `people:
  - name: Charlotte
    born_at: 2016-10-07T00:56:00Z
`
	if err := os.WriteFile(filepath.Join(vault, "people.yaml"), []byte(data), 0o644); err != nil {
		t.Fatal(err)
	}

	people, err := LoadPeople(vault)
	if err != nil {
		t.Fatal(err)
	}
	if len(people) != 1 || people[0].Name != "Charlotte" {
		t.Fatalf("unexpected people %+v", people)
	}
}

func TestApplyBirthdateDetails(t *testing.T) {
	entry := Entry{
		CreatedAt: time.Date(2025, 9, 28, 4, 0, 0, 0, time.UTC),
	}
	entry = ApplyBirthdateDetails(entry, []Person{
		{
			Name:   "Charlotte",
			BornAt: time.Date(2016, 10, 7, 0, 56, 0, 0, time.UTC),
		},
		{
			Name:   "Chase",
			BornAt: time.Date(2019, 1, 7, 17, 12, 0, 0, time.UTC),
		},
	})

	if len(entry.SubjectDetails) != 2 {
		t.Fatalf("expected configured people details, got %+v", entry.SubjectDetails)
	}
	if entry.SubjectDetails[0].AgeText != "8 years, 11 months, 21 days, 3 hours, 4 minutes" {
		t.Fatalf("unexpected age text %+v", entry.SubjectDetails[0])
	}
	if entry.SubjectDetails[1].Name != "Chase" {
		t.Fatalf("expected Chase detail, got %+v", entry.SubjectDetails[1])
	}
}
