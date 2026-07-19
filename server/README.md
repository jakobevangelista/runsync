# RunSync server

The server is a Go 1.26 `net/http` service backed by PostgreSQL 18. It accepts exact-ID telemetry batches and exposes policy-filtered channel bootstraps and SSE.

## Local setup

Enter the optional canonical tool environment with `nix develop`, or install Go 1.26 and a PostgreSQL 18 client directly. Create an untracked `.env` from `.env.example`, then create the secret files described in `docs/server-operations.md`. In particular, `postgres_password` must exactly match the password embedded in URL-encoded form in `runsync_database_url`. Bootstrap the database and credentials before starting the web service:

```sh
docker compose up -d postgres
docker compose --profile migration run --rm migrate
docker compose run --rm api admin bootstrap-owner --handle owner --channel-slug live
docker compose run --rm api admin configure-channel --owner owner --slug live --location-policy precise
docker compose run --rm api admin create-credential --owner owner --name ios --scopes telemetry:write
web_token="$(docker compose run --rm api admin create-credential --owner owner --name web --scopes channels:read | sed -n 's/^token=//p')"
test -n "$web_token"
(umask 077; printf '%s\n' "$web_token" > secrets/runsync_web_read_token)
unset web_token
docker compose up -d api web caddy cloudflared
```

Tokens are printed once. Put the iOS token directly in Keychain. The commands above extract only the value after `token=` into `secrets/runsync_web_read_token` before the web container starts; change that output path if `RUNSYNC_WEB_READ_TOKEN_FILE` selects another file. Compose mounts it server-side at `/run/secrets/runsync_web_read_token`. Do not add either token to `.env` or Compose configuration.

Channels default to hidden location. The explicit `configure-channel` command above enables the precise route required by the live map. Use `--location-policy rounded --coordinate-decimals 3` for reduced precision, or switch back to `hidden` at any time.

Set `RUNSYNC_API_HOST` and `RUNSYNC_WEB_HOST` to the two public hostnames. In the existing named Cloudflare Tunnel, configure both hostnames with service URL `http://caddy:8080`; do not create another tunnel or publish container ports. Create a public `pk.*` Mapbox token, register the exact allowed URL `https://<RUNSYNC_WEB_HOST>` without a wildcard, grant only the styles/tile APIs the map uses, and set `MAPBOX_ACCESS_TOKEN`. See `docs/server-operations.md` for the manual deployment checklist.

For development without Compose:

```sh
cd server
go run ./cmd/runsync migrate
go run ./cmd/runsync serve
```

## API

- `POST /v1/telemetry/batches`: requires `telemetry:write`; maximum 100 envelopes and 256 KiB.
- `POST /v1/viewer-tokens`: requires `channels:read`; viewer lifetime is at most five minutes.
- `GET /v1/channels/{slug}/bootstrap`: accepts a read service credential or viewer token and returns one repeatable-read snapshot, policy-filtered route, and `replayAfterEnvelopeId` ingest high-water.
- `GET /v1/channels/{slug}/snapshot`: legacy read accepting a read service credential or viewer token.
- `GET /v1/channels/{slug}/route`: legacy read accepting a read service credential or viewer token.
- `GET /v1/channels/{slug}/stream`: requires a viewer token and a streaming client that can set `Authorization`.
- `GET /healthz` and `GET /readyz`: minimal liveness and database readiness.

All bearer tokens belong in the `Authorization` header. SSE replay uses `Last-Event-ID`, never a URL token.

Viewer-token expiry is enforced for already-open streams. Replay IDs remain envelope UUIDs, while the server resolves them to a durable per-user ingest cursor so delayed phone timestamps are not skipped. Bootstrap and legacy full routes are ordered by phone receipt time and envelope UUID, then deterministically downsampled to at most 5,000 points while preserving both endpoints. The browser also caps live rendered geometry at 5,000 points; this is a display bound, not an ingestion or retention limit.

## Proxy trust

The Compose deployment keeps the API and web service on the internal `backend` network and Caddy on both `backend` and the isolated `edge` network with Cloudflare Tunnel. Caddy rejects unknown hosts, trusts private-network upstreams for `CF-Connecting-IP`, and preserves unbuffered API/SSE proxying. The API trusts private-network Caddy addresses for `X-Forwarded-For`. Do not publish the API, web, or Caddy container ports while using these defaults. If a service is exposed through another network path, set `RUNSYNC_TRUSTED_PROXY_CIDRS` to only the exact Caddy network/address and adjust Caddy's `trusted_proxies` to only the actual tunnel proxy addresses.

## Backups

Set `RUNSYNC_BACKUP_PATH` to a protected host directory and run a custom-format dump with:

```sh
docker compose --profile backup run --rm backup
```

The resulting `runsync-<UTC timestamp>.dump` is written beneath that mounted path. This one-shot profile does not provide scheduling, retention, encryption, restore testing, or off-host copies; operators must integrate those controls with their scheduler and backup system.

## Tests

```sh
cd server
gofmt -w .
go test ./...
go test -race ./...
```

Database integration tests are opt-in and require a disposable PostgreSQL 18 database. Some tests truncate RunSync tables:

```sh
RUNSYNC_TEST_DATABASE_URL='postgres://runsync:password@localhost:5432/runsync_test?sslmode=disable' go test -p 1 ./internal/ingest ./internal/live ./internal/api
```
