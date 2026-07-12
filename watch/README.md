# RunSync Connect IQ Data Field

The field targets the Forerunner 965 and Connect IQ API 5.0+.

## Build

Install Garmin Connect IQ SDK Manager and an SDK, then create a developer key. With the SDK `bin` directory on `PATH`:

```sh
monkeyc -d fr965 -f monkey.jungle -o bin/RunSync.prg -y "$HOME/.garmin/developer_key.der"
```

Run in the simulator as a running activity:

```sh
connectiq
monkeyc -d fr965 -f simulator.jungle -o bin/RunSync-simulator.prg -y "$HOME/.garmin/developer_key.der"
monkeydo bin/RunSync-simulator.prg fr965
```

`simulator.jungle` replaces BLE transmission with a no-op sender because Garmin's desktop simulator can connect to companion apps only through Android ADB. Use the physical `RunSync.prg` build for watch-to-iPhone messaging.

The manifest application UUID is `C2ABF013-EA3B-49DD-82E6-FC0B87C27474`. The iOS app must use the same UUID.
