package live

import (
	"context"
	"errors"
	"math"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jakobevangelista/runsync/server/internal/telemetry"
)

var ErrNotFound = errors.New("channel not found")

type Channel struct {
	ID, UserID                uuid.UUID
	Slug, DisplayName, Policy string
	Decimals                  *int16
	ActivityID                *uuid.UUID
}
type Store struct{ pool *pgxpool.Pool }

func NewStore(pool *pgxpool.Pool) *Store { return &Store{pool: pool} }

func (s *Store) Channel(ctx context.Context, user uuid.UUID, slug string) (Channel, error) {
	var c Channel
	err := s.pool.QueryRow(ctx, `SELECT id,user_id,slug,display_name,location_policy,coordinate_decimals,active_activity_id FROM live_channels WHERE user_id=$1 AND slug=$2`, user, slug).Scan(&c.ID, &c.UserID, &c.Slug, &c.DisplayName, &c.Policy, &c.Decimals, &c.ActivityID)
	if errors.Is(err, pgx.ErrNoRows) {
		return c, ErrNotFound
	}
	return c, err
}
func (s *Store) ChannelBySlug(ctx context.Context, slug string) (Channel, error) {
	var c Channel
	err := s.pool.QueryRow(ctx, `SELECT id,user_id,slug,display_name,location_policy,coordinate_decimals,active_activity_id FROM live_channels WHERE slug=$1`, slug).Scan(&c.ID, &c.UserID, &c.Slug, &c.DisplayName, &c.Policy, &c.Decimals, &c.ActivityID)
	if errors.Is(err, pgx.ErrNoRows) {
		return c, ErrNotFound
	}
	return c, err
}

type SampleView struct {
	EnvelopeID                uuid.UUID `json:"envelopeId"`
	PhoneReceivedAt           time.Time `json:"phoneReceivedAt"`
	ServerReceivedAt          time.Time `json:"serverReceivedAt"`
	ProtocolVersion           int       `json:"protocolVersion"`
	Sequence                  int       `json:"sequence"`
	State                     int16     `json:"state"`
	ActivityStartEpochSeconds *int      `json:"activityStartEpochSeconds,omitempty"`
	ElapsedTimeMilliseconds   *int      `json:"elapsedTimeMilliseconds,omitempty"`
	DistanceDecimeters        *int      `json:"distanceDecimeters,omitempty"`
	SpeedMillimetersPerSecond *int      `json:"speedMillimetersPerSecond,omitempty"`
	HeartRateBPM              *int      `json:"heartRateBPM,omitempty"`
	CadenceRPM                *int      `json:"cadenceRPM,omitempty"`
	LatitudeMicrodegrees      *int      `json:"latitudeMicrodegrees,omitempty"`
	LongitudeMicrodegrees     *int      `json:"longitudeMicrodegrees,omitempty"`
	GPSQuality                *int16    `json:"gpsQuality,omitempty"`
	AltitudeDecimeters        *int      `json:"altitudeDecimeters,omitempty"`
	TotalAscentMeters         *int      `json:"totalAscentMeters,omitempty"`
}
type Snapshot struct {
	ChannelID                   uuid.UUID    `json:"channelId"`
	Slug                        string       `json:"slug"`
	ActivityID                  *uuid.UUID   `json:"activityId,omitempty"`
	Status                      string       `json:"status"`
	Latest                      *SampleView  `json:"latest,omitempty"`
	LatestSampleAgeMilliseconds *int64       `json:"latestSampleAgeMilliseconds,omitempty"`
	Route                       []SampleView `json:"route"`
	ServerTime                  time.Time    `json:"serverTime"`
}

func (s *Store) Snapshot(ctx context.Context, c Channel, now time.Time) (Snapshot, error) {
	out := Snapshot{ChannelID: c.ID, Slug: c.Slug, ActivityID: c.ActivityID, Status: "offline", Route: []SampleView{}, ServerTime: now}
	if c.ActivityID == nil {
		return out, nil
	}
	rows, err := s.pool.Query(ctx, `SELECT envelope_id,phone_received_at,server_received_at,protocol_version,watch_sequence,activity_state,garmin_activity_start_epoch_seconds,elapsed_time_milliseconds,distance_decimeters,speed_millimeters_per_second,heart_rate_bpm,cadence_rpm,latitude_microdegrees,longitude_microdegrees,gps_quality,altitude_decimeters,total_ascent_meters FROM telemetry_samples WHERE user_id=$1 AND activity_id=$2 AND phone_received_at >= $3 ORDER BY phone_received_at DESC,ingest_cursor DESC LIMIT 500`, c.UserID, *c.ActivityID, now.Add(-30*time.Minute))
	if err != nil {
		return out, err
	}
	defer rows.Close()
	for rows.Next() {
		v, err := scanView(rows)
		if err != nil {
			return out, err
		}
		applyPolicy(&v, c.Policy, c.Decimals)
		if out.Latest == nil {
			x := v
			out.Latest = &x
			age := now.Sub(v.PhoneReceivedAt).Milliseconds()
			if age < 0 {
				age = 0
			}
			out.LatestSampleAgeMilliseconds = &age
			out.Status = stateName(v.State)
		}
		out.Route = append(out.Route, v)
	}
	for i, j := 0, len(out.Route)-1; i < j; i, j = i+1, j-1 {
		out.Route[i], out.Route[j] = out.Route[j], out.Route[i]
	}
	return out, rows.Err()
}

func (s *Store) Replay(ctx context.Context, c Channel, last uuid.UUID, limit int) ([]SampleView, bool, error) {
	if c.ActivityID == nil {
		return nil, false, nil
	}
	var cursor int64
	err := s.pool.QueryRow(ctx, `SELECT ingest_cursor FROM telemetry_samples WHERE envelope_id=$1 AND user_id=$2`, last, c.UserID).Scan(&cursor)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, true, nil
	}
	if err != nil {
		return nil, false, err
	}
	rows, err := s.pool.Query(ctx, `SELECT envelope_id,phone_received_at,server_received_at,protocol_version,watch_sequence,activity_state,garmin_activity_start_epoch_seconds,elapsed_time_milliseconds,distance_decimeters,speed_millimeters_per_second,heart_rate_bpm,cadence_rpm,latitude_microdegrees,longitude_microdegrees,gps_quality,altitude_decimeters,total_ascent_meters FROM telemetry_samples WHERE user_id=$1 AND activity_id=$2 AND ingest_cursor>$3 ORDER BY ingest_cursor LIMIT $4`, c.UserID, *c.ActivityID, cursor, limit+1)
	if err != nil {
		return nil, false, err
	}
	defer rows.Close()
	var out []SampleView
	for rows.Next() {
		v, e := scanView(rows)
		if e != nil {
			return nil, false, e
		}
		applyPolicy(&v, c.Policy, c.Decimals)
		out = append(out, v)
	}
	if len(out) > limit {
		return nil, true, nil
	}
	return out, false, rows.Err()
}

type scanner interface{ Scan(...any) error }

func scanView(row scanner) (SampleView, error) {
	var v SampleView
	err := row.Scan(&v.EnvelopeID, &v.PhoneReceivedAt, &v.ServerReceivedAt, &v.ProtocolVersion, &v.Sequence, &v.State, &v.ActivityStartEpochSeconds, &v.ElapsedTimeMilliseconds, &v.DistanceDecimeters, &v.SpeedMillimetersPerSecond, &v.HeartRateBPM, &v.CadenceRPM, &v.LatitudeMicrodegrees, &v.LongitudeMicrodegrees, &v.GPSQuality, &v.AltitudeDecimeters, &v.TotalAscentMeters)
	return v, err
}
func EventView(e telemetry.Event, policy string, decimals *int16) SampleView {
	s := e.Envelope.Sample
	v := SampleView{
		EnvelopeID: e.Envelope.EnvelopeID, PhoneReceivedAt: e.Envelope.PhoneReceivedAt,
		ServerReceivedAt: e.ServerReceivedAt, ProtocolVersion: s.ProtocolVersion,
		Sequence: s.Sequence, State: s.State, ActivityStartEpochSeconds: s.ActivityStartEpochSeconds,
		ElapsedTimeMilliseconds: s.ElapsedTimeMilliseconds, DistanceDecimeters: s.DistanceDecimeters,
		SpeedMillimetersPerSecond: s.SpeedMillimetersPerSecond, HeartRateBPM: s.HeartRateBPM,
		CadenceRPM: s.CadenceRPM, LatitudeMicrodegrees: s.LatitudeMicrodegrees,
		LongitudeMicrodegrees: s.LongitudeMicrodegrees, GPSQuality: s.GPSQuality,
		AltitudeDecimeters: s.AltitudeDecimeters, TotalAscentMeters: s.TotalAscentMeters,
	}
	applyPolicy(&v, policy, decimals)
	return v
}
func applyPolicy(v *SampleView, policy string, decimals *int16) {
	if policy == "hidden" {
		v.LatitudeMicrodegrees = nil
		v.LongitudeMicrodegrees = nil
	} else if policy == "rounded" && decimals != nil {
		round(&v.LatitudeMicrodegrees, *decimals)
		round(&v.LongitudeMicrodegrees, *decimals)
	}
}
func round(value **int, decimals int16) {
	if *value == nil {
		return
	}
	factor := math.Pow10(6 - int(decimals))
	v := int(math.Round(float64(**value)/factor) * factor)
	*value = &v
}
func stateName(v int16) string {
	switch v {
	case 0:
		return "waiting"
	case 1:
		return "running"
	case 2:
		return "paused"
	case 3:
		return "stopped"
	case 4:
		return "ended"
	default:
		return "offline"
	}
}
