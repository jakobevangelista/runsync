package api

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jakobevangelista/runsync/server/internal/auth"
	"github.com/jakobevangelista/runsync/server/internal/database"
	"github.com/jakobevangelista/runsync/server/internal/live"
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

func TestReplayResetClosesAndBootstrapAdvancesHighWater(t *testing.T) {
	databaseURL := os.Getenv("RUNSYNC_TEST_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("RUNSYNC_TEST_DATABASE_URL not set")
	}
	ctx := context.Background()
	pool, err := database.Open(ctx, databaseURL, 4)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	if err := database.Migrate(ctx, pool); err != nil {
		t.Fatal(err)
	}

	suffix := uuid.New().String()[:8]
	user, installation, device := uuid.New(), uuid.New(), uuid.New()
	activity, channelID := uuid.New(), uuid.New()
	slug := "reset-" + suffix
	now := time.Now().UTC().Truncate(time.Millisecond)
	mustExec := func(query string, args ...any) {
		t.Helper()
		if _, err := pool.Exec(ctx, query, args...); err != nil {
			t.Fatal(err)
		}
	}
	mustExec(`INSERT INTO users(id,handle) VALUES($1,$2)`, user, slug)
	t.Cleanup(func() {
		_, _ = pool.Exec(context.Background(), `DELETE FROM telemetry_samples WHERE user_id=$1; DELETE FROM live_channels WHERE user_id=$1; DELETE FROM activities WHERE user_id=$1; DELETE FROM garmin_devices WHERE user_id=$1; DELETE FROM installations WHERE user_id=$1; DELETE FROM users WHERE id=$1`, user)
	})
	mustExec(`INSERT INTO installations(id,user_id,first_seen_at,last_seen_at,app_version) VALUES($1,$2,$3,$3,'test')`, installation, user, now)
	mustExec(`INSERT INTO garmin_devices(id,user_id,garmin_identifier,first_seen_at,last_seen_at) VALUES($1,$2,$3,$4,$4)`, device, user, uuid.New(), now)
	mustExec(`INSERT INTO activities(id,user_id,installation_id,garmin_device_id,first_phone_received_at,last_phone_received_at,first_server_received_at,last_server_received_at,current_state,latest_ingest_cursor,sample_count) VALUES($1,$2,$3,$4,$5,$6,$5,$6,1,202,202)`, activity, user, installation, device, now, now.Add(202*time.Second))
	mustExec(`INSERT INTO live_channels(id,user_id,slug,display_name,active_activity_id,location_policy) VALUES($1,$2,$3,'Reset',$4,'hidden')`, channelID, user, slug, activity)
	mustExec(`INSERT INTO telemetry_samples(envelope_id,activity_id,user_id,phone_received_at,server_received_at,ingest_cursor,app_version,protocol_version,watch_sequence,activity_state)
		SELECT md5(($1::uuid)::text || ':' || g::text)::uuid,$1::uuid,$2::uuid,$3::timestamptz + g * interval '1 second',$3,g,'test',1,g,1 FROM generate_series(1,202) AS g`, activity, user, now)
	var firstEnvelope, highWaterEnvelope uuid.UUID
	if err := pool.QueryRow(ctx, `SELECT (SELECT envelope_id FROM telemetry_samples WHERE user_id=$1 ORDER BY ingest_cursor LIMIT 1),(SELECT envelope_id FROM telemetry_samples WHERE user_id=$1 ORDER BY ingest_cursor DESC LIMIT 1)`, user).Scan(&firstEnvelope, &highWaterEnvelope); err != nil {
		t.Fatal(err)
	}

	key := bytes.Repeat([]byte{2}, 32)
	claims := auth.ViewerClaims{ChannelID: channelID, UserID: user, Slug: slug, Policy: "hidden", IssuedAt: now.Unix(), ExpiresAt: now.Add(time.Minute).Unix(), Scope: "channel:live"}
	token, err := auth.SignViewer(key, claims)
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(New(pool, key, nil, nil, slog.New(slog.NewTextHandler(io.Discard, nil))).Handler())
	defer server.Close()

	streamRequest, err := http.NewRequest(http.MethodGet, server.URL+"/v1/channels/"+slug+"/stream", nil)
	if err != nil {
		t.Fatal(err)
	}
	streamRequest.Header.Set("Authorization", "Bearer "+token)
	streamRequest.Header.Set("Last-Event-ID", firstEnvelope.String())
	streamResponse, err := server.Client().Do(streamRequest)
	if err != nil {
		t.Fatal(err)
	}
	streamBody, err := io.ReadAll(streamResponse.Body)
	_ = streamResponse.Body.Close()
	if err != nil {
		t.Fatal(err)
	}
	if streamResponse.StatusCode != http.StatusOK || !strings.Contains(string(streamBody), "event: reset") {
		t.Fatalf("status=%d body=%s", streamResponse.StatusCode, streamBody)
	}

	bootstrapRequest, err := http.NewRequest(http.MethodGet, server.URL+"/v1/channels/"+slug+"/bootstrap", nil)
	if err != nil {
		t.Fatal(err)
	}
	bootstrapRequest.Header.Set("Authorization", "Bearer "+token)
	bootstrapResponse, err := server.Client().Do(bootstrapRequest)
	if err != nil {
		t.Fatal(err)
	}
	defer bootstrapResponse.Body.Close()
	var bootstrap live.Bootstrap
	if err := json.NewDecoder(bootstrapResponse.Body).Decode(&bootstrap); err != nil {
		t.Fatal(err)
	}
	if bootstrapResponse.StatusCode != http.StatusOK || bootstrap.ReplayAfterEnvelopeID == nil || *bootstrap.ReplayAfterEnvelopeID != highWaterEnvelope {
		t.Fatalf("status=%d bootstrap=%#v", bootstrapResponse.StatusCode, bootstrap)
	}
}
