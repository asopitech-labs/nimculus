import std/times
import nimnui/platform/macos/platform

let start = cpuTime()
var metrics: PlatformMetrics
for _ in 0 ..< 100_000:
  platformGetMetrics(addr metrics)
echo "platform metrics calls: 100000, elapsed: ", cpuTime() - start, "s"
