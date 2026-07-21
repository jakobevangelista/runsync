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

const maxRoutePoints = 5000

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

type RoutePoint struct {
	EnvelopeID            uuid.UUID `json:"envelopeId"`
	PhoneReceivedAt       time.Time `json:"phoneReceivedAt"`
	LatitudeMicrodegrees  int       `json:"latitudeMicrodegrees"`
	LongitudeMicrodegrees int       `json:"longitudeMicrodegrees"`
	GPSQuality            *int16    `json:"gpsQuality,omitempty"`
}

type Route struct {
	ChannelID      uuid.UUID    `json:"channelId"`
	ActivityID     *uuid.UUID   `json:"activityId"`
	LocationPolicy string       `json:"locationPolicy"`
	Points         []RoutePoint `json:"points"`
	ServerTime     time.Time    `json:"serverTime"`
}

type Bootstrap struct {
	Snapshot              Snapshot   `json:"snapshot"`
	Route                 Route      `json:"route"`
	ReplayAfterEnvelopeID *uuid.UUID `json:"replayAfterEnvelopeId"`
}

func (s *Store) Bootstrap(ctx context.Context, requested Channel, now time.Time) (Bootstrap, error) {
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if err != nil {
		return Bootstrap{}, err
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	out, err := bootstrapTx(ctx, tx, requested, now)
	if err != nil {
		return Bootstrap{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return Bootstrap{}, err
	}
	return out, nil
}

func bootstrapTx(ctx context.Context, tx pgx.Tx, requested Channel, now time.Time) (Bootstrap, error) {
	var out Bootstrap
	var c Channel
	err := tx.QueryRow(ctx, `SELECT id,user_id,slug,display_name,location_policy,coordinate_decimals,active_activity_id FROM live_channels WHERE user_id=$1 AND slug=$2`, requested.UserID, requested.Slug).Scan(&c.ID, &c.UserID, &c.Slug, &c.DisplayName, &c.Policy, &c.Decimals, &c.ActivityID)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && c.ID != requested.ID) {
		return out, ErrNotFound
	}
	if err != nil {
		return out, err
	}
	restrictPolicy(&c, requested.Policy, requested.Decimals)

	out.Snapshot = Snapshot{ChannelID: c.ID, Slug: c.Slug, ActivityID: c.ActivityID, Status: "offline", Route: []SampleView{}, ServerTime: now}
	out.Route = Route{ChannelID: c.ID, ActivityID: c.ActivityID, LocationPolicy: c.Policy, Points: []RoutePoint{}, ServerTime: now}
	if c.ActivityID == nil {
		return out, nil
	}

	var highWater int64
	var highWaterEnvelope uuid.UUID
	err = tx.QueryRow(ctx, `SELECT ingest_cursor,envelope_id FROM telemetry_samples WHERE user_id=$1 AND activity_id=$2 ORDER BY ingest_cursor DESC LIMIT 1`, c.UserID, *c.ActivityID).Scan(&highWater, &highWaterEnvelope)
	if errors.Is(err, pgx.ErrNoRows) {
		return out, nil
	}
	if err != nil {
		return out, err
	}
	out.ReplayAfterEnvelopeID = &highWaterEnvelope

	latest, err := scanView(tx.QueryRow(ctx, `SELECT envelope_id,phone_received_at,server_received_at,protocol_version,watch_sequence,activity_state,garmin_activity_start_epoch_seconds,elapsed_time_milliseconds,distance_decimeters,speed_millimeters_per_second,heart_rate_bpm,cadence_rpm,latitude_microdegrees,longitude_microdegrees,gps_quality,altitude_decimeters,total_ascent_meters FROM telemetry_samples WHERE user_id=$1 AND activity_id=$2 AND ingest_cursor<=$3 ORDER BY phone_received_at DESC,ingest_cursor DESC LIMIT 1`, c.UserID, *c.ActivityID, highWater))
	if err != nil {
		return out, err
	}
	applyPolicy(&latest, c.Policy, c.Decimals)
	out.Snapshot.Latest = &latest
	age := now.Sub(latest.PhoneReceivedAt).Milliseconds()
	if age < 0 {
		age = 0
	}
	out.Snapshot.LatestSampleAgeMilliseconds = &age
	out.Snapshot.Status = stateName(latest.State)

	if c.Policy != "hidden" {
		rows, err := tx.Query(ctx, `SELECT envelope_id,phone_received_at,latitude_microdegrees,longitude_microdegrees,gps_quality FROM telemetry_samples WHERE user_id=$1 AND activity_id=$2 AND ingest_cursor<=$3 AND latitude_microdegrees IS NOT NULL AND longitude_microdegrees IS NOT NULL ORDER BY phone_received_at,envelope_id`, c.UserID, *c.ActivityID, highWater)
		if err != nil {
			return out, err
		}
		for rows.Next() {
			var point RoutePoint
			if err := rows.Scan(&point.EnvelopeID, &point.PhoneReceivedAt, &point.LatitudeMicrodegrees, &point.LongitudeMicrodegrees, &point.GPSQuality); err != nil {
				rows.Close()
				return out, err
			}
			if c.Policy == "rounded" && c.Decimals != nil {
				roundValue(&point.LatitudeMicrodegrees, *c.Decimals)
				roundValue(&point.LongitudeMicrodegrees, *c.Decimals)
			}
			out.Route.Points = append(out.Route.Points, point)
		}
		if err := rows.Err(); err != nil {
			rows.Close()
			return out, err
		}
		rows.Close()
		out.Route.Points = downsample(out.Route.Points, maxRoutePoints)
	}

	return out, nil
}

func (s *Store) Snapshot(ctx context.Context, c Channel, now time.Time) (Snapshot, error) {
	out := Snapshot{ChannelID: c.ID, Slug: c.Slug, ActivityID: c.ActivityID, Status: "offline", Route: []SampleView{}, ServerTime: now}
	if c.ActivityID == nil {
		return out, nil
	}
	latest, err := scanView(s.pool.QueryRow(ctx, `SELECT envelope_id,phone_received_at,server_received_at,protocol_version,watch_sequence,activity_state,garmin_activity_start_epoch_seconds,elapsed_time_milliseconds,distance_decimeters,speed_millimeters_per_second,heart_rate_bpm,cadence_rpm,latitude_microdegrees,longitude_microdegrees,gps_quality,altitude_decimeters,total_ascent_meters FROM telemetry_samples WHERE user_id=$1 AND activity_id=$2 ORDER BY phone_received_at DESC,ingest_cursor DESC LIMIT 1`, c.UserID, *c.ActivityID))
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return out, err
	}
	if err == nil {
		applyPolicy(&latest, c.Policy, c.Decimals)
		out.Latest = &latest
		age := now.Sub(latest.PhoneReceivedAt).Milliseconds()
		if age < 0 {
			age = 0
		}
		out.LatestSampleAgeMilliseconds = &age
		out.Status = stateName(latest.State)
	}
	rows, err := s.pool.Query(ctx, `SELECT envelope_id,phone_received_at,server_received_at,protocol_version,watch_sequence,activity_state,garmin_activity_start_epoch_seconds,elapsed_time_milliseconds,distance_decimeters,speed_millimeters_per_second,heart_rate_bpm,cadence_rpm,latitude_microdegrees,longitude_microdegrees,gps_quality,altitude_decimeters,total_ascent_meters FROM telemetry_samples WHERE user_id=$1 AND activity_id=$2 AND phone_received_at >= $3 ORDER BY phone_received_at DESC,envelope_id DESC LIMIT 500`, c.UserID, *c.ActivityID, now.Add(-30*time.Minute))
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
		out.Route = append(out.Route, v)
	}
	for i, j := 0, len(out.Route)-1; i < j; i, j = i+1, j-1 {
		out.Route[i], out.Route[j] = out.Route[j], out.Route[i]
	}
	return out, rows.Err()
}

func (s *Store) Route(ctx context.Context, c Channel, now time.Time) (Route, error) {
	out := Route{ChannelID: c.ID, ActivityID: c.ActivityID, LocationPolicy: c.Policy, Points: []RoutePoint{}, ServerTime: now}
	if c.ActivityID == nil || c.Policy == "hidden" {
		return out, nil
	}
	rows, err := s.pool.Query(ctx, `SELECT envelope_id,phone_received_at,latitude_microdegrees,longitude_microdegrees,gps_quality FROM telemetry_samples WHERE user_id=$1 AND activity_id=$2 AND latitude_microdegrees IS NOT NULL AND longitude_microdegrees IS NOT NULL ORDER BY phone_received_at,envelope_id`, c.UserID, *c.ActivityID)
	if err != nil {
		return out, err
	}
	defer rows.Close()
	for rows.Next() {
		var point RoutePoint
		if err := rows.Scan(&point.EnvelopeID, &point.PhoneReceivedAt, &point.LatitudeMicrodegrees, &point.LongitudeMicrodegrees, &point.GPSQuality); err != nil {
			return out, err
		}
		if c.Policy == "rounded" && c.Decimals != nil {
			roundValue(&point.LatitudeMicrodegrees, *c.Decimals)
			roundValue(&point.LongitudeMicrodegrees, *c.Decimals)
		}
		out.Points = append(out.Points, point)
	}
	if err := rows.Err(); err != nil {
		return out, err
	}
	out.Points = downsample(out.Points, maxRoutePoints)
	return out, nil
}

func downsample(points []RoutePoint, limit int) []RoutePoint {
	if limit <= 0 {
		return []RoutePoint{}
	}
	if len(points) <= limit {
		return points
	}
	if limit == 1 {
		return points[:1]
	}
	out := make([]RoutePoint, limit)
	for i := range out {
		out[i] = points[i*(len(points)-1)/(limit-1)]
	}
	return out
}

func (s *Store) Replay(ctx context.Context, c Channel, last uuid.UUID, limit int) ([]SampleView, bool, error) {
	var cursor int64
	var activityID uuid.UUID
	err := s.pool.QueryRow(ctx, `SELECT ingest_cursor,activity_id FROM telemetry_samples WHERE envelope_id=$1 AND user_id=$2`, last, c.UserID).Scan(&cursor, &activityID)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, true, nil
	}
	if err != nil {
		return nil, false, err
	}
	if c.ActivityID == nil || activityID != *c.ActivityID {
		return nil, true, nil
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
func restrictPolicy(c *Channel, policy string, decimals *int16) {
	rank := map[string]int{"hidden": 0, "rounded": 1, "precise": 2}
	if rank[policy] < rank[c.Policy] {
		c.Policy = policy
		c.Decimals = decimals
	} else if c.Policy == "rounded" && policy == "rounded" && decimals != nil && (c.Decimals == nil || *decimals < *c.Decimals) {
		c.Decimals = decimals
	}
}
func round(value **int, decimals int16) {
	if *value == nil {
		return
	}
	roundValue(*value, decimals)
}
func roundValue(value *int, decimals int16) {
	factor := math.Pow10(6 - int(decimals))
	*value = int(math.Round(float64(*value)/factor) * factor)
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
