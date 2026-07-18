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

var demoTree = newUiTree()
var demoButton = NodeId(0)

proc setupDemoUi() =
  demoTree = newUiTree()
  let root = demoTree.addNode()
  let button = makeControl(demoTree, root, ControlKind.button, "Nimculus", focusable = true)
  let split = makeControl(demoTree, root, ControlKind.splitPane, "Editor split")
  let scroll = makeControl(demoTree, root, ControlKind.scrollView, "Editor scroll")
  demoButton = button.node
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
  let splitBar = Rect(origin: Point(x: px(margin * 2 + editorWidth * 0.5), y: px(128)),
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
  paint.drawSelection(Rect(origin: Point(x: px(72), y: px(145)),
    size: Size(width: px(220), height: px(24))))
  paint.pushClip(editor)
  paint.drawRectangle(editor)
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
      radius: cfloat(float32(command.radius)))
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

var imeState = newImeState()
var editorSession: EditorSession
var editorViewState = newEditorView()
var syntaxState: EditorSyntaxState
var activeWorkspace: Workspace
var workspaceSearchJob: SearchJob
var workspaceSearchQuery = ""
var workspaceSearchResults: seq[SearchResult]
var workspaceSearchCancelled = false
var workspacePreviewEntries: seq[WorkspaceEntry]
var externalAlertShown = false
var editorPointerDragging = false
var sessionFilePath = ""
var recoveryFilePath = ""
var persistenceTick = 0
var suppressRecoveryWrite = false

proc activeDocument(): ptr FileDocument
proc refreshWorkspacePreview()

proc setupPersistencePaths() =
  let directory = getHomeDir() / "Library" / "Application Support" / "Nimculus"
  if not dirExists(directory): createDir(directory)
  sessionFilePath = directory / "session.json"
  recoveryFilePath = directory / "active.recovery"

proc persistSession() =
  if sessionFilePath.len == 0: return
  try:
    if activeWorkspace != nil: editorSession.workspaceRoots = activeWorkspace.rootPaths
    saveSession(editorSession, sessionFilePath)
    let document = activeDocument()
    if not suppressRecoveryWrite and document != nil and document[].buffer.isDirty:
      writeRecovery(document[], recoveryFilePath)
    elif fileExists(recoveryFilePath):
      removeFile(recoveryFilePath)
    suppressRecoveryWrite = false
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
      editorViewState = newEditorView()
      editorViewState.statusMessage = "Recovered unsaved document"
    except CatchableError:
      discard

proc openActiveWorkspace(path: string) =
  when defined(macosx):
    if activeWorkspace != nil: activeWorkspace.stopWatching()
    activeWorkspace = openWorkspace(path)
    activeWorkspace.startWatching()
    workspaceSearchQuery = ""
    workspaceSearchResults.setLen(0)
    workspaceSearchCancelled = false
    refreshWorkspacePreview()

proc refreshWorkspacePreview() =
  when defined(macosx):
    if activeWorkspace == nil: return
    workspacePreviewEntries.setLen(0)
    var lines = @["Workspace: " & activeWorkspace.root]
    for rootIndex, root in activeWorkspace.rootPaths:
      if rootIndex > 0:
        if lines.len >= 12: break
        lines.add("Root: " & root)
        workspacePreviewEntries.add(WorkspaceEntry(path: root, kind: WorkspaceFileKind.directory))
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
    platformSetEditorText(lines.join("\n").cstring)

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
    platformSetEditorText(lines.join("\n").cstring)

proc showWorkspaceSearch(query: string) =
  when defined(macosx):
    if workspaceSearchJob != nil: workspaceSearchJob.cancelSearch()
    if activeWorkspace == nil or query.len == 0: return
    workspaceSearchQuery = query
    workspaceSearchResults.setLen(0)
    workspaceSearchCancelled = false
    workspaceSearchJob = activeWorkspace.startSearch(query)
    renderWorkspaceSearch()

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
    if workspaceSearchJob == nil:
      if changed.len > 0 and document == nil: refreshWorkspacePreview()
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
    let location = if document == nil: (line: 0, column: 0) else:
      document[].buffer.lineColumn(editorViewState.cursor)
    if document != nil:
      let lastVisibleLine = max(0, document[].buffer.lineStarts.len - 12)
      if location.line < editorViewState.scrollLine:
        editorViewState.scrollLine = location.line
      elif location.line >= editorViewState.scrollLine + 12:
        editorViewState.scrollLine = min(lastVisibleLine, location.line - 11)
    let visibleLine = max(0, location.line - editorViewState.scrollLine)
    platformSetEditorScrollLine(uint32(max(0, editorViewState.scrollLine)))
    platformSetEditorCursor(cdouble(8 + location.column * 8), cdouble(12 + visibleLine * 18))
    let selection = if document == nil: (startByte: 0, endByte: 0) else:
      editorViewState.selectedRange()
    platformSetEditorSelection(uint32(selection.startByte), uint32(selection.endByte))
    platformSetEditorDirty(document != nil and document[].buffer.isDirty)

when defined(macosx):
  proc editorOffsetAtPoint(document: ptr FileDocument, x, y: cdouble): int =
    if document == nil: return 0
    var metrics: PlatformMetrics
    platformGetMetrics(addr metrics)
    let viewHeight = if metrics.heightPoints > 0: metrics.heightPoints else: 640'u32
    let top = float32(viewHeight) - float32(y)
    let line = editorViewState.scrollLine + max(0, int(floor((top - 4.0'f32) / 18.0'f32)))
    let column = max(0, int(floor((float32(x) - 8.0'f32) / 8.0'f32)))
    document[].buffer.byteOffsetAtLineColumn(line, column)

proc refreshEditorSyntax() =
  let document = activeDocument()
  if document == nil: return
  var grammar: GrammarKind
  try: grammar = grammarForPath(document[].path)
  except ValueError: return
  if syntaxState == nil or syntaxState.grammar != grammar:
    if syntaxState != nil: syntaxState.close()
    syntaxState = newEditorSyntax(document[].path, document[].buffer.toString())
  elif syntaxState != nil:
    syntaxState.update(document[].buffer.toString())
  when defined(macosx):
    let highlights = if syntaxState == nil: @[] else:
      let firstLine = min(editorViewState.scrollLine, document[].buffer.lineStarts.high)
      let firstByte = document[].buffer.lineStarts[firstLine]
      let requestedLastLine = firstLine + 12
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
    platformSetEditorText(document[].buffer.toString().cstring)

proc receiveNativeText(text: cstring, composing: bool) {.cdecl.} =
  let value = if text == nil: "" else: $text
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

proc receiveNativeFile(path: cstring, saving: bool) {.cdecl.} =
  if path == nil or ($path).len == 0: return
  let filePath = $path
  if workspaceSearchJob != nil:
    workspaceSearchJob.cancelSearch()
    workspaceSearchJob = nil
  if saving:
    let document = activeDocument()
    if document != nil:
      document[].save(filePath)
      externalAlertShown = false
      syncEditorCursor()
  else:
    if dirExists(filePath):
      openActiveWorkspace(filePath)
      return
    try:
      workspacePreviewEntries.setLen(0)
      editorSession.addTab(openDocument(filePath))
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
  proc openWorkspaceEntryAtPoint(y: cdouble) =
    if activeWorkspace == nil or workspacePreviewEntries.len == 0: return
    var metrics: PlatformMetrics
    platformGetMetrics(addr metrics)
    let viewHeight = if metrics.heightPoints > 0: metrics.heightPoints else: 640'u32
    let top = float32(viewHeight) - float32(y)
    let line = int(floor((top - 4.0'f32) / 18.0'f32))
    let entryIndex = line - 1
    if entryIndex < 0 or entryIndex >= workspacePreviewEntries.len: return
    let entry = workspacePreviewEntries[entryIndex]
    if entry.kind == WorkspaceFileKind.directory:
      openActiveWorkspace(entry.path)
    else:
      receiveNativeFile(entry.path.cstring, false)

proc previousBoundary(text: string, offset: int): int =
  var resultOffset = max(0, min(offset, text.len)) - 1
  while resultOffset > 0 and (ord(text[resultOffset]) and 0xC0) == 0x80: dec resultOffset
  max(0, resultOffset)

proc nextBoundary(text: string, offset: int): int =
  var resultOffset = max(0, min(offset, text.len))
  if resultOffset < text.len:
    inc resultOffset
    while resultOffset < text.len and (ord(text[resultOffset]) and 0xC0) == 0x80: inc resultOffset
  resultOffset

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
  elif name.startsWith("workspaceAddRoot:") and activeWorkspace != nil:
    let path = workspaceRelativePayload(name, "workspaceAddRoot:")
    if path.len == 0 or not dirExists(path): return
    activeWorkspace.addRoot(path)
    activeWorkspace.startWatching()
    refreshWorkspacePreview()
  elif name == "newDocument":
    editorSession.addTab(newDocument())
    externalAlertShown = false
    editorViewState = newEditorView()
    if syntaxState != nil:
      syntaxState.close()
      syntaxState = nil
    when defined(macosx):
      platformSetEditorHighlights(nil, 0)
      platformSetEditorComposition("".cstring)
      platformSetEditorText("".cstring)
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
    let command = name[15 .. ^1].strip.toLowerAscii
    editorViewState.closeCommandPalette()
    case command
    of "new": receiveNativeCommand("newDocument".cstring)
    of "save":
      when defined(macosx):
        let path = chooseSaveFile()
        if path != nil and ($path).len > 0: receiveNativeFile(path, true)
    of "find":
      when defined(macosx):
        platformShowFindDocument()
    of "workspace search":
      when defined(macosx):
        platformShowWorkspaceSearch()
    of "cancel search": cancelWorkspaceSearch()
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
      editorSession.tabs[editorSession.activeTab].document = openDocument(document[].path)
      editorViewState = newEditorView()
      if syntaxState != nil:
        syntaxState.close()
        syntaxState = nil
      externalAlertShown = false
      syncEditorCursor()
      refreshEditorSyntax()
    except CatchableError:
      externalAlertShown = false
  elif name == "keepExternal" and document != nil:
    if fileExists(document[].path):
      let info = getFileInfo(document[].path)
      document[].externalSize = info.size
      document[].externalModified = info.lastWriteTime
    externalAlertShown = false
  elif name.startsWith("workspaceSearch:"):
    showWorkspaceSearch(name[16 .. ^1])
  elif name.startsWith("workspaceCreateFile:") and activeWorkspace != nil:
    let relative = workspaceRelativePayload(name, "workspaceCreateFile:")
    if relative.len == 0: return
    try:
      discard activeWorkspace.createFile(relative)
      refreshWorkspaceAfterMutation("Created " & relative)
    except CatchableError as error:
      editorViewState.statusMessage = "Create failed: " & error.msg
  elif name.startsWith("workspaceCreateDirectory:") and activeWorkspace != nil:
    let relative = workspaceRelativePayload(name, "workspaceCreateDirectory:")
    if relative.len == 0: return
    try:
      discard activeWorkspace.createDirectory(relative)
      refreshWorkspaceAfterMutation("Created " & relative)
    except CatchableError as error:
      editorViewState.statusMessage = "Create failed: " & error.msg
  elif name.startsWith("workspaceDelete:") and activeWorkspace != nil:
    let relative = workspaceRelativePayload(name, "workspaceDelete:")
    if relative.len == 0: return
    try:
      activeWorkspace.deleteEntry(relative)
      refreshWorkspaceAfterMutation("Deleted " & relative)
    except CatchableError as error:
      editorViewState.statusMessage = "Delete failed: " & error.msg
  elif name.startsWith("workspaceRename:") and activeWorkspace != nil:
    let payload = workspaceRelativePayload(name, "workspaceRename:")
    let separator = payload.find('\x1f')
    if separator <= 0 or separator + 1 >= payload.len: return
    let oldRelative = payload[0 ..< separator].strip
    let newRelative = payload[separator + 1 .. ^1].strip
    try:
      discard activeWorkspace.renameEntry(oldRelative, newRelative)
      refreshWorkspaceAfterMutation("Renamed " & oldRelative & " to " & newRelative)
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
    clipboardSet(document[].buffer.substring(selected.startByte, selected.endByte).cstring)
  elif name == "cut" and document != nil:
    let selected = editorViewState.selectedRange()
    clipboardSet(document[].buffer.substring(selected.startByte, selected.endByte).cstring)
    if selected.endByte > selected.startByte:
      document[].buffer.edit(Edit(startByte: selected.startByte, endByte: selected.endByte, text: ""))
      editorViewState.moveCursor(selected.startByte)
      refreshEditorSyntax()
      syncEditorCursor()
  elif name == "paste":
    receiveNativeText(clipboardGet(), false)
  elif name == "selectAll" and document != nil:
    editorViewState.selection.anchor = 0
    editorViewState.selection.active = document[].buffer.toString().len
    syncEditorCursor()

proc receiveNativeInput(event: ptr NimculusInputEvent) {.cdecl.} =
  if event.isNil: return
  let kind = case event.kind
    of 1'u32: pointerDown
    of 2'u32: pointerUp
    of 5'u32: pointerMove
    of 10'u32: keyDown
    of 11'u32: keyUp
    of 22'u32: scroll
    else: command
  let point = Point(x: px(float32(event.x)), y: px(float32(event.y)))
  let hit = demoTree.hitTest(point)
  let target = if kind == keyDown or kind == keyUp or kind == command:
    if demoTree.focused != NodeId(0): demoTree.focused else: hit
  else: hit
  when defined(macosx):
    let document = activeDocument()
    if document != nil and kind == scroll:
      let delta = if event.deltaY > 0: -3 elif event.deltaY < 0: 3 else: 0
      let maxScroll = max(0, document[].buffer.lineStarts.len - 12)
      editorViewState.scrollLine = max(0, min(maxScroll, editorViewState.scrollLine + delta))
      syncEditorCursor()
      refreshEditorSyntax()
    if document == nil and kind == pointerDown:
      openWorkspaceEntryAtPoint(event.y)
    if document != nil and kind in {pointerDown, pointerMove, pointerUp}:
      let offset = editorOffsetAtPoint(document, event.x, event.y)
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
  if kind == pointerMove:
    for node in demoTree.nodes:
      if node.state == hovered and node.id != hit: demoTree.setState(node.id, normal)
    if hit != NodeId(0): demoTree.setState(hit, hovered)
  elif kind == pointerDown and hit != NodeId(0):
    if demoTree.node(hit).focusable: discard demoTree.focus(hit)
    demoTree.setState(hit, active)
  elif kind == pointerUp and hit != NodeId(0):
    demoTree.setState(hit, if demoTree.focused == hit: focused else: normal)
  var uiEvent = UiEvent(kind: kind, target: target,
    position: point, keyCode: event.keyCode, modifiers: event.modifiers,
    deltaX: float32(event.deltaX), deltaY: float32(event.deltaY))
  discard demoTree.dispatch(uiEvent)

when isMainModule:
  when defined(macosx):
    setupPersistencePaths()
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
    platformSetTextCallback(receiveNativeText)
    platformSetInputCallback(receiveNativeInput)
    platformSetFileCallback(receiveNativeFile)
    platformSetCommandCallback(receiveNativeCommand)
    if activeDocument() != nil:
      syncEditorCursor()
      refreshEditorSyntax()
    else:
      persistSession()
  discard platformRun()
