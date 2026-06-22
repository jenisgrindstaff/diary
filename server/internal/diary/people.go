package diary

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

type Person struct {
	Name   string    `yaml:"name"`
	BornAt time.Time `yaml:"born_at"`
}

type peopleConfig struct {
	People []Person `yaml:"people"`
}

func LoadPeople(vaultDir string) ([]Person, error) {
	path := filepath.Join(vaultDir, "people.yaml")
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return []Person{}, nil
		}
		return nil, err
	}

	var cfg peopleConfig
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return nil, err
	}

	people := make([]Person, 0, len(cfg.People))
	for _, person := range cfg.People {
		person.Name = strings.TrimSpace(person.Name)
		if person.Name == "" || person.BornAt.IsZero() {
			continue
		}
		people = append(people, person)
	}
	return people, nil
}

func ApplyBirthdateDetails(entry Entry, people []Person) Entry {
	if len(entry.People) == 0 || len(people) == 0 {
		return entry
	}

	birthdays := map[string]time.Time{}
	for _, person := range people {
		birthdays[person.Name] = person.BornAt.UTC()
	}

	existing := map[string]bool{}
	for _, detail := range entry.SubjectDetails {
		if detail.Name != "" && detail.AgeText != "" {
			existing[detail.Name] = true
		}
	}

	for _, name := range entry.People {
		if existing[name] {
			continue
		}
		bornAt, ok := birthdays[name]
		if !ok {
			continue
		}
		entry.SubjectDetails = append(entry.SubjectDetails, SubjectDetail{
			Name:    name,
			Label:   "age",
			AgeText: FormatAge(bornAt, entry.CreatedAt),
		})
	}

	return entry
}

func FormatAge(bornAt time.Time, at time.Time) string {
	if at.Before(bornAt) {
		return "0 years, 0 months, 0 days, 0 hours, 0 minutes"
	}

	bornAt = bornAt.UTC()
	at = at.UTC()

	years := at.Year() - bornAt.Year()
	cursor := bornAt.AddDate(years, 0, 0)
	if cursor.After(at) {
		years--
		cursor = bornAt.AddDate(years, 0, 0)
	}

	months := 0
	for {
		next := cursor.AddDate(0, months+1, 0)
		if next.After(at) {
			break
		}
		months++
	}
	cursor = cursor.AddDate(0, months, 0)

	days := 0
	for {
		next := cursor.AddDate(0, 0, days+1)
		if next.After(at) {
			break
		}
		days++
	}
	cursor = cursor.AddDate(0, 0, days)

	remainder := at.Sub(cursor)
	hours := int(remainder / time.Hour)
	remainder -= time.Duration(hours) * time.Hour
	minutes := int(remainder / time.Minute)

	return strings.Join([]string{
		plural(years, "year"),
		plural(months, "month"),
		plural(days, "day"),
		plural(hours, "hour"),
		plural(minutes, "minute"),
	}, ", ")
}

func plural(value int, unit string) string {
	if value == 1 {
		return "1 " + unit
	}
	return strconv.Itoa(value) + " " + unit + "s"
}
