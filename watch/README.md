# RunSync Connect IQ Data Field

The field targets the Forerunner 965 and Connect IQ API 5.0+.

## Build

Install Garmin Connect IQ SDK Manager and an SDK, then create a developer key. With the SDK `bin` directory on `PATH`:

```sh
./build.sh physical
```

Run in the simulator as a running activity:

```sh
connectiq
./build.sh simulator
monkeydo bin/RunSync-simulator.prg fr965
```

`simulator.jungle` replaces BLE transmission with a deterministic local sender because Garmin's desktop simulator can connect to companion apps only through Android ADB. It completes attempts immediately by default and supports injected error, exception, missing-callback, and delayed-callback outcomes. Use the physical `RunSync.prg` build for watch-to-iPhone messaging.

Compile the deterministic sender tests with:

```sh
./build.sh test
monkeydo bin/RunSync-tests.prg fr965 -t
```

The manifest application UUID is `C2ABF013-EA3B-49DD-82E6-FC0B87C27474`. The iOS app must use the same UUID.
