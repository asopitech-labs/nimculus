import std/os
import std/times
import std/strutils
import std/sequtils
import nimculus/editor_buffer
import nimculus/atomic_io
import nimculus/editor_view

type
  LineEnding* = enum lf, crlf
  FileDocument* = object
    path*: string
    buffer*: PieceTable
    lineEnding*: LineEnding
    ## Presence is tracked separately from size because an empty file can be
    ## deleted without changing its byte count.
    externalExists*: bool
    ## The filesystem identity distinguishes an atomic replacement from an
    ## in-place edit, even when size and timestamp happen to be unchanged.
    externalIdentity*: string
    externalSize*: int64
    externalModified*: Time
  SearchMatch* = object
    startByte*, endByte*: int
  EditorTab* = object
    document*: FileDocument
    title*: string
    ## Per-tab transient editor state, matching Zed's item-owned selections
    ## and scroll position rather than sharing one pane state across buffers.
    view*: EditorViewState
  SplitDirection* = enum splitVertical, splitHorizontal
  EditorSession* = object
    tabs*: seq[EditorTab]
    activeTab*: int
    split*: bool
    splitDirection*: SplitDirection
    recentFiles*: seq[string]
    workspaceRoots*: seq[string]

proc fileStamp(path: string): tuple[identity: string, size: int64, modified: Time] =
  let info = getFileInfo(path)
  (identity: $info.id.device & ":" & $info.id.file,
   size: info.size,
   modified: info.lastWriteTime)

proc canonicalOpenPath*(path: string): string =
  ## Existing paths may arrive through `/tmp`, a symlink, Finder, URL events,
  ## or a shell. Follow symlinks so one on-disk document has one tab identity.
  if path.len == 0: return ""
  try:
    result = expandFilename(path)
  except OSError:
    # `expandFilename` cannot resolve a deleted leaf. Resolve its existing
    # parent instead so a recovery entry under `/tmp` keeps the same identity
    # as the live document under macOS's `/private/tmp` backing directory.
    let leaf = extractFilename(path)
    try:
      result = expandFilename(parentDir(path)) / leaf
    except OSError:
      result = absolutePath(path)

proc openDocument*(path: string): FileDocument =
  let identityPath = canonicalOpenPath(path)
  let raw = readFile(identityPath)
  result.path = identityPath
  result.lineEnding = if raw.contains("\r\n"): crlf else: lf
  result.buffer = initPieceTable(raw.replace("\r\n", "\n"))
  let stamp = fileStamp(identityPath)
  result.externalExists = true
  result.externalIdentity = stamp.identity
  result.externalSize = stamp.size
  result.externalModified = stamp.modified
  result.buffer.markSaved()

proc newDocument*(): FileDocument =
  result.buffer = initPieceTable()
  result.buffer.markSaved()

proc startupOpenPaths*(arguments: openArray[string]): seq[string] =
  ## Resolve positional startup paths before the native event loop begins.
  ## macOS LaunchServices delivers Finder opens later through AppDelegate, but
  ## `Nimculus path/to/file` must use the same file callback path and must not
  ## treat editor flags as documents. `--` permits a path beginning with '-'.
  var positionalOnly = false
  for argument in arguments:
    if not positionalOnly and argument == "--":
      positionalOnly = true
      continue
    if not positionalOnly and argument.startsWith('-'): continue
    if argument.len == 0: continue
    let path = canonicalOpenPath(argument)
    if (fileExists(path) or dirExists(path)) and path notin result:
      result.add(path)

proc save*(document: var FileDocument, path = "") =
  let targetPath = if path.len > 0: path else: document.path
  if targetPath.len == 0: raise newException(IOError, "document has no path")
  var content = document.buffer.toString()
  if document.lineEnding == crlf: content = content.replace("\n", "\r\n")
  atomicWriteFile(targetPath, content)
  # Keep a canonical path identity after Save As so later Finder / URL / CLI
  # opens select this tab rather than creating a second view of the file.
  document.path = canonicalOpenPath(targetPath)
  let stamp = fileStamp(document.path)
  document.externalExists = true
  document.externalIdentity = stamp.identity
  document.externalSize = stamp.size
  document.externalModified = stamp.modified
  document.buffer.markSaved()

proc externallyChanged*(document: FileDocument): bool =
  if document.path.len == 0: return false
  if not fileExists(document.path): return document.externalExists
  let stamp = fileStamp(document.path)
  stamp.identity != document.externalIdentity or
    stamp.size != document.externalSize or
    stamp.modified != document.externalModified

proc acceptExternalState*(document: var FileDocument) =
  ## Record the current disk state after the user chooses Keep Editing.
  ## Deletion is a real state, not an absent stamp; this mirrors Zed's
  ## DiskState::Deleted and prevents the same alert from firing every tick.
  if document.path.len == 0: return
  if not fileExists(document.path):
    document.externalExists = false
    return
  let stamp = fileStamp(document.path)
  document.externalExists = true
  document.externalIdentity = stamp.identity
  document.externalSize = stamp.size
  document.externalModified = stamp.modified

proc search*(document: FileDocument, query: string, caseSensitive = true): seq[SearchMatch] =
  if query.len == 0: return
  let haystack = if caseSensitive: document.buffer.toString() else: document.buffer.toString().toLowerAscii()
  let needle = if caseSensitive: query else: query.toLowerAscii()
  var offset = 0
  while true:
    let found = haystack.find(needle, offset)
    if found < 0: break
    result.add(SearchMatch(startByte: found, endByte: found + needle.len))
    offset = found + max(1, needle.len)

proc replaceAll*(document: var FileDocument, query, replacement: string,
                 caseSensitive = true): int =
  let matches = document.search(query, caseSensitive)
  var edits: seq[Edit]
  for match in matches: edits.add(Edit(startByte: match.startByte, endByte: match.endByte, text: replacement))
  if edits.len > 0: document.buffer.applyEdits(edits)
  matches.len

proc addTab*(session: var EditorSession, document: FileDocument) =
  let title = if document.path.len > 0: splitFile(document.path).name else: "Untitled"
  session.tabs.add(EditorTab(document: document, title: title, view: newEditorView()))
  session.activeTab = session.tabs.high

proc tabIndexForPath*(session: EditorSession, path: string): int =
  ## File-open events may repeat an already-visible absolute path. Keep one
  ## buffer and activate it instead of creating divergent tabs for one file.
  for index, tab in session.tabs:
    if tab.document.path == path: return index
  -1

proc tabIndexForSaveTarget*(session: EditorSession, path: string): int =
  ## Save As must not make two independently editable tabs represent one
  ## document. Normalize the prospective destination before comparing it to
  ## current tab identities; this also handles symlink aliases.
  session.tabIndexForPath(canonicalOpenPath(path))

proc saveActiveView*(session: var EditorSession, view: EditorViewState) =
  if session.activeTab >= 0 and session.activeTab < session.tabs.len:
    session.tabs[session.activeTab].view = view

proc loadActiveView*(session: EditorSession, view: var EditorViewState) =
  if session.activeTab >= 0 and session.activeTab < session.tabs.len:
    view = session.tabs[session.activeTab].view

proc switchTab*(session: var EditorSession, delta: int): bool =
  ## Move around the existing tabs without mutating their buffers.
  if session.tabs.len < 2: return false
  let current = max(0, min(session.activeTab, session.tabs.high))
  let count = session.tabs.len
  session.activeTab = ((current + delta) mod count + count) mod count
  true

proc switchTab*(session: var EditorSession, view: var EditorViewState, delta: int): bool =
  ## Activate another item while preserving each tab's selection and viewport.
  session.saveActiveView(view)
  if not session.switchTab(delta): return false
  session.loadActiveView(view)
  true

proc closeActiveTab*(session: var EditorSession, forceDirty = false): bool =
  if session.tabs.len == 0: return false
  session.activeTab = max(0, min(session.activeTab, session.tabs.high))
  if session.tabs[session.activeTab].document.buffer.isDirty and not forceDirty: return false
  session.tabs.delete(session.activeTab)
  session.activeTab = min(session.activeTab, session.tabs.high)
  true

proc hasDirtyTabs*(session: EditorSession): bool =
  for tab in session.tabs:
    if tab.document.buffer.isDirty: return true
  false

proc reloadActiveDocument*(session: var EditorSession, view: var EditorViewState): bool =
  ## Reload the active named document while preserving the item's view state.
  ## The file is opened before replacing the tab, so a failed read leaves the
  ## current buffer untouched.
  if session.activeTab < 0 or session.activeTab >= session.tabs.len: return false
  let path = session.tabs[session.activeTab].document.path
  if path.len == 0: return false
  let reloaded = openDocument(path)
  session.tabs[session.activeTab].document = reloaded
  view.clampSelectionToText(reloaded.buffer.toString())
  view.scrollLine = min(max(0, view.scrollLine), max(0, reloaded.buffer.lineStarts.high))
  true

proc splitEditor*(session: var EditorSession, direction: SplitDirection) =
  session.split = true
  session.splitDirection = direction

proc recordRecent*(session: var EditorSession, path: string) =
  session.recentFiles = session.recentFiles.filterIt(it != path)
  session.recentFiles.insert(path, 0)
