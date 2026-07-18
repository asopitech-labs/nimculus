import std/unittest
import std/os
import std/sequtils
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
