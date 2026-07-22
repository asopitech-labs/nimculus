import std/os
import std/times
import std/strutils
import nimculus/workspace

block workspaceBenchmark:
  let fileCount = parseInt(getEnv("NIMCULUS_WORKSPACE_BENCH_FILES", "100000"))
  let root = getTempDir() / ("nimculus-workspace-benchmark-" & $getCurrentProcessId())
  if dirExists(root): removeDir(root)
  defer:
    if dirExists(root): removeDir(root)
  createDir(root)
  for index in 0 ..< max(0, fileCount):
    let directory = root / ("group" & $(index div 100))
    if not dirExists(directory): createDir(directory)
    writeFile(directory / ("file" & $index & ".txt"), "workspace")

  let ws = openWorkspace(root)
  let start = cpuTime()
  let entries = ws.enumerateFiles()
  let elapsed = cpuTime() - start
  echo "workspace files: ", entries.len
  echo "workspace enumerate ", fileCount, ": ", elapsed, "s"
