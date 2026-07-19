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
func (*stubLiveStore) Replay(context.Context, live.Channel, uuid.UUID, int) ([]live.SampleView, bool, error) {
	return nil, false, nil
}

func TestStreamSubscribesBeforeActiveChannelLookup(t *testing.T) {
	key := bytes.Repeat([]byte{7}, 32)
	channel := live.Channel{ID: uuid.New(), UserID: uuid.New(), Slug: "transition", Policy: "hidden"}
	event := telemetry.Event{Envelope: telemetry.Envelope{EnvelopeID: uuid.New(), ActivityID: uuid.New(), Sample: telemetry.Sample{State: 1}}}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	store := &stubLiveStore{}
	server := &Server{live: store, hub: live.NewHub(4), key: key}
	lookups := 0
	subscribedAtLookup := false
	store.channel = func(context.Context, uuid.UUID, string) (live.Channel, error) {
		lookups++
		if lookups == 1 {
			subscribedAtLookup = server.hub.Count(channel.ID) == 1
			server.hub.Publish(channel.ID, live.Message{Kind: "activity", Event: event})
		} else {
			cancel()
		}
		return channel, nil
	}
	now := time.Now()
	token, err := auth.SignViewer(key, auth.ViewerClaims{ChannelID: channel.ID, UserID: channel.UserID, Slug: channel.Slug, Policy: channel.Policy, IssuedAt: now.Unix(), ExpiresAt: now.Add(time.Minute).Unix(), Scope: "channel:live"})
	if err != nil {
		t.Fatal(err)
	}
	request := httptest.NewRequest(http.MethodGet, "/v1/channels/transition/stream", nil).WithContext(ctx)
	request.SetPathValue("slug", channel.Slug)
	request.Header.Set("Authorization", "Bearer "+token)
	response := httptest.NewRecorder()
	server.stream(response, request)
	if !subscribedAtLookup {
		t.Fatal("stream was not subscribed during active-channel lookup")
	}
	if !strings.Contains(response.Body.String(), "event: activity") || !strings.Contains(response.Body.String(), event.Envelope.EnvelopeID.String()) {
		t.Fatalf("transition published during lookup was lost: %q", response.Body.String())
	}
}
