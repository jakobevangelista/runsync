package telemetry

import (
	"testing"
	"time"

	"github.com/google/uuid"
)

func validBatch() Batch {
	return Batch{InstallationID: uuid.New(), Envelopes: []Envelope{{EnvelopeID: uuid.New(), ActivityID: uuid.New(), GarminDeviceIdentifier: uuid.New(), PhoneReceivedAt: time.Now(), AppVersion: "1", Sample: Sample{ProtocolVersion: 1, State: 1}}}}
}
func TestBatchValidation(t *testing.T) {
	b := validBatch()
	if err := b.Validate(time.Now()); err != nil {
		t.Fatal(err)
	}
	lat := 1
	b.Envelopes[0].Sample.LatitudeMicrodegrees = &lat
	if err := b.Validate(time.Now()); err == nil {
		t.Fatal("half coordinate pair accepted")
	}
	lon := 181000000
	b.Envelopes[0].Sample.LongitudeMicrodegrees = &lon
	if err := b.Validate(time.Now()); err == nil {
		t.Fatal("invalid longitude accepted")
	}
}
func TestMetricBounds(t *testing.T) {
	tests := []struct {
		name   string
		mutate func(*Sample)
	}{{"protocol", func(s *Sample) { s.ProtocolVersion = 2 }}, {"sequence", func(s *Sample) { s.Sequence = int(int64(2147483647) + 1) }}, {"state", func(s *Sample) { s.State = 5 }}, {"heart", func(s *Sample) { v := 301; s.HeartRateBPM = &v }}, {"cadence", func(s *Sample) { v := -1; s.CadenceRPM = &v }}, {"gps", func(s *Sample) { v := int16(5); s.GPSQuality = &v }}, {"altitude", func(s *Sample) { v := int(int64(2147483647) + 1); s.AltitudeDecimeters = &v }}}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			s := Sample{ProtocolVersion: 1}
			tc.mutate(&s)
			if s.Validate() == nil {
				t.Fatal("invalid metric accepted")
			}
		})
	}
}
