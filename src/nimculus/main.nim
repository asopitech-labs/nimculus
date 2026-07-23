import std/algorithm
import std/json
import std/math
import std/os
import std/strutils
import std/tables
import std/times
import std/unicode except splitWhitespace
import nimnui/nimnui
import nimnui/render
import nimculus/editor_app
import nimculus/editor_buffer
import nimculus/editor_view
import nimculus/editor_syntax
import nimculus/tree_sitter
import nimculus/workspace
import nimculus/session
import nimculus/lsp_editor_bridge
import nimculus/lsp
import nimculus/editor_diagnostics
import nimculus/git_service
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
      echo "soak_sample\t", formatFloat(now - soakBenchmarkStartedAt, ffDecimal, 3),
        "\tseconds\tresident=", platformResidentMemoryBytes(),
        "\tlive_blocks=", platformLiveAllocationCount(),
        "\tframes=", metrics.frameCount,
        "\tinput=", platformInputCount()
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

proc syncEditorCursor()
proc persistSession()

var demoTree = newUiTree()
var shortcutRegistry: CommandRegistry
var demoButton = NodeId(0)
var demoSplitNode = NodeId(0)
var demoScrollNode = NodeId(0)
var demoSplitRatio = 0.5'f32
var demoSplitDragging = false
var activePointerNode = NodeId(0)
var demoEditorBounds = Rect(size: Size(width: px(0), height: px(0)))
when defined(macosx) or defined(windows):
  var appSettings: SettingsStore
  var editorLspSemanticTokens: seq[LspSemanticToken]
  var editorLspSemanticTokenPath = ""
  var editorLspSemanticTokenSource = ""
  var editorLspSignatureText = ""
  var editorLspInlayHints: seq[LspInlayHint]
  var editorLspInlayHintPath = ""
  var editorLspInlayHintSource = ""
  var pendingLspRename: seq[LspWorkspaceEdit]
  var pendingLspCodeActions: seq[LspCodeAction]
  var pendingLspSymbols: seq[LspSymbol]

proc resetPointerInteractions()
when defined(macosx):
  proc syncNativeHover()
  proc syncNativeInlayHints(document: ptr FileDocument)
  proc syncNativeSymbolTree()
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

proc setupDemoUi() =
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
  let margin = 24'f32
  let panel = Rect(origin: Point(x: px(margin), y: px(margin)),
    size: Size(width: px(max(0'f32, viewportWidth - margin * 2)),
               height: px(max(0'f32, viewportHeight - margin * 2))))
  let toolbar = Rect(origin: Point(x: px(margin * 2), y: px(margin * 2)),
    size: Size(width: px(max(0'f32, viewportWidth - margin * 4)), height: px(56)))
  let outlineWidth = 220'f32
  let editorWidth = max(0'f32, viewportWidth - margin * 4 - outlineWidth - 84'f32)
  let editorHeight = max(0'f32, viewportHeight - 208'f32)
  let editor = Rect(origin: Point(x: px(margin * 2 + outlineWidth), y: px(128)),
    size: Size(width: px(editorWidth), height: px(editorHeight)))
  demoEditorBounds = editor
  let splitBar = Rect(origin: Point(x: px(margin * 2 + outlineWidth + editorWidth * demoSplitRatio),
      y: px(128)),
    size: Size(width: px(2), height: px(editorHeight)))
  let scrollbar = Rect(origin: Point(x: px(margin * 2 + outlineWidth + editorWidth + 24), y: px(144)),
    size: Size(width: px(8), height: px(max(0'f32, editorHeight - 32'f32))))
  demoTree.node(button.node).bounds = toolbar
  demoTree.node(split.node).bounds = splitBar
  demoTree.node(scroll.node).bounds = editor
  var paint: PaintList
  paint.invalidate(viewport)
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
  else:
    paint.drawBorder(editor)
  paint.drawScrollbar(scrollbar)
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
  platformSetEditorRect(float64(float32(editor.origin.x)), float64(float32(editor.origin.y)),
                        float64(float32(editor.size.width)), float64(float32(editor.size.height)))

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
  # Keep all commands addressable from settings keymaps. They have no default
  # shortcut here when AppKit owns the standard menu equivalent; custom
  # bindings are installed below and are resolved before interpretKeyEvents.
  for name in [
      # Application and menu commands.
    "save", "newDocument", "closeTabRequest", "openSettings", "undo", "redo",
      "cut", "copy", "paste", "selectAll", "previousTab", "nextTab",
      # AppKit NSText movement/editing selectors. Keeping these names at the
        # application boundary lets settings override Command/Option behavior
        # without leaking Cocoa types into the editor core.
      "moveLeft", "moveRight", "moveUp", "moveDown",
      "selectLeft", "selectRight", "selectUp", "selectDown",
      "moveToBeginningOfLine", "moveToEndOfLine",
      "selectToBeginningOfLine", "selectToEndOfLine",
      "moveToBeginningOfDocument", "moveToEndOfDocument",
      "insertNewline", "insertTab", "moveWordLeft", "moveWordRight",
      "selectWordLeft", "selectWordRight", "deleteBackward", "deleteForward",
      "deleteWordBackward", "cancel", "toggleSoftWrap"]:
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

proc applySettingsTheme() =
  when defined(macosx) or defined(windows):
    if appSettings == nil: return
    when defined(windows):
      platformSetEditorFontSize(cdouble(appSettings.intSetting("editor.fontSize", 14)))
      platformSetEditorFontName(appSettings.stringSetting("editor.fontFamily", "Consolas").cstring)
      platformSetTerminalFontSize(cdouble(appSettings.intSetting("terminal.fontSize", 12)))
      platformSetTerminalFontName(appSettings.stringSetting("terminal.fontFamily", "Consolas").cstring)
    elif defined(macosx):
      var colors = appSettings.theme()
      let themeName = appSettings.stringSetting("theme", "dark").toLowerAscii
      let customBackground = appSettings.stringSetting("themeColors.background", "")
      platformSetEditorFontSize(cdouble(appSettings.intSetting("editor.fontSize", 14)))
      platformSetEditorFontName(appSettings.stringSetting("editor.fontFamily", "Menlo").cstring)
      platformSetTerminalFontSize(cdouble(appSettings.intSetting("terminal.fontSize", 12)))
      platformSetTerminalFontName(appSettings.stringSetting("terminal.fontFamily", "Menlo").cstring)
      if customBackground.len == 0 and themeName in ["light", "dark", "system"]:
        let dark = if themeName == "system": platformIsDarkAppearance() else: themeName == "dark"
        if dark:
          colors.background = "#1f2329"
          colors.foreground = "#d7dae0"
          colors.accent = "#4daafc"
        else:
          colors.background = "#ffffff"
          colors.foreground = "#1f2329"
          colors.accent = "#007aff"
      platformSetThemeColors(colors.background.cstring, colors.foreground.cstring,
        colors.accent.cstring, colors.selection.cstring, colors.border.cstring)

var imeState = newImeState()
var editorSession: EditorSession
var editorViewState = newEditorView()
var syntaxState: EditorSyntaxState
var activeWorkspace: Workspace
var workspaceSearchJob: SearchJob
var workspaceQuickOpenJob: FuzzySearchJob
var workspaceSearchQuery = ""
var workspaceSearchResults: seq[SearchResult]
var workspaceSearchCancelled = false
var workspaceQuickOpenQuery = ""
var workspacePreviewEntries: seq[WorkspaceEntry]
var workspacePreviewMode = ""
var externalAlertShown = false
var editorPointerDragging = false
var editorScrollRemainder = 0'f32
var sessionFilePath = ""
var recoveryFilePath = ""
var crashReportPath = ""
var settingsFilePath = ""
var persistenceTick = 0
var suppressRecoveryWrite = false
var discardDirtyOnExit = false
when defined(macosx):
  var lspBridge: LspEditorBridge
  var editorGitDiffJob: GitJob
  var editorGitStatusJob: GitJob
  var editorGitStatusRepository: GitRepository
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
  var editorTaskJob: TaskJob
  var editorTaskCommand = ""
  var editorTaskOutput = ""
  var editorTaskOutputVisible = false
  var editorTaskProblems: seq[TaskProblem]
  var editorTerminal: TerminalPty
  var editorTerminals: seq[TerminalPty]
  var editorTerminalIndex = -1
  var editorTerminalVisible = false
  var editorTerminalSelection = TerminalSelection()
  var editorTerminalSelecting = false
  var editorUpdateJob: UpdateDownloadJob
  var editorUpdatePath = ""

proc resetEditorViewState() =
  editorViewState = newEditorView()
  editorScrollRemainder = 0'f32
  when defined(macosx):
    pendingLspSymbols.setLen(0)
    syncNativeSymbolTree()

proc resetPointerInteractions() =
  demoSplitDragging = false
  editorPointerDragging = false
  if activePointerNode != NodeId(0):
    demoTree.setActive(activePointerNode, false)
    activePointerNode = NodeId(0)
  for node in demoTree.nodes:
    if node.hoveredState: demoTree.setHovered(node.id, false)

proc resetImeState() =
  imeState = newImeState()
  when defined(macosx):
    platformClearEditorComposition()

proc activeDocument(): ptr FileDocument
proc refreshWorkspacePreview()
proc refreshEditorSyntax()

when defined(macosx):
  proc gitRepositoryForDocument(document: ptr FileDocument): GitRepository =
    if document == nil or document[].path.len == 0: return nil
    if activeWorkspace != nil:
      try:
        let location = activeWorkspace.splitWorkspacePath(document[].path)
        return newGitRepository(location.root)
      except CatchableError:
        return nil
    newGitRepository(splitFile(absolutePath(document[].path)).dir)

  proc gitRelativePathForDocument(document: ptr FileDocument,
                                  repository: GitRepository): string =
    if document == nil or repository == nil or document[].path.len == 0: return ""
    if activeWorkspace != nil:
      try:
        let location = activeWorkspace.splitWorkspacePath(document[].path)
        return location.relative
      except CatchableError:
        return ""
    let absoluteDocumentPath = absolutePath(document[].path)
    let prefix = repository.root & DirSep
    if absoluteDocumentPath.startsWith(prefix):
      result = absoluteDocumentPath[prefix.len .. ^1]

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
    if job.result.exitCode != 0:
      editorViewState.statusMessage = "Git " & action & " failed: " & output
    elif action == "status":
      let entries = parseStatus(job.result.output)
      var conflicts = 0
      for entry in entries:
        if entry.conflict: inc conflicts
      editorViewState.statusMessage = "Git: " & $entries.len &
        " changed file(s), " & $conflicts & " conflict(s)"
    elif action == "log":
      let commits = parseLog(job.result.output, 5)
      editorViewState.statusMessage = if commits.len == 0:
        "Git log: no commits" else: "Git log: " & commits[0].subject
    elif action == "blame":
      let blameLines = parseBlame(job.result.output)
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

  proc handleGitGutterClick(document: ptr FileDocument, uiY: float32,
                            modifiers: uint32): bool =
    if document == nil or document[].path.len == 0: return false
    let repository = gitRepositoryForDocument(document)
    let relative = gitRelativePathForDocument(document, repository)
    if repository == nil or relative.len == 0: return false
    let line = max(0, int(floor((uiY - float32(demoEditorBounds.origin.y) - 4'f32) /
      18'f32)) + editorViewState.scrollLine)
    # Option-click follows the standard staged-diff convention and reverses
    # the operation against the index; a normal click stages the worktree hunk.
    let unstage = (modifiers and (1'u32 shl 19)) != 0'u32
    startNativeGitHunkAction(repository, relative,
      if unstage: "unstage hunk" else: "stage hunk", line)
    true

  proc clearNativeGitHunks() =
    platformSetEditorGitHunks(nil, 0)

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
    editorTaskOutputVisible = false
    platformSetTaskOutputVisible(false)
    editorTaskJob = startTask(TaskSpec(command: "/bin/zsh",
      args: @["-lc", command], workingDirectory: taskWorkingDirectory(activeDocument())))
    editorViewState.statusMessage = "Task: running " & command

  proc cancelNativeTask() =
    if editorTaskJob == nil or editorTaskJob.done:
      editorViewState.statusMessage = "Task: no running task"
      return
    editorTaskJob.cancel()
    editorViewState.statusMessage = "Task: cancelled"

  proc pollNativeTask() =
    if editorTaskJob == nil: return
    let completed = editorTaskJob.poll()
    let taskResult = editorTaskJob.result
    if taskResult.output != editorTaskOutput:
      editorTaskOutput = taskResult.output
      editorTaskProblems = taskResult.problems
      platformSetTaskOutputText(editorTaskOutput.cstring, uint32(editorTaskOutput.len))
    if not completed: return
    editorTaskProblems = taskResult.problems
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
      platformSetTerminalVisible(false)
    editorTaskOutputVisible = true
    platformSetTaskOutputVisible(true)
    platformSetTaskOutputText(editorTaskOutput.cstring, uint32(editorTaskOutput.len))

  proc showNativeLspPanel(title: string, lines: seq[string]) =
    if lines.len == 0:
      editorViewState.statusMessage = title & ": none"
      return
    editorTaskOutput = title & "\n" & lines.join("\n")
    platformSetTaskOutputText(editorTaskOutput.cstring, uint32(editorTaskOutput.len))
    if editorTerminalVisible:
      editorTerminalVisible = false
      platformSetTerminalVisible(false)
    editorTaskOutputVisible = true
    platformSetTaskOutputVisible(true)

  proc syncNativeSymbolTree() =
    var lines = @[
      "Outline",
      "────────"
    ]
    if pendingLspSymbols.len == 0:
      lines.add("No symbols")
    else:
      proc appendSymbol(symbol: LspSymbol, depth: int) =
        lines.add("  ".repeat(depth) & symbol.name & "  " &
          $(symbol.range.start.line + 1))
        for child in symbol.children:
          appendSymbol(child, depth + 1)
      for symbol in pendingLspSymbols: appendSymbol(symbol, 0)
    let text = lines.join("\n")
    platformSetEditorOutline(text.cstring, uint32(text.len), uint32(pendingLspSymbols.len))

  proc lspSelectionRange(document: ptr FileDocument): LspRange =
    if document == nil: return
    let selection = editorViewState.selectedRange()
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
      var tabIndex = -1
      for index, tab in editorSession.tabs:
        if tab.document.path.len > 0 and absolutePath(tab.document.path) == absolutePath(path):
          tabIndex = index
          break
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
      var lines: seq[string]
      proc appendSymbol(symbol: LspSymbol, depth: int) =
        pendingLspSymbols.add(symbol)
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
        let location = document[].buffer.lineColumn(editorViewState.cursor)
        platformSetEditorHoverPosition(float64(float32(location.column) * 7.2'f32),
          float64(float32(location.line - editorViewState.scrollLine) * 18'f32))
      syncNativeHover()
      var lines: seq[string]
      for item in signature.signatures:
        lines.add(item.label & (if item.documentation.len > 0: " — " &
            item.documentation else: ""))
      showNativeLspPanel("LSP Signature Help", lines)
    let hints = lspBridge.takeInlayHints()
    if hints.len > 0:
      editorLspInlayHints = hints
      if document != nil:
        editorLspInlayHintPath = document[].path
        editorLspInlayHintSource = document[].buffer.toString()
      syncNativeInlayHints(document)
      var lines: seq[string]
      for hint in hints:
        lines.add($(hint.position.line + 1) & ":" & $(hint.position.character + 1) & " " & hint.label)
      showNativeLspPanel("LSP Inlay Hints", lines)
    let commandEdits = lspBridge.takeCommandEdits()
    if commandEdits.len > 0:
      discard applyLspWorkspaceEdits(commandEdits, "code action command")

  proc syncNativeTerminal() =
    if editorTerminal == nil: return
    let screen = editorTerminal.screen
    let text = screen.gridText()
    var runs: seq[NativeTerminalRun]
    var byteOffset = 0
    for rowIndex, row in screen.lines:
      for columnIndex, cell in row:
        if cell.width == 0: continue
        let cellText = if cell.text.len == 0: " " else: cell.text
        let endByte = byteOffset + cellText.len
        let flags = (if cell.bold: 1'u32 else: 0'u32) or
          (if cell.dim: 2'u32 else: 0'u32) or
          (if cell.italic: 4'u32 else: 0'u32) or
          (if cell.underline: 8'u32 else: 0'u32) or
          (if cell.inverse: 16'u32 else: 0'u32) or
          (if cell.strikethrough: 32'u32 else: 0'u32)
        runs.add(NativeTerminalRun(startByte: uint32(byteOffset), endByte: uint32(endByte),
          flags: flags,
          row: uint32(rowIndex), column: uint32(columnIndex),
          cellWidth: uint32(max(1, cell.width)),
          foregroundKind: uint32(ord(cell.foreground.kind)), foregroundIndex: uint32(max(0,
              cell.foreground.index)),
          foregroundRed: uint32(cell.foreground.red), foregroundGreen: uint32(
              cell.foreground.green),
          foregroundBlue: uint32(cell.foreground.blue),
          backgroundKind: uint32(ord(cell.background.kind)), backgroundIndex: uint32(max(0,
              cell.background.index)),
          backgroundRed: uint32(cell.background.red), backgroundGreen: uint32(
              cell.background.green),
          backgroundBlue: uint32(cell.background.blue),
          hyperlinkUri: if cell.hyperlinkUri.len > 0: cell.hyperlinkUri.cstring else: nil))
        byteOffset = endByte
      byteOffset += 1
    if runs.len > 0:
      platformSetTerminalRuns(text.cstring, uint32(text.len), addr runs[0], uint32(runs.len))
    else:
      platformSetTerminalRuns(text.cstring, uint32(text.len), nil, 0)

  proc activateNativeTerminal(index: int) =
    if index < 0 or index >= editorTerminals.len: return
    editorTerminalIndex = index
    editorTerminal = editorTerminals[index]
    editorTerminalSelection = TerminalSelection()
    if editorTerminalVisible:
      platformSetTerminalSelection(0, 0, 0, 0)
      syncNativeTerminal()
    editorViewState.statusMessage = "Terminal " & $(index + 1) & "/" &
      $editorTerminals.len

  proc newNativeTerminal() =
    let cwd = if activeWorkspace != nil and activeWorkspace.rootPaths.len > 0:
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
      platformSetTerminalVisible(true)
      syncNativeTerminal()
      editorViewState.statusMessage = "Terminal " &
        $(editorTerminalIndex + 1) & "/" & $editorTerminals.len & " opened"
    except CatchableError as error:
      editorViewState.statusMessage = "Terminal failed: " & error.msg

  proc terminalOverlayBounds(): tuple[x, y, width, height: float32] =
    let height = min(180'f32, max(72'f32, float32(demoEditorBounds.size.height) * 0.42'f32))
    (x: float32(demoEditorBounds.origin.x),
     y: float32(demoEditorBounds.origin.y) + float32(demoEditorBounds.size.height) - height,
     width: float32(demoEditorBounds.size.width), height: height)

  proc terminalPointAt(x, y: float32): TerminalPoint =
    let bounds = terminalOverlayBounds()
    TerminalPoint(
      row: max(0, min(editorTerminal.screen.rows - 1,
        int(floor((y - bounds.y) / 18'f32)))),
      column: max(0, min(editorTerminal.screen.columns,
        int(floor((x - bounds.x) / 7.2'f32)))))

  proc terminalContains(x, y: float32): bool =
    let bounds = terminalOverlayBounds()
    x >= bounds.x and x < bounds.x + bounds.width and
      y >= bounds.y and y < bounds.y + bounds.height

  proc syncNativeTerminalSelection() =
    if editorTerminal == nil: return
    let selection = editorTerminal.screen.normalizedSelection(editorTerminalSelection)
    platformSetTerminalSelection(uint32(selection.anchor.row),
      uint32(selection.anchor.column), uint32(selection.active.row),
      uint32(selection.active.column))

  proc writeNativeTerminalInput(input: string, paste = false) =
    if editorTerminal == nil or editorTerminal.closed: return
    let payload = if paste and editorTerminal.screen.bracketedPaste:
      "\x1b[200~" & input & "\x1b[201~"
    else: input
    discard editorTerminal.writeInput(payload)

  proc handleTerminalPointer(kind: UiEventKind, x, y: float32,
                             button: uint32, modifiers: uint32,
                             deltaY: float32): bool =
    if not editorTerminalVisible or editorTerminal == nil or
        not terminalContains(x, y): return false
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
      editorTerminalVisible = false
      platformSetTerminalVisible(false)
      return
    if editorTerminal == nil or editorTerminal.closed:
      newNativeTerminal()
    else:
      editorTaskOutputVisible = false
      platformSetTaskOutputVisible(false)
      editorTerminalVisible = true
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
    platformSetTerminalVisible(true)

  proc closeNativeTerminals() =
    for session in editorTerminals:
      if session != nil: session.close()
    editorTerminals.setLen(0)
    editorTerminal = nil
    editorTerminalIndex = -1

  proc resizeNativeTerminals() =
    if editorTerminals.len == 0: return
    let bounds = terminalOverlayBounds()
    let columns = max(1, int(floor(bounds.width / 7.2'f32)) - 2)
    let rows = max(1, int(floor(bounds.height / 18'f32)) - 1)
    for session in editorTerminals:
      if session != nil and not session.closed: session.resize(columns, rows)
    if editorTerminalVisible:
      syncNativeTerminal()

  proc pollNativeTerminal() =
    for index, session in editorTerminals:
      if session == nil or session.closed: continue
      let output = session.pollOutput()
      if index == editorTerminalIndex and output.len > 0 and editorTerminalVisible:
        syncNativeTerminal()

  proc scheduleNativeGitHunks(document: ptr FileDocument) =
    if editorGitDiffJob != nil:
      editorGitDiffJob.cancel()
      editorGitDiffJob = nil
    if editorGitStatusJob != nil:
      editorGitStatusJob.cancel()
      editorGitStatusJob = nil
    editorGitStatusRepository = nil
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
    let branch = editorGitStatusRepository.currentBranch()
    let branchLabel = if branch.len > 0: branch else: "detached"
    editorViewState.statusMessage = "Git " & branchLabel & ": " & $entries.len &
      " changed, " & $conflicts & " conflict(s)"

  proc editorVisibleLineCount(): int =
    ## Keep cursor reveal, syntax requests, and native text rendering on the
    ## same viewport contract. The old fixed 12-line value left taller windows
    ## only half painted.
    max(1, int(ceil(float32(demoEditorBounds.size.height) / 18'f32)))

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
    if activeWorkspace != nil: editorSession.workspaceRoots = activeWorkspace.rootPaths
    saveSession(editorSession, sessionFilePath, preserveDirty = not discardDirtyOnExit)
    let document = activeDocument()
    if not suppressRecoveryWrite and document != nil and document[].buffer.isDirty:
      writeRecovery(document[], recoveryFilePath)
    elif fileExists(recoveryFilePath):
      removeFile(recoveryFilePath)
    suppressRecoveryWrite = false
    discardDirtyOnExit = false
  except CatchableError:
    discard

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
    reloadWorkspaceSettings(activeWorkspace.root)
    activeWorkspace.startWatching()
    workspaceSearchQuery = ""
    workspaceQuickOpenQuery = ""
    workspaceSearchResults.setLen(0)
    workspaceSearchCancelled = false
    refreshWorkspacePreview()

proc refreshWorkspacePreview() =
  when defined(macosx) or defined(windows):
    # Workspace opening can refresh the preview while the platform-specific
    # settings store is still being constructed. Keep that boundary safe, but
    # initialize settings before the first normal workspace refresh below.
    if activeWorkspace == nil or appSettings == nil: return
    workspacePreviewMode = "tree"
    workspacePreviewEntries.setLen(0)
    var lines = @["Workspace: " & activeWorkspace.root]
    # Keep the preview bounded, but walk beyond the root directory so the
    # workspace surface is a real lazy tree rather than a flat root listing.
    # The filesystem is still enumerated incrementally by the workspace API;
    # this view only asks for enough entries to fill its visible preview.
    var pending: seq[tuple[root, relative: string, depth: int]]
    for rootIndex in countdown(activeWorkspace.rootPaths.high, 0):
      let root = activeWorkspace.rootPaths[rootIndex]
      pending.add((root: root, relative: "", depth: 0))
    while pending.len > 0 and lines.len < 12:
      let directory = pending.pop()
      var children = activeWorkspace.listChildrenAt(directory.root, directory.relative)
      children.sort(proc(a, b: WorkspaceEntry): int = cmp(a.relativePath, b.relativePath))
      for childIndex in countdown(children.high, 0):
        let entry = children[childIndex]
        if lines.len >= 12: break
        workspacePreviewEntries.add(entry)
        let icon = appSettings.iconForPath(entry.path,
          entry.kind == WorkspaceFileKind.directory)
        let relativeName = entry.path.extractFilename
        lines.add(repeat("  ", directory.depth) & icon & " " & relativeName)
        if entry.kind == WorkspaceFileKind.directory:
          pending.add((root: directory.root, relative: entry.relativePath,
            depth: directory.depth + 1))
    let states = activeWorkspace.gitWorktreeStates()
    for root, state in states:
      if lines.len >= 12: break
      let shortHead = if state.head.len > 8: state.head[0 .. 7] else: state.head
      lines.add("[G] " & state.branch & " " & shortHead)
    platformSetEditorHighlights(nil, 0)
    platformSetEditorComposition("".cstring)
    platformSetEditorScrollLine(0)
    platformSetEditorCursorByte(0, 0)
    platformSetEditorSelection(0, 0)
    let text = lines.join("\n")
    platformSetEditorText(text.cstring, uint32(text.len))

proc refreshWorkspaceAfterMutation(message: string) =
  when defined(macosx) or defined(windows):
    if activeWorkspace != nil:
      activeWorkspace.startWatching()
      editorViewState.statusMessage = message
      refreshWorkspacePreview()

proc workspaceRelativePayload(name, prefix: string): string =
  if not name.startsWith(prefix) or name.len <= prefix.len: return ""
  name[prefix.len .. ^1].strip

proc renderWorkspaceSearch() =
  when defined(macosx) or defined(windows):
    if activeWorkspace == nil or workspaceSearchQuery.len == 0: return
    workspacePreviewMode = "search"
    workspacePreviewEntries.setLen(0)
    var lines = @["Search: " & workspaceSearchQuery]
    for result in workspaceSearchResults:
      if lines.len >= 12: break
      lines.add(result.path & ":" & $result.line & ":" & $result.column & " " & result.text)
    if workspaceSearchJob != nil and not workspaceSearchJob.isComplete:
      lines.add("… search continues")
    elif workspaceSearchCancelled:
      lines.add("Search cancelled")
    if workspaceSearchResults.len == 0 and workspaceSearchJob != nil and
        workspaceSearchJob.isComplete:
      lines.add("No matches")
    platformSetEditorHighlights(nil, 0)
    platformSetEditorComposition("".cstring)
    platformSetEditorScrollLine(0)
    platformSetEditorCursorByte(0, 0)
    platformSetEditorSelection(0, 0)
    let text = lines.join("\n")
    platformSetEditorText(text.cstring, uint32(text.len))

proc renderQuickOpen() =
  when defined(macosx) or defined(windows):
    if activeWorkspace == nil or workspaceQuickOpenQuery.len == 0: return
    workspacePreviewMode = "quickOpen"
    workspaceSearchQuery = ""
    var lines = @["Quick Open: " & workspaceQuickOpenQuery]
    for entry in workspacePreviewEntries:
      if lines.len >= 12: break
      lines.add(entry.relativePath)
    if workspaceQuickOpenJob != nil and not workspaceQuickOpenJob.isComplete:
      lines.add("… searching workspace")
    platformSetEditorHighlights(nil, 0)
    platformSetEditorComposition("".cstring)
    platformSetEditorScrollLine(0)
    platformSetEditorCursorByte(0, 0)
    platformSetEditorSelection(0, 0)
    let text = lines.join("\n")
    platformSetEditorText(text.cstring, uint32(text.len))

proc showWorkspaceSearch(query: string) =
  when defined(macosx) or defined(windows):
    if workspaceSearchJob != nil: workspaceSearchJob.cancelSearch()
    workspaceSearchJob = nil
    if workspaceQuickOpenJob != nil: workspaceQuickOpenJob.cancelFuzzySearch()
    workspaceQuickOpenJob = nil
    workspaceQuickOpenQuery = ""
    workspaceSearchQuery = query
    workspaceSearchResults.setLen(0)
    workspaceSearchCancelled = false
    if activeWorkspace == nil or query.len == 0:
      if activeWorkspace != nil: refreshWorkspacePreview()
      return
    workspaceSearchJob = activeWorkspace.startSearch(query)
    renderWorkspaceSearch()

proc showQuickOpen(query: string) =
  when defined(macosx) or defined(windows):
    if workspaceSearchJob != nil: workspaceSearchJob.cancelSearch()
    workspaceSearchJob = nil
    if workspaceQuickOpenJob != nil: workspaceQuickOpenJob.cancelFuzzySearch()
    workspaceQuickOpenJob = nil
    workspacePreviewMode = "quickOpen"
    workspaceSearchQuery = ""
    workspaceSearchResults.setLen(0)
    workspaceSearchCancelled = false
    workspaceQuickOpenQuery = query
    workspacePreviewEntries.setLen(0)
    if activeWorkspace == nil or query.len == 0:
      if activeWorkspace != nil: refreshWorkspacePreview()
      return
    workspaceQuickOpenJob = activeWorkspace.startFuzzySearch(query)
    renderQuickOpen()

proc cancelWorkspaceSearch() =
  when defined(macosx) or defined(windows):
    if workspaceSearchJob == nil: return
    workspaceSearchJob.cancelSearch()
    workspaceSearchJob = nil
    workspaceSearchCancelled = true
    renderWorkspaceSearch()

proc pollWorkspaceSearch() =
  when defined(macosx):
    inc persistenceTick
    if persistenceTick mod 20 == 0: persistSession()
    let changed = if activeWorkspace == nil: @[] else: activeWorkspace.changedPaths()
    let document = activeDocument()
    if document != nil and document[].path.len > 0 and document[].externallyChanged() and
        not externalAlertShown:
      externalAlertShown = true
      platformShowExternalChange(document[].path.cstring)
    if changed.len > 0:
      if workspaceSearchJob != nil:
        # Invalidate results produced against the pre-change filesystem view.
        workspaceSearchJob.cancelSearch()
        workspaceSearchResults.setLen(0)
        workspaceSearchCancelled = false
        workspaceSearchJob = activeWorkspace.startSearch(workspaceSearchQuery)
      elif workspaceQuickOpenJob != nil:
        workspaceQuickOpenJob.cancelFuzzySearch()
        workspacePreviewEntries.setLen(0)
        workspaceQuickOpenJob = activeWorkspace.startFuzzySearch(workspaceQuickOpenQuery)
      elif workspacePreviewMode == "search" and workspaceSearchQuery.len > 0:
        workspaceSearchResults.setLen(0)
        workspaceSearchCancelled = false
        workspaceSearchJob = activeWorkspace.startSearch(workspaceSearchQuery)
      elif workspacePreviewMode == "tree":
        refreshWorkspacePreview()
      elif workspacePreviewMode == "quickOpen":
        showQuickOpen(workspaceQuickOpenQuery)
    if workspaceQuickOpenJob != nil:
      for entry in workspaceQuickOpenJob.pollFuzzySearch(maxEntries = 256, maxResults = 100):
        if workspacePreviewEntries.len < 100: workspacePreviewEntries.add(entry)
      workspacePreviewEntries.sort(proc(a, b: WorkspaceEntry): int =
        let lengthOrder = cmp(a.relativePath.len, b.relativePath.len)
        if lengthOrder != 0: lengthOrder else: cmp(a.relativePath, b.relativePath))
      renderQuickOpen()
      if workspaceQuickOpenJob.isComplete: workspaceQuickOpenJob = nil
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

proc syncEditorCursor() =
  when defined(macosx):
    let document = activeDocument()
    if document != nil:
      # Undo/redo and external reload can shorten or reshape the buffer
      # without passing through the normal movement commands. Normalize both
      # endpoints before deriving line/UTF-16 positions or sending them to
      # NSTextInputClient, so a selection never lands inside a grapheme.
      editorViewState.clampSelectionToText(document[].buffer.toString())
    let visibleLines = editorVisibleLineCount()
    let location = if document == nil: (line: 0, column: 0) else:
      document[].buffer.lineColumn(editorViewState.cursor)
    if document != nil:
      let lastVisibleLine = max(0, document[].buffer.lineStarts.len - visibleLines)
      if location.line < editorViewState.scrollLine:
        editorViewState.scrollLine = location.line
      elif location.line >= editorViewState.scrollLine + visibleLines:
        editorViewState.scrollLine = min(lastVisibleLine, location.line - visibleLines + 1)
    platformSetEditorScrollLine(uint32(max(0, editorViewState.scrollLine)))
    platformSetEditorCursorByte(uint32(editorViewState.cursor), uint32(max(0, location.line)))
    let selection = if document == nil: (startByte: 0, endByte: 0) else:
      editorViewState.selectedRange()
    platformSetEditorSelection(uint32(selection.startByte), uint32(selection.endByte))
    platformInvalidateImeCoordinates()
    platformSetEditorDirty(document != nil and document[].buffer.isDirty)
    platformSetEditorLineNumbers(editorViewState.showLineNumbers)
    platformSetEditorSoftWrap(editorViewState.softWrap)
    platformSetEditorIndentGuides(editorViewState.showIndentGuides,
      uint32(max(1, editorViewState.indentWidth)))
    let status = if document != nil: editorViewState.statusBarText(document[].buffer)
      else: editorViewState.statusMessage
    platformSetEditorStatus(status.cstring)
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
    for tab in editorSession.tabs:
      tabTitles.add(tab.title & (if tab.document.buffer.isDirty: " •" else: ""))
    let tabsText = tabTitles.join("\n")
    platformSetEditorTabs(tabsText.cstring, uint32(tabsText.len),
      uint32(max(0, editorSession.activeTab)))

when defined(macosx):
  proc editorOffsetAtPoint(document: ptr FileDocument, x, y: cdouble): int =
    if document == nil: return 0
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
    if document == nil or editorLspInlayHints.len == 0:
      platformSetEditorAnnotations(nil, 0)
      return
    var annotations = newSeq[NativeEditorAnnotation](editorLspInlayHints.len)
    for index, hint in editorLspInlayHints:
      annotations[index] = NativeEditorAnnotation(
        line: uint32(max(0, hint.position.line)),
        character: uint32(max(0, hint.position.character)),
        kind: uint32(max(0, hint.kind)), text: hint.label.cstring)
    platformSetEditorAnnotations(addr annotations[0], uint32(annotations.len))

  proc requestEditorCompletion() =
    let document = activeDocument()
    if document == nil or lspBridge == nil:
      platformSetEditorCompletions("".cstring, 0)
      return
    if lspBridge.requestCompletion(document[].buffer, editorViewState.cursor):
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
    receiveNativeFile(match.path.cstring, false)
    let document = activeDocument()
    if document != nil:
      let lineIndex = max(0, match.line - 1)
      let lineStart = document[].buffer.byteOffsetAtLineColumn(lineIndex, 0)
      editorViewState.moveCursor(min(document[].buffer.toString().len,
        lineStart + max(0, match.column - 1)))
      syncEditorCursor()
      refreshEditorSyntax()

proc refreshEditorSyntax() =
  let document = activeDocument()
  if document == nil:
    when defined(macosx):
      platformSetEditorDiagnostics(nil, 0)
      editorLspInlayHints.setLen(0)
      platformSetEditorAnnotations(nil, 0)
      clearNativeGitHunks()
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
      let text = document[].buffer.toString()
      platformSetEditorText(text.cstring, uint32(text.len))
      syncNativeInlayHints(document)
      syncNativeDiagnostics(document)
      scheduleNativeGitHunks(document)
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
    let highlights = if syntaxState == nil: @[] else:
      let visibleLines = editorVisibleLineCount()
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
    pollNativeGitStatus()
    pollNativeGitAction()
    pollNativeTask()
    pollNativeUpdate()
    pollNativeTerminal()
    let idleDocument = activeDocument()
    let idleStatus = if idleDocument != nil: editorViewState.statusBarText(idleDocument[].buffer)
      else: editorViewState.statusMessage
    platformSetEditorStatus(idleStatus.cstring)
    if lspBridge == nil: return
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
    let finalDocument = activeDocument()
    let finalStatus = if finalDocument != nil: editorViewState.statusBarText(finalDocument[].buffer)
      else: editorViewState.statusMessage
    platformSetEditorStatus(finalStatus.cstring)

  proc acceptCurrentCompletion() =
    let document = activeDocument()
    if document == nil or lspBridge == nil or not lspBridge.completionVisible: return
    let edit = lspBridge.completionEdit(document[].buffer)
    if edit.endByte <= edit.startByte and edit.text.len == 0: return
    document[].buffer.edit(Edit(startByte: edit.startByte, endByte: edit.endByte,
      text: edit.text))
    editorViewState.moveCursor(edit.startByte + edit.text.len)
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
        workspaceSearchJob = activeWorkspace.startSearch(workspaceSearchQuery)
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
        let lengthOrder = cmp(a.relativePath.len, b.relativePath.len)
        if lengthOrder != 0: lengthOrder else: cmp(a.relativePath, b.relativePath))
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
    inc persistenceTick
    if persistenceTick mod 20 == 0:
      persistSession()

proc receiveNativeTextValue(value: string, composing: bool) =
  when defined(macosx):
    if editorTerminalVisible and editorTerminal != nil and not composing:
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
    let document = activeDocument()
    if document != nil:
      let selected = editorViewState.selectedRange()
      document[].buffer.edit(Edit(startByte: selected.startByte,
        endByte: selected.endByte, text: value))
      editorViewState.moveCursor(selected.startByte + value.len)
      syncEditorCursor()
      refreshEditorSyntax()
      when defined(macosx):
        requestEditorCompletion()

proc receiveNativeText(text: cstring, composing: bool) {.cdecl.} =
  receiveNativeTextValue(if text == nil: "" else: $text, composing)

proc receiveNativeSelection(startByte, endByte: uint32) {.cdecl.} =
  let document = activeDocument()
  if document == nil: return
  let text = document[].buffer.toString()
  let length = text.len
  editorViewState.selection.anchor = floorGraphemeBoundary(text, min(int(startByte), length))
  editorViewState.selection.active = floorGraphemeBoundary(text, min(int(endByte), length))
  syncEditorCursor()

proc receiveNativeFile(path: cstring, saving: bool) {.cdecl.} =
  if path == nil or ($path).len == 0: return
  let filePath = $path
  if workspaceSearchJob != nil:
    workspaceSearchJob.cancelSearch()
    workspaceSearchJob = nil
  if workspaceQuickOpenJob != nil:
    workspaceQuickOpenJob.cancelFuzzySearch()
    workspaceQuickOpenJob = nil
  if saving:
    let document = activeDocument()
    if document != nil:
      try:
        document[].save(filePath)
        if editorSession.activeTab >= 0 and editorSession.activeTab < editorSession.tabs.len:
          editorSession.tabs[editorSession.activeTab].title = splitFile(filePath).name
        externalAlertShown = false
        editorViewState.statusMessage = "Saved " & filePath
        syncEditorCursor()
        when defined(macosx):
          # The native Save Panel used by close confirmation must only allow
          # termination after the document write has actually succeeded.
          platformSetCloseDecision(true)
      except CatchableError as error:
        editorViewState.statusMessage = "Save failed: " & error.msg
        when defined(macosx):
          platformSetCloseDecision(false)
  else:
    if dirExists(filePath):
      openActiveWorkspace(filePath)
      return
    try:
      workspacePreviewEntries.setLen(0)
      workspacePreviewMode = ""
      editorSession.saveActiveView(editorViewState)
      editorSession.addTab(openDocument(filePath))
      resetImeState()
      resetEditorViewState()
      let document = activeDocument()
      if document != nil: editorViewState.moveCursor(0)
      editorSession.recordRecent(filePath)
      syncRecentFiles()
      syncEditorCursor()
      refreshEditorSyntax()
      persistSession()
    except CatchableError:
      discard

when defined(macosx):
  proc navigateToDefinition() =
    if lspBridge == nil: return
    let locations = lspBridge.takeDefinitionLocations()
    if locations.len == 0: return
    let targetPath = filePathFromUri(locations[0].uri)
    if targetPath.len == 0: return
    let current = activeDocument()
    if current == nil or absolutePath(current[].path) != absolutePath(targetPath):
      receiveNativeFile(targetPath.cstring, false)
    let document = activeDocument()
    if document == nil: return
    let location = locations[0].range.start
    let byteOffset = document[].buffer.byteOffsetAtUtf16Position(location.line, location.character)
    editorViewState.moveCursor(byteOffset)
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
      receiveNativeFile(entry.path.cstring, false)

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
    receiveNativeFile(match.path.cstring, false)
    let document = activeDocument()
    if document != nil:
      let lineIndex = max(0, match.line - 1)
      let lineStart = document[].buffer.byteOffsetAtLineColumn(lineIndex, 0)
      editorViewState.moveCursor(min(document[].buffer.toString().len,
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

proc receiveNativeCommand(command: cstring) {.cdecl.} =
  if command == nil: return
  let name = $command
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
    if editorTerminalVisible and editorTerminal != nil:
      case name
      of "insertNewline": writeNativeTerminalInput("\r")
      of "insertTab": writeNativeTerminalInput("\t")
      of "deleteBackward": writeNativeTerminalInput("\x7f")
      of "moveLeft": writeNativeTerminalInput(
        if editorTerminal.screen.applicationCursorKeys: "\x1bOD" else: "\x1b[D")
      of "moveRight": writeNativeTerminalInput(
        if editorTerminal.screen.applicationCursorKeys: "\x1bOC" else: "\x1b[C")
      of "moveUp": writeNativeTerminalInput(
        if editorTerminal.screen.applicationCursorKeys: "\x1bOA" else: "\x1b[A")
      of "moveDown": writeNativeTerminalInput(
        if editorTerminal.screen.applicationCursorKeys: "\x1bOB" else: "\x1b[B")
      of "moveToBeginningOfLine": writeNativeTerminalInput(
        if editorTerminal.screen.applicationCursorKeys: "\x1bOH" else: "\x1b[H")
      of "moveToEndOfLine": writeNativeTerminalInput(
        if editorTerminal.screen.applicationCursorKeys: "\x1bOF" else: "\x1b[F")
      of "pageUp": writeNativeTerminalInput("\x1b[5~")
      of "pageDown": writeNativeTerminalInput("\x1b[6~")
      of "cancel": writeNativeTerminalInput("\x03")
      of "copy":
        let copied = editorTerminal.screen.selectedText(editorTerminalSelection)
        if copied.len > 0: clipboardSet(copied.cstring, uint32(copied.len))
      of "selectAll":
        editorTerminalSelection = TerminalSelection(
          anchor: TerminalPoint(row: 0, column: 0),
          active: TerminalPoint(row: max(0, editorTerminal.screen.lineCount() - 1),
            column: editorTerminal.screen.columns))
        syncNativeTerminalSelection()
      of "paste": writeNativeTerminalInput(clipboardGet(), paste = true)
      else: discard
      if name in ["insertNewline", "insertTab", "deleteBackward", "moveLeft",
                  "moveRight", "moveUp", "moveDown", "moveToBeginningOfLine",
                  "moveToEndOfLine", "pageUp", "pageDown", "cancel", "copy",
                  "selectAll", "paste"]:
        return
  let document = activeDocument()
  if name == "workspaceSearchTick":
    pollWorkspaceSearch()
  elif name == "cancelWorkspaceSearch":
    cancelWorkspaceSearch()
  elif name == "windowResized":
    setupDemoUi()
    when defined(macosx): resizeNativeTerminals()
    if activeDocument() != nil: refreshEditorSyntax()
  elif name == "windowFocusLost":
    resetPointerInteractions()
  elif name == "quitRequest":
    when defined(macosx):
      if editorUpdateJob != nil and not editorUpdateJob.done:
        cancelNativeUpdateDownload()
      if editorSession.hasDirtyTabs(): platformRequestQuit()
      else:
        applyPendingUpdateAtQuit()
        closeNativeTerminals()
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
      when defined(macosx): applyPendingUpdateAtQuit()
      when defined(macosx): closeNativeTerminals()
      when defined(windows): closeWindowsTerminal()
    platformSetCloseDecision(success and not editorSession.hasDirtyTabs())
  elif name == "discardAllAndQuit":
    suppressRecoveryWrite = true
    discardDirtyOnExit = true
    if recoveryFilePath.len > 0 and fileExists(recoveryFilePath):
      removeFile(recoveryFilePath)
    when defined(macosx): applyPendingUpdateAtQuit()
    when defined(macosx): closeNativeTerminals()
    when defined(windows): closeWindowsTerminal()
    platformSetCloseDecision(true)
  elif name == "closeTabRequest":
    when defined(macosx): platformRequestCloseTab()
    when defined(windows):
      if document == nil: return
      if document[].buffer.isDirty:
        platformSetEditorStatus("Unsaved changes: save before closing".cstring)
      else:
        receiveNativeCommand("closeTabConfirmed".cstring)
  elif name == "saveAndCloseTab":
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
      when defined(macosx): platformShowSavePanelAndCloseTab()
  elif name == "closeTabConfirmed":
    when defined(macosx): editorLspSignatureText = ""
    if editorSession.closeActiveTab(forceDirty = true):
      resetImeState()
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
  elif name in ["previousTab", "nextTab"]:
    let delta = if name == "previousTab": -1 else: 1
    if editorSession.switchTab(editorViewState, delta):
      when defined(macosx): editorLspSignatureText = ""
      resetImeState()
      resetEditorViewState()
      workspacePreviewMode = ""
      externalAlertShown = false
      if syntaxState != nil:
        syntaxState.close()
        syntaxState = nil
      syncEditorCursor()
      refreshEditorSyntax()
      persistSession()
  elif name.startsWith("selectTab:"):
    let payload = name["selectTab:".len .. ^1]
    try:
      let target = parseInt(payload)
      if target >= 0 and target < editorSession.tabs.len and target != editorSession.activeTab:
        editorSession.saveActiveView(editorViewState)
        editorSession.activeTab = target
        editorSession.loadActiveView(editorViewState)
        resetImeState()
        resetEditorViewState()
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
      let font = if appSettings != nil: appSettings.stringSetting("editor.fontFamily",
          "Menlo") else: "Menlo"
      let shell = if appSettings != nil: appSettings.stringSetting("terminal.shell",
          "/bin/zsh") else: "/bin/zsh"
      platformShowSettingsPanel(theme.cstring, editorSize.cstring, terminalSize.cstring,
        font.cstring, shell.cstring)
  elif name.startsWith("settingsApply:"):
    let payload = name["settingsApply:".len .. ^1]
    let fields = payload.split('\x1f')
    if fields.len != 5 or settingsFilePath.len == 0:
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
    root["terminal"]["shell"] = %fields[4]
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
      editorViewState.moveCursor(document[].buffer.byteOffsetAtLineColumn(line, 0))
      syncEditorCursor()
      refreshEditorSyntax()
    except ValueError:
      editorViewState.statusMessage = "Invalid line number"
  elif name == "toggleSoftWrap":
    editorViewState.softWrap = not editorViewState.softWrap
    editorViewState.statusMessage = if editorViewState.softWrap:
      "Soft wrap enabled" else: "Soft wrap disabled"
    syncEditorCursor()
    refreshEditorSyntax()
    persistSession()
  elif name.startsWith("commandPalette:"):
    let rawCommand = name[15 .. ^1].strip
    let command = rawCommand.toLowerAscii
    let dispatchCommand =
      if command.startsWith("git commit "): "__git_commit__"
      elif command.startsWith("git checkout "): "__git_checkout__"
      elif command == "git stage hunk": "__git_stage_hunk__"
      elif command == "git unstage hunk": "__git_unstage_hunk__"
      elif command == "toggle terminal": "__toggle_terminal__"
      elif command == "new terminal": "__new_terminal__"
      elif command == "next terminal": "__next_terminal__"
      elif command == "previous terminal": "__previous_terminal__"
      elif command in ["toggle task output", "show task output"]: "__task_output__"
      elif command.startsWith("run task "): "__run_task__"
      elif command == "cancel task": "__cancel_task__"
      elif command == "cancel git": "__cancel_git__"
      elif command.startsWith("workspace search "): "__workspace_search__"
      elif command.startsWith("quick open "): "__quick_open__"
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
      when defined(macosx):
        if document != nil and document[].path.len > 0:
          try:
            document[].save()
            editorViewState.statusMessage = "Saved " & document[].path
            syncEditorCursor()
            refreshEditorSyntax()
          except CatchableError as error:
            editorViewState.statusMessage = "Save failed: " & error.msg
        else:
          let path = chooseSaveFile()
          if path != nil and ($path).len > 0: receiveNativeFile(path, true)
    of "find":
      when defined(macosx):
        platformShowFindDocument()
    of "openSettings":
      receiveNativeCommand("openSettings".cstring)
    of "go to definition":
      when defined(macosx):
        if document == nil or lspBridge == nil:
          editorViewState.statusMessage = "LSP definition unavailable"
        elif lspBridge.requestDefinition(document[].buffer, editorViewState.cursor):
          editorViewState.statusMessage = "LSP: finding definition"
        else:
          editorViewState.statusMessage = "LSP definition unavailable"
    of "find references":
      when defined(macosx):
        if document == nil or lspBridge == nil:
          editorViewState.statusMessage = "LSP references unavailable"
        elif lspBridge.requestReferences(document[].buffer, editorViewState.cursor):
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
              editorViewState.cursor, newName):
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
            if index < 0 or index >= pendingLspSymbols.len:
              editorViewState.statusMessage = "Invalid symbol number"
            else:
              let symbol = pendingLspSymbols[index]
              let target = document[].buffer.byteOffsetAtUtf16Position(
                symbol.range.start.line, symbol.range.start.character)
              editorViewState.moveCursor(target)
              syncEditorCursor()
              refreshEditorSyntax()
              editorViewState.statusMessage = "LSP: " & symbol.name
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
            not lspBridge.requestSignatureHelp(document[].buffer, editorViewState.cursor):
          editorViewState.statusMessage = "LSP signature help unavailable"
        else:
          editorViewState.statusMessage = "LSP: loading signature help"
    of "inlay hints":
      when defined(macosx):
        if document == nil or lspBridge == nil or
            not lspBridge.requestInlayHints(lspSelectionRange(document)):
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
    of "__cancel_git__":
      when defined(macosx):
        if editorGitActionJob == nil or editorGitActionJob.done:
          editorViewState.statusMessage = "Git: no running operation"
        else:
          cancelNativeGitAction()
          editorViewState.statusMessage = "Git: cancelled"
    of "__toggle_terminal__":
      when defined(macosx): toggleNativeTerminal()
    of "__new_terminal__":
      when defined(macosx): newNativeTerminal()
    of "__next_terminal__":
      when defined(macosx): switchNativeTerminal(1)
    of "__previous_terminal__":
      when defined(macosx): switchNativeTerminal(-1)
    of "__task_output__":
      when defined(macosx): toggleNativeTaskOutput()
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
    of "git status":
      when defined(macosx):
        let repository = gitRepositoryForDocument(document)
        if repository == nil:
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
          let line = document[].buffer.lineColumn(editorViewState.cursor).line
          startNativeGitHunkAction(repository, relative,
            if dispatchCommand == "__git_stage_hunk__": "stage hunk" else: "unstage hunk",
            line)
    of "git log":
      when defined(macosx):
        let repository = gitRepositoryForDocument(document)
        if repository == nil:
          editorViewState.statusMessage = "Git repository not found"
        else:
          startNativeGitAction(repository, "log", "", [
            "log", "--format=%H%x00%an%x00%ae%x00%at%x00%s%x00", "-n", "5"])
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
  elif name == "reloadExternal" and document != nil:
    try:
      discard editorSession.reloadActiveDocument(editorViewState)
      resetImeState()
      if syntaxState != nil:
        syntaxState.close()
        syntaxState = nil
      externalAlertShown = false
      syncEditorCursor()
      refreshEditorSyntax()
    except CatchableError:
      externalAlertShown = false
  elif name == "keepExternal" and document != nil:
    document[].acceptExternalState()
    externalAlertShown = false
  elif name.startsWith("workspaceSearch:"):
    showWorkspaceSearch(name[16 .. ^1])
  elif name.startsWith("quickOpen:"):
    showQuickOpen(name[10 .. ^1].strip)
  elif name.startsWith("workspaceCreateFile:") and activeWorkspace != nil:
    let payload = workspaceRelativePayload(name, "workspaceCreateFile:")
    if payload.len == 0: return
    try:
      let location = activeWorkspace.splitWorkspacePath(payload)
      discard activeWorkspace.createFileAt(location.root, location.relative)
      refreshWorkspaceAfterMutation("Created " & payload)
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
      discard activeWorkspace.renameEntryAt(oldLocation.root, oldLocation.relative,
          newLocation.relative)
      refreshWorkspaceAfterMutation("Renamed " & oldPayload & " to " & newPayload)
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
    editorViewState.clampSelectionToText(document[].buffer.toString())
    editorViewState.statusMessage = "Replaced " & $count & " matches"
    syncEditorCursor()
    refreshEditorSyntax()
  elif name == "cancel":
    imeState.composition.setLen(0)
    when defined(macosx) or defined(windows): platformSetEditorComposition("".cstring)
  elif name == "moveLeft" and document != nil:
    editorViewState.moveCursor(previousBoundary(document[].buffer.toString(),
        editorViewState.cursor))
    syncEditorCursor()
  elif name == "selectLeft" and document != nil:
    editorViewState.moveCursor(previousBoundary(document[].buffer.toString(),
        editorViewState.cursor), selecting = true)
    syncEditorCursor()
  elif name == "moveRight" and document != nil:
    editorViewState.moveCursor(nextBoundary(document[].buffer.toString(), editorViewState.cursor))
    syncEditorCursor()
  elif name in ["moveUp", "moveDown", "selectUp", "selectDown"] and document != nil:
    let location = document[].buffer.lineColumn(editorViewState.cursor)
    let delta = if name in ["moveUp", "selectUp"]: -1 else: 1
    let targetLine = max(0, min(document[].buffer.lineStarts.high, location.line + delta))
    let target = document[].buffer.byteOffsetAtLineColumn(targetLine, location.column)
    editorViewState.moveCursor(target, selecting = name.startsWith("select"))
    syncEditorCursor()
  elif name in ["moveToBeginningOfLine", "selectToBeginningOfLine"] and document != nil:
    let location = document[].buffer.lineColumn(editorViewState.cursor)
    editorViewState.moveCursor(document[].buffer.lineStarts[location.line],
      selecting = name.startsWith("select"))
    syncEditorCursor()
  elif name in ["moveToEndOfLine", "selectToEndOfLine"] and document != nil:
    let location = document[].buffer.lineColumn(editorViewState.cursor)
    editorViewState.moveCursor(lineEndOffset(document, location.line),
      selecting = name.startsWith("select"))
    syncEditorCursor()
  elif name == "moveToBeginningOfDocument" and document != nil:
    editorViewState.moveCursor(0)
    syncEditorCursor()
  elif name == "moveToEndOfDocument" and document != nil:
    editorViewState.moveCursor(document[].buffer.toString().len)
    syncEditorCursor()
  elif name == "insertNewline" and document != nil:
    receiveNativeText("\n".cstring, false)
  elif name == "insertTab" and document != nil:
    receiveNativeText("\t".cstring, false)
  elif name == "selectRight" and document != nil:
    editorViewState.moveCursor(nextBoundary(document[].buffer.toString(), editorViewState.cursor),
        selecting = true)
    syncEditorCursor()
  elif name == "moveWordLeft" and document != nil:
    editorViewState.moveCursor(previousWordBoundary(document[].buffer.toString(),
        editorViewState.cursor))
    syncEditorCursor()
  elif name == "selectWordLeft" and document != nil:
    editorViewState.moveCursor(previousWordBoundary(document[].buffer.toString(),
        editorViewState.cursor), selecting = true)
    syncEditorCursor()
  elif name == "moveWordRight" and document != nil:
    editorViewState.moveCursor(nextWordBoundary(document[].buffer.toString(),
        editorViewState.cursor))
    syncEditorCursor()
  elif name == "selectWordRight" and document != nil:
    editorViewState.moveCursor(nextWordBoundary(document[].buffer.toString(),
        editorViewState.cursor), selecting = true)
    syncEditorCursor()
  elif name in ["deleteBackward", "deleteForward", "deleteWordBackward"] and document != nil:
    let selected = editorViewState.selectedRange()
    var start = selected.startByte
    var finish = selected.endByte
    if start == finish:
      if name == "deleteWordBackward": start = previousWordBoundary(document[].buffer.toString(), start)
      elif name == "deleteBackward": start = previousBoundary(document[].buffer.toString(), start)
      else: finish = nextBoundary(document[].buffer.toString(), finish)
    if finish > start:
      document[].buffer.edit(Edit(startByte: start, endByte: finish, text: ""))
      editorViewState.moveCursor(start)
      syncEditorCursor()
      refreshEditorSyntax()
  elif name == "undo" and document != nil:
    if document[].buffer.undo():
      editorViewState.moveCursor(min(editorViewState.cursor, document[].buffer.toString().len))
      syncEditorCursor()
      refreshEditorSyntax()
  elif name == "redo" and document != nil:
    if document[].buffer.redo():
      editorViewState.moveCursor(min(editorViewState.cursor, document[].buffer.toString().len))
      syncEditorCursor()
      refreshEditorSyntax()
  elif name == "copy" and document != nil:
    let selected = editorViewState.selectedRange()
    let copied = document[].buffer.substring(selected.startByte, selected.endByte)
    clipboardSet(copied.cstring, uint32(copied.len))
  elif name == "cut" and document != nil:
    let selected = editorViewState.selectedRange()
    let copied = document[].buffer.substring(selected.startByte, selected.endByte)
    clipboardSet(copied.cstring, uint32(copied.len))
    if selected.endByte > selected.startByte:
      document[].buffer.edit(Edit(startByte: selected.startByte, endByte: selected.endByte, text: ""))
      editorViewState.moveCursor(selected.startByte)
      refreshEditorSyntax()
      syncEditorCursor()
  elif name == "paste":
    receiveNativeTextValue(clipboardGet(), false)
  elif name == "selectAll" and document != nil:
    editorViewState.selection.anchor = 0
    editorViewState.selection.active = document[].buffer.toString().len
    syncEditorCursor()

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
  let hit = demoTree.hitTest(point)
  let target = if kind in {keyDown, keyUp, modifiersChanged, command}:
    if demoTree.focused != NodeId(0): demoTree.focused else: hit
  else: hit
  when defined(macosx):
    let document = activeDocument()
    let inEditor = demoEditorBounds.contains(point)
    var splitPointerHandled = false
    if editorTerminalVisible and kind in {pointerDown, pointerMove, pointerUp, scroll} and
        handleTerminalPointer(kind, float32(event.x), uiY, event.button,
          event.modifiers, float32(event.deltaY)):
      return
    if not inEditor and lspBridge != nil:
      lspBridge.hideHover()
      syncNativeHover()
    if document != nil and kind == scroll and inEditor:
      let delta = scrollLineDelta(editorScrollRemainder, float32(event.deltaY),
        event.preciseScrolling)
      let maxScroll = max(0, document[].buffer.lineStarts.len - editorVisibleLineCount())
      editorViewState.scrollLine = max(0, min(maxScroll, editorViewState.scrollLine + delta))
      syncEditorCursor()
      refreshEditorSyntax()
    if document != nil and kind == pointerDown and inEditor and
        float32(event.x) - float32(demoEditorBounds.origin.x) < 8'f32 and
        handleGitGutterClick(document, uiY, event.modifiers):
      return
    if kind == pointerDown and hit == demoSplitNode:
      demoSplitDragging = true
      editorPointerDragging = false
      splitPointerHandled = true
    elif demoSplitDragging and kind == pointerMove:
      let editorBounds = demoTree.node(demoScrollNode).bounds
      let width = max(1'f32, float32(editorBounds.size.width))
      demoSplitRatio = min(0.9'f32, max(0.1'f32,
        (float32(event.x) - float32(editorBounds.origin.x)) / width))
      setupDemoUi()
      splitPointerHandled = true
    elif demoSplitDragging and kind == pointerUp:
      demoSplitDragging = false
      splitPointerHandled = true
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
      let offset = editorOffsetAtPoint(document, event.x, event.y)
      if kind == pointerDown:
        if lspBridge != nil:
          lspBridge.hideHover()
          editorLspSignatureText = ""
          syncNativeHover()
        editorPointerDragging = true
        editorViewState.moveCursor(offset)
        syncEditorCursor()
      elif kind == pointerMove and not editorPointerDragging and lspBridge != nil:
        lspBridge.scheduleHover(offset)
        platformSetEditorHoverPosition(
          float64(float32(event.x) - float32(demoEditorBounds.origin.x)),
          float64(uiY - float32(demoEditorBounds.origin.y)))
        syncNativeHover()
      elif kind == pointerMove and editorPointerDragging:
        editorViewState.moveCursor(offset, selecting = true)
        syncEditorCursor()
      elif kind == pointerUp:
        if editorPointerDragging:
          editorViewState.moveCursor(offset, selecting = true)
          syncEditorCursor()
        editorPointerDragging = false
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
    let initialRoot = if editorSession.workspaceRoots.len > 0:
      editorSession.workspaceRoots[0]
    else: getCurrentDir()
    # The workspace preview resolves file icons through SettingsStore. Build
    # the settings layer before opening the workspace so the first refresh is
    # identical to subsequent root changes.
    appSettings = newSettingsStore(settingsFilePath,
      initialRoot / ".nimculus" / "settings.json")
    openActiveWorkspace(if dirExists(initialRoot): initialRoot else: getCurrentDir())
    if editorSession.workspaceRoots.len > 1:
      for root in editorSession.workspaceRoots[1 .. ^1]:
        if dirExists(root): activeWorkspace.addRoot(root)
      activeWorkspace.startWatching()
      refreshWorkspacePreview()
    applySettingsKeymap()
    applySettingsTheme()
    let outline = "Outline\n────────\nNo symbols"
    platformSetEditorOutline(outline.cstring, uint32(outline.len), 0)
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
    if activeDocument() != nil:
      syncEditorCursor()
      refreshEditorSyntax()
    else:
      persistSession()
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
