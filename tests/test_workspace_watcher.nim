when defined(windows):
  import std/os
  import std/strutils
  import std/times
  import std/unittest
  import nimculus/workspace

when defined(windows):
  suite "workspace watcher integration":
    test "file changes reach the coalesced workspace queue":
      let root = getTempDir() / ("nimculus-workspace-watcher-" & $int(epochTime()))
      if dirExists(root): removeDir(root)
      createDir(root)
      let workspace = openWorkspace(root)
      workspace.startWatching()
      writeFile(root / "watch.txt", "changed\n")
      var found = false
      for _ in 0 ..< 40:
        sleep(50)
        for path in workspace.changedPaths():
          if path.endsWith("watch.txt"): found = true
        if found: break
      workspace.stopWatching()
      removeFile(root / "watch.txt")
      removeDir(root)
      check found
else:
  echo "[SKIP] workspace watcher integration requires Windows"
