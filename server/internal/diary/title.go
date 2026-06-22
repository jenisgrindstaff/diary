package diary

import (
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

var (
	titleBold       = regexp.MustCompile(`\*\*([^*]+)\*\*`)
	titleLink       = regexp.MustCompile(`!?\[([^\]]*)]\([^)]+\)`)
	titleWhitespace = regexp.MustCompile(`\s+`)
)

func derivedTitle(body string, subjects []string, createdAt time.Time, fallback string) string {
	narrative := firstNarrativeLine(body)
	if narrative == "" {
		if fallback != "" {
			return fallback
		}
		return createdAt.Format("2006-01-02")
	}

	if len(subjects) == 0 {
		return narrative
	}

	if len(subjects) == 1 {
		narrative = trimSubjectPrefix(narrative, subjects[0])
	} else {
		for _, subject := range subjects {
			narrative = trimSubjectLabelPrefix(narrative, subject)
		}
	}

	return truncateTitle(strings.Join(subjects, ", ") + ": " + narrative)
}

func shouldDeriveTitle(title string, subjects []string, createdAt time.Time) bool {
	title = strings.TrimSpace(title)
	if title == "" {
		return true
	}
	if len(subjects) > 0 && title == strings.Join(subjects, ", ") {
		return true
	}
	return title == createdAt.Format("2006-01-02")
}

func firstNarrativeLine(body string) string {
	for _, line := range strings.Split(body, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || separatorLine.MatchString(line) || headingLine.MatchString(line) {
			continue
		}

		if match := boldSubjectLine.FindStringSubmatch(line); len(match) == 3 {
			detail := cleanNarrativeTitle(match[2])
			if detail == "" || ageLikeSubjectDetails.MatchString(detail) {
				continue
			}
			return detail
		}

		if match := plainSubjectLine.FindStringSubmatch(line); len(match) == 3 && isKnownLegacySubject(match[1]) {
			detail := cleanNarrativeTitle(match[2])
			if detail == "" || ageLikeSubjectDetails.MatchString(detail) {
				continue
			}
			return detail
		}

		if title := cleanNarrativeTitle(line); title != "" {
			return title
		}
	}

	return ""
}

func cleanNarrativeTitle(value string) string {
	value = strings.TrimSpace(value)
	for {
		next := strings.TrimSpace(strings.TrimPrefix(strings.TrimPrefix(value, "*"), "-"))
		if next == value {
			break
		}
		value = next
	}
	value = titleLink.ReplaceAllString(value, "$1")
	value = titleBold.ReplaceAllString(value, "$1")
	value = strings.Trim(value, " \t\r\n#`")
	value = titleWhitespace.ReplaceAllString(value, " ")
	return truncateTitle(value)
}

func trimSubjectPrefix(value string, subject string) string {
	lowerValue := strings.ToLower(value)
	lowerSubject := strings.ToLower(subject)
	if !strings.HasPrefix(lowerValue, lowerSubject) {
		return value
	}

	remainder := strings.TrimSpace(value[len(subject):])
	remainder = strings.TrimPrefix(remainder, ":")
	remainder = strings.TrimSpace(remainder)
	if remainder == "" {
		return value
	}

	return uppercaseFirst(remainder)
}

func trimSubjectLabelPrefix(value string, subject string) string {
	lowerValue := strings.ToLower(value)
	lowerSubject := strings.ToLower(subject) + ":"
	if !strings.HasPrefix(lowerValue, lowerSubject) {
		return value
	}

	remainder := strings.TrimSpace(value[len(subject)+1:])
	if remainder == "" {
		return value
	}
	return uppercaseFirst(remainder)
}

func uppercaseFirst(value string) string {
	if value == "" {
		return value
	}
	return strings.ToUpper(value[:1]) + value[1:]
}

func truncateTitle(value string) string {
	const limit = 90
	value = strings.TrimSpace(value)
	if len(value) <= limit {
		return value
	}

	cut := strings.LastIndex(value[:limit], " ")
	if cut < 55 {
		cut = limit
	}
	return strings.TrimSpace(value[:cut]) + "..."
}

func fallbackTitleFromPath(path string) string {
	base := strings.TrimSuffix(filepath.Base(path), filepath.Ext(path))
	base = strings.ReplaceAll(base, "-", " ")
	base = strings.ReplaceAll(base, "_", " ")
	return strings.TrimSpace(base)
}
