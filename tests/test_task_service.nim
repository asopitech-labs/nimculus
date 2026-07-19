import std/os
import std/unittest
import nimculus/task_service

suite "M10 task service":
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
