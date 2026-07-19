import std/osproc
import std/streams
import std/strtabs
import std/strutils
import std/envvars

type
  TaskStatus* = enum
    taskRunning, taskSucceeded, taskFailed, taskCancelled

  TaskSpec* = object
    command*: string
    args*: seq[string]
    workingDirectory*: string
    environment*: seq[tuple[key, value: string]]

  TaskResult* = object
    status*: TaskStatus
    exitCode*: int
    output*: string

  TaskJob* = ref object
    process: Process
    result*: TaskResult
    done*: bool

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
    result = TaskJob(process: process,
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
  if exitCode < 0: return false
  job.result.exitCode = exitCode
  job.result.status = if exitCode == 0: taskSucceeded else: taskFailed
  job.result.output = job.process.outputStream.readAll()
  job.process.close()
  job.done = true
  true

proc isSuccess*(job: TaskJob): bool =
  job != nil and job.done and job.result.status == taskSucceeded
