package live

import (
	"encoding/json"
	"github.com/google/uuid"
	"github.com/jakobevangelista/runsync/server/internal/telemetry"
	"strings"
	"testing"
)

func TestSlowSubscriberDisconnected(t *testing.T) {
	h := NewHub(1)
	id := uuid.New()
	sub := h.Subscribe(id)
	h.Publish(id, Message{Kind: "sample", Event: telemetry.Event{}})
	h.Publish(id, Message{Kind: "sample", Event: telemetry.Event{}})
	if h.Count(id) != 0 {
		t.Fatal("slow subscriber retained")
	}
	<-sub.C
	if _, open := <-sub.C; open {
		t.Fatal("subscriber channel open")
	}
}
func TestLocationPolicy(t *testing.T) {
	lat, lon := 37774920, -122419380
	e := telemetry.Event{}
	e.Envelope.Sample.LatitudeMicrodegrees = &lat
	e.Envelope.Sample.LongitudeMicrodegrees = &lon
	hidden := EventView(e, "hidden", nil)
	if hidden.LatitudeMicrodegrees != nil {
		t.Fatal("hidden coordinates leaked")
	}
	d := int16(3)
	rounded := EventView(e, "rounded", &d)
	if *rounded.LatitudeMicrodegrees != 37775000 || *rounded.LongitudeMicrodegrees != -122419000 {
		t.Fatalf("wrong rounding: %d,%d", *rounded.LatitudeMicrodegrees, *rounded.LongitudeMicrodegrees)
	}
}

func TestEventViewOmitsPrivateWatchDiagnostics(t *testing.T) {
	build := "e4764923abcd"
	timeouts, errors, exceptions, failures := 1, 2, 3, 4
	outcome := int16(3)
	e := telemetry.Event{}
	e.Envelope.Sample.WatchBuildID = &build
	e.Envelope.Sample.TransportTimeoutCount = &timeouts
	e.Envelope.Sample.TransportErrorCount = &errors
	e.Envelope.Sample.TransportExceptionCount = &exceptions
	e.Envelope.Sample.TransportConsecutiveFailures = &failures
	e.Envelope.Sample.TransportLastOutcome = &outcome

	body, err := json.Marshal(EventView(e, "precise", nil))
	if err != nil {
		t.Fatal(err)
	}
	encoded := string(body)
	for _, field := range []string{"watchBuild", "transportTimeout", "transportError", "transportException", "transportConsecutive", "transportLastOutcome"} {
		if strings.Contains(encoded, field) {
			t.Fatalf("public event leaked %q in %s", field, encoded)
		}
	}
}

func TestWaitingStateName(t *testing.T) {
	if got := stateName(0); got != "waiting" {
		t.Fatalf("state 0 = %q", got)
	}
}
