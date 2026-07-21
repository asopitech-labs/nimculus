import std/os
import std/strutils
import std/unittest
import nimculus/task_service

suite "M10 task service":
  test "matches common compiler problem locations":
    let problems = parseTaskProblems("src/main.nim:12:7: undeclared identifier\n" &
      "src/other.nim:4: warning: unused import\n" &
      "ordinary log line")
    check problems.len == 2
    check problems[0].path == "src/main.nim"
    check problems[0].line == 12
    check problems[0].column == 7
    check problems[1].column == 1
    check problems[1].message == "warning: unused import"

  test "runs a task with working directory and environment":
    let job = startTask(TaskSpec(command: "/bin/sh", args: @[
      "-c", "printf '%s:%s' \"$TASK_MARKER\" \"$(pwd)\""],
      workingDirectory: "/tmp", environment: @[ ("TASK_MARKER", "nimculus")]))
    for _ in 0 ..< 100:
      if job.poll(): break
      sleep(10)
    check job.isSuccess()
    check job.result.output == "nimculus:" & expandFilename("/tmp")

  test "preserves a nonzero exit status":
    let job = startTask(TaskSpec(command: "/bin/sh", args: @["-c", "printf fail; exit 7"]))
    for _ in 0 ..< 100:
      if job.poll(): break
      sleep(10)
    check job.result.status == taskFailed
    check job.result.exitCode == 7
    check job.result.output == "fail"

  test "cancels a long-running task":
    let job = startTask(TaskSpec(command: "/bin/sh", args: @["-c", "sleep 10"]))
    sleep(20)
    job.cancel()
    check job.done
    check job.result.status == taskCancelled

  test "makes task output available before process exit":
    let job = startTask(TaskSpec(command: "/bin/sh", args: @["-c",
      "printf first; sleep 1; printf second"]))
    var sawFirst = false
    for _ in 0 ..< 50:
      discard job.poll()
      if job.result.output.find("first") >= 0:
        sawFirst = true
        break
      sleep(10)
    check sawFirst
    job.cancel()

  test "bounds task output at a UTF-8 line boundary":
    let bounded = appendBoundedTaskOutput("old line\n", "あいうえお\nnew line\n", 12)
    check bounded.truncated
    check bounded.output == "new line\n"
    check bounded.output.len <= 12
