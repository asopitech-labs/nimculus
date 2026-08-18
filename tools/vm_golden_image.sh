#!/bin/bash
# Idempotent, resumable lifecycle management for the UI-test golden image
# (docs/MACOS_UI_TEST_GUIDELINES.md §0). Also invoked via `make vm-*`.
#
# Design goal: every subcommand can be re-run after a partial failure without
# manual cleanup first. Nothing here deletes the golden image except
# `recreate`, and `recreate` only runs when explicitly invoked - never as a
# side effect of `status`, `verify` or `provision`.
#
# Usage:
#   tools/vm_golden_image.sh status      # non-destructive: does the image exist?
#   tools/vm_golden_image.sh verify      # non-destructive: boots a disposable
#                                         # clone and confirms `nimble
#                                         # packageMacos` actually resolves and
#                                         # builds, the way tools/ui_test.sh
#                                         # would use it
#   tools/vm_golden_image.sh provision   # idempotent: create the image if
#                                         # missing, (re-)apply every setup
#                                         # step. Safe to re-run on a
#                                         # partially-provisioned image; every
#                                         # step checks current state first.
#                                         # Never deletes an existing image.
#   tools/vm_golden_image.sh recreate    # explicit only: delete the existing
#                                         # image (if present), then provision
#                                         # from scratch. This is the actual
#                                         # recovery path for a corrupted image.
#
# Environment:
#   UI_TEST_BASE   image name             (default: ui-test-base)
#   VM_UPSTREAM    OCI source for clone    (default: ghcr.io/cirruslabs/macos-tahoe-xcode:latest)
#   VM_CPU         vCPUs                   (default: 4)
#   VM_MEMORY      MB                      (default: 8192)
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"

IMAGE="${UI_TEST_BASE:-ui-test-base}"
UPSTREAM="${VM_UPSTREAM:-ghcr.io/cirruslabs/macos-tahoe-xcode:latest}"
CPU="${VM_CPU:-4}"
MEMORY="${VM_MEMORY:-8192}"

require_tart() {
  command -v tart >/dev/null || {
    echo "tart is not installed. brew install openai/tools/tart" >&2
    echo "Note: the tap is openai/tools, not the old cirruslabs/cli." >&2
    exit 1
  }
}

image_exists() {
  tart list --source local --quiet 2>/dev/null | grep -qx "$1"
}

# Boots $1, waits for the guest agent, and returns 0/1. Leaves the VM running
# on success. Idempotent: stops any stale instance of the same name first, so
# a crashed prior attempt does not block this one.
boot_and_wait() {
  local vm="$1" out="$2"
  tart stop "$vm" >/dev/null 2>&1 || true
  tart run "$vm" >"$out/vm.log" 2>&1 &
  local ready=""
  for _ in $(seq 1 60); do
    if tart exec "$vm" true >/dev/null 2>&1; then ready=yes; break; fi
    sleep 5
  done
  [ -n "$ready" ] || { echo "guest agent did not come up; see $out/vm.log" >&2; return 1; }
  return 0
}

# Copies the working tree (tracked + untracked, minus .gitignore'd paths) into
# the guest, matching tools/ui_test.sh's source sync. Idempotent: overwrites
# whatever was there.
copy_source_into() {
  local vm="$1" out="$2"
  tart exec "$vm" mkdir -p /Users/admin/nimculus || return 1
  git ls-files -z --cached --others --exclude-standard \
    | tar --null -T - -czf "$out/source.tgz" 2>/dev/null
  tart exec -i "$vm" bash -lc 'cat > /tmp/source.tgz' < "$out/source.tgz" || return 1
  tart exec "$vm" bash -lc 'tar -xzf /tmp/source.tgz -C /Users/admin/nimculus' || return 1
  tart exec "$vm" bash -lc 'test -f /Users/admin/nimculus/nimculus.nimble' || {
    echo "source did not arrive in the guest" >&2; return 1; }
}

cmd_status() {
  require_tart
  if ! image_exists "$IMAGE"; then
    echo "status: MISSING ($IMAGE) - run 'tools/vm_golden_image.sh provision'"
    return 1
  fi
  echo "status: present"
  tart list --source local | { read -r header; echo "$header"; grep -E "^local +$IMAGE( |$)"; }
}

cmd_verify() {
  require_tart
  image_exists "$IMAGE" || {
    echo "verify: $IMAGE does not exist, run 'tools/vm_golden_image.sh provision' first" >&2
    return 1
  }
  # Deliberately not `local`: the EXIT trap below fires after this function
  # has returned, once the whole script's process is exiting - by then a
  # `local` here would already be out of scope and `set -u` would abort the
  # cleanup itself, leaking the disposable VM. (Hit this exact bug once.)
  verify_vm="ui-test-verify-$(date +%s)"
  verify_out="$(mktemp -d)"
  cleanup() {
    local status=$?
    tart stop "$verify_vm" >/dev/null 2>&1 || true
    tart delete "$verify_vm" >/dev/null 2>&1 || true
    rm -rf "$verify_out"
    return $status
  }
  trap cleanup EXIT
  local vm="$verify_vm" out="$verify_out"

  echo "== clone $IMAGE -> $vm (disposable, deleted on exit)"
  tart clone "$IMAGE" "$vm" || return 1

  echo "== boot"
  boot_and_wait "$vm" "$out" || return 1

  echo "== copy source"
  copy_source_into "$vm" "$out" || return 1

  echo "== nimble packageMacos (the exact command tools/ui_test.sh relies on)"
  if tart exec "$vm" bash -lc '
      cd /Users/admin/nimculus
      export NIMCULUS_ALLOW_ADHOC=1
      nimble packageMacos
    ' 2>&1 | tee "$out/verify.log"; then
    echo "verify: OK - $IMAGE can build a packaged app from a fresh clone"
  else
    echo "verify: FAILED - see the log above. This is the same class of" >&2
    echo "  failure documented in docs/UI_PARITY_HANDOFF.md; run" >&2
    echo "  'tools/vm_golden_image.sh recreate' to rebuild the image." >&2
    return 1
  fi
}

# Applies every provisioning step to whatever VM is passed in $1 (already
# booted). Each step checks current state before acting, so this is safe to
# run repeatedly against the same image - including the golden image itself.
provision_steps() {
  local vm="$1" out="$2"

  echo "== install missing packages (idempotent: skips what is already present)"
  tart exec "$vm" bash -lc '
    set -e
    command -v nim >/dev/null || brew install nim
    python3 -c "import PIL, numpy" 2>/dev/null || \
      python3 -m pip install --break-system-packages pillow numpy
    [ -d /Applications/Zed.app ] || brew install --cask zed
  ' || return 1

  echo "== remove quarantine from Zed (idempotent: harmless if already clear)"
  tart exec "$vm" bash -lc \
    'xattr -r -d com.apple.quarantine /Applications/Zed.app 2>/dev/null || true'

  # A `brew install --cask` move of the .app bundle does not always make
  # Launch Services resolve its bundle identifier immediately - the very
  # first `XCUIApplication(bundleIdentifier: "dev.zed.Zed")` after a fresh
  # cask install failed with "The app representing dev.zed.Zed could not be
  # found" until this ran. Idempotent: re-registering an already-known app
  # is a no-op.
  echo "== register Zed with Launch Services (idempotent)"
  tart exec "$vm" bash -lc \
    '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Zed.app'

  echo "== copy source (needed for the nimble package cache warm-up and the" \
    "provisioning XCUITest)"
  copy_source_into "$vm" "$out" || return 1

  echo "== warm the nimble package cache (this is what a broken image fails" \
    "on - see docs/UI_PARITY_HANDOFF.md)"
  tart exec "$vm" bash -lc '
    cd /Users/admin/nimculus
    export NIMCULUS_ALLOW_ADHOC=1
    nimble packageMacos
  ' || return 1

  # scripts/package_macos.sh does not register the built app with Launch
  # Services, and XCUIApplication(bundleIdentifier: "com.asopitech.nimculus")
  # in the provisioning test failed to resolve it without this - the same
  # class of problem as the Zed cask above, just for a hdiutil/codesign-built
  # bundle instead of a brew-moved one. Idempotent.
  echo "== register Nimculus.app with Launch Services (idempotent)"
  tart exec "$vm" bash -lc \
    '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Users/admin/nimculus/build/macos/Nimculus.app'

  echo "== apply settings files (idempotent: only writes if the key is absent)"
  tart exec "$vm" bash -lc '
    mkdir -p ~/.config/zed
    if ! grep -q auto_update ~/.config/zed/settings.json 2>/dev/null; then
      echo "{\"auto_update\": false}" > ~/.config/zed/settings.json
    fi
    mkdir -p ~/Library/Application\ Support/Nimculus
    if ! grep -q theme "~/Library/Application Support/Nimculus/settings.json" 2>/dev/null; then
      echo "{\"theme\": \"light\"}" > ~/Library/Application\ Support/Nimculus/settings.json
    fi
  '

  echo "== disable Notification Center (idempotent: unload is a no-op if" \
    "already unloaded)"
  tart exec "$vm" bash -lc \
    'launchctl unload -w /System/Library/LaunchAgents/com.apple.notificationcenterui.plist 2>/dev/null || true'

  echo "== dismiss Zed's one-time first-run dialogs via XCUITest" \
    "(docs/MACOS_UI_TEST_GUIDELINES.md §0)"
  tart exec "$vm" bash -lc '
    cd /Users/admin/nimculus
    xcodebuild test \
      -project tests/macos_ui/NimculusUITests.xcodeproj \
      -scheme NimculusUITests \
      -destination "platform=macOS" \
      -only-testing:NimculusUITests/ZedParityTests/testProvisionGoldenImage
  ' 2>&1 | tee "$out/provision-xcuitest.log"
  local xcuitest_status=${PIPESTATUS[0]:-$?}
  if [ "$xcuitest_status" -ne 0 ]; then
    echo "provision: the first-run dialog dismissal test failed." >&2
    echo "  Watch the VM window and finish it by hand this once - see" >&2
    echo "  docs/MACOS_UI_TEST_GUIDELINES.md §0 '構築中の VM を目で確認する'." >&2
    return 1
  fi
}

cmd_provision() {
  require_tart
  # Deliberately not `local`: see the comment on verify_vm/verify_out in
  # cmd_verify - the same bug (EXIT trap outliving the function's local
  # scope) bit this function's cleanup too.
  provision_out="$(mktemp -d)"
  trap 'rm -rf "$provision_out"' EXIT
  local out="$provision_out"

  if ! image_exists "$IMAGE"; then
    echo "== clone $UPSTREAM -> $IMAGE"
    tart clone "$UPSTREAM" "$IMAGE" || return 1
  else
    echo "== $IMAGE already exists, provisioning in place"
  fi

  echo "== set cpu=$CPU memory=${MEMORY}MB (idempotent)"
  tart set "$IMAGE" --cpu "$CPU" --memory "$MEMORY" || return 1

  echo "== boot $IMAGE directly (not a clone: changes must persist)"
  boot_and_wait "$IMAGE" "$out" || return 1

  if ! provision_steps "$IMAGE" "$out"; then
    echo "provision: failed partway. The image is left as-is (stopped);" >&2
    echo "  re-run 'tools/vm_golden_image.sh provision' to resume - every" >&2
    echo "  step above is safe to repeat." >&2
    tart stop "$IMAGE" >/dev/null 2>&1 || true
    return 1
  fi

  echo "== stop $IMAGE (changes persist on its own disk)"
  tart stop "$IMAGE" || return 1
  echo "provision: done. Run 'tools/vm_golden_image.sh verify' to confirm."
}

cmd_recreate() {
  require_tart
  echo "recreate: this deletes the existing '$IMAGE' image if present, then" \
    "provisions a fresh one."
  if image_exists "$IMAGE"; then
    tart stop "$IMAGE" >/dev/null 2>&1 || true
    tart delete "$IMAGE" || return 1
  fi
  cmd_provision
}

case "${1:-status}" in
  status) cmd_status ;;
  verify) cmd_verify ;;
  provision) cmd_provision ;;
  recreate) cmd_recreate ;;
  *)
    echo "usage: $0 {status|verify|provision|recreate}" >&2
    exit 2
    ;;
esac
