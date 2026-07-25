#!/usr/bin/env bash
set -euo pipefail

target="${1:-physical}"
device="${RUNSYNC_WATCH_DEVICE:-fr965}"
key="${RUNSYNC_WATCH_DEVELOPER_KEY:-$HOME/.garmin/developer_key.der}"
monkeyc_bin="${MONKEYC:-monkeyc}"
release="${RUNSYNC_RELEASE_BUILD:-0}"

case "$target" in
  physical)
    jungle="monkey.jungle"
    output="bin/RunSync.prg"
    test_flag=()
    ;;
  simulator)
    jungle="simulator.jungle"
    output="bin/RunSync-simulator.prg"
    test_flag=()
    ;;
  test)
    jungle="test.jungle"
    output="bin/RunSync-tests.prg"
    test_flag=(-t)
    ;;
  *)
    echo "usage: $0 [physical|simulator|test]" >&2
    exit 2
    ;;
esac

if [[ -n "${RUNSYNC_WATCH_BUILD_ID:-}" ]]; then
  build_id="$RUNSYNC_WATCH_BUILD_ID"
elif git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  build_id="$(git rev-parse --short=12 HEAD)"
  if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
    if [[ "$release" == "1" ]]; then
      echo "release watch builds require a clean working tree" >&2
      exit 1
    fi
    build_id="${build_id}-dirty"
  fi
else
  echo "RUNSYNC_WATCH_BUILD_ID is required outside a Git checkout" >&2
  exit 1
fi

if [[ ! "$build_id" =~ ^[A-Za-z0-9._+-]{1,32}$ ]]; then
  echo "invalid watch build ID: $build_id" >&2
  exit 1
fi

mkdir -p generated bin
printf 'import Toybox.Lang;\n\nconst RUNSYNC_WATCH_BUILD_ID = "%s";\n' "$build_id" > generated/WatchBuild.mc

"$monkeyc_bin" "${test_flag[@]}" -d "$device" -f "$jungle" -o "$output" -y "$key"
echo "built $output with RUNSYNC_WATCH_BUILD_ID=$build_id"
