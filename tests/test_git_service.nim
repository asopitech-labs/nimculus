import std/os
import std/osproc
import std/strutils
import std/sequtils
import std/unittest
import nimculus/git_service

proc git(repo: string, args: varargs[string]): string =
  var command = "git -C " & quoteShell(repo)
  for arg in args: command.add(" " & quoteShell(arg))
  let output = execCmdEx(command)
  doAssert output.exitCode == 0, output.output
  output.output

suite "M9 Git service":
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
