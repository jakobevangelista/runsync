# RunSync Server Implementation Plan

## 1. Purpose

Build a small, production-quality Go service that accepts live telemetry from the RunSync iOS app, stores it in PostgreSQL 18, and exposes a low-latency read contract for a separately deployed web dashboard and livestream overlay.

The first deployment is personal but the data model and authorization boundaries must support multiple users later without replacing identifiers or rewriting telemetry. The service will run in the homelab with Docker Compose and will be reachable without router port forwarding through Cloudflare Tunnel. Caddy remains the internal reverse-proxy boundary so the deployment can later join a shared homelab Caddy instance.

This plan includes:

- the Go API and PostgreSQL schema;
- Docker, Caddy, Cloudflare Tunnel, backups, and operations;
- iOS production upload and durable acknowledgement behavior;
- the read API and live-stream contract needed by a TanStack Start frontend;
- tests and staged acceptance criteria.

This plan does not include implementation of the web frontend.

## 2. Product Decisions

Nix flakes (`flake.nix` and `flake.lock`) are the canonical optional repository tool environment. Contributors may use equivalent native installations, but CI and documented tool discovery should follow the flake pins.

The following decisions are fixed for the first implementation:

- PostgreSQL 18 is the system of record.
- The service supports one owner initially but every resource is owned by a user.
- Full-resolution samples are retained until the owner deletes them.
- The primary read use case is a near-live run dashboard and browser-source overlay.
- The API should add only milliseconds of live-stream latency. End-to-end latency is measured rather than promised because Garmin BLE, iOS suspension, cellular scheduling, and retries are not deterministic.
- Precise coordinates are stored. A server-side live-channel policy decides whether viewers receive precise, rounded, or no coordinates.
- Long-lived iOS ingest and frontend read credentials are separate and scope-limited.
- A TanStack Start server route may hold the frontend read credential. It can exchange that credential for short-lived, channel-scoped viewer tokens so browsers can connect directly to the live stream without exposing a permanent secret.
- The homelab is exposed through an outbound Cloudflare Tunnel because inbound port 443 cannot be forwarded.
- Caddy is bundled initially but must be replaceable by a shared Caddy instance without changing the API image.

## 3. Architecture

```text
Garmin watch
  -> Garmin Connect IQ BLE messaging
  -> iOS protected NDJSON archive
  -> HTTPS batch ingestion
  -> Cloudflare edge
  -> outbound Cloudflare Tunnel
  -> Caddy
  -> Go API
  -> PostgreSQL 18

TanStack Start server
  -> long-lived read service credential
  -> short-lived viewer-token exchange and authenticated history reads

Browser dashboard or OBS browser source
  -> short-lived viewer token
  -> HTTPS snapshot + Server-Sent Events through Cloudflare Tunnel
```

Use one Go binary and one PostgreSQL database. Do not add Redis, a queue, ClickHouse, TimescaleDB, or separate ingestion/read services until measured load requires them.

### 3.1 Why PostgreSQL

One sample per second is modest for PostgreSQL. It also keeps users, credentials, devices, activities, channel configuration, and telemetry under transactional constraints. Preserve an append-only telemetry boundary so samples can later be replicated to ClickHouse without changing the mobile contract.

Do not install TimescaleDB initially. Add native time-based partitions only after table size and query plans justify them. A future ClickHouse deployment should be an analytical replica, not the initial source of truth.

### 3.2 Go service shape

Use a conventional Go module under `server/` with a small package structure:

```text
server/
  cmd/runsync/
  internal/api/
  internal/auth/
  internal/config/
  internal/database/
  internal/ingest/
  internal/live/
  internal/telemetry/
  migrations/
  Dockerfile
  go.mod
```

Implementation choices:

- standard `net/http` routing and middleware;
- `pgx/v5` and `pgxpool` for PostgreSQL access;
- SQL migrations embedded into the binary and executed by an explicit `migrate` command;
- hand-written SQL for the initial small query surface rather than adding an ORM;
- structured JSON logging with the standard `log/slog` package;
- dependency injection through constructors, without a framework or global mutable service locator;
- graceful HTTP and database shutdown on `SIGTERM`;
- UTC throughout the API and database.

Pin the Go toolchain, container base images, Caddy, PostgreSQL 18, and `cloudflared` to explicit versions when implementation begins. Refresh pins deliberately rather than using `latest`.

## 4. Identity Model

There are four distinct identities and they must not be conflated:

- `user_id`: server owner of data and configuration;
- `installation_id`: stable non-secret UUID generated by one iOS installation;
- `garmin_device_identifier`: Garmin SDK UUID for the authorized watch;
- `activity_id`: the iOS `localRunID`, which is the canonical server activity UUID.

Every archived iOS envelope also has a stable random `envelope_id`. This is the ingestion idempotency key.

Watch sequence values are diagnostic only. They can have gaps, duplicates, regressions, resets, and out-of-order delivery, so `(activity_id, sequence)` must not be unique and must never be used as the acknowledgement key.

The server assigns a monotonically increasing per-user `ingest_cursor` to each newly committed envelope. This cursor is internal ordering metadata for replay; it is not an acknowledgement key or part of the mobile request. Per-user advisory locking ensures cursor allocation and commit order agree. SSE continues to expose the envelope UUID as its event ID and resolves that UUID to the durable cursor during replay.

## 5. PostgreSQL Schema

Use UUID primary keys generated by the application. Use `timestamptz` for absolute times, integer columns for the watch's lossless native units, and explicit check constraints for protocol enums and geographic ranges.

### 5.1 `users`

```text
id uuid primary key
handle text not null unique
ingest_cursor bigint not null default 0
created_at timestamptz not null
disabled_at timestamptz null
```

Create the initial owner through an administrative bootstrap command. Interactive user login is deferred, but ownership is present from the first migration.

### 5.2 `api_credentials`

```text
id uuid primary key
user_id uuid not null references users
installation_id uuid null references installations
name text not null
token_prefix text not null unique
token_hash bytea not null
scopes text[] not null
created_at timestamptz not null
last_used_at timestamptz null
expires_at timestamptz null
revoked_at timestamptz null
```

Initial scopes:

- `telemetry:write` for the iOS installation;
- `channels:read` for the TanStack Start server;
- `channels:manage` for future channel settings;
- `activities:read` and `activities:delete` for future authenticated history UI.

Generate at least 256 bits of random token material. Store only a SHA-256 token digest plus a non-secret lookup prefix. Display the complete token once. Do not place credentials in source control, images, logs, URLs, or the watch app.

### 5.3 `installations`

```text
id uuid primary key
user_id uuid not null references users
display_name text null
first_seen_at timestamptz not null
last_seen_at timestamptz not null
app_version text null
created_at timestamptz not null
```

An ingest credential is bound to one user and may optionally be bound to one installation after first use. Reject attempts to reuse a bound credential with another installation ID.

### 5.4 `garmin_devices`

```text
id uuid primary key
user_id uuid not null references users
garmin_identifier uuid not null
display_name text null
first_seen_at timestamptz not null
last_seen_at timestamptz not null
unique (user_id, garmin_identifier)
```

Do not treat Garmin identifiers as authentication credentials.

### 5.5 `activities`

```text
id uuid primary key
user_id uuid not null references users
installation_id uuid not null references installations
garmin_device_id uuid not null references garmin_devices
garmin_started_at timestamptz null
first_phone_received_at timestamptz not null
last_phone_received_at timestamptz not null
first_server_received_at timestamptz not null
last_server_received_at timestamptz not null
current_state smallint not null
latest_ingest_cursor bigint not null default 0
ended_at timestamptz null
sample_count bigint not null default 0
created_at timestamptz not null
updated_at timestamptz not null
deleted_at timestamptz null
```

The server accepts the iOS `localRunID` as `activities.id`. On first envelope, create the activity, installation, and Garmin device as one transaction where needed. Subsequent batches update activity liveness and state monotonically by `phone_received_at`, not request arrival order.

The live stream is not Garmin's authoritative activity recording. Missing BLE samples remain missing, and the server must not interpolate them during ingestion.

### 5.6 `telemetry_samples`

```text
envelope_id uuid primary key
activity_id uuid not null references activities
user_id uuid not null references users
phone_received_at timestamptz not null
server_received_at timestamptz not null
ingest_cursor bigint not null
app_version text not null
protocol_version integer not null
watch_sequence integer not null
activity_state smallint not null
garmin_activity_start_epoch_seconds integer null
elapsed_time_milliseconds integer null
distance_decimeters integer null
speed_millimeters_per_second integer null
heart_rate_bpm integer null
cadence_rpm integer null
latitude_microdegrees integer null
longitude_microdegrees integer null
gps_quality smallint null
altitude_decimeters integer null
total_ascent_meters integer null
```

Constraints must preserve the existing decoder contract:

- latitude and longitude are either both null or both present;
- latitude is between `-90000000` and `90000000`;
- longitude is between `-180000000` and `180000000`;
- state and GPS quality are recognized enum values;
- nonnegative values are required where the metric cannot be negative;
- heart rate and cadence have conservative physical upper bounds to reject corrupt payloads;
- protocol version 1 is accepted initially.

Initial indexes:

```text
primary key (envelope_id)
unique (user_id, ingest_cursor)
index (activity_id, phone_received_at, envelope_id)
index (user_id, server_received_at desc)
```

Do not index every metric. Use `phone_received_at` as the live wall-clock axis and `elapsed_time_milliseconds` as the activity-relative axis. `server_received_at - phone_received_at` is the observable network/backlog delay.

Retain original integer units. Convert units only in API response views, where names include units. This avoids floating-point drift and preserves compatibility with the iOS archive.

### 5.7 `live_channels`

```text
id uuid primary key
user_id uuid not null references users
slug text not null unique
display_name text not null
active_activity_id uuid null references activities
location_policy text not null
coordinate_decimals smallint null
created_at timestamptz not null
updated_at timestamptz not null
```

Supported location policies:

- `precise`: return stored microdegree coordinates;
- `rounded`: round coordinates on the server to the configured decimal places;
- `hidden`: omit coordinates from snapshots, replay, and live events.

The initial owner's stable channel points to the most recently active run. The API can automatically attach an activity when its first running sample arrives and clear or mark it offline after it ends. A future management API may override the active activity and location policy.

Do not send precise coordinates to a browser and rely on JavaScript to round them. Once the browser receives a value, it is disclosed.

### 5.8 Future partitioning and OLAP

Do not partition at launch. Establish measured thresholds and inspect `pg_stat_user_tables`, index size, write latency, and `EXPLAIN (ANALYZE, BUFFERS)` output.

If the telemetry table reaches hundreds of millions of rows or maintenance/query latency degrades:

1. add native PostgreSQL range partitions by `server_received_at` or activity date;
2. add downsampled activity summaries for long-range views;
3. replicate append-only samples to ClickHouse for cross-run analytics;
4. keep PostgreSQL as the owner of users, credentials, channels, and activity metadata.

Stable envelope and activity UUIDs make replication idempotent.

## 6. Ingestion API

### 6.1 Endpoint

```http
POST /v1/telemetry/batches
Authorization: Bearer <ios-ingest-token>
Content-Type: application/json
Idempotency semantics: per envelopeId
```

Request:

```json
{
  "installationId": "7d9aa8d8-8e9f-4f25-a9e2-2bd75148f986",
  "envelopes": [
    {
      "envelopeId": "b608d8d9-a203-4ba4-860b-601c1509bc85",
      "activityId": "e4a55567-2aef-41d1-b82f-af1c209919c5",
      "phoneReceivedAt": "2026-07-12T18:42:01.250Z",
      "garminDeviceIdentifier": "0afb86af-a5ab-4517-82e4-f8a8ba8aef01",
      "appVersion": "1.0",
      "sample": {
        "protocolVersion": 1,
        "sequence": 175,
        "state": 1,
        "activityStartEpochSeconds": 1783884160,
        "elapsedTimeMilliseconds": 523000,
        "distanceDecimeters": 184260,
        "speedMillimetersPerSecond": 3710,
        "heartRateBPM": 154,
        "cadenceRPM": 87,
        "latitudeMicrodegrees": 37774920,
        "longitudeMicrodegrees": -122419380,
        "gpsQuality": 4,
        "altitudeDecimeters": 382,
        "totalAscentMeters": 22
      }
    }
  ]
}
```

Response:

```json
{
  "acknowledgedEnvelopeIds": [
    "b608d8d9-a203-4ba4-860b-601c1509bc85"
  ],
  "serverTime": "2026-07-12T18:42:01.410Z"
}
```

The server acknowledges an envelope only after its transaction commits. A replay of an identical `envelopeId` returns that ID as acknowledged. If an existing envelope ID is submitted with different immutable content, return a conflict and log metadata without coordinates.

Use an atomic batch initially: malformed or unauthorized content rejects the request without partially accepting new envelopes. Already-committed IDs remain acknowledged on retry. Return structured, stable error codes for authentication, validation, conflict, body size, rate limit, and internal failure.

### 6.2 Batch and request limits

Initial limits:

- at most 100 envelopes per request;
- at most 256 KiB decoded request body;
- all envelopes in a request must use the top-level installation ID and authenticated owner;
- request and database transaction deadlines;
- credential and source-IP rate limiting with enough burst capacity for outage recovery.

The iOS app should normally send immediately for low latency and may coalesce records that arrive while one request is in flight. Catch-up uses larger batches. These are maximums, not a requirement to delay a live sample until a batch fills.

### 6.3 Transaction behavior

For each accepted request:

1. authenticate and authorize before decoding a large body;
2. validate the complete request and normalize timestamps;
3. begin a transaction;
4. upsert installation and Garmin-device liveness;
5. create the activity if needed and verify immutable ownership and device association;
6. insert samples with envelope-ID conflict detection;
7. update activity state, timestamps, and sample count from newly inserted rows;
8. attach the activity to the owner's live channel when appropriate;
9. commit;
10. publish committed new samples to local live subscribers;
11. return exact committed and previously existing envelope IDs.

No SSE event may be emitted before commit.

## 7. Read And Live API

The future frontend needs a contract now, even though its implementation is deferred.

### 7.1 Service authentication

The TanStack Start server stores a long-lived `channels:read` credential in its server-only runtime secret store. Server-side history and configuration requests use the bearer token directly. It must never be serialized into HTML, JavaScript bundles, browser logs, or query parameters.

### 7.2 Viewer-token exchange

```http
POST /v1/viewer-tokens
Authorization: Bearer <frontend-read-token>
```

Request a channel slug and desired lifetime. Return a signed token with:

- channel ID;
- read-only live scope;
- effective location policy, clamped to the channel's configured maximum disclosure;
- issued-at and expiry times;
- a short maximum lifetime, initially five minutes.

The browser may receive this short-lived token. Its compromise cannot write telemetry, read other channels, increase coordinate precision, or survive expiry. The frontend refreshes it through its authenticated TanStack server route.

Use the `Authorization` header with a streaming `fetch` client. Do not put bearer tokens in URLs. Configure CORS with an explicit allowlist for the production frontend origin and local development origins; never combine credentialed access with wildcard origins.

### 7.3 Snapshot

```http
GET /v1/channels/{slug}/snapshot
Authorization: Bearer <service-or-viewer-token>
```

Return:

- channel and activity identifiers;
- online/running/paused/ended state;
- latest sample transformed by the effective location policy;
- latest-sample age;
- recent route points needed to initialize a live map, bounded by count and time;
- server timestamp.

The snapshot allows a newly opened browser source to render immediately before subscribing.

### 7.4 Server-Sent Events

```http
GET /v1/channels/{slug}/stream
Authorization: Bearer <viewer-token>
Accept: text/event-stream
```

Use SSE rather than WebSockets because the data flow is server-to-browser, browser reconnect behavior is straightforward, and standard HTTP proxying is sufficient.

Events:

- `sample`: one committed telemetry sample;
- `activity`: activity/channel transitions;
- `heartbeat`: comment or event every 15 seconds to detect dead intermediaries;
- `reset`: client replay position is too old and it must reload the snapshot.

Set `id` to the envelope UUID. Accept `Last-Event-ID`, resolve it to the internal per-user ingest cursor, and replay a small bounded window in commit order before joining the live subscriber. This prevents a delayed sample with an older phone timestamp from being skipped. Because native `EventSource` cannot set an authorization header, the frontend should consume the SSE response with streaming `fetch` or an SSE client that supports headers.

SSE payloads use the same public sample view as snapshots. They must not serialize the ingestion envelope's installation ID, Garmin device identifier, app version, or other internal ownership metadata. Enforce viewer-token expiry on an already-open stream rather than checking it only at connection time.

The initial API runs one replica and uses an in-process fan-out hub after database commit. Slow subscribers get a bounded queue; if they fall behind, disconnect them so they reconnect and replay rather than allowing unbounded memory growth.

Before running multiple API replicas, add a cross-instance committed-event mechanism such as PostgreSQL `LISTEN/NOTIFY` carrying only envelope identifiers or a transactional outbox. Do not add Redis preemptively.

### 7.5 History contract

Reserve authenticated service endpoints for later frontend work:

```text
GET /v1/activities
GET /v1/activities/{activityId}
GET /v1/activities/{activityId}/samples?after=&limit=
DELETE /v1/activities/{activityId}
```

Implement only what the first dashboard integration needs. Pagination must be cursor-based using `(phone_received_at, envelope_id)`, not large offsets.

## 8. Location And Privacy

Precise live location is sensitive even for a personal service.

- Store coordinates only after the existing explicit iOS privacy opt-in.
- Keep precise coordinates in PostgreSQL because the owner wants future configurable display precision.
- Enforce the channel's location policy in every read serializer, including snapshot, replay, SSE, and history.
- Treat the TanStack Start server as a trusted service only when it uses its long-lived server credential. Browser responses remain disclosures to the viewer.
- Do not log coordinates, request bodies, bearer tokens, viewer tokens, or complete authorization headers.
- Preserve an auditable `hidden` option that omits coordinate fields entirely.
- Make location-policy changes apply to future reads immediately; no rewritten telemetry is required.
- Add start/end masking as a future policy if the stream becomes broadly public.

Deletion must remove an activity's samples transactionally or through a visible asynchronous job if volume later makes a single transaction unsafe. The first implementation may use a transaction because personal volumes are small. Deletion should also clear any channel pointer to that activity.

## 9. iOS Production Uploader

Replace the in-process mock sink with a protocol-backed sink so tests can continue using the mock while production uses HTTP.

### 9.1 Configuration and credentials

- Add server base-URL and ingest-token provisioning to the iOS app.
- Require HTTPS outside debug builds.
- Store the ingest token in Keychain with an accessibility class compatible with use after first unlock.
- Keep the installation ID stable and non-secret.
- Never send the ingest credential to the watch.
- Show server configuration, last upload, pending count, last acknowledgement, and sanitized failure status in diagnostics.

### 9.2 Durable acknowledgements

Keep persistence-before-upload ordering. Rename the production journal concept from mock acknowledgements to server acknowledgements, with a migration that preserves existing local sample archives.

Legacy `mock-acks.ndjson` entries are not server acknowledgements and must not suppress first upload to the real server. Preserve those files as diagnostics, but only `server-acks.ndjson` proves server commit.

The server returns exact envelope UUIDs. Append each acknowledged UUID durably before removing it from the in-memory pending set. Never infer acknowledgement from watch sequence, HTTP status alone, or the highest observed sequence.

Retain raw local archives after acknowledgement until a separately defined local-retention policy is implemented. Server acknowledgement proves durable server commit, not Garmin activity completeness.

Recovery merges archived pending envelopes with messages received concurrently during startup instead of replacing the in-memory queue. Before every NDJSON append, truncate a non-newline-terminated tail left by abrupt termination so the next valid record cannot be concatenated onto corrupt partial JSON. Malformed complete acknowledgement lines are ignored conservatively and therefore cause a safe idempotent resend.

### 9.3 Scheduling and retry

- Allow only one HTTP submission in flight.
- Submit a new live sample immediately when no request is in flight.
- Coalesce newly arrived records into the next request without delaying solely to fill a batch.
- Use larger batches, up to the server maximum, during recovery.
- Trigger retry after a new persisted sample, request completion, app foregrounding, and explicit user action.
- Apply bounded exponential backoff with jitter for transport errors, `429`, and `5xx` responses.
- Honor `Retry-After`.
- Stop automatic retry for invalid credentials and schema errors while preserving archived records.
- Use request timeouts and an ephemeral or default `URLSession` appropriate to small requests.

Do not claim guaranteed one-second upload while iOS is suspended. A Garmin BLE callback may wake the app, but ordinary `URLSession` work is not guaranteed to complete before suspension. Background URL sessions are optimized for system-scheduled file transfers, not one-second low-latency requests. Measure real locked-screen behavior on physical hardware and report p50, p95, maximum latency, and delivery ratio.

### 9.4 App/server clock and ordering

The server stores both `phoneReceivedAt` and its own `serverReceivedAt`. Requests may arrive late or out of order. The UI should use phone receipt time for the live timeline while diagnostics expose network delay. Reject timestamps implausibly far in the future, but permit old archived samples during catch-up.

## 10. Authentication And Abuse Controls

The tunnel makes the hostname internet-reachable even though no home port is forwarded. Authentication and limits remain mandatory.

- Use independent random credentials for iOS ingestion and frontend reads.
- Compare token digests in constant time.
- Scope every database query by authenticated `user_id` in addition to resource ID.
- Support credential revocation and rotation without changing user or installation IDs.
- Apply request-body limits before JSON decoding.
- Rate-limit by credential and source IP in the Go service; optionally add Cloudflare edge rules as defense in depth.
- Set conservative HTTP header, read, write, idle, and handler timeouts without breaking SSE.
- Return generic authentication errors that do not reveal token prefixes or user existence.
- Use prepared/parameterized SQL exclusively.
- Run containers as non-root with read-only filesystems where practical.
- Do not expose PostgreSQL or Go debug endpoints on the host network.

The initial administrative CLI should support:

```text
runsync migrate
runsync admin bootstrap-owner
runsync admin create-credential
runsync admin revoke-credential
```

Bootstrap and credential commands print secrets once to the operator terminal. They must not write them into database logs or Compose configuration automatically.

## 11. Docker And Homelab Deployment

### 11.1 Compose services

Create a production Compose definition with:

- `api`: the RunSync Go binary;
- `postgres`: official PostgreSQL 18 image and persistent data volume;
- `caddy`: internal reverse proxy with persistent configuration/data volumes as needed;
- `cloudflared`: outbound Cloudflare Tunnel client.

Only `cloudflared` needs outbound internet access. The tunnel routes the RunSync hostname to Caddy over the private Compose network. Caddy proxies to `api`. PostgreSQL accepts connections only from the private application network.

No application port needs to be published publicly on the Docker host. An optional loopback-only Caddy port may be enabled for local administration and testing.

### 11.2 Caddy boundary

The bundled Caddy configuration should:

- reverse proxy API requests;
- preserve streaming and disable response buffering for SSE;
- set forwarding headers correctly while trusting only the local tunnel proxy;
- apply security headers where appropriate;
- expose no Caddy admin endpoint outside the container network;
- use an unencrypted internal hop initially because it never leaves the Compose network.

To migrate to a shared homelab Caddy later:

1. remove or disable the bundled Caddy service;
2. attach `api` to an explicitly named external proxy network;
3. copy the RunSync site block into shared Caddy configuration;
4. point `cloudflared` at shared Caddy;
5. keep the same external hostname and API environment variables.

The API image must not depend on Caddy-specific headers for authentication or correctness.

### 11.3 Cloudflare Tunnel

Create a Cloudflare-managed hostname such as `runsync-api.example.com`. Configure a named tunnel with narrowly scoped credentials and an ingress rule to internal Caddy. End ingress rules with a deny/not-found catch-all.

Store the tunnel token or credentials outside Git using Docker Compose secrets or the homelab's secret manager. Do not bake Cloudflare credentials into an image.

Cloudflare terminates public TLS. Confirm SSE streaming, idle timeout behavior, request-size limits, and client IP headers during deployment testing. Application bearer authentication remains required even if Cloudflare Access or WAF rules are later added.

### 11.4 Configuration

Validate all configuration at startup and fail fast. Expected settings include:

```text
RUNSYNC_HTTP_ADDRESS
RUNSYNC_DATABASE_URL_FILE (preferred) or RUNSYNC_DATABASE_URL
RUNSYNC_PUBLIC_BASE_URL
RUNSYNC_ALLOWED_ORIGINS
RUNSYNC_VIEWER_TOKEN_SIGNING_KEY_FILE (preferred) or RUNSYNC_VIEWER_TOKEN_SIGNING_KEY
RUNSYNC_LOG_LEVEL
RUNSYNC_TRUSTED_PROXY_CIDRS
```

Secrets must be read from files or environment values injected at deployment, never committed `.env` files. Compose uses the file variants for the database URL and viewer signing key. Add repository ignore rules before creating local secret files.

## 12. Database Operations

### 12.1 Migrations

- Number immutable forward migrations.
- Embed them in the API image.
- Run migration as an explicit one-shot deployment step before starting a new API version.
- Use PostgreSQL advisory locking so only one migrator runs.
- Do not automatically run potentially blocking migrations in every API process startup.
- Test migration from an empty database and from the previous released schema.

### 12.2 Backups

The database contains irreplaceable run history and precise location. A Docker volume alone is not a backup.

Initial policy:

- provide a one-shot Docker Compose backup profile that writes a custom-format dump to `RUNSYNC_BACKUP_PATH`;
- nightly logical backup with `pg_dump` in custom format;
- encrypted off-host copy through the homelab backup system;
- defined retention for daily, weekly, and monthly backups;
- backup job health alerting;
- documented quarterly restore test into an isolated PostgreSQL 18 instance.

If acceptable data-loss duration becomes shorter than one day, add physical/WAL backups. Do not claim recovery readiness until a restore has been tested.

The Compose profile only creates a dump. Scheduling, encryption, retention, off-host copying, alerting, and restore drills remain homelab operator responsibilities and are acceptance work, not behavior supplied by the container itself.

### 12.3 Maintenance

Use PostgreSQL defaults initially, then observe autovacuum, table/index growth, connection use, lock waits, and query latency. Keep the API pool small relative to `max_connections`. Do not add PgBouncer until connection pressure exists.

## 13. Observability

Expose unauthenticated health endpoints only on the internal proxy path or make their responses information-minimal:

- `/healthz`: process is alive;
- `/readyz`: required configuration is valid and PostgreSQL is reachable.

Record structured metrics without precise telemetry values:

- request count, status, and duration by route;
- accepted, duplicate, conflicted, and rejected envelope counts;
- database transaction duration;
- current SSE subscribers and disconnect reason;
- live publish delay from phone receipt and server receipt;
- iOS pending/acknowledged counts in app diagnostics;
- credential authentication and rate-limit failures without token material.

Logs may include envelope ID, activity ID, installation ID, route, status, and coarse timing. They must not include coordinates, request bodies, secrets, or authorization headers.

## 14. Testing Strategy

### 14.1 Go tests

Unit tests:

- token generation, hashing, scope enforcement, expiry, and revocation;
- request decoding and all metric bounds;
- location-policy transformation;
- activity state update ordering;
- viewer-token claims and expiry;
- SSE queue overflow behavior.

PostgreSQL 18 integration tests:

- migrations from empty state;
- first envelope creates related records atomically;
- identical envelope retry is acknowledged once;
- conflicting envelope reuse is rejected;
- duplicate/reset/out-of-order watch sequences remain accepted;
- malformed atomic batch inserts nothing;
- exact acknowledgements are returned only after commit;
- concurrent retries do not duplicate samples or counts;
- every read is isolated by user;
- rounded and hidden coordinates never leak through snapshot, replay, or SSE;
- activity deletion clears channel state and removes samples.

HTTP tests:

- request/body/time limits;
- CORS allowlist behavior;
- rate limiting and `Retry-After`;
- snapshot then SSE connection without a missed committed sample;
- reconnect/replay using the last envelope ID;
- slow subscriber disconnection and recovery;
- graceful shutdown of ordinary requests and streams.

Run `go test -race ./...` and static analysis in CI. Use an actual disposable PostgreSQL 18 container for repository tests instead of mocks for SQL semantics.

### 14.2 iOS tests

- request encoding matches the server fixture exactly;
- acknowledged IDs are journaled durably;
- duplicate acknowledgements are harmless;
- partial/missing acknowledgement keeps records pending;
- archive recovery resubmits the same envelope IDs;
- authentication and validation errors stop automatic retry;
- transient failures back off and recover;
- new samples are not delayed waiting for a full batch;
- Keychain protection permits access after first unlock while locked;
- mock sink tests remain available through the uploader protocol.

### 14.3 End-to-end tests

1. Start the complete Compose stack against PostgreSQL 18.
2. Bootstrap owner, iOS credential, frontend service credential, and channel.
3. Submit fixture envelopes and retry them.
4. Verify database rows and exact acknowledgements.
5. Obtain a viewer token, load snapshot, and observe committed SSE events.
6. Test `precise`, `rounded`, and `hidden` channel policies.
7. Repeat through the real Cloudflare hostname.
8. Run a physical watch/iPhone foreground test.
9. Run locked-screen tests on Wi-Fi and cellular.
10. Interrupt internet access, accumulate an archive backlog, reconnect, and verify exact catch-up without duplicates.

Measure timestamps at watch generation where available, phone receipt, server receipt, commit/publish, and browser receipt. Report p50, p95, and maximum latency separately for foreground and locked-screen tests.

## 15. Implementation Milestones

Current status:

- Milestones 1 through 5 are implemented and covered by local Go, PostgreSQL 18, Nix, Docker-build, and iOS simulator tests.
- Milestone 6 configuration is implemented, but real Cloudflare hostname/tunnel provisioning, secret installation, off-host backup automation, and a restore drill remain incomplete.
- Milestone 7 requires the deployed service and physical watch/iPhone tests.
- Milestone 8 remains deferred as planned.
- Structured request logging is implemented; production counters/metrics listed in Section 13 remain outstanding and must not be treated as complete observability.

### Milestone 1: service foundation

- Add the Go module, configuration validation, structured logging, HTTP lifecycle, and container build.
- Add PostgreSQL 18 Compose service and explicit migration command.
- Implement health and readiness endpoints.
- Add CI for formatting, tests, race detection, and static analysis.

### Milestone 2: schema and bootstrap

- Create users, credentials, installations, devices, activities, telemetry, and channels migrations.
- Implement owner and credential administrative commands.
- Add PostgreSQL integration tests for constraints, ownership, and migrations.

### Milestone 3: idempotent ingestion

- Implement bearer authentication and scopes.
- Implement batch validation, atomic inserts, activity/channel updates, and exact acknowledgements.
- Add conflict detection, limits, rate limiting, and ingestion metrics.
- Validate with archived iOS fixture payloads.

### Milestone 4: live read contract

- Implement service read authentication and short-lived viewer-token exchange.
- Implement server-enforced location policy.
- Implement channel snapshot, SSE fan-out, bounded replay, heartbeats, and slow-client handling.
- Verify CORS and streaming `fetch` behavior with a minimal test client, not the final frontend.

### Milestone 5: iOS uploader

- Introduce a sink/uploader protocol and retain the mock implementation for tests.
- Add HTTPS batch uploader, Keychain credentials, production acknowledgement journal, retry/backoff, and diagnostics.
- Preserve persistence-before-upload and exact-ID semantics.
- Add fixture, recovery, and failure tests.

### Milestone 6: homelab deployment

- Add production Compose, Caddy, and `cloudflared` configuration.
- Provision the Cloudflare hostname and tunnel secret outside Git.
- Confirm no PostgreSQL or API origin port is publicly exposed.
- Validate request limits, trusted proxy handling, CORS, and SSE through Cloudflare.
- Configure encrypted off-host backups and perform a restore test.

### Milestone 7: physical reliability

- Run foreground, locked Wi-Fi, locked cellular, and outage-catch-up tests.
- Compare local NDJSON envelope IDs to committed server IDs.
- Measure delivery ratio and end-to-end latency percentiles.
- Tune iOS batch/retry behavior from measurements without weakening durability.
- Document iOS suspension limitations and observed behavior.

### Milestone 8: frontend planning

- Use the measured API behavior to plan the TanStack Start site and OBS browser-source overlay.
- Keep the long-lived read credential in TanStack Start server-only configuration.
- Exchange it for short-lived viewer tokens and use snapshot plus streaming `fetch` in the browser.
- Define history and analytics screens only after the live overlay works.

## 16. Acceptance Criteria

The server phase is complete when:

- PostgreSQL 18 stores all valid protocol-v1 fields without lossy conversion;
- retries are idempotent by envelope UUID and return exact durable acknowledgements;
- watch sequence gaps, duplicates, resets, and out-of-order delivery cannot corrupt identity or acknowledgement;
- no sample is acknowledged before transaction commit;
- the iOS app preserves unacknowledged samples across termination and retries them safely;
- the live snapshot and SSE stream expose only the channel's configured coordinate precision;
- a stable channel follows the current activity and emits state changes and committed samples;
- long-lived ingest and read credentials are independent, scoped, rotatable, and absent from logs and source control;
- browser viewer tokens are short-lived, channel-limited, and read-only;
- the complete stack works through Cloudflare Tunnel without inbound router forwarding;
- bundled Caddy can be replaced by a shared Caddy instance without changing the API image or public contract;
- PostgreSQL and the API origin are not directly exposed to the internet;
- an encrypted off-host backup can be restored successfully;
- foreground and locked-screen tests report measured delivery and latency rather than claiming guaranteed real-time behavior;
- the API has no dependency on Redis, ClickHouse, TimescaleDB, or any frontend hosting runtime.

## 17. Deferred Decisions

Defer these until real usage supplies evidence:

- interactive multi-user signup and login;
- the TanStack Start frontend and visual design;
- public link UX and per-run sharing workflows;
- start/end location masking and publication delay;
- automatic server or phone retention windows;
- FIT-file import and reconciliation with Garmin's authoritative recording;
- downsampled summary tables and cross-run analytics;
- PostgreSQL partitioning;
- ClickHouse replication;
- multiple API replicas and cross-instance event fan-out;
- PgBouncer, Redis, queues, or a dedicated metrics stack.

None of these should require changing existing envelope IDs, activity IDs, telemetry units, or exact acknowledgement semantics.
