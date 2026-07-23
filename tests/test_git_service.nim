import std/os
import std/osproc
import std/strutils
import std/sequtils
import std/times
import std/unicode
import std/unittest
when defined(posix):
  import std/envvars
import nimculus/git_service

proc git(repo: string, args: varargs[string]): string =
  var command = "git -C " & quoteShell(repo)
  for arg in args: command.add(" " & quoteShell(arg))
  let output = execCmdEx(command)
  doAssert output.exitCode == 0, output.output
  output.output

suite "M9 Git service":
  test "bounds Git output at UTF-8 and line boundaries":
    let bounded = appendBoundedGitOutput("old\n", "日本語の長い出力\nnew\n", limit = 16)
    check bounded.truncated
    check bounded.output.len <= 16
    check bounded.output.validateUtf8 == -1
    check not bounded.output.startsWith("語")

  test "parses unified diff hunk ranges for inline and gutter consumers":
    let hunks = parseDiffHunks("diff --git a/a b/a\n@@ -2,2 +2,3 @@\n-old\n+new\n+added\n@@ -8 +9,0 @@\n-removed\n")
    check hunks.len == 2
    check hunks[0].oldStart == 2
    check hunks[0].oldCount == 2
    check hunks[0].newStart == 2
    check hunks[0].newCount == 3
    check hunks[0].kind == gitHunkModified
    check hunks[0].addedLines == 2
    check hunks[0].removedLines == 1
    check hunks[1].kind == gitHunkDeleted
    check hunks[0].patchText.startsWith("@@ -2,2 +2,3 @@")

  test "parses porcelain status including conflicts and renames":
    let status = " M old.txt\0R  new.txt\0old.txt\0UU conflict.txt\0"
    let entries = parseStatus(status)
    check entries.len == 3
    check entries[0].path == "old.txt"
    check entries[1].path == "new.txt"
    check entries[1].originalPath == "old.txt"
    check entries[2].conflict

  test "runs status, diff, stage, commit, log and blame":
    let root = getTempDir() / "nimculus-m9-git"
    if dirExists(root): removeDir(root)
    createDir(root)
    defer: removeDir(root)
    discard git(root, "init", "-q")
    discard git(root, "config", "user.name", "Nimculus Test")
    discard git(root, "config", "user.email", "test@nimculus.invalid")
    writeFile(root / "main.nim", "one\n")
    let repository = newGitRepository(root)
    check repository != nil
    check repository.currentBranch().len > 0
    check repository.status().anyIt(it.path == "main.nim")
    check repository.stage(["main.nim"]).exitCode == 0
    check repository.commit("initial").exitCode == 0
    writeFile(root / "main.nim", "one\ntwo\n")
    let diff = repository.diff("main.nim")
    check diff.exitCode == 0
    check diff.output.contains("+two")
    check repository.stage(["main.nim"]).exitCode == 0
    check repository.log(10).len == 1
    let blame = repository.blame("main.nim")
    check blame.len == 2
    check blame[1].text == "two"
    check repository.checkout("HEAD", ["main.nim"]).exitCode == 0
    check readFile(root / "main.nim") == "one\n"
    discard git(root, "mv", "main.nim", "renamed.nim")
    let renamed = repository.status().filterIt(it.path == "renamed.nim")
    check renamed.len == 1
    check renamed[0].originalPath == "main.nim"

  test "cancels a running git job":
    let root = getTempDir() / "nimculus-m9-job"
    if dirExists(root): removeDir(root)
    createDir(root)
    defer: removeDir(root)
    discard git(root, "init", "-q")
    let repository = newGitRepository(root)
    let job = repository.startGitJob(["status", "--porcelain"])
    job.cancel()
    check job.done
    check job.cancelled
    check job.result.exitCode == -1

  test "cancels a Git process that is waiting for stdin":
    let root = getTempDir() / "nimculus-m9-blocked-job"
    if dirExists(root): removeDir(root)
    createDir(root)
    defer: removeDir(root)
    discard git(root, "init", "-q")
    let repository = newGitRepository(root)
    let job = repository.startGitJob(["hash-object", "--stdin"])
    sleep(10)
    job.cancel()
    check job.done
    check job.cancelled
    check job.result.exitCode == -1

  when defined(posix):
    test "bounds repository probing when Git does not respond":
      let root = getTempDir() / "nimculus-m9-probe-timeout"
      let fakeGit = root / "git"
      if dirExists(root): removeDir(root)
      createDir(root)
      writeFile(fakeGit, "#!/bin/sh\nexec sleep 10\n")
      setFilePermissions(fakeGit, {fpUserRead, fpUserWrite, fpUserExec})
      let previousPath = getEnv("PATH")
      putEnv("PATH", root & ":" & previousPath)
      defer:
        putEnv("PATH", previousPath)
        if fileExists(fakeGit): removeFile(fakeGit)
        if dirExists(root): removeDir(root)
      let started = epochTime()
      check newGitRepository(root) == nil
      check epochTime() - started < 4.0

    test "drains verbose Git output before process exit":
      let root = getTempDir() / "nimculus-m9-verbose-job"
      let fakeGit = root / "git"
      if dirExists(root): removeDir(root)
      createDir(root)
      writeFile(fakeGit, "#!/bin/sh\nhead -c 1048576 /dev/zero | tr '\\000' x\n")
      setFilePermissions(fakeGit, {fpUserRead, fpUserWrite, fpUserExec})
      let previousPath = getEnv("PATH")
      putEnv("PATH", root & ":" & previousPath)
      defer:
        putEnv("PATH", previousPath)
        if fileExists(fakeGit): removeFile(fakeGit)
        if dirExists(root): removeDir(root)
      let job = GitRepository(root: root).startGitJob(["status", "--porcelain"])
      let deadline = epochTime() + 3.0
      while not job.poll() and epochTime() < deadline:
        sleep(1)
      if not job.done: job.cancel()
      check job.done
      check job.result.exitCode == 0
      check job.result.output.len == 1_048_576

  test "stages and unstages one hunk without affecting another":
    let root = getTempDir() / "nimculus-m9-hunk"
    if dirExists(root): removeDir(root)
    createDir(root)
    defer: removeDir(root)
    discard git(root, "init", "-q")
    discard git(root, "config", "user.name", "Nimculus Test")
    discard git(root, "config", "user.email", "test@nimculus.invalid")
    var lines: seq[string]
    for index in 1 .. 14: lines.add("line" & $index)
    writeFile(root / "main.txt", lines.join("\n") & "\n")
    discard git(root, "add", "main.txt")
    discard git(root, "commit", "-qm", "initial")
    lines[1] = "changed-two"
    lines[10] = "changed-eleven"
    writeFile(root / "main.txt", lines.join("\n") & "\n")
    let repository = newGitRepository(root)
    let hunks = repository.diffHunks("main.txt")
    check hunks.len == 2
    check repository.stageHunk("main.txt", 0).exitCode == 0
    let staged = repository.diff("main.txt", staged = true)
    let unstaged = repository.diff("main.txt")
    check staged.output.contains("changed-two")
    check not staged.output.contains("changed-eleven")
    check unstaged.output.contains("changed-eleven")
    check repository.unstageHunk("main.txt", 0).exitCode == 0
    check repository.diff("main.txt", staged = true).output.len == 0
