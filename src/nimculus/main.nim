import std/algorithm
import std/json
import std/math
import std/os
import std/osproc
import std/sequtils
import std/strutils
import std/times
import std/unicode except splitWhitespace
import nimnui/nimnui
import nimnui/render
import nimculus/editor_app
import nimculus/editor_buffer
import nimculus/editor_view
import nimculus/workspace_ui
import nimculus/editor_syntax
import nimculus/syntax
import nimculus/tree_sitter
import nimculus/workspace
import nimculus/session
import nimculus/persistence_scheduler
import nimculus/poll_scheduler
import nimculus/lsp_editor_bridge
import nimculus/lsp
import nimculus/dap
import nimculus/agent_service
import nimculus/extension_service
import nimculus/extension_catalog
import nimculus/wasm_runtime
import nimculus/editor_diagnostics
import nimculus/git_service
import nimculus/git_gutter
import nimculus/task_service
import nimculus/update_service
import nimculus/terminal
import nimculus/settings
when defined(windows):
  import nimculus/windows_terminal

when defined(windows):
  var windowsTaskJob: TaskJob
  var windowsTaskCommand = ""
  var windowsTaskOutput = ""
  var windowsTaskOutputVisible = false
  var windowsTaskProblems: seq[TaskProblem]

when defined(macosx) or defined(windows):
  var coldStartBenchmarkPending = getEnv("NIMCULUS_BENCH_COLD_START", "") == "1"
  let coldStartBenchmarkStartedAt = epochTime()

  proc positiveEnvSeconds(name: string, defaultValue: int): int =
    try:
      result = parseInt(getEnv(name, $defaultValue))
    except ValueError:
      result = defaultValue
    result = max(1, result)

  var soakBenchmarkPending = getEnv("NIMCULUS_BENCH_SOAK", "") == "1"
  let soakBenchmarkStartedAt = epochTime()
  let soakBenchmarkDurationSeconds = positiveEnvSeconds("NIMCULUS_SOAK_SECONDS", 8 * 60 * 60)
  let soakBenchmarkIntervalSeconds = positiveEnvSeconds("NIMCULUS_SOAK_INTERVAL_SECONDS", 30)
  var soakBenchmarkNextSampleAt = soakBenchmarkStartedAt

  proc finishColdStartBenchmark(): bool =
    if not coldStartBenchmarkPending: return false
    coldStartBenchmarkPending = false
    let elapsedMs = (epochTime() - coldStartBenchmarkStartedAt) * 1000.0
    var metrics: PlatformMetrics
    platformGetMetrics(addr metrics)
    echo "cold_start\t", formatFloat(elapsedMs, ffDecimal, 3),
      "\tmilliseconds\tready=1\tframes=", metrics.frameCount,
      "\tdrawable=", metrics.widthPixels, "x", metrics.heightPixels
    when defined(macosx):
      # The probe never edits a document, so bypass the user-facing dirty
      # confirmation sheet and exercise the actual application termination
      # path directly.
      platformConfirmQuit()
    else:
      platformRequestQuit()
    true

  proc pollSoakBenchmark(): bool =
    if not soakBenchmarkPending: return false
    let now = epochTime()
    if now >= soakBenchmarkNextSampleAt:
      var metrics: PlatformMetrics
      platformGetMetrics(addr metrics)
      var latencyDetails = ""
      when defined(macosx):
        var latency: InputLatencyStats
        var frameTiming: FrameTimingStats
        platformGetInputLatencyStats(addr latency)
        platformGetFrameTimingStats(addr frameTiming)
        latencyDetails = "\tlast_frame_ms=" & formatFloat(metrics.lastFrameTimeMs, ffDecimal, 3) &
          "\tframe_samples=" & $frameTiming.sampleCount &
          "\tframe_p95_ms=" & formatFloat(frameTiming.p95Ms, ffDecimal, 3) &
          "\tframe_over_60hz_budget=" & $frameTiming.over60HzBudgetCount &
          "\tlast_input_ms=" & formatFloat(metrics.lastInputLatencyMs, ffDecimal, 3) &
          "\tlatency_samples=" & $latency.sampleCount &
          "\tlatency_p95_ms=" & formatFloat(latency.p95Ms, ffDecimal, 3) &
          "\tcoalesced_events_p95=" & $latency.p95EventsPerFrame
      echo "soak_sample\t", formatFloat(now - soakBenchmarkStartedAt, ffDecimal, 3),
        "\tseconds\tresident=", platformResidentMemoryBytes(),
        "\tlive_blocks=", platformLiveAllocationCount(),
        "\tframes=", metrics.frameCount,
        "\tinput=", platformInputCount(), latencyDetails
      soakBenchmarkNextSampleAt = now + float64(soakBenchmarkIntervalSeconds)
    if now - soakBenchmarkStartedAt >= float64(soakBenchmarkDurationSeconds):
      soakBenchmarkPending = false
      echo "soak_complete\t", formatFloat(now - soakBenchmarkStartedAt, ffDecimal, 3),
        "\tseconds\tsamples=ready"
      when defined(macosx):
        platformConfirmQuit()
      else:
        platformRequestQuit()
      return true
    false

proc syncEditorCursor(ensureCursor = true)
proc syncWorkspaceUiTabs()
proc activeDocument(): ptr FileDocument
proc secondaryPaneDocument(): ptr FileDocument
when defined(macosx):
  proc syncSecondaryEditorView(ensureCursor = true)
  proc syncSecondaryNativeDiagnostics(document: ptr FileDocument)
proc persistSession()

var demoTree = newUiTree()
var shortcutRegistry: CommandRegistry
var demoButton = NodeId(0)
var demoSplitNode = NodeId(0)
var demoScrollNode = NodeId(0)
var editorWorkspaceUi: WorkspaceUiState
when defined(macosx):
  # Layout composition needs these visibility facts before the platform-owned
  # terminal/task services are declared below.
  var editorTaskOutputVisible = false
  var editorTerminalVisible = false
var demoSplitRatio = 0.5'f32
var demoSplitDragging = false
var demoSplitEnabled = false
var demoSplitDirection = splitVertical
var activePointerNode = NodeId(0)
var demoEditorBounds = Rect(size: Size(width: px(0), height: px(0)))
var demoSecondaryEditorBounds = Rect(size: Size(width: px(0), height: px(0)))
var demoBottomDockBounds = Rect(size: Size(width: px(0), height: px(0)))
  # Match Zed's default macOS workspace: the activity bar is outermost left and
  # the Files panel sits immediately inside it. WorkspaceUiState already owns
  # the logical left dock, so the macOS projection uses the same side.
const MacProjectDockOnRight = false
when defined(macosx) or defined(windows):
  var appSettings: SettingsStore
  var editorLspSemanticTokens: seq[LspSemanticToken]
  var editorLspSemanticTokenPath = ""
  var editorLspSemanticTokenSource = ""
  var editorLspSignatureText = ""
  var editorLspInlayHints: seq[LspInlayHint]
  var editorLspInlayHintPath = ""
  var editorLspInlayHintSource = ""
  var editorLspSecondaryInlayHints: seq[LspInlayHint]
  var editorLspSecondaryInlayHintPath = ""
  var editorLspSecondaryInlayHintSource = ""
  var pendingLspRename: seq[LspWorkspaceEdit]
  var pendingLspCodeActions: seq[LspCodeAction]
  var pendingLspSymbols: seq[LspSymbol]
  var pendingLspSymbolDepths: seq[int]
  ## Tree-sitter supplies a local outline even when no Language Server is
  ## configured. Keep it separate so an LSP response can take precedence
  ## without losing the immediate syntax fallback during server startup.
  var pendingSyntaxSymbols: seq[LspSymbol]

when defined(macosx):
  # NSSavePanel is asynchronous. Remember the tab that initiated it so a
  # focused secondary pane is not replaced by whichever tab is active when
  # the panel returns.
  var pendingSaveTabIndex = -1
  # Index of the next tab to save while an asynchronous Save All and Quit
  # sequence is waiting for an untitled document's NSSavePanel response.
  var pendingSaveAllQuitNextTab = -1
  # A close sheet is asynchronous. Keep its Pane-local target stable rather
  # than resolving the then-current focus when the sheet completes.
  var pendingCloseTabIndex = -1
  var pendingClosePane = 0
  var editorWasmComponentJob: WasmComponentJob
  var editorWasmComponentId = ""
  var editorWasmComponentCancelRequested = false
  # A single packaged-app workflow exercises the same command/input boundary
  # as a user without relying on flaky Accessibility scripting. The harness
  # is opt-in and writes one result file before the app is cleaned up.
  var macosGuiWorkflowEnabled = false
  var macosGuiWorkflowStep = 0
  var macosGuiWorkflowStartedAt = 0.0
  var macosGuiWorkflowResultPath = ""

proc resetPointerInteractions()
when defined(macosx):
  proc syncNativeHover()
  proc syncNativeInlayHints(document: ptr FileDocument)
  proc syncNativeSecondaryInlayHints(document: ptr FileDocument)
  proc syncNativeSymbolTree()
  proc updateSyntaxOutline(document: ptr FileDocument)
  proc expandNativeSyntaxSelection(expand: bool)
  proc moveNativeSyntaxSibling(next: bool)
  proc moveNativeToEnclosingBracket()
  proc handleCompletionShortcut(event: ptr NimculusInputEvent): bool

when defined(windows):
  proc windowsEditorLineHeight(): float32 =
    float32(max(1.0, platformEditorLineHeight()))

  proc windowsEditorCellWidth(): float32 =
    let size = if appSettings != nil: appSettings.intSetting("editor.fontSize", 14) else: 14
    max(4'f32, float32(size) * 0.5'f32)

  proc registerWindowsDemoImage() =
    var pixels = newSeq[uint8](16 * 16 * 4)
    for y in 0 ..< 16:
      for x in 0 ..< 16:
        let alternate = ((x div 4) + (y div 4)) mod 2 == 0
        let offset = (y * 16 + x) * 4
        pixels[offset] = if alternate: 80'u8 else: 30'u8
        pixels[offset + 1] = if alternate: 180'u8 else: 90'u8
        pixels[offset + 2] = if alternate: 240'u8 else: 150'u8
        pixels[offset + 3] = 255'u8
    platformSetImageRgba(1, 16, 16, addr pixels[0], uint32(pixels.len))

proc widestVisibleEditorLineWidth(buffer: PieceTable, view: EditorViewState,
                                  visibleLines: int): float32
proc addEditorScrollbars(paint: var PaintList, bounds: Rect, view: EditorViewState,
                         lineCount, visibleLines: int, widestLineWidth: float32)
proc drawCurrentEditorScrollbars(paint: var PaintList, primary, secondary: Rect,
                                 lineCount: int, document: ptr FileDocument)
when defined(macosx):
  proc editorVisibleLineCount(): int
  proc secondaryEditorVisibleLineCount(): int

proc setupDemoUi() =
  ## Keep rendering state synchronized with the document session at the
  ## composition boundary. Pane ownership remains independent: a split
  ## duplicates a viewport, never a document buffer.
  when defined(macosx):
    # The bottom dock has no persistent content of its own: terminal PTYs and
    # task output both cease to exist when the app exits. Never reserve editor
    # space for restored dock metadata unless a native presenter is actually
    # visible. This makes the render layout match the AppKit overlay contract.
    if not editorTerminalVisible and not editorTaskOutputVisible:
      editorWorkspaceUi.bottomDock.isOpen = false
  let document = activeDocument()
  let hasDocument = document != nil
  syncWorkspaceUiTabs()
  demoTree = newUiTree()
  resetPointerInteractions()
  let root = demoTree.addNode()
  let button = makeControl(demoTree, root, ControlKind.button, "Nimculus", focusable = true)
  let split = makeControl(demoTree, root, ControlKind.splitPane, "Editor split")
  let scroll = makeControl(demoTree, root, ControlKind.scrollView, "Editor scroll")
  demoButton = button.node
  demoSplitNode = split.node
  demoScrollNode = scroll.node
  var metrics: PlatformMetrics
  platformGetMetrics(addr metrics)
  let viewportWidth = if metrics.widthPoints > 0: float32(metrics.widthPoints) else: 960'f32
  let viewportHeight = if metrics.heightPoints > 0: float32(metrics.heightPoints) else: 640'f32
  let viewport = Rect(size: Size(width: px(viewportWidth), height: px(viewportHeight)))
  let spec = LayoutSpec(direction: row,
    size: Size(width: px(0), height: px(0)),
    minSize: Size(width: px(0), height: px(0)),
    maxSize: Size(width: px(10000), height: px(10000)),
    padding: EdgeInsets(top: px(20), right: px(20), bottom: px(20), left: px(20)),
    gap: px(8), alignment: alignCenter,
    viewport: viewport)
  demoTree.layoutNode(root, viewport, spec)
  let bounds = demoTree.node(button.node).bounds
  let workspaceLayout = editorWorkspaceUi.layout(
    Size(width: px(viewportWidth), height: px(viewportHeight)))
  let logicalDockWidth = float32(workspaceLayout.leftDock.size.width)
  # The native Project presenter needs 124pt of content plus the 38pt
  # activity bar and the 16pt outer spacing used by the AppKit boundary. If
  # the logical dock has already yielded that space to the editor, retire the
  # dock as one visual unit rather than leaving an empty Metal gutter beside
  # a hidden native sidebar. Its open/panel state remains in WorkspaceUiState
  # and returns automatically when the window is widened again.
  const MacNativeSidebarMinimumDockWidth = 178'f32
  let nativePresenterMinimum = if MacProjectDockOnRight:
    MacNativeSidebarMinimumDockWidth else: 0'f32
  let leftDockWidth = dockPresentationWidth(logicalDockWidth,
    nativePresenterMinimum)
  let sidebarCanPresent = not MacProjectDockOnRight or leftDockWidth > 0'f32
  let bottomDockHeight = float32(workspaceLayout.bottomDock.size.height)
  # Keep the platform projection aligned with WorkspaceUiState: the logical
  # left dock is also the visible macOS left dock.
  let contentX = if MacProjectDockOnRight: 0'f32 else: leftDockWidth
  let contentWidth = max(0'f32, viewportWidth - leftDockWidth)
  demoBottomDockBounds = Rect(origin: Point(x: px(contentX),
      y: workspaceLayout.bottomDock.origin.y),
    size: Size(width: px(contentWidth), height: workspaceLayout.bottomDock.size.height))
  let margin = 24'f32
  let panel = Rect(origin: Point(x: px(margin), y: px(margin)),
    size: Size(width: px(max(0'f32, viewportWidth - margin * 2)),
               height: px(max(0'f32, viewportHeight - margin * 2))))
  let toolbar = Rect(origin: Point(x: px(margin * 2), y: px(margin * 2)),
    size: Size(width: px(max(0'f32, viewportWidth - margin * 4)), height: px(56)))
  # Preserve the mature editor presenter's internal gutters while making the
  # composition boundary authoritative: the dock owns its width and the
  # center receives the remainder.
  let editorWidth = max(0'f32, contentWidth - 28'f32)
  # Keep a compact Zed-like workspace header. The AppKit traffic lights sit
  # over the app-owned titlebar, while this Metal view remains the content
  # region below it. Breadcrumb, tabs, and text occupy the first 56pt of the
  # workspace in sequence.
  # The native tab strip occupies the first 28pt of the editor surface. Keep
  # the text viewport below it instead of treating the pane's outer rectangle
  # as editable content: otherwise the first rendered line can appear behind
  # tabs and a resized pane has no unambiguous bottom boundary.
  const EditorTabStripHeight = 28'f32
  const EditorTopInset = 28'f32 + EditorTabStripHeight
  # The status bar is the only persistent chrome below the editor. Align the
  # editor's bottom edge directly with the logical status-panel top; an extra
  # gutter here becomes a visible blank strip between the editor and footer.
  const EditorBottomInset = DefaultStatusHeight
  let editorHeight = max(0'f32, float32(workspaceLayout.center.size.height) -
    EditorTopInset - EditorBottomInset)
  let editor = Rect(origin: Point(x: px(contentX + 28'f32), y: px(EditorTopInset)),
    size: Size(width: px(editorWidth), height: px(editorHeight)))
  # PaneTree is the sole owner of split geometry. The native primary and
  # secondary text presenters consume its first two leaves during the staged
  # migration; they no longer calculate a competing split rectangle here.
  let paneLayout = editorWorkspaceUi.center.paneLayout(editor)
  var primaryEditor = if paneLayout.panes.len > 0: paneLayout.panes[0].bounds else: editor
  var secondaryEditor = Rect(size: Size(width: px(0), height: px(0)))
  var splitBar = Rect(size: Size(width: px(0), height: px(0)))
  if paneLayout.panes.len > 1:
    secondaryEditor = paneLayout.panes[1].bounds
  if paneLayout.dividers.len > 0:
    splitBar = paneLayout.dividers[0].bounds
  demoSplitEnabled = paneLayout.panes.len > 1
  if editorWorkspaceUi.center != nil and editorWorkspaceUi.center.kind == paneSplit:
    demoSplitDirection = if editorWorkspaceUi.center.axis ==
        paneVertical: splitVertical else: splitHorizontal
    demoSplitRatio = editorWorkspaceUi.center.ratio
  demoEditorBounds = primaryEditor
  demoSecondaryEditorBounds = secondaryEditor
  demoTree.node(button.node).bounds = toolbar
  demoTree.node(split.node).bounds = splitBar
  demoTree.node(scroll.node).bounds = editor
  var paint: PaintList
  paint.invalidate(viewport)
  # The native text overlays remain transitional content presenters, but their
  # surface is composed by the same Metal scene as the editor.  Derive chrome
  # from WorkspaceUiState rather than drawing a disconnected demo card.
  paint.drawWorkspaceBackground(viewport)
  if leftDockWidth > 0:
    let dockX = if MacProjectDockOnRight: viewportWidth - leftDockWidth else: 0'f32
    paint.drawWorkspacePanel(Rect(origin: Point(x: px(dockX), y: px(24)),
      size: Size(width: px(leftDockWidth), height: px(max(0'f32, viewportHeight - 46'f32 -
          bottomDockHeight)))))
    paint.drawWorkspaceSeparator(Rect(origin: Point(x: px(
        if MacProjectDockOnRight: dockX else: leftDockWidth - 1), y: px(24)),
      size: Size(width: px(1), height: px(max(0'f32, viewportHeight - 46'f32 - bottomDockHeight)))))
  if bottomDockHeight > 0:
    paint.drawWorkspacePanel(Rect(origin: Point(x: px(contentX),
      y: px(viewportHeight - DefaultStatusHeight - bottomDockHeight)),
      size: Size(width: px(contentWidth), height: px(bottomDockHeight))))
    paint.drawWorkspaceSeparator(Rect(origin: Point(x: px(contentX),
      y: px(viewportHeight - DefaultStatusHeight - bottomDockHeight)),
      size: Size(width: px(max(0'f32, viewportWidth - leftDockWidth)), height: px(1))))
  paint.drawWorkspacePanel(workspaceLayout.status)
  if hasDocument and editorWorkspaceUi.focusedRegion == regionCenter:
    paint.drawWorkspaceActive(Rect(origin: Point(x: px(float32(editor.origin.x)), y: px(24)),
      size: Size(width: px(2), height: px(max(0'f32, viewportHeight - 46'f32 - bottomDockHeight)))))
  if getEnv("NIMCULUS_UI_GALLERY", "") == "1":
    # Keep the M2 renderer gallery available for explicit visual inspection,
    # but do not let placeholder paint kinds obscure the normal editor.
    paint.drawShadow(panel.offset(px(4), px(6)))
    paint.drawRoundedRectangle(panel, px(12))
    paint.drawBorder(panel)
    paint.drawRoundedRectangle(toolbar, px(8))
    paint.drawBorder(toolbar)
    paint.drawText(Rect(origin: Point(x: px(margin * 2 + 16), y: px(margin * 2 + 18)),
      size: Size(width: px(150), height: px(22))), "Nimculus")
    paint.drawImage(Rect(origin: Point(x: px(viewportWidth - margin * 3 - 24), y: px(margin * 2 + 16)),
      size: Size(width: px(24), height: px(24))), imageId = 1)
    paint.pushTransform(translationTransform(px(6), px(6)))
    paint.drawRectangle(Rect(origin: Point(x: px(margin * 2 + 260), y: px(margin * 2 + 16)),
      size: Size(width: px(12), height: px(12))))
    paint.popTransform()
    paint.drawSelection(Rect(origin: Point(x: px(72), y: px(145)),
      size: Size(width: px(220), height: px(24))))
    paint.pushClip(editor)
    paint.drawRectangle(editor)
    paint.drawRectangle(splitBar)
    paint.drawCaret(Rect(origin: Point(x: px(74), y: px(176)),
      size: Size(width: px(2), height: px(20))))
    paint.popClip()
  elif hasDocument:
    paint.drawBorder(editor)
  if hasDocument:
    drawCurrentEditorScrollbars(paint, primaryEditor, secondaryEditor,
      document[].buffer.lineStarts.len, document)
  var nativeCommands = newSeq[NativePaintCommand](paint.commands.len)
  for index, command in paint.commands:
    nativeCommands[index] = NativePaintCommand(
      kind: uint32(ord(command.kind)),
      x: cfloat(float32(command.bounds.origin.x)),
      y: cfloat(float32(command.bounds.origin.y)),
      width: cfloat(float32(command.bounds.size.width)),
      height: cfloat(float32(command.bounds.size.height)),
      clipX: cfloat(float32(command.clip.origin.x)),
      clipY: cfloat(float32(command.clip.origin.y)),
      clipWidth: cfloat(float32(command.clip.size.width)),
      clipHeight: cfloat(float32(command.clip.size.height)),
      radius: cfloat(float32(command.radius)),
      sourceX: cfloat(float32(command.sourceBounds.origin.x)),
      sourceY: cfloat(float32(command.sourceBounds.origin.y)),
      sourceWidth: cfloat(float32(command.sourceBounds.size.width)),
      sourceHeight: cfloat(float32(command.sourceBounds.size.height)),
      transformA: cfloat(command.transform.a),
      transformB: cfloat(command.transform.b),
      transformC: cfloat(command.transform.c),
      transformD: cfloat(command.transform.d),
      transformTx: cfloat(command.transform.tx),
      transformTy: cfloat(command.transform.ty),
      imageId: command.imageId)
  if nativeCommands.len > 0:
    platformSetPaintCommands(addr nativeCommands[0], uint32(nativeCommands.len))
  else:
    platformSetPaintCommands(nil, 0)
  var nativeDirty = newSeq[NativePaintRegion](paint.dirty.len)
  for index, dirty in paint.dirty:
    nativeDirty[index] = NativePaintRegion(
      x: cfloat(float32(dirty.origin.x)),
      y: cfloat(float32(dirty.origin.y)),
      width: cfloat(float32(dirty.size.width)),
      height: cfloat(float32(dirty.size.height)))
  if nativeDirty.len > 0:
    platformSetPaintDirtyRegions(addr nativeDirty[0], uint32(nativeDirty.len))
  else:
    platformSetPaintDirtyRegions(nil, 0)
  platformSetUiRectangle(float32(bounds.origin.x), float32(bounds.origin.y),
                         float32(bounds.size.width), float32(bounds.size.height))
  platformSetEditorRect(float64(float32(primaryEditor.origin.x)), float64(float32(primaryEditor.origin.y)),
                        float64(float32(primaryEditor.size.width)), float64(float32(
                            primaryEditor.size.height)))
  when defined(macosx):
    platformSetEditorSidebarVisible(editorWorkspaceUi.leftDock.isOpen and sidebarCanPresent)
    platformSetEditorSidebarOnRight(MacProjectDockOnRight)
    platformSetTerminalPanelRect(float64(float32(demoBottomDockBounds.origin.x)),
      float64(float32(demoBottomDockBounds.origin.y)),
      float64(float32(demoBottomDockBounds.size.width)),
      float64(float32(demoBottomDockBounds.size.height)))
    platformSetSecondaryEditorRect(demoSplitEnabled,
      float64(float32(secondaryEditor.origin.x)), float64(float32(secondaryEditor.origin.y)),
      float64(float32(secondaryEditor.size.width)), float64(float32(secondaryEditor.size.height)))

proc receiveNativeCommand(command: cstring) {.cdecl.}
proc receiveNativeFile(path: cstring, saving: bool) {.cdecl.}
when defined(macosx):
  proc navigateToDefinition()
  proc applyPendingFormatting()

proc dispatchNativeShortcut(event: ptr NimculusInputEvent): bool {.cdecl.} =
  if event == nil: return false
  when defined(macosx):
    if handleCompletionShortcut(event): return true
  var modifiers = event.modifiers
  when defined(windows):
    # Windows standard editing shortcuts use Ctrl where macOS uses Command.
    # Keep the registry's platform-neutral command bindings usable on Win32.
    if (modifiers and (1'u32 shl 18)) != 0:
      modifiers = (modifiers or (1'u32 shl 20)) and not (1'u32 shl 18)
  shortcutRegistry.dispatchShortcut(Shortcut(
    keyCode: event.keyCode,
    modifiers: macOSModifiers(modifiers)))

proc nativeShortcutAction(name: string): proc() {.closure.} =
  result = proc() = receiveNativeCommand(name.cstring)

proc setupShortcutRegistry() =
  shortcutRegistry = CommandRegistry()
  shortcutRegistry.register(Command(
    name: "commandPalette",
    shortcut: Shortcut(keyCode: 35, modifiers: {commandModifier, shiftModifier}),
    action: proc() = platformShowCommandPalette()))
  shortcutRegistry.register(Command(
    name: "workspaceSearch",
    shortcut: Shortcut(keyCode: 3, modifiers: {commandModifier, shiftModifier}),
    action: proc() = platformShowWorkspaceSearch()))
  # Match Zed's macOS workspace entry points. These forward through the same
  # palette dispatch used by the activity bar, keeping keyboard and pointer
  # navigation on one panel-state path.
  shortcutRegistry.register(Command(
    name: "toggleFiles",
    shortcut: Shortcut(keyCode: 14, modifiers: {commandModifier, shiftModifier}),
    action: nativeShortcutAction("commandPalette:toggle files")))
  shortcutRegistry.register(Command(
    name: "toggleOutline",
    shortcut: Shortcut(keyCode: 11, modifiers: {commandModifier, shiftModifier}),
    action: nativeShortcutAction("commandPalette:toggle outline")))
  shortcutRegistry.register(Command(
    name: "expandSyntaxSelection",
    shortcut: Shortcut(keyCode: 124, modifiers: {commandModifier, controlModifier}),
    action: nativeShortcutAction("expandSelection")))
  shortcutRegistry.register(Command(
    name: "shrinkSyntaxSelection",
    shortcut: Shortcut(keyCode: 123, modifiers: {commandModifier, controlModifier}),
    action: nativeShortcutAction("shrinkSelection")))
  shortcutRegistry.register(Command(
    name: "selectPreviousSyntaxNode",
    shortcut: Shortcut(keyCode: 126, modifiers: {commandModifier, controlModifier}),
    action: nativeShortcutAction("selectPreviousSyntaxNode")))
  shortcutRegistry.register(Command(
    name: "selectNextSyntaxNode",
    shortcut: Shortcut(keyCode: 125, modifiers: {commandModifier, controlModifier}),
    action: nativeShortcutAction("selectNextSyntaxNode")))
  shortcutRegistry.register(Command(
    name: "moveToEnclosingBracket",
    shortcut: Shortcut(keyCode: 42, modifiers: {commandModifier, shiftModifier}),
    action: nativeShortcutAction("moveToEnclosingBracket")))
  shortcutRegistry.register(Command(
    name: "moveToEnclosingBracketControlM",
    shortcut: Shortcut(keyCode: 46, modifiers: {controlModifier}),
    action: nativeShortcutAction("moveToEnclosingBracket")))
  # Zed's macOS fold bindings are Option-Cmd-[ / ]. Keep the same physical
  # keys while routing the action through the document-owned fold map.
  shortcutRegistry.register(Command(
    name: "fold",
    shortcut: Shortcut(keyCode: 33, modifiers: {commandModifier, optionModifier}),
    action: nativeShortcutAction("fold")))
  shortcutRegistry.register(Command(
    name: "unfold",
    shortcut: Shortcut(keyCode: 30, modifiers: {commandModifier, optionModifier}),
    action: nativeShortcutAction("unfold")))
  shortcutRegistry.register(Command(
    name: "toggleGit",
    shortcut: Shortcut(keyCode: 5, modifiers: {controlModifier, shiftModifier}),
    action: nativeShortcutAction("commandPalette:toggle git")))
  shortcutRegistry.register(Command(
    name: "toggleTerminal",
    shortcut: Shortcut(keyCode: 50, modifiers: {controlModifier}),
    action: nativeShortcutAction("commandPalette:toggle terminal")))
  # Zed's multi-selection entry points: Cmd+D selects the next match,
  # Cmd+Shift+L selects all matches, and Option+Shift+Up/Down add a caret in
  # the adjacent logical line.
  shortcutRegistry.register(Command(
    name: "selectNext",
    shortcut: Shortcut(keyCode: 2, modifiers: {commandModifier}),
    action: nativeShortcutAction("selectNext")))
  shortcutRegistry.register(Command(
    name: "selectAllMatches",
    shortcut: Shortcut(keyCode: 37, modifiers: {commandModifier, shiftModifier}),
    action: nativeShortcutAction("selectAllMatches")))
  shortcutRegistry.register(Command(
    name: "addSelectionAbove",
    shortcut: Shortcut(keyCode: 126, modifiers: {optionModifier, shiftModifier}),
    action: nativeShortcutAction("addSelectionAbove")))
  shortcutRegistry.register(Command(
    name: "addSelectionBelow",
    shortcut: Shortcut(keyCode: 125, modifiers: {optionModifier, shiftModifier}),
    action: nativeShortcutAction("addSelectionBelow")))
  # Keep all commands addressable from settings keymaps. They have no default
  # shortcut here when AppKit owns the standard menu equivalent; custom
  # bindings are installed below and are resolved before interpretKeyEvents.
  for name in [
      # Application and menu commands.
    "save", "newDocument", "closeTabRequest", "reopenClosedTab", "openSettings", "splitEditor",
      "splitEditorHorizontal", "closeSplit", "undo", "redo",
      "cut", "copy", "paste", "selectAll", "previousTab", "nextTab",
      # AppKit NSText movement/editing selectors. Keeping these names at the
        # application boundary lets settings override Command/Option behavior
        # without leaking Cocoa types into the editor core.
      "moveLeft", "moveRight", "moveUp", "moveDown",
      "selectLeft", "selectRight", "selectUp", "selectDown",
      "moveToBeginningOfLine", "moveToEndOfLine",
      "selectToBeginningOfLine", "selectToEndOfLine",
      "moveToBeginningOfDocument", "moveToEndOfDocument",
      "selectToBeginningOfDocument", "selectToEndOfDocument",
      "insertNewline", "insertTab", "moveWordLeft", "moveWordRight",
      "selectWordLeft", "selectWordRight", "deleteBackward", "deleteForward",
      "deleteWordBackward", "deleteWordForward", "deleteToBeginningOfLine",
      "deleteToEndOfLine", "cancel", "toggleSoftWrap", "selectNext",
      "selectAllMatches", "addSelectionAbove", "addSelectionBelow",
      "selectPreviousSyntaxNode", "selectNextSyntaxNode",
      "moveToEnclosingBracket", "fold", "unfold", "toggleFold", "foldAll",
      "unfoldAll", "foldRecursive", "unfoldRecursive", "toggleFoldRecursive",
      "foldAtLevel1", "foldAtLevel2", "foldAtLevel3", "foldAtLevel4",
      "foldAtLevel5", "foldAtLevel6", "foldAtLevel7", "foldAtLevel8",
      "foldAtLevel9"]:
    var action: proc() {.closure.}
    if name == "openSettings":
      when defined(macosx):
        action = proc() = receiveNativeCommand("openSettingsUI".cstring)
      else:
        action = nativeShortcutAction(name)
    else:
      action = nativeShortcutAction(name)
    shortcutRegistry.register(Command(name: name, action: action))

proc applySettingsKeymap() =
  when defined(macosx) or defined(windows):
    if appSettings == nil: return
    # Rebuild from defaults so removing a binding on disk also removes the
    # previous live binding, matching Zed's keymap reload semantics.
    setupShortcutRegistry()
    for binding in appSettings.keyBindings():
      let shortcut = shortcutFromKeyBinding(binding.key)
      if shortcut.keyCode == 0: continue
      for index in 0 ..< shortcutRegistry.commands.len:
        if shortcutRegistry.commands[index].name == binding.command:
          shortcutRegistry.commands[index].shortcut = shortcut

when defined(macosx):
  proc resizeNativeTerminals()

proc applySettingsTheme() =
  when defined(macosx) or defined(windows):
    if appSettings == nil: return
    when defined(windows):
      platformSetEditorFontSize(cdouble(appSettings.intSetting("editor.fontSize", 14)))
      platformSetEditorFontName(appSettings.stringSetting("editor.fontFamily", "Consolas").cstring)
      platformSetTerminalFontSize(cdouble(appSettings.intSetting("terminal.fontSize", 12)))
      platformSetTerminalFontName(appSettings.stringSetting("terminal.fontFamily",
          "Consolas").cstring)
    elif defined(macosx):
      let colors = appSettings.resolvedTheme(platformIsDarkAppearance())
      platformSetEditorFontSize(cdouble(appSettings.intSetting("editor.fontSize", 14)))
      platformSetEditorFontName(appSettings.stringSetting("editor.fontFamily", "Menlo").cstring)
      platformSetTerminalFontSize(cdouble(appSettings.intSetting("terminal.fontSize", 12)))
      platformSetTerminalFontName(appSettings.stringSetting("terminal.fontFamily", "Menlo").cstring)
      resizeNativeTerminals()
      platformSetThemePaletteJson(themePaletteJson(colors).cstring)

var imeState = newImeState()
var editorSession: EditorSession
var editorViewState = newEditorView()
var syntaxState: EditorSyntaxState
when defined(macosx):
  var secondarySyntaxState: EditorSyntaxState

proc syncWorkspaceUiTabs() =
  editorWorkspaceUi.syncRootTabs(editorSession.tabs.len, editorSession.activeTab)
  # With one editor pane, EditorSession.activeTab is the canonical focused
  # document. Keep the pane-owned tab selection synchronized at this
  # composition boundary as well. Startup file arguments and Finder/Open With
  # callbacks can add or activate a tab after the workspace tree was restored;
  # leaving the old pane index valid would highlight a different tab from the
  # document rendered in the editor (the exact mismatch users see in Zed-like
  # tab surfaces).
  if not editorSession.split and editorWorkspaceUi.center != nil:
    discard editorWorkspaceUi.selectPaneTab(editorWorkspaceUi.center.firstPane().id,
      editorSession.activeTab)
var activeWorkspace: Workspace
var workspaceSearchJob: SearchJob
var workspaceQuickOpenJob: FuzzySearchJob
var workspaceSearchQuery = ""
var workspaceSearchScope = ""
var workspaceSearchResults: seq[SearchResult]
var workspaceSearchCancelled = false
var workspaceQuickOpenQuery = ""
var workspaceQuickOpenOpenPending = false
var workspacePreviewEntries: seq[WorkspaceEntry]
var workspaceExpandedDirectories: seq[string]
var workspacePreviewMode = ""
var workspaceRevealPath = ""
when defined(macosx):
  # Project Panel copy/cut state is intentionally separate from the editor
  # text clipboard. Zed keeps filesystem entries and document text in
  # different transfer paths so Cmd+V in Files never inserts a path into the
  # active buffer.
  var workspaceClipboardPath = ""
  var workspaceClipboardCut = false
type EditorSidebarMode = enum
  sidebarOutline, sidebarFiles, sidebarGitHistory, sidebarGitStatus, sidebarGitBranches,
  sidebarWorkspaceSearch, sidebarDebugger

type GitStatusProjection = enum
  ## A partial file is intentionally rendered in both sections. Preserve this
  ## projection so user actions never have to guess which half was targeted.
  gitStatusConflict, gitStatusStaged, gitStatusUnstaged

var editorSidebarMode = sidebarFiles

proc focusedEditorView(): EditorViewState
proc storeFocusedEditorView(view: EditorViewState)

proc workspacePanelForSidebarMode(mode: EditorSidebarMode): PanelKind =
  case mode
  of sidebarFiles: panelFiles
  of sidebarGitHistory, sidebarGitStatus, sidebarGitBranches: panelGit
  of sidebarOutline: panelOutline
  of sidebarWorkspaceSearch: panelSearch
  of sidebarDebugger: panelDebugger

when defined(macosx):
  proc syncNativeSidebarSelection() =
    let index = editorWorkspaceUi.panelSelectedIndex(
      workspacePanelForSidebarMode(editorSidebarMode))
    platformSetEditorSidebarSelection(if index < 0: uint32.high else: uint32(index))
var externalAlertShown = false
var externalAlertTab = -1
var editorPointerDragging = false
var editorPointerPane = 0
var editorScrollRemainder = 0'f32
var editorSecondaryScrollRemainder = 0'f32
var sessionFilePath = ""
var recoveryFilePath = ""
var crashReportPath = ""
var settingsFilePath = ""
var sessionPersistence: PersistenceSchedule
var workspaceMaintenance: PollSchedule
var lastNativeEditorStatus = ""
var suppressRecoveryWrite = false
var discardDirtyOnExit = false
when defined(macosx):
  var lspBridge: LspEditorBridge
  var editorGitDiffJob: GitJob
  var editorSecondaryGitDiffJob: GitJob
  var editorGitStatusJob: GitJob
  var editorGitBranchJob: GitJob
  var editorGitStatusRepository: GitRepository
  var editorGitBranchRepository: GitRepository
  var editorGitStatusDocumentPath = ""
  var editorGitActionJob: GitJob
  var editorGitAction = ""
  var editorGitActionPhase = ""
  var editorGitActionDocumentPath = ""
  var editorGitActionPath = ""
  var editorGitActionSource = ""
  var editorGitActionLine = -1
  var editorGitRepository: GitRepository
  var editorGitPath = ""
  var editorSecondaryGitPath = ""
  var editorGitHistory: seq[GitCommit]
  var editorGitHistoryPath = ""
  # Keep the porcelain result separately from the rendered rows. A partially
  # staged path renders once under Staged and once under Unstaged, but a later
  # branch-name repaint must never treat those two rows as two Git entries.
  var editorGitStatusSourceEntries: seq[GitStatusEntry]
  var editorGitStatusEntries: seq[GitStatusEntry]
  var editorGitStatusProjections: seq[GitStatusProjection]
  var editorGitPanelBranch = ""
  var editorGitStatusGeneration = 0'u64
  var editorGitEntriesGeneration = 0'u64
  var editorGitBranchGeneration = 0'u64
  var editorGitBranches: seq[GitBranch]
  var editorTaskJob: TaskJob
  var editorTaskCommand = ""
  var editorTaskOutput = ""
  var editorTaskProblems: seq[TaskProblem]
  var editorTerminal: TerminalPty
  var editorTerminals: seq[TerminalPty]
  var editorTerminalIndex = -1
  var editorTerminalFocused = false
  var editorTerminalSelection = TerminalSelection()
  var editorTerminalSelecting = false
  var editorTerminalScrollOffset = 0
  var editorTerminalScrollRemainder = 0'f32
  var editorUpdateJob: UpdateDownloadJob
  var editorUpdatePath = ""
  var editorDapSession: DapSession
  var editorDapOutput = ""
  var editorDapInitialized = false
  var editorDapThreadId = -1
  var editorDapFrameId = -1
  var editorDapBreakpointLines: seq[int]
  var editorDapAttachPid = -1
  var editorDapTerminalJobs: seq[TaskJob]
  var editorDapWatchExpressions: seq[string]
  type
    DapChildSession = ref object
      id: int
      session: DapSession
      requestKind: string
      configuration: JsonNode
      initialized: bool

    DapSidebarItemKind = enum
      dapThreadItem
      dapFrameItem
      dapScopeItem
      dapVariableItem
      dapWatchItem

    DapSidebarItem = object
      kind: DapSidebarItemKind
      id: int
      reference: int

    DapThreadInfo = object
      id: int
      name: string

    DapFrameInfo = object
      id: int
      name: string
      source: string
      line: int

    DapScopeInfo = object
      name: string
      reference: int

    DapVariableInfo = object
      name: string
      value: string
      reference: int
      depth: int

  var editorDapChildSessions: seq[DapChildSession]
  var editorDapNextChildId = 1
  var editorDapThreads: seq[DapThreadInfo]
  var editorDapFrames: seq[DapFrameInfo]
  var editorDapScopes: seq[DapScopeInfo]
  var editorDapVariables: seq[DapVariableInfo]
  var editorDapWatchLines: seq[string]
  var editorDapVariableRootReference = 0
  var editorDapVariableRequestReference = 0
  var editorDapExpandedVariableReferences: seq[int]
  var editorDapSidebarItems: seq[DapSidebarItem]
  var editorAgentManager: AgentManager
  var editorAgentOutput = ""
  var editorAgentSessionId = -1
  var editorExtensionRegistry: ExtensionRegistry
  var pendingExtensionPermission: ExtensionManifest
  var pendingExtensionPermissionAction = ""
  var pendingExtensionPermissionSource = ""
  var editorExtensionCatalog: seq[ExtensionCatalogEntry]
  var editorExtensionCatalogSync = false
  var editorExtensionPackageJob: UpdateDownloadJob
  var editorExtensionPackageEntry: ExtensionCatalogEntry
  var editorExtensionPackagePath = ""

proc resetEditorTransientState() =
  ## Tab switches must preserve their cursor/selection/viewport. Only reset
  ## interaction and derived UI state which is not owned by an EditorTab.
  editorScrollRemainder = 0'f32
  editorSecondaryScrollRemainder = 0'f32
  when defined(macosx):
    pendingLspSymbols.setLen(0)
    pendingLspSymbolDepths.setLen(0)
    updateSyntaxOutline(activeDocument())

proc resetEditorViewState() =
  editorViewState = newEditorView()
  resetEditorTransientState()

proc widestVisibleEditorLineWidth(buffer: PieceTable, view: EditorViewState,
                                  visibleLines: int): float32 =
  ## The native shaper remains the authority for glyph placement. This compact
  ## estimate is only scrollbar geometry and follows the editor's monospace
  ## metrics closely enough to keep the thumb stable while scrolling.
  let lines = buffer.toString.splitLines
  if lines.len == 0: return 0'f32
  let first = min(max(0, view.scrollLine), lines.high)
  let last = min(lines.high, first + max(1, visibleLines) + 1)
  for index in first .. last:
    var columns = 0
    for rune in lines[index].runes:
      columns += (if rune == Rune('\t'): 4 else: 1)
    result = max(result, float32(columns) * 7.2'f32)

proc addEditorScrollbars(paint: var PaintList, bounds: Rect, view: EditorViewState,
                         lineCount, visibleLines: int, widestLineWidth: float32) =
  let width = max(0'f32, float32(bounds.size.width))
  let height = max(0'f32, float32(bounds.size.height))
  if lineCount > max(1, visibleLines):
    let trackY = float32(bounds.origin.y) + 6'f32
    let trackHeight = max(0'f32, height - 32'f32)
    let thumbHeight = max(18'f32, trackHeight * float32(visibleLines) /
      float32(max(1, lineCount)))
    let maxScrollPixels = max(1'f32, float32(lineCount - max(1, visibleLines)) * 18'f32)
    let thumbY = trackY + max(0'f32, trackHeight - thumbHeight) *
      min(1'f32, max(0'f32, view.scrollYPixels) / maxScrollPixels)
    paint.drawScrollbar(Rect(origin: Point(x: px(float32(bounds.origin.x) + width - 14'f32),
      y: px(thumbY)), size: Size(width: px(8), height: px(min(trackHeight, thumbHeight)))))
  let viewportWidth = max(0'f32, width - 36'f32)
  if not view.softWrap and widestLineWidth > viewportWidth and viewportWidth > 0'f32:
    let trackWidth = viewportWidth
    let trackX = float32(bounds.origin.x) + 8'f32
    let trackY = float32(bounds.origin.y) + height - 14'f32
    let thumbWidth = max(24'f32, trackWidth * viewportWidth / widestLineWidth)
    let maxScroll = max(1'f32, widestLineWidth - viewportWidth)
    let thumbX = trackX + max(0'f32, trackWidth - thumbWidth) *
      min(1'f32, max(0'f32, view.scrollX) / maxScroll)
    paint.drawScrollbar(Rect(origin: Point(x: px(thumbX), y: px(trackY)),
      size: Size(width: px(min(trackWidth, thumbWidth)), height: px(8))))

proc drawCurrentEditorScrollbars(paint: var PaintList, primary, secondary: Rect,
                                 lineCount: int, document: ptr FileDocument) =
  let primaryVisibleLines = when defined(macosx): editorVisibleLineCount()
    else: max(1, int(ceil(float32(primary.size.height) / 18'f32)))
  addEditorScrollbars(paint, primary, editorViewState, lineCount,
    primaryVisibleLines, when defined(macosx):
      float32(platformEditorWidestVisibleLineWidth())
    else: widestVisibleEditorLineWidth(document[].buffer, editorViewState,
      primaryVisibleLines))
  if demoSplitEnabled:
    let secondaryView = editorSession.secondaryView
    let secondaryVisibleLines = when defined(macosx): secondaryEditorVisibleLineCount()
      else: max(1, int(ceil(float32(secondary.size.height) / 18'f32)))
    addEditorScrollbars(paint, secondary, secondaryView, lineCount,
      secondaryVisibleLines, when defined(macosx):
        float32(platformSecondaryEditorWidestVisibleLineWidth())
      else: widestVisibleEditorLineWidth(document[].buffer, secondaryView,
        secondaryVisibleLines))

proc resetPointerInteractions() =
  demoSplitDragging = false
  editorPointerDragging = false
  editorPointerPane = 0
  if activePointerNode != NodeId(0):
    demoTree.setActive(activePointerNode, false)
    activePointerNode = NodeId(0)
  for node in demoTree.nodes:
    if node.hoveredState: demoTree.setHovered(node.id, false)

proc resetImeState() =
  imeState = newImeState()
  when defined(macosx):
    platformClearEditorComposition()

proc activeEditorCursor(): int
proc activeEditorSelection(): tuple[startByte, endByte: int]
proc moveActiveEditorCursor(offset: int, selecting = false)
proc refreshWorkspacePreview()
proc refreshEditorSyntax()
proc refreshDocumentLanguageSettings()

when defined(macosx):
  proc refreshSecondaryEditorSyntax()
  proc scheduleNativeGitHunks(document: ptr FileDocument)
  proc scheduleNativeSecondaryGitHunks(document: ptr FileDocument)

  proc editorContextText(document: ptr FileDocument): string =
    ## Keep the compact native header meaningful even when several similarly
    ## named tabs are open. Workspace-relative breadcrumbs avoid leaking an
    ## unreadable absolute path into the editor chrome.
    if document == nil:
      return ""
    if document[].path.len == 0:
      return editorSession.displayTitle(editorSession.activeTab)
    if activeWorkspace != nil:
      try:
        let location = activeWorkspace.splitWorkspacePath(document[].path)
        let root = location.root.extractFilename
        let relative = location.relative.replace("/", " › ")
        return if root.len > 0 and relative.len > 0: root & " › " & relative
          elif relative.len > 0: relative
          else: root
      except CatchableError:
        discard
    document[].path

  proc gitRepositoryForDocument(document: ptr FileDocument): GitRepository =
    # Zed's Git panel is owned by a workspace repository, not by an editor
    # buffer. An untitled editor (or no editor at all) must still be able to
    # show a workspace's history/status. For a concrete document, keep its
    # own worktree authoritative, including files restored outside the roots.
    if document == nil or document[].path.len == 0:
      if activeWorkspace != nil:
        return firstRepositoryForPaths(activeWorkspace.rootPaths)
      return nil
    if activeWorkspace != nil:
      try:
        let location = activeWorkspace.splitWorkspacePath(document[].path)
        return newGitRepository(location.root)
      except CatchableError:
        discard
    repositoryForPath(document[].path)

  proc gitRelativePathForDocument(document: ptr FileDocument,
                                  repository: GitRepository): string =
    if document == nil or repository == nil or document[].path.len == 0: return ""
    if activeWorkspace != nil:
      try:
        let location = activeWorkspace.splitWorkspacePath(document[].path)
        result = location.relative
        return
      except CatchableError:
        discard
    let absoluteDocumentPath = absolutePath(document[].path)
    let prefix = repository.root & DirSep
    if absoluteDocumentPath.startsWith(prefix):
      result = absoluteDocumentPath[prefix.len .. ^1]

  proc showNativeLspPanel(title: string, lines: seq[string])
  proc taskWorkingDirectory(document: ptr FileDocument): string

  proc appendNativeAgentOutput(chunk: string) =
    if chunk.len == 0: return
    let bounded = appendBoundedAgentOutput(editorAgentOutput, chunk)
    editorAgentOutput = bounded.output
    platformSetTaskOutputTitle("Agent".cstring, uint32("Agent".len))
    platformSetTaskOutputText(editorAgentOutput.cstring, uint32(editorAgentOutput.len))

  proc activeNativeAgent(): AgentSession =
    if editorAgentManager == nil: return nil
    editorAgentManager.active()

  proc stopNativeAgent() =
    let session = activeNativeAgent()
    if session == nil:
      editorViewState.statusMessage = "Agent: no active session"
      return
    discard editorAgentManager.stop(session.id)
    editorAgentSessionId = -1
    editorViewState.statusMessage = "Agent stopped"

  proc startNativeAgent(worktreePath = "", providerValue = "") =
    let configuredCommand = getEnv("NIMCULUS_AGENT_COMMAND", "").strip
    let configuredProvider = if providerValue.strip.len > 0: providerValue else:
      getEnv("NIMCULUS_AGENT_PROVIDER", "")
    let configuredArgs = getEnv("NIMCULUS_AGENT_ARGS", "").splitWhitespace
    let launch = resolveAgentLaunchSpec(configuredProvider, configuredCommand,
      configuredArgs)
    if launch.command.len == 0:
      let requested = if configuredProvider.strip.len > 0:
        " for " & configuredProvider.strip else: ""
      editorViewState.statusMessage = "Agent unavailable" & requested &
        ": install Codex CLI, Claude Code, or OpenCode, or set NIMCULUS_AGENT_COMMAND"
      return
    if editorAgentManager == nil: editorAgentManager = newAgentManager()
    let document = activeDocument()
    try:
      let session = editorAgentManager.start(launch.command, launch.args,
        taskWorkingDirectory(document), if worktreePath.len > 0: worktreePath
          else: getEnv("NIMCULUS_AGENT_WORKTREE", ""))
      editorAgentSessionId = session.id
      editorAgentOutput = launch.displayName & " session #" & $session.id &
        " started\n"
      editorTaskOutputVisible = true
      editorTerminalVisible = false
      platformSetTerminalVisible(false)
      platformSetTaskOutputVisible(true)
      platformSetTaskOutputCancellable(true)
      editorWorkspaceUi.openPanel(panelTasks)
      setupDemoUi()
      platformSetTaskOutputTitle("Agent".cstring, uint32("Agent".len))
      platformSetTaskOutputText(editorAgentOutput.cstring, uint32(editorAgentOutput.len))
      editorViewState.statusMessage = launch.displayName &
        " running — use `agent send <prompt>`"
    except CatchableError as error:
      editorViewState.statusMessage = "Agent failed: " & error.msg

  proc sendNativeAgentPrompt(prompt: string) =
    let session = activeNativeAgent()
    if session == nil or not session.isRunning:
      editorViewState.statusMessage = "Agent is not running"
      return
    if prompt.strip.len == 0:
      editorViewState.statusMessage = "Agent prompt is empty"
      return
    try:
      session.sendPrompt(prompt)
      appendNativeAgentOutput("→ " & prompt.strip & "\n")
      editorViewState.statusMessage = "Agent prompt sent"
    except CatchableError as error:
      editorViewState.statusMessage = "Agent input failed: " & error.msg

  proc showNativeAgentDiff() =
    let session = activeNativeAgent()
    if session == nil:
      editorViewState.statusMessage = "Agent: no active session"
      return
    try:
      let diff = session.currentDiff()
      showNativeLspPanel("Agent — Review Changes", if diff.len == 0:
        @[("No changes in " & session.worktreePath)] else: diff.splitLines)
      editorViewState.statusMessage = if diff.len == 0: "Agent: no changes" else:
        "Agent changes ready for review"
    except CatchableError as error:
      editorViewState.statusMessage = "Agent diff failed: " & error.msg

  proc rejectNativeAgentChanges() =
    let session = activeNativeAgent()
    if session == nil:
      editorViewState.statusMessage = "Agent: no active session"
      return
    if session.rejectChanges():
      refreshWorkspacePreview()
      editorViewState.statusMessage = "Agent changes rejected"
    else:
      editorViewState.statusMessage = "Agent changes could not be rejected"

  proc approveNativeAgentChanges() =
    let session = activeNativeAgent()
    if session == nil:
      editorViewState.statusMessage = "Agent: no active session"
      return
    discard session.refreshChanges()
    editorViewState.statusMessage = "Agent changes approved"

  proc applyNativeAgentPatch() =
    let session = activeNativeAgent()
    let patch = getEnv("NIMCULUS_AGENT_PATCH", "")
    if session == nil:
      editorViewState.statusMessage = "Agent: no active session"
    elif patch.len == 0:
      editorViewState.statusMessage = "Agent patch unavailable: set NIMCULUS_AGENT_PATCH"
    elif session.applyPatch(patch):
      refreshWorkspacePreview()
      editorViewState.statusMessage = "Agent patch applied"
    else:
      editorViewState.statusMessage = "Agent patch rejected by Git"

  proc pollNativeAgent() =
    let session = activeNativeAgent()
    if session == nil: return
    let pollResult = session.poll()
    if pollResult.output.len > 0: appendNativeAgentOutput(pollResult.output)
    if pollResult.changedPaths.len > 0:
      refreshWorkspacePreview()
      editorViewState.statusMessage = "Agent changed " &
        $pollResult.changedPaths.len & " file(s) — review the diff"
    if pollResult.done:
      editorAgentSessionId = -1
      platformSetTaskOutputCancellable(false)
      editorViewState.statusMessage = "Agent " & $session.state &
        " (exit " & $pollResult.exitCode & ")"

  proc switchNativeAgent(delta: int) =
    if editorAgentManager == nil or not editorAgentManager.activateRelative(delta):
      editorViewState.statusMessage = "Agent: no other session"
      return
    let session = activeNativeAgent()
    editorAgentSessionId = session.id
    editorAgentOutput = session.retainedOutput
    platformSetTaskOutputTitle(("Agent #" & $session.id).cstring,
      uint32(("Agent #" & $session.id).len))
    platformSetTaskOutputText(editorAgentOutput.cstring, uint32(editorAgentOutput.len))
    editorViewState.statusMessage = "Agent session #" & $session.id & " active"

  proc reloadNativeExtensions() =
    if editorExtensionRegistry == nil:
      editorExtensionRegistry = newExtensionRegistry()
    editorExtensionRegistry.clear()
    let discovered = editorExtensionRegistry.discover()
    editorViewState.statusMessage = "Extensions reloaded: " & $discovered

  proc showNativeExtensions()
  proc requestNativeExtensionPermission(manifest: ExtensionManifest,
                                        action, source: string): bool

  proc showNativeExtensionCatalog() =
    var lines = @[
      "Extension Catalog",
      "──────────────────"
    ]
    if editorExtensionCatalog.len == 0:
      lines.add("No catalog entries. Set NIMCULUS_EXTENSION_CATALOG and sync.")
    else:
      lines.add("Install with: extensions install <id>")
      for entry in editorExtensionCatalog:
        lines.add(entry.id & " " & entry.version & " — " & entry.name)
        lines.add("  archive: " & entry.archiveUrl)
        lines.add("  SHA-256: " & entry.sha256)
    showNativeLspPanel("Extension Catalog", lines)

  proc syncNativeExtensionCatalog() =
    let url = getEnv("NIMCULUS_EXTENSION_CATALOG", "").strip
    if not isSecureExtensionCatalogUrl(url):
      editorViewState.statusMessage =
        "Extension catalog requires NIMCULUS_EXTENSION_CATALOG=https://…"
      return
    if editorTaskJob != nil and not editorTaskJob.done:
      editorTaskJob.cancel()
    editorTaskCommand = "Extension catalog"
    editorTaskOutput = ""
    editorTaskProblems.setLen(0)
    editorExtensionCatalogSync = true
    editorTaskOutputVisible = true
    platformSetTaskOutputVisible(true)
    platformSetTaskOutputCancellable(true)
    editorWorkspaceUi.openPanel(panelTasks)
    setupDemoUi()
    let title = "Extension Catalog"
    platformSetTaskOutputTitle(title.cstring, uint32(title.len))
    editorTaskJob = startTask(TaskSpec(command: "curl", args: @[
      "--fail", "--location", "--silent", "--show-error",
      "--proto", "=https", "--tlsv1.2", "--max-time", "20",
      "--max-filesize", $MaxExtensionCatalogBytes, url]))
    editorViewState.statusMessage = "Syncing extension catalog"

  proc installNativeCatalogExtension(id: string) =
    let entry = findCatalogEntry(editorExtensionCatalog, id)
    if entry.id.len == 0:
      editorViewState.statusMessage = "Catalog extension not found: " & id
      return
    if editorExtensionPackageJob != nil and not editorExtensionPackageJob.done:
      editorViewState.statusMessage = "Another catalog package is downloading"
      return
    let packagePath = getTempDir() / ("nimculus-extension-" & entry.id & ".zip")
    editorExtensionPackageEntry = entry
    editorExtensionPackagePath = packagePath
    editorExtensionPackageJob = startUpdateDownload(
      UpdateRelease(version: entry.version, url: entry.archiveUrl,
        sha256: entry.sha256), packagePath)
    if editorExtensionPackageJob.done:
      editorExtensionPackageJob = nil
      editorViewState.statusMessage = "Catalog package download could not start"
    else:
      editorViewState.statusMessage = "Downloading extension: " & entry.name

  proc installNativeCatalogExtensionNow(archivePath: string) =
    let installRoot = getHomeDir() / ".nimculus" / "extensions"
    if editorExtensionRegistry == nil:
      editorExtensionRegistry = newExtensionRegistry([installRoot])
    try:
      let manifest = editorExtensionRegistry.installCatalogArchive(archivePath,
        installRoot)
      if fileExists(archivePath): removeFile(archivePath)
      editorViewState.statusMessage = "Installed catalog extension: " & manifest.name
      showNativeExtensions()
    except CatchableError as error:
      editorViewState.statusMessage = "Catalog extension install failed: " & error.msg

  proc pollNativeExtensionPackage() =
    if editorExtensionPackageJob == nil: return
    let partialPath = editorExtensionPackagePath & ".part"
    if fileExists(partialPath) and
        getFileSize(partialPath) > MaxExtensionPackageBytes:
      editorExtensionPackageJob.cancelUpdateDownload()
      editorExtensionPackageJob = nil
      editorViewState.statusMessage = "Extension package exceeds the size limit"
      return
    if not editorExtensionPackageJob.pollUpdateDownload(): return
    let archivePath = editorExtensionPackagePath
    let entry = editorExtensionPackageEntry
    let success = editorExtensionPackageJob.success
    editorExtensionPackageJob = nil
    if not success:
      editorViewState.statusMessage = "Extension download failed: " & entry.id
      return
    try:
      let manifest = inspectCatalogArchive(archivePath)
      if not requestNativeExtensionPermission(manifest, "catalog-install", archivePath):
        return
      installNativeCatalogExtensionNow(archivePath)
    except CatchableError as error:
      if fileExists(archivePath): removeFile(archivePath)
      editorViewState.statusMessage = "Catalog package rejected: " & error.msg

  proc requestNativeExtensionPermission(manifest: ExtensionManifest,
                                        action, source: string): bool =
    ## Permission is a user action, not a hidden side effect of starting a
    ## Component. The AppKit sheet is asynchronous so it cannot freeze the
    ## editor or create the modal-loop failures seen with unsaved dialogs.
    var requested: seq[string]
    for permission in manifest.extensionPermissionList:
      if permission.extensionPermissionRequiresPrompt:
        requested.add(permission & " — " &
          permission.extensionPermissionDescription)
    if requested.len == 0: return true
    pendingExtensionPermission = manifest
    pendingExtensionPermissionAction = action
    pendingExtensionPermissionSource = source
    let details = "Extension: " & manifest.name & " (API v" &
      $manifest.apiVersion & ")\n\nRequested capabilities:\n  " &
      requested.join("\n  ") & "\n\nGranted by host API v" &
      $SupportedExtensionApiVersion & ": " & manifest.extensionHostCapabilityString
    platformPromptExtensionPermissions(
      ("Allow capabilities for " & manifest.name).cstring, details.cstring)
    editorViewState.statusMessage = "Waiting for extension permission decision"
    false

  proc clearNativeExtensionPermission() =
    pendingExtensionPermission = ExtensionManifest()
    pendingExtensionPermissionAction = ""
    pendingExtensionPermissionSource = ""

  proc installNativeExtensionNow(source: string) =
    let installRoot = getHomeDir() / ".nimculus" / "extensions"
    if editorExtensionRegistry == nil:
      editorExtensionRegistry = newExtensionRegistry([installRoot])
    try:
      let manifest = editorExtensionRegistry.installDirectory(source, installRoot)
      editorViewState.statusMessage = "Installed extension: " & manifest.name
      showNativeExtensions()
    except CatchableError as error:
      editorViewState.statusMessage = "Extension install failed: " & error.msg

  proc installNativeExtension(source: string) =
    try:
      let manifest = loadExtensionManifest(normalizedPath(source) / "extension.json")
      if not requestNativeExtensionPermission(manifest, "install", source): return
      installNativeExtensionNow(source)
    except CatchableError as error:
      editorViewState.statusMessage = "Extension install failed: " & error.msg

  proc startNativeWasmComponent(manifest: ExtensionManifest): bool =
    if editorWasmComponentJob.handle != nil:
      cancelWasmComponentJob(editorWasmComponentJob)
      editorViewState.statusMessage = "WASM component is still cancelling"
      return false
    if editorTaskJob != nil and not editorTaskJob.done:
      editorTaskJob.cancel()
    var startError = ""
    let job = startWasmComponentJob(manifest, startError)
    if job.handle == nil:
      editorViewState.statusMessage = "WASM component failed to start: " &
        (if startError.len > 0: startError else: "unknown error")
      return false
    editorWasmComponentJob = job
    editorWasmComponentId = manifest.id
    editorWasmComponentCancelRequested = false
    editorTaskCommand = "WASM component " & manifest.id
    editorTaskOutput = ""
    editorTaskProblems.setLen(0)
    if editorTerminalVisible:
      editorTerminalVisible = false
      editorTerminalFocused = false
      platformSetTerminalVisible(false)
    editorTaskOutputVisible = true
    platformSetTaskOutputVisible(true)
    platformSetTaskOutputCancellable(true)
    editorWorkspaceUi.openPanel(panelTasks)
    setupDemoUi()
    let title = "WASM Component — " & manifest.name
    platformSetTaskOutputTitle(title.cstring, uint32(title.len))
    editorViewState.statusMessage = "WASM component running: " & manifest.id
    true

  proc startNativeExternalExtension(manifest: ExtensionManifest): bool =
    if manifest.externalProcess.len == 0:
      editorViewState.statusMessage = "Extension has no external process: " & manifest.id
      return false
    if not manifest.hasPermission("process"):
      editorViewState.statusMessage = "External process permission is required: " & manifest.id
      return false
    ## The manifest field is intentionally a command line split into argv
    ## without shell interpretation. Extensions cannot inject `sh -c`, pipes,
    ## redirections, or a different working directory through this boundary.
    let commandParts = manifest.externalProcess.strip.splitWhitespace
    if commandParts.len == 0 or commandParts[0].len == 0:
      editorViewState.statusMessage = "External process command is empty: " & manifest.id
      return false
    if editorTaskJob != nil and not editorTaskJob.done:
      editorTaskJob.cancel()
    editorTaskCommand = "Extension " & manifest.id
    editorTaskOutput = ""
    editorTaskProblems.setLen(0)
    if editorTerminalVisible:
      editorTerminalVisible = false
      editorTerminalFocused = false
      platformSetTerminalVisible(false)
    editorTaskOutputVisible = true
    platformSetTaskOutputVisible(true)
    platformSetTaskOutputCancellable(true)
    editorWorkspaceUi.openPanel(panelTasks)
    setupDemoUi()
    let title = "Extension — " & manifest.name
    platformSetTaskOutputTitle(title.cstring, uint32(title.len))
    editorTaskJob = startTask(TaskSpec(command: commandParts[0],
      args: if commandParts.len > 1: commandParts[1 .. ^1] else: @[],
      workingDirectory: normalizedPath(manifest.root)))
    editorViewState.statusMessage = "Extension process running: " & manifest.id
    true

  proc runNativeWasmExtension(id: string = "") =
    if editorExtensionRegistry == nil:
      editorViewState.statusMessage = "Extensions are not loaded"
      return
    var selected: ExtensionManifest
    if id.strip.len > 0:
      selected = editorExtensionRegistry.find(id.strip)
    else:
      for _, manifest in editorExtensionRegistry.items:
        if manifest.wasmModule.len > 0:
          selected = manifest
          break
    if selected.id.len == 0:
      editorViewState.statusMessage = if id.strip.len > 0:
        "WASM extension not found: " & id.strip
        else: "No WASM extension is installed"
      return
    if selected.wasmModule.len == 0 and selected.externalProcess.len == 0:
      editorViewState.statusMessage = "Extension has no executable entrypoint: " & selected.id
      return
    if not requestNativeExtensionPermission(selected, "run", ""):
      return
    if selected.wasmModule.len == 0:
      discard startNativeExternalExtension(selected)
      return
    if wasmComponentHostAvailable() and isWasmComponent(selected):
      if editorWasmComponentJob.handle != nil:
        discard startNativeWasmComponent(selected)
        return
      if startNativeWasmComponent(selected): return
    try:
      let plan = prepareWasmExecution(selected)
      if editorTaskJob != nil and not editorTaskJob.done:
        editorTaskJob.cancel()
      editorTaskCommand = "WASM extension " & selected.id
      editorTaskOutput = ""
      editorTaskProblems.setLen(0)
      if editorTerminalVisible:
        editorTerminalVisible = false
        editorTerminalFocused = false
        platformSetTerminalVisible(false)
      editorTaskOutputVisible = true
      platformSetTaskOutputVisible(true)
      platformSetTaskOutputCancellable(true)
      editorWorkspaceUi.openPanel(panelTasks)
      setupDemoUi()
      let title = "WASM — " & selected.name
      platformSetTaskOutputTitle(title.cstring, uint32(title.len))
      ## Direct argv execution is deliberate: no shell, no inherited cwd
      ## preopen, and only the extension root is granted to Wasmtime.
      editorTaskJob = startTask(TaskSpec(command: plan.command, args: plan.args,
        workingDirectory: plan.workingDirectory))
      editorViewState.statusMessage = "WASM extension running: " & selected.id
    except CatchableError as error:
      editorViewState.statusMessage = "WASM extension failed to start: " & error.msg

  proc resolveMacosDapCommand(): string =
    ## LLDB-DAP is Apple's system adapter on current Xcode installations.
    ## Keep the environment override for other adapters, then use xcrun so
    ## the selected developer directory is honored instead of hard-coding a
    ## single Xcode bundle path.
    let configured = getEnv("NIMCULUS_DAP_COMMAND", "").strip
    if configured.len > 0: return configured
    for candidate in [
        "/Applications/Xcode.app/Contents/Developer/usr/bin/lldb-dap",
        "/usr/bin/lldb-dap"]:
      if fileExists(candidate): return candidate
    let xcrun = findExe("xcrun")
    if xcrun.len > 0:
      let resolved = execCmdEx(quoteShell(xcrun) & " --find lldb-dap")
      if resolved.exitCode == 0 and fileExists(resolved.output.strip):
        return resolved.output.strip
    ""

  proc showNativeExtensions() =
    if editorExtensionRegistry == nil:
      editorViewState.statusMessage = "Extensions are not loaded"
      return
    var lines = @[
      "Extensions",
      "──────────"
    ]
    for id, manifest in editorExtensionRegistry.items:
      lines.add(id & " " & manifest.version & " — " & manifest.name)
      if manifest.wasmModule.len > 0:
        lines.add("  WASM module validated (API " & $manifest.apiVersion & ")")
        lines.add("  runtime: " & wasmRuntimeStatus())
        if manifest.wasmEntrypoint.len > 0:
          lines.add("  entrypoint: " & manifest.wasmEntrypoint)
      if manifest.permissions.len > 0:
        lines.add("  permissions: " & manifest.extensionPermissionList.join(", "))
      lines.add("  host API v" & $SupportedExtensionApiVersion & ": " &
        manifest.extensionHostCapabilityString)
      if manifest.externalProcess.len > 0:
        lines.add("  external process (permissioned)")
    lines.add("  component host: " &
      (if wasmComponentHostAvailable(): "in-process" else: "CLI fallback"))
    if lines.len == 2: lines.add("No extensions installed")
    showNativeLspPanel("Extensions", lines)

  proc appendNativeDapOutput(line: string) =
    if line.len == 0: return
    if editorDapOutput.len > 0: editorDapOutput.add("\n")
    editorDapOutput.add(line)
    # Keep the debug panel bounded like task output. DAP adapters can emit
    # verbose output continuously, and a debug session must never grow the
    # editor's retained UI text without limit.
    const maxOutput = 4 * 1024 * 1024
    if editorDapOutput.len > maxOutput:
      let start = editorDapOutput.len - maxOutput
      let boundary = editorDapOutput.find('\n', start)
      editorDapOutput = if boundary >= 0: editorDapOutput[boundary + 1 .. ^1]
        else: editorDapOutput[start .. ^1]
    platformSetTaskOutputTitle("Debugger".cstring, uint32("Debugger".len))
    platformSetTaskOutputText(editorDapOutput.cstring, uint32(editorDapOutput.len))

  proc renderNativeDapSidebar() =
    ## Zed keeps debugger state in structured, keyboard-selectable lists.  The
    ## native overlay is still text-backed, but every visible debugger row now
    ## has a stable panel item and an action target rather than being display
    ## only.
    var lines = @[
      "Debugger",
      "────────",
      if editorDapSession == nil: "No active session" else:
        (if editorDapThreadId > 0: "Stopped" else: "Running")
    ]
    var lineItems = @[-1'i32, -1'i32, -1'i32]
    var itemKeys: seq[string]
    editorDapSidebarItems.setLen(0)
    proc addHeader(text: string) =
      lines.add(text)
      lineItems.add(-1'i32)
    proc addItem(text, key: string, kind: DapSidebarItemKind,
                 id = -1, reference = 0) =
      lines.add(text)
      editorDapSidebarItems.add(DapSidebarItem(kind: kind, id: id,
        reference: reference))
      itemKeys.add(key)
      lineItems.add(int32(editorDapSidebarItems.high))
    if editorDapThreads.len > 0:
      addHeader("")
      addHeader("Threads")
      addHeader("───────")
      for thread in editorDapThreads:
        addItem("#" & $thread.id & "  " & thread.name, "thread:" & $thread.id,
          dapThreadItem, thread.id)
    if editorDapFrames.len > 0:
      addHeader("")
      addHeader("Stack Frames")
      addHeader("────────────")
      for frame in editorDapFrames:
        let marker = if frame.id == editorDapFrameId: "● " else: "  "
        let displayLine = frame.line + 1
        addItem(marker & frame.name & "  " & frame.source & ":" & $displayLine,
          "frame:" & $frame.id, dapFrameItem, frame.id)
    if editorDapScopes.len > 0:
      addHeader("")
      addHeader("Scopes")
      addHeader("──────")
      for scope in editorDapScopes:
        addItem("▾ " & scope.name, "scope:" & $scope.reference,
          dapScopeItem, reference = scope.reference)
    if editorDapVariables.len > 0:
      addHeader("")
      addHeader("Variables")
      addHeader("─────────")
      for index, variable in editorDapVariables:
        let expanded = variable.reference > 0 and
          variable.reference in editorDapExpandedVariableReferences
        let disclosure = if variable.reference <= 0: "  "
          elif expanded: "▼ " else: "▶ "
        let indent = repeat("  ", variable.depth)
        addItem(indent & disclosure & variable.name & " = " & variable.value,
          "variable:" & $index & ":" & $variable.reference,
          dapVariableItem, reference = variable.reference)
    if editorDapWatchLines.len > 0:
      addHeader("")
      addHeader("Watches")
      addHeader("───────")
      for index, watch in editorDapWatchLines:
        addItem(watch, "watch:" & $index, dapWatchItem)
    if editorDapChildSessions.len > 0:
      addHeader("")
      addHeader("Child Sessions")
      addHeader("──────────────")
      for child in editorDapChildSessions:
        if child != nil:
          addHeader("#" & $child.id & "  " & child.requestKind & "  " &
            (if child.initialized: "running" else: "initializing"))
    if editorDapThreads.len == 0 and editorDapFrames.len == 0 and
        editorDapScopes.len == 0 and editorDapVariables.len == 0 and
        editorDapWatchLines.len == 0:
      addHeader("")
      addHeader("Start or attach a debugger to inspect the session.")
    editorWorkspaceUi.replacePanelItems(panelDebugger, itemKeys)
    let text = lines.join("\n")
    platformSetEditorSidebar(text.cstring, uint32(text.len),
      uint32(editorDapSidebarItems.len), uint32(sidebarDebugger))
    if lineItems.len > 0:
      platformSetEditorSidebarLineItems(addr lineItems[0], uint32(lineItems.len))

  proc showNativeDapSidebar() =
    editorSidebarMode = sidebarDebugger
    editorWorkspaceUi.openPanel(panelDebugger)
    # Opening the panel must not steal the editor's first responder. This is
    # the same distinction Zed makes between panel visibility and focus.
    editorWorkspaceUi.focusCenter()
    renderNativeDapSidebar()

  proc stopNativeDapChildren()

  proc stopNativeDap() =
    if editorDapSession == nil and editorDapChildSessions.len == 0:
      editorViewState.statusMessage = "Debugger: no active session"
      return
    stopNativeDapChildren()
    if editorDapSession == nil:
      editorDapInitialized = false
      renderNativeDapSidebar()
      editorViewState.statusMessage = "Debugger stopped"
      return
    editorDapSession.stop()
    for job in editorDapTerminalJobs:
      if job != nil and not job.done: job.cancel()
    editorDapTerminalJobs.setLen(0)
    editorDapSession = nil
    editorDapInitialized = false
    editorDapThreadId = -1
    editorDapFrameId = -1
    editorDapAttachPid = -1
    editorDapThreads.setLen(0)
    editorDapFrames.setLen(0)
    editorDapScopes.setLen(0)
    editorDapVariables.setLen(0)
    editorDapWatchLines.setLen(0)
    editorDapVariableRootReference = 0
    editorDapVariableRequestReference = 0
    editorDapExpandedVariableReferences.setLen(0)
    editorDapSidebarItems.setLen(0)
    renderNativeDapSidebar()
    editorViewState.statusMessage = "Debugger stopped"

  proc startNativeDap(attach = false) =
    if editorDapSession != nil:
      editorViewState.statusMessage = "Debugger is already running"
      return
    let command = resolveMacosDapCommand()
    let remoteHost = getEnv("NIMCULUS_DAP_HOST", "").strip
    if command.len == 0 and remoteHost.len == 0:
      editorViewState.statusMessage = "Debugger unavailable: install Xcode LLDB-DAP or set NIMCULUS_DAP_COMMAND/NIMCULUS_DAP_HOST"
      return
    let document = activeDocument()
    let workingDirectory = taskWorkingDirectory(document)
    let attachPid = if attach:
      try: parseInt(getEnv("NIMCULUS_DAP_PID", "-1"))
      except ValueError: -1
      else: -1
    if attach and attachPid <= 0:
      editorViewState.statusMessage = "Debugger attach requires NIMCULUS_DAP_PID"
      return
    try:
      if remoteHost.len > 0:
        let remotePort = try: parseInt(getEnv("NIMCULUS_DAP_PORT", "0"))
          except ValueError: 0
        editorDapSession = startDapRemoteSession(remoteHost, remotePort, workingDirectory)
      else:
        editorDapSession = startDapSession(command,
          getEnv("NIMCULUS_DAP_ARGS", "").splitWhitespace, workingDirectory)
      editorDapOutput = ""
      editorDapBreakpointLines.setLen(0)
      editorDapInitialized = false
      editorDapThreadId = -1
      editorDapFrameId = -1
      editorDapAttachPid = if attach: attachPid else: -1
      editorDapThreads.setLen(0)
      editorDapFrames.setLen(0)
      editorDapScopes.setLen(0)
      editorDapVariables.setLen(0)
      editorDapWatchLines.setLen(0)
      editorDapVariableRootReference = 0
      editorDapVariableRequestReference = 0
      editorDapExpandedVariableReferences.setLen(0)
      editorDapSidebarItems.setLen(0)
      editorTaskOutputVisible = true
      editorTerminalVisible = false
      platformSetTerminalVisible(false)
      platformSetTaskOutputVisible(true)
      platformSetTaskOutputCancellable(false)
      editorWorkspaceUi.openPanel(panelTasks)
      showNativeDapSidebar()
      let request = editorDapSession.sendRequest("initialize", initializeArguments())
      appendNativeDapOutput("→ initialize (#" & $request.seq & ")")
      editorViewState.statusMessage = "Debugger: initializing"
    except CatchableError as error:
      editorDapSession = nil
      editorViewState.statusMessage = "Debugger failed: " & error.msg

  proc sendNativeDapRequest(command: string, arguments: JsonNode = nil): bool =
    if editorDapSession == nil or not editorDapSession.isRunning:
      editorViewState.statusMessage = "Debugger is not running"
      return false
    try:
      let request = editorDapSession.sendRequest(command, arguments)
      appendNativeDapOutput("→ " & command & " (#" & $request.seq & ")")
      true
    except CatchableError as error:
      editorViewState.statusMessage = "Debugger request failed: " & error.msg
      false

  proc stopNativeDapChildren() =
    for child in editorDapChildSessions:
      if child != nil and child.session != nil:
        child.session.stop()
    editorDapChildSessions.setLen(0)

  proc startNativeDapChild(request: DapMessage): bool =
    ## Zed creates a new session from the parent's adapter and keeps the
    ## parent request open only until the child has been accepted. The child
    ## has its own transport, request tracker, and bounded shutdown path; it
    ## must never replace the UI's selected parent session.
    let arguments = request.arguments
    let requestKind = if arguments != nil and arguments.kind == JObject and
        arguments.hasKey("request") and arguments["request"].kind == JString:
      arguments["request"].getStr.toLowerAscii
      else: "launch"
    if requestKind notin ["launch", "attach"]:
      if editorDapSession != nil:
        editorDapSession.sendResponse(request, false, %*{},
          "startDebugging request must be launch or attach")
      return false
    let configuration = if arguments != nil and arguments.kind == JObject and
        arguments.hasKey("configuration") and arguments["configuration"].kind == JObject:
      arguments["configuration"] else: %*{}
    let workingDirectory = taskWorkingDirectory(activeDocument())
    let remoteHost = getEnv("NIMCULUS_DAP_HOST", "").strip
    let command = resolveMacosDapCommand()
    if command.len == 0 and remoteHost.len == 0:
      if editorDapSession != nil:
        editorDapSession.sendResponse(request, false, %*{},
          "child DAP adapter is unavailable")
      return false
    try:
      var session: DapSession
      if remoteHost.len > 0:
        let port = try: parseInt(getEnv("NIMCULUS_DAP_PORT", "0"))
          except ValueError: 0
        session = startDapRemoteSession(remoteHost, port, workingDirectory)
      else:
        session = startDapSession(command,
          getEnv("NIMCULUS_DAP_ARGS", "").splitWhitespace, workingDirectory)
      let child = DapChildSession(id: editorDapNextChildId, session: session,
        requestKind: requestKind, configuration: configuration, initialized: false)
      inc editorDapNextChildId
      editorDapChildSessions.add(child)
      let initialize = session.sendRequest("initialize", initializeArguments())
      appendNativeDapOutput("→ child debugger #" & $child.id &
        " initialize (#" & $initialize.seq & ")")
      if editorDapSession != nil:
        editorDapSession.sendResponse(request, true, %*{})
      renderNativeDapSidebar()
      editorViewState.statusMessage = "Child debugger #" & $child.id & " initializing"
      true
    except CatchableError as error:
      if editorDapSession != nil:
        editorDapSession.sendResponse(request, false, %*{}, error.msg)
      editorViewState.statusMessage = "Child debugger failed: " & error.msg
      false

  proc pollNativeDapChildren() =
    if editorDapChildSessions.len == 0: return
    var remaining: seq[DapChildSession]
    for child in editorDapChildSessions:
      if child == nil or child.session == nil: continue
      for message in child.session.poll():
        case message.messageType
        of dapResponseMessage:
          if not message.success:
            appendNativeDapOutput("← child debugger #" & $child.id & " " &
              message.command & ": " & message.responseMessage)
            child.session.stop()
          elif message.command == "initialize" and not child.initialized:
            child.initialized = true
            let launch = child.session.sendRequest(child.requestKind, child.configuration)
            appendNativeDapOutput("→ child debugger #" & $child.id & " " &
              child.requestKind & " (#" & $launch.seq & ")")
            renderNativeDapSidebar()
          elif message.command in ["launch", "attach"]:
            appendNativeDapOutput("← child debugger #" & $child.id & " " &
              message.command & " accepted")
          else:
            appendNativeDapOutput("← child debugger #" & $child.id & " " &
              message.command)
        of dapEventMessage:
          let event = if message.event.len > 0: message.event else: "event"
          appendNativeDapOutput("• child debugger #" & $child.id & " " & event)
        of dapRequestMessage:
          try:
            child.session.sendResponse(message, false, %*{},
              "nested reverse requests are not supported")
          except CatchableError:
            discard
      if child.session.state in {dapStopped, dapFailed} or not child.session.isRunning:
        appendNativeDapOutput("• child debugger #" & $child.id & " stopped")
        child.session.stop()
      else:
        remaining.add(child)
    editorDapChildSessions = remaining
    renderNativeDapSidebar()

  proc pollNativeDapTerminalJobs() =
    if editorDapTerminalJobs.len == 0: return
    var output: seq[string]
    var active: seq[TaskJob]
    for job in editorDapTerminalJobs:
      if job == nil: continue
      discard job.poll()
      if job.result.output.len > 0: output.add(job.result.output)
      if job.done:
        appendNativeDapOutput("• runInTerminal exited (" & $job.result.exitCode & ")")
      else:
        active.add(job)
    editorDapTerminalJobs = active
    if output.len > 0:
      editorTaskOutputVisible = true
      platformSetTaskOutputVisible(true)
      platformSetTaskOutputText(output.join("\n").cstring,
        uint32(output.join("\n").len))

  proc pollNativeDap() =
    if editorDapSession == nil: return
    for message in editorDapSession.poll():
      case message.messageType
      of dapResponseMessage:
        if not message.success:
          appendNativeDapOutput("← " & message.command & ": " & message.responseMessage)
          editorViewState.statusMessage = "Debugger: " & message.command & " failed"
          if message.command in ["initialize", "launch", "attach"]:
            # A failed adapter handshake/target attach must not leave
            # lldb-dap or a runInTerminal child behind. This is especially
            # important on macOS where debugserver can reject a target after
            # the adapter itself has already emitted process events.
            editorDapSession.stop()
            editorDapSession = nil
            stopNativeDapChildren()
            for job in editorDapTerminalJobs:
              if job != nil and not job.done: job.cancel()
            editorDapTerminalJobs.setLen(0)
            editorDapInitialized = false
            renderNativeDapSidebar()
          continue
        appendNativeDapOutput("← " & message.command)
        if message.command == "initialize" and not editorDapInitialized:
          editorDapInitialized = true
          let document = activeDocument()
          if editorDapAttachPid > 0:
            discard sendNativeDapRequest("attach", attachArguments(editorDapAttachPid,
              taskWorkingDirectory(document)))
          else:
            let configuredProgram = getEnv("NIMCULUS_DAP_PROGRAM", "").strip
            let documentProgram = if document != nil and document[].path.len > 0 and
                fileExists(document[].path) and fpUserExec in getFilePermissions(document[].path):
              document[].path
              else: ""
            let program = if configuredProgram.len > 0: configuredProgram else: documentProgram
            if program.len == 0:
              appendNativeDapOutput("Debugger launch requires NIMCULUS_DAP_PROGRAM or an executable active file")
              editorViewState.statusMessage = "Debugger launch target is not configured"
              editorDapSession.stop()
              editorDapSession = nil
              stopNativeDapChildren()
              renderNativeDapSidebar()
            else:
              discard sendNativeDapRequest("launch", launchArguments(program,
                taskWorkingDirectory(document), getEnv("NIMCULUS_DAP_PROGRAM_ARGS",
                    "").splitWhitespace))
        elif message.command == "stackTrace" and message.body != nil:
          if message.body.hasKey("stackFrames") and message.body["stackFrames"].kind == JArray:
            var lines = @["Debugger — Stack Frames"]
            editorDapFrames.setLen(0)
            editorDapScopes.setLen(0)
            editorDapVariables.setLen(0)
            editorDapVariableRootReference = 0
            editorDapVariableRequestReference = 0
            editorDapExpandedVariableReferences.setLen(0)
            editorDapFrameId = -1
            for frame in message.body["stackFrames"]:
              if frame.kind != JObject: continue
              let id = if frame.hasKey("id"): frame["id"].getInt else: -1
              let name = if frame.hasKey("name"): frame["name"].getStr else: "<frame>"
              let line = if frame.hasKey("line"): frame["line"].getInt else: 0
              let source = if frame.hasKey("source") and frame["source"].kind == JObject and
                  frame["source"].hasKey("path"): frame["source"]["path"].getStr else: ""
              editorDapFrames.add(DapFrameInfo(id: id, name: name, source: source, line: line))
              if editorDapFrameId < 0: editorDapFrameId = id
              lines.add(name & "  " & source & ":" & $(line + 1))
            editorDapOutput = lines.join("\n") & "\n\n" & editorDapOutput
            platformSetTaskOutputText(editorDapOutput.cstring, uint32(editorDapOutput.len))
            renderNativeDapSidebar()
            if editorDapFrameId > 0:
              discard sendNativeDapRequest("scopes", scopesArguments(editorDapFrameId))
        elif message.command == "scopes" or message.command == "variables":
          if message.body != nil:
            if message.command == "scopes" and message.body.hasKey("scopes") and
                message.body["scopes"].kind == JArray:
              editorDapScopes.setLen(0)
              editorDapVariables.setLen(0)
              editorDapVariableRootReference = 0
              editorDapVariableRequestReference = 0
              editorDapExpandedVariableReferences.setLen(0)
              appendNativeDapOutput("Scopes:")
              for scope in message.body["scopes"]:
                if scope.kind != JObject: continue
                let name = if scope.hasKey("name"): scope["name"].getStr else: "scope"
                let reference = if scope.hasKey("variablesReference"):
                  scope["variablesReference"].getInt else: 0
                appendNativeDapOutput("  " & name)
                editorDapScopes.add(DapScopeInfo(name: name, reference: reference))
                if editorDapVariableRootReference == 0 and reference > 0:
                  editorDapVariableRootReference = reference
              if editorDapVariableRootReference > 0:
                editorDapVariableRequestReference = editorDapVariableRootReference
                discard sendNativeDapRequest("variables",
                  variablesArguments(editorDapVariableRootReference))
            elif message.command == "variables" and message.body.hasKey("variables") and
                message.body["variables"].kind == JArray:
              let parentReference = editorDapVariableRequestReference
              var parsed: seq[DapVariableInfo]
              appendNativeDapOutput("Variables:")
              for variable in message.body["variables"]:
                if variable.kind != JObject: continue
                let name = if variable.hasKey("name"): variable["name"].getStr else: "?"
                let value = if variable.hasKey("value"): variable["value"].getStr else: ""
                let reference = if variable.hasKey("variablesReference"):
                  variable["variablesReference"].getInt else: 0
                appendNativeDapOutput("  " & name & " = " & value)
                parsed.add(DapVariableInfo(name: name, value: value,
                  reference: reference, depth: 0))
              if parentReference == editorDapVariableRootReference:
                editorDapVariables = parsed
              else:
                var parentIndex = -1
                for index, variable in editorDapVariables:
                  if variable.reference == parentReference:
                    parentIndex = index
                    break
                if parentIndex >= 0:
                  let depth = editorDapVariables[parentIndex].depth + 1
                  var insertAt = parentIndex + 1
                  while insertAt < editorDapVariables.len and
                      editorDapVariables[insertAt].depth > editorDapVariables[parentIndex].depth:
                    inc insertAt
                  for child in parsed:
                    var nested = child
                    nested.depth = depth
                    editorDapVariables.insert(nested, insertAt)
                    inc insertAt
              editorDapVariableRequestReference = 0
            else:
              appendNativeDapOutput("  " & $message.body)
            renderNativeDapSidebar()
        elif message.command == "threads" and message.body != nil and
            message.body.hasKey("threads") and message.body["threads"].kind == JArray:
          editorDapThreads.setLen(0)
          for thread in message.body["threads"]:
            if thread.kind != JObject: continue
            let id = if thread.hasKey("id"): thread["id"].getInt else: -1
            let name = if thread.hasKey("name"): thread["name"].getStr else: "thread"
            editorDapThreads.add(DapThreadInfo(id: id, name: name))
          renderNativeDapSidebar()
        elif message.command == "evaluate" and message.body != nil:
          let value = if message.body.hasKey("result"): message.body[
              "result"].getStr else: $message.body
          editorDapWatchLines.add(value)
          if editorDapWatchLines.len > 64: editorDapWatchLines.delete(0)
          renderNativeDapSidebar()
      of dapEventMessage:
        case message.event
        of "initialized":
          # DAP adapters announce this event after initialize/launch.  This
          # is the safe boundary for breakpoints and configurationDone; it
          # avoids racing adapter capabilities with client requests.
          let document = activeDocument()
          if document != nil and document[].path.len > 0 and editorDapBreakpointLines.len > 0:
            discard sendNativeDapRequest("setBreakpoints",
              setBreakpointsArguments(document[].path, editorDapBreakpointLines))
          discard sendNativeDapRequest("configurationDone", configurationDoneArguments())
          editorViewState.statusMessage = "Debugger ready"
        of "output":
          if message.body != nil and message.body.hasKey("output"):
            appendNativeDapOutput(message.body["output"].getStr.strip(chars = {'\n'}))
        of "stopped":
          if message.body != nil and message.body.hasKey("threadId"):
            editorDapThreadId = message.body["threadId"].getInt
            editorViewState.statusMessage = "Debugger stopped: " &
              (if message.body.hasKey("reason"): message.body["reason"].getStr else: "breakpoint")
            discard sendNativeDapRequest("stackTrace", stackTraceArguments(editorDapThreadId))
            renderNativeDapSidebar()
            for expression in editorDapWatchExpressions:
              discard sendNativeDapRequest("evaluate", evaluateArguments(expression,
                editorDapFrameId))
        of "continued": editorViewState.statusMessage = "Debugger continued"
        of "terminated", "exited": editorViewState.statusMessage = "Debugger terminated"
        else: discard
        appendNativeDapOutput("• " & message.event)
      of dapRequestMessage:
        appendNativeDapOutput("← adapter request: " & message.command)
        try:
          case message.command
          of "runInTerminal":
            var commandArgs: seq[string]
            var cwd = taskWorkingDirectory(activeDocument())
            var environment: seq[tuple[key, value: string]]
            if message.arguments != nil and message.arguments.kind == JObject:
              if message.arguments.hasKey("cwd") and
                  message.arguments["cwd"].kind == JString:
                cwd = message.arguments["cwd"].getStr
              if message.arguments.hasKey("args") and
                  message.arguments["args"].kind == JArray:
                for argument in message.arguments["args"]:
                  if argument.kind == JString: commandArgs.add(argument.getStr)
              if message.arguments.hasKey("env") and
                  message.arguments["env"].kind == JObject:
                for key, value in message.arguments["env"]:
                  if value.kind == JString:
                    environment.add((key: key, value: value.getStr))
            if commandArgs.len == 0:
              editorDapSession.sendResponse(message, false, %*{},
                "runInTerminal requires a non-empty args array")
            elif not dirExists(cwd):
              editorDapSession.sendResponse(message, false, %*{},
                "runInTerminal working directory is unavailable")
            else:
              let job = startTask(TaskSpec(command: commandArgs[0],
                args: if commandArgs.len > 1: commandArgs[1 .. ^1] else: @[],
                workingDirectory: cwd, environment: environment))
              if job == nil or job.done or job.processId <= 0:
                editorDapSession.sendResponse(message, false, %*{},
                  "runInTerminal process could not be started")
              else:
                editorDapTerminalJobs.add(job)
                editorTaskOutputVisible = true
                platformSetTaskOutputVisible(true)
                editorWorkspaceUi.openPanel(panelTasks)
                editorDapSession.sendResponse(message, true, %*{
                  "processId": job.processId,
                  "shellProcessId": job.processId
                })
          of "startDebugging":
            discard startNativeDapChild(message)
          else:
            editorDapSession.sendResponse(message, false, %*{},
              "unsupported DAP reverse request: " & message.command)
        except CatchableError as error:
          editorViewState.statusMessage = "Debugger reverse request failed: " & error.msg
          try:
            editorDapSession.sendResponse(message, false, %*{}, error.msg)
          except CatchableError:
            discard
    if editorDapSession == nil: return
    if editorDapSession.state in {dapStopped, dapFailed}:
      editorViewState.statusMessage = if editorDapSession.state == dapFailed:
        "Debugger adapter exited unexpectedly" else: "Debugger stopped"
      editorDapSession.stop()
      editorDapSession = nil
      stopNativeDapChildren()
      renderNativeDapSidebar()
  proc renderNativeGitStatus(entries: seq[GitStatusEntry])

  proc refreshNativeGitPanelBranch(repository: GitRepository) =
    ## Keep branch resolution cancellable and off the idle/UI path. A direct
    ## `currentBranch` call spawns Git synchronously and can wait on a slow
    ## repository filesystem operation.
    if editorGitBranchJob != nil and not editorGitBranchJob.done:
      editorGitBranchJob.cancel()
    editorGitBranchJob = nil
    editorGitBranchRepository = repository
    editorGitBranchGeneration = editorGitStatusGeneration
    editorGitPanelBranch = ""
    platformSetEditorGitBranch("".cstring)
    if repository != nil:
      editorGitBranchJob = repository.startGitJob([
        "symbolic-ref", "--quiet", "--short", "HEAD"])

  proc cancelNativeGitAction() =
    if editorGitActionJob != nil and not editorGitActionJob.done:
      editorGitActionJob.cancel()
    editorGitActionJob = nil
    editorGitAction = ""
    editorGitActionPhase = ""

  proc startNativeGitAction(repository: GitRepository, action, path: string,
                            args: openArray[string], source = "",
                            line = -1) =
    cancelNativeGitAction()
    if repository == nil:
      editorViewState.statusMessage = "Git repository not found"
      return
    editorGitRepository = repository
    editorGitAction = action
    editorGitActionPhase = "run"
    editorGitActionDocumentPath = if activeDocument() == nil: ""
      else: activeDocument()[].path
    editorGitActionPath = path
    editorGitActionSource = source
    editorGitActionLine = line
    editorGitActionJob = repository.startGitJob(args)
    editorViewState.statusMessage = "Git: " & action & "…"

  proc startNativeGitHunkAction(repository: GitRepository, path, action: string,
                                line: int) =
    cancelNativeGitAction()
    if repository == nil or path.len == 0:
      editorViewState.statusMessage = "Git repository not found"
      return
    editorGitAction = action
    editorGitActionPhase = "diff"
    editorGitActionDocumentPath = if activeDocument() == nil: ""
      else: activeDocument()[].path
    editorGitActionPath = path
    editorGitActionLine = line
    editorGitRepository = repository
    var diffArgs = @["diff", "--no-ext-diff", "--unified=3"]
    if action == "unstage hunk": diffArgs.add("--cached")
    diffArgs.add("--")
    diffArgs.add(path)
    editorGitActionJob = repository.startGitJob(diffArgs)
    editorViewState.statusMessage = "Git: " & action & "…"

  proc renderNativeGitHistory(commits: seq[GitCommit], title = "Git History",
                              path = "") =
    editorWorkspaceUi.openPanel(panelGit)
    setupDemoUi()
    editorSidebarMode = sidebarGitHistory
    editorGitHistory = commits
    editorGitHistoryPath = path
    var lines = @[title, "────────"]
    if commits.len == 0:
      lines.add("No commits")
    else:
      for commit in commits:
        let shortHash = if commit.hash.len > 8: commit.hash[0 .. 7] else: commit.hash
        lines.add(shortHash & "  " & commit.subject & " — " & commit.author)
    editorWorkspaceUi.replacePanelItems(panelGit, commits.mapIt(it.hash))
    let text = lines.join("\n")
    platformSetEditorSidebar(text.cstring, uint32(text.len), uint32(commits.len),
      uint32(sidebarGitHistory))
    syncNativeSidebarSelection()

  proc renderNativeGitHistoryPlaceholder(message: string, title = "Git History",
                                         path = "") =
    ## Match Zed's History state machine: the tab owns a clear Loading/Error/
    ## Empty transition rather than retaining whatever sidebar happened to be
    ## visible before the asynchronous Git job started.
    editorWorkspaceUi.openPanel(panelGit)
    setupDemoUi()
    editorSidebarMode = sidebarGitHistory
    editorGitHistory.setLen(0)
    editorGitHistoryPath = path
    editorWorkspaceUi.replacePanelItems(panelGit, @[])
    let text = title & "\n────────\n" & message
    platformSetEditorSidebar(text.cstring, uint32(text.len), 0,
      uint32(sidebarGitHistory))
    syncNativeSidebarSelection()

  proc renderNativeGitEmpty() =
    ## Keep Git discoverable even before a project resolves to a repository.
    ## The sidebar owns the primary next action instead of leaving a stale
    ## Files/Outline list visible behind a status-bar-only error.
    editorWorkspaceUi.openPanel(panelGit)
    setupDemoUi()
    editorSidebarMode = sidebarGitStatus
    editorGitRepository = nil
    editorGitStatusSourceEntries.setLen(0)
    editorGitStatusEntries.setLen(0)
    editorGitStatusProjections.setLen(0)
    editorWorkspaceUi.replacePanelItems(panelGit, @["open-workspace"])
    let text = "Git\n────────\nNo repository found\nOpen Folder…"
    platformSetEditorSidebar(text.cstring, uint32(text.len), 1,
      uint32(sidebarGitStatus))
    syncNativeSidebarSelection()

  proc renderNativeGitBlame(entries: seq[GitBlameLine], path: string) =
    ## Zed renders inline blame when space permits. The native output panel is
    ## Nimculus' current compact equivalent: retain a bounded, line-oriented
    ## view while leaving the editor text and cursor untouched.
    const MaxPanelLines = 500
    var lines = @["Git Blame — " & path, "────────"]
    let shown = min(entries.len, MaxPanelLines)
    for index in 0 ..< shown:
      let entry = entries[index]
      let shortHash = if entry.hash.len > 8: entry.hash[0 .. 7] else: entry.hash
      lines.add(align($((index + 1)), 5) & "  " & shortHash & "  " &
        entry.author & " │ " & entry.text)
    if entries.len > shown:
      lines.add("… " & $(entries.len - shown) & " additional line(s) omitted")
    showNativeLspPanel("Git Blame", lines)

  proc renderNativeGitStatus(entries: seq[GitStatusEntry]) =
    editorWorkspaceUi.openPanel(panelGit)
    setupDemoUi()
    ## Keep conflicts explicit and ahead of ordinary changes. As in Zed's
    ## separate conflict section, this is informational only: bulk stage or
    ## unstage actions must not silently resolve or discard an unmerged file.
    const MaxPanelEntries = 1_000
    let title = if editorGitPanelBranch.len > 0:
      "Git Status — " & editorGitPanelBranch else: "Git Status"
    var lines = @[title, "────────"]
    var lineItems: seq[int32] = @[-1'i32, -1'i32]
    var conflicts: seq[GitStatusEntry]
    var staged: seq[GitStatusEntry]
    var unstaged: seq[GitStatusEntry]
    for entry in entries:
      if entry.conflict:
        conflicts.add(entry)
      else:
        # A partially staged file intentionally appears in both sections, as
        # it does in Zed: each section describes the corresponding index or
        # worktree state rather than hiding one half of the file's changes.
        if entry.indexStatus notin {' ', '?', '!'}: staged.add(entry)
        if entry.worktreeStatus != ' ' or entry.indexStatus in {'?', '!'}:
          unstaged.add(entry)
    var displayed: seq[GitStatusEntry]
    var projections: seq[GitStatusProjection]
    var panelKeys: seq[string]
    var omitted = 0
    proc appendSection(name: string, section: openArray[GitStatusEntry],
                       projection: GitStatusProjection) =
      if section.len == 0: return
      lines.add(name & " (" & $section.len & ")")
      lineItems.add(-1'i32)
      for entry in section:
        if displayed.len >= MaxPanelEntries:
          inc omitted
          continue
        let state = case projection
          of gitStatusConflict: "! CONFLICT"
          of gitStatusStaged: "✓ " & $entry.indexStatus
          of gitStatusUnstaged: "○ " & $entry.worktreeStatus
        let path = if entry.originalPath.len > 0:
          entry.originalPath & " → " & entry.path else: entry.path
        lines.add(state & "  " & path)
        displayed.add(entry)
        projections.add(projection)
        panelKeys.add($projection & "\x1f" & $entry.indexStatus & $entry.worktreeStatus &
          "\x1f" & entry.path)
        lineItems.add(int32(displayed.high))
    appendSection("Conflicts", conflicts, gitStatusConflict)
    appendSection("Staged", staged, gitStatusStaged)
    appendSection("Unstaged", unstaged, gitStatusUnstaged)
    if displayed.len == 0:
      lines.add("No changes")
      lineItems.add(-1'i32)
    if omitted > 0:
      lines.add("… " & $omitted & " additional entry(s) omitted")
      lineItems.add(-1'i32)
    # Status is the primary Git sidebar surface, not an editor/output result.
    # Rendering the same list into the output panel duplicated its title and
    # obscured the document after every refresh. Reserve that panel for an
    # explicit detail action such as commit show, blame, task output, or LSP.
    # The scrollable sidebar owns the complete status list and file actions.
    editorSidebarMode = sidebarGitStatus
    editorGitStatusEntries = displayed
    editorGitStatusProjections = projections
    editorGitEntriesGeneration = editorGitStatusGeneration
    let sidebarText = lines.join("\n")
    editorWorkspaceUi.replacePanelItems(panelGit, panelKeys)
    platformSetEditorSidebar(sidebarText.cstring, uint32(sidebarText.len),
      uint32(editorGitStatusEntries.len), uint32(sidebarGitStatus))
    if lineItems.len > 0:
      platformSetEditorSidebarLineItems(unsafeAddr lineItems[0], uint32(lineItems.len))
    syncNativeSidebarSelection()

  proc renderNativeGitBranches(branches: seq[GitBranch]) =
    editorWorkspaceUi.openPanel(panelGit)
    setupDemoUi()
    editorSidebarMode = sidebarGitBranches
    editorGitBranches = branches
    var lines = @["Git Branches", "────────"]
    for branch in branches:
      lines.add((if branch.current: "● " else: "  ") & branch.name)
    if branches.len == 0: lines.add("No local branches")
    editorWorkspaceUi.replacePanelItems(panelGit, branches.mapIt(it.name))
    let text = lines.join("\n")
    platformSetEditorSidebar(text.cstring, uint32(text.len), uint32(branches.len),
      uint32(sidebarGitBranches))
    syncNativeSidebarSelection()

  proc reloadCleanDocumentsForBranch(repository: GitRepository): int =
    ## Git switches update the working tree atomically from the editor's point
    ## of view. Reload only clean tabs under the switched repository; dirty
    ## buffers remain user-owned and Git itself has already refused unsafe
    ## worktree changes. Preserve both split panes' item-local view state.
    if repository == nil: return
    editorSession.saveActiveView(editorViewState)
    editorSession.saveSecondaryActiveView(editorSession.secondaryView)
    result = editorSession.reloadCleanDocumentsUnder(repository.root)
    editorSession.loadActiveView(editorViewState)
    editorSession.loadSecondaryActiveView()

  proc pollNativeGitAction() =
    if editorGitActionJob == nil or not editorGitActionJob.poll(): return
    let job = editorGitActionJob
    let action = editorGitAction
    let document = activeDocument()
    let sameDocument = document != nil and
      document[].path == editorGitActionDocumentPath
    if action.endsWith("hunk") and not sameDocument:
      cancelNativeGitAction()
      return
    if job.cancelled:
      editorViewState.statusMessage = "Git: cancelled"
      cancelNativeGitAction()
      return
    if action.endsWith("hunk") and editorGitActionPhase == "diff":
      if job.result.exitCode != 0:
        editorViewState.statusMessage = "Git hunk diff failed: " & job.result.output.strip
        cancelNativeGitAction()
        return
      let hunks = parseDiffHunks(job.result.output)
      var hunkIndex = -1
      for index, hunk in hunks:
        let firstLine = max(0, hunk.newStart - 1)
        let lineCount = max(1, hunk.newCount)
        if editorGitActionLine >= firstLine and
            editorGitActionLine < firstLine + lineCount:
          hunkIndex = index
          break
      if hunkIndex < 0:
        editorViewState.statusMessage = "Git: no hunk at cursor"
        cancelNativeGitAction()
        return
      let headerEnd = job.result.output.find("@@ ")
      if headerEnd < 0:
        editorViewState.statusMessage = "Git: hunk patch unavailable"
        cancelNativeGitAction()
        return
      let patch = job.result.output[0 ..< headerEnd] & hunks[hunkIndex].patchText
      var args = @["apply", "--cached", "--whitespace=nowarn"]
      if action == "unstage hunk": args.add("--reverse")
      args.add("-")
      editorGitActionPhase = "apply"
      editorGitActionJob = editorGitRepository.startGitJobInput(args, patch)
      editorViewState.statusMessage = "Git: applying hunk…"
      return
    let output = job.result.output.strip
    # `git diff --no-index` deliberately returns 1 when it found a diff.
    # Treat that as a successful untracked-file preview, not as a failed job.
    let diffFound = action == "show file diff" and job.result.exitCode == 1
    if job.result.exitCode != 0 and not diffFound:
      if action == "log" or action == "refresh history":
        renderNativeGitHistoryPlaceholder("Failed to load commit history")
      elif action == "file history":
        renderNativeGitHistoryPlaceholder("Failed to load commit history",
          "Git History — " & editorGitActionPath, editorGitActionPath)
      editorViewState.statusMessage = "Git " & action & " failed: " & output
    elif action == "status":
      let entries = parseStatus(job.result.output)
      var conflicts = 0
      for entry in entries:
        if entry.conflict: inc conflicts
      inc editorGitStatusGeneration
      refreshNativeGitPanelBranch(editorGitRepository)
      editorGitStatusSourceEntries = entries
      renderNativeGitStatus(entries)
      editorViewState.statusMessage = "Git: " & $entries.len &
        " changed file(s), " & $conflicts & " conflict(s)"
    elif action == "log":
      let commits = parseLog(job.result.output, 100)
      renderNativeGitHistory(commits)
      editorViewState.statusMessage = if commits.len == 0:
        "Git log: no commits" else: "Git log: " & commits[0].subject
    elif action == "file history":
      let commits = parseLog(job.result.output, 100)
      renderNativeGitHistory(commits, "Git History — " & editorGitActionPath,
        editorGitActionPath)
      editorViewState.statusMessage = if commits.len == 0:
        "Git file history: no commits" else: "Git file history: " & commits[0].subject
    elif action == "branches":
      let branches = parseBranches(job.result.output)
      renderNativeGitBranches(branches)
      editorViewState.statusMessage = if branches.len == 0:
        "Git: no local branches" else: "Git: " & $branches.len & " local branch(es)"
    elif action == "stage file" or action == "unstage file":
      # Refresh the panel through the same job boundary after an item-local
      # mutation. This avoids stale staging affordances and never blocks UI.
      scheduleNativeGitHunks(activeDocument())
      scheduleNativeSecondaryGitHunks(secondaryPaneDocument())
      startNativeGitAction(editorGitRepository, "refresh status", "", [
        "status", "--porcelain=v1", "--untracked-files=all", "-z"], source = action)
      return
    elif action == "refresh status":
      let entries = parseStatus(job.result.output)
      inc editorGitStatusGeneration
      refreshNativeGitPanelBranch(editorGitRepository)
      editorGitStatusSourceEntries = entries
      renderNativeGitStatus(entries)
      editorViewState.statusMessage = "Git: " & editorGitActionSource & " complete"
    elif action == "commit" or action == "amend":
      # A Git panel must not keep displaying the old HEAD after a successful
      # write. Refresh through the same cancellable job boundary rather than
      # synchronously reading history on the UI thread.
      scheduleNativeGitHunks(activeDocument())
      scheduleNativeSecondaryGitHunks(secondaryPaneDocument())
      startNativeGitAction(editorGitRepository, "refresh history", "", [
        "log", "--format=%H%x00%an%x00%ae%x00%at%x00%s%x00", "-n", "100"],
        source = action)
      return
    elif action == "refresh history":
      let commits = parseLog(job.result.output, 100)
      renderNativeGitHistory(commits)
      editorViewState.statusMessage = "Git: " & editorGitActionSource &
        " complete — history refreshed"
    elif action == "switch branch":
      let reloaded = reloadCleanDocumentsForBranch(editorGitRepository)
      if activeWorkspace != nil: refreshWorkspacePreview()
      resetImeState()
      if syntaxState != nil:
        syntaxState.close()
        syntaxState = nil
      refreshEditorSyntax()
      scheduleNativeGitHunks(activeDocument())
      scheduleNativeSecondaryGitHunks(secondaryPaneDocument())
      editorViewState.statusMessage = "Git: switched to " & editorGitActionSource &
        " (reloaded " & $reloaded & " clean tab(s))"
    elif action == "show":
      showNativeLspPanel("Git Commit", job.result.output.splitLines())
      editorViewState.statusMessage = "Git: commit details"
    elif action == "show file diff":
      let title = "Git Diff — " & editorGitActionPath
      let lines = if output.len > 0: job.result.output.splitLines()
        else: @["No textual differences to show"]
      showNativeLspPanel(title, lines)
      editorViewState.statusMessage = "Git: file diff"
    elif action == "blame":
      let blameLines = parseBlame(job.result.output)
      renderNativeGitBlame(blameLines, editorGitActionPath)
      let location = if not sameDocument: -1
        elif document == nil: -1
        else: document[].buffer.lineColumn(editorViewState.cursor).line
      editorViewState.statusMessage = if location >= 0 and location < blameLines.len:
        "Blame: " & blameLines[location].author & " — " & blameLines[location].summary
        else: "Git blame unavailable for this line"
    elif action == "checkout":
      if document != nil and document[].path == editorGitActionDocumentPath:
        discard editorSession.reloadActiveDocument(editorViewState)
        resetImeState()
        refreshEditorSyntax()
      editorViewState.statusMessage = "Git: checked out " & editorGitActionSource
    else:
      editorViewState.statusMessage = "Git: " & action
      refreshEditorSyntax()
    cancelNativeGitAction()

  proc handleGitGutterClick(document: ptr FileDocument, bounds: Rect,
                            scrollLine: int, uiX, uiY: float32,
                            modifiers: uint32, scrollYFraction = 0'f32): bool =
    if document == nil or document[].path.len == 0: return false
    let repository = gitRepositoryForDocument(document)
    let relative = gitRelativePathForDocument(document, repository)
    if repository == nil or relative.len == 0: return false
    let action = gitGutterActionAt(uiX, uiY,
      float32(bounds.origin.x), float32(bounds.origin.y), 8'f32, scrollLine,
      modifiers, scrollYFraction)
    if action.kind == gitGutterNone: return false
    # Option-click follows the standard staged-diff convention and reverses
    # the operation against the index; a normal click stages the worktree hunk.
    startNativeGitHunkAction(repository, relative,
      if action.kind == gitGutterUnstage: "unstage hunk" else: "stage hunk",
      action.line)
    true

  proc clearNativeGitHunks() =
    platformSetEditorGitHunks(nil, 0)

  proc clearNativeSecondaryGitHunks() =
    platformSetSecondaryEditorGitHunks(nil, 0)

  proc resetNativeSecondaryGitHunks() =
    if editorSecondaryGitDiffJob != nil:
      editorSecondaryGitDiffJob.cancel()
      editorSecondaryGitDiffJob = nil
    editorSecondaryGitPath = ""
    clearNativeSecondaryGitHunks()

  proc taskWorkingDirectory(document: ptr FileDocument): string =
    if activeWorkspace != nil and activeWorkspace.rootPaths.len > 0:
      return activeWorkspace.rootPaths[0]
    if document != nil and document[].path.len > 0:
      return splitFile(absolutePath(document[].path)).dir
    getCurrentDir()

  proc startNativeTask(command: string) =
    if editorTaskJob != nil and not editorTaskJob.done:
      editorTaskJob.cancel()
    editorTaskCommand = command
    editorTaskOutput = ""
    editorTaskProblems.setLen(0)
    if editorTerminalVisible:
      editorTerminalVisible = false
      editorTerminalFocused = false
      platformSetTerminalVisible(false)
    editorTaskOutputVisible = true
    platformSetTaskOutputVisible(true)
    platformSetTaskOutputCancellable(true)
    editorWorkspaceUi.openPanel(panelTasks)
    setupDemoUi()
    let title = "Task — " & command
    platformSetTaskOutputTitle(title.cstring, uint32(title.len))
    editorTaskJob = startTask(TaskSpec(command: "/bin/zsh",
      args: @["-lc", command], workingDirectory: taskWorkingDirectory(activeDocument())))
    editorViewState.statusMessage = "Task: running " & command

  proc cancelNativeTask() =
    if editorWasmComponentJob.handle != nil:
      cancelWasmComponentJob(editorWasmComponentJob)
      editorWasmComponentCancelRequested = true
      platformSetTaskOutputCancellable(false)
      editorViewState.statusMessage = "WASM component: cancelling"
      return
    if editorTaskJob == nil or editorTaskJob.done:
      editorViewState.statusMessage = "Task: no running task"
      return
    editorTaskJob.cancel()
    platformSetTaskOutputCancellable(false)
    editorViewState.statusMessage = "Task: cancelled"

  proc pollNativeWasmComponent(): bool =
    if editorWasmComponentJob.handle == nil: return false
    var errorMessage = ""
    let state = pollWasmComponentJob(editorWasmComponentJob, errorMessage)
    if state == 0: return true
    if errorMessage.len > 0:
      editorTaskOutput = errorMessage
      platformSetTaskOutputText(editorTaskOutput.cstring,
        uint32(editorTaskOutput.len))
    if state == 1:
      editorViewState.statusMessage = "WASM component succeeded: " &
        editorWasmComponentId
    elif editorWasmComponentCancelRequested or state == 2:
      editorViewState.statusMessage = if editorWasmComponentCancelRequested:
        "WASM component cancelled: " & editorWasmComponentId
        else: "WASM component failed: " & editorWasmComponentId &
          (if errorMessage.len > 0: " — " & errorMessage else: "")
    else:
      editorViewState.statusMessage = "WASM component unavailable: " &
        editorWasmComponentId
    deleteWasmComponentJob(editorWasmComponentJob)
    editorWasmComponentId = ""
    editorWasmComponentCancelRequested = false
    platformSetTaskOutputCancellable(false)
    true

  proc pollNativeTask() =
    if pollNativeWasmComponent(): return
    if editorTaskJob == nil: return
    let completed = editorTaskJob.poll()
    let taskResult = editorTaskJob.result
    if taskResult.output != editorTaskOutput:
      editorTaskOutput = taskResult.output
      editorTaskProblems = taskResult.problems
      platformSetTaskOutputText(editorTaskOutput.cstring, uint32(editorTaskOutput.len))
    if not completed: return
    editorTaskProblems = taskResult.problems
    if editorExtensionCatalogSync:
      editorExtensionCatalogSync = false
      if taskResult.status == taskSucceeded:
        try:
          editorExtensionCatalog = parseExtensionCatalog(taskResult.output)
          editorViewState.statusMessage = "Extension catalog synced: " &
            $editorExtensionCatalog.len & " entries"
          showNativeExtensionCatalog()
        except ExtensionCatalogError as error:
          editorViewState.statusMessage = "Extension catalog rejected: " & error.msg
      else:
        editorViewState.statusMessage = "Extension catalog sync failed"
      editorTaskJob = nil
      platformSetTaskOutputCancellable(false)
      return
    let output = taskResult.output.strip()
    let summary = if output.len == 0: "" else:
      let lines = output.splitLines
      " — " & lines[lines.high]
    let problemSummary = if editorTaskProblems.len == 0: "" else:
      " (" & $editorTaskProblems.len & " problems)"
    let truncationSummary = if taskResult.outputTruncated: " [output truncated]" else: ""
    case taskResult.status
    of taskSucceeded:
      editorViewState.statusMessage = "Task succeeded: " & editorTaskCommand &
        truncationSummary & summary
    of taskFailed:
      editorViewState.statusMessage = "Task failed (" & $taskResult.exitCode & "): " &
        editorTaskCommand & problemSummary & truncationSummary & summary
    of taskCancelled:
      editorViewState.statusMessage = "Task cancelled: " & editorTaskCommand
    else: discard
    editorTaskJob = nil
    platformSetTaskOutputCancellable(false)

  proc pollNativeUpdate() =
    if editorUpdateJob == nil: return
    if not editorUpdateJob.pollUpdateDownload(): return
    if editorUpdateJob.success:
      editorUpdatePath = editorUpdateJob.destination
      editorViewState.statusMessage = "Update downloaded; it will install when Nimculus quits"
    else:
      editorViewState.statusMessage = "Update download or verification failed"
    editorUpdateJob = nil

  proc cancelNativeUpdateDownload() =
    if editorUpdateJob == nil or editorUpdateJob.done: return
    editorUpdateJob.cancelUpdateDownload()
    editorUpdateJob = nil
    editorViewState.statusMessage = "Update download cancelled"

  proc runningAppBundle(): string =
    let executable = getAppFilename()
    let candidate = parentDir(parentDir(parentDir(executable)))
    if candidate.endsWith(".app") and dirExists(candidate): candidate else: ""

  proc applyPendingUpdateAtQuit() =
    if editorUpdatePath.len == 0: return
    let appBundle = runningAppBundle()
    if appBundle.len == 0:
      editorViewState.statusMessage = "Update ready; launch from a signed .app to install"
      return
    if installMacosDmgUpdate(editorUpdatePath, appBundle, getTempDir()):
      editorViewState.statusMessage = "Update installed"
      try: removeFile(editorUpdatePath)
      except CatchableError: discard
      editorUpdatePath = ""
    else:
      editorViewState.statusMessage = "Update installation failed"

  proc toggleNativeTaskOutput() =
    if editorTaskOutputVisible:
      editorTaskOutputVisible = false
      platformSetTaskOutputVisible(false)
      return
    if editorTaskOutput.len == 0:
      editorViewState.statusMessage = "Task output is empty"
      return
    if editorTerminalVisible:
      editorTerminalVisible = false
      editorTerminalFocused = false
      platformSetTerminalVisible(false)
    editorTaskOutputVisible = true
    platformSetTaskOutputVisible(true)
    platformSetTaskOutputText(editorTaskOutput.cstring, uint32(editorTaskOutput.len))

  proc showNativeLspPanel(title: string, lines: seq[string]) =
    if lines.len == 0:
      editorViewState.statusMessage = title & ": none"
      return
    editorTaskOutput = lines.join("\n")
    platformSetTaskOutputTitle(title.cstring, uint32(title.len))
    platformSetTaskOutputText(editorTaskOutput.cstring, uint32(editorTaskOutput.len))
    if editorTerminalVisible:
      editorTerminalVisible = false
      editorTerminalFocused = false
      platformSetTerminalVisible(false)
    editorTaskOutputVisible = true
    platformSetTaskOutputVisible(true)

  proc syncNativeSymbolTree() =
    if editorSidebarMode != sidebarOutline: return
    let symbols = if pendingLspSymbols.len > 0: pendingLspSymbols else:
      pendingSyntaxSymbols
    let depths = if pendingLspSymbols.len > 0: pendingLspSymbolDepths else: @[]
    var lines = @[
      "Outline",
      "────────"
    ]
    var keys: seq[string]
    if symbols.len == 0:
      lines.add("No symbols")
    else:
      for index, symbol in symbols:
        let depth = if index < depths.len: depths[index] else: 0
        lines.add("  ".repeat(depth) & symbol.name & "  " &
          $(symbol.range.start.line + 1))
        # A symbol name alone is not stable across overloads. The LSP range
        # keeps the selected outline entry attached to the same source span.
        keys.add(symbol.name & "\x1f" & $symbol.range.start.line & ":" &
          $symbol.range.start.character & ":" & $symbol.range.finish.line & ":" &
          $symbol.range.finish.character)
    editorWorkspaceUi.replacePanelItems(panelOutline, keys)
    let text = lines.join("\n")
    platformSetEditorOutline(text.cstring, uint32(text.len), uint32(symbols.len))
    syncNativeSidebarSelection()

  proc openNativeSymbol(index: int): bool =
    let document = activeDocument()
    let symbols = if pendingLspSymbols.len > 0: pendingLspSymbols else:
      pendingSyntaxSymbols
    if document == nil or index < 0 or index >= symbols.len:
      editorViewState.statusMessage = "LSP symbol is unavailable"
      return false
    let symbol = symbols[index]
    let target = document[].buffer.byteOffsetAtUtf16Position(
      symbol.range.start.line, symbol.range.start.character)
    moveActiveEditorCursor(target)
    syncEditorCursor()
    refreshEditorSyntax()
    editorWorkspaceUi.focusCenter()
    platformFocusEditor()
    editorViewState.statusMessage = if pendingLspSymbols.len > 0:
      "LSP: " & symbol.name else: "Outline: " & symbol.name
    true

  proc updateSyntaxOutline(document: ptr FileDocument) =
    ## Tree-sitter's local outline is the immediate editor affordance. LSP
    ## document symbols replace it only when a valid response arrives; until
    ## then the Outline panel must remain useful for a plain local project.
    pendingSyntaxSymbols.setLen(0)
    if document == nil or syntaxState == nil or syntaxState.tree == nil:
      if editorSidebarMode == sidebarOutline: syncNativeSymbolTree()
      return
    for item in syntaxState.tree.outline():
      # LspRange uses UTF-16 columns. `lineColumn` is intentionally a
      # grapheme-column API for editor movement, so use the buffer's explicit
      # UTF-16 conversion at this protocol boundary (important for Japanese
      # identifiers and astral symbols before a declaration).
      let start = document[].buffer.utf16Position(int(item.startByte))
      let finish = document[].buffer.utf16Position(int(item.endByte))
      pendingSyntaxSymbols.add(LspSymbol(name: item.name, kind: 0,
        range: LspRange(
          start: LspPosition(line: start.line, character: start.character),
          finish: LspPosition(line: finish.line, character: finish.character))))
    if editorSidebarMode == sidebarOutline: syncNativeSymbolTree()

  proc expandNativeSyntaxSelection(expand: bool) =
    let document = activeDocument()
    if document == nil or syntaxState == nil or syntaxState.tree == nil:
      editorViewState.statusMessage = "Syntax selection unavailable"
      return
    let selection = activeEditorSelection()
    let source = document[].buffer.toString()
    let target = if expand:
      syntaxState.tree.largerSelection(uint32(selection.startByte),
        uint32(selection.endByte))
    else:
      syntaxState.tree.smallerSelection(uint32(selection.startByte),
        uint32(selection.endByte), uint32(activeEditorCursor()))
    if target.startByte == uint32(selection.startByte) and
        target.endByte == uint32(selection.endByte):
      editorViewState.statusMessage = if expand:
        "No larger syntax selection" else: "No smaller syntax selection"
      return
    let start = floorGraphemeBoundary(source, int(target.startByte))
    let finish = floorGraphemeBoundary(source, int(target.endByte))
    moveActiveEditorCursor(start)
    moveActiveEditorCursor(finish, true)
    syncEditorCursor()
    refreshEditorSyntax()
    persistSession()
    editorViewState.statusMessage = if expand:
      "Expanded syntax selection" else: "Shrank syntax selection"

  proc moveNativeSyntaxSibling(next: bool) =
    let document = activeDocument()
    if document == nil or syntaxState == nil or syntaxState.tree == nil:
      editorViewState.statusMessage = "Syntax navigation unavailable"
      return
    let selection = activeEditorSelection()
    let target = syntaxState.tree.syntaxSibling(uint32(selection.startByte),
      uint32(selection.endByte), next)
    if target.startByte == uint32(selection.startByte) and
        target.endByte == uint32(selection.endByte):
      editorViewState.statusMessage = if next:
        "No next syntax sibling" else: "No previous syntax sibling"
      return
    let source = document[].buffer.toString()
    let start = floorGraphemeBoundary(source, int(target.startByte))
    let finish = floorGraphemeBoundary(source, int(target.endByte))
    moveActiveEditorCursor(start)
    moveActiveEditorCursor(finish, true)
    syncEditorCursor()
    refreshEditorSyntax()
    persistSession()
    editorViewState.statusMessage = if next:
      "Selected next syntax sibling" else: "Selected previous syntax sibling"

  proc moveNativeToEnclosingBracket() =
    let document = activeDocument()
    if document == nil:
      editorViewState.statusMessage = "Bracket navigation unavailable"
      return
    let source = document[].buffer.toString()
    let selection = activeEditorSelection()
    let target = if syntaxState != nil and syntaxState.tree != nil:
      syntax.moveToEnclosingBracket(syntaxState.tree, selection.startByte,
        selection.endByte, activeEditorCursor())
    else:
      syntax.moveToEnclosingBracket(source, selection.startByte,
        selection.endByte, activeEditorCursor())
    if target < 0:
      editorViewState.statusMessage = "No enclosing bracket"
      return
    moveActiveEditorCursor(floorGraphemeBoundary(source, target))
    syncEditorCursor()
    refreshEditorSyntax()
    persistSession()
    editorViewState.statusMessage = "Moved to enclosing bracket"

  proc syntaxFoldCandidates(document: ptr FileDocument,
                            state: EditorSyntaxState): seq[FoldRange] =
    if document == nil or state == nil or state.tree == nil: return
    let source = document[].buffer.toString()
    for candidate in state.tree.foldRanges(source):
      if candidate.endByte <= candidate.startByte or candidate.endByte > uint32(source.len):
        continue
      let startLine = document[].buffer.lineColumn(int(candidate.startByte)).line
      let endLine = document[].buffer.lineColumn(int(candidate.endByte) - 1).line
      if endLine > startLine:
        var duplicate = false
        for existing in result:
          if existing.startByte == candidate.startByte and
              existing.endByte == candidate.endByte:
            duplicate = true
            break
        if not duplicate:
          result.add(candidate)

  proc sameFold(left, right: FoldRange): bool =
    left.startByte == right.startByte and left.endByte == right.endByte

  proc toggleNativeFold(expand: bool, all = false, toggle = false,
                        recursive = false) =
    let document = if editorSession.split and editorSession.splitActivePane == 1:
      secondaryPaneDocument() else: activeDocument()
    let state = if editorSession.split and editorSession.splitActivePane == 1:
      secondarySyntaxState else: syntaxState
    if document == nil or state == nil or state.tree == nil:
      editorViewState.statusMessage = "Folding unavailable"
      return
    var view = focusedEditorView()
    let candidates = syntaxFoldCandidates(document, state)
    if candidates.len == 0:
      view.statusMessage = "No foldable syntax"
      storeFocusedEditorView(view)
      return
    if all:
      if expand:
        view.foldedRanges.setLen(0)
        view.statusMessage = "Unfolded all"
      else:
        view.foldedRanges = candidates
        view.statusMessage = "Folded all"
      storeFocusedEditorView(view)
      syncEditorCursor()
      refreshEditorSyntax()
      return
    let cursorLine = document[].buffer.lineColumn(view.cursor).line
    var target: FoldRange
    var found = false
    var bestSize = high(int)
    for candidate in candidates:
      let startLine = document[].buffer.lineColumn(int(candidate.startByte)).line
      let endLine = document[].buffer.lineColumn(int(candidate.endByte) - 1).line
      let isTarget = if recursive:
        startLine <= cursorLine and cursorLine <= endLine
      elif not expand:
        startLine == cursorLine
      else:
        startLine <= cursorLine and cursorLine <= endLine
      if isTarget:
        let size = int(candidate.endByte - candidate.startByte)
        if not found or size < bestSize:
          target = candidate
          bestSize = size
          found = true
    if not found:
      view.statusMessage = if expand: "No enclosing fold" else: "No foldable syntax on this line"
      storeFocusedEditorView(view)
      return
    if recursive:
      let targetStartLine = document[].buffer.lineColumn(int(target.startByte)).line
      let targetEndLine = document[].buffer.lineColumn(int(target.endByte) - 1).line
      if expand:
        var kept: seq[FoldRange]
        for folded in view.foldedRanges:
          let foldedStartLine = document[].buffer.lineColumn(int(folded.startByte)).line
          let foldedEndLine = document[].buffer.lineColumn(int(folded.endByte) - 1).line
          if foldedStartLine < targetStartLine or foldedEndLine > targetEndLine:
            kept.add(folded)
        view.foldedRanges = kept
        view.statusMessage = "Unfolded recursively"
      else:
        for candidate in candidates:
          let candidateStartLine = document[].buffer.lineColumn(int(candidate.startByte)).line
          let candidateEndLine = document[].buffer.lineColumn(int(candidate.endByte) - 1).line
          if candidateStartLine < targetStartLine or candidateEndLine > targetEndLine:
            continue
          var alreadyFolded = false
          for folded in view.foldedRanges:
            if folded.sameFold(candidate):
              alreadyFolded = true
              break
          if not alreadyFolded:
            view.foldedRanges.add(candidate)
        view.statusMessage = "Folded recursively"
      storeFocusedEditorView(view)
      syncEditorCursor()
      refreshEditorSyntax()
      persistSession()
      return
    var existing = -1
    for index, folded in view.foldedRanges:
      if folded.sameFold(target):
        existing = index
        break
    if expand:
      if existing >= 0: view.foldedRanges.delete(existing)
      else: view.statusMessage = "Already unfolded"
      if existing >= 0: view.statusMessage = "Unfolded"
    elif existing >= 0 and toggle:
      view.foldedRanges.delete(existing)
      view.statusMessage = "Unfolded"
    elif existing >= 0:
      view.statusMessage = if expand: "Already unfolded" else: "Already folded"
    else:
      view.foldedRanges.add(target)
      view.statusMessage = "Folded"
    storeFocusedEditorView(view)
    syncEditorCursor()
    refreshEditorSyntax()
    persistSession()

  proc foldNativeAtLevel(level: int) =
    ## Match Zed's FoldAtLevel actions using the nesting depth of the
    ## Tree-sitter fold candidates. The underlying text and byte positions are
    ## unchanged; only the focused pane's display map is updated.
    if level < 1: return
    let document = if editorSession.split and editorSession.splitActivePane == 1:
      secondaryPaneDocument() else: activeDocument()
    let state = if editorSession.split and editorSession.splitActivePane == 1:
      secondarySyntaxState else: syntaxState
    if document == nil or state == nil or state.tree == nil:
      editorViewState.statusMessage = "Folding unavailable"
      return
    let candidates = syntaxFoldCandidates(document, state)
    if candidates.len == 0:
      editorViewState.statusMessage = "No foldable syntax"
      return
    var view = focusedEditorView()
    var foldedAtLevel = 0
    for candidate in candidates:
      var depth = 1
      for enclosing in candidates:
        if enclosing.startByte < candidate.startByte and
            enclosing.endByte > candidate.endByte:
          inc depth
      if depth != level: continue
      var alreadyFolded = false
      for folded in view.foldedRanges:
        if folded.sameFold(candidate):
          alreadyFolded = true
          break
      if not alreadyFolded:
        view.foldedRanges.add(candidate)
      inc foldedAtLevel
    view.statusMessage = if foldedAtLevel == 0:
      "No foldable syntax at level " & $level
    else:
      "Folded level " & $level
    storeFocusedEditorView(view)
    syncEditorCursor()
    refreshEditorSyntax()
    persistSession()

  proc lspSelectionRange(document: ptr FileDocument): LspRange =
    if document == nil: return
    let selection = activeEditorSelection()
    let start = document[].buffer.utf16Position(selection.startByte)
    let finish = document[].buffer.utf16Position(selection.endByte)
    LspRange(start: LspPosition(line: start.line, character: start.character),
      finish: LspPosition(line: finish.line, character: finish.character))

  proc applyLspWorkspaceEdits(edits: seq[LspWorkspaceEdit], label: string): bool =
    ## Apply a complete workspace edit as one in-memory validation pass per
    ## file. This follows Zed's workspace-edit boundary: ranges are converted
    ## using the target buffer's UTF-16 mapping, and no partial range update is
    ## allowed when edits overlap or use invalid UTF-8 boundaries.
    if edits.len == 0: return false
    var grouped: seq[LspWorkspaceEdit]
    for item in edits:
      if item.uri.len == 0 or item.edits.len == 0: continue
      grouped.add(item)
    if grouped.len == 0: return false
    for item in grouped:
      let path = filePathFromUri(item.uri)
      if path.len == 0:
        editorViewState.statusMessage = label & " skipped: unsupported URI"
        return false
      var target: FileDocument
      let tabIndex = editorSession.tabIndexForPath(path)
      if tabIndex >= 0:
        target = editorSession.tabs[tabIndex].document
      else:
        try: target = openDocument(path)
        except CatchableError as error:
          editorViewState.statusMessage = label & " failed: " & error.msg
          return false
      var bufferEdits: seq[Edit]
      for textEdit in item.edits:
        let startByte = target.buffer.byteOffsetAtUtf16Position(
          textEdit.range.start.line, textEdit.range.start.character)
        let endByte = target.buffer.byteOffsetAtUtf16Position(
          textEdit.range.finish.line, textEdit.range.finish.character)
        bufferEdits.add(Edit(startByte: startByte, endByte: endByte,
          text: textEdit.newText))
      try:
        target.buffer.applyEdits(bufferEdits)
      except CatchableError as error:
        editorViewState.statusMessage = label & " rejected: " & error.msg
        return false
      if tabIndex >= 0:
        editorSession.tabs[tabIndex].document = target
      else:
        try: target.save()
        except CatchableError as error:
          editorViewState.statusMessage = label & " failed: " & error.msg
          return false
    editorViewState.statusMessage = "LSP: " & label & " applied"
    syncEditorCursor()
    refreshEditorSyntax()
    persistSession()
    true

  proc pollNativeLspFeatureResults() =
    if lspBridge == nil: return
    let document = activeDocument()
    var references = lspBridge.takeReferenceLocations()
    if references.len > 0:
      var lines: seq[string]
      for location in references:
        lines.add(filePathFromUri(location.uri) & ":" &
          $(location.range.start.line + 1) & ":" & $(location.range.start.character + 1))
      showNativeLspPanel("LSP References", lines)
    let symbols = lspBridge.takeSymbols()
    if symbols.len > 0:
      pendingLspSymbols.setLen(0)
      pendingLspSymbolDepths.setLen(0)
      var lines: seq[string]
      proc appendSymbol(symbol: LspSymbol, depth: int) =
        pendingLspSymbols.add(symbol)
        pendingLspSymbolDepths.add(depth)
        lines.add($(pendingLspSymbols.len) & ". " & "  ".repeat(depth) & symbol.name & "  " &
          $(symbol.range.start.line + 1))
        for child in symbol.children:
          appendSymbol(child, depth + 1)
      for symbol in symbols: appendSymbol(symbol, 0)
      syncNativeSymbolTree()
      lines.add("")
      lines.add("Use `open symbol <number>` to navigate")
      showNativeLspPanel("LSP Symbols", lines)
    let semanticTokens = lspBridge.takeSemanticTokens()
    if semanticTokens.len > 0:
      editorLspSemanticTokens = semanticTokens
      if document != nil:
        editorLspSemanticTokenPath = document[].path
        editorLspSemanticTokenSource = document[].buffer.toString()
      refreshEditorSyntax()
      editorViewState.statusMessage = "LSP: semantic tokens applied"
    let actions = lspBridge.takeCodeActions()
    if actions.len > 0:
      pendingLspCodeActions = actions
      var lines: seq[string]
      for index, action in actions:
        lines.add($(index + 1) & ". " & action.title)
      lines.add("")
      lines.add("Use `apply code action <number>` to apply")
      showNativeLspPanel("LSP Code Actions", lines)
    let resolvedAction = lspBridge.takeResolvedCodeAction()
    if resolvedAction.title.len > 0:
      var action = resolvedAction
      # The resolve response is complete; do not issue codeAction/resolve again.
      action.data = nil
      pendingLspCodeActions = @[action]
      editorViewState.statusMessage = "LSP: code action resolved; apply code action 1"
      showNativeLspPanel("LSP Code Action Ready", @[
        "1. " & action.title, "", "Use `apply code action 1` to apply"])
    let renameEdits = lspBridge.takeRenameEdits()
    if renameEdits.len > 0:
      pendingLspRename = renameEdits
      var lines: seq[string]
      for workspaceEdit in renameEdits:
        lines.add(filePathFromUri(workspaceEdit.uri) & " (" & $workspaceEdit.edits.len & " edits)")
      lines.add("")
      lines.add("Use `apply rename` to apply")
      showNativeLspPanel("LSP Rename Preview", lines)
    let signature = lspBridge.takeSignatureHelp()
    if signature.signatures.len > 0:
      let active = max(0, min(signature.activeSignature, signature.signatures.high))
      let selected = signature.signatures[active]
      editorLspSignatureText = selected.label
      if signature.signatures.len > 1:
        editorLspSignatureText = "[" & $(active + 1) & "/" &
          $signature.signatures.len & "] " & editorLspSignatureText
      if selected.documentation.len > 0:
        editorLspSignatureText.add("\n" & selected.documentation)
      if document != nil:
        let location = document[].buffer.lineColumn(activeEditorCursor())
        let pane = if editorSession.split and editorSession.splitActivePane == 1: 1 else: 0
        let scrollLine = if editorSession.split and editorSession.splitActivePane == 1:
          editorSession.secondaryView.scrollLine else: editorViewState.scrollLine
        let scrollFraction = if editorSession.split and editorSession.splitActivePane == 1:
          editorSession.secondaryView.scrollYFraction else: editorViewState.scrollYFraction
        platformSetEditorHoverPane(uint32(pane))
        platformSetEditorHoverPosition(float64(float32(location.column) * 7.2'f32),
          float64(float32(location.line - scrollLine) * 18'f32 - scrollFraction))
      syncNativeHover()
      var lines: seq[string]
      for item in signature.signatures:
        lines.add(item.label & (if item.documentation.len > 0: " — " &
            item.documentation else: ""))
      showNativeLspPanel("LSP Signature Help", lines)
    let hintResult = lspBridge.takeInlayHintsWithPath()
    if hintResult.path.len > 0:
      let secondary = secondaryPaneDocument()
      if document != nil and document[].path == hintResult.path:
        editorLspInlayHints = hintResult.hints
        editorLspInlayHintPath = document[].path
        editorLspInlayHintSource = document[].buffer.toString()
        syncNativeInlayHints(document)
      elif secondary != nil and secondary[].path == hintResult.path:
        editorLspSecondaryInlayHints = hintResult.hints
        editorLspSecondaryInlayHintPath = secondary[].path
        editorLspSecondaryInlayHintSource = secondary[].buffer.toString()
        syncNativeSecondaryInlayHints(secondary)
      let hints = hintResult.hints
      var lines: seq[string]
      for hint in hints:
        lines.add($(hint.position.line + 1) & ":" & $(hint.position.character + 1) & " " & hint.label)
      showNativeLspPanel("LSP Inlay Hints", lines)
    let commandEdits = lspBridge.takeCommandEdits()
    if commandEdits.len > 0:
      discard applyLspWorkspaceEdits(commandEdits, "code action command")

  proc syncNativeTerminal() =
    var sessionTitles: seq[string]
    for index in 0 ..< editorTerminals.len:
      sessionTitles.add("Terminal " & $(index + 1))
    let titles = sessionTitles.join("\n")
    platformSetTerminalSessions(titles.cstring, uint32(titles.len),
      uint32(max(0, editorTerminalIndex)))
    if editorTerminal == nil: return
    let screen = editorTerminal.screen
    let viewportStart = terminalViewportStart(screen.lineCount(), screen.rows,
      editorTerminalScrollOffset)
    var text = ""
    var runs: seq[NativeTerminalRun]
    var byteOffset = 0
    for rowIndex in 0 ..< screen.rows:
      if rowIndex > 0: text.add('\n')
      let row = screen.lineAt(viewportStart + rowIndex)
      for columnIndex, cell in row:
        if cell.width == 0: continue
        let cellText = screen.cellText(cell)
        text.add(cellText)
        let style = screen.cellStyle(cell)
        let hyperlink = screen.cellHyperlinkUri(cell)
        let endByte = byteOffset + cellText.len
        let flags = (if style.bold: 1'u32 else: 0'u32) or
          (if style.dim: 2'u32 else: 0'u32) or
          (if style.italic: 4'u32 else: 0'u32) or
          (if style.underline: 8'u32 else: 0'u32) or
          (if style.inverse: 16'u32 else: 0'u32) or
          (if style.strikethrough: 32'u32 else: 0'u32)
        runs.add(NativeTerminalRun(startByte: uint32(byteOffset), endByte: uint32(endByte),
          flags: flags,
          row: uint32(rowIndex), column: uint32(columnIndex),
          cellWidth: uint32(max(1, cell.width)),
          foregroundKind: uint32(ord(style.foreground.kind)), foregroundIndex: uint32(max(0,
              style.foreground.index)),
          foregroundRed: uint32(style.foreground.red), foregroundGreen: uint32(
              style.foreground.green),
          foregroundBlue: uint32(style.foreground.blue),
          backgroundKind: uint32(ord(style.background.kind)), backgroundIndex: uint32(max(0,
              style.background.index)),
          backgroundRed: uint32(style.background.red), backgroundGreen: uint32(
              style.background.green),
          backgroundBlue: uint32(style.background.blue),
          hyperlinkUri: if hyperlink.len > 0: hyperlink.cstring else: nil))
        byteOffset = endByte
      if rowIndex + 1 < screen.rows: inc byteOffset
    if runs.len > 0:
      platformSetTerminalRuns(text.cstring, uint32(text.len), addr runs[0], uint32(runs.len))
    else:
      platformSetTerminalRuns(text.cstring, uint32(text.len), nil, 0)

  proc activateNativeTerminal(index: int) =
    if index < 0 or index >= editorTerminals.len: return
    editorTerminalIndex = index
    editorTerminal = editorTerminals[index]
    editorTerminalSelection = TerminalSelection()
    editorTerminalScrollOffset = 0
    editorTerminalScrollRemainder = 0'f32
    if editorTerminalVisible:
      platformSetTerminalSelection(0, 0, 0, 0)
    syncNativeTerminal()
    editorViewState.statusMessage = "Terminal " & $(index + 1) & "/" &
      $editorTerminals.len

  proc newNativeTerminal(workingDirectory = "") =
    let cwd = if workingDirectory.len > 0:
      workingDirectory
    elif activeWorkspace != nil and activeWorkspace.rootPaths.len > 0:
      activeWorkspace.rootPaths[0]
    elif activeDocument() != nil and activeDocument()[].path.len > 0:
      splitFile(absolutePath(activeDocument()[].path)).dir
    else: getCurrentDir()
    try:
      let shell = if appSettings != nil:
        appSettings.stringSetting("terminal.shell", "/bin/zsh")
      else: "/bin/zsh"
      let session = newTerminalPty(shell, cwd, 120, 8)
      editorTerminals.add(session)
      activateNativeTerminal(editorTerminals.high)
      editorTaskOutputVisible = false
      platformSetTaskOutputVisible(false)
      editorTerminalVisible = true
      editorTerminalFocused = true
      platformSetTerminalVisible(true)
      syncNativeTerminal()
      editorViewState.statusMessage = "Terminal " &
        $(editorTerminalIndex + 1) & "/" & $editorTerminals.len & " opened"
    except CatchableError as error:
      editorViewState.statusMessage = "Terminal failed: " & error.msg

  proc terminalOverlayBounds(): tuple[x, y, width, height: float32] =
    if float32(demoBottomDockBounds.size.width) > 0 and
        float32(demoBottomDockBounds.size.height) > 0:
      return (x: float32(demoBottomDockBounds.origin.x),
        y: float32(demoBottomDockBounds.origin.y),
        width: float32(demoBottomDockBounds.size.width),
        height: float32(demoBottomDockBounds.size.height))
    let height = min(180'f32, max(72'f32, float32(demoEditorBounds.size.height) * 0.42'f32))
    (x: float32(demoEditorBounds.origin.x),
     y: float32(demoEditorBounds.origin.y) + float32(demoEditorBounds.size.height) - height,
     width: float32(demoEditorBounds.size.width), height: height)

  proc terminalPointAt(x, y: float32): TerminalPoint =
    let bounds = terminalOverlayBounds()
    let cellWidth = max(1'f32, float32(platformTerminalCellWidth()))
    let lineHeight = max(1'f32, float32(platformTerminalLineHeight()))
    let insetX = max(0'f32, float32(platformTerminalInsetX()))
    let insetY = max(0'f32, float32(platformTerminalInsetY()))
    let viewportStart = terminalViewportStart(editorTerminal.screen.lineCount(),
      editorTerminal.screen.rows, editorTerminalScrollOffset)
    TerminalPoint(
      row: viewportStart + max(0, min(editorTerminal.screen.rows - 1,
        int(floor((y - bounds.y - insetY) / lineHeight)))),
      column: max(0, min(editorTerminal.screen.columns,
        int(floor((x - bounds.x - insetX) / cellWidth)))))

  proc terminalContains(x, y: float32): bool =
    let bounds = terminalOverlayBounds()
    x >= bounds.x and x < bounds.x + bounds.width and
      y >= bounds.y and y < bounds.y + bounds.height

  proc syncNativeTerminalSelection() =
    if editorTerminal == nil: return
    let screen = editorTerminal.screen
    let selection = screen.normalizedSelection(editorTerminalSelection)
    let viewportStart = terminalViewportStart(screen.lineCount(), screen.rows,
      editorTerminalScrollOffset)
    let viewportEnd = viewportStart + screen.rows - 1
    if selection.active.row < viewportStart or selection.anchor.row > viewportEnd:
      platformSetTerminalSelection(0, 0, 0, 0)
      return
    let startRow = max(selection.anchor.row, viewportStart)
    let endRow = min(selection.active.row, viewportEnd)
    let startColumn = if startRow == selection.anchor.row: selection.anchor.column else: 0
    let endColumn = if endRow == selection.active.row: selection.active.column else: screen.columns
    platformSetTerminalSelection(uint32(startRow - viewportStart), uint32(startColumn),
      uint32(endRow - viewportStart), uint32(endColumn))

  proc writeNativeTerminalInput(input: string, paste = false) =
    if editorTerminal == nil or editorTerminal.closed: return
    let payload = if paste and editorTerminal.screen.bracketedPaste:
      "\x1b[200~" & input & "\x1b[201~"
    else: input
    discard editorTerminal.writeInput(payload)

  proc handleTerminalPointer(kind: UiEventKind, x, y: float32,
                             button: uint32, modifiers: uint32,
                             deltaY: float32, preciseScrolling: bool): bool =
    if not editorTerminalVisible or editorTerminal == nil or
        not terminalContains(x, y): return false
    if kind == pointerDown:
      editorTerminalFocused = true
    let point = terminalPointAt(x, y)
    if editorTerminal.screen.mouseReporting:
      let mouseKind = case kind
        of pointerDown: terminalMousePress
        of pointerUp: terminalMouseRelease
        of pointerMove: terminalMouseMove
        of scroll: terminalMouseScroll
        else: terminalMouseMove
      let report = editorTerminal.screen.mouseReport(mouseKind, int(button),
        point.column, point.row, deltaY, modifiers)
      if report.len > 0:
        writeNativeTerminalInput(report)
      return true
    if kind == scroll:
      let rows = terminalScrollLineDelta(editorTerminalScrollRemainder, deltaY,
        preciseScrolling, float32(platformTerminalLineHeight()))
      if rows != 0:
        editorTerminalScrollOffset = terminalScrollOffset(editorTerminalScrollOffset,
          editorTerminal.screen.lineCount(), editorTerminal.screen.rows, rows)
        editorTerminalScrollRemainder -= float32(rows)
        syncNativeTerminal()
        syncNativeTerminalSelection()
      return true
    if kind == pointerDown:
      editorTerminalSelection.anchor = terminalPointAt(x, y)
      editorTerminalSelection.active = editorTerminalSelection.anchor
      editorTerminalSelecting = true
    elif kind == pointerMove and editorTerminalSelecting:
      editorTerminalSelection.active = terminalPointAt(x, y)
    elif kind == pointerUp:
      if editorTerminalSelecting:
        editorTerminalSelection.active = terminalPointAt(x, y)
      editorTerminalSelecting = false
    else:
      return false
    syncNativeTerminalSelection()
    true

  proc toggleNativeTerminal() =
    if editorTerminalVisible:
      # Match Zed's terminal-panel Toggle: a visible terminal first receives
      # focus, and only a second invocation while it owns input closes it.
      if not editorTerminalFocused:
        editorTerminalFocused = true
        platformFocusEditor()
      else:
        editorTerminalVisible = false
        editorTerminalFocused = false
        platformSetTerminalVisible(false)
      return
    if editorTerminal == nil or editorTerminal.closed:
      newNativeTerminal()
    else:
      editorTaskOutputVisible = false
      platformSetTaskOutputVisible(false)
      editorTerminalVisible = true
      editorTerminalFocused = true
      platformSetTerminalVisible(true)
      syncNativeTerminal()
      editorViewState.statusMessage = "Terminal " &
        $(editorTerminalIndex + 1) & "/" & $editorTerminals.len

  proc switchNativeTerminal(delta: int) =
    if editorTerminals.len == 0:
      newNativeTerminal()
      return
    editorTaskOutputVisible = false
    platformSetTaskOutputVisible(false)
    var index = (editorTerminalIndex + delta) mod editorTerminals.len
    if index < 0: index += editorTerminals.len
    activateNativeTerminal(index)
    editorTerminalVisible = true
    editorTerminalFocused = true
    platformSetTerminalVisible(true)

  proc closeNativeTerminal() =
    ## Close only the selected PTY. `TerminalPty.close` terminates its process
    ## group, so shells and their foreground descendants do not survive as
    ## orphaned processes after a tab/session is removed.
    if editorTerminalIndex < 0 or editorTerminalIndex >= editorTerminals.len:
      editorViewState.statusMessage = "Terminal: no active session"
      return
    let closingIndex = editorTerminalIndex
    let session = editorTerminals[closingIndex]
    if session != nil: session.close()
    editorTerminals.delete(closingIndex)
    editorTerminalSelection = TerminalSelection()
    editorTerminalScrollOffset = 0
    editorTerminalScrollRemainder = 0'f32
    if editorTerminals.len == 0:
      editorTerminal = nil
      editorTerminalIndex = -1
      editorTerminalVisible = false
      editorTerminalFocused = false
      platformSetTerminalVisible(false)
      syncNativeTerminal()
      editorViewState.statusMessage = "Terminal closed"
    else:
      activateNativeTerminal(min(closingIndex, editorTerminals.high))
      editorTerminalVisible = true
      editorTerminalFocused = true
      platformSetTerminalVisible(true)
      syncNativeTerminal()
      editorViewState.statusMessage = "Terminal closed — " &
        $(editorTerminalIndex + 1) & "/" & $editorTerminals.len

  proc closeNativeTerminals() =
    for session in editorTerminals:
      if session != nil: session.close()
    editorTerminals.setLen(0)
    editorTerminal = nil
    editorTerminalIndex = -1
    editorTerminalVisible = false
    editorTerminalFocused = false
    platformSetTerminalVisible(false)

  proc shutdownNativeServices() =
    ## Run only after the macOS close/quit decision has been accepted. The
    ## app owns every process it started, so do not rely on process exit to
    ## clean up task children, Git hooks, LSP workers, an update download, or
    ## workspace watcher callbacks.
    if workspaceSearchJob != nil: workspaceSearchJob.cancelSearch()
    workspaceSearchJob = nil
    if workspaceQuickOpenJob != nil: workspaceQuickOpenJob.cancelFuzzySearch()
    workspaceQuickOpenJob = nil
    if activeWorkspace != nil:
      # applicationWillTerminate persists the session after this shutdown
      # callback. Preserve the current roots before releasing the workspace.
      editorSession.workspaceRoots = activeWorkspace.rootPaths
      activeWorkspace.stopWatching()
    activeWorkspace = nil
    cancelNativeUpdateDownload()
    if editorGitDiffJob != nil and not editorGitDiffJob.done:
      editorGitDiffJob.cancel()
    editorGitDiffJob = nil
    if editorSecondaryGitDiffJob != nil and not editorSecondaryGitDiffJob.done:
      editorSecondaryGitDiffJob.cancel()
    editorSecondaryGitDiffJob = nil
    if editorGitStatusJob != nil and not editorGitStatusJob.done:
      editorGitStatusJob.cancel()
    editorGitStatusJob = nil
    if editorGitBranchJob != nil and not editorGitBranchJob.done:
      editorGitBranchJob.cancel()
    editorGitBranchJob = nil
    editorGitBranchRepository = nil
    cancelNativeGitAction()
    if editorTaskJob != nil and not editorTaskJob.done:
      editorTaskJob.cancel()
    editorTaskJob = nil
    if editorWasmComponentJob.handle != nil:
      cancelWasmComponentJob(editorWasmComponentJob)
      var componentError = ""
      if pollWasmComponentJob(editorWasmComponentJob, componentError) != 0:
        deleteWasmComponentJob(editorWasmComponentJob)
      ## If the worker is still unwinding, process termination owns the final
      ## reclamation; never free a live job from the Cocoa shutdown callback.
    for job in editorDapTerminalJobs:
      if job != nil and not job.done: job.cancel()
    editorDapTerminalJobs.setLen(0)
    stopNativeDapChildren()
    if editorDapSession != nil:
      editorDapSession.stop()
    editorDapSession = nil
    editorDapInitialized = false
    if editorAgentManager != nil:
      editorAgentManager.stopAll()
    editorAgentManager = nil
    editorAgentSessionId = -1
    if lspBridge != nil:
      lspBridge.shutdown()
    lspBridge = nil
    closeNativeTerminals()
    # Tree-sitter owns C parser/tree allocations outside Nim's ARC heap.
    # The active document normally replaces these on tab changes, but quit
    # must release the final pair explicitly as well.
    if syntaxState != nil:
      syntaxState.close()
    syntaxState = nil
    if secondarySyntaxState != nil:
      secondarySyntaxState.close()
    secondarySyntaxState = nil

  proc resizeNativeTerminals() =
    if editorTerminals.len == 0: return
    let bounds = terminalOverlayBounds()
    let dimensions = terminalGridSize(bounds.width, bounds.height,
      float32(platformTerminalCellWidth()), float32(platformTerminalLineHeight()),
      float32(platformTerminalInsetX()), float32(platformTerminalInsetY()))
    for session in editorTerminals:
      if session != nil and not session.closed and
          (session.screen.columns != dimensions.columns or
           session.screen.rows != dimensions.rows):
        session.resize(dimensions.columns, dimensions.rows)
    if editorTerminalVisible:
      syncNativeTerminal()

  proc pollNativeTerminal() =
    for index, session in editorTerminals:
      if session == nil or session.closed: continue
      let scrollbackSerialBefore = session.screen.scrollbackSerial
      let scrollbackDiscardedBefore = session.screen.scrollbackDiscardedSerial
      let output = session.pollOutput()
      if index == editorTerminalIndex and output.len > 0 and editorTerminalVisible:
        let discardedRows = session.screen.scrollbackDiscardedSerial -
          scrollbackDiscardedBefore
        if discardedRows > 0:
          editorTerminalSelection = terminalSelectionAfterScrollbackDiscard(
            editorTerminalSelection, int(discardedRows), session.screen.lineCount(),
            session.screen.columns)
        if editorTerminalScrollOffset > 0:
          let appendedRows = session.screen.scrollbackSerial - scrollbackSerialBefore
          editorTerminalScrollOffset = terminalScrollOffset(editorTerminalScrollOffset,
            session.screen.lineCount(), session.screen.rows, int(appendedRows))
        syncNativeTerminal()
        # Native selection ranges are viewport-relative. Reproject any active
        # terminal selection after output changes the visible scrollback rows.
        syncNativeTerminalSelection()

  proc scheduleNativeGitHunks(document: ptr FileDocument) =
    inc editorGitStatusGeneration
    if editorGitDiffJob != nil:
      editorGitDiffJob.cancel()
      editorGitDiffJob = nil
    if editorGitStatusJob != nil:
      editorGitStatusJob.cancel()
      editorGitStatusJob = nil
    if editorGitBranchJob != nil:
      editorGitBranchJob.cancel()
      editorGitBranchJob = nil
    editorGitStatusRepository = nil
    editorGitBranchRepository = nil
    editorGitPanelBranch = ""
    platformSetEditorGitBranch("".cstring)
    editorGitStatusDocumentPath = ""
    editorGitRepository = nil
    editorGitPath = ""
    clearNativeGitHunks()
    if document == nil or document[].path.len == 0: return
    let repository = gitRepositoryForDocument(document)
    if repository == nil: return
    let relative = gitRelativePathForDocument(document, repository)
    if relative.len == 0: return
    editorGitRepository = repository
    editorGitPath = document[].path
    editorGitStatusRepository = repository
    editorGitStatusDocumentPath = document[].path
    editorGitDiffJob = repository.startGitJob([
      "diff", "--no-ext-diff", "--unified=3", "--", relative])
    editorGitStatusJob = repository.startGitJob([
      "status", "--porcelain=v1", "--untracked-files=all", "-z"])
    refreshNativeGitPanelBranch(repository)

  proc pollNativeGitHunks() =
    if editorGitDiffJob == nil or not editorGitDiffJob.poll(): return
    let completedJob = editorGitDiffJob
    let output = completedJob.result
    editorGitDiffJob = nil
    let document = activeDocument()
    if document == nil or document[].path != editorGitPath or output.exitCode != 0:
      return
    let hunks = parseDiffHunks(output.output)
    var nativeHunks = newSeq[NativeGitHunkSpan](hunks.len)
    for index, hunk in hunks:
      nativeHunks[index] = NativeGitHunkSpan(
        startLine: uint32(max(0, hunk.newStart - 1)),
        lineCount: uint32(max(1, hunk.newCount)),
        kind: uint32(ord(hunk.kind)))
    if nativeHunks.len > 0:
      platformSetEditorGitHunks(addr nativeHunks[0], uint32(nativeHunks.len))
    else:
      clearNativeGitHunks()

  proc scheduleNativeSecondaryGitHunks(document: ptr FileDocument) =
    ## Secondary panes can own a different document. Keep their diff request
    ## and line ranges independent from the primary Git panel state.
    resetNativeSecondaryGitHunks()
    if not editorSession.split or document == nil or document[].path.len == 0: return
    let repository = gitRepositoryForDocument(document)
    if repository == nil: return
    let relative = gitRelativePathForDocument(document, repository)
    if relative.len == 0: return
    editorSecondaryGitPath = document[].path
    editorSecondaryGitDiffJob = repository.startGitJob([
      "diff", "--no-ext-diff", "--unified=3", "--", relative])

  proc pollNativeSecondaryGitHunks() =
    if editorSecondaryGitDiffJob == nil or not editorSecondaryGitDiffJob.poll(): return
    let completedJob = editorSecondaryGitDiffJob
    let output = completedJob.result
    editorSecondaryGitDiffJob = nil
    let document = secondaryPaneDocument()
    if document == nil or document[].path != editorSecondaryGitPath or output.exitCode != 0:
      return
    let hunks = parseDiffHunks(output.output)
    var nativeHunks = newSeq[NativeGitHunkSpan](hunks.len)
    for index, hunk in hunks:
      nativeHunks[index] = NativeGitHunkSpan(
        startLine: uint32(max(0, hunk.newStart - 1)),
        lineCount: uint32(max(1, hunk.newCount)),
        kind: uint32(ord(hunk.kind)))
    if nativeHunks.len > 0:
      platformSetSecondaryEditorGitHunks(addr nativeHunks[0], uint32(nativeHunks.len))
    else:
      resetNativeSecondaryGitHunks()

  proc pollNativeGitStatus() =
    if editorGitStatusJob == nil or not editorGitStatusJob.poll(): return
    let completedJob = editorGitStatusJob
    editorGitStatusJob = nil
    let document = activeDocument()
    if document == nil or document[].path != editorGitStatusDocumentPath or
        completedJob.result.exitCode != 0:
      return
    let entries = parseStatus(completedJob.result.output)
    var conflicts = 0
    for entry in entries:
      if entry.conflict: inc conflicts
    editorViewState.statusMessage = "Git: " & $entries.len &
      " changed, " & $conflicts & " conflict(s)"

  proc pollNativeGitBranch() =
    if editorGitBranchJob == nil or not editorGitBranchJob.poll(): return
    let completedJob = editorGitBranchJob
    let repository = editorGitBranchRepository
    editorGitBranchJob = nil
    editorGitBranchRepository = nil
    if repository == nil or completedJob.cancelled: return
    let branch = if completedJob.result.exitCode == 0:
      completedJob.result.output.strip else: "(detached)"
    editorGitPanelBranch = if branch.len > 0: branch else: "(detached)"
    platformSetEditorGitBranch(editorGitPanelBranch.cstring)
    # The branch can arrive before or after porcelain status. Repaint only an
    # already-visible Changes list; no Git command or filesystem access occurs
    # on this path.
    if editorSidebarMode == sidebarGitStatus and editorGitStatusSourceEntries.len > 0 and
        editorGitEntriesGeneration == editorGitBranchGeneration:
      renderNativeGitStatus(editorGitStatusSourceEntries)

  proc editorVisibleLineCountForBounds(bounds: Rect): int =
    max(1, int(ceil(float32(bounds.size.height) / 18'f32)))

  proc editorVisibleLineCount(): int =
    ## Keep cursor reveal, syntax requests, and native text rendering on the
    ## same viewport contract. The old fixed 12-line value left taller windows
    ## only half painted.
    editorVisibleLineCountForBounds(demoEditorBounds)

  proc secondaryEditorVisibleLineCount(): int =
    ## A horizontal split gives the secondary pane a different viewport height;
    ## it must not borrow the primary pane's cursor and scroll geometry.
    editorVisibleLineCountForBounds(demoSecondaryEditorBounds)

proc setupPersistencePaths() =
  let directory = when defined(macosx):
    getHomeDir() / "Library" / "Application Support" / "Nimculus"
  else:
    getHomeDir() / ".local" / "share" / "nimculus"
  if not dirExists(directory): createDir(directory)
  sessionFilePath = directory / "session.json"
  recoveryFilePath = directory / "active.recovery"
  crashReportPath = directory / "crash-report.json"
  settingsFilePath = directory / "settings.json"

proc persistSession() =
  if sessionFilePath.len == 0: return
  try:
    editorSession.saveActiveView(editorViewState)
    editorSession.saveSecondaryActiveView(editorSession.secondaryView)
    if activeWorkspace != nil: editorSession.workspaceRoots = activeWorkspace.rootPaths
    editorWorkspaceUi.saveWorkspaceUi(editorSession)
    saveSession(editorSession, sessionFilePath, preserveDirty = not discardDirtyOnExit)
    let document = activeDocument()
    if not suppressRecoveryWrite and document != nil and document[].buffer.isDirty:
      writeRecovery(document[], recoveryFilePath)
    elif fileExists(recoveryFilePath):
      removeFile(recoveryFilePath)
    suppressRecoveryWrite = false
    discardDirtyOnExit = false
    sessionPersistence.clear()
  except CatchableError:
    discard

proc scheduleSessionPersistence() =
  ## Text input can arrive at frame rate. Persisting the full session from
  ## both the AppKit timer and idle callback serialized every open buffer over
  ## and over again while typing. Debounce ordinary edits, but cap the delay
  ## so crash recovery is never deferred indefinitely during continuous input.
  if sessionFilePath.len == 0: return
  let now = epochTime()
  sessionPersistence.schedule(now)

proc flushScheduledSessionPersistence() =
  if sessionPersistence.isDue(epochTime()):
    persistSession()

proc syncRecentFiles() =
  when defined(macosx):
    var paths = newSeq[cstring](editorSession.recentFiles.len)
    for index, path in editorSession.recentFiles:
      paths[index] = path.cstring
    if paths.len > 0:
      platformSetRecentFiles(addr paths[0], uint32(paths.len))
    else:
      platformSetRecentFiles(nil, 0)

proc restoreSession() =
  if sessionFilePath.len == 0: return
  if fileExists(sessionFilePath):
    try:
      editorSession = loadSession(sessionFilePath)
    except CatchableError:
      editorSession = EditorSession(activeTab: -1)
  if fileExists(recoveryFilePath):
    try:
      editorSession.addTab(recoverDocument(recoveryFilePath))
      resetEditorViewState()
      editorViewState.statusMessage = "Recovered unsaved document"
    except CatchableError:
      discard
  editorSession.loadActiveView(editorViewState)
  editorSession.loadSecondaryActiveView()
  demoSplitRatio = editorSession.effectiveSplitRatio
  demoSplitEnabled = editorSession.split
  demoSplitDirection = editorSession.splitDirection
  # Bottom-panel processes are not restorable. Clear the persisted open bit
  # before constructing the workspace too, so the next persistence write
  # cannot reintroduce an empty dock from stale session metadata.
  editorSession.workspaceBottomDockOpen = false
  editorWorkspaceUi = initWorkspaceUi(editorSession)
  # Project navigation is the primary Zed-like startup surface. Restoring an
  # old Outline selection leaves an empty, low-value pane beside the editor
  # and obscures the files users need to act on first.
  editorWorkspaceUi.leftDock.isOpen = true
  editorWorkspaceUi.leftDock.activePanel = panelFiles
  # A terminal or task cannot survive process relaunch. Restoring only this
  # dock's geometry while its native presenter is absent leaves an inert blank
  # region over the editor, so always reopen it through an explicit action.
  editorWorkspaceUi.bottomDock.isOpen = false
  editorWorkspaceUi.focusedRegion = regionCenter
  editorSidebarMode = sidebarFiles
  if editorSession.split:
    discard editorWorkspaceUi.splitFocusedPane(if editorSession.splitDirection == splitVertical:
      paneVertical else: paneHorizontal, editorSession.effectiveSplitRatio)
    if editorSession.effectiveSplitSecondaryTab() >= 0:
      discard editorWorkspaceUi.selectPaneTab(editorWorkspaceUi.center.second.pane.id,
        editorSession.effectiveSplitSecondaryTab())
    if editorSession.splitActivePane == 1:
      discard editorWorkspaceUi.focusPane(editorWorkspaceUi.center.second.pane.id)

proc reloadWorkspaceSettings(root: string) =
  when defined(macosx) or defined(windows):
    if appSettings == nil: return
    let workspacePath = absolutePath(root) / ".nimculus" / "settings.json"
    if appSettings.workspacePath == workspacePath: return
    appSettings.workspacePath = workspacePath
    # Force SettingsStore.reload to observe the new workspace layer even when
    # the previous and new files happen to have the same timestamp.
    appSettings.workspaceStamp = -1
    discard appSettings.reload()
    applySettingsKeymap()
    applySettingsTheme()

proc openActiveWorkspace(path: string) =
  when defined(macosx) or defined(windows):
    if activeWorkspace != nil: activeWorkspace.stopWatching()
    # A search job owns the workspace snapshot it is traversing.  Drop it
    # before replacing activeWorkspace so results from the previous root
    # cannot be rendered after the switch.
    if workspaceSearchJob != nil: workspaceSearchJob.cancelSearch()
    workspaceSearchJob = nil
    if workspaceQuickOpenJob != nil: workspaceQuickOpenJob.cancelFuzzySearch()
    workspaceQuickOpenJob = nil
    activeWorkspace = openWorkspace(path)
    when defined(macosx):
      platformSetWorkspaceOpen(true)
      # Keep the center entry surface until the first document opens. The
      # native implementation leaves the workspace Files tree visible beside
      # it, so opening a folder never produces a blank editor.
      platformSetWelcomeVisible(activeDocument() == nil)
    workspaceExpandedDirectories = activeWorkspace.rootPaths
    workspaceRevealPath = ""
    reloadWorkspaceSettings(activeWorkspace.root)
    activeWorkspace.startWatching()
    workspaceSearchQuery = ""
    workspaceSearchScope = ""
    workspaceQuickOpenQuery = ""
    workspaceSearchResults.setLen(0)
    workspaceSearchCancelled = false
    refreshWorkspacePreview()
    when defined(macosx):
      # A folder chosen from the welcome surface should immediately become a
      # visible project, but keyboard focus remains in the center editor.
      editorWorkspaceUi.leftDock.activePanel = panelFiles
      editorWorkspaceUi.leftDock.isOpen = true
      editorWorkspaceUi.focusedRegion = regionCenter
      setupDemoUi()

proc refreshWorkspacePreview() =
  when defined(macosx) or defined(windows):
    # Workspace opening can refresh the preview while the platform-specific
    # settings store is still being constructed. Keep that boundary safe, but
    # initialize settings before the first normal workspace refresh below.
    if activeWorkspace == nil or appSettings == nil: return
    when defined(macosx): platformSetWorkspaceOpen(true)
    workspacePreviewMode = "tree"
    workspacePreviewEntries.setLen(0)
    var lines = @["Files", "────────"]
    # The active document is the presentation source of truth. A watcher
    # refresh can happen after the document callback and before
    # workspaceRevealPath is updated, so derive a canonical target here too.
    var revealTarget = canonicalOpenPath(workspaceRevealPath)
    let currentDocument = activeDocument()
    if currentDocument != nil and currentDocument[].path.len > 0:
      revealTarget = canonicalOpenPath(currentDocument[].path)
    var revealRoot = ""
    var revealRelative = ""
    if revealTarget.len > 0:
      try:
        let location = activeWorkspace.splitWorkspacePath(revealTarget)
        revealRoot = location.root
        revealRelative = normalizedPath(location.relative)
      except CatchableError:
        discard
    # Follow Zed's Project Panel ordering: expanded children are emitted
    # directly below their directory. Traversal remains lazy because only
    # directories in workspaceExpandedDirectories are opened; do not impose a
    # fixed row limit here. A fixed cap made valid files disappear from the
    # Files panel once a repository had more than 192 visible entries.
    proc containsReveal(path: string): bool =
      let candidate = canonicalOpenPath(path)
      revealTarget == candidate or revealTarget.startsWith(candidate / "")
    proc appendDirectory(root, relative: string, depth: int) =
      var children = activeWorkspace.listChildrenAt(root, relative)
      children.sort(proc(a, b: WorkspaceEntry): int =
        let aPriority = if containsReveal(a.path): 0 else: 1
        let bPriority = if containsReveal(b.path): 0 else: 1
        result = cmp(aPriority, bPriority)
        if result == 0:
          # Match Zed's Project Panel default (DirectoriesFirst): folders
          # remain discoverable as navigation containers while files retain a
          # stable lexical order beneath them.
          let aDirectory = a.kind == WorkspaceFileKind.directory
          let bDirectory = b.kind == WorkspaceFileKind.directory
          if aDirectory != bDirectory:
            result = if aDirectory: -1 else: 1
          else:
            result = cmp(a.relativePath, b.relativePath))
      for entry in children:
        workspacePreviewEntries.add(entry)
        let icon = appSettings.iconForPath(entry.path,
          entry.kind == WorkspaceFileKind.directory)
        let relativeName = entry.path.extractFilename
        let expanded = entry.kind == WorkspaceFileKind.directory and
          entry.path in workspaceExpandedDirectories
        let marker = if entry.kind == WorkspaceFileKind.directory:
          if expanded: "▾" else: "▸" else: icon
        lines.add(repeat("  ", depth) & marker & " " & relativeName)
        if expanded:
          appendDirectory(root, entry.relativePath, depth + 1)
    var roots = activeWorkspace.rootPaths
    roots.sort(proc(a, b: string): int =
      let aPriority = if containsReveal(a): 0 else: 1
      let bPriority = if containsReveal(b): 0 else: 1
      result = cmp(aPriority, bPriority)
      if result == 0: result = cmp(a, b))
    for root in roots:
      let rootName = if root.extractFilename.len > 0: root.extractFilename else: root
      let expanded = root in workspaceExpandedDirectories
      workspacePreviewEntries.add(WorkspaceEntry(path: root, relativePath: "",
        kind: WorkspaceFileKind.directory))
      lines.add((if expanded: "▾" else: "▸") & " " & rootName)
      if expanded:
        appendDirectory(root, "", 1)
    let text = lines.join("\n")
    when defined(macosx):
      editorWorkspaceUi.replacePanelItems(panelFiles,
        workspacePreviewEntries.mapIt(it.path))
      # Keep the Project tree aligned with the active editor, as Zed does:
      # revealing a document expands its ancestry and selects the concrete
      # row rather than merely moving it closer to the top of the list.
      var revealedIndex = -1
      if revealTarget.len > 0:
        for index, entry in workspacePreviewEntries:
          let sameCanonicalPath = canonicalOpenPath(entry.path) == revealTarget
          let sameWorkspaceIdentity = revealRoot.len > 0 and
            entry.rootPath == revealRoot and
            normalizedPath(entry.relativePath) == revealRelative
          if sameCanonicalPath or sameWorkspaceIdentity:
            revealedIndex = index
            break
      if revealedIndex >= 0:
        discard editorWorkspaceUi.selectPanelItem(panelFiles, revealedIndex)
      # File watcher and workspace mutations refresh this cache in the
      # background. They must not steal the active Git/Outline panel just
      # because Files happens to be the data source being updated. Present
      # the rebuilt tree only while Files is the selected left-dock surface;
      # opening a workspace already selects Files before calling this path.
      if editorWorkspaceUi.leftDock.isOpen and
          editorWorkspaceUi.leftDock.activePanel == panelFiles:
        editorSidebarMode = sidebarFiles
        platformSetEditorSidebar(text.cstring, uint32(text.len),
          uint32(workspacePreviewEntries.len), uint32(sidebarFiles))
        if revealedIndex >= 0:
          # The generic dock selection may still point at the workspace root
          # after a list refresh. The active document is the stronger source
          # of truth for Files presentation.
          platformSetEditorSidebarSelection(uint32(revealedIndex))
        else:
          syncNativeSidebarSelection()
    else:
      # The macOS sidebar is intentionally native-only until another platform
      # needs the same interaction contract. Keep the established Win32
      # preview functional rather than leaking AppKit's sidebar ABI into it.
      platformSetEditorText(text.cstring, uint32(text.len))

proc refreshWorkspaceAfterMutation(message: string) =
  when defined(macosx) or defined(windows):
    if activeWorkspace != nil:
      activeWorkspace.startWatching()
      editorViewState.statusMessage = message
      refreshWorkspacePreview()

proc rebaseOpenDocuments(oldPath, newPath: string) =
  ## Keep open buffers attached to a file after a Files-panel rename. Zed's
  ## Project Panel and Buffer store share the rename transaction; leaving the
  ## old path here would turn an ordinary rename into a false external-delete
  ## alert and make the next Save write to the removed pathname.
  let oldCanonical = canonicalOpenPath(oldPath)
  let newCanonical = canonicalOpenPath(newPath)
  if oldCanonical.len == 0 or newCanonical.len == 0: return
  let oldPrefix = oldCanonical / ""
  proc replacePrefix(path: string): string =
    let canonical = canonicalOpenPath(path)
    if canonical == oldCanonical:
      return newCanonical
    if canonical.startsWith(oldPrefix):
      return newCanonical / canonical[oldPrefix.len .. ^1]
    path
  for tab in editorSession.tabs.mitems:
    if tab.document.path.len == 0: continue
    let rebased = replacePrefix(tab.document.path)
    if rebased == tab.document.path: continue
    tab.document.path = rebased
    tab.document.acceptExternalState()
    tab.title = splitFile(rebased).name
  for index in 0 ..< editorSession.recentFiles.len:
    editorSession.recentFiles[index] = replacePrefix(editorSession.recentFiles[index])
  if workspaceRevealPath.len > 0:
    workspaceRevealPath = replacePrefix(workspaceRevealPath)
  if workspaceSearchScope.len > 0:
    workspaceSearchScope = replacePrefix(workspaceSearchScope)
  when defined(macosx):
    if editorGitHistoryPath.len > 0:
      editorGitHistoryPath = replacePrefix(editorGitHistoryPath)
    if editorGitActionDocumentPath.len > 0:
      editorGitActionDocumentPath = replacePrefix(editorGitActionDocumentPath)

when defined(macosx):
  proc selectedWorkspacePanelEntry(): WorkspaceEntry =
    if activeWorkspace == nil or editorSidebarMode != sidebarFiles:
      raise newException(ValueError, "Files panel is unavailable")
    let index = editorWorkspaceUi.panelSelectedIndex(panelFiles)
    if index < 0 or index >= workspacePreviewEntries.len:
      raise newException(ValueError, "No workspace entry is selected")
    workspacePreviewEntries[index]

  proc workspaceDestinationForSelection(entry: WorkspaceEntry): tuple[root, relative: string] =
    let base = if entry.kind == WorkspaceFileKind.directory: entry.path else: entry.path.parentDir
    activeWorkspace.splitWorkspacePath(base)

  proc uniqueWorkspaceCopyPath(path: string): string =
    let parts = splitFile(path)
    var suffix = " copy"
    var candidate = parts.dir / (parts.name & suffix & parts.ext)
    var index = 2
    while fileExists(candidate) or dirExists(candidate):
      candidate = parts.dir / (parts.name & suffix & " " & $index & parts.ext)
      inc index
    candidate

  proc expandWorkspaceDirectoryTree(startPath: string) =
    if activeWorkspace == nil: return
    var pending = @[startPath]
    while pending.len > 0:
      let directory = pending.pop()
      let location = activeWorkspace.splitWorkspacePath(directory)
      if directory notin workspaceExpandedDirectories:
        workspaceExpandedDirectories.add(directory)
      for child in activeWorkspace.listChildrenAt(location.root, location.relative):
        if child.kind == WorkspaceFileKind.directory:
          pending.add(child.path)

  proc duplicateSelectedWorkspaceEntry() =
    try:
      let entry = selectedWorkspacePanelEntry()
      if entry.relativePath.len == 0:
        raise newException(ValueError, "Workspace root cannot be duplicated")
      let sourceLocation = activeWorkspace.splitWorkspacePath(entry.path)
      let destinationPath = uniqueWorkspaceCopyPath(entry.path)
      let destinationLocation = activeWorkspace.splitWorkspacePath(destinationPath)
      discard activeWorkspace.copyEntryBetweenRoots(sourceLocation.root,
        sourceLocation.relative, destinationLocation.root, destinationLocation.relative)
      workspaceRevealPath = destinationPath
      refreshWorkspaceAfterMutation("Duplicated " & entry.path.extractFilename)
    except CatchableError as error:
      editorViewState.statusMessage = "Duplicate failed: " & error.msg

  proc pasteWorkspaceEntry() =
    if workspaceClipboardPath.len == 0:
      editorViewState.statusMessage = "No workspace entry is on the clipboard"
      return
    try:
      let selected = selectedWorkspacePanelEntry()
      let sourceLocation = activeWorkspace.splitWorkspacePath(workspaceClipboardPath)
      if sourceLocation.relative.len == 0:
        raise newException(ValueError, "Workspace root cannot be pasted")
      let destinationBase = workspaceDestinationForSelection(selected)
      let sourceName = workspaceClipboardPath.extractFilename
      let destinationRelative = if destinationBase.relative.len == 0: sourceName
        else: destinationBase.relative / sourceName
      if workspaceClipboardCut and sourceLocation.root == destinationBase.root:
        let oldPath = activeWorkspace.entryPathAt(sourceLocation.root, sourceLocation.relative)
        let newPath = activeWorkspace.renameEntryAt(sourceLocation.root,
          sourceLocation.relative, destinationRelative)
        rebaseOpenDocuments(oldPath, newPath)
        workspaceRevealPath = newPath
      else:
        let newPath = activeWorkspace.copyEntryBetweenRoots(sourceLocation.root,
          sourceLocation.relative, destinationBase.root, destinationRelative)
        if workspaceClipboardCut:
          activeWorkspace.deleteEntryAt(sourceLocation.root, sourceLocation.relative)
        workspaceRevealPath = newPath
      let action = if workspaceClipboardCut: "Moved " else: "Copied "
      editorViewState.statusMessage = action & sourceName
      workspaceClipboardPath = ""
      workspaceClipboardCut = false
      refreshWorkspacePreview()
      syncRecentFiles()
      syncEditorCursor()
      refreshEditorSyntax()
      persistSession()
    except CatchableError as error:
      editorViewState.statusMessage = "Paste failed: " & error.msg

  proc copyOrCutSelectedWorkspaceEntry(cut: bool) =
    try:
      let entry = selectedWorkspacePanelEntry()
      if entry.relativePath.len == 0:
        raise newException(ValueError, "Workspace root cannot be transferred")
      workspaceClipboardPath = entry.path
      workspaceClipboardCut = cut
      editorViewState.statusMessage = (if cut: "Cut " else: "Copied ") &
        entry.path.extractFilename
    except CatchableError as error:
      editorViewState.statusMessage = error.msg

  proc deleteSelectedWorkspaceEntry(permanent: bool) =
    try:
      let entry = selectedWorkspacePanelEntry()
      if entry.relativePath.len == 0:
        raise newException(ValueError, "Workspace root cannot be deleted")
      let command = if permanent: "workspaceDelete:" else: "workspaceTrash:"
      receiveNativeCommand((command & entry.path).cstring)
    except CatchableError as error:
      editorViewState.statusMessage = error.msg

proc revealActiveDocumentInWorkspace() =
  ## Expand only the ancestors of the active document. This follows the
  ## project-panel reveal behavior without eagerly traversing a large root.
  if activeWorkspace == nil:
    editorViewState.statusMessage = "Workspace not open"
    return
  let document = if editorSession.split and editorSession.splitActivePane == 1:
    secondaryPaneDocument() else: activeDocument()
  if document == nil or document[].path.len == 0:
    editorViewState.statusMessage = "Active document has no file path"
    return
  let documentPath = canonicalOpenPath(document[].path)
  workspaceRevealPath = documentPath
  var matched = false
  for configuredRoot in activeWorkspace.rootPaths:
    let root = canonicalOpenPath(configuredRoot)
    let prefix = root / ""
    if documentPath == root or documentPath.startsWith(prefix):
      matched = true
      var directory = documentPath.parentDir
      while true:
        if directory notin workspaceExpandedDirectories:
          workspaceExpandedDirectories.add(directory)
        if directory == root: break
        let parent = directory.parentDir
        if parent == directory or not parent.startsWith(prefix): break
        directory = parent
      break
  if not matched:
    editorViewState.statusMessage = "Active file is outside the workspace"
    return
  refreshWorkspacePreview()
  editorViewState.statusMessage = "Revealed " & documentPath.extractFilename

proc collapseAllWorkspaceEntries() =
  ## Keep workspace roots visible but collapse every directory below their
  ## header. This is the Project Panel's fast reset after a deep reveal or a
  ## large manual expansion; it never traverses or reloads file contents.
  if activeWorkspace == nil:
    editorViewState.statusMessage = "Workspace not open"
    return
  workspaceExpandedDirectories.setLen(0)
  workspaceRevealPath = ""
  refreshWorkspacePreview()
  editorViewState.statusMessage = "Collapsed workspace folders"

proc workspaceRelativePayload(name, prefix: string): string =
  if not name.startsWith(prefix) or name.len <= prefix.len: return ""
  name[prefix.len .. ^1].strip

proc renderWorkspaceSearch() =
  when defined(macosx) or defined(windows):
    if activeWorkspace == nil or workspaceSearchQuery.len == 0: return
    workspacePreviewMode = "search"
    let scopeLabel = if workspaceSearchScope.len > 0:
      " — " & workspaceSearchScope.extractFilename else: ""
    var lines = @["Search: " & workspaceSearchQuery & scopeLabel, "────────"]
    let visibleCount = min(workspaceSearchResults.len, 100)
    for index in 0 ..< visibleCount:
      let result = workspaceSearchResults[index]
      lines.add(result.path & ":" & $result.line & ":" & $result.column & " " & result.text)
    if workspaceSearchJob != nil and not workspaceSearchJob.isComplete:
      lines.add("… search continues")
    elif workspaceSearchCancelled:
      lines.add("Search cancelled")
    if workspaceSearchResults.len == 0 and workspaceSearchJob != nil and
        workspaceSearchJob.isComplete:
      lines.add("No matches")
    let text = lines.join("\n")
    when defined(macosx):
      # A workspace grep is navigation state, not a replacement document.
      # Keep the active editor (and any split) visible while presenting the
      # streaming result list in its own dock, following Zed's Search panel.
      editorWorkspaceUi.openPanel(panelSearch)
      editorWorkspaceUi.leftDock.isOpen = true
      editorSidebarMode = sidebarWorkspaceSearch
      editorWorkspaceUi.replacePanelItems(panelSearch,
        workspaceSearchResults[0 ..< visibleCount].mapIt(
          it.path & "\x1f" & $it.line & ":" & $it.column))
      platformSetEditorSidebar(text.cstring, uint32(text.len),
        uint32(visibleCount), uint32(sidebarWorkspaceSearch))
      syncNativeSidebarSelection()
      setupDemoUi()
    else:
      workspacePreviewEntries.setLen(0)
      platformSetEditorHighlights(nil, 0)
      platformSetEditorComposition("".cstring)
      platformSetEditorScrollLine(0)
      platformSetEditorCursorByte(0, 0)
      platformSetEditorSelection(0, 0)
      platformSetEditorText(text.cstring, uint32(text.len))

proc renderQuickOpen() =
  when defined(macosx) or defined(windows):
    if activeWorkspace == nil or workspaceQuickOpenQuery.len == 0: return
    workspacePreviewMode = "quickOpen"
    workspaceSearchQuery = ""
    workspaceSearchScope = ""
    # Native sidebar selection reserves its first two lines for title and
    # separator, just like Files/Git. Keep that contract so a result's visual
    # row and its activation index are identical.
    var lines = @["Quick Open: " & workspaceQuickOpenQuery, "────────"]
    let visibleCount = min(workspacePreviewEntries.len, 100)
    for index in 0 ..< visibleCount:
      let entry = workspacePreviewEntries[index]
      lines.add(entry.relativePath)
    if workspaceQuickOpenJob != nil and not workspaceQuickOpenJob.isComplete:
      lines.add("… searching workspace")
    let text = lines.join("\n")
    when defined(macosx):
      # File discovery is navigation chrome, not document content. Rendering
      # results into the editor discarded the current visual context (and made
      # a split editor look empty) until a file was chosen. Reuse the native
      # Files list so click, keyboard selection, and Enter retain their normal
      # workspace semantics while the edited document remains visible.
      editorWorkspaceUi.openPanel(panelFiles)
      editorWorkspaceUi.leftDock.isOpen = true
      editorSidebarMode = sidebarFiles
      editorWorkspaceUi.replacePanelItems(panelFiles,
        workspacePreviewEntries[0 ..< visibleCount].mapIt(it.path))
      platformSetEditorSidebar(text.cstring, uint32(text.len),
        uint32(visibleCount), uint32(sidebarFiles))
      syncNativeSidebarSelection()
      setupDemoUi()
    else:
      platformSetEditorHighlights(nil, 0)
      platformSetEditorComposition("".cstring)
      platformSetEditorScrollLine(0)
      platformSetEditorCursorByte(0, 0)
      platformSetEditorSelection(0, 0)
      platformSetEditorText(text.cstring, uint32(text.len))

proc showWorkspaceSearch(query: string, scopePath = "") =
  when defined(macosx) or defined(windows):
    if workspaceSearchJob != nil: workspaceSearchJob.cancelSearch()
    workspaceSearchJob = nil
    if workspaceQuickOpenJob != nil: workspaceQuickOpenJob.cancelFuzzySearch()
    workspaceQuickOpenJob = nil
    workspaceQuickOpenQuery = ""
    workspaceSearchQuery = query
    workspaceSearchScope = scopePath
    workspaceSearchResults.setLen(0)
    workspaceSearchCancelled = false
    if activeWorkspace == nil or query.len == 0:
      if activeWorkspace != nil: refreshWorkspacePreview()
      return
    workspaceSearchJob = activeWorkspace.startSearch(query, scopePath = scopePath)
    renderWorkspaceSearch()

proc showQuickOpen(query: string) =
  when defined(macosx) or defined(windows):
    if workspaceSearchJob != nil: workspaceSearchJob.cancelSearch()
    workspaceSearchJob = nil
    if workspaceQuickOpenJob != nil: workspaceQuickOpenJob.cancelFuzzySearch()
    workspaceQuickOpenJob = nil
    workspacePreviewMode = "quickOpen"
    workspaceSearchQuery = ""
    workspaceSearchScope = ""
    workspaceSearchResults.setLen(0)
    workspaceSearchCancelled = false
    workspaceQuickOpenOpenPending = false
    workspaceQuickOpenQuery = query
    workspacePreviewEntries.setLen(0)
    if activeWorkspace == nil or query.len == 0:
      if activeWorkspace != nil: refreshWorkspacePreview()
      return
    workspaceQuickOpenJob = activeWorkspace.startFuzzySearch(query)
    renderQuickOpen()

when defined(macosx):
  proc openFilesDockEntry(path: string)

proc cancelWorkspaceSearch() =
  when defined(macosx) or defined(windows):
    if workspaceSearchJob == nil: return
    workspaceSearchJob.cancelSearch()
    workspaceSearchJob = nil
    workspaceSearchCancelled = true
    renderWorkspaceSearch()

proc pollWorkspaceSearch() =
  when defined(macosx):
    flushScheduledSessionPersistence()
    let hasActiveJob = workspaceSearchJob != nil or workspaceQuickOpenJob != nil
    if not workspaceMaintenance.shouldPoll(epochTime(), hasActiveJob): return
    let changed = if activeWorkspace == nil: @[] else: activeWorkspace.changedPaths()
    if not externalAlertShown:
      for index, tab in editorSession.tabs:
        if tab.document.path.len > 0 and tab.document.externallyChanged():
          externalAlertShown = true
          externalAlertTab = index
          platformShowExternalChange(tab.document.path.cstring)
          break
    if changed.len > 0:
      if workspaceSearchJob != nil:
        # Invalidate results produced against the pre-change filesystem view.
        workspaceSearchJob.cancelSearch()
        workspaceSearchResults.setLen(0)
        workspaceSearchCancelled = false
        workspaceSearchJob = activeWorkspace.startSearch(workspaceSearchQuery,
          scopePath = workspaceSearchScope)
      elif workspaceQuickOpenJob != nil:
        workspaceQuickOpenJob.cancelFuzzySearch()
        workspacePreviewEntries.setLen(0)
        workspaceQuickOpenJob = activeWorkspace.startFuzzySearch(workspaceQuickOpenQuery)
      elif workspacePreviewMode == "search" and workspaceSearchQuery.len > 0:
        workspaceSearchResults.setLen(0)
        workspaceSearchCancelled = false
        workspaceSearchJob = activeWorkspace.startSearch(workspaceSearchQuery,
          scopePath = workspaceSearchScope)
      elif workspacePreviewMode == "tree":
        refreshWorkspacePreview()
      elif workspacePreviewMode == "quickOpen":
        showQuickOpen(workspaceQuickOpenQuery)
    if workspaceQuickOpenJob != nil:
      for entry in workspaceQuickOpenJob.pollFuzzySearch(maxEntries = 256, maxResults = 100):
        if workspacePreviewEntries.len < 100: workspacePreviewEntries.add(entry)
      workspacePreviewEntries.sort(proc(a, b: WorkspaceEntry): int =
        compareFuzzyEntries(a, b, workspaceQuickOpenQuery))
      renderQuickOpen()
      if workspaceQuickOpenJob.isComplete:
        workspaceQuickOpenJob = nil
      if workspaceQuickOpenOpenPending and workspacePreviewEntries.len > 0:
        let entry = workspacePreviewEntries[0]
        workspaceQuickOpenOpenPending = false
        if entry.kind == WorkspaceFileKind.directory:
          openActiveWorkspace(entry.path)
        else:
          openFilesDockEntry(entry.path)
    if workspaceSearchJob == nil:
      return
    for result in workspaceSearchJob.pollSearch(maxFiles = 8, maxLines = 256):
      if workspaceSearchResults.len < 256: workspaceSearchResults.add(result)
    renderWorkspaceSearch()
    if workspaceSearchJob.isComplete: workspaceSearchJob = nil

proc activeDocument(): ptr FileDocument =
  if editorSession.tabs.len == 0 or editorSession.activeTab < 0 or
      editorSession.activeTab >= editorSession.tabs.len: return nil
  addr editorSession.tabs[editorSession.activeTab].document

proc secondaryPaneDocument(): ptr FileDocument =
  ## The second native presenter is the second leaf of the current PaneTree.
  ## Its selected item is independent from the primary session tab.
  if editorWorkspaceUi.center.isNil or editorWorkspaceUi.center.kind != paneSplit:
    return nil
  let tab = editorWorkspaceUi.center.second.pane.activeTabIndex
  if tab < 0 or tab >= editorSession.tabs.len: return nil
  addr editorSession.tabs[tab].document

proc focusedPaneTabIndex(): int =
  if editorSession.split and editorSession.splitActivePane == 1 and
      editorWorkspaceUi.center != nil and editorWorkspaceUi.center.kind == paneSplit:
    editorWorkspaceUi.center.second.pane.activeTabIndex
  else:
    editorSession.activeTab

proc documentForTab(tabIndex: int): ptr FileDocument =
  if tabIndex < 0 or tabIndex >= editorSession.tabs.len:
    return nil
  addr editorSession.tabs[tabIndex].document

proc refreshDocumentLanguageSettings() =
  ## Follow Zed's per-buffer settings boundary: document activation chooses a
  ## language overlay without waiting for a settings-file reload.
  when defined(macosx) or defined(windows):
    if appSettings == nil: return
    let document = activeDocument()
    var languageId = ""
    if document != nil and document[].path.len > 0:
      try:
        languageId = $grammarForPath(document[].path)
      except ValueError:
        discard
    if appSettings.setLanguageId(languageId):
      applySettingsKeymap()
      applySettingsTheme()

proc activeEditorCursor(): int =
  ## A split owns two independent views over the same document. Position-based
  ## commands must use the focused view rather than the primary view by
  ## default, matching Zed's active-pane command boundary.
  if editorSession.split and editorSession.splitActivePane == 1:
    editorSession.secondaryView.cursor
  else:
    editorViewState.cursor

proc activeEditorSelection(): tuple[startByte, endByte: int] =
  if editorSession.split and editorSession.splitActivePane == 1:
    editorSession.secondaryView.selectedRange()
  else:
    editorViewState.selectedRange()

proc moveActiveEditorCursor(offset: int, selecting = false) =
  editorSession.moveActivePaneCursor(editorViewState, offset, selecting)

proc syncNativeEditorStatus(document: ptr FileDocument) =
  when defined(macosx):
    let message = editorViewState.statusMessage.strip
    let status = if message.len > 0: message else: "Ready"
    if status != lastNativeEditorStatus:
      lastNativeEditorStatus = status
      platformSetEditorStatus(status.cstring)
    let location = if document == nil: (line: 0, column: 0) else:
      document[].buffer.lineColumn(editorViewState.cursor)
    var language = "Plain Text"
    if document != nil and document[].path.len > 0:
      try:
        language = $grammarForPath(document[].path)
      except ValueError:
        discard
    let lineEnding = if document != nil and document[].lineEnding == crlf: "CRLF" else: "LF"
    let languageServer = if lspBridge != nil: "LSP: 接続済み" else: "LSP: なし"
    let footer = @[
      "Ln " & $(location.line + 1) & ", Col " & $(location.column + 1),
      "Spaces: " & $max(1, editorViewState.indentWidth),
      "UTF-8",
      lineEnding,
      language,
      languageServer
    ]
    platformSetEditorFooter(footer.join("\t").cstring)

when defined(macosx):
  proc unfoldFoldContainingCursor(document: ptr FileDocument,
                                  view: var EditorViewState): bool =
    if document == nil or view.foldedRanges.len == 0: return false
    let line = document[].buffer.lineColumn(view.cursor).line
    var kept: seq[FoldRange]
    for folded in view.foldedRanges:
      let startLine = document[].buffer.lineColumn(int(folded.startByte)).line
      let endLine = document[].buffer.lineColumn(int(folded.endByte) - 1).line
      if line > startLine and line <= endLine:
        result = true
      else:
        kept.add(folded)
    if result: view.foldedRanges = kept

  proc syncNativeEditorFolds(document: ptr FileDocument, view: EditorViewState,
                             state: EditorSyntaxState, secondary = false) =
    var nativeFolds: seq[NativeFoldRange]
    if document != nil and state != nil and state.tree != nil:
      let sourceLength = document[].buffer.toString().len
      for folded in view.foldedRanges:
        if folded.endByte <= folded.startByte or int(folded.endByte) > sourceLength:
          continue
        let startLine = document[].buffer.lineColumn(int(folded.startByte)).line
        let endLine = document[].buffer.lineColumn(int(folded.endByte) - 1).line
        if endLine > startLine:
          nativeFolds.add(NativeFoldRange(startLine: uint32(startLine),
            endLine: uint32(endLine)))
    let folds = if nativeFolds.len > 0: addr nativeFolds[0] else: nil
    if secondary:
      platformSetSecondaryEditorFolds(folds, uint32(nativeFolds.len))
    else:
      platformSetEditorFolds(folds, uint32(nativeFolds.len))

proc syncEditorCursor(ensureCursor = true) =
  when defined(macosx):
    let document = activeDocument()
    # An empty editor still needs an actionable entry surface. Keep the open
    # workspace's Files tree visible, but show Welcome in the center until a
    # document is opened; a blank editor with only line 1 is not a usable
    # application state.
    platformSetWelcomeVisible(document == nil)
    if document != nil and unfoldFoldContainingCursor(document, editorViewState):
      persistSession()
    let visibleLines = editorVisibleLineCount()
    if document != nil and ensureCursor:
      # Undo/redo and external reload can shorten or reshape the buffer
      # without passing through the normal movement commands. Normalize both
      # endpoints before deriving line/UTF-16 positions or sending them to
      # NSTextInputClient, and keep the focused position in its pane viewport.
      editorViewState.ensureCursorVisible(document[].buffer, visibleLines)
    let location = if document == nil: (line: 0, column: 0) else:
      document[].buffer.lineColumn(editorViewState.cursor)
    if editorViewState.softWrap: editorViewState.scrollX = 0'f32
    let maxScrollPixels = if document == nil: 0'f32 else:
      float32(max(0, document[].buffer.lineStarts.len - visibleLines)) * 18'f32
    editorViewState.reconcileScrollPosition(18'f32, maxScrollPixels)
    platformSetEditorScrollLine(uint32(max(0, editorViewState.scrollLine)))
    platformSetEditorScrollYFraction(cdouble(max(0'f32,
      editorViewState.scrollYFraction)))
    platformSetEditorScrollX(cdouble(max(0'f32, editorViewState.scrollX)))
    platformSetEditorCursorByte(uint32(editorViewState.cursor), uint32(max(0, location.line)))
    editorViewState.scrollX = float32(max(0.0, platformEditorScrollX()))
    let selection = if document == nil: (startByte: 0, endByte: 0) else:
      editorViewState.selectedRange()
    platformSetEditorSelection(uint32(selection.startByte), uint32(selection.endByte))
    var nativeSelections: seq[NativeEditorSelection]
    if document != nil:
      for item in editorViewState.selections:
        nativeSelections.add(NativeEditorSelection(
          startByte: uint32(max(0, min(item.anchor, item.active))),
          endByte: uint32(max(0, max(item.anchor, item.active))),
          cursorByte: uint32(max(0, item.active))))
    platformSetEditorSelections(if nativeSelections.len > 0: addr nativeSelections[0] else: nil,
      uint32(nativeSelections.len))
    platformInvalidateImeCoordinates()
    platformSetEditorDirty(document != nil and document[].buffer.isDirty)
    platformSetEditorLineNumbers(editorViewState.showLineNumbers)
    platformSetEditorSoftWrap(editorViewState.softWrap)
    platformSetEditorIndentGuides(editorViewState.showIndentGuides,
      uint32(max(1, editorViewState.indentWidth)))
    syncNativeEditorFolds(document, editorViewState, syntaxState)
    platformSetEditorContext(editorContextText(document).cstring)
    syncNativeEditorStatus(document)
    var tabTitles: seq[string]
    for index, tab in editorSession.tabs:
      tabTitles.add(editorSession.tabDisplayLabel(index) &
        (if tab.document.buffer.isDirty: " •" else: ""))
    let tabsText = tabTitles.join("\n")
    let primaryTab = if editorWorkspaceUi.center != nil:
      editorWorkspaceUi.center.firstPane().activeTabIndex else: editorSession.activeTab
    platformSetEditorTabs(tabsText.cstring, uint32(tabsText.len),
      uint32(max(0, primaryTab)))
    syncSecondaryEditorView(ensureCursor)
    if not editorSession.split:
      platformSetSecondaryEditorTabs("".cstring, 0, 0)
    platformSetEditorInputPane(uint32(if editorSession.split: editorSession.splitActivePane else: 0))
  elif defined(windows):
    let document = activeDocument()
    if document != nil:
      editorViewState.clampSelectionToText(document[].buffer.toString())
    let visibleLines = max(1, int(floor(float32(demoEditorBounds.size.height) /
      windowsEditorLineHeight())))
    let location = if document == nil: (line: 0, column: 0) else:
      document[].buffer.lineColumn(editorViewState.cursor)
    if document != nil:
      let lastVisibleLine = max(0, document[].buffer.lineStarts.len - visibleLines)
      if location.line < editorViewState.scrollLine:
        editorViewState.scrollLine = location.line
      elif location.line >= editorViewState.scrollLine + visibleLines:
        editorViewState.scrollLine = min(lastVisibleLine, location.line - visibleLines + 1)
    platformSetEditorScrollLine(uint32(max(0, editorViewState.scrollLine)))
    platformSetEditorCursorByte(uint32(max(0, editorViewState.cursor)),
      uint32(max(0, location.line)))
    let selection = if document == nil: (startByte: 0, endByte: 0) else:
      editorViewState.selectedRange()
    platformSetEditorSelection(uint32(max(0, selection.startByte)),
      uint32(max(0, selection.endByte)))
    # The native backend consumes logical window coordinates for IMM32. The
    # bootstrap renderer uses the same fixed-width cell metrics and scroll
    # origin, while the final DirectWrite layout will replace these constants.
    let visibleLine = max(0, location.line - editorViewState.scrollLine)
    let cellWidth = windowsEditorCellWidth()
    let lineHeight = windowsEditorLineHeight()
    platformSetEditorCursor(
      cdouble(float32(demoEditorBounds.origin.x) + 8.0'f32 + float(location.column) * cellWidth),
      cdouble(float32(demoEditorBounds.origin.y) + 6.0'f32 + float(visibleLine) * lineHeight))
    var tabTitles: seq[string]
    for index, tab in editorSession.tabs:
      tabTitles.add(editorSession.tabDisplayLabel(index) &
        (if tab.document.buffer.isDirty: " •" else: ""))
    let tabsText = tabTitles.join("\n")
    platformSetEditorTabs(tabsText.cstring, uint32(tabsText.len),
      uint32(max(0, editorSession.activeTab)))

when defined(macosx):
  proc syncSecondaryEditorView(ensureCursor = true) =
    if not editorSession.split:
      platformSetSecondaryEditorDiagnostics(nil, 0)
      resetNativeSecondaryGitHunks()
      return
    let document = secondaryPaneDocument()
    if document == nil:
      platformSetSecondaryEditorDiagnostics(nil, 0)
      resetNativeSecondaryGitHunks()
      return
    let tab = editorWorkspaceUi.center.second.pane.activeTabIndex
    var view = editorSession.tabs[tab].secondaryView
    if unfoldFoldContainingCursor(document, view):
      editorSession.tabs[tab].secondaryView = view
      editorSession.secondaryView = view
    if ensureCursor:
      view.ensureCursorVisible(document[].buffer, secondaryEditorVisibleLineCount())
    editorSession.tabs[tab].secondaryView = view
    let location = document[].buffer.lineColumn(view.cursor)
    let selection = view.selectedRange()
    let text = document[].buffer.toString()
    var tabTitles: seq[string]
    for index, editorTab in editorSession.tabs:
      tabTitles.add(editorSession.tabDisplayLabel(index) &
        (if editorTab.document.buffer.isDirty: " •" else: ""))
    let tabsText = tabTitles.join("\n")
    platformSetSecondaryEditorTabs(tabsText.cstring, uint32(tabsText.len), uint32(tab))
    platformSetSecondaryEditorText(text.cstring, uint32(text.len))
    if view.softWrap: view.scrollX = 0'f32
    let secondaryVisibleLines = secondaryEditorVisibleLineCount()
    let maxScrollPixels = float32(max(0, document[].buffer.lineStarts.len -
      secondaryVisibleLines)) * 18'f32
    view.reconcileScrollPosition(18'f32, maxScrollPixels)
    platformSetSecondaryEditorScrollLine(uint32(max(0, view.scrollLine)))
    platformSetSecondaryEditorScrollYFraction(cdouble(max(0'f32,
      view.scrollYFraction)))
    platformSetSecondaryEditorScrollX(cdouble(max(0'f32, view.scrollX)))
    platformSetSecondaryEditorSoftWrap(view.softWrap)
    syncNativeEditorFolds(document, view, secondarySyntaxState, secondary = true)
    platformSetSecondaryEditorCursorByte(uint32(view.cursor),
      uint32(max(0, location.line)))
    view.scrollX = float32(max(0.0, platformSecondaryEditorScrollX()))
    editorSession.tabs[tab].secondaryView = view
    platformSetSecondaryEditorSelection(uint32(selection.startByte), uint32(selection.endByte))
    var nativeSelections: seq[NativeEditorSelection]
    for item in view.selections:
      nativeSelections.add(NativeEditorSelection(
        startByte: uint32(max(0, min(item.anchor, item.active))),
        endByte: uint32(max(0, max(item.anchor, item.active))),
        cursorByte: uint32(max(0, item.active))))
    platformSetSecondaryEditorSelections(if nativeSelections.len > 0: addr nativeSelections[
        0] else: nil,
      uint32(nativeSelections.len))
    syncSecondaryNativeDiagnostics(document)

  proc editorOffsetAtPoint(document: ptr FileDocument, x, y: cdouble, pane = 0): int =
    if document == nil: return 0
    if pane == 1:
      int(platformSecondaryEditorByteOffsetAtPoint(x, y))
    else:
      int(platformEditorByteOffsetAtPoint(x, y))

  proc syncNativeDiagnostics(document: ptr FileDocument) =
    if lspBridge == nil or document == nil:
      platformSetEditorDiagnostics(nil, 0)
      return
    let text = document[].buffer.toString()
    lspBridge.updateDocument(document[].path, text)
    discard lspBridge.poll()
    let diagnostics = document[].buffer.resolveDiagnostics(lspBridge.diagnostics())
    var nativeDiagnostics = newSeq[NativeDiagnosticSpan](diagnostics.len)
    for index, diagnostic in diagnostics:
      nativeDiagnostics[index] = NativeDiagnosticSpan(
        startByte: uint32(max(0, diagnostic.startByte)),
        endByte: uint32(max(0, diagnostic.endByte)),
        severity: uint32(max(0, diagnostic.severity)))
    if nativeDiagnostics.len > 0:
      platformSetEditorDiagnostics(addr nativeDiagnostics[0], uint32(nativeDiagnostics.len))
    else:
      platformSetEditorDiagnostics(nil, 0)

  proc syncSecondaryNativeDiagnostics(document: ptr FileDocument) =
    ## Synchronize the visible secondary buffer without activating it for
    ## primary-pane requests. The URI-keyed LSP session can then render its
    ## own byte offsets instead of borrowing primary diagnostics.
    if lspBridge == nil or document == nil:
      platformSetSecondaryEditorDiagnostics(nil, 0)
      return
    let text = document[].buffer.toString()
    lspBridge.syncDocument(document[].path, text)
    let diagnostics = document[].buffer.resolveDiagnostics(
      lspBridge.diagnosticsForPath(document[].path))
    var nativeDiagnostics = newSeq[NativeDiagnosticSpan](diagnostics.len)
    for index, diagnostic in diagnostics:
      nativeDiagnostics[index] = NativeDiagnosticSpan(
        startByte: uint32(max(0, diagnostic.startByte)),
        endByte: uint32(max(0, diagnostic.endByte)),
        severity: uint32(max(0, diagnostic.severity)))
    if nativeDiagnostics.len > 0:
      platformSetSecondaryEditorDiagnostics(addr nativeDiagnostics[0],
        uint32(nativeDiagnostics.len))
    else:
      platformSetSecondaryEditorDiagnostics(nil, 0)
    syncNativeSecondaryInlayHints(document)

  proc syncNativeCompletion() =
    if lspBridge == nil or not lspBridge.completionVisible:
      platformSetEditorCompletions("".cstring, 0)
      return
    let text = lspBridge.completionText()
    platformSetEditorCompletions(text.cstring, uint32(text.len))

  proc syncNativeHover() =
    if editorLspSignatureText.len > 0:
      platformSetEditorHover(editorLspSignatureText.cstring,
        uint32(editorLspSignatureText.len))
      return
    if lspBridge == nil or not lspBridge.hoverVisible:
      platformSetEditorHover("".cstring, 0)
      return
    let text = lspBridge.hoverText()
    platformSetEditorHover(text.cstring, uint32(text.len))

  proc syncNativeInlayHints(document: ptr FileDocument) =
    if document == nil:
      platformSetEditorAnnotations(nil, 0)
      return
    let text = document[].buffer.toString()
    if lspBridge != nil:
      lspBridge.syncDocument(document[].path, text)
    if lspBridge != nil and (editorLspInlayHintPath != document[].path or
        editorLspInlayHintSource != text):
      editorLspInlayHints = lspBridge.inlayHintsForPath(document[].path)
      editorLspInlayHintPath = document[].path
      editorLspInlayHintSource = text
    if editorLspInlayHints.len == 0:
      platformSetEditorAnnotations(nil, 0)
      return
    var annotations = newSeq[NativeEditorAnnotation](editorLspInlayHints.len)
    for index, hint in editorLspInlayHints:
      annotations[index] = NativeEditorAnnotation(
        line: uint32(max(0, hint.position.line)),
        character: uint32(max(0, hint.position.character)),
        kind: uint32(max(0, hint.kind)), text: hint.label.cstring)
    platformSetEditorAnnotations(addr annotations[0], uint32(annotations.len))

  proc syncNativeSecondaryInlayHints(document: ptr FileDocument) =
    if document == nil:
      editorLspSecondaryInlayHints.setLen(0)
      editorLspSecondaryInlayHintPath = ""
      editorLspSecondaryInlayHintSource = ""
      platformSetSecondaryEditorAnnotations(nil, 0)
      return
    let text = document[].buffer.toString()
    if lspBridge != nil:
      lspBridge.syncDocument(document[].path, text)
    if lspBridge != nil and (editorLspSecondaryInlayHintPath != document[].path or
        editorLspSecondaryInlayHintSource != text):
      editorLspSecondaryInlayHints = lspBridge.inlayHintsForPath(document[].path)
      editorLspSecondaryInlayHintPath = document[].path
      editorLspSecondaryInlayHintSource = text
    if editorLspSecondaryInlayHints.len == 0:
      platformSetSecondaryEditorAnnotations(nil, 0)
      return
    var annotations = newSeq[NativeEditorAnnotation](editorLspSecondaryInlayHints.len)
    for index, hint in editorLspSecondaryInlayHints:
      annotations[index] = NativeEditorAnnotation(
        line: uint32(max(0, hint.position.line)),
        character: uint32(max(0, hint.position.character)),
        kind: uint32(max(0, hint.kind)), text: hint.label.cstring)
    platformSetSecondaryEditorAnnotations(addr annotations[0], uint32(annotations.len))

  proc requestEditorCompletion() =
    let document = activeDocument()
    if document == nil or lspBridge == nil:
      platformSetEditorCompletions("".cstring, 0)
      return
    if lspBridge.requestCompletion(document[].buffer, activeEditorCursor()):
      platformSetEditorCompletions("".cstring, 0)
    else:
      platformSetEditorCompletions("".cstring, 0)

when defined(windows):
  proc windowsTabIndexAtPoint(x, y: float32): int =
    if y < 88'f32 or y > 120'f32: return -1
    var left = 24'f32
    for index, tab in editorSession.tabs:
      let title = tab.title & (if tab.document.buffer.isDirty: " •" else: "")
      var titleCharacters = 0
      for _ in title.runes: inc titleCharacters
      let width = max(92'f32, float32(titleCharacters * 8 + 28))
      if x >= left and x < left + width: return index
      left += width + 1'f32
    -1

  proc editorOffsetAtWindowsPoint(document: ptr FileDocument, x, y: float32): int =
    ## The Windows text surface is currently a fixed-width GDI bootstrap. Keep
    ## its hit testing in the editor layer, just as Zed converts a logical
    ## mouse position through its text layout before producing an anchor.
    if document == nil or document[].buffer.lineStarts.len == 0: return 0
    let editorX = float32(demoEditorBounds.origin.x)
    let editorY = float32(demoEditorBounds.origin.y)
    let lineHeight = windowsEditorLineHeight()
    let cellWidth = windowsEditorCellWidth()
    let firstLine = max(0, editorViewState.scrollLine)
    let row = max(0, int(floor((y - editorY) / lineHeight)))
    let line = min(document[].buffer.lineStarts.high, firstLine + row)
    let graphemeColumn = max(0, int(floor((x - editorX - 8'f32) / cellWidth)))
    # Screen columns are logical grapheme columns, not UTF-8 byte offsets.
    # Keep conversion in the editor buffer so Japanese, emoji, and combining
    # sequences land on the same safe boundaries as keyboard movement.
    document[].buffer.byteOffsetAtLineColumn(line, graphemeColumn)

  proc openWindowsWorkspaceEntryAtPoint(y: cdouble) =
    if activeWorkspace == nil or workspacePreviewEntries.len == 0: return
    var metrics: PlatformMetrics
    platformGetMetrics(addr metrics)
    let viewHeight = if metrics.heightPoints > 0: metrics.heightPoints else: 640'u32
    let top = float32(viewHeight) - float32(y) - float32(demoEditorBounds.origin.y)
    let line = int(floor((top - 4.0'f32) / 18.0'f32))
    let entryIndex = line - 1
    if entryIndex < 0 or entryIndex >= workspacePreviewEntries.len: return
    let entry = workspacePreviewEntries[entryIndex]
    if entry.kind == WorkspaceFileKind.directory:
      openActiveWorkspace(entry.path)
    else:
      receiveNativeFile(entry.path.cstring, false)

  proc openWindowsWorkspaceSearchResultAtPoint(y: cdouble) =
    if activeWorkspace == nil or workspaceSearchResults.len == 0: return
    var metrics: PlatformMetrics
    platformGetMetrics(addr metrics)
    let viewHeight = if metrics.heightPoints > 0: metrics.heightPoints else: 640'u32
    let top = float32(viewHeight) - float32(y) - float32(demoEditorBounds.origin.y)
    let line = int(floor((top - 4.0'f32) / 18.0'f32))
    let resultIndex = line - 1
    if resultIndex < 0 or resultIndex >= workspaceSearchResults.len: return
    let match = workspaceSearchResults[resultIndex]
    openFilesDockEntry(match.path)
    let document = if editorSession.split and editorSession.splitActivePane == 1:
      secondaryPaneDocument() else: activeDocument()
    if document != nil:
      let lineIndex = max(0, match.line - 1)
      let lineStart = document[].buffer.byteOffsetAtLineColumn(lineIndex, 0)
      editorViewState.moveCursor(min(document[].buffer.toString().len,
        lineStart + max(0, match.column - 1)))
      syncEditorCursor()
      refreshEditorSyntax()

proc refreshEditorSyntax() =
  refreshDocumentLanguageSettings()
  let document = activeDocument()
  if document == nil:
    when defined(macosx):
      pendingSyntaxSymbols.setLen(0)
      if editorSidebarMode == sidebarOutline: syncNativeSymbolTree()
      platformSetEditorDiagnostics(nil, 0)
      editorLspInlayHints.setLen(0)
      editorLspSecondaryInlayHints.setLen(0)
      platformSetEditorAnnotations(nil, 0)
      platformSetSecondaryEditorAnnotations(nil, 0)
      clearNativeGitHunks()
      refreshSecondaryEditorSyntax()
    return
  when defined(macosx):
    let currentText = document[].buffer.toString()
    if editorLspSemanticTokenPath != document[].path or
        (editorLspSemanticTokenSource.len > 0 and editorLspSemanticTokenSource != currentText):
      editorLspSemanticTokens.setLen(0)
      editorLspSemanticTokenPath = document[].path
      editorLspSemanticTokenSource = ""
    if editorLspInlayHintPath != document[].path or
        (editorLspInlayHintSource.len > 0 and editorLspInlayHintSource != currentText):
      editorLspInlayHints.setLen(0)
      editorLspInlayHintPath = document[].path
      editorLspInlayHintSource = ""
    syncNativeInlayHints(document)
  var grammar: GrammarKind
  try:
    grammar = grammarForPath(document[].path)
  except ValueError:
    # Zed keeps a buffer as plain text when language detection has no match;
    # changing from a parsed file must therefore clear the old syntax state
    # and still refresh the native text surface.
    if syntaxState != nil:
      syntaxState.close()
      syntaxState = nil
    when defined(macosx):
      platformSetEditorHighlights(nil, 0)
      pendingSyntaxSymbols.setLen(0)
      if editorSidebarMode == sidebarOutline: syncNativeSymbolTree()
      let text = document[].buffer.toString()
      platformSetEditorText(text.cstring, uint32(text.len))
      syncNativeInlayHints(document)
      syncNativeDiagnostics(document)
      scheduleNativeGitHunks(document)
      refreshSecondaryEditorSyntax()
    when defined(windows):
      platformSetEditorHighlights(nil, 0)
      let text = document[].buffer.toString()
      platformSetEditorText(text.cstring, uint32(text.len))
    return
  if syntaxState == nil or syntaxState.grammar != grammar:
    if syntaxState != nil: syntaxState.close()
    syntaxState = newEditorSyntax(document[].path, document[].buffer.toString())
  elif syntaxState != nil:
    syntaxState.update(document[].buffer.toString())
  when defined(macosx):
    updateSyntaxOutline(document)
  when defined(macosx):
    let highlights = if syntaxState == nil: @[] else:
      let visibleLines = editorVisibleLineCount()
      proc visibleByteRange(view: EditorViewState): HighlightByteRange =
        let firstLine = min(view.scrollLine, document[].buffer.lineStarts.high)
        let firstByte = document[].buffer.lineStarts[firstLine]
        let requestedLastLine = firstLine + visibleLines
        let lastByte = if requestedLastLine < document[].buffer.lineStarts.len:
          document[].buffer.lineStarts[requestedLastLine]
        else: document[].buffer.toString().len
        (firstByte: uint32(firstByte), lastByte: uint32(lastByte))
      var ranges = @[visibleByteRange(editorViewState)]
      syntaxState.visibleHighlights(ranges)
    var nativeHighlights = newSeq[NativeHighlightSpan](highlights.len)
    for index, span in highlights:
      nativeHighlights[index] = NativeHighlightSpan(startByte: span.startByte,
        endByte: span.endByte, kind: uint32(ord(span.kind)))
    for token in editorLspSemanticTokens:
      let startByte = document[].buffer.byteOffsetAtUtf16Position(token.line,
        token.startCharacter)
      let endByte = document[].buffer.byteOffsetAtUtf16Position(token.line,
        token.startCharacter + token.length)
      if endByte > startByte:
        nativeHighlights.add(NativeHighlightSpan(startByte: uint32(startByte),
          endByte: uint32(endByte), kind: uint32(token.tokenType mod 6)))
    var highlightPtr: ptr NativeHighlightSpan = nil
    if nativeHighlights.len > 0: highlightPtr = addr nativeHighlights[0]
    platformSetEditorHighlights(highlightPtr, uint32(nativeHighlights.len))
    let text = document[].buffer.toString()
    platformSetEditorCompletions("".cstring, 0)
    platformSetEditorText(text.cstring, uint32(text.len))
    syncNativeInlayHints(document)
    syncNativeDiagnostics(document)
    scheduleNativeGitHunks(document)
    refreshSecondaryEditorSyntax()
  when defined(windows):
    let highlights = if syntaxState == nil: @[] else:
      let visibleLines = max(1, int(float32(demoEditorBounds.size.height) /
        windowsEditorLineHeight()) + 2)
      let firstLine = min(editorViewState.scrollLine, document[].buffer.lineStarts.high)
      let firstByte = document[].buffer.lineStarts[firstLine]
      let requestedLastLine = firstLine + visibleLines
      let lastByte = if requestedLastLine < document[].buffer.lineStarts.len:
        document[].buffer.lineStarts[requestedLastLine]
      else: document[].buffer.toString().len
      syntaxState.visibleHighlights(uint32(firstByte), uint32(lastByte))
    var nativeHighlights = newSeq[NativeHighlightSpan](highlights.len)
    for index, span in highlights:
      nativeHighlights[index] = NativeHighlightSpan(startByte: span.startByte,
        endByte: span.endByte, kind: uint32(ord(span.kind)))
    var highlightPtr: ptr NativeHighlightSpan = nil
    if nativeHighlights.len > 0: highlightPtr = addr nativeHighlights[0]
    platformSetEditorHighlights(highlightPtr, uint32(nativeHighlights.len))
    let text = document[].buffer.toString()
    platformSetEditorText(text.cstring, uint32(text.len))

when defined(macosx):
  proc refreshSecondaryEditorSyntax() =
    ## The secondary pane may show another buffer and grammar. Its Core Text
    ## texture therefore receives a separate byte-range list instead of the
    ## primary pane's offsets.
    if not editorSession.split:
      if secondarySyntaxState != nil:
        secondarySyntaxState.close()
        secondarySyntaxState = nil
      platformSetSecondaryEditorHighlights(nil, 0)
      platformSetSecondaryEditorDiagnostics(nil, 0)
      editorLspSecondaryInlayHints.setLen(0)
      editorLspSecondaryInlayHintPath = ""
      editorLspSecondaryInlayHintSource = ""
      platformSetSecondaryEditorAnnotations(nil, 0)
      resetNativeSecondaryGitHunks()
      return
    let document = secondaryPaneDocument()
    if document == nil:
      if secondarySyntaxState != nil:
        secondarySyntaxState.close()
        secondarySyntaxState = nil
      platformSetSecondaryEditorHighlights(nil, 0)
      platformSetSecondaryEditorDiagnostics(nil, 0)
      editorLspSecondaryInlayHints.setLen(0)
      editorLspSecondaryInlayHintPath = ""
      editorLspSecondaryInlayHintSource = ""
      platformSetSecondaryEditorAnnotations(nil, 0)
      resetNativeSecondaryGitHunks()
      return
    syncNativeSecondaryInlayHints(document)
    var grammar: GrammarKind
    try:
      grammar = grammarForPath(document[].path)
    except ValueError:
      if secondarySyntaxState != nil:
        secondarySyntaxState.close()
        secondarySyntaxState = nil
      platformSetSecondaryEditorHighlights(nil, 0)
      syncNativeSecondaryInlayHints(document)
      scheduleNativeSecondaryGitHunks(document)
      return
    let text = document[].buffer.toString()
    if secondarySyntaxState == nil or secondarySyntaxState.grammar != grammar:
      if secondarySyntaxState != nil: secondarySyntaxState.close()
      secondarySyntaxState = newEditorSyntax(document[].path, text)
    else:
      secondarySyntaxState.update(text)
    let tab = editorWorkspaceUi.center.second.pane.activeTabIndex
    let view = editorSession.tabs[tab].secondaryView
    let visibleLines = secondaryEditorVisibleLineCount()
    let firstLine = min(view.scrollLine, document[].buffer.lineStarts.high)
    let firstByte = document[].buffer.lineStarts[firstLine]
    let requestedLastLine = firstLine + visibleLines
    let lastByte = if requestedLastLine < document[].buffer.lineStarts.len:
      document[].buffer.lineStarts[requestedLastLine] else: text.len
    let highlights = if secondarySyntaxState == nil: @[] else:
      secondarySyntaxState.visibleHighlights(@[(firstByte: uint32(firstByte),
        lastByte: uint32(lastByte))])
    var nativeHighlights = newSeq[NativeHighlightSpan](highlights.len)
    for index, span in highlights:
      nativeHighlights[index] = NativeHighlightSpan(startByte: span.startByte,
        endByte: span.endByte, kind: uint32(ord(span.kind)))
    let ptrHighlights = if nativeHighlights.len > 0: addr nativeHighlights[0] else: nil
    platformSetSecondaryEditorHighlights(ptrHighlights, uint32(nativeHighlights.len))
    scheduleNativeSecondaryGitHunks(document)

when defined(macosx):
  proc finishMacosGuiWorkflow(success: bool, detail: string) =
    let result = (if success: "ok " else: "fail ") & detail
    if macosGuiWorkflowResultPath.len > 0:
      try:
        writeFile(macosGuiWorkflowResultPath, result & "\n")
      except CatchableError:
        discard
    macosGuiWorkflowEnabled = false

  proc pollMacosGuiWorkflow() =
    ## Zed's visual test runner opens the Project Panel, opens a project file,
    ## and only then advances to the next surface. Keep this workflow
    ## asynchronous at the same boundaries as the application so Git and PTY
    ## work never blocks the GUI idle callback.
    if not macosGuiWorkflowEnabled: return
    if epochTime() - macosGuiWorkflowStartedAt > 20.0:
      finishMacosGuiWorkflow(false, "timeout step=" & $macosGuiWorkflowStep)
      return
    case macosGuiWorkflowStep
    of 0:
      if activeWorkspace == nil:
        finishMacosGuiWorkflow(false, "workspace-not-open")
        return
      receiveNativeCommand("__show_files__")
      macosGuiWorkflowStep = 1
    of 1:
      var candidate = ""
      for entry in workspacePreviewEntries:
        if entry.kind == WorkspaceFileKind.file:
          candidate = entry.path
          break
      if candidate.len == 0: return
      openFilesDockEntry(candidate)
      if activeDocument() == nil or activeDocument()[].path.len == 0:
        finishMacosGuiWorkflow(false, "file-open-failed")
        return
      macosGuiWorkflowStep = 2
    of 2:
      # Use the same command-palette dispatch that the visible Git History
      # action uses. The short label "git log" is a palette command, not a
      # direct native callback, so sending it raw would silently do nothing.
      receiveNativeCommand("commandPalette:git log")
      macosGuiWorkflowStep = 3
    of 3:
      if editorSidebarMode != sidebarGitHistory or editorGitHistory.len == 0: return
      receiveNativeCommand("commandPalette:new terminal")
      macosGuiWorkflowStep = 4
    of 4:
      if not editorTerminalVisible or editorTerminals.len == 0: return
      receiveNativeCommand("commandPalette:close terminal")
      macosGuiWorkflowStep = 5
    of 5:
      if editorTerminalVisible or editorTerminals.len != 0: return
      finishMacosGuiWorkflow(true, "files-editor-git-history-terminal")
    else:
      finishMacosGuiWorkflow(false, "invalid-step=" & $macosGuiWorkflowStep)

  proc pollLspAndRefreshDiagnostics() =
    let document = activeDocument()
    if document != nil: syncNativeDiagnostics(document)

  proc receiveNativeIdle() {.cdecl.} =
    if finishColdStartBenchmark(): return
    if pollSoakBenchmark(): return
    if appSettings != nil and appSettings.reload():
      applySettingsKeymap()
      applySettingsTheme()
      editorViewState.statusMessage = "Settings reloaded"
    pollNativeGitHunks()
    pollNativeSecondaryGitHunks()
    pollNativeGitBranch()
    pollNativeGitStatus()
    pollNativeGitAction()
    pollNativeTask()
    pollNativeUpdate()
    pollNativeExtensionPackage()
    pollNativeDapTerminalJobs()
    pollNativeDapChildren()
    pollNativeDap()
    pollNativeAgent()
    pollNativeTerminal()
    pollMacosGuiWorkflow()
    if lspBridge == nil:
      syncNativeEditorStatus(activeDocument())
      return
    let document = activeDocument()
    if document != nil:
      discard lspBridge.tickHover(document[].buffer)
    if lspBridge.poll():
      if document != nil: syncNativeDiagnostics(document)
      syncNativeCompletion()
      syncNativeHover()
      navigateToDefinition()
      applyPendingFormatting()
      pollNativeLspFeatureResults()
    syncNativeEditorStatus(activeDocument())

  proc acceptCurrentCompletion() =
    let document = activeDocument()
    if document == nil or lspBridge == nil or not lspBridge.completionVisible: return
    let edit = lspBridge.completionEdit(document[].buffer)
    if edit.endByte <= edit.startByte and edit.text.len == 0: return
    document[].buffer.edit(Edit(startByte: edit.startByte, endByte: edit.endByte,
      text: edit.text))
    moveActiveEditorCursor(edit.startByte + edit.text.len)
    lspBridge.hideCompletion()
    platformSetEditorCompletions("".cstring, 0)
    syncEditorCursor()
    refreshEditorSyntax()

  proc handleCompletionShortcut(event: ptr NimculusInputEvent): bool =
    if event == nil or lspBridge == nil or not lspBridge.completionVisible: return false
    case event.keyCode
    of 125'u32:
      lspBridge.completionSelected = min(lspBridge.completionItems.high,
        lspBridge.completionSelected + 1)
      syncNativeCompletion()
      true
    of 126'u32:
      lspBridge.completionSelected = max(0, lspBridge.completionSelected - 1)
      syncNativeCompletion()
      true
    of 36'u32, 48'u32:
      acceptCurrentCompletion()
      true
    of 53'u32:
      lspBridge.hideCompletion()
      syncNativeCompletion()
      true
    else: false

when defined(windows):
  proc windowsTaskWorkingDirectory(document: ptr FileDocument): string =
    if activeWorkspace != nil and activeWorkspace.rootPaths.len > 0:
      return activeWorkspace.rootPaths[0]
    if document != nil and document[].path.len > 0:
      return splitFile(absolutePath(document[].path)).dir
    getCurrentDir()

  proc startWindowsTask(command: string) =
    if windowsTaskJob != nil and not windowsTaskJob.done:
      windowsTaskJob.cancel()
    windowsTaskCommand = command
    windowsTaskOutput = ""
    windowsTaskProblems.setLen(0)
    windowsTaskOutputVisible = false
    platformSetTaskOutputVisible(false)
    windowsTaskJob = startTask(TaskSpec(command: "cmd.exe",
      args: @["/C", command],
      workingDirectory: windowsTaskWorkingDirectory(activeDocument())))
    editorViewState.statusMessage = "Task: running " & command

  proc cancelWindowsTask() =
    if windowsTaskJob == nil or windowsTaskJob.done:
      editorViewState.statusMessage = "Task: no running task"
      return
    windowsTaskJob.cancel()
    editorViewState.statusMessage = "Task: cancelled"

  proc pollWindowsTask() =
    if windowsTaskJob == nil: return
    let completed = windowsTaskJob.poll()
    let taskResult = windowsTaskJob.result
    if taskResult.output != windowsTaskOutput:
      windowsTaskOutput = taskResult.output
      windowsTaskProblems = taskResult.problems
      platformSetTaskOutputText(windowsTaskOutput.cstring, uint32(windowsTaskOutput.len))
    if not completed: return
    windowsTaskProblems = taskResult.problems
    let output = taskResult.output.strip()
    let summary = if output.len == 0: "" else:
      let lines = output.splitLines
      " — " & lines[lines.high]
    let problemSummary = if windowsTaskProblems.len == 0: "" else:
      " (" & $windowsTaskProblems.len & " problems)"
    let truncationSummary = if taskResult.outputTruncated: " [output truncated]" else: ""
    case taskResult.status
    of taskSucceeded:
      editorViewState.statusMessage = "Task succeeded: " & windowsTaskCommand &
        truncationSummary & summary
    of taskFailed:
      editorViewState.statusMessage = "Task failed (" & $taskResult.exitCode & "): " &
        windowsTaskCommand & problemSummary & truncationSummary & summary
    of taskCancelled:
      editorViewState.statusMessage = "Task cancelled: " & windowsTaskCommand
    else: discard
    windowsTaskJob = nil

  proc toggleWindowsTaskOutput() =
    if windowsTaskOutputVisible:
      windowsTaskOutputVisible = false
      platformSetTaskOutputVisible(false)
      return
    if windowsTaskOutput.len == 0:
      editorViewState.statusMessage = "Task output is empty"
      return
    if windowsTerminalVisible:
      closeWindowsTerminal()
    windowsTaskOutputVisible = true
    platformSetTaskOutputVisible(true)
    platformSetTaskOutputText(windowsTaskOutput.cstring, uint32(windowsTaskOutput.len))

  proc pollWindowsWorkspaceChanges() =
    ## Consume ReadDirectoryChangesW notifications at the UI boundary.
    ## Filesystem events are incomplete until derived views invalidate them.
    if activeWorkspace == nil: return
    let changed = activeWorkspace.changedPaths()
    if changed.len > 0:
      if workspaceSearchJob != nil:
        workspaceSearchJob.cancelSearch()
        workspaceSearchResults.setLen(0)
        workspaceSearchCancelled = false
        workspaceSearchJob = activeWorkspace.startSearch(workspaceSearchQuery,
          scopePath = workspaceSearchScope)
      elif workspaceQuickOpenJob != nil:
        workspaceQuickOpenJob.cancelFuzzySearch()
        workspacePreviewEntries.setLen(0)
        workspaceQuickOpenJob = activeWorkspace.startFuzzySearch(workspaceQuickOpenQuery)
      elif workspacePreviewMode == "tree":
        refreshWorkspacePreview()
      editorViewState.statusMessage = "Workspace updated"
    if workspaceQuickOpenJob != nil:
      for entry in workspaceQuickOpenJob.pollFuzzySearch(maxEntries = 256, maxResults = 100):
        if workspacePreviewEntries.len < 100: workspacePreviewEntries.add(entry)
      workspacePreviewEntries.sort(proc(a, b: WorkspaceEntry): int =
        compareFuzzyEntries(a, b, workspaceQuickOpenQuery))
      renderQuickOpen()
      if workspaceQuickOpenJob.isComplete: workspaceQuickOpenJob = nil
    if workspaceSearchJob != nil:
      for result in workspaceSearchJob.pollSearch(maxFiles = 8, maxLines = 256):
        if workspaceSearchResults.len < 256: workspaceSearchResults.add(result)
      renderWorkspaceSearch()
      if workspaceSearchJob.isComplete: workspaceSearchJob = nil

  proc pollWindowsWorkspace() =
    pollWindowsWorkspaceChanges()
    let document = activeDocument()
    if document == nil or document[].path.len == 0:
      externalAlertShown = false
      return
    if document[].externallyChanged():
      if not externalAlertShown:
        externalAlertShown = true
        editorViewState.statusMessage = if fileExists(document[].path):
          "File changed on disk: run reloadExternal or keepExternal"
        else:
          "File deleted on disk: run reloadExternal or keepExternal"
    else:
      externalAlertShown = false

  proc receiveNativeIdle() {.cdecl.} =
    if finishColdStartBenchmark(): return
    if pollSoakBenchmark(): return
    if appSettings != nil and appSettings.reload():
      applySettingsTheme()
      editorViewState.statusMessage = "Settings reloaded"
    pollWindowsTerminal()
    pollWindowsTask()
    pollWindowsWorkspace()
    flushScheduledSessionPersistence()

proc editEditorSelections(document: ptr FileDocument, view: var EditorViewState,
                          replacement: string): bool

proc receiveNativeTextValue(value: string, composing: bool) =
  when defined(macosx):
    if terminalOwnsInput(editorTerminalVisible, editorTerminalFocused) and
        editorTerminal != nil and not composing:
      if value.len > 0: writeNativeTerminalInput(value)
      return
  when defined(windows):
    if not composing and writeWindowsTerminalText(value): return
  imeState.receiveText(value, composing)
  when defined(macosx) or defined(windows):
    if composing:
      platformSetEditorComposition(value.cstring)
      return
    platformSetEditorComposition("".cstring)
  if not composing and value.len > 0:
    let document = if editorSession.split and editorSession.splitActivePane == 1:
      secondaryPaneDocument() else: activeDocument()
    if document != nil:
      var view = focusedEditorView()
      if editEditorSelections(document, view, value):
        storeFocusedEditorView(view)
      syncEditorCursor()
      refreshEditorSyntax()
      scheduleSessionPersistence()
      when defined(macosx):
        requestEditorCompletion()

proc receiveNativeText(text: cstring, composing: bool) {.cdecl.} =
  receiveNativeTextValue(if text == nil: "" else: $text, composing)

proc receiveNativeSelection(startByte, endByte: uint32) {.cdecl.} =
  let secondary = editorSession.split and editorSession.splitActivePane == 1
  let document = if secondary: secondaryPaneDocument() else: activeDocument()
  if document == nil: return
  let text = document[].buffer.toString()
  let length = text.len
  let anchor = floorGraphemeBoundary(text, min(int(startByte), length))
  let active = floorGraphemeBoundary(text, min(int(endByte), length))
  if secondary:
    let tab = if editorWorkspaceUi.center != nil and
        editorWorkspaceUi.center.kind == paneSplit:
      editorWorkspaceUi.center.second.pane.activeTabIndex else: -1
    if tab < 0 or tab >= editorSession.tabs.len: return
    editorSession.tabs[tab].secondaryView.selection.anchor = anchor
    editorSession.tabs[tab].secondaryView.selection.active = active
    editorSession.secondaryView = editorSession.tabs[tab].secondaryView
  else:
    editorViewState.selection.anchor = anchor
    editorViewState.selection.active = active
  syncEditorCursor()

when defined(macosx):
  proc finishSaveAllAndQuit() =
    pendingSaveAllQuitNextTab = -1
    if editorSession.hasDirtyTabs():
      platformSetCloseDecision(false)
      return
    shutdownNativeServices()
    applyPendingUpdateAtQuit()
    platformSetCloseDecision(true)
    # applicationShouldTerminate already deferred the first quit request
    # while an untitled document's Save Panel was open.
    platformConfirmQuit()

  proc continueSaveAllAndQuit() =
    while pendingSaveAllQuitNextTab >= 0 and
        pendingSaveAllQuitNextTab < editorSession.tabs.len:
      let tabIndex = pendingSaveAllQuitNextTab
      inc pendingSaveAllQuitNextTab
      if not editorSession.tabs[tabIndex].document.buffer.isDirty: continue
      if editorSession.tabs[tabIndex].document.path.len > 0:
        try:
          editorSession.tabs[tabIndex].document.save()
          editorSession.tabs[tabIndex].title =
            splitFile(editorSession.tabs[tabIndex].document.path).name
        except CatchableError as error:
          pendingSaveAllQuitNextTab = -1
          platformSetCloseDecision(false)
          editorViewState.statusMessage = "Save all failed: " & error.msg
          return
        continue
      editorSession.saveActiveView(editorViewState)
      editorSession.saveSecondaryActiveView(editorSession.secondaryView)
      editorSession.activeTab = tabIndex
      editorSession.loadActiveView(editorViewState)
      editorSession.loadSecondaryActiveView()
      syncEditorCursor()
      platformShowSavePanel()
      editorViewState.statusMessage = "Choose a location to save " &
        editorSession.tabs[tabIndex].title
      return
    finishSaveAllAndQuit()

proc receiveNativeFile(path: cstring, saving: bool) {.cdecl.} =
  if path == nil or ($path).len == 0: return
  let inputPath = $path
  if workspaceSearchJob != nil:
    workspaceSearchJob.cancelSearch()
    workspaceSearchJob = nil
  if workspaceQuickOpenJob != nil:
    workspaceQuickOpenJob.cancelFuzzySearch()
    workspaceQuickOpenJob = nil
  workspaceQuickOpenOpenPending = false
  if saving:
    let saveTab = when defined(macosx):
      if pendingCloseTabIndex >= 0 and pendingCloseTabIndex < editorSession.tabs.len:
        pendingCloseTabIndex
      elif pendingSaveTabIndex >= 0 and pendingSaveTabIndex < editorSession.tabs.len:
        pendingSaveTabIndex
      else:
        editorSession.activeTab
    else:
      editorSession.activeTab
    let document = documentForTab(saveTab)
    if document != nil:
      let existingTab = editorSession.tabIndexForSaveTarget(inputPath)
      if existingTab >= 0 and existingTab != saveTab:
        when defined(macosx):
          # An untitled tab in Save All / Quit uses this same panel callback.
          # Do not leave its asynchronous queue armed after rejecting a
          # conflicting destination, or a later ordinary Save could resume a
          # stale termination sequence.
          let wasSavingAllAndQuitting = pendingSaveAllQuitNextTab >= 0
          let wasClosingTab = pendingCloseTabIndex == saveTab
          pendingSaveTabIndex = -1
          pendingSaveAllQuitNextTab = -1
          pendingCloseTabIndex = -1
          platformSetCloseDecision(false)
          editorViewState.statusMessage = if wasSavingAllAndQuitting:
            "Save all cancelled: destination is already open"
          elif wasClosingTab:
            "Close cancelled: destination is already open"
          else:
            "Save As cancelled: destination is already open"
        else:
          editorViewState.statusMessage = "Save As cancelled: destination is already open"
        return
      try:
        document[].save(inputPath)
        if saveTab >= 0 and saveTab < editorSession.tabs.len:
          editorSession.tabs[saveTab].title =
            splitFile(document[].path).name
        externalAlertShown = false
        if editorSession.split and editorSession.splitActivePane == 1:
          editorSession.saveSecondaryActiveView(editorSession.secondaryView)
        else:
          editorSession.saveActiveView(editorViewState)
        editorSession.recordRecent(document[].path)
        syncRecentFiles()
        persistSession()
        editorViewState.statusMessage = "Saved " & document[].path
        syncEditorCursor()
        when defined(macosx):
          pendingSaveTabIndex = -1
          # The native Save Panel used by close confirmation must only allow
          # termination after the document write has actually succeeded.
          if pendingCloseTabIndex == saveTab:
            platformSetCloseDecision(true)
          elif pendingSaveAllQuitNextTab >= 0:
            platformSetCloseDecision(false)
            continueSaveAllAndQuit()
          else:
            platformSetCloseDecision(true)
      except CatchableError as error:
        editorViewState.statusMessage = "Save failed: " & error.msg
        when defined(macosx):
          pendingSaveTabIndex = -1
          platformSetCloseDecision(false)
  else:
    let filePath = canonicalOpenPath(inputPath)
    if dirExists(filePath):
      openActiveWorkspace(filePath)
      return
    try:
      let existingTab = editorSession.tabIndexForPath(filePath)
      if existingTab >= 0:
        editorSession.saveActiveView(editorViewState)
        editorSession.saveSecondaryActiveView(editorSession.secondaryView)
        editorSession.activeTab = existingTab
        editorSession.loadActiveView(editorViewState)
        editorSession.loadSecondaryActiveView()
        resetImeState()
        resetEditorTransientState()
        externalAlertShown = false
        workspacePreviewMode = ""
        if syntaxState != nil:
          syntaxState.close()
          syntaxState = nil
        when defined(macosx): editorLspSignatureText = ""
        editorSession.recordRecent(filePath)
        syncRecentFiles()
        setupDemoUi()
        revealActiveDocumentInWorkspace()
        syncEditorCursor()
        # Opening an item from Files/Quick Open must return keyboard focus to
        # the editor. The sidebar remains visible, but it must not keep the
        # next typed character or IME composition after the file is opened.
        when defined(macosx): platformFocusEditor()
        refreshEditorSyntax()
        persistSession()
        return
      workspacePreviewEntries.setLen(0)
      workspacePreviewMode = ""
      editorSession.saveActiveView(editorViewState)
      editorSession.saveSecondaryActiveView(editorSession.secondaryView)
      editorSession.addTab(openDocument(filePath))
      editorSession.loadSecondaryActiveView()
      resetImeState()
      resetEditorViewState()
      let document = activeDocument()
      if document != nil: editorViewState.moveCursor(0)
      editorSession.recordRecent(filePath)
      syncRecentFiles()
      setupDemoUi()
      revealActiveDocumentInWorkspace()
      syncEditorCursor()
      when defined(macosx): platformFocusEditor()
      refreshEditorSyntax()
      persistSession()
    except CatchableError:
      discard

proc openFilesDockEntry(path: string) =
  ## Project-panel activation targets the focused native Pane. Finder and Open
  ## panels deliberately keep using receiveNativeFile, whose primary-session
  ## activation semantics are part of the macOS application contract.
  if path.len == 0:
    return
  let filePath = canonicalOpenPath(path)
  if filePath.len == 0 or dirExists(filePath) or not editorSession.split or
      editorWorkspaceUi.center == nil or editorWorkspaceUi.center.kind != paneSplit or
      editorWorkspaceUi.focusedPane != editorWorkspaceUi.center.second.pane.id:
    receiveNativeFile(path.cstring, false)
    return
  try:
    var tab = editorSession.tabIndexForPath(filePath)
    if tab < 0:
      tab = editorSession.addBackgroundTab(openDocument(filePath))
      syncWorkspaceUiTabs()
    if not editorWorkspaceUi.selectPaneTab(editorWorkspaceUi.center.second.pane.id, tab):
      return
    # The legacy session field remains the focused-secondary bridge during the
    # migration. Keep it aligned with the tab owned by the secondary Pane;
    # syncSecondaryEditorView reads the Pane selection as the source of truth.
    editorSession.secondaryView = editorSession.tabs[tab].secondaryView
    editorSession.splitSecondaryTab = tab
    resetImeState()
    resetEditorTransientState()
    externalAlertShown = false
    editorSession.recordRecent(filePath)
    syncRecentFiles()
    syncEditorCursor()
    refreshEditorSyntax()
    # Files/Search activation can start while the secondary pane owns the
    # editor focus. Selecting its tab is not enough: AppKit's outline remains
    # first responder until the native editor view is explicitly restored,
    # which would route the next keyboard event or IME composition into the
    # sidebar instead of the newly opened document.
    platformFocusEditor()
    persistSession()
  except CatchableError as error:
    editorViewState.statusMessage = "Open failed: " & error.msg

when defined(macosx):
  proc openNativeDapFrame(frame: DapFrameInfo) =
    ## Zed activates the selected frame and opens its source at the reported
    ## line. Keep the same user-visible boundary: selecting a frame requests
    ## scopes, while activating it navigates the focused Nimculus pane.
    if frame.source.len == 0:
      editorViewState.statusMessage = "Debugger frame has no source path"
      return
    var sourcePath = frame.source
    if not isAbsolute(sourcePath):
      sourcePath = taskWorkingDirectory(activeDocument()) / sourcePath
    sourcePath = canonicalOpenPath(sourcePath)
    if sourcePath.len == 0 or not fileExists(sourcePath):
      editorViewState.statusMessage = "Debugger source is unavailable: " & frame.source
      return
    openFilesDockEntry(sourcePath)
    let tab = focusedPaneTabIndex()
    let document = documentForTab(tab)
    if document == nil or canonicalOpenPath(document[].path) != sourcePath:
      editorViewState.statusMessage = "Debugger source could not be opened: " & sourcePath
      return
    # initialize advertises zero-based line/column coordinates. DAP adapters
    # therefore report the first line as 0; the visible status is one-based.
    let targetLine = max(0, min(frame.line, document[].buffer.lineStarts.high))
    let byteOffset = document[].buffer.byteOffsetAtLineColumn(targetLine, 0)
    if editorSession.split and editorSession.splitActivePane == 1:
      var view = editorSession.tabs[tab].secondaryView
      view.moveCursor(byteOffset)
      view.scrollLine = targetLine
      editorSession.tabs[tab].secondaryView = view
      editorSession.secondaryView = view
    else:
      editorViewState.moveCursor(byteOffset)
      editorViewState.scrollLine = targetLine
    editorViewState.statusMessage = "Debugger: " & sourcePath & ":" & $(targetLine + 1)
    syncEditorCursor()
    refreshEditorSyntax()

when defined(macosx):
  proc navigateToDefinition() =
    if lspBridge == nil: return
    let locations = lspBridge.takeDefinitionLocations()
    if locations.len == 0: return
    let targetPath = filePathFromUri(locations[0].uri)
    if targetPath.len == 0: return
    let current = activeDocument()
    if current == nil or canonicalOpenPath(current[].path) != canonicalOpenPath(targetPath):
      openFilesDockEntry(targetPath)
    let document = if editorSession.split and editorSession.splitActivePane == 1:
      secondaryPaneDocument() else: activeDocument()
    if document == nil: return
    let location = locations[0].range.start
    let byteOffset = document[].buffer.byteOffsetAtUtf16Position(location.line, location.character)
    moveActiveEditorCursor(byteOffset)
    editorViewState.statusMessage = "LSP: definition"
    syncEditorCursor()
    refreshEditorSyntax()

  proc applyPendingFormatting() =
    if lspBridge == nil: return
    let edits = lspBridge.takeFormattingEdits()
    if edits.len == 0: return
    let document = activeDocument()
    if document == nil: return
    var bufferEdits: seq[Edit]
    for edit in edits:
      let startByte = document[].buffer.byteOffsetAtUtf16Position(
        edit.range.start.line, edit.range.start.character)
      let endByte = document[].buffer.byteOffsetAtUtf16Position(
        edit.range.finish.line, edit.range.finish.character)
      bufferEdits.add(Edit(startByte: startByte, endByte: endByte,
        text: edit.newText))
    try:
      document[].buffer.applyEdits(bufferEdits)
      editorViewState.clampSelectionToText(document[].buffer.toString())
      editorViewState.statusMessage = "LSP: formatted"
      syncEditorCursor()
      refreshEditorSyntax()
    except CatchableError as error:
      editorViewState.statusMessage = "LSP formatting failed: " & error.msg

  proc openWorkspaceEntryAtPoint(y: cdouble) =
    if activeWorkspace == nil or workspacePreviewEntries.len == 0: return
    var metrics: PlatformMetrics
    platformGetMetrics(addr metrics)
    let viewHeight = if metrics.heightPoints > 0: metrics.heightPoints else: 640'u32
    let top = float32(viewHeight) - float32(y) - float32(demoEditorBounds.origin.y)
    let line = int(floor((top - 4.0'f32) / 18.0'f32))
    let entryIndex = line - 1
    if entryIndex < 0 or entryIndex >= workspacePreviewEntries.len: return
    let entry = workspacePreviewEntries[entryIndex]
    if entry.kind == WorkspaceFileKind.directory:
      openActiveWorkspace(entry.path)
    else:
      openFilesDockEntry(entry.path)

  proc openWorkspaceSearchResultAtPoint(y: cdouble) =
    if activeWorkspace == nil or workspaceSearchResults.len == 0: return
    var metrics: PlatformMetrics
    platformGetMetrics(addr metrics)
    let viewHeight = if metrics.heightPoints > 0: metrics.heightPoints else: 640'u32
    let top = float32(viewHeight) - float32(y) - float32(demoEditorBounds.origin.y)
    let line = int(floor((top - 4.0'f32) / 18.0'f32))
    let resultIndex = line - 1
    if resultIndex < 0 or resultIndex >= workspaceSearchResults.len: return
    let match = workspaceSearchResults[resultIndex]
    openFilesDockEntry(match.path)
    let document = if editorSession.split and editorSession.splitActivePane == 1:
      secondaryPaneDocument() else: activeDocument()
    if document != nil:
      let lineIndex = max(0, match.line - 1)
      let lineStart = document[].buffer.byteOffsetAtLineColumn(lineIndex, 0)
      # Workspace results are a position-based navigation command. Opening a
      # result must move the pane that owns keyboard focus, just like LSP
      # definition navigation; otherwise a secondary-pane search silently
      # moves the hidden primary cursor.
      moveActiveEditorCursor(min(document[].buffer.toString().len,
        lineStart + max(0, match.column - 1)))
      syncEditorCursor()
      refreshEditorSyntax()

proc previousBoundary(text: string, offset: int): int =
  previousGraphemeBoundary(text, offset)

proc nextBoundary(text: string, offset: int): int =
  nextGraphemeBoundary(text, offset)

proc lineEndOffset(document: ptr FileDocument, line: int): int =
  if document == nil or document[].buffer.lineStarts.len == 0: return 0
  document[].buffer.lineEndByteOffset(line)

proc focusedEditorView(): EditorViewState =
  if editorSession.split and editorSession.splitActivePane == 1:
    let tab = focusedPaneTabIndex()
    if tab >= 0 and tab < editorSession.tabs.len:
      return editorSession.tabs[tab].secondaryView
  editorViewState

proc storeFocusedEditorView(view: EditorViewState) =
  if editorSession.split and editorSession.splitActivePane == 1:
    let tab = focusedPaneTabIndex()
    if tab >= 0 and tab < editorSession.tabs.len:
      editorSession.tabs[tab].secondaryView = view
      editorSession.secondaryView = view
    return
  editorViewState = view

proc editEditorSelections(document: ptr FileDocument, view: var EditorViewState,
                          replacement: string): bool =
  if document == nil: return false
  let selections = view.selectionRanges
  var edits: seq[Edit]
  var nextSelections: seq[Selection]
  var previousEnd = -1
  var cumulativeShift = 0
  for selection in selections:
    let startByte = selection.startByte
    let endByte = selection.endByte
    if startByte < previousEnd: continue
    edits.add(Edit(startByte: startByte, endByte: endByte, text: replacement))
    let newCursor = startByte + cumulativeShift + replacement.len
    nextSelections.add(Selection(anchor: newCursor, active: newCursor))
    cumulativeShift += replacement.len - (endByte - startByte)
    previousEnd = endByte
  if edits.len == 0: return false
  document[].buffer.applyEdits(edits)
  # Byte-anchored fold ranges are invalidated by edits until Tree-sitter has
  # produced a fresh display map. Recomputing them avoids hiding a different
  # source region after an insertion shifts the old range.
  view.foldedRanges.setLen(0)
  view.selection = nextSelections[0]
  view.additionalSelections = if nextSelections.len > 1:
    nextSelections[1 .. ^1] else: @[]
  true

proc deleteEditorSelections(document: ptr FileDocument, view: var EditorViewState,
                            command: string): bool =
  if document == nil: return false
  let text = document[].buffer.toString()
  let selections = view.selectionRanges
  var edits: seq[Edit]
  var nextSelections: seq[Selection]
  var previousEnd = -1
  var cumulativeShift = 0
  for selection in selections:
    var startByte = selection.startByte
    var endByte = selection.endByte
    if startByte == endByte:
      if command == "deleteWordBackward": startByte = previousWordBoundary(text, startByte)
      elif command == "deleteWordForward": endByte = nextWordBoundary(text, endByte)
      elif command == "deleteToBeginningOfLine":
        startByte = document[].buffer.lineStarts[document[].buffer.lineColumn(startByte).line]
      elif command == "deleteToEndOfLine":
        endByte = lineEndOffset(document, document[].buffer.lineColumn(endByte).line)
      elif command == "deleteBackward": startByte = previousBoundary(text, startByte)
      else: endByte = nextBoundary(text, endByte)
    if startByte < previousEnd: continue
    if endByte <= startByte:
      nextSelections.add(Selection(anchor: startByte + cumulativeShift,
        active: startByte + cumulativeShift))
      continue
    edits.add(Edit(startByte: startByte, endByte: endByte, text: ""))
    let newCursor = startByte + cumulativeShift
    nextSelections.add(Selection(anchor: newCursor, active: newCursor))
    cumulativeShift -= endByte - startByte
    previousEnd = endByte
  if edits.len == 0: return false
  document[].buffer.applyEdits(edits)
  view.foldedRanges.setLen(0)
  view.selection = nextSelections[0]
  view.additionalSelections = if nextSelections.len > 1:
    nextSelections[1 .. ^1] else: @[]
  true

proc copyEditorSelections(document: ptr FileDocument, view: EditorViewState): string =
  if document == nil: return ""
  var values: seq[string]
  for range in view.selectionRanges:
    if range.endByte > range.startByte:
      values.add(document[].buffer.substring(range.startByte, range.endByte))
  values.join("\n")

proc selectAllEditorMatches(document: ptr FileDocument, view: var EditorViewState): int =
  if document == nil: return 0
  let text = document[].buffer.toString()
  var selected = view.selectedRange()
  var query = if selected.endByte > selected.startByte:
    document[].buffer.substring(selected.startByte, selected.endByte) else: ""
  if query.len == 0:
    let start = previousWordBoundary(text, view.cursor)
    let finish = nextWordBoundary(text, view.cursor)
    if finish > start:
      selected = (startByte: start, endByte: finish)
      query = text[start ..< finish]
  if query.len == 0: return 0
  let matches = document[].search(query)
  if matches.len == 0: return 0
  view.selection = Selection(anchor: matches[0].startByte, active: matches[0].endByte)
  view.additionalSelections.setLen(0)
  if matches.len > 1:
    for match in matches[1 .. ^1]:
      view.additionalSelections.add(Selection(anchor: match.startByte, active: match.endByte))
  matches.len

proc selectNextEditorMatch(document: ptr FileDocument, view: var EditorViewState): bool =
  if document == nil: return false
  let text = document[].buffer.toString()
  var selected = view.selectedRange()
  if selected.endByte <= selected.startByte:
    let start = previousWordBoundary(text, view.cursor)
    let finish = nextWordBoundary(text, view.cursor)
    if finish <= start: return false
    selected = (startByte: start, endByte: finish)
    view.selection = Selection(anchor: start, active: finish)
  let query = document[].buffer.substring(selected.startByte, selected.endByte)
  if query.len == 0: return false
  let matches = document[].search(query)
  if matches.len == 0: return false
  for match in matches:
    if match.startByte >= selected.endByte:
      var overlaps = false
      for range in view.selectionRanges:
        if range.startByte < match.endByte and match.startByte < range.endByte:
          overlaps = true
          break
      if not overlaps:
        view.additionalSelections.add(Selection(anchor: match.startByte, active: match.endByte))
        return true
  for match in matches:
    if match.startByte < selected.startByte:
      var overlaps = false
      for range in view.selectionRanges:
        if range.startByte < match.endByte and match.startByte < range.endByte:
          overlaps = true
          break
      if not overlaps:
        view.additionalSelections.add(Selection(anchor: match.startByte, active: match.endByte))
        return true
  false

proc handleSecondaryEditorCommand(name: string, document: ptr FileDocument): bool =
  ## Cocoa has one NSTextInputClient, while a split owns two view states. Once
  ## the platform selected pane 1, route every editing selector through that
  ## view before mutating the shared document buffer.
  if not editorSession.split or editorSession.splitActivePane != 1:
    return false
  let secondaryDocument = secondaryPaneDocument()
  if secondaryDocument == nil: return false
  let tab = editorWorkspaceUi.center.second.pane.activeTabIndex
  template view: untyped = editorSession.tabs[tab].secondaryView
  template activeDocument: untyped = secondaryDocument
  let text = activeDocument[].buffer.toString()
  case name
  of "moveLeft": view.moveCursor(previousBoundary(text, view.cursor))
  of "selectLeft": view.moveCursor(previousBoundary(text, view.cursor), selecting = true)
  of "moveRight": view.moveCursor(nextBoundary(text, view.cursor))
  of "selectRight": view.moveCursor(nextBoundary(text, view.cursor), selecting = true)
  of "moveUp", "moveDown", "selectUp", "selectDown":
    let location = activeDocument[].buffer.lineColumn(view.cursor)
    let delta = if name in ["moveUp", "selectUp"]: -1 else: 1
    let targetLine = max(0, min(activeDocument[].buffer.lineStarts.high, location.line + delta))
    view.moveCursor(activeDocument[].buffer.byteOffsetAtLineColumn(targetLine, location.column),
      selecting = name.startsWith("select"))
  of "moveToBeginningOfLine", "selectToBeginningOfLine":
    let location = activeDocument[].buffer.lineColumn(view.cursor)
    view.moveCursor(activeDocument[].buffer.lineStarts[location.line], selecting = name.startsWith("select"))
  of "moveToEndOfLine", "selectToEndOfLine":
    let location = activeDocument[].buffer.lineColumn(view.cursor)
    view.moveCursor(lineEndOffset(activeDocument, location.line), selecting = name.startsWith("select"))
  of "moveToBeginningOfDocument": view.moveCursor(0)
  of "moveToEndOfDocument": view.moveCursor(text.len)
  of "selectToBeginningOfDocument": view.moveCursor(0, selecting = true)
  of "selectToEndOfDocument": view.moveCursor(text.len, selecting = true)
  of "moveWordLeft": view.moveCursor(previousWordBoundary(text, view.cursor))
  of "selectWordLeft": view.moveCursor(previousWordBoundary(text, view.cursor), selecting = true)
  of "moveWordRight": view.moveCursor(nextWordBoundary(text, view.cursor))
  of "selectWordRight": view.moveCursor(nextWordBoundary(text, view.cursor), selecting = true)
  of "deleteBackward", "deleteForward", "deleteWordBackward", "deleteWordForward",
      "deleteToBeginningOfLine", "deleteToEndOfLine":
    discard deleteEditorSelections(activeDocument, view, name)
  of "undo":
    if activeDocument[].buffer.undo():
      view.moveCursor(min(view.cursor, activeDocument[].buffer.toString().len))
      refreshEditorSyntax()
  of "redo":
    if activeDocument[].buffer.redo():
      view.moveCursor(min(view.cursor, activeDocument[].buffer.toString().len))
      refreshEditorSyntax()
  of "copy":
    let copied = copyEditorSelections(activeDocument, view)
    clipboardSet(copied.cstring, uint32(copied.len))
  of "cut":
    let copied = copyEditorSelections(activeDocument, view)
    clipboardSet(copied.cstring, uint32(copied.len))
    discard deleteEditorSelections(activeDocument, view, "deleteForward")
  of "paste": receiveNativeTextValue(clipboardGet(), false)
  of "selectAll":
    view.makeSingleSelection(0, text.len)
  of "selectNext":
    discard selectNextEditorMatch(activeDocument, view)
  of "selectAllMatches":
    discard selectAllEditorMatches(activeDocument, view)
  of "addSelectionAbove", "addSelectionBelow":
    let location = activeDocument[].buffer.lineColumn(view.cursor)
    let delta = if name == "addSelectionAbove": -1 else: 1
    let targetLine = location.line + delta
    if targetLine >= 0 and targetLine <= activeDocument[].buffer.lineStarts.high:
      discard view.addCaret(activeDocument[].buffer.byteOffsetAtLineColumn(
        targetLine, location.column), text)
  of "save":
    if activeDocument[].path.len == 0:
      when defined(macosx):
        pendingSaveTabIndex = tab
        platformShowSavePanel()
        editorViewState.statusMessage = "Choose a location to save " & editorSession.tabs[tab].title
        editorSession.secondaryView = view
        syncEditorCursor()
        return true
      else:
        editorViewState.statusMessage = "Save As is required for this split-pane document"
    else:
      try:
        activeDocument[].save()
        editorSession.tabs[tab].title = splitFile(activeDocument[].path).name
        editorViewState.statusMessage = "Saved " & editorSession.tabs[tab].title
        persistSession()
      except CatchableError as error:
        editorViewState.statusMessage = "Save failed: " & error.msg
  of "saveAs":
    when defined(macosx):
      pendingSaveTabIndex = tab
      let suggestedName = if activeDocument[].path.len > 0:
        splitFile(activeDocument[].path).name & splitFile(activeDocument[].path).ext
      else:
        editorSession.tabs[tab].title
      platformShowSaveAsPanel(suggestedName.cstring)
      editorViewState.statusMessage = "Choose a new location to save"
      editorSession.secondaryView = view
      syncEditorCursor()
      return true
    else:
      return false
  else: return false
  editorSession.secondaryView = view
  syncEditorCursor()
  scheduleSessionPersistence()
  true

proc receiveNativeCommand(command: cstring) {.cdecl.} =
  if command == nil: return
  # Older settings files and external keymaps may use the short `settings`
  # alias. Resolve it at the command boundary so startup does not expose an
  # "Unknown command" status for a valid settings action.
  let name = if $command == "settings": "openSettings" else: $command
  when defined(windows):
    case name
    of "toggleFullscreen":
      platformToggleFullscreen()
      return
    of "minimizeWindow":
      platformMinimizeWindow()
      return
    of "maximizeWindow":
      platformMaximizeWindow()
      return
    of "restoreWindow":
      platformRestoreWindow()
      return
    of "__toggle_terminal__":
      toggleWindowsTerminal()
      return
    of "__new_terminal__":
      newWindowsTerminal()
      return
    of "__next_terminal__", "__previous_terminal__":
      editorViewState.statusMessage = "Windows supports one terminal session in this milestone"
      return
    of "__run_task__":
      editorViewState.statusMessage = "Use `run task <command>` from the command palette"
      return
    of "__cancel_task__":
      cancelWindowsTask()
      return
    of "__task_output__":
      toggleWindowsTaskOutput()
      return
    else: discard
  when defined(windows):
    if windowsTerminalVisible:
      case name
      of "copy":
        let copied = windowsTerminalSelectedText()
        if copied.len > 0: clipboardSet(copied.cstring, uint32(copied.len))
        return
      of "selectAll":
        selectAllWindowsTerminal()
        return
      else: discard
  when defined(macosx):
    if name == "closeOutputPanel":
      editorTaskOutputVisible = false
      platformSetTaskOutputVisible(false)
      return
    if name == "cancelTask":
      cancelNativeTask()
      return
    if name.startsWith("terminalSession:"):
      try:
        activateNativeTerminal(parseInt(name["terminalSession:".len .. ^1]))
        editorTaskOutputVisible = false
        platformSetTaskOutputVisible(false)
        editorTerminalVisible = true
        editorTerminalFocused = true
        platformSetTerminalVisible(true)
      except ValueError:
        discard
      return
    if name == "terminalNew":
      newNativeTerminal()
      return
    if name == "terminalClose":
      closeNativeTerminal()
      return
    if terminalOwnsInput(editorTerminalVisible, editorTerminalFocused) and
        editorTerminal != nil:
      case name
      of "copy":
        let copied = editorTerminal.screen.selectedText(editorTerminalSelection)
        if copied.len > 0: clipboardSet(copied.cstring, uint32(copied.len))
        return
      of "selectAll":
        editorTerminalSelection = TerminalSelection(
          anchor: TerminalPoint(row: 0, column: 0),
          active: TerminalPoint(row: max(0, editorTerminal.screen.lineCount() - 1),
            column: editorTerminal.screen.columns))
        syncNativeTerminalSelection()
        return
      of "paste":
        writeNativeTerminalInput(clipboardGet(), paste = true)
        return
      else:
        let terminalInput = terminalCommandInput(editorTerminal.screen, name)
        if terminalInput.handled:
          if terminalInput.input.len > 0: writeNativeTerminalInput(terminalInput.input)
          return
  let document = if editorSession.split and editorSession.splitActivePane == 1:
    secondaryPaneDocument() else: activeDocument()
  when defined(macosx):
    if handleSecondaryEditorCommand(name, document): return
  if name == "workspaceSearchTick":
    pollWorkspaceSearch()
  elif name == "cancelWorkspaceSearch":
    cancelWorkspaceSearch()
  elif name == "expandSelection":
    when defined(macosx): expandNativeSyntaxSelection(true)
  elif name == "shrinkSelection":
    when defined(macosx): expandNativeSyntaxSelection(false)
  elif name == "selectPreviousSyntaxNode":
    when defined(macosx): moveNativeSyntaxSibling(false)
  elif name == "selectNextSyntaxNode":
    when defined(macosx): moveNativeSyntaxSibling(true)
  elif name == "moveToEnclosingBracket":
    when defined(macosx): moveNativeToEnclosingBracket()
  elif name == "fold":
    when defined(macosx): toggleNativeFold(false, toggle = false)
  elif name == "unfold":
    when defined(macosx): toggleNativeFold(true, toggle = false)
  elif name == "toggleFold":
    when defined(macosx): toggleNativeFold(false, toggle = true)
  elif name == "foldAll":
    when defined(macosx): toggleNativeFold(false, all = true)
  elif name.startsWith("foldAtLevel"):
    when defined(macosx):
      try:
        foldNativeAtLevel(parseInt(name["foldAtLevel".len .. ^1]))
      except ValueError:
        discard
  elif name == "foldRecursive":
    when defined(macosx): toggleNativeFold(false, recursive = true)
  elif name == "unfoldRecursive":
    when defined(macosx): toggleNativeFold(true, recursive = true)
  elif name == "toggleFoldRecursive":
    when defined(macosx): toggleNativeFold(false, toggle = true, recursive = true)
  elif name == "unfoldAll":
    when defined(macosx): toggleNativeFold(true, all = true)
  elif name == "windowResized":
    setupDemoUi()
    when defined(macosx): resizeNativeTerminals()
    if activeDocument() != nil: refreshEditorSyntax()
  elif name == "windowFocusLost":
    resetPointerInteractions()
  elif name == "appearanceChanged":
    when defined(macosx):
      if appSettings != nil and appSettings.stringSetting("theme", "dark").toLowerAscii == "system":
        applySettingsTheme()
  elif name in ["splitEditor", "splitEditorHorizontal"]:
    if document == nil:
      editorViewState.statusMessage = "Open a document before splitting"
    elif editorSession.split:
      editorViewState.statusMessage = "Editor is already split"
    else:
      let direction = if name == "splitEditorHorizontal": splitHorizontal else: splitVertical
      let axis = if direction == splitHorizontal: paneHorizontal else: paneVertical
      editorSession.splitEditor(direction, demoSplitRatio)
      if not editorWorkspaceUi.splitFocusedPane(axis, editorSession.effectiveSplitRatio):
        # A restored split already has a pane tree; session state is still the
        # compatibility source while pane-local tab ownership is migrated.
        discard
      demoSplitEnabled = true
      demoSplitDirection = editorSession.splitDirection
      editorViewState.statusMessage = if direction == splitHorizontal:
        "Editor split horizontally" else: "Editor split vertically"
      setupDemoUi()
      syncEditorCursor()
      persistSession()
  elif name == "closeSplit":
    if editorSession.split:
      editorSession.closeSplit()
      if not editorWorkspaceUi.closeRootSplit():
        editorWorkspaceUi = initWorkspaceUi(editorSession)
      demoSplitEnabled = false
      editorPointerPane = 0
      editorPointerDragging = false
      editorViewState.statusMessage = "Split closed"
      setupDemoUi()
      syncEditorCursor()
      persistSession()
  elif name == "quitRequest":
    when defined(macosx):
      if editorSession.hasDirtyTabs(): platformRequestQuit()
      else:
        shutdownNativeServices()
        applyPendingUpdateAtQuit()
        platformConfirmQuit()
    when defined(windows):
      if editorSession.hasDirtyTabs():
        editorViewState.statusMessage = "Unsaved changes: use save all or discard all before closing"
        platformSetCloseDecision(false)
      else:
        cancelWindowsTask()
        closeWindowsTerminal()
        platformSetCloseDecision(true)
  elif name == "saveAllAndQuit":
    when defined(macosx):
      var hasUntitledDirtyTab = false
      for tab in editorSession.tabs:
        if tab.document.buffer.isDirty and tab.document.path.len == 0:
          hasUntitledDirtyTab = true
          break
      if hasUntitledDirtyTab:
        pendingSaveAllQuitNextTab = 0
        continueSaveAllAndQuit()
        return
    var success = true
    for tab in editorSession.tabs.mitems:
      if not tab.document.buffer.isDirty: continue
      try:
        if tab.document.path.len > 0:
          tab.document.save()
          tab.title = splitFile(tab.document.path).name
        else:
          let path = chooseSaveFile()
          if path == nil or ($path).len == 0:
            success = false
          else:
            let target = $path
            tab.document.save(target)
            tab.title = splitFile(target).name
      except CatchableError:
        success = false
    if success and not editorSession.hasDirtyTabs():
      when defined(macosx): shutdownNativeServices()
      when defined(macosx): applyPendingUpdateAtQuit()
      when defined(windows): closeWindowsTerminal()
    platformSetCloseDecision(success and not editorSession.hasDirtyTabs())
  elif name == "savePanelCancelled":
    when defined(macosx):
      pendingSaveTabIndex = -1
      if pendingSaveAllQuitNextTab >= 0:
        pendingSaveAllQuitNextTab = -1
        platformSetCloseDecision(false)
        editorViewState.statusMessage = "Save all cancelled"
      elif pendingCloseTabIndex >= 0:
        pendingCloseTabIndex = -1
        platformSetCloseDecision(false)
        editorViewState.statusMessage = "Close cancelled"
      else:
        editorViewState.statusMessage = "Save cancelled"
  elif name == "discardAllAndQuit":
    suppressRecoveryWrite = true
    discardDirtyOnExit = true
    if recoveryFilePath.len > 0 and fileExists(recoveryFilePath):
      removeFile(recoveryFilePath)
    when defined(macosx): shutdownNativeServices()
    when defined(macosx): applyPendingUpdateAtQuit()
    when defined(windows): closeWindowsTerminal()
    platformSetCloseDecision(true)
  elif name == "closeTabRequest":
    when defined(macosx):
      let closingTab = focusedPaneTabIndex()
      let closingDocument = documentForTab(closingTab)
      if closingDocument == nil: return
      pendingCloseTabIndex = closingTab
      pendingClosePane = if editorSession.split and editorSession.splitActivePane == 1: 1 else: 0
      platformRequestCloseTabWithUnsaved(closingDocument[].buffer.isDirty)
    when defined(windows):
      if document == nil: return
      if document[].buffer.isDirty:
        platformSetEditorStatus("Unsaved changes: save before closing".cstring)
      else:
        receiveNativeCommand("closeTabConfirmed".cstring)
  elif name == "saveAndCloseTab":
    let closingTab = when defined(macosx): pendingCloseTabIndex else: editorSession.activeTab
    let closingDocument = documentForTab(closingTab)
    if closingDocument == nil:
      when defined(macosx): pendingCloseTabIndex = -1
      platformSetCloseDecision(false)
    elif not closingDocument[].buffer.isDirty:
      receiveNativeCommand("closeTabConfirmed".cstring)
    elif closingDocument[].path.len > 0:
      try:
        closingDocument[].save()
        editorSession.tabs[closingTab].title = splitFile(closingDocument[].path).name
        syncEditorCursor()
        receiveNativeCommand("closeTabConfirmed".cstring)
      except CatchableError:
        platformSetCloseDecision(false)
    else:
      when defined(macosx): platformShowSavePanelAndCloseTab()
  elif name == "closeTabCancelled":
    when defined(macosx):
      pendingCloseTabIndex = -1
      platformSetCloseDecision(false)
      editorViewState.statusMessage = "Close cancelled"
  elif name == "closeTabConfirmed":
    let closingSecondary = when defined(macosx):
      pendingClosePane == 1
    else:
      editorSession.split and editorSession.splitActivePane == 1
    let closingTab = when defined(macosx):
      pendingCloseTabIndex
    else:
      focusedPaneTabIndex()
    if closingTab < 0 or closingTab >= editorSession.tabs.len: return
    editorSession.saveActiveView(editorViewState)
    if closingSecondary:
      editorSession.tabs[closingTab].secondaryView = editorSession.secondaryView
    else:
      editorSession.saveSecondaryActiveView(editorSession.secondaryView)
    when defined(macosx): editorLspSignatureText = ""
    if editorSession.closeTabAt(closingTab, forceDirty = true):
      when defined(macosx): pendingCloseTabIndex = -1
      editorWorkspaceUi.removeTab(closingTab)
      resetImeState()
      if editorSession.activeTab >= 0:
        editorSession.loadActiveView(editorViewState)
        if editorSession.split:
          let secondary = secondaryPaneDocument()
          if secondary != nil:
            let tab = editorWorkspaceUi.center.second.pane.activeTabIndex
            editorSession.secondaryView = editorSession.tabs[tab].secondaryView
          else:
            editorSession.secondaryView = newEditorView()
        else:
          editorSession.loadSecondaryActiveView()
        resetEditorTransientState()
      else:
        resetEditorViewState()
      externalAlertShown = false
      if syntaxState != nil:
        syntaxState.close()
        syntaxState = nil
      workspacePreviewMode = ""
      when defined(macosx) or defined(windows):
        platformSetEditorHighlights(nil, 0)
        let current = activeDocument()
        if current == nil:
          platformSetEditorText("".cstring, 0)
        else:
          refreshEditorSyntax()
        syncEditorCursor()
      persistSession()
  elif name == "reopenClosedTab":
    editorSession.saveActiveView(editorViewState)
    editorSession.saveSecondaryActiveView(editorSession.secondaryView)
    let reopened = editorSession.reopenClosedTab()
    if reopened < 0:
      editorViewState.statusMessage = "No closed file to reopen"
    else:
      syncWorkspaceUiTabs()
      if editorWorkspaceUi.center != nil:
        discard editorWorkspaceUi.selectPaneTab(editorWorkspaceUi.center.firstPane().id,
          editorSession.activeTab)
        if editorSession.split and editorWorkspaceUi.center.kind == paneSplit:
          discard editorWorkspaceUi.selectPaneTab(editorWorkspaceUi.center.second.pane.id,
            editorSession.effectiveSplitSecondaryTab())
      editorSession.loadActiveView(editorViewState)
      editorSession.loadSecondaryActiveView()
      resetImeState()
      resetEditorTransientState()
      editorViewState.statusMessage = "Reopened " & editorSession.displayTitle(reopened)
      syncEditorCursor()
      refreshEditorSyntax()
      persistSession()
  elif name in ["previousTab", "nextTab"]:
    let delta = if name == "previousTab": -1 else: 1
    let pane = editorWorkspaceUi.focusedPane
    let previous = focusedPaneTabIndex()
    let target = editorWorkspaceUi.cyclePaneTab(pane, delta)
    if target >= 0 and target != previous:
      # Reuse the normal tab activation boundary so focused-pane IME, text
      # overlay, view state, and persistence remain synchronized. Unlike the
      # old EditorSession.switchTab path, this does not change a sibling pane.
      let paneIndex = if editorSession.split and editorSession.splitActivePane == 1: 1 else: 0
      let command = if editorSession.split:
          "selectPaneTab:" & $paneIndex & ":" & $target
        else:
          "selectTab:" & $target
      receiveNativeCommand(command.cstring)
  elif name.startsWith("selectPaneTab:"):
    let payload = name["selectPaneTab:".len .. ^1].split(':')
    if payload.len != 2: return
    try:
      let paneIndex = parseInt(payload[0])
      let target = parseInt(payload[1])
      if target < 0 or target >= editorSession.tabs.len or
          editorWorkspaceUi.center == nil or editorWorkspaceUi.center.kind != paneSplit:
        return
      let pane = if paneIndex == 0: editorWorkspaceUi.center.first.pane.id
        elif paneIndex == 1: editorWorkspaceUi.center.second.pane.id else: PaneId(-1)
      if pane == PaneId(-1) or not editorWorkspaceUi.selectPaneTab(pane, target): return
      if paneIndex == 0:
        discard editorWorkspaceUi.focusPane(pane)
        if editorSession.activeTab != target:
          editorSession.saveActiveView(editorViewState)
          editorSession.saveSecondaryActiveView(editorSession.secondaryView)
          editorSession.activeTab = target
          editorSession.loadActiveView(editorViewState)
          editorSession.loadSecondaryActiveView()
      else:
        discard editorWorkspaceUi.focusPane(pane)
        discard editorSession.activateSplitPane(1)
        editorSession.splitSecondaryTab = target
        editorSession.secondaryView = editorSession.tabs[target].secondaryView
      resetImeState()
      resetEditorTransientState()
      syncEditorCursor()
      refreshEditorSyntax()
      persistSession()
    except ValueError:
      discard
  elif name.startsWith("closePaneTab:"):
    let payload = name["closePaneTab:".len .. ^1].split(':')
    if payload.len != 2: return
    try:
      let paneIndex = parseInt(payload[0])
      let target = parseInt(payload[1])
      if target < 0 or target >= editorSession.tabs.len or paneIndex < 0 or paneIndex > 1:
        return
      let selectCommand = if editorWorkspaceUi.center != nil and
          editorWorkspaceUi.center.kind == paneSplit:
        "selectPaneTab:" & $paneIndex & ":" & $target
      elif paneIndex == 0:
        "selectTab:" & $target
      else:
        ""
      if selectCommand.len == 0: return
      receiveNativeCommand(selectCommand.cstring)
      if focusedPaneTabIndex() == target:
        receiveNativeCommand("closeTabRequest".cstring)
    except ValueError:
      discard
  elif name.startsWith("tabContext:"):
    when defined(macosx):
      try:
        let payload = name["tabContext:".len .. ^1].split(':')
        if payload.len != 2: return
        let paneIndex = parseInt(payload[0])
        let tabIndex = parseInt(payload[1])
        if paneIndex notin 0..1 or tabIndex < 0 or tabIndex >= editorSession.tabs.len:
          return
        platformShowEditorTabContext(uint32(paneIndex), uint32(tabIndex),
          editorSession.tabs[tabIndex].pinned, editorSession.pinnedTabCount() > 0)
      except ValueError:
        discard
  elif name.startsWith("movePaneTab:"):
    when defined(macosx):
      try:
        let payload = name["movePaneTab:".len .. ^1].split(':')
        if payload.len != 3: return
        let paneIndex = parseInt(payload[0])
        let source = parseInt(payload[1])
        let requestedDestination = parseInt(payload[2])
        if paneIndex notin 0..1 or source < 0 or source >= editorSession.tabs.len or
            requestedDestination < 0 or requestedDestination >= editorSession.tabs.len:
          return
        let pinnedCount = editorSession.pinnedTabCount()
        let sourcePinned = editorSession.tabs[source].pinned
        let destination = if sourcePinned:
          min(requestedDestination, pinnedCount - 1)
        else:
          max(requestedDestination, pinnedCount)
        if source == destination: return
        editorSession.saveActiveView(editorViewState)
        editorSession.saveSecondaryActiveView(editorSession.secondaryView)
        if editorSession.moveTab(source, destination):
          syncWorkspaceUiTabs()
          if editorWorkspaceUi.center != nil:
            discard editorWorkspaceUi.selectPaneTab(editorWorkspaceUi.center.firstPane().id,
              editorSession.activeTab)
            if editorSession.split and editorWorkspaceUi.center.kind == paneSplit:
              discard editorWorkspaceUi.selectPaneTab(editorWorkspaceUi.center.second.pane.id,
                editorSession.effectiveSplitSecondaryTab())
          editorSession.loadActiveView(editorViewState)
          editorSession.loadSecondaryActiveView()
          editorViewState.statusMessage = "Tab reordered"
          syncEditorCursor()
          persistSession()
      except ValueError:
        discard
  elif name.startsWith("editorTabContext:"):
    when defined(macosx):
      try:
        let payload = name["editorTabContext:".len .. ^1].split(':')
        if payload.len != 3: return
        let paneIndex = parseInt(payload[1])
        let tabIndex = parseInt(payload[2])
        if paneIndex notin 0..1 or tabIndex < 0 or tabIndex >= editorSession.tabs.len:
          return
        let document = documentForTab(tabIndex)
        case payload[0]
        of "pin", "unpin":
          let pin = payload[0] == "pin"
          if editorSession.setTabPinned(tabIndex, pin):
            # PaneState currently mirrors EditorSession's item store. Rebind
            # both pane selections after the item moves so a pin operation in
            # one pane cannot make the sibling point at a different document.
            syncWorkspaceUiTabs()
            if editorWorkspaceUi.center != nil:
              discard editorWorkspaceUi.selectPaneTab(editorWorkspaceUi.center.firstPane().id,
                editorSession.activeTab)
              if editorSession.split and editorWorkspaceUi.center.kind == paneSplit:
                discard editorWorkspaceUi.selectPaneTab(editorWorkspaceUi.center.second.pane.id,
                  editorSession.effectiveSplitSecondaryTab())
            editorViewState.statusMessage = if pin: "Tab pinned" else: "Tab unpinned"
            persistSession()
            syncEditorCursor()
          else:
            editorViewState.statusMessage = if pin: "Tab is already pinned" else: "Tab is not pinned"
        of "unpinAll":
          if editorSession.unpinAllTabs():
            editorViewState.statusMessage = "All tabs unpinned"
            persistSession()
            syncEditorCursor()
          else:
            editorViewState.statusMessage = "No pinned tabs"
        of "close":
          receiveNativeCommand(("closePaneTab:" & $paneIndex & ":" & $tabIndex).cstring)
        of "closeOthers", "closeLeft", "closeRight", "closeClean", "closeAll":
          let keepPath = if document != nil: document[].path else: ""
          let closed = case payload[0]
            of "closeOthers": editorSession.closeCleanTabsExcept(tabIndex)
            of "closeLeft": editorSession.closeCleanTabsBefore(tabIndex)
            of "closeRight": editorSession.closeCleanTabsAfter(tabIndex)
            of "closeClean":
              var count = 0
              for index in countdown(editorSession.tabs.high, 0):
                if index != tabIndex and editorSession.closeTabAt(index): inc count
              count
            else: editorSession.closeAllCleanTabs()
          if closed > 0 and keepPath.len > 0:
            let kept = editorSession.tabIndexForPath(keepPath)
            if kept >= 0:
              editorSession.activeTab = kept
              editorSession.loadActiveView(editorViewState)
          editorViewState.statusMessage = if closed > 0:
            "Closed " & $closed & " clean tab" & (if closed == 1: "" else: "s")
          else: "No clean tabs closed"
          syncWorkspaceUiTabs()
          syncEditorCursor()
          persistSession()
        of "copyPath":
          if document == nil or document[].path.len == 0:
            editorViewState.statusMessage = "Tab has no file path"
          else:
            clipboardSet(document[].path.cstring, uint32(document[].path.len))
            editorViewState.statusMessage = "File path copied"
        of "reveal":
          if document == nil or document[].path.len == 0:
            editorViewState.statusMessage = "Tab has no file path"
          else:
            platformRevealPath(document[].path.cstring)
            editorViewState.statusMessage = "Revealed " & document[].path.extractFilename
        else: discard
      except ValueError:
        discard
  elif name.startsWith("selectTab:"):
    let payload = name["selectTab:".len .. ^1]
    try:
      let target = parseInt(payload)
      if target >= 0 and target < editorSession.tabs.len and target != editorSession.activeTab:
        editorSession.saveActiveView(editorViewState)
        editorSession.saveSecondaryActiveView(editorSession.secondaryView)
        editorSession.activeTab = target
        discard editorWorkspaceUi.selectPaneTab(editorWorkspaceUi.focusedPane, target)
        editorSession.loadActiveView(editorViewState)
        editorSession.loadSecondaryActiveView()
        resetImeState()
        resetEditorTransientState()
        workspacePreviewMode = ""
        externalAlertShown = false
        if syntaxState != nil:
          syntaxState.close()
          syntaxState = nil
        syncEditorCursor()
        refreshEditorSyntax()
        persistSession()
    except ValueError:
      discard
  elif name.startsWith("workspaceAddRoot:") and activeWorkspace != nil:
    let path = workspaceRelativePayload(name, "workspaceAddRoot:")
    if path.len == 0 or not dirExists(path): return
    activeWorkspace.addRoot(path)
    activeWorkspace.startWatching()
    refreshWorkspacePreview()
  elif name == "newDocument":
    editorSession.saveActiveView(editorViewState)
    editorSession.addTab(newDocument())
    resetImeState()
    externalAlertShown = false
    resetEditorViewState()
    if syntaxState != nil:
      syntaxState.close()
      syntaxState = nil
    when defined(macosx) or defined(windows):
      platformSetEditorHighlights(nil, 0)
      platformSetEditorComposition("".cstring)
      platformSetEditorText("".cstring, 0)
      syncEditorCursor()
  elif name == "save" and document != nil:
    try:
      if document[].path.len > 0:
        document[].save()
      else:
        when defined(macosx):
          pendingSaveTabIndex = editorSession.activeTab
          platformShowSavePanel()
          editorViewState.statusMessage = "Choose a location to save"
          return
        else:
          let path = chooseSaveFile()
          if path == nil or ($path).len == 0:
            editorViewState.statusMessage = "Save cancelled"
            return
          document[].save($path)
          if editorSession.activeTab >= 0 and editorSession.activeTab < editorSession.tabs.len:
            editorSession.tabs[editorSession.activeTab].title = splitFile(document[].path).name
      editorSession.saveActiveView(editorViewState)
      persistSession()
      editorViewState.statusMessage = "Saved " &
        (if document[].path.len > 0: splitFile(document[].path).name else: "document")
      syncEditorCursor()
    except CatchableError as error:
      editorViewState.statusMessage = "Save failed: " & error.msg
  elif name == "saveAs" and document != nil:
    when defined(macosx):
      pendingSaveTabIndex = editorSession.activeTab
      let suggestedName = if document[].path.len > 0:
        splitFile(document[].path).name & splitFile(document[].path).ext
      elif editorSession.activeTab >= 0 and editorSession.activeTab < editorSession.tabs.len:
        editorSession.tabs[editorSession.activeTab].title
      else:
        "Untitled"
      platformShowSaveAsPanel(suggestedName.cstring)
      editorViewState.statusMessage = "Choose a new location to save"
    else:
      discard
  elif name == "saveSession":
    persistSession()
  elif name == "discardSession":
    suppressRecoveryWrite = true
    if recoveryFilePath.len > 0 and fileExists(recoveryFilePath):
      removeFile(recoveryFilePath)
  elif name == "openSettings":
    when defined(macosx) or defined(windows):
      if settingsFilePath.len == 0:
        editorViewState.statusMessage = "Settings unavailable"
      else:
        try:
          if not fileExists(settingsFilePath):
            writeFile(settingsFilePath, pretty(settingsSchema()) & "\n")
          receiveNativeFile(settingsFilePath.cstring, false)
          editorViewState.statusMessage = "Editing Nimculus settings"
        except CatchableError as error:
          editorViewState.statusMessage = "Settings failed: " & error.msg
  elif name == "openSettingsUI":
    when defined(macosx):
      let theme = if appSettings != nil: appSettings.stringSetting("theme", "system") else: "system"
      let editorSize = if appSettings != nil: $appSettings.intSetting("editor.fontSize", 14) else: "14"
      let terminalSize = if appSettings != nil: $appSettings.intSetting("terminal.fontSize", 12) else: "12"
      let editorFont = if appSettings != nil: appSettings.stringSetting("editor.fontFamily",
          "Menlo") else: "Menlo"
      let terminalFont = if appSettings != nil: appSettings.stringSetting("terminal.fontFamily",
          "Menlo") else: "Menlo"
      let shell = if appSettings != nil: appSettings.stringSetting("terminal.shell",
          "/bin/zsh") else: "/bin/zsh"
      platformShowSettingsPanel(theme.cstring, editorSize.cstring, terminalSize.cstring,
        editorFont.cstring, terminalFont.cstring, shell.cstring)
  elif name.startsWith("settingsApply:"):
    let payload = name["settingsApply:".len .. ^1]
    let fields = payload.split('\x1f')
    if fields.len != 6 or settingsFilePath.len == 0:
      editorViewState.statusMessage = "Settings panel: invalid values"
      return
    var editorSize, terminalSize: int
    try:
      editorSize = parseInt(fields[1])
      terminalSize = parseInt(fields[2])
    except ValueError:
      editorViewState.statusMessage = "Settings panel: font sizes must be numbers"
      return
    if editorSize < 6 or editorSize > 48 or terminalSize < 6 or terminalSize > 48:
      editorViewState.statusMessage = "Settings panel: font sizes must be 6-48"
      return
    var root = if fileExists(settingsFilePath): parseFile(settingsFilePath) else: newJObject()
    if root.kind != JObject: root = newJObject()
    if not root.hasKey("editor") or root["editor"].kind != JObject: root["editor"] = newJObject()
    if not root.hasKey("terminal") or root["terminal"].kind != JObject: root[
        "terminal"] = newJObject()
    root["theme"] = %fields[0]
    root["editor"]["fontSize"] = %editorSize
    root["editor"]["fontFamily"] = %fields[3]
    root["terminal"]["fontSize"] = %terminalSize
    root["terminal"]["fontFamily"] = %fields[4]
    root["terminal"]["shell"] = %fields[5]
    try:
      writeFile(settingsFilePath, pretty(root) & "\n")
      when defined(macosx) or defined(windows):
        if appSettings != nil: discard appSettings.reload()
      applySettingsKeymap()
      applySettingsTheme()
      editorViewState.statusMessage = "Settings applied"
    except CatchableError as error:
      editorViewState.statusMessage = "Settings failed: " & error.msg
  elif name.startsWith("goToLine:") and document != nil:
    let value = name[9 .. ^1].strip
    try:
      let line = max(1, parseInt(value)) - 1
      let target = document[].buffer.byteOffsetAtLineColumn(line, 0)
      if editorSession.split and editorSession.splitActivePane == 1:
        editorSession.secondaryView.moveCursor(target)
      else:
        editorViewState.moveCursor(target)
      syncEditorCursor()
      refreshEditorSyntax()
    except ValueError:
      editorViewState.statusMessage = "Invalid line number"
  elif name == "toggleSoftWrap":
    if editorSession.split and editorSession.splitActivePane == 1:
      editorSession.secondaryView.softWrap = not editorSession.secondaryView.softWrap
      if editorSession.secondaryView.softWrap:
        editorSession.secondaryView.scrollX = 0'f32
      editorViewState.statusMessage = if editorSession.secondaryView.softWrap:
        "Soft wrap enabled in secondary pane" else: "Soft wrap disabled in secondary pane"
    else:
      editorViewState.softWrap = not editorViewState.softWrap
      if editorViewState.softWrap: editorViewState.scrollX = 0'f32
      editorViewState.statusMessage = if editorViewState.softWrap:
        "Soft wrap enabled" else: "Soft wrap disabled"
    syncEditorCursor()
    refreshEditorSyntax()
    persistSession()
  elif name == "gitCommitPrompt":
    when defined(macosx):
      platformShowGitCommitSheet()
  elif name == "gitRefreshPanel":
    ## Refresh must preserve the currently selected Git surface. A Changes
    ## refresh must not unexpectedly switch to History, and vice versa.
    when defined(macosx):
      case editorSidebarMode
      of sidebarGitHistory:
        # File History is anchored to the path that produced the list, not to
        # a potentially different document that gained focus meanwhile.
        if editorGitRepository != nil and editorGitHistoryPath.len > 0:
          let path = editorGitHistoryPath
          renderNativeGitHistoryPlaceholder("Loading Commit History…",
            "Git History — " & path, path)
          startNativeGitAction(editorGitRepository, "file history", path, [
            "log", "--format=%H%x00%an%x00%ae%x00%at%x00%s%x00", "-n", "100",
            "--", path])
        else:
          receiveNativeCommand("commandPalette:git log".cstring)
      of sidebarGitBranches: receiveNativeCommand("commandPalette:git branches".cstring)
      else: receiveNativeCommand("commandPalette:git status".cstring)
  elif name == "gitCommitMessageEmpty":
    editorViewState.statusMessage = "Git commit requires a message"
  elif name == "resetWorkspaceSidebarWidth":
    when defined(macosx):
      editorWorkspaceUi.resetDockSize(dockLeft)
      setupDemoUi()
      persistSession()
  elif name == "extensionPermissions:allow":
    let action = pendingExtensionPermissionAction
    let manifest = pendingExtensionPermission
    let source = pendingExtensionPermissionSource
    clearNativeExtensionPermission()
    if action == "install":
      installNativeExtensionNow(source)
    elif action == "catalog-install":
      installNativeCatalogExtensionNow(source)
    elif action == "run":
      runNativeWasmExtension(manifest.id)
  elif name == "extensionPermissions:deny":
    let source = pendingExtensionPermissionSource
    let action = pendingExtensionPermissionAction
    let extensionName = pendingExtensionPermission.name
    clearNativeExtensionPermission()
    if action == "catalog-install" and fileExists(source): removeFile(source)
    editorViewState.statusMessage = "Extension permission denied: " & extensionName
  elif name.startsWith("extensionInstall:"):
    when defined(macosx):
      let source = name["extensionInstall:".len .. ^1].strip
      if source.len == 0:
        editorViewState.statusMessage = "Extension install cancelled"
      else:
        installNativeExtension(source)
  elif name.startsWith("commandPalette:"):
    let rawCommand = name[15 .. ^1].strip
    let command = rawCommand.toLowerAscii
    let dispatchCommand =
      if command.startsWith("git commit --amend "): "__git_amend__"
      elif command.startsWith("git commit "): "__git_commit__"
      elif command == "git commit": "gitCommitPrompt"
      elif command in ["git file history", "git history for file"]: "__git_file_history__"
      elif command.startsWith("git checkout "): "__git_checkout__"
      elif command.startsWith("git switch "): "__git_switch__"
      elif command == "git branches": "__git_branches__"
      elif command == "git stage hunk": "__git_stage_hunk__"
      elif command == "git unstage hunk": "__git_unstage_hunk__"
      elif command == "toggle terminal": "__toggle_terminal__"
      elif command == "new terminal": "__new_terminal__"
      elif command in ["close terminal", "kill terminal"]: "__close_terminal__"
      elif command == "next terminal": "__next_terminal__"
      elif command == "previous terminal": "__previous_terminal__"
      elif command in ["toggle task output", "show task output"]: "__task_output__"
      elif command.startsWith("run task "): "__run_task__"
      elif command == "cancel task": "__cancel_task__"
      elif command == "run task": "__run_task__"
      elif command in ["debug start", "start debugging", "debug launch"]: "__debug_start__"
      elif command in ["debug attach", "attach debugger"]: "__debug_attach__"
      elif command in ["debug stop", "stop debugging"]: "__debug_stop__"
      elif command in ["debug continue", "continue debugging"]: "__debug_continue__"
      elif command in ["debug pause", "pause debugging"]: "__debug_pause__"
      elif command in ["debug step over", "step over"]: "__debug_step_over__"
      elif command in ["debug step into", "step into"]: "__debug_step_into__"
      elif command in ["debug step out", "step out"]: "__debug_step_out__"
      elif command in ["debug toggle breakpoint", "toggle breakpoint"]: "__debug_toggle_breakpoint__"
      elif command.startsWith("debug evaluate "): "__debug_evaluate__"
      elif command.startsWith("debug watch "): "__debug_watch__"
      elif command in ["debug clear watches", "clear debug watches"]: "__debug_clear_watches__"
      elif command in ["debug variables", "show debug variables"]: "__debug_variables__"
      elif command in ["debug threads", "show debug threads"]: "__debug_threads__"
      elif command == "agent start": "__agent_start__"
      elif command.startsWith("agent start worktree "): "__agent_start_worktree__"
      elif command.startsWith("agent start "): "__agent_start_provider__"
      elif command == "agent stop": "__agent_stop__"
      elif command.startsWith("agent send "): "__agent_send__"
      elif command == "agent next": "__agent_next__"
      elif command == "agent previous": "__agent_previous__"
      elif command in ["agent review diff", "agent diff"]: "__agent_diff__"
      elif command in ["agent approve", "agent approve changes"]: "__agent_approve__"
      elif command in ["agent reject", "agent reject changes"]: "__agent_reject__"
      elif command in ["agent apply patch", "apply agent patch"]: "__agent_apply_patch__"
      elif command in ["extensions install", "install extension"]: "__extensions_install__"
      elif command.startsWith("extensions install "): "__extensions_install_catalog__"
      elif command in ["extensions reload", "reload extensions"]: "__extensions_reload__"
      elif command in ["extensions list", "list extensions"]: "__extensions_list__"
      elif command in ["extensions catalog", "sync extension catalog"]: "__extensions_catalog__"
      elif command in ["extensions runtime", "wasm runtime"]: "__extensions_runtime__"
      elif command == "extensions run": "__extensions_run__"
      elif command.startsWith("extensions run "): "__extensions_run_id__"
      elif command == "cancel git": "__cancel_git__"
      elif command == "save as": "saveAs"
      elif command == "replace": "replaceDocument"
      elif command in ["go to line", "goto line"]: "goToLine"
      elif command == "quick open": "quickOpen"
      elif command in ["split", "split editor", "split vertical"]: "splitEditor"
      elif command in ["split horizontal", "split editor horizontally"]: "splitEditorHorizontal"
      elif command in ["close split", "unsplit"]: "closeSplit"
      elif command in ["reopen closed tab", "reopen closed file"]: "reopenClosedTab"
      elif command.startsWith("workspace search "): "__workspace_search__"
      elif command.startsWith("quick open "): "__quick_open__"
      elif command in ["show files", "show explorer", "show project"]: "__show_files__"
      elif command in ["toggle files", "toggle explorer", "toggle project"]: "__toggle_files__"
      elif command in ["reveal active file", "reveal in files", "reveal in explorer"]:
        "__reveal_active_file__"
      elif command in ["collapse all files", "collapse all folders", "collapse workspace folders"]:
        "__collapse_all_files__"
      elif command in ["expand all files", "expand all folders", "expand workspace folders"]:
        "sidebarExpandAll"
      elif command in ["duplicate workspace entry", "duplicate selected entry"]:
        "sidebarDuplicateSelected"
      elif command in ["copy workspace entry", "copy selected entry"]:
        "sidebarCopySelected"
      elif command in ["cut workspace entry", "cut selected entry"]:
        "sidebarCutSelected"
      elif command in ["paste workspace entry", "paste selected entry"]:
        "sidebarPasteSelected"
      elif command in ["move workspace entry to trash", "trash workspace entry"]:
        "sidebarTrashSelected"
      elif command in ["delete workspace entry permanently", "permanently delete workspace entry"]:
        "sidebarDeleteSelected"
      elif command in ["reveal selected workspace entry", "reveal workspace entry"]:
        "sidebarRevealSelected"
      elif command in ["open selected workspace entry with system",
          "open workspace entry with system"]:
        "sidebarOpenWithSystem"
      elif command in ["find in selected folder", "search selected folder"]:
        "sidebarSearchInSelected"
      elif command in ["show outline", "show symbols"]: "__show_outline__"
      elif command in ["show problems", "show diagnostics"]: "__show_problems__"
      elif command in ["toggle outline", "toggle symbols"]: "__toggle_outline__"
      elif command in ["expand selection", "expand syntax selection"]: "__expand_selection__"
      elif command in ["shrink selection", "shrink syntax selection"]: "__shrink_selection__"
      elif command in ["select previous syntax node", "select previous sibling"]:
        "__select_previous_syntax__"
      elif command in ["select next syntax node", "select next sibling"]:
        "__select_next_syntax__"
      elif command in ["move to enclosing bracket", "go to matching bracket",
          "move to matching bracket"]: "__move_to_bracket__"
      elif command in ["fold", "fold current"]: "fold"
      elif command in ["unfold", "unfold current"]: "unfold"
      elif command in ["toggle fold", "toggle folding"]: "toggleFold"
      elif command in ["fold all", "fold all code"]: "foldAll"
      elif command == "fold at level 1": "foldAtLevel1"
      elif command == "fold at level 2": "foldAtLevel2"
      elif command == "fold at level 3": "foldAtLevel3"
      elif command == "fold at level 4": "foldAtLevel4"
      elif command == "fold at level 5": "foldAtLevel5"
      elif command == "fold at level 6": "foldAtLevel6"
      elif command == "fold at level 7": "foldAtLevel7"
      elif command == "fold at level 8": "foldAtLevel8"
      elif command == "fold at level 9": "foldAtLevel9"
      elif command in ["unfold all", "unfold all code"]: "unfoldAll"
      elif command in ["fold recursively", "fold recursive"]: "foldRecursive"
      elif command in ["unfold recursively", "unfold recursive"]: "unfoldRecursive"
      elif command in ["toggle fold recursively", "toggle recursive fold"]:
        "toggleFoldRecursive"
      elif command in ["toggle git", "toggle source control"]: "__toggle_git__"
      elif command == "open settings": "openSettings"
      elif command in ["toggle soft wrap", "toggle word wrap"]: "toggleSoftWrap"
      elif command == "check for updates": "__check_updates__"
      elif command.startsWith("open symbol "): "__open_symbol__"
      elif command.startsWith("apply code action "): "__apply_code_action__"
      elif command == "apply rename": "__apply_rename__"
      elif command.startsWith("rename "): "__rename__"
      else: command
    editorViewState.closeCommandPalette()
    case dispatchCommand
    of "new": receiveNativeCommand("newDocument".cstring)
    of "save":
      receiveNativeCommand("save".cstring)
    of "saveAs":
      receiveNativeCommand("saveAs".cstring)
    of "reopenClosedTab":
      receiveNativeCommand("reopenClosedTab".cstring)
    of "find":
      when defined(macosx):
        platformShowFindDocument()
    of "replaceDocument":
      when defined(macosx):
        platformShowReplaceDocument()
    of "goToLine":
      when defined(macosx):
        platformShowGoToLine()
    of "quickOpen":
      when defined(macosx):
        platformShowQuickOpen()
    of "openSettings":
      receiveNativeCommand("openSettings".cstring)
    of "gitCommitPrompt":
      receiveNativeCommand("gitCommitPrompt".cstring)
    of "expandSelection":
      when defined(macosx): expandNativeSyntaxSelection(true)
    of "shrinkSelection":
      when defined(macosx): expandNativeSyntaxSelection(false)
    of "go to definition":
      when defined(macosx):
        if document == nil or lspBridge == nil:
          editorViewState.statusMessage = "LSP definition unavailable"
        elif lspBridge.requestDefinition(document[].buffer, activeEditorCursor()):
          editorViewState.statusMessage = "LSP: finding definition"
        else:
          editorViewState.statusMessage = "LSP definition unavailable"
    of "find references":
      when defined(macosx):
        if document == nil or lspBridge == nil:
          editorViewState.statusMessage = "LSP references unavailable"
        elif lspBridge.requestReferences(document[].buffer, activeEditorCursor()):
          editorViewState.statusMessage = "LSP: finding references"
        else:
          editorViewState.statusMessage = "LSP references unavailable"
    of "rename":
      when defined(macosx):
        editorViewState.statusMessage = "Use `rename <new-name>` from the command palette"
    of "__rename__":
      when defined(macosx):
        if document == nil or lspBridge == nil or rawCommand.len <= 7:
          editorViewState.statusMessage = "LSP rename unavailable"
        else:
          let newName = rawCommand[7 .. ^1].strip
          if newName.len == 0 or not lspBridge.requestRename(document[].buffer,
              activeEditorCursor(), newName):
            editorViewState.statusMessage = "LSP rename unavailable"
          else:
            editorViewState.statusMessage = "LSP: preparing rename"
    of "__apply_rename__":
      when defined(macosx):
        if pendingLspRename.len == 0:
          editorViewState.statusMessage = "No pending LSP rename"
        elif applyLspWorkspaceEdits(pendingLspRename, "rename"):
          pendingLspRename.setLen(0)
    of "__open_symbol__":
      when defined(macosx):
        if document == nil or pendingLspSymbols.len == 0:
          editorViewState.statusMessage = "No pending LSP symbols"
        else:
          let value = if rawCommand.len > 12: rawCommand[12 .. ^1].strip else: ""
          try:
            let index = parseInt(value) - 1
            if not openNativeSymbol(index):
              editorViewState.statusMessage = "Invalid symbol number"
          except ValueError:
            editorViewState.statusMessage = "Invalid symbol number"
    of "__apply_code_action__":
      when defined(macosx):
        if pendingLspCodeActions.len == 0:
          editorViewState.statusMessage = "No pending LSP code action"
        else:
          let value = if rawCommand.len > 18: rawCommand[18 .. ^1].strip else: ""
          try:
            let index = parseInt(value) - 1
            if index < 0 or index >= pendingLspCodeActions.len:
              editorViewState.statusMessage = "Invalid code action number"
            else:
              var edits = pendingLspCodeActions[index].workspaceEdits
              if edits.len == 0 and pendingLspCodeActions[index].edits.len > 0:
                let uri = if pendingLspCodeActions[index].uri.len > 0:
                    pendingLspCodeActions[index].uri else: lspBridge.uri
                edits.add(LspWorkspaceEdit(uri: uri,
                  edits: pendingLspCodeActions[index].edits))
              if edits.len > 0 and applyLspWorkspaceEdits(edits, "code action"):
                pendingLspCodeActions.setLen(0)
              elif edits.len == 0 and pendingLspCodeActions[index].command.len > 0 and
                  lspBridge.requestExecuteCommand(pendingLspCodeActions[index].command,
                    pendingLspCodeActions[index].arguments):
                pendingLspCodeActions.setLen(0)
                editorViewState.statusMessage = "LSP: executing code action command"
              elif edits.len == 0 and pendingLspCodeActions[index].data != nil and
                  lspBridge.requestCodeActionResolve(pendingLspCodeActions[index]):
                editorViewState.statusMessage = "LSP: resolving code action"
              elif edits.len == 0:
                editorViewState.statusMessage = "Code action has no executable edit or command"
          except ValueError:
            editorViewState.statusMessage = "Invalid code action number"
    of "__check_updates__":
      when defined(macosx):
        let manifestPath = getEnv("NIMCULUS_UPDATE_MANIFEST", "")
        if manifestPath.len == 0 or not fileExists(manifestPath):
          editorViewState.statusMessage = "Update manifest unavailable"
        else:
          let release = parseUpdateManifest(readFile(manifestPath))
          if release.version.len == 0 or release.url.len == 0:
            editorViewState.statusMessage = "Update manifest invalid"
          elif isUpdateAvailable(getEnv("NIMCULUS_VERSION", "0.1.0"), release):
            if editorUpdateJob != nil:
              editorViewState.statusMessage = "Update download already in progress"
            else:
              let destination = getTempDir() / "Nimculus-update.dmg"
              editorUpdateJob = startUpdateDownload(release, destination)
              if editorUpdateJob.done:
                editorViewState.statusMessage = "Update download could not start"
              else:
                editorViewState.statusMessage = "Downloading update: " & release.version
          else:
            editorViewState.statusMessage = "Nimculus is up to date"
    of "document symbols", "show symbols":
      when defined(macosx):
        if lspBridge == nil or not lspBridge.requestSymbols():
          editorViewState.statusMessage = "LSP symbols unavailable"
        else:
          editorViewState.statusMessage = "LSP: loading symbols"
    of "code actions":
      when defined(macosx):
        if document == nil or lspBridge == nil or
            not lspBridge.requestCodeActions(lspSelectionRange(document)):
          editorViewState.statusMessage = "LSP code actions unavailable"
        else:
          editorViewState.statusMessage = "LSP: loading code actions"
    of "signature help":
      when defined(macosx):
        editorLspSignatureText = ""
        platformSetEditorHover("".cstring, 0)
        if document == nil or lspBridge == nil or
            not lspBridge.requestSignatureHelp(document[].buffer, activeEditorCursor()):
          editorViewState.statusMessage = "LSP signature help unavailable"
        else:
          editorViewState.statusMessage = "LSP: loading signature help"
    of "inlay hints":
      when defined(macosx):
        if document == nil or lspBridge == nil:
          editorViewState.statusMessage = "LSP inlay hints unavailable"
        else:
          lspBridge.syncDocument(document[].path, document[].buffer.toString())
          if not lspBridge.requestInlayHintsForPath(document[].path,
              lspSelectionRange(document)):
            editorViewState.statusMessage = "LSP inlay hints unavailable"
          else:
            editorViewState.statusMessage = "LSP: loading inlay hints"
    of "semantic tokens":
      when defined(macosx):
        if lspBridge == nil or not lspBridge.requestSemanticTokens():
          editorViewState.statusMessage = "LSP semantic tokens unavailable"
        else:
          editorViewState.statusMessage = "LSP: loading semantic tokens"
    of "format document":
      when defined(macosx):
        if document == nil or lspBridge == nil:
          editorViewState.statusMessage = "LSP formatting unavailable"
        elif lspBridge.requestFormatting():
          editorViewState.statusMessage = "LSP: formatting"
        else:
          editorViewState.statusMessage = "LSP formatting unavailable"
    of "__run_task__":
      when defined(macosx):
        let taskCommand = if rawCommand.len > 9: rawCommand[9 .. ^1].strip else: ""
        if taskCommand.len == 0:
          editorViewState.statusMessage = "Task requires a command"
        else:
          startNativeTask(taskCommand)
      when defined(windows):
        let taskCommand = if rawCommand.len > 9: rawCommand[9 .. ^1].strip else: ""
        if taskCommand.len == 0:
          editorViewState.statusMessage = "Task requires a command"
        else:
          startWindowsTask(taskCommand)
    of "__cancel_task__":
      when defined(macosx): cancelNativeTask()
      when defined(windows): cancelWindowsTask()
    of "__debug_start__":
      when defined(macosx): startNativeDap()
    of "__debug_attach__":
      when defined(macosx): startNativeDap(true)
    of "__debug_stop__":
      when defined(macosx): stopNativeDap()
    of "__debug_continue__":
      when defined(macosx): discard sendNativeDapRequest("continue",
        continueArguments(editorDapThreadId))
    of "__debug_pause__":
      when defined(macosx): discard sendNativeDapRequest("pause",
        continueArguments(editorDapThreadId))
    of "__debug_step_over__":
      when defined(macosx): discard sendNativeDapRequest("next",
        continueArguments(editorDapThreadId))
    of "__debug_step_into__":
      when defined(macosx): discard sendNativeDapRequest("stepIn",
        continueArguments(editorDapThreadId))
    of "__debug_step_out__":
      when defined(macosx): discard sendNativeDapRequest("stepOut",
        continueArguments(editorDapThreadId))
    of "__debug_toggle_breakpoint__":
      when defined(macosx):
        let document = activeDocument()
        if document == nil or document[].path.len == 0:
          editorViewState.statusMessage = "Breakpoint requires a saved document"
        elif editorDapSession == nil:
          editorViewState.statusMessage = "Debugger is not running"
        else:
          let line = document[].buffer.lineColumn(activeEditorCursor()).line + 1
          let existing = editorDapBreakpointLines.find(line)
          if existing >= 0: editorDapBreakpointLines.delete(existing)
          else: editorDapBreakpointLines.add(line)
          discard sendNativeDapRequest("setBreakpoints",
            setBreakpointsArguments(document[].path, editorDapBreakpointLines))
          editorViewState.statusMessage = if existing >= 0:
            "Removed breakpoint at line " & $line else:
            "Added breakpoint at line " & $line
    of "__debug_evaluate__":
      when defined(macosx):
        let expression = if rawCommand.len > 16: rawCommand[16 .. ^1].strip else: ""
        if expression.len == 0:
          editorViewState.statusMessage = "Debug evaluate requires an expression"
        else:
          discard sendNativeDapRequest("evaluate", evaluateArguments(expression,
            editorDapFrameId))
    of "__debug_watch__":
      when defined(macosx):
        let expression = if rawCommand.len > 12: rawCommand[12 .. ^1].strip else: ""
        if expression.len == 0:
          editorViewState.statusMessage = "Debug watch requires an expression"
        elif expression notin editorDapWatchExpressions:
          editorDapWatchExpressions.add(expression)
          showNativeDapSidebar()
          editorViewState.statusMessage = "Added debug watch: " & expression
          if editorDapThreadId > 0:
            discard sendNativeDapRequest("evaluate", evaluateArguments(expression,
              editorDapFrameId))
    of "__debug_clear_watches__":
      when defined(macosx):
        editorDapWatchExpressions.setLen(0)
        editorViewState.statusMessage = "Debug watches cleared"
    of "__debug_variables__":
      when defined(macosx):
        if editorDapFrameId <= 0:
          editorViewState.statusMessage = "No stopped debugger frame"
        else:
          showNativeDapSidebar()
          discard sendNativeDapRequest("scopes", scopesArguments(editorDapFrameId))
    of "__debug_threads__":
      when defined(macosx):
        showNativeDapSidebar()
        discard sendNativeDapRequest("threads", threadsArguments())
    of "__agent_start__":
      when defined(macosx): startNativeAgent()
    of "__agent_start_provider__":
      when defined(macosx):
        let provider = if rawCommand.len > 12: rawCommand[12 .. ^1].strip else: ""
        startNativeAgent(providerValue = provider)
    of "__agent_start_worktree__":
      when defined(macosx):
        let path = if rawCommand.len > 21: rawCommand[21 .. ^1].strip else: ""
        if path.len == 0: editorViewState.statusMessage = "Agent worktree path is empty"
        else: startNativeAgent(path)
    of "__agent_stop__":
      when defined(macosx): stopNativeAgent()
    of "__agent_send__":
      when defined(macosx):
        let prompt = if rawCommand.len > 11: rawCommand[11 .. ^1].strip else: ""
        sendNativeAgentPrompt(prompt)
    of "__agent_next__":
      when defined(macosx): switchNativeAgent(1)
    of "__agent_previous__":
      when defined(macosx): switchNativeAgent(-1)
    of "__agent_diff__":
      when defined(macosx): showNativeAgentDiff()
    of "__agent_approve__":
      when defined(macosx): approveNativeAgentChanges()
    of "__agent_reject__":
      when defined(macosx): rejectNativeAgentChanges()
    of "__agent_apply_patch__":
      when defined(macosx): applyNativeAgentPatch()
    of "__extensions_reload__":
      when defined(macosx): reloadNativeExtensions()
    of "__extensions_install__":
      when defined(macosx): platformPromptExtensionDirectory()
    of "__extensions_install_catalog__":
      when defined(macosx):
        let prefix = "extensions install "
        let id = if rawCommand.len > prefix.len:
          rawCommand[prefix.len .. ^1].strip else: ""
        if id.len == 0: editorViewState.statusMessage =
          "Catalog install requires an extension id"
        else: installNativeCatalogExtension(id)
    of "__extensions_list__":
      when defined(macosx): showNativeExtensions()
    of "__extensions_catalog__":
      when defined(macosx): syncNativeExtensionCatalog()
    of "__extensions_runtime__":
      when defined(macosx):
        editorViewState.statusMessage = "WASM runtime: " & wasmRuntimeStatus() &
          "; Component host: " &
          (if wasmComponentHostAvailable(): "in-process" else: "CLI fallback")
    of "__extensions_run__":
      when defined(macosx): runNativeWasmExtension()
    of "__extensions_run_id__":
      when defined(macosx):
        let prefix = "extensions run "
        let id = if rawCommand.len > prefix.len: rawCommand[prefix.len .. ^1].strip else: ""
        runNativeWasmExtension(id)
    of "__cancel_git__":
      when defined(macosx):
        if editorGitActionJob == nil or editorGitActionJob.done:
          editorViewState.statusMessage = "Git: no running operation"
        else:
          cancelNativeGitAction()
          editorViewState.statusMessage = "Git: cancelled"
    of "__toggle_terminal__":
      when defined(macosx):
        toggleNativeTerminal()
        if editorTerminalVisible:
          editorWorkspaceUi.openPanel(panelTerminal)
          platformFocusEditor()
        elif editorTaskOutputVisible: editorWorkspaceUi.openPanel(panelTasks)
        else: editorWorkspaceUi.bottomDock.isOpen = false
        setupDemoUi()
        resizeNativeTerminals()
    of "__new_terminal__":
      when defined(macosx):
        newNativeTerminal()
        if editorTerminalVisible: editorWorkspaceUi.openPanel(panelTerminal)
        setupDemoUi()
        resizeNativeTerminals()
    of "__close_terminal__":
      when defined(macosx):
        closeNativeTerminal()
        if not editorTerminalVisible and not editorTaskOutputVisible:
          editorWorkspaceUi.bottomDock.isOpen = false
        setupDemoUi()
    of "__next_terminal__":
      when defined(macosx): switchNativeTerminal(1)
    of "__previous_terminal__":
      when defined(macosx): switchNativeTerminal(-1)
    of "__task_output__":
      when defined(macosx):
        toggleNativeTaskOutput()
        if editorTaskOutputVisible: editorWorkspaceUi.openPanel(panelTasks)
        elif editorTerminalVisible: editorWorkspaceUi.openPanel(panelTerminal)
        else: editorWorkspaceUi.bottomDock.isOpen = false
        setupDemoUi()
        resizeNativeTerminals()
      when defined(windows): toggleWindowsTaskOutput()
    of "__workspace_search__":
      let query = if rawCommand.len > 17: rawCommand[17 .. ^1].strip else: ""
      if query.len == 0:
        editorViewState.statusMessage = "Workspace search requires a query"
      else:
        showWorkspaceSearch(query)
    of "__quick_open__":
      let query = if rawCommand.len > 10: rawCommand[10 .. ^1].strip else: ""
      if query.len == 0:
        editorViewState.statusMessage = "Quick Open requires a query"
      else:
        showQuickOpen(query)
    of "workspace search":
      when defined(macosx):
        platformShowWorkspaceSearch()
    of "cancel search": cancelWorkspaceSearch()
    of "__show_files__":
      when defined(macosx):
        editorWorkspaceUi.openPanel(panelFiles)
        setupDemoUi()
        if activeWorkspace == nil:
          editorSidebarMode = sidebarFiles
          let emptyPanel = "Files\n────────\nOpen a folder to start a workspace."
          editorWorkspaceUi.replacePanelItems(panelFiles, @[])
          platformSetWorkspaceOpen(false)
          platformSetEditorSidebar(emptyPanel.cstring, uint32(emptyPanel.len), 0,
            uint32(sidebarFiles))
          editorViewState.statusMessage = "Open a folder to start a workspace"
        else:
          refreshWorkspacePreview()
    of "__toggle_files__":
      when defined(macosx):
        let didFocusPanel = editorWorkspaceUi.togglePanelFocus(panelFiles)
        if didFocusPanel:
          editorSidebarMode = sidebarFiles
        setupDemoUi()
        if didFocusPanel and activeWorkspace == nil:
          let emptyPanel = "Files\n────────\nOpen a folder to start a workspace."
          editorWorkspaceUi.replacePanelItems(panelFiles, @[])
          platformSetWorkspaceOpen(false)
          platformSetEditorSidebar(emptyPanel.cstring, uint32(emptyPanel.len), 0,
            uint32(sidebarFiles))
          syncNativeSidebarSelection()
          editorViewState.statusMessage = "Open a folder to start a workspace"
        elif didFocusPanel and activeWorkspace != nil:
          refreshWorkspacePreview()
        if didFocusPanel: platformFocusEditorSidebar()
        else: platformFocusEditor()
    of "__reveal_active_file__":
      when defined(macosx): revealActiveDocumentInWorkspace()
    of "__collapse_all_files__":
      when defined(macosx): collapseAllWorkspaceEntries()
    of "__show_outline__":
      when defined(macosx):
        editorWorkspaceUi.openPanel(panelOutline)
        setupDemoUi()
        editorSidebarMode = sidebarOutline
        syncNativeSymbolTree()
    of "__show_problems__":
      when defined(macosx):
        let active = activeDocument()
        if active == nil or lspBridge == nil:
          editorViewState.statusMessage = "Diagnostics: none"
        else:
          lspBridge.syncDocument(active[].path, active[].buffer.toString())
          let diagnostics = active[].buffer.resolveDiagnostics(lspBridge.diagnostics())
          var lines: seq[string]
          for diagnostic in diagnostics:
            let severity = case diagnostic.severity
            of 1: "Error"
            of 2: "Warning"
            of 3: "Info"
            else: "Hint"
            lines.add(severity & ": " & diagnostic.message)
          showNativeLspPanel("Problems", if lines.len > 0: lines else: @["No problems"])
    of "__toggle_outline__":
      when defined(macosx):
        let didFocusPanel = editorWorkspaceUi.togglePanelFocus(panelOutline)
        setupDemoUi()
        if didFocusPanel:
          editorSidebarMode = sidebarOutline
          syncNativeSymbolTree()
          platformFocusEditorSidebar()
        else:
          platformFocusEditor()
    of "__expand_selection__":
      when defined(macosx): expandNativeSyntaxSelection(true)
    of "__shrink_selection__":
      when defined(macosx): expandNativeSyntaxSelection(false)
    of "__select_previous_syntax__":
      when defined(macosx): moveNativeSyntaxSibling(false)
    of "__select_next_syntax__":
      when defined(macosx): moveNativeSyntaxSibling(true)
    of "__move_to_bracket__":
      when defined(macosx): moveNativeToEnclosingBracket()
    of "fold":
      when defined(macosx): toggleNativeFold(false)
    of "unfold":
      when defined(macosx): toggleNativeFold(true)
    of "toggleFold":
      when defined(macosx): toggleNativeFold(false)
    of "foldAll":
      when defined(macosx): toggleNativeFold(false, all = true)
    of "foldAtLevel1":
      when defined(macosx): foldNativeAtLevel(1)
    of "foldAtLevel2":
      when defined(macosx): foldNativeAtLevel(2)
    of "foldAtLevel3":
      when defined(macosx): foldNativeAtLevel(3)
    of "foldAtLevel4":
      when defined(macosx): foldNativeAtLevel(4)
    of "foldAtLevel5":
      when defined(macosx): foldNativeAtLevel(5)
    of "foldAtLevel6":
      when defined(macosx): foldNativeAtLevel(6)
    of "foldAtLevel7":
      when defined(macosx): foldNativeAtLevel(7)
    of "foldAtLevel8":
      when defined(macosx): foldNativeAtLevel(8)
    of "foldAtLevel9":
      when defined(macosx): foldNativeAtLevel(9)
    of "foldRecursive":
      when defined(macosx): toggleNativeFold(false, recursive = true)
    of "unfoldRecursive":
      when defined(macosx): toggleNativeFold(true, recursive = true)
    of "toggleFoldRecursive":
      when defined(macosx): toggleNativeFold(false, toggle = true, recursive = true)
    of "unfoldAll":
      when defined(macosx): toggleNativeFold(true, all = true)
    of "__toggle_git__":
      when defined(macosx):
        let wasActive = editorWorkspaceUi.leftDock.isOpen and
          editorWorkspaceUi.leftDock.activePanel == panelGit
        if wasActive:
          let didFocusPanel = editorWorkspaceUi.togglePanelFocus(panelGit)
          setupDemoUi()
          if didFocusPanel: platformFocusEditorSidebar()
          else: platformFocusEditor()
        else:
          # Reuse the existing asynchronous Git status path rather than
          # inventing a second source-control presenter.
          receiveNativeCommand("commandPalette:git status".cstring)
          platformFocusEditorSidebar()
    of "git status":
      when defined(macosx):
        editorWorkspaceUi.openPanel(panelGit)
        let repository = gitRepositoryForDocument(document)
        if repository == nil:
          renderNativeGitEmpty()
          editorViewState.statusMessage = "Git repository not found"
        else:
          startNativeGitAction(repository, "status", "", [
            "status", "--porcelain=v1", "--untracked-files=all", "-z"])
    of "git stage all":
      when defined(macosx):
        let repository = gitRepositoryForDocument(document)
        if repository == nil:
          editorViewState.statusMessage = "Git repository not found"
        else:
          startNativeGitAction(repository, "stage all", "", ["add", "-A"])
    of "git unstage all":
      when defined(macosx):
        let repository = gitRepositoryForDocument(document)
        if repository == nil:
          editorViewState.statusMessage = "Git repository not found"
        else:
          startNativeGitAction(repository, "unstage all", "", ["reset", "HEAD"])
    of "__git_stage_hunk__", "__git_unstage_hunk__":
      when defined(macosx):
        let repository = gitRepositoryForDocument(document)
        let relative = gitRelativePathForDocument(document, repository)
        if repository == nil or document == nil or relative.len == 0:
          editorViewState.statusMessage = "Git repository not found"
        else:
          let line = document[].buffer.lineColumn(activeEditorCursor()).line
          startNativeGitHunkAction(repository, relative,
            if dispatchCommand == "__git_stage_hunk__": "stage hunk" else: "unstage hunk",
            line)
    of "git log":
      when defined(macosx):
        editorWorkspaceUi.openPanel(panelGit)
        let repository = gitRepositoryForDocument(document)
        if repository == nil:
          renderNativeGitEmpty()
          editorViewState.statusMessage = "Git repository not found"
        else:
          renderNativeGitHistoryPlaceholder("Loading Commit History…")
          startNativeGitAction(repository, "log", "", [
            "log", "--format=%H%x00%an%x00%ae%x00%at%x00%s%x00", "-n", "100"])
    of "__git_file_history__":
      when defined(macosx):
        editorWorkspaceUi.openPanel(panelGit)
        let repository = gitRepositoryForDocument(document)
        let relative = gitRelativePathForDocument(document, repository)
        if repository == nil or relative.len == 0:
          editorViewState.statusMessage = "Git repository not found"
        else:
          renderNativeGitHistoryPlaceholder("Loading Commit History…",
            "Git History — " & relative, relative)
          startNativeGitAction(repository, "file history", relative, [
            "log", "--format=%H%x00%an%x00%ae%x00%at%x00%s%x00", "-n", "100",
            "--", relative])
    of "__git_branches__":
      when defined(macosx):
        editorWorkspaceUi.openPanel(panelGit)
        let repository = gitRepositoryForDocument(document)
        if repository == nil:
          renderNativeGitEmpty()
          editorViewState.statusMessage = "Git repository not found"
        else:
          startNativeGitAction(repository, "branches", "", [
            "branch", "--format=%(HEAD)%(refname:short)"])
    of "git blame":
      when defined(macosx):
        let repository = gitRepositoryForDocument(document)
        let relative = gitRelativePathForDocument(document, repository)
        if repository == nil or relative.len == 0:
          editorViewState.statusMessage = "Git repository not found"
        else:
          startNativeGitAction(repository, "blame", relative, [
            "blame", "--line-porcelain", "--", relative])
    of "__git_commit__":
      when defined(macosx):
        let repository = gitRepositoryForDocument(document)
        let message = if rawCommand.len > 11: rawCommand[11 .. ^1].strip else: ""
        if repository == nil:
          editorViewState.statusMessage = "Git repository not found"
        elif message.len == 0:
          editorViewState.statusMessage = "Git commit requires a message"
        else:
          startNativeGitAction(repository, "commit", "", ["commit", "-m", message])
    of "__git_amend__":
      when defined(macosx):
        let repository = gitRepositoryForDocument(document)
        const amendPrefix = "git commit --amend"
        let message = if rawCommand.len > amendPrefix.len:
          rawCommand[amendPrefix.len .. ^1].strip else: ""
        if repository == nil:
          editorViewState.statusMessage = "Git repository not found"
        elif message.len == 0:
          editorViewState.statusMessage = "Git amend requires a message"
        else:
          # Zed exposes amend as an explicit commit-modal mode. The command
          # palette keeps that safety property: it never infers --amend.
          startNativeGitAction(repository, "amend", "",
            ["commit", "--amend", "-m", message])
    of "__git_checkout__":
      when defined(macosx):
        let repository = gitRepositoryForDocument(document)
        let source = if rawCommand.len > 13: rawCommand[13 .. ^1].strip else: ""
        let relative = gitRelativePathForDocument(document, repository)
        if repository == nil or relative.len == 0:
          editorViewState.statusMessage = "Git repository not found"
        elif source.len == 0:
          editorViewState.statusMessage = "Git checkout requires a revision"
        else:
          startNativeGitAction(repository, "checkout", relative,
            ["checkout", source, "--", relative], source = source)
    of "__git_switch__":
      when defined(macosx):
        let repository = gitRepositoryForDocument(document)
        let branch = if rawCommand.len > 11: rawCommand[11 .. ^1].strip else: ""
        if repository == nil:
          editorViewState.statusMessage = "Git repository not found"
        elif not isSafeBranchName(branch):
          editorViewState.statusMessage = "Git branch name is invalid"
        else:
          # `switchBranch` validates with `check-ref-format`; the UI keeps the
          # same Git process asynchronous and lets Git reject unknown branches.
          startNativeGitAction(repository, "switch branch", "",
            ["switch", "--no-guess", branch], source = branch)
    else: editorViewState.statusMessage = "Unknown command: " & command
  elif name == "saveAndClose":
    let document = activeDocument()
    if document == nil or not document[].buffer.isDirty:
      platformSetCloseDecision(true)
    elif document[].path.len > 0:
      try:
        document[].save()
        syncEditorCursor()
        platformSetCloseDecision(true)
      except CatchableError:
        platformSetCloseDecision(false)
    else:
      platformShowSavePanelAndClose()
  elif name == "reloadExternal":
    try:
      let target = externalAlertTab
      if target < 0 or target >= editorSession.tabs.len: return
      let path = editorSession.tabs[target].document.path
      if path.len == 0: return
      let reloaded = openDocument(path)
      editorSession.tabs[target].document = reloaded
      let text = reloaded.buffer.toString()
      editorSession.tabs[target].view.clampSelectionToText(text)
      editorSession.tabs[target].secondaryView.clampSelectionToText(text)
      if target == editorSession.activeTab:
        editorSession.loadActiveView(editorViewState)
      if editorSession.split and target == editorSession.effectiveSplitSecondaryTab():
        editorSession.secondaryView = editorSession.tabs[target].secondaryView
      resetImeState()
      if syntaxState != nil:
        syntaxState.close()
        syntaxState = nil
      externalAlertShown = false
      externalAlertTab = -1
      syncEditorCursor()
      refreshEditorSyntax()
    except CatchableError:
      externalAlertShown = false
      externalAlertTab = -1
  elif name == "keepExternal":
    let target = externalAlertTab
    if target >= 0 and target < editorSession.tabs.len:
      editorSession.tabs[target].document.acceptExternalState()
    externalAlertShown = false
    externalAlertTab = -1
  elif name.startsWith("sidebarSelect:"):
    when defined(macosx):
      try:
        let index = parseInt(name[14 .. ^1])
        if editorWorkspaceUi.selectPanelItem(workspacePanelForSidebarMode(editorSidebarMode), index):
          syncNativeSidebarSelection()
      except ValueError:
        editorViewState.statusMessage = "Invalid sidebar selection"
  elif name == "sidebarFocusEditor":
    when defined(macosx):
      editorWorkspaceUi.focusCenter()
      platformFocusEditor()
  elif name == "sidebarStageToggleSelected":
    when defined(macosx):
      let index = editorWorkspaceUi.panelSelectedIndex(panelGit)
      if editorSidebarMode != sidebarGitStatus or index < 0:
        editorViewState.statusMessage = "Git status item is unavailable"
      else:
        receiveNativeCommand(("sidebarStageToggle:" & $index).cstring)
  elif name in ["sidebarDuplicateSelected", "sidebarCopySelected", "sidebarCutSelected",
                "sidebarPasteSelected", "sidebarTrashSelectedNoPrompt",
                "sidebarDeleteSelected", "sidebarRevealSelected",
                "sidebarOpenWithSystem", "sidebarSearchInSelected"]:
    when defined(macosx):
      if editorSidebarMode != sidebarFiles or activeWorkspace == nil:
        return
      try:
        let entry = selectedWorkspacePanelEntry()
        case name
        of "sidebarDuplicateSelected": duplicateSelectedWorkspaceEntry()
        of "sidebarCopySelected": copyOrCutSelectedWorkspaceEntry(false)
        of "sidebarCutSelected": copyOrCutSelectedWorkspaceEntry(true)
        of "sidebarPasteSelected": pasteWorkspaceEntry()
        of "sidebarTrashSelectedNoPrompt": deleteSelectedWorkspaceEntry(false)
        of "sidebarDeleteSelected": deleteSelectedWorkspaceEntry(true)
        of "sidebarRevealSelected": platformRevealPath(entry.path.cstring)
        of "sidebarOpenWithSystem": platformOpenPath(entry.path.cstring)
        of "sidebarSearchInSelected":
          if entry.kind != WorkspaceFileKind.directory:
            editorViewState.statusMessage = "Find in Folder requires a directory"
          else:
            platformPromptWorkspaceSearchAtContext(entry.path.cstring, true)
        else: discard
      except CatchableError as error:
        editorViewState.statusMessage = error.msg
  elif name == "sidebarRenameSelected":
    when defined(macosx):
      if editorSidebarMode != sidebarFiles or activeWorkspace == nil:
        return
      let index = editorWorkspaceUi.panelSelectedIndex(panelFiles)
      if index < 0 or index >= workspacePreviewEntries.len:
        return
      let entry = workspacePreviewEntries[index]
      if entry.relativePath.len == 0:
        editorViewState.statusMessage = "Workspace root cannot be renamed"
      else:
        platformRenameWorkspaceEntry(entry.path.cstring,
          entry.kind == WorkspaceFileKind.directory)
  elif name in ["sidebarNewFileSelected", "sidebarNewDirectorySelected", "sidebarTrashSelected"]:
    when defined(macosx):
      if editorSidebarMode != sidebarFiles or activeWorkspace == nil:
        return
      let index = editorWorkspaceUi.panelSelectedIndex(panelFiles)
      if index < 0 or index >= workspacePreviewEntries.len:
        return
      let entry = workspacePreviewEntries[index]
      if name == "sidebarTrashSelected" and entry.relativePath.len == 0:
        editorViewState.statusMessage = "Workspace root cannot be moved to Trash"
      elif name == "sidebarNewFileSelected":
        platformPromptWorkspaceFileAtContext(entry.path.cstring,
          entry.kind == WorkspaceFileKind.directory)
      elif name == "sidebarNewDirectorySelected":
        platformPromptWorkspaceDirectoryAtContext(entry.path.cstring,
          entry.kind == WorkspaceFileKind.directory)
      else:
        platformPromptWorkspaceTrashAtContext(entry.path.cstring,
          entry.kind == WorkspaceFileKind.directory)
  elif name in ["sidebarCollapseAll", "sidebarExpandAll"]:
    when defined(macosx):
      if editorSidebarMode != sidebarFiles or activeWorkspace == nil:
        return
      try:
        let entry = selectedWorkspacePanelEntry()
        if name == "sidebarCollapseAll":
          collapseAllWorkspaceEntries()
        else:
          let start = if entry.kind == WorkspaceFileKind.directory: entry.path else: entry.path.parentDir
          expandWorkspaceDirectoryTree(start)
          refreshWorkspacePreview()
          editorViewState.statusMessage = "Expanded workspace folders"
      except CatchableError as error:
        editorViewState.statusMessage = error.msg
  elif name in ["sidebarCollapseSelected", "sidebarExpandSelected"]:
    when defined(macosx):
      if editorSidebarMode != sidebarFiles or activeWorkspace == nil:
        return
      let index = editorWorkspaceUi.panelSelectedIndex(panelFiles)
      if index < 0 or index >= workspacePreviewEntries.len:
        return
      let entry = workspacePreviewEntries[index]
      if name == "sidebarCollapseSelected" and
          entry.kind != WorkspaceFileKind.directory:
        let parent = entry.path.parentDir
        for parentIndex, candidate in workspacePreviewEntries:
          if candidate.kind == WorkspaceFileKind.directory and candidate.path == parent:
            discard editorWorkspaceUi.selectPanelItem(panelFiles, parentIndex)
            syncNativeSidebarSelection()
            return
      if entry.kind != WorkspaceFileKind.directory:
        return
      var expandedIndex = -1
      for candidateIndex, candidate in workspaceExpandedDirectories:
        if candidate == entry.path:
          expandedIndex = candidateIndex
          break
      if name == "sidebarExpandSelected" and expandedIndex < 0:
        workspaceExpandedDirectories.add(entry.path)
        refreshWorkspacePreview()
      elif name == "sidebarExpandSelected" and index + 1 < workspacePreviewEntries.len:
        # Zed advances into an already-expanded directory on Right, so a
        # second key press moves from its label to its first visible child.
        discard editorWorkspaceUi.selectPanelItem(panelFiles, index + 1)
        syncNativeSidebarSelection()
      elif name == "sidebarCollapseSelected" and expandedIndex >= 0:
        workspaceExpandedDirectories.delete(expandedIndex)
        refreshWorkspacePreview()
      elif name == "sidebarCollapseSelected":
        # A collapsed directory yields to its visible parent. This also keeps
        # keyboard navigation inside the bounded tree projection.
        let parent = entry.path.parentDir
        for parentIndex, candidate in workspacePreviewEntries:
          if candidate.kind == WorkspaceFileKind.directory and candidate.path == parent:
            discard editorWorkspaceUi.selectPanelItem(panelFiles, parentIndex)
            syncNativeSidebarSelection()
            break
  elif name in ["sidebarPrevious", "sidebarNext", "sidebarFirst", "sidebarLast"]:
    when defined(macosx):
      let panel = workspacePanelForSidebarMode(editorSidebarMode)
      let changed = case name
        of "sidebarPrevious": editorWorkspaceUi.movePanelSelection(panel, -1)
        of "sidebarNext": editorWorkspaceUi.movePanelSelection(panel, 1)
        of "sidebarFirst": editorWorkspaceUi.selectPanelBoundary(panel, last = false)
        else: editorWorkspaceUi.selectPanelBoundary(panel, last = true)
      if changed: syncNativeSidebarSelection()
  elif name == "sidebarOpenSelected":
    when defined(macosx):
      let index = editorWorkspaceUi.panelSelectedIndex(
        workspacePanelForSidebarMode(editorSidebarMode))
      if index >= 0:
        receiveNativeCommand(("sidebarOpen:" & $index).cstring)
  elif name.startsWith("sidebarItem:") or name.startsWith("sidebarOpen:"):
    when defined(macosx):
      let payload = name[12 .. ^1]
      try:
        let index = parseInt(payload)
        if editorSidebarMode != sidebarOutline:
          discard editorWorkspaceUi.selectPanelItem(
            workspacePanelForSidebarMode(editorSidebarMode), index)
          syncNativeSidebarSelection()
        case editorSidebarMode
        of sidebarFiles:
          if activeWorkspace == nil:
            if index == 0: platformOpenWorkspaceFolder()
          elif index >= 0 and index < workspacePreviewEntries.len:
            let entry = workspacePreviewEntries[index]
            if entry.kind == WorkspaceFileKind.directory:
              var expandedIndex = -1
              for candidateIndex, candidate in workspaceExpandedDirectories:
                if candidate == entry.path:
                  expandedIndex = candidateIndex
                  break
              if expandedIndex >= 0:
                workspaceExpandedDirectories.delete(expandedIndex)
              else:
                workspaceExpandedDirectories.add(entry.path)
              refreshWorkspacePreview()
            else:
              openFilesDockEntry(entry.path)
        of sidebarWorkspaceSearch:
          if index >= 0 and index < workspaceSearchResults.len:
            let match = workspaceSearchResults[index]
            openFilesDockEntry(match.path)
            let target = if editorSession.split and editorSession.splitActivePane == 1:
              secondaryPaneDocument() else: activeDocument()
            if target != nil:
              let lineIndex = max(0, match.line - 1)
              let lineStart = target[].buffer.byteOffsetAtLineColumn(lineIndex, 0)
              moveActiveEditorCursor(min(target[].buffer.toString().len,
                lineStart + max(0, match.column - 1)))
              syncEditorCursor()
              refreshEditorSyntax()
        of sidebarGitHistory:
          if index >= 0 and index < editorGitHistory.len:
            # A history list belongs to the repository that produced it, not
            # to whichever document happened to gain focus while it remained
            # visible. This matches Zed's project-path history target.
            let repository = editorGitRepository
            if repository == nil:
              editorViewState.statusMessage = "Git repository not found"
            else:
              # Zed presents commit metadata separately from the loaded diff.
              # Keep the same bounded async Git job boundary here, but include
              # the patch so a history entry is useful without a shell escape
              # or repository-provided external diff driver.
              var args = @["show", "--format=fuller", "--stat", "--patch",
                "--no-ext-diff", editorGitHistory[index].hash]
              if editorGitHistoryPath.len > 0:
                args.add("--")
                args.add(editorGitHistoryPath)
              startNativeGitAction(repository, "show", "", args)
        of sidebarGitStatus:
          if editorGitRepository == nil and index == 0:
            platformOpenWorkspaceFolder()
          elif index >= 0 and index < editorGitStatusEntries.len:
            let entry = editorGitStatusEntries[index]
            let repository = editorGitRepository
            if repository == nil:
              editorViewState.statusMessage = "Git repository not found"
            else:
              let candidate = canonicalOpenPath(repository.root / entry.path)
              let root = canonicalOpenPath(repository.root)
              let rootPrefix = root / ""
              if not (candidate == root or candidate.startsWith(rootPrefix)):
                editorViewState.statusMessage = "Git status path is outside repository"
              elif not fileExists(candidate) or dirExists(candidate):
                editorViewState.statusMessage = "Git status file is unavailable: " & entry.path
              else:
                # A Git change-list file is a workspace navigation action,
                # so preserve the focused split pane just like Files does.
                openFilesDockEntry(candidate)
        of sidebarGitBranches:
          if index >= 0 and index < editorGitBranches.len:
            let branch = editorGitBranches[index]
            if branch.current:
              editorViewState.statusMessage = "Git: already on " & branch.name
            elif editorGitRepository == nil:
              editorViewState.statusMessage = "Git repository not found"
            else:
              # The source is Git's own machine-oriented branch listing, and
              # the command still opts out of remote-name guessing.
              startNativeGitAction(editorGitRepository, "switch branch", "",
                ["switch", "--no-guess", branch.name], source = branch.name)
        of sidebarOutline:
          discard openNativeSymbol(index)
        of sidebarDebugger:
          if index < 0 or index >= editorDapSidebarItems.len:
            editorViewState.statusMessage = "Debugger row is unavailable"
          else:
            let item = editorDapSidebarItems[index]
            case item.kind
            of dapThreadItem:
              editorDapThreadId = item.id
              editorDapFrameId = -1
              editorDapScopes.setLen(0)
              editorDapVariables.setLen(0)
              editorDapVariableRootReference = 0
              editorDapVariableRequestReference = 0
              editorDapExpandedVariableReferences.setLen(0)
              discard sendNativeDapRequest("stackTrace", stackTraceArguments(item.id))
            of dapFrameItem:
              editorDapFrameId = item.id
              editorDapScopes.setLen(0)
              editorDapVariables.setLen(0)
              editorDapVariableRootReference = 0
              editorDapVariableRequestReference = 0
              editorDapExpandedVariableReferences.setLen(0)
              discard sendNativeDapRequest("scopes", scopesArguments(item.id))
              for frame in editorDapFrames:
                if frame.id == item.id:
                  openNativeDapFrame(frame)
                  break
            of dapScopeItem:
              editorDapVariableRootReference = item.reference
              editorDapVariableRequestReference = item.reference
              editorDapVariables.setLen(0)
              editorDapExpandedVariableReferences.setLen(0)
              discard sendNativeDapRequest("variables",
                variablesArguments(item.reference))
            of dapVariableItem:
              if item.reference <= 0:
                editorViewState.statusMessage = "Variable has no children"
              else:
                let expandedIndex = editorDapExpandedVariableReferences.find(item.reference)
                var rowIndex = -1
                for candidateIndex, candidate in editorDapVariables:
                  if candidate.reference == item.reference:
                    rowIndex = candidateIndex
                    break
                if expandedIndex >= 0 and rowIndex >= 0:
                  let depth = editorDapVariables[rowIndex].depth
                  var lastRow = rowIndex + 1
                  while lastRow < editorDapVariables.len and
                      editorDapVariables[lastRow].depth > depth:
                    inc lastRow
                  if lastRow > rowIndex + 1:
                    editorDapVariables.delete(rowIndex + 1 .. lastRow - 1)
                  editorDapExpandedVariableReferences.delete(expandedIndex)
                elif expandedIndex < 0:
                  editorDapExpandedVariableReferences.add(item.reference)
                  editorDapVariableRequestReference = item.reference
                  discard sendNativeDapRequest("variables",
                    variablesArguments(item.reference))
            of dapWatchItem:
              discard
            renderNativeDapSidebar()
      except ValueError:
        editorViewState.statusMessage = "Invalid sidebar item"
  elif name.startsWith("sidebarContext:"):
    when defined(macosx):
      try:
        let index = parseInt(name[15 .. ^1])
        if editorSidebarMode == sidebarFiles and index >= 0 and index < workspacePreviewEntries.len:
          let entry = workspacePreviewEntries[index]
          discard editorWorkspaceUi.selectPanelItem(panelFiles, index)
          syncNativeSidebarSelection()
          platformShowWorkspaceEntryContext(entry.path.cstring,
            entry.kind == WorkspaceFileKind.directory)
        elif editorSidebarMode == sidebarGitHistory and index >= 0 and
            index < editorGitHistory.len:
          discard editorWorkspaceUi.selectPanelItem(panelGit, index)
          syncNativeSidebarSelection()
          platformShowGitHistoryContext(uint32(index))
        elif editorSidebarMode == sidebarGitStatus and index >= 0 and
            index < editorGitStatusEntries.len:
          let projection = if index < editorGitStatusProjections.len:
            editorGitStatusProjections[index] else: gitStatusConflict
          discard editorWorkspaceUi.selectPanelItem(panelGit, index)
          syncNativeSidebarSelection()
          # A projected partial file receives the action dictated by its
          # section: Staged means Unstage, Unstaged means Stage. Conflicts
          # intentionally expose no implicit resolution action.
          platformShowGitStatusContext(uint32(index), uint32(ord(projection)))
        elif editorSidebarMode == sidebarGitBranches and index >= 0 and
            index < editorGitBranches.len:
          discard editorWorkspaceUi.selectPanelItem(panelGit, index)
          syncNativeSidebarSelection()
          platformShowGitBranchContext(uint32(index))
      except ValueError:
        editorViewState.statusMessage = "Invalid workspace context item"
  elif name.startsWith("gitBranchContext:"):
    when defined(macosx):
      let parts = name.split(':')
      if parts.len != 3 or parts[1] != "copy":
        editorViewState.statusMessage = "Invalid Git branch action"
      else:
        try:
          let index = parseInt(parts[2])
          if editorSidebarMode != sidebarGitBranches or index < 0 or
              index >= editorGitBranches.len:
            editorViewState.statusMessage = "Git branch is unavailable"
          else:
            let branch = editorGitBranches[index].name
            clipboardSet(branch.cstring, uint32(branch.len))
            editorViewState.statusMessage = "Git branch copied: " & branch
        except ValueError:
          editorViewState.statusMessage = "Invalid Git branch action"
  elif name.startsWith("gitStatusContext:"):
    when defined(macosx):
      let parts = name.split(':')
      if parts.len != 3:
        editorViewState.statusMessage = "Invalid Git status action"
      else:
        try:
          let index = parseInt(parts[2])
          if editorSidebarMode != sidebarGitStatus or index < 0 or
              index >= editorGitStatusEntries.len or editorGitRepository == nil:
            editorViewState.statusMessage = "Git status item is unavailable"
          else:
            let entry = editorGitStatusEntries[index]
            let repository = editorGitRepository
            case parts[1]
            of "diff", "diffStaged", "diffUnstaged":
              let candidate = canonicalOpenPath(repository.root / entry.path)
              if entry.indexStatus == '?' and entry.worktreeStatus == '?':
                # Untracked files have no HEAD side. `--no-index` supplies a
                # normal unified patch against /dev/null and returns 1 by Git
                # convention, which pollNativeGitAction accepts for this view.
                startNativeGitAction(repository, "show file diff", entry.path,
                  ["diff", "--no-index", "--no-ext-diff", "--unified=3", "--",
                   "/dev/null", candidate])
              else:
                let diffArgs = case parts[1]
                  of "diffStaged": @["diff", "--cached", "--no-ext-diff", "--unified=3", "--", entry.path]
                  of "diffUnstaged": @["diff", "--no-ext-diff", "--unified=3", "--", entry.path]
                  else: @["diff", "--no-ext-diff", "--unified=3", "HEAD", "--", entry.path]
                startNativeGitAction(repository, "show file diff", entry.path, diffArgs)
            of "open":
              let candidate = canonicalOpenPath(repository.root / entry.path)
              let root = canonicalOpenPath(repository.root)
              let rootPrefix = root / ""
              if not (candidate == root or candidate.startsWith(rootPrefix)):
                editorViewState.statusMessage = "Git status path is outside repository"
              elif not fileExists(candidate) or dirExists(candidate):
                editorViewState.statusMessage = "Git status file is unavailable: " & entry.path
              else:
                openFilesDockEntry(candidate)
            of "stage":
              if entry.conflict:
                editorViewState.statusMessage = "Git conflict must be resolved before staging"
              elif entry.worktreeStatus == ' ' and entry.indexStatus != '?':
                editorViewState.statusMessage = "Git change is already staged"
              else:
                startNativeGitAction(repository, "stage file", entry.path,
                  ["add", "--", entry.path])
            of "unstage":
              if entry.conflict:
                editorViewState.statusMessage = "Git conflict must be resolved explicitly"
              elif entry.indexStatus in {' ', '?', '!'}:
                editorViewState.statusMessage = "Git change is not staged"
              else:
                startNativeGitAction(repository, "unstage file", entry.path,
                  ["reset", "HEAD", "--", entry.path])
            else:
              editorViewState.statusMessage = "Unknown Git status action"
        except ValueError:
          editorViewState.statusMessage = "Invalid Git status item"
  elif name.startsWith("sidebarStageToggle:"):
    when defined(macosx):
      try:
        let index = parseInt(name[19 .. ^1])
        if editorSidebarMode != sidebarGitStatus or index < 0 or
            index >= editorGitStatusEntries.len or index >= editorGitStatusProjections.len or
            editorGitRepository == nil:
          editorViewState.statusMessage = "Git status item is unavailable"
        else:
          let entry = editorGitStatusEntries[index]
          discard editorWorkspaceUi.selectPanelItem(panelGit, index)
          syncNativeSidebarSelection()
          case editorGitStatusProjections[index]
          of gitStatusConflict:
            editorViewState.statusMessage = "Git conflict must be resolved explicitly"
          of gitStatusStaged:
            startNativeGitAction(editorGitRepository, "unstage file", entry.path,
              ["reset", "HEAD", "--", entry.path])
          of gitStatusUnstaged:
            startNativeGitAction(editorGitRepository, "stage file", entry.path,
              ["add", "--", entry.path])
      except ValueError:
        editorViewState.statusMessage = "Invalid Git status item"
  elif name.startsWith("gitHistoryContext:"):
    when defined(macosx):
      let parts = name.split(':')
      if parts.len != 3:
        editorViewState.statusMessage = "Invalid Git history action"
      else:
        try:
          let index = parseInt(parts[2])
          if editorSidebarMode != sidebarGitHistory or index < 0 or
              index >= editorGitHistory.len:
            editorViewState.statusMessage = "Git history item is unavailable"
          elif parts[1] == "copy":
            let hash = editorGitHistory[index].hash
            clipboardSet(hash.cstring, uint32(hash.len))
            editorViewState.statusMessage = "Git: commit SHA copied"
          elif parts[1] == "open":
            let repository = editorGitRepository
            if repository == nil:
              editorViewState.statusMessage = "Git repository not found"
            else:
              var args = @["show", "--format=fuller", "--stat", "--patch",
                "--no-ext-diff", editorGitHistory[index].hash]
              if editorGitHistoryPath.len > 0:
                args.add("--")
                args.add(editorGitHistoryPath)
              startNativeGitAction(repository, "show", "", args)
          else:
            editorViewState.statusMessage = "Unknown Git history action"
        except ValueError:
          editorViewState.statusMessage = "Invalid Git history item"
  elif name.startsWith("workspaceSearchIn:"):
    when defined(macosx):
      let fields = name["workspaceSearchIn:".len .. ^1].split('\x1f', maxsplit = 1)
      if fields.len != 2 or fields[1].strip.len == 0:
        editorViewState.statusMessage = "Folder search requires a query"
      else:
        let scope = canonicalOpenPath(fields[0])
        var belongsToWorkspace = false
        if activeWorkspace != nil:
          for configuredRoot in activeWorkspace.rootPaths:
            let root = canonicalOpenPath(configuredRoot)
            if scope == root or scope.startsWith(root / ""):
              belongsToWorkspace = true
              break
        if not belongsToWorkspace or not dirExists(scope):
          editorViewState.statusMessage = "Search folder is outside workspace"
        else:
          showWorkspaceSearch(fields[1].strip, scope)
  elif name.startsWith("workspaceSearch:"):
    showWorkspaceSearch(name[16 .. ^1])
  elif name.startsWith("workspaceFileHistory:"):
    when defined(macosx):
      let filePath = canonicalOpenPath(name["workspaceFileHistory:".len .. ^1])
      let repository = repositoryForPath(filePath)
      if repository == nil:
        editorViewState.statusMessage = "Git repository not found"
      else:
        let prefix = repository.root & DirSep
        if not filePath.startsWith(prefix):
          editorViewState.statusMessage = "Git history path is outside repository"
        else:
          let relative = filePath[prefix.len .. ^1]
          startNativeGitAction(repository, "file history", relative, [
            "log", "--format=%H%x00%an%x00%ae%x00%at%x00%s%x00", "-n", "100",
            "--", relative])
  elif name.startsWith("workspaceOpenTerminal:"):
    when defined(macosx):
      let selectedPath = canonicalOpenPath(name["workspaceOpenTerminal:".len .. ^1])
      let cwd = if dirExists(selectedPath): selectedPath else: selectedPath.parentDir
      var belongsToWorkspace = false
      if activeWorkspace != nil:
        for configuredRoot in activeWorkspace.rootPaths:
          let root = canonicalOpenPath(configuredRoot)
          if cwd == root or cwd.startsWith(root / ""):
            belongsToWorkspace = true
            break
      if not belongsToWorkspace or not dirExists(cwd):
        editorViewState.statusMessage = "Terminal path is outside workspace"
      else:
        newNativeTerminal(cwd)
        if editorTerminalVisible: editorWorkspaceUi.openPanel(panelTerminal)
        setupDemoUi()
        resizeNativeTerminals()
  elif name.startsWith("workspaceCopyPath:"):
    let path = name["workspaceCopyPath:".len .. ^1]
    if path.len > 0:
      clipboardSet(path.cstring, uint32(path.len))
      editorViewState.statusMessage = "Copied path"
  elif name.startsWith("workspaceCopyRelativePath:"):
    let path = name["workspaceCopyRelativePath:".len .. ^1]
    if path.len > 0 and activeWorkspace != nil:
      try:
        let location = activeWorkspace.splitWorkspacePath(path)
        let relative = if location.relative.len > 0: location.relative else: "."
        clipboardSet(relative.cstring, uint32(relative.len))
        editorViewState.statusMessage = "Copied relative path"
      except CatchableError:
        editorViewState.statusMessage = "Path is outside the workspace"
  elif name.startsWith("quickOpenOpen:"):
    when defined(macosx):
      let query = name[14 .. ^1].strip
      if query.len == 0: return
      if workspacePreviewMode != "quickOpen" or workspaceQuickOpenQuery != query:
        showQuickOpen(query)
      if workspacePreviewEntries.len > 0:
        let entry = workspacePreviewEntries[0]
        if entry.kind == WorkspaceFileKind.directory:
          openActiveWorkspace(entry.path)
        else:
          openFilesDockEntry(entry.path)
      else:
        # Fuzzy search is asynchronous. Keep the user's Return intent and
        # open the first result at the same UI boundary that publishes the
        # completed result list.
        workspaceQuickOpenOpenPending = true
  elif name == "cancelQuickOpen":
    when defined(macosx):
      if workspaceQuickOpenJob != nil:
        workspaceQuickOpenJob.cancelFuzzySearch()
        workspaceQuickOpenJob = nil
      workspaceQuickOpenOpenPending = false
      workspaceQuickOpenQuery = ""
      workspacePreviewEntries.setLen(0)
      if activeWorkspace != nil:
        refreshWorkspacePreview()
  elif name.startsWith("quickOpen:"):
    showQuickOpen(name[10 .. ^1].strip)
  elif name.startsWith("workspaceCreateFile:") and activeWorkspace != nil:
    let payload = workspaceRelativePayload(name, "workspaceCreateFile:")
    if payload.len == 0: return
    try:
      let location = activeWorkspace.splitWorkspacePath(payload)
      let createdPath = activeWorkspace.createFileAt(location.root, location.relative)
      refreshWorkspaceAfterMutation("Created " & payload)
      # Match Zed's Project Panel auto-open behavior for ordinary files: the
      # new item becomes a real editor tab, not a filesystem-only mutation.
      if fileExists(createdPath): receiveNativeFile(createdPath.cstring, false)
    except CatchableError as error:
      editorViewState.statusMessage = "Create failed: " & error.msg
  elif name.startsWith("workspaceCreateDirectory:") and activeWorkspace != nil:
    let payload = workspaceRelativePayload(name, "workspaceCreateDirectory:")
    if payload.len == 0: return
    try:
      let location = activeWorkspace.splitWorkspacePath(payload)
      discard activeWorkspace.createDirectoryAt(location.root, location.relative)
      refreshWorkspaceAfterMutation("Created " & payload)
    except CatchableError as error:
      editorViewState.statusMessage = "Create failed: " & error.msg
  elif name.startsWith("workspaceDelete:") and activeWorkspace != nil:
    let payload = workspaceRelativePayload(name, "workspaceDelete:")
    if payload.len == 0: return
    try:
      let location = activeWorkspace.splitWorkspacePath(payload)
      activeWorkspace.deleteEntryAt(location.root, location.relative)
      refreshWorkspaceAfterMutation("Deleted " & payload)
    except CatchableError as error:
      editorViewState.statusMessage = "Delete failed: " & error.msg
  elif name.startsWith("workspaceTrash:") and activeWorkspace != nil:
    let payload = workspaceRelativePayload(name, "workspaceTrash:")
    if payload.len == 0: return
    try:
      let location = activeWorkspace.splitWorkspacePath(payload)
      let path = activeWorkspace.entryPathAt(location.root, location.relative)
      when defined(macosx):
        if not platformMoveItemToTrash(path.cstring):
          raise newException(IOError, "macOS could not move the entry to Trash")
        refreshWorkspaceAfterMutation("Moved to Trash " & payload)
      else:
        raise newException(IOError, "Moving workspace entries to Trash requires macOS")
    except CatchableError as error:
      editorViewState.statusMessage = "Move to Trash failed: " & error.msg
  elif name.startsWith("workspaceRename:") and activeWorkspace != nil:
    let payload = workspaceRelativePayload(name, "workspaceRename:")
    let separator = payload.find('\x1f')
    if separator <= 0 or separator + 1 >= payload.len: return
    let oldPayload = payload[0 ..< separator].strip
    let newPayload = payload[separator + 1 .. ^1].strip
    try:
      let oldLocation = activeWorkspace.splitWorkspacePath(oldPayload)
      let newLocation = activeWorkspace.splitWorkspacePath(newPayload)
      if oldLocation.root != newLocation.root:
        raise newException(ValueError, "rename must stay within one workspace root")
      let oldPath = activeWorkspace.entryPathAt(oldLocation.root, oldLocation.relative)
      let newPath = activeWorkspace.renameEntryAt(oldLocation.root, oldLocation.relative,
          newLocation.relative)
      rebaseOpenDocuments(oldPath, newPath)
      refreshWorkspaceAfterMutation("Renamed " & oldPayload & " to " & newPayload)
      syncRecentFiles()
      syncEditorCursor()
      refreshEditorSyntax()
      persistSession()
    except CatchableError as error:
      editorViewState.statusMessage = "Rename failed: " & error.msg
  elif name.startsWith("findDocument:") and document != nil:
    let prefix = "findDocument:"
    let query = if name.len > prefix.len: name[prefix.len .. ^1] else: ""
    if query.len == 0:
      editorViewState.statusMessage = "Find requires a query"
      return
    let matches = document[].search(query)
    if matches.len > 0:
      if editorSession.split and editorSession.splitActivePane == 1:
        editorSession.secondaryView.selection.anchor = matches[0].startByte
        editorSession.secondaryView.selection.active = matches[0].endByte
      else:
        editorViewState.selection.anchor = matches[0].startByte
        editorViewState.selection.active = matches[0].endByte
      editorViewState.statusMessage = "Found " & query
      syncEditorCursor()
      refreshEditorSyntax()
    else:
      editorViewState.statusMessage = "No matches for " & query
  elif name.startsWith("replaceDocument:") and document != nil:
    let prefix = "replaceDocument:"
    let payload = if name.len > prefix.len: name[prefix.len .. ^1] else: ""
    let separator = payload.find('\x1f')
    if separator <= 0:
      editorViewState.statusMessage = "Replace requires search and replacement"
      return
    let query = payload[0 ..< separator]
    let replacement = if separator + 1 < payload.len: payload[separator + 1 .. ^1] else: ""
    let count = document[].replaceAll(query, replacement)
    let text = document[].buffer.toString()
    editorViewState.clampSelectionToText(text)
    if editorSession.split:
      editorSession.secondaryView.clampSelectionToText(text)
    editorViewState.statusMessage = "Replaced " & $count & " matches"
    syncEditorCursor()
    refreshEditorSyntax()
  elif name == "cancel":
    imeState.composition.setLen(0)
    when defined(macosx) or defined(windows): platformSetEditorComposition("".cstring)
  elif name == "moveLeft" and document != nil:
    editorViewState.clearAdditionalSelections()
    editorViewState.moveCursor(previousBoundary(document[].buffer.toString(),
        editorViewState.cursor))
    syncEditorCursor()
  elif name == "selectLeft" and document != nil:
    editorViewState.clearAdditionalSelections()
    editorViewState.moveCursor(previousBoundary(document[].buffer.toString(),
        editorViewState.cursor), selecting = true)
    syncEditorCursor()
  elif name == "moveRight" and document != nil:
    editorViewState.clearAdditionalSelections()
    editorViewState.moveCursor(nextBoundary(document[].buffer.toString(), editorViewState.cursor))
    syncEditorCursor()
  elif name in ["moveUp", "moveDown", "selectUp", "selectDown"] and document != nil:
    editorViewState.clearAdditionalSelections()
    let location = document[].buffer.lineColumn(editorViewState.cursor)
    let delta = if name in ["moveUp", "selectUp"]: -1 else: 1
    let targetLine = max(0, min(document[].buffer.lineStarts.high, location.line + delta))
    let target = document[].buffer.byteOffsetAtLineColumn(targetLine, location.column)
    editorViewState.moveCursor(target, selecting = name.startsWith("select"))
    syncEditorCursor()
  elif name in ["moveToBeginningOfLine", "selectToBeginningOfLine"] and document != nil:
    editorViewState.clearAdditionalSelections()
    let location = document[].buffer.lineColumn(editorViewState.cursor)
    editorViewState.moveCursor(document[].buffer.lineStarts[location.line],
      selecting = name.startsWith("select"))
    syncEditorCursor()
  elif name in ["moveToEndOfLine", "selectToEndOfLine"] and document != nil:
    editorViewState.clearAdditionalSelections()
    let location = document[].buffer.lineColumn(editorViewState.cursor)
    editorViewState.moveCursor(lineEndOffset(document, location.line),
      selecting = name.startsWith("select"))
    syncEditorCursor()
  elif name == "moveToBeginningOfDocument" and document != nil:
    editorViewState.clearAdditionalSelections()
    editorViewState.moveCursor(0)
    syncEditorCursor()
  elif name == "moveToEndOfDocument" and document != nil:
    editorViewState.clearAdditionalSelections()
    editorViewState.moveCursor(document[].buffer.toString().len)
    syncEditorCursor()
  elif name == "selectToBeginningOfDocument" and document != nil:
    editorViewState.clearAdditionalSelections()
    editorViewState.moveCursor(0, selecting = true)
    syncEditorCursor()
  elif name == "selectToEndOfDocument" and document != nil:
    editorViewState.clearAdditionalSelections()
    editorViewState.moveCursor(document[].buffer.toString().len, selecting = true)
    syncEditorCursor()
  elif name == "insertNewline" and document != nil:
    receiveNativeText("\n".cstring, false)
  elif name == "insertTab" and document != nil:
    receiveNativeText("\t".cstring, false)
  elif name == "selectRight" and document != nil:
    editorViewState.clearAdditionalSelections()
    editorViewState.moveCursor(nextBoundary(document[].buffer.toString(), editorViewState.cursor),
        selecting = true)
    syncEditorCursor()
  elif name == "moveWordLeft" and document != nil:
    editorViewState.clearAdditionalSelections()
    editorViewState.moveCursor(previousWordBoundary(document[].buffer.toString(),
        editorViewState.cursor))
    syncEditorCursor()
  elif name == "selectWordLeft" and document != nil:
    editorViewState.clearAdditionalSelections()
    editorViewState.moveCursor(previousWordBoundary(document[].buffer.toString(),
        editorViewState.cursor), selecting = true)
    syncEditorCursor()
  elif name == "moveWordRight" and document != nil:
    editorViewState.clearAdditionalSelections()
    editorViewState.moveCursor(nextWordBoundary(document[].buffer.toString(),
        editorViewState.cursor))
    syncEditorCursor()
  elif name == "selectWordRight" and document != nil:
    editorViewState.clearAdditionalSelections()
    editorViewState.moveCursor(nextWordBoundary(document[].buffer.toString(),
        editorViewState.cursor), selecting = true)
    syncEditorCursor()
  elif name in ["deleteBackward", "deleteForward", "deleteWordBackward", "deleteWordForward",
                "deleteToBeginningOfLine", "deleteToEndOfLine"] and document != nil:
    if deleteEditorSelections(document, editorViewState, name):
      syncEditorCursor()
      refreshEditorSyntax()
      scheduleSessionPersistence()
  elif name == "undo" and document != nil:
    if document[].buffer.undo():
      editorViewState.moveCursor(min(editorViewState.cursor, document[].buffer.toString().len))
      syncEditorCursor()
      refreshEditorSyntax()
      scheduleSessionPersistence()
  elif name == "redo" and document != nil:
    if document[].buffer.redo():
      editorViewState.moveCursor(min(editorViewState.cursor, document[].buffer.toString().len))
      syncEditorCursor()
      refreshEditorSyntax()
      scheduleSessionPersistence()
  elif name == "copy" and document != nil:
    let copied = copyEditorSelections(document, editorViewState)
    clipboardSet(copied.cstring, uint32(copied.len))
  elif name == "cut" and document != nil:
    let copied = copyEditorSelections(document, editorViewState)
    clipboardSet(copied.cstring, uint32(copied.len))
    if deleteEditorSelections(document, editorViewState, "deleteForward"):
      refreshEditorSyntax()
      syncEditorCursor()
      scheduleSessionPersistence()
  elif name == "paste":
    receiveNativeTextValue(clipboardGet(), false)
  elif name == "selectAll" and document != nil:
    editorViewState.makeSingleSelection(0, document[].buffer.toString().len)
    syncEditorCursor()
  elif name == "selectNext" and document != nil:
    if selectNextEditorMatch(document, editorViewState):
      syncEditorCursor()
      refreshEditorSyntax()
  elif name == "selectAllMatches" and document != nil:
    if selectAllEditorMatches(document, editorViewState) > 0:
      syncEditorCursor()
      refreshEditorSyntax()
  elif name in ["addSelectionAbove", "addSelectionBelow"] and document != nil:
    let location = document[].buffer.lineColumn(editorViewState.cursor)
    let delta = if name == "addSelectionAbove": -1 else: 1
    let targetLine = location.line + delta
    if targetLine >= 0 and targetLine <= document[].buffer.lineStarts.high and
        editorViewState.addCaret(document[].buffer.byteOffsetAtLineColumn(
          targetLine, location.column), document[].buffer.toString()):
      syncEditorCursor()
      refreshEditorSyntax()

proc receiveNativeInput(event: ptr NimculusInputEvent) {.cdecl.} =
  if event.isNil: return
  when defined(windows):
    if handleWindowsTerminalInput(event): return
  when defined(macosx): pollLspAndRefreshDiagnostics()
  let kind = nativeEventKind(event.kind)
  # AppKit view points use a bottom-left origin. NimNUI layout and hit-test
  # rectangles use a top-left origin, so normalize once at the boundary.
  var uiY = float32(event.y)
  when defined(macosx):
    var metrics: PlatformMetrics
    platformGetMetrics(addr metrics)
    if metrics.heightPoints > 0:
      uiY = float32(metrics.heightPoints) - float32(event.y)
  let point = Point(x: px(float32(event.x)), y: px(uiY))
  when defined(macosx):
    ## Dock resizing belongs to workspace composition, not to the editor text
    ## presenter. Restrict capture to the divider so normal sidebar rows keep
    ## their native click behavior while the user has a direct affordance for
    ## persistent panel sizing.
    let viewportWidth = if metrics.widthPoints > 0: float32(metrics.widthPoints) else: 960'f32
    let viewportHeight = if metrics.heightPoints > 0: float32(metrics.heightPoints) else: 640'f32
    let workspaceViewport = Size(width: px(viewportWidth), height: px(viewportHeight))
    let workspaceLayout = editorWorkspaceUi.layout(workspaceViewport)
    let logicalDockWidth = float32(workspaceLayout.leftDock.size.width)
    let presentedDockWidth = dockPresentationWidth(logicalDockWidth,
      if MacProjectDockOnRight: 178'f32 else: 0'f32)
    let leftDividerX = editorWorkspaceUi.dockResizeDivider(dockLeft,
      viewportWidth, dockOnRight = MacProjectDockOnRight)
    let bottomDividerY = float32(workspaceLayout.bottomDock.origin.y)
    if editorWorkspaceUi.isResizingDock:
      if kind == pointerMove:
        if editorWorkspaceUi.resizingDock == dockLeft:
          editorWorkspaceUi.resizeDock(dockLeft, dockResizeRequest(dockLeft,
            float32(event.x), viewportWidth,
            dockOnRight = MacProjectDockOnRight), viewportWidth)
        else:
          editorWorkspaceUi.resizeDock(dockBottom,
            viewportHeight - uiY - DefaultStatusHeight, viewportHeight)
        setupDemoUi()
        return
      elif kind == pointerUp:
        editorWorkspaceUi.endDockResize()
        persistSession()
        return
    if kind == pointerDown and presentedDockWidth > 0'f32 and
        editorWorkspaceUi.leftDock.isOpen and
        abs(float32(event.x) - leftDividerX) <= 4'f32:
      editorWorkspaceUi.beginDockResize(dockLeft)
      return
    if kind == pointerDown and editorWorkspaceUi.bottomDock.isOpen and
        abs(uiY - bottomDividerY) <= 4'f32:
      editorWorkspaceUi.beginDockResize(dockBottom)
      return
    if kind == pointerDown:
      case workspaceLayout.presentedRegionAt(workspaceViewport, point,
          dockOnRight = MacProjectDockOnRight,
          presentedDockWidth = presentedDockWidth)
      of regionLeftDock: editorWorkspaceUi.focusedRegion = regionLeftDock
      of regionBottomDock: editorWorkspaceUi.focusedRegion = regionBottomDock
      of regionCenter: editorWorkspaceUi.focusCenter()
      else: discard
  let hit = demoTree.hitTest(point)
  let target = if kind in {keyDown, keyUp, modifiersChanged, command}:
    if demoTree.focused != NodeId(0): demoTree.focused else: hit
  else: hit
  when defined(macosx):
    let document = activeDocument()
    let inEditor = demoEditorBounds.contains(point) or demoSecondaryEditorBounds.contains(point)
    var splitPointerHandled = false
    if editorTerminalVisible and kind in {pointerDown, pointerMove, pointerUp, scroll} and
        handleTerminalPointer(kind, float32(event.x), uiY, event.button,
          event.modifiers, float32(event.deltaY), event.preciseScrolling):
      return
    if kind == pointerDown:
      editorTerminalFocused = false
    if not inEditor and lspBridge != nil:
      lspBridge.hideHover()
      syncNativeHover()
    if document != nil and kind == scroll and inEditor:
      let pane = if demoSplitEnabled:
        max(0, editorWorkspaceUi.paneIndexAt(demoTree.node(demoScrollNode).bounds, point)) else: 0
      let scrollDocument = if pane == 1: secondaryPaneDocument() else: document
      let visibleLines = if pane == 1: secondaryEditorVisibleLineCount() else:
        editorVisibleLineCount()
      let maxScroll = if scrollDocument == nil: 0 else:
        max(0, scrollDocument[].buffer.lineStarts.len - visibleLines)
      let modifiers = macOSModifiers(event.modifiers)
      let shiftScroll = shiftModifier in modifiers
      let horizontalDelta = if abs(float32(event.deltaX)) > 0.01'f32:
          float32(event.deltaX)
        elif shiftScroll: float32(event.deltaY) else: 0'f32
      let verticalDelta = if shiftScroll and abs(float32(event.deltaX)) <= 0.01'f32:
          0'f32 else: float32(event.deltaY)
      if pane == 1:
        if not editorSession.secondaryView.softWrap and abs(horizontalDelta) > 0.01'f32:
          editorSession.secondaryView.scrollX = max(0'f32,
            editorSession.secondaryView.scrollX + horizontalDelta)
        if abs(verticalDelta) > 0.01'f32:
          var view = editorSession.secondaryView
          view.reconcileScrollPosition(18'f32, float32(maxScroll) * 18'f32)
          let pixelDelta = scrollPixelDelta(editorSecondaryScrollRemainder,
            verticalDelta, event.preciseScrolling)
          view.setScrollYPixels(view.scrollYPixels + pixelDelta, 18'f32,
            float32(maxScroll) * 18'f32)
          editorSession.secondaryView = view
      else:
        if not editorViewState.softWrap and abs(horizontalDelta) > 0.01'f32:
          editorViewState.scrollX = max(0'f32,
            editorViewState.scrollX + horizontalDelta)
        if abs(verticalDelta) > 0.01'f32:
          editorViewState.reconcileScrollPosition(18'f32,
            float32(maxScroll) * 18'f32)
          let pixelDelta = scrollPixelDelta(editorScrollRemainder, verticalDelta,
            event.preciseScrolling)
          editorViewState.setScrollYPixels(editorViewState.scrollYPixels + pixelDelta,
            18'f32, float32(maxScroll) * 18'f32)
      # Wheel input changes only the viewport. Do not let cursor visibility
      # synchronization pull the freely scrolled position back into view.
      syncEditorCursor(ensureCursor = false)
      refreshEditorSyntax()
    if document != nil and kind == pointerDown and inEditor:
      let gutterPane = if demoSplitEnabled:
          editorWorkspaceUi.paneIndexAt(demoTree.node(demoScrollNode).bounds, point)
        else: 0
      let gutterDocument = if gutterPane == 1: secondaryPaneDocument() else: document
      let gutterBounds = if gutterPane == 1: demoSecondaryEditorBounds else: demoEditorBounds
      let gutterScrollLine = if gutterPane == 1:
          editorSession.secondaryView.scrollLine else: editorViewState.scrollLine
      let gutterScrollFraction = if gutterPane == 1:
          editorSession.secondaryView.scrollYFraction else: editorViewState.scrollYFraction
      if gutterDocument != nil and float32(event.x) - float32(gutterBounds.origin.x) < 8'f32 and
          handleGitGutterClick(gutterDocument, gutterBounds, gutterScrollLine,
            float32(event.x), uiY, event.modifiers, gutterScrollFraction):
        return
    if kind == pointerDown and hit == demoSplitNode:
      if not editorSession.split:
        editorSession.splitEditor(splitVertical, demoSplitRatio)
      demoSplitEnabled = true
      demoSplitDirection = editorSession.splitDirection
      demoSplitDragging = true
      editorPointerDragging = false
      splitPointerHandled = true
    elif demoSplitDragging and kind == pointerMove:
      let editorBounds = demoTree.node(demoScrollNode).bounds
      let axisLength = if demoSplitDirection == splitHorizontal:
          max(1'f32, float32(editorBounds.size.height))
        else:
          max(1'f32, float32(editorBounds.size.width))
      let position = if demoSplitDirection == splitHorizontal:
          uiY - float32(editorBounds.origin.y)
        else:
          float32(event.x) - float32(editorBounds.origin.x)
      let constrainedRatio = editorWorkspaceUi.clampedRootSplitRatio(editorBounds,
        position / axisLength)
      editorSession.setSplitRatio(constrainedRatio)
      demoSplitRatio = editorSession.effectiveSplitRatio
      discard editorWorkspaceUi.setRootSplitRatio(demoSplitRatio)
      setupDemoUi()
      splitPointerHandled = true
    elif demoSplitDragging and kind == pointerUp:
      demoSplitDragging = false
      # Persist the settled divider once.  Writing an atomic session for every
      # pointer sample would create avoidable I/O and cache churn while dragging.
      persistSession()
      splitPointerHandled = true
    elif document != nil and kind == pointerDown and demoSplitEnabled:
      let targetPane = editorWorkspaceUi.paneIndexAt(demoTree.node(demoScrollNode).bounds, point)
      if targetPane >= 0 and targetPane != editorSession.splitActivePane:
        # One NSTextInputClient is reused for both views. Do not carry AppKit
        # marked text into a different view state when a click changes focus.
        resetImeState()
      let panes = editorWorkspaceUi.center.paneLayout(demoTree.node(demoScrollNode).bounds).panes
      if targetPane >= 0 and targetPane < panes.len:
        discard editorWorkspaceUi.focusPane(panes[targetPane].id)
      if targetPane >= 0 and targetPane <= 1 and editorSession.activateSplitPane(targetPane):
        # Zed resolves pointer location to a specific pane before turning it
        # into an editor anchor. Preserve that pane through a drag so a
        # selection cannot cross into the other viewport mid-gesture.
        editorPointerPane = targetPane
    elif document != nil and kind == pointerMove and not editorPointerDragging and
        demoSplitEnabled:
      # Hover does not activate a pane, but it must use the pane-local text
      # layout before asking LSP for a UTF-16 position.
      let pane = editorWorkspaceUi.paneIndexAt(demoTree.node(demoScrollNode).bounds, point)
      if pane >= 0 and pane <= 1:
        editorPointerPane = pane
    if kind == pointerDown and workspacePreviewMode == "quickOpen" and
        workspacePreviewEntries.len > 0:
      openWorkspaceEntryAtPoint(event.y)
    elif kind == pointerDown and workspacePreviewMode == "search" and
        workspaceSearchResults.len > 0:
      openWorkspaceSearchResultAtPoint(event.y)
    elif document == nil and kind == pointerDown:
      openWorkspaceEntryAtPoint(event.y)
    if document != nil and not splitPointerHandled and not demoSplitDragging and
        workspacePreviewMode != "quickOpen" and (inEditor or editorPointerDragging) and
        kind in {pointerDown, pointerMove, pointerUp}:
      let offset = editorOffsetAtPoint(document, event.x, event.y, editorPointerPane)
      if kind == pointerDown:
        if lspBridge != nil:
          lspBridge.hideHover()
          editorLspSignatureText = ""
          syncNativeHover()
        let addSelection = optionModifier in macOSModifiers(event.modifiers)
        if editorPointerPane == 1:
          let text = document[].buffer.toString()
          let tab = focusedPaneTabIndex()
          if tab >= 0 and tab < editorSession.tabs.len:
            var view = editorSession.tabs[tab].secondaryView
            if addSelection: discard view.addCaret(offset, text)
            else: view.makeSingleSelection(offset, offset)
            editorSession.tabs[tab].secondaryView = view
            editorSession.secondaryView = view
        else:
          if addSelection:
            discard editorViewState.addCaret(offset, document[].buffer.toString())
          else:
            editorViewState.makeSingleSelection(offset, offset)
        editorPointerDragging = not addSelection
        syncEditorCursor()
        if addSelection:
          editorPointerPane = 0
          return
      elif kind == pointerMove and not editorPointerDragging and lspBridge != nil:
        lspBridge.scheduleHover(offset)
        let bounds = if editorPointerPane == 1: demoSecondaryEditorBounds else: demoEditorBounds
        platformSetEditorHoverPane(uint32(editorPointerPane))
        platformSetEditorHoverPosition(
          float64(float32(event.x) - float32(bounds.origin.x)),
          float64(uiY - float32(bounds.origin.y)))
        syncNativeHover()
      elif kind == pointerMove and editorPointerDragging:
        if editorPointerPane == 1:
          editorSession.secondaryView.moveCursor(offset, selecting = true)
        else:
          editorViewState.moveCursor(offset, selecting = true)
        syncEditorCursor()
      elif kind == pointerUp:
        if editorPointerDragging:
          if editorPointerPane == 1:
            editorSession.secondaryView.moveCursor(offset, selecting = true)
          else:
            editorViewState.moveCursor(offset, selecting = true)
          syncEditorCursor()
        editorPointerDragging = false
        editorPointerPane = 0
  when defined(windows):
    let document = activeDocument()
    let inEditor = demoEditorBounds.contains(point)
    if kind == pointerDown:
      let tabIndex = windowsTabIndexAtPoint(float32(event.x), uiY)
      if tabIndex >= 0:
        if event.button == 0:
          receiveNativeCommand(("selectTab:" & $tabIndex).cstring)
        elif event.button == 2:
          receiveNativeCommand(("selectTab:" & $tabIndex).cstring)
          receiveNativeCommand("closeTabRequest".cstring)
        return
    if kind == pointerDown and workspacePreviewMode == "quickOpen" and
        workspacePreviewEntries.len > 0:
      openWindowsWorkspaceEntryAtPoint(event.y)
      return
    if kind == pointerDown and workspacePreviewMode == "search" and
        workspaceSearchResults.len > 0:
      openWindowsWorkspaceSearchResultAtPoint(event.y)
      return
    if document == nil and kind == pointerDown:
      openWindowsWorkspaceEntryAtPoint(event.y)
      return
    if document != nil and kind == scroll and inEditor:
      let wheelLines = if event.deltaY > 0'f64: -1 else: 1
      let visibleLines = max(1, int(floor(float32(demoEditorBounds.size.height) /
        windowsEditorLineHeight())))
      let maxScroll = max(0, document[].buffer.lineStarts.len - visibleLines)
      editorViewState.scrollLine = max(0, min(maxScroll,
        editorViewState.scrollLine + wheelLines))
      syncEditorCursor()
      refreshEditorSyntax()
      return
    if document != nil and (inEditor or editorPointerDragging) and
        kind in {pointerDown, pointerMove, pointerUp}:
      let offset = editorOffsetAtWindowsPoint(document, float32(event.x), uiY)
      if kind == pointerDown:
        editorPointerDragging = true
        editorViewState.moveCursor(offset)
        syncEditorCursor()
      elif kind == pointerMove and editorPointerDragging:
        editorViewState.moveCursor(offset, selecting = true)
        syncEditorCursor()
      elif kind == pointerUp:
        if editorPointerDragging:
          editorViewState.moveCursor(offset, selecting = true)
          syncEditorCursor()
        editorPointerDragging = false
      return
  if kind in {pointerMove, pointerEnter}:
    for node in demoTree.nodes:
      if node.hoveredState and node.id != hit: demoTree.setHovered(node.id, false)
    if hit != NodeId(0): demoTree.setHovered(hit, true)
  elif kind == pointerExit:
    for node in demoTree.nodes:
      if node.hoveredState: demoTree.setHovered(node.id, false)
    when defined(macosx):
      if lspBridge != nil:
        lspBridge.hideHover()
        editorLspSignatureText = ""
        syncNativeHover()
  elif kind == pointerDown and hit != NodeId(0):
    if demoTree.node(hit).focusable: discard demoTree.focus(hit)
    demoTree.setActive(hit, true)
    activePointerNode = hit
  if kind == pointerUp and activePointerNode != NodeId(0):
    demoTree.setActive(activePointerNode, false)
    activePointerNode = NodeId(0)
  var uiEvent = UiEvent(kind: kind, target: target,
    position: point, keyCode: event.keyCode, button: event.button, modifiers: event.modifiers,
    shortcutModifiers: macOSModifiers(event.modifiers),
    deltaX: float32(event.deltaX), deltaY: float32(event.deltaY))
  discard demoTree.dispatch(uiEvent)

when isMainModule:
  when defined(macosx):
    setupPersistencePaths()
    platformInstallCrashHandler(crashReportPath.cstring)
    setupShortcutRegistry()
    restoreSession()
    syncRecentFiles()
    setupDemoUi()
    let restoredRoot = if editorSession.workspaceRoots.len > 0 and
        dirExists(editorSession.workspaceRoots[0]): editorSession.workspaceRoots[0] else: ""
    let initialRoot = if restoredRoot.len > 0: restoredRoot else: getHomeDir()
    # The workspace preview resolves file icons through SettingsStore. Build
    # the settings layer before opening the workspace so the first refresh is
    # identical to subsequent root changes.
    appSettings = newSettingsStore(settingsFilePath,
      if restoredRoot.len > 0: restoredRoot / ".nimculus" / "settings.json" else: "")
    let extensionRoots = if restoredRoot.len > 0:
      @[getHomeDir() / ".nimculus" / "extensions", restoredRoot / ".nimculus" / "extensions"]
      else: @[getHomeDir() / ".nimculus" / "extensions"]
    editorExtensionRegistry = newExtensionRegistry(extensionRoots)
    discard editorExtensionRegistry.discover()
    if restoredRoot.len > 0:
      openActiveWorkspace(restoredRoot)
    else:
      # LaunchServices starts app bundles with `/` as their current directory.
      # Treating it as a project would enumerate the entire machine. Keep the
      # Files dock instead, with its explicit Open Folder action: this is the
      # useful Zed-like entry point for an empty launch.
      editorWorkspaceUi.leftDock.isOpen = true
      editorWorkspaceUi.leftDock.activePanel = panelFiles
      editorWorkspaceUi.focusedRegion = regionCenter
      editorSidebarMode = sidebarFiles
      setupDemoUi()
    if activeWorkspace != nil and editorSession.workspaceRoots.len > 1:
      for root in editorSession.workspaceRoots[1 .. ^1]:
        if dirExists(root): activeWorkspace.addRoot(root)
      activeWorkspace.startWatching()
      refreshWorkspacePreview()
    applySettingsKeymap()
    applySettingsTheme()
    if activeWorkspace == nil:
      let files = "Files\n────────\nOpen a folder to start a workspace."
      editorWorkspaceUi.replacePanelItems(panelFiles, @[])
      platformSetWorkspaceOpen(false)
      platformSetEditorSidebar(files.cstring, uint32(files.len), 0,
        uint32(sidebarFiles))
      syncNativeSidebarSelection()
    else:
      # openActiveWorkspace has already populated Files. Refresh after the
      # native view is available so restored sessions cannot fall back to an
      # empty Outline presenter.
      refreshWorkspacePreview()
    let lspCommand = getEnv("NIMCULUS_LSP_COMMAND",
      appSettings.stringSetting("lsp.command", ""))
    if lspCommand.len > 0:
      lspBridge = newLspEditorBridge(lspCommand,
        getEnv("NIMCULUS_LSP_ARGS", "").splitWhitespace,
        if dirExists(initialRoot): fileUri(initialRoot) else: "")
    platformSetTextCallback(receiveNativeText)
    platformSetSelectionCallback(receiveNativeSelection)
    platformSetInputCallback(receiveNativeInput)
    platformSetShortcutCallback(dispatchNativeShortcut)
    platformSetFileCallback(receiveNativeFile)
    platformSetCommandCallback(receiveNativeCommand)
    platformSetIdleCallback(receiveNativeIdle)
    # Match Finder/Open With handling for direct terminal launches. This runs
    # only after the native callbacks are installed, so Japanese paths and
    # workspace directories follow the same open boundary as Apple Events.
    let startupArguments = commandLineParams()
    for startupPath in startupOpenPaths(startupArguments):
      receiveNativeFile(startupPath.cstring, false)
    if activeDocument() != nil:
      syncEditorCursor()
      refreshEditorSyntax()
    else:
      platformSetWelcomeVisible(activeDocument() == nil)
      persistSession()
    for argument in startupArguments:
      if argument == "--nimculus-gui-workflow":
        macosGuiWorkflowEnabled = true
        macosGuiWorkflowStep = 0
        macosGuiWorkflowStartedAt = epochTime()
      elif argument.startsWith("--nimculus-gui-workflow-result="):
        macosGuiWorkflowResultPath = argument["--nimculus-gui-workflow-result=".len .. ^1]
  elif defined(windows):
    setupPersistencePaths()
    restoreSession()
    setupShortcutRegistry()
    platformSetShortcutCallback(dispatchNativeShortcut)
    let initialRoot = if editorSession.workspaceRoots.len > 0:
      editorSession.workspaceRoots[0] else: getCurrentDir()
    let workspaceRoot = if dirExists(initialRoot): initialRoot else: getCurrentDir()
    appSettings = newSettingsStore(settingsFilePath,
      workspaceRoot / ".nimculus" / "settings.json")
    applySettingsTheme()
    registerWindowsDemoImage()
    setupDemoUi()
    openActiveWorkspace(workspaceRoot)
    platformSetTextCallback(receiveNativeText)
    platformSetInputCallback(receiveNativeInput)
    platformSetFileCallback(receiveNativeFile)
    platformSetCommandCallback(receiveNativeCommand)
    platformSetIdleCallback(receiveNativeIdle)
    if activeDocument() != nil:
      syncEditorCursor()
      refreshEditorSyntax()
    else:
      persistSession()
    startWindowsTerminal()
  discard platformRun()
