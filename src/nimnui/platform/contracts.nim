## OS-independent ABI contracts shared by NimNUI platform backends.
##
## Keep these layouts synchronized with the native header for every backend.
## Backend-specific window, GPU, IME, and dialog code belongs beside the
## platform implementation, not in this module.

type
  PlatformMetrics* {.bycopy.} = object
    scaleFactor*: cdouble
    widthPoints*: uint32
    heightPoints*: uint32
    widthPixels*: uint32
    heightPixels*: uint32
    lastFrameTimeMs*: cdouble
    frameCount*: uint64

  NativeHighlightSpan* {.bycopy.} = object
    startByte*, endByte*, kind*: uint32
  NativeDiagnosticSpan* {.bycopy.} = object
    startByte*, endByte*, severity*: uint32
  NativeGitHunkSpan* {.bycopy.} = object
    startLine*, lineCount*, kind*: uint32
  NativePaintCommand* {.bycopy.} = object
    kind*: uint32
    x*, y*, width*, height*: cfloat
    clipX*, clipY*, clipWidth*, clipHeight*: cfloat
    radius*: cfloat
    sourceX*, sourceY*, sourceWidth*, sourceHeight*: cfloat
    transformA*, transformB*, transformC*, transformD*, transformTx*, transformTy*: cfloat
    imageId*: uint32
  NativePaintRegion* {.bycopy.} = object
    x*, y*, width*, height*: cfloat
  NativeEditorAnnotation* {.bycopy.} = object
    line*, character*, kind*: uint32
    text*: cstring
  NativeTerminalRun* {.bycopy.} = object
    startByte*, endByte*, flags*: uint32
    row*, column*, cellWidth*: uint32
    foregroundKind*, foregroundIndex*, foregroundRed*, foregroundGreen*, foregroundBlue*: uint32
    backgroundKind*, backgroundIndex*, backgroundRed*, backgroundGreen*, backgroundBlue*: uint32
    hyperlinkUri*: cstring
  NimculusInputEvent* {.bycopy.} = object
    kind*, keyCode*, modifiers*, button*: uint32
    x*, y*, deltaX*, deltaY*: cdouble
    preciseScrolling*: bool

  InputCallback* = proc(event: ptr NimculusInputEvent) {.cdecl.}
  ShortcutCallback* = proc(event: ptr NimculusInputEvent): bool {.cdecl.}
  TextCallback* = proc(utf8: cstring, composing: bool) {.cdecl.}
  SelectionCallback* = proc(startByte, endByte: uint32) {.cdecl.}
  FileCallback* = proc(path: cstring, saving: bool) {.cdecl.}
  CommandCallback* = proc(command: cstring) {.cdecl.}
  IdleCallback* = proc() {.cdecl.}
