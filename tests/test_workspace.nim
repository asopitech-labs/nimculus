import std/unittest
import std/os
import std/sequtils
import std/strutils
import std/tables
import std/times
when defined(posix):
  import std/osproc
  import std/envvars
import nimculus/workspace
import nimculus/search

suite "M6 workspace":
  when defined(macosx):
    test "FSEvents loss flags request a root rescan":
      check validateWorkspaceWatcherRescanFlags()

  test "FSEvents watcher can stop before its workspace is released":
    let root = getTempDir() / "nimculus-m6-watcher-stop"
    if dirExists(root): removeDir(root)
    createDir(root)
    defer: removeDir(root)
    let workspace = openWorkspace(root)
    workspace.startWatching()
    check workspace.isWatching
    workspace.stopWatching()
    check not workspace.isWatching

  test "workspace roots coalesce symlink aliases before watcher registration":
    let root = getTempDir() / "nimculus-m6-root-identity-日本語🙂"
    let alias = getTempDir() / "nimculus-m6-root-identity-alias"
    if symlinkExists(alias): removeFile(alias)
    if dirExists(root): removeDir(root)
    createDir(root)
    defer:
      if symlinkExists(alias): removeFile(alias)
      if dirExists(root): removeDir(root)
    when defined(posix):
      createSymlink(root, alias)
      let workspace = openWorkspace(alias)
      workspace.addRoot(root)
      check workspace.rootPaths == @[canonicalWorkspaceRoot(root)]

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

  test "gitignore supports negation, anchored globs, and nested files":
    let root = getTempDir() / "nimculus-m6-ignore-spec"
    createDir(root); createDir(root / "src"); createDir(root / "build")
    createDir(root / "src" / "nested")
    writeFile(root / ".gitignore", "*.log\n!/keep.log\n/build/\n")
    writeFile(root / "keep.log", "keep")
    writeFile(root / "drop.log", "drop")
    writeFile(root / "build" / "artifact.txt", "artifact")
    writeFile(root / "src" / ".gitignore", "nested/\n")
    writeFile(root / "src" / "nested" / "file.txt", "nested")
    let workspace = openWorkspace(root)
    let entries = workspace.enumerateFiles()
    check entries.allIt(not it.relativePath.endsWith("drop.log"))
    check entries.allIt(not it.relativePath.startsWith("build/"))
    check entries.allIt(not it.relativePath.startsWith("src/nested/"))
    check entries.anyIt(it.relativePath == "keep.log")
    removeFile(root / "src" / "nested" / "file.txt"); removeDir(root / "src" / "nested")
    removeFile(root / "src" / ".gitignore"); removeDir(root / "src")
    removeFile(root / "build" / "artifact.txt"); removeDir(root / "build")
    removeFile(root / ".gitignore"); removeFile(root / "keep.log"); removeFile(root / "drop.log")
    removeDir(root)

  test "ignore stacks reload after ignore file changes":
    let root = getTempDir() / "nimculus-m6-ignore-reload"
    createDir(root)
    writeFile(root / ".gitignore", "ignored\n")
    writeFile(root / "ignored", "value")
    var workspace = openWorkspace(root)
    check workspace.enumerateFiles().len == 1
    writeFile(root / ".gitignore", "")
    workspace.reloadIgnoreRules()
    check workspace.enumerateFiles().len == 2
    removeFile(root / ".gitignore"); removeFile(root / "ignored"); removeDir(root)

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

  test "workspace search options honor case, whole-word, regex, and filters":
    let root = getTempDir() / "nimculus-m6-search-options"
    createDir(root)
    writeFile(root / "main.txt", "Needle needle needle42\ncat scatter")
    writeFile(root / "other.log", "needle")
    let workspace = openWorkspace(root)
    check workspace.searchWorkspace("needle", options = SearchOptions(
      caseSensitive: true)).len == 3
    check workspace.searchWorkspace("needle", options = SearchOptions(
      caseSensitive: false, wholeWord: true)).len == 3
    check workspace.searchWorkspace("needle\\d+", options = SearchOptions(
      regex: true)).len == 1
    check workspace.searchWorkspace("needle", options = SearchOptions(
      caseSensitive: false, includePatterns: "*.log")).len == 1
    removeFile(root / "main.txt"); removeFile(root / "other.log"); removeDir(root)

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

  test "search job scopes traversal to a selected workspace directory":
    let root = getTempDir() / "nimculus-m6-search-scope"
    let selected = root / "selected"
    let sibling = root / "sibling"
    createDir(root); createDir(selected); createDir(sibling)
    writeFile(selected / "inside.txt", "needle")
    writeFile(sibling / "outside.txt", "needle")
    let workspace = openWorkspace(root)
    let job = workspace.startSearch("needle", scopePath = selected)
    var results: seq[SearchResult]
    while not job.isComplete:
      results.add(job.pollSearch(maxFiles = 2, maxLines = 32))
    check results.len == 1
    # macOS canonicalizes /var to /private/var for workspace entries.
    check results[0].path.endsWith(DirSep & "selected" & DirSep & "inside.txt")
    removeFile(selected / "inside.txt"); removeFile(sibling / "outside.txt")
    removeDir(selected); removeDir(sibling); removeDir(root)

  test "changed paths are normalized and coalesced":
    let root = getTempDir() / "nimculus-m6-change-set"
    createDir(root)
    let filePath = root / "a.txt"
    writeFile(filePath, "value")
    let workspace = openWorkspace(root)
    workspace.changes.add(filePath)
    workspace.changes.add(normalizedPath(root / "." / "a.txt"))
    workspace.changes.add(root / "b.txt")
    let changed = workspace.changedPaths()
    check changed.len == 2
    check changed[0] == canonicalWorkspaceRoot(filePath)
    check changed[1] == canonicalWorkspaceRoot(root) / "b.txt"
    check workspace.changedPaths().len == 0
    removeFile(filePath); removeDir(root)

  test "changed paths invalidate cached files and descendants":
    let root = getTempDir() / "nimculus-m6-cache-invalidation"
    createDir(root); createDir(root / "nested")
    writeFile(root / "nested" / "one.txt", "one")
    writeFile(root / "nested" / "two.txt", "two")
    let workspace = openWorkspace(root)
    discard workspace.enumerateFiles()
    check workspace.entries.len == 3
    workspace.changes.add(root / "nested")
    discard workspace.changedPaths()
    check workspace.entries.len == 0
    removeFile(root / "nested" / "one.txt")
    removeFile(root / "nested" / "two.txt")
    removeDir(root / "nested")
    removeDir(root)

  test "fuzzy search yields bounded batches and can be cancelled":
    let root = getTempDir() / "nimculus-m6-fuzzy-job"
    createDir(root)
    for index in 0 ..< 5:
      writeFile(root / ("needle-" & $index & ".txt"), "value")
    createDir(root / "nested")
    writeFile(root / "main.nim", "discard")
    writeFile(root / "nested" / "main.nim", "discard")
    let workspace = openWorkspace(root)
    let job = workspace.startFuzzySearch("needle")
    let first = job.pollFuzzySearch(maxEntries = 1, maxResults = 100)
    check first.len == 1
    check not job.isComplete
    var rest = first
    while not job.isComplete:
      rest.add(job.pollFuzzySearch(maxEntries = 2, maxResults = 100))
    check rest.len == 5
    let ranked = workspace.fuzzyFileSearch("main")
    check ranked.len == 2
    check ranked[0].relativePath == "main.nim"
    let cancelled = workspace.startFuzzySearch("needle")
    cancelled.cancelFuzzySearch()
    check cancelled.pollFuzzySearch().len == 0
    check cancelled.isComplete
    for index in 0 ..< 5: removeFile(root / ("needle-" & $index & ".txt"))
    removeFile(root / "main.nim")
    removeFile(root / "nested" / "main.nim")
    removeDir(root / "nested")
    removeDir(root)

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
    check workspace.createFileAt(second, "src/secondary.nim", "discard").endsWith("src/secondary.nim")
    let secondaryLocation = workspace.splitWorkspacePath(second / "src/secondary.nim")
    check secondaryLocation.root == canonicalWorkspaceRoot(second)
    check secondaryLocation.relative == "src/secondary.nim"
    check workspace.entryPathAt(secondaryLocation.root, secondaryLocation.relative) ==
      canonicalWorkspaceRoot(second) / "src/secondary.nim"
    expect ValueError:
      discard workspace.entryPathAt(secondaryLocation.root, "")
    expect ValueError:
      discard workspace.splitWorkspacePath(getTempDir() / "outside-workspace.txt")
    check workspace.enumerateFiles().anyIt(it.rootPath == canonicalWorkspaceRoot(second) and
      it.relativePath == "src/secondary.nim")
    check workspace.searchWorkspace("discard").anyIt(
      it.path == canonicalWorkspaceRoot(second) / "src/secondary.nim")
    discard workspace.createDirectory("assets")
    writeFile(root / "assets" / "icon.txt", "asset")
    let copiedDirectory = workspace.copyEntryBetweenRoots(root, "assets", second,
      "copied-assets")
    check copiedDirectory.endsWith("copied-assets")
    check readFile(second / "copied-assets" / "icon.txt") == "asset"
    let copiedFile = workspace.copyEntryAt(second, "src/secondary.nim", "src/copied.nim")
    check copiedFile.endsWith("src/copied.nim")
    check readFile(second / "src" / "copied.nim") == "discard"
    expect IOError:
      discard workspace.copyEntryAt(second, "src/secondary.nim", "src/copied.nim")
    check workspace.renameEntryAt(second, "src/secondary.nim", "src/renamed.nim").endsWith("src/renamed.nim")
    workspace.deleteEntryAt(second, "src/renamed.nim")
    check not fileExists(second / "src" / "renamed.nim")
    check workspace.renameEntry("src/main.nim", "src/app.nim").endsWith("src/app.nim")
    check fileExists(root / "src/app.nim")
    discard workspace.createDirectory("empty")
    workspace.deleteEntry("empty")
    workspace.deleteEntry("src/app.nim")
    workspace.deleteEntryAt(second, "src/copied.nim")
    workspace.deleteEntryAt(second, "copied-assets")
    workspace.deleteEntry("assets")
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

  when defined(posix):
    test "external search termination is bounded":
      let process = startProcess("/bin/sh", args = @["-c", "exec sleep 10"],
        options = {poUsePath})
      let started = epochTime()
      discard terminateSearchProcess(process)
      check epochTime() - started < 3.0

  when defined(macosx):
    test "worktree metadata probe is bounded when Git does not respond":
      let root = getTempDir() / "nimculus-m6-worktree-timeout"
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
      let workspace = openWorkspace(root)
      let started = epochTime()
      check workspace.gitWorktreeStates().len == 0
      check epochTime() - started < 4.0

  test "ripgrep results preserve colons in paths and source lines":
    let root = getTempDir() / "nimculus-m6-rg-colon"
    createDir(root)
    let path = root / "a:b.txt"
    writeFile(path, "needle: here\nneedle again")
    let workspace = openWorkspace(root)
    let results = workspace.searchRipgrep("needle")
    check results.len == 2
    check results[0].path.endsWith("a:b.txt")
    check results[0].text == "needle: here"
    check results[1].line == 2
    check results[1].text == "needle again"
    removeFile(path); removeDir(root)

  test "search result count is bounded":
    let root = getTempDir() / "nimculus-m6-search-limit"
    createDir(root)
    let path = root / "many.txt"
    writeFile(path, repeat("needle\n", MaxWorkspaceSearchResults + 5))
    let workspace = openWorkspace(root)
    check workspace.searchWorkspace("needle").len == MaxWorkspaceSearchResults
    check workspace.searchRipgrep("needle").len == MaxWorkspaceSearchResults
    removeFile(path); removeDir(root)

  test "cooperative search stops after its global result limit":
    let root = getTempDir() / "nimculus-m6-search-job-limit"
    createDir(root)
    let path = root / "many.txt"
    writeFile(path, repeat("needle\n", MaxWorkspaceSearchResults + 5))
    let workspace = openWorkspace(root)
    let job = workspace.startSearch("needle")
    var total = 0
    while not job.isComplete:
      total += job.pollSearch(maxFiles = 1, maxLines = 4096).len
    check total == MaxWorkspaceSearchResults
    check job.truncated
    removeFile(path); removeDir(root)

  test "keeps Git worktree state keyed by worktree root":
    let workspace = openWorkspace(getCurrentDir())
    let states = workspace.gitWorktreeStates()
    check states.len >= 1
    for root, state in states:
      check root == state.root
      check state.head.len > 0
