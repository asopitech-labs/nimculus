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
  var interactionPassed = false
  var inputEvents = 0

  proc countInput(event: ptr NimculusInputEvent) {.cdecl.} =
    if event != nil:
      inputEvents.inc

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
    interactionPassed = platformValidateNativeInteraction()
    platformRequestQuit()

  suite "Windows native GPU text smoke":
    test "creates D3D11 device and validates glyph frame contracts":
      platformSetInputCallback(countInput)
      platformSetIdleCallback(validateNativeFrame)
      check platformRun()
      check callbackRan
      check atlasUploadPassed
      check subpixelPassed
      check shapingPassed
      check fallbackPassed
      check fallbackShapingPassed
      check colorGlyphPassed
      check interactionPassed
      check inputEvents >= 6
else:
  suite "Windows native GPU text smoke":
    test "requires a Windows runner":
      echo "  [SKIP] Windows native GPU smoke requires Windows"
