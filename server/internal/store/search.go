package store

import (
	"strings"

	"diary/server/internal/diary"
)

type SearchResult struct {
	Entry   diary.Entry
	Snippet string
}

func (s *Store) Search(query string) ([]diary.Entry, error) {
	results, err := s.SearchWithSnippets(query)
	if err != nil {
		return nil, err
	}

	entries := make([]diary.Entry, 0, len(results))
	for _, result := range results {
		entries = append(entries, result.Entry)
	}
	return entries, nil
}

func (s *Store) SearchWithSnippets(query string) ([]SearchResult, error) {
	query = FTSQuery(query)
	if query == "" {
		entries, err := s.Entries()
		if err != nil {
			return nil, err
		}

		results := make([]SearchResult, 0, len(entries))
		for _, entry := range entries {
			results = append(results, SearchResult{Entry: entry})
		}
		return results, nil
	}

	rows, err := s.db.Query(`
SELECT e.id, e.created_at, e.updated_at, e.server_revision, e.title, e.excerpt, e.body_markdown, e.source_path, e.vault_path, e.tags_json, e.people_json, e.subject_details_json, e.context_json,
       snippet(entries_fts, -1, '[[', ']]', '...', 18)
FROM entries_fts f
JOIN entries e ON e.id = f.id
WHERE entries_fts MATCH ?
ORDER BY rank, e.created_at DESC`, query)
	if err != nil {
		return nil, err
	}

	return scanSearchResults(rows, s.attachmentsForEntries)
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
