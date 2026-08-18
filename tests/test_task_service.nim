import std/os
import std/strutils
import std/unittest
import nimculus/task_service
import wait_support

suite "M10 task service":
  test "loads project templates and resolves editor variables":
    let root = getTempDir() / ("nimculus-task-template-" & $getCurrentProcessId())
    let metadata = root / ".nimculus"
    createDir(root)
    createDir(metadata)
    defer:
      removeFile(metadata / "tasks.json")
      removeDir(metadata)
      removeDir(root)
    writeFile(metadata / "tasks.json", """[
      {"label":"build","command":"nim","args":["c","${NIMCULUS_RELATIVE_FILE}"],
       "cwd":"${NIMCULUS_WORKTREE_ROOT}","env":{"TASK_FILE":"${NIMCULUS_FILENAME}"}}
    ]""")
    let templates = loadProjectTaskTemplates(root)
    check templates.len == 1
    let context = TaskContext(
      file: root / "src" / "main.nim",
      relativeFile: "src/main.nim",
      dirname: root / "src",
      filename: "main.nim",
      stem: "main",
      worktreeRoot: root,
      row: 4,
      column: 9)
    let spec = resolveTaskTemplate(templates[0], context)
    check spec.command == "nim"
    check spec.args == @["c", "src/main.nim"]
    check spec.workingDirectory == root
    check spec.environment == @[ ("TASK_FILE", "main.nim")]

  test "resolves all supplied task variables and honors defaults":
    let context = TaskContext(file: "/work/src/main.nim",
      relativeFile: "src/main.nim", dirname: "/work/src", filename: "main.nim",
      stem: "main", worktreeRoot: "/work", row: 12, column: 7)
    let taskTemplate = TaskTemplate(command:
      "${NIMCULUS_FILE}|${NIMCULUS_RELATIVE_FILE}|${NIMCULUS_DIRNAME}|" &
      "${NIMCULUS_FILENAME}|${NIMCULUS_STEM}|${NIMCULUS_WORKTREE_ROOT}|" &
      "${NIMCULUS_ROW}|${NIMCULUS_COLUMN}", args: @[
        "${NIMCULUS_FILENAME:fallback}", "${NIMCULUS_MISSING:default}"])
    let spec = resolveTaskTemplate(taskTemplate, context)
    check spec.command == "/work/src/main.nim|src/main.nim|/work/src|" &
      "main.nim|main|/work|12|7"
    check spec.args == @["main.nim", "default"]

    let absent = TaskContext()
    let defaultSpec = resolveTaskTemplate(TaskTemplate(command:
      "${NIMCULUS_FILENAME:fallback}"), absent)
    check defaultSpec.command == "fallback"
    expect ValueError:
      discard resolveTaskTemplate(TaskTemplate(command: "${NIMCULUS_WORKTREE_ROOT}"), absent)

  test "folder and single-file contexts keep worktree substitution distinct":
    let folder = TaskContext(file: "/project/src/main.nim",
      relativeFile: "src/main.nim", dirname: "/project/src", filename: "main.nim",
      stem: "main", worktreeRoot: "/project", row: 1, column: 1)
    let singleFile = TaskContext(file: "/tmp/main.nim", filename: "main.nim",
      dirname: "/tmp", stem: "main", row: 1, column: 1)
    let taskTemplate = TaskTemplate(command: "run", workingDirectory:
      "${NIMCULUS_WORKTREE_ROOT}", args: @["${NIMCULUS_RELATIVE_FILE}"])
    let folderSpec = resolveTaskTemplate(taskTemplate, folder)
    check folderSpec.workingDirectory == "/project"
    check folderSpec.args == @["src/main.nim"]
    expect ValueError:
      discard resolveTaskTemplate(taskTemplate, singleFile)

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
    let wait = waitForTest("successful task completion", condition = proc(): bool = job.poll())
    check checkTestWait(wait)
    check job.processId > 0
    check job.isSuccess()
    check job.result.output == "nimculus:" & expandFilename("/tmp")

  test "preserves a nonzero exit status":
    let job = startTask(TaskSpec(command: "/bin/sh", args: @["-c", "printf fail; exit 7"]))
    let wait = waitForTest("failed task completion", condition = proc(): bool = job.poll())
    check checkTestWait(wait)
    check job.result.status == taskFailed
    check job.result.exitCode == 7
    check job.result.output == "fail"

  test "cancels a long-running task":
    let job = startTask(TaskSpec(command: "/bin/sh", args: @["-c", "sleep 10"]))
    sleep(20)
    job.cancel()
    check job.done
    check job.result.status == taskCancelled

  test "cancels a task blocked on stdin":
    let job = startTask(TaskSpec(command: "/bin/sh", args: @["-c", "read value"]))
    sleep(20)
    job.cancel()
    check job.done
    check job.result.status == taskCancelled

  test "makes task output available before process exit":
    let job = startTask(TaskSpec(command: "/bin/sh", args: @["-c",
      "printf first; sleep 1; printf second"]))
    var sawFirst = false
    let wait = waitForTest("first task output", condition = proc(): bool =
      discard job.poll()
      sawFirst = job.result.output.find("first") >= 0
      sawFirst)
    check checkTestWait(wait)
    check sawFirst
    job.cancel()
    check "first" in job.result.output

  test "bounds task output at a UTF-8 line boundary":
    let bounded = appendBoundedTaskOutput("old line\n", "あいうえお\nnew line\n", 12)
    check bounded.truncated
    check bounded.output == "new line\n"
    check bounded.output.len <= 12
