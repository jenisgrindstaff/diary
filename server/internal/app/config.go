package app

import (
	"os"
	"path/filepath"
)

type Config struct {
	Addr      string
	VaultDir  string
	ImportDir string
	DataDir   string
	APIToken  string
}

func ConfigFromEnv() Config {
	return Config{
		Addr:      env("DIARY_ADDR", ":8080"),
		VaultDir:  env("DIARY_VAULT_DIR", "/vault"),
		ImportDir: env("DIARY_IMPORT_DIR", "/imports"),
		DataDir:   env("DIARY_DATA_DIR", "/data"),
		APIToken:  os.Getenv("DIARY_API_TOKEN"),
	}
}

func (c Config) DBPath() string {
	return filepath.Join(c.DataDir, "diary.sqlite")
}

func env(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}

	return fallback
}
