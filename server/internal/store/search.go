package store

import (
	"strings"

	"diary/server/internal/diary"
)

func (s *Store) Search(query string) ([]diary.Entry, error) {
	query = FTSQuery(query)
	if query == "" {
		return s.Entries()
	}

	rows, err := s.db.Query(`
SELECT e.id, e.created_at, e.updated_at, e.server_revision, e.title, e.excerpt, e.body_markdown, e.source_path, e.vault_path, e.tags_json, e.people_json, e.subject_details_json
FROM entries_fts f
JOIN entries e ON e.id = f.id
WHERE entries_fts MATCH ?
ORDER BY rank, e.created_at DESC`, query)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	return scanEntries(rows, s.attachmentsForEntry)
}

func FTSQuery(query string) string {
	terms := strings.Fields(query)
	if len(terms) == 0 {
		return ""
	}

	quoted := make([]string, 0, len(terms))
	for _, term := range terms {
		term = strings.Trim(term, " \t\r\n\"'.,;:!?()[]{}")
		if term == "" {
			continue
		}
		term = strings.ReplaceAll(term, `"`, `""`)
		quoted = append(quoted, `"`+term+`"`)
	}
	return strings.Join(quoted, " AND ")
}
