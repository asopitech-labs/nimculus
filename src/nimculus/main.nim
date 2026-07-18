import std/algorithm
import std/os
import std/strutils
import std/tables
import nimnui/nimnui
import nimculus/editor_app
import nimculus/editor_buffer
import nimculus/editor_view
import nimculus/editor_syntax
import nimculus/tree_sitter
import nimculus/workspace

var demoTree = newUiTree()
var demoButton = NodeId(0)

proc setupDemoUi() =
  demoTree = newUiTree()
  let root = demoTree.addNode()
  let button = makeControl(demoTree, root, ControlKind.button, "Nimculus", focusable = true)
  demoButton = button.node
  let spec = LayoutSpec(direction: row,
    size: Size(width: px(0), height: px(0)),
    minSize: Size(width: px(0), height: px(0)),
    maxSize: Size(width: px(10000), height: px(10000)),
    padding: EdgeInsets(top: px(20), right: px(20), bottom: px(20), left: px(20)),
    gap: px(8), alignment: alignCenter,
    viewport: Rect(size: Size(width: px(960), height: px(640))))
  demoTree.layoutNode(root, Rect(size: Size(width: px(960), height: px(640))), spec)
  let bounds = demoTree.node(button.node).bounds
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
var externalAlertShown = false

proc activeDocument(): ptr FileDocument

proc refreshWorkspacePreview() =
  when defined(macosx):
    if activeWorkspace == nil: return
    var lines = @["Workspace: " & activeWorkspace.root]
    var children = activeWorkspace.listChildren()
    children.sort(proc(a, b: WorkspaceEntry): int = cmp(a.relativePath, b.relativePath))
    for entry in children:
      if lines.len >= 12: break
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

proc renderWorkspaceSearch() =
  when defined(macosx):
    if activeWorkspace == nil or workspaceSearchQuery.len == 0: return
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
    let document = activeDocument()
    if document != nil and document[].path.len > 0 and document[].externallyChanged() and not externalAlertShown:
      externalAlertShown = true
      platformShowExternalChange(document[].path.cstring)
    if workspaceSearchJob == nil: return
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
    platformSetEditorCursor(cdouble(8 + location.column * 8), cdouble(12 + location.line * 18))
    let selection = if document == nil: (startByte: 0, endByte: 0) else:
      editorViewState.selectedRange()
    platformSetEditorSelection(uint32(selection.startByte), uint32(selection.endByte))

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
      syntaxState.visibleHighlights(0, uint32(min(document[].buffer.toString().len, 4096)))
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
  else:
    if dirExists(filePath):
      activeWorkspace = openWorkspace(filePath)
      refreshWorkspacePreview()
      return
    try:
      editorSession.addTab(openDocument(filePath))
      let document = activeDocument()
      if document != nil: editorViewState.moveCursor(0)
      syncEditorCursor()
      refreshEditorSyntax()
    except CatchableError:
      discard

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
  elif name == "cancel":
    imeState.composition.setLen(0)
  elif name == "moveLeft" and document != nil:
    editorViewState.moveCursor(previousBoundary(document[].buffer.toString(), editorViewState.cursor))
    syncEditorCursor()
  elif name == "moveRight" and document != nil:
    editorViewState.moveCursor(nextBoundary(document[].buffer.toString(), editorViewState.cursor))
    syncEditorCursor()
  elif name in ["deleteBackward", "deleteForward"] and document != nil:
    let selected = editorViewState.selectedRange()
    var start = selected.startByte
    var finish = selected.endByte
    if start == finish:
      if name == "deleteBackward": start = previousBoundary(document[].buffer.toString(), start)
      else: finish = nextBoundary(document[].buffer.toString(), finish)
    if finish > start:
      document[].buffer.edit(Edit(startByte: start, endByte: finish, text: ""))
      editorViewState.moveCursor(start)
      syncEditorCursor()
      refreshEditorSyntax()
  elif name == "undo" and document != nil:
    discard document[].buffer.undo()
  elif name == "redo" and document != nil:
    discard document[].buffer.redo()
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
  var uiEvent = UiEvent(kind: kind, target: demoButton,
    position: Point(x: px(float32(event.x)), y: px(float32(event.y))),
    keyCode: event.keyCode)
  discard demoTree.dispatch(uiEvent)

when isMainModule:
  when defined(macosx):
    setupDemoUi()
    activeWorkspace = openWorkspace(getCurrentDir())
    refreshWorkspacePreview()
    platformSetTextCallback(receiveNativeText)
    platformSetInputCallback(receiveNativeInput)
    platformSetFileCallback(receiveNativeFile)
    platformSetCommandCallback(receiveNativeCommand)
    platformSetUiRectangle(360, 260, 240, 120)
  discard platformRun()
