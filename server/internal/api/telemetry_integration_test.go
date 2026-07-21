package api

import (
	"bytes"
	"context"
	"encoding/json"
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
	"github.com/jakobevangelista/runsync/server/internal/telemetry"
)

func TestTelemetryValidationAndLaterIsolatedBatch(t *testing.T) {
	databaseURL := os.Getenv("RUNSYNC_TEST_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("RUNSYNC_TEST_DATABASE_URL not set")
	}
	ctx := context.Background()
	pool, err := database.Open(ctx, databaseURL, 4)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	if err := database.Migrate(ctx, pool); err != nil {
		t.Fatal(err)
	}

	token, prefix, hash, err := auth.GenerateToken()
	if err != nil {
		t.Fatal(err)
	}
	suffix := uuid.New().String()[:8]
	userID, credentialID := uuid.New(), uuid.New()
	if _, err := pool.Exec(ctx, `INSERT INTO users(id,handle) VALUES($1,$2)`, userID, "telemetry-api-"+suffix); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO api_credentials(id,user_id,name,token_prefix,token_hash,scopes) VALUES($1,$2,'telemetry-api',$3,$4,ARRAY['telemetry:write'])`, credentialID, userID, prefix, hash); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		for _, query := range []string{
			`DELETE FROM telemetry_samples WHERE user_id=$1`,
			`DELETE FROM live_channels WHERE user_id=$1`,
			`DELETE FROM activities WHERE user_id=$1`,
			`DELETE FROM api_credentials WHERE user_id=$1`,
			`DELETE FROM garmin_devices WHERE user_id=$1`,
			`DELETE FROM installations WHERE user_id=$1`,
			`DELETE FROM users WHERE id=$1`,
		} {
			_, _ = pool.Exec(context.Background(), query, userID)
		}
	})

	server := httptest.NewServer(New(pool, bytes.Repeat([]byte{1}, 32), nil, nil, slog.New(slog.NewTextHandler(io.Discard, nil))).Handler())
	defer server.Close()
	post := func(value any) (*http.Response, []byte) {
		t.Helper()
		body, err := json.Marshal(value)
		if err != nil {
			t.Fatal(err)
		}
		req, err := http.NewRequest(http.MethodPost, server.URL+"/v1/telemetry/batches", bytes.NewReader(body))
		if err != nil {
			t.Fatal(err)
		}
		req.Header.Set("Authorization", "Bearer "+token)
		req.Header.Set("Content-Type", "application/json")
		response, err := server.Client().Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer response.Body.Close()
		responseBody, err := io.ReadAll(response.Body)
		if err != nil {
			t.Fatal(err)
		}
		return response, responseBody
	}

	now := time.Now().UTC().Truncate(time.Millisecond)
	installationID, activityID, deviceID := uuid.New(), uuid.New(), uuid.New()
	invalidID := uuid.New()
	heartRate := 301
	invalid := telemetry.Envelope{EnvelopeID: invalidID, ActivityID: activityID, PhoneReceivedAt: now, GarminDeviceIdentifier: deviceID, AppVersion: "api-test", Sample: telemetry.Sample{ProtocolVersion: 1, State: 1, HeartRateBPM: &heartRate}}
	response, body := post(telemetry.Batch{InstallationID: installationID, Envelopes: []telemetry.Envelope{invalid}})
	apiError := decodeTestError(t, body)
	if response.StatusCode != http.StatusUnprocessableEntity || apiError.Error.Code != "invalid_envelope" || apiError.Error.Message == "" || apiError.Error.EnvelopeID == nil || *apiError.Error.EnvelopeID != invalidID || apiError.Error.Retryable {
		t.Fatalf("invalid envelope: status=%d error=%#v", response.StatusCode, apiError.Error)
	}

	unsupported := invalid
	unsupported.EnvelopeID = uuid.New()
	unsupported.Sample.HeartRateBPM = nil
	unsupported.Sample.ProtocolVersion = 2
	response, body = post(telemetry.Batch{InstallationID: installationID, Envelopes: []telemetry.Envelope{unsupported}})
	apiError = decodeTestError(t, body)
	if response.StatusCode != http.StatusUnprocessableEntity || apiError.Error.Code != "unsupported_protocol" || apiError.Error.Message == "" || apiError.Error.EnvelopeID != nil || apiError.Error.Retryable {
		t.Fatalf("unsupported protocol: status=%d error=%#v", response.StatusCode, apiError.Error)
	}

	validID := uuid.New()
	valid := invalid
	valid.EnvelopeID = validID
	valid.Sample.HeartRateBPM = nil
	response, body = post(telemetry.Batch{InstallationID: installationID, Envelopes: []telemetry.Envelope{valid}})
	if response.StatusCode != http.StatusOK {
		t.Fatalf("valid isolated batch: status=%d body=%s", response.StatusCode, body)
	}
	var acknowledgement struct {
		EnvelopeIDs []uuid.UUID `json:"acknowledgedEnvelopeIds"`
	}
	if err := json.Unmarshal(body, &acknowledgement); err != nil || len(acknowledgement.EnvelopeIDs) != 1 || acknowledgement.EnvelopeIDs[0] != validID {
		t.Fatalf("acknowledgement=%#v err=%v body=%s", acknowledgement, err, body)
	}
	var count int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM telemetry_samples WHERE user_id=$1`, userID).Scan(&count); err != nil || count != 1 {
		t.Fatalf("stored samples=%d err=%v", count, err)
	}
}
