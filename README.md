# RunSync

RunSync streams live telemetry from a Garmin Forerunner 965 native Run activity to an iOS companion over Connect IQ app messaging.

- `watch/`: Connect IQ Data Field written in Monkey C
- `ios/`: iOS 17 SwiftUI companion using Garmin Connect IQ Companion SDK 1.8.0
- `server/`: Go 1.26 API, embedded PostgreSQL migrations, and deployment configuration
- `web/`: TanStack Start live preview and OBS map/metric browser sources
- `docs/plans/runsync.md`: implementation and acceptance specification
- `docs/setup.md`: physical-device setup and testing

The iOS app archives protected NDJSON before uploading exact-ID batches to the Go service. The server persists telemetry in PostgreSQL 18 and exposes policy-filtered snapshots and Server-Sent Events to the web overlays.

Copy `.env.example` to an untracked `.env`, create the secret files under `secrets/`, and follow `server/README.md` and `docs/server-operations.md` to bootstrap credentials and deploy the stack. The API and web public hostnames both enter the same named Cloudflare Tunnel at `http://caddy:8080`; Caddy routes them by hostname while API, web, and PostgreSQL remain unpublished.

For local end-to-end development, copy `.env.local.example` to `.env.local` and use `compose.dev.yaml`. It supports either the full container stack at `http://live.runsync.localhost:8080` or `vp dev` with HMR at `http://localhost:3000` against the real Go API on loopback port `8081`. See `web/README.md` for commands.

Use `nix develop` for the repository's canonical optional system tool environment. It supplies Go 1.26, PostgreSQL 18, Node.js 24, and pnpm 11. Vite+ `0.2.4` is not in the pinned nixpkgs and its upstream Nix support is incomplete, so the flake deliberately does not claim a reproducible web build or check. After entering the shell, install that exact release and explicitly select the shell's Node.js and pnpm with `curl -fsSL https://vite.plus | env VP_VERSION=0.2.4 bash` followed by `vp env off`; then run `vp install` from `web/`. Alternatively, use the exact `ghcr.io/voidzero-dev/vite-plus:0.2.4` image. The shell does not run `vp env off` automatically.
