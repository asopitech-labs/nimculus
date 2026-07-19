#include <stdbool.h>
#include <stdint.h>

typedef struct NimculusTextMetrics {
  double width;
  double ascent;
  double descent;
  uint32_t glyph_count;
} NimculusTextMetrics;

typedef void (*NimculusFontCallback)(const char *name);

bool nimculus_font_available(const char *name, double size);
void nimculus_enumerate_fonts(NimculusFontCallback callback);
void nimculus_measure_text(const char *utf8, const char *font_name, double size,
                           NimculusTextMetrics *metrics);
void nimculus_measure_text_utf8(const uint8_t *utf8, uint32_t length,
                                const char *font_name, double size,
                                NimculusTextMetrics *metrics);
