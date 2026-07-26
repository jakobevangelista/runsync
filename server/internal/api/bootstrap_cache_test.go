package api

import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jakobevangelista/runsync/server/internal/live"
	"github.com/jakobevangelista/runsync/server/internal/telemetry"
)

func TestBootstrapCacheHitsAndExpires(t *testing.T) {
	cache := newBootstrapCache()
	channel := live.Channel{ID: uuid.New(), ActivityID: uuidPointer(), Policy: "precise"}
	now := time.Now().UTC()
	var calls atomic.Int32
	loader := func(context.Context, live.Channel, time.Time) (live.Bootstrap, error) {
		call := calls.Add(1)
		return bootstrapWithMarker(uuid.New(), string(rune('a'+call-1))), nil
	}

	first, err := cache.get(context.Background(), channel, now, loader)
	if err != nil {
		t.Fatal(err)
	}
	hit, err := cache.get(context.Background(), channel, now.Add(bootstrapCacheTTL-time.Nanosecond), loader)
	if err != nil {
		t.Fatal(err)
	}
	if calls.Load() != 1 || hit.Snapshot.Slug != first.Snapshot.Slug {
		t.Fatalf("cache hit calls=%d first=%q hit=%q", calls.Load(), first.Snapshot.Slug, hit.Snapshot.Slug)
	}
	expired, err := cache.get(context.Background(), channel, now.Add(bootstrapCacheTTL), loader)
	if err != nil {
		t.Fatal(err)
	}
	if calls.Load() != 2 || expired.Snapshot.Slug == first.Snapshot.Slug {
		t.Fatalf("expiration calls=%d first=%q expired=%q", calls.Load(), first.Snapshot.Slug, expired.Snapshot.Slug)
	}
}

func TestBootstrapCacheCoalescesConcurrentMisses(t *testing.T) {
	cache := newBootstrapCache()
	channel := live.Channel{ID: uuid.New(), ActivityID: uuidPointer(), Policy: "precise"}
	now := time.Now().UTC()
	started := make(chan struct{})
	release := make(chan struct{})
	var calls atomic.Int32
	loader := func(context.Context, live.Channel, time.Time) (live.Bootstrap, error) {
		if calls.Add(1) == 1 {
			close(started)
		}
		<-release
		return bootstrapWithMarker(uuid.New(), "coalesced"), nil
	}

	const viewers = 100
	results := make(chan live.Bootstrap, viewers)
	errorsSeen := make(chan error, viewers)
	var wg sync.WaitGroup
	for viewer := 0; viewer < viewers; viewer++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			value, err := cache.get(context.Background(), channel, now, loader)
			results <- value
			errorsSeen <- err
		}()
	}
	<-started
	close(release)
	wg.Wait()
	close(results)
	close(errorsSeen)
	if calls.Load() != 1 {
		t.Fatalf("underlying bootstrap calls=%d, want 1", calls.Load())
	}
	for err := range errorsSeen {
		if err != nil {
			t.Fatal(err)
		}
	}
	for result := range results {
		if result.Snapshot.Slug != "coalesced" {
			t.Fatalf("coalesced result=%#v", result)
		}
	}
}

func TestBootstrapCacheSeparatesActivityPolicyAndPrecision(t *testing.T) {
	cache := newBootstrapCache()
	channelID := uuid.New()
	activityA, activityB := uuid.New(), uuid.New()
	roundedTwo, roundedThree := int16(2), int16(3)
	channels := []live.Channel{
		{ID: channelID, ActivityID: &activityA, Policy: "precise"},
		{ID: channelID, ActivityID: &activityA, Policy: "rounded", Decimals: &roundedTwo},
		{ID: channelID, ActivityID: &activityA, Policy: "rounded", Decimals: &roundedThree},
		{ID: channelID, ActivityID: &activityA, Policy: "hidden"},
		{ID: channelID, ActivityID: &activityB, Policy: "precise"},
	}
	var calls atomic.Int32
	loader := func(_ context.Context, channel live.Channel, _ time.Time) (live.Bootstrap, error) {
		calls.Add(1)
		return policyBootstrap(channel), nil
	}
	now := time.Now().UTC()
	for _, channel := range channels {
		first, err := cache.get(context.Background(), channel, now, loader)
		if err != nil {
			t.Fatal(err)
		}
		second, err := cache.get(context.Background(), channel, now, loader)
		if err != nil {
			t.Fatal(err)
		}
		if first.Route.LocationPolicy != channel.Policy ||
			second.Route.LocationPolicy != channel.Policy ||
			first.Snapshot.ActivityID == nil ||
			*first.Snapshot.ActivityID != *channel.ActivityID {
			t.Fatalf("isolated result=%#v for channel=%#v", first, channel)
		}
		switch channel.Policy {
		case "precise":
			if first.Snapshot.Latest == nil ||
				first.Snapshot.Latest.LatitudeMicrodegrees == nil ||
				*first.Snapshot.Latest.LatitudeMicrodegrees != 37774921 {
				t.Fatalf("precise cache result=%#v", first)
			}
		case "rounded":
			if first.Snapshot.Latest == nil || first.Snapshot.Latest.LatitudeMicrodegrees == nil {
				t.Fatalf("rounded cache result=%#v", first)
			}
			want := 37770000
			if channel.Decimals != nil && *channel.Decimals == 3 {
				want = 37775000
			}
			if *first.Snapshot.Latest.LatitudeMicrodegrees != want {
				t.Fatalf("rounded latitude=%d, want %d", *first.Snapshot.Latest.LatitudeMicrodegrees, want)
			}
		case "hidden":
			if first.Snapshot.Latest == nil ||
				first.Snapshot.Latest.LatitudeMicrodegrees != nil ||
				first.Snapshot.Latest.LongitudeMicrodegrees != nil ||
				len(first.Route.Points) != 0 {
				t.Fatalf("hidden cache leaked coordinates=%#v", first)
			}
		}
	}
	if calls.Load() != int32(len(channels)) {
		t.Fatalf("underlying calls=%d, want %d isolated keys", calls.Load(), len(channels))
	}
}

func TestBootstrapCacheInvalidationAndInFlightGeneration(t *testing.T) {
	cache := newBootstrapCache()
	channel := live.Channel{ID: uuid.New(), ActivityID: uuidPointer(), Policy: "precise"}
	now := time.Now().UTC()
	firstStarted := make(chan struct{})
	releaseFirst := make(chan struct{})
	var calls atomic.Int32
	loader := func(context.Context, live.Channel, time.Time) (live.Bootstrap, error) {
		call := calls.Add(1)
		if call == 1 {
			close(firstStarted)
			<-releaseFirst
			return bootstrapWithMarker(uuid.New(), "stale"), nil
		}
		return bootstrapWithMarker(uuid.New(), "fresh"), nil
	}

	firstResult := make(chan live.Bootstrap, 1)
	go func() {
		value, _ := cache.get(context.Background(), channel, now, loader)
		firstResult <- value
	}()
	<-firstStarted
	cache.invalidate([]uuid.UUID{channel.ID})
	fresh, err := cache.get(context.Background(), channel, now.Add(time.Second), loader)
	if err != nil {
		t.Fatal(err)
	}
	if fresh.Snapshot.Slug != "fresh" {
		t.Fatalf("post-invalidation result=%q", fresh.Snapshot.Slug)
	}
	close(releaseFirst)
	if stale := <-firstResult; stale.Snapshot.Slug != "stale" {
		t.Fatalf("original in-flight result=%q", stale.Snapshot.Slug)
	}
	hit, err := cache.get(context.Background(), channel, now.Add(2*time.Second), loader)
	if err != nil {
		t.Fatal(err)
	}
	if calls.Load() != 2 || hit.Snapshot.Slug != "fresh" {
		t.Fatalf("stale fill replaced cache: calls=%d hit=%q", calls.Load(), hit.Snapshot.Slug)
	}
}

func TestBootstrapCacheDoesNotCacheErrorsAndHonorsWaiterCancellation(t *testing.T) {
	cache := newBootstrapCache()
	channel := live.Channel{ID: uuid.New(), Policy: "hidden"}
	now := time.Now().UTC()
	started := make(chan struct{})
	release := make(chan struct{})
	expected := errors.New("bootstrap unavailable")
	var calls atomic.Int32
	loader := func(context.Context, live.Channel, time.Time) (live.Bootstrap, error) {
		calls.Add(1)
		close(started)
		<-release
		return live.Bootstrap{}, expected
	}
	firstDone := make(chan error, 1)
	go func() {
		_, err := cache.get(context.Background(), channel, now, loader)
		firstDone <- err
	}()
	<-started
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := cache.get(ctx, channel, now, loader); !errors.Is(err, context.Canceled) {
		t.Fatalf("waiter error=%v, want context.Canceled", err)
	}
	close(release)
	if err := <-firstDone; !errors.Is(err, expected) {
		t.Fatalf("loader error=%v, want %v", err, expected)
	}
	if calls.Load() != 1 {
		t.Fatalf("calls=%d", calls.Load())
	}
	retryCalls := atomic.Int32{}
	_, err := cache.get(context.Background(), channel, now, func(context.Context, live.Channel, time.Time) (live.Bootstrap, error) {
		retryCalls.Add(1)
		return bootstrapWithMarker(uuid.New(), "recovered"), nil
	})
	if err != nil || retryCalls.Load() != 1 {
		t.Fatalf("error was cached: calls=%d err=%v", retryCalls.Load(), err)
	}
}

func TestBootstrapCachePreservesReplayCursor(t *testing.T) {
	cache := newBootstrapCache()
	channel := live.Channel{ID: uuid.New(), ActivityID: uuidPointer(), Policy: "hidden"}
	cursor := uuid.New()
	value := bootstrapWithMarker(cursor, "cursor")
	loader := func(context.Context, live.Channel, time.Time) (live.Bootstrap, error) {
		return value, nil
	}
	now := time.Now().UTC()
	_, err := cache.get(context.Background(), channel, now, loader)
	if err != nil {
		t.Fatal(err)
	}
	hit, err := cache.get(context.Background(), channel, now.Add(time.Second), loader)
	if err != nil {
		t.Fatal(err)
	}
	if hit.ReplayAfterEnvelopeID == nil || *hit.ReplayAfterEnvelopeID != cursor {
		t.Fatalf("cached replay cursor=%v, want %s", hit.ReplayAfterEnvelopeID, cursor)
	}
}

func bootstrapWithMarker(cursor uuid.UUID, marker string) live.Bootstrap {
	return live.Bootstrap{
		Snapshot:              live.Snapshot{Slug: marker},
		ReplayAfterEnvelopeID: &cursor,
	}
}

func policyBootstrap(channel live.Channel) live.Bootstrap {
	activity := channel.ActivityID
	latitude, longitude := 37774921, -122419381
	sample := live.EventView(telemetry.Event{Envelope: telemetry.Envelope{
		EnvelopeID: uuid.New(),
		Sample: telemetry.Sample{
			LatitudeMicrodegrees:  &latitude,
			LongitudeMicrodegrees: &longitude,
		},
	}}, channel.Policy, channel.Decimals)
	points := []live.RoutePoint{}
	if sample.LatitudeMicrodegrees != nil && sample.LongitudeMicrodegrees != nil {
		points = append(points, live.RoutePoint{
			EnvelopeID:            sample.EnvelopeID,
			LatitudeMicrodegrees:  *sample.LatitudeMicrodegrees,
			LongitudeMicrodegrees: *sample.LongitudeMicrodegrees,
		})
	}
	return live.Bootstrap{
		Snapshot: live.Snapshot{
			ChannelID:  channel.ID,
			ActivityID: activity,
			Slug:       channel.Policy,
			Latest:     &sample,
		},
		Route: live.Route{
			ChannelID:      channel.ID,
			ActivityID:     activity,
			LocationPolicy: channel.Policy,
			Points:         points,
		},
	}
}

func uuidPointer() *uuid.UUID {
	value := uuid.New()
	return &value
}
