package diary

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"time"
)

var (
	legacyDateHeading     = regexp.MustCompile(`(?m)^####\s+(.+?)\s*$`)
	boldSubjectLine       = regexp.MustCompile(`^\s*\*\*([^*\n]+?)\s*:?\*\*\s*(.*?)\s*$`)
	plainSubjectLine      = regexp.MustCompile(`^\s*([A-Z][A-Za-z]+):\s*(.*?)\s*$`)
	separatorLine         = regexp.MustCompile(`^\s*(?:_{4,}|-{5,})\s*$`)
	ageLikeSubjectDetails = regexp.MustCompile(`(?i)(?:\d+\s*(?:y|year|years|m|month|months|d|day|days|hour|hours|minute|minutes)|\b\d+y\b|\b\d+m\b|\b\d+d\b)`)
)

type legacyHeading struct {
	raw       string
	date      time.Time
	start     int
	bodyStart int
	line      int
}

func ParseLegacyLog(path string) ([]Entry, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}

	text := strings.ReplaceAll(string(data), "\r\n", "\n")
	headings := legacyHeadings(text)
	if len(headings) <= 1 {
		return nil, nil
	}

	entries := make([]Entry, 0, len(headings))
	for index, heading := range headings {
		end := len(text)
		if index+1 < len(headings) {
			end = headings[index+1].start
		}

		body := cleanLegacyBody(text[heading.bodyStart:end])
		if body == "" {
			continue
		}

		subjectDetails := extractSubjectDetails(body)
		subjects := subjectsFromDetails(subjectDetails)
		title := derivedTitle(body, subjects, heading.date, heading.date.Format("2006-01-02"))

		id := legacyID(path, heading.line, heading.raw, body)
		entries = append(entries, Entry{
			ID:             id,
			CreatedAt:      heading.date.UTC(),
			UpdatedAt:      heading.date.UTC(),
			ServerRevision: stableRevision(body, heading.date),
			Title:          title,
			Excerpt:        excerpt(body),
			BodyMarkdown:   body,
			SourcePath:     fmt.Sprintf("%s:%d", path, heading.line),
			Tags:           []string{"legacy-import"},
			People:         subjects,
			SubjectDetails: subjectDetails,
			Attachments:    []Attachment{},
			VaultPath:      path,
		})
	}

	return entries, nil
}

func legacyHeadings(text string) []legacyHeading {
	matches := legacyDateHeading.FindAllStringSubmatchIndex(text, -1)
	headings := make([]legacyHeading, 0, len(matches))

	for _, match := range matches {
		raw := strings.TrimSpace(text[match[2]:match[3]])
		date, ok := parseLegacyDate(raw)
		if !ok {
			continue
		}

		line := 1 + strings.Count(text[:match[0]], "\n")
		bodyStart := match[1]
		if bodyStart < len(text) && text[bodyStart] == '\n' {
			bodyStart++
		}

		headings = append(headings, legacyHeading{
			raw:       raw,
			date:      date,
			start:     match[0],
			bodyStart: bodyStart,
			line:      line,
		})
	}

	return headings
}

func parseLegacyDate(raw string) (time.Time, bool) {
	value := strings.TrimSpace(raw)
	if open := strings.Index(value, "("); open >= 0 {
		value = strings.TrimSpace(value[:open])
	}

	formats := []string{
		"2006-01-02",
		"1-2-06",
		"01-02-06",
		"1/2/06",
		"01/02/06",
		"1/2/2006",
		"01/02/2006",
	}

	for _, format := range formats {
		date, err := time.ParseInLocation(format, value, time.Local)
		if err == nil {
			return date, true
		}
	}

	return time.Time{}, false
}

func cleanLegacyBody(body string) string {
	lines := strings.Split(strings.TrimSpace(stripInvisible(body)), "\n")
	for len(lines) > 0 && separatorLine.MatchString(lines[0]) {
		lines = lines[1:]
	}
	for len(lines) > 0 && separatorLine.MatchString(lines[len(lines)-1]) {
		lines = lines[:len(lines)-1]
	}

	return strings.TrimSpace(strings.Join(lines, "\n"))
}

func extractSubjects(body string) []string {
	return subjectsFromDetails(extractSubjectDetails(body))
}

func extractSubjectDetails(body string) []SubjectDetail {
	seen := map[string]bool{}
	details := []SubjectDetail{}

	for _, line := range strings.Split(body, "\n") {
		rawLine := strings.TrimSpace(line)
		if rawLine == "" {
			continue
		}

		detail := SubjectDetail{}
		if match := boldSubjectLine.FindStringSubmatch(rawLine); len(match) == 3 {
			detail.Name = cleanSubjectName(match[1])
			detail.AgeText = cleanSubjectDetail(match[2])
		} else if match := plainSubjectLine.FindStringSubmatch(rawLine); len(match) == 3 && isKnownLegacySubject(match[1]) {
			detail.Name = cleanSubjectName(match[1])
			detail.AgeText = cleanSubjectDetail(match[2])
		}

		if detail.Name == "" || seen[detail.Name] {
			continue
		}

		if detail.AgeText != "" && ageLikeSubjectDetails.MatchString(detail.AgeText) {
			detail.Label = "age"
		}
		detail.RawText = rawLine
		seen[detail.Name] = true
		details = append(details, detail)
	}

	return details
}

func subjectsFromDetails(details []SubjectDetail) []string {
	subjects := make([]string, 0, len(details))
	for _, detail := range details {
		if detail.RawText == "" {
			continue
		}
		if detail.Name != "" {
			subjects = append(subjects, detail.Name)
		}
	}
	return subjects
}

func cleanSubjectName(value string) string {
	return strings.TrimSpace(strings.TrimSuffix(strings.TrimSpace(value), ":"))
}

func cleanSubjectDetail(value string) string {
	value = strings.TrimSpace(value)
	value = strings.TrimSuffix(value, "  ")
	return strings.TrimSpace(value)
}

func isKnownLegacySubject(subject string) bool {
	known := []string{"All", "Charlotte", "Charity", "Chase", "Church", "Family", "Jenis"}
	return slices.Contains(known, subject)
}

func stripInvisible(value string) string {
	value = strings.ReplaceAll(value, "\u200b", "")
	value = strings.ReplaceAll(value, "\ufeff", "")
	return value
}

func legacyID(path string, line int, rawDate string, body string) string {
	source := filepath.Clean(path) + fmt.Sprintf(":%d\n%s\n%s", line, rawDate, body)
	sum := sha256.Sum256([]byte(source))
	return hex.EncodeToString(sum[:16])
}
