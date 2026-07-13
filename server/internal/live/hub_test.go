package live

import (
	"github.com/google/uuid"
	"github.com/jakobevangelista/runsync/server/internal/telemetry"
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

func TestWaitingStateName(t *testing.T) {
	if got := stateName(0); got != "waiting" {
		t.Fatalf("state 0 = %q", got)
	}
}
