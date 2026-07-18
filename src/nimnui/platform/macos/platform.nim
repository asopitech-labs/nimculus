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
type
  InputCallback* = proc(event: ptr NimculusInputEvent) {.cdecl.}
  TextCallback* = proc(utf8: cstring, composing: bool) {.cdecl.}
  FileCallback* = proc(path: cstring, saving: bool) {.cdecl.}
  CommandCallback* = proc(command: cstring) {.cdecl.}
  NimculusInputEvent* {.bycopy.} = object
    kind*, keyCode*, modifiers*: uint32
    x*, y*, deltaX*, deltaY*: cdouble

proc platformSetInputCallback*(callback: InputCallback) {.importc: "nimculus_platform_set_input_callback", cdecl.}
proc platformSetTextCallback*(callback: TextCallback) {.importc: "nimculus_platform_set_text_callback", cdecl.}
proc platformSetFileCallback*(callback: FileCallback) {.importc: "nimculus_platform_set_file_callback", cdecl.}
proc platformSetCommandCallback*(callback: CommandCallback) {.importc: "nimculus_platform_set_command_callback", cdecl.}
proc platformSetEditorCursor*(x, y: cdouble) {.importc: "nimculus_platform_set_editor_cursor", cdecl.}
proc platformSetEditorText*(text: cstring) {.importc: "nimculus_platform_set_editor_text", cdecl.}
proc platformSetUiRectangle*(x, y, width, height: cdouble) {.importc: "nimculus_platform_set_ui_rectangle", cdecl.}
proc clipboardSet*(text: cstring) {.importc: "nimculus_clipboard_set", cdecl.}
proc clipboardGet*(): cstring {.importc: "nimculus_clipboard_get", cdecl.}
proc chooseOpenFile*(): cstring {.importc: "nimculus_choose_open_file", cdecl.}
proc chooseSaveFile*(): cstring {.importc: "nimculus_choose_save_file", cdecl.}
