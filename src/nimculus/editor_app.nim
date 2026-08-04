import std/os
import std/times
import std/strutils
import std/sequtils
import nimculus/editor_buffer
import nimculus/atomic_io
import nimculus/editor_view
import nimculus/search

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
  SearchMatch* = search.SearchMatch
  EditorTab* = object
    document*: FileDocument
    title*: string
    ## Pinned tabs retain their document identity and stay before ordinary
    ## tabs. The session owns this state so it survives a relaunch and both
    ## split panes see the same ordering.
    pinned*: bool
    ## Per-tab transient editor state, matching Zed's item-owned selections
    ## and scroll position rather than sharing one pane state across buffers.
    view*: EditorViewState
    ## The first split duplicates the same item into a second viewport.  Its
    ## state belongs to the item too, otherwise switching tabs leaks the last
    ## document's secondary cursor and scroll position into the next one.
    secondaryView*: EditorViewState
  ClosedEditorTab* = object
    ## A bounded, path-backed record. Do not retain PieceTable contents after
    ## closing a file: a large closed document must release its memory, and a
    ## reopen should reflect the current on-disk file.
    path*, title*: string
    pinned*: bool
    view*, secondaryView*: EditorViewState
  SplitDirection* = enum splitVertical, splitHorizontal
  EditorSession* = object
    tabs*: seq[EditorTab]
    closedTabs*: seq[ClosedEditorTab]
    activeTab*: int
    split*: bool
    splitDirection*: SplitDirection
    ## The divider is session state, not transient UI state.  Keeping it here
    ## makes resize and relaunch preserve the user's pane allocation.
    splitRatio*: float32
    ## A cloned split starts on the same document, but owns its own cursor,
    ## selection, viewport, and display preferences.
    secondaryView*: EditorViewState
    ## The second Pane can select a different shared document. Persist that
    ## item identity independently of `activeTab`, which belongs to the
    ## primary Pane.
    splitSecondaryTab*: int
    splitActivePane*: int
    recentFiles*: seq[string]
    workspaceRoots*: seq[string]
    ## Persisted workspace composition. The actual Dock/Panes remain in
    ## workspace_ui; these scalar fields keep session serialization free of
    ## platform and renderer types.
    workspaceLeftDockOpen*, workspaceBottomDockOpen*: bool
    workspaceLeftDockSize*, workspaceBottomDockSize*: float32
    workspaceLeftPanel*, workspaceBottomPanel*: int

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

proc search*(document: FileDocument, query: string, caseSensitive = true,
             wholeWord = false, regex = false): seq[SearchMatch] =
  result = findMatches(document.buffer.toString(), query, SearchOptions(
    caseSensitive: caseSensitive, wholeWord: wholeWord, regex: regex))

proc search*(document: FileDocument, query: string,
             options: SearchOptions): seq[SearchMatch] =
  findMatches(document.buffer.toString(), query, options)

proc replaceAll*(document: var FileDocument, query, replacement: string,
                 caseSensitive = true, wholeWord = false,
                 regex = false): int =
  let matches = document.search(query, caseSensitive, wholeWord, regex)
  var edits: seq[Edit]
  for match in matches: edits.add(Edit(startByte: match.startByte, endByte: match.endByte,
      text: replacement))
  if edits.len > 0: document.buffer.applyEdits(edits)
  matches.len

proc replaceAll*(document: var FileDocument, query, replacement: string,
                 options: SearchOptions): int =
  let matches = document.search(query, options)
  var edits: seq[Edit]
  for match in matches: edits.add(Edit(startByte: match.startByte, endByte: match.endByte,
      text: replacement))
  if edits.len > 0: document.buffer.applyEdits(edits)
  matches.len

proc addTab*(session: var EditorSession, document: FileDocument) =
  let title = if document.path.len > 0: splitFile(document.path).name else: "Untitled"
  let view = newEditorView()
  session.tabs.add(EditorTab(document: document, title: title, view: view,
    secondaryView: view))
  session.activeTab = session.tabs.high

proc addBackgroundTab*(session: var EditorSession, document: FileDocument): int =
  ## A secondary Pane can display a newly opened document without changing the
  ## primary session activation. The document remains in the shared tab store;
  ## only the caller's Pane selection decides where it becomes visible.
  let active = session.activeTab
  session.addTab(document)
  result = session.activeTab
  session.activeTab = active

proc visibleTabTitle(tab: EditorTab): string =
  ## A tab's persisted title is kept separate from its filesystem identity,
  ## but a named document always presents its complete filename in chrome.
  if tab.document.path.len > 0:
    let parts = splitFile(tab.document.path)
    if parts.name.len > 0:
      return parts.name & parts.ext
  if tab.title.len > 0: tab.title else: "Untitled"

proc displayTitle*(session: EditorSession, index: int): string =
  ## Titles are item labels, not stable identities. A restored set of unsaved
  ## buffers can legitimately contain several "Untitled" entries; number only
  ## duplicate labels so every visible tab remains an actionable target.
  if index < 0 or index >= session.tabs.len: return "Untitled"
  let title = visibleTabTitle(session.tabs[index])
  var total = 0
  var ordinal = 0
  for candidate, tab in session.tabs:
    if visibleTabTitle(tab) == title:
      inc total
      if candidate <= index: inc ordinal
  result = if total > 1: title & " " & $ordinal else: title

proc tabDisplayLabel*(session: EditorSession, index: int): string =
  ## Keep the stored title clean for Save As/session semantics while making
  ## pin state continuously visible in the native tab strip and tab picker.
  result = if index >= 0 and index < session.tabs.len and session.tabs[index].pinned:
    "📌 " else: ""
  result.add(session.displayTitle(index))

proc pinnedTabCount*(session: EditorSession): int =
  for tab in session.tabs:
    if tab.pinned: inc result

proc remapTabIndex(index, source, destination: int): int =
  ## Remap an index after moving one item from source to destination.
  if index == source: return destination
  if source < destination and index > source and index <= destination:
    return index - 1
  if destination < source and index >= destination and index < source:
    return index + 1
  index

proc moveTab*(session: var EditorSession, source, destination: int): bool =
  ## Move an item without losing primary/secondary pane document identity.
  if source < 0 or source >= session.tabs.len or destination < 0 or
      destination >= session.tabs.len or source == destination:
    return false
  let tab = session.tabs[source]
  session.tabs.delete(source)
  session.tabs.insert(tab, destination)
  session.activeTab = remapTabIndex(session.activeTab, source, destination)
  session.splitSecondaryTab = remapTabIndex(session.splitSecondaryTab, source, destination)
  true

proc setTabPinned*(session: var EditorSession, index: int, pinned: bool): bool =
  ## Zed keeps pinned items as a contiguous prefix. Do the same rather than
  ## merely decorating a tab: pinned items stay predictably reachable when a
  ## tab strip overflows.
  if index < 0 or index >= session.tabs.len or session.tabs[index].pinned == pinned:
    return false
  let boundary = session.pinnedTabCount()
  session.tabs[index].pinned = pinned
  let destination = if pinned: boundary else: boundary - 1
  discard session.moveTab(index, destination)
  true

proc unpinAllTabs*(session: var EditorSession): bool =
  var changed = false
  for index in 0 ..< session.tabs.len:
    if session.tabs[index].pinned:
      session.tabs[index].pinned = false
      changed = true
  changed

proc recordClosedTab(session: var EditorSession, tab: EditorTab) =
  ## Zed's reopen history is path-oriented. Untitled buffers and discarded
  ## dirty text intentionally do not enter it, which avoids resurrecting a
  ## user's explicit Don't Save choice.
  if tab.document.path.len == 0 or tab.document.buffer.isDirty: return
  session.closedTabs.add(ClosedEditorTab(path: tab.document.path, title: tab.title,
    pinned: tab.pinned, view: tab.view, secondaryView: tab.secondaryView))
  const maxClosedTabs = 32
  if session.closedTabs.len > maxClosedTabs:
    session.closedTabs.delete(0)

proc remapTabIndexForInsert(index, destination: int): int =
  if index >= destination and index >= 0: index + 1 else: index

proc reopenClosedTab*(session: var EditorSession): int =
  ## Reopen the newest viable file path. A deleted/moved path is skipped,
  ## matching Zed's path-backed closed-item history instead of restoring a
  ## stale in-memory buffer.
  while session.closedTabs.len > 0:
    let closed = session.closedTabs.pop()
    if closed.path.len == 0 or not fileExists(closed.path) or dirExists(closed.path):
      continue
    try:
      let document = openDocument(closed.path)
      let destination = if closed.pinned: session.pinnedTabCount() else: session.tabs.len
      session.activeTab = remapTabIndexForInsert(session.activeTab, destination)
      session.splitSecondaryTab = remapTabIndexForInsert(session.splitSecondaryTab, destination)
      session.tabs.insert(EditorTab(document: document, title: closed.title,
        pinned: closed.pinned, view: closed.view, secondaryView: closed.secondaryView),
        destination)
      session.activeTab = destination
      return destination
    except CatchableError:
      discard
  -1

proc tabIndexForPath*(session: EditorSession, path: string): int =
  ## Every file-bearing feature (Finder, Save As, LSP, and navigation) must
  ## identify a document the same way. Keep one buffer for symlink and macOS
  ## path aliases, rather than requiring every caller to normalize first.
  let identityPath = canonicalOpenPath(path)
  if identityPath.len == 0: return -1
  for index, tab in session.tabs:
    if tab.document.path == identityPath: return index
  -1

proc tabIndexForSaveTarget*(session: EditorSession, path: string): int =
  ## Save As must not make two independently editable tabs represent one
  ## document. Normalize the prospective destination before comparing it to
  ## current tab identities; this also handles symlink aliases.
  session.tabIndexForPath(path)

proc saveActiveView*(session: var EditorSession, view: EditorViewState) =
  if session.activeTab >= 0 and session.activeTab < session.tabs.len:
    session.tabs[session.activeTab].view = view

proc loadActiveView*(session: EditorSession, view: var EditorViewState) =
  if session.activeTab >= 0 and session.activeTab < session.tabs.len:
    view = session.tabs[session.activeTab].view

proc effectiveSplitSecondaryTab*(session: EditorSession): int

proc saveSecondaryActiveView*(session: var EditorSession, view: EditorViewState) =
  session.secondaryView = view
  let tab = session.effectiveSplitSecondaryTab()
  if tab >= 0 and tab < session.tabs.len:
    session.tabs[tab].secondaryView = view

proc loadSecondaryActiveView*(session: var EditorSession) =
  let tab = session.effectiveSplitSecondaryTab()
  if tab >= 0 and tab < session.tabs.len:
    session.secondaryView = session.tabs[tab].secondaryView

proc effectiveSplitSecondaryTab*(session: EditorSession): int =
  if session.split and session.splitSecondaryTab >= 0 and
      session.splitSecondaryTab < session.tabs.len:
    session.splitSecondaryTab
  else:
    session.activeTab

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

proc switchTab*(session: var EditorSession, view: var EditorViewState,
                secondaryView: var EditorViewState, delta: int): bool =
  ## Compatibility helper for callers that intentionally treat a split as two
  ## viewports of the newly active primary item. Workspace UI commands use
  ## pane-local selection instead and never call this overload.
  session.saveActiveView(view)
  session.saveSecondaryActiveView(secondaryView)
  if not session.switchTab(delta): return false
  if session.split: session.splitSecondaryTab = session.activeTab
  session.loadActiveView(view)
  session.loadSecondaryActiveView()
  secondaryView = session.secondaryView
  true

proc closeTabAt*(session: var EditorSession, tabIndex: int, forceDirty = false): bool =
  if tabIndex < 0 or tabIndex >= session.tabs.len: return false
  if session.tabs[tabIndex].document.buffer.isDirty and not forceDirty: return false
  session.recordClosedTab(session.tabs[tabIndex])
  session.tabs.delete(tabIndex)
  if session.activeTab > tabIndex: dec session.activeTab
  elif session.activeTab == tabIndex: session.activeTab = min(tabIndex, session.tabs.high)
  session.activeTab = min(session.activeTab, session.tabs.high)
  if session.splitSecondaryTab > tabIndex: dec session.splitSecondaryTab
  elif session.splitSecondaryTab == tabIndex:
    session.splitSecondaryTab = min(tabIndex, session.tabs.high)
  if session.tabs.len == 0: session.splitSecondaryTab = -1
  true

proc closeActiveTab*(session: var EditorSession, forceDirty = false): bool =
  if session.tabs.len == 0: return false
  session.activeTab = max(0, min(session.activeTab, session.tabs.high))
  result = session.closeTabAt(session.activeTab, forceDirty)

proc closeCleanTabsExcept*(session: var EditorSession, keepIndex: int): int =
  ## Close the clean items around the focused tab. Dirty items remain open so
  ## a bulk tab command can never discard user changes without the normal
  ## confirmation path.
  if keepIndex < 0 or keepIndex >= session.tabs.len: return 0
  for index in countdown(session.tabs.high, 0):
    if index == keepIndex: continue
    if session.closeTabAt(index): inc result

proc closeCleanTabsBefore*(session: var EditorSession, tabIndex: int): int =
  if tabIndex < 0 or tabIndex >= session.tabs.len: return 0
  for index in countdown(tabIndex - 1, 0):
    if session.closeTabAt(index): inc result

proc closeCleanTabsAfter*(session: var EditorSession, tabIndex: int): int =
  if tabIndex < 0 or tabIndex >= session.tabs.len: return 0
  for index in countdown(session.tabs.high, tabIndex + 1):
    if session.closeTabAt(index): inc result

proc closeAllCleanTabs*(session: var EditorSession): int =
  for index in countdown(session.tabs.high, 0):
    if session.closeTabAt(index): inc result

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

proc reloadCleanDocumentsUnder*(session: var EditorSession, root: string): int =
  ## Refresh clean tabs after an external operation (such as `git switch`)
  ## updates one worktree. Dirty tabs stay entirely user-owned; their on-disk
  ## counterpart may be refreshed later through normal external-change
  ## resolution. Tab-owned primary and secondary views are clamped before the
  ## caller restores the active pane state.
  let canonicalRoot = canonicalOpenPath(root)
  if canonicalRoot.len == 0: return
  let prefix = canonicalRoot & DirSep
  for index in 0 ..< session.tabs.len:
    let document = session.tabs[index].document
    if document.path.len == 0 or document.buffer.isDirty or
        not document.path.startsWith(prefix) or not fileExists(document.path):
      continue
    try:
      let reloaded = openDocument(document.path)
      session.tabs[index].document = reloaded
      session.tabs[index].view.clampSelectionToText(reloaded.buffer.toString())
      session.tabs[index].secondaryView.clampSelectionToText(reloaded.buffer.toString())
      session.tabs[index].view.scrollLine = min(
        max(0, session.tabs[index].view.scrollLine),
        max(0, reloaded.buffer.lineStarts.high))
      session.tabs[index].secondaryView.scrollLine = min(
        max(0, session.tabs[index].secondaryView.scrollLine),
        max(0, reloaded.buffer.lineStarts.high))
      inc result
    except CatchableError:
      discard

proc normalizedSplitRatio*(ratio: float32): float32 =
  ## Reserve usable space for both sides.  Zed's PaneGroup likewise constrains
  ## split geometry instead of letting a drag collapse a pane to zero.
  min(0.9'f32, max(0.1'f32, ratio))

proc splitEditor*(session: var EditorSession, direction: SplitDirection,
                  ratio = 0.5'f32) =
  session.split = true
  session.splitDirection = direction
  session.splitRatio = normalizedSplitRatio(ratio)
  if session.activeTab >= 0 and session.activeTab < session.tabs.len:
    session.splitSecondaryTab = session.activeTab
    session.secondaryView = session.tabs[session.activeTab].view
    session.tabs[session.activeTab].secondaryView = session.secondaryView
  else:
    session.splitSecondaryTab = -1
    session.secondaryView = newEditorView()
  session.splitActivePane = 0

proc setSplitRatio*(session: var EditorSession, ratio: float32) =
  session.splitRatio = normalizedSplitRatio(ratio)

proc effectiveSplitRatio*(session: EditorSession): float32 =
  ## Sessions written before split ratios existed deserialize as zero.
  if session.splitRatio <= 0'f32: 0.5'f32 else: normalizedSplitRatio(session.splitRatio)

proc activateSplitPane*(session: var EditorSession, pane: int): bool =
  if not session.split or pane notin 0..1: return false
  session.splitActivePane = pane
  true

proc moveActivePaneCursor*(session: var EditorSession,
                           primaryView: var EditorViewState, offset: int,
                           selecting = false) =
  ## Keep all position-based operations in the pane that owns focus.  The
  ## document is shared by a split, but each pane owns its cursor and anchor.
  if session.split and session.splitActivePane == 1:
    session.secondaryView.moveCursor(offset, selecting)
  else:
    primaryView.moveCursor(offset, selecting)

proc ensureCursorVisible*(view: var EditorViewState, buffer: PieceTable,
                          visibleLines: int) =
  ## Cursor ownership and viewport ownership are both per pane.  Keep a
  ## position-based operation (completion, definition, go-to-line) visible
  ## without moving the sibling pane's viewport.
  let text = buffer.toString()
  view.clampSelectionToText(text)
  let lineCount = buffer.lineStarts.len
  if lineCount == 0: return
  let viewportLines = max(1, visibleLines)
  view.reconcileScrollPosition()
  let location = buffer.lineColumn(view.cursor)
  let lastScrollLine = max(0, lineCount - viewportLines)
  let lineHeight = editorLineHeight()
  if location.line < view.scrollLine:
    view.setScrollYPixels(float32(location.line) * lineHeight,
      lineHeight, float32(lastScrollLine) * lineHeight)
  elif location.line >= view.scrollLine + viewportLines:
    view.setScrollYPixels(float32(min(lastScrollLine,
      location.line - viewportLines + 1)) * lineHeight,
      lineHeight, float32(lastScrollLine) * lineHeight)

proc closeSplit*(session: var EditorSession) =
  session.split = false
  session.splitSecondaryTab = -1
  session.splitActivePane = 0

proc recordRecent*(session: var EditorSession, path: string) =
  session.recentFiles = session.recentFiles.filterIt(it != path)
  session.recentFiles.insert(path, 0)
