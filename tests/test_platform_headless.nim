import std/unittest
import nimnui/platform/headless/platform

suite "portable platform contract":
  test "headless backend exposes safe default metrics":
    var metrics: PlatformMetrics
    platformGetMetrics(addr metrics)
    check metrics.scaleFactor == 1.0
    check metrics.widthPixels == 0'u32
    check not platformValidateNative()

  test "headless ABI sizes use the shared contracts":
    check platformMetricsSize() == uint32(sizeof(PlatformMetrics))
    check platformInputEventSize() == uint32(sizeof(NimculusInputEvent))
    check platformPaintCommandSize() == uint32(sizeof(NativePaintCommand))
    check platformPaintRegionSize() == uint32(sizeof(NativePaintRegion))

  test "headless UI calls are safe no-ops":
    platformSetEditorText("portable".cstring, 8)
    platformSetPaintCommands(nil, 0)
    platformSetPaintDirtyRegions(nil, 0)
    platformSetEditorSelection(0, 0)
    check platformEditorByteOffsetAtPoint(10.0, 10.0) == 0'u32
