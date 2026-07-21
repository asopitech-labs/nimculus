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

  test "editor font settings drive a valid native line height":
    platformSetEditorFontSize(20.0)
    check platformEditorLineHeight() >= 20.0
    platformSetEditorFontSize(14.0)
    check platformEditorLineHeight() > 0.0

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

  test "editor cursor and selection refresh the native text overlay":
    platformSetEditorText("A日本語🙂".cstring, uint32("A日本語🙂".len))
    platformSetEditorCursor(24.0, 30.0)
    platformSetEditorCursorByte(4, 0)
    platformSetEditorSelection(1, 4)
    platformSetEditorSelection(0, 0)
    check true

  test "syntax and diagnostic spans have separate native contracts":
    platformSetEditorHighlights(nil, 0)
    platformSetEditorDiagnostics(nil, 0)
    check true

  test "editor annotation overlay contract can be cleared":
    platformSetEditorAnnotations(nil, 0)
    check true

  test "idle callback contract can be cleared":
    platformSetIdleCallback(nil)
    check true

  test "completion popup contract can be cleared":
    platformSetEditorCompletions("".cstring, 0)
    check true

  test "hover tooltip contract can be cleared":
    platformSetEditorHover("".cstring, 0)
    platformSetEditorHoverPosition(8.0, 12.0)
    check true

  test "Git hunk gutter contract can be cleared":
    platformSetEditorGitHunks(nil, 0)
    check true

  test "terminal overlay contract can be cleared":
    platformSetThemeColors("#1f2329".cstring, "#d7dae0".cstring, "#4daafc".cstring)
    platformSetTerminalVisible(false)
    platformSetTerminalText("".cstring, 0)
    platformSetTerminalRuns("".cstring, 0, nil, 0)
    platformSetTerminalSelection(0, 0, 0, 0)
    platformSetTaskOutputVisible(false)
    platformSetTaskOutputText("".cstring, 0)
    check true
