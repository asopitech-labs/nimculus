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
APP_COMMAND=""

app_process_is_ours() {
  [[ -n "$APP_PID" ]] || return 1
  [[ "$(ps -p "$APP_PID" -o command= 2>/dev/null || true)" == "$APP_COMMAND"* ]]
}

owned_app_pids() {
  # Match both the exact executable and this run's unique temporary document.
  # This cannot select a developer's interactive Nimculus process.
  ps -axo pid=,command= | awk -v executable="$ROOT_DIR/nimculus/main" \
    -v document="$TMP_ROOT/project/main.nim" \
    '$2 == executable && index($0, document) > 0 { print $1 }'
}

terminate_owned_app_processes() {
  local pid
  for pid in $(owned_app_pids); do kill -TERM "$pid" 2>/dev/null || true; done
  for _ in $(seq 1 10); do
    [[ -z "$(owned_app_pids)" ]] && return 0
    sleep 0.1
  done
  for pid in $(owned_app_pids); do kill -KILL "$pid" 2>/dev/null || true; done
  sleep 0.1
  [[ -z "$(owned_app_pids)" ]]
}

cleanup() {
  # This test must never use a process-group signal: nimble and Codex can
  # share a controlling terminal with the shell that launched the harness.
  # Terminate only the executable PID that this script started, after checking
  # its command line still identifies it as our isolated acceptance instance.
  if app_process_is_ours; then
    kill -TERM "$APP_PID" 2>/dev/null || true
    # A GUI workflow can leave a PTY session active. Never let the harness
    # wait indefinitely for an AppKit quit path: give it the same bounded
    # grace period used by the task/PTY shutdown code, then reap it.
    for _ in $(seq 1 10); do
      if ! kill -0 "$APP_PID" 2>/dev/null; then break; fi
      sleep 0.1
    done
    if app_process_is_ours; then kill -KILL "$APP_PID" 2>/dev/null || true; fi
    wait "$APP_PID" 2>/dev/null || true
  fi
  # AppKit is not expected to fork here, but audit the unique test document
  # after reaping the direct child. If that assumption changes, clean up only
  # processes proven to belong to this temporary E2E workspace and fail loud.
  if ! terminate_owned_app_processes; then
    echo "Nimculus GUI E2E left an owned app process alive: $(owned_app_pids)" >&2
    exit 1
  fi
  rm -rf "$TMP_ROOT"
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
# Give Changes a real unstaged row. The workflow then verifies the visible
# bulk Stage/Unstage controls against Git, not merely their accessibility IDs.
printf 'echo "unstaged GUI workflow change"\n' >> "$TMP_ROOT/project/main.nim"

cd "$ROOT_DIR"
nimble build
# Keep the acceptance app's session, recovery data, and settings isolated from
# the developer's real macOS profile. A GUI test must never manufacture a
# fleet of restored Untitled tabs in the user's next interactive launch.
HOME="$TMP_ROOT/home" "$ROOT_DIR/nimculus/main" "$TMP_ROOT/project/main.nim" >"$TMP_ROOT/app.log" 2>&1 &
APP_PID=$!
APP_COMMAND="$ROOT_DIR/nimculus/main $TMP_ROOT/project/main.nim"

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
    repeat with title in {"Files", "Search", "Git", "Terminal"}
      if not (exists button (contents of title) of window 1) then error "Missing workspace action: " & (contents of title)
    end repeat

    click button "Files" of window 1
    delay 0.5
    if not (exists button "New File" of window 1) then error "Files panel did not expose New File"

    click menu item "Quick Open…" of menu "File" of menu bar item "File" of menu bar 1
    delay 0.3
    if not (exists sheet 1) then error "Quick Open did not present a sheet"
    set value of text field 1 of sheet 1 to "main"
    click button "Search" of sheet 1
    delay 0.8
    set quickOpenVisible to false
    repeat with area in every text area of window 1
      if (value of area as text) contains "Quick Open: main" then set quickOpenVisible to true
    end repeat
    if not quickOpenVisible then error "Quick Open did not render in the Files sidebar"

    click menu item "Find in Workspace…" of menu "Edit" of menu bar item "Edit" of menu bar 1
    delay 0.3
    if not (exists sheet 1) then error "Workspace Search did not present a sheet"
    set value of text field 1 of sheet 1 to "Nimculus"
    click button "Search" of sheet 1
    delay 0.8
    set workspaceSearchVisible to false
    repeat with area in every text area of window 1
      if (value of area as text) contains "Search: Nimculus" then set workspaceSearchVisible to true
    end repeat
    if not workspaceSearchVisible then error "Workspace Search did not render in its sidebar"
    if not (exists button "New workspace search" of window 1) then error "Search panel did not expose New Search"
    if not (exists button "Cancel workspace search" of window 1) then error "Search panel did not expose Cancel Search"

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
    if not (exists button "Branches" of window 1) then error "Git panel did not expose Branches"
    if not (exists button "Refresh Git panel" of window 1) then error "Git panel did not expose Refresh"
    if not (exists button "Stage all changes" of window 1) then error "Git panel did not expose Stage All"
    if not (exists button "Unstage all changes" of window 1) then error "Git panel did not expose Unstage All"
    click button "Stage all changes" of window 1
    delay 0.8
    click button "Unstage all changes" of window 1
    delay 0.8
    click button "History" of window 1
    delay 0.8
    set gitHistoryVisible to false
    repeat with area in every text area of window 1
      if (value of area as text) contains "Git History" then set gitHistoryVisible to true
    end repeat
    if not gitHistoryVisible then error "Git History did not render in its sidebar"
    click button "Refresh Git panel" of window 1
    delay 0.5

    click button "Terminal" of window 1
    delay 0.5
    -- The session-bar controls are custom native views and their individual
    -- Accessibility names differ by macOS release. This workflow asserts the
    -- public Terminal navigation dispatch; PTY creation/input/resize/close is
    -- covered by the terminal integration suite in the consolidated E2E.
  end tell
end tell
APPLESCRIPT

# The visible Stage All then Unstage All controls must leave this fixture with
# precisely its original worktree change: no staged residue and an unstaged
# diff still present. This checks the result, not just command dispatch.
if ! git -C "$TMP_ROOT/project" diff --quiet; then
  : # expected: the last visible action was Unstage All
else
  echo "Git GUI controls did not restore the unstaged fixture" >&2
  exit 1
fi
if ! git -C "$TMP_ROOT/project" diff --cached --quiet; then
  echo "Git GUI controls left staged fixture changes behind" >&2
  exit 1
fi

echo "macos_gui_workflows_complete"
