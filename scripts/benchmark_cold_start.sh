#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNS="${NIMCULUS_COLD_START_RUNS:-5}"
TMP_ROOT="${TMPDIR:-/tmp}/nimculus-cold-start-$$"
CACHE_DIR="$TMP_ROOT/nimcache"
HOME_DIR="${NIMCULUS_BENCH_HOME:-$TMP_ROOT/home}"
BINARY="${NIMCULUS_BINARY:-$TMP_ROOT/Nimculus}"

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

mkdir -p "$HOME_DIR/Library/Application Support"
if [[ -z "${NIMCULUS_BINARY:-}" ]]; then
  mkdir -p "$TMP_ROOT"
  nim c --mm:arc -d:release --nimcache:"$CACHE_DIR" \
    --path:"$ROOT_DIR/src" -o:"$BINARY" "$ROOT_DIR/src/nimculus/main.nim"
elif [[ ! -x "$BINARY" ]]; then
  echo "NIMCULUS_BINARY is not executable: $BINARY" >&2
  exit 2
fi

for run in $(seq 1 "$RUNS"); do
  set +e
  output="$(HOME="$HOME_DIR" NIMCULUS_BENCH_COLD_START=1 "$BINARY" 2>&1)"
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
