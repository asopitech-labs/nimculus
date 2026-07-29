import std/[os, unittest]
import nimnui/platform/macos/platform

proc nativeGuiValidationRequired(): bool =
  getEnv("CI").len > 0 or getEnv("NIMCULUS_REQUIRE_NATIVE_GUI") == "1"

proc skipNativeSheetService(): bool =
  ## The consolidated E2E may run in an isolated GUI process where macOS does
  ## not vend the Save Panel auxiliary XPC service. Dedicated GUI runners keep
  ## this contract enabled; the broader E2E must still exercise the remaining
  ## editor, renderer, benchmark, and package paths.
  getEnv("NIMCULUS_SKIP_NATIVE_SHEET_CONTRACTS") == "1"

suite "macOS file panel contracts":
  test "Save As uses a non-blocking window sheet with the suggested file name":
    if skipNativeSheetService():
      echo "  [SKIP] Save panel sheet contract (auxiliary GUI service excluded)"
    elif platformValidateSavePanelSheet():
      check true
    elif nativeGuiValidationRequired():
      check false
    else:
      echo "  [SKIP] Save panel sheet contract (GUI services unavailable in this session)"
