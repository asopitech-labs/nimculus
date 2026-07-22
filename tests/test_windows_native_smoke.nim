import std/unittest

when defined(windows):
  import nimnui/platform/windows/platform

  var callbackRan = false
  var atlasUploadPassed = false
  var subpixelPassed = false
  var shapingPassed = false

  proc validateNativeFrame() {.cdecl.} =
    if callbackRan:
      return
    callbackRan = true
    atlasUploadPassed = platformValidateGlyphAtlasUpload()
    subpixelPassed = platformValidateGlyphSubpixelVariants()
    shapingPassed = platformValidateGlyphShaping()
    platformRequestQuit()

  suite "Windows native GPU text smoke":
    test "creates D3D11 device and validates glyph frame contracts":
      platformSetIdleCallback(validateNativeFrame)
      check platformRun()
      check callbackRan
      check atlasUploadPassed
      check subpixelPassed
      check shapingPassed
else:
  suite "Windows native GPU text smoke":
    test "requires a Windows runner":
      echo "  [SKIP] Windows native GPU smoke requires Windows"
