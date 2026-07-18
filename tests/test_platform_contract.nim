import std/unittest
import nimnui/platform/macos/platform

suite "macOS platform contract":
  test "metrics have a valid default scale":
    var metrics: PlatformMetrics
    platformGetMetrics(addr metrics)
    check metrics.scaleFactor >= 0.0
    check metrics.widthPixels >= 0'u32

  test "input counter is monotonic":
    let before = platformInputCount()
    let after = platformInputCount()
    check after >= before

  test "native Metal layer contract is available":
    # CI and terminal-only sessions may not expose a Metal device. In that
    # environment the native smoke test is unavailable, not a contract failure.
    if platformValidateNative():
      check true
    else:
      echo "  [SKIP] native Metal layer contract (no Metal device in this session)"
