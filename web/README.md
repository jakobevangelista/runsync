# RunSync Web

TanStack Start browser-source overlays for the current RunSync activity. The overlay UUID is a public, unlisted identifier; it is discovery resistance, not authentication.

## Toolchain

- Node.js `24.18.0` (production and development pin)
- pnpm `11.13.0`, managed through Vite+
- Vite+ `0.2.4` with its bundled Vite/Vitest/Oxlint/Oxfmt toolchain
- TanStack Start `1.168.28`, TanStack Router `1.170.18`, React `19.2.7`

Use Vite+ rather than package-manager scripts:

```sh
vp install --frozen-lockfile
vp dev
vp check
vp test
vp build
```

No standalone ESLint, Prettier, Vite, or Vitest configuration is used.

## Local Fixture Mode

The app and tests work without a RunSync API credential or Mapbox token. Fixture mode serves a realistic bootstrap and renders the styled map fallback:

```sh
RUNSYNC_USE_FIXTURES=true vp dev
```

Open `http://localhost:3000/live/7a85db43-30ba-4de7-bb5e-7f2038937538/preview`.

## Local End-to-End Development

The repository root provides `compose.dev.yaml` and `.env.local.example`. The development override publishes the API only on `127.0.0.1:8081` and Caddy only on `127.0.0.1:8080`; PostgreSQL remains private.

After completing the one-time database and credential bootstrap in the root README, run the real Go API and PostgreSQL:

```sh
docker compose --env-file .env.local -f compose.yaml -f compose.dev.yaml up -d postgres api
```

Then start the TanStack application with Vite+ HMR:

```sh
cd web
set -a
. ../.env.local
set +a
vp install --frozen-lockfile
vp dev
```

Open `http://localhost:3000/live/7a85db43-30ba-4de7-bb5e-7f2038937538/preview`. This path uses the real PostgreSQL database, the Go consistent-bootstrap endpoint, viewer-token exchange, and SSE stream. HTTP API URLs are accepted only for `localhost`, `127.0.0.1`, or `::1`; non-loopback deployments still require HTTPS.

For a production-like local container test instead of HMR, start `postgres api web caddy` with both Compose files and open `http://live.runsync.localhost:8080/live/7a85db43-30ba-4de7-bb5e-7f2038937538/preview`. Modern browsers resolve `*.localhost` to loopback without an `/etc/hosts` entry.

## Production Configuration

The production server validates configuration when its server entry loads and exits if required values or the credential file are missing.

```text
RUNSYNC_API_INTERNAL_URL=http://api:8080
RUNSYNC_API_PUBLIC_URL=https://runsync-api.example.com
RUNSYNC_API_READ_TOKEN_FILE=/run/secrets/runsync_web_read_token
RUNSYNC_CHANNEL_SLUG=live
RUNSYNC_OVERLAY_ID=<random UUID>
RUNSYNC_DEFAULT_UNITS=imperial
RUNSYNC_DEFAULT_PACE=rolling
MAPBOX_ACCESS_TOKEN=<public hostname-restricted pk token, optional>
```

The permanent `channels:read` token is read only by the Start server. `POST /api/live/<overlayId>/session` exchanges it for a five-minute viewer token and fetches one repeatable-read bootstrap with `Cache-Control: no-store`. Browser SSE uses the short-lived token only in an `Authorization` header and resumes from bootstrap `replayAfterEnvelopeId`, never from the latest phone-time metrics sample. Never place either token in an OBS URL.

Route geometry is ordered by phone receipt time and envelope UUID. Bootstrap responses contain at most 5,000 deterministically sampled points, and the browser keeps the origin plus newest points when additional live samples exceed 5,000. This is a rendering bound only; it does not limit server ingestion or telemetry retention.

`MAPBOX_ACCESS_TOKEN` is public by design. Restrict it to the deployed frontend hostname and required styles/APIs. Without it, or without WebGL, map routes show a stable fallback while metrics continue to work. Mapbox receives tile requests and viewer network metadata when configured.

## Routes

```text
/live/<overlayId>/preview
/live/<overlayId>/map
/live/<overlayId>/metrics?units=imperial&pace=rolling
/live/<overlayId>/metric/pace
/live/<overlayId>/metric/heart-rate
/live/<overlayId>/metric/distance
/api/health
```

Supported query values are `units=imperial|metric` and `pace=rolling|average`; invalid values use deployment defaults. Unknown overlay and metric IDs return 404 without revealing deployment configuration.

Recommended OBS sizes are listed on the preview page. Browser sources should use 30 FPS and “Refresh browser when scene becomes active.” Map and metric pages have transparent outer backgrounds.

## Container

Build from this directory so no repository-level files enter the context:

```sh
docker build -t runsync-web .
```

The multi-stage image builds with the exact Vite+ release, copies the pinned Node 24 runtime, installs production-only dependencies separately, and runs as `nobody` on port `3000`. Mount the read token as a runtime secret; do not pass it as a build argument. Probe `GET /api/health` for health checks. The container supports a read-only root filesystem when `/tmp` is supplied as a writable tmpfs if required by the runtime.
