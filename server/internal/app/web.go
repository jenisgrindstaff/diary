package app

import (
	"bytes"
	"html/template"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strconv"
	"strings"
	"time"

	"diary/server/internal/diary"
	"github.com/yuin/goldmark"
)

type homePageData struct {
	Entries      []entryListItem
	Subjects     []subjectCount
	Tags         []tagCount
	Archive      []archiveCount
	Query        string
	Subject      string
	Tag          string
	Year         string
	Month        string
	Message      string
	TotalEntries int
	ImportFiles  []string
	CSRFToken    string
	Public       bool
}

type detailPageData struct {
	Entry     diary.Entry
	BodyHTML  template.HTML
	RawBody   string
	Message   string
	ShareURL  string
	CSRFToken string
	Public    bool
}

type entryFormPageData struct {
	Heading      string
	Action       string
	SubmitLabel  string
	AllowMedia   bool
	Date         string
	Title        string
	People       string
	Tags         string
	BodyMarkdown string
	Message      string
	CSRFToken    string
	Public       bool
}

type entryListItem struct {
	diary.Entry
	CleanExcerpt string
}

type subjectCount struct {
	Name  string
	Count int
}

type tagCount struct {
	Name  string
	Count int
}

type archiveCount struct {
	Year  string
	Month string
	Label string
	Count int
}

func (s *Server) handleHome(w http.ResponseWriter, r *http.Request) {
	entries, err := s.store.Entries()
	if err != nil {
		writeError(w, http.StatusInternalServerError, publicMessage(err))
		return
	}

	query := strings.TrimSpace(r.URL.Query().Get("q"))
	subject := strings.TrimSpace(r.URL.Query().Get("subject"))
	tag := strings.TrimSpace(r.URL.Query().Get("tag"))
	year := strings.TrimSpace(r.URL.Query().Get("year"))
	month := strings.TrimSpace(r.URL.Query().Get("month"))
	message := strings.TrimSpace(r.URL.Query().Get("message"))
	searchEntries := entries
	if query != "" {
		searchEntries, err = s.store.Search(query)
		if err != nil {
			message = "Search failed: " + publicMessage(err)
			searchEntries = []diary.Entry{}
		}
	}
	filtered := listItems(filterEntries(searchEntries, subject, tag, year, month))
	importFiles, _ := markdownFiles(s.cfg.ImportDir)

	data := homePageData{
		Entries:      filtered,
		Subjects:     subjectCounts(entries),
		Tags:         tagCounts(entries),
		Archive:      archiveCounts(entries),
		Query:        query,
		Subject:      subject,
		Tag:          tag,
		Year:         year,
		Month:        month,
		Message:      message,
		TotalEntries: len(entries),
		ImportFiles:  importFiles,
		CSRFToken:    ensureCSRFToken(w, r),
	}

	if err := pageTemplate.ExecuteTemplate(w, "home", data); err != nil {
		s.logger.Error("render home failed", "error", err)
	}
}

func (s *Server) handleWebEntry(w http.ResponseWriter, r *http.Request) {
	entry, err := s.store.Entry(r.PathValue("id"))
	if err != nil {
		writeError(w, http.StatusNotFound, "entry not found")
		return
	}

	bodyHTML, err := renderMarkdown(entry.BodyMarkdown)
	if err != nil {
		writeError(w, http.StatusInternalServerError, publicMessage(err))
		return
	}

	if err := pageTemplate.ExecuteTemplate(w, "detail", detailPageData{
		Entry:     entry,
		BodyHTML:  bodyHTML,
		RawBody:   entry.BodyMarkdown,
		Message:   strings.TrimSpace(r.URL.Query().Get("message")),
		ShareURL:  absoluteURL(r, "/share/"+s.shareToken(entry.ID)),
		CSRFToken: ensureCSRFToken(w, r),
	}); err != nil {
		s.logger.Error("render entry failed", "error", err)
	}
}

func (s *Server) handleShare(w http.ResponseWriter, r *http.Request) {
	entryID, ok := s.verifyShareToken(r.PathValue("token"))
	if !ok {
		writeError(w, http.StatusNotFound, "share link not found")
		return
	}
	entry, err := s.store.Entry(entryID)
	if err != nil {
		writeError(w, http.StatusNotFound, "entry not found")
		return
	}
	bodyHTML, err := renderMarkdown(entry.BodyMarkdown)
	if err != nil {
		writeError(w, http.StatusInternalServerError, publicMessage(err))
		return
	}

	if err := pageTemplate.ExecuteTemplate(w, "share", detailPageData{
		Entry:    entry,
		BodyHTML: bodyHTML,
		RawBody:  entry.BodyMarkdown,
		Public:   true,
	}); err != nil {
		s.logger.Error("render share failed", "error", err)
	}
}

func (s *Server) handleNewEntry(w http.ResponseWriter, r *http.Request) {
	data := entryFormPageData{
		Heading:     "New Entry",
		Action:      "/entries",
		SubmitLabel: "Create Entry",
		AllowMedia:  true,
		Date:        time.Now().Format("2006-01-02"),
		CSRFToken:   ensureCSRFToken(w, r),
	}
	if err := pageTemplate.ExecuteTemplate(w, "entryForm", data); err != nil {
		s.logger.Error("render entry form failed", "error", err)
	}
}

func (s *Server) handleCreateEntry(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, 512<<20)
	if err := r.ParseMultipartForm(64 << 20); err != nil {
		writeError(w, http.StatusBadRequest, "invalid form")
		return
	}
	if !validCSRF(r) {
		writeError(w, http.StatusForbidden, "invalid CSRF token")
		return
	}

	data := entryFormPageData{
		Heading:      "New Entry",
		Action:       "/entries",
		SubmitLabel:  "Create Entry",
		AllowMedia:   true,
		Date:         strings.TrimSpace(r.FormValue("date")),
		Title:        strings.TrimSpace(r.FormValue("title")),
		People:       strings.TrimSpace(r.FormValue("people")),
		Tags:         strings.TrimSpace(r.FormValue("tags")),
		BodyMarkdown: strings.TrimSpace(r.FormValue("body_markdown")),
		CSRFToken:    ensureCSRFToken(w, r),
	}

	createdAt, err := time.ParseInLocation("2006-01-02", data.Date, time.Local)
	if err != nil {
		data.Message = "Use a valid date."
		w.WriteHeader(http.StatusBadRequest)
		_ = pageTemplate.ExecuteTemplate(w, "entryForm", data)
		return
	}

	entry, err := diary.CreateEntry(s.cfg.VaultDir, diary.CreateEntryInput{
		CreatedAt:    createdAt,
		Title:        data.Title,
		BodyMarkdown: data.BodyMarkdown,
		People:       splitFormList(data.People),
		Tags:         splitFormList(data.Tags),
		Now:          time.Now().UTC(),
	})
	if err != nil {
		data.Message = "Create failed: " + publicMessage(err)
		w.WriteHeader(http.StatusBadRequest)
		_ = pageTemplate.ExecuteTemplate(w, "entryForm", data)
		return
	}
	attached, err := s.attachUploadedMedia(&entry, r, time.Now().UTC())
	if err != nil {
		data.Message = "Attach failed: " + publicMessage(err)
		w.WriteHeader(http.StatusBadRequest)
		_ = pageTemplate.ExecuteTemplate(w, "entryForm", data)
		return
	}
	if err := s.indexEntry(entry.VaultPath); err != nil {
		data.Message = "Reindex failed: " + publicMessage(err)
		w.WriteHeader(http.StatusInternalServerError)
		_ = pageTemplate.ExecuteTemplate(w, "entryForm", data)
		return
	}

	message := "Created entry"
	if attached > 0 {
		message += " with " + itoa(attached) + " media file"
		if attached > 1 {
			message += "s"
		}
	}
	http.Redirect(w, r, "/entries/"+url.PathEscape(entry.ID)+"?message="+urlMessage(message), http.StatusSeeOther)
}

func (s *Server) handleEditEntry(w http.ResponseWriter, r *http.Request) {
	entry, err := s.store.Entry(r.PathValue("id"))
	if err != nil {
		writeError(w, http.StatusNotFound, "entry not found")
		return
	}

	data := entryFormDataForEntry(entry)
	data.CSRFToken = ensureCSRFToken(w, r)
	if err := pageTemplate.ExecuteTemplate(w, "entryForm", data); err != nil {
		s.logger.Error("render edit form failed", "error", err)
	}
}

func (s *Server) handleUpdateEntry(w http.ResponseWriter, r *http.Request) {
	entryID := r.PathValue("id")
	entry, err := s.store.Entry(entryID)
	if err != nil {
		writeError(w, http.StatusNotFound, "entry not found")
		return
	}
	if err := r.ParseForm(); err != nil {
		writeError(w, http.StatusBadRequest, "invalid form")
		return
	}
	if !validCSRF(r) {
		writeError(w, http.StatusForbidden, "invalid CSRF token")
		return
	}

	data := entryFormPageData{
		Heading:      "Edit Entry",
		Action:       "/entries/" + url.PathEscape(entryID),
		SubmitLabel:  "Save Entry",
		Date:         strings.TrimSpace(r.FormValue("date")),
		Title:        strings.TrimSpace(r.FormValue("title")),
		People:       strings.TrimSpace(r.FormValue("people")),
		Tags:         strings.TrimSpace(r.FormValue("tags")),
		BodyMarkdown: strings.TrimSpace(r.FormValue("body_markdown")),
		CSRFToken:    ensureCSRFToken(w, r),
	}

	createdAt, err := time.ParseInLocation("2006-01-02", data.Date, time.Local)
	if err != nil {
		data.Message = "Use a valid date."
		w.WriteHeader(http.StatusBadRequest)
		_ = pageTemplate.ExecuteTemplate(w, "entryForm", data)
		return
	}

	updated, err := diary.UpdateEntry(s.cfg.VaultDir, entry, diary.UpdateEntryInput{
		CreatedAt:    createdAt,
		Title:        data.Title,
		BodyMarkdown: data.BodyMarkdown,
		People:       splitFormList(data.People),
		Tags:         splitFormList(data.Tags),
		Now:          time.Now().UTC(),
	})
	if err != nil {
		data.Message = "Update failed: " + publicMessage(err)
		w.WriteHeader(http.StatusBadRequest)
		_ = pageTemplate.ExecuteTemplate(w, "entryForm", data)
		return
	}
	if err := s.indexEntry(updated.VaultPath); err != nil {
		data.Message = "Reindex failed: " + publicMessage(err)
		w.WriteHeader(http.StatusInternalServerError)
		_ = pageTemplate.ExecuteTemplate(w, "entryForm", data)
		return
	}

	http.Redirect(w, r, "/entries/"+url.PathEscape(updated.ID)+"?message="+urlMessage("Updated entry"), http.StatusSeeOther)
}

func (s *Server) handleTrashEntry(w http.ResponseWriter, r *http.Request) {
	if !validCSRF(r) {
		writeError(w, http.StatusForbidden, "invalid CSRF token")
		return
	}
	entryID := r.PathValue("id")
	entry, err := s.store.Entry(entryID)
	if err != nil {
		writeError(w, http.StatusNotFound, "entry not found")
		return
	}

	tombstone, err := diary.TrashEntry(s.cfg.VaultDir, entry, time.Now().UTC())
	if err != nil {
		http.Redirect(w, r, "/entries/"+url.PathEscape(entryID)+"?message="+urlMessage("Trash failed: "+publicMessage(err)), http.StatusSeeOther)
		return
	}
	if err := s.store.IndexDeletion(tombstone); err != nil {
		http.Redirect(w, r, "/?message="+urlMessage("Reindex failed: "+publicMessage(err)), http.StatusSeeOther)
		return
	}

	http.Redirect(w, r, "/?message="+urlMessage("Moved entry to trash"), http.StatusSeeOther)
}

func (s *Server) handleWebAttachMedia(w http.ResponseWriter, r *http.Request) {
	entryID := r.PathValue("id")
	entry, err := s.store.Entry(entryID)
	if err != nil {
		writeError(w, http.StatusNotFound, "entry not found")
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, 512<<20)
	if !validCSRF(r) {
		writeError(w, http.StatusForbidden, "invalid CSRF token")
		return
	}
	file, header, err := r.FormFile("media")
	if err != nil {
		http.Redirect(w, r, "/entries/"+url.PathEscape(entryID)+"?message="+urlMessage("Choose a file to attach"), http.StatusSeeOther)
		return
	}
	defer file.Close()

	updated, attachment, err := diary.AttachFile(s.cfg.VaultDir, entry, header.Filename, header.Header.Get("Content-Type"), file, time.Now().UTC())
	if err != nil {
		http.Redirect(w, r, "/entries/"+url.PathEscape(entryID)+"?message="+urlMessage("Attach failed: "+publicMessage(err)), http.StatusSeeOther)
		return
	}
	if err := s.indexEntry(updated.VaultPath); err != nil {
		http.Redirect(w, r, "/entries/"+url.PathEscape(entryID)+"?message="+urlMessage("Reindex failed: "+publicMessage(err)), http.StatusSeeOther)
		return
	}

	http.Redirect(w, r, "/entries/"+url.PathEscape(entryID)+"?message="+urlMessage("Attached "+attachment.Filename), http.StatusSeeOther)
}

func (s *Server) attachUploadedMedia(entry *diary.Entry, r *http.Request, now time.Time) (int, error) {
	if r.MultipartForm == nil || r.MultipartForm.File == nil {
		return 0, nil
	}

	headers := r.MultipartForm.File["media"]
	attached := 0
	for _, header := range headers {
		if header == nil || strings.TrimSpace(header.Filename) == "" {
			continue
		}
		file, err := header.Open()
		if err != nil {
			return attached, err
		}
		updated, _, err := diary.AttachFile(s.cfg.VaultDir, *entry, header.Filename, header.Header.Get("Content-Type"), file, now)
		closeErr := file.Close()
		if err != nil {
			return attached, err
		}
		if closeErr != nil {
			return attached, closeErr
		}
		*entry = updated
		attached++
	}

	return attached, nil
}

func (s *Server) handleWebAsset(w http.ResponseWriter, r *http.Request) {
	asset, err := s.store.Asset(r.PathValue("id"))
	if err != nil {
		writeError(w, http.StatusNotFound, "asset not found")
		return
	}

	http.ServeFile(w, r, asset.AbsolutePath)
}

func (s *Server) handleWebImport(w http.ResponseWriter, r *http.Request) {
	if !validCSRF(r) {
		writeError(w, http.StatusForbidden, "invalid CSRF token")
		return
	}
	result, err := s.importer.Import(s.cfg.ImportDir)
	if err != nil {
		http.Redirect(w, r, "/?message="+urlMessage("Import failed: "+publicMessage(err)), http.StatusSeeOther)
		return
	}
	if err := s.Reindex(); err != nil {
		http.Redirect(w, r, "/?message="+urlMessage("Reindex failed: "+publicMessage(err)), http.StatusSeeOther)
		return
	}

	message := "Imported " + itoa(result.ImportedEntries) + " entries"
	if result.SkippedEntries > 0 {
		message += ", skipped " + itoa(result.SkippedEntries)
	}
	http.Redirect(w, r, "/?message="+urlMessage(message), http.StatusSeeOther)
}

func (s *Server) handleWebReindex(w http.ResponseWriter, r *http.Request) {
	if !validCSRF(r) {
		writeError(w, http.StatusForbidden, "invalid CSRF token")
		return
	}
	if err := s.Reindex(); err != nil {
		http.Redirect(w, r, "/?message="+urlMessage("Reindex failed: "+publicMessage(err)), http.StatusSeeOther)
		return
	}

	http.Redirect(w, r, "/?message="+urlMessage("Reindexed vault"), http.StatusSeeOther)
}

func filterEntries(entries []diary.Entry, subject string, tag string, year string, month string) []diary.Entry {
	filtered := make([]diary.Entry, 0, len(entries))

	for _, entry := range entries {
		if subject != "" && !slices.Contains(entry.People, subject) {
			continue
		}
		if tag != "" && !slices.Contains(entry.Tags, tag) {
			continue
		}
		if year != "" && entry.CreatedAt.Format("2006") != year {
			continue
		}
		if month != "" && entry.CreatedAt.Format("01") != month {
			continue
		}

		filtered = append(filtered, entry)
	}

	return filtered
}

func listItems(entries []diary.Entry) []entryListItem {
	items := make([]entryListItem, 0, len(entries))
	for _, entry := range entries {
		items = append(items, entryListItem{
			Entry:        entry,
			CleanExcerpt: cleanExcerpt(entry.Excerpt),
		})
	}
	return items
}

func subjectCounts(entries []diary.Entry) []subjectCount {
	counts := map[string]int{}
	for _, entry := range entries {
		for _, subject := range entry.People {
			counts[subject]++
		}
	}

	subjects := make([]subjectCount, 0, len(counts))
	for name, count := range counts {
		subjects = append(subjects, subjectCount{Name: name, Count: count})
	}
	sort.Slice(subjects, func(i, j int) bool {
		if subjects[i].Count == subjects[j].Count {
			return subjects[i].Name < subjects[j].Name
		}
		return subjects[i].Count > subjects[j].Count
	})

	return subjects
}

func tagCounts(entries []diary.Entry) []tagCount {
	counts := map[string]int{}
	for _, entry := range entries {
		for _, tag := range entry.Tags {
			counts[tag]++
		}
	}

	tags := make([]tagCount, 0, len(counts))
	for name, count := range counts {
		tags = append(tags, tagCount{Name: name, Count: count})
	}
	sort.Slice(tags, func(i, j int) bool {
		if tags[i].Count == tags[j].Count {
			return tags[i].Name < tags[j].Name
		}
		return tags[i].Count > tags[j].Count
	})

	return tags
}

func archiveCounts(entries []diary.Entry) []archiveCount {
	counts := map[string]int{}
	for _, entry := range entries {
		key := entry.CreatedAt.Format("2006-01")
		counts[key]++
	}

	archive := make([]archiveCount, 0, len(counts))
	for key, count := range counts {
		parts := strings.Split(key, "-")
		if len(parts) != 2 {
			continue
		}
		date, err := time.Parse("2006-01", key)
		if err != nil {
			continue
		}
		archive = append(archive, archiveCount{
			Year:  parts[0],
			Month: parts[1],
			Label: date.Format("January 2006"),
			Count: count,
		})
	}

	sort.Slice(archive, func(i, j int) bool {
		if archive[i].Year == archive[j].Year {
			return archive[i].Month > archive[j].Month
		}
		return archive[i].Year > archive[j].Year
	})

	return archive
}

func markdownFiles(root string) ([]string, error) {
	files := []string{}
	err := filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			return nil
		}
		ext := strings.ToLower(filepath.Ext(path))
		if ext != ".md" && ext != ".markdown" && ext != ".txt" {
			return nil
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			rel = path
		}
		files = append(files, rel)
		return nil
	})
	sort.Strings(files)
	return files, err
}

func splitFormList(value string) []string {
	parts := strings.Split(value, ",")
	out := make([]string, 0, len(parts))
	for _, part := range parts {
		part = strings.TrimSpace(part)
		if part != "" {
			out = append(out, part)
		}
	}
	return out
}

func entryFormDataForEntry(entry diary.Entry) entryFormPageData {
	return entryFormPageData{
		Heading:      "Edit Entry",
		Action:       "/entries/" + url.PathEscape(entry.ID),
		SubmitLabel:  "Save Entry",
		Date:         entry.CreatedAt.Format("2006-01-02"),
		Title:        entry.Title,
		People:       strings.Join(entry.People, ", "),
		Tags:         strings.Join(entry.Tags, ", "),
		BodyMarkdown: entry.BodyMarkdown,
	}
}

func urlMessage(value string) string {
	return url.QueryEscape(value)
}

func itoa(value int) string {
	return strconv.Itoa(value)
}

func renderMarkdown(value string) (template.HTML, error) {
	var buf bytes.Buffer
	if err := goldmark.Convert([]byte(value), &buf); err != nil {
		return "", err
	}
	return template.HTML(buf.String()), nil
}

var (
	markdownBold       = regexp.MustCompile(`\*\*([^*]+)\*\*`)
	markdownBullet     = regexp.MustCompile(`(?m)^\s*\*\s+`)
	inlineBullet       = regexp.MustCompile(`(?:^|\s)\*\s+`)
	markdownHeading    = regexp.MustCompile(`(?m)^#{1,6}\s+`)
	markdownWhitespace = regexp.MustCompile(`\s+`)
)

func cleanExcerpt(value string) string {
	value = markdownBold.ReplaceAllString(value, "$1")
	value = markdownBullet.ReplaceAllString(value, "")
	value = inlineBullet.ReplaceAllString(value, " ")
	value = markdownHeading.ReplaceAllString(value, "")
	value = strings.ReplaceAll(value, "`", "")
	value = markdownWhitespace.ReplaceAllString(value, " ")
	value = strings.TrimSpace(value)
	if len(value) > 220 {
		value = value[:220] + "..."
	}
	return value
}

var pageTemplate = template.Must(template.New("pages").Funcs(template.FuncMap{
	"date": func(t time.Time) string {
		return t.Format("Jan 2, 2006")
	},
	"month": func(t time.Time) string {
		return t.Format("January 2006")
	},
	"join":     strings.Join,
	"urlquery": url.QueryEscape,
	"queryFor": func(query string, subject string, tag string, year string, month string) string {
		values := url.Values{}
		if query != "" {
			values.Set("q", query)
		}
		if subject != "" {
			values.Set("subject", subject)
		}
		if tag != "" {
			values.Set("tag", tag)
		}
		if year != "" {
			values.Set("year", year)
		}
		if month != "" {
			values.Set("month", month)
		}
		encoded := values.Encode()
		if encoded == "" {
			return "/"
		}
		return "/?" + encoded
	},
	"trim": func(value string) string {
		return strings.TrimSpace(value)
	},
	"webAsset": func(asset diary.Attachment) string {
		return "/assets/" + url.PathEscape(asset.ID)
	},
}).Parse(pageTemplates))

const pageTemplates = `
{{define "layoutStart"}}
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Diary</title>
  <style>
    :root {
      color-scheme: light dark;
      --bg: #f7f7f4;
      --panel: #ffffff;
      --text: #20201d;
      --muted: #6f6d66;
      --line: #dedbd2;
      --accent: #2f6f73;
      --accent-weak: #e3f0ef;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --bg: #171713;
        --panel: #23231e;
        --text: #f2f0e8;
        --muted: #b9b4a7;
        --line: #3a382f;
        --accent: #8ecfd0;
        --accent-weak: #1f3434;
      }
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font: 16px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      background: var(--bg);
      color: var(--text);
    }
    header {
      position: sticky;
      top: 0;
      z-index: 2;
      border-bottom: 1px solid var(--line);
      background: color-mix(in srgb, var(--bg) 88%, transparent);
      backdrop-filter: blur(16px);
    }
    .bar, main {
      max-width: 1180px;
      margin: 0 auto;
      padding: 18px;
    }
    .bar {
      display: flex;
      gap: 16px;
      align-items: center;
      justify-content: space-between;
    }
    .brand {
      font-size: 24px;
      font-weight: 700;
      color: var(--text);
      text-decoration: none;
    }
    .actions {
      display: flex;
      gap: 8px;
      flex-wrap: wrap;
    }
    .entry-actions {
      display: flex;
      gap: 8px;
      flex-wrap: wrap;
      align-items: center;
      margin-bottom: 14px;
    }
    button, .button {
      appearance: none;
      border: 1px solid var(--line);
      border-radius: 8px;
      padding: 8px 12px;
      background: var(--panel);
      color: var(--text);
      text-decoration: none;
      cursor: pointer;
      font: inherit;
    }
    button.primary, .button.primary {
      background: var(--accent);
      border-color: var(--accent);
      color: white;
    }
    button.danger {
      background: #763030;
      border-color: #a33d3d;
      color: #ffd7d7;
    }
    .grid {
      display: grid;
      grid-template-columns: 280px minmax(0, 1fr);
      gap: 18px;
    }
    aside, .entry, .detail {
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 8px;
    }
    aside {
      align-self: start;
      padding: 16px;
      position: sticky;
      top: 82px;
    }
    h1, h2, h3, p { margin-top: 0; }
    .muted { color: var(--muted); }
    .notice {
      margin-bottom: 16px;
      padding: 10px 12px;
      border: 1px solid var(--line);
      border-radius: 8px;
      background: var(--accent-weak);
    }
    input[type="search"], input[type="file"], input[type="text"], input[type="date"], textarea {
      width: 100%;
      border: 1px solid var(--line);
      border-radius: 8px;
      padding: 10px 12px;
      font: inherit;
      background: var(--panel);
      color: var(--text);
    }
    textarea {
      min-height: 280px;
      resize: vertical;
      font-family: ui-serif, Georgia, serif;
      line-height: 1.55;
    }
    .subjects {
      display: flex;
      gap: 8px;
      flex-wrap: wrap;
    }
    .chip {
      display: inline-flex;
      gap: 6px;
      align-items: center;
      border: 1px solid var(--line);
      border-radius: 999px;
      padding: 5px 10px;
      color: var(--text);
      text-decoration: none;
      background: transparent;
      font-size: 14px;
    }
    .chip.active {
      background: var(--accent-weak);
      border-color: var(--accent);
    }
    .list {
      display: grid;
      gap: 10px;
    }
    .month {
      margin: 18px 0 8px;
      color: var(--muted);
      font-size: 13px;
      font-weight: 700;
      text-transform: uppercase;
      letter-spacing: .06em;
    }
    .entry {
      display: block;
      padding: 14px 16px;
      color: var(--text);
      text-decoration: none;
    }
    .entry:hover { border-color: var(--accent); }
    .entry h3 {
      margin-bottom: 4px;
      font-size: 18px;
    }
  .meta {
      display: flex;
      gap: 10px;
      flex-wrap: wrap;
      color: var(--muted);
      font-size: 13px;
    }
    .subject-details {
      display: flex;
      gap: 8px;
      flex-wrap: wrap;
      margin-top: 12px;
    }
    .media {
      display: grid;
      gap: 12px;
      margin-top: 24px;
    }
    .media h2 {
      margin-bottom: 0;
      font-size: 18px;
    }
    .media-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
      gap: 12px;
      align-items: start;
    }
    .media-item {
      display: grid;
      align-content: start;
      overflow: hidden;
      border: 1px solid var(--line);
      border-radius: 8px;
      background: var(--bg);
      margin: 0;
    }
    .media-item img, .media-item video {
      display: block;
      width: 100%;
      max-height: 520px;
      object-fit: contain;
      background: #111;
    }
    .media-item a {
      display: block;
      padding: 12px;
      color: var(--text);
      overflow-wrap: anywhere;
    }
    .media-caption {
      margin: 0;
      padding: 8px 10px;
      color: var(--muted);
      font-size: 13px;
      overflow-wrap: anywhere;
    }
    .attach-form {
      display: grid;
      gap: 10px;
      margin-top: 24px;
      padding: 14px;
      border: 1px solid var(--line);
      border-radius: 8px;
      background: var(--bg);
    }
    .attach-form h2 {
      margin: 0;
      font-size: 18px;
    }
    .entry-form {
      display: grid;
      gap: 14px;
      max-width: 860px;
    }
    .entry-form label {
      display: grid;
      gap: 6px;
      color: var(--muted);
      font-size: 14px;
    }
    .form-row {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 12px;
    }
    .detail {
      padding: 24px;
      max-width: 860px;
    }
    .body {
      margin-top: 24px;
      font-family: ui-serif, Georgia, serif;
      font-size: 18px;
      line-height: 1.65;
    }
    .body > :first-child { margin-top: 0; }
    .body p, .body ul, .body ol { margin: 0 0 16px; }
    .body li { margin: 4px 0; }
    .body strong { font-weight: 700; }
    code {
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
      font-size: 13px;
    }
    @media (max-width: 780px) {
      .grid { grid-template-columns: 1fr; }
      .form-row { grid-template-columns: 1fr; }
      aside { position: static; }
      .bar { align-items: flex-start; flex-direction: column; }
    }
    .share-box { margin: 12px 0 4px; }
    .share-row { display: flex; gap: 8px; align-items: center; }
    .share-row input {
      flex: 1; padding: 8px 10px; border: 1px solid var(--line);
      border-radius: 8px; background: var(--panel); color: var(--text);
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 13px;
    }
    .editor-toolbar { display: flex; justify-content: flex-end; margin-bottom: 6px; }
    .hint { margin-top: 6px; font-size: 13px; }
    textarea.drag { outline: 2px dashed var(--accent); outline-offset: 2px; }
    body.focus-mode header,
    body.focus-mode .entry-form > p,
    body.focus-mode .entry-form .form-row { display: none; }
    body.focus-mode main { max-width: 760px; }
    body.focus-mode .entry-form textarea { min-height: 70vh; }
  </style>
</head>
<body>
<header>
  <div class="bar">
    {{if .Public}}<span class="brand">Diary</span>{{else}}<a class="brand" href="/">Diary</a>{{end}}
    {{if not .Public}}
    <div class="actions">
      <a class="button primary" href="/entries/new">New Entry</a>
      <form method="post" action="/admin/import"><input type="hidden" name="csrf_token" value="{{.CSRFToken}}"><button class="primary" type="submit">Import</button></form>
      <form method="post" action="/admin/reindex"><input type="hidden" name="csrf_token" value="{{.CSRFToken}}"><button type="submit">Reindex</button></form>
    </div>
    {{end}}
  </div>
</header>
<main>
{{end}}

{{define "layoutEnd"}}
</main>
<script>
(function(){
  document.querySelectorAll('[data-copy]').forEach(function(btn){
    btn.addEventListener('click', function(){
      var el = document.querySelector(btn.getAttribute('data-copy'));
      if(!el){ return; }
      el.focus(); el.select();
      if(navigator.clipboard){ navigator.clipboard.writeText(el.value); }
      var label = btn.textContent;
      btn.textContent = 'Copied';
      setTimeout(function(){ btn.textContent = label; }, 1200);
    });
  });

  document.querySelectorAll('[data-focus-toggle]').forEach(function(btn){
    btn.addEventListener('click', function(){ document.body.classList.toggle('focus-mode'); });
  });

  var editor = document.getElementById('editor');
  if(editor){
    editor.addEventListener('keydown', function(e){
      if((e.metaKey || e.ctrlKey) && e.key === 'Enter'){
        var form = editor.closest('form');
        if(form){ e.preventDefault(); form.requestSubmit ? form.requestSubmit() : form.submit(); }
      }
    });

    var mediaInput = document.getElementById('media-input');
    if(editor.hasAttribute('data-drop-target') && mediaInput && 'DataTransfer' in window){
      ['dragover','dragenter'].forEach(function(ev){
        editor.addEventListener(ev, function(e){ e.preventDefault(); editor.classList.add('drag'); });
      });
      ['dragleave','dragend'].forEach(function(ev){
        editor.addEventListener(ev, function(){ editor.classList.remove('drag'); });
      });
      editor.addEventListener('drop', function(e){
        editor.classList.remove('drag');
        if(!e.dataTransfer || !e.dataTransfer.files.length){ return; }
        e.preventDefault();
        var dt = new DataTransfer();
        Array.prototype.forEach.call(mediaInput.files, function(f){ dt.items.add(f); });
        Array.prototype.forEach.call(e.dataTransfer.files, function(f){ dt.items.add(f); });
        mediaInput.files = dt.files;
        var note = document.getElementById('drop-note');
        if(note){ note.textContent = mediaInput.files.length + ' file(s) ready'; }
      });
    }
  }
})();
</script>
</body>
</html>
{{end}}

{{define "home"}}
{{template "layoutStart" .}}
{{if .Message}}<div class="notice">{{.Message}}</div>{{end}}
<div class="grid">
  <aside>
    <form method="get" action="/">
              <input type="search" name="q" value="{{.Query}}" placeholder="Search entries">
              {{if .Subject}}<input type="hidden" name="subject" value="{{.Subject}}">{{end}}
              {{if .Tag}}<input type="hidden" name="tag" value="{{.Tag}}">{{end}}
              {{if .Year}}<input type="hidden" name="year" value="{{.Year}}">{{end}}
              {{if .Month}}<input type="hidden" name="month" value="{{.Month}}">{{end}}
              <p><button type="submit">Search</button> {{if or .Query .Subject .Tag .Year .Month}}<a class="button" href="/">Clear</a>{{end}}</p>
            </form>
            <h2>People</h2>
            <div class="subjects">
              {{range .Subjects}}
        <a class="chip {{if eq $.Subject .Name}}active{{end}}" href="{{queryFor $.Query .Name $.Tag $.Year $.Month}}">{{.Name}} <span class="muted">{{.Count}}</span></a>
      {{end}}
    </div>
    {{if .Tags}}
    <h2 style="margin-top:22px;">Tags</h2>
    <div class="subjects">
      {{range .Tags}}
        <a class="chip {{if eq $.Tag .Name}}active{{end}}" href="{{queryFor $.Query $.Subject .Name $.Year $.Month}}">#{{.Name}} <span class="muted">{{.Count}}</span></a>
      {{end}}
    </div>
    {{end}}
    <h2 style="margin-top:22px;">Archive</h2>
    <div class="subjects">
      {{range .Archive}}
        <a class="chip {{if and (eq $.Year .Year) (eq $.Month .Month)}}active{{end}}" href="{{queryFor $.Query $.Subject $.Tag .Year .Month}}">{{.Label}} <span class="muted">{{.Count}}</span></a>
      {{end}}
    </div>
    <h2 style="margin-top:22px;">Import</h2>
    <p class="muted">{{.TotalEntries}} indexed entries</p>
    {{if .ImportFiles}}
      <p class="muted">Import folder:</p>
      {{range .ImportFiles}}<p><code>{{.}}</code></p>{{end}}
    {{else}}
      <p class="muted">No Markdown files in imports.</p>
    {{end}}
  </aside>
  <section>
    <h1>{{len .Entries}} Entries</h1>
    <div class="list">
      {{$lastMonth := ""}}
      {{range .Entries}}
        {{$month := month .CreatedAt}}
        {{if ne $month $lastMonth}}<div class="month">{{$month}}</div>{{end}}
        <a class="entry" href="/entries/{{.ID}}">
          <h3>{{.Title}}</h3>
          <p>{{.CleanExcerpt}}</p>
          <div class="meta">
            <span>{{date .CreatedAt}}</span>
            {{if .People}}<span>{{join .People ", "}}</span>{{end}}
            {{if .Tags}}<span>{{join .Tags ", "}}</span>{{end}}
          </div>
        </a>
        {{$lastMonth = $month}}
      {{else}}
        <p class="muted">No entries match this filter.</p>
      {{end}}
    </div>
  </section>
</div>
{{template "layoutEnd" .}}
{{end}}

{{define "entryForm"}}
{{template "layoutStart" .}}
{{if .Message}}<div class="notice">{{.Message}}</div>{{end}}
<form class="detail entry-form" method="post" action="{{.Action}}" {{if .AllowMedia}}enctype="multipart/form-data"{{end}}>
  <input type="hidden" name="csrf_token" value="{{.CSRFToken}}">
  <p><a href="/">Back to entries</a></p>
  <h1>{{.Heading}}</h1>
  <div class="form-row">
    <label>Date
      <input type="date" name="date" value="{{.Date}}">
    </label>
    <label>Title
      <input type="text" name="title" value="{{.Title}}">
    </label>
  </div>
  <div class="form-row">
    <label>People
      <input type="text" name="people" value="{{.People}}">
    </label>
    <label>Tags
      <input type="text" name="tags" value="{{.Tags}}">
    </label>
  </div>
  <label>Markdown
    <div class="editor-toolbar">
      <button type="button" class="button" data-focus-toggle>Focus mode</button>
    </div>
    <textarea id="editor" name="body_markdown" {{if .AllowMedia}}data-drop-target{{end}}>{{.BodyMarkdown}}</textarea>
    <p class="muted hint">⌘/Ctrl + Return to save.{{if .AllowMedia}} Drag files onto the editor to attach.{{end}}</p>
  </label>
  {{if .AllowMedia}}
    <label>Media
      <input id="media-input" type="file" name="media" multiple accept="image/*,video/*,.pdf,.txt,.md,.markdown">
      <span id="drop-note" class="muted"></span>
    </label>
  {{end}}
  <p><button class="primary" type="submit">{{.SubmitLabel}}</button></p>
</form>
{{template "layoutEnd" .}}
{{end}}

{{define "detail"}}
{{template "layoutStart" .}}
{{if .Message}}<div class="notice">{{.Message}}</div>{{end}}
<article class="detail">
  <div class="entry-actions">
    <a href="/">Back to entries</a>
    <a class="button" href="/entries/{{.Entry.ID}}/edit">Edit</a>
    <form method="post" action="/entries/{{.Entry.ID}}/trash">
      <input type="hidden" name="csrf_token" value="{{.CSRFToken}}">
      <button class="danger" type="submit">Move to Trash</button>
    </form>
  </div>
  {{if .ShareURL}}
  <div class="share-box">
    <label class="muted" for="share-url">Read-only share link</label>
    <div class="share-row">
      <input id="share-url" type="text" readonly value="{{.ShareURL}}" onfocus="this.select()">
      <button type="button" class="button" data-copy="#share-url">Copy</button>
    </div>
  </div>
  {{end}}
  <p class="muted">{{date .Entry.CreatedAt}}</p>
  <h1>{{.Entry.Title}}</h1>
  <div class="meta">
    {{if .Entry.People}}<span>{{join .Entry.People ", "}}</span>{{end}}
    {{if .Entry.Tags}}<span>{{join .Entry.Tags ", "}}</span>{{end}}
    <span><code>{{.Entry.SourcePath}}</code></span>
  </div>
  {{if .Entry.SubjectDetails}}
    <div class="subject-details">
      {{range .Entry.SubjectDetails}}
        <span class="chip">{{.Name}}{{if .AgeText}} <span class="muted">{{.AgeText}}</span>{{end}}</span>
      {{end}}
    </div>
  {{end}}
  {{if .Entry.Attachments}}
    <section class="media">
      <h2>Media</h2>
      <div class="media-grid">
        {{range .Entry.Attachments}}
          <figure class="media-item">
            {{if eq .Kind "image"}}
              <img src="{{webAsset .}}" alt="{{.Filename}}" loading="lazy">
            {{else if eq .Kind "video"}}
              <video src="{{webAsset .}}" controls preload="metadata"></video>
            {{else}}
              <a href="{{webAsset .}}">{{.Filename}}</a>
            {{end}}
            <figcaption class="media-caption">{{.Filename}}</figcaption>
          </figure>
        {{end}}
      </div>
    </section>
  {{end}}
  <form class="attach-form" method="post" action="/entries/{{.Entry.ID}}/attachments" enctype="multipart/form-data">
    <input type="hidden" name="csrf_token" value="{{.CSRFToken}}">
    <h2>Add Media</h2>
    <input type="file" name="media" multiple accept="image/*,video/*,.pdf,.txt,.md,.markdown">
    <button class="primary" type="submit">Attach</button>
  </form>
  <div class="body rendered-markdown">{{.BodyHTML}}</div>
  <details style="margin-top:24px;">
    <summary class="muted">Raw Markdown</summary>
    <pre style="white-space:pre-wrap; overflow:auto;"><code>{{.RawBody}}</code></pre>
  </details>
</article>
{{template "layoutEnd" .}}
{{end}}

{{define "share"}}
{{template "layoutStart" .}}
<article class="detail">
  <p class="muted">{{date .Entry.CreatedAt}}</p>
  <h1>{{.Entry.Title}}</h1>
  <div class="meta">
    {{if .Entry.People}}<span>{{join .Entry.People ", "}}</span>{{end}}
    {{if .Entry.Tags}}<span>{{join .Entry.Tags ", "}}</span>{{end}}
  </div>
  {{if .Entry.SubjectDetails}}
    <div class="subject-details">
      {{range .Entry.SubjectDetails}}
        <span class="chip">{{.Name}}{{if .AgeText}} <span class="muted">{{.AgeText}}</span>{{end}}</span>
      {{end}}
    </div>
  {{end}}
  {{if .Entry.Attachments}}
    <section class="media">
      <div class="media-grid">
        {{range .Entry.Attachments}}
          <figure class="media-item">
            {{if eq .Kind "image"}}
              <img src="{{webAsset .}}" alt="{{.Filename}}" loading="lazy">
            {{else if eq .Kind "video"}}
              <video src="{{webAsset .}}" controls preload="metadata"></video>
            {{else}}
              <a href="{{webAsset .}}">{{.Filename}}</a>
            {{end}}
            <figcaption class="media-caption">{{.Filename}}</figcaption>
          </figure>
        {{end}}
      </div>
    </section>
  {{end}}
  <div class="body rendered-markdown">{{.BodyHTML}}</div>
  <p class="muted" style="margin-top:32px;">Shared from Diary · read-only</p>
</article>
{{template "layoutEnd" .}}
{{end}}
`
