package ingest

import (
	"context"
	"errors"
	"os"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jakobevangelista/runsync/server/internal/auth"
	"github.com/jakobevangelista/runsync/server/internal/database"
	"github.com/jakobevangelista/runsync/server/internal/telemetry"
)

func TestStoreRejectionClassificationAndIsolation(t *testing.T) {
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

	suffix := uuid.New().String()[:8]
	userID, foreignUserID := uuid.New(), uuid.New()
	credentialID := uuid.New()
	installationID, foreignInstallationID := uuid.New(), uuid.New()
	foreignDeviceID, foreignActivityID := uuid.New(), uuid.New()
	now := time.Now().UTC().Truncate(time.Millisecond)
	mustExec := func(query string, arguments ...any) {
		t.Helper()
		if _, err := pool.Exec(ctx, query, arguments...); err != nil {
			t.Fatal(err)
		}
	}
	mustExec(`INSERT INTO users(id,handle) VALUES($1,$2),($3,$4)`, userID, "rejection-"+suffix, foreignUserID, "foreign-"+suffix)
	mustExec(`INSERT INTO installations(id,user_id,first_seen_at,last_seen_at) VALUES($1,$2,$5,$5),($3,$4,$5,$5)`, installationID, userID, foreignInstallationID, foreignUserID, now)
	mustExec(`INSERT INTO api_credentials(id,user_id,installation_id,name,token_prefix,token_hash,scopes) VALUES($1,$2,$3,'rejection',$4,decode(repeat('00',32),'hex'),ARRAY['telemetry:write'])`, credentialID, userID, installationID, "rs_rej_"+suffix)
	mustExec(`INSERT INTO garmin_devices(id,user_id,garmin_identifier,first_seen_at,last_seen_at) VALUES($1,$2,$3,$4,$4)`, foreignDeviceID, foreignUserID, uuid.New(), now)
	mustExec(`INSERT INTO activities(id,user_id,installation_id,garmin_device_id,first_phone_received_at,last_phone_received_at,first_server_received_at,last_server_received_at,current_state,created_at,updated_at) VALUES($1,$2,$3,$4,$5,$5,$5,$5,1,$5,$5)`, foreignActivityID, foreignUserID, foreignInstallationID, foreignDeviceID, now)
	t.Cleanup(func() {
		for _, query := range []string{
			`DELETE FROM telemetry_samples WHERE user_id IN ($1,$2)`,
			`DELETE FROM live_channels WHERE user_id IN ($1,$2)`,
			`DELETE FROM activities WHERE user_id IN ($1,$2)`,
			`DELETE FROM api_credentials WHERE user_id IN ($1,$2)`,
			`DELETE FROM garmin_devices WHERE user_id IN ($1,$2)`,
			`DELETE FROM installations WHERE user_id IN ($1,$2)`,
			`DELETE FROM users WHERE id IN ($1,$2)`,
		} {
			_, _ = pool.Exec(context.Background(), query, userID, foreignUserID)
		}
	})

	principal := auth.Principal{CredentialID: credentialID, UserID: userID, InstallationID: &installationID, Scopes: map[string]bool{"telemetry:write": true}}
	deviceID, activityID := uuid.New(), uuid.New()
	makeEnvelope := func(envelopeID, activity uuid.UUID, sequence int) telemetry.Envelope {
		return telemetry.Envelope{
			EnvelopeID:             envelopeID,
			ActivityID:             activity,
			PhoneReceivedAt:        now.Add(time.Duration(sequence) * time.Millisecond),
			GarminDeviceIdentifier: deviceID,
			AppVersion:             "rejection-test",
			Sample:                 telemetry.Sample{ProtocolVersion: 1, Sequence: sequence, State: 1},
		}
	}
	assertRejection := func(err error, code RejectionCode, envelopeID *uuid.UUID) {
		t.Helper()
		var rejection *RejectionError
		if !errors.As(err, &rejection) {
			t.Fatalf("error = %v, want RejectionError", err)
		}
		if rejection.Code != code {
			t.Fatalf("code = %q, want %q", rejection.Code, code)
		}
		if envelopeID == nil {
			if rejection.EnvelopeID != nil {
				t.Fatalf("envelope ID = %v, want nil", rejection.EnvelopeID)
			}
		} else if rejection.EnvelopeID == nil || *rejection.EnvelopeID != *envelopeID {
			t.Fatalf("envelope ID = %v, want %s", rejection.EnvelopeID, *envelopeID)
		}
	}

	store := New(pool)
	_, err = store.Ingest(ctx, principal, telemetry.Batch{InstallationID: foreignInstallationID, Envelopes: []telemetry.Envelope{makeEnvelope(uuid.New(), activityID, 1)}}, now)
	assertRejection(err, CodeInstallationOwnershipConflict, nil)

	validID, rejectedID := uuid.New(), uuid.New()
	valid := makeEnvelope(validID, activityID, 2)
	rejected := makeEnvelope(rejectedID, foreignActivityID, 3)
	_, err = store.Ingest(ctx, principal, telemetry.Batch{InstallationID: installationID, Envelopes: []telemetry.Envelope{valid, rejected}}, now)
	assertRejection(err, CodeEnvelopeOwnershipConflict, &rejectedID)
	var count int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM telemetry_samples WHERE envelope_id=$1`, validID).Scan(&count); err != nil || count != 0 {
		t.Fatalf("rejected batch was not atomic: count=%d err=%v", count, err)
	}

	result, err := store.Ingest(ctx, principal, telemetry.Batch{InstallationID: installationID, Envelopes: []telemetry.Envelope{valid}}, now)
	if err != nil || len(result.Acknowledged) != 1 || result.Acknowledged[0] != validID {
		t.Fatalf("later isolated valid batch: result=%#v err=%v", result, err)
	}

	conflict := valid
	conflict.Sample.Sequence++
	_, err = store.Ingest(ctx, principal, telemetry.Batch{InstallationID: installationID, Envelopes: []telemetry.Envelope{conflict}}, now)
	assertRejection(err, CodeEnvelopeConflict, &validID)
	if !errors.Is(err, ErrConflict) {
		t.Fatalf("conflict does not unwrap to ErrConflict: %v", err)
	}

	missingCredential := principal
	missingCredential.CredentialID = uuid.New()
	missingCredential.InstallationID = nil
	databaseFailureBatch := telemetry.Batch{InstallationID: uuid.New(), Envelopes: []telemetry.Envelope{makeEnvelope(uuid.New(), uuid.New(), 4)}}
	_, err = store.Ingest(ctx, missingCredential, databaseFailureBatch, now)
	if !errors.Is(err, pgx.ErrNoRows) {
		t.Fatalf("database error = %v, want pgx.ErrNoRows", err)
	}
	var rejection *RejectionError
	if errors.As(err, &rejection) {
		t.Fatalf("database error was misclassified as %s", rejection.Code)
	}
}
