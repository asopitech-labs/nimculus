#!/bin/bash
# Run the macOS GUI tests inside a disposable Tart VM.
#
# The policy is docs/MACOS_UI_TEST_GUIDELINES.md §0: GUI tests never run on the
# developer's own desktop. Measuring on the host steals the keyboard focus,
# leaves Terminal windows behind, and dies silently when the screen sleeps -
# all of which happened while measuring the Zed parity work by hand.
#
# The guest has its own WindowServer, keyboard, mouse, pasteboard and login
# session, so a click() in the guest cannot reach the host.
#
# Every run starts from the golden image, so UserDefaults, Keychain,
# Pasteboard, Caches and TCC state are identical each time.
#
# This is the automated test path. Comparing pixels against Zed is a separate
# activity with separate tooling (tools/bitdiff.sh, tools/ink_check.py,
# tools/scroll_cost.sh); it needs Zed running beside Nimculus under matched
# conditions and does not belong in this harness.
#
# Usage:
#   tools/ui_test.sh smoke        # build + XCUITest
#   tools/ui_test.sh regression   # the full UI suite
#   tools/ui_test.sh shell        # interactive shell in a throwaway VM
#
# Environment:
#   UI_TEST_BASE   golden image name          (default: ui-test-base)
#   UI_TEST_KEEP   1 = keep the VM on exit    (default: unset, VM is deleted)
#   UI_TEST_OUT    artifact directory         (default: build/ui-test/<run>)
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"

MODE="${1:-smoke}"
BASE="${UI_TEST_BASE:-ui-test-base}"
RUN="ui-test-$(date +%s)"
OUT="${UI_TEST_OUT:-$REPO/build/ui-test/$RUN}"

command -v tart >/dev/null || {
  echo "tart is not installed. brew install openai/tools/tart" >&2
  echo "Note: the tap is openai/tools, not the old cirruslabs/cli." >&2
  exit 1
}

tart list --source local --quiet 2>&1 | grep -qx "$BASE" || {
  echo "golden image '$BASE' not found. Create it with:" >&2
  echo "  tart clone ghcr.io/cirruslabs/macos-tahoe-xcode:latest $BASE" >&2
  echo "  tart set $BASE --cpu 4 --memory 8192" >&2
  exit 1
}

mkdir -p "$OUT"

cleanup() {
  local status=$?
  if [ -n "${UI_TEST_KEEP:-}" ]; then
    echo "keeping VM $RUN (UI_TEST_KEEP is set)"
  else
    tart stop "$RUN" >/dev/null 2>&1
    tart delete "$RUN" >/dev/null 2>&1
  fi
  return $status
}
trap cleanup EXIT

echo "== clone $BASE -> $RUN"
tart clone "$BASE" "$RUN" || exit 1

echo "== boot"
# Keep the guest display alive. The guest needs a WindowServer for XCUITest;
# only the *host* is spared the display and input. --no-graphics is not used
# until it is shown to still support WindowServer, click/typeText and
# screenshots (see docs/MACOS_UI_TEST_GUIDELINES.md §0).
tart run "$RUN" >"$OUT/vm.log" 2>&1 &
VM_PID=$!

# The guest agent answers once the login session is up. Poll rather than
# sleeping a fixed amount: a cold boot is much slower than a warm one.
echo "== wait for guest agent"
ready=""
for _ in $(seq 1 60); do
  if tart exec "$RUN" true >/dev/null 2>&1; then ready=yes; break; fi
  sleep 5
done
[ -n "$ready" ] || { echo "guest agent did not come up; see $OUT/vm.log" >&2; exit 1; }

# The source is copied into the guest rather than shared read-write over
# VirtioFS: Tart issue #1272 (open as of 2026-06-18) reports git working trees
# corrupting over a RW mount. Build output stays on the guest's APFS.
echo "== copy source into the guest"
tart exec "$RUN" mkdir -p /Users/admin/nimculus || exit 1
# Ship a clean archive of the working tree, including uncommitted changes, but
# never the host's build/ or nimcache/ directories.
git ls-files -z --cached --others --exclude-standard \
  | tar --null -T - -czf "$OUT/source.tgz" 2>/dev/null
# -i is required: without it tart does not attach the host's stdin and the
# archive arrives empty, which shows up much later as "Could not find a
# .nimble file" inside the guest.
tart exec -i "$RUN" bash -lc 'cat > /tmp/source.tgz' < "$OUT/source.tgz" || exit 1
tart exec "$RUN" bash -lc 'tar -xzf /tmp/source.tgz -C /Users/admin/nimculus' || exit 1
tart exec "$RUN" bash -lc 'test -f /Users/admin/nimculus/nimculus.nimble' || {
  echo "source did not arrive in the guest" >&2; exit 1; }

echo "== run: $MODE"
case "$MODE" in
  shell)
    UI_TEST_KEEP=1
    echo "VM $RUN is up. Attach with: tart exec $RUN bash -l"
    wait "$VM_PID"
    ;;
  smoke|regression|parity|profile)
    tart exec "$RUN" bash -lc "
      set -e
      cd /Users/admin/nimculus
      export NIMCULUS_ALLOW_ADHOC=1
      nimble packageMacos
      cp -f DEVELOPMENT_GUIDELINES.md /Users/admin/nimculus/DEVELOPMENT_GUIDELINES.md 2>/dev/null || true
      tools/ui_measure.sh $MODE
    " 2>&1 | tee "$OUT/run.log"
    STATUS=${PIPESTATUS[0]}
    echo "== collect artifacts"
    tart exec "$RUN" bash -lc "cat /Users/admin/nimculus/build/ui-test/xcuitest.log" \
      > "$OUT/xcuitest.log" 2>/dev/null || rm -f "$OUT/xcuitest.log"
    # The .xcresult is a bundle, so it travels as an archive.
    for p in hot-lines.txt sample-Nimculus.txt sample-zed.txt nimculus-window.png zed-window.png nimculus-ms-per-scroll.txt zed-ms-per-scroll.txt scroll-normalised.txt nimculus-scroll-cal-0.png nimculus-scroll-cal-1.png nimculus-scroll-cal-2.png nimculus-scroll-cal-4.png nimculus-scroll-cal-8.png nimculus-scroll-cal-16.png zed-scroll-cal-0.png zed-scroll-cal-1.png zed-scroll-cal-2.png zed-scroll-cal-4.png zed-scroll-cal-8.png zed-scroll-cal-16.png \
             nimculus-scroll-before.png nimculus-scroll-after.png zed-scroll-before.png zed-scroll-after.png; do
      tart exec "$RUN" bash -lc "cat /Users/admin/nimculus/build/ui-test/$p" \
        > "$OUT/$p" 2>/dev/null || rm -f "$OUT/$p"
    done
    tart exec "$RUN" bash -lc "cd /Users/admin/nimculus/build/ui-test && tar -czf - NimculusUITests.xcresult" \
      > "$OUT/xcresult.tgz" 2>/dev/null && tar -xzf "$OUT/xcresult.tgz" -C "$OUT" && rm -f "$OUT/xcresult.tgz"
    echo "artifacts: $OUT"
    exit "$STATUS"
    ;;
  *)
    echo "unknown mode: $MODE (smoke|regression|parity|profile|shell)" >&2
    exit 2
    ;;
esac
