import std/[os, unittest]
import nimnui/platform/macos/platform

proc nativeGuiValidationRequired(): bool =
  getEnv("CI").len > 0 or getEnv("NIMCULUS_REQUIRE_NATIVE_GUI") == "1"

proc skipNativeSheetService(): bool =
  getEnv("NIMCULUS_SKIP_NATIVE_SHEET_CONTRACTS") == "1"

suite "macOS modal sheet contracts":
  test "unsaved tab close confirmation uses a non-blocking window sheet":
    if skipNativeSheetService():
      echo "  [SKIP] unsaved-close sheet contract (auxiliary GUI service excluded)"
    elif platformValidateUnsavedCloseSheet():
      check true
    elif nativeGuiValidationRequired():
      check false
    else:
      echo "  [SKIP] unsaved-close sheet contract (GUI services unavailable in this session)"
