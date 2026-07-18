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

proc saveSession*(session: EditorSession, path: string) =
  var root = %*{"activeTab": session.activeTab, "split": session.split,
                "splitDirection": $session.splitDirection,
                "recentFiles": session.recentFiles,
                "workspaceRoots": session.workspaceRoots}
  var tabs = newJArray()
  for tab in session.tabs:
    tabs.add(%*{"path": tab.document.path, "title": tab.title,
      "view": {
        "anchor": tab.view.selection.anchor,
        "active": tab.view.selection.active,
        "scrollLine": tab.view.scrollLine,
        "showLineNumbers": tab.view.showLineNumbers,
        "softWrap": tab.view.softWrap,
        "showIndentGuides": tab.view.showIndentGuides,
        "indentWidth": tab.view.indentWidth
      }})
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
  if root.hasKey("activeTab"): result.activeTab = root["activeTab"].getInt(-1)
  else: result.activeTab = -1
  if root.hasKey("split"): result.split = root["split"].getBool(false)
  if root.hasKey("recentFiles") and root["recentFiles"].kind == JArray:
    for item in root["recentFiles"].getElems:
      if item.kind == JString: result.recentFiles.add(item.getStr)
  if root.hasKey("workspaceRoots") and root["workspaceRoots"].kind == JArray:
    for item in root["workspaceRoots"].getElems:
      if item.kind == JString and dirExists(item.getStr): result.workspaceRoots.add(item.getStr)
  if not root.hasKey("tabs") or root["tabs"].kind != JArray: return
  for item in root["tabs"].getElems:
    if item.kind != JObject or not item.hasKey("path"): continue
    let filePath = item["path"].getStr
    if filePath.len > 0 and fileExists(filePath):
      try:
        result.addTab(openDocument(filePath))
        if item.hasKey("view") and item["view"].kind == JObject:
          let view = item["view"]
          let tabIndex = result.tabs.high
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
