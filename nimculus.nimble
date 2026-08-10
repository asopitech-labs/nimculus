version       = "0.1.0"
author        = "Nimculus contributors"
description   = "A macOS-first GPU-native code editor"
license       = "MIT"
srcDir        = "src"
bin           = @ ["nimculus/main"]
testEntryPoint = "tests/test_runner.nim"

requires "nim >= 2.0.0"
requires "graphemes >= 0.12.0"
requires "gitignore >= 0.1.0"

task build, "Build the Nimculus macOS application":
  exec "nim c --mm:arc -d:release --nimcache:.nimcache/build src/nimculus/main.nim"

task clean, "Remove generated build caches and local artifacts":
  rmDir(".nimcache")
  rmDir("nimcache")
  rmDir("nimblecache")
  rmDir("build")
  rmDir("dist")
  rmFile("src/nimculus/main")

task format, "Format Nim sources with nimpretty":
  exec "nimpretty --maxLineLen:100 src/nimnui/*.nim src/nimnui/platform/macos/*.nim src/nimnui/platform/headless/*.nim src/nimnui/platform/windows/*.nim src/nimculus/*.nim tests/*.nim"

task lint, "Run Nim's static checks":
  exec "nim check --mm:arc --nimcache:.nimcache/lint --path:src src/nimculus/main.nim"

task testWindows, "Run Windows-only tests on a Windows runner":
  exec "nim c --mm:arc --nimcache:.nimcache/test_windows_terminal -r --path:src tests/test_windows_terminal.nim"
  exec "nim c --mm:arc --nimcache:.nimcache/test_windows_platform_contract -r --path:src tests/test_windows_platform_contract.nim"
  exec "nim c --mm:arc --nimcache:.nimcache/test_windows_native_smoke -r --path:src tests/test_windows_native_smoke.nim"

task benchmark, "Run platform benchmark smoke tests":
  exec "nim c --mm:arc --nimcache:.nimcache/bench_m20 -r --path:src tests/bench_m20.nim"
  exec "nim c --mm:arc --nimcache:.nimcache/bench_platform -r --path:src tests/bench_platform.nim"
  exec "nim c --mm:arc --nimcache:.nimcache/bench_editor -r --path:src tests/bench_editor.nim"
  exec "nim c --mm:arc --nimcache:.nimcache/bench_large_editor -r --path:src tests/bench_large_editor.nim"
  exec "nim c --mm:arc --nimcache:.nimcache/bench_buffer_strategies -r --path:src tests/bench_buffer_strategies.nim"
  exec "nim c --mm:arc --nimcache:.nimcache/bench_syntax -r --path:src tests/bench_syntax.nim"
  exec "nim c --mm:arc --nimcache:.nimcache/bench_workspace -r --path:src tests/bench_workspace.nim"

task packageMacos, "Build, sign, and package the macOS application":
  exec "bash scripts/package_macos.sh"

task macosE2E, "Run the consolidated macOS release-candidate E2E gate":
  exec "bash scripts/test_macos_e2e.sh"

task macosGuiE2E, "Run GUI-login workspace workflow E2E on macOS":
  exec "bash scripts/test_macos_gui_workflows.sh"
