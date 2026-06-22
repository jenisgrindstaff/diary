package app

import (
	"database/sql"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"

	"diary/server/internal/diary"
	"diary/server/internal/store"
)

type Server struct {
	cfg      Config
	logger   *slog.Logger
	db       *sql.DB
	store    *store.Store
	importer *diary.Importer
}

func New(cfg Config, logger *slog.Logger) (*Server, error) {
	if logger == nil {
		logger = slog.Default()
	}

	for _, dir := range []string{cfg.VaultDir, cfg.ImportDir, cfg.DataDir} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return nil, err
		}
	}
	for _, dir := range []string{
		filepath.Join(cfg.VaultDir, "entries"),
		filepath.Join(cfg.VaultDir, "assets"),
		filepath.Join(cfg.VaultDir, "deletions"),
	} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return nil, err
		}
	}

	db, err := store.Open(cfg.DBPath())
	if err != nil {
		return nil, err
	}

	st := store.New(db)
	if err := st.Migrate(); err != nil {
		_ = db.Close()
		return nil, err
	}

	importer := diary.NewImporter(cfg.VaultDir, cfg.ImportDir)
	server := &Server{
		cfg:      cfg,
		logger:   logger,
		db:       db,
		store:    st,
		importer: importer,
	}

	if err := server.Reindex(); err != nil {
		_ = db.Close()
		return nil, err
	}

	return server, nil
}

func (s *Server) Close() error {
	if s.db == nil {
		return nil
	}

	return s.db.Close()
}

func (s *Server) Reindex() error {
	entries, err := diary.ReadVault(s.cfg.VaultDir)
	if err != nil {
		return err
	}
	tombstones, err := diary.ReadTombstones(s.cfg.VaultDir)
	if err != nil {
		return err
	}

	return s.store.ReplaceIndex(entries, tombstones)
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, map[string]string{"error": message})
}

func publicMessage(err error) string {
	if err == nil {
		return ""
	}
	if errors.Is(err, os.ErrNotExist) {
		return "not found"
	}

	return err.Error()
}
