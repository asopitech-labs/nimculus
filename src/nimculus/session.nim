import std/json
import std/os
import nimculus/editor_app
import nimculus/editor_buffer
import nimculus/editor_view
import nimculus/atomic_io

proc jsonInt(node: JsonNode, key: string, fallback: int): int =
  if node == nil or node.kind != JObject or not node.hasKey(key): return fallback
  try: node[key].getInt(fallback)
  except CatchableError: fallback

proc jsonBool(node: JsonNode, key: string, fallback: bool): bool =
  if node == nil or node.kind != JObject or not node.hasKey(key): return fallback
  try: node[key].getBool(fallback)
  except CatchableError: fallback

proc jsonString(node: JsonNode, key, fallback: string): string =
  if node == nil or node.kind != JObject or not node.hasKey(key): return fallback
  try:
    if node[key].kind == JString: return node[key].getStr
  except CatchableError: discard
  fallback

proc jsonFloat(node: JsonNode, key: string, fallback: float32): float32 =
  if node == nil or node.kind != JObject or not node.hasKey(key): return fallback
  try:
    if node[key].kind in {JFloat, JInt}: return float32(node[key].getFloat)
  except CatchableError:
    discard
  fallback

proc normalizedSessionPaths(paths: openArray[string], directoriesOnly = false): seq[string] =
  ## Session data predates the canonical identity boundary used by Finder,
  ## Save As, and workspace roots. Preserve non-existent recent files, but
  ## omit invalid workspace roots and never retain aliases twice.
  for path in paths:
    if path.len == 0 or (directoriesOnly and not dirExists(path)): continue
    let identityPath = canonicalOpenPath(path)
    if identityPath.len > 0 and identityPath notin result:
      result.add(identityPath)

proc saveSession*(session: EditorSession, path: string, preserveDirty = true) =
  let recentFiles = normalizedSessionPaths(session.recentFiles)
  let workspaceRoots = normalizedSessionPaths(session.workspaceRoots, directoriesOnly = true)
  var root = %*{"activeTab": -1, "split": session.split,
                "splitDirection": $session.splitDirection,
                "splitRatio": session.effectiveSplitRatio,
                "recentFiles": recentFiles,
                "workspaceRoots": workspaceRoots}
  var tabs = newJArray()
  var savedActive = -1
  # Keep persistence on the same one-buffer-per-canonical-path invariant as
  # live document opens. This also repairs an in-memory session produced by
  # older builds before its next launch. Dirty content wins; active dirty
  # content wins over another dirty duplicate.
  var selectedNamedPaths: seq[string]
  var selectedNamedIndices: seq[int]
  var selectedNamedPriorities: seq[int]
  for index, tab in session.tabs:
    if tab.document.path.len == 0: continue
    let identityPath = canonicalOpenPath(tab.document.path)
    let priority = (if tab.document.buffer.isDirty: 2 else: 0) +
      (if index == session.activeTab: 1 else: 0)
    var existing = -1
    for candidate, candidatePath in selectedNamedPaths:
      if candidatePath == identityPath:
        existing = candidate
        break
    if existing < 0:
      selectedNamedPaths.add(identityPath)
      selectedNamedIndices.add(index)
      selectedNamedPriorities.add(priority)
    elif priority > selectedNamedPriorities[existing]:
      selectedNamedIndices[existing] = index
      selectedNamedPriorities[existing] = priority
  for originalIndex, tab in session.tabs:
    if tab.document.path.len > 0:
      let identityPath = canonicalOpenPath(tab.document.path)
      var selectedIndex = -1
      for candidate, candidatePath in selectedNamedPaths:
        if candidatePath == identityPath:
          selectedIndex = selectedNamedIndices[candidate]
          break
      if selectedIndex != originalIndex: continue
    let dirty = tab.document.buffer.isDirty
    # A discarded untitled buffer has no disk path to reopen, so do not carry
    # it into the next session. Clean untitled tabs remain restorable.
    if not preserveDirty and dirty and tab.document.path.len == 0: continue
    let saveDirty = preserveDirty and dirty
    if originalIndex == session.activeTab: savedActive = tabs.len
    var serializedTab = %*{"path": tab.document.path, "title": tab.title,
      "dirty": saveDirty,
      "view": {
        "anchor": tab.view.selection.anchor,
        "active": tab.view.selection.active,
        "scrollLine": tab.view.scrollLine,
        "showLineNumbers": tab.view.showLineNumbers,
        "softWrap": tab.view.softWrap,
        "showIndentGuides": tab.view.showIndentGuides,
        "indentWidth": tab.view.indentWidth
      }}
    if tab.document.path.len == 0 or saveDirty:
      serializedTab["content"] = %tab.document.buffer.toString()
      serializedTab["lineEnding"] = %($tab.document.lineEnding)
    tabs.add(serializedTab)
  if savedActive < 0 and session.activeTab >= 0 and
      session.activeTab < session.tabs.len:
    let activePath = session.tabs[session.activeTab].document.path
    if activePath.len > 0:
      let activeIdentity = canonicalOpenPath(activePath)
      for index, serializedTab in tabs.getElems:
        if jsonString(serializedTab, "path", "") == activeIdentity:
          savedActive = index
          break
  root["activeTab"] = %savedActive
  root["tabs"] = tabs
  atomicWriteFile(path, $root)

proc loadSession*(path: string): EditorSession =
  if not fileExists(path): return
  var root: JsonNode
  try:
    root = parseJson(readFile(path))
  except CatchableError:
    result.activeTab = -1
    return
  if root.kind != JObject:
    result.activeTab = -1
    return
  result.activeTab = jsonInt(root, "activeTab", -1)
  result.split = jsonBool(root, "split", false)
  let direction = jsonString(root, "splitDirection", "splitVertical")
  result.splitDirection = if direction == "splitHorizontal": splitHorizontal else: splitVertical
  result.splitRatio = normalizedSplitRatio(jsonFloat(root, "splitRatio", 0.5'f32))
  if root.hasKey("recentFiles") and root["recentFiles"].kind == JArray:
    for item in root["recentFiles"].getElems:
      if item.kind == JString:
        let path = canonicalOpenPath(item.getStr)
        if path.len > 0 and path notin result.recentFiles: result.recentFiles.add(path)
  if root.hasKey("workspaceRoots") and root["workspaceRoots"].kind == JArray:
    for item in root["workspaceRoots"].getElems:
      if item.kind == JString and dirExists(item.getStr):
        let path = canonicalOpenPath(item.getStr)
        if path.len > 0 and path notin result.workspaceRoots: result.workspaceRoots.add(path)
  if not root.hasKey("tabs") or root["tabs"].kind != JArray: return
  # Older builds could serialize the same named document more than once.  Keep
  # restore on the same one-buffer-per-canonical-path invariant as Finder,
  # URL, CLI, and Save As opens.  Dirty content wins over a clean duplicate;
  # an active dirty duplicate wins over any other duplicate.
  let requestedActive = result.activeTab
  var restoredActive = -1
  var restorePriority: seq[int]
  for originalIndex, item in root["tabs"].getElems:
    if item.kind != JObject or not item.hasKey("path"): continue
    let filePath = jsonString(item, "path", "")
    let savedDirty = jsonBool(item, "dirty", false)
    var document: FileDocument
    var canRestore = false
    try:
      if filePath.len > 0 and fileExists(filePath) and not dirExists(filePath):
        try:
          document = openDocument(filePath)
          if savedDirty and item.hasKey("content") and
             item["content"].kind == JString:
            document.buffer = initPieceTable(item["content"].getStr)
            document.lineEnding = if jsonString(item, "lineEnding", "lf") == "crlf": crlf else: lf
            document.buffer.markDirty()
          canRestore = true
        except CatchableError:
          # A permission/read failure is treated like a missing disk state;
          # a serialized dirty buffer is still recoverable below.
          discard
      if not canRestore and filePath.len > 0 and savedDirty and item.hasKey("content") and
           item["content"].kind == JString:
        # Keep an unsaved named buffer even when the disk file was deleted or
        # moved after the last session write.  The path remains attached so a
        # later Save can recreate it, matching Zed's Deleted disk state rather
        # than silently dropping the user's only dirty copy.
        document = newDocument()
        # Older sessions can contain a pre-canonical `/tmp` or symlink path.
        # Keep recovery documents on the same identity boundary as freshly
        # opened documents, even though their leaf no longer exists.
        document.path = canonicalOpenPath(filePath)
        document.buffer = initPieceTable(item["content"].getStr)
        document.lineEnding = if jsonString(item, "lineEnding", "lf") == "crlf": crlf else: lf
        document.buffer.markDirty()
        canRestore = true
      elif not canRestore and filePath.len == 0 and item.hasKey("content") and
           item["content"].kind == JString:
        document = newDocument()
        document.buffer = initPieceTable(item["content"].getStr)
        document.lineEnding = if jsonString(item, "lineEnding", "lf") == "crlf": crlf else: lf
        if jsonBool(item, "dirty", false): document.buffer.markDirty()
        canRestore = true
      if canRestore:
        let priority = (if savedDirty: 2 else: 0) +
          (if originalIndex == requestedActive: 1 else: 0)
        var tabIndex = if document.path.len > 0:
          result.tabIndexForPath(document.path)
        else:
          -1
        let replaceExisting = tabIndex >= 0 and priority > restorePriority[tabIndex]
        var adopted = false
        if tabIndex < 0:
          result.addTab(document)
          tabIndex = result.tabs.high
          restorePriority.add(priority)
          adopted = true
        elif replaceExisting:
          result.tabs[tabIndex].document = document
          restorePriority[tabIndex] = priority
          adopted = true
        if originalIndex == requestedActive: restoredActive = tabIndex
        if adopted:
          let savedTitle = jsonString(item, "title", "")
          if savedTitle.len > 0: result.tabs[tabIndex].title = savedTitle
        if adopted and item.hasKey("view") and item["view"].kind == JObject:
          let view = item["view"]
          let tabView = addr result.tabs[tabIndex].view
          let text = result.tabs[tabIndex].document.buffer.toString()
          tabView[].selection.anchor = floorGraphemeBoundary(text, jsonInt(view, "anchor", 0))
          tabView[].selection.active = floorGraphemeBoundary(text, jsonInt(view, "active", 0))
          tabView[].scrollLine = min(max(0, jsonInt(view, "scrollLine", 0)),
            max(0, result.tabs[tabIndex].document.buffer.lineStarts.high))
          tabView[].showLineNumbers = jsonBool(view, "showLineNumbers", true)
          tabView[].softWrap = jsonBool(view, "softWrap", false)
          tabView[].showIndentGuides = jsonBool(view, "showIndentGuides", true)
          tabView[].indentWidth = max(1, jsonInt(view, "indentWidth", 2))
    except CatchableError: discard
  if result.tabs.len == 0: result.activeTab = -1
  else:
    result.activeTab = if restoredActive >= 0: restoredActive
      else: max(0, min(requestedActive, result.tabs.high))

proc writeRecovery*(document: FileDocument, path: string) =
  atomicWriteFile(path, document.buffer.toString())

proc recoverDocument*(path: string): FileDocument =
  result = newDocument()
  result.buffer = initPieceTable(readFile(path))
  # Recovery content was not committed to a named file. Keep it dirty so the
  # next persistence tick cannot mistake it for saved content and delete the
  # only copy of the recovered buffer.
  result.buffer.markDirty()
