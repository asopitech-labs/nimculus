when defined(windows) and not defined(nimculusPortableOnly):
  {.compile: "windows_platform.c".}
  {.passL: "-ld3d11 -ldxgi -luser32 -lgdi32 -lcomdlg32 -limm32 -lshell32".}

import nimnui/platform/headless/platform as headless_platform
export headless_platform

when defined(windows) and not defined(nimculusPortableOnly):
  proc platformRun*(): bool {.importc: "nimculus_platform_run", cdecl.}
  proc platformValidateNative*(): bool {.importc: "nimculus_platform_validate_native", cdecl.}
  proc platformGetMetrics*(metrics: ptr PlatformMetrics) {.importc: "nimculus_platform_get_metrics", cdecl.}
  proc platformInputCount*(): uint64 {.importc: "nimculus_platform_input_count", cdecl.}
  proc platformSetInputCallback*(callback: InputCallback) {.importc: "nimculus_platform_set_input_callback", cdecl.}
  proc platformSetTextCallback*(callback: TextCallback) {.importc: "nimculus_platform_set_text_callback", cdecl.}
  proc platformSetFileCallback*(callback: FileCallback) {.importc: "nimculus_platform_set_file_callback", cdecl.}
  proc platformSetCommandCallback*(callback: CommandCallback) {.importc: "nimculus_platform_set_command_callback", cdecl.}
  proc platformSetIdleCallback*(callback: IdleCallback) {.importc: "nimculus_platform_set_idle_callback", cdecl.}
  proc platformSetTerminalVisible*(visible: bool) {.importc: "nimculus_platform_set_terminal_visible", cdecl.}
  proc platformSetTerminalText*(text: cstring, length: uint32) {.importc: "nimculus_platform_set_terminal_text", cdecl.}
  proc platformSetEditorCursor*(x, y: cdouble) {.importc: "nimculus_platform_set_editor_cursor", cdecl.}
  proc platformInvalidateImeCoordinates*() {.importc: "nimculus_platform_invalidate_ime_coordinates", cdecl.}
  proc clipboardSet*(text: cstring, length: uint32) {.importc: "nimculus_clipboard_set", cdecl.}
  proc clipboardUtf8Length*(): uint32 {.importc: "nimculus_clipboard_utf8_length", cdecl.}
  proc clipboardUtf8Bytes*(): pointer {.importc: "nimculus_clipboard_utf8_bytes", cdecl.}
  proc chooseOpenFile*(): cstring {.importc: "nimculus_choose_open_file", cdecl.}
  proc chooseSaveFile*(): cstring {.importc: "nimculus_choose_save_file", cdecl.}
  proc clipboardGet*(): string =
    let length = int(clipboardUtf8Length())
    if length <= 0: return ""
    let bytes = clipboardUtf8Bytes()
    if bytes == nil: return ""
    result = newString(length)
    copyMem(addr result[0], bytes, length)
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
  proc platformSetFileCallback*(callback: FileCallback) =
    if callback != nil: discard
  proc platformSetCommandCallback*(callback: CommandCallback) =
    if callback != nil: discard
  proc platformSetIdleCallback*(callback: IdleCallback) =
    if callback != nil: discard
  proc platformSetTerminalVisible*(visible: bool) = discard visible
  proc platformSetTerminalText*(text: cstring, length: uint32) = discard (text, length)
  proc platformSetEditorCursor*(x, y: cdouble) = discard (x, y)
  proc platformInvalidateImeCoordinates*() = discard
  proc clipboardSet*(text: cstring, length: uint32) = discard (text, length)
  proc clipboardGet*(): string = ""
  proc chooseOpenFile*(): cstring = ""
  proc chooseSaveFile*(): cstring = ""
