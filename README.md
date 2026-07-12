# RunSync

RunSync streams live telemetry from a Garmin Forerunner 965 native Run activity to an iOS companion over Connect IQ app messaging.

- `watch/`: Connect IQ Data Field written in Monkey C
- `ios/`: iOS 17 SwiftUI companion using Garmin Connect IQ Companion SDK 1.8.0
- `docs/plans/runsync.md`: implementation and acceptance specification
- `docs/setup.md`: physical-device setup and testing

The current MVP archives protected NDJSON on the phone and exercises delivery through an in-app mock sink. A production server is intentionally deferred.
