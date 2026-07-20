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
    problems*: seq[TaskProblem]

  TaskJob* = ref object
    process: Process
    output: Stream
    result*: TaskResult
    done*: bool

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

proc startTask*(spec: TaskSpec): TaskJob =
  if spec.command.strip.len == 0:
    return TaskJob(done: true,
      result: TaskResult(status: taskFailed, exitCode: -1, output: "task command is empty"))
  try:
    let process = startProcess(spec.command, spec.workingDirectory, spec.args,
      env = taskEnvironment(spec), options = {poUsePath, poStdErrToStdOut})
    result = TaskJob(process: process, output: process.peekableOutputStream(),
      result: TaskResult(status: taskRunning, exitCode: -1))
  except CatchableError as error:
    result = TaskJob(done: true,
      result: TaskResult(status: taskFailed, exitCode: -1, output: error.msg))

proc cancel*(job: TaskJob) =
  if job == nil or job.done: return
  job.process.terminate()
  discard job.process.waitForExit()
  job.process.close()
  job.result = TaskResult(status: taskCancelled, exitCode: -1, output: "cancelled")
  job.done = true

proc poll*(job: TaskJob): bool =
  if job == nil: return true
  if job.done: return true
  let exitCode = job.process.peekExitCode()
  let chunk = job.readAvailable()
  if chunk.len > 0:
    job.result.output.add(chunk)
    job.result.problems = parseTaskProblems(job.result.output)
  if exitCode < 0: return false
  job.result.exitCode = exitCode
  job.result.status = if exitCode == 0: taskSucceeded else: taskFailed
  let tail = job.readAvailable()
  if tail.len > 0: job.result.output.add(tail)
  job.result.problems = parseTaskProblems(job.result.output)
  job.process.close()
  job.done = true
  true

proc isSuccess*(job: TaskJob): bool =
  job != nil and job.done and job.result.status == taskSucceeded
