import std/os
import std/strutils
import std/tables
import std/algorithm
import std/osproc

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
    roots*: seq[string]
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
  result.roots = @[result.root]
  result.ignoredPatterns = loadIgnoreFile(result.root)

proc addRoot*(workspace: Workspace, root: string) =
  let absolute = absolutePath(root)
  if absolute notin workspace.roots: workspace.roots.add(absolute)

proc rootPaths*(workspace: Workspace): seq[string] = workspace.roots

proc listChildrenAt*(workspace: Workspace, root: string; relative = ""): seq[WorkspaceEntry] =
  let directory = root / relative
  if not dirExists(directory): return
  for kind, path in walkDir(directory, relative = false):
    let relativePath = relative / path.extractFilename
    let ignored = workspace.isIgnored(relativePath)
    let entry = WorkspaceEntry(path: path, relativePath: relativePath,
      kind: if kind == pcDir: WorkspaceFileKind.directory else: WorkspaceFileKind.file, ignored: ignored)
    workspace.entries[root / relativePath] = entry
    if not ignored: result.add(entry)

proc listChildren*(workspace: Workspace, relative = ""): seq[WorkspaceEntry] =
  workspace.listChildrenAt(workspace.root, relative)

proc enumerateFiles*(workspace: Workspace, token: CancelToken = nil): seq[WorkspaceEntry] =
  for root in workspace.roots:
    var pending = @[""]
    while pending.len > 0:
      if token != nil and token.cancelled: return
      let relative = pending.pop()
      for entry in workspace.listChildrenAt(root, relative):
        if token != nil and token.cancelled: return
        if entry.kind == WorkspaceFileKind.directory: pending.add(entry.relativePath)
        else:
          var normalized = entry
          if root != workspace.root: normalized.relativePath = root / entry.relativePath
          result.add(normalized)

proc resolvePath(workspace: Workspace, relative: string): string =
  let candidate = normalizedPath(workspace.root / relative)
  let root = normalizedPath(workspace.root)
  if candidate == root or candidate.startsWith(root & DirSep): return candidate
  raise newException(ValueError, "workspace path escapes root")

proc createFile*(workspace: Workspace, relative: string, content = ""): string =
  let path = workspace.resolvePath(relative)
  if fileExists(path) or dirExists(path): raise newException(IOError, "path already exists")
  let parent = path.parentDir
  if not dirExists(parent): createDir(parent)
  writeFile(path, content)
  path

proc createDirectory*(workspace: Workspace, relative: string): string =
  let path = workspace.resolvePath(relative)
  if fileExists(path) or dirExists(path): raise newException(IOError, "path already exists")
  createDir(path)
  path

proc deleteEntry*(workspace: Workspace, relative: string) =
  let path = workspace.resolvePath(relative)
  if dirExists(path): removeDir(path)
  elif fileExists(path): removeFile(path)

proc renameEntry*(workspace: Workspace, relative, newRelative: string): string =
  let oldPath = workspace.resolvePath(relative)
  let newPath = workspace.resolvePath(newRelative)
  if not fileExists(oldPath) and not dirExists(oldPath): raise newException(IOError, "path does not exist")
  if fileExists(newPath) or dirExists(newPath): raise newException(IOError, "destination already exists")
  moveFile(oldPath, newPath)
  newPath

proc fuzzyFileSearch*(workspace: Workspace, query: string, limit = 100): seq[WorkspaceEntry] =
  if query.len == 0: return
  let needle = query.toLowerAscii
  for entry in workspace.enumerateFiles():
    var cursor = 0
    for character in entry.relativePath.toLowerAscii:
      if cursor < needle.len and character == needle[cursor]: inc cursor
    if cursor == needle.len:
      result.add(entry)
      if result.len >= limit: break
  result.sort(proc(a, b: WorkspaceEntry): int = cmp(a.relativePath.len, b.relativePath.len))

proc searchWorkspace*(workspace: Workspace, query: string,
                      token: CancelToken = nil): seq[SearchResult]

proc searchRipgrep*(workspace: Workspace, query: string,
                    token: CancelToken = nil): seq[SearchResult] =
  if query.len == 0 or (token != nil and token.cancelled): return
  var usedRipgrep = true
  try:
    for root in workspace.roots:
      if token != nil and token.cancelled: return
      let command = "rg --color never --no-heading --line-number --column --glob !.git " &
        quoteShell(query) & " " & quoteShell(root)
      let output = execCmdEx(command)
      if output.exitCode > 1:
        usedRipgrep = false
        break
      for line in output.output.splitLines:
        let parts = line.split(':', maxsplit = 3)
        if parts.len < 4: continue
        let lineNumber = parseInt(parts[parts.len - 3])
        let column = parseInt(parts[parts.len - 2])
        let text = parts[parts.len - 1]
        let path = parts[0 ..< parts.len - 3].join(":")
        result.add(SearchResult(path: path, line: lineNumber, column: column, text: text))
    if usedRipgrep and workspace.roots.len > 0: return
  except CatchableError:
    discard
  workspace.searchWorkspace(query, token)

proc gitWorktrees*(workspace: Workspace): seq[string] =
  try:
    let output = execCmdEx("git -C " & quoteShell(workspace.root) & " worktree list --porcelain")
    for line in output.output.splitLines:
      if line.startsWith("worktree "): result.add(line[9 .. ^1])
  except CatchableError:
    discard

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
