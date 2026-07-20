#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <CoreText/CoreText.h>
#import <CoreGraphics/CoreGraphics.h>
#import <mach/mach_time.h>
#include <limits.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include "platform.h"

static uint64_t g_input_count = 0;
static NimculusPlatformMetrics g_metrics = {1.0, 0, 0, 0, 0, 0.0, 0};
static NimculusInputCallback g_input_callback = NULL;
static NimculusShortcutCallback g_shortcut_callback = NULL;
static NimculusTextCallback g_text_callback = NULL;
static NimculusSelectionCallback g_selection_callback = NULL;
static NimculusFileCallback g_file_callback = NULL;
static NimculusCommandCallback g_command_callback = NULL;
static NimculusIdleCallback g_idle_callback = NULL;
static double g_ui_rect[4] = {360.0, 260.0, 240.0, 120.0};
static double g_editor_rect[4] = {48.0, 128.0, 828.0, 432.0};
static NimculusPaintCommand *g_paint_commands = NULL;
static uint32_t g_paint_count = 0;
static NimculusPaintRegion *g_paint_dirty_regions = NULL;
static uint32_t g_paint_dirty_count = 0;
static double g_editor_cursor[2] = {8.0, 12.0};
static NSUInteger g_editor_scroll_line = 0;
static NSUInteger g_editor_selection_start = 0;
static NSUInteger g_editor_selection_end = 0;
static NSString *g_editor_text = @"";
static NSString *g_terminal_text = @"";
static NSString *g_theme_background = @"#1f2329";
static NSString *g_theme_foreground = @"#d7dae0";
static NSString *g_theme_accent = @"#4daafc";
static NimculusTerminalRun *g_terminal_runs = NULL;
static uint32_t g_terminal_run_count = 0;
static NSMutableArray<NSString *> *g_terminal_hyperlinks = nil;
static BOOL g_terminal_visible = NO;
static NSString *g_task_output_text = @"";
static BOOL g_task_output_visible = NO;
static BOOL g_terminal_has_selection = NO;
static uint32_t g_terminal_selection_start_row = 0;
static uint32_t g_terminal_selection_start_column = 0;
static uint32_t g_terminal_selection_end_row = 0;
static uint32_t g_terminal_selection_end_column = 0;
static NSString *g_marked_text = @"";
static NSString *g_editor_completions = @"";
static NSString *g_editor_hover = @"";
static double g_editor_hover_position[2] = {8.0, 12.0};
static NSString *g_clipboard_text = @"";
static NSData *g_clipboard_utf8_data = nil;
static char g_dialog_path[PATH_MAX] = {0};
static BOOL g_editor_dirty = NO;
static BOOL g_close_decision = NO;

static NSColor *themeHexColor(NSString *value, NSColor *fallback) {
  if (!value || value.length != 7 || [value characterAtIndex:0] != '#') return fallback;
  unsigned int red = 0, green = 0, blue = 0;
  NSScanner *scanner = [NSScanner scannerWithString:[value substringFromIndex:1]];
  if (![scanner scanHexInt:&red] || red > 0xFFFFFF) return fallback;
  green = (red >> 8) & 0xFF;
  blue = red & 0xFF;
  red = (red >> 16) & 0xFF;
  return [NSColor colorWithCalibratedRed:red / 255.0 green:green / 255.0
                                   blue:blue / 255.0 alpha:1.0];
}
static BOOL g_terminate_decision = NO;
static NSArray<NSString *> *g_recent_files = nil;
static uint32_t g_last_width_points = 0;
static uint32_t g_last_height_points = 0;

static uint32_t mouseButtonForEvent(NSEvent *event) {
  switch (event.type) {
    case NSEventTypeRightMouseDown:
    case NSEventTypeRightMouseUp:
    case NSEventTypeRightMouseDragged:
      return 1;
    case NSEventTypeOtherMouseDown:
    case NSEventTypeOtherMouseUp:
    case NSEventTypeOtherMouseDragged:
      return 2;
    default:
      return 0;
  }
}

typedef struct NimculusDrawUniforms {
  float opacity;
} NimculusDrawUniforms;

static id<MTLRenderPipelineState> g_pipeline = nil;
static id<MTLRenderPipelineState> g_text_pipeline = nil;
static id<MTLRenderPipelineState> g_glyph_pipeline = nil;
static id<MTLRenderPipelineState> g_image_pipeline = nil;
static id<MTLCommandQueue> g_queue = nil;
static id<MTLTexture> g_text_texture = nil;
static CGFloat g_text_texture_scale = 1.0;
static id<MTLTexture> g_glyph_atlas_texture = nil;
static CGFloat g_glyph_atlas_scale = 0.0;
static BOOL g_glyph_rendering_available = NO;
static NSMutableDictionary<NSString *, NSValue *> *g_glyph_atlas_entries = nil;
static NSUInteger g_glyph_atlas_next_x = 0;
static NSUInteger g_glyph_atlas_next_y = 0;
static NSUInteger g_glyph_atlas_row_height = 0;
static uint64_t g_glyph_atlas_hit_count = 0;
static uint64_t g_glyph_atlas_miss_count = 0;
static uint64_t g_glyph_atlas_eviction_count = 0;

void nimculus_platform_set_image_rgba(uint32_t image_id, uint32_t width,
                                      uint32_t height, const uint8_t *rgba,
                                      uint32_t length);

typedef struct NimculusGlyphAtlasEntry {
  uint32_t x;
  uint32_t y;
  uint32_t width;
  uint32_t height;
  float bounds_x;
  float bounds_y;
  float bounds_width;
  float bounds_height;
} NimculusGlyphAtlasEntry;

typedef struct NimculusGlyphVertex {
  float x;
  float y;
  float u;
  float v;
  float red;
  float green;
  float blue;
  float alpha;
} NimculusGlyphVertex;

static NimculusGlyphVertex *g_glyph_vertices = NULL;
static uint32_t g_glyph_vertex_count = 0;
static uint32_t g_glyph_vertex_capacity = 0;
static id<MTLTexture> g_scene_texture = nil;
static NSMutableDictionary<NSNumber *, id<MTLTexture>> *g_image_textures = nil;
static BOOL g_scene_initialized = NO;
static BOOL g_scene_dirty = YES;
static id g_active_view = nil;
static NimculusHighlightSpan *g_highlights = NULL;
static uint32_t g_highlight_count = 0;
static NimculusDiagnosticSpan *g_diagnostics = NULL;
static uint32_t g_diagnostic_count = 0;
static NimculusGitHunkSpan *g_git_hunks = NULL;
static uint32_t g_git_hunk_count = 0;

static void markSceneFullyDirty(void) {
  g_scene_dirty = YES;
  free(g_paint_dirty_regions);
  g_paint_dirty_regions = NULL;
  g_paint_dirty_count = 0;
}

typedef struct NimculusAffine {
  float a, b, c, d, tx, ty;
} NimculusAffine;

static NimculusAffine identityAffine(void) {
  NimculusAffine result = {1.0f, 0.0f, 0.0f, 1.0f, 0.0f, 0.0f};
  return result;
}

static NimculusAffine paintAffine(NimculusPaintCommand paint) {
  return (NimculusAffine){paint.transform_a, paint.transform_b,
    paint.transform_c, paint.transform_d, paint.transform_tx, paint.transform_ty};
}

static CGPoint applyAffine(NimculusAffine transform, double x, double y) {
  return CGPointMake(transform.a * x + transform.c * y + transform.tx,
                     transform.b * x + transform.d * y + transform.ty);
}

static void writeLogicalVertex(float *vertex, CGPoint point, CGSize logicalSize,
                               float red, float green, float blue, float alpha) {
  vertex[0] = (float)(point.x / logicalSize.width * 2.0 - 1.0);
  vertex[1] = (float)(1.0 - point.y / logicalSize.height * 2.0);
  vertex[2] = 0.0f;
  vertex[3] = 1.0f;
  vertex[4] = red;
  vertex[5] = green;
  vertex[6] = blue;
  vertex[7] = alpha;
}

static void drawColoredRectangleWithTransform(id<MTLRenderCommandEncoder> encoder,
                                 id<MTLDevice> device, CGSize logicalSize,
                                 double x, double y, double width, double height,
                                 float red, float green, float blue, float alpha,
                                 NimculusAffine transform) {
  if (logicalSize.width <= 0 || logicalSize.height <= 0 || width <= 0 || height <= 0) return;
  float vertices[32];
  writeLogicalVertex(&vertices[0], applyAffine(transform, x, y + height), logicalSize,
    red, green, blue, alpha);
  writeLogicalVertex(&vertices[8], applyAffine(transform, x + width, y + height), logicalSize,
    red, green, blue, alpha);
  writeLogicalVertex(&vertices[16], applyAffine(transform, x, y), logicalSize,
    red, green, blue, alpha);
  writeLogicalVertex(&vertices[24], applyAffine(transform, x + width, y), logicalSize,
    red, green, blue, alpha);
  id<MTLBuffer> buffer = [device newBufferWithBytes:vertices length:sizeof(vertices)
    options:MTLResourceStorageModeShared];
  [encoder setVertexBuffer:buffer offset:0 atIndex:0];
  NimculusDrawUniforms uniforms = {1.0f};
  id<MTLBuffer> uniformBuffer = [device newBufferWithBytes:&uniforms
    length:sizeof(uniforms) options:MTLResourceStorageModeShared];
  [encoder setVertexBuffer:uniformBuffer offset:0 atIndex:1];
  [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
}

static void drawColoredRectangle(id<MTLRenderCommandEncoder> encoder,
                                 id<MTLDevice> device, CGSize logicalSize,
                                 double x, double y, double width, double height,
                                 float red, float green, float blue, float alpha) {
  drawColoredRectangleWithTransform(encoder, device, logicalSize, x, y, width, height,
    red, green, blue, alpha, identityAffine());
}

static void drawImageTexture(id<MTLRenderCommandEncoder> encoder,
                             id<MTLDevice> device, CGSize logicalSize,
                             double x, double y, double width, double height,
                             NimculusAffine transform,
                             id<MTLTexture> texture) {
  if (!texture || logicalSize.width <= 0 || logicalSize.height <= 0 ||
      width <= 0 || height <= 0) return;
  float vertices[16];
  CGPoint bottomLeft = applyAffine(transform, x, y + height);
  CGPoint bottomRight = applyAffine(transform, x + width, y + height);
  CGPoint topLeft = applyAffine(transform, x, y);
  CGPoint topRight = applyAffine(transform, x + width, y);
  float *points[] = {&vertices[0], &vertices[4], &vertices[8], &vertices[12]};
  CGPoint positions[] = {bottomLeft, bottomRight, topLeft, topRight};
  float u[] = {0.0f, 1.0f, 0.0f, 1.0f};
  float v[] = {1.0f, 1.0f, 0.0f, 0.0f};
  for (int index = 0; index < 4; index++) {
    points[index][0] = (float)(positions[index].x / logicalSize.width * 2.0 - 1.0);
    points[index][1] = (float)(1.0 - positions[index].y / logicalSize.height * 2.0);
    points[index][2] = u[index];
    points[index][3] = v[index];
  }
  id<MTLBuffer> buffer = [device newBufferWithBytes:vertices length:sizeof(vertices)
    options:MTLResourceStorageModeShared];
  if (!buffer) return;
  [encoder setVertexBuffer:buffer offset:0 atIndex:0];
  [encoder setFragmentTexture:texture atIndex:0];
  [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
}

static void drawRoundedRectangleWithTransform(id<MTLRenderCommandEncoder> encoder,
                                 id<MTLDevice> device, CGSize logicalSize,
                                 double x, double y, double width, double height,
                                 double radius, float red, float green,
                                 float blue, float alpha, NimculusAffine transform) {
  if (logicalSize.width <= 0 || logicalSize.height <= 0 || width <= 0 || height <= 0) return;
  const int cornerSegments = 6;
  const int perimeterPoints = (cornerSegments + 1) * 4;
  const int vertexCount = perimeterPoints + 1;
  float *vertices = malloc(sizeof(float) * vertexCount * 8);
  if (!vertices) return;
  double r = MIN(radius, MIN(width, height) / 2.0);
  double centerX = x + width / 2.0;
  double centerY = y + height / 2.0;
  writeLogicalVertex(&vertices[0], applyAffine(transform, centerX, centerY), logicalSize,
    red, green, blue, alpha);
  const double centers[4][2] = {
    {x + r, y + r}, {x + width - r, y + r},
    {x + width - r, y + height - r}, {x + r, y + height - r}
  };
  const double starts[4] = {M_PI, -M_PI / 2.0, 0.0, M_PI / 2.0};
  int vertex = 1;
  for (int corner = 0; corner < 4; corner++) {
    for (int step = 0; step <= cornerSegments; step++) {
      double angle = starts[corner] + (M_PI / 2.0) * step / cornerSegments;
      double pointX = centers[corner][0] + cos(angle) * r;
      double pointY = centers[corner][1] + sin(angle) * r;
      int offset = vertex * 8;
      writeLogicalVertex(&vertices[offset], applyAffine(transform, pointX, pointY), logicalSize,
        red, green, blue, alpha);
      vertex++;
    }
  }
  const int triangleVertexCount = perimeterPoints * 3;
  float *triangles = malloc(sizeof(float) * triangleVertexCount * 8);
  if (!triangles) { free(vertices); return; }
  for (int point = 0; point < perimeterPoints; point++) {
    int next = (point + 1) % perimeterPoints;
    memcpy(&triangles[point * 24], &vertices[0], sizeof(float) * 8);
    memcpy(&triangles[point * 24 + 8], &vertices[(point + 1) * 8], sizeof(float) * 8);
    memcpy(&triangles[point * 24 + 16], &vertices[(next + 1) * 8], sizeof(float) * 8);
  }
  id<MTLBuffer> buffer = [device newBufferWithBytes:triangles
    length:sizeof(float) * triangleVertexCount * 8 options:MTLResourceStorageModeShared];
  free(vertices);
  free(triangles);
  [encoder setVertexBuffer:buffer offset:0 atIndex:0];
  NimculusDrawUniforms uniforms = {1.0f};
  id<MTLBuffer> uniformBuffer = [device newBufferWithBytes:&uniforms
    length:sizeof(uniforms) options:MTLResourceStorageModeShared];
  [encoder setVertexBuffer:uniformBuffer offset:0 atIndex:1];
  [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0
    vertexCount:triangleVertexCount];
}

static void drawRoundedRectangle(id<MTLRenderCommandEncoder> encoder,
                                 id<MTLDevice> device, CGSize logicalSize,
                                 double x, double y, double width, double height,
                                 double radius, float red, float green,
                                 float blue, float alpha) {
  drawRoundedRectangleWithTransform(encoder, device, logicalSize, x, y, width, height,
    radius, red, green, blue, alpha, identityAffine());
}

static void setScissorForRegion(id<MTLRenderCommandEncoder> encoder,
                                NimculusPaintRegion region, CGSize logicalSize,
                                CGSize drawableSize) {
  if (logicalSize.width <= 0 || logicalSize.height <= 0) return;
  double scaleX = drawableSize.width / logicalSize.width;
  double scaleY = drawableSize.height / logicalSize.height;
  double x = MAX(0.0, MIN(logicalSize.width, region.x));
  double y = MAX(0.0, MIN(logicalSize.height, region.y));
  double right = MAX(x, MIN(logicalSize.width, region.x + region.width));
  double bottom = MAX(y, MIN(logicalSize.height, region.y + region.height));
  MTLScissorRect scissor = {
    (NSUInteger)floor(x * scaleX),
    (NSUInteger)floor((logicalSize.height - bottom) * scaleY),
    (NSUInteger)ceil((right - x) * scaleX),
    (NSUInteger)ceil((bottom - y) * scaleY)
  };
  if (scissor.width > 0 && scissor.height > 0) [encoder setScissorRect:scissor];
}

static NimculusPaintRegion intersectPaintRegions(NimculusPaintRegion a,
                                                 NimculusPaintRegion b) {
  double left = MAX(a.x, b.x);
  double top = MAX(a.y, b.y);
  double right = MIN(a.x + a.width, b.x + b.width);
  double bottom = MIN(a.y + a.height, b.y + b.height);
  NimculusPaintRegion result = {
    (float)left, (float)top,
    (float)MAX(0.0, right - left),
    (float)MAX(0.0, bottom - top)
  };
  return result;
}

static void drawPaintCommand(id<MTLRenderCommandEncoder> encoder,
                             id<MTLDevice> device, CGSize logicalSize,
                             NimculusPaintCommand paint) {
  NimculusAffine transform = paintAffine(paint);
  const double x = paint.source_x;
  const double y = paint.source_y;
  const double width = paint.source_width;
  const double height = paint.source_height;
  if (paint.kind == 4 && paint.image_id != 0 && g_image_pipeline && g_image_textures) {
    id<MTLTexture> texture = g_image_textures[@(paint.image_id)];
    if (texture) {
      [encoder setRenderPipelineState:g_image_pipeline];
      drawImageTexture(encoder, device, logicalSize, x, y, width, height,
        transform, texture);
      [encoder setRenderPipelineState:g_pipeline];
      return;
    }
  }
  [encoder setRenderPipelineState:g_pipeline];
  if (paint.kind == 0) { // rectangle
    drawColoredRectangleWithTransform(encoder, device, logicalSize,
      x, y, width, height,
      0.15f, 0.48f, 0.92f, 1.0f, transform);
  } else if (paint.kind == 1) { // border
    const double thickness = 2.0;
    drawColoredRectangleWithTransform(encoder, device, logicalSize,
      x, y, width, thickness, 0.15f, 0.48f, 0.92f, 1.0f, transform);
    drawColoredRectangleWithTransform(encoder, device, logicalSize,
      x, y + height - thickness, width, thickness,
      0.15f, 0.48f, 0.92f, 1.0f, transform);
    drawColoredRectangleWithTransform(encoder, device, logicalSize,
      x, y, thickness, height, 0.15f, 0.48f, 0.92f, 1.0f, transform);
    drawColoredRectangleWithTransform(encoder, device, logicalSize,
      x + width - thickness, y, thickness, height,
      0.15f, 0.48f, 0.92f, 1.0f, transform);
  } else if (paint.kind == 2) { // rounded rectangle
    drawRoundedRectangleWithTransform(encoder, device, logicalSize,
      x, y, width, height, paint.radius,
      0.15f, 0.48f, 0.92f, 1.0f, transform);
  } else if (paint.kind == 3) { // text placeholder; M3 owns real text shaping
    drawColoredRectangleWithTransform(encoder, device, logicalSize,
      x, y, width, height,
      0.55f, 0.62f, 0.72f, 0.75f, transform);
  } else if (paint.kind == 4) { // image placeholder until a texture handle is supplied
    drawColoredRectangleWithTransform(encoder, device, logicalSize,
      x, y, width, height,
      0.28f, 0.34f, 0.42f, 1.0f, transform);
  } else if (paint.kind == 7) { // shadow
    drawColoredRectangleWithTransform(encoder, device, logicalSize,
      x + 3.0, y + 3.0, width, height,
      0.0f, 0.0f, 0.0f, 0.35f, transform);
  } else if (paint.kind == 8) { // caret
    drawColoredRectangleWithTransform(encoder, device, logicalSize,
      x, y, width, height,
      0.85f, 0.90f, 1.0f, 1.0f, transform);
  } else if (paint.kind == 9) { // selection
    drawColoredRectangleWithTransform(encoder, device, logicalSize,
      x, y, width, height,
      0.20f, 0.40f, 0.75f, 0.45f, transform);
  } else if (paint.kind == 10) { // scrollbar
    drawColoredRectangleWithTransform(encoder, device, logicalSize,
      x, y, width, height,
      0.45f, 0.50f, 0.58f, 0.85f, transform);
  }
}

static id<MTLTexture> sceneTextureForDevice(id<MTLDevice> device, CGSize drawableSize) {
  if (drawableSize.width <= 0 || drawableSize.height <= 0) return nil;
  if (g_scene_texture && (g_scene_texture.width != (NSUInteger)drawableSize.width ||
                          g_scene_texture.height != (NSUInteger)drawableSize.height)) {
    g_scene_texture = nil;
    g_scene_initialized = NO;
  }
  if (!g_scene_texture) {
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
      MTLPixelFormatBGRA8Unorm width:(NSUInteger)drawableSize.width
      height:(NSUInteger)drawableSize.height mipmapped:NO];
    descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    g_scene_texture = [device newTextureWithDescriptor:descriptor];
    g_scene_initialized = NO;
  }
  return g_scene_texture;
}

static void highlightColor(uint32_t kind, CGFloat *r, CGFloat *g, CGFloat *b) {
  *r = 0.85; *g = 0.90; *b = 1.0;
  if (kind == 0) { *r = 0.35; *g = 0.70; *b = 1.0; }
  else if (kind == 1) { *r = 0.95; *g = 0.65; *b = 0.35; }
  else if (kind == 2) { *r = 0.80; *g = 0.55; *b = 1.0; }
  else if (kind == 3) { *r = 0.45; *g = 0.75; *b = 0.50; }
  else if (kind == 5) { *r = 0.65; *g = 0.70; *b = 0.78; }
}

static CTFontRef editorFont(void) {
  CTFontRef font = CTFontCreateWithName(CFSTR("Menlo"), 14.0, NULL);
  if (!font) font = CTFontCreateUIFontForLanguage(kCTFontSystemFontType, 14.0, NULL);
  return font;
}

static NSUInteger utf16OffsetForUTF8Bytes(NSString *line, NSUInteger targetBytes) {
  NSUInteger bytes = 0;
  NSUInteger units = 0;
  NSUInteger index = 0;
  while (index < line.length && bytes < targetBytes) {
    NSUInteger width = 1;
    unichar value = [line characterAtIndex:index];
    if (value >= 0xD800 && value <= 0xDBFF && index + 1 < line.length) width = 2;
    NSString *scalar = [line substringWithRange:NSMakeRange(index, width)];
    NSUInteger scalarBytes = [[scalar dataUsingEncoding:NSUTF8StringEncoding] length];
    if (bytes + scalarBytes > targetBytes) break;
    bytes += scalarBytes;
    units += width;
    index += width;
  }
  return units;
}

static NSUInteger utf8BytesForUTF16Offset(NSString *line, NSUInteger targetUnits) {
  NSString *value = line ?: @"";
  NSUInteger target = MIN(targetUnits, value.length);
  NSUInteger units = 0;
  NSUInteger bytes = 0;
  while (units < target) {
    NSUInteger width = 1;
    unichar first = [value characterAtIndex:units];
    if (first >= 0xD800 && first <= 0xDBFF && units + 1 < value.length) {
      unichar second = [value characterAtIndex:units + 1];
      if (second >= 0xDC00 && second <= 0xDFFF) width = 2;
    }
    // Never manufacture an unpaired surrogate when AppKit asks for a
    // UTF-16 position inside an emoji or another supplementary scalar.
    if (units + width > target) break;
    NSString *scalar = [value substringWithRange:NSMakeRange(units, width)];
    NSData *encoded = [scalar dataUsingEncoding:NSUTF8StringEncoding];
    if (!encoded) break;
    bytes += encoded.length;
    units += width;
  }
  return bytes;
}

static NSUInteger utf8BytesForDocumentUTF16Offset(NSString *text, NSUInteger targetUnits) {
  return utf8BytesForUTF16Offset(text ?: @"", targetUnits);
}

static NSRange boundedDocumentRange(NSRange range, NSUInteger documentLength) {
  NSUInteger start = MIN(range.location, documentLength);
  NSUInteger length = MIN(range.length, documentLength - start);
  return NSMakeRange(start, length);
}

static CGFloat editorTextOffset(NSString *line, NSUInteger utf16Index) {
  CTFontRef font = editorFont();
  if (!font) return 0.0;
  NSDictionary *attributes = @{ (id)kCTFontAttributeName: (__bridge id)font };
  NSString *value = line ?: @"";
  NSAttributedString *attributed = [[NSAttributedString alloc] initWithString:value attributes:attributes];
  CTLineRef ctLine = CTLineCreateWithAttributedString((CFAttributedStringRef)attributed);
  CGFloat offset = CTLineGetOffsetForStringIndex(ctLine, MIN(utf16Index, value.length), NULL);
  CFRelease(ctLine);
  CFRelease(font);
  return offset;
}

static CGPoint editorPointForUTF16Offset(NSUInteger documentOffset) {
  NSArray<NSString *> *lines = [g_editor_text componentsSeparatedByString:@"\n"];
  NSUInteger remaining = MIN(documentOffset, g_editor_text.length);
  NSUInteger lineIndex = 0;
  NSString *lineText = lines.count > 0 ? lines[0] : @"";
  for (NSUInteger index = 0; index < lines.count; index++) {
    lineText = lines[index];
    if (remaining <= lineText.length || index + 1 == lines.count) {
      lineIndex = index;
      break;
    }
    remaining -= lineText.length + 1;
  }
  NSUInteger visibleLine = lineIndex > g_editor_scroll_line
    ? lineIndex - g_editor_scroll_line : 0;
  return CGPointMake(8.0 + editorTextOffset(lineText, remaining),
                     12.0 + visibleLine * 18.0);
}

static void updateEditorGlyphAtlas(id<MTLDevice> device, NSString *text);

static void updateEditorTextTexture(id<MTLDevice> device, NSString *text,
                                    BOOL updateAtlas) {
  if (!device) return;
  // The atlas is the primary committed-text renderer. The Core Text texture
  // remains an overlay for selection, marked composition, and caret, with a
  // complete-text fallback only when atlas generation is unavailable.
  if (updateAtlas) updateEditorGlyphAtlas(device, text);
  const BOOL drawFallbackText = !g_glyph_rendering_available;
  CGFloat scale = g_metrics.scale_factor > 0.0 ? g_metrics.scale_factor : 1.0;
  const size_t width = (size_t)ceil(MAX(1.0, g_editor_rect[2]) * scale);
  const size_t height = (size_t)ceil(MAX(1.0, g_editor_rect[3]) * scale);
  const CGFloat logicalHeight = MAX(1.0, g_editor_rect[3]);
  NSMutableData *pixels = [NSMutableData dataWithLength:width * height * 4];
  CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
  CGContextRef context = CGBitmapContextCreate(pixels.mutableBytes, width, height, 8,
    width * 4, colorSpace, kCGImageAlphaPremultipliedLast);
  CGColorSpaceRelease(colorSpace);
  if (!context) return;
  CGContextScaleCTM(context, scale, scale);
  CTFontRef font = editorFont();
  NSColor *baseColor = themeHexColor(g_theme_foreground,
    [NSColor colorWithCalibratedRed:0.85 green:0.90 blue:1.0 alpha:1.0]);
  NSDictionary *attributes = @{ (id)kCTFontAttributeName: (__bridge id)font,
    (id)kCTForegroundColorAttributeName: (id)baseColor.CGColor };
  NSArray<NSString *> *lines = [(text ?: @"") componentsSeparatedByString:@"\n"];
  NSUInteger startLine = MIN(g_editor_scroll_line, lines.count);
  const CGFloat lineHeight = 18.0;
  NSUInteger visibleLines = MIN(lines.count - startLine,
    (NSUInteger)MAX(1.0, ceil(g_editor_rect[3] / lineHeight)));
  NSUInteger lineStartByte = 0;
  NSUInteger lineStartUnit = 0;
  for (NSUInteger index = 0; index < startLine; index++) {
    NSString *skippedLine = lines[index];
    lineStartByte += [[skippedLine dataUsingEncoding:NSUTF8StringEncoding] length] + 1;
    lineStartUnit += skippedLine.length + 1;
  }
  for (NSUInteger displayIndex = 0; displayIndex < visibleLines; displayIndex++) {
    NSUInteger index = startLine + displayIndex;
    NSString *lineText = lines[index];
    NSUInteger lineLength = [[lineText dataUsingEncoding:NSUTF8StringEncoding] length];
    NSUInteger lineEndUnit = lineStartUnit + lineText.length;
    if (g_editor_selection_end > g_editor_selection_start &&
        g_editor_selection_end > lineStartUnit && g_editor_selection_start < lineEndUnit) {
      NSUInteger startUnit = MAX(g_editor_selection_start, lineStartUnit) - lineStartUnit;
      NSUInteger endUnit = MIN(g_editor_selection_end, lineEndUnit) - lineStartUnit;
      CGContextSetRGBFillColor(context, 0.20, 0.40, 0.75, 0.45);
      CGContextFillRect(context, CGRectMake(8.0 + editorTextOffset(lineText, startUnit),
        logicalHeight - lineHeight * (displayIndex + 1) - 4.0,
        MAX(1.0, editorTextOffset(lineText, endUnit) - editorTextOffset(lineText, startUnit)), 20.0));
    }
    NSUInteger documentLine = startLine + displayIndex;
    for (uint32_t hunkIndex = 0; hunkIndex < g_git_hunk_count; hunkIndex++) {
      NimculusGitHunkSpan hunk = g_git_hunks[hunkIndex];
      NSUInteger hunkStart = hunk.start_line;
      NSUInteger hunkEnd = hunkStart + MAX((uint32_t)1, hunk.line_count);
      if (documentLine < hunkStart || documentLine >= hunkEnd) continue;
      CGFloat red = 0.30, green = 0.75, blue = 0.42;
      if (hunk.kind == 1) {
        red = 0.92; green = 0.34; blue = 0.34;
      } else if (hunk.kind >= 2) {
        red = 0.35; green = 0.58; blue = 0.95;
      }
      CGContextSetRGBFillColor(context, red, green, blue, 0.95);
      CGContextFillRect(context, CGRectMake(1.0,
        logicalHeight - lineHeight * (displayIndex + 1) - 1.0, 3.0, 16.0));
      break;
    }
    NSMutableAttributedString *attributed = [[NSMutableAttributedString alloc]
      initWithString:lineText attributes:attributes];
    for (uint32_t spanIndex = 0; spanIndex < g_highlight_count; spanIndex++) {
      NimculusHighlightSpan span = g_highlights[spanIndex];
      if (span.end_byte > lineStartByte && span.start_byte < lineStartByte + lineLength) {
        NSUInteger startByte = MAX((NSUInteger)span.start_byte, lineStartByte) - lineStartByte;
        NSUInteger endByte = MIN((NSUInteger)span.end_byte, lineStartByte + lineLength) - lineStartByte;
        NSUInteger startUnit = utf16OffsetForUTF8Bytes(lineText, startByte);
        NSUInteger endUnit = utf16OffsetForUTF8Bytes(lineText, endByte);
        if (endUnit > startUnit) {
          CGFloat red, green, blue;
          highlightColor(span.kind, &red, &green, &blue);
          NSColor *color = [NSColor colorWithCalibratedRed:red green:green blue:blue alpha:1.0];
          [attributed addAttribute:(id)kCTForegroundColorAttributeName
            value:(id)color.CGColor range:NSMakeRange(startUnit, endUnit - startUnit)];
        }
      }
    }
    if (drawFallbackText) {
      CTLineRef line = CTLineCreateWithAttributedString((CFAttributedStringRef)attributed);
      CGContextSetTextPosition(context, 8.0,
        logicalHeight - lineHeight * (displayIndex + 1) + 1.0);
      CTLineDraw(line, context);
      CFRelease(line);
    }
    for (uint32_t diagnosticIndex = 0; diagnosticIndex < g_diagnostic_count; diagnosticIndex++) {
      NimculusDiagnosticSpan diagnostic = g_diagnostics[diagnosticIndex];
      if (diagnostic.end_byte <= lineStartByte ||
          diagnostic.start_byte >= lineStartByte + lineLength) continue;
      NSUInteger startByte = MAX((NSUInteger)diagnostic.start_byte, lineStartByte) - lineStartByte;
      NSUInteger endByte = MIN((NSUInteger)diagnostic.end_byte, lineStartByte + lineLength) - lineStartByte;
      NSUInteger startUnit = utf16OffsetForUTF8Bytes(lineText, startByte);
      NSUInteger endUnit = utf16OffsetForUTF8Bytes(lineText, endByte);
      if (endUnit <= startUnit) continue;
      CGFloat red = 0.95, green = 0.25, blue = 0.25;
      if (diagnostic.severity == 2) {
        red = 0.98; green = 0.62; blue = 0.16;
      } else if (diagnostic.severity == 3) {
        red = 0.30; green = 0.60; blue = 0.98;
      } else if (diagnostic.severity >= 4) {
        red = 0.55; green = 0.60; blue = 0.68;
      }
      CGContextSetStrokeColorWithColor(context,
        [NSColor colorWithCalibratedRed:red green:green blue:blue alpha:1.0].CGColor);
      CGContextSetLineWidth(context, 1.0);
      CGFloat x0 = 8.0 + editorTextOffset(lineText, startUnit);
      CGFloat x1 = 8.0 + editorTextOffset(lineText, endUnit);
      CGFloat y = logicalHeight - lineHeight * (displayIndex + 1) - 1.5;
      CGContextMoveToPoint(context, x0, y);
      CGContextAddLineToPoint(context, MAX(x0 + 2.0, x1), y);
      CGContextStrokePath(context);
    }
    lineStartByte += lineLength + 1;
    lineStartUnit = lineEndUnit + 1;
  }
  if (g_marked_text.length > 0) {
    NSDictionary *markedAttributes = @{ (id)kCTFontAttributeName: (__bridge id)font,
      (id)kCTForegroundColorAttributeName: (id)baseColor.CGColor,
      (id)kCTUnderlineStyleAttributeName: @1 };
    NSAttributedString *marked = [[NSAttributedString alloc] initWithString:g_marked_text
      attributes:markedAttributes];
    CTLineRef markedLine = CTLineCreateWithAttributedString((CFAttributedStringRef)marked);
    CGFloat baseline = logicalHeight - g_editor_cursor[1] - 14.0;
    CGContextSetTextPosition(context, g_editor_cursor[0], MAX(0.0, baseline));
    CTLineDraw(markedLine, context);
    CFRelease(markedLine);
  }
  if (g_editor_completions.length > 0) {
    NSArray<NSString *> *completionLines = [g_editor_completions componentsSeparatedByString:@"\n"];
    NSUInteger visibleCount = MIN((NSUInteger)6, completionLines.count);
    CGFloat popupTop = logicalHeight - g_editor_cursor[1] - 4.0;
    CGFloat popupHeight = visibleCount * 18.0 + 6.0;
    CGContextSetRGBFillColor(context, 0.08, 0.10, 0.14, 0.96);
    CGContextFillRect(context, CGRectMake(g_editor_cursor[0], popupTop - popupHeight,
      360.0, popupHeight));
    NSDictionary *completionAttributes = @{ (id)kCTFontAttributeName: (__bridge id)font,
      (id)kCTForegroundColorAttributeName: (id)[NSColor whiteColor].CGColor };
    for (NSUInteger index = 0; index < visibleCount; index++) {
      NSString *lineText = completionLines[index];
      NSAttributedString *line = [[NSAttributedString alloc] initWithString:lineText
        attributes:completionAttributes];
      CTLineRef completionLine = CTLineCreateWithAttributedString((CFAttributedStringRef)line);
      CGContextSetTextPosition(context, g_editor_cursor[0] + 6.0,
        popupTop - 18.0 * (index + 1) + 3.0);
      CTLineDraw(completionLine, context);
      CFRelease(completionLine);
    }
  }
  if (g_editor_hover.length > 0) {
    NSArray<NSString *> *hoverLines = [g_editor_hover componentsSeparatedByString:@"\n"];
    NSUInteger visibleCount = MIN((NSUInteger)8, hoverLines.count);
    CGFloat popupTop = logicalHeight - g_editor_hover_position[1] - 4.0;
    CGFloat popupHeight = visibleCount * 18.0 + 8.0;
    CGFloat popupX = MAX(8.0, g_editor_hover_position[0]);
    CGContextSetRGBFillColor(context, 0.06, 0.07, 0.10, 0.96);
    CGContextFillRect(context, CGRectMake(popupX, popupTop - popupHeight,
      460.0, popupHeight));
    NSDictionary *hoverAttributes = @{ (id)kCTFontAttributeName: (__bridge id)font,
      (id)kCTForegroundColorAttributeName: (id)[NSColor whiteColor].CGColor };
    for (NSUInteger index = 0; index < visibleCount; index++) {
      NSString *lineText = hoverLines[index];
      NSAttributedString *line = [[NSAttributedString alloc] initWithString:lineText
        attributes:hoverAttributes];
      CTLineRef hoverLine = CTLineCreateWithAttributedString((CFAttributedStringRef)line);
      CGContextSetTextPosition(context, popupX + 6.0,
        popupTop - 18.0 * (index + 1) + 4.0);
      CTLineDraw(hoverLine, context);
      CFRelease(hoverLine);
    }
  }
  CGContextSetStrokeColorWithColor(context, [NSColor colorWithCalibratedRed:0.85
    green:0.90 blue:1.0 alpha:1.0].CGColor);
  CGContextSetLineWidth(context, 1.0);
  CGFloat caretY = logicalHeight - g_editor_cursor[1] - 4.0;
  CGContextMoveToPoint(context, g_editor_cursor[0], caretY);
  CGContextAddLineToPoint(context, g_editor_cursor[0], caretY + 20.0);
  CGContextStrokePath(context);
  CFRelease(font);
  CGContextRelease(context);
  MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
    width:width height:height mipmapped:NO];
  descriptor.usage = MTLTextureUsageShaderRead;
  g_text_texture = [device newTextureWithDescriptor:descriptor];
  [g_text_texture replaceRegion:MTLRegionMake2D(0, 0, width, height)
    mipmapLevel:0 withBytes:pixels.bytes bytesPerRow:width * 4];
  g_text_texture_scale = scale;
}

static void resetGlyphVertices(void) {
  g_glyph_vertex_count = 0;
}

static void ensureGlyphAtlas(id<MTLDevice> device, CGFloat scale) {
  const NSUInteger atlasSize = 2048;
  if (!g_glyph_atlas_texture || fabs(g_glyph_atlas_scale - scale) > 0.001) {
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
      width:atlasSize height:atlasSize mipmapped:NO];
    descriptor.usage = MTLTextureUsageShaderRead;
    g_glyph_atlas_texture = [device newTextureWithDescriptor:descriptor];
    g_glyph_atlas_scale = scale;
    g_glyph_atlas_entries = [NSMutableDictionary dictionary];
    g_glyph_atlas_next_x = 0;
    g_glyph_atlas_next_y = 0;
    g_glyph_atlas_row_height = 0;
  }
  if (!g_glyph_atlas_entries) g_glyph_atlas_entries = [NSMutableDictionary dictionary];
}

static void appendGlyphVertex(NimculusGlyphVertex vertex) {
  if (g_glyph_vertex_count == g_glyph_vertex_capacity) {
    uint32_t capacity = g_glyph_vertex_capacity == 0 ? 1024 : g_glyph_vertex_capacity * 2;
    NimculusGlyphVertex *vertices = realloc(g_glyph_vertices,
      sizeof(NimculusGlyphVertex) * capacity);
    if (!vertices) return;
    g_glyph_vertices = vertices;
    g_glyph_vertex_capacity = capacity;
  }
  g_glyph_vertices[g_glyph_vertex_count++] = vertex;
}

static void colorForGlyphRun(CTRunRef run, CGFloat *red, CGFloat *green,
                             CGFloat *blue, CGFloat *alpha) {
  *red = 0.85; *green = 0.90; *blue = 1.0; *alpha = 1.0;
  NSDictionary *attributes = (__bridge NSDictionary *)CTRunGetAttributes(run);
  CGColorRef color = (__bridge CGColorRef)[attributes objectForKey:(id)kCTForegroundColorAttributeName];
  if (!color) return;
  NSColor *nsColor = [NSColor colorWithCGColor:color];
  NSColor *rgb = [nsColor colorUsingColorSpace:[NSColorSpace genericRGBColorSpace]];
  if (!rgb) return;
  *red = rgb.redComponent;
  *green = rgb.greenComponent;
  *blue = rgb.blueComponent;
  *alpha = rgb.alphaComponent;
}

static BOOL atlasEntryForGlyph(id<MTLDevice> device, CTFontRef font, CGGlyph glyph,
                               CGFloat scale, NimculusGlyphAtlasEntry *entry) {
  if (!device || !font || !entry) return NO;
  NSString *fontName = (__bridge_transfer NSString *)CTFontCopyPostScriptName(font);
  NSString *key = [NSString stringWithFormat:@"%@|%.3f|%u", fontName ?: @"system",
    scale, (unsigned)glyph];
  NSValue *cached = [g_glyph_atlas_entries objectForKey:key];
  if (cached) {
    [cached getValue:entry];
    g_glyph_atlas_hit_count++;
    return entry->width > 0 && entry->height > 0;
  }
  g_glyph_atlas_miss_count++;
  CGRect bounds = CTFontGetBoundingRectsForGlyphs(font, kCTFontOrientationDefault,
    &glyph, NULL, 1);
  memset(entry, 0, sizeof(*entry));
  entry->bounds_x = bounds.origin.x;
  entry->bounds_y = bounds.origin.y;
  entry->bounds_width = bounds.size.width;
  entry->bounds_height = bounds.size.height;
  if (bounds.size.width <= 0.0 || bounds.size.height <= 0.0) {
    [g_glyph_atlas_entries setObject:[NSValue valueWithBytes:entry
      objCType:@encode(NimculusGlyphAtlasEntry)] forKey:key];
    return NO;
  }
  NSUInteger padding = 1;
  NSUInteger width = (NSUInteger)ceil(bounds.size.width * scale) + padding * 2;
  NSUInteger height = (NSUInteger)ceil(bounds.size.height * scale) + padding * 2;
  const NSUInteger atlasSize = 2048;
  if (width >= atlasSize || height >= atlasSize) return NO;
  if (g_glyph_atlas_next_x + width > atlasSize) {
    g_glyph_atlas_next_x = 0;
    g_glyph_atlas_next_y += g_glyph_atlas_row_height;
    g_glyph_atlas_row_height = 0;
  }
  if (g_glyph_atlas_next_y + height > atlasSize) {
    [g_glyph_atlas_entries removeAllObjects];
    g_glyph_atlas_next_x = 0;
    g_glyph_atlas_next_y = 0;
    g_glyph_atlas_row_height = 0;
    g_glyph_atlas_eviction_count++;
  }
  if (g_glyph_atlas_next_x + width > atlasSize ||
      g_glyph_atlas_next_y + height > atlasSize) return NO;
  NSUInteger x = g_glyph_atlas_next_x;
  NSUInteger y = g_glyph_atlas_next_y;
  g_glyph_atlas_next_x += width;
  g_glyph_atlas_row_height = MAX(g_glyph_atlas_row_height, height);
  NSMutableData *pixels = [NSMutableData dataWithLength:width * height];
  CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceGray();
  CGContextRef context = CGBitmapContextCreate(pixels.mutableBytes, width, height, 8,
    width, colorSpace, (CGBitmapInfo)kCGImageAlphaNone);
  CGColorSpaceRelease(colorSpace);
  if (!context) return NO;
  CGContextSetGrayFillColor(context, 1.0, 1.0);
  CGContextScaleCTM(context, scale, scale);
  CGPoint origin = CGPointMake((CGFloat)padding / scale - bounds.origin.x,
    (CGFloat)padding / scale - bounds.origin.y);
  CTFontDrawGlyphs(font, &glyph, &origin, 1, context);
  CGContextRelease(context);
  [g_glyph_atlas_texture replaceRegion:MTLRegionMake2D(x, y, width, height)
    mipmapLevel:0 withBytes:pixels.bytes bytesPerRow:width];
  entry->x = (uint32_t)x;
  entry->y = (uint32_t)y;
  entry->width = (uint32_t)width;
  entry->height = (uint32_t)height;
  [g_glyph_atlas_entries setObject:[NSValue valueWithBytes:entry
    objCType:@encode(NimculusGlyphAtlasEntry)] forKey:key];
  return YES;
}

static float normalizedX(CGFloat value, CGFloat width) {
  return (float)(value / width * 2.0 - 1.0);
}

static float normalizedY(CGFloat value, CGFloat height) {
  return (float)(1.0 - value / height * 2.0);
}

static void appendGlyphQuad(CGSize sceneSize, CGRect editorRect, CGFloat scale,
                            NimculusGlyphAtlasEntry entry, CGPoint glyphOrigin,
                            CGFloat baselineY, CGFloat red, CGFloat green,
                            CGFloat blue, CGFloat alpha) {
  if (entry.width == 0 || entry.height == 0 || sceneSize.width <= 0 ||
      sceneSize.height <= 0 || editorRect.size.width <= 0 ||
      editorRect.size.height <= 0) return;
  CGFloat x0 = editorRect.origin.x + 8.0 + glyphOrigin.x + entry.bounds_x;
  CGFloat x1 = x0 + entry.bounds_width;
  CGFloat bottomOrigin = baselineY + entry.bounds_y;
  CGFloat y0 = editorRect.origin.y + editorRect.size.height -
    (bottomOrigin + entry.bounds_height);
  CGFloat y1 = editorRect.origin.y + editorRect.size.height - bottomOrigin;
  float u0 = (float)entry.x / 2048.0f;
  float u1 = (float)(entry.x + entry.width) / 2048.0f;
  float v0 = 1.0f - (float)(entry.y + entry.height) / 2048.0f;
  float v1 = 1.0f - (float)entry.y / 2048.0f;
  NimculusGlyphVertex vertices[6] = {
    {normalizedX(x0, sceneSize.width), normalizedY(y1, sceneSize.height), u0, v0, red, green, blue, alpha},
    {normalizedX(x1, sceneSize.width), normalizedY(y1, sceneSize.height), u1, v0, red, green, blue, alpha},
    {normalizedX(x0, sceneSize.width), normalizedY(y0, sceneSize.height), u0, v1, red, green, blue, alpha},
    {normalizedX(x0, sceneSize.width), normalizedY(y0, sceneSize.height), u0, v1, red, green, blue, alpha},
    {normalizedX(x1, sceneSize.width), normalizedY(y1, sceneSize.height), u1, v0, red, green, blue, alpha},
    {normalizedX(x1, sceneSize.width), normalizedY(y0, sceneSize.height), u1, v1, red, green, blue, alpha}
  };
  (void)scale;
  for (NSUInteger index = 0; index < 6; index++) appendGlyphVertex(vertices[index]);
}

static void updateEditorGlyphAtlas(id<MTLDevice> device, NSString *text) {
  g_glyph_rendering_available = NO;
  if (!device) return;
  CGFloat scale = g_metrics.scale_factor > 0.0 ? g_metrics.scale_factor : 1.0;
  ensureGlyphAtlas(device, scale);
  resetGlyphVertices();
  CTFontRef baseFont = editorFont();
  if (!baseFont) return;
  NSColor *baseColor = themeHexColor(g_theme_foreground,
    [NSColor colorWithCalibratedRed:0.85 green:0.90 blue:1.0 alpha:1.0]);
  NSDictionary *attributes = @{ (id)kCTFontAttributeName: (__bridge id)baseFont,
    (id)kCTForegroundColorAttributeName: (id)baseColor.CGColor };
  NSArray<NSString *> *lines = [(text ?: @"") componentsSeparatedByString:@"\n"];
  NSUInteger startLine = MIN(g_editor_scroll_line, lines.count);
  const CGFloat lineHeight = 18.0;
  NSUInteger visibleLines = MIN(lines.count - startLine,
    (NSUInteger)MAX(1.0, ceil(g_editor_rect[3] / lineHeight)));
  NSUInteger lineStartByte = 0;
  for (NSUInteger index = 0; index < startLine; index++) {
    lineStartByte += [[lines[index] dataUsingEncoding:NSUTF8StringEncoding] length] + 1;
  }
  CGSize editorSize = CGSizeMake(MAX(1.0, g_editor_rect[2]),
                                 MAX(1.0, g_editor_rect[3]));
  CGSize sceneSize = CGSizeMake(MAX((CGFloat)g_metrics.width_points,
                                    g_editor_rect[0] + editorSize.width),
                                MAX((CGFloat)g_metrics.height_points,
                                    g_editor_rect[1] + editorSize.height));
  CGRect editorRect = CGRectMake(g_editor_rect[0], g_editor_rect[1],
                                 editorSize.width, editorSize.height);
  for (NSUInteger displayIndex = 0; displayIndex < visibleLines; displayIndex++) {
    NSString *lineText = lines[startLine + displayIndex];
    NSUInteger lineLength = [[lineText dataUsingEncoding:NSUTF8StringEncoding] length];
    NSMutableAttributedString *attributed = [[NSMutableAttributedString alloc]
      initWithString:lineText attributes:attributes];
    for (uint32_t spanIndex = 0; spanIndex < g_highlight_count; spanIndex++) {
      NimculusHighlightSpan span = g_highlights[spanIndex];
      if (span.end_byte > lineStartByte && span.start_byte < lineStartByte + lineLength) {
        NSUInteger startByte = MAX((NSUInteger)span.start_byte, lineStartByte) - lineStartByte;
        NSUInteger endByte = MIN((NSUInteger)span.end_byte, lineStartByte + lineLength) - lineStartByte;
        NSUInteger startUnit = utf16OffsetForUTF8Bytes(lineText, startByte);
        NSUInteger endUnit = utf16OffsetForUTF8Bytes(lineText, endByte);
        if (endUnit > startUnit) {
          CGFloat red, green, blue;
          highlightColor(span.kind, &red, &green, &blue);
          NSColor *color = [NSColor colorWithCalibratedRed:red green:green blue:blue alpha:1.0];
          [attributed addAttribute:(id)kCTForegroundColorAttributeName
            value:(id)color.CGColor range:NSMakeRange(startUnit, endUnit - startUnit)];
        }
      }
    }
    CTLineRef line = CTLineCreateWithAttributedString((CFAttributedStringRef)attributed);
    CFArrayRef runs = CTLineGetGlyphRuns(line);
    CGFloat baselineY = editorSize.height - lineHeight * (displayIndex + 1);
    for (CFIndex runIndex = 0; runIndex < CFArrayGetCount(runs); runIndex++) {
      CTRunRef run = (CTRunRef)CFArrayGetValueAtIndex(runs, runIndex);
      NSDictionary *runAttributes = (__bridge NSDictionary *)CTRunGetAttributes(run);
      CTFontRef font = (__bridge CTFontRef)[runAttributes objectForKey:(id)kCTFontAttributeName];
      if (!font) font = baseFont;
      CGFloat red, green, blue, alpha;
      colorForGlyphRun(run, &red, &green, &blue, &alpha);
      CFIndex glyphCount = CTRunGetGlyphCount(run);
      if (glyphCount == 0) continue;
      CGGlyph *glyphs = malloc(sizeof(CGGlyph) * (NSUInteger)glyphCount);
      CGPoint *positions = malloc(sizeof(CGPoint) * (NSUInteger)glyphCount);
      if (!glyphs || !positions) { free(glyphs); free(positions); continue; }
      CTRunGetGlyphs(run, CFRangeMake(0, glyphCount), glyphs);
      CTRunGetPositions(run, CFRangeMake(0, glyphCount), positions);
      for (CFIndex glyphIndex = 0; glyphIndex < glyphCount; glyphIndex++) {
        NimculusGlyphAtlasEntry entry;
        if (atlasEntryForGlyph(device, font, glyphs[glyphIndex], scale, &entry)) {
          appendGlyphQuad(sceneSize, editorRect, scale, entry, positions[glyphIndex], baselineY,
            red, green, blue, alpha);
        }
      }
      free(glyphs);
      free(positions);
    }
    CFRelease(line);
    lineStartByte += lineLength + 1;
  }
  CFRelease(baseFont);
  g_glyph_rendering_available = g_glyph_pipeline != nil && g_glyph_vertex_count > 0;
}

static double millisecondsSince(uint64_t start) {
  mach_timebase_info_data_t timebase;
  mach_timebase_info(&timebase);
  uint64_t nanos = (mach_absolute_time() - start) * timebase.numer / timebase.denom;
  return (double)nanos / 1000000.0;
}

static BOOL logInput(NSString *kind, NSEvent *event) {
  g_input_count++;
  NSPoint location = event.locationInWindow;
  if (g_active_view) {
    location = [(NSView *)g_active_view convertPoint:event.locationInWindow fromView:nil];
  }
  NSLog(@"Nimculus input kind=%@ keyCode=%hu modifiers=0x%lx x=%.1f y=%.1f dx=%.1f dy=%.1f",
        kind, event.keyCode, event.modifierFlags, location.x, location.y,
        event.deltaX, event.deltaY);
  if (g_input_callback) {
    NimculusInputEvent input = {
      .type = (uint32_t)event.type,
      .key_code = event.keyCode,
      .modifiers = (uint32_t)event.modifierFlags,
      .button = mouseButtonForEvent(event),
      .x = location.x, .y = location.y,
      .delta_x = event.deltaX, .delta_y = event.deltaY,
      .precise_scrolling = event.hasPreciseScrollingDeltas == YES,
    };
    if (event.type == NSEventTypeKeyDown && g_shortcut_callback &&
        g_shortcut_callback(&input)) {
      return YES;
    }
    if (g_input_callback) g_input_callback(&input);
  }
  return NO;
}

@interface NimculusMetalView : NSView <NSTextInputClient>
@property(nonatomic, strong) CAMetalLayer *metalLayer;
@property(nonatomic, copy) NSString *markedText;
@property(nonatomic) NSRange markedTextRange;
@property(nonatomic) NSRange selectedTextRange;
@property(nonatomic, strong) NSTrackingArea *trackingArea;
- (void)updateTerminalFrame;
@end

@interface NimculusTerminalOverlay : NSTextView
@end

@interface NimculusTaskOutputOverlay : NSTextView
@end

@implementation NimculusTerminalOverlay
- (BOOL)acceptsFirstResponder { return NO; }
- (NSView *)hitTest:(NSPoint)point { return nil; }
@end

@implementation NimculusTaskOutputOverlay
- (BOOL)acceptsFirstResponder { return NO; }
- (NSView *)hitTest:(NSPoint)point { return nil; }
@end

static NSUInteger terminalUTF16OffsetForCell(uint32_t row, uint32_t column) {
  NSArray<NSString *> *lines = [g_terminal_text componentsSeparatedByString:@"\n"];
  if (lines.count == 0) return 0;
  NSUInteger lineIndex = MIN((NSUInteger)row, lines.count - 1);
  NSUInteger offset = 0;
  for (NSUInteger index = 0; index < lineIndex; index++) {
    offset += lines[index].length + 1;
  }
  NSString *line = lines[lineIndex];
  __block NSUInteger cell = 0;
  __block NSUInteger utf16 = 0;
  [line enumerateSubstringsInRange:NSMakeRange(0, line.length)
                           options:NSStringEnumerationByComposedCharacterSequences
                        usingBlock:^(NSString *substring, NSRange substringRange,
                                     NSRange enclosingRange, BOOL *stop) {
    (void)substring; (void)enclosingRange;
    if (cell >= column) { *stop = YES; return; }
    utf16 = NSMaxRange(substringRange);
    cell++;
  }];
  return offset + MIN(utf16, line.length);
}

static void applyTerminalSelection(NSTextView *terminal) {
  if (!terminal || !g_terminal_has_selection) {
    if (terminal) terminal.selectedRange = NSMakeRange(0, 0);
    return;
  }
  NSUInteger start = terminalUTF16OffsetForCell(g_terminal_selection_start_row,
                                                 g_terminal_selection_start_column);
  NSUInteger end = terminalUTF16OffsetForCell(g_terminal_selection_end_row,
                                               g_terminal_selection_end_column);
  NSUInteger lower = MIN(start, end);
  NSUInteger upper = MAX(start, end);
  terminal.selectedRange = NSMakeRange(lower, upper - lower);
}

static void terminalIndexedColor(uint32_t index, CGFloat *red, CGFloat *green, CGFloat *blue) {
  static const CGFloat ansi[16][3] = {
    {0.08, 0.09, 0.12}, {0.85, 0.25, 0.28}, {0.30, 0.78, 0.42}, {0.82, 0.68, 0.25},
    {0.30, 0.52, 0.92}, {0.72, 0.36, 0.80}, {0.28, 0.75, 0.78}, {0.78, 0.82, 0.88},
    {0.35, 0.38, 0.45}, {1.00, 0.40, 0.43}, {0.42, 0.94, 0.52}, {1.00, 0.84, 0.38},
    {0.45, 0.65, 1.00}, {0.88, 0.48, 0.96}, {0.42, 0.90, 0.92}, {0.96, 0.97, 1.00}
  };
  if (index < 16) {
    *red = ansi[index][0]; *green = ansi[index][1]; *blue = ansi[index][2]; return;
  }
  if (index >= 232) {
    CGFloat value = 8.0 + (CGFloat)(index - 232) * 10.0;
    *red = *green = *blue = value / 255.0; return;
  }
  uint32_t cube = index - 16;
  uint32_t r = cube / 36, g = (cube / 6) % 6, b = cube % 6;
  *red = r == 0 ? 0.0 : (55.0 + r * 40.0) / 255.0;
  *green = g == 0 ? 0.0 : (55.0 + g * 40.0) / 255.0;
  *blue = b == 0 ? 0.0 : (55.0 + b * 40.0) / 255.0;
}

static NSColor *terminalColor(uint32_t kind, uint32_t index,
                              uint32_t red, uint32_t green, uint32_t blue,
                              BOOL foreground) {
  CGFloat r = foreground ? 0.82 : 0.025;
  CGFloat g = foreground ? 0.88 : 0.030;
  CGFloat b = foreground ? 0.92 : 0.045;
  if (kind == 1) terminalIndexedColor(index, &r, &g, &b);
  else if (kind == 2) { r = red / 255.0; g = green / 255.0; b = blue / 255.0; }
  return [NSColor colorWithCalibratedRed:r green:g blue:b alpha:1.0];
}

static void applyTerminalRuns(NSTextView *terminal) {
  if (!terminal) return;
  NSMutableAttributedString *attributed = [[NSMutableAttributedString alloc]
    initWithString:g_terminal_text ?: @"" attributes:@{
      NSFontAttributeName: [NSFont fontWithName:@"Menlo" size:12.0] ?: [NSFont monospacedSystemFontOfSize:12.0 weight:NSFontWeightRegular],
      NSForegroundColorAttributeName: terminalColor(0, 0, 0, 0, 0, YES),
      NSBackgroundColorAttributeName: terminalColor(0, 0, 0, 0, 0, NO)
    }];
  for (uint32_t index = 0; index < g_terminal_run_count; index++) {
    NimculusTerminalRun run = g_terminal_runs[index];
    NSUInteger start = utf16OffsetForUTF8Bytes(g_terminal_text, run.start_byte);
    NSUInteger end = utf16OffsetForUTF8Bytes(g_terminal_text, run.end_byte);
    if (end <= start || start >= attributed.length) continue;
    end = MIN(end, attributed.length);
    NSColor *foreground = terminalColor(run.foreground_kind, run.foreground_index,
      run.foreground_red, run.foreground_green, run.foreground_blue, YES);
    NSColor *background = terminalColor(run.background_kind, run.background_index,
      run.background_red, run.background_green, run.background_blue, NO);
    if (run.flags & 16) { NSColor *swap = foreground; foreground = background; background = swap; }
    NSFont *font = [NSFont fontWithName:@"Menlo" size:12.0] ?: [NSFont monospacedSystemFontOfSize:12.0 weight:NSFontWeightRegular];
    if (run.flags & 1) font = [NSFont fontWithName:@"Menlo-Bold" size:12.0] ?: font;
    if (run.flags & 4) font = [NSFont fontWithName:@"Menlo-Italic" size:12.0] ?: font;
    NSRange range = NSMakeRange(start, end - start);
    [attributed addAttribute:NSFontAttributeName value:font range:range];
    [attributed addAttribute:NSForegroundColorAttributeName value:foreground range:range];
    [attributed addAttribute:NSBackgroundColorAttributeName value:background range:range];
    if (run.flags & 8) [attributed addAttribute:NSUnderlineStyleAttributeName value:@(NSUnderlineStyleSingle) range:range];
    if (run.flags & 32) [attributed addAttribute:NSStrikethroughStyleAttributeName value:@(NSUnderlineStyleSingle) range:range];
    if (run.flags & 2) [attributed addAttribute:NSForegroundColorAttributeName value:[foreground colorWithAlphaComponent:0.65] range:range];
    if (g_terminal_hyperlinks && index < g_terminal_hyperlinks.count) {
      NSString *hyperlink = g_terminal_hyperlinks[index];
      if (hyperlink.length > 0) {
        [attributed addAttribute:NSLinkAttributeName value:hyperlink range:range];
        [attributed addAttribute:NSUnderlineStyleAttributeName value:@(NSUnderlineStyleSingle) range:range];
      }
    }
  }
  [terminal.textStorage setAttributedString:attributed];
  applyTerminalSelection(terminal);
}

@implementation NimculusMetalView

+ (Class)layerClass { return [CAMetalLayer class]; }

- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    self.wantsLayer = YES;
    self.metalLayer = [CAMetalLayer layer];
    self.layer = self.metalLayer;
    self.metalLayer.device = MTLCreateSystemDefaultDevice();
    self.metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    // The retained scene is copied into each newly acquired drawable.
    self.metalLayer.framebufferOnly = NO;
    self.markedText = @"";
    self.markedTextRange = NSMakeRange(NSNotFound, 0);
    self.selectedTextRange = NSMakeRange(0, 0);
    NimculusTerminalOverlay *terminal = [[NimculusTerminalOverlay alloc]
      initWithFrame:NSZeroRect];
    terminal.editable = NO;
    // Allow programmatic selection highlighting while hitTest:/first-responder
    // remain disabled so PTY keyboard input stays owned by the Metal view.
    terminal.selectable = YES;
    terminal.drawsBackground = YES;
    terminal.backgroundColor = [themeHexColor(g_theme_background,
      [NSColor colorWithCalibratedRed:0.025 green:0.030 blue:0.045 alpha:1.0]) colorWithAlphaComponent:0.98];
    terminal.textColor = themeHexColor(g_theme_foreground,
      [NSColor colorWithCalibratedRed:0.82 green:0.88 blue:0.92 alpha:1.0]);
    terminal.font = [NSFont fontWithName:@"Menlo" size:12.0] ?: [NSFont monospacedSystemFontOfSize:12.0 weight:NSFontWeightRegular];
    terminal.textContainerInset = NSMakeSize(8.0, 6.0);
    terminal.hidden = YES;
    [self addSubview:terminal];
    NimculusTaskOutputOverlay *taskOutput = [[NimculusTaskOutputOverlay alloc]
      initWithFrame:NSZeroRect];
    taskOutput.editable = NO;
    taskOutput.selectable = YES;
    taskOutput.drawsBackground = YES;
    taskOutput.backgroundColor = [NSColor colorWithCalibratedRed:0.045 green:0.040 blue:0.030 alpha:0.98];
    taskOutput.textColor = [NSColor colorWithCalibratedRed:0.92 green:0.88 blue:0.76 alpha:1.0];
    taskOutput.font = [NSFont fontWithName:@"Menlo" size:12.0] ?: [NSFont monospacedSystemFontOfSize:12.0 weight:NSFontWeightRegular];
    taskOutput.textContainerInset = NSMakeSize(8.0, 6.0);
    taskOutput.hidden = YES;
    [self addSubview:taskOutput];
    [self updateTrackingAreas];
  }
  return self;
}

- (BOOL)acceptsFirstResponder { return YES; }

- (void)updateTrackingAreas {
  if (self.trackingArea) [self removeTrackingArea:self.trackingArea];
  self.trackingArea = [[NSTrackingArea alloc]
    initWithRect:NSZeroRect
    options:(NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
             NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect)
    owner:self userInfo:nil];
  [self addTrackingArea:self.trackingArea];
  [super updateTrackingAreas];
}

- (void)updateMetrics {
  CGFloat scale = self.window.backingScaleFactor ?: 1.0;
  NSRect bounds = self.bounds;
  CGSize drawable = self.metalLayer.drawableSize;
  g_metrics.scale_factor = scale;
  g_metrics.width_points = (uint32_t)MAX(0, bounds.size.width);
  g_metrics.height_points = (uint32_t)MAX(0, bounds.size.height);
  g_metrics.width_pixels = (uint32_t)MAX(0, drawable.width);
  g_metrics.height_pixels = (uint32_t)MAX(0, drawable.height);
  if (g_command_callback &&
      (g_last_width_points != g_metrics.width_points ||
       g_last_height_points != g_metrics.height_points)) {
    g_last_width_points = g_metrics.width_points;
    g_last_height_points = g_metrics.height_points;
    g_command_callback("windowResized");
  }
}

- (void)layout {
  [super layout];
  [self updateBackingScale];
}

- (void)updateBackingScale {
  CGFloat scale = self.window.backingScaleFactor ?: 1.0;
  self.metalLayer.contentsScale = scale;
  self.metalLayer.drawableSize = CGSizeMake(self.bounds.size.width * scale,
                                            self.bounds.size.height * scale);
  [self updateMetrics];
  [self updateTerminalFrame];
  if (g_queue && fabs(g_text_texture_scale - g_metrics.scale_factor) > 0.001) {
    updateEditorTextTexture(g_queue.device, g_editor_text, YES);
  }
  [self drawFrame];
}

- (void)updateTerminalFrame {
  NimculusTerminalOverlay *terminal = nil;
  NimculusTaskOutputOverlay *taskOutput = nil;
  for (NSView *subview in self.subviews) {
    if ([subview isKindOfClass:[NimculusTerminalOverlay class]]) terminal = (NimculusTerminalOverlay *)subview;
    if ([subview isKindOfClass:[NimculusTaskOutputOverlay class]]) taskOutput = (NimculusTaskOutputOverlay *)subview;
  }
  if (!terminal || !taskOutput) return;
  BOOL panelVisible = g_terminal_visible || g_task_output_visible;
  CGFloat height = panelVisible ? MIN(180.0, MAX(72.0, g_editor_rect[3] * 0.42)) : 0.0;
  terminal.hidden = !g_terminal_visible;
  taskOutput.hidden = !g_task_output_visible;
  if (!g_terminal_visible && !g_task_output_visible) return;
  CGFloat y = self.bounds.size.height - g_editor_rect[1] - height;
  terminal.frame = NSMakeRect(g_editor_rect[0], y, g_editor_rect[2], height);
  taskOutput.frame = NSMakeRect(g_editor_rect[0], y, g_editor_rect[2], height);
  terminal.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
  taskOutput.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
}

- (void)viewDidChangeBackingProperties {
  [super viewDidChangeBackingProperties];
  // Moving a window between Retina and non-Retina screens does not require a
  // bounds/layout change. AppKit reports that transition here; update the
  // drawable and Core Text texture just as Zed updates its window scale
  // factor in its backing-properties callback.
  [self updateBackingScale];
}

- (void)drawFrame {
  uint64_t start = mach_absolute_time();
  id<CAMetalDrawable> drawable = [self.metalLayer nextDrawable];
  if (!drawable || !g_queue) return;
  id<MTLCommandBuffer> command = [g_queue commandBuffer];
  CGSize drawableSize = CGSizeMake(drawable.texture.width, drawable.texture.height);
  id<MTLTexture> scene = sceneTextureForDevice(drawable.texture.device, drawableSize);
  if (!scene) return;
  if (g_scene_dirty || !g_scene_initialized) {
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = scene;
    pass.colorAttachments[0].loadAction = g_scene_initialized ? MTLLoadActionLoad : MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0.055, 0.067, 0.090, 1.0);
    id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
    CGSize logicalSize = self.bounds.size;
    CGSize drawableSize = CGSizeMake(scene.width, scene.height);
    if (g_pipeline) {
      [encoder setRenderPipelineState:g_pipeline];
      if (!g_scene_initialized || g_paint_dirty_count == 0) {
        NimculusPaintRegion full = {0, 0, (float)logicalSize.width, (float)logicalSize.height};
        setScissorForRegion(encoder, full, logicalSize, drawableSize);
        drawColoredRectangle(encoder, drawable.texture.device, logicalSize, 0, 0,
          logicalSize.width, logicalSize.height, 0.055f, 0.067f, 0.090f, 1.0f);
      } else {
        for (uint32_t i = 0; i < g_paint_dirty_count; i++) {
          NimculusPaintRegion region = g_paint_dirty_regions[i];
          setScissorForRegion(encoder, region, logicalSize, drawableSize);
          drawColoredRectangle(encoder, drawable.texture.device, logicalSize,
            region.x, region.y, region.width, region.height,
            0.055f, 0.067f, 0.090f, 1.0f);
        }
      }
      if (g_paint_dirty_count == 0) {
        MTLScissorRect fullScissor = {0, 0, scene.width, scene.height};
        [encoder setScissorRect:fullScissor];
        for (uint32_t i = 0; i < g_paint_count; i++) {
          NimculusPaintCommand paint = g_paint_commands[i];
          NimculusPaintRegion clip = {paint.clip_x, paint.clip_y,
                                      paint.clip_width, paint.clip_height};
          setScissorForRegion(encoder, clip, logicalSize, drawableSize);
          drawPaintCommand(encoder, drawable.texture.device, logicalSize, paint);
        }
      } else {
        // Retained scene pixels outside the damage regions stay intact. Each
        // command is therefore clipped to dirty ∩ command clip, matching the
        // damage/scissor boundary used by Zed's renderer.
        for (uint32_t dirtyIndex = 0; dirtyIndex < g_paint_dirty_count; dirtyIndex++) {
          NimculusPaintRegion dirty = g_paint_dirty_regions[dirtyIndex];
          for (uint32_t i = 0; i < g_paint_count; i++) {
            NimculusPaintCommand paint = g_paint_commands[i];
            NimculusPaintRegion clip = {paint.clip_x, paint.clip_y,
                                        paint.clip_width, paint.clip_height};
            NimculusPaintRegion visible = intersectPaintRegions(dirty, clip);
            if (visible.width <= 0 || visible.height <= 0) continue;
            setScissorForRegion(encoder, visible, logicalSize, drawableSize);
            drawPaintCommand(encoder, drawable.texture.device, logicalSize, paint);
          }
        }
      }
      if (g_paint_count == 0) {
        NimculusPaintRegion full = {g_ui_rect[0], g_ui_rect[1], g_ui_rect[2], g_ui_rect[3]};
        setScissorForRegion(encoder, full, logicalSize, drawableSize);
        drawColoredRectangle(encoder, drawable.texture.device, logicalSize,
          g_ui_rect[0], g_ui_rect[1], g_ui_rect[2], g_ui_rect[3],
          0.15f, 0.48f, 0.92f, 1.0f);
      }
    }
    if (g_glyph_pipeline && g_glyph_atlas_texture && g_glyph_vertex_count > 0) {
      id<MTLBuffer> glyphBuffer = [drawable.texture.device newBufferWithBytes:g_glyph_vertices
        length:sizeof(NimculusGlyphVertex) * g_glyph_vertex_count
        options:MTLResourceStorageModeShared];
      [encoder setRenderPipelineState:g_glyph_pipeline];
      [encoder setVertexBuffer:glyphBuffer offset:0 atIndex:0];
      [encoder setFragmentTexture:g_glyph_atlas_texture atIndex:0];
      if (g_paint_dirty_count == 0) {
        MTLScissorRect fullScissor = {0, 0, scene.width, scene.height};
        [encoder setScissorRect:fullScissor];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0
          vertexCount:g_glyph_vertex_count];
      } else {
        for (uint32_t i = 0; i < g_paint_dirty_count; i++) {
          setScissorForRegion(encoder, g_paint_dirty_regions[i], logicalSize, drawableSize);
          [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0
            vertexCount:g_glyph_vertex_count];
        }
      }
    }
    if (g_text_pipeline && g_text_texture) {
      const float left = (float)(g_editor_rect[0] / logicalSize.width * 2.0 - 1.0);
      const float right = (float)((g_editor_rect[0] + g_editor_rect[2]) / logicalSize.width * 2.0 - 1.0);
      const float top = (float)(1.0 - g_editor_rect[1] / logicalSize.height * 2.0);
      const float bottom = (float)(1.0 - (g_editor_rect[1] + g_editor_rect[3]) / logicalSize.height * 2.0);
      const float textVertices[] = {
        left, top, 0.0f, 0.0f,
        right, top, 1.0f, 0.0f,
        left, bottom, 0.0f, 1.0f,
        right, bottom, 1.0f, 1.0f,
      };
      id<MTLBuffer> textBuffer = [drawable.texture.device newBufferWithBytes:textVertices
        length:sizeof(textVertices) options:MTLResourceStorageModeShared];
      [encoder setRenderPipelineState:g_text_pipeline];
      [encoder setVertexBuffer:textBuffer offset:0 atIndex:0];
      [encoder setFragmentTexture:g_text_texture atIndex:0];
      if (g_paint_dirty_count == 0) {
        MTLScissorRect fullScissor = {0, 0, scene.width, scene.height};
        [encoder setScissorRect:fullScissor];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
      } else {
        for (uint32_t i = 0; i < g_paint_dirty_count; i++) {
          setScissorForRegion(encoder, g_paint_dirty_regions[i], logicalSize, drawableSize);
          [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        }
      }
    }
    [encoder endEncoding];
    g_scene_initialized = YES;
    g_scene_dirty = NO;
    free(g_paint_dirty_regions);
    g_paint_dirty_regions = NULL;
    g_paint_dirty_count = 0;
  }
  id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
  [blit copyFromTexture:scene sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
    sourceSize:MTLSizeMake(scene.width, scene.height, 1) toTexture:drawable.texture
    destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
  [blit endEncoding];
  [command presentDrawable:drawable];
  [command commit];
  g_metrics.last_frame_time_ms = millisecondsSince(start);
  g_metrics.frame_count++;
}

- (void)keyDown:(NSEvent *)event {
  if (logInput(@"keyDown", event)) return;
  [self interpretKeyEvents:@[event]];
}
- (void)keyUp:(NSEvent *)event { logInput(@"keyUp", event); }
- (void)flagsChanged:(NSEvent *)event { logInput(@"flagsChanged", event); }
- (void)mouseDown:(NSEvent *)event { logInput(@"mouseDown", event); }
- (void)mouseUp:(NSEvent *)event { logInput(@"mouseUp", event); }
- (void)mouseMoved:(NSEvent *)event { logInput(@"mouseMoved", event); }
- (void)mouseDragged:(NSEvent *)event { logInput(@"mouseDragged", event); }
- (void)rightMouseDragged:(NSEvent *)event { logInput(@"rightMouseDragged", event); }
- (void)rightMouseDown:(NSEvent *)event { logInput(@"rightMouseDown", event); }
- (void)rightMouseUp:(NSEvent *)event { logInput(@"rightMouseUp", event); }
- (void)otherMouseDown:(NSEvent *)event { logInput(@"otherMouseDown", event); }
- (void)otherMouseUp:(NSEvent *)event { logInput(@"otherMouseUp", event); }
- (void)otherMouseDragged:(NSEvent *)event { logInput(@"otherMouseDragged", event); }
- (void)scrollWheel:(NSEvent *)event { logInput(@"scrollWheel", event); }
- (void)mouseEntered:(NSEvent *)event { logInput(@"mouseEntered", event); }
- (void)mouseExited:(NSEvent *)event { logInput(@"mouseExited", event); }
- (BOOL)becomeFirstResponder {
  NSLog(@"Nimculus focus gained");
  return [super becomeFirstResponder];
}
- (BOOL)resignFirstResponder {
  NSLog(@"Nimculus focus lost");
  return [super resignFirstResponder];
}
- (void)viewDidMoveToWindow {
  [self.window makeFirstResponder:self];
  // The first window attachment can occur before a layout callback. Initialize
  // the drawable size and backing scale here as well as in layout, matching
  // the later Retina-transition path.
  [self updateBackingScale];
}

// NSTextInputClient: composition is forwarded to the application editor while
// committed text remains separate until insertText is received.
- (BOOL)hasMarkedText { return self.markedText.length > 0; }
- (NSRange)markedRange { return self.markedTextRange; }
- (NSRange)selectedRange {
  return self.selectedTextRange;
}
- (NSArray<NSAttributedStringKey> *)validAttributesForMarkedText { return @[]; }
- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range
                                                     actualRange:(NSRangePointer)actualRange {
  NSString *text = g_editor_text ?: @"";
  NSRange actual = boundedDocumentRange(range, text.length);
  if (actualRange) *actualRange = actual;
  return [[NSAttributedString alloc] initWithString:[text substringWithRange:actual]];
}
- (NSAttributedString *)attributedString {
  // This optional NSTextInputClient method describes the committed document,
  // not the transient marked composition. Zed does not register the optional
  // selector, but since Nimculus exposes it, return the actual document.
  return [[NSAttributedString alloc] initWithString:g_editor_text ?: @""];
}
- (void)setMarkedText:(id)string selectedRange:(NSRange)selectedRange
      replacementRange:(NSRange)replacementRange {
  if ([string isKindOfClass:[NSAttributedString class]]) {
    self.markedText = [string string];
  } else if ([string isKindOfClass:[NSString class]]) {
    self.markedText = string;
  } else {
    self.markedText = @"";
  }
  // NSTextInputClient supplies UTF-16 document ranges. Zed forwards the
  // replacement range to its InputHandler instead of assuming it equals the
  // current selection; do the same at the Cocoa/Nim boundary.
  NSRange effectiveReplacement = replacementRange.location == NSNotFound
    ? NSMakeRange(g_editor_selection_start,
                  g_editor_selection_end - g_editor_selection_start)
    : replacementRange;
  NSUInteger textLength = g_editor_text.length;
  NSRange boundedReplacement = boundedDocumentRange(effectiveReplacement, textLength);
  NSUInteger replacementStart = boundedReplacement.location;
  NSUInteger replacementEnd = NSMaxRange(boundedReplacement);
  uint32_t startByte = (uint32_t)utf8BytesForDocumentUTF16Offset(g_editor_text, replacementStart);
  uint32_t endByte = (uint32_t)utf8BytesForDocumentUTF16Offset(g_editor_text, replacementEnd);
  if (g_selection_callback) g_selection_callback(startByte, endByte);
  self.markedTextRange = NSMakeRange(replacementStart, self.markedText.length);
  NSUInteger markedSelection = MIN(selectedRange.location, self.markedText.length);
  markedSelection = self.markedTextRange.location + markedSelection;
  self.selectedTextRange = NSMakeRange(markedSelection,
                                       MIN(selectedRange.length,
                                           self.markedText.length - (markedSelection - self.markedTextRange.location)));
  if (g_text_callback) g_text_callback(self.markedText.UTF8String, true);
}
- (void)unmarkText {
  self.markedText = @"";
  self.markedTextRange = NSMakeRange(NSNotFound, 0);
  // AppKit can cancel composition without calling insertText:. Mirror Zed's
  // InputHandler::unmark_text contract so the Nim-side composition state is
  // cleared as well as the native marked-text surface.
  if (g_text_callback) g_text_callback("", true);
}
- (void)insertText:(id)string replacementRange:(NSRange)replacementRange {
  NSString *committed = [string isKindOfClass:[NSAttributedString class]]
    ? [string string] : (NSString *)string;
  if (replacementRange.location != NSNotFound && g_selection_callback) {
    NSUInteger textLength = g_editor_text.length;
    NSRange boundedReplacement = boundedDocumentRange(replacementRange, textLength);
    NSUInteger startUnit = boundedReplacement.location;
    NSUInteger endUnit = NSMaxRange(boundedReplacement);
    uint32_t startByte = (uint32_t)utf8BytesForDocumentUTF16Offset(g_editor_text, startUnit);
    uint32_t endByte = (uint32_t)utf8BytesForDocumentUTF16Offset(g_editor_text, endUnit);
    // NSTextInputClient may commit text with a replacement range even when
    // no preceding marked-text update selected it. Preserve Zed's
    // insert_text(range) contract at the Nim boundary.
    g_selection_callback(startByte, endByte);
  }
  if (g_text_callback) g_text_callback(committed.UTF8String, false);
  [self unmarkText];
}
- (void)doCommandBySelector:(SEL)selector {
  NSString *name = NSStringFromSelector(selector);
  if ([name isEqualToString:@"moveLeft:"]) { if (g_command_callback) g_command_callback("moveLeft"); }
  else if ([name isEqualToString:@"moveRight:"]) { if (g_command_callback) g_command_callback("moveRight"); }
  else if ([name isEqualToString:@"moveUp:"]) { if (g_command_callback) g_command_callback("moveUp"); }
  else if ([name isEqualToString:@"moveDown:"]) { if (g_command_callback) g_command_callback("moveDown"); }
  else if ([name isEqualToString:@"moveLeftAndModifySelection:"]) { if (g_command_callback) g_command_callback("selectLeft"); }
  else if ([name isEqualToString:@"moveRightAndModifySelection:"]) { if (g_command_callback) g_command_callback("selectRight"); }
  else if ([name isEqualToString:@"moveUpAndModifySelection:"]) { if (g_command_callback) g_command_callback("selectUp"); }
  else if ([name isEqualToString:@"moveDownAndModifySelection:"]) { if (g_command_callback) g_command_callback("selectDown"); }
  else if ([name isEqualToString:@"moveToBeginningOfLine:"]) { if (g_command_callback) g_command_callback("moveToBeginningOfLine"); }
  else if ([name isEqualToString:@"moveToEndOfLine:"]) { if (g_command_callback) g_command_callback("moveToEndOfLine"); }
  else if ([name isEqualToString:@"moveToBeginningOfLineAndModifySelection:"]) { if (g_command_callback) g_command_callback("selectToBeginningOfLine"); }
  else if ([name isEqualToString:@"moveToEndOfLineAndModifySelection:"]) { if (g_command_callback) g_command_callback("selectToEndOfLine"); }
  else if ([name isEqualToString:@"moveToBeginningOfDocument:"]) { if (g_command_callback) g_command_callback("moveToBeginningOfDocument"); }
  else if ([name isEqualToString:@"moveToEndOfDocument:"]) { if (g_command_callback) g_command_callback("moveToEndOfDocument"); }
  else if ([name isEqualToString:@"insertNewline:"]) { if (g_command_callback) g_command_callback("insertNewline"); }
  else if ([name isEqualToString:@"insertTab:"]) { if (g_command_callback) g_command_callback("insertTab"); }
  else if ([name isEqualToString:@"moveWordLeft:"]) { if (g_command_callback) g_command_callback("moveWordLeft"); }
  else if ([name isEqualToString:@"moveWordRight:"]) { if (g_command_callback) g_command_callback("moveWordRight"); }
  else if ([name isEqualToString:@"moveWordLeftAndModifySelection:"]) { if (g_command_callback) g_command_callback("selectWordLeft"); }
  else if ([name isEqualToString:@"moveWordRightAndModifySelection:"]) { if (g_command_callback) g_command_callback("selectWordRight"); }
  else if ([name isEqualToString:@"deleteBackward:"]) { if (g_command_callback) g_command_callback("deleteBackward"); }
  else if ([name isEqualToString:@"deleteForward:"]) { if (g_command_callback) g_command_callback("deleteForward"); }
  else if ([name isEqualToString:@"deleteWordBackward:"]) { if (g_command_callback) g_command_callback("deleteWordBackward"); }
  else if ([name isEqualToString:@"cancelOperation:"]) { if (g_command_callback) g_command_callback("cancel"); }
}
- (void)undo:(id)sender { if (g_command_callback) g_command_callback("undo"); }
- (void)redo:(id)sender { if (g_command_callback) g_command_callback("redo"); }
- (void)cut:(id)sender { if (g_command_callback) g_command_callback("cut"); }
- (void)copy:(id)sender { if (g_command_callback) g_command_callback("copy"); }
- (void)paste:(id)sender { if (g_command_callback) g_command_callback("paste"); }
- (void)selectAll:(id)sender { if (g_command_callback) g_command_callback("selectAll"); }
- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
  NSUInteger documentLength = g_editor_text.length;
  NSUInteger start = MIN(range.location, documentLength);
  NSUInteger length = MIN(range.length, documentLength - start);
  if (actualRange) *actualRange = NSMakeRange(start, length);
  // The editor keeps cursor Y in top-origin logical coordinates, while NSView
  // uses a bottom-origin coordinate system for this protocol callback.
  CGFloat lineHeight = 18.0;
  CGPoint logical = editorPointForUTF16Offset(start);
  CGFloat viewY = self.bounds.size.height - g_editor_rect[1] - logical.y - lineHeight;
  NSRect cursor = NSMakeRect(g_editor_rect[0] + logical.x, MAX(0.0, viewY), 0, lineHeight);
  return [self.window convertRectToScreen:[self convertRect:cursor toView:nil]];
}
- (NSUInteger)characterIndexForPoint:(NSPoint)point {
  // NSTextInputClient supplies this point in screen coordinates. Convert it
  // through the window before handing it to the view-local editor hit-test;
  // treating screen coordinates as window coordinates breaks on any window
  // that is not positioned at the screen origin (the same conversion Zed uses
  // in screen_point_to_gpui_point).
  NSPoint windowPoint = self.window ? [self.window convertScreenToBase:point] : point;
  NSPoint viewPoint = [self convertPoint:windowPoint fromView:nil];
  return nimculus_platform_editor_utf16_offset_at_point(viewPoint.x, viewPoint.y);
}
- (CGFloat)baselineDeltaForCharacterAtIndex:(NSUInteger)index { return 18.0; }
- (BOOL)drawsVerticallyForCharacterAtIndex:(NSUInteger)index { return NO; }
- (CGFloat)fractionOfDistanceThroughGlyphForPoint:(NSPoint)point {
  NSPoint windowPoint = self.window ? [self.window convertScreenToBase:point] : point;
  NSPoint viewPoint = [self convertPoint:windowPoint fromView:nil];
  NSArray<NSString *> *lines = [g_editor_text componentsSeparatedByString:@"\n"];
  if (lines.count == 0) return 0.0;
  CGFloat fromTop = self.bounds.size.height - viewPoint.y - g_editor_rect[1];
  NSInteger lineIndex = MAX(0, (NSInteger)floor((fromTop - 4.0) / 18.0));
  lineIndex = MIN(lineIndex + (NSInteger)g_editor_scroll_line, (NSInteger)lines.count - 1);
  NSString *lineText = lines[(NSUInteger)lineIndex];
  CTFontRef font = editorFont();
  if (!font) return 0.0;
  NSDictionary *attributes = @{ (id)kCTFontAttributeName: (__bridge id)font };
  NSAttributedString *attributed = [[NSAttributedString alloc]
    initWithString:lineText attributes:attributes];
  CTLineRef ctLine = CTLineCreateWithAttributedString((CFAttributedStringRef)attributed);
  CGFloat textX = MAX(0.0, viewPoint.x - g_editor_rect[0] - 8.0);
  CFIndex index = CTLineGetStringIndexForPosition(ctLine, CGPointMake(textX, 0.0));
  if (index == kCFNotFound) index = (CFIndex)lineText.length;
  CGFloat left = CTLineGetOffsetForStringIndex(ctLine, index, NULL);
  CFIndex next = MIN(index + 1, (CFIndex)lineText.length);
  CGFloat right = CTLineGetOffsetForStringIndex(ctLine, next, NULL);
  CGFloat width = right - left;
  CGFloat fraction = width > 0.0 ? (textX - left) / width : 0.0;
  CFRelease(ctLine);
  CFRelease(font);
  return MIN(1.0, MAX(0.0, fraction));
}

@end

@interface NimculusAppDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) NimculusMetalView *view;
@property(nonatomic, strong) NSTimer *workspaceSearchTimer;
@end

@implementation NimculusAppDelegate

- (void)applicationDidResignActive:(NSNotification *)notification {
  (void)notification;
  if (g_command_callback) g_command_callback("windowFocusLost");
}

- (BOOL)confirmClose {
  if (!g_editor_dirty) return YES;
  g_close_decision = NO;
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = @"Unsaved Changes";
  alert.informativeText = @"The current document has unsaved changes.";
  [alert addButtonWithTitle:@"Save"];
  [alert addButtonWithTitle:@"Don’t Save"];
  [alert addButtonWithTitle:@"Cancel"];
  NSInteger response = [alert runModal];
  if (response == NSAlertSecondButtonReturn) {
    g_close_decision = YES;
    if (g_command_callback) g_command_callback("discardSession");
  } else if (response == NSAlertFirstButtonReturn && g_command_callback) {
    g_command_callback("saveAndClose");
  }
  return g_close_decision;
}

- (BOOL)windowShouldClose:(NSWindow *)window {
  (void)window;
  if (g_command_callback) {
    g_command_callback("quitRequest");
    return NO;
  }
  return [self confirmClose];
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)application {
  (void)application;
  if (g_terminate_decision) {
    g_terminate_decision = NO;
    return NSTerminateNow;
  }
  if (g_command_callback) {
    g_command_callback("quitRequest");
    return NSTerminateCancel;
  }
  return [self confirmClose] ? NSTerminateNow : NSTerminateCancel;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
  (void)notification;
  if (g_command_callback) g_command_callback("saveSession");
}

- (void)setupMainMenu {
  NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@"MainMenu"];
  NSMenuItem *appItem = [[NSMenuItem alloc] initWithTitle:@"Nimculus" action:NULL keyEquivalent:@""];
  NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"Nimculus"];
  NSMenuItem *settings = [[NSMenuItem alloc] initWithTitle:@"Settings…"
    action:@selector(openSettings:) keyEquivalent:@","];
  settings.keyEquivalentModifierMask = NSEventModifierFlagCommand;
  [appMenu addItem:settings];
  [appMenu addItem:[NSMenuItem separatorItem]];
  [appMenu addItem:[[NSMenuItem alloc] initWithTitle:@"Quit Nimculus" action:@selector(terminate:) keyEquivalent:@"q"]];
  [appItem setSubmenu:appMenu];
  [mainMenu addItem:appItem];

  NSMenuItem *fileItem = [[NSMenuItem alloc] initWithTitle:@"File" action:NULL keyEquivalent:@""];
  NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
  NSMenuItem *newDocument = [[NSMenuItem alloc] initWithTitle:@"New" action:@selector(newDocument:) keyEquivalent:@"n"];
  NSMenuItem *open = [[NSMenuItem alloc] initWithTitle:@"Open…" action:@selector(openDocument:) keyEquivalent:@"o"];
  NSMenuItem *save = [[NSMenuItem alloc] initWithTitle:@"Save" action:@selector(saveDocument:) keyEquivalent:@"s"];
  NSMenuItem *close = [[NSMenuItem alloc] initWithTitle:@"Close Tab" action:@selector(closeDocument:) keyEquivalent:@"w"];
  newDocument.keyEquivalentModifierMask = NSEventModifierFlagCommand;
  open.keyEquivalentModifierMask = NSEventModifierFlagCommand;
  save.keyEquivalentModifierMask = NSEventModifierFlagCommand;
  close.keyEquivalentModifierMask = NSEventModifierFlagCommand;
  [fileMenu addItem:newDocument]; [fileMenu addItem:open]; [fileMenu addItem:save]; [fileMenu addItem:close];
  [fileMenu addItem:[[NSMenuItem alloc] initWithTitle:@"Open Recent…"
    action:@selector(openRecent:) keyEquivalent:@""]];
  [fileMenu addItem:[[NSMenuItem alloc] initWithTitle:@"Add Workspace Folder…"
    action:@selector(addWorkspaceFolder:) keyEquivalent:@""]];
  NSMenuItem *quickOpen = [[NSMenuItem alloc] initWithTitle:@"Quick Open…"
    action:@selector(quickOpen:) keyEquivalent:@"p"];
  quickOpen.keyEquivalentModifierMask = NSEventModifierFlagCommand;
  [fileMenu addItem:quickOpen];
  [fileMenu addItem:[NSMenuItem separatorItem]];
  [fileMenu addItem:[[NSMenuItem alloc] initWithTitle:@"New File…"
    action:@selector(createWorkspaceFile:) keyEquivalent:@""]];
  [fileMenu addItem:[[NSMenuItem alloc] initWithTitle:@"New Folder…"
    action:@selector(createWorkspaceDirectory:) keyEquivalent:@""]];
  [fileMenu addItem:[[NSMenuItem alloc] initWithTitle:@"Rename Workspace Entry…"
    action:@selector(renameWorkspaceEntry:) keyEquivalent:@""]];
  [fileMenu addItem:[[NSMenuItem alloc] initWithTitle:@"Delete Workspace Entry…"
    action:@selector(deleteWorkspaceEntry:) keyEquivalent:@""]];
  [fileItem setSubmenu:fileMenu];
  [mainMenu addItem:fileItem];

  NSMenuItem *editItem = [[NSMenuItem alloc] initWithTitle:@"Edit" action:NULL keyEquivalent:@""];
  NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
  [editMenu addItem:[[NSMenuItem alloc] initWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"]];
  [editMenu addItem:[[NSMenuItem alloc] initWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@"Z"]];
  [editMenu addItem:[NSMenuItem separatorItem]];
  [editMenu addItem:[[NSMenuItem alloc] initWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"]];
  [editMenu addItem:[[NSMenuItem alloc] initWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"]];
  [editMenu addItem:[[NSMenuItem alloc] initWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"]];
  [editMenu addItem:[[NSMenuItem alloc] initWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"]];
  NSMenuItem *findDocument = [[NSMenuItem alloc] initWithTitle:@"Find…"
    action:@selector(findInDocument:) keyEquivalent:@"f"];
  findDocument.keyEquivalentModifierMask = NSEventModifierFlagCommand;
  [editMenu addItem:findDocument];
  NSMenuItem *replaceDocument = [[NSMenuItem alloc] initWithTitle:@"Replace…"
    action:@selector(replaceInDocument:) keyEquivalent:@""];
  [editMenu addItem:replaceDocument];
  NSMenuItem *goToLine = [[NSMenuItem alloc] initWithTitle:@"Go to Line…"
    action:@selector(goToLine:) keyEquivalent:@"l"];
  goToLine.keyEquivalentModifierMask = NSEventModifierFlagCommand;
  [editMenu addItem:goToLine];
  NSMenuItem *commandPalette = [[NSMenuItem alloc] initWithTitle:@"Command Palette…"
    action:@selector(openCommandPalette:) keyEquivalent:@"p"];
  commandPalette.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
  [editMenu addItem:commandPalette];
  NSMenuItem *workspaceSearch = [[NSMenuItem alloc] initWithTitle:@"Find in Workspace…"
    action:@selector(findInWorkspace:) keyEquivalent:@"f"];
  workspaceSearch.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
  [editMenu addItem:workspaceSearch];
  NSMenuItem *cancelSearch = [[NSMenuItem alloc] initWithTitle:@"Cancel Workspace Search"
    action:@selector(cancelWorkspaceSearch:) keyEquivalent:@"."];
  cancelSearch.keyEquivalentModifierMask = NSEventModifierFlagCommand;
  [editMenu addItem:cancelSearch];
  for (NSMenuItem *item in editMenu.itemArray) {
    if (item != workspaceSearch) item.keyEquivalentModifierMask = NSEventModifierFlagCommand;
  }
  [editItem setSubmenu:editMenu];
  [mainMenu addItem:editItem];

  NSMenuItem *viewItem = [[NSMenuItem alloc] initWithTitle:@"View" action:NULL keyEquivalent:@""];
  NSMenu *viewMenu = [[NSMenu alloc] initWithTitle:@"View"];
  NSMenuItem *fullScreen = [[NSMenuItem alloc] initWithTitle:@"Enter Full Screen" action:@selector(toggleFullScreen:) keyEquivalent:@"f"];
  fullScreen.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagControl;
  [viewMenu addItem:fullScreen];
  [viewItem setSubmenu:viewMenu];
  [mainMenu addItem:viewItem];

  NSMenuItem *windowItem = [[NSMenuItem alloc] initWithTitle:@"Window" action:NULL keyEquivalent:@""];
  NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
  NSMenuItem *minimize = [[NSMenuItem alloc] initWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
  minimize.keyEquivalentModifierMask = NSEventModifierFlagCommand;
  [windowMenu addItem:minimize];
  NSMenuItem *previousTab = [[NSMenuItem alloc] initWithTitle:@"Previous Tab"
    action:@selector(previousTab:) keyEquivalent:@"["];
  previousTab.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
  [windowMenu addItem:previousTab];
  NSMenuItem *nextTab = [[NSMenuItem alloc] initWithTitle:@"Next Tab"
    action:@selector(nextTab:) keyEquivalent:@"]"];
  nextTab.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
  [windowMenu addItem:nextTab];
  [windowMenu addItem:[[NSMenuItem alloc] initWithTitle:@"Zoom" action:@selector(performZoom:) keyEquivalent:@""]];
  [windowItem setSubmenu:windowMenu];
  [mainMenu addItem:windowItem];
  [NSApp setMainMenu:mainMenu];
}

- (void)openSettings:(id)sender {
  (void)sender;
  if (g_command_callback) g_command_callback("openSettings");
}

- (void)previousTab:(id)sender {
  (void)sender;
  if (g_command_callback) g_command_callback("previousTab");
}

- (void)nextTab:(id)sender {
  (void)sender;
  if (g_command_callback) g_command_callback("nextTab");
}

- (void)findInWorkspace:(id)sender {
  (void)sender;
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = @"Find in Workspace";
  alert.informativeText = @"Enter text to search in the current workspace.";
  NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 320, 24)];
  field.placeholderString = @"Search text";
  alert.accessoryView = field;
  [alert addButtonWithTitle:@"Find"];
  [alert addButtonWithTitle:@"Cancel"];
  if ([alert runModal] == NSAlertFirstButtonReturn && g_command_callback) {
    NSString *command = [NSString stringWithFormat:@"workspaceSearch:%@", field.stringValue];
    g_command_callback(command.UTF8String);
  }
}

- (void)findInDocument:(id)sender {
  (void)sender;
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = @"Find in Document";
  NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 320, 24)];
  field.placeholderString = @"Search text";
  alert.accessoryView = field;
  [alert addButtonWithTitle:@"Find"];
  [alert addButtonWithTitle:@"Cancel"];
  if ([alert runModal] == NSAlertFirstButtonReturn && g_command_callback) {
    NSString *command = [NSString stringWithFormat:@"findDocument:%@", field.stringValue];
    g_command_callback(command.UTF8String);
  }
}

- (void)replaceInDocument:(id)sender {
  (void)sender;
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = @"Replace in Document";
  NSStackView *fields = [[NSStackView alloc] initWithFrame:NSMakeRect(0, 0, 320, 56)];
  fields.orientation = NSUserInterfaceLayoutOrientationVertical;
  fields.spacing = 8;
  NSTextField *query = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 320, 24)];
  query.placeholderString = @"Search text";
  NSTextField *replacement = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 320, 24)];
  replacement.placeholderString = @"Replacement";
  [fields addArrangedSubview:query];
  [fields addArrangedSubview:replacement];
  alert.accessoryView = fields;
  [alert addButtonWithTitle:@"Replace All"];
  [alert addButtonWithTitle:@"Cancel"];
  if ([alert runModal] == NSAlertFirstButtonReturn && g_command_callback) {
    // Unit Separator is not valid in normal text input and keeps this ABI
    // independent of colons/newlines in either field.
    NSString *command = [NSString stringWithFormat:@"replaceDocument:%@\x1f%@",
      query.stringValue, replacement.stringValue];
    g_command_callback(command.UTF8String);
  }
}

- (void)goToLine:(id)sender {
  (void)sender;
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = @"Go to Line";
  NSTextField *field = [self workspacePathField:@"Line number"];
  field.stringValue = @"1";
  alert.accessoryView = field;
  [alert addButtonWithTitle:@"Go"];
  [alert addButtonWithTitle:@"Cancel"];
  if ([alert runModal] == NSAlertFirstButtonReturn && g_command_callback) {
    NSString *command = [NSString stringWithFormat:@"goToLine:%@", field.stringValue];
    g_command_callback(command.UTF8String);
  }
}

- (void)openCommandPalette:(id)sender {
  (void)sender;
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = @"Command Palette";
  alert.informativeText = @"Available: new, save, find, workspace search, cancel search";
  NSTextField *field = [self workspacePathField:@"Command"];
  alert.accessoryView = field;
  [alert addButtonWithTitle:@"Run"];
  [alert addButtonWithTitle:@"Cancel"];
  if ([alert runModal] == NSAlertFirstButtonReturn && g_command_callback) {
    NSString *command = [NSString stringWithFormat:@"commandPalette:%@", field.stringValue];
    g_command_callback(command.UTF8String);
  }
}

- (void)cancelWorkspaceSearch:(id)sender {
  (void)sender;
  if (g_command_callback) g_command_callback("cancelWorkspaceSearch");
}

- (void)emitWorkspaceSearchTick:(NSTimer *)timer {
  (void)timer;
  if (g_idle_callback) g_idle_callback();
  if (g_command_callback) g_command_callback("workspaceSearchTick");
}

- (void)openDocument:(id)sender {
  NSOpenPanel *panel = [NSOpenPanel openPanel];
  panel.canChooseFiles = YES;
  panel.canChooseDirectories = YES;
  if ([panel runModal] == NSModalResponseOK) {
    if (g_file_callback) g_file_callback(panel.URL.path.UTF8String, false);
  }
}

- (void)openRecent:(id)sender {
  (void)sender;
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = @"Open Recent";
  if (g_recent_files.count == 0) {
    alert.informativeText = @"No recent files.";
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
    return;
  }
  NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 360, 26)
    pullsDown:NO];
  [popup addItemsWithTitles:g_recent_files];
  alert.accessoryView = popup;
  [alert addButtonWithTitle:@"Open"];
  [alert addButtonWithTitle:@"Cancel"];
  if ([alert runModal] == NSAlertFirstButtonReturn && g_file_callback) {
    NSString *path = popup.selectedItem.title;
    if (path.length > 0) g_file_callback(path.UTF8String, false);
  }
}

- (void)addWorkspaceFolder:(id)sender {
  (void)sender;
  NSOpenPanel *panel = [NSOpenPanel openPanel];
  panel.canChooseFiles = NO;
  panel.canChooseDirectories = YES;
  panel.allowsMultipleSelection = YES;
  if ([panel runModal] == NSModalResponseOK && g_command_callback) {
    for (NSURL *url in panel.URLs) {
      NSString *command = [NSString stringWithFormat:@"workspaceAddRoot:%@", url.path];
      g_command_callback(command.UTF8String);
    }
  }
}

- (void)quickOpen:(id)sender {
  (void)sender;
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = @"Quick Open";
  alert.informativeText = @"Enter part of a file name or path.";
  NSTextField *field = [self workspacePathField:@"File name"];
  alert.accessoryView = field;
  [alert addButtonWithTitle:@"Search"];
  [alert addButtonWithTitle:@"Cancel"];
  if ([alert runModal] == NSAlertFirstButtonReturn && g_command_callback) {
    NSString *command = [NSString stringWithFormat:@"quickOpen:%@", field.stringValue];
    g_command_callback(command.UTF8String);
  }
}

- (void)newDocument:(id)sender {
  (void)sender;
  if (g_command_callback) g_command_callback("newDocument");
}

- (NSTextField *)workspacePathField:(NSString *)placeholder {
  NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 320, 24)];
  field.placeholderString = placeholder;
  return field;
}

- (void)createWorkspaceFile:(id)sender {
  (void)sender;
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = @"New File";
  NSTextField *field = [self workspacePathField:@"Relative path, or absolute path in a workspace root"];
  alert.accessoryView = field;
  [alert addButtonWithTitle:@"Create"];
  [alert addButtonWithTitle:@"Cancel"];
  if ([alert runModal] == NSAlertFirstButtonReturn && g_command_callback) {
    NSString *command = [NSString stringWithFormat:@"workspaceCreateFile:%@", field.stringValue];
    g_command_callback(command.UTF8String);
  }
}

- (void)createWorkspaceDirectory:(id)sender {
  (void)sender;
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = @"New Folder";
  NSTextField *field = [self workspacePathField:@"Relative path, or absolute path in a workspace root"];
  alert.accessoryView = field;
  [alert addButtonWithTitle:@"Create"];
  [alert addButtonWithTitle:@"Cancel"];
  if ([alert runModal] == NSAlertFirstButtonReturn && g_command_callback) {
    NSString *command = [NSString stringWithFormat:@"workspaceCreateDirectory:%@", field.stringValue];
    g_command_callback(command.UTF8String);
  }
}

- (void)renameWorkspaceEntry:(id)sender {
  (void)sender;
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = @"Rename Workspace Entry";
  NSStackView *fields = [[NSStackView alloc] initWithFrame:NSMakeRect(0, 0, 320, 56)];
  fields.orientation = NSUserInterfaceLayoutOrientationVertical;
  fields.spacing = 8;
  NSTextField *oldField = [self workspacePathField:@"Existing relative or absolute path"];
  NSTextField *newField = [self workspacePathField:@"New relative or absolute path"];
  [fields addArrangedSubview:oldField];
  [fields addArrangedSubview:newField];
  alert.accessoryView = fields;
  [alert addButtonWithTitle:@"Rename"];
  [alert addButtonWithTitle:@"Cancel"];
  if ([alert runModal] == NSAlertFirstButtonReturn && g_command_callback) {
    NSString *command = [NSString stringWithFormat:@"workspaceRename:%@\x1f%@",
      oldField.stringValue, newField.stringValue];
    g_command_callback(command.UTF8String);
  }
}

- (void)deleteWorkspaceEntry:(id)sender {
  (void)sender;
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = @"Delete Workspace Entry";
  alert.informativeText = @"Deleting a directory requires it to be empty.";
  NSTextField *field = [self workspacePathField:@"Relative or absolute path in a workspace root"];
  alert.accessoryView = field;
  [alert addButtonWithTitle:@"Delete"];
  [alert addButtonWithTitle:@"Cancel"];
  alert.alertStyle = NSAlertStyleWarning;
  if ([alert runModal] == NSAlertFirstButtonReturn && g_command_callback) {
    NSString *command = [NSString stringWithFormat:@"workspaceDelete:%@", field.stringValue];
    g_command_callback(command.UTF8String);
  }
}

- (void)saveDocument:(id)sender {
  (void)sender;
  // Nim decides whether the active document already has a path. Existing
  // files must save directly on Cmd+S; only untitled documents need a panel.
  if (g_command_callback) g_command_callback("save");
}

- (void)closeDocument:(id)sender {
  (void)sender;
  if (g_command_callback) g_command_callback("closeTabRequest");
}

- (void)createTextAtlas:(id<MTLDevice>)device {
  const size_t width = 512, height = 64;
  NSMutableData *pixels = [NSMutableData dataWithLength:width * height];
  CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceGray();
  CGContextRef context = CGBitmapContextCreate(pixels.mutableBytes, width, height, 8,
    width, colorSpace, (CGBitmapInfo)kCGImageAlphaNone);
  CGColorSpaceRelease(colorSpace);
  if (!context) return;
  CGContextSetGrayFillColor(context, 1.0, 1.0);
  CTFontRef font = CTFontCreateWithName(CFSTR("Hiragino Sans"), 28.0, NULL);
  if (!font) font = CTFontCreateUIFontForLanguage(kCTFontSystemFontType, 28.0, NULL);
  NSDictionary *attributes = @{ (id)kCTFontAttributeName: (__bridge id)font };
  NSAttributedString *string = [[NSAttributedString alloc] initWithString:@"Nimculus M2/M3"
    attributes:attributes];
  CTLineRef line = CTLineCreateWithAttributedString((CFAttributedStringRef)string);
  CGContextSetTextPosition(context, 8.0, 12.0);
  CTLineDraw(line, context);
  CFRelease(line);
  CFRelease(font);
  CGContextRelease(context);

  MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
    width:width height:height mipmapped:NO];
  descriptor.usage = MTLTextureUsageShaderRead;
  g_text_texture = [device newTextureWithDescriptor:descriptor];
  [g_text_texture replaceRegion:MTLRegionMake2D(0, 0, width, height)
    mipmapLevel:0 withBytes:pixels.bytes bytesPerRow:width];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  g_queue = [device newCommandQueue];
  NSError *error = nil;
  NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "struct V { float4 pos [[position]]; float4 color; };\n"
    "struct U { float opacity; };\n"
    "vertex V vs(uint id [[vertex_id]], constant float4 *v [[buffer(0)]], constant U& u [[buffer(1)]]) { V o; o.pos=v[id*2]; o.color=v[id*2+1] * u.opacity; return o; }\n"
    "fragment float4 fs(V in [[stage_in]]) { return in.color; }\n"
    "struct TV { float4 pos [[position]]; float2 uv; };\n"
    "vertex TV textVs(uint id [[vertex_id]], constant float4 *v [[buffer(0)]]) { TV o; o.pos=float4(v[id].xy,0,1); o.uv=v[id].zw; return o; }\n"
    "fragment float4 textFs(TV in [[stage_in]], texture2d<float> atlas [[texture(0)]]) { constexpr sampler s(filter::linear); return atlas.sample(s,in.uv); }\n"
    "vertex TV imageVs(uint id [[vertex_id]], constant float4 *v [[buffer(0)]]) { TV o; o.pos=float4(v[id].xy,0,1); o.uv=v[id].zw; return o; }\n"
    "fragment float4 imageFs(TV in [[stage_in]], texture2d<float> image [[texture(0)]]) { constexpr sampler s(filter::linear, address::clamp_to_edge); return image.sample(s,in.uv); }";
  source = [source stringByAppendingString:
    @"\nstruct GV { float4 pos [[position]]; float2 uv; float4 color; };\n"
     "vertex GV glyphVs(uint id [[vertex_id]], constant float4 *v [[buffer(0)]]) { "
     "GV o; o.pos=float4(v[id*2].xy,0,1); o.uv=v[id*2].zw; o.color=v[id*2+1]; return o; }\n"
     "fragment float4 glyphFs(GV in [[stage_in]], texture2d<float> atlas [[texture(0)]]) { "
     "constexpr sampler s(filter::linear); float alpha=atlas.sample(s,in.uv).r; "
     "return float4(in.color.rgb,in.color.a*alpha); }"];
  id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
  if (library) {
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = [library newFunctionWithName:@"vs"];
    descriptor.fragmentFunction = [library newFunctionWithName:@"fs"];
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    g_pipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    MTLRenderPipelineDescriptor *textDescriptor = [MTLRenderPipelineDescriptor new];
    textDescriptor.vertexFunction = [library newFunctionWithName:@"textVs"];
    textDescriptor.fragmentFunction = [library newFunctionWithName:@"textFs"];
    textDescriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    textDescriptor.colorAttachments[0].blendingEnabled = YES;
    textDescriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    textDescriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    textDescriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    textDescriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    g_text_pipeline = [device newRenderPipelineStateWithDescriptor:textDescriptor error:&error];
    MTLRenderPipelineDescriptor *glyphDescriptor = [MTLRenderPipelineDescriptor new];
    glyphDescriptor.vertexFunction = [library newFunctionWithName:@"glyphVs"];
    glyphDescriptor.fragmentFunction = [library newFunctionWithName:@"glyphFs"];
    glyphDescriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    glyphDescriptor.colorAttachments[0].blendingEnabled = YES;
    glyphDescriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    glyphDescriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    glyphDescriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    glyphDescriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    g_glyph_pipeline = [device newRenderPipelineStateWithDescriptor:glyphDescriptor error:&error];
    MTLRenderPipelineDescriptor *imageDescriptor = [MTLRenderPipelineDescriptor new];
    imageDescriptor.vertexFunction = [library newFunctionWithName:@"imageVs"];
    imageDescriptor.fragmentFunction = [library newFunctionWithName:@"imageFs"];
    imageDescriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    imageDescriptor.colorAttachments[0].blendingEnabled = YES;
    imageDescriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    imageDescriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    imageDescriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    imageDescriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    g_image_pipeline = [device newRenderPipelineStateWithDescriptor:imageDescriptor error:&error];
    g_image_textures = [NSMutableDictionary dictionary];
    updateEditorTextTexture(device, g_editor_text, YES);
    uint8_t demoPixels[16 * 16 * 4];
    for (uint32_t y = 0; y < 16; y++) {
      for (uint32_t x = 0; x < 16; x++) {
        const BOOL alternate = ((x / 4) + (y / 4)) % 2 == 0;
        const NSUInteger offset = ((NSUInteger)y * 16 + x) * 4;
        demoPixels[offset + 0] = alternate ? 80 : 30;
        demoPixels[offset + 1] = alternate ? 180 : 90;
        demoPixels[offset + 2] = alternate ? 240 : 150;
        demoPixels[offset + 3] = 255;
      }
    }
    nimculus_platform_set_image_rgba(1, 16, 16, demoPixels, sizeof(demoPixels));
  }

  NSRect frame = NSMakeRect(0, 0, 960, 640);
  self.window = [[NSWindow alloc] initWithContentRect:frame
    styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
               NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
    backing:NSBackingStoreBuffered defer:NO];
  self.window.title = @"Nimculus";
  self.window.acceptsMouseMovedEvents = YES;
  [self setupMainMenu];
  self.view = [[NimculusMetalView alloc] initWithFrame:frame];
  g_active_view = self.view;
  self.window.contentView = self.view;
  [self.window center];
  [self.window makeKeyAndOrderFront:nil];
  self.workspaceSearchTimer = [NSTimer scheduledTimerWithTimeInterval:0.05
    target:self selector:@selector(emitWorkspaceSearchTick:) userInfo:nil repeats:YES];
}
- (void)application:(NSApplication *)application openFiles:(NSArray<NSString *> *)filenames {
  (void)application;
  for (NSString *path in filenames) {
    if (g_file_callback) g_file_callback(path.UTF8String, false);
  }
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return YES; }
@end

void nimculus_platform_show_external_change(const char *path) {
  @autoreleasepool {
    NSString *filePath = path ? [NSString stringWithUTF8String:path] : @"file";
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"File changed on disk";
    alert.informativeText = [NSString stringWithFormat:@"%@ was changed by another application.", filePath];
    [alert addButtonWithTitle:@"Reload"];
    [alert addButtonWithTitle:@"Keep Editing"];
    if ([alert runModal] == NSAlertFirstButtonReturn) {
      if (g_command_callback) g_command_callback("reloadExternal");
    } else {
      if (g_command_callback) g_command_callback("keepExternal");
    }
  }
}

void nimculus_platform_show_find_document(void) {
  id delegate = [NSApp delegate];
  if ([delegate respondsToSelector:@selector(findInDocument:)]) {
    [delegate performSelector:@selector(findInDocument:) withObject:nil];
  }
}

void nimculus_platform_show_workspace_search(void) {
  id delegate = [NSApp delegate];
  if ([delegate respondsToSelector:@selector(findInWorkspace:)]) {
    [delegate performSelector:@selector(findInWorkspace:) withObject:nil];
  }
}

void nimculus_platform_show_command_palette(void) {
  id delegate = [NSApp delegate];
  if ([delegate respondsToSelector:@selector(openCommandPalette:)]) {
    [delegate performSelector:@selector(openCommandPalette:) withObject:nil];
  }
}

bool nimculus_platform_run(void) {
  @autoreleasepool {
    NSApplication *app = [NSApplication sharedApplication];
    [app setActivationPolicy:NSApplicationActivationPolicyRegular];
    NimculusAppDelegate *delegate = [NimculusAppDelegate new];
    app.delegate = delegate;
    [app activateIgnoringOtherApps:YES];
    [app run];
  }
  return true;
}

bool nimculus_platform_validate_native(void) {
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  if (!device) return false;
  CAMetalLayer *layer = [CAMetalLayer layer];
  layer.device = device;
  layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
  layer.contentsScale = 2.0;
  layer.drawableSize = CGSizeMake(1280.0, 800.0);
  return layer.device != nil && layer.drawableSize.width == 1280.0 &&
    layer.drawableSize.height == 800.0;
}

bool nimculus_platform_validate_glyph_atlas(void) {
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  if (!device) return false;
  if (g_metrics.scale_factor <= 0.0) g_metrics.scale_factor = 2.0;
  if (g_editor_rect[2] <= 0.0) g_editor_rect[2] = 640.0;
  if (g_editor_rect[3] <= 0.0) g_editor_rect[3] = 320.0;
  NSString *sample = @"A日本語🙂";
  updateEditorGlyphAtlas(device, sample);
  if (!g_glyph_atlas_texture || g_glyph_vertex_count == 0) return false;
  uint64_t hitsBefore = g_glyph_atlas_hit_count;
  updateEditorGlyphAtlas(device, sample);
  return g_glyph_vertex_count > 0 && g_glyph_atlas_hit_count > hitsBefore;
}

void nimculus_platform_get_metrics(NimculusPlatformMetrics *metrics) {
  if (metrics) *metrics = g_metrics;
}

uint64_t nimculus_platform_input_count(void) { return g_input_count; }
void nimculus_platform_set_input_callback(NimculusInputCallback callback) { g_input_callback = callback; }
void nimculus_platform_set_shortcut_callback(NimculusShortcutCallback callback) { g_shortcut_callback = callback; }
void nimculus_platform_set_text_callback(NimculusTextCallback callback) { g_text_callback = callback; }
void nimculus_platform_set_selection_callback(NimculusSelectionCallback callback) { g_selection_callback = callback; }
void nimculus_platform_set_file_callback(NimculusFileCallback callback) { g_file_callback = callback; }
void nimculus_platform_set_command_callback(NimculusCommandCallback callback) { g_command_callback = callback; }
void nimculus_platform_set_idle_callback(NimculusIdleCallback callback) { g_idle_callback = callback; }
void nimculus_platform_set_editor_cursor(double x, double y) {
  g_editor_cursor[0] = x;
  g_editor_cursor[1] = y;
  if (g_queue) updateEditorTextTexture(g_queue.device, g_editor_text, NO);
  markSceneFullyDirty();
}
void nimculus_platform_set_editor_cursor_byte(uint32_t byte_offset, uint32_t line) {
  NSArray<NSString *> *lines = [g_editor_text componentsSeparatedByString:@"\n"];
  if (lines.count == 0) return;
  NSUInteger lineIndex = MIN((NSUInteger)line, lines.count - 1);
  NSUInteger lineStartByte = 0;
  for (NSUInteger index = 0; index < lineIndex; index++) {
    lineStartByte += [[lines[index] dataUsingEncoding:NSUTF8StringEncoding] length] + 1;
  }
  NSString *lineText = lines[lineIndex];
  NSUInteger lineLength = [[lineText dataUsingEncoding:NSUTF8StringEncoding] length];
  NSUInteger localByte = byte_offset > lineStartByte ? byte_offset - lineStartByte : 0;
  localByte = MIN(localByte, lineLength);
  NSUInteger utf16 = utf16OffsetForUTF8Bytes(lineText, localByte);
  g_editor_cursor[0] = 8.0 + editorTextOffset(lineText, utf16);
  NSUInteger visibleLine = lineIndex > g_editor_scroll_line ? lineIndex - g_editor_scroll_line : 0;
  g_editor_cursor[1] = 12.0 + visibleLine * 18.0;
  if (g_queue) updateEditorTextTexture(g_queue.device, g_editor_text, NO);
  markSceneFullyDirty();
}
void nimculus_platform_invalidate_ime_coordinates(void) {
  // Zed invalidates NSTextInputContext's cached character coordinates whenever
  // the editor cursor moves. Without this, AppKit can keep placing the IME
  // candidate window at the previous cursor position after navigation or
  // scrolling.
  NSTextInputContext *inputContext = [NSTextInputContext currentInputContext];
  if (inputContext) [inputContext invalidateCharacterCoordinates];
}
uint32_t nimculus_platform_editor_utf16_offset_at_point(double x, double y) {
  NSArray<NSString *> *lines = [g_editor_text componentsSeparatedByString:@"\n"];
  if (lines.count == 0) return 0;
  CGFloat viewHeight = g_metrics.height_points > 0 ? g_metrics.height_points : 640.0;
  CGFloat fromTop = viewHeight - y - g_editor_rect[1];
  NSInteger lineIndex = MAX(0, (NSInteger)floor((fromTop - 4.0) / 18.0));
  lineIndex = MIN(lineIndex + (NSInteger)g_editor_scroll_line, (NSInteger)lines.count - 1);
  NSString *lineText = lines[(NSUInteger)lineIndex];
  CTFontRef font = editorFont();
  if (!font) return 0;
  NSDictionary *attributes = @{ (id)kCTFontAttributeName: (__bridge id)font };
  NSAttributedString *attributed = [[NSAttributedString alloc]
    initWithString:lineText attributes:attributes];
  CTLineRef ctLine = CTLineCreateWithAttributedString((CFAttributedStringRef)attributed);
  CFIndex localIndex = CTLineGetStringIndexForPosition(ctLine,
    CGPointMake(MAX(0.0, x - g_editor_rect[0] - 8.0), 0.0));
  if (localIndex == kCFNotFound) localIndex = (CFIndex)lineText.length;
  NSUInteger documentIndex = 0;
  for (NSInteger index = 0; index < lineIndex; index++) {
    documentIndex += lines[(NSUInteger)index].length + 1;
  }
  documentIndex += MIN((NSUInteger)localIndex, lineText.length);
  CFRelease(ctLine);
  CFRelease(font);
  return (uint32_t)documentIndex;
}
uint32_t nimculus_platform_editor_byte_offset_at_point(double x, double y) {
  NSArray<NSString *> *lines = [g_editor_text componentsSeparatedByString:@"\n"];
  if (lines.count == 0) return 0;
  CGFloat viewHeight = g_metrics.height_points > 0 ? g_metrics.height_points : 640.0;
  CGFloat fromTop = viewHeight - y - g_editor_rect[1];
  NSInteger lineIndex = MAX(0, (NSInteger)floor((fromTop - 4.0) / 18.0));
  lineIndex = MIN(lineIndex + (NSInteger)g_editor_scroll_line, (NSInteger)lines.count - 1);
  NSString *lineText = lines[(NSUInteger)lineIndex];
  NSUInteger lineStartByte = 0;
  for (NSInteger index = 0; index < lineIndex; index++) {
    lineStartByte += [[lines[(NSUInteger)index] dataUsingEncoding:NSUTF8StringEncoding] length] + 1;
  }
  CTFontRef font = editorFont();
  if (!font) return (uint32_t)lineStartByte;
  NSDictionary *attributes = @{ (id)kCTFontAttributeName: (__bridge id)font };
  NSAttributedString *attributed = [[NSAttributedString alloc]
    initWithString:lineText attributes:attributes];
  CTLineRef ctLine = CTLineCreateWithAttributedString((CFAttributedStringRef)attributed);
  CGFloat textX = MAX(0.0, x - g_editor_rect[0] - 8.0);
  CFIndex utf16Index = CTLineGetStringIndexForPosition(ctLine, CGPointMake(textX, 0.0));
  if (utf16Index == kCFNotFound) utf16Index = (CFIndex)lineText.length;
  NSUInteger localByte = utf8BytesForUTF16Offset(lineText, (NSUInteger)utf16Index);
  CFRelease(ctLine);
  CFRelease(font);
  return (uint32_t)(lineStartByte + localByte);
}
void nimculus_platform_set_editor_scroll_line(uint32_t line) {
  g_editor_scroll_line = line;
  markSceneFullyDirty();
  if (g_queue) updateEditorTextTexture(g_queue.device, g_editor_text, YES);
  if (g_active_view) [(NimculusMetalView *)g_active_view drawFrame];
}
void nimculus_platform_set_editor_rect(double x, double y, double width, double height) {
  g_editor_rect[0] = MAX(0.0, x);
  g_editor_rect[1] = MAX(0.0, y);
  g_editor_rect[2] = MAX(1.0, width);
  g_editor_rect[3] = MAX(1.0, height);
  if (g_active_view) [(NimculusMetalView *)g_active_view updateTerminalFrame];
  if (g_queue) updateEditorTextTexture(g_queue.device, g_editor_text, YES);
  markSceneFullyDirty();
  if (g_active_view) [(NimculusMetalView *)g_active_view drawFrame];
}
void nimculus_platform_set_editor_dirty(bool dirty) { g_editor_dirty = dirty ? YES : NO; }
void nimculus_platform_set_close_decision(bool allow) { g_close_decision = allow ? YES : NO; }
void nimculus_platform_request_close_tab(void) {
  if (!g_editor_dirty) {
    if (g_command_callback) g_command_callback("closeTabConfirmed");
    return;
  }
  g_close_decision = NO;
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = @"Unsaved Changes";
  alert.informativeText = @"The current document has unsaved changes.";
  [alert addButtonWithTitle:@"Save"];
  [alert addButtonWithTitle:@"Don’t Save"];
  [alert addButtonWithTitle:@"Cancel"];
  NSInteger response = [alert runModal];
  if (response == NSAlertSecondButtonReturn) {
    if (g_command_callback) g_command_callback("closeTabConfirmed");
  } else if (response == NSAlertFirstButtonReturn && g_command_callback) {
    g_command_callback("saveAndCloseTab");
    if (g_close_decision) g_command_callback("closeTabConfirmed");
  }
}
void nimculus_platform_show_save_panel_and_close_tab(void) {
  g_close_decision = NO;
  NSSavePanel *panel = [NSSavePanel savePanel];
  if ([panel runModal] == NSModalResponseOK) {
    if (g_file_callback) g_file_callback(panel.URL.path.UTF8String, true);
  }
}
void nimculus_platform_confirm_quit(void);
void nimculus_platform_request_quit(void) {
  g_close_decision = NO;
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = @"Unsaved Changes";
  alert.informativeText = @"One or more tabs have unsaved changes.";
  [alert addButtonWithTitle:@"Save All"];
  [alert addButtonWithTitle:@"Don’t Save"];
  [alert addButtonWithTitle:@"Cancel"];
  NSInteger response = [alert runModal];
  if (response == NSAlertSecondButtonReturn) {
    if (g_command_callback) g_command_callback("discardAllAndQuit");
  } else if (response == NSAlertFirstButtonReturn && g_command_callback) {
    g_command_callback("saveAllAndQuit");
  }
  if (g_close_decision) nimculus_platform_confirm_quit();
}
void nimculus_platform_confirm_quit(void) {
  g_terminate_decision = YES;
  [NSApp terminate:nil];
}
void nimculus_platform_show_save_panel_and_close(void) {
  g_close_decision = NO;
  NSSavePanel *panel = [NSSavePanel savePanel];
  if ([panel runModal] == NSModalResponseOK) {
    if (g_file_callback) g_file_callback(panel.URL.path.UTF8String, true);
    // windowShouldClose/applicationShouldTerminate already returned a
    // deferred cancellation while the modal Save Panel was open. A successful
    // Nim save changes g_close_decision asynchronously at this boundary, so
    // explicitly retry the close only after the write succeeded. The second
    // close observes a clean document and is accepted by confirmClose.
    if (g_close_decision) {
      id delegate = [NSApp delegate];
      if ([delegate respondsToSelector:@selector(window)]) {
        NSWindow *window = [delegate window];
        if (window) [window performClose:nil];
      }
    }
  }
}
void nimculus_platform_set_editor_selection(uint32_t start_byte, uint32_t end_byte) {
  NSUInteger start = utf16OffsetForUTF8Bytes(g_editor_text ?: @"", start_byte);
  NSUInteger end = utf16OffsetForUTF8Bytes(g_editor_text ?: @"", end_byte);
  g_editor_selection_start = MIN(start, end);
  g_editor_selection_end = MAX(start, end);
  if (g_active_view) {
    NimculusMetalView *view = (NimculusMetalView *)g_active_view;
    view.selectedTextRange = NSMakeRange(g_editor_selection_start,
      g_editor_selection_end - g_editor_selection_start);
  }
  if (g_queue) updateEditorTextTexture(g_queue.device, g_editor_text, NO);
  markSceneFullyDirty();
  if (g_active_view) [(NimculusMetalView *)g_active_view drawFrame];
}
void nimculus_platform_set_editor_text(const char *utf8, uint32_t length) {
  g_editor_text = (utf8 && length > 0)
    ? [[NSString alloc] initWithBytes:utf8 length:length encoding:NSUTF8StringEncoding]
    : @"";
  if (!g_editor_text) g_editor_text = @"";
  markSceneFullyDirty();
  if (g_queue) updateEditorTextTexture(g_queue.device, g_editor_text, YES);
  if (g_active_view) [g_active_view drawFrame];
}
void nimculus_platform_set_terminal_visible(bool visible) {
  g_terminal_visible = visible ? YES : NO;
  if (g_active_view) {
    [(NimculusMetalView *)g_active_view updateTerminalFrame];
    [g_active_view drawFrame];
  }
}
void nimculus_platform_set_terminal_text(const char *utf8, uint32_t length) {
  g_terminal_text = (utf8 && length > 0)
    ? [[NSString alloc] initWithBytes:utf8 length:length encoding:NSUTF8StringEncoding]
    : @"";
  if (!g_terminal_text) g_terminal_text = @"";
  NimculusMetalView *view = (NimculusMetalView *)g_active_view;
  if (view) {
    NSTextView *terminal = nil;
    for (NSView *subview in view.subviews) {
      if ([subview isKindOfClass:[NimculusTerminalOverlay class]]) {
        terminal = (NSTextView *)subview;
        break;
      }
    }
    if (!terminal) return;
    terminal.string = g_terminal_text;
    applyTerminalSelection(terminal);
    [terminal scrollRangeToVisible:NSMakeRange(terminal.string.length, 0)];
  }
}
void nimculus_platform_set_terminal_runs(const char *utf8, uint32_t length,
                                         const NimculusTerminalRun *runs, uint32_t count) {
  g_terminal_text = (utf8 && length > 0)
    ? [[NSString alloc] initWithBytes:utf8 length:length encoding:NSUTF8StringEncoding]
    : @"";
  if (!g_terminal_text) g_terminal_text = @"";
  free(g_terminal_runs);
  g_terminal_runs = NULL;
  g_terminal_run_count = 0;
  g_terminal_hyperlinks = [NSMutableArray arrayWithCapacity:count];
  if (runs && count > 0) {
    g_terminal_runs = calloc(count, sizeof(NimculusTerminalRun));
    if (g_terminal_runs) {
      memcpy(g_terminal_runs, runs, count * sizeof(NimculusTerminalRun));
      g_terminal_run_count = count;
      for (uint32_t index = 0; index < count; index++) {
        const char *uri = runs[index].hyperlink_uri;
        [g_terminal_hyperlinks addObject:uri ?
          ([NSString stringWithUTF8String:uri] ?: @"") : @""];
      }
    }
  }
  NimculusMetalView *view = (NimculusMetalView *)g_active_view;
  if (!view) return;
  for (NSView *subview in view.subviews) {
    if ([subview isKindOfClass:[NimculusTerminalOverlay class]]) {
      NSTextView *terminal = (NSTextView *)subview;
      applyTerminalRuns(terminal);
      [terminal scrollRangeToVisible:NSMakeRange(terminal.string.length, 0)];
      break;
    }
  }
}
void nimculus_platform_set_theme_colors(const char *background, const char *foreground,
                                        const char *accent) {
  if (background) g_theme_background = [[NSString alloc] initWithUTF8String:background] ?: @"#1f2329";
  if (foreground) g_theme_foreground = [[NSString alloc] initWithUTF8String:foreground] ?: @"#d7dae0";
  if (accent) g_theme_accent = [[NSString alloc] initWithUTF8String:accent] ?: @"#4daafc";
  NimculusMetalView *view = (NimculusMetalView *)g_active_view;
  if (!view) return;
  for (NSView *subview in view.subviews) {
    if ([subview isKindOfClass:[NimculusTerminalOverlay class]]) {
      NSTextView *terminal = (NSTextView *)subview;
      terminal.backgroundColor = [themeHexColor(g_theme_background,
        [NSColor colorWithCalibratedRed:0.025 green:0.030 blue:0.045 alpha:1.0]) colorWithAlphaComponent:0.98];
      terminal.textColor = themeHexColor(g_theme_foreground,
        [NSColor colorWithCalibratedRed:0.82 green:0.88 blue:0.92 alpha:1.0]);
    }
  }
  [view drawFrame];
}
void nimculus_platform_set_terminal_selection(uint32_t start_row, uint32_t start_column,
                                              uint32_t end_row, uint32_t end_column) {
  g_terminal_has_selection = (start_row != end_row || start_column != end_column);
  g_terminal_selection_start_row = start_row;
  g_terminal_selection_start_column = start_column;
  g_terminal_selection_end_row = end_row;
  g_terminal_selection_end_column = end_column;
  NimculusMetalView *view = (NimculusMetalView *)g_active_view;
  if (view) {
    for (NSView *subview in view.subviews) {
      if ([subview isKindOfClass:[NimculusTerminalOverlay class]]) {
        applyTerminalSelection((NSTextView *)subview);
        break;
      }
    }
    [view drawFrame];
  }
}
void nimculus_platform_set_task_output_visible(bool visible) {
  g_task_output_visible = visible ? YES : NO;
  if (g_active_view) {
    [(NimculusMetalView *)g_active_view updateTerminalFrame];
    [g_active_view drawFrame];
  }
}
void nimculus_platform_set_task_output_text(const char *utf8, uint32_t length) {
  g_task_output_text = (utf8 && length > 0)
    ? [[NSString alloc] initWithBytes:utf8 length:length encoding:NSUTF8StringEncoding]
    : @"";
  if (!g_task_output_text) g_task_output_text = @"";
  NimculusMetalView *view = (NimculusMetalView *)g_active_view;
  if (view) {
    for (NSView *subview in view.subviews) {
      if ([subview isKindOfClass:[NimculusTaskOutputOverlay class]]) {
        NSTextView *taskOutput = (NSTextView *)subview;
        taskOutput.string = g_task_output_text;
        [taskOutput scrollRangeToVisible:NSMakeRange(taskOutput.string.length, 0)];
        break;
      }
    }
  }
}
void nimculus_platform_set_editor_completions(const char *utf8, uint32_t length) {
  g_editor_completions = (utf8 && length > 0)
    ? [[NSString alloc] initWithBytes:utf8 length:length encoding:NSUTF8StringEncoding]
    : @"";
  if (!g_editor_completions) g_editor_completions = @"";
  markSceneFullyDirty();
  if (g_queue) updateEditorTextTexture(g_queue.device, g_editor_text, NO);
  if (g_active_view) [g_active_view drawFrame];
}
void nimculus_platform_set_editor_hover(const char *utf8, uint32_t length) {
  g_editor_hover = (utf8 && length > 0)
    ? [[NSString alloc] initWithBytes:utf8 length:length encoding:NSUTF8StringEncoding]
    : @"";
  if (!g_editor_hover) g_editor_hover = @"";
  markSceneFullyDirty();
  if (g_queue) updateEditorTextTexture(g_queue.device, g_editor_text, NO);
  if (g_active_view) [g_active_view drawFrame];
}
void nimculus_platform_set_editor_hover_position(double x, double y) {
  g_editor_hover_position[0] = x;
  g_editor_hover_position[1] = y;
  markSceneFullyDirty();
  if (g_queue) updateEditorTextTexture(g_queue.device, g_editor_text, NO);
  if (g_active_view) [g_active_view drawFrame];
}
uint32_t nimculus_platform_editor_text_utf8_length(void) {
  NSData *data = [g_editor_text dataUsingEncoding:NSUTF8StringEncoding];
  return data ? (uint32_t)data.length : 0;
}
void nimculus_platform_set_editor_composition(const char *utf8) {
  g_marked_text = utf8 ? [NSString stringWithUTF8String:utf8] : @"";
  if (g_marked_text.length == 0 && g_active_view) {
    // Empty composition updates are also used by command/menu paths to end
    // composition. Keep the NSTextInputClient state in lockstep instead of
    // leaving a stale marked range behind.
    NimculusMetalView *view = (NimculusMetalView *)g_active_view;
    view.markedText = @"";
    view.markedTextRange = NSMakeRange(NSNotFound, 0);
  }
  markSceneFullyDirty();
  if (g_queue) updateEditorTextTexture(g_queue.device, g_editor_text, NO);
  if (g_active_view) [g_active_view drawFrame];
}
void nimculus_platform_clear_editor_composition(void) {
  g_marked_text = @"";
  if (g_active_view) {
    NimculusMetalView *view = (NimculusMetalView *)g_active_view;
    view.markedText = @"";
    view.markedTextRange = NSMakeRange(NSNotFound, 0);
  }
  markSceneFullyDirty();
  if (g_queue) updateEditorTextTexture(g_queue.device, g_editor_text, NO);
  if (g_active_view) [g_active_view drawFrame];
}
void nimculus_platform_set_editor_highlights(const NimculusHighlightSpan *spans, uint32_t count) {
  free(g_highlights);
  g_highlights = NULL;
  g_highlight_count = 0;
  if (spans && count > 0) {
    g_highlights = malloc(sizeof(NimculusHighlightSpan) * count);
    if (g_highlights) {
      memcpy(g_highlights, spans, sizeof(NimculusHighlightSpan) * count);
      g_highlight_count = count;
    }
  }
  markSceneFullyDirty();
}
void nimculus_platform_set_editor_diagnostics(const NimculusDiagnosticSpan *spans, uint32_t count) {
  free(g_diagnostics);
  g_diagnostics = NULL;
  g_diagnostic_count = 0;
  if (spans && count > 0) {
    g_diagnostics = malloc(sizeof(NimculusDiagnosticSpan) * count);
    if (g_diagnostics) {
      memcpy(g_diagnostics, spans, sizeof(NimculusDiagnosticSpan) * count);
      g_diagnostic_count = count;
    }
  }
  markSceneFullyDirty();
  if (g_queue) updateEditorTextTexture(g_queue.device, g_editor_text, NO);
  if (g_active_view) [(NimculusMetalView *)g_active_view drawFrame];
}
void nimculus_platform_set_editor_git_hunks(const NimculusGitHunkSpan *spans, uint32_t count) {
  free(g_git_hunks);
  g_git_hunks = NULL;
  g_git_hunk_count = 0;
  if (spans && count > 0) {
    g_git_hunks = malloc(sizeof(NimculusGitHunkSpan) * count);
    if (g_git_hunks) {
      memcpy(g_git_hunks, spans, sizeof(NimculusGitHunkSpan) * count);
      g_git_hunk_count = count;
    }
  }
  markSceneFullyDirty();
  if (g_queue) updateEditorTextTexture(g_queue.device, g_editor_text, NO);
  if (g_active_view) [(NimculusMetalView *)g_active_view drawFrame];
}
void nimculus_platform_set_recent_files(const char *const *paths, uint32_t count) {
  NSMutableArray<NSString *> *files = [NSMutableArray arrayWithCapacity:count];
  for (uint32_t index = 0; index < count; index++) {
    if (paths[index]) {
      NSString *path = [NSString stringWithUTF8String:paths[index]];
      if (path.length > 0) [files addObject:path];
    }
  }
  g_recent_files = [files copy];
}
void nimculus_platform_set_paint_commands(const NimculusPaintCommand *commands, uint32_t count) {
  free(g_paint_commands);
  g_paint_commands = NULL;
  g_paint_count = 0;
  if (commands && count > 0) {
    g_paint_commands = malloc(sizeof(NimculusPaintCommand) * count);
    if (g_paint_commands) {
      memcpy(g_paint_commands, commands, sizeof(NimculusPaintCommand) * count);
      g_paint_count = count;
    }
  }
  g_scene_dirty = YES;
}
void nimculus_platform_set_image_rgba(uint32_t image_id, uint32_t width,
                                      uint32_t height, const uint8_t *rgba,
                                      uint32_t length) {
  if (!g_image_textures || image_id == 0) return;
  uint64_t required = (uint64_t)width * (uint64_t)height * 4u;
  if (!rgba || width == 0 || height == 0 || required > UINT32_MAX || length < required) {
    [g_image_textures removeObjectForKey:@(image_id)];
    markSceneFullyDirty();
    return;
  }
  MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
    MTLPixelFormatRGBA8Unorm width:width height:height mipmapped:NO];
  descriptor.usage = MTLTextureUsageShaderRead;
  id<MTLTexture> texture = [g_queue.device newTextureWithDescriptor:descriptor];
  if (!texture) return;
  [texture replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0
    withBytes:rgba bytesPerRow:(NSUInteger)width * 4];
  g_image_textures[@(image_id)] = texture;
  markSceneFullyDirty();
  if (g_active_view) [(NimculusMetalView *)g_active_view drawFrame];
}
void nimculus_platform_set_paint_dirty_regions(const NimculusPaintRegion *regions, uint32_t count) {
  free(g_paint_dirty_regions);
  g_paint_dirty_regions = NULL;
  g_paint_dirty_count = 0;
  if (regions && count > 0) {
    g_paint_dirty_regions = malloc(sizeof(NimculusPaintRegion) * count);
    if (g_paint_dirty_regions) {
      memcpy(g_paint_dirty_regions, regions, sizeof(NimculusPaintRegion) * count);
      g_paint_dirty_count = count;
    }
  }
  g_scene_dirty = YES;
}
void nimculus_platform_set_ui_rectangle(double x, double y, double width, double height) {
  g_ui_rect[0] = x; g_ui_rect[1] = y; g_ui_rect[2] = width; g_ui_rect[3] = height;
  markSceneFullyDirty();
}
void nimculus_clipboard_set(const char *utf8, uint32_t length) {
  NSData *data = (utf8 && length > 0) ?
    [NSData dataWithBytes:utf8 length:length] : [NSData data];
  NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  g_clipboard_text = text ?: @"";
  g_clipboard_utf8_data = [g_clipboard_text dataUsingEncoding:NSUTF8StringEncoding];
  NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
  [pasteboard clearContents];
  [pasteboard setString:g_clipboard_text forType:NSPasteboardTypeString];
}
uint32_t nimculus_clipboard_utf8_length(void) {
  NSString *text = [[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString];
  g_clipboard_text = text ?: @"";
  g_clipboard_utf8_data = [g_clipboard_text dataUsingEncoding:NSUTF8StringEncoding];
  return (uint32_t)g_clipboard_utf8_data.length;
}
const uint8_t *nimculus_clipboard_utf8_bytes(void) {
  return (const uint8_t *)g_clipboard_utf8_data.bytes;
}

static const char *runFilePanel(BOOL save) {
  @autoreleasepool {
    NSSavePanel *savePanel = save ? [NSSavePanel savePanel] : nil;
    NSOpenPanel *openPanel = save ? nil : [NSOpenPanel openPanel];
    NSInteger response = save ? [savePanel runModal] : [openPanel runModal];
    if (response != NSModalResponseOK) { g_dialog_path[0] = '\0'; return g_dialog_path; }
    NSString *path = save ? savePanel.URL.path : openPanel.URL.path;
    strncpy(g_dialog_path, path.UTF8String ?: "", sizeof(g_dialog_path) - 1);
    g_dialog_path[sizeof(g_dialog_path) - 1] = '\0';
    return g_dialog_path;
  }
}
const char *nimculus_choose_open_file(void) { return runFilePanel(NO); }
const char *nimculus_choose_save_file(void) { return runFilePanel(YES); }
