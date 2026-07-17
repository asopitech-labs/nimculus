when defined(macosx):
  {.compile: "macos_platform.m".}
  {.passL: "-framework Cocoa -framework Metal -framework QuartzCore".}

type
  PlatformMetrics* {.bycopy.} = object
    scaleFactor*: cdouble
    widthPoints*: uint32
    heightPoints*: uint32
    widthPixels*: uint32
    heightPixels*: uint32

proc platformRun*(): bool {.importc: "nimculus_platform_run", cdecl.}
proc platformGetMetrics*(metrics: ptr PlatformMetrics) {.importc: "nimculus_platform_get_metrics", cdecl.}
proc platformInputCount*(): uint64 {.importc: "nimculus_platform_input_count", cdecl.}
