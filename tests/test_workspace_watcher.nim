when defined(windows):
  import std/os
  import std/strutils
  import std/times
  import std/unittest
  import nimculus/workspace

  proc waitForPath(workspace: Workspace, suffix: string): bool =
    for _ in 0 ..< 40:
      for path in workspace.changedPaths():
        if path.endsWith(suffix): return true
      sleep(50)
    false

when defined(windows):
  suite "workspace watcher integration":
    test "recursive create and write changes reach the coalesced queue":
      let root = getTempDir() / ("nimculus-workspace-watcher-create-" & $int(epochTime()))
      if dirExists(root): removeDir(root)
      createDir(root)
      let workspace = openWorkspace(root)
      workspace.startWatching()
      createDir(root / "nested")
      writeFile(root / "nested" / "watch.txt", "changed\n")
      let found = workspace.waitForPath("nested" / "watch.txt")
      workspace.stopWatching()
      removeFile(root / "nested" / "watch.txt")
      removeDir(root / "nested")
      removeDir(root)
      check found

    test "rename and delete changes retain their affected path":
      let root = getTempDir() / ("nimculus-workspace-watcher-mutate-" & $int(epochTime()))
      if dirExists(root): removeDir(root)
      createDir(root)
      let workspace = openWorkspace(root)
      workspace.startWatching()
      let original = root / "original.txt"
      let renamed = root / "renamed.txt"
      writeFile(original, "before\n")
      discard workspace.waitForPath("original.txt")
      discard workspace.changedPaths()
      moveFile(original, renamed)
      let renamedFound = workspace.waitForPath("renamed.txt")
      discard workspace.changedPaths()
      removeFile(renamed)
      let deletedFound = workspace.waitForPath("renamed.txt")
      workspace.stopWatching()
      if fileExists(original): removeFile(original)
      if fileExists(renamed): removeFile(renamed)
      removeDir(root)
      check renamedFound
      check deletedFound

    test "repeated writes are coalesced to one normalized path":
      let root = getTempDir() / ("nimculus-workspace-watcher-coalesce-" & $int(epochTime()))
      if dirExists(root): removeDir(root)
      createDir(root)
      let workspace = openWorkspace(root)
      workspace.startWatching()
      let changed = root / "coalesced.txt"
      writeFile(changed, "one\n")
      discard workspace.waitForPath("coalesced.txt")
      discard workspace.changedPaths()
      for value in ["two\n", "three\n", "four\n"]:
        writeFile(changed, value)
      var paths: seq[string]
      for _ in 0 ..< 40:
        paths = workspace.changedPaths()
        if paths.len > 0: break
        sleep(50)
      workspace.stopWatching()
      if fileExists(changed): removeFile(changed)
      removeDir(root)
      check paths.len == 1
      check paths[0].endsWith("coalesced.txt")
else:
  echo "[SKIP] workspace watcher integration requires Windows"
