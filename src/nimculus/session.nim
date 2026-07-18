import std/json
import std/os
import nimculus/editor_app
import nimculus/editor_buffer

proc saveSession*(session: EditorSession, path: string) =
  var root = %*{"activeTab": session.activeTab, "split": session.split,
                "splitDirection": $session.splitDirection,
                "recentFiles": session.recentFiles}
  var tabs = newJArray()
  for tab in session.tabs: tabs.add(%*{"path": tab.document.path, "title": tab.title})
  root["tabs"] = tabs
  writeFile(path, $root)

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
  if root.hasKey("activeTab"): result.activeTab = root["activeTab"].getInt(-1)
  else: result.activeTab = -1
  if root.hasKey("split"): result.split = root["split"].getBool(false)
  if root.hasKey("recentFiles") and root["recentFiles"].kind == JArray:
    for item in root["recentFiles"].getElems:
      if item.kind == JString: result.recentFiles.add(item.getStr)
  if not root.hasKey("tabs") or root["tabs"].kind != JArray: return
  for item in root["tabs"].getElems:
    if item.kind != JObject or not item.hasKey("path"): continue
    let filePath = item["path"].getStr
    if filePath.len > 0 and fileExists(filePath):
      try: result.addTab(openDocument(filePath))
      except CatchableError: discard
  if result.tabs.len == 0: result.activeTab = -1
  else: result.activeTab = max(0, min(result.activeTab, result.tabs.high))

proc writeRecovery*(document: FileDocument, path: string) =
  writeFile(path, document.buffer.toString())

proc recoverDocument*(path: string): FileDocument =
  result = newDocument()
  result.buffer = initPieceTable(readFile(path))
