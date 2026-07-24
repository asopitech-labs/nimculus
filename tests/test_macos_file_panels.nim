import std/[os, unittest]
import nimnui/platform/macos/platform

proc nativeGuiValidationRequired(): bool =
  getEnv("CI").len > 0 or getEnv("NIMCULUS_REQUIRE_NATIVE_GUI") == "1"

suite "macOS file panel contracts":
  test "Save As uses a non-blocking window sheet with the suggested file name":
    if platformValidateSavePanelSheet():
      check true
    elif nativeGuiValidationRequired():
      check false
    else:
      echo "  [SKIP] Save panel sheet contract (GUI services unavailable in this session)"
