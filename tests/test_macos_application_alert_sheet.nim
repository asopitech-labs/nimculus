import std/[os, unittest]
import nimnui/platform/macos/platform

proc nativeGuiValidationRequired(): bool =
  getEnv("CI").len > 0 or getEnv("NIMCULUS_REQUIRE_NATIVE_GUI") == "1"

proc skipNativeSheetService(): bool =
  getEnv("NIMCULUS_SKIP_NATIVE_SHEET_CONTRACTS") == "1"

suite "macOS editor overlay contracts":
  test "document, workspace search, and command palette stay non-modal":
    if skipNativeSheetService():
      echo "  [SKIP] document search overlay contract (auxiliary GUI service excluded)"
    elif platformValidateApplicationAlertSheet():
      check true
    elif nativeGuiValidationRequired():
      check false
    else:
      echo "  [SKIP] document search overlay contract (GUI services unavailable in this session)"
