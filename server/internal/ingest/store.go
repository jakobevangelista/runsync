package ingest

import (
	"context"
	"errors"
	"sort"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jakobevangelista/runsync/server/internal/auth"
	"github.com/jakobevangelista/runsync/server/internal/telemetry"
)

var (
	ErrConflict              = errors.New("envelope conflict")
	ErrInstallationOwnership = errors.New("installation ownership conflict")
	ErrEnvelopeOwnership     = errors.New("envelope ownership conflict")
)

type RejectionCode string

const (
	CodeEnvelopeConflict              RejectionCode = "envelope_conflict"
	CodeInstallationOwnershipConflict RejectionCode = "installation_ownership_conflict"
	CodeEnvelopeOwnershipConflict     RejectionCode = "envelope_ownership_conflict"
)

type RejectionError struct {
	Code       RejectionCode
	EnvelopeID *uuid.UUID
	kind       error
}

func (e *RejectionError) Error() string {
	if e.kind == nil {
		return string(e.Code)
	}
	return e.kind.Error()
}
func (e *RejectionError) Unwrap() error { return e.kind }

func rejection(kind error, code RejectionCode, envelopeID *uuid.UUID) error {
	return &RejectionError{Code: code, EnvelopeID: envelopeID, kind: kind}
}

func envelopeRejection(kind error, code RejectionCode, envelopeID uuid.UUID) error {
	id := envelopeID
	return rejection(kind, code, &id)
}

type Result struct {
	Acknowledged []uuid.UUID
	Events       []telemetry.Event
	Transitions  []telemetry.Event
	Channels     map[uuid.UUID][]uuid.UUID
}
type Store struct{ pool *pgxpool.Pool }

func New(pool *pgxpool.Pool) *Store { return &Store{pool: pool} }

func (s *Store) Ingest(ctx context.Context, p auth.Principal, b telemetry.Batch, now time.Time) (Result, error) {
	var result Result
	result.Channels = map[uuid.UUID][]uuid.UUID{}
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return result, err
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	// Cursor allocation and commit order must agree for each user's replay stream.
	if _, err = tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1::text,0))`, p.UserID); err != nil {
		return result, err
	}
	if p.InstallationID != nil && *p.InstallationID != b.InstallationID {
		return result, rejection(ErrInstallationOwnership, CodeInstallationOwnershipConflict, nil)
	}
	var installationUser uuid.UUID
	err = tx.QueryRow(ctx, `INSERT INTO installations(id,user_id,first_seen_at,last_seen_at,app_version) VALUES($1,$2,$3,$3,$4) ON CONFLICT(id) DO UPDATE SET last_seen_at=GREATEST(installations.last_seen_at,excluded.last_seen_at),app_version=excluded.app_version RETURNING user_id`, b.InstallationID, p.UserID, now, b.Envelopes[len(b.Envelopes)-1].AppVersion).Scan(&installationUser)
	if err != nil {
		return result, err
	}
	if installationUser != p.UserID {
		return result, rejection(ErrInstallationOwnership, CodeInstallationOwnershipConflict, nil)
	}
	if p.InstallationID == nil {
		tag, err := tx.Exec(ctx, `UPDATE api_credentials SET installation_id=$1 WHERE id=$2 AND installation_id IS NULL`, b.InstallationID, p.CredentialID)
		if err != nil {
			return result, err
		}
		if tag.RowsAffected() == 0 {
			var bound uuid.UUID
			if err := tx.QueryRow(ctx, `SELECT installation_id FROM api_credentials WHERE id=$1`, p.CredentialID).Scan(&bound); err != nil {
				return result, err
			}
			if bound != b.InstallationID {
				return result, rejection(ErrInstallationOwnership, CodeInstallationOwnershipConflict, nil)
			}
		}
	}
	newByActivity := map[uuid.UUID][]telemetry.Event{}
	for _, e := range b.Envelopes {
		var deviceID, user uuid.UUID
		err = tx.QueryRow(ctx, `INSERT INTO garmin_devices(id,user_id,garmin_identifier,first_seen_at,last_seen_at) VALUES($1,$2,$3,$4,$4) ON CONFLICT(user_id,garmin_identifier) DO UPDATE SET last_seen_at=GREATEST(garmin_devices.last_seen_at,excluded.last_seen_at) RETURNING id,user_id`, uuid.New(), p.UserID, e.GarminDeviceIdentifier, now).Scan(&deviceID, &user)
		if err != nil {
			return result, err
		}
		if user != p.UserID {
			return result, envelopeRejection(ErrEnvelopeOwnership, CodeEnvelopeOwnershipConflict, e.EnvelopeID)
		}
		var activityUser, activityInstallation, activityDevice uuid.UUID
		started := epoch(e.Sample.ActivityStartEpochSeconds)
		err = tx.QueryRow(ctx, `INSERT INTO activities(id,user_id,installation_id,garmin_device_id,garmin_started_at,first_phone_received_at,last_phone_received_at,first_server_received_at,last_server_received_at,current_state,created_at,updated_at) VALUES($1,$2,$3,$4,$5,$6,$6,$7,$7,$8,$7,$7) ON CONFLICT(id) DO UPDATE SET updated_at=activities.updated_at RETURNING user_id,installation_id,garmin_device_id`, e.ActivityID, p.UserID, b.InstallationID, deviceID, started, e.PhoneReceivedAt, now, e.Sample.State).Scan(&activityUser, &activityInstallation, &activityDevice)
		if err != nil {
			return result, err
		}
		if activityUser != p.UserID || activityInstallation != b.InstallationID || activityDevice != deviceID {
			return result, envelopeRejection(ErrEnvelopeOwnership, CodeEnvelopeOwnershipConflict, e.EnvelopeID)
		}
		inserted, cursor, err := insertSample(ctx, tx, p.UserID, e, now)
		if err != nil {
			return result, err
		}
		result.Acknowledged = append(result.Acknowledged, e.EnvelopeID)
		if inserted {
			ev := telemetry.Event{Envelope: e, ServerReceivedAt: now, IngestCursor: cursor}
			newByActivity[e.ActivityID] = append(newByActivity[e.ActivityID], ev)
			result.Events = append(result.Events, ev)
		}
	}
	sortEvents(result.Events)
	var attach *telemetry.Event
	for activity, events := range newByActivity {
		earliest := events[0]
		latest := events[0]
		var latestWithStart *telemetry.Event
		hasRunning := false
		for _, e := range events[1:] {
			if e.Envelope.PhoneReceivedAt.Before(earliest.Envelope.PhoneReceivedAt) {
				earliest = e
			}
			if eventAfter(e, latest) {
				latest = e
			}
		}
		for _, e := range events {
			if e.Envelope.Sample.State == 1 {
				hasRunning = true
			}
			if e.Envelope.Sample.ActivityStartEpochSeconds != nil && (latestWithStart == nil || eventAfter(e, *latestWithStart)) {
				candidate := e
				latestWithStart = &candidate
			}
		}
		var started *time.Time
		if latestWithStart != nil {
			started = epoch(latestWithStart.Envelope.Sample.ActivityStartEpochSeconds)
		}
		var authoritativeCursor int64
		err = tx.QueryRow(ctx, `UPDATE activities SET first_phone_received_at=LEAST(first_phone_received_at,$2),last_phone_received_at=GREATEST(last_phone_received_at,$3),last_server_received_at=GREATEST(last_server_received_at,$4),garmin_started_at=COALESCE(garmin_started_at,$5),current_state=CASE WHEN $3>last_phone_received_at OR ($3=last_phone_received_at AND $9>latest_ingest_cursor) THEN $6 ELSE current_state END,ended_at=CASE WHEN ($3>last_phone_received_at OR ($3=last_phone_received_at AND $9>latest_ingest_cursor)) AND $6=4 THEN $3 WHEN $3>last_phone_received_at OR ($3=last_phone_received_at AND $9>latest_ingest_cursor) THEN NULL ELSE ended_at END,latest_ingest_cursor=CASE WHEN $3>last_phone_received_at OR ($3=last_phone_received_at AND $9>latest_ingest_cursor) THEN $9 ELSE latest_ingest_cursor END,sample_count=sample_count+$7,updated_at=$4 WHERE id=$1 AND user_id=$8 RETURNING latest_ingest_cursor`, activity, earliest.Envelope.PhoneReceivedAt, latest.Envelope.PhoneReceivedAt, now, started, latest.Envelope.Sample.State, len(events), p.UserID, latest.IngestCursor).Scan(&authoritativeCursor)
		if err != nil {
			return result, err
		}
		if hasRunning {
			candidate := latest
			if authoritativeCursor != latest.IngestCursor {
				candidate, err = loadEvent(ctx, tx, p.UserID, activity, authoritativeCursor)
				if err != nil {
					return result, err
				}
			}
			if candidate.Envelope.Sample.State != 0 && (attach == nil || eventAfter(candidate, *attach)) {
				attach = &candidate
			}
		}
	}
	if attach != nil {
		tag, updateErr := tx.Exec(ctx, `UPDATE live_channels c SET active_activity_id=$1,updated_at=$2 WHERE c.user_id=$3 AND (c.active_activity_id IS NULL OR EXISTS (SELECT 1 FROM activities active WHERE active.id=c.active_activity_id AND (active.last_phone_received_at,active.latest_ingest_cursor)<($4,$5)))`, attach.Envelope.ActivityID, now, p.UserID, attach.Envelope.PhoneReceivedAt, attach.IngestCursor)
		if updateErr != nil {
			return result, updateErr
		}
		if tag.RowsAffected() > 0 {
			result.Transitions = append(result.Transitions, *attach)
		}
	}
	rows, err := tx.Query(ctx, `SELECT id,active_activity_id FROM live_channels WHERE user_id=$1 AND active_activity_id=ANY($2) ORDER BY id`, p.UserID, activityIDs(newByActivity))
	if err != nil {
		return result, err
	}
	for rows.Next() {
		var channel, activity uuid.UUID
		if err := rows.Scan(&channel, &activity); err != nil {
			rows.Close()
			return result, err
		}
		result.Channels[activity] = append(result.Channels[activity], channel)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return result, err
	}
	rows.Close()
	if err = tx.Commit(ctx); err != nil {
		return Result{}, err
	}
	return result, nil
}

func insertSample(ctx context.Context, tx pgx.Tx, user uuid.UUID, e telemetry.Envelope, now time.Time) (bool, int64, error) {
	s := e.Sample
	var cursor int64
	err := tx.QueryRow(ctx, `WITH next AS (UPDATE users SET ingest_cursor=ingest_cursor+1 WHERE id=$3 RETURNING ingest_cursor) INSERT INTO telemetry_samples(envelope_id,activity_id,user_id,phone_received_at,server_received_at,ingest_cursor,app_version,protocol_version,watch_sequence,activity_state,garmin_activity_start_epoch_seconds,elapsed_time_milliseconds,distance_decimeters,speed_millimeters_per_second,heart_rate_bpm,cadence_rpm,latitude_microdegrees,longitude_microdegrees,gps_quality,altitude_decimeters,total_ascent_meters) SELECT $1,$2,$3,$4,$5,next.ingest_cursor,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20 FROM next ON CONFLICT DO NOTHING RETURNING ingest_cursor`, e.EnvelopeID, e.ActivityID, user, e.PhoneReceivedAt, now, e.AppVersion, s.ProtocolVersion, s.Sequence, s.State, s.ActivityStartEpochSeconds, s.ElapsedTimeMilliseconds, s.DistanceDecimeters, s.SpeedMillimetersPerSecond, s.HeartRateBPM, s.CadenceRPM, s.LatitudeMicrodegrees, s.LongitudeMicrodegrees, s.GPSQuality, s.AltitudeDecimeters, s.TotalAscentMeters).Scan(&cursor)
	if err == nil {
		return true, cursor, nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return false, 0, err
	}
	var owned, equal bool
	err = tx.QueryRow(ctx, `SELECT user_id=$3,activity_id=$2 AND user_id=$3 AND phone_received_at=$4 AND app_version=$5 AND protocol_version=$6 AND watch_sequence=$7 AND activity_state=$8 AND garmin_activity_start_epoch_seconds IS NOT DISTINCT FROM $9 AND elapsed_time_milliseconds IS NOT DISTINCT FROM $10 AND distance_decimeters IS NOT DISTINCT FROM $11 AND speed_millimeters_per_second IS NOT DISTINCT FROM $12 AND heart_rate_bpm IS NOT DISTINCT FROM $13 AND cadence_rpm IS NOT DISTINCT FROM $14 AND latitude_microdegrees IS NOT DISTINCT FROM $15 AND longitude_microdegrees IS NOT DISTINCT FROM $16 AND gps_quality IS NOT DISTINCT FROM $17 AND altitude_decimeters IS NOT DISTINCT FROM $18 AND total_ascent_meters IS NOT DISTINCT FROM $19 FROM telemetry_samples WHERE envelope_id=$1`, e.EnvelopeID, e.ActivityID, user, e.PhoneReceivedAt, e.AppVersion, s.ProtocolVersion, s.Sequence, s.State, s.ActivityStartEpochSeconds, s.ElapsedTimeMilliseconds, s.DistanceDecimeters, s.SpeedMillimetersPerSecond, s.HeartRateBPM, s.CadenceRPM, s.LatitudeMicrodegrees, s.LongitudeMicrodegrees, s.GPSQuality, s.AltitudeDecimeters, s.TotalAscentMeters).Scan(&owned, &equal)
	if err != nil {
		return false, 0, err
	}
	if !owned {
		return false, 0, envelopeRejection(ErrEnvelopeOwnership, CodeEnvelopeOwnershipConflict, e.EnvelopeID)
	}
	if !equal {
		return false, 0, envelopeRejection(ErrConflict, CodeEnvelopeConflict, e.EnvelopeID)
	}
	return false, 0, nil
}

func activityIDs(events map[uuid.UUID][]telemetry.Event) []uuid.UUID {
	ids := make([]uuid.UUID, 0, len(events))
	for id := range events {
		ids = append(ids, id)
	}
	return ids
}
func sortEvents(events []telemetry.Event) {
	sort.Slice(events, func(i, j int) bool {
		if events[i].Envelope.PhoneReceivedAt.Equal(events[j].Envelope.PhoneReceivedAt) {
			return events[i].IngestCursor < events[j].IngestCursor
		}
		return events[i].Envelope.PhoneReceivedAt.Before(events[j].Envelope.PhoneReceivedAt)
	})
}
func eventAfter(a, b telemetry.Event) bool {
	return a.Envelope.PhoneReceivedAt.After(b.Envelope.PhoneReceivedAt) || (a.Envelope.PhoneReceivedAt.Equal(b.Envelope.PhoneReceivedAt) && a.IngestCursor > b.IngestCursor)
}
func loadEvent(ctx context.Context, tx pgx.Tx, user, activity uuid.UUID, cursor int64) (telemetry.Event, error) {
	var event telemetry.Event
	e := &event.Envelope
	s := &e.Sample
	err := tx.QueryRow(ctx, `SELECT t.envelope_id,t.activity_id,t.phone_received_at,d.garmin_identifier,t.app_version,t.protocol_version,t.watch_sequence,t.activity_state,t.garmin_activity_start_epoch_seconds,t.elapsed_time_milliseconds,t.distance_decimeters,t.speed_millimeters_per_second,t.heart_rate_bpm,t.cadence_rpm,t.latitude_microdegrees,t.longitude_microdegrees,t.gps_quality,t.altitude_decimeters,t.total_ascent_meters,t.server_received_at,t.ingest_cursor FROM telemetry_samples t JOIN activities a ON a.id=t.activity_id AND a.user_id=t.user_id JOIN garmin_devices d ON d.id=a.garmin_device_id WHERE t.user_id=$1 AND t.activity_id=$2 AND t.ingest_cursor=$3`, user, activity, cursor).Scan(&e.EnvelopeID, &e.ActivityID, &e.PhoneReceivedAt, &e.GarminDeviceIdentifier, &e.AppVersion, &s.ProtocolVersion, &s.Sequence, &s.State, &s.ActivityStartEpochSeconds, &s.ElapsedTimeMilliseconds, &s.DistanceDecimeters, &s.SpeedMillimetersPerSecond, &s.HeartRateBPM, &s.CadenceRPM, &s.LatitudeMicrodegrees, &s.LongitudeMicrodegrees, &s.GPSQuality, &s.AltitudeDecimeters, &s.TotalAscentMeters, &event.ServerReceivedAt, &event.IngestCursor)
	return event, err
}
func epoch(v *int) *time.Time {
	if v == nil {
		return nil
	}
	t := time.Unix(int64(*v), 0).UTC()
	return &t
}
