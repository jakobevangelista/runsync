# RunSync Frontend Implementation Plan

## 1. Purpose

Build a small TanStack Start application that presents the current RunSync activity as broadcast-ready browser sources for OBS or another streaming platform.

The first version has two jobs:

- render low-latency, composable overlays for the route map and live metrics;
- provide a normal browser preview page for checking connection state and generating OBS URLs.

The application runs in the homelab as a Docker service and is exposed through the existing Cloudflare Tunnel and Caddy boundary. It consumes the Go API's snapshot, short-lived viewer-token, and Server-Sent Events contracts. The permanent RunSync read credential remains server-side.

The first version is intentionally not a general fitness dashboard, account system, or historical analytics application.

### Implementation status (2026-07-13)

Milestones 1 through 5 are implemented, including the full-route API, durable final snapshot, Vite+ frontend toolchain, server-side session broker, streaming client, and metric overlays. The Mapbox overlay, preview page, Compose service, Caddy routing, secret files, and deployment documentation are also implemented.

Automated Go, PostgreSQL 18, Vite+, Nix, container, and disposable full-stack smoke tests pass. The remaining acceptance work requires deployment-specific inputs and real clients: configure the Cloudflare hostnames, install a hostname-restricted Mapbox token, validate Mapbox rendering and attribution, exercise the public tunnel, position sources in OBS, and complete the two-hour OBS endurance test.

## 2. Product Decisions

The following decisions are fixed for the first implementation:

- Use TanStack Start, React, TypeScript, and Vite through the Vite+ toolchain.
- Host the application in the homelab, not Vercel.
- Optimize the initial design for a 1920x1080 landscape OBS scene while remaining responsive.
- Provide separate browser-source routes for the map and metrics.
- Provide a combined three-metric panel and individual pace, heart-rate, and distance routes.
- Include activity state, elapsed time, altitude, and total ascent in the combined panel.
- Keep the final route and values visible after the activity ends.
- Use a high-contrast broadcast-dark visual language.
- Support metric and imperial units through validated URL query parameters.
- Support rolling and whole-activity pace through validated URL query parameters.
- Use official Mapbox GL JS with a public, hostname-restricted Mapbox token.
- Follow the runner with the map camera while retaining the full route line.
- Use a stable random UUID as the public overlay identifier. It is discovery resistance, not authentication.
- Keep the permanent API read credential in the TanStack Start server runtime.
- Mint short-lived, channel-scoped API viewer tokens for browsers.
- Recover the full current route after refresh or reconnect, including runs longer than 30 minutes.
- Add the smallest required Go API extension for bounded full-route recovery before calling the map complete.

## 3. User Experience

### 3.1 Public routes

Use one deployment-configured overlay UUID, for example `7a85db43-30ba-4de7-bb5e-7f2038937538`.

```text
/live/<overlayId>/preview
/live/<overlayId>/map
/live/<overlayId>/metrics
/live/<overlayId>/metric/pace
/live/<overlayId>/metric/heart-rate
/live/<overlayId>/metric/distance
```

Unknown overlay IDs return a plain 404 and must not reveal the configured ID, channel slug, API hostname, or credential state.

The UUID route is public. Anyone who learns it can view the same information shown on stream. It must not be described as a secret or as strong authorization.

### 3.2 Preview page

The preview page is a normal responsive page, not an OBS overlay. It should show:

- a combined representation of the map and metric panel;
- connection state: connecting, live, reconnecting, stale, ended, or error;
- latest sample age;
- current activity ID and latest envelope ID for diagnostics;
- the configured location-disclosure mode reported by the server, without exposing credentials;
- generated OBS URLs for the map, panel, and individual counters;
- controls for units and pace mode that update the generated URLs;
- a copy button for each URL;
- recommended OBS width, height, and refresh settings.

The preview page must not receive or display the permanent API read token.

### 3.3 OBS map source

The map route fills its browser-source viewport and renders:

- a Mapbox dark basemap;
- the complete route as a high-contrast line with a subtle casing or glow;
- a distinct start marker;
- an animated current-position marker;
- a small state indicator;
- required Mapbox attribution and branding;
- a transparent outer page background so OBS can crop or transform it cleanly.

Default camera behavior:

- once the first usable location arrives, center on it at a deployment-tuned running zoom;
- ease toward new positions rather than jumping once per second;
- throttle camera animation so one-second updates do not cause constant visual vibration;
- preserve north-up orientation initially;
- follow while waiting, running, paused, or stopped;
- stop camera movement and retain the final route when ended;
- do not continually fit the full route, because that makes the runner progressively smaller during a long run.

Do not draw a point when coordinates are absent. Do not treat missing coordinates as `0,0`. GPS quality may affect marker confidence styling, but valid server-returned coordinates remain the source of truth.

### 3.4 OBS metric panel

The panel route renders:

- pace;
- heart rate;
- distance;
- elapsed time;
- altitude and total ascent;
- activity state.

Visual hierarchy:

- pace, heart rate, and distance use the largest numerals;
- units are visibly subordinate but remain readable at stream resolution;
- elapsed time and elevation use a compact secondary row;
- state is a restrained pill or signal, not a large alert;
- the page outside cards is transparent;
- values use tabular numerals to prevent layout shifting.

### 3.5 Individual metric routes

Each individual metric route contains only one broadcast counter and its label/unit. It must resize cleanly to arbitrary OBS browser-source dimensions without assuming a 16:9 viewport.

The individual routes share the same data and formatting implementation as the combined panel. Do not duplicate pace, distance, or missing-value logic in route components.

### 3.6 Final and stale behavior

The user selected "keep final result." Apply these rules:

- `ended`: retain the final route and metrics indefinitely while the page remains open and after refresh while the server's active channel still points to that activity;
- `paused` or `stopped`: retain values and show the state without pretending updates are live;
- temporary disconnect during an active run: freeze the latest values and show a subtle stale/reconnecting indicator;
- no activity yet: show a deliberate waiting state, not zeros that look like real measurements;
- activity ID changes: atomically reset the route, pace window, deduplication state, and displayed metrics to the new activity snapshot.

Do not automatically hide the overlay when telemetry stops.

## 4. Visual Direction

Use a broadcast-dark system rather than a generic dashboard aesthetic.

Suggested visual language:

- near-black graphite background surfaces;
- cool gray map framing and typography;
- electric lime or cyan for route/live state;
- warm coral for heart rate;
- off-white primary numerals;
- thin borders, restrained glow, and low-blur shadows that survive video compression;
- condensed display numerals paired with a neutral sans-serif UI face;
- locally bundled open-license fonts so OBS rendering does not depend on third-party font requests.

Use CSS custom properties for colors, type scale, radii, and overlay opacity. Keep a single dark theme in the MVP; do not build a theme editor.

Animations must be functional and restrained:

- ease map position changes;
- interpolate number changes only when it improves readability;
- do not pulse the entire UI every second;
- honor `prefers-reduced-motion`;
- avoid expensive filters that make OBS browser rendering unstable.

## 5. Query Configuration

OBS behavior is controlled by validated query parameters:

```text
?units=imperial&pace=rolling
?units=metric&pace=average
```

Supported values:

```text
units = imperial | metric
pace = rolling | average
```

Defaults:

- `units`: deployment setting, with `imperial` as the initial example;
- `pace`: `rolling`;

Invalid values fall back to configured defaults and do not reach arbitrary component or API behavior. The preview page always generates explicit query values so OBS links remain stable if deployment defaults later change.

Do not put API credentials, Mapbox private tokens, or session bearer tokens in browser-source URLs.

## 6. Metric Semantics

### 6.1 Distance

The API supplies cumulative decimeters.

- imperial: convert to miles and display two decimals below 10 miles, then one decimal unless design testing shows otherwise;
- metric: convert to kilometers with equivalent precision;
- never integrate speed to create a second distance source;
- preserve the last valid value when a sample omits distance.

### 6.2 Heart rate

- display the latest valid BPM as an integer;
- show an em dash or deliberate unavailable glyph before the first valid value;
- preserve the last valid value across nullable samples;
- do not infer heart-rate zones without user-specific zone configuration;
- do not color a missing heart-rate value as healthy or low.

### 6.3 Rolling pace

Prefer cumulative distance and elapsed time over instantaneous speed to reduce one-second GPS noise.

Maintain a bounded recent window of samples from the same activity. Compute:

```text
pace = elapsed-time delta / distance delta
```

Initial rules:

- target a 10-second recent window;
- require a minimum positive distance delta before emitting a new pace;
- ignore regressions and activity changes;
- do not update rolling pace while paused, stopped, or ended;
- retain the last valid pace during pause and at activity end;
- fall back to speed-derived pace only when the cumulative fields needed for the window are unavailable;
- clamp physically implausible values to unavailable rather than displaying extreme garbage.

Format as `M:SS /mi` or `M:SS /km`.

### 6.4 Average pace

Compute whole-activity pace from cumulative elapsed time and distance. Use the same validity checks and unit formatter as rolling pace. Do not average already-formatted pace strings.

### 6.5 Elapsed time

Format `elapsedTimeMilliseconds` as:

- `MM:SS` under one hour;
- `H:MM:SS` at or above one hour.

Do not run an independent browser timer that drifts away from Garmin telemetry. Optional visual interpolation between fresh samples may be considered only after comparison with actual pause/resume behavior.

### 6.6 Elevation and ascent

- altitude is supplied in decimeters;
- total ascent is supplied in meters;
- imperial displays feet;
- metric displays meters;
- label altitude and ascent distinctly;
- preserve nullable semantics.

### 6.7 State

Map the API state explicitly:

```text
0 waiting
1 running
2 paused
3 stopped
4 ended
```

Do not infer ended from an SSE disconnect or stale sample age.

## 7. Full-Route API Prerequisite

The existing snapshot returns at most 500 points from the last 30 minutes. That is enough to start a recent trail but cannot restore a complete long run after OBS refreshes.

Before the map acceptance criteria can pass, add:

```http
GET /v1/channels/{slug}/route
Authorization: Bearer <service-or-viewer-token>
```

Suggested response:

```json
{
  "channelId": "...",
  "activityId": "...",
  "locationPolicy": "precise",
  "points": [
    {
      "envelopeId": "...",
      "phoneReceivedAt": "2026-07-12T18:42:01.250Z",
      "latitudeMicrodegrees": 37774920,
      "longitudeMicrodegrees": -122419380,
      "gpsQuality": 4
    }
  ],
  "serverTime": "2026-07-12T18:42:01.410Z"
}
```

Server requirements:

- scope by authenticated user and channel;
- use the channel's active activity only;
- enforce the same `precise`, `rounded`, or `hidden` location policy as snapshot and SSE;
- return an empty point array when location is hidden or unavailable;
- return the effective location policy so the preview can explain whether coordinates are precise, rounded, or hidden;
- order points by activity time with deterministic ingest-cursor tie-breaking;
- include the first point, latest point, and enough intermediate geometry to preserve turns;
- bound the response to at most 5,000 points initially;
- downsample deterministically when the route exceeds the bound;
- return `Cache-Control: no-store`;
- do not include installation, Garmin device, user, or ingest credential metadata.

For MVP volume, a deterministic stride that always preserves first and last points is acceptable. If route quality is visibly poor, replace it with a geometry-aware algorithm such as Douglas-Peucker without changing the response contract.

The frontend loads the full route once per activity, then appends deduplicated SSE locations. It must not refetch the full route once per sample.

Also adjust the existing snapshot implementation so `latest` always returns the active activity's most recent sample, even when that sample is older than the current 30-minute recent-route window. Without this separation, a refreshed ended overlay eventually loses its final metrics even though the channel still points to the ended activity.

## 8. Frontend Architecture

### 8.1 Repository layout

Add the application under `web/`:

```text
web/
  app/
    components/
    lib/
    routes/
    styles/
  public/
  tests/
  Dockerfile
  package.json
  tsconfig.json
  vite.config.ts
```

Use the TanStack Start file-based router and server functions. The selected stack is TanStack Start `1.168.28` (the upstream project is currently a release candidate), TanStack Router `1.170.18`, React `19.2.7`, and Vite+ `0.2.4` (beta). Pin every package exactly in `package.json` and `pnpm-lock.yaml`, and pin the build image to the exact Vite+ tag rather than `latest`.

### 8.2 Package and tool choices

- Node.js `24.18.0`, pinned in `.node-version` and copied from the Vite+ build image into the production image;
- pnpm `11.13.0`, declared by `packageManager` and invoked through Vite+ rather than as the repository's frontend command surface;
- Vite+ `0.2.4` beta as the canonical frontend entry point: `vp install --frozen-lockfile`, `vp check`, `vp test`, and `vp build`;
- TanStack Start `1.168.28` release-candidate line and TanStack Router `1.170.18`;
- React and TypeScript with strict checking;
- official `mapbox-gl` for map rendering;
- a small schema validator such as Zod only where runtime validation is needed;
- Vite+'s bundled Vitest plus Testing Library for unit/component tests;
- Playwright for route and visual checks.

Do not add a client state-management framework for the MVP. One activity store built around a reducer or external-store interface is sufficient.

The root Nix shell supplies Node.js 24 and pnpm 11 for a system-first environment, but Vite+ is absent from the pinned nixpkgs and upstream Nix support is incomplete. Do not wrap the installer, fetched binary, or Docker daemon in a derivation and call it reproducible. After `nix develop`, install the exact CLI with `curl -fsSL https://vite.plus | env VP_VERSION=0.2.4 bash`, explicitly run `vp env off` so Vite+ prefers the Nix runtime, and then run `vp install` from `web/`. The shell must not alter an arbitrary `vp` installation automatically. Alternatively, run commands through `ghcr.io/voidzero-dev/vite-plus:0.2.4`. The shell exposes `web/node_modules/.bin` on `PATH` after installation. Until Vite+ and all install inputs can be represented by fixed-output Nix dependencies, the flake must not expose a web package/check; container and local `vp` checks remain the honest validation path.

### 8.3 Server-only configuration

Expected runtime configuration:

```text
RUNSYNC_API_INTERNAL_URL=http://api:8080
RUNSYNC_API_PUBLIC_URL=https://runsync-api.example.com
RUNSYNC_API_READ_TOKEN_FILE=/run/secrets/runsync_web_read_token
RUNSYNC_CHANNEL_SLUG=live
RUNSYNC_OVERLAY_ID=<random UUID>
RUNSYNC_DEFAULT_UNITS=imperial
RUNSYNC_DEFAULT_PACE=rolling
MAPBOX_ACCESS_TOKEN=<public pk token>
```

The read credential is a Docker secret and server-only. Fail startup if it is missing. The Mapbox browser token is public by design but must be a `pk.*` token restricted in Mapbox to the deployed frontend hostname and only the required APIs/styles.

Never expose `RUNSYNC_API_INTERNAL_URL` or the long-lived read token through route loaders, serialized server state, logs, source maps, or client bundles.

### 8.4 Session bootstrap

Add a same-origin TanStack server endpoint or server function for the browser:

```text
POST /api/live/<overlayId>/session
```

Behavior:

1. validate the overlay UUID against deployment configuration;
2. apply per-IP rate limiting at Caddy/Cloudflare and a conservative application limit;
3. use the server-only `channels:read` credential to request a five-minute viewer token from the Go API;
4. use that viewer token to fetch snapshot and full route, or return enough session data for the browser to fetch them directly;
5. return only the short-lived token, expiry, public API URL, snapshot, route, and public Mapbox configuration;
6. set `Cache-Control: no-store`;
7. never return the permanent read credential.

Bundling snapshot and route into bootstrap reduces public round trips and lets the TanStack server report one sanitized initialization failure. The browser still connects directly to the Go SSE endpoint for lowest latency.

### 8.5 Live client

Native `EventSource` cannot set an `Authorization` header. Implement a small streaming-`fetch` SSE client that:

- sends the viewer token in `Authorization: Bearer`;
- parses events correctly across arbitrary response chunk boundaries;
- records the latest envelope UUID as replay position;
- sends `Last-Event-ID` on reconnect;
- handles `sample`, `activity`, heartbeat comments, and `reset`;
- deduplicates by envelope UUID;
- aborts and refreshes the viewer token before expiry;
- reconnects with bounded exponential backoff and jitter;
- reloads snapshot and full route after a `reset` event;
- stops work when its owning route unmounts;
- never logs bearer tokens or precise coordinate payloads.

Use the latest snapshot envelope ID as the initial `Last-Event-ID` so samples committed between snapshot creation and stream subscription are replayed.

### 8.6 Activity store

Maintain one route-local store with:

```text
connection state
channel ID
activity ID
latest sample
latest envelope ID
deduplicated route points
rolling pace window
last valid formatted-source values
sample age
viewer-token expiry
```

The store accepts snapshot, route, sample, activity, reset, stale, and connection events. Keep raw canonical integer values in state; convert and format at selectors/component boundaries.

When the activity ID changes, reset all activity-scoped state before applying new data.

## 9. Mapbox Integration

Use official Mapbox GL JS and a Mapbox dark style suitable for broadcast.

Implementation constraints:

- dynamically import the map component client-side so SSR never touches `window`, WebGL, or workers;
- create one map instance per mounted map route;
- represent the route as one GeoJSON `LineString` source;
- update source data incrementally or in bounded batches rather than recreating the map;
- use one source/layer for route casing and one for the colored route line;
- update a reusable current-position marker;
- disable unnecessary controls and interactions for OBS;
- keep attribution visible and comply with Mapbox terms;
- account for WebGL context loss and recreate the map if necessary;
- show a styled non-map fallback if WebGL initialization fails.

Mapbox token controls:

- use a public token with URL restrictions for the frontend hostname;
- grant only required scopes;
- configure usage alerts or spending limits;
- never use a secret Mapbox token in browser code;
- document that each OBS source and preview browser may generate tile requests.

Keep provider-specific code inside the map adapter/component. Metric routes must have no dependency on Mapbox or load its JavaScript.

## 10. Deployment And Tunneling

### 10.1 Docker service

Use the official `ghcr.io/voidzero-dev/vite-plus:0.2.4` image in the build and production-dependency stages of a multi-stage `web/Dockerfile` that:

- installs from the pinned lockfile;
- builds the TanStack Start production server;
- runs as a non-root user;
- exposes only its internal application port;
- has a minimal health endpoint;
- does not bake runtime secrets into image layers;
- uses a read-only filesystem and temporary writable directories where practical.

Add `web` to the root Compose stack on the private backend network.

### 10.2 Shared Caddy routing

Use the existing `cloudflared -> Caddy` boundary. Configure two public hostnames:

```text
runsync-api.example.com  -> Caddy -> api:8080
runsync-live.example.com -> Caddy -> web:3000
```

Both Cloudflare public hostnames may target `http://caddy:8080` inside the tunnel. Caddy selects the upstream from the trusted `Host` header.

Update Caddy to:

- reject unknown hostnames;
- route the API hostname only to the Go API;
- route the live hostname only to TanStack Start;
- preserve SSE streaming and disable buffering on API streams;
- apply appropriate security headers;
- avoid caching session bootstrap, snapshots, route responses, or live HTML containing session state;
- support WebGL/Mapbox Content Security Policy requirements without broad unsafe allowances where avoidable.

The frontend server should call the Go API over the private Docker network for token exchange and bootstrap. Browser SSE uses the public API hostname because the browser cannot resolve Docker service names.

### 10.3 Cloudflare configuration

Manual operator actions:

- add the live frontend public hostname to the existing named tunnel;
- point it at internal Caddy;
- keep the API hostname route;
- configure DNS through the tunnel, with no router port forwarding;
- verify long-lived SSE behavior through Cloudflare;
- add basic rate limiting for session bootstrap and obvious abuse;
- avoid Cloudflare Access on the OBS route because unattended OBS login is brittle;
- restrict the Mapbox public token to the live hostname.

The stable overlay UUID remains in the path. Cloudflare and application logs should avoid unnecessary query-string logging.

## 11. Security And Privacy

- Treat the overlay as publicly viewable data.
- Treat the random UUID as an unlisted identifier, not authentication.
- Keep the long-lived `channels:read` token server-side and in a Docker secret.
- Give browsers only five-minute, read-only, channel-scoped viewer tokens.
- Refresh tokens automatically without putting them in URLs.
- Apply the Go server's location policy to snapshot, full route, replay, and SSE.
- Never attempt to increase location precision in the frontend.
- Do not include precise coordinates, API payloads, or tokens in analytics or error reporting.
- Disable third-party analytics initially.
- Set the web response's `Referrer-Policy` to `strict-origin-when-cross-origin` so hostname-restricted Mapbox public tokens receive the exact web origin without disclosing the overlay path or UUID cross-origin. The API may use `no-referrer`.
- Keep source maps private or omit them from public production output unless an explicit secure error-reporting design is added.
- Use an explicit API CORS allowlist containing only the live frontend origin and approved local development origins.
- Rate-limit public session creation even though resulting tokens are read-only.
- Return sanitized errors to the browser and detailed token-free errors to server logs.

Mapbox receives tile/style requests and the viewer's network metadata. Document this external dependency in the deployment privacy notes.

## 12. Performance And OBS Compatibility

OBS browser sources use Chromium Embedded Framework and may run for hours. Optimize for stability rather than animation density.

- keep metric routes free of Mapbox bundles;
- lazy-load the map only on map and preview routes;
- cap in-memory route points and rely on server downsampling at bootstrap;
- deduplicate SSE events before rendering;
- batch route source updates if one-second updates cause excess map work;
- avoid rerendering the full React tree for a ticking sample-age label;
- use CSS containment where useful;
- use local fonts and fixed numeral metrics to avoid layout shifts;
- test transparency and device-pixel-ratio behavior in OBS;
- tolerate OBS source shutdown/reload by restoring snapshot and route;
- avoid service workers in the first version so stale overlay assets and sessions are easier to reason about;
- set explicit no-store behavior for live/session responses while allowing immutable hashed static assets to cache.

Target behavior on the homelab:

- initial overlay usable within three seconds on a warm network;
- new committed samples reflected shortly after SSE receipt, normally within one animation frame plus map throttling;
- no unbounded memory growth over a four-hour browser-source run;
- reconnect and route restoration without manually refreshing OBS.

## 13. Testing Strategy

### 13.1 Unit tests

- decimeter-to-mile and decimeter-to-kilometer conversion;
- altitude/ascent conversion;
- elapsed-time formatting;
- rolling pace window, fallback, clamping, pause, and reset behavior;
- average pace;
- state labels;
- query-parameter validation and defaults;
- nullable metric preservation;
- activity-change reset;
- envelope deduplication;
- route-point deduplication and ordering;
- SSE parsing across split chunks and multiple events per chunk;
- reconnect backoff and token-expiry scheduling.

### 13.2 Component tests

- waiting, running, paused, stopped, ended, reconnecting, and stale states;
- missing heart rate, pace, elevation, and location;
- metric/imperial output;
- rolling/average pace selection;
- combined panel and each individual metric route;
- route reset when activity changes;
- final values retained after ended;
- no Mapbox import on metric-only routes.

### 13.3 Contract tests

Share JSON fixtures derived from the Go API for:

- viewer-token response;
- snapshot with and without location;
- full-route response;
- sample and activity SSE events;
- reset and token-expiration reconnect paths.

Fail tests when server response field names or nullable behavior drift from the frontend decoder.

### 13.4 Browser and visual tests

Use Playwright to verify:

- preview at desktop and mobile widths;
- map at representative OBS dimensions;
- combined metric panel at 1920x1080 composition scale;
- individual counters at narrow and wide source dimensions;
- transparent page backgrounds;
- no horizontal overflow;
- Mapbox fallback when WebGL fails;
- token refresh and SSE reconnect using a controlled test server;
- screenshot baselines for waiting, live, paused, ended, and stale states.

Perform a manual OBS test because Playwright Chromium is not identical to OBS CEF:

1. add map and metrics as separate browser sources;
2. set explicit source dimensions;
3. confirm transparency and font rendering;
4. run for at least two hours;
5. disconnect and restore the network;
6. restart the source and verify complete route recovery;
7. end a run and verify the final result remains;
8. monitor OBS and web-container memory.

## 14. Implementation Milestones

### Milestone 1: API route prerequisite

- Add authenticated `GET /v1/channels/{slug}/route`.
- Apply location policy and deterministic bounded downsampling.
- Separate latest-sample lookup from the snapshot's recent-route time window so ended metrics remain recoverable.
- Add PostgreSQL and HTTP tests for precise, rounded, hidden, long, empty, and cross-user routes.
- Update the server contract documentation.

### Milestone 2: TanStack Start foundation

- Add `web/` with TanStack Start, strict TypeScript, exact dependency pins, and a pnpm lockfile managed through Vite+.
- Add Node.js 24 and pnpm 11 to the Nix shell, use Vite+ system-first mode, and omit a Nix frontend check until it can be genuinely reproducible.
- Add configuration validation and health endpoint.
- Add the Docker production build.
- Create route skeletons and shared broadcast-dark styles.

### Milestone 3: server-side session broker

- Validate the public overlay UUID.
- Exchange the server-only read credential for viewer tokens.
- Fetch snapshot and full route.
- Return sanitized, no-store bootstrap data.
- Add rate limiting and tests proving the permanent credential never reaches client output.

### Milestone 4: live-data client

- Implement streaming-fetch SSE parsing.
- Implement deduplication, replay, token refresh, reset recovery, and backoff.
- Implement the canonical activity store and selectors.
- Add contract and state-transition tests.

### Milestone 5: metric overlays

- Implement pace, heart rate, distance, elapsed time, altitude/ascent, and state formatting.
- Implement combined and individual routes.
- Implement query configuration and transparent responsive layouts.
- Add component and screenshot tests.

### Milestone 6: map overlay

- Integrate Mapbox GL JS client-side.
- Load full route, append SSE points, follow the runner, and retain final state.
- Add start/current markers, route styling, attribution, and WebGL fallback.
- Verify Mapbox token restrictions and usage controls.

### Milestone 7: preview and OBS setup

- Build the preview/status page.
- Generate explicit OBS URLs and recommended dimensions.
- Add copy controls and connection diagnostics.
- Complete manual OBS rendering and endurance tests.

### Milestone 8: homelab deployment

- Add the web service and secret to Compose.
- Add host-based Caddy routing for API and frontend.
- Add the frontend hostname to Cloudflare Tunnel.
- Update API CORS and security headers.
- Verify session bootstrap, Mapbox assets, snapshot, full route, SSE, token refresh, and reconnect through public hostnames.

## 15. Acceptance Criteria

The frontend MVP is complete when:

- an OBS map source and metric source can be positioned independently;
- combined and individual metric routes render pace, heart rate, and distance correctly;
- the combined panel also shows elapsed time, elevation/ascent, and activity state;
- imperial/metric and rolling/average pace are selectable through validated URLs;
- the map follows the current position and renders the complete current route;
- refreshing OBS during a run longer than 30 minutes restores the full bounded route;
- nullable metrics never render misleading zeros;
- pause, stop, end, stale, reconnect, and new-activity transitions are visually correct;
- the final result remains visible after activity end;
- refreshing an ended overlay restores final metrics even when the last sample is older than 30 minutes;
- the permanent API read credential is absent from browser HTML, JavaScript, network responses, URLs, and logs;
- browser tokens are short-lived, channel-scoped, refreshed automatically, and sent only in authorization headers;
- location policy is enforced by the Go API for bootstrap, route, replay, and live events;
- SSE reconnect uses exact envelope IDs and does not duplicate route points;
- metric-only routes do not load Mapbox;
- Mapbox attribution remains visible and the public token is hostname-restricted;
- the frontend and API work through Cloudflare Tunnel with no inbound router port forwarding;
- unknown overlay UUIDs return 404;
- a two-hour OBS test shows no uncontrolled memory growth;
- a source restart restores current values and route without operator intervention.

## 16. Deferred Work

- historical activity browsing and analytics;
- user accounts and interactive login;
- overlay editor or drag-and-drop scene builder;
- multiple public overlay IDs or channels per user;
- heart-rate zones and user physiology settings;
- cadence-specific overlay;
- theme customization;
- public share-link management UI;
- self-hosted MapLibre/PMTiles migration;
- terrain, 3D buildings, camera bearing, and route replay animation;
- service worker/offline asset caching;
- frontend analytics or third-party error reporting;
- multi-replica frontend fan-out.

The MVP should establish reusable live-data, formatting, and map boundaries so these additions do not change the Go ingestion or exact acknowledgement contracts.

## 17. Manual Inputs Required

Implementation and deployment will require the user to provide or create:

- a Mapbox account and public browser token;
- the final live frontend hostname;
- a random public overlay UUID;
- a `channels:read` RunSync credential stored as a Docker secret;
- the additional Cloudflare Tunnel public-hostname mapping;
- OBS source dimensions and final scene placement for manual visual validation.

Do not request permanent credentials in chat or commit them to the repository.
