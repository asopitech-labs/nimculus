## OS-independent ABI contracts shared by NimNUI platform backends.
##
## Keep these layouts synchronized with the native header for every backend.
## Backend-specific window, GPU, IME, and dialog code belongs beside the
## platform implementation, not in this module.

type
  ## The phases forwarded by the macOS scroll-wheel contract. The native ABI
  ## stores this as uint32 so every backend has the same layout.
  TouchPhase* = enum
    touchStarted
    touchMoved
    touchEnded

  PlatformPriority* = enum
    platformHigh
    platformMedium
    platformLow

  ## C ABI runnable/context signature used by native backends.
  PlatformRunnable* = proc(context: pointer) {.cdecl, gcsafe.}
  Runnable* = proc() {.gcsafe.}

  PlatformDispatcher* = ref object
    ## Framework-facing equivalent of Zed's PlatformDispatcher. The object
    ## contains only scheduling operations; UI decisions do not belong here.
    mainThread*: proc(): bool {.gcsafe.}
    background*: proc(runnable: Runnable, priority: PlatformPriority) {.gcsafe.}
    mainQueue*: proc(runnable: Runnable, priority: PlatformPriority) {.gcsafe.}
    delayed*: proc(durationNanoseconds: uint64, runnable: Runnable) {.gcsafe.}

  PlatformMetrics* {.bycopy.} = object
    scaleFactor*: cdouble
    widthPoints*: uint32
    heightPoints*: uint32
    widthPixels*: uint32
    heightPixels*: uint32
    lastFrameTimeMs*: cdouble
    frameCount*: uint64
    lastInputLatencyMs*: cdouble

  NativeHighlightSpan* {.bycopy.} = object
    startByte*, endByte*, kind*: uint32
  NativeDiagnosticSpan* {.bycopy.} = object
    startByte*, endByte*, severity*: uint32
  NativeEditorLayoutGlyph* {.bycopy.} = object
    glyphId*: uint32
    x*, y*: cfloat
    index*, fontId*, colorKind*: uint32
    isEmoji*: bool
    red*, green*, blue*, alpha*: cfloat
  NativeEditorGlyphColor* {.bycopy.} = object
    red*, green*, blue*, alpha*: cfloat
  NativeEditorLayoutRow* {.bycopy.} = object
    sourceLine*, displayRow*, sourceStartByte*: uint32
    segmentStartByte*, segmentEndByte*: uint32
    glyphStart*, glyphCount*: uint32
    fontSize*, ascent*, descent*: cfloat
  NativeEditorSelection* {.bycopy.} = object
    startByte*, endByte*, cursorByte*: uint32
  NativeGitHunkSpan* {.bycopy.} = object
    startLine*, lineCount*, kind*: uint32
  NativeFoldRange* {.bycopy.} = object
    startLine*, endLine*: uint32
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
  NativeAccessibilityNode* {.bycopy.} = object
    id*, parentId*: uint64
    role*, childStart*, childCount*: uint32
    x*, y*, width*, height*: cfloat
    textStartByte*, textEndByte*, cursorByte*: uint32
    selectionStartByte*, selectionEndByte*, flags*: uint32
    identifier*, title*, value*, actionCommand*: cstring
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
    phase*: uint32

  InputCallback* = proc(event: ptr NimculusInputEvent) {.cdecl.}
  ShortcutCallback* = proc(event: ptr NimculusInputEvent): bool {.cdecl.}
  TextCallback* = proc(utf8: cstring, composing: bool) {.cdecl.}
  SelectionCallback* = proc(startByte, endByte: uint32) {.cdecl.}
  FileCallback* = proc(path: cstring, saving: bool) {.cdecl.}
  CommandCallback* = proc(command: cstring) {.cdecl.}
  IdleCallback* = proc() {.cdecl.}
  FrameCallback* = proc() {.cdecl.}

proc isMainThread*(dispatcher: PlatformDispatcher): bool =
  dispatcher.mainThread()

proc dispatch*(dispatcher: PlatformDispatcher, runnable: Runnable,
               priority = platformMedium) =
  dispatcher.background(runnable, priority)

proc dispatchOnMainThread*(dispatcher: PlatformDispatcher, runnable: Runnable,
                           priority = platformMedium) =
  dispatcher.mainQueue(runnable, priority)

proc dispatchAfter*(dispatcher: PlatformDispatcher, durationNanoseconds: uint64,
                    runnable: Runnable) =
  dispatcher.delayed(durationNanoseconds, runnable)
