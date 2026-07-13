# Server operations

## Deployment

1. Store the PostgreSQL password and Cloudflare tunnel token in secret files or a secret manager. Keep `.env` and `secrets/` untracked.
2. Configure the managed tunnel hostname to route to `http://caddy:8080` and finish tunnel ingress with `http_status:404`. `server/cloudflared.example.yml` shows the equivalent locally managed ingress form.
3. Run `docker compose --profile migration run --rm migrate` before starting a new API image.
4. Start with `docker compose up -d postgres api caddy cloudflared`.
5. Verify `/healthz`, `/readyz`, snapshot, and an authenticated SSE connection through the public hostname.

No service publishes a host port. For temporary local diagnostics, add a private override that maps Caddy as `127.0.0.1:8080:8080`; never publish PostgreSQL or the API origin.

To use a shared Caddy, attach `api` to the shared external proxy network, copy the site block from `server/Caddyfile`, point the tunnel at that Caddy, and omit the bundled `caddy` service. The API does not trust proxy headers unless the proxy address is included in `RUNSYNC_TRUSTED_PROXY_CIDRS`.

## Credentials

Create separate credentials for ingestion and reads. Rotation is create, install the new token, verify it, then revoke the old credential by UUID or displayed prefix:

```sh
runsync admin create-credential --owner owner --name ios-2026-07 --scopes telemetry:write
runsync admin revoke-credential --prefix rs_example
```

An ingest credential binds atomically to the first installation UUID that uses it. Use a new credential for a replacement installation.

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
