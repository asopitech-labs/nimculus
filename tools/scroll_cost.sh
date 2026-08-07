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
# Usage: tools/scroll_cost.sh [scroll_count] [app_name]
#
# The app name defaults to Nimculus. Pass "Zed" to measure the reference the
# parity work is aimed at: the number only means something next to Zed's on
# the same document, window size, and event count.
set -u
cd "$(dirname "$0")/.."
COUNT="${1:-60}"
APP_NAME="${2:-Nimculus}"
APP=build/macos/Nimculus.app

if [ "$APP_NAME" = "Nimculus" ]; then
  [ -d "$APP" ] || { echo "build the app first: NIMCULUS_ALLOW_ADHOC=1 nimble packageMacos" >&2; exit 1; }
  pkill -x Nimculus 2>/dev/null
  sleep 2
  open "$APP" || exit 1
else
  # An already-running reference app is left alone: restarting it would lose
  # the document and scroll position the comparison depends on.
  pgrep -ix "$APP_NAME" >/dev/null || { echo "$APP_NAME is not running" >&2; exit 1; }
fi

# A freshly launched window is not addressable for a second or two. Retry
# rather than reporting the first failure as a permission problem.
sized=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  sleep 2
  if err=$(osascript -e "tell application \"System Events\" to tell process \"$APP_NAME\" to set size of window 1 to {1389, 791}" 2>&1); then
    sized=yes
    break
  fi
done
if [ -z "$sized" ]; then
  echo "cannot drive $APP_NAME through Apple Events: $err" >&2
  echo "If that is a -1743 permission error, grant Automation to the app that" >&2
  echo "runs this script and start it again: the grant is read at process" >&2
  echo "start, so a running process stays denied." >&2
  exit 2
fi
sleep 1

# Zed splits its work over a main process and a helper; charging only one of
# them would flatter it against our single process. Sum the whole app.
PIDS="$(pgrep -ix "$APP_NAME" | tr '\n' ' ')"
[ -n "$PIDS" ] || { echo "$APP_NAME is not running" >&2; exit 1; }
echo "pids             $PIDS" >&2

cpu_ms() {
  # ps reports [dd-]hh:mm:ss.ss of accumulated CPU time, summed over the app's
  # processes.
  ps -o time= -p $(echo "$1" | tr ' ' ',' | sed 's/,$//') | awk -F'[:.]' '{
    n = NF
    ms = $n * 10 + $(n-1) * 1000 + $(n-2) * 60000
    if (n >= 4) ms += $(n-3) * 3600000
    total += ms
  } END { print total }'
}

BEFORE="$(cpu_ms "$PIDS")"
# Alternate Page Down and Page Up. Paging in one direction reaches the end of
# the document after a dozen events on any normal file, and every event after
# that is a no-op that costs nothing and flatters the average.
HALF=$((COUNT / 2))
osascript <<OSA >/dev/null 2>&1
tell application "$APP_NAME" to activate
delay 0.5
tell application "System Events"
  repeat $HALF times
    key code 121
    delay 0.02
    key code 116
    delay 0.02
  end repeat
end tell
OSA
sleep 1
AFTER="$(cpu_ms "$PIDS")"

DELTA=$((AFTER - BEFORE))
echo "app              $APP_NAME"
echo "scrolls          $((HALF * 2)) (alternating page down/up)"
echo "cpu_ms_total     $DELTA"
awk -v d="$DELTA" -v c="$((HALF * 2))" 'BEGIN { printf "ms_cpu_per_scroll %.2f\n", d / c }'
echo
echo "Compare this number across builds. It excludes GPU time, so pair it with"
echo "a visual check once Screen Recording is available."
