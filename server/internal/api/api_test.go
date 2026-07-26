package api

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jakobevangelista/runsync/server/internal/auth"
	"github.com/jakobevangelista/runsync/server/internal/ingest"
	"github.com/jakobevangelista/runsync/server/internal/live"
	"github.com/jakobevangelista/runsync/server/internal/telemetry"
)

type testErrorResponse struct {
	Error struct {
		Code       string     `json:"code"`
		Message    string     `json:"message"`
		EnvelopeID *uuid.UUID `json:"envelopeId"`
		Retryable  bool       `json:"retryable"`
	} `json:"error"`
}

func decodeTestError(t *testing.T, body []byte) testErrorResponse {
	t.Helper()
	var response testErrorResponse
	if err := json.Unmarshal(body, &response); err != nil {
		t.Fatalf("decode error response: %v: %s", err, body)
	}
	return response
}

func TestHealthAndCORS(t *testing.T) {
	s := New(nil, bytes.Repeat([]byte{1}, 32), map[string]struct{}{"https://app.example": {}}, nil, slog.New(slog.NewTextHandler(io.Discard, nil)))
	h := s.Handler()
	r := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	r.Header.Set("Origin", "https://app.example")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 200 || w.Header().Get("Access-Control-Allow-Origin") != "https://app.example" {
		t.Fatalf("status=%d headers=%v", w.Code, w.Header())
	}
	r = httptest.NewRequest(http.MethodGet, "/healthz", nil)
	r.Header.Set("Origin", "https://evil.example")
	w = httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 403 {
		t.Fatalf("status=%d", w.Code)
	}
}
func TestDecodeRejectsOversizeAndUnknown(t *testing.T) {
	for _, tc := range []struct {
		name, body, code, message string
		status                    int
	}{{"unknown", `{"unknown":1}`, "invalid_json", "invalid JSON request", 400}, {"large", `{"value":"` + string(bytes.Repeat([]byte{'x'}, maxBody)) + `"}`, "body_too_large", "request body exceeds 256 KiB", 413}} {
		t.Run(tc.name, func(t *testing.T) {
			r := httptest.NewRequest(http.MethodPost, "/", bytes.NewBufferString(tc.body))
			r.Header.Set("Content-Type", "application/json")
			w := httptest.NewRecorder()
			var dst struct {
				Value string `json:"value"`
			}
			if decode(w, r, &dst) || w.Code != tc.status {
				t.Fatalf("status=%d", w.Code)
			}
			response := decodeTestError(t, w.Body.Bytes())
			if response.Error.Code != tc.code || response.Error.Message != tc.message || response.Error.EnvelopeID != nil || response.Error.Retryable {
				t.Fatalf("error=%#v", response.Error)
			}
		})
	}
}

func TestErrorResponseContractAndRetryability(t *testing.T) {
	envelopeID := uuid.New()
	for _, tc := range []struct {
		name       string
		status     int
		code       string
		message    string
		envelopeID *uuid.UUID
		retryable  bool
	}{
		{"invalid envelope", http.StatusUnprocessableEntity, "invalid_envelope", "invalid sample", &envelopeID, false},
		{"rate limit", http.StatusTooManyRequests, "rate_limited", "request rate exceeded", nil, true},
		{"store failure", http.StatusInternalServerError, "internal_error", "internal server error", nil, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			w := httptest.NewRecorder()
			writeAPIError(w, tc.status, tc.code, tc.message, tc.envelopeID)
			response := decodeTestError(t, w.Body.Bytes())
			if response.Error.Code != tc.code || response.Error.Message != tc.message || response.Error.Retryable != tc.retryable {
				t.Fatalf("error=%#v", response.Error)
			}
			if tc.envelopeID == nil {
				if response.Error.EnvelopeID != nil {
					t.Fatalf("envelope ID=%v, want nil", response.Error.EnvelopeID)
				}
			} else if response.Error.EnvelopeID == nil || *response.Error.EnvelopeID != *tc.envelopeID {
				t.Fatalf("envelope ID=%v, want %s", response.Error.EnvelopeID, *tc.envelopeID)
			}
			var raw struct {
				Error map[string]json.RawMessage `json:"error"`
			}
			if err := json.Unmarshal(w.Body.Bytes(), &raw); err != nil {
				t.Fatal(err)
			}
			if len(raw.Error) != 4 {
				t.Fatalf("error fields=%v, want only code, message, envelopeId, retryable", raw.Error)
			}
		})
	}
}

func TestIngestRejectionResponse(t *testing.T) {
	envelopeID := uuid.New()
	tests := []struct {
		name    string
		err     error
		status  int
		code    string
		message string
		id      *uuid.UUID
		ok      bool
	}{
		{"conflict", &ingest.RejectionError{Code: ingest.CodeEnvelopeConflict, EnvelopeID: &envelopeID}, http.StatusConflict, string(ingest.CodeEnvelopeConflict), "envelope conflicts with existing telemetry", &envelopeID, true},
		{"envelope ownership", &ingest.RejectionError{Code: ingest.CodeEnvelopeOwnershipConflict, EnvelopeID: &envelopeID}, http.StatusForbidden, string(ingest.CodeEnvelopeOwnershipConflict), "envelope is not available to this credential", &envelopeID, true},
		{"installation ownership", &ingest.RejectionError{Code: ingest.CodeInstallationOwnershipConflict}, http.StatusForbidden, string(ingest.CodeInstallationOwnershipConflict), "installation is not available to this credential", nil, true},
		{"database", errors.New("database unavailable"), 0, "", "", nil, false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			status, code, message, id, ok := ingestRejectionResponse(tc.err)
			if status != tc.status || code != tc.code || message != tc.message || ok != tc.ok {
				t.Fatalf("got status=%d code=%q message=%q ok=%v", status, code, message, ok)
			}
			if tc.id == nil {
				if id != nil {
					t.Fatalf("ID=%v, want nil", id)
				}
			} else if id == nil || *id != *tc.id {
				t.Fatalf("ID=%v, want %s", id, *tc.id)
			}
		})
	}
}

func TestPublishIngestSendsEndedTransitionBeforeSamples(t *testing.T) {
	channelID, activityID := uuid.New(), uuid.New()
	transition := telemetry.Event{Envelope: telemetry.Envelope{EnvelopeID: uuid.New(), ActivityID: activityID, Sample: telemetry.Sample{State: 4}}, IngestCursor: 20}
	sample := telemetry.Event{Envelope: telemetry.Envelope{EnvelopeID: uuid.New(), ActivityID: activityID}, IngestCursor: 10}
	s := &Server{hub: live.NewHub(3)}
	sub := s.hub.Subscribe(channelID)
	defer sub.Close()

	s.publishIngest(ingest.Result{
		Events:      []telemetry.Event{transition, sample},
		Transitions: []telemetry.Event{transition},
		Channels:    map[uuid.UUID][]uuid.UUID{activityID: {channelID}},
	})

	for i, want := range []struct {
		kind  string
		id    uuid.UUID
		state int16
	}{{"activity", transition.Envelope.EnvelopeID, 4}, {"sample", sample.Envelope.EnvelopeID, 0}, {"sample", transition.Envelope.EnvelopeID, 4}} {
		message := <-sub.C
		if message.Kind != want.kind || message.Event.Envelope.EnvelopeID != want.id || message.Event.Envelope.Sample.State != want.state {
			t.Fatalf("message %d = %s/%s/state %d, want %s/%s/state %d", i, message.Kind, message.Event.Envelope.EnvelopeID, message.Event.Envelope.Sample.State, want.kind, want.id, want.state)
		}
	}
}

func TestUserIngestLocksSerializeCommitThroughPublication(t *testing.T) {
	locks := newUserLocks()
	user := uuid.New()
	releaseFirst := make(chan struct{})
	secondEntered := make(chan struct{})
	var wg sync.WaitGroup
	firstUnlock, err := locks.Lock(context.Background(), user)
	if err != nil {
		t.Fatal(err)
	}
	wg.Add(2)
	go func() {
		defer wg.Done()
		<-releaseFirst
		firstUnlock()
	}()
	go func() {
		defer wg.Done()
		unlock, err := locks.Lock(context.Background(), user)
		if err != nil {
			return
		}
		close(secondEntered)
		unlock()
	}()
	waitForUserLockRefs(t, locks, user, 2)

	select {
	case <-secondEntered:
		t.Fatal("second ingest entered before the first published")
	default:
	}
	close(releaseFirst)
	select {
	case <-secondEntered:
	case <-time.After(time.Second):
		t.Fatal("second ingest did not proceed after publication")
	}
	wg.Wait()
	locks.mu.Lock()
	defer locks.mu.Unlock()
	if len(locks.locks) != 0 {
		t.Fatalf("unused keyed locks retained: %d", len(locks.locks))
	}
}

func TestUserIngestLockWaitIsCancelableAndCleanedUp(t *testing.T) {
	locks := newUserLocks()
	user := uuid.New()
	unlock, err := locks.Lock(context.Background(), user)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	waiting := make(chan error, 1)
	go func() {
		_, err := locks.Lock(ctx, user)
		waiting <- err
	}()
	waitForUserLockRefs(t, locks, user, 2)
	cancel()
	select {
	case err := <-waiting:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("lock error=%v, want context.Canceled", err)
		}
	case <-time.After(time.Second):
		t.Fatal("canceled lock wait did not return")
	}
	unlock()
	locks.mu.Lock()
	defer locks.mu.Unlock()
	if len(locks.locks) != 0 {
		t.Fatalf("unused keyed locks retained: %d", len(locks.locks))
	}
}

func waitForUserLockRefs(t *testing.T, locks *userLocks, user uuid.UUID, want int) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for {
		locks.mu.Lock()
		lock := locks.locks[user]
		refs := 0
		if lock != nil {
			refs = lock.refs
		}
		locks.mu.Unlock()
		if refs == want {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("user lock refs=%d, want %d", refs, want)
		}
		runtime.Gosched()
	}
}

type stubLiveStore struct {
	channel func(context.Context, uuid.UUID, string) (live.Channel, error)
	replay  func(context.Context, live.Channel, uuid.UUID, int) ([]live.SampleView, bool, error)
}

func (s *stubLiveStore) Channel(ctx context.Context, user uuid.UUID, slug string) (live.Channel, error) {
	return s.channel(ctx, user, slug)
}
func (*stubLiveStore) Bootstrap(context.Context, live.Channel, time.Time) (live.Bootstrap, error) {
	return live.Bootstrap{}, nil
}
func (*stubLiveStore) Snapshot(context.Context, live.Channel, time.Time) (live.Snapshot, error) {
	return live.Snapshot{}, nil
}
func (*stubLiveStore) Route(context.Context, live.Channel, time.Time) (live.Route, error) {
	return live.Route{}, nil
}
func (s *stubLiveStore) Replay(ctx context.Context, channel live.Channel, id uuid.UUID, limit int) ([]live.SampleView, bool, error) {
	if s.replay != nil {
		return s.replay(ctx, channel, id, limit)
	}
	return nil, false, nil
}

func TestStreamLoadsChannelOnceAcrossAnyNumberOfTelemetryMessages(t *testing.T) {
	key := bytes.Repeat([]byte{7}, 32)
	channel := live.Channel{ID: uuid.New(), UserID: uuid.New(), Slug: "one-lookup", Policy: "precise"}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	store := &stubLiveStore{}
	server := &Server{
		live:    store,
		hub:     live.NewHub(128),
		key:     key,
		streams: newSSEConnectionRegistry(),
	}
	lookups := 0
	subscribedAtLookup := false
	const messages = 64
	events := make([]telemetry.Event, messages)
	for index := range events {
		events[index] = telemetry.Event{
			Envelope: telemetry.Envelope{
				EnvelopeID: uuid.New(),
				ActivityID: uuid.New(),
				Sample:     telemetry.Sample{State: 1},
			},
		}
	}
	store.channel = func(context.Context, uuid.UUID, string) (live.Channel, error) {
		lookups++
		subscribedAtLookup = server.hub.Count(channel.ID) == 1
		for _, event := range events {
			server.hub.Publish(channel.ID, live.Message{Kind: "sample", Event: event})
		}
		return channel, nil
	}
	now := time.Now()
	token, err := auth.SignViewer(key, auth.ViewerClaims{ChannelID: channel.ID, UserID: channel.UserID, Slug: channel.Slug, Policy: channel.Policy, IssuedAt: now.Unix(), ExpiresAt: now.Add(time.Minute).Unix(), Scope: "channel:live"})
	if err != nil {
		t.Fatal(err)
	}
	request := httptest.NewRequest(http.MethodGet, "/v1/channels/one-lookup/stream", nil).WithContext(ctx)
	request.SetPathValue("slug", channel.Slug)
	request.Header.Set("Authorization", "Bearer "+token)
	response := newStreamTestWriter(cancel, events[len(events)-1].Envelope.EnvelopeID.String())
	server.stream(response, request)
	if !subscribedAtLookup {
		t.Fatal("stream was not subscribed during active-channel lookup")
	}
	if lookups != 1 {
		t.Fatalf("channel lookups=%d, want 1", lookups)
	}
	if count := strings.Count(response.String(), "event: sample"); count != messages {
		t.Fatalf("sample events=%d, want %d", count, messages)
	}
	assertEmptySSERegistry(t, server.streams)
}

func TestStreamEffectiveLocationPolicy(t *testing.T) {
	roundedTwo, roundedThree, roundedFive := int16(2), int16(3), int16(5)
	tests := []struct {
		name            string
		channelPolicy   string
		channelDecimals *int16
		tokenPolicy     string
		tokenDecimals   *int16
		wantLatitude    *int
		wantLongitude   *int
	}{
		{"precise", "precise", nil, "precise", nil, intPointer(37774921), intPointer(-122419381)},
		{"token rounds precise", "precise", nil, "rounded", &roundedTwo, intPointer(37770000), intPointer(-122420000)},
		{"token hides precise", "precise", nil, "hidden", nil, nil, nil},
		{"token cannot unround", "rounded", &roundedThree, "precise", nil, intPointer(37775000), intPointer(-122419000)},
		{"token cannot add rounded precision", "rounded", &roundedThree, "rounded", &roundedFive, intPointer(37775000), intPointer(-122419000)},
		{"token can reduce rounded precision", "rounded", &roundedThree, "rounded", &roundedTwo, intPointer(37770000), intPointer(-122420000)},
		{"token cannot reveal hidden", "hidden", nil, "precise", nil, nil, nil},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			key := bytes.Repeat([]byte{8}, 32)
			channel := live.Channel{
				ID:       uuid.New(),
				UserID:   uuid.New(),
				Slug:     "policy",
				Policy:   test.channelPolicy,
				Decimals: test.channelDecimals,
			}
			latitude, longitude := 37774921, -122419381
			event := telemetry.Event{Envelope: telemetry.Envelope{
				EnvelopeID: uuid.New(),
				ActivityID: uuid.New(),
				Sample: telemetry.Sample{
					State:                 1,
					LatitudeMicrodegrees:  &latitude,
					LongitudeMicrodegrees: &longitude,
				},
			}}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			lookups := 0
			server := &Server{
				hub:     live.NewHub(4),
				key:     key,
				streams: newSSEConnectionRegistry(),
			}
			server.live = &stubLiveStore{channel: func(context.Context, uuid.UUID, string) (live.Channel, error) {
				lookups++
				server.hub.Publish(channel.ID, live.Message{Kind: "sample", Event: event})
				return channel, nil
			}}
			now := time.Now()
			token, err := auth.SignViewer(key, auth.ViewerClaims{
				ChannelID: channel.ID,
				UserID:    channel.UserID,
				Slug:      channel.Slug,
				Policy:    test.tokenPolicy,
				Decimals:  test.tokenDecimals,
				IssuedAt:  now.Unix(),
				ExpiresAt: now.Add(time.Minute).Unix(),
				Scope:     "channel:live",
			})
			if err != nil {
				t.Fatal(err)
			}
			request := httptest.NewRequest(http.MethodGet, "/v1/channels/policy/stream", nil).WithContext(ctx)
			request.SetPathValue("slug", channel.Slug)
			request.Header.Set("Authorization", "Bearer "+token)
			response := newStreamTestWriter(cancel, event.Envelope.EnvelopeID.String())
			server.stream(response, request)
			view := decodeSSESample(t, response.String())
			if lookups != 1 {
				t.Fatalf("channel lookups=%d, want 1", lookups)
			}
			assertOptionalInt(t, "latitude", view.LatitudeMicrodegrees, test.wantLatitude)
			assertOptionalInt(t, "longitude", view.LongitudeMicrodegrees, test.wantLongitude)
			assertEmptySSERegistry(t, server.streams)
		})
	}
}

func TestInvalidViewerTokenDoesNotConsumeSSECapacity(t *testing.T) {
	server := &Server{
		key:     bytes.Repeat([]byte{9}, 32),
		streams: newSSEConnectionRegistry(),
	}
	request := httptest.NewRequest(http.MethodGet, "/v1/channels/live/stream", nil)
	request.SetPathValue("slug", "live")
	request.Header.Set("Authorization", "Bearer invalid")
	response := httptest.NewRecorder()
	server.stream(response, request)
	if response.Code != http.StatusUnauthorized {
		t.Fatalf("status=%d", response.Code)
	}
	assertEmptySSERegistry(t, server.streams)
}

func TestStreamCapacityRejectionReturns429WithoutPartialAcquire(t *testing.T) {
	key := bytes.Repeat([]byte{10}, 32)
	channel := live.Channel{ID: uuid.New(), UserID: uuid.New(), Slug: "capacity", Policy: "hidden"}
	registry := newSSEConnectionRegistryWithLimits(sseConnectionLimits{
		perIP:      1,
		perChannel: 2,
		global:     2,
	})
	release, ok := registry.acquire("192.0.2.1", channel.ID)
	if !ok {
		t.Fatal("fixture acquire rejected")
	}
	defer release()
	lookups := 0
	server := &Server{
		key:     key,
		hub:     live.NewHub(4),
		streams: registry,
		live: &stubLiveStore{channel: func(context.Context, uuid.UUID, string) (live.Channel, error) {
			lookups++
			return channel, nil
		}},
	}
	now := time.Now()
	token, err := auth.SignViewer(key, auth.ViewerClaims{
		ChannelID: channel.ID,
		UserID:    channel.UserID,
		Slug:      channel.Slug,
		Policy:    channel.Policy,
		IssuedAt:  now.Unix(),
		ExpiresAt: now.Add(time.Minute).Unix(),
		Scope:     "channel:live",
	})
	if err != nil {
		t.Fatal(err)
	}
	request := httptest.NewRequest(http.MethodGet, "/v1/channels/capacity/stream", nil)
	request.RemoteAddr = "192.0.2.1:1234"
	request.SetPathValue("slug", channel.Slug)
	request.Header.Set("Authorization", "Bearer "+token)
	response := httptest.NewRecorder()
	server.stream(response, request)
	if response.Code != http.StatusTooManyRequests || response.Header().Get("Retry-After") != "1" {
		t.Fatalf("status=%d retry-after=%q", response.Code, response.Header().Get("Retry-After"))
	}
	if lookups != 0 {
		t.Fatalf("channel lookups=%d after capacity rejection", lookups)
	}
	counts := registry.counts()
	if counts.total != 1 || counts.byIP["192.0.2.1"] != 1 || counts.byChannel[channel.ID] != 1 {
		t.Fatalf("capacity rejection changed registry=%#v", counts)
	}
}

func TestStreamReleasesCapacityOnEarlyExitPaths(t *testing.T) {
	key := bytes.Repeat([]byte{11}, 32)
	channel := live.Channel{ID: uuid.New(), UserID: uuid.New(), Slug: "release", Policy: "hidden"}
	now := time.Now()
	token, err := auth.SignViewer(key, auth.ViewerClaims{
		ChannelID: channel.ID,
		UserID:    channel.UserID,
		Slug:      channel.Slug,
		Policy:    channel.Policy,
		IssuedAt:  now.Unix(),
		ExpiresAt: now.Add(time.Minute).Unix(),
		Scope:     "channel:live",
	})
	if err != nil {
		t.Fatal(err)
	}
	tests := []struct {
		name       string
		store      *stubLiveStore
		writer     http.ResponseWriter
		lastEvent  string
		wantStatus int
	}{
		{
			name: "channel rejected",
			store: &stubLiveStore{channel: func(context.Context, uuid.UUID, string) (live.Channel, error) {
				return live.Channel{}, live.ErrNotFound
			}},
			writer:     httptest.NewRecorder(),
			wantStatus: http.StatusUnauthorized,
		},
		{
			name: "stream unsupported",
			store: &stubLiveStore{channel: func(context.Context, uuid.UUID, string) (live.Channel, error) {
				return channel, nil
			}},
			writer:     newNonFlusherWriter(),
			wantStatus: http.StatusInternalServerError,
		},
		{
			name: "invalid replay position",
			store: &stubLiveStore{channel: func(context.Context, uuid.UUID, string) (live.Channel, error) {
				return channel, nil
			}},
			writer:     httptest.NewRecorder(),
			lastEvent:  "not-a-uuid",
			wantStatus: http.StatusOK,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			registry := newSSEConnectionRegistry()
			server := &Server{
				key:     key,
				hub:     live.NewHub(4),
				streams: registry,
				live:    test.store,
			}
			request := httptest.NewRequest(http.MethodGet, "/v1/channels/release/stream", nil)
			request.SetPathValue("slug", channel.Slug)
			request.Header.Set("Authorization", "Bearer "+token)
			if test.lastEvent != "" {
				request.Header.Set("Last-Event-ID", test.lastEvent)
			}
			server.stream(test.writer, request)
			status := responseStatus(test.writer)
			if status != test.wantStatus {
				t.Fatalf("status=%d, want %d", status, test.wantStatus)
			}
			assertEmptySSERegistry(t, registry)
			if server.hub.Count(channel.ID) != 0 {
				t.Fatalf("hub retained subscription")
			}
		})
	}
}

func TestClientIPUsesOnlyTrustedProxyHeaders(t *testing.T) {
	trusted := netip.MustParsePrefix("10.0.0.0/8")
	server := &Server{proxies: []netip.Prefix{trusted}}
	request := httptest.NewRequest(http.MethodGet, "/", nil)
	request.RemoteAddr = "10.1.2.3:1234"
	request.Header.Set("X-Forwarded-For", "203.0.113.8, 10.1.2.3")
	if got := server.clientIP(request); got != "203.0.113.8" {
		t.Fatalf("trusted proxy client IP=%q", got)
	}
	request.RemoteAddr = "192.0.2.9:1234"
	request.Header.Set("X-Forwarded-For", "203.0.113.99")
	if got := server.clientIP(request); got != "192.0.2.9" {
		t.Fatalf("untrusted proxy client IP=%q", got)
	}
}

type streamTestWriter struct {
	mu     sync.Mutex
	header http.Header
	body   strings.Builder
	cancel context.CancelFunc
	stopAt string
	status int
}

func newStreamTestWriter(cancel context.CancelFunc, stopAt string) *streamTestWriter {
	return &streamTestWriter{
		header: http.Header{},
		cancel: cancel,
		stopAt: stopAt,
		status: http.StatusOK,
	}
}

func (w *streamTestWriter) Header() http.Header { return w.header }

func (w *streamTestWriter) WriteHeader(status int) { w.status = status }

func (w *streamTestWriter) Write(data []byte) (int, error) {
	w.mu.Lock()
	written, err := w.body.Write(data)
	shouldCancel := w.stopAt != "" && strings.Contains(w.body.String(), w.stopAt)
	w.mu.Unlock()
	if shouldCancel {
		w.cancel()
	}
	return written, err
}

func (*streamTestWriter) Flush() {}

func (w *streamTestWriter) String() string {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.body.String()
}

type nonFlusherWriter struct {
	header http.Header
	body   strings.Builder
	status int
}

func newNonFlusherWriter() *nonFlusherWriter {
	return &nonFlusherWriter{header: http.Header{}, status: http.StatusOK}
}

func (w *nonFlusherWriter) Header() http.Header            { return w.header }
func (w *nonFlusherWriter) WriteHeader(status int)         { w.status = status }
func (w *nonFlusherWriter) Write(data []byte) (int, error) { return w.body.Write(data) }

func responseStatus(writer http.ResponseWriter) int {
	switch value := writer.(type) {
	case *httptest.ResponseRecorder:
		return value.Code
	case *nonFlusherWriter:
		return value.status
	default:
		return http.StatusOK
	}
}

func decodeSSESample(t *testing.T, body string) live.SampleView {
	t.Helper()
	for _, line := range strings.Split(body, "\n") {
		if !strings.HasPrefix(line, "data: ") {
			continue
		}
		var sample live.SampleView
		if err := json.Unmarshal([]byte(strings.TrimPrefix(line, "data: ")), &sample); err != nil {
			t.Fatal(err)
		}
		return sample
	}
	t.Fatalf("SSE sample missing from %q", body)
	return live.SampleView{}
}

func assertOptionalInt(t *testing.T, name string, got, want *int) {
	t.Helper()
	if want == nil {
		if got != nil {
			t.Fatalf("%s=%d, want hidden", name, *got)
		}
		return
	}
	if got == nil || *got != *want {
		t.Fatalf("%s=%v, want %d", name, got, *want)
	}
}

func intPointer(value int) *int { return &value }
