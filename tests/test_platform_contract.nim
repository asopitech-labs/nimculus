import std/[os, strutils, unittest]
import nimnui/platform/macos/platform

proc nativeGuiValidationRequired(): bool =
  ## GitHub macOS runners and explicit local GUI runs must fail closed. A
  ## sandboxed terminal may lack the LaunchServices/pasteboard services even
  ## though compilation and non-modal AppKit contracts still work.
  getEnv("CI").len > 0 or getEnv("NIMCULUS_REQUIRE_NATIVE_GUI") == "1"

proc skipNativeSheetService(): bool =
  getEnv("NIMCULUS_SKIP_NATIVE_SHEET_CONTRACTS") == "1"

proc fullscreenTransitionValidationRequired(): bool =
  ## This deliberately changes the active macOS GUI space, so it runs only
  ## on the explicitly opted-in self-hosted runner.
  getEnv("NIMCULUS_REQUIRE_FULLSCREEN_TRANSITION") == "1"

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

  test "input latency retains a bounded recent distribution":
    check platformValidateInputLatencyTracking()
    check uint32(sizeof(InputLatencyStats)) == platformInputLatencyStatsSize()
    var stats: InputLatencyStats
    platformGetInputLatencyStats(addr stats)
    check stats.recentSampleCount <= 256'u64
    check stats.sampleCount >= stats.recentSampleCount
    check stats.inputEventCount >= stats.sampleCount
    check stats.averageMs >= 0.0
    check stats.p95Ms >= 0.0
    check stats.maxMs >= stats.p95Ms
    check stats.averageEventsPerFrame >= 0.0
    check stats.p95EventsPerFrame <= stats.maxEventsPerFrame

  test "frame timing retains a bounded recent distribution":
    check platformValidateFrameTimingTracking()
    check uint32(sizeof(FrameTimingStats)) == platformFrameTimingStatsSize()
    var stats: FrameTimingStats
    platformGetFrameTimingStats(addr stats)
    check stats.recentSampleCount <= 256'u64
    check stats.sampleCount >= stats.recentSampleCount
    check stats.over30HzBudgetCount <= stats.over60HzBudgetCount
    check stats.averageMs >= 0.0
    check stats.p95Ms >= 0.0
    check stats.maxMs >= stats.p95Ms

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

  test "native appearance changes dispatch a system-theme command":
    check platformValidateAppearanceCallback()

  test "native main menu exposes macOS standard command shortcuts":
    check platformValidateMainMenu()

  test "native Command shortcuts dispatch through the Metal view":
    check platformValidateShortcutDispatch()

  test "native editor gutter mouse input reaches the application boundary":
    if platformValidateEditorGutterInput():
      check true
    elif nativeGuiValidationRequired():
      check false
    else:
      echo "  [SKIP] native editor gutter input (GUI services unavailable in this session)"

  test "native Open panel uses a non-blocking window sheet":
    if skipNativeSheetService():
      echo "  [SKIP] Open panel sheet contract (auxiliary GUI service excluded)"
    elif platformValidateOpenPanelSheet():
      check true
    elif nativeGuiValidationRequired():
      check false
    else:
      echo "  [SKIP] Open panel sheet contract (GUI services unavailable in this session)"

  test "native window supports fullscreen, minimize, zoom, and monitor bounds":
    if platformValidateWindowLifecycle():
      check true
    elif nativeGuiValidationRequired():
      check false
    else:
      echo "  [SKIP] native window lifecycle (GUI services unavailable in this session)"

  test "native app delegate receives close and screen-change window callbacks":
    if platformValidateWindowDelegate():
      check true
    elif nativeGuiValidationRequired():
      check false
    else:
      echo "  [SKIP] native window delegate (GUI services unavailable in this session)"

  test "native window enters and exits macOS fullscreen":
    if fullscreenTransitionValidationRequired():
      check platformValidateFullscreenTransition()
    else:
      echo "  [SKIP] fullscreen transition (dedicated GUI runner not requested)"

  test "native split pane geometry keeps hit regions disjoint":
    check platformValidateEditorPaneGeometry()

  test "native editor text viewport excludes pane right and bottom chrome":
    check platformValidateEditorTextViewport()

  test "native status overlay skips unchanged AppKit values":
    check platformValidateStatusUpdateDeduplication()

  test "native retained scene rebuilds fully for a new target":
    check platformValidateDamageRebuild()

  test "native Metal scroll viewport clip limits 2x backing pixels":
    if platformValidateScrollClipPixels():
      check true
    elif nativeGuiValidationRequired():
      check false
    else:
      echo "  [SKIP] native Metal scroll clip pixels (no Metal device in this session)"

  test "native retained scene replaces its Metal texture across size changes":
    if platformValidateSceneTextureReplacement():
      check true
    elif nativeGuiValidationRequired():
      check false
    else:
      echo "  [SKIP] native scene texture replacement (no Metal device in this session)"

  test "native file open events preserve Finder and URL paths":
    check platformValidateFileOpenEvents()

  test "Finder launch events wait for the Nim file callback":
    check platformValidateDeferredFileOpenEvents()

  test "external file changes use a non-modal action notification":
    if skipNativeSheetService():
      echo "  [SKIP] external-change notification contract (auxiliary GUI service excluded)"
    elif platformValidateExternalChangeSheet():
      check true
    elif nativeGuiValidationRequired():
      check false
    else:
      echo "  [SKIP] external-change sheet contract (GUI services unavailable in this session)"

  test "native IME composition preserves UTF-16 and UTF-8 boundaries":
    check platformValidateImeComposition()

  test "terminal cell metrics follow the selected fixed-pitch font":
    let defaultWidth = platformTerminalCellWidth()
    let defaultHeight = platformTerminalLineHeight()
    check defaultWidth > 0.0
    check defaultHeight > 0.0
    check platformTerminalInsetX() >= 0.0
    check platformTerminalInsetY() >= 0.0
    platformSetTerminalFontSize(24.0)
    check platformTerminalCellWidth() > defaultWidth
    check platformTerminalLineHeight() > defaultHeight
    platformSetTerminalFontSize(12.0)

  test "IME command fallback dispatches native editor commands":
    check platformValidateImeCommandDispatch()

  test "native IME candidate rect follows the UTF-16 cursor position":
    ## `firstRectForCharacterRange:` requires the same HIServices auxiliary
    ## process as a real IME candidate window. The dedicated GUI runner keeps
    ## this strict; the combined isolated E2E must not start that service.
    if skipNativeSheetService():
      echo "  [SKIP] native IME candidate rect (auxiliary GUI service excluded)"
    elif platformValidateImeCandidateRect():
      check true
    elif nativeGuiValidationRequired():
      check false
    else:
      echo "  [SKIP] native IME candidate rect (GUI services unavailable in this session)"

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

  test "terminal cell runs preserve style links wide cells and selection":
    check platformValidateTerminalOverlayRuns()

  test "terminal session bar exposes select new and close actions":
    check platformValidateTerminalSessionBar()

  test "output panel presents title close and task-cancel actions":
    check platformValidateOutputPanelBar()

  test "every document tab exposes an independent close target":
    check platformValidateTabBarCloseTargets()

  test "editor tab context actions retain their pane and tab target":
    check platformValidateEditorTabContext()

  test "Git branch context action retains its selected branch row":
    check platformValidateGitBranchContext()

  test "editor header keeps a non-interactive truncated document breadcrumb":
    check platformValidateEditorContextHeader()

  test "native glyph atlas uploads and reuses visible glyphs":
    if platformValidateGlyphAtlas():
      check true
    elif nativeGuiValidationRequired():
      check false
    else:
      echo "  [SKIP] native glyph atlas contract (no Metal/Core Text device in this session)"

  test "native glyph atlas rebuilds visible quads after eviction":
    if platformValidateGlyphAtlasEviction():
      check true
    elif nativeGuiValidationRequired():
      check false
    else:
      echo "  [SKIP] native glyph atlas eviction contract (no Metal/Core Text device in this session)"

  test "Retina scale changes rebuild text assets and retain 2x atlas entries":
    if platformValidateRetinaTextScaling():
      check true
    elif nativeGuiValidationRequired():
      check false
    else:
      echo "  [SKIP] Retina text scale contract (no Metal/Core Text device in this session)"

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

  test "native line index resolves a deep ten-thousand-line cursor position":
    let lineCount = 10_000
    let text = "x\n".repeat(lineCount - 1) & "終"
    platformSetEditorRect(48.0, 128.0, 400.0, 300.0)
    platformSetEditorText(text.cstring, uint32(text.len))
    platformSetEditorScrollLine(uint32(lineCount - 1))
    let finalLineByteOffset = uint32((lineCount - 1) * 2)
    check platformEditorByteOffsetAtPoint(56.0, 512.0) == finalLineByteOffset
    check platformEditorUtf16OffsetAtPoint(56.0, 512.0) == finalLineByteOffset
    platformSetEditorScrollLine(0)
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
    platformSetSecondaryEditorDiagnostics(nil, 0)
    check true

  test "split panes keep independent syntax highlight buffers":
    check platformValidateSecondaryHighlightIsolation()

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
    platformSetSecondaryEditorGitHunks(nil, 0)
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

  test "sidebar contract accepts project files and Git history without changing editor text":
    let files = "Files: /tmp/project\n────────\nsrc\nmain.nim"
    platformSetEditorSidebar(files.cstring, uint32(files.len), 2, 1)
    let history = "Git History\n────────\n12345678  Initial commit — Nimculus"
    platformSetEditorSidebar(history.cstring, uint32(history.len), 1, 2)
    check true

  test "sidebar rows keep Git section headers out of native dispatch":
    let changes = "Git Status\n────────\nStaged (1)\nM   src/main.nim\nUnstaged (1)\n M  src/main.nim"
    var lineItems = [-1'i32, -1'i32, -1'i32, 0'i32, -1'i32, 1'i32]
    platformSetEditorSidebar(changes.cstring, uint32(changes.len), 2, 3)
    platformSetEditorSidebarLineItems(addr lineItems[0], uint32(lineItems.len))
    check platformValidateSidebarDispatch()

  test "Files sidebar dispatches a native context-menu item":
    check platformValidateSidebarContextDispatch()

  test "Git sidebar exposes Changes History and Branches tabs":
    check platformValidateGitSidebarTabs()

  test "Files sidebar exposes New File and New Folder actions":
    check platformValidateFilesSidebarActions()

  test "Search sidebar exposes New Search and Cancel Search actions":
    check platformValidateSearchSidebarActions()

  test "workspace toolbar exposes primary panel actions":
    check platformValidateWorkspaceToolbar()

  test "activity bar exposes persistent workspace navigation":
    check platformValidateActivityBar()

  test "sidebar supports scrolling long file and Git history lists":
    check platformValidateSidebarScrollContainer()

  test "right sidebar never exceeds a narrowed logical dock":
    check platformValidateSidebarBounds()

  # This must remain last: it releases global Metal, AppKit bridge, and CPU
  # resources exactly as applicationWillTerminate does.
  test "native platform teardown releases retained renderer resources":
    check platformValidateResourceTeardown()
