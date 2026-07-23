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
MAX_RESIDENT_GROWTH_BYTES="${NIMCULUS_SOAK_MAX_RESIDENT_GROWTH_BYTES:-134217728}"
MAX_LIVE_BLOCK_GROWTH="${NIMCULUS_SOAK_MAX_LIVE_BLOCK_GROWTH:-50000}"
if ! is_positive_integer "$TIMEOUT_SECONDS"; then
  echo "soak timeout must be a positive integer" >&2
  exit 2
fi
if (( TIMEOUT_SECONDS <= DURATION_SECONDS )); then
  echo "NIMCULUS_SOAK_TIMEOUT_SECONDS must exceed NIMCULUS_SOAK_SECONDS" >&2
  exit 2
fi
if ! [[ "$MAX_RESIDENT_GROWTH_BYTES" =~ ^[0-9]+$ ]] ||
   ! [[ "$MAX_LIVE_BLOCK_GROWTH" =~ ^[0-9]+$ ]]; then
  echo "soak growth limits must be non-negative integers" >&2
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
  -v max_resident_growth="$MAX_RESIDENT_GROWTH_BYTES" \
  -v max_live_block_growth="$MAX_LIVE_BLOCK_GROWTH" \
  '$1 == "soak_sample" {
     samples++
     for (i = 1; i <= NF; i++) {
       split($i, value, "=")
       if (value[1] == "frames" && value[2] > max_frames) max_frames = value[2]
       if (value[1] == "resident") {
         if (!have_resident) { first_resident = value[2]; have_resident = 1 }
         last_resident = value[2]
       }
       if (value[1] == "live_blocks") {
         if (!have_blocks) { first_blocks = value[2]; have_blocks = 1 }
         last_blocks = value[2]
       }
     }
   }
   $1 == "soak_complete" { complete = 1 }
   END {
     resident_growth = last_resident - first_resident
     block_growth = last_blocks - first_blocks
     valid = complete && samples > 0 && max_frames > 0 && have_resident && have_blocks
     valid = valid && resident_growth <= max_resident_growth && block_growth <= max_live_block_growth
     if (!valid) printf "soak summary: samples=%d frames=%d resident_growth=%d live_block_growth=%d\\n", samples, max_frames, resident_growth, block_growth > "/dev/stderr"
     exit(valid ? 0 : 1)
   }'; then
  echo "soak run violated frame/completion or memory-growth contract" >&2
  exit 1
fi
