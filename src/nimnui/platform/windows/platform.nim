when defined(windows) and not defined(nimculusPortableOnly):
  {.compile: "windows_platform.c".}
  {.passL: "-ld3d11 -ldxgi -ld3dcompiler -ld2d1 -ldwrite -luser32 -lgdi32 -lcomdlg32 -limm32 -lshell32 -lpsapi".}

import nimnui/platform/headless/platform as headless_platform
export headless_platform

when defined(windows) and not defined(nimculusPortableOnly):
  proc platformRun*(): bool {.importc: "nimculus_platform_run", cdecl.}
  proc platformRequestQuit*() {.importc: "nimculus_platform_request_quit", cdecl.}
  proc platformValidateNative*(): bool {.importc: "nimculus_platform_validate_native", cdecl.}
  proc platformGetMetrics*(metrics: ptr PlatformMetrics) {.importc: "nimculus_platform_get_metrics", cdecl.}
  proc platformResidentMemoryBytes*(): uint64 {.importc: "nimculus_platform_resident_memory_bytes", cdecl.}
  proc platformInputCount*(): uint64 {.importc: "nimculus_platform_input_count", cdecl.}
  proc platformSetInputCallback*(callback: InputCallback) {.importc: "nimculus_platform_set_input_callback", cdecl.}
  proc platformSetShortcutCallback*(callback: ShortcutCallback) {.importc: "nimculus_platform_set_shortcut_callback", cdecl.}
  proc platformSetTextCallback*(callback: TextCallback) {.importc: "nimculus_platform_set_text_callback", cdecl.}
  proc platformSetFileCallback*(callback: FileCallback) {.importc: "nimculus_platform_set_file_callback", cdecl.}
  proc platformSetCommandCallback*(callback: CommandCallback) {.importc: "nimculus_platform_set_command_callback", cdecl.}
  proc platformShowCommandPalette*() {.importc: "nimculus_platform_show_command_palette", cdecl.}
  proc platformSetIdleCallback*(callback: IdleCallback) {.importc: "nimculus_platform_set_idle_callback", cdecl.}
  proc platformSetTerminalVisible*(visible: bool) {.importc: "nimculus_platform_set_terminal_visible", cdecl.}
  proc platformSetTaskOutputVisible*(visible: bool) {.importc: "nimculus_platform_set_task_output_visible", cdecl.}
  proc platformSetTerminalText*(text: cstring, length: uint32) {.importc: "nimculus_platform_set_terminal_text", cdecl.}
  proc platformSetTaskOutputText*(text: cstring, length: uint32) {.importc: "nimculus_platform_set_task_output_text", cdecl.}
  proc platformSetTerminalRuns*(text: cstring, length: uint32,
      runs: ptr NativeTerminalRun, count: uint32) {.importc: "nimculus_platform_set_terminal_runs", cdecl.}
  proc platformSetTerminalFontSize*(size: cdouble) {.importc: "nimculus_platform_set_terminal_font_size", cdecl.}
  proc platformSetTerminalFontName*(name: cstring) {.importc: "nimculus_platform_set_terminal_font_name", cdecl.}
  proc platformGetTerminalCellMetrics*(cellWidth, lineHeight: ptr cdouble) {.importc: "nimculus_platform_get_terminal_cell_metrics", cdecl.}
  proc platformSetPaintCommands*(commands: ptr NativePaintCommand, count: uint32) {.importc: "nimculus_platform_set_paint_commands", cdecl.}
  proc platformSetImageRgba*(imageId, width, height: uint32, rgba: pointer,
      length: uint32) {.importc: "nimculus_platform_set_image_rgba", cdecl.}
  proc platformSetEditorText*(text: cstring, length: uint32) {.importc: "nimculus_platform_set_editor_text", cdecl.}
  proc platformSetEditorRect*(x, y, width, height: cdouble) {.importc: "nimculus_platform_set_editor_rect", cdecl.}
  proc platformSetEditorComposition*(text: cstring) {.importc: "nimculus_platform_set_editor_composition", cdecl.}
  proc platformSetEditorDirty*(dirty: bool) {.importc: "nimculus_platform_set_editor_dirty", cdecl.}
  proc platformSetEditorIndentGuides*(visible: bool, indentWidth: uint32) {.importc: "nimculus_platform_set_editor_indent_guides", cdecl.}
  proc platformSetEditorLineNumbers*(visible: bool) {.importc: "nimculus_platform_set_editor_line_numbers", cdecl.}
  proc platformSetEditorSoftWrap*(enabled: bool) {.importc: "nimculus_platform_set_editor_soft_wrap", cdecl.}
  proc platformSetEditorTabs*(titles: cstring, length, activeIndex: uint32) {.importc: "nimculus_platform_set_editor_tabs", cdecl.}
  proc platformSetEditorStatus*(text: cstring) {.importc: "nimculus_platform_set_editor_status", cdecl.}
  proc platformSetTerminalSelection*(startRow, startColumn, endRow,
      endColumn: uint32) {.importc: "nimculus_platform_set_terminal_selection", cdecl.}
  proc platformSetEditorHighlights*(spans: ptr NativeHighlightSpan,
      count: uint32) {.importc: "nimculus_platform_set_editor_highlights", cdecl.}
  proc platformSetEditorFontSize*(size: cdouble) {.importc: "nimculus_platform_set_editor_font_size", cdecl.}
  proc platformSetEditorFontName*(name: cstring) {.importc: "nimculus_platform_set_editor_font_name", cdecl.}
  proc platformEditorLineHeight*(): cdouble {.importc: "nimculus_platform_editor_line_height", cdecl.}
  proc platformSetEditorCursorByte*(byteOffset, line: uint32) {.importc: "nimculus_platform_set_editor_cursor_byte", cdecl.}
  proc platformSetEditorScrollLine*(line: uint32) {.importc: "nimculus_platform_set_editor_scroll_line", cdecl.}
  proc platformSetEditorSelection*(startByte, endByte: uint32) {.importc: "nimculus_platform_set_editor_selection", cdecl.}
  proc platformSetCloseDecision*(allow: bool) {.importc: "nimculus_platform_set_close_decision", cdecl.}
  proc platformToggleFullscreen*() {.importc: "nimculus_platform_toggle_fullscreen", cdecl.}
  proc platformMinimizeWindow*() {.importc: "nimculus_platform_minimize_window", cdecl.}
  proc platformMaximizeWindow*() {.importc: "nimculus_platform_maximize_window", cdecl.}
  proc platformRestoreWindow*() {.importc: "nimculus_platform_restore_window", cdecl.}
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
  proc platformResidentMemoryBytes*(): uint64 = 0
  proc platformInputCount*(): uint64 = 0
  proc platformSetInputCallback*(callback: InputCallback) =
    if callback != nil: discard
  proc platformSetShortcutCallback*(callback: ShortcutCallback) =
    if callback != nil: discard
  proc platformSetTextCallback*(callback: TextCallback) =
    if callback != nil: discard
  proc platformSetFileCallback*(callback: FileCallback) =
    if callback != nil: discard
  proc platformSetCommandCallback*(callback: CommandCallback) =
    if callback != nil: discard
  proc platformSetIdleCallback*(callback: IdleCallback) =
    if callback != nil: discard
  proc platformShowCommandPalette*() = discard
  proc platformSetTerminalVisible*(visible: bool) = discard visible
  proc platformSetTaskOutputVisible*(visible: bool) = discard visible
  proc platformSetTerminalText*(text: cstring, length: uint32) = discard (text, length)
  proc platformSetTaskOutputText*(text: cstring, length: uint32) = discard (text, length)
  proc platformSetTerminalRuns*(text: cstring, length: uint32,
      runs: ptr NativeTerminalRun, count: uint32) = discard (text, length, runs, count)
  proc platformGetTerminalCellMetrics*(cellWidth, lineHeight: ptr cdouble) =
    if cellWidth != nil: cellWidth[] = 7.2
    if lineHeight != nil: lineHeight[] = 14.0
  proc platformSetPaintCommands*(commands: ptr NativePaintCommand, count: uint32) = discard (commands, count)
  proc platformSetImageRgba*(imageId, width, height: uint32, rgba: pointer,
      length: uint32) = discard (imageId, width, height, rgba, length)
  proc platformSetEditorText*(text: cstring, length: uint32) = discard (text, length)
  proc platformSetEditorRect*(x, y, width, height: cdouble) = discard (x, y, width, height)
  proc platformSetEditorComposition*(text: cstring) = discard text
  proc platformSetEditorDirty*(dirty: bool) = discard dirty
  proc platformSetEditorIndentGuides*(visible: bool, indentWidth: uint32) = discard (visible, indentWidth)
  proc platformSetEditorLineNumbers*(visible: bool) = discard visible
  proc platformSetEditorSoftWrap*(enabled: bool) = discard enabled
  proc platformSetEditorTabs*(titles: cstring, length, activeIndex: uint32) = discard (titles, length, activeIndex)
  proc platformSetEditorStatus*(text: cstring) = discard text
  proc platformSetTerminalSelection*(startRow, startColumn, endRow,
      endColumn: uint32) = discard (startRow, startColumn, endRow, endColumn)
  proc platformSetEditorHighlights*(spans: ptr NativeHighlightSpan,
      count: uint32) = discard (spans, count)
  proc platformSetEditorCursorByte*(byteOffset, line: uint32) = discard (byteOffset, line)
  proc platformSetEditorScrollLine*(line: uint32) = discard line
  proc platformSetEditorSelection*(startByte, endByte: uint32) = discard (startByte, endByte)
  proc platformSetCloseDecision*(allow: bool) = discard allow
  proc platformToggleFullscreen*() = discard
  proc platformMinimizeWindow*() = discard
  proc platformMaximizeWindow*() = discard
  proc platformRestoreWindow*() = discard
  proc platformSetEditorCursor*(x, y: cdouble) = discard (x, y)
  proc platformSetEditorFontSize*(size: cdouble) = discard size
  proc platformSetEditorFontName*(name: cstring) = discard name
  proc platformSetTerminalFontSize*(size: cdouble) = discard size
  proc platformSetTerminalFontName*(name: cstring) = discard name
  proc platformEditorLineHeight*(): cdouble = 16.0
  proc platformInvalidateImeCoordinates*() = discard
  proc clipboardSet*(text: cstring, length: uint32) = discard (text, length)
  proc clipboardGet*(): string = ""
  proc chooseOpenFile*(): cstring = ""
  proc chooseSaveFile*(): cstring = ""
