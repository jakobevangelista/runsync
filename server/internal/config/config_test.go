package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestDatabaseURLFromFile(t *testing.T) {
	t.Setenv("RUNSYNC_DATABASE_URL", "")
	path := filepath.Join(t.TempDir(), "database-url")
	if err := os.WriteFile(path, []byte("  postgres://file-value\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("RUNSYNC_DATABASE_URL_FILE", path)

	got, err := DatabaseURL()
	if err != nil {
		t.Fatal(err)
	}
	if got != "postgres://file-value" {
		t.Fatalf("DatabaseURL() = %q", got)
	}
}

func TestDatabaseURLValueTakesPrecedenceOverFile(t *testing.T) {
	t.Setenv("RUNSYNC_DATABASE_URL", "postgres://environment-value")
	t.Setenv("RUNSYNC_DATABASE_URL_FILE", filepath.Join(t.TempDir(), "missing"))

	got, err := DatabaseURL()
	if err != nil {
		t.Fatal(err)
	}
	if got != "postgres://environment-value" {
		t.Fatalf("DatabaseURL() = %q", got)
	}
}
