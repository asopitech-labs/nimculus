import std/algorithm
import std/math
import std/os
import std/strutils
import std/tables
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
import nimculus/editor_diagnostics
import nimculus/git_service
import nimculus/task_service

var demoTree = newUiTree()
var shortcutRegistry: CommandRegistry
var demoButton = NodeId(0)
var demoSplitNode = NodeId(0)
var demoScrollNode = NodeId(0)
var demoSplitRatio = 0.5'f32
var demoSplitDragging = false
var activePointerNode = NodeId(0)
var demoEditorBounds = Rect(size: Size(width: px(0), height: px(0)))

proc resetPointerInteractions()
when defined(macosx):
  proc handleCompletionShortcut(event: ptr NimculusInputEvent): bool

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
  let editorWidth = max(0'f32, viewportWidth - margin * 4 - 84'f32)
  let editorHeight = max(0'f32, viewportHeight - 208'f32)
  let editor = Rect(origin: Point(x: px(margin * 2), y: px(128)),
    size: Size(width: px(editorWidth), height: px(editorHeight)))
  demoEditorBounds = editor
  let splitBar = Rect(origin: Point(x: px(margin * 2 + editorWidth * demoSplitRatio), y: px(128)),
    size: Size(width: px(2), height: px(editorHeight)))
  let scrollbar = Rect(origin: Point(x: px(margin * 2 + editorWidth + 24), y: px(144)),
    size: Size(width: px(8), height: px(max(0'f32, editorHeight - 32'f32))))
  demoTree.node(button.node).bounds = toolbar
  demoTree.node(split.node).bounds = splitBar
  demoTree.node(scroll.node).bounds = editor
  var paint: PaintList
  paint.invalidate(viewport)
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
when defined(macosx):
  proc navigateToDefinition()
  proc applyPendingFormatting()

proc dispatchNativeShortcut(event: ptr NimculusInputEvent): bool {.cdecl.} =
  if event == nil: return false
  when defined(macosx):
    if handleCompletionShortcut(event): return true
  shortcutRegistry.dispatchShortcut(Shortcut(
    keyCode: event.keyCode,
    modifiers: macOSModifiers(event.modifiers)))

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
var persistenceTick = 0
var suppressRecoveryWrite = false
var discardDirtyOnExit = false
when defined(macosx):
  var lspBridge: LspEditorBridge
  var editorGitDiffJob: GitJob
  var editorGitRepository: GitRepository
  var editorGitPath = ""
  var editorTaskJob: TaskJob
  var editorTaskCommand = ""

proc resetEditorViewState() =
  editorViewState = newEditorView()
  editorScrollRemainder = 0'f32

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
    let hunks = repository.diffHunks(relative, staged = unstage)
    var hunkIndex = -1
    for index, hunk in hunks:
      let firstLine = max(0, hunk.newStart - 1)
      let lineCount = max(1, hunk.newCount)
      if line >= firstLine and line < firstLine + lineCount:
        hunkIndex = index
        break
    if hunkIndex < 0: return false
    let outcome = if unstage: repository.unstageHunk(relative, hunkIndex)
      else: repository.stageHunk(relative, hunkIndex)
    editorViewState.statusMessage = if outcome.exitCode == 0:
      (if unstage: "Git: unstaged hunk" else: "Git: staged hunk")
      else: "Git hunk operation failed: " & outcome.output.strip
    refreshEditorSyntax()
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
    if editorTaskJob == nil or not editorTaskJob.poll(): return
    let taskResult = editorTaskJob.result
    let output = taskResult.output.strip()
    let summary = if output.len == 0: "" else:
      let lines = output.splitLines
      " — " & lines[lines.high]
    case taskResult.status
    of taskSucceeded:
      editorViewState.statusMessage = "Task succeeded: " & editorTaskCommand & summary
    of taskFailed:
      editorViewState.statusMessage = "Task failed (" & $taskResult.exitCode & "): " &
        editorTaskCommand & summary
    of taskCancelled:
      editorViewState.statusMessage = "Task cancelled: " & editorTaskCommand
    else: discard
    editorTaskJob = nil

  proc scheduleNativeGitHunks(document: ptr FileDocument) =
    if editorGitDiffJob != nil:
      editorGitDiffJob.cancel()
      editorGitDiffJob = nil
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
    editorGitDiffJob = repository.startGitJob([
      "diff", "--no-ext-diff", "--unified=3", "--", relative])

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

  proc editorVisibleLineCount(): int =
    ## Keep cursor reveal, syntax requests, and native text rendering on the
    ## same viewport contract. The old fixed 12-line value left taller windows
    ## only half painted.
    max(1, int(ceil(float32(demoEditorBounds.size.height) / 18'f32)))

proc setupPersistencePaths() =
  let directory = getHomeDir() / "Library" / "Application Support" / "Nimculus"
  if not dirExists(directory): createDir(directory)
  sessionFilePath = directory / "session.json"
  recoveryFilePath = directory / "active.recovery"

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

proc openActiveWorkspace(path: string) =
  when defined(macosx):
    if activeWorkspace != nil: activeWorkspace.stopWatching()
    # A search job owns the workspace snapshot it is traversing.  Drop it
    # before replacing activeWorkspace so results from the previous root
    # cannot be rendered after the switch.
    if workspaceSearchJob != nil: workspaceSearchJob.cancelSearch()
    workspaceSearchJob = nil
    if workspaceQuickOpenJob != nil: workspaceQuickOpenJob.cancelFuzzySearch()
    workspaceQuickOpenJob = nil
    activeWorkspace = openWorkspace(path)
    activeWorkspace.startWatching()
    workspaceSearchQuery = ""
    workspaceQuickOpenQuery = ""
    workspaceSearchResults.setLen(0)
    workspaceSearchCancelled = false
    refreshWorkspacePreview()

proc refreshWorkspacePreview() =
  when defined(macosx):
    if activeWorkspace == nil: return
    workspacePreviewMode = "tree"
    workspacePreviewEntries.setLen(0)
    var lines = @["Workspace: " & activeWorkspace.root]
    for rootIndex, root in activeWorkspace.rootPaths:
      if rootIndex > 0:
        if lines.len >= 12: break
        lines.add("Root: " & root)
        workspacePreviewEntries.add(WorkspaceEntry(path: root, rootPath: root,
          relativePath: root, kind: WorkspaceFileKind.directory))
      var children = activeWorkspace.listChildrenAt(root)
      children.sort(proc(a, b: WorkspaceEntry): int = cmp(a.relativePath, b.relativePath))
      for entry in children:
        if lines.len >= 12: break
        workspacePreviewEntries.add(entry)
        let marker = if entry.kind == WorkspaceFileKind.directory: "[D] " else: "    "
        lines.add(marker & entry.relativePath)
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
  when defined(macosx):
    if activeWorkspace != nil:
      activeWorkspace.startWatching()
      editorViewState.statusMessage = message
      refreshWorkspacePreview()

proc workspaceRelativePayload(name, prefix: string): string =
  if not name.startsWith(prefix) or name.len <= prefix.len: return ""
  name[prefix.len .. ^1].strip

proc renderWorkspaceSearch() =
  when defined(macosx):
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
    if workspaceSearchResults.len == 0 and workspaceSearchJob != nil and workspaceSearchJob.isComplete:
      lines.add("No matches")
    platformSetEditorHighlights(nil, 0)
    platformSetEditorComposition("".cstring)
    platformSetEditorScrollLine(0)
    platformSetEditorCursorByte(0, 0)
    platformSetEditorSelection(0, 0)
    let text = lines.join("\n")
    platformSetEditorText(text.cstring, uint32(text.len))

proc renderQuickOpen() =
  when defined(macosx):
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
  when defined(macosx):
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
  when defined(macosx):
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
  when defined(macosx):
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
    if document != nil and document[].path.len > 0 and document[].externallyChanged() and not externalAlertShown:
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
    if lspBridge == nil or not lspBridge.hoverVisible:
      platformSetEditorHover("".cstring, 0)
      return
    let text = lspBridge.hoverText()
    platformSetEditorHover(text.cstring, uint32(text.len))

  proc requestEditorCompletion() =
    let document = activeDocument()
    if document == nil or lspBridge == nil:
      platformSetEditorCompletions("".cstring, 0)
      return
    if lspBridge.requestCompletion(document[].buffer, editorViewState.cursor):
      platformSetEditorCompletions("".cstring, 0)
    else:
      platformSetEditorCompletions("".cstring, 0)

proc refreshEditorSyntax() =
  let document = activeDocument()
  if document == nil:
    when defined(macosx):
      platformSetEditorDiagnostics(nil, 0)
      clearNativeGitHunks()
    return
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
      syncNativeDiagnostics(document)
      scheduleNativeGitHunks(document)
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
    var highlightPtr: ptr NativeHighlightSpan = nil
    if nativeHighlights.len > 0: highlightPtr = addr nativeHighlights[0]
    platformSetEditorHighlights(highlightPtr, uint32(nativeHighlights.len))
    let text = document[].buffer.toString()
    platformSetEditorCompletions("".cstring, 0)
    platformSetEditorText(text.cstring, uint32(text.len))
    syncNativeDiagnostics(document)
    scheduleNativeGitHunks(document)

when defined(macosx):
  proc pollLspAndRefreshDiagnostics() =
    let document = activeDocument()
    if document != nil: syncNativeDiagnostics(document)

  proc receiveNativeIdle() {.cdecl.} =
    pollNativeGitHunks()
    pollNativeTask()
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

proc receiveNativeTextValue(value: string, composing: bool) =
  imeState.receiveText(value, composing)
  when defined(macosx):
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
  let document = activeDocument()
  if name == "workspaceSearchTick":
    pollWorkspaceSearch()
  elif name == "cancelWorkspaceSearch":
    cancelWorkspaceSearch()
  elif name == "windowResized":
    setupDemoUi()
    if activeDocument() != nil: refreshEditorSyntax()
  elif name == "windowFocusLost":
    resetPointerInteractions()
  elif name == "quitRequest":
    when defined(macosx):
      if editorSession.hasDirtyTabs(): platformRequestQuit()
      else: platformConfirmQuit()
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
    platformSetCloseDecision(success and not editorSession.hasDirtyTabs())
  elif name == "discardAllAndQuit":
    suppressRecoveryWrite = true
    discardDirtyOnExit = true
    if recoveryFilePath.len > 0 and fileExists(recoveryFilePath):
      removeFile(recoveryFilePath)
    platformSetCloseDecision(true)
  elif name == "closeTabRequest":
    when defined(macosx): platformRequestCloseTab()
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
    if editorSession.closeActiveTab(forceDirty = true):
      resetImeState()
      resetEditorViewState()
      externalAlertShown = false
      if syntaxState != nil:
        syntaxState.close()
        syntaxState = nil
      workspacePreviewMode = ""
      when defined(macosx):
        platformSetEditorHighlights(nil, 0)
        syncEditorCursor()
        let current = activeDocument()
        if current == nil:
          platformSetEditorText("".cstring, 0)
        else:
          refreshEditorSyntax()
      persistSession()
  elif name in ["previousTab", "nextTab"]:
    let delta = if name == "previousTab": -1 else: 1
    if editorSession.switchTab(editorViewState, delta):
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
    when defined(macosx):
      platformSetEditorHighlights(nil, 0)
      platformSetEditorComposition("".cstring)
      platformSetEditorText("".cstring, 0)
      syncEditorCursor()
  elif name == "saveSession":
    persistSession()
  elif name == "discardSession":
    suppressRecoveryWrite = true
    if recoveryFilePath.len > 0 and fileExists(recoveryFilePath):
      removeFile(recoveryFilePath)
  elif name.startsWith("goToLine:") and document != nil:
    let value = name[9 .. ^1].strip
    try:
      let line = max(1, parseInt(value)) - 1
      editorViewState.moveCursor(document[].buffer.byteOffsetAtLineColumn(line, 0))
      syncEditorCursor()
      refreshEditorSyntax()
    except ValueError:
      editorViewState.statusMessage = "Invalid line number"
  elif name.startsWith("commandPalette:"):
    let rawCommand = name[15 .. ^1].strip
    let command = rawCommand.toLowerAscii
    let dispatchCommand =
      if command.startsWith("git commit "): "__git_commit__"
      elif command.startsWith("git checkout "): "__git_checkout__"
      elif command == "git stage hunk": "__git_stage_hunk__"
      elif command == "git unstage hunk": "__git_unstage_hunk__"
      elif command.startsWith("run task "): "__run_task__"
      elif command == "cancel task": "__cancel_task__"
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
    of "go to definition":
      when defined(macosx):
        if document == nil or lspBridge == nil:
          editorViewState.statusMessage = "LSP definition unavailable"
        elif lspBridge.requestDefinition(document[].buffer, editorViewState.cursor):
          editorViewState.statusMessage = "LSP: finding definition"
        else:
          editorViewState.statusMessage = "LSP definition unavailable"
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
    of "__cancel_task__":
      when defined(macosx): cancelNativeTask()
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
          let entries = repository.status()
          var conflicts = 0
          for entry in entries:
            if entry.conflict: inc conflicts
          editorViewState.statusMessage = "Git: " & $entries.len &
            " changed file(s), " & $conflicts & " conflict(s)"
    of "git stage all":
      when defined(macosx):
        let repository = gitRepositoryForDocument(document)
        if repository == nil:
          editorViewState.statusMessage = "Git repository not found"
        else:
          let outcome = repository.stageAll()
          editorViewState.statusMessage = if outcome.exitCode == 0:
            "Git: staged all changes" else: "Git stage failed: " & outcome.output.strip
          refreshEditorSyntax()
    of "git unstage all":
      when defined(macosx):
        let repository = gitRepositoryForDocument(document)
        if repository == nil:
          editorViewState.statusMessage = "Git repository not found"
        else:
          let outcome = repository.unstageAll()
          editorViewState.statusMessage = if outcome.exitCode == 0:
            "Git: unstaged all changes" else: "Git unstage failed: " & outcome.output.strip
          refreshEditorSyntax()
    of "__git_stage_hunk__", "__git_unstage_hunk__":
      when defined(macosx):
        let repository = gitRepositoryForDocument(document)
        let relative = gitRelativePathForDocument(document, repository)
        if repository == nil or document == nil or relative.len == 0:
          editorViewState.statusMessage = "Git repository not found"
        else:
          let line = document[].buffer.lineColumn(editorViewState.cursor).line
          let hunks = repository.diffHunks(relative,
            staged = dispatchCommand == "__git_unstage_hunk__")
          var hunkIndex = -1
          for index, hunk in hunks:
            let firstLine = max(0, hunk.newStart - 1)
            let lineCount = max(1, hunk.newCount)
            if line >= firstLine and line < firstLine + lineCount:
              hunkIndex = index
              break
          if hunkIndex < 0:
            editorViewState.statusMessage = "Git: no hunk at cursor"
          else:
            let outcome = if dispatchCommand == "__git_stage_hunk__":
              repository.stageHunk(relative, hunkIndex)
            else:
              repository.unstageHunk(relative, hunkIndex)
            editorViewState.statusMessage = if outcome.exitCode == 0:
              (if dispatchCommand == "__git_stage_hunk__":
                "Git: staged hunk" else: "Git: unstaged hunk")
              else: "Git hunk operation failed: " & outcome.output.strip
            refreshEditorSyntax()
    of "git log":
      when defined(macosx):
        let repository = gitRepositoryForDocument(document)
        if repository == nil:
          editorViewState.statusMessage = "Git repository not found"
        else:
          let commits = repository.log(5)
          if commits.len == 0:
            editorViewState.statusMessage = "Git log: no commits"
          else:
            editorViewState.statusMessage = "Git log: " & commits[0].subject
    of "git blame":
      when defined(macosx):
        let repository = gitRepositoryForDocument(document)
        let relative = gitRelativePathForDocument(document, repository)
        if repository == nil or relative.len == 0:
          editorViewState.statusMessage = "Git repository not found"
        else:
          let location = document[].buffer.lineColumn(editorViewState.cursor)
          let blameLines = repository.blame(relative)
          if location.line < blameLines.len:
            let entry = blameLines[location.line]
            editorViewState.statusMessage = "Blame: " & entry.author & " — " & entry.summary
          else:
            editorViewState.statusMessage = "Git blame unavailable for this line"
    of "__git_commit__":
      when defined(macosx):
        let repository = gitRepositoryForDocument(document)
        let message = if rawCommand.len > 11: rawCommand[11 .. ^1].strip else: ""
        if repository == nil:
          editorViewState.statusMessage = "Git repository not found"
        elif message.len == 0:
          editorViewState.statusMessage = "Git commit requires a message"
        else:
          let outcome = repository.commit(message)
          editorViewState.statusMessage = if outcome.exitCode == 0:
            "Git: committed" else: "Git commit failed: " & outcome.output.strip
          refreshEditorSyntax()
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
          let outcome = repository.checkout(source, [relative])
          if outcome.exitCode == 0:
            discard editorSession.reloadActiveDocument(editorViewState)
            resetImeState()
            refreshEditorSyntax()
            editorViewState.statusMessage = "Git: checked out " & source
          else:
            editorViewState.statusMessage = "Git checkout failed: " & outcome.output.strip
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
      discard activeWorkspace.renameEntryAt(oldLocation.root, oldLocation.relative, newLocation.relative)
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
    when defined(macosx): platformSetEditorComposition("".cstring)
  elif name == "moveLeft" and document != nil:
    editorViewState.moveCursor(previousBoundary(document[].buffer.toString(), editorViewState.cursor))
    syncEditorCursor()
  elif name == "selectLeft" and document != nil:
    editorViewState.moveCursor(previousBoundary(document[].buffer.toString(), editorViewState.cursor), selecting = true)
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
    editorViewState.moveCursor(nextBoundary(document[].buffer.toString(), editorViewState.cursor), selecting = true)
    syncEditorCursor()
  elif name == "moveWordLeft" and document != nil:
    editorViewState.moveCursor(previousWordBoundary(document[].buffer.toString(), editorViewState.cursor))
    syncEditorCursor()
  elif name == "selectWordLeft" and document != nil:
    editorViewState.moveCursor(previousWordBoundary(document[].buffer.toString(), editorViewState.cursor), selecting = true)
    syncEditorCursor()
  elif name == "moveWordRight" and document != nil:
    editorViewState.moveCursor(nextWordBoundary(document[].buffer.toString(), editorViewState.cursor))
    syncEditorCursor()
  elif name == "selectWordRight" and document != nil:
    editorViewState.moveCursor(nextWordBoundary(document[].buffer.toString(), editorViewState.cursor), selecting = true)
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
    setupShortcutRegistry()
    restoreSession()
    syncRecentFiles()
    setupDemoUi()
    let initialRoot = if editorSession.workspaceRoots.len > 0:
      editorSession.workspaceRoots[0]
    else: getCurrentDir()
    openActiveWorkspace(if dirExists(initialRoot): initialRoot else: getCurrentDir())
    if editorSession.workspaceRoots.len > 1:
      for root in editorSession.workspaceRoots[1 .. ^1]:
        if dirExists(root): activeWorkspace.addRoot(root)
      activeWorkspace.startWatching()
      refreshWorkspacePreview()
    let lspCommand = getEnv("NIMCULUS_LSP_COMMAND", "")
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
  discard platformRun()
