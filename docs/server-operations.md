# Server operations

## Deployment

1. Copy `.env.example` to untracked `.env`. Set distinct API and web hostnames, matching API public URLs, `RUNSYNC_ALLOWED_ORIGINS=https://<web-hostname>`, a random overlay UUID, and the remaining required values.
2. Create the files selected by `RUNSYNC_POSTGRES_PASSWORD_FILE`, `RUNSYNC_DATABASE_URL_FILE`, `RUNSYNC_VIEWER_TOKEN_SIGNING_KEY_FILE`, and `RUNSYNC_CLOUDFLARE_TOKEN_FILE`. The database URL file contains the full `postgres://runsync:<password>@postgres:5432/runsync?sslmode=disable` URL. The plaintext in `postgres_password` must exactly match the password embedded in the URL, with reserved characters percent-encoded in the URL. The viewer signing-key file contains base64 encoding of at least 32 random bytes, for example output from `openssl rand -base64 48`. Keep `.env` and `secrets/` untracked and make the files readable only by the deployment account.
3. Start PostgreSQL and run `docker compose --profile migration run --rm migrate` before starting a new API image.
4. If this is a new database, run `docker compose run --rm api admin bootstrap-owner --handle owner --channel-slug live`. Channels default to hidden location. For the live map, explicitly run `docker compose run --rm api admin configure-channel --owner owner --slug live --location-policy precise`, or choose `rounded --coordinate-decimals <0..6>`. Then create the iOS and web credentials as shown in `server/README.md`. Write only the printed web token value to the path selected by `RUNSYNC_WEB_READ_TOKEN_FILE` before starting `web`; never start it with a placeholder or empty secret.
5. In Cloudflare Zero Trust, open the existing named tunnel and add both public hostnames. Set each service URL to `http://caddy:8080`; keep the tunnel's final catch-all at `http_status:404`. Do not create a second tunnel. The unchanged `cloudflared` service token runs that named tunnel, while Caddy uses the trusted `Host` value to select `api:8080` or `web:3000` and rejects every other host.
6. Create a Mapbox public `pk.*` token. Register the exact allowed URL `https://<web-hostname>` without a wildcard, grant only the styles/tile APIs used by Mapbox GL JS, configure usage alerts or limits, and set `MAPBOX_ACCESS_TOKEN`. The web response uses `Referrer-Policy: strict-origin-when-cross-origin` so Mapbox receives that origin for URL enforcement. This token is browser-visible by design; never use a Mapbox secret token.
7. Start with `docker compose up -d postgres api web caddy cloudflared`.
8. Verify the API `/healthz` and `/readyz`, web `/api/health`, preview route, Mapbox attribution, snapshot, full route, token refresh, and an authenticated SSE reconnect through their public hostnames. Compose gates `web` and Caddy on API readiness; web health is static liveness because web configuration and the server-only read-token file are validated at process startup.

No service publishes a host port. For temporary local diagnostics, add a private override that maps Caddy as `127.0.0.1:8080:8080`; never publish PostgreSQL, the API origin, or the web origin.

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

The in-process SSE hub supports one API replica. Before scaling horizontally, add a committed cross-instance mechanism such as PostgreSQL `LISTEN/NOTIFY` or a transactional outbox.
