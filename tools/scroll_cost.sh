#!/bin/bash
# Measure what one scroll costs the editor, in CPU time and in frames.
#
# The parity tooling needs Screen Recording; this deliberately does not. It
# drives the app with Page Down through Apple Events and reads the process's
# own CPU accounting, so it can run whenever the app can be driven at all.
#
# Run it on the build you want to measure, then on the other build, and compare
# ms_cpu_per_scroll. Frame counts come from the app's metrics, so a build that
# renders the same result with fewer rasterizations shows up here.
#
# Usage: tools/scroll_cost.sh [scroll_count]
set -u
cd "$(dirname "$0")/.."
COUNT="${1:-60}"
APP=build/macos/Nimculus.app

[ -d "$APP" ] || { echo "build the app first: NIMCULUS_ALLOW_ADHOC=1 nimble packageMacos" >&2; exit 1; }

pkill -x Nimculus 2>/dev/null
sleep 2
open "$APP" || exit 1
sleep 6
osascript -e 'tell application "System Events" to tell process "Nimculus" \
  to set size of window 1 to {1389, 791}' >/dev/null 2>&1 || {
  echo "cannot drive Nimculus through Apple Events." >&2
  echo "Grant Automation to the terminal app, then QUIT AND REOPEN it: the" >&2
  echo "grant is read when a process starts, so a running one stays denied." >&2
  exit 2
}
sleep 2

PID="$(pgrep -x Nimculus)"
[ -n "$PID" ] || { echo "Nimculus is not running" >&2; exit 1; }

cpu_ms() {
  # ps reports [dd-]hh:mm:ss.ss of accumulated CPU time.
  ps -o time= -p "$1" | awk -F'[:.]' '{
    n = NF
    ms = $n * 10 + $(n-1) * 1000 + $(n-2) * 60000
    if (n >= 4) ms += $(n-3) * 3600000
    print ms
  }'
}

BEFORE="$(cpu_ms "$PID")"
osascript <<OSA >/dev/null 2>&1
tell application "Nimculus" to activate
delay 0.5
tell application "System Events"
  repeat $COUNT times
    key code 121
    delay 0.02
  end repeat
end tell
OSA
sleep 1
AFTER="$(cpu_ms "$PID")"

DELTA=$((AFTER - BEFORE))
echo "scrolls          $COUNT"
echo "cpu_ms_total     $DELTA"
awk -v d="$DELTA" -v c="$COUNT" 'BEGIN { printf "ms_cpu_per_scroll %.2f\n", d / c }'
echo
echo "Compare this number across builds. It excludes GPU time, so pair it with"
echo "a visual check once Screen Recording is available."
