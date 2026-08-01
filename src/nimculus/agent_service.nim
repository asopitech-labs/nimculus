## CLI agent session service for macOS.
##
## Zed keeps an agent thread's process, working directory, output and
## worktree identity separate from the editor buffer.  Nimculus follows that
## boundary for CLI agents without embedding a JavaScript runtime: every
## session owns one directly-created child process and its own bounded output,
## prompt input, Git change snapshot and review patch.

import std/os
import std/osproc
import std/algorithm
import std/sequtils
import std/streams
import std/strutils
import std/tables
when defined(posix):
  import std/posix

when defined(posix):
  type
    AgentFileStreamObj = object of Stream
      f: File
    AgentFileStream = ref AgentFileStreamObj

type
  AgentProtocolError* = object of CatchableError

  AgentSessionState* = enum
    agentRunning
    agentExited
    agentStopped
    agentFailed

  AgentPollResult* = object
    output*: string
    done*: bool
    exitCode*: int
    state*: AgentSessionState
    changedPaths*: seq[string]

  AgentSession* = ref object
    id*: int
    command*: string
    args*: seq[string]
    workingDirectory*: string
    worktreePath*: string
    state*: AgentSessionState
    exitCode*: int
    process: Process
    input: Stream
    output: Stream
    retainedOutput*: string
    baselinePaths: seq[string]
    changedPaths*: seq[string]

  AgentManager* = ref object
    nextId: int
    sessions*: Table[int, AgentSession]
    activeId*: int

const MaxAgentOutputBytes* = 4 * 1024 * 1024

proc agentError(message: string): ref AgentProtocolError =
  newException(AgentProtocolError, message)

proc appendBoundedAgentOutput*(current, chunk: string;
    limit = MaxAgentOutputBytes): tuple[output: string, truncated: bool] =
  if chunk.len == 0: return (current, false)
  let combined = current & chunk
  if limit <= 0: return ("", true)
  if combined.len <= limit: return (combined, false)
  var start = combined.len - limit
  while start < combined.len and (ord(combined[start]) and 0xC0) == 0x80:
    inc start
  let lineBreak = combined.find('\n', start)
  if lineBreak >= 0: start = lineBreak + 1
  return (output: (if start < combined.len: combined[start .. ^1] else: ""),
    truncated: true)

proc processOptions(): set[ProcessOption] = {poUsePath, poInteractive, poStdErrToStdOut}

proc gitStatusPaths(root: string): seq[string] =
  if root.len == 0 or not dirExists(root): return
  try:
    let output = execProcess("git", args = ["status", "--porcelain=v1",
      "--untracked-files=all", "-z"], workingDir = root,
      options = {poUsePath, poStdErrToStdOut})
    var index = 0
    while index < output.len:
      let endIndex = output.find('\0', index)
      let raw = if endIndex < 0: output[index .. ^1] else: output[index ..< endIndex]
      if raw.len > 3:
        var path = raw[3 .. ^1]
        if path.contains(" -> "):
          path = path.split(" -> ")[^1]
        result.add(path)
      if endIndex < 0: break
      index = endIndex + 1
  except CatchableError:
    discard

proc newAgentSession*(id: int, command: string, args: openArray[string] = [],
                      workingDirectory: string; worktreePath = ""): AgentSession =
  if command.strip.len == 0: raise agentError("agent command is empty")
  if workingDirectory.len == 0 or not dirExists(workingDirectory):
    raise agentError("agent working directory does not exist")
  if worktreePath.len > 0 and not dirExists(worktreePath):
    raise agentError("agent worktree does not exist")
  let processDirectory = if worktreePath.len > 0: worktreePath else: workingDirectory
  try:
    let process = startProcess(command, processDirectory, args,
      options = processOptions())
    result = AgentSession(id: id, command: command, args: @args,
      workingDirectory: processDirectory,
      worktreePath: processDirectory,
      state: agentRunning, exitCode: -1, process: process,
      input: process.inputStream, output: process.peekableOutputStream())
    result.baselinePaths = gitStatusPaths(result.worktreePath)
  except CatchableError as error:
    raise agentError("could not start agent: " & error.msg)

proc isRunning*(session: AgentSession): bool =
  session != nil and session.state == agentRunning and session.process != nil and
    session.process.peekExitCode() < 0

proc sendInput*(session: AgentSession, input: string) =
  if session == nil or not session.isRunning: raise agentError("agent session is not running")
  session.input.write(input)
  session.input.flush()

proc sendPrompt*(session: AgentSession, prompt: string) =
  session.sendInput(prompt & "\n")

proc readAvailable(session: AgentSession): string =
  if session == nil or session.process == nil or session.output == nil: return
  when defined(posix):
    let stream = cast[AgentFileStream](session.output)
    if stream == nil or stream.f == nil: return
    let fd = cint(getOsFileHandle(stream.f))
    let flags = fcntl(fd, F_GETFL)
    if flags < 0 or fcntl(fd, F_SETFL, flags or O_NONBLOCK) < 0: return
    var bytes: array[8192, char]
    while true:
      let count = posix.read(fd, addr bytes[0], bytes.len)
      if count <= 0: break
      let oldLength = result.len
      result.setLen(oldLength + count)
      copyMem(addr result[oldLength], addr bytes[0], count)
  else:
    if session.process.hasData(): result = session.output.readStr(8192)

proc refreshChanges*(session: AgentSession): seq[string] =
  if session == nil: return
  session.changedPaths = gitStatusPaths(session.worktreePath)
  for path in session.changedPaths:
    if path notin session.baselinePaths: result.add(path)
  for path in session.baselinePaths:
    if path notin session.changedPaths: result.add(path)

proc poll*(session: AgentSession): AgentPollResult =
  if session == nil: return AgentPollResult(done: true, state: agentFailed, exitCode: -1)
  let chunk = session.readAvailable()
  result.output = chunk
  if chunk.len > 0:
    let bounded = appendBoundedAgentOutput(session.retainedOutput, chunk)
    session.retainedOutput = bounded.output
  if session.process != nil:
    let code = session.process.peekExitCode()
    if code >= 0:
      session.exitCode = code
      session.state = if code == 0: agentExited else: agentFailed
      let tail = session.readAvailable()
      if tail.len > 0:
        result.output.add(tail)
        let bounded = appendBoundedAgentOutput(session.retainedOutput, tail)
        session.retainedOutput = bounded.output
      discard session.refreshChanges()
  result.done = session.state != agentRunning
  result.exitCode = session.exitCode
  result.state = session.state
  result.changedPaths = session.refreshChanges()

proc stop*(session: AgentSession) =
  if session == nil: return
  if session.process != nil:
    if session.process.running:
      session.process.terminate()
      let code = session.process.waitForExit(1_000)
      if code < 0:
        session.process.kill()
        discard session.process.waitForExit(1_000)
    session.process.close()
  session.process = nil
  session.input = nil
  session.output = nil
  session.state = agentStopped
  session.exitCode = -1

proc currentDiff*(session: AgentSession): string =
  if session == nil or session.worktreePath.len == 0: return
  try:
    result = execProcess("git", args = ["diff", "--binary", "HEAD", "--"],
      workingDir = session.worktreePath, options = {poUsePath, poStdErrToStdOut})
  except CatchableError as error:
    raise agentError("could not collect agent diff: " & error.msg)

proc runGit(root: string, args: openArray[string]): tuple[code: int, output: string] =
  try:
    let process = startProcess("git", root, args, options = {poUsePath, poStdErrToStdOut})
    result.code = process.waitForExit(10_000)
    result.output = process.outputStream.readAll()
    process.close()
  except CatchableError as error:
    result.code = -1
    result.output = error.msg

proc applyPatch*(session: AgentSession, patch: string): bool =
  if session == nil or session.worktreePath.len == 0 or patch.len == 0: return false
  let path = getTempDir() / ("nimculus-agent-" & $session.id & ".patch")
  try:
    writeFile(path, patch)
    let check = runGit(session.worktreePath, ["apply", "--check", path])
    if check.code != 0: return false
    let applied = runGit(session.worktreePath, ["apply", path])
    if applied.code == 0:
      discard session.refreshChanges()
      return true
    false
  finally:
    if fileExists(path): removeFile(path)

proc rejectChanges*(session: AgentSession): bool =
  if session == nil or session.worktreePath.len == 0: return false
  let gitResult = runGit(session.worktreePath,
    ["restore", "--source=HEAD", "--worktree", "--staged", "--", "."])
  if gitResult.code == 0:
    discard session.refreshChanges()
    true
  else: false

proc newAgentManager*(): AgentManager =
  AgentManager(nextId: 1, sessions: initTable[int, AgentSession](), activeId: -1)

proc start*(manager: AgentManager, command: string, args: openArray[string],
            workingDirectory: string; worktreePath = ""): AgentSession =
  if manager == nil: raise agentError("agent manager is nil")
  result = newAgentSession(manager.nextId, command, args, workingDirectory, worktreePath)
  inc manager.nextId
  manager.sessions[result.id] = result
  manager.activeId = result.id

proc active*(manager: AgentManager): AgentSession =
  if manager == nil or manager.activeId notin manager.sessions: return nil
  manager.sessions[manager.activeId]

proc activate*(manager: AgentManager, id: int): bool =
  if manager == nil or id notin manager.sessions: return false
  manager.activeId = id
  true

proc sessionIds*(manager: AgentManager): seq[int] =
  if manager == nil: return
  for id in manager.sessions.keys: result.add(id)
  result.sort()

proc activateRelative*(manager: AgentManager, delta: int): bool =
  let ids = manager.sessionIds()
  if ids.len == 0: return false
  let current = ids.find(manager.activeId)
  let start = if current < 0: 0 else: current
  let index = ((start + delta) mod ids.len + ids.len) mod ids.len
  manager.activate(ids[index])

proc stop*(manager: AgentManager, id: int): bool =
  if manager == nil or id notin manager.sessions: return false
  manager.sessions[id].stop()
  manager.sessions.del(id)
  if manager.activeId == id:
    manager.activeId = if manager.sessions.len == 0: -1 else: toSeq(manager.sessions.keys)[^1]
  true

proc stopAll*(manager: AgentManager) =
  if manager == nil: return
  for _, session in manager.sessions.mpairs: session.stop()
  manager.sessions.clear()
  manager.activeId = -1
