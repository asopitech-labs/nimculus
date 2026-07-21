## Portable fallback backend used until a native desktop backend is selected.
##
## This deliberately owns no OS APIs. It keeps the NimNUI/application layer
## buildable on non-macOS hosts while Win32, Wayland, and X11 backends are
## developed behind the same contracts (following Zed's platform selection
## boundary rather than leaking one OS into the core).

import nimnui/platform/contracts

export contracts

when not defined(windows):
  proc platformRun*(): bool = false
  proc platformValidateNative*(): bool = false
  proc platformValidateGlyphAtlas*(): bool = false

  proc platformGetMetrics*(metrics: ptr PlatformMetrics) =
    if metrics != nil:
      metrics[] = PlatformMetrics(scaleFactor: 1.0)

  proc platformInputCount*(): uint64 = 0
proc platformMetricsSize*(): uint32 = uint32(sizeof(PlatformMetrics))
proc platformInputEventSize*(): uint32 = uint32(sizeof(NimculusInputEvent))
proc platformTerminalRunSize*(): uint32 = uint32(sizeof(NativeTerminalRun))
proc platformHighlightSpanSize*(): uint32 = uint32(sizeof(NativeHighlightSpan))
proc platformDiagnosticSpanSize*(): uint32 = uint32(sizeof(NativeDiagnosticSpan))
proc platformEditorAnnotationSize*(): uint32 = uint32(sizeof(NativeEditorAnnotation))
proc platformGitHunkSpanSize*(): uint32 = uint32(sizeof(NativeGitHunkSpan))
proc platformPaintCommandSize*(): uint32 = uint32(sizeof(NativePaintCommand))
proc platformPaintRegionSize*(): uint32 = uint32(sizeof(NativePaintRegion))

when not defined(windows):
  proc platformSetInputCallback*(callback: InputCallback) =
    if callback != nil: discard
when not defined(windows):
  proc platformSetTextCallback*(callback: TextCallback) =
    if callback != nil: discard
when not defined(windows):
  proc platformSetShortcutCallback*(callback: ShortcutCallback) =
    if callback != nil: discard
proc platformSetSelectionCallback*(callback: SelectionCallback) =
  if callback != nil: discard
when not defined(windows):
  proc platformSetFileCallback*(callback: FileCallback) =
    if callback != nil: discard
when not defined(windows):
  proc platformSetCommandCallback*(callback: CommandCallback) =
    if callback != nil: discard
when not defined(windows):
  proc platformSetIdleCallback*(callback: IdleCallback) =
    if callback != nil: discard
when not defined(windows):
  proc platformSetEditorCursor*(x, y: cdouble) = discard (x, y)
when not defined(windows):
  proc platformSetEditorCursorByte*(byteOffset, line: uint32) = discard (byteOffset, line)
when not defined(windows):
  proc platformSetEditorFontSize*(size: cdouble) = discard size
  proc platformSetEditorFontName*(name: cstring) = discard name
  proc platformEditorLineHeight*(): cdouble = 16.0
when not defined(windows):
  proc platformInvalidateImeCoordinates*() = discard
proc platformEditorByteOffsetAtPoint*(x, y: cdouble): uint32 = 0
proc platformEditorUtf16OffsetAtPoint*(x, y: cdouble): uint32 = 0
when not defined(windows):
  proc platformSetEditorScrollLine*(line: uint32) = discard line
proc platformSetEditorRect*(x, y, width, height: cdouble) = discard (x, y, width, height)
proc platformSetEditorDirty*(dirty: bool) = discard dirty
proc platformSetEditorIndentGuides*(visible: bool, indentWidth: uint32) = discard (visible, indentWidth)
proc platformSetEditorLineNumbers*(visible: bool) = discard visible
proc platformSetEditorSoftWrap*(enabled: bool) = discard enabled
proc platformSetEditorTabs*(titles: cstring, length, activeIndex: uint32) = discard (titles, length, activeIndex)
proc platformSetEditorStatus*(text: cstring) = discard text
when not defined(windows):
  proc platformSetCloseDecision*(allow: bool) = discard allow
proc platformRequestCloseTab*() = discard
proc platformShowSavePanelAndCloseTab*() = discard
proc platformRequestQuit*() = discard
proc platformConfirmQuit*() = discard
proc platformShowSavePanelAndClose*() = discard
when not defined(windows):
  proc platformSetEditorSelection*(startByte, endByte: uint32) = discard (startByte, endByte)
when not defined(windows):
  proc platformSetEditorText*(text: cstring, length: uint32) = discard (text, length)
proc platformSetEditorOutline*(text: cstring, length, symbolCount: uint32) = discard (text, length, symbolCount)
when not defined(windows):
  proc platformSetTerminalVisible*(visible: bool) = discard visible
  proc platformSetTerminalText*(text: cstring, length: uint32) = discard (text, length)
when not defined(windows):
  proc platformSetTerminalRuns*(text: cstring, length: uint32,
                                runs: ptr NativeTerminalRun, count: uint32) = discard (text, length,
                                    runs, count)
proc platformSetThemeColors*(background, foreground, accent, selection, border: cstring) = discard (
  background, foreground, accent, selection, border)
when not defined(windows):
  proc platformSetTerminalFontSize*(size: cdouble) = discard size
  proc platformSetTerminalFontName*(name: cstring) = discard name
proc platformIsDarkAppearance*(): bool = false
proc platformInstallCrashHandler*(path: cstring) = discard path
when not defined(windows):
  proc platformSetTerminalSelection*(startRow, startColumn, endRow, endColumn: uint32) = discard (
    startRow, startColumn, endRow, endColumn)
when not defined(windows):
  proc platformSetTaskOutputVisible*(visible: bool) = discard visible
  proc platformSetTaskOutputText*(text: cstring, length: uint32) = discard (text, length)
proc platformSetEditorCompletions*(text: cstring, length: uint32) = discard (text, length)
proc platformSetEditorHover*(text: cstring, length: uint32) = discard (text, length)
proc platformSetEditorHoverPosition*(x, y: cdouble) = discard (x, y)
proc platformEditorTextUtf8Length*(): uint32 = 0
when not defined(windows):
  proc platformSetEditorComposition*(text: cstring) = discard text
proc platformClearEditorComposition*() = discard
when not defined(windows):
  proc platformSetEditorHighlights*(spans: ptr NativeHighlightSpan, count: uint32) = discard (spans, count)
proc platformSetEditorDiagnostics*(spans: ptr NativeDiagnosticSpan, count: uint32) = discard (spans, count)
proc platformSetEditorAnnotations*(annotations: ptr NativeEditorAnnotation,
    count: uint32) = discard (annotations, count)
proc platformSetEditorGitHunks*(spans: ptr NativeGitHunkSpan, count: uint32) = discard (spans, count)
proc platformSetRecentFiles*(paths: ptr cstring, count: uint32) = discard (paths, count)
when not defined(windows):
  proc platformSetPaintCommands*(commands: ptr NativePaintCommand, count: uint32) = discard (commands, count)
when not defined(windows):
  proc platformSetImageRgba*(imageId, width, height: uint32, rgba: pointer,
      length: uint32) = discard (imageId, width, height, rgba, length)
proc platformSetPaintDirtyRegions*(regions: ptr NativePaintRegion, count: uint32) = discard (
  regions, count)
proc platformShowExternalChange*(path: cstring) = discard path
proc platformShowFindDocument*() = discard
proc platformShowWorkspaceSearch*() = discard
proc platformShowCommandPalette*() = discard
proc platformShowSettingsPanel*(theme, editorFontSize, terminalFontSize,
                                fontFamily, shell: cstring) = discard (theme, editorFontSize,
                                    terminalFontSize, fontFamily, shell)
proc platformSetUiRectangle*(x, y, width, height: cdouble) = discard (x, y, width, height)
when not defined(windows):
  proc platformToggleFullscreen*() = discard
  proc platformMinimizeWindow*() = discard
  proc platformMaximizeWindow*() = discard
  proc platformRestoreWindow*() = discard

when not defined(windows):
  proc clipboardSet*(text: cstring, length: uint32) = discard (text, length)
  proc clipboardGet*(): string = ""
  proc chooseOpenFile*(): cstring = ""
  proc chooseSaveFile*(): cstring = ""
