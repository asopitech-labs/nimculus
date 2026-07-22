#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNS="${NIMCULUS_COLD_START_RUNS:-5}"
TIMEOUT_SECONDS="${NIMCULUS_COLD_START_TIMEOUT_SECONDS:-15}"
TMP_ROOT="${TMPDIR:-/tmp}/nimculus-cold-start-$$"
CACHE_DIR="$TMP_ROOT/nimcache"
HOME_DIR="${NIMCULUS_BENCH_HOME:-$TMP_ROOT/home}"
APP_DIR="$TMP_ROOT/Nimculus.app"
APP_BINARY="$APP_DIR/Contents/MacOS/Nimculus"
RUN_BINARY="$APP_BINARY"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

case "$RUNS" in
  ''|*[!0-9]*) echo "NIMCULUS_COLD_START_RUNS must be a positive integer" >&2; exit 2 ;;
esac
if [[ "$RUNS" -lt 1 ]]; then
  echo "NIMCULUS_COLD_START_RUNS must be a positive integer" >&2
  exit 2
fi
case "$TIMEOUT_SECONDS" in
  ''|*[!0-9]*) echo "NIMCULUS_COLD_START_TIMEOUT_SECONDS must be a positive integer" >&2; exit 2 ;;
esac
if [[ "$TIMEOUT_SECONDS" -lt 1 ]]; then
  echo "NIMCULUS_COLD_START_TIMEOUT_SECONDS must be a positive integer" >&2
  exit 2
fi

mkdir -p "$HOME_DIR/Library/Application Support"
if [[ -z "${NIMCULUS_BINARY:-}" ]]; then
  mkdir -p "$(dirname "$APP_BINARY")"
  nim c --mm:arc -d:release --nimcache:"$CACHE_DIR" \
    --path:"$ROOT_DIR/src" -o:"$APP_BINARY" "$ROOT_DIR/src/nimculus/main.nim"
  cp "$ROOT_DIR/packaging/macos/Info.plist" "$APP_DIR/Contents/Info.plist"
else
  BINARY="$NIMCULUS_BINARY"
  if [[ ! -x "$BINARY" ]]; then
    echo "NIMCULUS_BINARY is not executable: $BINARY" >&2
    exit 2
  fi
  # AppKit's LaunchServices lifecycle requires a bundle identifier. Accept a
  # ready-made app executable, or wrap a raw developer binary in the same
  # minimal bundle used by the default build path.
  if [[ "$BINARY" == *.app/Contents/MacOS/* ]]; then
    RUN_BINARY="$BINARY"
  else
    mkdir -p "$(dirname "$APP_BINARY")"
    cp "$BINARY" "$APP_BINARY"
    cp "$ROOT_DIR/packaging/macos/Info.plist" "$APP_DIR/Contents/Info.plist"
  fi
fi

if [[ ! -x "$RUN_BINARY" ]]; then
  echo "cold-start bundle executable is not executable: $RUN_BINARY" >&2
  exit 2
fi

for run in $(seq 1 "$RUNS"); do
  set +e
  output="$(HOME="$HOME_DIR" NIMCULUS_BENCH_COLD_START=1 \
    /usr/bin/perl -e 'alarm shift; exec @ARGV' "$TIMEOUT_SECONDS" "$RUN_BINARY" 2>&1)"
  status=$?
  set -e
  if [[ "$status" -ne 0 ]]; then
    echo "$output" >&2
    echo "cold-start run $run failed with exit code $status" >&2
    exit "$status"
  fi
  if ! printf '%s\n' "$output" | awk -F '\t' -v run="$run" \
      '$1 == "cold_start" { print "cold_start\t" run "\t" $2 "\t" $3 "\t" $4; found = 1 }
       END { exit(found ? 0 : 1) }'; then
    echo "$output" >&2
    echo "cold-start run $run produced no ready metric" >&2
    exit 1
  fi
done
