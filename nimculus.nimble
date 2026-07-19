version       = "0.1.0"
author        = "Nimculus contributors"
description   = "A macOS-first GPU-native code editor"
license       = "MIT"
srcDir        = "src"
bin           = @ ["nimculus/main"]

requires "nim >= 2.0.0"
requires "graphemes >= 0.12.0"
requires "gitignore >= 0.1.0"

task build, "Build the Nimculus macOS application":
  exec "nim c --mm:arc -d:release src/nimculus/main.nim"

task format, "Format Nim sources with nimpretty":
  exec "nimpretty --maxLineLen:100 src/nimnui/*.nim src/nimnui/platform/macos/*.nim src/nimculus/*.nim tests/*.nim"

task lint, "Run Nim's static checks":
  exec "nim check --mm:arc --nimcache:.nimcache/lint --path:src src/nimculus/main.nim"

task test, "Run unit and integration tests":
  exec "nim c --mm:arc --nimcache:.nimcache/test_platform_contract -r --path:src tests/test_platform_contract.nim"
  exec "nim c --mm:arc --nimcache:.nimcache/test_ui_text -r --path:src tests/test_ui_text.nim"
  exec "nim c --mm:arc --nimcache:.nimcache/test_editor -r --path:src tests/test_editor.nim"
  exec "nim c --mm:arc --nimcache:.nimcache/test_editor_fuzz -r --path:src tests/test_editor_fuzz.nim"
  exec "nim c --mm:arc --nimcache:.nimcache/test_workspace -r --path:src tests/test_workspace.nim"
  exec "nim c --mm:arc --nimcache:.nimcache/test_tree_sitter -r --path:src tests/test_tree_sitter.nim"
  exec "nim c --mm:arc --nimcache:.nimcache/test_syntax -r --path:src tests/test_syntax.nim"
  exec "nim c --mm:arc --nimcache:.nimcache/test_editor_syntax -r --path:src tests/test_editor_syntax.nim"
  exec "nim c --mm:arc --nimcache:.nimcache/test_lsp -r --path:src tests/test_lsp.nim"
  exec "nim c --mm:arc --nimcache:.nimcache/test_lsp_editor_bridge -r --path:src tests/test_lsp_editor_bridge.nim"
  exec "nim c --mm:arc --nimcache:.nimcache/test_git_service -r --path:src tests/test_git_service.nim"

task benchmark, "Run platform benchmark smoke tests":
  exec "nim c --mm:arc --nimcache:.nimcache/bench_platform -r --path:src tests/bench_platform.nim"
  exec "nim c --mm:arc --nimcache:.nimcache/bench_editor -r --path:src tests/bench_editor.nim"
  exec "nim c --mm:arc --nimcache:.nimcache/bench_large_editor -r --path:src tests/bench_large_editor.nim"
  exec "nim c --mm:arc --nimcache:.nimcache/bench_buffer_strategies -r --path:src tests/bench_buffer_strategies.nim"
  exec "nim c --mm:arc --nimcache:.nimcache/bench_syntax -r --path:src tests/bench_syntax.nim"
  exec "nim c --mm:arc --nimcache:.nimcache/bench_workspace -r --path:src tests/bench_workspace.nim"
