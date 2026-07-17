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

bool nimculus_platform_run(void);
void nimculus_platform_get_metrics(NimculusPlatformMetrics *metrics);
uint64_t nimculus_platform_input_count(void);
