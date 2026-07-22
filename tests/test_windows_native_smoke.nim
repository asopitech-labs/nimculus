import std/unittest

when defined(windows):
  import nimnui/platform/windows/platform

  var callbackRan = false
  var atlasUploadPassed = false
  var subpixelPassed = false
  var shapingPassed = false
  var fallbackPassed = false
  var fallbackShapingPassed = false
  var colorGlyphPassed = false
  var advancedColorGlyphPassed = false
  var pngColorAtlasPassed = false
  var jpegColorAtlasPassed = false
  var colorAtlasPassed = false
  var interactionPassed = false
  var visibleGlyphPassed = false
  var inputEvents = 0
  var textEvents = 0

  proc countInput(event: ptr NimculusInputEvent) {.cdecl.} =
    if event != nil:
      inputEvents.inc

  proc countText(text: cstring, composing: bool) {.cdecl.} =
    if text != nil:
      textEvents.inc

  proc validateNativeFrame() {.cdecl.} =
    if callbackRan:
      return
    callbackRan = true
    atlasUploadPassed = platformValidateGlyphAtlasUpload()
    subpixelPassed = platformValidateGlyphSubpixelVariants()
    shapingPassed = platformValidateGlyphShaping()
    fallbackPassed = platformValidateGlyphFallback()
    fallbackShapingPassed = platformValidateGlyphFallbackShaping()
    colorGlyphPassed = platformValidateColorGlyphPath()
    advancedColorGlyphPassed = platformValidateAdvancedColorGlyphPath()
    pngColorAtlasPassed = platformValidatePngColorGlyphAtlas()
    jpegColorAtlasPassed = platformValidateJpegColorGlyphAtlas()
    colorAtlasPassed = platformValidateColorGlyphAtlas()
    visibleGlyphPassed = platformValidateVisibleGlyphFrame()
    interactionPassed = platformValidateNativeInteraction()
    platformRequestQuit()

  suite "Windows native GPU text smoke":
    test "creates D3D11 device and validates glyph frame contracts":
      let sample = "office 日本 😀"
      platformSetEditorText(sample.cstring, uint32(sample.len))
      platformSetInputCallback(countInput)
      platformSetTextCallback(countText)
      platformSetIdleCallback(validateNativeFrame)
      check platformRun()
      check callbackRan
      check atlasUploadPassed
      check subpixelPassed
      check shapingPassed
      check fallbackPassed
      check fallbackShapingPassed
      check colorGlyphPassed
      check advancedColorGlyphPassed
      check pngColorAtlasPassed
      check jpegColorAtlasPassed
      check colorAtlasPassed
      check visibleGlyphPassed
      check interactionPassed
      check inputEvents >= 6
      check textEvents >= 3
else:
  suite "Windows native GPU text smoke":
    test "requires a Windows runner":
      echo "  [SKIP] Windows native GPU smoke requires Windows"
