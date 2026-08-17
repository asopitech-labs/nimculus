import std/os
import std/tables
import std/osproc
import std/streams
import std/strutils
import std/times
import std/asyncdispatch
import std/asyncfutures
import nimnui/executor
import nimnui/platform/contracts
when defined(posix):
  import std/posix

when defined(posix):
  type
    GitFileStreamObj = object of Stream
      f: File
    GitFileStream = ref GitFileStreamObj

type
  GitResult* = object
    exitCode*: int
    output*: string
    outputTruncated*: bool

  GitStatusEntry* = object
    indexStatus*: char
    worktreeStatus*: char
    path*: string
    originalPath*: string
    conflict*: bool

  GitSummary* = object
    indexCount*: int
    worktreeCount*: int
    conflictCount*: int

  GitSummaryCache = object
    generation: uint64
    sourceAddress: pointer
    sourceLength: int
    summaries: Table[string, GitSummary]
    fileFlags: Table[string, int32]
    initialized: bool

  GitCommit* = object
    hash*: string
    author*: string
    email*: string
    timestamp*: int64
    subject*: string

  GitBranch* = object
    name*: string
    current*: bool

  GitBlameLine* = object
    hash*: string
    author*: string
    authorTime*: int64
    authorTimeValid*: bool
    summary*: string
    line*: int
    text*: string

  GitDiffHunkKind* = enum
    gitHunkAdded, gitHunkDeleted, gitHunkModified

  GitDiffLineRange* = object
    ## One contiguous run of changed lines in the new file, one-based like
    ## the line numbers in a unified diff header.
    startLine*, lineCount*: int

  GitDiffHunk* = object
    oldStart*, oldCount*: int
    newStart*, newCount*: int
    addedLines*, removedLines*: int
    kind*: GitDiffHunkKind
    changedRanges*: seq[GitDiffLineRange]
    patchText*: string

  GitJob* = ref object
    process: Process
    output: Stream
    done*: bool
    cancelled*: bool
    result*: GitResult

  GitRepository* = ref object
    root*: string

const MaxGitOutputBytes* = 16 * 1024 * 1024
const GitProbeTimeoutMs = 2_000

const
  GitStatusFlagAdded = 2'i32
  GitStatusFlagModified = 4'i32
  GitStatusFlagDeleted = 8'i32

proc normalizedStatusPath(path: string): string =
  result = path.replace("\\", "/")
  while result.startsWith("/"):
    result = result[1 .. ^1]
  while result.endsWith("/"):
    result.setLen(result.len - 1)

proc incrementSummary(summaries: var Table[string, GitSummary]; directory: string;
                      entry: GitStatusEntry) =
  var summary = summaries.getOrDefault(directory)
  if entry.indexStatus notin {' ', '?', '!'}:
    inc summary.indexCount
  if entry.worktreeStatus notin {' ', '!'}:
    inc summary.worktreeCount
  if entry.conflict:
    inc summary.conflictCount
  summaries[directory] = summary

proc addPathSummaries(summaries: var Table[string, GitSummary]; path: string;
                      entry: GitStatusEntry) =
  incrementSummary(summaries, "", entry)
  var separator = path.rfind('/')
  while separator >= 0:
    incrementSummary(summaries, path[0 ..< separator], entry)
    separator = path.rfind('/', 0, separator - 1)

proc statusFlag(entry: GitStatusEntry): int32 =
  if entry.conflict or entry.indexStatus in {'U', 'A'} and
      entry.worktreeStatus in {'U', 'D'} or entry.worktreeStatus == 'D':
    return GitStatusFlagDeleted
  if entry.indexStatus in {'M', 'R'} or entry.worktreeStatus == 'M':
    return GitStatusFlagModified
  if entry.indexStatus in {'A', 'C', '?'} or entry.worktreeStatus == '?':
    return GitStatusFlagAdded

proc summariesByDirectory*(entries: openArray[GitStatusEntry]): Table[string, GitSummary] =
  result = initTable[string, GitSummary]()
  for entry in entries:
    let path = normalizedStatusPath(entry.path)
    if path.len == 0: continue
    addPathSummaries(result, path, entry)

proc refreshGitSummaryCache(cache: var GitSummaryCache;
                            entries: openArray[GitStatusEntry]; generation: uint64) =
  let sourceAddress = if entries.len == 0: nil else:
    cast[pointer](unsafeAddr entries[0])
  if cache.initialized and cache.generation == generation and
      cache.sourceAddress == sourceAddress and cache.sourceLength == entries.len:
    return
  cache.summaries = summariesByDirectory(entries)
  cache.fileFlags = initTable[string, int32]()
  for entry in entries:
    let path = normalizedStatusPath(entry.path)
    if path.len > 0:
      cache.fileFlags[path] = statusFlag(entry)
  cache.generation = generation
  cache.sourceAddress = sourceAddress
  cache.sourceLength = entries.len
  cache.initialized = true

proc gitStatusFlagMaskForPath*(entries: openArray[GitStatusEntry]; generation: uint64;
                               path: string; directory: bool): int32 =
  ## Build the directory aggregate once for a status generation, then keep
  ## project-panel row lookups to hash-table reads.
  var cache {.global.}: GitSummaryCache
  refreshGitSummaryCache(cache, entries, generation)
  let candidate = normalizedStatusPath(path)
  if not directory:
    return cache.fileFlags.getOrDefault(candidate)
  let summary = cache.summaries.getOrDefault(candidate)
  if summary.conflictCount > 0:
    return GitStatusFlagDeleted
  if summary.indexCount > 0:
    result = result or GitStatusFlagModified
  if summary.worktreeCount > 0:
    result = result or GitStatusFlagAdded

proc appendBoundedGitOutput*(current, chunk: string;
    limit: int = MaxGitOutputBytes): tuple[output: string; truncated: bool] =
  ## Keep Git output bounded while retaining the newest complete lines.
  ## Truncate only at UTF-8 and line boundaries, as Git consumers parse text.
  if chunk.len == 0: return (current, false)
  let combined = current & chunk
  if limit <= 0: return ("", combined.len > 0)
  if combined.len <= limit: return (combined, false)
  var start = combined.len - limit
  while start < combined.len and
      (ord(combined[start]) and 0xC0) == 0x80:
    inc start
  let lineBreak = combined.find('\n', start)
  if lineBreak >= 0: start = lineBreak + 1
  if start >= combined.len: return ("", true)
  (combined[start .. ^1], true)

proc readAvailable(job: GitJob): string {.gcsafe.} =
  if job == nil or job.process == nil or job.output == nil: return
  when defined(posix):
    let stream = cast[GitFileStream](job.output)
    if stream == nil or stream.f == nil: return
    let fd = cint(getOsFileHandle(stream.f))
    let flags = fcntl(fd, F_GETFL)
    if flags < 0 or fcntl(fd, F_SETFL, flags or O_NONBLOCK) < 0: return
    var bytes: array[8192, char]
    while true:
      let count = posix.read(fd, addr bytes[0], bytes.len)
      if count > 0:
        let oldLength = result.len
        result.setLen(oldLength + count)
        copyMem(addr result[oldLength], addr bytes[0], count)
      elif count < 0 and (errno == EAGAIN or errno == EWOULDBLOCK):
        break
      else:
        break
  else:
    if job.process.hasData(): result = job.output.readStr(8192)

proc absorbOutput(job: GitJob) {.gcsafe.} =
  let chunk = job.readAvailable()
  if chunk.len == 0: return
  let bounded = appendBoundedGitOutput(job.result.output, chunk)
  job.result.output = bounded.output
  job.result.outputTruncated = job.result.outputTruncated or bounded.truncated

proc cancel*(job: GitJob) {.gcsafe.}
proc poll*(job: GitJob): bool {.gcsafe.}
proc startGitJobInput*(repository: GitRepository; args: openArray[string];
                       input: string): GitJob

proc gitProcessOptions(): set[ProcessOption] =
  {poUsePath, poStdErrToStdOut}

proc newGitJob(process: Process): GitJob {.gcsafe.} =
  result = GitJob(process: process, output: process.peekableOutputStream())

var gitRepositoryCache: ptr Table[string, GitRepository]
gitRepositoryCache = cast[ptr Table[string, GitRepository]](
  allocShared0(sizeof(Table[string, GitRepository])))

proc clearGitRepositoryCache*() =
  ## Call this when the worktree layout can have changed under us -- a clone,
  ## a `git init`, a workspace switch. Resolution is otherwise stable for the
  ## life of a path.
  gitRepositoryCache[].clear()

proc hasCachedGitRepository*(root: string): bool =
  gitRepositoryCache[].hasKey(root)

proc cachedGitRepository*(root: string): GitRepository =
  if gitRepositoryCache[].hasKey(root): result = gitRepositoryCache[][root]

proc resolveGitRepositorySync(root: string): GitRepository =
  ## Resolution spawns `git rev-parse --show-toplevel` and blocks the caller
  ## until it answers. That is fine once per document; it is not fine per input
  ## event, which is what the editor's per-event resync was doing -- a profile
  ## of a scroll burst found the main thread parked in nanosleep inside this
  ## probe.
  let absolute = absolutePath(root)
  if not dirExists(absolute):
    return nil
  var probe: Process
  try:
    probe = startProcess("git", "", @["-C", absolute, "rev-parse", "--show-toplevel"],
      options = gitProcessOptions())
  except CatchableError:
    return nil
  let job = newGitJob(probe)
  let startedAt = epochTime()
  while not job.poll():
    if (epochTime() - startedAt) * 1_000.0 >= float64(GitProbeTimeoutMs):
      job.cancel()
      # A timeout is not an answer about the path; do not remember it.
      return nil
    sleep(1)
  if job.result.exitCode != 0 or job.result.outputTruncated:
    return nil
  let resolved = job.result.output.strip()
  if resolved.len == 0:
    return nil
  result = try: GitRepository(root: absolutePath(resolved))
    except CatchableError: nil

proc newGitRepository*(root: string; executor: BackgroundExecutor): Future[GitRepository] =
  ## Resolve Git off the caller's thread. The returned Future is owned by the
  ## caller; the worker never touches it and only returns a GitRepository value
  ## through BackgroundExecutor's main-thread completion path.
  ## a profile of a scroll burst found the main thread parked in nanosleep
  ## inside this probe, so the uncached probe must stay on the background path.
  if gitRepositoryCache[].hasKey(root):
    result = newFuture[GitRepository]("newGitRepository.cached")
    result.complete(gitRepositoryCache[][root])
    return
  if executor == nil:
    result = newFuture[GitRepository]("newGitRepository.invalid-executor")
    result.complete(nil)
    return
  let future = newFuture[GitRepository]("newGitRepository")
  let probe = executor.spawn(proc(): GitRepository {.gcsafe.} =
    resolveGitRepositorySync(root))
  probe.addCallback(proc(probe: Future[GitRepository]) =
    if probe.failed:
      future.fail(probe.readError)
      return
    let repository = probe.read
    gitRepositoryCache[][root] = repository
    future.complete(repository)
  )
  future

proc newGitRepositorySync*(root: string): GitRepository =
  ## Compatibility path for callers that already run outside the UI loop.
  ## New UI code must use newGitRepository(root, BackgroundExecutor).
  if gitRepositoryCache[].hasKey(root): return gitRepositoryCache[][root]
  result = resolveGitRepositorySync(root)
  gitRepositoryCache[][root] = result

proc repositoryForPath*(path: string): GitRepository =
  ## Resolve a repository from the document's own location. This remains
  ## correct when a restored session opens a file outside the active workspace
  ## roots, and `git rev-parse --show-toplevel` selects the enclosing worktree.
  if path.len == 0: return nil
  let absolute = absolutePath(path)
  let probe = if dirExists(absolute): absolute else: splitFile(absolute).dir
  newGitRepositorySync(probe)

proc firstRepositoryForPaths*(paths: openArray[string]): GitRepository =
  ## A workspace can be useful before it has an open file. Resolve its Git
  ## context from the configured roots in their workspace order, skipping
  ## ordinary folders without making a document selection a prerequisite for
  ## history, status, or branch operations.
  for path in paths:
    result = repositoryForPath(path)
    if result != nil: return

proc runGit*(repository: GitRepository; args: openArray[string]): GitResult =
  if repository == nil: return GitResult(exitCode: -1, output: "not a git repository")
  var commandArgs = @["-C", repository.root]
  commandArgs.add(args)
  let process = startProcess("git", "", commandArgs,
    options = gitProcessOptions())
  var job = newGitJob(process)
  while not job.poll():
    sleep(1)
  result = job.result

proc runGitInput(repository: GitRepository; args: openArray[string]; input: string): GitResult =
  if repository == nil: return GitResult(exitCode: -1, output: "not a git repository")
  var commandArgs = @["-C", repository.root]
  commandArgs.add(args)
  let job = repository.startGitJobInput(args, input)
  while not job.poll():
    sleep(1)
  result = job.result

proc startGitJob*(repository: GitRepository; args: openArray[string]): GitJob =
  if repository == nil: return GitJob(done: true,
    result: GitResult(exitCode: -1, output: "not a git repository"))
  var commandArgs = @["-C", repository.root]
  commandArgs.add(args)
  let process = startProcess("git", "", commandArgs,
    options = gitProcessOptions())
  result = newGitJob(process)

proc startGitJobInput*(repository: GitRepository; args: openArray[string];
                       input: string): GitJob =
  ## Start a cancellable Git process with a bounded patch/input payload.
  ## The caller must keep the payload small enough to write before polling;
  ## this is intended for one diff hunk, not repository-sized stdin.
  result = repository.startGitJob(args)
  if result == nil or result.done: return
  try:
    result.process.inputStream.write(input)
    result.process.inputStream.close()
  except CatchableError:
    result.cancel()

proc cancel*(job: GitJob) {.gcsafe.} =
  if job == nil or job.done: return
  job.cancelled = true
  if job.process != nil and job.process.running:
    ## Cancelling a Git refresh must never propagate to the terminal that
    ## launched Nimculus.  Keep the cancellation boundary to the exact child
    ## Process created for this job.
    job.process.terminate()
    let exitCode = job.process.waitForExit(1_000)
    if exitCode < 0:
      job.process.kill()
      discard job.process.waitForExit(1_000)
  job.absorbOutput()
  if job.process != nil: job.process.close()
  job.result.exitCode = -1
  if job.result.output.len == 0: job.result.output = "cancelled"
  job.done = true

proc poll*(job: GitJob): bool {.gcsafe.} =
  if job == nil: return true
  if job.done: return true
  # Drain while the child is still running. Waiting for its exit before
  # reading stdout can deadlock a verbose Git command on a full pipe.
  job.absorbOutput()
  let exitCode = job.process.peekExitCode()
  if exitCode < 0: return false
  job.absorbOutput()
  job.result.exitCode = exitCode
  job.absorbOutput()
  job.process.close()
  job.done = true
  true

proc parseStatus*(output: string): seq[GitStatusEntry] =
  ## Parse porcelain-v1 NUL output. Git emits a second pathname for rename/copy.
  let records = output.split('\0')
  var index = 0
  while index < records.len:
    let record = records[index]
    inc index
    if record.len < 3: continue
    let x = record[0]
    let y = record[1]
    var path = record[3 .. ^1]
    var original = ""
    if x in {'R', 'C'} or y in {'R', 'C'}:
      if index < records.len:
        original = records[index]
        inc index
    result.add(GitStatusEntry(indexStatus: x, worktreeStatus: y,
      path: path, originalPath: original,
      conflict: x == 'U' or y == 'U' or (x == 'A' and y == 'A') or
        (x == 'D' and y == 'D')))

proc status*(repository: GitRepository): seq[GitStatusEntry] =
  let output = repository.runGit(["status", "--porcelain=v1", "--untracked-files=all", "-z"])
  if output.exitCode == 0: result = parseStatus(output.output)

proc diff*(repository: GitRepository; path = ""; staged = false): GitResult =
  var args = @["diff", "--no-ext-diff", "--unified=3"]
  if staged: args.add("--cached")
  if path.len > 0:
    args.add("--")
    args.add(path)
  repository.runGit(args)

proc parseDiffRange(value: string): tuple[start, count: int] =
  var range = value
  if range.len > 0 and range[0] in {'-', '+'}: range = range[1 .. ^1]
  let comma = range.find(',')
  try:
    if comma < 0: (parseInt(range), 1)
    else: (parseInt(range[0 ..< comma]), parseInt(range[comma + 1 .. ^1]))
  except ValueError:
    (0, 0)

proc appendChangedLine(hunk: var GitDiffHunk; line: int) =
  if hunk.changedRanges.len > 0:
    let last = hunk.changedRanges.high
    if hunk.changedRanges[last].startLine + hunk.changedRanges[last].lineCount == line:
      inc hunk.changedRanges[last].lineCount
      return
  hunk.changedRanges.add(GitDiffLineRange(startLine: line, lineCount: 1))

proc gitHunkThemeRole*(kind: GitDiffHunkKind): string =
  case kind
  of gitHunkAdded: "added"
  of gitHunkDeleted: "deleted"
  of gitHunkModified: "modified"

proc gutterLineRanges*(hunk: GitDiffHunk): seq[GitDiffLineRange] =
  ## Return only lines represented by +/- records, not unified-diff context.
  ## A deletion has no line in the new file, so its marker occupies the line
  ## at the deletion insertion point, matching Zed's gutter behavior.
  if hunk.changedRanges.len > 0:
    return hunk.changedRanges
  if hunk.kind == gitHunkDeleted:
    return @[GitDiffLineRange(startLine: max(1, hunk.newStart), lineCount: 1)]

proc parseDiffHunks*(output: string): seq[GitDiffHunk] =
  ## Convert unified diff headers into stable line ranges for inline/gutter UI.
  ## Body lines are counted only after a header, so file metadata cannot alter
  ## the current hunk's added/removed counts.
  var current = -1
  var currentPatch: seq[string]
  var oldLine = 0
  var newLine = 0
  for line in output.splitLines:
    if line.startsWith("@@ "):
      if current >= 0:
        result[current].patchText = currentPatch.join("\n") & "\n"
      let fields = line.splitWhitespace()
      if fields.len < 3: continue
      let oldRange = parseDiffRange(fields[1])
      let newRange = parseDiffRange(fields[2])
      result.add(GitDiffHunk(oldStart: oldRange.start, oldCount: oldRange.count,
        newStart: newRange.start, newCount: newRange.count,
        kind: if oldRange.count == 0: gitHunkAdded
          elif newRange.count == 0: gitHunkDeleted else: gitHunkModified,
        changedRanges: @[]))
      current = result.high
      currentPatch = @[line]
      oldLine = oldRange.start
      newLine = newRange.start
    elif current >= 0 and line.len > 0:
      currentPatch.add(line)
      case line[0]
      of '+':
        inc result[current].addedLines
        result[current].appendChangedLine(newLine)
        inc newLine
      of '-':
        inc result[current].removedLines
        inc oldLine
      of ' ':
        inc oldLine
        inc newLine
      else: discard
  if current >= 0:
    result[current].patchText = currentPatch.join("\n") & "\n"

proc diffHunks*(repository: GitRepository; path = ""; staged = false): seq[GitDiffHunk] =
  let output = repository.diff(path, staged)
  if output.exitCode == 0: result = parseDiffHunks(output.output)

proc applyHunk*(repository: GitRepository; path: string; hunkIndex: int;
                reverse = false): GitResult =
  let diff = repository.diff(path, staged = reverse)
  if diff.exitCode != 0: return diff
  let hunks = parseDiffHunks(diff.output)
  if hunkIndex < 0 or hunkIndex >= hunks.len:
    return GitResult(exitCode: -1, output: "diff hunk index out of range")
  let headerEnd = diff.output.find("@@ ")
  if headerEnd < 0:
    return GitResult(exitCode: -1, output: "diff contains no hunk")
  let patch = diff.output[0 ..< headerEnd] & hunks[hunkIndex].patchText
  var args = @["apply", "--cached", "--whitespace=nowarn"]
  if reverse: args.add("--reverse")
  args.add("-")
  repository.runGitInput(args, patch)

proc stageHunk*(repository: GitRepository; path: string; hunkIndex: int): GitResult =
  repository.applyHunk(path, hunkIndex)

proc unstageHunk*(repository: GitRepository; path: string; hunkIndex: int): GitResult =
  repository.applyHunk(path, hunkIndex, reverse = true)

proc stage*(repository: GitRepository; paths: openArray[string]): GitResult =
  var args = @["add", "--"]
  args.add(paths)
  repository.runGit(args)

proc stageAll*(repository: GitRepository): GitResult =
  repository.runGit(["add", "-A"])

proc unstage*(repository: GitRepository; paths: openArray[string]): GitResult =
  var args = @["reset", "HEAD", "--"]
  args.add(paths)
  repository.runGit(args)

proc unstageAll*(repository: GitRepository): GitResult =
  repository.runGit(["reset", "HEAD"])

proc commit*(repository: GitRepository; message: string): GitResult =
  let subject = message.strip()
  if subject.len == 0:
    return GitResult(exitCode: -1, output: "Git commit message is empty")
  repository.runGit(["commit", "-m", subject])

proc amendCommit*(repository: GitRepository; message: string): GitResult =
  ## Amending is intentionally explicit. The caller must provide a new
  ## message, so this cannot accidentally reuse the prior subject.
  let subject = message.strip()
  if subject.len == 0:
    return GitResult(exitCode: -1, output: "Git amend message is empty")
  repository.runGit(["commit", "--amend", "-m", subject])

proc checkout*(repository: GitRepository; source: string;
               paths: openArray[string]): GitResult =
  if source.len == 0: return GitResult(exitCode: -1, output: "checkout source is empty")
  var args = @["checkout", source, "--"]
  args.add(paths)
  repository.runGit(args)

proc currentBranch*(repository: GitRepository): string =
  let output = repository.runGit(["symbolic-ref", "--quiet", "--short", "HEAD"])
  if output.exitCode == 0: result = output.output.strip()
  else: result = "(detached)"

proc parseBranches*(output: string): seq[GitBranch] =
  ## `git branch --format=%(HEAD)%(refname:short)` is one branch per line.
  ## The leading HEAD marker is `*` for the active local branch and a space
  ## otherwise; parsing this stable, machine-oriented format avoids terminal
  ## coloring and localization.
  for line in output.splitLines:
    if line.len < 2: continue
    let name = line[1 .. ^1].strip()
    if name.len > 0:
      result.add(GitBranch(name: name, current: line[0] == '*'))

proc branches*(repository: GitRepository): seq[GitBranch] =
  if repository == nil: return
  let output = repository.runGit(["branch", "--format=%(HEAD)%(refname:short)"])
  if output.exitCode == 0: result = parseBranches(output.output)

proc isSafeBranchName*(branch: string): bool =
  ## Reject option-looking and control-character input before constructing a
  ## Git command. Git still performs its authoritative ref-format validation.
  let name = branch.strip()
  if name.len == 0 or name.startsWith('-'): return false
  for character in name:
    if ord(character) < 32 or ord(character) == 127: return false
  true

proc switchBranch*(repository: GitRepository; branch: string): GitResult =
  ## Switch only to an existing local branch. `--no-guess` prevents an editor
  ## command from implicitly creating/tracking a remote branch, and Git's
  ## normal safety checks refuse a switch that would lose worktree changes.
  let name = branch.strip()
  if repository == nil:
    return GitResult(exitCode: -1, output: "Git repository not found")
  if not isSafeBranchName(name):
    return GitResult(exitCode: -1, output: "Git branch name is invalid")
  let validation = repository.runGit(["check-ref-format", "--branch", name])
  if validation.exitCode != 0:
    return GitResult(exitCode: -1, output: "Git branch name is invalid")
  repository.runGit(["switch", "--no-guess", name])

proc head*(repository: GitRepository): string =
  let output = repository.runGit(["rev-parse", "HEAD"])
  if output.exitCode == 0: result = output.output.strip()

proc parseLog*(output: string; limit = 50): seq[GitCommit] =
  let fields = output.split('\0')
  var index = 0
  while index + 4 < fields.len and result.len < max(1, limit):
    if fields[index].len == 0: break
    try:
      result.add(GitCommit(hash: fields[index], author: fields[index + 1],
        email: fields[index + 2], timestamp: parseInt(fields[index + 3]),
        subject: fields[index + 4]))
    except ValueError: discard
    index += 5

proc log*(repository: GitRepository; limit = 50): seq[GitCommit] =
  let output = repository.runGit(["log", "--format=%H%x00%an%x00%ae%x00%at%x00%s%x00",
    "-n", $max(1, limit)])
  if output.exitCode == 0: result = parseLog(output.output, limit)

proc logPath*(repository: GitRepository; path: string; limit = 50): seq[GitCommit] =
  ## Keep path history distinct from repository history. `--` prevents a
  ## file name from being interpreted as a revision or a Git option.
  let relativePath = path.strip()
  if repository == nil or relativePath.len == 0: return
  let output = repository.runGit(["log", "--format=%H%x00%an%x00%ae%x00%at%x00%s%x00",
    "-n", $max(1, limit), "--", relativePath])
  if output.exitCode == 0: result = parseLog(output.output, limit)

proc showCommit*(repository: GitRepository; revision: string): GitResult =
  ## Return bounded, self-contained commit metadata and its patch for the
  ## history panel. Disable external diff drivers: opening a history entry
  ## must not execute repository-configured tools from the editor process.
  if repository == nil:
    return GitResult(exitCode: -1, output: "Git repository not found")
  if revision.strip.len == 0:
    return GitResult(exitCode: -1, output: "Git revision is empty")
  repository.runGit(["show", "--format=fuller", "--stat", "--patch",
    "--no-ext-diff", revision])

proc showCommitPath*(repository: GitRepository; revision, path: string): GitResult =
  ## The file-history detail view must retain its path filter. Place the
  ## pathspec after `--`, independently of the commit revision.
  let relativePath = path.strip()
  if relativePath.len == 0:
    return showCommit(repository, revision)
  if repository == nil:
    return GitResult(exitCode: -1, output: "Git repository not found")
  if revision.strip.len == 0:
    return GitResult(exitCode: -1, output: "Git revision is empty")
  repository.runGit(["show", "--format=fuller", "--stat", "--patch",
    "--no-ext-diff", revision, "--", relativePath])

proc parseBlame*(output: string): seq[GitBlameLine] =
  var current = GitBlameLine()
  var haveHeader = false
  for line in output.splitLines:
    let fields = line.splitWhitespace()
    if fields.len >= 4 and fields[0].len == 40 and fields[1].allCharsInSet({'0'..'9'}):
      current = GitBlameLine(hash: fields[0], line: parseInt(fields[2]))
      haveHeader = true
    elif haveHeader and line.startsWith("author "):
      current.author = line[7 .. ^1]
    elif haveHeader and line.startsWith("author-time "):
      try:
        current.authorTime = parseInt(line[12 .. ^1])
        current.authorTimeValid = true
      except ValueError:
        current.authorTime = 0
    elif haveHeader and line.startsWith("summary "):
      current.summary = line[8 .. ^1]
    elif haveHeader and line.startsWith("\t"):
      current.text = line[1 .. ^1]
      result.add(current)
      haveHeader = false

proc blame*(repository: GitRepository; path: string): seq[GitBlameLine] =
  let output = repository.runGit(["blame", "--line-porcelain", "--", path])
  if output.exitCode == 0: result = parseBlame(output.output)

proc conflictPaths*(repository: GitRepository): seq[string] =
  for entry in repository.status():
    if entry.conflict: result.add(entry.path)
