#import <CoreText/CoreText.h>
#import <Foundation/Foundation.h>
#include <stdint.h>
#include <string.h>
#include "text_platform.h"

static CTFontRef makeFont(const char *name, double size) {
  NSString *fontName = name ? [NSString stringWithUTF8String:name] : nil;
  CTFontRef font = fontName ? CTFontCreateWithName((CFStringRef)fontName, size, NULL)
                            : CTFontCreateUIFontForLanguage(kCTFontSystemFontType, size, NULL);
  if (!font) font = CTFontCreateUIFontForLanguage(kCTFontSystemFontType, size, NULL);
  return font;
}

bool nimculus_font_available(const char *name, double size) {
  if (!name || size <= 0.0) return false;
  NSString *requested = [NSString stringWithUTF8String:name];
  if (!requested || requested.length == 0) return false;

  // Do not use makeFont here: it intentionally falls back to the system
  // font for shaping, which would make every unknown name appear available.
  // Availability is an exact database query; fallback remains a separate
  // rendering concern, matching Zed's font resolution contract.
  CFArrayRef postScriptNames = CTFontManagerCopyAvailablePostScriptNames();
  CFArrayRef familyNames = CTFontManagerCopyAvailableFontFamilyNames();
  bool available = false;
  for (CFIndex i = 0; i < CFArrayGetCount(postScriptNames) && !available; i++) {
    NSString *candidate = (NSString *)CFArrayGetValueAtIndex(postScriptNames, i);
    available = [candidate isEqualToString:requested];
  }
  for (CFIndex i = 0; i < CFArrayGetCount(familyNames) && !available; i++) {
    NSString *candidate = (NSString *)CFArrayGetValueAtIndex(familyNames, i);
    available = [candidate isEqualToString:requested];
  }
  CFRelease(postScriptNames);
  CFRelease(familyNames);
  return available;
}

void nimculus_enumerate_fonts(NimculusFontCallback callback) {
  if (!callback) return;
  CFArrayRef names = CTFontManagerCopyAvailablePostScriptNames();
  for (CFIndex i = 0; i < CFArrayGetCount(names); i++) {
    CFStringRef name = (CFStringRef)CFArrayGetValueAtIndex(names, i);
    char buffer[512];
    if (CFStringGetCString(name, buffer, sizeof(buffer), kCFStringEncodingUTF8)) callback(buffer);
  }
  CFRelease(names);
}

static void measureTextString(NSString *string, const char *font_name, double size,
                              NimculusTextMetrics *metrics) {
  if (!metrics) return;
  memset(metrics, 0, sizeof(*metrics));
  CTFontRef font = makeFont(font_name, size);
  if (!font) return;
  if (!string) { CFRelease(font); return; }
  NSDictionary *attributes = @{(id)kCTFontAttributeName: (id)font};
  NSAttributedString *attributed = [[NSAttributedString alloc] initWithString:string
    attributes:attributes];
  CTLineRef line = CTLineCreateWithAttributedString((CFAttributedStringRef)attributed);
  metrics->width = CTLineGetTypographicBounds(line, &metrics->ascent,
                                               &metrics->descent, NULL);
  CFArrayRef runs = CTLineGetGlyphRuns(line);
  for (CFIndex i = 0; i < CFArrayGetCount(runs); i++) {
    CTRunRef run = (CTRunRef)CFArrayGetValueAtIndex(runs, i);
    metrics->glyph_count += (uint32_t)CTRunGetGlyphCount(run);
  }
  CFRelease(line);
  CFRelease(font);
}

void nimculus_measure_text(const char *utf8, const char *font_name, double size,
                           NimculusTextMetrics *metrics) {
  if (!utf8) {
    measureTextString(nil, font_name, size, metrics);
    return;
  }
  measureTextString([[NSString alloc] initWithBytes:utf8 length:strlen(utf8)
                                           encoding:NSUTF8StringEncoding],
                    font_name, size, metrics);
}

void nimculus_measure_text_utf8(const uint8_t *utf8, uint32_t length,
                                const char *font_name, double size,
                                NimculusTextMetrics *metrics) {
  NSString *string = (utf8 && length > 0)
    ? [[NSString alloc] initWithBytes:utf8 length:length encoding:NSUTF8StringEncoding]
    : @"";
  measureTextString(string, font_name, size, metrics);
}
