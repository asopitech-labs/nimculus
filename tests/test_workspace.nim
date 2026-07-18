import std/unittest
import std/os
import std/sequtils
import std/strutils
import std/tables
import nimculus/workspace

suite "M6 workspace":
  test "lazy tree honors gitignore and enumerates files":
    let root = getTempDir() / "nimculus-m6-workspace"
    createDir(root)
    createDir(root / "src")
    createDir(root / "ignored")
    writeFile(root / ".gitignore", "ignored\n*.tmp\n")
    writeFile(root / "src" / "main.nim", "echo 1")
    writeFile(root / "ignored" / "secret.txt", "secret")
    writeFile(root / "cache.tmp", "cache")
    var workspace = openWorkspace(root)
    check workspace.listChildren().len == 2
    let entries = workspace.enumerateFiles()
    check entries.len == 2
    check entries.anyIt(it.relativePath == "src/main.nim")
    removeDir(root / "src"); removeDir(root / "ignored");
    removeFile(root / ".gitignore"); removeFile(root / "cache.tmp"); removeDir(root)

  test "search can be cancelled":
    let root = getTempDir() / "nimculus-m6-search"
    createDir(root)
    writeFile(root / "a.txt", "needle\nneedle")
    var workspace = openWorkspace(root)
    let token = newCancelToken()
    let results = workspace.searchWorkspace("needle", token)
    check results.len == 2
    token.cancel()
    check workspace.searchWorkspace("needle", token).len == 0
    removeFile(root / "a.txt"); removeDir(root)

  test "search job yields bounded batches and can be cancelled":
    let root = getTempDir() / "nimculus-m6-search-job"
    createDir(root)
    writeFile(root / "a.txt", "needle")
    writeFile(root / "b.txt", "needle")
    let workspace = openWorkspace(root)
    let job = workspace.startSearch("needle")
    let firstBatch = job.pollSearch(1)
    check firstBatch.len == 1
    check not job.isComplete
    let secondBatch = job.pollSearch(1)
    check secondBatch.len == 1
    check job.isComplete
    let cancelled = workspace.startSearch("needle")
    cancelled.cancelSearch()
    check cancelled.pollSearch(1).len == 0
    check cancelled.isComplete
    removeFile(root / "a.txt"); removeFile(root / "b.txt"); removeDir(root)

  test "supports roots, file operations, and fuzzy search":
    let root = getTempDir() / "nimculus-m6-ops"
    let second = getTempDir() / "nimculus-m6-ops-second"
    createDir(root); createDir(second)
    createDir(second / "ignored")
    writeFile(second / ".gitignore", "ignored\n")
    writeFile(second / "ignored" / "secret.txt", "secret")
    var workspace = openWorkspace(root)
    workspace.addRoot(second)
    discard workspace.createFile("src/main.nim", "proc main() = discard")
    writeFile(second / "README.md", "nimculus")
    check workspace.rootPaths.len == 2
    check workspace.fuzzyFileSearch("main").len == 1
    check workspace.enumerateFiles().allIt(not it.relativePath.endsWith("secret.txt"))
    check workspace.renameEntry("src/main.nim", "src/app.nim").endsWith("src/app.nim")
    check fileExists(root / "src/app.nim")
    discard workspace.createDirectory("empty")
    workspace.deleteEntry("empty")
    workspace.deleteEntry("src/app.nim")
    expect ValueError:
      workspace.deleteEntry("")
    expect ValueError:
      discard workspace.renameEntry("", "moved")
    removeDir(root / "src")
    removeFile(second / ".gitignore"); removeFile(second / "ignored" / "secret.txt")
    removeDir(second / "ignored")
    removeDir(root); removeDir(second)

  test "rejects symlink paths that escape the workspace root":
    let root = getTempDir() / "nimculus-m6-symlink-root"
    let outside = getTempDir() / "nimculus-m6-symlink-outside"
    createDir(root); createDir(outside)
    when defined(posix):
      createSymlink(outside, root / "escape")
      let workspace = openWorkspace(root)
      expect ValueError:
        discard workspace.createFile("escape/new.txt")
      expect ValueError:
        workspace.deleteEntry("escape")
      removeFile(root / "escape")
    removeDir(root); removeDir(outside)

  test "uses ripgrep-compatible search results when available":
    let root = getTempDir() / "nimculus-m6-rg"
    createDir(root)
    writeFile(root / "main.nim", "needle here")
    let workspace = openWorkspace(root)
    let results = workspace.searchRipgrep("needle")
    check results.len == 1
    check results[0].line == 1
    removeFile(root / "main.nim"); removeDir(root)

  test "keeps Git worktree state keyed by worktree root":
    let workspace = openWorkspace(getCurrentDir())
    let states = workspace.gitWorktreeStates()
    check states.len >= 1
    for root, state in states:
      check root == state.root
      check state.head.len > 0
