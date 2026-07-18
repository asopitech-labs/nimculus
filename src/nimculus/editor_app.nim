import std/os
import std/times
import std/strutils
import std/sequtils
import nimculus/editor_buffer
import nimculus/atomic_io

type
  LineEnding* = enum lf, crlf
  FileDocument* = object
    path*: string
    buffer*: PieceTable
    lineEnding*: LineEnding
    externalSize*: int64
    externalModified*: Time
  SearchMatch* = object
    startByte*, endByte*: int
  EditorTab* = object
    document*: FileDocument
    title*: string
  SplitDirection* = enum splitVertical, splitHorizontal
  EditorSession* = object
    tabs*: seq[EditorTab]
    activeTab*: int
    split*: bool
    splitDirection*: SplitDirection
    recentFiles*: seq[string]
    workspaceRoots*: seq[string]

proc fileStamp(path: string): tuple[size: int64, modified: Time] =
  let info = getFileInfo(path)
  (size: info.size, modified: info.lastWriteTime)

proc openDocument*(path: string): FileDocument =
  let raw = readFile(path)
  result.path = path
  result.lineEnding = if raw.contains("\r\n"): crlf else: lf
  result.buffer = initPieceTable(raw.replace("\r\n", "\n"))
  let stamp = fileStamp(path)
  result.externalSize = stamp.size
  result.externalModified = stamp.modified
  result.buffer.markSaved()

proc newDocument*(): FileDocument =
  result.buffer = initPieceTable()
  result.buffer.markSaved()

proc save*(document: var FileDocument, path = "") =
  let targetPath = if path.len > 0: path else: document.path
  if targetPath.len == 0: raise newException(IOError, "document has no path")
  var content = document.buffer.toString()
  if document.lineEnding == crlf: content = content.replace("\n", "\r\n")
  atomicWriteFile(targetPath, content)
  document.path = targetPath
  let stamp = fileStamp(targetPath)
  document.externalSize = stamp.size
  document.externalModified = stamp.modified
  document.buffer.markSaved()

proc externallyChanged*(document: FileDocument): bool =
  if document.path.len == 0: return false
  if not fileExists(document.path): return document.externalSize > 0
  let stamp = fileStamp(document.path)
  stamp.size != document.externalSize or stamp.modified != document.externalModified

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
  session.tabs.add(EditorTab(document: document, title: title))
  session.activeTab = session.tabs.high

proc switchTab*(session: var EditorSession, delta: int): bool =
  ## Move around the existing tabs without mutating their buffers.
  if session.tabs.len < 2: return false
  let current = max(0, min(session.activeTab, session.tabs.high))
  let count = session.tabs.len
  session.activeTab = ((current + delta) mod count + count) mod count
  true

proc closeActiveTab*(session: var EditorSession): bool =
  if session.tabs.len == 0: return false
  session.activeTab = max(0, min(session.activeTab, session.tabs.high))
  if session.tabs[session.activeTab].document.buffer.isDirty: return false
  session.tabs.delete(session.activeTab)
  session.activeTab = min(session.activeTab, session.tabs.high)
  true

proc splitEditor*(session: var EditorSession, direction: SplitDirection) =
  session.split = true
  session.splitDirection = direction

proc recordRecent*(session: var EditorSession, path: string) =
  session.recentFiles = session.recentFiles.filterIt(it != path)
  session.recentFiles.insert(path, 0)
