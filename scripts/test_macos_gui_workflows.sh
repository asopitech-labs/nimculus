#!/usr/bin/env bash
set -euo pipefail

# LaunchServices/AppKit boundary acceptance for macOS. Accessibility scripting
# is deliberately not used here: on some GUI-login images System Events
# reports zero windows even for Finder and Terminal. The native integration
# suite validates the NSButton/NSMenu contracts; this script validates the
# packaged application and the real WindowServer surface.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_BASE="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
TMP_ROOT="$TMP_BASE/nimculus-gui-workflows-$$"
APP_PID=""
APP_COMMAND=""

app_process_is_ours() {
  [[ -n "$APP_PID" ]] || return 1
  [[ "$(ps -p "$APP_PID" -o command= 2>/dev/null || true)" == "$APP_COMMAND"* ]]
}

cleanup() {
  if app_process_is_ours; then
    kill -TERM "$APP_PID" 2>/dev/null || true
    for _ in $(seq 1 10); do
      if ! kill -0 "$APP_PID" 2>/dev/null; then break; fi
      sleep 0.1
    done
    if app_process_is_ours; then kill -KILL "$APP_PID" 2>/dev/null || true; fi
    wait "$APP_PID" 2>/dev/null || true
  fi
  if app_process_is_ours; then
    echo "Nimculus GUI E2E child did not exit: $APP_PID" >&2
    exit 1
  fi
  if [[ "${NIMCULUS_GUI_KEEP_TMP:-0}" == "1" ]]; then
    echo "Nimculus GUI E2E retained artifacts: $TMP_ROOT" >&2
  else
    find "$TMP_ROOT" -depth -delete 2>/dev/null || true
  fi
}
trap cleanup EXIT

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "macOS GUI workflows require Darwin" >&2
  exit 2
fi

mkdir -p "$TMP_ROOT/project" "$TMP_ROOT/home"
printf 'echo "Nimculus GUI E2E"\n' > "$TMP_ROOT/project/main.nim"
git -C "$TMP_ROOT/project" init -q
git -C "$TMP_ROOT/project" config user.name "Nimculus GUI E2E"
git -C "$TMP_ROOT/project" config user.email "gui-e2e@nimculus.invalid"
git -C "$TMP_ROOT/project" add main.nim
git -C "$TMP_ROOT/project" commit -qm "initial"

cd "$ROOT_DIR"
NIMCULUS_ALLOW_ADHOC=1 NIMCULUS_OUT_DIR="$TMP_ROOT/package" \
  bash "$ROOT_DIR/scripts/package_macos.sh" >/dev/null
APP_EXEC="$TMP_ROOT/package/Nimculus.app/Contents/MacOS/Nimculus"
APP_COMMAND="$APP_EXEC $TMP_ROOT/project"
HOME="$TMP_ROOT/home" open -n "$TMP_ROOT/package/Nimculus.app" \
  --args "$TMP_ROOT/project" >"$TMP_ROOT/app.log" 2>&1 &

for _ in $(seq 1 40); do
  APP_PID="$(pgrep -f -- "$APP_COMMAND" | head -1 || true)"
  [[ -n "$APP_PID" ]] && break
  sleep 0.25
done
if [[ -z "$APP_PID" ]]; then
  echo "Nimculus LaunchServices process did not appear" >&2
  exit 1
fi

window_is_onscreen() {
  swift -e '
    import CoreGraphics
    import Foundation
    let pid = Int32(CommandLine.arguments[1])!
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
    let found = windows.contains { window in
      let ownerPid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? -1
      let onscreen = (window[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
      return ownerPid == pid && onscreen
    }
    print(found ? "1" : "0")
  ' "$APP_PID" 2>/dev/null | grep -q '^1$'
}

for _ in $(seq 1 20); do
  if window_is_onscreen; then break; fi
  sleep 0.25
done
if ! window_is_onscreen; then
  echo "Nimculus process exists but WindowServer has no onscreen window" >&2
  exit 1
fi

WINDOW_GEOMETRY="$(swift -e '
  import CoreGraphics
  import Foundation
  let pid = Int32(CommandLine.arguments[1])!
  let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
  for window in windows {
    let ownerPid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? -1
    guard ownerPid == pid, let bounds = window[kCGWindowBounds as String] as? [String: Any],
      let width = (bounds["Width"] as? NSNumber)?.doubleValue,
      let height = (bounds["Height"] as? NSNumber)?.doubleValue else { continue }
    print("\(Int(width))x\(Int(height))")
    break
  }
' "$APP_PID" 2>/dev/null)"
if [[ ! "$WINDOW_GEOMETRY" =~ ^([0-9]+)x([0-9]+)$ ]]; then
  echo "Invalid Nimculus window geometry: ${WINDOW_GEOMETRY:-missing}" >&2
  exit 1
fi
WINDOW_WIDTH="${BASH_REMATCH[1]}"
WINDOW_HEIGHT="${BASH_REMATCH[2]}"
if (( WINDOW_WIDTH < 360 || WINDOW_HEIGHT < 240 )); then
  echo "Nimculus window is below its AppKit minimum: ${WINDOW_GEOMETRY}" >&2
  exit 1
fi

# Button/menu discovery and dispatch are validated by the consolidated native
# integration suite against the same AppKit instances. Never call an AX query
# that can silently become a no-op on a runner and then report GUI success.
echo "macos_gui_workflows_complete window=${WINDOW_GEOMETRY} pid=${APP_PID}"
