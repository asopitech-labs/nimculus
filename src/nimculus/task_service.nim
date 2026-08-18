import std/osproc
import std/json
import std/os
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

  TaskContext* = object
    ## Values available to project task templates. Empty strings and zero
    ## positions mean that the corresponding value is not available.
    file*: string
    relativeFile*: string
    dirname*: string
    filename*: string
    stem*: string
    worktreeRoot*: string
    row*: int
    column*: int

  TaskTemplate* = object
    ## A project task definition before its context-dependent values are
    ## resolved. `label` is the name used by the task picker/command palette.
    label*: string
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
    pid*: int
    result*: TaskResult
    done*: bool

const MaxTaskOutputBytes* = 4 * 1024 * 1024

const projectTaskFileNames = [
  ".nimculus" / "tasks.json",
  ".zed" / "tasks.json",
  "tasks.json"
]

proc taskJsonString(node: JsonNode, name: string, fallback = ""): string =
  if node != nil and node.kind == JObject and node.hasKey(name) and
      node[name].kind == JString:
    return node[name].getStr
  fallback

proc taskJsonStringList(node: JsonNode, name: string): seq[string] =
  if node == nil or node.kind != JObject or not node.hasKey(name): return
  let value = node[name]
  if value.kind == JArray:
    for item in value:
      if item.kind != JString:
        raise newException(ValueError, "task " & name & " entries must be strings")
      result.add(item.getStr)
  elif value.kind == JString:
    result = value.getStr.splitWhitespace
  else:
    raise newException(ValueError, "task " & name & " must be a string array")

proc taskJsonEnvironment(node: JsonNode, name: string): seq[tuple[key, value: string]] =
  if node == nil or node.kind != JObject or not node.hasKey(name): return
  let value = node[name]
  if value.kind != JObject:
    raise newException(ValueError, "task " & name & " must be an object")
  for key, item in value:
    if item.kind != JString:
      raise newException(ValueError, "task environment values must be strings")
    result.add((key, item.getStr))

proc taskTemplateFromJson(node: JsonNode, source: string): TaskTemplate =
  if node == nil or node.kind != JObject:
    raise newException(ValueError, "task entry in " & source & " must be an object")
  result.label = taskJsonString(node, "label", taskJsonString(node, "name"))
  result.command = taskJsonString(node, "command")
  if result.command.len == 0:
    raise newException(ValueError, "task entry in " & source & " has no command")
  result.args = taskJsonStringList(node, "args")
  result.workingDirectory = taskJsonString(node, "cwd",
    taskJsonString(node, "workingDirectory"))
  result.environment = taskJsonEnvironment(node, "env")
  if result.environment.len == 0:
    result.environment = taskJsonEnvironment(node, "environment")

proc loadTaskTemplates*(path: string): seq[TaskTemplate] =
  ## Load a Zed-compatible JSON task list. Both a top-level array and an
  ## object containing a `tasks` array are accepted so project files can carry
  ## a small amount of metadata if needed later.
  if not fileExists(path): return
  let root = try:
    parseJson(readFile(path))
  except CatchableError as error:
    raise newException(ValueError, "cannot parse task file " & path & ": " & error.msg)
  let entries = if root.kind == JArray: root
    elif root.kind == JObject and root.hasKey("tasks") and root["tasks"].kind == JArray:
      root["tasks"]
    else:
      raise newException(ValueError, "task file " & path & " must contain a task array")
  for entry in entries:
    result.add(taskTemplateFromJson(entry, path))

proc loadProjectTaskTemplates*(worktreeRoot: string): seq[TaskTemplate] =
  ## Project-local tasks live in `.nimculus/tasks.json`; `.zed/tasks.json`
  ## and a root `tasks.json` are accepted for easy migration from Zed and
  ## other task-file conventions. The first existing file wins.
  if worktreeRoot.len == 0: return
  for relativePath in projectTaskFileNames:
    let path = worktreeRoot / relativePath
    if fileExists(path): return loadTaskTemplates(path)

proc taskContextValue(ctx: TaskContext, name: string): tuple[found: bool; value: string] =
  case name
  of "NIMCULUS_FILE": (ctx.file.len > 0, ctx.file)
  of "NIMCULUS_RELATIVE_FILE": (ctx.relativeFile.len > 0, ctx.relativeFile)
  of "NIMCULUS_DIRNAME": (ctx.dirname.len > 0, ctx.dirname)
  of "NIMCULUS_FILENAME": (ctx.filename.len > 0, ctx.filename)
  of "NIMCULUS_STEM": (ctx.stem.len > 0, ctx.stem)
  of "NIMCULUS_WORKTREE_ROOT": (ctx.worktreeRoot.len > 0, ctx.worktreeRoot)
  of "NIMCULUS_ROW": (ctx.row > 0, $ctx.row)
  of "NIMCULUS_COLUMN": (ctx.column > 0, $ctx.column)
  else: (false, "")

proc resolveTaskString(value: string, ctx: TaskContext, fieldName: string): string =
  var position = 0
  while true:
    let marker = value.find("${", position)
    if marker < 0:
      if position < value.len: result.add(value[position .. ^1])
      break
    result.add(value[position ..< marker])
    let closing = value.find('}', marker + 2)
    if closing < 0:
      raise newException(ValueError, "unterminated task variable in " & fieldName)
    let expression = value[marker + 2 ..< closing]
    let separator = expression.find(':')
    let name = if separator < 0: expression else: expression[0 ..< separator]
    let defaultValue = if separator < 0: "" else: expression[separator + 1 .. ^1]
    let resolved = taskContextValue(ctx, name)
    if resolved.found:
      result.add(resolved.value)
    elif separator >= 0:
      result.add(defaultValue)
    else:
      raise newException(ValueError, "task variable " & name &
        " is unavailable in " & fieldName)
    position = closing + 1

proc resolveTaskTemplate*(t: TaskTemplate, ctx: TaskContext): TaskSpec =
  ## Resolve every command, argument, working-directory, and environment
  ## value. Missing values are errors rather than silently becoming empty
  ## strings, which is especially important for an absent worktree root.
  result.command = resolveTaskString(t.command, ctx, "command")
  if result.command.strip.len == 0:
    raise newException(ValueError, "resolved task command is empty")
  for index, arg in t.args:
    result.args.add(resolveTaskString(arg, ctx, "args[" & $index & "]"))
  result.workingDirectory = resolveTaskString(t.workingDirectory, ctx, "cwd")
  for entry in t.environment:
    result.environment.add((entry.key,
      resolveTaskString(entry.value, ctx, "environment[" & entry.key & "]")))

proc appendBoundedTaskOutput*(current, chunk: string;
    limit: int = MaxTaskOutputBytes): tuple[output: string; truncated: bool] =
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

proc taskProcessOptions(): set[ProcessOption] =
  {poUsePath, poStdErrToStdOut}

proc startTask*(spec: TaskSpec): TaskJob =
  if spec.command.strip.len == 0:
    return TaskJob(done: true,
      result: TaskResult(status: taskFailed, exitCode: -1, output: "task command is empty"))
  try:
    let process = startProcess(spec.command, spec.workingDirectory, spec.args,
      env = taskEnvironment(spec), options = taskProcessOptions())
    result = TaskJob(process: process, output: process.peekableOutputStream(),
      pid: process.processID(),
      result: TaskResult(status: taskRunning, exitCode: -1))
  except CatchableError as error:
    result = TaskJob(done: true,
      result: TaskResult(status: taskFailed, exitCode: -1, output: error.msg))

proc cancel*(job: TaskJob) =
  if job == nil or job.done: return
  if job.process != nil and job.process.running:
    ## Do not signal a process group here.  The editor is frequently launched
    ## from an interactive terminal, and a group-level signal is an unsafe
    ## boundary for a UI action: it can include the launcher or its tools.
    ## The Process handle represents the task leader we created, so it is the
    ## only process cancellation is allowed to address.
    job.process.terminate()
    let exitCode = job.process.waitForExit(1_000)
    if exitCode < 0:
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

proc processId*(job: TaskJob): int =
  ## Keep the direct child identity available after the process handle is
  ## closed. DAP `runInTerminal` responses use this identity for attach.
  if job == nil: 0 else: job.pid
