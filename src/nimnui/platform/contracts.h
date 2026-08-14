#ifndef NIMCULUS_PLATFORM_CONTRACTS_H
#define NIMCULUS_PLATFORM_CONTRACTS_H

#include <stdbool.h>
#include <stdint.h>

typedef struct NimculusPlatformMetrics {
  double scale_factor;
  uint32_t width_points;
  uint32_t height_points;
  uint32_t width_pixels;
  uint32_t height_pixels;
  double last_frame_time_ms;
  uint64_t frame_count;
  double last_input_latency_ms;
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
  uint32_t phase;
} NimculusInputEvent;

enum {
  NIMCULUS_TOUCH_PHASE_STARTED = 0,
  NIMCULUS_TOUCH_PHASE_MOVED = 1,
  NIMCULUS_TOUCH_PHASE_ENDED = 2
};

typedef enum NimculusCursorStyle {
  NIMCULUS_CURSOR_ARROW = 0,
  NIMCULUS_CURSOR_IBEAM = 1,
  NIMCULUS_CURSOR_RESIZE_LEFT_RIGHT = 2
} NimculusCursorStyle;

typedef struct NimculusTerminalRun {
  uint32_t start_byte;
  uint32_t end_byte;
  uint32_t flags;
  uint32_t row;
  uint32_t column;
  uint32_t cell_width;
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

typedef struct NimculusHighlightSpan {
  uint32_t start_byte;
  uint32_t end_byte;
  uint32_t kind;
} NimculusHighlightSpan;
typedef NimculusHighlightSpan NimculusBreadcrumbHighlight;
typedef struct NimculusDiagnosticSpan {
  uint32_t start_byte;
  uint32_t end_byte;
  uint32_t severity;
} NimculusDiagnosticSpan;

// PlatformTextSystem: one-line shape/raster contract. The framework owns
// rows, wrapping, cache keys, and decorations; the platform only resolves a
// font and returns the shaped glyph stream for one line.
typedef struct NimculusPlatformFontRun {
  uint32_t len;
  uint32_t font_id;
} NimculusPlatformFontRun;
typedef struct NimculusPlatformGlyph {
  uint32_t glyph_id;
  double x;
  double y;
  uint32_t index;
  uint32_t font_id;
  bool is_emoji;
} NimculusPlatformGlyph;
typedef struct NimculusPlatformLineMetrics {
  double width;
  double ascent;
  double descent;
  uint32_t len;
  uint32_t glyph_count;
} NimculusPlatformLineMetrics;

typedef struct NimculusEditorFontFeature {
  const char *tag;
  bool enabled;
} NimculusEditorFontFeature;

typedef struct NimculusEditorLayoutGlyph {
  uint32_t glyph_id;
  float x;
  float y;
  uint32_t index;
  uint32_t font_id;
  uint32_t color_kind;
  bool is_emoji;
  float red;
  float green;
  float blue;
  float alpha;
} NimculusEditorLayoutGlyph;
typedef struct NimculusEditorGlyphColor {
  float red;
  float green;
  float blue;
  float alpha;
} NimculusEditorGlyphColor;
typedef struct NimculusEditorLayoutRow {
  uint32_t source_line;
  uint32_t display_row;
  uint32_t source_start_byte;
  uint32_t segment_start_byte;
  uint32_t segment_end_byte;
  uint32_t glyph_start;
  uint32_t glyph_count;
  float font_size;
  float ascent;
  float descent;
} NimculusEditorLayoutRow;
typedef struct NimculusEditorSelection {
  uint32_t start_byte;
  uint32_t end_byte;
  uint32_t cursor_byte;
} NimculusEditorSelection;
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
typedef struct NimculusFoldRange {
  uint32_t start_line;
  uint32_t end_line;
} NimculusFoldRange;

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
  uint32_t selection_row_start;
  uint32_t selection_row_count;
} NimculusPaintCommand;

typedef struct NimculusPaintSelectionRow {
  float x;
  float y;
  float width;
  float height;
} NimculusPaintSelectionRow;

typedef struct NimculusPaintRegion {
  float x;
  float y;
  float width;
  float height;
} NimculusPaintRegion;

typedef struct NimculusAccessibilityNode {
  uint64_t id;
  uint64_t parent_id;
  uint32_t role;
  uint32_t child_start;
  uint32_t child_count;
  float x;
  float y;
  float width;
  float height;
  uint32_t text_start_byte;
  uint32_t text_end_byte;
  uint32_t cursor_byte;
  uint32_t selection_start_byte;
  uint32_t selection_end_byte;
  uint32_t flags;
  const char *identifier;
  const char *title;
  const char *value;
  const char *action_command;
} NimculusAccessibilityNode;

typedef void (*NimculusInputCallback)(const NimculusInputEvent *event);
typedef bool (*NimculusShortcutCallback)(const NimculusInputEvent *event);
typedef void (*NimculusTextCallback)(const char *utf8, bool composing);
typedef void (*NimculusSelectionCallback)(uint32_t start_byte, uint32_t end_byte);
typedef void (*NimculusFileCallback)(const char *path, bool saving);
typedef void (*NimculusCommandCallback)(const char *command);
typedef void (*NimculusIdleCallback)(void);
typedef void (*NimculusFrameCallback)(void);

typedef enum NimculusPlatformPriority {
  NIMCULUS_PLATFORM_PRIORITY_HIGH = 0,
  NIMCULUS_PLATFORM_PRIORITY_MEDIUM = 1,
  NIMCULUS_PLATFORM_PRIORITY_LOW = 2
} NimculusPlatformPriority;

typedef void (*NimculusPlatformRunnable)(void *context);

// Native macOS contract used by the platform test runner to verify that the
// concrete editor view exposes the selectors AppKit and Zed rely on.
bool nimculus_platform_validate_view_selectors(void);

// PlatformDispatcher's C ABI. The platform only chooses where a runnable is
// executed; UI policy and Future ownership stay in the framework layer.
bool nimculus_platform_is_main_thread(void);
void nimculus_platform_dispatch(NimculusPlatformRunnable runnable, void *context,
                                NimculusPlatformPriority priority);
void nimculus_platform_dispatch_on_main_thread(NimculusPlatformRunnable runnable,
                                               void *context,
                                               NimculusPlatformPriority priority);
void nimculus_platform_dispatch_after(uint64_t nanoseconds,
                                      NimculusPlatformRunnable runnable,
                                      void *context);

#endif
