import std/[algorithm, os, osproc]

type
  TestSpec = tuple[name: string, file: string, threads: bool]

const excludedTestFiles = [
  # The runner is the entry point and must not invoke itself recursively.
  "tests/test_runner.nim",
  # These tests are owned by `task testWindows` and do not run on macOS.
  "tests/test_windows_native_smoke.nim",
  "tests/test_windows_platform_contract.nim",
  "tests/test_windows_terminal.nim"
]

var testSpecs: seq[TestSpec] = @[]
for file in walkFiles("tests/test_*.nim"):
  if file notin excludedTestFiles:
    let name = splitFile(file).name
    testSpecs.add((name, file, name == "test_executor"))

testSpecs.sort(proc (left, right: TestSpec): int =
  if left.file < right.file: -1
  elif left.file > right.file: 1
  else: 0)

var
  successCount = 0
  failedFiles: seq[string] = @[]

for index, spec in testSpecs:
  echo "\n[test ", index + 1, "/", testSpecs.len, "] ", spec.file
  let threadFlag = if spec.threads: " --threads:on" else: ""
  let command = "nim c --mm:arc" & threadFlag &
    " --nimcache:.nimcache/" & spec.name & " -r --path:src " & spec.file
  let exitCode = try:
    execCmd(command)
  except CatchableError:
    1
  if exitCode == 0:
    inc successCount
  else:
    failedFiles.add(spec.file)
    echo "[FAILED FILE] ", spec.file

echo "\n実行: ", testSpecs.len, " / 成功: ", successCount, " / 失敗: ", failedFiles.len
if failedFiles.len > 0:
  echo "失敗したファイル:"
  for file in failedFiles:
    echo "  ", file
  quit(1)
