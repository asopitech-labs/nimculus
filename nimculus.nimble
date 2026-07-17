version       = "0.1.0"
author        = "Nimculus contributors"
description   = "A macOS-first GPU-native code editor"
license       = "MIT"
srcDir        = "src"
bin           = @ ["nimculus/main"]

requires "nim >= 2.0.0"

task build, "Build the Nimculus macOS application":
  exec "nim c --mm:arc -d:release src/nimculus/main.nim"

task test, "Run unit and integration tests":
  exec "nim c --mm:arc -r --path:src tests/test_platform_contract.nim"

task benchmark, "Run platform benchmark smoke tests":
  exec "nim c --mm:arc -r --path:src tests/bench_platform.nim"
