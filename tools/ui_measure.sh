#!/bin/bash
# The automated UI test path, as run *inside* the test VM.
#
# This is the guest half of tools/ui_test.sh and it runs XCUITest only.
# XCUIAutomation drives the app through the macOS Accessibility Tree, so it
# needs no screen-recording or accessibility grant of its own: xcodebuild
# reaches the app through testmanagerd.
#
# This is NOT the Zed comparison path. Comparing pixels against Zed requires
# both applications running side by side under matched conditions and is a
# different activity with different tooling - see tools/bitdiff.sh,
# tools/ink_check.py, tools/scroll_cost.sh and docs/UI_PARITY_HANDOFF.md.
# Keeping the two apart matters: the parity tools capture the screen and post
# synthetic events, which is exactly the permission surface the automated test
# path is designed to avoid.
set -uo pipefail
cd "$(dirname "$0")/.."
MODE="${1:-smoke}"
OUT="build/ui-test"
mkdir -p "$OUT"

SCHEME=NimculusUITests
PROJECT=tests/macos_ui/NimculusUITests.xcodeproj

[ -d build/macos/Nimculus.app ] || {
  echo "no packaged app; run nimble packageMacos first" >&2
  exit 1
}

# Only the smoke subset runs on every change; the full suite is for nightly.
TEST_ARGS=()
if [ "$MODE" = smoke ]; then
  TEST_ARGS+=(-only-testing:"$SCHEME/NimculusUITests")
fi
if [ "$MODE" = parity ]; then
  TEST_ARGS+=(-only-testing:"$SCHEME/ZedParityTests")
fi

# `profile` samples both editors while the same scroll test drives them, so the
# two profiles are directly comparable. The remaining gap against Zed has been
# found this way four times running, and every time it was either something Zed
# has that was never ported, or something Zed does not do at all.
if [ "$MODE" = profile ]; then
  # Profile each editor in its own run. Sharing one xcodebuild invocation made
  # the second sample miss entirely: `pgrep` matched while the first test was
  # still running, so by the time Zed started the loop had already moved on and
  # reported "zed never started".
  for spec in "Nimculus:testNimculusLongScroll" "zed:testZedLongScroll"; do
    app="${spec%%:*}"
    test="${spec##*:}"
    pkill -x Nimculus 2>/dev/null; pkill -x zed 2>/dev/null
    sleep 3
    xcodebuild test \
      -project "$PROJECT" -scheme "$SCHEME" -destination 'platform=macOS' \
      -only-testing:"$SCHEME/ZedParityTests/$test" \
      > "$OUT/profile-$app.log" 2>&1 &
    test_pid=$!
    pid=""
    for _ in $(seq 1 90); do
      pid=$(pgrep -ix "$app" | head -1)
      [ -n "$pid" ] && break
      sleep 2
    done
    if [ -z "$pid" ]; then
      echo "$app never started" >&2
      wait "$test_pid"
      continue
    fi
    # Let the burst get going; sampling the launch phase records only idle wait.
    sleep 10
    sample "$pid" 12 1 -f "$OUT/sample-$app.txt" >/dev/null 2>&1
    echo "sampled $app (pid $pid)"
    if [ "$app" = Nimculus ]; then
      # Resolve the hot frames to source lines against the very binary that was
      # sampled. Reading offsets out of the sample and reasoning about which
      # statement they land in got the diagnosis wrong three times.
      python3 tools/hot_lines.py "$OUT/sample-$app.txt" \
        build/macos/Nimculus.app/Contents/MacOS/Nimculus > "$OUT/hot-lines.txt" 2>&1
    fi
    wait "$test_pid"
  done
  exit 0
fi

echo "== xcuitest ($MODE)"
xcodebuild test \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination 'platform=macOS' \
  -resultBundlePath "$OUT/$SCHEME.xcresult" \
  "${TEST_ARGS[@]}" \
  2>&1 | tee "$OUT/xcuitest.log"
STATUS=${PIPESTATUS[0]}

# The .xcresult carries the failures, the attachments and any screenshots the
# tests recorded with XCUIScreenshot. It is the artifact worth keeping.

# Normalise cost by how far each editor actually scrolled. The same synthetic
# wheel delta moved them very differently - Nimculus 192px per event against
# Zed 17.7 - so milliseconds per event was comparing different amounts of work.
if [ "$MODE" = parity ] && [ "$STATUS" -eq 0 ]; then
  : > "$OUT/scroll-normalised.txt"
  for app in nimculus zed; do
    ms_file="$OUT/$app-ms-per-scroll.txt"
    [ -f "$ms_file" ] || continue
    best_px=""
    best_steps=""
    for steps in 1 2 4 8 16; do
      cal="$OUT/$app-scroll-cal-$steps.png"
      [ -f "$cal" ] || continue
      px=$(python3 tools/scroll_shift.py "$OUT/$app-scroll-cal-0.png" "$cal" --min-pixels 1 \
        | sed -n 's/^vertical shift: \([0-9]*\)px.*/\1/p')
      [ -z "$px" ] && continue
      # Usable when it moved enough to correlate but stayed on screen.
      if [ "$px" -ge 40 ] && [ "$px" -le 900 ]; then
        best_px="$px"; best_steps="$steps"
      fi
      [ -n "$best_px" ] && break
    done
    if [ -z "$best_px" ]; then
      echo "$app: no calibration step produced a usable shift" | tee -a "$OUT/scroll-normalised.txt"
      STATUS=1
      continue
    fi
    ms=$(cat "$ms_file")
    python3 -c "
px_per_event = float('$best_px') / float('$best_steps')
ms = float('$ms')
print('$app: %.1f px/event (from %s events), %.2f ms/event, %.3f ms per 100px'
      % (px_per_event, '$best_steps', ms, ms / px_per_event * 100))
" | tee -a "$OUT/scroll-normalised.txt"
  done
fi

if [ "$STATUS" -ne 0 ]; then
  echo "FAIL: xcuitest (see $OUT/$SCHEME.xcresult)" >&2
fi
exit "$STATUS"
