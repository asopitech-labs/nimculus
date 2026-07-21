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

typedef void (*NimculusInputCallback)(const NimculusInputEvent *event);
typedef bool (*NimculusShortcutCallback)(const NimculusInputEvent *event);
typedef void (*NimculusTextCallback)(const char *utf8, bool composing);
typedef void (*NimculusSelectionCallback)(uint32_t start_byte, uint32_t end_byte);
typedef void (*NimculusFileCallback)(const char *path, bool saving);
typedef void (*NimculusCommandCallback)(const char *command);
typedef void (*NimculusIdleCallback)(void);

#endif
