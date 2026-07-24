import std/osproc
import std/streams
import std/strtabs
import std/strutils
import std/envvars
when defined(posix):
  import std/posix

when defined(posix):
  ## PipeOutStream wraps FileStream privately. Keep a layout-compatible view so
  ## task polling can use the same non-blocking POSIX boundary as the LSP.
  type
    TaskFileStreamObj = object of Stream
      f: File
    TaskFileStream = ref TaskFileStreamObj

type
  TaskStatus* = enum
    taskRunning, taskSucceeded, taskFailed, taskCancelled

  TaskSpec* = object
    command*: string
    args*: seq[string]
    workingDirectory*: string
    environment*: seq[tuple[key, value: string]]

  TaskProblem* = object
    path*: string
    line*: int
    column*: int
    message*: string

  TaskResult* = object
    status*: TaskStatus
    exitCode*: int
    output*: string
    outputTruncated*: bool
    problems*: seq[TaskProblem]

  TaskJob* = ref object
    process: Process
    output: Stream
    ## Set only after verifying the POSIX spawn-created child group. Keeping
    ## this optional prevents a failed group setup from ever signaling the
    ## editor's own process group.
    processGroupId*: Pid
    result*: TaskResult
    done*: bool

const MaxTaskOutputBytes* = 4 * 1024 * 1024

proc appendBoundedTaskOutput*(current, chunk: string;
    limit: int = MaxTaskOutputBytes): tuple[output: string, truncated: bool] =
  ## Keep task output bounded while retaining the newest complete lines.
  ## The byte limit is applied only at UTF-8 boundaries.
  if chunk.len == 0:
    return (current, false)
  let combined = current & chunk
  if limit <= 0:
    return ("", combined.len > 0)
  if combined.len <= limit:
    return (combined, false)

  var start = combined.len - limit
  while start < combined.len and
      (ord(combined[start]) and 0xC0) == 0x80:
    inc start
  let lineBreak = combined.find('\n', start)
  if lineBreak >= 0:
    start = lineBreak + 1
  if start >= combined.len:
    return ("", true)
  (combined[start .. ^1], true)

proc readAvailable(job: TaskJob): string =
  if job == nil or job.process == nil or job.output == nil: return
  when defined(posix):
    let stream = cast[TaskFileStream](job.output)
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

proc parseTaskProblems*(output: string): seq[TaskProblem] =
  ## Parse common compiler formats without treating unrelated log lines as
  ## diagnostics: path:line:column: message and path:line: message.
  for rawLine in output.splitLines:
    let fields = rawLine.strip.split(':')
    if fields.len < 3: continue
    for index in 0 .. fields.high - 2:
      try:
        let lineNumber = parseInt(fields[index + 1].strip)
        var columnNumber = 1
        var messageStart = index + 2
        try:
          columnNumber = parseInt(fields[index + 2].strip)
          messageStart = index + 3
        except ValueError: discard
        if messageStart > fields.high: continue
        let path = fields[0 .. index].join(":").strip
        let message = fields[messageStart .. ^1].join(":").strip
        if path.len == 0 or message.len == 0: continue
        result.add(TaskProblem(path: path, line: max(1, lineNumber),
          column: max(1, columnNumber), message: message))
        break
      except ValueError: discard

proc taskEnvironment(spec: TaskSpec): StringTableRef =
  if spec.environment.len == 0: return nil
  result = newStringTable(modeCaseSensitive)
  for entry in envPairs(): result[entry.key] = entry.value
  for entry in spec.environment:
    if entry.key.len > 0: result[entry.key] = entry.value

when defined(posix):
  proc getpgid(pid: Pid): Pid {.importc, header: "<unistd.h>".}

proc taskProcessOptions(): set[ProcessOption] =
  result = {poUsePath, poStdErrToStdOut}
  when defined(posix):
    # Nim's POSIX spawn path implements poDaemon with
    # POSIX_SPAWN_SETPGROUP. Unlike a parent-side setpgid call, this happens
    # before exec and cannot race a fast shell command.
    result.incl(poDaemon)

proc configureTaskProcessGroup(job: TaskJob) =
  ## Match Zed's Unix task ownership: descendants belong to the task, not the
  ## editor. Verify the child-side spawn group before ever using kill(-pid).
  when defined(posix):
    if job == nil or job.process == nil: return
    let pid = Pid(processID(job.process))
    if pid <= 0: return
    if getpgid(pid) == pid:
      job.processGroupId = pid

proc startTask*(spec: TaskSpec): TaskJob =
  if spec.command.strip.len == 0:
    return TaskJob(done: true,
      result: TaskResult(status: taskFailed, exitCode: -1, output: "task command is empty"))
  try:
    let process = startProcess(spec.command, spec.workingDirectory, spec.args,
      env = taskEnvironment(spec), options = taskProcessOptions())
    result = TaskJob(process: process, output: process.peekableOutputStream(),
      result: TaskResult(status: taskRunning, exitCode: -1))
    result.configureTaskProcessGroup()
  except CatchableError as error:
    result = TaskJob(done: true,
      result: TaskResult(status: taskFailed, exitCode: -1, output: error.msg))

proc cancel*(job: TaskJob) =
  if job == nil or job.done: return
  if job.process != nil and job.process.running:
    when defined(posix):
      if job.processGroupId > 0:
        discard kill(-job.processGroupId, SIGTERM)
      else:
        job.process.terminate()
    else:
      job.process.terminate()
    let exitCode = job.process.waitForExit(1_000)
    if exitCode < 0:
      when defined(posix):
        if job.processGroupId > 0:
          discard kill(-job.processGroupId, SIGKILL)
        else:
          job.process.kill()
      else:
        job.process.kill()
      discard job.process.waitForExit(1_000)
  let tail = job.readAvailable()
  if tail.len > 0:
    let bounded = appendBoundedTaskOutput(job.result.output, tail)
    job.result.output = bounded.output
    job.result.outputTruncated = job.result.outputTruncated or bounded.truncated
  job.process.close()
  job.result.status = taskCancelled
  job.result.exitCode = -1
  job.result.problems = parseTaskProblems(job.result.output)
  job.done = true

proc poll*(job: TaskJob): bool =
  if job == nil: return true
  if job.done: return true
  let exitCode = job.process.peekExitCode()
  let chunk = job.readAvailable()
  if chunk.len > 0:
    let bounded = appendBoundedTaskOutput(job.result.output, chunk)
    job.result.output = bounded.output
    job.result.outputTruncated = job.result.outputTruncated or bounded.truncated
    job.result.problems = parseTaskProblems(job.result.output)
  if exitCode < 0: return false
  job.result.exitCode = exitCode
  job.result.status = if exitCode == 0: taskSucceeded else: taskFailed
  let tail = job.readAvailable()
  if tail.len > 0:
    let bounded = appendBoundedTaskOutput(job.result.output, tail)
    job.result.output = bounded.output
    job.result.outputTruncated = job.result.outputTruncated or bounded.truncated
  job.result.problems = parseTaskProblems(job.result.output)
  job.process.close()
  job.done = true
  true

proc isSuccess*(job: TaskJob): bool =
  job != nil and job.done and job.result.status == taskSucceeded
