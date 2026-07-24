package telemetry

import (
	"errors"
	"fmt"
	"regexp"
	"time"

	"github.com/google/uuid"
)

const MaxBatch = 100
const maxDiagnosticCounter = 2147483647

var watchBuildIDPattern = regexp.MustCompile(`^[A-Za-z0-9._+-]{1,32}$`)

type ValidationCode string

const (
	ValidationInvalidRequest      ValidationCode = "invalid_request"
	ValidationInvalidEnvelope     ValidationCode = "invalid_envelope"
	ValidationUnsupportedProtocol ValidationCode = "unsupported_protocol"
)

type ValidationError struct {
	Code       ValidationCode
	EnvelopeID *uuid.UUID
	reason     string
}

func (e *ValidationError) Error() string { return e.reason }

func validationError(code ValidationCode, envelopeID *uuid.UUID, reason string) error {
	return &ValidationError{Code: code, EnvelopeID: envelopeID, reason: reason}
}

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
	ProtocolVersion              int     `json:"protocolVersion"`
	Sequence                     int     `json:"sequence"`
	State                        int16   `json:"state"`
	ActivityStartEpochSeconds    *int    `json:"activityStartEpochSeconds,omitempty"`
	ElapsedTimeMilliseconds      *int    `json:"elapsedTimeMilliseconds,omitempty"`
	DistanceDecimeters           *int    `json:"distanceDecimeters,omitempty"`
	SpeedMillimetersPerSecond    *int    `json:"speedMillimetersPerSecond,omitempty"`
	HeartRateBPM                 *int    `json:"heartRateBPM,omitempty"`
	CadenceRPM                   *int    `json:"cadenceRPM,omitempty"`
	LatitudeMicrodegrees         *int    `json:"latitudeMicrodegrees,omitempty"`
	LongitudeMicrodegrees        *int    `json:"longitudeMicrodegrees,omitempty"`
	GPSQuality                   *int16  `json:"gpsQuality,omitempty"`
	AltitudeDecimeters           *int    `json:"altitudeDecimeters,omitempty"`
	TotalAscentMeters            *int    `json:"totalAscentMeters,omitempty"`
	WatchBuildID                 *string `json:"watchBuildID,omitempty"`
	TransportTimeoutCount        *int    `json:"transportTimeoutCount,omitempty"`
	TransportErrorCount          *int    `json:"transportErrorCount,omitempty"`
	TransportExceptionCount      *int    `json:"transportExceptionCount,omitempty"`
	TransportConsecutiveFailures *int    `json:"transportConsecutiveFailures,omitempty"`
	TransportLastOutcome         *int16  `json:"transportLastOutcome,omitempty"`
}

func (b Batch) Validate(now time.Time) error {
	if b.InstallationID == uuid.Nil {
		return validationError(ValidationInvalidRequest, nil, "installationId is required")
	}
	if len(b.Envelopes) == 0 || len(b.Envelopes) > MaxBatch {
		return validationError(ValidationInvalidRequest, nil, fmt.Sprintf("envelopes must contain 1..%d entries", MaxBatch))
	}
	for i, e := range b.Envelopes {
		if e.Sample.ProtocolVersion != 1 {
			return validationError(ValidationUnsupportedProtocol, nil, fmt.Sprintf("envelopes[%d]: unsupported protocolVersion", i))
		}
	}
	seen := map[uuid.UUID]bool{}
	for i, e := range b.Envelopes {
		if e.EnvelopeID == uuid.Nil || e.ActivityID == uuid.Nil || e.GarminDeviceIdentifier == uuid.Nil {
			return invalidEnvelope(e.EnvelopeID, fmt.Sprintf("envelopes[%d]: identifiers are required", i))
		}
		if seen[e.EnvelopeID] {
			return invalidEnvelope(e.EnvelopeID, fmt.Sprintf("envelopes[%d]: duplicate envelopeId in batch", i))
		}
		seen[e.EnvelopeID] = true
		if e.PhoneReceivedAt.IsZero() || e.PhoneReceivedAt.After(now.Add(5*time.Minute)) {
			return invalidEnvelope(e.EnvelopeID, fmt.Sprintf("envelopes[%d]: invalid phoneReceivedAt", i))
		}
		if len(e.AppVersion) < 1 || len(e.AppVersion) > 64 {
			return invalidEnvelope(e.EnvelopeID, fmt.Sprintf("envelopes[%d]: invalid appVersion", i))
		}
		if err := e.Sample.Validate(); err != nil {
			var validation *ValidationError
			if errors.As(err, &validation) && validation.Code == ValidationUnsupportedProtocol {
				return validationError(ValidationUnsupportedProtocol, nil, fmt.Sprintf("envelopes[%d]: %s", i, err))
			}
			return invalidEnvelope(e.EnvelopeID, fmt.Sprintf("envelopes[%d]: %s", i, err))
		}
	}
	return nil
}

func invalidEnvelope(envelopeID uuid.UUID, reason string) error {
	if envelopeID == uuid.Nil {
		return validationError(ValidationInvalidEnvelope, nil, reason)
	}
	id := envelopeID
	return validationError(ValidationInvalidEnvelope, &id, reason)
}

func (s Sample) Validate() error {
	if s.ProtocolVersion != 1 {
		return validationError(ValidationUnsupportedProtocol, nil, "unsupported protocolVersion")
	}
	if s.Sequence < 0 || int64(s.Sequence) > 2147483647 || s.State < 0 || s.State > 4 {
		return validationError(ValidationInvalidEnvelope, nil, "invalid sequence or state")
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
		return validationError(ValidationInvalidEnvelope, nil, "coordinates must both be present or absent")
	}
	if err := bounded("latitudeMicrodegrees", s.LatitudeMicrodegrees, -90000000, 90000000); err != nil {
		return err
	}
	if err := bounded("longitudeMicrodegrees", s.LongitudeMicrodegrees, -180000000, 180000000); err != nil {
		return err
	}
	if s.GPSQuality != nil && (*s.GPSQuality < 0 || *s.GPSQuality > 4) {
		return validationError(ValidationInvalidEnvelope, nil, "gpsQuality is out of range")
	}
	if err := bounded("altitudeDecimeters", s.AltitudeDecimeters, -2147483648, 2147483647); err != nil {
		return err
	}
	if s.WatchBuildID != nil && !watchBuildIDPattern.MatchString(*s.WatchBuildID) {
		return validationError(ValidationInvalidEnvelope, nil, "watchBuildID is invalid")
	}
	for name, value := range map[string]*int{
		"transportTimeoutCount":        s.TransportTimeoutCount,
		"transportErrorCount":          s.TransportErrorCount,
		"transportExceptionCount":      s.TransportExceptionCount,
		"transportConsecutiveFailures": s.TransportConsecutiveFailures,
	} {
		if err := bounded(name, value, 0, maxDiagnosticCounter); err != nil {
			return err
		}
	}
	if s.TransportLastOutcome != nil && (*s.TransportLastOutcome < 0 || *s.TransportLastOutcome > 4) {
		return validationError(ValidationInvalidEnvelope, nil, "transportLastOutcome is out of range")
	}
	return nil
}

func bounded(name string, value *int, min, max int) error {
	if value != nil && (*value < min || *value > max) {
		return validationError(ValidationInvalidEnvelope, nil, fmt.Sprintf("%s is out of range", name))
	}
	return nil
}

type Event struct {
	Envelope         Envelope  `json:"envelope"`
	ServerReceivedAt time.Time `json:"serverReceivedAt"`
	IngestCursor     int64     `json:"-"`
}
