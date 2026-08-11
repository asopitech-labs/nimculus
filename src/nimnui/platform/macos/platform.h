#include "../contracts.h"

void nimculus_platform_layout_line(const uint8_t *utf8, uint32_t length,
                                   double font_size,
                                   const NimculusPlatformFontRun *runs,
                                   uint32_t run_count,
                                   NimculusPlatformLineMetrics *metrics,
                                   NimculusPlatformGlyph *glyphs,
                                   uint32_t glyph_capacity);
void nimculus_platform_set_editor_layout(bool secondary,
                                         const NimculusEditorLayoutRow *rows,
                                         uint32_t row_count,
                                         const NimculusEditorLayoutGlyph *glyphs,
                                         uint32_t glyph_count);
void nimculus_platform_set_editor_layout_scroll(bool secondary, double x,
                                                double y_fraction);
void nimculus_platform_set_editor_inline_blame(bool secondary, bool visible,
                                               uint32_t source_line, const char *text,
                                               int32_t padding, int32_t min_column);
void nimculus_platform_set_accessibility_tree(const NimculusAccessibilityNode *nodes,
                                              uint32_t node_count,
                                              const uint64_t *children,
                                              uint32_t child_count);
void nimculus_platform_get_editor_glyph_color(uint32_t kind,
                                              NimculusEditorGlyphColor *color);

bool nimculus_platform_run(void);
bool nimculus_platform_validate_native(void);
bool nimculus_platform_validate_cursor_styles(void);
bool nimculus_platform_validate_titlebar_height(void);
bool nimculus_platform_validate_appearance_callback(void);
bool nimculus_platform_validate_window_lifecycle(void);
bool nimculus_platform_validate_window_delegate(void);
bool nimculus_platform_validate_fullscreen_transition(void);
bool nimculus_platform_validate_editor_pane_geometry(void);
bool nimculus_platform_validate_editor_gutter_geometry(void);
bool nimculus_platform_validate_editor_text_viewport(void);
bool nimculus_platform_validate_editor_body_ink(void);
bool nimculus_platform_validate_editor_annotation_viewport(void);
bool nimculus_platform_validate_secondary_annotation_isolation(void);
bool nimculus_platform_validate_status_update_deduplication(void);
bool nimculus_platform_validate_editor_footer_items(void);
bool nimculus_platform_validate_editor_git_blame(void);
bool nimculus_platform_validate_editor_git_hunk_gutter(void);
bool nimculus_platform_validate_editor_diagnostics_summary(void);
bool nimculus_platform_validate_editor_activity_indicator(void);
bool nimculus_platform_validate_editor_search_button(void);
bool nimculus_platform_validate_editor_panel_footer(void);
bool nimculus_platform_validate_damage_rebuild(void);
bool nimculus_platform_validate_scroll_clip_pixels(void);
bool nimculus_platform_validate_main_menu(void);
bool nimculus_platform_validate_shortcut_dispatch(void);
bool nimculus_platform_validate_open_panel_sheet(void);
bool nimculus_platform_validate_save_panel_sheet(void);
bool nimculus_platform_validate_unsaved_close_sheet(void);
bool nimculus_platform_validate_application_alert_sheet(void);
bool nimculus_platform_validate_file_open_events(void);
bool nimculus_platform_validate_deferred_file_open_events(void);
bool nimculus_platform_validate_external_change_sheet(void);
bool nimculus_platform_validate_ime_composition(void);
bool nimculus_platform_validate_ime_command_dispatch(void);
bool nimculus_platform_validate_input_event_fields(void);
bool nimculus_platform_validate_input_latency_tracking(void);
bool nimculus_platform_validate_frame_timing_tracking(void);
bool nimculus_platform_validate_clipboard_roundtrip(void);
bool nimculus_platform_validate_glyph_atlas(void);
bool nimculus_platform_validate_glyph_atlas_eviction(void);
bool nimculus_platform_validate_color_emoji_sprite_routing(void);
bool nimculus_platform_validate_color_emoji_sequences(void);
bool nimculus_platform_validate_terminal_overlay_runs(void);
bool nimculus_platform_validate_editor_context_header(void);
bool nimculus_platform_validate_editor_context_syntax_highlights(void);
bool nimculus_platform_validate_tab_bar_hit_test_geometry(void);
bool nimculus_platform_validate_sidebar_dispatch(void);
bool nimculus_platform_validate_sidebar_context_dispatch(void);
bool nimculus_platform_validate_git_sidebar_tabs(void);
bool nimculus_platform_validate_files_sidebar_actions(void);
bool nimculus_platform_validate_sidebar_scroll_container(void);
bool nimculus_platform_validate_sidebar_bounds(void);
bool nimculus_platform_validate_sidebar_presentation(void);
bool nimculus_platform_validate_secondary_highlight_isolation(void);
void nimculus_platform_get_metrics(NimculusPlatformMetrics *metrics);
typedef struct NimculusInputLatencyStats {
  uint64_t sample_count;
  uint64_t recent_sample_count;
  uint64_t input_event_count;
  double average_ms;
  double p95_ms;
  double max_ms;
  double average_events_per_frame;
  uint64_t p95_events_per_frame;
  uint64_t max_events_per_frame;
} NimculusInputLatencyStats;
void nimculus_platform_get_input_latency_stats(NimculusInputLatencyStats *stats);
uint32_t nimculus_platform_input_latency_stats_size(void);
typedef struct NimculusFrameTimingStats {
  uint64_t sample_count;
  uint64_t recent_sample_count;
  uint64_t over_60hz_budget_count;
  uint64_t over_30hz_budget_count;
  double average_ms;
  double p95_ms;
  double max_ms;
} NimculusFrameTimingStats;
void nimculus_platform_get_frame_timing_stats(NimculusFrameTimingStats *stats);
uint32_t nimculus_platform_frame_timing_stats_size(void);
uint64_t nimculus_platform_resident_memory_bytes(void);
uint64_t nimculus_platform_live_allocation_count(void);
uint64_t nimculus_platform_input_count(void);
uint32_t nimculus_platform_metrics_size(void);
uint32_t nimculus_platform_input_event_size(void);
uint32_t nimculus_platform_terminal_run_size(void);
uint32_t nimculus_platform_highlight_span_size(void);
uint32_t nimculus_platform_diagnostic_span_size(void);
uint32_t nimculus_platform_editor_annotation_size(void);
uint32_t nimculus_platform_git_hunk_span_size(void);
uint32_t nimculus_platform_paint_command_size(void);
uint32_t nimculus_platform_paint_region_size(void);
uint32_t nimculus_platform_accessibility_node_size(void);
void nimculus_platform_set_input_callback(NimculusInputCallback callback);
void nimculus_platform_set_shortcut_callback(NimculusShortcutCallback callback);
void nimculus_platform_set_text_callback(NimculusTextCallback callback);
void nimculus_platform_set_selection_callback(NimculusSelectionCallback callback);
void nimculus_platform_set_file_callback(NimculusFileCallback callback);
void nimculus_platform_show_workspace_entry_context(const char *path, bool is_directory);
bool nimculus_platform_move_item_to_trash(const char *path);
// projection: 0 = conflict, 1 = staged, 2 = unstaged. A partially staged
// path can occur in both groups, so native actions need the projected group.
void nimculus_platform_show_git_status_context(uint32_t item_index,
                                               uint32_t projection);
void nimculus_platform_show_git_history_context(uint32_t item_index);
void nimculus_platform_set_command_callback(NimculusCommandCallback callback);
void nimculus_platform_set_idle_callback(NimculusIdleCallback callback);
void nimculus_platform_set_idle_for_blame(bool requested);
void nimculus_platform_set_cursor_style(NimculusCursorStyle style);
void nimculus_platform_set_editor_cursor(double x, double y);
void nimculus_platform_set_editor_cursor_byte(uint32_t byte_offset, uint32_t line);
void nimculus_platform_set_editor_font_size(double size);
void nimculus_platform_set_editor_font_name(const char *name);
double nimculus_platform_editor_line_height(void);
void nimculus_platform_invalidate_ime_coordinates(void);
uint32_t nimculus_platform_editor_byte_offset_at_point(double x, double y);
uint32_t nimculus_platform_secondary_editor_byte_offset_at_point(double x, double y);
uint32_t nimculus_platform_editor_utf16_offset_at_point(double x, double y);
void nimculus_platform_set_editor_scroll_line(uint32_t line);
void nimculus_platform_set_editor_scroll_y_fraction(double pixels);
void nimculus_platform_set_editor_scroll_display_row(uint32_t row);
void nimculus_platform_set_editor_scroll_x(double offset);
double nimculus_platform_editor_scroll_x(void);
double nimculus_platform_editor_widest_visible_line_width(void);
uint32_t nimculus_platform_editor_display_rows_before_line(uint32_t line);
uint32_t nimculus_platform_editor_display_row_count(void);
uint32_t nimculus_platform_editor_source_line_for_display_pixels(double pixels);
double nimculus_platform_editor_display_fraction_for_scroll_pixels(double pixels);
void nimculus_platform_set_editor_rect(double x, double y, double width, double height);
void nimculus_platform_set_terminal_panel_rect(double x, double y, double width, double height);
void nimculus_platform_set_secondary_editor_rect(bool visible, double x, double y,
                                                 double width, double height);
void nimculus_platform_set_secondary_editor_cursor_byte(uint32_t byte_offset,
                                                        uint32_t line);
void nimculus_platform_set_secondary_editor_selection(uint32_t start_byte,
                                                      uint32_t end_byte);
void nimculus_platform_set_secondary_editor_selections(const NimculusEditorSelection *selections,
                                                       uint32_t count);
void nimculus_platform_set_secondary_editor_scroll_line(uint32_t line);
void nimculus_platform_set_secondary_editor_scroll_y_fraction(double pixels);
void nimculus_platform_set_secondary_editor_scroll_x(double offset);
double nimculus_platform_secondary_editor_scroll_x(void);
double nimculus_platform_secondary_editor_widest_visible_line_width(void);
void nimculus_platform_log_editor_scroll_debug(const char *pane, double widest,
                                               double viewport, double scroll_x,
                                               double track_x, double track_width,
                                               double thumb_x, double thumb_width);
void nimculus_platform_set_secondary_editor_soft_wrap(bool enabled);
void nimculus_platform_set_editor_input_pane(uint32_t pane);
uint32_t nimculus_platform_editor_pane_at_point(double x, double y);
void nimculus_platform_set_editor_dirty(bool dirty);
void nimculus_platform_set_editor_indent_guides(bool visible, uint32_t indent_width);
void nimculus_platform_set_editor_line_numbers(bool visible);
void nimculus_platform_set_editor_soft_wrap(bool enabled);
void nimculus_platform_set_editor_folds(const NimculusFoldRange *ranges, uint32_t count);
void nimculus_platform_set_secondary_editor_folds(const NimculusFoldRange *ranges, uint32_t count);
void nimculus_platform_set_editor_tabs(const char *utf8, uint32_t length, uint32_t active_index);
void nimculus_platform_set_secondary_editor_tabs(const char *utf8, uint32_t length,
                                                 uint32_t active_index);
void nimculus_platform_set_editor_context(const char *utf8);
void nimculus_platform_set_editor_context_highlights(const char *utf8,
                                                      const NimculusBreadcrumbHighlight *spans,
                                                      uint32_t count);
void nimculus_platform_set_editor_git_branch(const char *utf8);
void nimculus_platform_set_editor_status(const char *utf8);
void nimculus_platform_set_activity_progress(const char *utf8);
void nimculus_platform_set_editor_footer(const char *utf8);
void nimculus_platform_set_diagnostics_button(bool visible);
void nimculus_platform_set_search_button(bool visible);
void nimculus_platform_set_footer_panel_dock_sides(uint32_t panel_dock_side_mask);
void nimculus_platform_set_welcome_visible(bool visible);
void nimculus_platform_set_close_decision(bool allow);
void nimculus_platform_request_close_tab(void);
void nimculus_platform_request_close_tab_with_unsaved(bool unsaved);
void nimculus_platform_show_save_panel(void);
void nimculus_platform_show_save_as_panel(const char *suggested_name);
void nimculus_platform_show_save_panel_and_close_tab(void);
void nimculus_platform_request_quit(void);
void nimculus_platform_confirm_quit(void);
void nimculus_platform_show_save_panel_and_close(void);
void nimculus_platform_set_editor_selection(uint32_t start_byte, uint32_t end_byte);
void nimculus_platform_set_editor_selections(const NimculusEditorSelection *selections,
                                             uint32_t count);
void nimculus_platform_set_editor_text(const char *utf8, uint32_t length);
void nimculus_platform_set_secondary_editor_text(const char *utf8, uint32_t length);
void nimculus_platform_set_editor_outline(const char *utf8, uint32_t length,
                                          uint32_t symbol_count);
void nimculus_platform_set_editor_sidebar(const char *utf8, uint32_t length,
                                          uint32_t item_count, uint32_t mode);
// Maps each rendered sidebar line to a logical item index. A negative value
// makes the line presentational only (for example, a Git section header).
void nimculus_platform_set_editor_sidebar_line_items(const int32_t *items,
                                                     uint32_t count);
void nimculus_platform_set_editor_sidebar_selection(uint32_t item_index);
void nimculus_platform_set_editor_sidebar_visible(bool visible);
void nimculus_platform_focus_editor_sidebar(void);
void nimculus_platform_focus_editor(void);
void nimculus_platform_set_editor_sidebar_on_right(bool on_right);
void nimculus_platform_set_workspace_open(bool open);
void nimculus_platform_open_workspace_folder(void);
void nimculus_platform_prompt_extension_permissions(const char *title,
                                                    const char *details);
void nimculus_platform_rename_workspace_entry(const char *path, bool is_directory);
void nimculus_platform_set_terminal_visible(bool visible);
void nimculus_platform_set_terminal_sessions(const char *utf8, uint32_t length,
                                             uint32_t active_index);
void nimculus_platform_set_terminal_text(const char *utf8, uint32_t length);
void nimculus_platform_set_terminal_runs(const char *utf8, uint32_t length,
                                         const NimculusTerminalRun *runs, uint32_t count);
void nimculus_platform_set_theme_colors(const char *background, const char *foreground,
                                        const char *accent, const char *selection,
                                        const char *border);
void nimculus_platform_set_theme_palette_json(const char *json);
void nimculus_platform_set_terminal_font_size(double size);
void nimculus_platform_set_terminal_font_name(const char *name);
double nimculus_platform_terminal_cell_width(void);
double nimculus_platform_terminal_line_height(void);
double nimculus_platform_terminal_inset_x(void);
double nimculus_platform_terminal_inset_y(void);
bool nimculus_platform_is_dark_appearance(void);
void nimculus_platform_install_crash_handler(const char *path);
void nimculus_platform_set_terminal_selection(uint32_t start_row, uint32_t start_column,
                                              uint32_t end_row, uint32_t end_column);
void nimculus_platform_set_task_output_visible(bool visible);
void nimculus_platform_set_task_output_cancellable(bool cancellable);
void nimculus_platform_set_task_output_title(const char *utf8, uint32_t length);
void nimculus_platform_set_task_output_text(const char *utf8, uint32_t length);
void nimculus_platform_set_editor_completions(const char *utf8, uint32_t length);
void nimculus_platform_set_editor_hover(const char *utf8, uint32_t length);
void nimculus_platform_set_editor_hover_position(double x, double y);
void nimculus_platform_set_editor_hover_pane(uint32_t pane);
uint32_t nimculus_platform_editor_text_utf8_length(void);
void nimculus_platform_set_editor_composition(const char *utf8);
void nimculus_platform_clear_editor_composition(void);
void nimculus_platform_set_editor_highlights(const NimculusHighlightSpan *spans, uint32_t count);
void nimculus_platform_set_secondary_editor_highlights(const NimculusHighlightSpan *spans,
                                                       uint32_t count);
void nimculus_platform_set_editor_diagnostics(const NimculusDiagnosticSpan *spans, uint32_t count);
void nimculus_platform_set_secondary_editor_diagnostics(const NimculusDiagnosticSpan *spans,
                                                        uint32_t count);
void nimculus_platform_set_editor_annotations(const NimculusEditorAnnotation *annotations, uint32_t count);
void nimculus_platform_set_secondary_editor_annotations(const NimculusEditorAnnotation *annotations,
                                                        uint32_t count);
void nimculus_platform_set_editor_git_hunks(const NimculusGitHunkSpan *spans, uint32_t count);
void nimculus_platform_set_secondary_editor_git_hunks(const NimculusGitHunkSpan *spans,
                                                       uint32_t count);
void nimculus_platform_set_recent_files(const char *const *paths, uint32_t count);
void nimculus_platform_set_paint_commands(const NimculusPaintCommand *commands, uint32_t count);
void nimculus_platform_set_paint_selection_rows(const NimculusPaintSelectionRow *rows,
                                                uint32_t count);
void nimculus_platform_set_image_rgba(uint32_t image_id, uint32_t width, uint32_t height,
                                      const uint8_t *rgba, uint32_t length);
void nimculus_platform_set_paint_dirty_regions(const NimculusPaintRegion *regions, uint32_t count);
void nimculus_platform_show_external_change(const char *path);
void nimculus_platform_show_find_document(void);
void nimculus_platform_show_outline_picker(void);
void nimculus_platform_show_workspace_search(void);
void nimculus_platform_show_settings_panel(const char *theme, const char *editor_font_size,
                                           const char *terminal_font_size,
                                           const char *editor_font_family,
                                           const char *terminal_font_family, const char *shell);
void nimculus_platform_set_ui_rectangle(double x, double y, double width, double height);
void nimculus_clipboard_set(const char *utf8, uint32_t length);
uint32_t nimculus_clipboard_utf8_length(void);
const uint8_t *nimculus_clipboard_utf8_bytes(void);
const char *nimculus_choose_open_file(void);
const char *nimculus_choose_save_file(void);
