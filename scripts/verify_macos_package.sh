#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${NIMCULUS_OUT_DIR:-$ROOT_DIR/build/macos}"
DMG="${NIMCULUS_DMG:-}"
REQUIRE_NOTARIZATION="${NIMCULUS_REQUIRE_NOTARIZATION:-0}"
MOUNT_DIR="${TMPDIR:-/tmp}/nimculus-package-mount-$$"
MOUNTED=0

cleanup() {
  if [[ "$MOUNTED" == "1" ]]; then
    hdiutil detach "$MOUNT_DIR" -quiet || hdiutil detach "$MOUNT_DIR" -force -quiet || true
  fi
  rm -rf "$MOUNT_DIR"
}
trap cleanup EXIT

if [[ -z "$DMG" ]]; then
  shopt -s nullglob
  candidates=("$OUT_DIR"/Nimculus-*.dmg)
  shopt -u nullglob
  if [[ "${#candidates[@]}" -ne 1 ]]; then
    echo "expected exactly one Nimculus DMG in $OUT_DIR" >&2
    exit 2
  fi
  DMG="${candidates[0]}"
fi

if [[ ! -s "$DMG" ]]; then
  echo "macOS package DMG is missing or empty: $DMG" >&2
  exit 2
fi

hdiutil verify "$DMG" >/dev/null
mkdir -p "$MOUNT_DIR"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MOUNT_DIR" "$DMG"
MOUNTED=1

APP="$MOUNT_DIR/Nimculus.app"
if [[ ! -x "$APP/Contents/MacOS/Nimculus" ]]; then
  echo "DMG does not contain an executable Nimculus.app" >&2
  exit 3
fi

codesign --verify --deep --strict --verbose=2 "$APP"

if [[ "$REQUIRE_NOTARIZATION" == "1" ]]; then
  # A valid Developer ID signature is not enough for the distribution gate:
  # require the ticket to be stapled and require Gatekeeper to accept both
  # the mounted application and the disk image that contains it.
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose "$APP"
  xcrun stapler validate "$DMG"
  spctl --assess --type open --context context:primary-signature "$DMG"
fi

# Run the exact app executable from the mounted distribution. The benchmark
# supplies a temporary HOME, so the read-only DMG is never used for writable
# application state.
NIMCULUS_BINARY="$APP/Contents/MacOS/Nimculus" \
NIMCULUS_COLD_START_RUNS="${NIMCULUS_COLD_START_RUNS:-1}" \
NIMCULUS_COLD_START_TIMEOUT_SECONDS="${NIMCULUS_COLD_START_TIMEOUT_SECONDS:-30}" \
bash "$ROOT_DIR/scripts/benchmark_cold_start.sh"

echo "Verified mounted macOS package: $DMG"
