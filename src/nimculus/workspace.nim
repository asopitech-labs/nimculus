import std/os
import std/strutils
import std/tables
import std/algorithm
import std/osproc
import std/locks
import std/times
import gitignore/repo

when defined(posix):
  import posix

when defined(macosx):
  {.compile: "workspace_macos.m".}
  {.passL: "-framework Cocoa -framework CoreServices -framework CoreFoundation".}
when defined(windows):
  {.compile: "workspace_windows.c".}

type
  WorkspaceFileKind* = enum file, directory
  WorkspaceEntry* = object
    path*: string
    relativePath*: string
    rootPath*: string
    kind*: WorkspaceFileKind
    ignored*: bool
  SearchResult* = object
    path*: string
    rootPath*: string
    line*, column*: int
    text*: string
  WorktreeState* = object
    root*, head*, branch*: string
  CancelToken* = ref object
    cancelled*: bool
  SearchJob* = ref object
    workspace*: Workspace
    query*: string
    token*: CancelToken
    pendingDirectories: seq[tuple[root: string, relative: string]]
    pendingFiles: seq[WorkspaceEntry]
    bufferedResults: seq[SearchResult]
    activeFile: File
    activeEntry: WorkspaceEntry
    activeLine: int
    hasActiveFile: bool
    complete*: bool
    truncated*: bool
    maxResults*: int
    totalResults: int
  FuzzySearchJob* = ref object
    workspace*: Workspace
    query*: string
    token*: CancelToken
    pendingDirectories: seq[tuple[root: string, relative: string]]
    pendingFiles: seq[WorkspaceEntry]
    bufferedResults: seq[WorkspaceEntry]
    complete*: bool
  Workspace* = ref object
    root*: string
    roots*: seq[string]
    entries*: Table[string, WorkspaceEntry]
    ignoreStacksByRoot: Table[string, IgnoreStack]
    watchers: seq[pointer]
    changes*: seq[string]
    changesLock: Lock

const
  MaxWorkspaceSearchResults* = 10_000
  MaxWorkspaceSearchOutputBytes* = 32 * 1024 * 1024
  SearchProcessGracePeriodMs = 1_000

when defined(macosx) or defined(windows):
  type WorkspaceChangeCallback* = proc(path: cstring, context: pointer) {.cdecl.}
  proc startWorkspaceWatcher*(root: cstring, callback: WorkspaceChangeCallback,
                              context: pointer): pointer {.importc: "nimculus_start_workspace_watcher", cdecl.}
  proc stopWorkspaceWatcher*(watcher: pointer) {.importc: "nimculus_stop_workspace_watcher", cdecl.}

when defined(macosx):
  proc validateWorkspaceWatcherRescanFlags*(): bool {.importc: "nimculus_workspace_validate_rescan_flags", cdecl.}

proc newCancelToken*(): CancelToken = CancelToken(cancelled: false)
proc cancel*(token: CancelToken) = token.cancelled = true

proc isIgnored(workspace: Workspace, root, relative: string, isDir: bool): bool =
  if relative == ".git" or relative.startsWith(".git/"): return true
  if root notin workspace.ignoreStacksByRoot: return false
  workspace.ignoreStacksByRoot[root].isIgnored(relative, isDir)

proc openWorkspace*(root: string): Workspace =
  result = Workspace(root: absolutePath(root))
  initLock(result.changesLock)
  result.roots = @[result.root]
  result.ignoreStacksByRoot = initTable[string, IgnoreStack]()
  result.ignoreStacksByRoot[result.root] = newIgnoreStack(result.root)

proc addRoot*(workspace: Workspace, root: string) =
  let absolute = absolutePath(root)
  if absolute notin workspace.roots:
    workspace.roots.add(absolute)
    workspace.ignoreStacksByRoot[absolute] = newIgnoreStack(absolute)

proc rootPaths*(workspace: Workspace): seq[string] = workspace.roots

proc reloadIgnoreRules*(workspace: Workspace) =
  ## Rebuild per-root IgnoreStacks after an ignore file changes. The stacks
  ## contain lazy nested-file caches, so replacing the value is the cache
  ## invalidation boundary rather than mutating a partially loaded stack.
  if workspace == nil: return
  for root in workspace.roots:
    workspace.ignoreStacksByRoot[root] = newIgnoreStack(root)

proc isIgnoreRulePath(workspace: Workspace, path: string): bool =
  let candidate = normalizedPath(path).replace("\\", "/")
  for root in workspace.roots:
    let normalizedRoot = normalizedPath(root).replace("\\", "/")
    if candidate == normalizedRoot & "/.gitignore" or
        candidate == normalizedRoot & "/.git/info/exclude": return true
    if candidate.startsWith(normalizedRoot & "/") and candidate.endsWith("/.gitignore"):
      return true
  false

proc canonicalPath(path: string): string =
  when defined(posix):
    var buffer = newString(4096)
    if realpath(path.cstring, buffer.cstring) == nil:
      raise newException(IOError, "cannot resolve workspace path: " & path)
    result = $buffer.cstring
  else:
    result = normalizedPath(path)

proc boundaryPath(path: string): string =
  if fileExists(path) or dirExists(path):
    return canonicalPath(path)
  var current = normalizedPath(path)
  var missing: seq[string]
  while not fileExists(current) and not dirExists(current):
    let parent = current.parentDir
    if parent == current: return normalizedPath(path)
    missing.add(current.extractFilename)
    current = parent
  result = canonicalPath(current)
  for index in countdown(missing.high, 0):
    result = result / missing[index]

proc listChildrenAt*(workspace: Workspace, root: string; relative = ""): seq[WorkspaceEntry] =
  let directory = root / relative
  if not dirExists(directory): return
  for kind, path in walkDir(directory, relative = false):
    let relativePath = relative / path.extractFilename
    let ignored = workspace.isIgnored(root, relativePath, kind == pcDir)
    let entry = WorkspaceEntry(path: path, relativePath: relativePath, rootPath: root,
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
          result.add(normalized)

proc normalizedWorkspaceRoot(workspace: Workspace, root: string): string =
  let absolute = absolutePath(root)
  for registeredRoot in workspace.roots:
    if normalizedPath(registeredRoot) == normalizedPath(absolute): return normalizedPath(registeredRoot)
  raise newException(ValueError, "root is not registered in workspace: " & root)

proc resolvePathAt*(workspace: Workspace, root, relative: string): string =
  let registeredRoot = workspace.normalizedWorkspaceRoot(root)
  let candidate = normalizedPath(registeredRoot / relative)
  let canonicalRoot = canonicalPath(registeredRoot)
  let checked = boundaryPath(candidate)
  if checked == canonicalRoot or checked.startsWith(canonicalRoot & DirSep): return candidate
  raise newException(ValueError, "workspace path escapes root")

proc splitWorkspacePath*(workspace: Workspace, path: string): tuple[root, relative: string] =
  ## Resolve an operation payload to its owning workspace root. Relative
  ## payloads retain the primary-root convenience behavior; absolute payloads
  ## must belong to a registered root so secondary roots cannot be redirected
  ## silently to the primary root.
  if not isAbsolute(path):
    return (root: workspace.root, relative: path)
  let candidate = normalizedPath(path)
  for root in workspace.roots:
    let normalizedRoot = normalizedPath(root)
    if candidate == normalizedRoot:
      return (root: root, relative: "")
    if candidate.startsWith(normalizedRoot & DirSep):
      return (root: root, relative: candidate[(normalizedRoot.len + 1) .. ^1])
  raise newException(ValueError, "path is outside registered workspace roots")

proc resolveEntryPathAt(workspace: Workspace, root, relative: string): string =
  let path = workspace.resolvePathAt(root, relative)
  if path == normalizedPath(root):
    raise newException(ValueError, "workspace root is not an entry")
  path

proc createFileAt*(workspace: Workspace, root, relative: string, content = ""): string =
  let path = workspace.resolveEntryPathAt(root, relative)
  if fileExists(path) or dirExists(path): raise newException(IOError, "path already exists")
  let parent = path.parentDir
  if not dirExists(parent): createDir(parent)
  writeFile(path, content)
  path

proc createFile*(workspace: Workspace, relative: string, content = ""): string =
  workspace.createFileAt(workspace.root, relative, content)

proc createDirectoryAt*(workspace: Workspace, root, relative: string): string =
  let path = workspace.resolveEntryPathAt(root, relative)
  if fileExists(path) or dirExists(path): raise newException(IOError, "path already exists")
  createDir(path)
  path

proc createDirectory*(workspace: Workspace, relative: string): string =
  workspace.createDirectoryAt(workspace.root, relative)

proc deleteEntryAt*(workspace: Workspace, root, relative: string) =
  let path = workspace.resolveEntryPathAt(root, relative)
  if dirExists(path): removeDir(path)
  elif fileExists(path): removeFile(path)

proc deleteEntry*(workspace: Workspace, relative: string) =
  workspace.deleteEntryAt(workspace.root, relative)

proc renameEntryAt*(workspace: Workspace, root, relative, newRelative: string): string =
  let oldPath = workspace.resolveEntryPathAt(root, relative)
  let newPath = workspace.resolveEntryPathAt(root, newRelative)
  if not fileExists(oldPath) and not dirExists(oldPath): raise newException(IOError, "path does not exist")
  if fileExists(newPath) or dirExists(newPath): raise newException(IOError, "destination already exists")
  moveFile(oldPath, newPath)
  newPath

proc renameEntry*(workspace: Workspace, relative, newRelative: string): string =
  workspace.renameEntryAt(workspace.root, relative, newRelative)

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
  result.sort(proc(a, b: WorkspaceEntry): int =
    let lengthOrder = cmp(a.relativePath.len, b.relativePath.len)
    if lengthOrder != 0: lengthOrder else: cmp(a.relativePath, b.relativePath))

proc startFuzzySearch*(workspace: Workspace, query: string,
                       token: CancelToken = nil): FuzzySearchJob =
  result = FuzzySearchJob(workspace: workspace, query: query,
    token: if token == nil: newCancelToken() else: token)
  if workspace == nil or query.len == 0:
    result.complete = true
    return
  for root in workspace.roots:
    result.pendingDirectories.add((root: root, relative: ""))

proc cancelFuzzySearch*(job: FuzzySearchJob) =
  if job != nil and job.token != nil: job.token.cancel()

proc isComplete*(job: FuzzySearchJob): bool = job == nil or job.complete

proc fuzzyMatches(path, query: string): bool =
  var cursor = 0
  for character in path.toLowerAscii:
    if cursor < query.len and character == query[cursor]: inc cursor
  cursor == query.len

proc pollFuzzySearch*(job: FuzzySearchJob, maxEntries = 256,
                      maxResults = 100): seq[WorkspaceEntry] =
  ## Yield path matching in bounded batches. Zed's file finders run from
  ## background/project tasks; the macOS UI must not enumerate a 100k-file
  ## workspace synchronously while opening Quick Open.
  if job == nil or job.complete: return
  if job.token != nil and job.token.cancelled:
    job.complete = true
    return
  var processed = 0
  let needle = job.query.toLowerAscii
  while processed < max(1, maxEntries) and job.bufferedResults.len < max(1, maxResults):
    if job.token != nil and job.token.cancelled:
      job.complete = true
      break
    if job.pendingFiles.len == 0:
      if job.pendingDirectories.len == 0:
        job.complete = true
        break
      let directory = job.pendingDirectories.pop()
      for entry in job.workspace.listChildrenAt(directory.root, directory.relative):
        if entry.kind == WorkspaceFileKind.directory:
          job.pendingDirectories.add((root: directory.root, relative: entry.relativePath))
        else:
          job.pendingFiles.add(entry)
      continue
    let entry = job.pendingFiles.pop()
    inc processed
    if fuzzyMatches(entry.relativePath, needle):
      job.bufferedResults.add(entry)
  if job.pendingFiles.len == 0 and job.pendingDirectories.len == 0:
    job.complete = true
  result = job.bufferedResults
  job.bufferedResults.setLen(0)
  result.sort(proc(a, b: WorkspaceEntry): int =
    let lengthOrder = cmp(a.relativePath.len, b.relativePath.len)
    if lengthOrder != 0: lengthOrder else: cmp(a.relativePath, b.relativePath))

proc searchWorkspace*(workspace: Workspace, query: string,
                      token: CancelToken = nil,
                      maxResults = MaxWorkspaceSearchResults): seq[SearchResult]

proc invalidateEntryCache(workspace: Workspace, path: string) =
  ## Filesystem events are the invalidation boundary for the lazy entry cache.
  ## Remove the changed path and descendants before a subsequent tree scan;
  ## this handles deletes and renames where the path no longer exists.
  if workspace == nil or workspace.entries.len == 0: return
  let normalized = normalizedPath(path)
  var stale: seq[string]
  for key in workspace.entries.keys:
    let candidate = normalizedPath(key)
    if candidate == normalized or candidate.startsWith(normalized & DirSep):
      stale.add(key)
  for key in stale:
    workspace.entries.del(key)

proc startSearch*(workspace: Workspace, query: string,
                  token: CancelToken = nil): SearchJob =
  result = SearchJob(workspace: workspace, query: query,
    token: if token == nil: newCancelToken() else: token,
    truncated: false, maxResults: MaxWorkspaceSearchResults, totalResults: 0)
  if query.len == 0:
    result.complete = true
    return
  for root in workspace.roots:
    result.pendingDirectories.add((root: root, relative: ""))

proc cancelSearch*(job: SearchJob) =
  if job != nil:
    if job.hasActiveFile: close(job.activeFile)
    job.hasActiveFile = false
    if job.token != nil: job.token.cancel()

proc isComplete*(job: SearchJob): bool = job == nil or job.complete

proc searchLine(job: SearchJob, line: string, lineNumber: int,
                entry: WorkspaceEntry) =
  var offset = 0
  while true:
    let column = line.find(job.query, offset)
    if column < 0: break
    if job.totalResults >= max(1, job.maxResults):
      job.truncated = true
      return
    job.bufferedResults.add(SearchResult(path: entry.path, rootPath: entry.rootPath,
      line: lineNumber, column: column + 1, text: line))
    inc job.totalResults
    offset = column + max(1, job.query.len)

proc pollSearch*(job: SearchJob, maxFiles = 16, maxLines = 4096): seq[SearchResult] =
  ## Process bounded file/line work. Call this from the application's scheduler
  ## so a large workspace search can yield between batches without loading a
  ## complete file into memory.
  if job == nil or job.complete: return
  if job.token != nil and job.token.cancelled:
    job.complete = true
    return
  var processedFiles = 0
  var processedLines = 0
  while processedFiles < max(1, maxFiles) and processedLines < max(1, maxLines):
    if job.token != nil and job.token.cancelled:
      job.complete = true
      break
    if not job.hasActiveFile and job.pendingFiles.len == 0:
      if job.pendingDirectories.len == 0:
        job.complete = true
        break
      let directory = job.pendingDirectories.pop()
      for entry in job.workspace.listChildrenAt(directory.root, directory.relative):
        if entry.kind == WorkspaceFileKind.directory:
          job.pendingDirectories.add((root: directory.root, relative: entry.relativePath))
        else:
          var file = entry
          job.pendingFiles.add(file)
      continue
    if not job.hasActiveFile:
      job.activeEntry = job.pendingFiles.pop()
      if not open(job.activeFile, job.activeEntry.path, fmRead):
        inc processedFiles
        continue
      job.activeLine = 0
      job.hasActiveFile = true
    var line = ""
    if job.activeFile.readLine(line):
      inc job.activeLine
      job.searchLine(line, job.activeLine, job.activeEntry)
      inc processedLines
      if job.truncated:
        close(job.activeFile)
        job.hasActiveFile = false
        job.complete = true
        break
    else:
      close(job.activeFile)
      job.hasActiveFile = false
      inc processedFiles
  if not job.hasActiveFile and job.pendingFiles.len == 0 and job.pendingDirectories.len == 0:
    job.complete = true
  result = job.bufferedResults
  job.bufferedResults.setLen(0)

proc readFilePrefix(path: string, maxBytes: int): string =
  if maxBytes <= 0: return
  var file: File
  if not open(file, path, fmRead): return
  defer: file.close()
  result = newString(maxBytes)
  let count = file.readBuffer(addr result[0], maxBytes)
  result.setLen(max(0, count))

proc terminateSearchProcess*(process: Process): int =
  ## Stop an external search without allowing cancellation to block the UI.
  ## POSIX uses `exec` for the shell command above, so terminate/kill targets
  ## the ripgrep process itself on macOS. Keep the same bounded lifecycle for
  ## the Windows implementation until its native search path is replaced.
  if process == nil: return -1
  if process.running:
    process.terminate()
    result = process.waitForExit(SearchProcessGracePeriodMs)
    if result < 0:
      process.kill()
      result = process.waitForExit(SearchProcessGracePeriodMs)
  else:
    result = process.peekExitCode()
  process.close()

proc runSearchProcess(command: string, token: CancelToken,
                      maxOutputBytes = MaxWorkspaceSearchOutputBytes):
    tuple[exitCode: int, output: string, truncated: bool] =
  ## Run an external search without making cancellation wait for command exit.
  ## POSIX and Windows use a shell only for file redirection; the command
  ## itself is fully quoteShell-escaped by the caller. Both platforms monitor
  ## the temporary file so output and disk usage stay bounded.
  when defined(posix) or defined(windows):
    let outputPath = getTempDir() / ("nimculus-rg-" & $getCurrentProcessId() & "-" &
      $int(epochTime() * 1_000_000) & ".out")
    var process: Process
    var stoppedForOutputLimit = false
    try:
      let shellCommand = (when defined(posix): "exec " else: "") & command &
        " > " & quoteShell(outputPath) & " 2>&1"
      process = startProcess(shellCommand,
        options = {poEvalCommand})
      while process.running:
        if token != nil and token.cancelled:
          discard terminateSearchProcess(process)
          if fileExists(outputPath): removeFile(outputPath)
          return (-1, "", false)
        if fileExists(outputPath) and getFileSize(outputPath) > int64(maxOutputBytes):
          result.truncated = true
          result.exitCode = terminateSearchProcess(process)
          stoppedForOutputLimit = true
          break
        sleep(10)
      if not stoppedForOutputLimit:
        result.exitCode = process.waitForExit()
        process.close()
      if fileExists(outputPath):
        let size = getFileSize(outputPath)
        if size > int64(maxOutputBytes): result.truncated = true
        result.output = if result.truncated: readFilePrefix(outputPath, maxOutputBytes)
          else: readFile(outputPath)
        removeFile(outputPath)
    except CatchableError:
      if process != nil:
        try: process.close()
        except CatchableError: discard
      if fileExists(outputPath): removeFile(outputPath)
      raise
  else:
    let output = execCmdEx(command)
    result.exitCode = output.exitCode
    result.truncated = output.output.len > maxOutputBytes
    result.output = if result.truncated: output.output[0 ..< maxOutputBytes] else: output.output

when defined(macosx):
  proc runWorkspaceMetadataCommand(command: string):
      tuple[exitCode: int, output: string, truncated: bool] =
    ## Worktree metadata is requested from the Cocoa refresh path. Reuse the
    ## bounded temporary-file runner so a stalled Git helper cannot block the
    ## event loop indefinitely or grow the preview state without a limit.
    runSearchProcess(command, nil, 64 * 1024)

proc appendRipgrepRecord(results: var seq[SearchResult], root, path, payload: string) =
  let parts = payload.split(':', maxsplit = 2)
  if path.len == 0 or parts.len < 3: return
  try:
    results.add(SearchResult(path: path, rootPath: root, line: parseInt(parts[0]),
      column: parseInt(parts[1]), text: parts[2]))
  except ValueError:
    discard

proc parseRipgrepOutput(output, root: string,
                        maxResults = MaxWorkspaceSearchResults): seq[SearchResult] =
  ## `rg --null` emits one path NUL and one result line per match. Keep the
  ## path delimiter separate from the line delimiter so filenames may contain
  ## colons or newlines and multiple matches in one file are not collapsed.
  var offset = 0
  while offset < output.len and result.len < max(1, maxResults):
    let pathEnd = output.find('\0', offset)
    if pathEnd < 0: break
    let resultStart = pathEnd + 1
    let resultEnd = output.find('\n', resultStart)
    let endOffset = if resultEnd < 0: output.len else: resultEnd
    if resultStart <= endOffset:
      result.appendRipgrepRecord(root, output[offset ..< pathEnd],
        output[resultStart ..< endOffset])
    offset = if resultEnd < 0: output.len else: resultEnd + 1

proc searchRipgrep*(workspace: Workspace, query: string,
                    token: CancelToken = nil,
                    maxResults = MaxWorkspaceSearchResults): seq[SearchResult] =
  if query.len == 0 or (token != nil and token.cancelled): return
  var usedRipgrep = true
  try:
    for root in workspace.roots:
      if token != nil and token.cancelled: return
      # NUL-separate the path and each result record. Plain ':' parsing breaks
      # on macOS filenames and source lines containing colons. Do not use
      # --null-data: it changes ripgrep's record model and collapses multiple
      # matching lines into one payload.
      let command = "rg --color never --no-heading --line-number --column --null --glob !.git " &
        quoteShell(query) & " " & quoteShell(root)
      let output = runSearchProcess(command, token)
      if output.exitCode > 1 and not output.truncated:
        usedRipgrep = false
        break
      let remaining = max(1, maxResults) - result.len
      result.add(parseRipgrepOutput(output.output, root, remaining))
      if output.truncated or result.len >= max(1, maxResults): return
    if usedRipgrep and workspace.roots.len > 0: return
  except CatchableError:
    discard
  workspace.searchWorkspace(query, token)

proc gitWorktrees*(workspace: Workspace): seq[string] =
  try:
    when defined(macosx):
      let output = runWorkspaceMetadataCommand("git -C " & quoteShell(workspace.root) &
        " worktree list --porcelain")
      if output.exitCode != 0 or output.truncated: return
      for line in output.output.splitLines:
        if line.startsWith("worktree "): result.add(line[9 .. ^1])
    else:
      let output = execCmdEx("git -C " & quoteShell(workspace.root) & " worktree list --porcelain")
      for line in output.output.splitLines:
        if line.startsWith("worktree "): result.add(line[9 .. ^1])
  except CatchableError:
    discard

proc gitWorktreeStates*(workspace: Workspace): Table[string, WorktreeState] =
  result = initTable[string, WorktreeState]()
  for root in workspace.gitWorktrees():
    try:
      when defined(macosx):
        let headResult = runWorkspaceMetadataCommand("git -C " & quoteShell(root) &
          " rev-parse HEAD")
        let branchResult = runWorkspaceMetadataCommand("git -C " & quoteShell(root) &
          " symbolic-ref --short HEAD")
        if headResult.exitCode != 0 or headResult.truncated: continue
        let head = headResult.output.strip
        let branch = if branchResult.exitCode == 0 and not branchResult.truncated:
          branchResult.output.strip else: "(detached)"
      else:
        let head = execCmdEx("git -C " & quoteShell(root) & " rev-parse HEAD").output.strip
        let branchResult = execCmdEx("git -C " & quoteShell(root) & " symbolic-ref --short HEAD")
        let branch = if branchResult.exitCode == 0: branchResult.output.strip else: "(detached)"
      result[root] = WorktreeState(root: root, head: head, branch: branch)
    except CatchableError:
      discard

proc searchWorkspace*(workspace: Workspace, query: string,
                      token: CancelToken = nil,
                      maxResults = MaxWorkspaceSearchResults): seq[SearchResult] =
  if query.len == 0: return
  for entry in workspace.enumerateFiles(token):
    if result.len >= max(1, maxResults): break
    if token != nil and token.cancelled: break
    var file: File
    if not open(file, entry.path, fmRead): continue
    try:
      defer: file.close()
      var lineNumber = 0
      var line = ""
      while file.readLine(line):
        inc lineNumber
        var offset = 0
        while true:
          let column = line.find(query, offset)
          if column < 0: break
          if result.len >= max(1, maxResults): break
          result.add(SearchResult(path: entry.path, rootPath: entry.rootPath, line: lineNumber,
            column: column + 1, text: line))
          offset = column + max(1, query.len)
        if result.len >= max(1, maxResults): break
    except CatchableError:
      discard

proc changedPaths*(workspace: Workspace): seq[string] =
  if workspace == nil: return
  acquire(workspace.changesLock)
  try:
    # FSEvents may report the same path repeatedly in one burst. Expose the
    # same coalesced, normalized change-set contract as Zed's UpdatedEntriesSet.
    var seen = initTable[string, bool]()
    for path in workspace.changes:
      let normalized = normalizedPath(path)
      if normalized notin seen:
        seen[normalized] = true
        result.add(normalized)
    workspace.changes.setLen(0)
  finally:
    release(workspace.changesLock)
  for path in result:
    workspace.invalidateEntryCache(path)
  for path in result:
    if workspace.isIgnoreRulePath(path):
      workspace.reloadIgnoreRules()
      break

when defined(macosx) or defined(windows):
  proc receiveWorkspaceChange(path: cstring, context: pointer) {.cdecl.} =
    let workspace = cast[Workspace](context)
    if workspace != nil:
      acquire(workspace.changesLock)
      try:
        workspace.changes.add($path)
      finally:
        release(workspace.changesLock)

proc stopWatching*(workspace: Workspace)

proc isWatching*(workspace: Workspace): bool =
  workspace != nil and workspace.watchers.len > 0

proc startWatching*(workspace: Workspace) =
  when defined(macosx) or defined(windows):
    workspace.stopWatching()
    for root in workspace.roots:
      let watcher = startWorkspaceWatcher(root.cstring, receiveWorkspaceChange, cast[pointer](workspace))
      if watcher != nil: workspace.watchers.add(watcher)

proc stopWatching*(workspace: Workspace) =
  when defined(macosx) or defined(windows):
    for watcher in workspace.watchers:
      if watcher != nil: stopWorkspaceWatcher(watcher)
    workspace.watchers.setLen(0)
