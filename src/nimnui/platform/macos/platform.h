#import <stdbool.h>
#import <stdint.h>

typedef struct NimculusPlatformMetrics {
  double scale_factor;
  uint32_t width_points;
  uint32_t height_points;
  uint32_t width_pixels;
  uint32_t height_pixels;
  double last_frame_time_ms;
  uint64_t frame_count;
} NimculusPlatformMetrics;

typedef struct NimculusInputEvent {
  uint32_t type;
  uint32_t key_code;
  uint32_t modifiers;
  uint32_t button;
  double x;
  double y;
  double delta_x;
  double delta_y;
  bool precise_scrolling;
} NimculusInputEvent;

typedef struct NimculusTerminalRun {
  uint32_t start_byte;
  uint32_t end_byte;
  uint32_t flags;
  uint32_t foreground_kind;
  uint32_t foreground_index;
  uint32_t foreground_red;
  uint32_t foreground_green;
  uint32_t foreground_blue;
  uint32_t background_kind;
  uint32_t background_index;
  uint32_t background_red;
  uint32_t background_green;
  uint32_t background_blue;
  const char *hyperlink_uri;
} NimculusTerminalRun;

typedef void (*NimculusInputCallback)(const NimculusInputEvent *event);
typedef bool (*NimculusShortcutCallback)(const NimculusInputEvent *event);
typedef void (*NimculusTextCallback)(const char *utf8, bool composing);
typedef void (*NimculusSelectionCallback)(uint32_t start_byte, uint32_t end_byte);
typedef void (*NimculusFileCallback)(const char *path, bool saving);
typedef void (*NimculusCommandCallback)(const char *command);
typedef void (*NimculusIdleCallback)(void);
typedef struct NimculusHighlightSpan {
  uint32_t start_byte;
  uint32_t end_byte;
  uint32_t kind;
} NimculusHighlightSpan;
typedef struct NimculusDiagnosticSpan {
  uint32_t start_byte;
  uint32_t end_byte;
  uint32_t severity;
} NimculusDiagnosticSpan;
typedef struct NimculusEditorAnnotation {
  uint32_t line;
  uint32_t character;
  uint32_t kind;
  const char *text;
} NimculusEditorAnnotation;
typedef struct NimculusGitHunkSpan {
  uint32_t start_line;
  uint32_t line_count;
  uint32_t kind;
} NimculusGitHunkSpan;

typedef struct NimculusPaintCommand {
  uint32_t kind;
  float x;
  float y;
  float width;
  float height;
  float clip_x;
  float clip_y;
  float clip_width;
  float clip_height;
  float radius;
  float source_x;
  float source_y;
  float source_width;
  float source_height;
  float transform_a;
  float transform_b;
  float transform_c;
  float transform_d;
  float transform_tx;
  float transform_ty;
  uint32_t image_id;
} NimculusPaintCommand;

typedef struct NimculusPaintRegion {
  float x;
  float y;
  float width;
  float height;
} NimculusPaintRegion;

bool nimculus_platform_run(void);
bool nimculus_platform_validate_native(void);
bool nimculus_platform_validate_glyph_atlas(void);
void nimculus_platform_get_metrics(NimculusPlatformMetrics *metrics);
uint64_t nimculus_platform_input_count(void);
void nimculus_platform_set_input_callback(NimculusInputCallback callback);
void nimculus_platform_set_shortcut_callback(NimculusShortcutCallback callback);
void nimculus_platform_set_text_callback(NimculusTextCallback callback);
void nimculus_platform_set_selection_callback(NimculusSelectionCallback callback);
void nimculus_platform_set_file_callback(NimculusFileCallback callback);
void nimculus_platform_set_command_callback(NimculusCommandCallback callback);
void nimculus_platform_set_idle_callback(NimculusIdleCallback callback);
void nimculus_platform_set_editor_cursor(double x, double y);
void nimculus_platform_set_editor_cursor_byte(uint32_t byte_offset, uint32_t line);
void nimculus_platform_set_editor_font_size(double size);
void nimculus_platform_set_editor_font_name(const char *name);
double nimculus_platform_editor_line_height(void);
void nimculus_platform_invalidate_ime_coordinates(void);
uint32_t nimculus_platform_editor_byte_offset_at_point(double x, double y);
uint32_t nimculus_platform_editor_utf16_offset_at_point(double x, double y);
void nimculus_platform_set_editor_scroll_line(uint32_t line);
void nimculus_platform_set_editor_rect(double x, double y, double width, double height);
void nimculus_platform_set_editor_dirty(bool dirty);
void nimculus_platform_set_close_decision(bool allow);
void nimculus_platform_request_close_tab(void);
void nimculus_platform_show_save_panel_and_close_tab(void);
void nimculus_platform_request_quit(void);
void nimculus_platform_confirm_quit(void);
void nimculus_platform_show_save_panel_and_close(void);
void nimculus_platform_set_editor_selection(uint32_t start_byte, uint32_t end_byte);
void nimculus_platform_set_editor_text(const char *utf8, uint32_t length);
void nimculus_platform_set_terminal_visible(bool visible);
void nimculus_platform_set_terminal_text(const char *utf8, uint32_t length);
void nimculus_platform_set_terminal_runs(const char *utf8, uint32_t length,
                                         const NimculusTerminalRun *runs, uint32_t count);
void nimculus_platform_set_theme_colors(const char *background, const char *foreground,
                                        const char *accent);
void nimculus_platform_set_terminal_font_size(double size);
void nimculus_platform_set_terminal_font_name(const char *name);
bool nimculus_platform_is_dark_appearance(void);
void nimculus_platform_install_crash_handler(const char *path);
void nimculus_platform_set_terminal_selection(uint32_t start_row, uint32_t start_column,
                                              uint32_t end_row, uint32_t end_column);
void nimculus_platform_set_task_output_visible(bool visible);
void nimculus_platform_set_task_output_text(const char *utf8, uint32_t length);
void nimculus_platform_set_editor_completions(const char *utf8, uint32_t length);
void nimculus_platform_set_editor_hover(const char *utf8, uint32_t length);
void nimculus_platform_set_editor_hover_position(double x, double y);
uint32_t nimculus_platform_editor_text_utf8_length(void);
void nimculus_platform_set_editor_composition(const char *utf8);
void nimculus_platform_clear_editor_composition(void);
void nimculus_platform_set_editor_highlights(const NimculusHighlightSpan *spans, uint32_t count);
void nimculus_platform_set_editor_diagnostics(const NimculusDiagnosticSpan *spans, uint32_t count);
void nimculus_platform_set_editor_annotations(const NimculusEditorAnnotation *annotations, uint32_t count);
void nimculus_platform_set_editor_git_hunks(const NimculusGitHunkSpan *spans, uint32_t count);
void nimculus_platform_set_recent_files(const char *const *paths, uint32_t count);
void nimculus_platform_set_paint_commands(const NimculusPaintCommand *commands, uint32_t count);
void nimculus_platform_set_image_rgba(uint32_t image_id, uint32_t width, uint32_t height,
                                      const uint8_t *rgba, uint32_t length);
void nimculus_platform_set_paint_dirty_regions(const NimculusPaintRegion *regions, uint32_t count);
void nimculus_platform_show_external_change(const char *path);
void nimculus_platform_show_find_document(void);
void nimculus_platform_show_workspace_search(void);
void nimculus_platform_set_ui_rectangle(double x, double y, double width, double height);
void nimculus_clipboard_set(const char *utf8, uint32_t length);
uint32_t nimculus_clipboard_utf8_length(void);
const uint8_t *nimculus_clipboard_utf8_bytes(void);
const char *nimculus_choose_open_file(void);
const char *nimculus_choose_save_file(void);
