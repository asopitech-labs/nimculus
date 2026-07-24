import std/[os, unittest]
import nimnui/platform/macos/platform

proc nativeGuiValidationRequired(): bool =
  getEnv("CI").len > 0 or getEnv("NIMCULUS_REQUIRE_NATIVE_GUI") == "1"

suite "macOS application alert sheet contracts":
  test "application alerts use a non-blocking window sheet and dispatch after completion":
    if platformValidateApplicationAlertSheet():
      check true
    elif nativeGuiValidationRequired():
      check false
    else:
      echo "  [SKIP] application-alert sheet contract (GUI services unavailable in this session)"
