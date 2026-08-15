import std/[os, unittest]
import nimnui/platform/macos/platform

proc nativeGuiValidationRequired(): bool =
  getEnv("CI").len > 0 or getEnv("NIMCULUS_REQUIRE_NATIVE_GUI") == "1"

suite "macOS glyph atlas generations":
  test "overflow pushes each shelf independently and preserves cached hits":
    if platformValidateGlyphAtlasEviction():
      check true
    elif nativeGuiValidationRequired():
      check false
    else:
      echo "  [SKIP] glyph atlas generations (no Metal/Core Text device in this session)"
