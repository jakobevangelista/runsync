package ingest

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jakobevangelista/runsync/server/internal/auth"
	"github.com/jakobevangelista/runsync/server/internal/database"
	"github.com/jakobevangelista/runsync/server/internal/live"
	"github.com/jakobevangelista/runsync/server/internal/telemetry"
)

func TestActivitySegmentationCatchUpSelection(t *testing.T) {
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
	user, credential := uuid.New(), uuid.New()
	installation, device := uuid.New(), uuid.New()
	channelID, slug := uuid.New(), "segmentation-"+suffix
	if _, err := pool.Exec(ctx, `INSERT INTO users(id,handle) VALUES($1,$2)`, user, slug); err != nil {
		t.Fatal(err)
	}
	defer func() {
		_, _ = pool.Exec(context.Background(), `DELETE FROM telemetry_samples WHERE user_id=$1; DELETE FROM live_channels WHERE user_id=$1; DELETE FROM activities WHERE user_id=$1; DELETE FROM api_credentials WHERE user_id=$1; DELETE FROM garmin_devices WHERE user_id=$1; DELETE FROM installations WHERE user_id=$1; DELETE FROM users WHERE id=$1`, user)
	}()
	if _, err := pool.Exec(ctx, `INSERT INTO api_credentials(id,user_id,name,token_prefix,token_hash,scopes) VALUES($1,$2,'segmentation','rs_segmentation_' || $3,decode(repeat('00',32),'hex'),ARRAY['telemetry:write'])`, credential, user, suffix); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO live_channels(id,user_id,slug,display_name,location_policy) VALUES($1,$2,$3,'Segmentation','precise')`, channelID, user, slug); err != nil {
		t.Fatal(err)
	}

	principal := auth.Principal{CredentialID: credential, UserID: user, Scopes: map[string]bool{"telemetry:write": true}}
	store := New(pool)
	liveStore := live.NewStore(pool)
	base := time.Now().UTC().Truncate(time.Millisecond).Add(-2 * time.Minute)
	serverTime := base.Add(90 * time.Second)
	sequence := 0
	makeEnvelope := func(activity uuid.UUID, at time.Time, state int16, started *int) telemetry.Envelope {
		sequence++
		return telemetry.Envelope{
			EnvelopeID:             uuid.New(),
			ActivityID:             activity,
			PhoneReceivedAt:        at,
			GarminDeviceIdentifier: device,
			AppVersion:             "segmentation-test",
			Sample: telemetry.Sample{
				ProtocolVersion:           1,
				Sequence:                  sequence,
				State:                     state,
				ActivityStartEpochSeconds: started,
			},
		}
	}
	ingestBatch := func(envelopes ...telemetry.Envelope) Result {
		t.Helper()
		result, err := store.Ingest(ctx, principal, telemetry.Batch{InstallationID: installation, Envelopes: envelopes}, serverTime)
		if err != nil {
			t.Fatal(err)
		}
		return result
	}
	assertTransition := func(result Result, activity uuid.UUID, state int16) {
		t.Helper()
		if len(result.Transitions) != 1 || result.Transitions[0].Envelope.ActivityID != activity || result.Transitions[0].Envelope.Sample.State != state {
			t.Fatalf("transitions=%#v", result.Transitions)
		}
		if channels := result.Channels[activity]; len(channels) != 1 || channels[0] != channelID {
			t.Fatalf("channels for %s = %#v", activity, channels)
		}
	}
	assertSnapshot := func(activity uuid.UUID, status string) live.Snapshot {
		t.Helper()
		channel, err := liveStore.Channel(ctx, user, slug)
		if err != nil {
			t.Fatal(err)
		}
		if channel.ActivityID == nil || *channel.ActivityID != activity {
			t.Fatalf("active activity=%v, want %s", channel.ActivityID, activity)
		}
		snapshot, err := liveStore.Snapshot(ctx, channel, serverTime)
		if err != nil {
			t.Fatal(err)
		}
		if snapshot.Status != status || snapshot.Latest == nil {
			t.Fatalf("snapshot=%#v", snapshot)
		}
		return snapshot
	}

	activityA := uuid.New()
	runningA := makeEnvelope(activityA, base, 1, nil)
	assertTransition(ingestBatch(runningA), activityA, 1)
	endedA := makeEnvelope(activityA, base.Add(time.Second), 4, nil)
	endedResult := ingestBatch(endedA)
	if len(endedResult.Transitions) != 0 || len(endedResult.Events) != 1 || endedResult.Events[0].Envelope.Sample.State != 4 {
		t.Fatalf("ended update result=%#v", endedResult)
	}
	var activityCount, sampleCount int
	var state int16
	var endedAt *time.Time
	if err := pool.QueryRow(ctx, `SELECT (SELECT count(*) FROM activities WHERE user_id=$1),sample_count,current_state,ended_at FROM activities WHERE id=$2`, user, activityA).Scan(&activityCount, &sampleCount, &state, &endedAt); err != nil {
		t.Fatal(err)
	}
	if activityCount != 1 || sampleCount != 2 || state != 4 || endedAt == nil || !endedAt.Equal(endedA.PhoneReceivedAt) {
		t.Fatalf("ended activity: activities=%d samples=%d state=%d endedAt=%v", activityCount, sampleCount, state, endedAt)
	}
	assertSnapshot(activityA, "ended")

	activityB := uuid.New()
	startB := int(base.Add(10 * time.Second).Unix())
	runningB := makeEnvelope(activityB, base.Add(10*time.Second), 1, &startB)
	pausedB := makeEnvelope(activityB, base.Add(11*time.Second), 2, nil)
	assertTransition(ingestBatch(pausedB, runningB), activityB, 2)
	assertSnapshot(activityB, "paused")

	activityC := uuid.New()
	startC := int(base.Add(20 * time.Second).Unix())
	runningC := makeEnvelope(activityC, base.Add(20*time.Second), 1, &startC)
	stoppedC := makeEnvelope(activityC, base.Add(21*time.Second), 3, nil)
	assertTransition(ingestBatch(stoppedC, runningC), activityC, 3)
	assertSnapshot(activityC, "stopped")

	activityD := uuid.New()
	startD := int(base.Add(30 * time.Second).Unix())
	runningD := makeEnvelope(activityD, base.Add(30*time.Second), 1, &startD)
	pausedD := makeEnvelope(activityD, base.Add(31*time.Second), 2, nil)
	stoppedD := makeEnvelope(activityD, base.Add(32*time.Second), 3, nil)
	endedD := makeEnvelope(activityD, base.Add(33*time.Second), 4, nil)
	lat, lon := 37774921, -122419381
	for i, envelope := range []*telemetry.Envelope{&runningD, &pausedD, &stoppedD, &endedD} {
		pointLat, pointLon := lat+i, lon-i
		envelope.Sample.LatitudeMicrodegrees = &pointLat
		envelope.Sample.LongitudeMicrodegrees = &pointLon
	}
	catchUp := telemetry.Batch{InstallationID: installation, Envelopes: []telemetry.Envelope{endedD, stoppedD, runningD, pausedD}}
	catchUpResult, err := store.Ingest(ctx, principal, catchUp, serverTime)
	if err != nil {
		t.Fatal(err)
	}
	assertTransition(catchUpResult, activityD, 4)
	if len(catchUpResult.Events) != 4 || len(catchUpResult.Acknowledged) != 4 {
		t.Fatalf("catch-up result=%#v", catchUpResult)
	}
	wantEvents := []uuid.UUID{runningD.EnvelopeID, pausedD.EnvelopeID, stoppedD.EnvelopeID, endedD.EnvelopeID}
	for i, want := range wantEvents {
		if catchUpResult.Events[i].Envelope.EnvelopeID != want {
			t.Fatalf("catch-up event %d=%s, want %s", i, catchUpResult.Events[i].Envelope.EnvelopeID, want)
		}
	}
	snapshot := assertSnapshot(activityD, "ended")
	if snapshot.Latest.EnvelopeID != endedD.EnvelopeID || len(snapshot.Route) != 4 {
		t.Fatalf("ended snapshot=%#v", snapshot)
	}
	channel, err := liveStore.Channel(ctx, user, slug)
	if err != nil {
		t.Fatal(err)
	}
	route, err := liveStore.Route(ctx, channel, serverTime)
	if err != nil {
		t.Fatal(err)
	}
	wantRoute := []uuid.UUID{runningD.EnvelopeID, pausedD.EnvelopeID, stoppedD.EnvelopeID, endedD.EnvelopeID}
	if route.ActivityID == nil || *route.ActivityID != activityD || len(route.Points) != len(wantRoute) {
		t.Fatalf("route=%#v", route)
	}
	for i, want := range wantRoute {
		if route.Points[i].EnvelopeID != want {
			t.Fatalf("route point %d=%s, want %s", i, route.Points[i].EnvelopeID, want)
		}
	}
	var garminStartedAt *time.Time
	if err := pool.QueryRow(ctx, `SELECT garmin_started_at FROM activities WHERE id=$1`, activityD).Scan(&garminStartedAt); err != nil {
		t.Fatal(err)
	}
	if garminStartedAt == nil || garminStartedAt.Unix() != int64(startD) {
		t.Fatalf("garmin_started_at=%v, want epoch %d", garminStartedAt, startD)
	}

	replayResult, err := store.Ingest(ctx, principal, catchUp, serverTime.Add(time.Second))
	if err != nil {
		t.Fatal(err)
	}
	if len(replayResult.Acknowledged) != 4 || len(replayResult.Events) != 0 || len(replayResult.Transitions) != 0 {
		t.Fatalf("duplicate replay result=%#v", replayResult)
	}
	if err := pool.QueryRow(ctx, `SELECT sample_count FROM activities WHERE id=$1`, activityD).Scan(&sampleCount); err != nil || sampleCount != 4 {
		t.Fatalf("sample_count=%d err=%v", sampleCount, err)
	}

	activityE := uuid.New()
	startE := int(base.Add(40 * time.Second).Unix())
	runningE := makeEnvelope(activityE, base.Add(40*time.Second), 1, &startE)
	endedE := makeEnvelope(activityE, base.Add(41*time.Second), 4, nil)
	terminalFirst := ingestBatch(endedE)
	if len(terminalFirst.Events) != 1 || len(terminalFirst.Transitions) != 0 || len(terminalFirst.Channels[activityE]) != 0 {
		t.Fatalf("terminal-first result=%#v", terminalFirst)
	}
	assertSnapshot(activityD, "ended")
	mixedResult := ingestBatch(endedE, runningE)
	assertTransition(mixedResult, activityE, 4)
	if mixedResult.Transitions[0].Envelope.EnvelopeID != endedE.EnvelopeID || len(mixedResult.Events) != 1 || mixedResult.Events[0].Envelope.EnvelopeID != runningE.EnvelopeID || len(mixedResult.Acknowledged) != 2 {
		t.Fatalf("mixed duplicate/new result=%#v", mixedResult)
	}
	assertSnapshot(activityE, "ended")
	mixedReplay := ingestBatch(endedE, runningE)
	if len(mixedReplay.Acknowledged) != 2 || len(mixedReplay.Events) != 0 || len(mixedReplay.Transitions) != 0 {
		t.Fatalf("mixed replay result=%#v", mixedReplay)
	}
	if err := pool.QueryRow(ctx, `SELECT sample_count,current_state,ended_at FROM activities WHERE id=$1`, activityE).Scan(&sampleCount, &state, &endedAt); err != nil {
		t.Fatal(err)
	}
	if sampleCount != 2 || state != 4 || endedAt == nil || !endedAt.Equal(endedE.PhoneReceivedAt) {
		t.Fatalf("mixed activity: samples=%d state=%d endedAt=%v", sampleCount, state, endedAt)
	}

	staleActivity := uuid.New()
	staleStart := int(base.Add(24 * time.Second).Unix())
	staleRunning := makeEnvelope(staleActivity, base.Add(24*time.Second), 1, &staleStart)
	staleEnded := makeEnvelope(staleActivity, base.Add(25*time.Second), 4, nil)
	staleResult := ingestBatch(staleEnded, staleRunning)
	if len(staleResult.Transitions) != 0 || len(staleResult.Channels[staleActivity]) != 0 {
		t.Fatalf("stale candidate result=%#v", staleResult)
	}
	assertSnapshot(activityE, "ended")

	if err := pool.QueryRow(ctx, `SELECT count(*) FROM activities WHERE user_id=$1 AND id=$2`, user, activityD).Scan(&activityCount); err != nil || activityCount != 1 {
		t.Fatalf("completed activity rows=%d err=%v", activityCount, err)
	}
}

func TestSortEventsAuthoritatively(t *testing.T) {
	at := time.Now().UTC()
	older := telemetry.Event{Envelope: telemetry.Envelope{EnvelopeID: uuid.New(), PhoneReceivedAt: at.Add(-time.Second)}, IngestCursor: 30}
	tieFirst := telemetry.Event{Envelope: telemetry.Envelope{EnvelopeID: uuid.New(), PhoneReceivedAt: at}, IngestCursor: 10}
	tieSecond := telemetry.Event{Envelope: telemetry.Envelope{EnvelopeID: uuid.New(), PhoneReceivedAt: at}, IngestCursor: 20}
	events := []telemetry.Event{tieSecond, older, tieFirst}

	sortEvents(events)

	want := []uuid.UUID{older.Envelope.EnvelopeID, tieFirst.Envelope.EnvelopeID, tieSecond.Envelope.EnvelopeID}
	for i := range want {
		if events[i].Envelope.EnvelopeID != want[i] {
			t.Fatalf("event %d=%s, want %s", i, events[i].Envelope.EnvelopeID, want[i])
		}
	}
}
