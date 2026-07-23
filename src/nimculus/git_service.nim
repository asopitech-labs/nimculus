import std/os
import std/osproc
import std/streams
import std/strutils
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

  GitCommit* = object
    hash*: string
    author*: string
    email*: string
    timestamp*: int64
    subject*: string

  GitBlameLine* = object
    hash*: string
    author*: string
    summary*: string
    line*: int
    text*: string

  GitDiffHunkKind* = enum
    gitHunkAdded, gitHunkDeleted, gitHunkModified

  GitDiffHunk* = object
    oldStart*, oldCount*: int
    newStart*, newCount*: int
    addedLines*, removedLines*: int
    kind*: GitDiffHunkKind
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

proc appendBoundedGitOutput*(current, chunk: string;
    limit: int = MaxGitOutputBytes): tuple[output: string, truncated: bool] =
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

proc readAvailable(job: GitJob): string =
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

proc absorbOutput(job: GitJob) =
  let chunk = job.readAvailable()
  if chunk.len == 0: return
  let bounded = appendBoundedGitOutput(job.result.output, chunk)
  job.result.output = bounded.output
  job.result.outputTruncated = job.result.outputTruncated or bounded.truncated

proc cancel*(job: GitJob)
proc poll*(job: GitJob): bool
proc startGitJobInput*(repository: GitRepository, args: openArray[string],
                       input: string): GitJob

proc newGitRepository*(root: string): GitRepository =
  let absolute = absolutePath(root)
  if not dirExists(absolute): return nil
  let probe = startProcess("git", "", @["-C", absolute, "rev-parse", "--show-toplevel"],
    options = {poUsePath, poStdErrToStdOut})
  let output = probe.outputStream.readStr(MaxGitOutputBytes)
  let exitCode = probe.waitForExit()
  probe.close()
  if exitCode != 0: return nil
  let resolved = output.strip()
  if resolved.len == 0: return nil
  GitRepository(root: absolutePath(resolved))

proc runGit*(repository: GitRepository, args: openArray[string]): GitResult =
  if repository == nil: return GitResult(exitCode: -1, output: "not a git repository")
  var commandArgs = @["-C", repository.root]
  commandArgs.add(args)
  let process = startProcess("git", "", commandArgs,
    options = {poUsePath, poStdErrToStdOut})
  var job = GitJob(process: process, output: process.peekableOutputStream())
  while not job.poll():
    sleep(1)
  result = job.result

proc runGitInput(repository: GitRepository, args: openArray[string], input: string): GitResult =
  if repository == nil: return GitResult(exitCode: -1, output: "not a git repository")
  var commandArgs = @["-C", repository.root]
  commandArgs.add(args)
  let job = repository.startGitJobInput(args, input)
  while not job.poll():
    sleep(1)
  result = job.result

proc startGitJob*(repository: GitRepository, args: openArray[string]): GitJob =
  if repository == nil: return GitJob(done: true,
    result: GitResult(exitCode: -1, output: "not a git repository"))
  var commandArgs = @["-C", repository.root]
  commandArgs.add(args)
  let process = startProcess("git", "", commandArgs,
    options = {poUsePath, poStdErrToStdOut})
  result = GitJob(process: process, output: process.peekableOutputStream())

proc startGitJobInput*(repository: GitRepository, args: openArray[string],
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

proc cancel*(job: GitJob) =
  if job == nil or job.done: return
  job.cancelled = true
  if job.process != nil and job.process.running:
    job.process.terminate()
    let exitCode = job.process.waitForExit(1_000)
    if exitCode < 0:
      job.process.kill()
      discard job.process.waitForExit(1_000)
  job.process.close()
  job.result = GitResult(exitCode: -1, output: "cancelled")
  job.done = true

proc poll*(job: GitJob): bool =
  if job == nil: return true
  if job.done: return true
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

proc diff*(repository: GitRepository, path = "", staged = false): GitResult =
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

proc parseDiffHunks*(output: string): seq[GitDiffHunk] =
  ## Convert unified diff headers into stable line ranges for inline/gutter UI.
  ## Body lines are counted only after a header, so file metadata cannot alter
  ## the current hunk's added/removed counts.
  var current = -1
  var currentPatch: seq[string]
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
          elif newRange.count == 0: gitHunkDeleted else: gitHunkModified))
      current = result.high
      currentPatch = @[line]
    elif current >= 0 and line.len > 0:
      currentPatch.add(line)
      if line[0] == '+': inc result[current].addedLines
      elif line[0] == '-': inc result[current].removedLines
  if current >= 0:
    result[current].patchText = currentPatch.join("\n") & "\n"

proc diffHunks*(repository: GitRepository, path = "", staged = false): seq[GitDiffHunk] =
  let output = repository.diff(path, staged)
  if output.exitCode == 0: result = parseDiffHunks(output.output)

proc applyHunk*(repository: GitRepository, path: string, hunkIndex: int,
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

proc stageHunk*(repository: GitRepository, path: string, hunkIndex: int): GitResult =
  repository.applyHunk(path, hunkIndex)

proc unstageHunk*(repository: GitRepository, path: string, hunkIndex: int): GitResult =
  repository.applyHunk(path, hunkIndex, reverse = true)

proc stage*(repository: GitRepository, paths: openArray[string]): GitResult =
  var args = @["add", "--"]
  args.add(paths)
  repository.runGit(args)

proc stageAll*(repository: GitRepository): GitResult =
  repository.runGit(["add", "-A"])

proc unstage*(repository: GitRepository, paths: openArray[string]): GitResult =
  var args = @["reset", "HEAD", "--"]
  args.add(paths)
  repository.runGit(args)

proc unstageAll*(repository: GitRepository): GitResult =
  repository.runGit(["reset", "HEAD"])

proc commit*(repository: GitRepository, message: string): GitResult =
  repository.runGit(["commit", "-m", message])

proc checkout*(repository: GitRepository, source: string,
               paths: openArray[string]): GitResult =
  if source.len == 0: return GitResult(exitCode: -1, output: "checkout source is empty")
  var args = @["checkout", source, "--"]
  args.add(paths)
  repository.runGit(args)

proc currentBranch*(repository: GitRepository): string =
  let output = repository.runGit(["symbolic-ref", "--quiet", "--short", "HEAD"])
  if output.exitCode == 0: result = output.output.strip()
  else: result = "(detached)"

proc head*(repository: GitRepository): string =
  let output = repository.runGit(["rev-parse", "HEAD"])
  if output.exitCode == 0: result = output.output.strip()

proc parseLog*(output: string, limit = 50): seq[GitCommit] =
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

proc log*(repository: GitRepository, limit = 50): seq[GitCommit] =
  let output = repository.runGit(["log", "--format=%H%x00%an%x00%ae%x00%at%x00%s%x00",
    "-n", $max(1, limit)])
  if output.exitCode == 0: result = parseLog(output.output, limit)

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
    elif haveHeader and line.startsWith("summary "):
      current.summary = line[8 .. ^1]
    elif haveHeader and line.startsWith("\t"):
      current.text = line[1 .. ^1]
      result.add(current)
      haveHeader = false

proc blame*(repository: GitRepository, path: string): seq[GitBlameLine] =
  let output = repository.runGit(["blame", "--line-porcelain", "--", path])
  if output.exitCode == 0: result = parseBlame(output.output)

proc conflictPaths*(repository: GitRepository): seq[string] =
  for entry in repository.status():
    if entry.conflict: result.add(entry.path)
