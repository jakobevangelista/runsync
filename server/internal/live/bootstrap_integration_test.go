package live

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jakobevangelista/runsync/server/internal/database"
)

func TestBootstrapRepeatableReadFencesConcurrentCommit(t *testing.T) {
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
	firstEnvelope, secondEnvelope := uuid.New(), uuid.New()
	now := time.Now().UTC().Truncate(time.Millisecond)
	mustExec := func(query string, args ...any) {
		t.Helper()
		if _, err := pool.Exec(ctx, query, args...); err != nil {
			t.Fatal(err)
		}
	}
	mustExec(`INSERT INTO users(id,handle) VALUES($1,$2)`, user, "bootstrap-"+suffix)
	t.Cleanup(func() {
		_, _ = pool.Exec(context.Background(), `DELETE FROM telemetry_samples WHERE user_id=$1; DELETE FROM live_channels WHERE user_id=$1; DELETE FROM activities WHERE user_id=$1; DELETE FROM garmin_devices WHERE user_id=$1; DELETE FROM installations WHERE user_id=$1; DELETE FROM users WHERE id=$1`, user)
	})
	mustExec(`INSERT INTO installations(id,user_id,first_seen_at,last_seen_at,app_version) VALUES($1,$2,$3,$3,'test')`, installation, user, now)
	mustExec(`INSERT INTO garmin_devices(id,user_id,garmin_identifier,first_seen_at,last_seen_at) VALUES($1,$2,$3,$4,$4)`, device, user, uuid.New(), now)
	mustExec(`INSERT INTO activities(id,user_id,installation_id,garmin_device_id,first_phone_received_at,last_phone_received_at,first_server_received_at,last_server_received_at,current_state,latest_ingest_cursor,sample_count) VALUES($1,$2,$3,$4,$5,$5,$5,$5,1,1,1)`, activity, user, installation, device, now)
	mustExec(`INSERT INTO live_channels(id,user_id,slug,display_name,active_activity_id,location_policy) VALUES($1,$2,$3,'Bootstrap',$4,'precise')`, channelID, user, "bootstrap-"+suffix, activity)
	insertSample := func(envelope uuid.UUID, cursor int64) {
		t.Helper()
		mustExec(`INSERT INTO telemetry_samples(envelope_id,activity_id,user_id,phone_received_at,server_received_at,ingest_cursor,app_version,protocol_version,watch_sequence,activity_state,latitude_microdegrees,longitude_microdegrees) VALUES($1,$2,$3,$4,$4,$5,'test',1,$6,1,37774921,-122419381)`, envelope, activity, user, now, cursor, int(cursor))
	}
	insertSample(firstEnvelope, 1)

	tx, err := pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	var visibleChannel uuid.UUID
	if err := tx.QueryRow(ctx, `SELECT id FROM live_channels WHERE id=$1`, channelID).Scan(&visibleChannel); err != nil {
		t.Fatal(err)
	}
	insertSample(secondEnvelope, 2)

	requested := Channel{ID: channelID, UserID: user, Slug: "bootstrap-" + suffix, Policy: "precise", ActivityID: &activity}
	duringCommit, err := bootstrapTx(ctx, tx, requested, now.Add(time.Second))
	if err != nil {
		t.Fatal(err)
	}
	if duringCommit.ReplayAfterEnvelopeID == nil || *duringCommit.ReplayAfterEnvelopeID != firstEnvelope || len(duringCommit.Route.Points) != 1 {
		t.Fatalf("repeatable-read bootstrap=%#v", duringCommit)
	}
	if err := tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}

	afterCommit, err := NewStore(pool).Bootstrap(ctx, requested, now.Add(2*time.Second))
	if err != nil {
		t.Fatal(err)
	}
	if afterCommit.ReplayAfterEnvelopeID == nil || *afterCommit.ReplayAfterEnvelopeID != secondEnvelope || afterCommit.Snapshot.Latest == nil || afterCommit.Snapshot.Latest.EnvelopeID != secondEnvelope || len(afterCommit.Route.Points) != 2 {
		t.Fatalf("post-commit bootstrap=%#v", afterCommit)
	}
	wantFirst, wantSecond := firstEnvelope, secondEnvelope
	if wantFirst.String() > wantSecond.String() {
		wantFirst, wantSecond = wantSecond, wantFirst
	}
	if afterCommit.Route.Points[0].EnvelopeID != wantFirst || afterCommit.Route.Points[1].EnvelopeID != wantSecond {
		t.Fatalf("equal-time route order=%v", afterCommit.Route.Points)
	}
}
