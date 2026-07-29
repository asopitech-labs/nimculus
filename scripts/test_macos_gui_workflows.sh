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
    # A GUI workflow can leave a PTY session active. Never let the harness
    # wait indefinitely for an AppKit quit path: give it the same bounded
    # grace period used by the task/PTY shutdown code, then reap it.
    for _ in $(seq 1 10); do
      if ! kill -0 "$APP_PID" 2>/dev/null; then break; fi
      sleep 0.1
    done
    if kill -0 "$APP_PID" 2>/dev/null; then kill -KILL "$APP_PID" 2>/dev/null || true; fi
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
  # Do not select an arbitrary already-running Nimculus instance by name.
  # A developer can keep the packaged app open while this test runs; the
  # workflow must inspect the executable it launched.
  if osascript -e "tell application \"System Events\" to tell (first process whose unix id is $APP_PID) to get name of every button of window 1" 2>/dev/null | grep -q 'Files'; then
    break
  fi
  sleep 0.25
done

osascript -e "set targetPid to $APP_PID" <<'APPLESCRIPT'
tell application "System Events"
  tell (first process whose unix id is targetPid)
    set frontmost to true
    if not (exists window 1) then error "Nimculus window did not open"
    repeat with title in {"Files", "Git", "Terminal"}
      if not (exists button (contents of title) of window 1) then error "Missing workspace action: " & (contents of title)
    end repeat

    click button "Files" of window 1
    delay 0.5
    if not (exists button "New File" of window 1) then error "Files panel did not expose New File"

    click button "Split" of window 1
    delay 0.5
    if not (exists button "Close Split" of window 1) then error "Split did not expose Close Split"
    click button "Close Split" of window 1
    delay 0.5
    if not (exists button "Split" of window 1) then error "Close Split did not restore Split"

    click menu item "Split Editor Horizontally" of menu "Window" of menu bar item "Window" of menu bar 1
    delay 0.5
    if not (exists button "Close Split" of window 1) then error "Horizontal split did not expose Close Split"
    click button "Close Split" of window 1
    delay 0.5
    if not (exists button "Split" of window 1) then error "Close Split did not restore Split after horizontal split"

    click button "Git" of window 1
    delay 0.5
    if not (exists button "Changes" of window 1) then error "Git panel did not expose Changes"
    if not (exists button "History" of window 1) then error "Git panel did not expose History"

    click button "Terminal" of window 1
    delay 0.5
    -- The session-bar controls are custom native views and their individual
    -- Accessibility names differ by macOS release. This workflow asserts the
    -- public Terminal navigation dispatch; PTY creation/input/resize/close is
    -- covered by the terminal integration suite in the consolidated E2E.
  end tell
end tell
APPLESCRIPT

echo "macos_gui_workflows_complete"
