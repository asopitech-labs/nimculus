import std/unittest
when defined(windows):
  import nimnui/platform/windows/platform

  suite "Windows platform contract":
    test "metrics and process counters are callable":
      var metrics: PlatformMetrics
      platformGetMetrics(addr metrics)
      check metrics.scaleFactor >= 0.0
      check metrics.widthPixels >= 0'u32
      check metrics.lastFrameTimeMs >= 0.0
      check metrics.lastInputLatencyMs >= 0.0
      check platformResidentMemoryBytes() >= 0'u64
      check platformLiveAllocationCount() >= 0'u64

    test "native ABI sizes match shared contracts":
      check uint32(sizeof(PlatformMetrics)) == platformMetricsSize()
      check uint32(sizeof(NimculusInputEvent)) == platformInputEventSize()
      check uint32(sizeof(NativeTerminalRun)) == platformTerminalRunSize()
      check uint32(sizeof(NativeHighlightSpan)) == platformHighlightSpanSize()
      check uint32(sizeof(NativeDiagnosticSpan)) == platformDiagnosticSpanSize()
      check uint32(sizeof(NativePaintCommand)) == platformPaintCommandSize()
      check uint32(sizeof(NativePaintRegion)) == platformPaintRegionSize()

    test "input counter is monotonic":
      let before = platformInputCount()
      let after = platformInputCount()
      check after >= before

    test "native startup failure is observable without crashing":
      if platformValidateNative():
        check true
      else:
        echo "  [SKIP] native D3D11 device contract (no active window in this test)"

    test "DirectWrite text format is cached for an unchanged configuration":
      check platformValidateTextFormatCache()

    test "DirectWrite glyph rasterization interface is available":
      check platformValidateGlyphRasterInterface()

    test "DirectWrite glyph raster cache reuses the same raster":
      check platformValidateGlyphRasterCache()

    test "DirectWrite glyph raster cache separates subpixel variants":
      check platformValidateGlyphSubpixelVariants()

    test "DirectWrite analyzer produces a shaped glyph run":
      check platformValidateGlyphShaping()

    test "DirectWrite system fallback maps Japanese text to a font face":
      check platformValidateGlyphFallback()
    test "DirectWrite system fallback shapes a Japanese glyph run":
      check platformValidateGlyphFallbackShaping()
    test "DirectWrite color glyph translation path is safe":
      check platformValidateColorGlyphPath()

    test "DirectWrite Factory4 color glyph formats are classified safely":
      if platformValidateNative():
        check platformValidateAdvancedColorGlyphPath()
      else:
        echo "  [SKIP] DirectWrite Factory4 color format contract requires an active native window"

    test "PNG color glyphs decode and upload when the fallback provides them":
      if platformValidateNative():
        check platformValidatePngColorGlyphAtlas()
      else:
        echo "  [SKIP] PNG color atlas contract requires an active native window"

    test "D3D11 glyph atlas uploads and reuses a cached tile":
      if platformValidateNative():
        check platformValidateGlyphAtlasUpload()
      else:
        echo "  [SKIP] D3D11 glyph atlas upload requires an active native window"
else:
  suite "Windows platform contract":
    test "requires a Windows runner":
      echo "  [SKIP] Windows native platform contract requires Windows"
