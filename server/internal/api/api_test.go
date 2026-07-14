package api

import (
	"bytes"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/google/uuid"
	"github.com/jakobevangelista/runsync/server/internal/ingest"
	"github.com/jakobevangelista/runsync/server/internal/live"
	"github.com/jakobevangelista/runsync/server/internal/telemetry"
)

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
		name, body string
		status     int
	}{{"unknown", `{"unknown":1}`, 400}, {"large", `{"value":"` + string(bytes.Repeat([]byte{'x'}, maxBody)) + `"}`, 413}} {
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
		})
	}
}

func TestPublishIngestSendsTransitionBeforeSamples(t *testing.T) {
	channelID, activityID := uuid.New(), uuid.New()
	transition := telemetry.Event{Envelope: telemetry.Envelope{EnvelopeID: uuid.New(), ActivityID: activityID}}
	sample := telemetry.Event{Envelope: telemetry.Envelope{EnvelopeID: uuid.New(), ActivityID: activityID}}
	s := &Server{hub: live.NewHub(3)}
	sub := s.hub.Subscribe(channelID)
	defer sub.Close()

	s.publishIngest(ingest.Result{
		Events:      []telemetry.Event{transition, sample},
		Transitions: []telemetry.Event{transition},
		Channels:    map[uuid.UUID][]uuid.UUID{activityID: {channelID}},
	})

	for i, want := range []struct {
		kind string
		id   uuid.UUID
	}{{"activity", transition.Envelope.EnvelopeID}, {"sample", transition.Envelope.EnvelopeID}, {"sample", sample.Envelope.EnvelopeID}} {
		message := <-sub.C
		if message.Kind != want.kind || message.Event.Envelope.EnvelopeID != want.id {
			t.Fatalf("message %d = %s/%s, want %s/%s", i, message.Kind, message.Event.Envelope.EnvelopeID, want.kind, want.id)
		}
	}
}
