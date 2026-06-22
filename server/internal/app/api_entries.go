package app

import (
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"diary/server/internal/diary"
)

type entryWriteRequest struct {
	Date                   string   `json:"date"`
	CreatedAt              string   `json:"created_at"`
	ExpectedServerRevision string   `json:"expected_server_revision"`
	Title                  string   `json:"title"`
	BodyMarkdown           string   `json:"body_markdown"`
	People                 []string `json:"people"`
	Tags                   []string `json:"tags"`
}

func (s *Server) handleCreateEntryAPI(w http.ResponseWriter, r *http.Request) {
	req, err := decodeEntryWriteRequest(r)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	createdAt, err := parseEntryDate(req)
	if err != nil {
		writeError(w, http.StatusBadRequest, "date or created_at is required")
		return
	}

	entry, err := diary.CreateEntry(s.cfg.VaultDir, diary.CreateEntryInput{
		CreatedAt:    createdAt,
		Title:        strings.TrimSpace(req.Title),
		BodyMarkdown: req.BodyMarkdown,
		People:       req.People,
		Tags:         req.Tags,
		Now:          time.Now().UTC(),
	})
	if err != nil {
		writeError(w, http.StatusBadRequest, publicMessage(err))
		return
	}
	if err := s.Reindex(); err != nil {
		writeError(w, http.StatusInternalServerError, publicMessage(err))
		return
	}

	entry, _ = s.store.Entry(entry.ID)
	writeJSON(w, http.StatusCreated, map[string]any{"entry": entry})
}

func (s *Server) handleUpdateEntryAPI(w http.ResponseWriter, r *http.Request) {
	entry, err := s.store.Entry(r.PathValue("id"))
	if err != nil {
		writeError(w, http.StatusNotFound, "entry not found")
		return
	}

	req, err := decodeEntryWriteRequest(r)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	createdAt, err := parseEntryDate(req)
	if err != nil {
		writeError(w, http.StatusBadRequest, "date or created_at is required")
		return
	}

	if req.ExpectedServerRevision != "" && req.ExpectedServerRevision != entry.ServerRevision {
		writeJSON(w, http.StatusConflict, map[string]any{
			"error": "entry has changed on the server",
			"entry": entry,
		})
		return
	}

	updated, err := diary.UpdateEntry(s.cfg.VaultDir, entry, diary.UpdateEntryInput{
		CreatedAt:    createdAt,
		Title:        strings.TrimSpace(req.Title),
		BodyMarkdown: req.BodyMarkdown,
		People:       req.People,
		Tags:         req.Tags,
		Now:          time.Now().UTC(),
	})
	if err != nil {
		writeError(w, http.StatusBadRequest, publicMessage(err))
		return
	}
	if err := s.Reindex(); err != nil {
		writeError(w, http.StatusInternalServerError, publicMessage(err))
		return
	}

	updated, _ = s.store.Entry(updated.ID)
	writeJSON(w, http.StatusOK, map[string]any{"entry": updated})
}

func (s *Server) handleTrashEntryAPI(w http.ResponseWriter, r *http.Request) {
	entryID := r.PathValue("id")
	entry, err := s.store.Entry(entryID)
	if err != nil {
		writeError(w, http.StatusNotFound, "entry not found")
		return
	}

	tombstone, err := diary.TrashEntry(s.cfg.VaultDir, entry, time.Now().UTC())
	if err != nil {
		writeError(w, http.StatusInternalServerError, publicMessage(err))
		return
	}
	if err := s.Reindex(); err != nil {
		writeError(w, http.StatusInternalServerError, publicMessage(err))
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"deleted_entry_id": entryID,
		"deleted_at":       tombstone.DeletedAt,
		"trash_path":       tombstone.TrashPath,
	})
}

func (s *Server) handleAttachMediaAPI(w http.ResponseWriter, r *http.Request) {
	entryID := r.PathValue("id")
	entry, err := s.store.Entry(entryID)
	if err != nil {
		writeError(w, http.StatusNotFound, "entry not found")
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, 512<<20)
	file, header, err := r.FormFile("media")
	if err != nil {
		writeError(w, http.StatusBadRequest, "media file is required")
		return
	}
	defer file.Close()

	updated, attachment, err := diary.AttachFile(s.cfg.VaultDir, entry, header.Filename, header.Header.Get("Content-Type"), file, time.Now().UTC())
	if err != nil {
		writeError(w, http.StatusBadRequest, publicMessage(err))
		return
	}
	if err := s.Reindex(); err != nil {
		writeError(w, http.StatusInternalServerError, publicMessage(err))
		return
	}

	updated, _ = s.store.Entry(updated.ID)
	writeJSON(w, http.StatusCreated, map[string]any{
		"attachment": attachment,
		"entry":      updated,
	})
}

func (s *Server) handleRemoveMediaAPI(w http.ResponseWriter, r *http.Request) {
	entry, err := s.store.Entry(r.PathValue("id"))
	if err != nil {
		writeError(w, http.StatusNotFound, "entry not found")
		return
	}

	updated, attachment, err := diary.RemoveAttachment(s.cfg.VaultDir, entry, r.PathValue("attachment_id"), time.Now().UTC())
	if err != nil {
		writeError(w, http.StatusBadRequest, publicMessage(err))
		return
	}
	if err := s.Reindex(); err != nil {
		writeError(w, http.StatusInternalServerError, publicMessage(err))
		return
	}

	updated, _ = s.store.Entry(updated.ID)
	writeJSON(w, http.StatusOK, map[string]any{
		"removed_attachment": attachment,
		"entry":              updated,
	})
}

func decodeEntryWriteRequest(r *http.Request) (entryWriteRequest, error) {
	var req entryWriteRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		return entryWriteRequest{}, err
	}
	req.Title = strings.TrimSpace(req.Title)
	req.BodyMarkdown = strings.TrimSpace(req.BodyMarkdown)
	req.People = cleanStringList(req.People)
	req.Tags = cleanStringList(req.Tags)
	return req, nil
}

func parseEntryDate(req entryWriteRequest) (time.Time, error) {
	if strings.TrimSpace(req.CreatedAt) != "" {
		if parsed, err := time.Parse(time.RFC3339Nano, strings.TrimSpace(req.CreatedAt)); err == nil {
			return parsed.UTC(), nil
		}
	}
	if strings.TrimSpace(req.Date) != "" {
		return time.ParseInLocation("2006-01-02", strings.TrimSpace(req.Date), time.Local)
	}
	return time.Time{}, http.ErrMissingFile
}

func cleanStringList(values []string) []string {
	out := make([]string, 0, len(values))
	seen := map[string]bool{}
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value == "" || seen[value] {
			continue
		}
		seen[value] = true
		out = append(out, value)
	}
	return out
}
