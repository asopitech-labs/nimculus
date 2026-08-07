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

# A freshly launched window is not addressable for a second or two. Retry
# rather than reporting the first failure as a permission problem.
sized=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  sleep 2
  if err=$(osascript -e 'tell application "System Events" to tell process "Nimculus" to set size of window 1 to {1389, 791}' 2>&1); then
    sized=yes
    break
  fi
done
if [ -z "$sized" ]; then
  echo "cannot drive Nimculus through Apple Events: $err" >&2
  echo "If that is a -1743 permission error, grant Automation to the app that" >&2
  echo "runs this script and start it again: the grant is read at process" >&2
  echo "start, so a running process stays denied." >&2
  exit 2
fi
sleep 1

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
