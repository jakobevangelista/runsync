package telemetry

import (
	"fmt"
	"time"

	"github.com/google/uuid"
)

const MaxBatch = 100

type Batch struct {
	InstallationID uuid.UUID  `json:"installationId"`
	Envelopes      []Envelope `json:"envelopes"`
}

type Envelope struct {
	EnvelopeID             uuid.UUID `json:"envelopeId"`
	ActivityID             uuid.UUID `json:"activityId"`
	PhoneReceivedAt        time.Time `json:"phoneReceivedAt"`
	GarminDeviceIdentifier uuid.UUID `json:"garminDeviceIdentifier"`
	AppVersion             string    `json:"appVersion"`
	Sample                 Sample    `json:"sample"`
}

type Sample struct {
	ProtocolVersion           int    `json:"protocolVersion"`
	Sequence                  int    `json:"sequence"`
	State                     int16  `json:"state"`
	ActivityStartEpochSeconds *int   `json:"activityStartEpochSeconds,omitempty"`
	ElapsedTimeMilliseconds   *int   `json:"elapsedTimeMilliseconds,omitempty"`
	DistanceDecimeters        *int   `json:"distanceDecimeters,omitempty"`
	SpeedMillimetersPerSecond *int   `json:"speedMillimetersPerSecond,omitempty"`
	HeartRateBPM              *int   `json:"heartRateBPM,omitempty"`
	CadenceRPM                *int   `json:"cadenceRPM,omitempty"`
	LatitudeMicrodegrees      *int   `json:"latitudeMicrodegrees,omitempty"`
	LongitudeMicrodegrees     *int   `json:"longitudeMicrodegrees,omitempty"`
	GPSQuality                *int16 `json:"gpsQuality,omitempty"`
	AltitudeDecimeters        *int   `json:"altitudeDecimeters,omitempty"`
	TotalAscentMeters         *int   `json:"totalAscentMeters,omitempty"`
}

func (b Batch) Validate(now time.Time) error {
	if b.InstallationID == uuid.Nil {
		return fmt.Errorf("installationId is required")
	}
	if len(b.Envelopes) == 0 || len(b.Envelopes) > MaxBatch {
		return fmt.Errorf("envelopes must contain 1..%d entries", MaxBatch)
	}
	seen := map[uuid.UUID]bool{}
	for i, e := range b.Envelopes {
		if e.EnvelopeID == uuid.Nil || e.ActivityID == uuid.Nil || e.GarminDeviceIdentifier == uuid.Nil {
			return fmt.Errorf("envelopes[%d]: identifiers are required", i)
		}
		if seen[e.EnvelopeID] {
			return fmt.Errorf("envelopes[%d]: duplicate envelopeId in batch", i)
		}
		seen[e.EnvelopeID] = true
		if e.PhoneReceivedAt.IsZero() || e.PhoneReceivedAt.After(now.Add(5*time.Minute)) {
			return fmt.Errorf("envelopes[%d]: invalid phoneReceivedAt", i)
		}
		if len(e.AppVersion) < 1 || len(e.AppVersion) > 64 {
			return fmt.Errorf("envelopes[%d]: invalid appVersion", i)
		}
		if err := e.Sample.Validate(); err != nil {
			return fmt.Errorf("envelopes[%d]: %w", i, err)
		}
	}
	return nil
}

func (s Sample) Validate() error {
	if s.ProtocolVersion != 1 {
		return fmt.Errorf("unsupported protocolVersion")
	}
	if s.Sequence < 0 || int64(s.Sequence) > 2147483647 || s.State < 0 || s.State > 4 {
		return fmt.Errorf("invalid sequence or state")
	}
	if err := bounded("activityStartEpochSeconds", s.ActivityStartEpochSeconds, 0, 2147483647); err != nil {
		return err
	}
	for name, value := range map[string]*int{"elapsedTimeMilliseconds": s.ElapsedTimeMilliseconds, "distanceDecimeters": s.DistanceDecimeters, "speedMillimetersPerSecond": s.SpeedMillimetersPerSecond, "totalAscentMeters": s.TotalAscentMeters} {
		if err := bounded(name, value, 0, 2147483647); err != nil {
			return err
		}
	}
	if err := bounded("heartRateBPM", s.HeartRateBPM, 0, 300); err != nil {
		return err
	}
	if err := bounded("cadenceRPM", s.CadenceRPM, 0, 300); err != nil {
		return err
	}
	if (s.LatitudeMicrodegrees == nil) != (s.LongitudeMicrodegrees == nil) {
		return fmt.Errorf("coordinates must both be present or absent")
	}
	if err := bounded("latitudeMicrodegrees", s.LatitudeMicrodegrees, -90000000, 90000000); err != nil {
		return err
	}
	if err := bounded("longitudeMicrodegrees", s.LongitudeMicrodegrees, -180000000, 180000000); err != nil {
		return err
	}
	if s.GPSQuality != nil && (*s.GPSQuality < 0 || *s.GPSQuality > 4) {
		return fmt.Errorf("gpsQuality is out of range")
	}
	if err := bounded("altitudeDecimeters", s.AltitudeDecimeters, -2147483648, 2147483647); err != nil {
		return err
	}
	return nil
}

func bounded(name string, value *int, min, max int) error {
	if value != nil && (*value < min || *value > max) {
		return fmt.Errorf("%s is out of range", name)
	}
	return nil
}

type Event struct {
	Envelope         Envelope  `json:"envelope"`
	ServerReceivedAt time.Time `json:"serverReceivedAt"`
	IngestCursor     int64     `json:"-"`
}
