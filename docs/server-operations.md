# Server operations

## Deployment

1. Copy `.env.example` to untracked `.env`. Set distinct API and web hostnames, matching API public URLs, `RUNSYNC_ALLOWED_ORIGINS=https://<web-hostname>`, random and preferably distinct studio/overlay, share, and embed UUIDs, and the remaining required values. Existing deployments may omit the share and embed UUIDs temporarily; both then fall back to the overlay UUID.
2. Create the files selected by `RUNSYNC_POSTGRES_PASSWORD_FILE`, `RUNSYNC_DATABASE_URL_FILE`, `RUNSYNC_VIEWER_TOKEN_SIGNING_KEY_FILE`, and `RUNSYNC_CLOUDFLARE_TOKEN_FILE`. The database URL file contains the full `postgres://runsync:<password>@postgres:5432/runsync?sslmode=disable` URL. The plaintext in `postgres_password` must exactly match the password embedded in the URL, with reserved characters percent-encoded in the URL. The viewer signing-key file contains base64 encoding of at least 32 random bytes, for example output from `openssl rand -base64 48`. Keep `.env` and `secrets/` untracked and make the files readable only by the deployment account.
3. Build the reviewed server revision under the commit-specific image tag selected by `RUNSYNC_API_IMAGE`. The current known-good pin is `docker build --pull --tag runsync-api:8e74040a2676 ./server`. Confirm the checked-out `server/` tree is that revision before building. Start PostgreSQL and run `docker compose --profile migration run --rm migrate`; `migrate` and `api` use the exact same pinned image.
4. If this is a new database, run `docker compose run --rm api admin bootstrap-owner --handle owner --channel-slug live`. Channels default to hidden location. For the live map, explicitly run `docker compose run --rm api admin configure-channel --owner owner --slug live --location-policy precise`, or choose `rounded --coordinate-decimals <0..6>`. Then create the iOS and web credentials as shown in `server/README.md`. Write only the printed web token value to the path selected by `RUNSYNC_WEB_READ_TOKEN_FILE` before starting `web`; never start it with a placeholder or empty secret.
5. In Cloudflare Zero Trust, open the existing named tunnel and add both public hostnames. Set each service URL to `http://caddy:8080`; keep the tunnel's final catch-all at `http_status:404`. Do not create a second tunnel. The unchanged `cloudflared` service token runs that named tunnel, while Caddy uses the trusted `Host` value to select `api:8080` or `web:3000` and rejects every other host.
6. Create a Mapbox public `pk.*` token. Register the exact allowed URL `https://<web-hostname>` without a wildcard, grant only the styles/tile APIs used by Mapbox GL JS, configure usage alerts or limits, and set `MAPBOX_ACCESS_TOKEN`. The web response uses `Referrer-Policy: strict-origin-when-cross-origin` so Mapbox receives that origin for URL enforcement. This token is browser-visible by design; never use a Mapbox secret token.
7. Start with `docker compose up -d postgres api web caddy cloudflared`.
8. Verify the API `/healthz` and `/readyz`, web `/api/health`, preview route, Mapbox attribution, snapshot, full route, token refresh, and an authenticated SSE reconnect through their public hostnames. Compose gates `web` and Caddy on API readiness; web health is static liveness because web configuration and the server-only read-token file are validated at process startup.

No service publishes a host port. For temporary local diagnostics, add a private override that maps Caddy as `127.0.0.1:8080:8080`; never publish PostgreSQL, the API origin, or the web origin.

### Pinned API image

`compose.yaml` deliberately does not contain `build:` for `api` or `migrate`.
Both use `${RUNSYNC_API_IMAGE:-runsync-api:8e74040a2676}` with
`pull_policy: never`. As a result, broad frontend iteration commands such as
`docker compose up -d --build` cannot rebuild or retag the API from a stale
working tree.

To advance the server:

1. Choose the reviewed server commit and a matching immutable tag, for example
   `runsync-api:<12-character-commit>`.
2. Check out or archive that exact revision and build its `server/` directory
   under that tag.
3. Set `RUNSYNC_API_IMAGE` in the deployment's untracked `.env` to the new tag.
4. Run `docker compose --profile migration run --rm migrate`.
5. Run `docker compose up -d api`.
6. Verify the container image, migrations, readiness, and a real telemetry
   acknowledgement before removing the previous local image.

Never reuse a commit-specific tag for different source. Keep the previous image
available until the new API and migration are verified.

### Viewer capacity

The API has fixed in-process SSE ceilings of 50 connections per trusted-proxy-
resolved client IP, 150 per channel, and 200 globally. They provide reconnect
headroom around the 100-viewer deployment target and prevent unbounded socket
and goroutine use. They are resource ceilings, not authentication or complete
DDoS protection, and are intentionally code constants rather than deployment
configuration. A rejected stream receives `429 Too Many Requests` with
`Retry-After`; the existing web session issuance limit remains 20 requests per
IP per minute.

Each stream reuses the location policy loaded and clamped when it connects.
Viewer tokens last at most five minutes, open streams close at expiry, and the
browser reconnect obtains the current policy. Do not add policy polling to the
telemetry fan-out path. If immediate revocation is needed later, add an explicit
policy-change control event.

The API also caches full bootstraps for 30 seconds and coalesces concurrent
misses. Cache identity includes the channel, active activity, effective policy,
and coordinate precision. Committed telemetry invalidates affected entries
before live publication, so this cache does not replace SSE replay or its
high-water consistency contract. Both the SSE registry and bootstrap cache are
per-process; the deployment remains intentionally single-instance.

To use a shared Caddy, attach both `api` and `web` to the shared external proxy network, copy the host matchers from `server/Caddyfile`, point both tunnel hostnames at that Caddy, and omit the bundled `caddy` service. The API does not trust proxy headers unless the proxy address is included in `RUNSYNC_TRUSTED_PROXY_CIDRS`.

## Credentials

Create separate credentials for ingestion and reads. Rotation is create, install the new token, verify it, then revoke the old credential by UUID or displayed prefix:

```sh
runsync admin create-credential --owner owner --name ios-2026-07 --scopes telemetry:write
runsync admin create-credential --owner owner --name web-2026-07 --scopes channels:read
runsync admin revoke-credential --prefix rs_example
```

An ingest credential binds atomically to the first installation UUID that uses it. Use a new credential for a replacement installation.

For web credential rotation, write the newly printed token value to the protected file selected by `RUNSYNC_WEB_READ_TOKEN_FILE`, recreate `web`, verify session bootstrap and SSE, and only then revoke the previous prefix. The permanent token must never enter `.env`, an OBS URL, browser storage, HTML, or client logs.

## Backup and restore

Create a PostgreSQL 18 custom-format dump with the Compose backup profile:

```sh
docker compose --profile backup run --rm backup
```

Set `RUNSYNC_BACKUP_PATH` to a protected host directory. The profile creates one dump but does not schedule, encrypt, retain, or copy it off-host. Integrate the command with the homelab scheduler and backup system.

Retain daily, weekly, and monthly copies according to the homelab backup policy and alert on missed jobs. Quarterly, create an isolated PostgreSQL 18 database, restore with `pg_restore --clean --if-exists`, run `runsync migrate`, compare row counts, and exercise snapshot reads. Record the date, dump identifier, duration, and result. A Docker volume is not a backup.

## Incident checks

- Readiness failures: inspect PostgreSQL health, connection limits, and API JSON logs.
- Ingest conflicts: use logged envelope/activity IDs; never log or inspect coordinates unless explicitly required.
- SSE reconnect loops: verify Cloudflare/Caddy buffering and idle behavior, viewer expiry, and `Last-Event-ID` replay.
- Compromised token: revoke it immediately, create a replacement, and review `last_used_at` without exposing token material.

For a telemetry cutoff on a known activity, correlate private watch transport diagnostics without selecting location or physiological values:

```sql
WITH ordered AS (
  SELECT
    phone_received_at,
    server_received_at,
    watch_sequence,
    watch_build_id,
    transport_timeout_count,
    transport_error_count,
    transport_exception_count,
    transport_consecutive_failures,
    transport_last_outcome,
    lag(phone_received_at) OVER (ORDER BY phone_received_at, envelope_id) AS previous_phone_received_at,
    lag(watch_sequence) OVER (ORDER BY phone_received_at, envelope_id) AS previous_watch_sequence
  FROM telemetry_samples
  WHERE activity_id = $1
  ORDER BY phone_received_at, envelope_id
)
SELECT
  phone_received_at,
  watch_sequence,
  watch_build_id,
  transport_timeout_count,
  transport_error_count,
  transport_exception_count,
  transport_consecutive_failures,
  transport_last_outcome,
  server_received_at - phone_received_at AS phone_to_server_delay,
  phone_received_at - previous_phone_received_at AS receipt_gap,
  watch_sequence - previous_watch_sequence AS sequence_delta
FROM ordered
WHERE previous_phone_received_at IS NULL
   OR phone_received_at - previous_phone_received_at > interval '10 seconds'
   OR watch_sequence - previous_watch_sequence > 1
   OR transport_consecutive_failures > 0
ORDER BY phone_received_at;
```

The in-process SSE hub supports one API replica. Before scaling horizontally, add a committed cross-instance mechanism such as PostgreSQL `LISTEN/NOTIFY` or a transactional outbox.
