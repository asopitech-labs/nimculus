import std/os
import std/strutils
import std/unittest
import nimculus/workspace

when defined(macosx):
  {.compile: "test_workspace_watcher_macos.m".}
  proc pumpMainRunLoop(seconds: cdouble) {.importc: "nimculus_test_pump_main_run_loop", cdecl.}

when defined(macosx) or defined(windows):
  proc pumpWatcher() =
    when defined(macosx):
      # FSEvents is scheduled on the main run loop by the native bridge.
      pumpMainRunLoop(0.05)
    else:
      sleep(50)

  proc waitForPath(workspace: Workspace, suffix: string): bool =
    for _ in 0 ..< 40:
      for path in workspace.changedPaths():
        if path.endsWith(suffix): return true
      pumpWatcher()
    false

  proc newWatcherRoot(label: string): string =
    getTempDir() / ("nimculus-workspace-watcher-" & label & "-" &
      $getCurrentProcessId())

  suite "workspace watcher integration":
    test "recursive create and write changes reach the coalesced queue":
      let root = newWatcherRoot("create")
      if dirExists(root): removeDir(root)
      createDir(root)
      let workspace = openWorkspace(root)
      workspace.startWatching()
      defer:
        workspace.stopWatching()
        if dirExists(root): removeDir(root)
      if not workspace.isWatching:
        skip()
      else:
        createDir(root / "nested")
        writeFile(root / "nested" / "watch.txt", "changed\n")
        check workspace.waitForPath("nested" / "watch.txt")

    test "rename and delete changes retain their affected path":
      let root = newWatcherRoot("mutate")
      if dirExists(root): removeDir(root)
      createDir(root)
      let workspace = openWorkspace(root)
      workspace.startWatching()
      defer:
        workspace.stopWatching()
        if dirExists(root): removeDir(root)
      if not workspace.isWatching:
        skip()
      else:
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
        check renamedFound
        check deletedFound

    test "repeated writes are coalesced to one normalized path":
      let root = newWatcherRoot("coalesce")
      if dirExists(root): removeDir(root)
      createDir(root)
      let workspace = openWorkspace(root)
      workspace.startWatching()
      defer:
        workspace.stopWatching()
        if dirExists(root): removeDir(root)
      if not workspace.isWatching:
        skip()
      else:
        let changed = root / "coalesced.txt"
        writeFile(changed, "one\n")
        discard workspace.waitForPath("coalesced.txt")
        discard workspace.changedPaths()
        for value in ["two\n", "three\n", "four\n"]:
          writeFile(changed, value)
        for _ in 0 ..< 10:
          pumpWatcher()
        let paths = workspace.changedPaths()
        check paths.len == 1
        check paths[0].endsWith("coalesced.txt")
else:
  echo "[SKIP] workspace watcher integration requires macOS or Windows"
