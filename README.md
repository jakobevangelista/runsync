# RunSync

RunSync streams live telemetry from a Garmin Forerunner 965 native Run activity to an iOS companion over Connect IQ app messaging.

- `watch/`: Connect IQ Data Field written in Monkey C
- `ios/`: iOS 17 SwiftUI companion using Garmin Connect IQ Companion SDK 1.8.0
- `server/`: Go 1.26 API, embedded PostgreSQL migrations, and deployment configuration
- `docs/plans/runsync.md`: implementation and acceptance specification
- `docs/setup.md`: physical-device setup and testing

The iOS app archives protected NDJSON before uploading exact-ID batches to the Go service. The server persists telemetry in PostgreSQL 18 and exposes policy-filtered snapshots and Server-Sent Events for a future web dashboard.

Use `nix develop` for the repository's canonical optional tool environment. See `server/README.md` and `docs/server-operations.md` for server setup and operation.
