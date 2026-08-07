#!/bin/bash
# Measure what one scroll costs the editor, in CPU time and in frames.
#
# It drives the app with real scroll-wheel events and reads the process's own
# CPU accounting.
#
# Do not measure this with key events. Nimculus ignores Page Down entirely, so
# a key-driven run times an event the editor throws away and reports a cost for
# work that never happened - which is exactly how this file once reported
# 6ms per scroll for a build that actually cost 39ms.
#
# Run it on the build you want to measure, then on the other build, and compare
# ms_cpu_per_scroll. Run it against Zed for the number that matters.
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

POSTER="${TMPDIR:-/tmp}/nimculus-post-scroll"
[ -x "$POSTER" ] || swiftc -O tools/post_scroll.swift -o "$POSTER" || exit 1

# Scroll goes to the window under the pointer, so aim at the middle of the
# editor: the window origin plus roughly a third of its width.
read -r WX WY <<EOF
$(osascript -e "tell application \"System Events\" to tell process \"$APP_NAME\" to get position of window 1" 2>/dev/null | tr ',' ' ')
EOF
POINT_X=$(( ${WX:-0} + 500 ))
POINT_Y=$(( ${WY:-0} + 400 ))

osascript -e "tell application \"$APP_NAME\" to activate" >/dev/null 2>&1
sleep 0.5
# Park at the top first: paging into a document end turns the rest of the run
# into clamped no-ops that cost nothing and flatter the average.
"$POSTER" 60 "$POINT_X" "$POINT_Y" 5 15 up >/dev/null 2>&1
sleep 1

BEFORE="$(cpu_ms "$PIDS")"
"$POSTER" "$COUNT" "$POINT_X" "$POINT_Y" 5 15 >/dev/null 2>&1
sleep 1
AFTER="$(cpu_ms "$PIDS")"

DELTA=$((AFTER - BEFORE))
echo "app              $APP_NAME"
echo "scrolls          $COUNT (wheel, 5 lines each)"
echo "cpu_ms_total     $DELTA"
awk -v d="$DELTA" -v c="$COUNT" 'BEGIN { printf "ms_cpu_per_scroll %.2f\n", d / c }'
echo
echo "Confirm the view actually moved before trusting the number: a run that"
echo "scrolls nothing is cheap and meaningless."
