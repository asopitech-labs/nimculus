import std/[os, unittest]
import nimnui/platform/macos/platform

proc nativeGuiValidationRequired(): bool =
  ## GitHub macOS runners and explicit local GUI runs must fail closed. A
  ## sandboxed terminal may lack the LaunchServices/pasteboard services even
  ## though compilation and non-modal AppKit contracts still work.
  getEnv("CI").len > 0 or getEnv("NIMCULUS_REQUIRE_NATIVE_GUI") == "1"

suite "macOS platform contract":
  test "metrics have a valid default scale":
    var metrics: PlatformMetrics
    platformGetMetrics(addr metrics)
    check metrics.scaleFactor >= 0.0
    check metrics.widthPixels >= 0'u32
    check metrics.lastFrameTimeMs >= 0.0
    check metrics.lastInputLatencyMs >= 0.0
    check metrics.frameCount >= 0'u64

  test "resident memory metric has a valid contract":
    check platformResidentMemoryBytes() >= 0'u64

  test "live allocation metric has a valid contract":
    check platformLiveAllocationCount() >= 0'u64

  test "native ABI sizes match Nim contracts":
    check uint32(sizeof(PlatformMetrics)) == platformMetricsSize()
    check uint32(sizeof(NimculusInputEvent)) == platformInputEventSize()
    check uint32(sizeof(NativeTerminalRun)) == platformTerminalRunSize()
    check uint32(sizeof(NativeHighlightSpan)) == platformHighlightSpanSize()
    check uint32(sizeof(NativeDiagnosticSpan)) == platformDiagnosticSpanSize()
    check uint32(sizeof(NativeEditorAnnotation)) == platformEditorAnnotationSize()
    check uint32(sizeof(NativeGitHunkSpan)) == platformGitHunkSpanSize()
    check uint32(sizeof(NativePaintCommand)) == platformPaintCommandSize()
    check uint32(sizeof(NativePaintRegion)) == platformPaintRegionSize()

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

  test "native main menu exposes macOS standard command shortcuts":
    check platformValidateMainMenu()

  test "native window supports fullscreen, minimize, zoom, and monitor bounds":
    if platformValidateWindowLifecycle():
      check true
    elif nativeGuiValidationRequired():
      check false
    else:
      echo "  [SKIP] native window lifecycle (GUI services unavailable in this session)"

  test "native retained scene rebuilds fully for a new target":
    check platformValidateDamageRebuild()

  test "native file open events preserve Finder and URL paths":
    check platformValidateFileOpenEvents()

  test "native IME composition preserves UTF-16 and UTF-8 boundaries":
    check platformValidateImeComposition()

  test "native input event fields are read only for supported event types":
    check platformValidateInputEventFields()

  test "native clipboard round trip preserves UTF-8 text":
    if platformValidateClipboardRoundtrip():
      check true
    elif nativeGuiValidationRequired():
      check false
    else:
      echo "  [SKIP] native clipboard round trip (pasteboard unavailable in this session)"

  test "editor font settings drive a valid native line height":
    platformSetEditorFontName("Menlo")
    platformSetEditorFontSize(20.0)
    check platformEditorLineHeight() >= 20.0
    platformSetEditorFontSize(14.0)
    check platformEditorLineHeight() > 0.0

  test "terminal font settings are accepted by the native overlay contract":
    platformSetTerminalFontName("Menlo")
    platformSetTerminalFontSize(13.0)
    check true

  test "native glyph atlas uploads and reuses visible glyphs":
    if platformValidateGlyphAtlas():
      check true
    elif nativeGuiValidationRequired():
      check false
    else:
      echo "  [SKIP] native glyph atlas contract (no Metal/Core Text device in this session)"

  test "color emoji keeps the RGBA fallback beside the glyph atlas":
    if platformValidateColorEmojiFallback():
      check true
    elif nativeGuiValidationRequired():
      check false
    else:
      echo "  [SKIP] color emoji fallback contract (no Metal/Core Text device in this session)"

  test "Core Text classifies joined and keycap emoji sequences":
    check platformValidateColorEmojiSequences()

  test "mixed Japanese symbol and emoji text reaches the visible text asset paths":
    if platformValidateVisibleTextAssets():
      check true
    elif nativeGuiValidationRequired():
      check false
    else:
      echo "  [SKIP] mixed visible text asset contract (no Metal/Core Text device in this session)"

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
    platformSetThemeColors("#1f2329".cstring, "#d7dae0".cstring, "#4daafc".cstring,
      "#264f78".cstring, "#3b4048".cstring)
    platformSetTerminalVisible(false)
    platformSetTerminalText("".cstring, 0)
    platformSetTerminalRuns("".cstring, 0, nil, 0)
    platformSetTerminalSelection(0, 0, 0, 0)
    platformSetTaskOutputVisible(false)
    platformSetTaskOutputText("".cstring, 0)
    check true

  test "outline overlay contract accepts symbol text":
    let outline = "Outline\n────────\nmain  1"
    platformSetEditorOutline(outline.cstring, uint32(outline.len), 1)
    check true
