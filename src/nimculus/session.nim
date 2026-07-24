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

proc saveSession*(session: EditorSession, path: string, preserveDirty = true) =
  var root = %*{"activeTab": -1, "split": session.split,
                "splitDirection": $session.splitDirection,
                "recentFiles": session.recentFiles,
                "workspaceRoots": session.workspaceRoots}
  var tabs = newJArray()
  var savedActive = -1
  for originalIndex, tab in session.tabs:
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
  if root.hasKey("recentFiles") and root["recentFiles"].kind == JArray:
    for item in root["recentFiles"].getElems:
      if item.kind == JString: result.recentFiles.add(item.getStr)
  if root.hasKey("workspaceRoots") and root["workspaceRoots"].kind == JArray:
    for item in root["workspaceRoots"].getElems:
      if item.kind == JString and dirExists(item.getStr): result.workspaceRoots.add(item.getStr)
  if not root.hasKey("tabs") or root["tabs"].kind != JArray: return
  for item in root["tabs"].getElems:
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
        result.addTab(document)
        let tabIndex = result.tabs.high
        let savedTitle = jsonString(item, "title", "")
        if savedTitle.len > 0: result.tabs[tabIndex].title = savedTitle
        if item.hasKey("view") and item["view"].kind == JObject:
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
  else: result.activeTab = max(0, min(result.activeTab, result.tabs.high))

proc writeRecovery*(document: FileDocument, path: string) =
  atomicWriteFile(path, document.buffer.toString())

proc recoverDocument*(path: string): FileDocument =
  result = newDocument()
  result.buffer = initPieceTable(readFile(path))
  # Recovery content was not committed to a named file. Keep it dirty so the
  # next persistence tick cannot mistake it for saved content and delete the
  # only copy of the recovered buffer.
  result.buffer.markDirty()
