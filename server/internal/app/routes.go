package app

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"time"

	"diary/server/internal/store"
)

type authContextKey string

const deviceIDContextKey authContextKey = "device_id"

func (s *Server) Routes() http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("GET /healthz", s.handleHealth)
	mux.HandleFunc("GET /", s.handleHome)
	mux.HandleFunc("GET /entries/new", s.handleNewEntry)
	mux.HandleFunc("POST /entries", s.handleCreateEntry)
	mux.HandleFunc("GET /entries/{id}/edit", s.handleEditEntry)
	mux.HandleFunc("POST /entries/{id}", s.handleUpdateEntry)
	mux.HandleFunc("POST /entries/{id}/trash", s.handleTrashEntry)
	mux.HandleFunc("GET /entries/{id}", s.handleWebEntry)
	mux.HandleFunc("POST /entries/{id}/attachments", s.handleWebAttachMedia)
	mux.HandleFunc("GET /assets/{id}", s.handleWebAsset)
	mux.HandleFunc("POST /admin/import", s.handleWebImport)
	mux.HandleFunc("POST /admin/reindex", s.handleWebReindex)
	mux.Handle("GET /api/v1/entries", s.auth(http.HandlerFunc(s.handleEntries)))
	mux.Handle("POST /api/v1/entries", s.auth(http.HandlerFunc(s.handleCreateEntryAPI)))
	mux.Handle("GET /api/v1/entries/{id}", s.auth(http.HandlerFunc(s.handleEntry)))
	mux.Handle("PATCH /api/v1/entries/{id}", s.auth(http.HandlerFunc(s.handleUpdateEntryAPI)))
	mux.Handle("DELETE /api/v1/entries/{id}", s.auth(http.HandlerFunc(s.handleTrashEntryAPI)))
	mux.Handle("POST /api/v1/entries/{id}/attachments", s.auth(http.HandlerFunc(s.handleAttachMediaAPI)))
	mux.Handle("DELETE /api/v1/entries/{id}/attachments/{attachment_id}", s.auth(http.HandlerFunc(s.handleRemoveMediaAPI)))
	mux.Handle("GET /api/v1/search", s.auth(http.HandlerFunc(s.handleSearch)))
	mux.Handle("GET /api/v1/assets/{id}", s.auth(http.HandlerFunc(s.handleAsset)))
	mux.Handle("POST /api/v1/sync/register-device", s.auth(http.HandlerFunc(s.handleRegisterDevice)))
	mux.Handle("POST /api/v1/admin/import", s.auth(http.HandlerFunc(s.handleImport)))
	mux.Handle("POST /api/v1/admin/reindex", s.auth(http.HandlerFunc(s.handleReindex)))

	return loggingMiddleware(s.logger)(mux)
}

func (s *Server) auth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if s.cfg.APIToken == "" {
			next.ServeHTTP(w, r)
			return
		}

		token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		if token == "" {
			writeError(w, http.StatusUnauthorized, "unauthorized")
			return
		}

		if constantTimeEqual(token, s.cfg.APIToken) {
			next.ServeHTTP(w, r)
			return
		}

		device, err := s.store.DeviceByTokenHash(hashBearerToken(token))
		if err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				writeError(w, http.StatusUnauthorized, "unauthorized")
				return
			}
			writeError(w, http.StatusInternalServerError, publicMessage(err))
			return
		}
		_ = s.store.TouchDevice(device.DeviceID, time.Now().UTC())
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), deviceIDContextKey, device.DeviceID)))
	})
}

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *Server) handleEntries(w http.ResponseWriter, r *http.Request) {
	cursor := r.URL.Query().Get("updated_since")
	entries, nextCursor, err := s.store.EntriesUpdatedSince(cursor)
	if err != nil {
		writeError(w, http.StatusInternalServerError, publicMessage(err))
		return
	}
	tombstones, tombstoneCursor, err := s.store.TombstonesUpdatedSince(cursor)
	if err != nil {
		writeError(w, http.StatusInternalServerError, publicMessage(err))
		return
	}

	deletedEntryIDs := make([]string, 0, len(tombstones))
	for _, tombstone := range tombstones {
		deletedEntryIDs = append(deletedEntryIDs, tombstone.EntryID)
	}

	nextCursor = newerCursor(nextCursor, tombstoneCursor)
	if deviceID := authenticatedDeviceID(r.Context()); deviceID != "" {
		_ = s.store.UpdateDeviceSyncCursor(deviceID, nextCursor, time.Now().UTC())
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"entries":           entries,
		"deleted_entry_ids": deletedEntryIDs,
		"next_cursor":       nextCursor,
	})
}

func (s *Server) handleEntry(w http.ResponseWriter, r *http.Request) {
	entry, err := s.store.Entry(r.PathValue("id"))
	if err != nil {
		writeError(w, http.StatusNotFound, publicMessage(err))
		return
	}

	writeJSON(w, http.StatusOK, entry)
}

func (s *Server) handleSearch(w http.ResponseWriter, r *http.Request) {
	query := strings.TrimSpace(r.URL.Query().Get("q"))
	entries, err := s.store.Search(query)
	if err != nil {
		writeError(w, http.StatusBadRequest, publicMessage(err))
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"entries": entries,
		"query":   query,
	})
}

func (s *Server) handleAsset(w http.ResponseWriter, r *http.Request) {
	asset, err := s.store.Asset(r.PathValue("id"))
	if err != nil {
		writeError(w, http.StatusNotFound, publicMessage(err))
		return
	}

	http.ServeFile(w, r, asset.AbsolutePath)
}

func (s *Server) handleRegisterDevice(w http.ResponseWriter, r *http.Request) {
	var req struct {
		DeviceID    string `json:"device_id"`
		DisplayName string `json:"display_name"`
		Platform    string `json:"platform"`
		AppVersion  string `json:"app_version"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json")
		return
	}
	if strings.TrimSpace(req.DeviceID) == "" {
		writeError(w, http.StatusBadRequest, "device_id is required")
		return
	}

	deviceToken, err := randomBearerToken()
	if err != nil {
		writeError(w, http.StatusInternalServerError, publicMessage(err))
		return
	}
	now := time.Now().UTC()
	device, err := s.store.RegisterDevice(store.SyncDevice{
		DeviceID:    strings.TrimSpace(req.DeviceID),
		DisplayName: strings.TrimSpace(req.DisplayName),
		Platform:    strings.TrimSpace(req.Platform),
		AppVersion:  strings.TrimSpace(req.AppVersion),
	}, hashBearerToken(deviceToken), now)
	if err != nil {
		writeError(w, http.StatusInternalServerError, publicMessage(err))
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"device":       device,
		"device_token": deviceToken,
		"accepted_at":  now.Format(time.RFC3339Nano),
	})
}

func (s *Server) handleImport(w http.ResponseWriter, r *http.Request) {
	var req struct {
		SourceDir string `json:"source_dir"`
	}
	_ = json.NewDecoder(r.Body).Decode(&req)
	if strings.TrimSpace(req.SourceDir) == "" {
		req.SourceDir = s.cfg.ImportDir
	}

	result, err := s.importer.Import(req.SourceDir)
	if err != nil {
		writeError(w, http.StatusInternalServerError, publicMessage(err))
		return
	}

	if err := s.Reindex(); err != nil {
		writeError(w, http.StatusInternalServerError, publicMessage(err))
		return
	}

	writeJSON(w, http.StatusOK, result)
}

func (s *Server) handleReindex(w http.ResponseWriter, r *http.Request) {
	if err := s.Reindex(); err != nil {
		writeError(w, http.StatusInternalServerError, publicMessage(err))
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "reindexed"})
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func newerCursor(a string, b string) string {
	if b == "" {
		return a
	}
	if a == "" {
		return b
	}
	at, aErr := time.Parse(time.RFC3339Nano, a)
	bt, bErr := time.Parse(time.RFC3339Nano, b)
	if aErr != nil || bErr != nil {
		if b > a {
			return b
		}
		return a
	}
	if bt.After(at) {
		return b
	}
	return a
}

func authenticatedDeviceID(ctx context.Context) string {
	deviceID, _ := ctx.Value(deviceIDContextKey).(string)
	return deviceID
}

func randomBearerToken() (string, error) {
	var data [32]byte
	if _, err := io.ReadFull(rand.Reader, data[:]); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(data[:]), nil
}

func hashBearerToken(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

func constantTimeEqual(a string, b string) bool {
	return subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1
}
