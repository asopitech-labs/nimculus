#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DURATION_SECONDS="${NIMCULUS_SOAK_SECONDS:-28800}"
INTERVAL_SECONDS="${NIMCULUS_SOAK_INTERVAL_SECONDS:-30}"
TMP_ROOT="${TMPDIR:-/tmp}/nimculus-soak-$$"
CACHE_DIR="$TMP_ROOT/nimcache"
HOME_DIR="${NIMCULUS_BENCH_HOME:-$TMP_ROOT/home}"
APP_DIR="$TMP_ROOT/Nimculus.app"
APP_BINARY="$APP_DIR/Contents/MacOS/Nimculus"
RUN_BINARY="$APP_BINARY"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

is_positive_integer() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

if ! is_positive_integer "$DURATION_SECONDS" ||
   ! is_positive_integer "$INTERVAL_SECONDS"; then
  echo "soak duration and interval must be positive integers" >&2
  exit 2
fi
TIMEOUT_SECONDS="${NIMCULUS_SOAK_TIMEOUT_SECONDS:-$((DURATION_SECONDS + 60))}"
if ! is_positive_integer "$TIMEOUT_SECONDS"; then
  echo "soak timeout must be a positive integer" >&2
  exit 2
fi
if (( TIMEOUT_SECONDS <= DURATION_SECONDS )); then
  echo "NIMCULUS_SOAK_TIMEOUT_SECONDS must exceed NIMCULUS_SOAK_SECONDS" >&2
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
  if [[ "$BINARY" == *.app/Contents/MacOS/* ]]; then
    RUN_BINARY="$BINARY"
  else
    mkdir -p "$(dirname "$APP_BINARY")"
    cp "$BINARY" "$APP_BINARY"
    cp "$ROOT_DIR/packaging/macos/Info.plist" "$APP_DIR/Contents/Info.plist"
  fi
fi

if [[ ! -x "$RUN_BINARY" ]]; then
  echo "soak bundle executable is not executable: $RUN_BINARY" >&2
  exit 2
fi

set +e
output="$(HOME="$HOME_DIR" NIMCULUS_BENCH_SOAK=1 \
  NIMCULUS_SOAK_SECONDS="$DURATION_SECONDS" \
  NIMCULUS_SOAK_INTERVAL_SECONDS="$INTERVAL_SECONDS" \
  /usr/bin/perl -e 'alarm shift; exec @ARGV' "$TIMEOUT_SECONDS" "$RUN_BINARY" 2>&1)"
status=$?
set -e
printf '%s\n' "$output"
if [[ "$status" -ne 0 ]]; then
  echo "soak run failed with exit code $status" >&2
  exit "$status"
fi
if ! printf '%s\n' "$output" | awk -F '\t' \
  '$1 == "soak_complete" { found = 1 } END { exit(found ? 0 : 1) }'; then
  echo "soak run produced no completion metric" >&2
  exit 1
fi
