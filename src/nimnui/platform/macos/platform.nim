when defined(macosx):
  {.compile: "macos_platform.m".}
  {.passL: "-framework Cocoa -framework Metal -framework QuartzCore".}

import nimnui/platform/contracts
export contracts

proc platformRun*(): bool {.importc: "nimculus_platform_run", cdecl.}
proc platformValidateNative*(): bool {.importc: "nimculus_platform_validate_native", cdecl.}
proc platformValidateWindowLifecycle*(): bool {.importc: "nimculus_platform_validate_window_lifecycle", cdecl.}
proc platformValidateEditorPaneGeometry*(): bool {.importc: "nimculus_platform_validate_editor_pane_geometry", cdecl.}
proc platformValidateDamageRebuild*(): bool {.importc: "nimculus_platform_validate_damage_rebuild", cdecl.}
proc platformValidateSceneTextureReplacement*(): bool {.importc: "nimculus_platform_validate_scene_texture_replacement", cdecl.}
proc platformValidateMainMenu*(): bool {.importc: "nimculus_platform_validate_main_menu", cdecl.}
proc platformValidateShortcutDispatch*(): bool {.importc: "nimculus_platform_validate_shortcut_dispatch", cdecl.}
proc platformValidateOpenPanelSheet*(): bool {.importc: "nimculus_platform_validate_open_panel_sheet", cdecl.}
proc platformValidateSavePanelSheet*(): bool {.importc: "nimculus_platform_validate_save_panel_sheet", cdecl.}
proc platformValidateUnsavedCloseSheet*(): bool {.importc: "nimculus_platform_validate_unsaved_close_sheet", cdecl.}
proc platformValidateApplicationAlertSheet*(): bool {.importc: "nimculus_platform_validate_application_alert_sheet", cdecl.}
proc platformValidateVisibleTextAssets*(): bool {.importc: "nimculus_platform_validate_visible_text_assets", cdecl.}
proc platformValidateFileOpenEvents*(): bool {.importc: "nimculus_platform_validate_file_open_events", cdecl.}
proc platformValidateExternalChangeSheet*(): bool {.importc: "nimculus_platform_validate_external_change_sheet", cdecl.}
proc platformValidateImeComposition*(): bool {.importc: "nimculus_platform_validate_ime_composition", cdecl.}
proc platformValidateImeCandidateRect*(): bool {.importc: "nimculus_platform_validate_ime_candidate_rect", cdecl.}
proc platformValidateInputEventFields*(): bool {.importc: "nimculus_platform_validate_input_event_fields", cdecl.}
proc platformValidateClipboardRoundtrip*(): bool {.importc: "nimculus_platform_validate_clipboard_roundtrip", cdecl.}
proc platformValidateGlyphAtlas*(): bool {.importc: "nimculus_platform_validate_glyph_atlas", cdecl.}
proc platformValidateGlyphAtlasEviction*(): bool {.importc: "nimculus_platform_validate_glyph_atlas_eviction", cdecl.}
proc platformValidateRetinaTextScaling*(): bool {.importc: "nimculus_platform_validate_retina_text_scaling", cdecl.}
proc platformValidateResourceTeardown*(): bool {.importc: "nimculus_platform_validate_resource_teardown", cdecl.}
proc platformValidateColorEmojiFallback*(): bool {.importc: "nimculus_platform_validate_color_emoji_fallback", cdecl.}
proc platformValidateColorEmojiSequences*(): bool {.importc: "nimculus_platform_validate_color_emoji_sequences", cdecl.}
proc platformGetMetrics*(metrics: ptr PlatformMetrics) {.importc: "nimculus_platform_get_metrics", cdecl.}
proc platformResidentMemoryBytes*(): uint64 {.importc: "nimculus_platform_resident_memory_bytes", cdecl.}
proc platformLiveAllocationCount*(): uint64 {.importc: "nimculus_platform_live_allocation_count", cdecl.}
proc platformInputCount*(): uint64 {.importc: "nimculus_platform_input_count", cdecl.}
proc platformMetricsSize*(): uint32 {.importc: "nimculus_platform_metrics_size", cdecl.}
proc platformInputEventSize*(): uint32 {.importc: "nimculus_platform_input_event_size", cdecl.}
proc platformTerminalRunSize*(): uint32 {.importc: "nimculus_platform_terminal_run_size", cdecl.}
proc platformHighlightSpanSize*(): uint32 {.importc: "nimculus_platform_highlight_span_size", cdecl.}
proc platformDiagnosticSpanSize*(): uint32 {.importc: "nimculus_platform_diagnostic_span_size", cdecl.}
proc platformEditorAnnotationSize*(): uint32 {.importc: "nimculus_platform_editor_annotation_size", cdecl.}
proc platformGitHunkSpanSize*(): uint32 {.importc: "nimculus_platform_git_hunk_span_size", cdecl.}
proc platformPaintCommandSize*(): uint32 {.importc: "nimculus_platform_paint_command_size", cdecl.}
proc platformPaintRegionSize*(): uint32 {.importc: "nimculus_platform_paint_region_size", cdecl.}

proc platformSetInputCallback*(callback: InputCallback) {.importc: "nimculus_platform_set_input_callback", cdecl.}
proc platformSetShortcutCallback*(callback: ShortcutCallback) {.importc: "nimculus_platform_set_shortcut_callback", cdecl.}
proc platformSetTextCallback*(callback: TextCallback) {.importc: "nimculus_platform_set_text_callback", cdecl.}
proc platformSetSelectionCallback*(callback: SelectionCallback) {.importc: "nimculus_platform_set_selection_callback", cdecl.}
proc platformSetFileCallback*(callback: FileCallback) {.importc: "nimculus_platform_set_file_callback", cdecl.}
proc platformSetCommandCallback*(callback: CommandCallback) {.importc: "nimculus_platform_set_command_callback", cdecl.}
proc platformSetIdleCallback*(callback: IdleCallback) {.importc: "nimculus_platform_set_idle_callback", cdecl.}
proc platformSetEditorCursor*(x, y: cdouble) {.importc: "nimculus_platform_set_editor_cursor", cdecl.}
proc platformSetEditorCursorByte*(byteOffset, line: uint32) {.importc: "nimculus_platform_set_editor_cursor_byte", cdecl.}
proc platformSetEditorFontSize*(size: cdouble) {.importc: "nimculus_platform_set_editor_font_size", cdecl.}
proc platformSetEditorFontName*(name: cstring) {.importc: "nimculus_platform_set_editor_font_name", cdecl.}
proc platformEditorLineHeight*(): cdouble {.importc: "nimculus_platform_editor_line_height", cdecl.}
proc platformInvalidateImeCoordinates*() {.importc: "nimculus_platform_invalidate_ime_coordinates", cdecl.}
proc platformEditorByteOffsetAtPoint*(x, y: cdouble): uint32 {.importc: "nimculus_platform_editor_byte_offset_at_point", cdecl.}
proc platformSecondaryEditorByteOffsetAtPoint*(x, y: cdouble): uint32 {.importc: "nimculus_platform_secondary_editor_byte_offset_at_point", cdecl.}
proc platformEditorUtf16OffsetAtPoint*(x, y: cdouble): uint32 {.importc: "nimculus_platform_editor_utf16_offset_at_point", cdecl.}
proc platformSetEditorScrollLine*(line: uint32) {.importc: "nimculus_platform_set_editor_scroll_line", cdecl.}
proc platformSetEditorRect*(x, y, width, height: cdouble) {.importc: "nimculus_platform_set_editor_rect", cdecl.}
proc platformSetSecondaryEditorRect*(visible: bool, x, y, width, height: cdouble) {.importc: "nimculus_platform_set_secondary_editor_rect", cdecl.}
proc platformSetSecondaryEditorCursorByte*(byteOffset, line: uint32) {.importc: "nimculus_platform_set_secondary_editor_cursor_byte", cdecl.}
proc platformSetSecondaryEditorSelection*(startByte, endByte: uint32) {.importc: "nimculus_platform_set_secondary_editor_selection", cdecl.}
proc platformSetSecondaryEditorScrollLine*(line: uint32) {.importc: "nimculus_platform_set_secondary_editor_scroll_line", cdecl.}
proc platformSetEditorInputPane*(pane: uint32) {.importc: "nimculus_platform_set_editor_input_pane", cdecl.}
proc platformEditorPaneAtPoint*(x, y: cdouble): uint32 {.importc: "nimculus_platform_editor_pane_at_point", cdecl.}
proc platformSetEditorDirty*(dirty: bool) {.importc: "nimculus_platform_set_editor_dirty", cdecl.}
proc platformSetEditorIndentGuides*(visible: bool, indentWidth: uint32) {.importc: "nimculus_platform_set_editor_indent_guides", cdecl.}
proc platformSetEditorLineNumbers*(visible: bool) {.importc: "nimculus_platform_set_editor_line_numbers", cdecl.}
proc platformSetEditorSoftWrap*(enabled: bool) {.importc: "nimculus_platform_set_editor_soft_wrap", cdecl.}
proc platformSetEditorTabs*(titles: cstring, length, activeIndex: uint32) {.importc: "nimculus_platform_set_editor_tabs", cdecl.}
proc platformSetEditorStatus*(text: cstring) {.importc: "nimculus_platform_set_editor_status", cdecl.}
proc platformSetCloseDecision*(allow: bool) {.importc: "nimculus_platform_set_close_decision", cdecl.}
proc platformRequestCloseTab*() {.importc: "nimculus_platform_request_close_tab", cdecl.}
proc platformShowSavePanel*() {.importc: "nimculus_platform_show_save_panel", cdecl.}
proc platformShowSaveAsPanel*(suggestedName: cstring) {.importc: "nimculus_platform_show_save_as_panel", cdecl.}
proc platformShowSavePanelAndCloseTab*() {.importc: "nimculus_platform_show_save_panel_and_close_tab", cdecl.}
proc platformRequestQuit*() {.importc: "nimculus_platform_request_quit", cdecl.}
proc platformConfirmQuit*() {.importc: "nimculus_platform_confirm_quit", cdecl.}
proc platformShowSavePanelAndClose*() {.importc: "nimculus_platform_show_save_panel_and_close", cdecl.}
proc platformSetEditorSelection*(startByte, endByte: uint32) {.importc: "nimculus_platform_set_editor_selection", cdecl.}
proc platformSetEditorText*(text: cstring, length: uint32) {.importc: "nimculus_platform_set_editor_text", cdecl.}
proc platformSetEditorOutline*(text: cstring, length, symbolCount: uint32) {.importc: "nimculus_platform_set_editor_outline", cdecl.}
proc platformSetTerminalVisible*(visible: bool) {.importc: "nimculus_platform_set_terminal_visible", cdecl.}
proc platformSetTerminalText*(text: cstring, length: uint32) {.importc: "nimculus_platform_set_terminal_text", cdecl.}
proc platformSetTerminalRuns*(text: cstring, length: uint32, runs: ptr NativeTerminalRun,
                             count: uint32) {.importc: "nimculus_platform_set_terminal_runs", cdecl.}
proc platformSetThemeColors*(background, foreground, accent, selection, border: cstring) {.importc: "nimculus_platform_set_theme_colors", cdecl.}
proc platformSetTerminalFontSize*(size: cdouble) {.importc: "nimculus_platform_set_terminal_font_size", cdecl.}
proc platformSetTerminalFontName*(name: cstring) {.importc: "nimculus_platform_set_terminal_font_name", cdecl.}
proc platformIsDarkAppearance*(): bool {.importc: "nimculus_platform_is_dark_appearance", cdecl.}
proc platformInstallCrashHandler*(path: cstring) {.importc: "nimculus_platform_install_crash_handler", cdecl.}
proc platformSetTerminalSelection*(startRow, startColumn, endRow, endColumn: uint32) {.importc: "nimculus_platform_set_terminal_selection", cdecl.}
proc platformSetTaskOutputVisible*(visible: bool) {.importc: "nimculus_platform_set_task_output_visible", cdecl.}
proc platformSetTaskOutputText*(text: cstring, length: uint32) {.importc: "nimculus_platform_set_task_output_text", cdecl.}
proc platformSetEditorCompletions*(text: cstring, length: uint32) {.importc: "nimculus_platform_set_editor_completions", cdecl.}
proc platformSetEditorHover*(text: cstring, length: uint32) {.importc: "nimculus_platform_set_editor_hover", cdecl.}
proc platformSetEditorHoverPosition*(x, y: cdouble) {.importc: "nimculus_platform_set_editor_hover_position", cdecl.}
proc platformEditorTextUtf8Length*(): uint32 {.importc: "nimculus_platform_editor_text_utf8_length", cdecl.}
proc platformSetEditorComposition*(text: cstring) {.importc: "nimculus_platform_set_editor_composition", cdecl.}
proc platformClearEditorComposition*() {.importc: "nimculus_platform_clear_editor_composition", cdecl.}
proc platformSetEditorHighlights*(spans: ptr NativeHighlightSpan, count: uint32) {.importc: "nimculus_platform_set_editor_highlights", cdecl.}
proc platformSetEditorDiagnostics*(spans: ptr NativeDiagnosticSpan, count: uint32) {.importc: "nimculus_platform_set_editor_diagnostics", cdecl.}
proc platformSetEditorAnnotations*(annotations: ptr NativeEditorAnnotation, count: uint32) {.importc: "nimculus_platform_set_editor_annotations", cdecl.}
proc platformSetEditorGitHunks*(spans: ptr NativeGitHunkSpan, count: uint32) {.importc: "nimculus_platform_set_editor_git_hunks", cdecl.}
proc platformSetRecentFiles*(paths: ptr cstring, count: uint32) {.importc: "nimculus_platform_set_recent_files", cdecl.}
proc platformSetPaintCommands*(commands: ptr NativePaintCommand, count: uint32) {.importc: "nimculus_platform_set_paint_commands", cdecl.}
proc platformSetImageRgba*(imageId, width, height: uint32, rgba: pointer, length: uint32) {.importc: "nimculus_platform_set_image_rgba", cdecl.}
proc platformSetPaintDirtyRegions*(regions: ptr NativePaintRegion, count: uint32) {.importc: "nimculus_platform_set_paint_dirty_regions", cdecl.}
proc platformShowExternalChange*(path: cstring) {.importc: "nimculus_platform_show_external_change", cdecl.}
proc platformShowFindDocument*() {.importc: "nimculus_platform_show_find_document", cdecl.}
proc platformShowWorkspaceSearch*() {.importc: "nimculus_platform_show_workspace_search", cdecl.}
proc platformShowCommandPalette*() {.importc: "nimculus_platform_show_command_palette", cdecl.}
proc platformShowSettingsPanel*(theme, editorFontSize, terminalFontSize,
                                fontFamily, shell: cstring) {.importc: "nimculus_platform_show_settings_panel", cdecl.}
proc platformSetUiRectangle*(x, y, width, height: cdouble) {.importc: "nimculus_platform_set_ui_rectangle", cdecl.}
proc clipboardSet*(text: cstring, length: uint32) {.importc: "nimculus_clipboard_set", cdecl.}
proc clipboardUtf8Length*(): uint32 {.importc: "nimculus_clipboard_utf8_length", cdecl.}
proc clipboardUtf8Bytes*(): pointer {.importc: "nimculus_clipboard_utf8_bytes", cdecl.}

proc clipboardGet*(): string =
  let length = int(clipboardUtf8Length())
  if length <= 0: return ""
  let bytes = clipboardUtf8Bytes()
  if bytes == nil: return ""
  result = newString(length)
  copyMem(addr result[0], bytes, length)
proc chooseOpenFile*(): cstring {.importc: "nimculus_choose_open_file", cdecl.}
proc chooseSaveFile*(): cstring {.importc: "nimculus_choose_save_file", cdecl.}
