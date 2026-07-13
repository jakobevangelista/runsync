package api

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jakobevangelista/runsync/server/internal/auth"
	"github.com/jakobevangelista/runsync/server/internal/database"
)

func TestStreamClosesWhenViewerTokenExpires(t *testing.T) {
	databaseURL := os.Getenv("RUNSYNC_TEST_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("RUNSYNC_TEST_DATABASE_URL not set")
	}
	ctx := context.Background()
	pool, err := database.Open(ctx, databaseURL, 2)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	if err := database.Migrate(ctx, pool); err != nil {
		t.Fatal(err)
	}
	userID, channelID := uuid.New(), uuid.New()
	slug := fmt.Sprintf("stream-%s", uuid.New().String()[:8])
	if _, err := pool.Exec(ctx, `INSERT INTO users(id,handle) VALUES($1,$2)`, userID, slug); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO live_channels(id,user_id,slug,display_name,location_policy) VALUES($1,$2,$3,'Stream test','hidden')`, channelID, userID, slug); err != nil {
		t.Fatal(err)
	}
	defer pool.Exec(ctx, `DELETE FROM users WHERE id=$1`, userID)            //nolint:errcheck
	defer pool.Exec(ctx, `DELETE FROM live_channels WHERE id=$1`, channelID) //nolint:errcheck

	key := bytes.Repeat([]byte{1}, 32)
	now := time.Now()
	claims := auth.ViewerClaims{ChannelID: channelID, UserID: userID, Slug: slug, Policy: "hidden", IssuedAt: now.Unix(), ExpiresAt: now.Add(2 * time.Second).Unix(), Scope: "channel:live"}
	token, err := auth.SignViewer(key, claims)
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(New(pool, key, nil, nil, slog.New(slog.NewTextHandler(io.Discard, nil))).Handler())
	defer server.Close()
	req, err := http.NewRequest(http.MethodGet, server.URL+"/v1/channels/"+slug+"/stream", nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer "+token)
	started := time.Now()
	response, err := server.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = response.Body.Close() }()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("status=%d", response.StatusCode)
	}
	if _, err := io.Copy(io.Discard, response.Body); err != nil {
		t.Fatal(err)
	}
	elapsed := time.Since(started)
	if elapsed < 500*time.Millisecond || elapsed > 3*time.Second {
		t.Fatalf("stream closed after %s", elapsed)
	}
}
