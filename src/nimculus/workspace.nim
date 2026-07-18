import std/os
import std/strutils
import std/tables

when defined(macosx):
  {.compile: "workspace_macos.m".}
  {.passL: "-framework Cocoa -framework CoreServices -framework CoreFoundation".}

type
  WorkspaceFileKind* = enum file, directory
  WorkspaceEntry* = object
    path*: string
    relativePath*: string
    kind*: WorkspaceFileKind
    ignored*: bool
  SearchResult* = object
    path*: string
    line*, column*: int
    text*: string
  CancelToken* = ref object
    cancelled*: bool
  Workspace* = ref object
    root*: string
    entries*: Table[string, WorkspaceEntry]
    ignoredPatterns*: seq[string]
    watcher*: pointer
    changes*: seq[string]

when defined(macosx):
  type WorkspaceChangeCallback* = proc(path: cstring, context: pointer) {.cdecl.}
  proc startWorkspaceWatcher*(root: cstring, callback: WorkspaceChangeCallback,
                              context: pointer): pointer {.importc: "nimculus_start_workspace_watcher", cdecl.}
  proc stopWorkspaceWatcher*(watcher: pointer) {.importc: "nimculus_stop_workspace_watcher", cdecl.}

proc newCancelToken*(): CancelToken = CancelToken(cancelled: false)
proc cancel*(token: CancelToken) = token.cancelled = true

proc matchesIgnore(path, pattern: string): bool =
  let normalized = path.replace("\\", "/")
  let p = pattern.strip(chars = {'/'})
  if p.len == 0 or p[0] == '#': return false
  if p.startsWith("*"): return normalized.endsWith(p[1..^1])
  normalized == p or normalized.endsWith("/" & p) or normalized.contains("/" & p & "/")

proc loadIgnoreFile(root: string): seq[string] =
  let path = root / ".gitignore"
  if fileExists(path):
    for line in readFile(path).splitLines:
      if line.strip.len > 0 and not line.strip.startsWith("#"): result.add(line.strip)

proc isIgnored(workspace: Workspace, relative: string): bool =
  if relative == ".git" or relative.startsWith(".git/"): return true
  for pattern in workspace.ignoredPatterns:
    if matchesIgnore(relative, pattern): return true

proc openWorkspace*(root: string): Workspace =
  result = Workspace(root: absolutePath(root))
  result.ignoredPatterns = loadIgnoreFile(result.root)

proc listChildren*(workspace: Workspace, relative = ""): seq[WorkspaceEntry] =
  let directory = workspace.root / relative
  if not dirExists(directory): return
  for kind, path in walkDir(directory, relative = false):
    let relativePath = relative / path.extractFilename
    let ignored = workspace.isIgnored(relativePath)
    let entry = WorkspaceEntry(path: path, relativePath: relativePath,
      kind: if kind == pcDir: WorkspaceFileKind.directory else: WorkspaceFileKind.file, ignored: ignored)
    workspace.entries[relativePath] = entry
    if not ignored: result.add(entry)

proc enumerateFiles*(workspace: Workspace, token: CancelToken = nil): seq[WorkspaceEntry] =
  var pending = @[""]
  while pending.len > 0:
    if token != nil and token.cancelled: break
    let relative = pending.pop()
    for entry in workspace.listChildren(relative):
      if token != nil and token.cancelled: break
      if entry.kind == WorkspaceFileKind.directory: pending.add(entry.relativePath)
      else: result.add(entry)

proc searchWorkspace*(workspace: Workspace, query: string,
                      token: CancelToken = nil): seq[SearchResult] =
  if query.len == 0: return
  for entry in workspace.enumerateFiles(token):
    if token != nil and token.cancelled: break
    try:
      let lines = readFile(entry.path).splitLines
      for lineNumber in 0 ..< lines.len:
        let line = lines[lineNumber]
        var offset = 0
        while true:
          let column = line.find(query, offset)
          if column < 0: break
          result.add(SearchResult(path: entry.relativePath, line: lineNumber + 1,
            column: column + 1, text: line))
          offset = column + max(1, query.len)
    except CatchableError:
      discard

proc changedPaths*(workspace: Workspace): seq[string] =
  result = workspace.changes
  workspace.changes.setLen(0)

when defined(macosx):
  proc receiveWorkspaceChange(path: cstring, context: pointer) {.cdecl.} =
    let workspace = cast[Workspace](context)
    if workspace != nil: workspace.changes.add($path)

proc startWatching*(workspace: Workspace) =
  when defined(macosx):
    workspace.watcher = startWorkspaceWatcher(workspace.root.cstring, receiveWorkspaceChange, cast[pointer](workspace))

proc stopWatching*(workspace: Workspace) =
  when defined(macosx):
    if workspace.watcher != nil: stopWorkspaceWatcher(workspace.watcher)
    workspace.watcher = nil
