package telemetry

import (
	"errors"
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

func TestWatchDiagnosticValidation(t *testing.T) {
	build := "e4764923abcd-dirty"
	timeouts, errors, exceptions, failures := 1, 2, 3, 4
	outcome := int16(3)
	s := Sample{
		ProtocolVersion:              1,
		State:                        1,
		WatchBuildID:                 &build,
		TransportTimeoutCount:        &timeouts,
		TransportErrorCount:          &errors,
		TransportExceptionCount:      &exceptions,
		TransportConsecutiveFailures: &failures,
		TransportLastOutcome:         &outcome,
	}
	if err := s.Validate(); err != nil {
		t.Fatalf("valid diagnostics rejected: %v", err)
	}

	tests := []struct {
		name   string
		mutate func(*Sample)
	}{
		{"empty build", func(s *Sample) { v := ""; s.WatchBuildID = &v }},
		{"long build", func(s *Sample) { v := "123456789012345678901234567890123"; s.WatchBuildID = &v }},
		{"unsafe build", func(s *Sample) { v := "bad value"; s.WatchBuildID = &v }},
		{"negative timeout", func(s *Sample) { v := -1; s.TransportTimeoutCount = &v }},
		{"large errors", func(s *Sample) { v := int(int64(2147483647) + 1); s.TransportErrorCount = &v }},
		{"bad outcome", func(s *Sample) { v := int16(5); s.TransportLastOutcome = &v }},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			candidate := s
			tc.mutate(&candidate)
			if candidate.Validate() == nil {
				t.Fatal("invalid diagnostics accepted")
			}
		})
	}
}

func TestBatchValidationClassifiesSafeEnvelopeAttribution(t *testing.T) {
	now := time.Now()
	envelopeID := uuid.New()
	tests := []struct {
		name       string
		mutate     func(*Batch)
		code       ValidationCode
		envelopeID *uuid.UUID
	}{
		{
			name: "request-wide",
			mutate: func(b *Batch) {
				b.InstallationID = uuid.Nil
			},
			code: ValidationInvalidRequest,
		},
		{
			name: "unsupported protocol is request-wide",
			mutate: func(b *Batch) {
				b.Envelopes[0].Sample.ProtocolVersion = 2
			},
			code: ValidationUnsupportedProtocol,
		},
		{
			name: "unsupported protocol takes request-wide precedence",
			mutate: func(b *Batch) {
				b.Envelopes[0].Sample.State = 5
				second := b.Envelopes[0]
				second.EnvelopeID = uuid.New()
				second.Sample.State = 1
				second.Sample.ProtocolVersion = 2
				b.Envelopes = append(b.Envelopes, second)
			},
			code: ValidationUnsupportedProtocol,
		},
		{
			name: "identified invalid envelope",
			mutate: func(b *Batch) {
				b.Envelopes[0].EnvelopeID = envelopeID
				b.Envelopes[0].Sample.State = 5
			},
			code:       ValidationInvalidEnvelope,
			envelopeID: &envelopeID,
		},
		{
			name: "invalid envelope without safe identifier",
			mutate: func(b *Batch) {
				b.Envelopes[0].EnvelopeID = uuid.Nil
			},
			code: ValidationInvalidEnvelope,
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			batch := validBatch()
			tc.mutate(&batch)
			var validation *ValidationError
			if err := batch.Validate(now); !errors.As(err, &validation) {
				t.Fatalf("error = %v, want ValidationError", err)
			}
			if validation.Code != tc.code {
				t.Fatalf("code = %q, want %q", validation.Code, tc.code)
			}
			if tc.envelopeID == nil {
				if validation.EnvelopeID != nil {
					t.Fatalf("envelope ID = %s, want nil", validation.EnvelopeID)
				}
			} else if validation.EnvelopeID == nil || *validation.EnvelopeID != *tc.envelopeID {
				t.Fatalf("envelope ID = %v, want %s", validation.EnvelopeID, *tc.envelopeID)
			}
		})
	}
}
