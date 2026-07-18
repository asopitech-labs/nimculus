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
  double x;
  double y;
  double delta_x;
  double delta_y;
} NimculusInputEvent;

typedef void (*NimculusInputCallback)(const NimculusInputEvent *event);
typedef void (*NimculusTextCallback)(const char *utf8, bool composing);
typedef void (*NimculusFileCallback)(const char *path, bool saving);
typedef void (*NimculusCommandCallback)(const char *command);
typedef struct NimculusHighlightSpan {
  uint32_t start_byte;
  uint32_t end_byte;
  uint32_t kind;
} NimculusHighlightSpan;

bool nimculus_platform_run(void);
void nimculus_platform_get_metrics(NimculusPlatformMetrics *metrics);
uint64_t nimculus_platform_input_count(void);
void nimculus_platform_set_input_callback(NimculusInputCallback callback);
void nimculus_platform_set_text_callback(NimculusTextCallback callback);
void nimculus_platform_set_file_callback(NimculusFileCallback callback);
void nimculus_platform_set_command_callback(NimculusCommandCallback callback);
void nimculus_platform_set_editor_cursor(double x, double y);
void nimculus_platform_set_editor_text(const char *utf8);
void nimculus_platform_set_editor_highlights(const NimculusHighlightSpan *spans, uint32_t count);
void nimculus_platform_set_ui_rectangle(double x, double y, double width, double height);
void nimculus_clipboard_set(const char *utf8);
const char *nimculus_clipboard_get(void);
const char *nimculus_choose_open_file(void);
const char *nimculus_choose_save_file(void);
