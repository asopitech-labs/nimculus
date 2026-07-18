import std/os
import std/times
import nimculus/workspace

let root = getTempDir() / "nimculus-workspace-benchmark"
if dirExists(root): removeDir(root)
createDir(root)
for index in 0 ..< 10000:
  let directory = root / ("group" & $(index div 100))
  if not dirExists(directory): createDir(directory)
  writeFile(directory / ("file" & $index & ".txt"), "workspace")

let ws = openWorkspace(root)
let start = cpuTime()
let entries = ws.enumerateFiles()
let elapsed = cpuTime() - start
echo "workspace files: ", entries.len
echo "workspace enumerate 10k: ", elapsed, "s"
removeDir(root)
