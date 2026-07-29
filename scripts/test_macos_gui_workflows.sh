#!/usr/bin/env bash
set -euo pipefail

# GUI-login acceptance for the three primary macOS workspace destinations.
# This intentionally exercises the public AppKit controls instead of calling
# Nim callbacks directly: Files, Git, and Terminal must stay discoverable and
# dispatchable as a user sees them. It is opt-in from the consolidated E2E
# because GitHub-hosted runners may not grant Accessibility automation.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="${TMPDIR:-/tmp}/nimculus-gui-workflows-$$"
APP_PID=""

cleanup() {
  if [[ -n "$APP_PID" ]]; then
    kill -TERM "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "macOS GUI workflows require Darwin" >&2
  exit 2
fi

mkdir -p "$TMP_ROOT/project"
printf 'echo "Nimculus GUI E2E"\n' > "$TMP_ROOT/project/main.nim"
git -C "$TMP_ROOT/project" init -q
git -C "$TMP_ROOT/project" config user.name "Nimculus GUI E2E"
git -C "$TMP_ROOT/project" config user.email "gui-e2e@nimculus.invalid"
git -C "$TMP_ROOT/project" add main.nim
git -C "$TMP_ROOT/project" commit -qm "initial"

cd "$ROOT_DIR"
nimble build
"$ROOT_DIR/nimculus/main" "$TMP_ROOT/project/main.nim" >"$TMP_ROOT/app.log" 2>&1 &
APP_PID=$!

for _ in $(seq 1 40); do
  if osascript -e 'tell application "System Events" to tell process "Nimculus" to get name of every button of window 1' 2>/dev/null | grep -q 'Files'; then
    break
  fi
  sleep 0.25
done

osascript <<'APPLESCRIPT'
tell application "Nimculus" to activate
tell application "System Events"
  tell process "Nimculus"
    if not (exists window 1) then error "Nimculus window did not open"
    repeat with title in {"Files", "Git", "Terminal"}
      if not (exists button (contents of title) of window 1) then
        error "Missing workspace action: " & (contents of title)
      end if
      click button (contents of title) of window 1
      delay 0.5
    end repeat
  end tell
end tell
APPLESCRIPT

echo "macos_gui_workflows_complete"
