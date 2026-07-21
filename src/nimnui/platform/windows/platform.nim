when defined(windows) and not defined(nimculusPortableOnly):
  {.compile: "windows_platform.c".}
  {.passL: "-ld3d11 -ldxgi -luser32 -lgdi32".}

import nimnui/platform/headless/platform as headless_platform
export headless_platform

when defined(windows) and not defined(nimculusPortableOnly):
  proc platformRun*(): bool {.importc: "nimculus_platform_run", cdecl.}
  proc platformValidateNative*(): bool {.importc: "nimculus_platform_validate_native", cdecl.}
  proc platformGetMetrics*(metrics: ptr PlatformMetrics) {.importc: "nimculus_platform_get_metrics", cdecl.}
  proc platformInputCount*(): uint64 {.importc: "nimculus_platform_input_count", cdecl.}
  proc platformSetInputCallback*(callback: InputCallback) {.importc: "nimculus_platform_set_input_callback", cdecl.}
  proc platformSetTextCallback*(callback: TextCallback) {.importc: "nimculus_platform_set_text_callback", cdecl.}
else:
  proc platformRun*(): bool = false
  proc platformValidateNative*(): bool = false
  proc platformGetMetrics*(metrics: ptr PlatformMetrics) =
    if metrics != nil: metrics[] = PlatformMetrics(scaleFactor: 1.0)
  proc platformInputCount*(): uint64 = 0
  proc platformSetInputCallback*(callback: InputCallback) =
    if callback != nil: discard
  proc platformSetTextCallback*(callback: TextCallback) =
    if callback != nil: discard
