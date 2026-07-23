package ingest

import (
	"context"
	"errors"
	"os"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jakobevangelista/runsync/server/internal/auth"
	"github.com/jakobevangelista/runsync/server/internal/database"
	"github.com/jakobevangelista/runsync/server/internal/live"
	"github.com/jakobevangelista/runsync/server/internal/telemetry"
)

func TestIdempotencyConflictAndSequenceSemantics(t *testing.T) {
	url := os.Getenv("RUNSYNC_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("RUNSYNC_TEST_DATABASE_URL not set")
	}
	ctx := context.Background()
	pool, err := database.Open(ctx, url, 4)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	if err = database.Migrate(ctx, pool); err != nil {
		t.Fatal(err)
	}
	_, err = pool.Exec(ctx, `TRUNCATE telemetry_samples,live_channels,activities,api_credentials,garmin_devices,installations,users CASCADE`)
	if err != nil {
		t.Fatal(err)
	}
	user, credential := uuid.New(), uuid.New()
	_, err = pool.Exec(ctx, `INSERT INTO users(id,handle) VALUES($1,'integration')`, user)
	if err == nil {
		_, err = pool.Exec(ctx, `INSERT INTO api_credentials(id,user_id,name,token_prefix,token_hash,scopes) VALUES($1,$2,'test','rs_testpref',decode(repeat('00',32),'hex'),ARRAY['telemetry:write'])`, credential, user)
	}
	channelID := uuid.New()
	if err == nil {
		_, err = pool.Exec(ctx, `INSERT INTO live_channels(id,user_id,slug,display_name,location_policy) VALUES($1,$2,'integration-live','Live','hidden')`, channelID, user)
	}
	if err != nil {
		t.Fatal(err)
	}
	p := auth.Principal{CredentialID: credential, UserID: user, Scopes: map[string]bool{"telemetry:write": true}}
	now := time.Now().UTC().Truncate(time.Millisecond)
	installation, activity, device := uuid.New(), uuid.New(), uuid.New()
	makeEnvelope := func(id uuid.UUID, sequence int) telemetry.Envelope {
		return telemetry.Envelope{EnvelopeID: id, ActivityID: activity, GarminDeviceIdentifier: device, PhoneReceivedAt: now.Add(time.Duration(sequence) * time.Second), AppVersion: "1.0", Sample: telemetry.Sample{ProtocolVersion: 1, Sequence: sequence, State: 1}}
	}
	id := uuid.New()
	batch := telemetry.Batch{InstallationID: installation, Envelopes: []telemetry.Envelope{makeEnvelope(id, 5)}}
	build := "e4764923abcd"
	timeouts, errorsCount, exceptions, failures := 1, 2, 3, 4
	outcome := int16(3)
	batch.Envelopes[0].Sample.WatchBuildID = &build
	batch.Envelopes[0].Sample.TransportTimeoutCount = &timeouts
	batch.Envelopes[0].Sample.TransportErrorCount = &errorsCount
	batch.Envelopes[0].Sample.TransportExceptionCount = &exceptions
	batch.Envelopes[0].Sample.TransportConsecutiveFailures = &failures
	batch.Envelopes[0].Sample.TransportLastOutcome = &outcome
	store := New(pool)
	firstResult, err := store.Ingest(ctx, p, batch, now)
	if err != nil || len(firstResult.Events) != 1 {
		t.Fatalf("first: %#v %v", firstResult, err)
	}
	var storedBuild *string
	var storedTimeouts, storedErrors, storedExceptions, storedFailures *int
	var storedOutcome *int16
	if err = pool.QueryRow(ctx, `SELECT watch_build_id,transport_timeout_count,transport_error_count,transport_exception_count,transport_consecutive_failures,transport_last_outcome FROM telemetry_samples WHERE envelope_id=$1`, id).Scan(&storedBuild, &storedTimeouts, &storedErrors, &storedExceptions, &storedFailures, &storedOutcome); err != nil {
		t.Fatal(err)
	}
	if storedBuild == nil || *storedBuild != build || storedTimeouts == nil || *storedTimeouts != timeouts || storedErrors == nil || *storedErrors != errorsCount || storedExceptions == nil || *storedExceptions != exceptions || storedFailures == nil || *storedFailures != failures || storedOutcome == nil || *storedOutcome != outcome {
		t.Fatalf("stored diagnostics = build:%v timeouts:%v errors:%v exceptions:%v failures:%v outcome:%v", storedBuild, storedTimeouts, storedErrors, storedExceptions, storedFailures, storedOutcome)
	}
	second, err := store.Ingest(ctx, p, batch, now.Add(time.Second))
	if err != nil || len(second.Events) != 0 || len(second.Acknowledged) != 1 {
		t.Fatalf("retry: %#v %v", second, err)
	}
	diagnosticConflict := batch
	changedTimeouts := timeouts + 1
	diagnosticConflict.Envelopes[0].Sample.TransportTimeoutCount = &changedTimeouts
	if _, err = store.Ingest(ctx, p, diagnosticConflict, now); !errors.Is(err, ErrConflict) {
		t.Fatalf("diagnostic conflict: %v", err)
	}
	conflict := batch
	conflict.Envelopes = []telemetry.Envelope{makeEnvelope(id, 99)}
	if _, err = store.Ingest(ctx, p, conflict, now); !errors.Is(err, ErrConflict) {
		t.Fatalf("conflict: %v", err)
	}
	outOfOrder := telemetry.Batch{InstallationID: installation, Envelopes: []telemetry.Envelope{makeEnvelope(uuid.New(), 5), makeEnvelope(uuid.New(), 1)}}
	outOfOrderResult, err := store.Ingest(ctx, p, outOfOrder, now)
	if err != nil {
		t.Fatal(err)
	}
	if len(outOfOrderResult.Transitions) != 0 {
		t.Fatal("ordinary samples produced an activity transition")
	}
	var count int
	if err = pool.QueryRow(ctx, `SELECT sample_count FROM activities WHERE id=$1`, activity).Scan(&count); err != nil || count != 3 {
		t.Fatalf("count=%d err=%v", count, err)
	}
	var firstReceived time.Time
	if err = pool.QueryRow(ctx, `SELECT first_phone_received_at FROM activities WHERE id=$1`, activity).Scan(&firstReceived); err != nil || !firstReceived.Equal(now.Add(time.Second)) {
		t.Fatalf("first_phone_received_at=%s err=%v", firstReceived, err)
	}
	concurrent := telemetry.Batch{InstallationID: installation, Envelopes: []telemetry.Envelope{makeEnvelope(uuid.New(), 6)}}
	var wg sync.WaitGroup
	errs := make(chan error, 2)
	eventCounts := make(chan int, 2)
	for range 2 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			result, err := store.Ingest(ctx, p, concurrent, now.Add(time.Second))
			errs <- err
			eventCounts <- len(result.Events)
		}()
	}
	wg.Wait()
	close(errs)
	close(eventCounts)
	for err := range errs {
		if err != nil {
			t.Fatalf("concurrent retry: %v", err)
		}
	}
	totalEvents := 0
	for n := range eventCounts {
		totalEvents += n
	}
	if totalEvents != 1 {
		t.Fatalf("concurrent retries published %d events", totalEvents)
	}
	if err = pool.QueryRow(ctx, `SELECT sample_count FROM activities WHERE id=$1`, activity).Scan(&count); err != nil || count != 4 {
		t.Fatalf("concurrent count=%d err=%v", count, err)
	}

	beforeDelayed := concurrent.Envelopes[0].EnvelopeID
	delayed := makeEnvelope(uuid.New(), 0)
	delayed.PhoneReceivedAt = now.Add(-time.Hour)
	if _, err = store.Ingest(ctx, p, telemetry.Batch{InstallationID: installation, Envelopes: []telemetry.Envelope{delayed}}, now.Add(2*time.Second)); err != nil {
		t.Fatal(err)
	}
	liveStore := live.NewStore(pool)
	channel := live.Channel{ID: channelID, UserID: user, ActivityID: &activity, Policy: "hidden"}
	replayed, reset, err := liveStore.Replay(ctx, channel, beforeDelayed, 10)
	if err != nil || reset || len(replayed) != 1 || replayed[0].EnvelopeID != delayed.EnvelopeID {
		t.Fatalf("delayed replay: items=%v reset=%v err=%v", replayed, reset, err)
	}

	activityB := uuid.New()
	makeForActivity := func(activityID uuid.UUID, at time.Time, state int16) telemetry.Envelope {
		e := makeEnvelope(uuid.New(), 20)
		e.ActivityID = activityID
		e.PhoneReceivedAt = at
		e.Sample.State = state
		return e
	}
	staleOther := makeForActivity(activityB, now.Add(5*time.Second), 1)
	staleResult, err := store.Ingest(ctx, p, telemetry.Batch{InstallationID: installation, Envelopes: []telemetry.Envelope{staleOther}}, now.Add(3*time.Second))
	if err != nil {
		t.Fatal(err)
	}
	var active uuid.UUID
	if err = pool.QueryRow(ctx, `SELECT active_activity_id FROM live_channels WHERE id=$1`, channelID).Scan(&active); err != nil || active != activity {
		t.Fatalf("stale activity replaced active activity: active=%s err=%v", active, err)
	}
	if len(staleResult.Channels[activityB]) != 0 {
		t.Fatal("stale activity was published to channel")
	}

	newerA := makeForActivity(activity, now.Add(35*time.Second), 1)
	newerB := makeForActivity(activityB, now.Add(40*time.Second), 1)
	multi, err := store.Ingest(ctx, p, telemetry.Batch{InstallationID: installation, Envelopes: []telemetry.Envelope{newerA, newerB}}, now.Add(4*time.Second))
	if err != nil {
		t.Fatal(err)
	}
	if err = pool.QueryRow(ctx, `SELECT active_activity_id FROM live_channels WHERE id=$1`, channelID).Scan(&active); err != nil || active != activityB {
		t.Fatalf("wrong deterministic active activity: active=%s err=%v", active, err)
	}
	if len(multi.Channels[activity]) != 0 || len(multi.Channels[activityB]) != 1 {
		t.Fatalf("channel mappings do not reflect final activity: %#v", multi.Channels)
	}
	if len(multi.Transitions) != 1 || multi.Transitions[0].Envelope.ActivityID != activityB {
		t.Fatalf("channel switch transitions=%#v", multi.Transitions)
	}
	channel.ActivityID = &activityB
	if replayed, reset, err = liveStore.Replay(ctx, channel, newerA.EnvelopeID, 10); err != nil || !reset || len(replayed) != 0 {
		t.Fatalf("cross-activity replay: items=%v reset=%v err=%v", replayed, reset, err)
	}

	staleEnd := makeForActivity(activityB, now.Add(39*time.Second), 4)
	staleEndResult, err := store.Ingest(ctx, p, telemetry.Batch{InstallationID: installation, Envelopes: []telemetry.Envelope{staleEnd}}, now.Add(5*time.Second))
	if err != nil {
		t.Fatal(err)
	}
	if len(staleEndResult.Transitions) != 0 {
		t.Fatal("stale sample produced an activity transition")
	}
	var state int16
	if err = pool.QueryRow(ctx, `SELECT current_state FROM activities WHERE id=$1`, activityB).Scan(&state); err != nil || state != 1 {
		t.Fatalf("stale sample changed state: state=%d err=%v", state, err)
	}
	var distinct, total int
	if err = pool.QueryRow(ctx, `SELECT count(DISTINCT ingest_cursor),count(*) FROM telemetry_samples WHERE user_id=$1`, user).Scan(&distinct, &total); err != nil || distinct != total {
		t.Fatalf("ingest cursors are not unique: distinct=%d total=%d err=%v", distinct, total, err)
	}
}
