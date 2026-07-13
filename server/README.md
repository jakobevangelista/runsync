# RunSync server

The server is a Go 1.26 `net/http` service backed by PostgreSQL 18. It accepts exact-ID telemetry batches and exposes policy-filtered channel snapshots and SSE.

## Local setup

Enter the optional canonical tool environment with `nix develop`, or install Go 1.26 and a PostgreSQL 18 client directly. Create an untracked `.env` from `.env.example`, create the two files below `secrets/`, then run:

```sh
docker compose up -d postgres
docker compose --profile migration run --rm migrate
docker compose run --rm api admin bootstrap-owner --handle owner --channel-slug live
docker compose run --rm api admin create-credential --owner owner --name ios --scopes telemetry:write
docker compose run --rm api admin create-credential --owner owner --name web --scopes channels:read
docker compose up -d api caddy cloudflared
```

Tokens are printed once. Put them directly in the iOS Keychain or the frontend's server-only secret store; do not add them to `.env` or Compose configuration.

For development without Compose:

```sh
cd server
go run ./cmd/runsync migrate
go run ./cmd/runsync serve
```

## API

- `POST /v1/telemetry/batches`: requires `telemetry:write`; maximum 100 envelopes and 256 KiB.
- `POST /v1/viewer-tokens`: requires `channels:read`; viewer lifetime is at most five minutes.
- `GET /v1/channels/{slug}/snapshot`: accepts a read service credential or viewer token.
- `GET /v1/channels/{slug}/stream`: requires a viewer token and a streaming client that can set `Authorization`.
- `GET /healthz` and `GET /readyz`: minimal liveness and database readiness.

All bearer tokens belong in the `Authorization` header. SSE replay uses `Last-Event-ID`, never a URL token.

Viewer-token expiry is enforced for already-open streams. Replay IDs remain envelope UUIDs, while the server resolves them to a durable per-user ingest cursor so delayed phone timestamps are not skipped.

## Proxy trust

The Compose deployment keeps the API on the internal `backend` network and Caddy on the isolated `edge` network with Cloudflare Tunnel. Caddy trusts private-network upstreams for `CF-Connecting-IP`, and the API trusts private-network Caddy addresses for `X-Forwarded-For`. Do not publish the API or Caddy container ports while using these defaults. If either service is exposed through another network path, set `RUNSYNC_TRUSTED_PROXY_CIDRS` to only the exact Caddy network/address and adjust Caddy's `trusted_proxies` to only the actual tunnel proxy addresses.

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

Database integration tests are opt-in and require a disposable PostgreSQL 18 database. The tests truncate RunSync tables:

```sh
RUNSYNC_TEST_DATABASE_URL='postgres://runsync:password@localhost:5432/runsync_test?sslmode=disable' go test ./internal/ingest
```
