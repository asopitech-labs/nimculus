import std/os
import std/osproc
import std/streams
import std/strutils

type
  GitResult* = object
    exitCode*: int
    output*: string

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

  GitJob* = ref object
    process: Process
    done*: bool
    cancelled*: bool
    result*: GitResult

  GitRepository* = ref object
    root*: string

proc newGitRepository*(root: string): GitRepository =
  let absolute = absolutePath(root)
  if not dirExists(absolute): return nil
  let probe = startProcess("git", "", @["-C", absolute, "rev-parse", "--show-toplevel"],
    options = {poUsePath, poStdErrToStdOut})
  let output = probe.outputStream.readAll()
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
  result.output = process.outputStream.readAll()
  result.exitCode = process.waitForExit()
  process.close()

proc startGitJob*(repository: GitRepository, args: openArray[string]): GitJob =
  if repository == nil: return GitJob(done: true,
    result: GitResult(exitCode: -1, output: "not a git repository"))
  var commandArgs = @["-C", repository.root]
  commandArgs.add(args)
  result = GitJob(process: startProcess("git", "", commandArgs,
    options = {poUsePath, poStdErrToStdOut}))

proc cancel*(job: GitJob) =
  if job == nil or job.done: return
  job.cancelled = true
  job.process.terminate()
  discard job.process.waitForExit()
  job.process.close()
  job.result = GitResult(exitCode: -1, output: "cancelled")
  job.done = true

proc poll*(job: GitJob): bool =
  if job == nil: return true
  if job.done: return true
  let exitCode = job.process.peekExitCode()
  if exitCode < 0: return false
  job.result.output = job.process.outputStream.readAll()
  job.result.exitCode = exitCode
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

proc currentBranch*(repository: GitRepository): string =
  let output = repository.runGit(["symbolic-ref", "--quiet", "--short", "HEAD"])
  if output.exitCode == 0: result = output.output.strip()
  else: result = "(detached)"

proc head*(repository: GitRepository): string =
  let output = repository.runGit(["rev-parse", "HEAD"])
  if output.exitCode == 0: result = output.output.strip()

proc log*(repository: GitRepository, limit = 50): seq[GitCommit] =
  let output = repository.runGit(["log", "--format=%H%x00%an%x00%ae%x00%at%x00%s%x00",
    "-n", $max(1, limit)])
  if output.exitCode != 0: return
  let fields = output.output.split('\0')
  var index = 0
  while index + 4 < fields.len:
    if fields[index].len == 0: break
    try:
      result.add(GitCommit(hash: fields[index], author: fields[index + 1],
        email: fields[index + 2], timestamp: parseInt(fields[index + 3]),
        subject: fields[index + 4]))
    except ValueError: discard
    index += 5

proc blame*(repository: GitRepository, path: string): seq[GitBlameLine] =
  let output = repository.runGit(["blame", "--line-porcelain", "--", path])
  if output.exitCode != 0: return
  var current = GitBlameLine()
  var haveHeader = false
  for line in output.output.splitLines:
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

proc conflictPaths*(repository: GitRepository): seq[string] =
  for entry in repository.status():
    if entry.conflict: result.add(entry.path)
