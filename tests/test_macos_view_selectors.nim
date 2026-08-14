import std/unittest
import nimnui/platform/macos/platform

when defined(macosx):
  proc platformValidateViewSelectors(): bool
      {.importc: "nimculus_platform_validate_view_selectors", cdecl.}

suite "macOS native view selector contract":
  test "NimculusMetalView exposes Zed's fixed selector set and accepts first mouse":
    when defined(macosx):
      check platformValidateViewSelectors()
    else:
      echo "  [SKIP] macOS native view selector contract (not macOS)"
