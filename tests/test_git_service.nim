import std/os
import std/osproc
import std/strutils
import std/sequtils
import std/times
import std/tables
import std/unicode
import std/unittest
when defined(posix):
  import std/envvars
import nimculus/git_service
import wait_support
import nimculus/git_blame
import nimculus/editor_buffer

proc git(repo: string, args: varargs[string]): string =
  var command = "git -C " & quoteShell(repo)
  for arg in args: command.add(" " & quoteShell(arg))
  let output = execCmdEx(command)
  doAssert output.exitCode == 0, output.output
  output.output

proc m9TempDir(label: string): string =
  ## Every Git test gets a fresh directory so an interrupted test cannot make
  ## the next `git init` fail while copying its template files.
  getTempDir() / ("nimculus-m9-" & label & "-" & $getCurrentProcessId() & "-" &
    $int(epochTime() * 1_000_000))

suite "M9 Git service":
  test "Git blame cache remembers an unavailable repository by document version":
    var cache: GitBlameCache
    cache.beginUnavailable("/tmp/DEVELOPMENT_GUIDELINES.md", 4)
    check cache.unavailableMatches("/tmp/DEVELOPMENT_GUIDELINES.md", 4)
    check not cache.unavailableMatches("/tmp/DEVELOPMENT_GUIDELINES.md", 5)
    check not cache.unavailableMatches("/tmp/other.md", 4)

  test "Git blame cache is keyed by document version, not cursor line":
    var cache: GitBlameCache
    cache.begin("/repo", "/repo/main.nim", 7)
    cache.finish(@[
      GitBlameLine(hash: "aaa", author: "First"),
      GitBlameLine(hash: "bbb", author: "Second")])
    let buffer = initPieceTable("first\nsecond\n")
    check cache.matches("/repo", "/repo/main.nim", 7)
    check not cache.shouldStart("/repo", "/repo/main.nim", 7, false, false)
    check cache.entryAt(0).hash == "aaa"
    check cache.entryAt(1).hash == "bbb"
    check cache.shouldShow(buffer, 0)
    check cache.shouldShow(buffer, 1)
    check cache.matches("/repo", "/repo/main.nim", 7)
    check not cache.matches("/repo", "/repo/main.nim", 8)
    check cache.shouldStart("/repo", "/repo/main.nim", 8, false, false)
    var edited = initPieceTable("first\nsecond\n")
    let beforeEdit = edited.version
    edited.edit(Edit(startByte: 0, endByte: 5, text: "changed"))
    check edited.version != beforeEdit
    check not cache.matches("/repo", "/repo/main.nim", edited.version)

  test "Git blame cache hides empty lines and empty results":
    let buffer = initPieceTable("first\n\nthird\n")
    var cache: GitBlameCache
    cache.begin("/repo", "/repo/main.nim", 1)
    cache.finish(@[
      GitBlameLine(hash: "aaa"), GitBlameLine(hash: "bbb"), GitBlameLine(hash: "ccc")])
    check cache.shouldShow(buffer, 0)
    check not cache.shouldShow(buffer, 1)
    check cache.shouldShow(buffer, 2)
    cache.finish(@[])
    check not cache.shouldShow(buffer, 0)

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
    check hunks[0].changedRanges.len == 1
    check hunks[0].changedRanges[0].startLine == 2
    check hunks[0].changedRanges[0].lineCount == 2
    check hunks[1].kind == gitHunkDeleted
    check gutterLineRanges(hunks[1])[0].startLine == 9
    check gutterLineRanges(hunks[1])[0].lineCount == 1
    check gitHunkThemeRole(gitHunkAdded) == "added"
    check gitHunkThemeRole(gitHunkModified) == "modified"
    check gitHunkThemeRole(gitHunkDeleted) == "deleted"
    check hunks[0].patchText.startsWith("@@ -2,2 +2,3 @@")

    let workspaceHunks = parseDiffHunks(
      "diff --git a/workspace_target.txt b/workspace_target.txt\n" &
      "index e83319a..ab5872f 100644\n" &
      "--- a/workspace_target.txt\n+++ b/workspace_target.txt\n" &
      "@@ -1,3 +1,3 @@\n # Workspace capture target\n committed line\n" &
      "-changed line\n+working tree hunk\n")
    check workspaceHunks.len == 1
    check workspaceHunks[0].newCount == 3
    check gutterLineRanges(workspaceHunks[0]).len == 1
    check gutterLineRanges(workspaceHunks[0])[0].startLine == 3
    check gutterLineRanges(workspaceHunks[0])[0].lineCount == 1

  test "parses porcelain status including conflicts and renames":
    let status = " M old.txt\0R  new.txt\0old.txt\0UU conflict.txt\0"
    let entries = parseStatus(status)
    check entries.len == 3
    check entries[0].path == "old.txt"
    check entries[1].path == "new.txt"
    check entries[1].originalPath == "old.txt"
    check entries[2].conflict

  test "rolls Git status up through every directory to the repository root":
    let entries = @[
      GitStatusEntry(indexStatus: ' ', worktreeStatus: 'M', path: "a/b/c.txt"),
      GitStatusEntry(indexStatus: 'A', worktreeStatus: ' ', path: "a/d.txt")]
    let summaries = summariesByDirectory(entries)
    check summaries.hasKey("")
    check summaries.hasKey("a")
    check summaries.hasKey("a/b")
    check summaries["a"].indexCount == 1
    check summaries["a"].worktreeCount == 1
    check summaries["a"].conflictCount == 0
    check summaries["a/b"].indexCount == 0
    check summaries["a/b"].worktreeCount == 1
    check summaries["a/b"].conflictCount == 0
    check summaries[""].indexCount == 1
    check summaries[""].worktreeCount == 1

  test "Git status flag lookup is cached per generation":
    var entries = newSeq[GitStatusEntry](5_000)
    for index in 0 ..< entries.len:
      entries[index] = GitStatusEntry(indexStatus: ' ', worktreeStatus: 'M',
        path: "directory/file" & $index & ".txt")
    let generation = 7_341'u64
    discard gitStatusFlagMaskForPath(entries, generation, "directory", true)
    let started = cpuTime()
    for _ in 0 ..< 10_000:
      discard gitStatusFlagMaskForPath(entries, generation, "directory", true)
    check (cpuTime() - started) * 1_000.0 < 50.0

  test "runs status, diff, stage, commit, log and blame":
    let root = m9TempDir("git")
    createDir(root)
    defer: removeDir(root)
    discard git(root, "init", "-q")
    discard git(root, "config", "user.name", "Nimculus Test")
    discard git(root, "config", "user.email", "test@nimculus.invalid")
    writeFile(root / "main.nim", "one\n")
    let repository = newGitRepositorySync(root)
    check repository != nil
    let nested = root / "nested"
    createDir(nested)
    let nestedRepository = repositoryForPath(nested / "outside-workspace.nim")
    check nestedRepository != nil
    check nestedRepository.root == repository.root
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
    check blame[1].authorTime > 0
    check blame[1].authorTimeValid
    check repository.checkout("HEAD", ["main.nim"]).exitCode == 0
    check readFile(root / "main.nim") == "one\n"
    discard git(root, "mv", "main.nim", "renamed.nim")
    let renamed = repository.status().filterIt(it.path == "renamed.nim")
    check renamed.len == 1
    check renamed[0].originalPath == "main.nim"

  test "resolves the first Git repository from workspace roots":
    let root = m9TempDir("workspace-root")
    let ordinary = m9TempDir("ordinary-root")
    createDir(root)
    createDir(ordinary)
    defer:
      removeDir(root)
      removeDir(ordinary)
    discard git(root, "init", "-q")
    let repository = firstRepositoryForPaths([ordinary, root])
    let directRepository = newGitRepositorySync(root)
    check repository != nil
    check directRepository != nil
    # Git resolves macOS's /var -> /private/var temporary-directory alias.
    check repository.root == directRepository.root

  test "returns newest-first bounded commit history for the Git sidebar":
    let root = m9TempDir("history")
    createDir(root)
    defer: removeDir(root)
    discard git(root, "init", "-q")
    discard git(root, "config", "user.name", "Nimculus Test")
    discard git(root, "config", "user.email", "test@nimculus.invalid")
    writeFile(root / "history.nim", "first\n")
    let repository = newGitRepositorySync(root)
    check repository.stage(["history.nim"]).exitCode == 0
    check repository.commit("first commit").exitCode == 0
    writeFile(root / "history.nim", "second\n")
    check repository.stage(["history.nim"]).exitCode == 0
    check repository.commit("second commit").exitCode == 0
    check repository.amendCommit("").exitCode == -1
    check repository.amendCommit("amended second commit").exitCode == 0
    let commits = repository.log(100)
    check commits.len == 2
    check commits[0].subject == "amended second commit"
    check commits[1].subject == "first commit"
    check repository.log(1).len == 1
    check repository.logPath("history.nim", 100).len == 2
    check repository.logPath("", 100).len == 0
    let details = repository.showCommit(commits[0].hash)
    check details.exitCode == 0
    check details.output.contains("amended second commit")
    check details.output.contains("-first")
    check details.output.contains("+second")
    let filtered = repository.showCommitPath(commits[0].hash, "history.nim")
    check filtered.exitCode == 0
    check filtered.output.contains("history.nim")
    check repository.showCommit("").exitCode == -1

  test "lists and safely switches local branches":
    let root = getTempDir() / ("nimculus-m9-branches-" & $getCurrentProcessId())
    if dirExists(root): removeDir(root)
    createDir(root)
    defer: removeDir(root)
    discard git(root, "init", "-q")
    discard git(root, "config", "user.name", "Nimculus Test")
    discard git(root, "config", "user.email", "test@nimculus.invalid")
    writeFile(root / "branches.nim", "base\n")
    let repository = newGitRepositorySync(root)
    check repository.stage(["branches.nim"]).exitCode == 0
    check repository.commit("initial").exitCode == 0
    discard git(root, "branch", "feature")
    let listed = repository.branches()
    check listed.len == 2
    check listed.anyIt(it.current)
    check listed.anyIt(it.name == "feature" and not it.current)
    check repository.switchBranch("feature").exitCode == 0
    check repository.currentBranch() == "feature"
    check repository.switchBranch("--discard-changes").exitCode == -1
    check repository.switchBranch("not a valid branch").exitCode == -1

  test "cancels a running git job":
    let root = getTempDir() / ("nimculus-m9-job-" & $getCurrentProcessId())
    if dirExists(root): removeDir(root)
    createDir(root)
    defer: removeDir(root)
    discard git(root, "init", "-q")
    let repository = newGitRepositorySync(root)
    let job = repository.startGitJob(["status", "--porcelain"])
    job.cancel()
    check job.done
    check job.cancelled
    check job.result.exitCode == -1

  test "cancels a Git process that is waiting for stdin":
    let root = m9TempDir("blocked-job")
    createDir(root)
    defer: removeDir(root)
    discard git(root, "init", "-q")
    let repository = newGitRepositorySync(root)
    let job = repository.startGitJob(["hash-object", "--stdin"])
    sleep(10)
    job.cancel()
    check job.done
    check job.cancelled
    check job.result.exitCode == -1

  when defined(posix):
    test "cancels the direct Git child without blocking the editor":
      let root = m9TempDir("git-process-group")
      let fakeGit = root / "git"
      createDir(root)
      writeFile(fakeGit, "#!/bin/sh\nexec sleep 30\n")
      setFilePermissions(fakeGit, {fpUserRead, fpUserWrite, fpUserExec})
      let previousPath = getEnv("PATH")
      putEnv("PATH", root & ":" & previousPath)
      defer:
        putEnv("PATH", previousPath)
        if fileExists(fakeGit): removeFile(fakeGit)
        if dirExists(root): removeDir(root)
      let job = GitRepository(root: root).startGitJob(["status", "--porcelain"])
      sleep(20)
      job.cancel()
      check job.done
      check job.cancelled

    test "bounds repository probing when Git does not respond":
      let root = m9TempDir("probe-timeout")
      let fakeGit = root / "git"
      createDir(root)
      writeFile(fakeGit, "#!/bin/sh\nexec sleep 10\n")
      setFilePermissions(fakeGit, {fpUserRead, fpUserWrite, fpUserExec})
      let previousPath = getEnv("PATH")
      putEnv("PATH", root & ":" & previousPath)
      defer:
        putEnv("PATH", previousPath)
        if fileExists(fakeGit): removeFile(fakeGit)
        if dirExists(root): removeDir(root)
      check newGitRepositorySync(root) == nil

    test "drains verbose Git output before process exit":
      let root = m9TempDir("verbose-job")
      let fakeGit = root / "git"
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
      let wait = waitForTest("verbose Git job completion", timeoutMs = 10_000,
        condition = proc(): bool = job.poll())
      check checkTestWait(wait)
      if not job.done: job.cancel()
      check job.done
      check job.result.exitCode == 0
      check job.result.output.len == 1_048_576

  test "stages and unstages one hunk without affecting another":
    let root = m9TempDir("hunk")
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
    let repository = newGitRepositorySync(root)
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
