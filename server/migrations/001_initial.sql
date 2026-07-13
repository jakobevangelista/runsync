CREATE TABLE users (
    id uuid PRIMARY KEY,
    handle text NOT NULL UNIQUE CHECK (handle ~ '^[a-z0-9][a-z0-9_-]{1,62}$'),
    ingest_cursor bigint NOT NULL DEFAULT 0 CHECK (ingest_cursor >= 0),
    created_at timestamptz NOT NULL DEFAULT now(),
    disabled_at timestamptz
);

CREATE TABLE installations (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id),
    display_name text,
    first_seen_at timestamptz NOT NULL,
    last_seen_at timestamptz NOT NULL,
    app_version text,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX installations_user_id_idx ON installations(user_id);

CREATE TABLE api_credentials (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id),
    installation_id uuid REFERENCES installations(id),
    name text NOT NULL CHECK (length(name) BETWEEN 1 AND 128),
    token_prefix text NOT NULL UNIQUE,
    token_hash bytea NOT NULL CHECK (octet_length(token_hash) = 32),
    scopes text[] NOT NULL CHECK (cardinality(scopes) > 0 AND scopes <@ ARRAY['telemetry:write','channels:read','channels:manage','activities:read','activities:delete']::text[]),
    created_at timestamptz NOT NULL DEFAULT now(),
    last_used_at timestamptz,
    expires_at timestamptz,
    revoked_at timestamptz
);
CREATE INDEX api_credentials_user_id_idx ON api_credentials(user_id);

CREATE TABLE garmin_devices (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id),
    garmin_identifier uuid NOT NULL,
    display_name text,
    first_seen_at timestamptz NOT NULL,
    last_seen_at timestamptz NOT NULL,
    UNIQUE (user_id, garmin_identifier)
);

CREATE TABLE activities (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id),
    installation_id uuid NOT NULL REFERENCES installations(id),
    garmin_device_id uuid NOT NULL REFERENCES garmin_devices(id),
    garmin_started_at timestamptz,
    first_phone_received_at timestamptz NOT NULL,
    last_phone_received_at timestamptz NOT NULL,
    first_server_received_at timestamptz NOT NULL,
    last_server_received_at timestamptz NOT NULL,
    current_state smallint NOT NULL CHECK (current_state BETWEEN 0 AND 4),
    latest_ingest_cursor bigint NOT NULL DEFAULT 0 CHECK (latest_ingest_cursor >= 0),
    ended_at timestamptz,
    sample_count bigint NOT NULL DEFAULT 0 CHECK (sample_count >= 0),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz
);
CREATE INDEX activities_user_last_received_idx ON activities(user_id, last_phone_received_at DESC);

CREATE TABLE telemetry_samples (
    envelope_id uuid PRIMARY KEY,
    activity_id uuid NOT NULL REFERENCES activities(id) ON DELETE CASCADE,
    user_id uuid NOT NULL REFERENCES users(id),
    phone_received_at timestamptz NOT NULL,
    server_received_at timestamptz NOT NULL,
    ingest_cursor bigint NOT NULL CHECK (ingest_cursor > 0),
    app_version text NOT NULL CHECK (length(app_version) BETWEEN 1 AND 64),
    protocol_version integer NOT NULL CHECK (protocol_version = 1),
    watch_sequence integer NOT NULL CHECK (watch_sequence >= 0),
    activity_state smallint NOT NULL CHECK (activity_state BETWEEN 0 AND 4),
    garmin_activity_start_epoch_seconds integer CHECK (garmin_activity_start_epoch_seconds >= 0),
    elapsed_time_milliseconds integer CHECK (elapsed_time_milliseconds >= 0),
    distance_decimeters integer CHECK (distance_decimeters >= 0),
    speed_millimeters_per_second integer CHECK (speed_millimeters_per_second >= 0),
    heart_rate_bpm integer CHECK (heart_rate_bpm BETWEEN 0 AND 300),
    cadence_rpm integer CHECK (cadence_rpm BETWEEN 0 AND 300),
    latitude_microdegrees integer CHECK (latitude_microdegrees BETWEEN -90000000 AND 90000000),
    longitude_microdegrees integer CHECK (longitude_microdegrees BETWEEN -180000000 AND 180000000),
    gps_quality smallint CHECK (gps_quality BETWEEN 0 AND 4),
    altitude_decimeters integer,
    total_ascent_meters integer CHECK (total_ascent_meters >= 0),
    CHECK ((latitude_microdegrees IS NULL) = (longitude_microdegrees IS NULL))
);
CREATE UNIQUE INDEX telemetry_user_ingest_cursor_idx ON telemetry_samples(user_id, ingest_cursor);
CREATE INDEX telemetry_activity_time_idx ON telemetry_samples(activity_id, phone_received_at, envelope_id);
CREATE INDEX telemetry_user_received_idx ON telemetry_samples(user_id, server_received_at DESC);

CREATE TABLE live_channels (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id),
    slug text NOT NULL UNIQUE CHECK (slug ~ '^[a-z0-9][a-z0-9-]{1,62}$'),
    display_name text NOT NULL,
    active_activity_id uuid REFERENCES activities(id) ON DELETE SET NULL,
    location_policy text NOT NULL CHECK (location_policy IN ('precise','rounded','hidden')),
    coordinate_decimals smallint,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CHECK ((location_policy = 'rounded' AND coordinate_decimals BETWEEN 0 AND 6) OR (location_policy <> 'rounded' AND coordinate_decimals IS NULL)),
    UNIQUE (user_id, id)
);
CREATE INDEX live_channels_user_id_idx ON live_channels(user_id);
