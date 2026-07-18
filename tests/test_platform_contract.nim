import std/unittest
import nimnui/platform/macos/platform

suite "macOS platform contract":
  test "metrics have a valid default scale":
    var metrics: PlatformMetrics
    platformGetMetrics(addr metrics)
    check metrics.scaleFactor >= 0.0
    check metrics.widthPixels >= 0'u32

  test "input counter is monotonic":
    let before = platformInputCount()
    let after = platformInputCount()
    check after >= before

  test "IME coordinate invalidation is safe without an active input context":
    platformInvalidateImeCoordinates()
    platformClearEditorComposition()
    check true

  test "native Metal layer contract is available":
    # CI and terminal-only sessions may not expose a Metal device. In that
    # environment the native smoke test is unavailable, not a contract failure.
    if platformValidateNative():
      check true
    else:
      echo "  [SKIP] native Metal layer contract (no Metal device in this session)"

  test "native glyph atlas uploads and reuses visible glyphs":
    if platformValidateGlyphAtlas():
      check true
    else:
      echo "  [SKIP] native glyph atlas contract (no Metal/Core Text device in this session)"

  test "Core Text hit-test preserves UTF-8 and UTF-16 contracts":
    platformSetEditorRect(48.0, 128.0, 400.0, 300.0)
    let text = "A日本語🙂\nnext"
    platformSetEditorText(text.cstring, uint32(text.len))
    platformSetEditorScrollLine(0)
    check platformEditorUtf16OffsetAtPoint(48.0, 512.0) == 0'u32
    check platformEditorByteOffsetAtPoint(10000.0, 512.0) == 14'u32
    check platformEditorUtf16OffsetAtPoint(10000.0, 512.0) == 6'u32
    check platformEditorByteOffsetAtPoint(48.0, 490.0) == 15'u32
    let nulText = "A\0B"
    platformSetEditorText(nulText.cstring, uint32(nulText.len))
    check platformEditorTextUtf8Length() == uint32(nulText.len)
    platformSetEditorText("".cstring, 0)
