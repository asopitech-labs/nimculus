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
static NimculusTextCallback g_text_callback = NULL;
static NimculusFileCallback g_file_callback = NULL;
static NimculusCommandCallback g_command_callback = NULL;
static double g_ui_rect[4] = {360.0, 260.0, 240.0, 120.0};
static NimculusPaintCommand *g_paint_commands = NULL;
static uint32_t g_paint_count = 0;
static NimculusPaintRegion *g_paint_dirty_regions = NULL;
static uint32_t g_paint_dirty_count = 0;
static double g_editor_cursor[2] = {8.0, 12.0};
static NSUInteger g_editor_selection_start = 0;
static NSUInteger g_editor_selection_end = 0;
static NSString *g_editor_text = @"";
static NSString *g_marked_text = @"";
static NSString *g_clipboard_text = @"";
static char g_dialog_path[PATH_MAX] = {0};

static id<MTLRenderPipelineState> g_pipeline = nil;
static id<MTLRenderPipelineState> g_text_pipeline = nil;
static id<MTLCommandQueue> g_queue = nil;
static id<MTLTexture> g_text_texture = nil;
static CGFloat g_text_texture_scale = 1.0;
static id<MTLTexture> g_scene_texture = nil;
static BOOL g_scene_initialized = NO;
static BOOL g_scene_dirty = YES;
static id g_active_view = nil;
static NimculusHighlightSpan *g_highlights = NULL;
static uint32_t g_highlight_count = 0;

static void markSceneFullyDirty(void) {
  g_scene_dirty = YES;
  free(g_paint_dirty_regions);
  g_paint_dirty_regions = NULL;
  g_paint_dirty_count = 0;
}

static void drawColoredRectangle(id<MTLRenderCommandEncoder> encoder,
                                 id<MTLDevice> device, CGSize logicalSize,
                                 double x, double y, double width, double height,
                                 float red, float green, float blue, float alpha) {
  if (logicalSize.width <= 0 || logicalSize.height <= 0 || width <= 0 || height <= 0) return;
  float left = (float)(x / logicalSize.width * 2.0 - 1.0);
  float right = (float)((x + width) / logicalSize.width * 2.0 - 1.0);
  float top = (float)(1.0 - y / logicalSize.height * 2.0);
  float bottom = (float)(1.0 - (y + height) / logicalSize.height * 2.0);
  const float vertices[] = {
    left, bottom, 0.0f, 1.0f, red, green, blue, alpha,
    right, bottom, 0.0f, 1.0f, red, green, blue, alpha,
    left, top, 0.0f, 1.0f, red, green, blue, alpha,
    right, top, 0.0f, 1.0f, red, green, blue, alpha,
  };
  id<MTLBuffer> buffer = [device newBufferWithBytes:vertices length:sizeof(vertices)
    options:MTLResourceStorageModeShared];
  [encoder setVertexBuffer:buffer offset:0 atIndex:0];
  [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
}

static void drawRoundedRectangle(id<MTLRenderCommandEncoder> encoder,
                                 id<MTLDevice> device, CGSize logicalSize,
                                 double x, double y, double width, double height,
                                 double radius, float red, float green,
                                 float blue, float alpha) {
  if (logicalSize.width <= 0 || logicalSize.height <= 0 || width <= 0 || height <= 0) return;
  const int cornerSegments = 6;
  const int perimeterPoints = (cornerSegments + 1) * 4;
  const int vertexCount = perimeterPoints + 1;
  float *vertices = malloc(sizeof(float) * vertexCount * 8);
  if (!vertices) return;
  double r = MIN(radius, MIN(width, height) / 2.0);
  double centerX = x + width / 2.0;
  double centerY = y + height / 2.0;
  vertices[0] = (float)(centerX / logicalSize.width * 2.0 - 1.0);
  vertices[1] = (float)(1.0 - centerY / logicalSize.height * 2.0);
  vertices[2] = 0.0f; vertices[3] = 1.0f;
  vertices[4] = red; vertices[5] = green; vertices[6] = blue; vertices[7] = alpha;
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
      vertices[offset] = (float)(pointX / logicalSize.width * 2.0 - 1.0);
      vertices[offset + 1] = (float)(1.0 - pointY / logicalSize.height * 2.0);
      vertices[offset + 2] = 0.0f; vertices[offset + 3] = 1.0f;
      vertices[offset + 4] = red; vertices[offset + 5] = green;
      vertices[offset + 6] = blue; vertices[offset + 7] = alpha;
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
  [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0
    vertexCount:triangleVertexCount];
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

static void updateEditorTextTexture(id<MTLDevice> device, NSString *text) {
  if (!device) return;
  CGFloat scale = g_metrics.scale_factor > 0.0 ? g_metrics.scale_factor : 1.0;
  const size_t width = (size_t)ceil(1024.0 * scale);
  const size_t height = (size_t)ceil(256.0 * scale);
  NSMutableData *pixels = [NSMutableData dataWithLength:width * height * 4];
  CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
  CGContextRef context = CGBitmapContextCreate(pixels.mutableBytes, width, height, 8,
    width * 4, colorSpace, kCGImageAlphaPremultipliedLast);
  CGColorSpaceRelease(colorSpace);
  if (!context) return;
  CGContextScaleCTM(context, scale, scale);
  CTFontRef font = CTFontCreateWithName(CFSTR("Menlo"), 14.0, NULL);
  NSColor *baseColor = [NSColor colorWithCalibratedRed:0.85 green:0.90 blue:1.0 alpha:1.0];
  NSDictionary *attributes = @{ (id)kCTFontAttributeName: (__bridge id)font,
    (id)kCTForegroundColorAttributeName: (id)baseColor.CGColor };
  NSArray<NSString *> *lines = [(text ?: @"") componentsSeparatedByString:@"\n"];
  NSUInteger visibleLines = MIN(lines.count, (NSUInteger)12);
  NSUInteger lineStartByte = 0;
  NSUInteger lineStartUnit = 0;
  for (NSUInteger index = 0; index < visibleLines; index++) {
    NSString *lineText = lines[index];
    NSUInteger lineLength = [[lineText dataUsingEncoding:NSUTF8StringEncoding] length];
    NSUInteger lineEndUnit = lineStartUnit + lineText.length;
    if (g_editor_selection_end > g_editor_selection_start &&
        g_editor_selection_end > lineStartUnit && g_editor_selection_start < lineEndUnit) {
      NSUInteger startUnit = MAX(g_editor_selection_start, lineStartUnit) - lineStartUnit;
      NSUInteger endUnit = MIN(g_editor_selection_end, lineEndUnit) - lineStartUnit;
      CGContextSetRGBFillColor(context, 0.20, 0.40, 0.75, 0.45);
      CGContextFillRect(context, CGRectMake(8.0 + startUnit * 8.0,
        height - 24.0 * (index + 1) - 4.0,
        MAX(1.0, (endUnit - startUnit) * 8.0), 20.0));
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
    CTLineRef line = CTLineCreateWithAttributedString((CFAttributedStringRef)attributed);
    CGContextSetTextPosition(context, 8.0, height - 24.0 * (index + 1));
    CTLineDraw(line, context);
    CFRelease(line);
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
    CGFloat baseline = height - g_editor_cursor[1] - 14.0;
    CGContextSetTextPosition(context, g_editor_cursor[0], MAX(0.0, baseline));
    CTLineDraw(markedLine, context);
    CFRelease(markedLine);
  }
  CGContextSetStrokeColorWithColor(context, [NSColor colorWithCalibratedRed:0.85
    green:0.90 blue:1.0 alpha:1.0].CGColor);
  CGContextSetLineWidth(context, 1.0);
  CGFloat caretY = height - g_editor_cursor[1] - 4.0;
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

static double millisecondsSince(uint64_t start) {
  mach_timebase_info_data_t timebase;
  mach_timebase_info(&timebase);
  uint64_t nanos = (mach_absolute_time() - start) * timebase.numer / timebase.denom;
  return (double)nanos / 1000000.0;
}

static void logInput(NSString *kind, NSEvent *event) {
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
      .x = location.x, .y = location.y,
      .delta_x = event.deltaX, .delta_y = event.deltaY,
    };
    g_input_callback(&input);
  }
}

@interface NimculusMetalView : NSView <NSTextInputClient>
@property(nonatomic, strong) CAMetalLayer *metalLayer;
@property(nonatomic, copy) NSString *markedText;
@property(nonatomic) NSRange markedTextRange;
@property(nonatomic) NSRange selectedTextRange;
@property(nonatomic, strong) NSTrackingArea *trackingArea;
@end

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
}

- (void)layout {
  [super layout];
  CGFloat scale = self.window.backingScaleFactor ?: 1.0;
  self.metalLayer.contentsScale = scale;
  self.metalLayer.drawableSize = CGSizeMake(self.bounds.size.width * scale,
                                            self.bounds.size.height * scale);
  [self updateMetrics];
  if (g_queue && fabs(g_text_texture_scale - g_metrics.scale_factor) > 0.001) {
    updateEditorTextTexture(g_queue.device, g_editor_text);
  }
  [self drawFrame];
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
      MTLScissorRect fullScissor = {0, 0, scene.width, scene.height};
      [encoder setScissorRect:fullScissor];
      for (uint32_t i = 0; i < g_paint_count; i++) {
        NimculusPaintCommand paint = g_paint_commands[i];
        NimculusPaintRegion clip = {paint.clip_x, paint.clip_y, paint.clip_width, paint.clip_height};
        setScissorForRegion(encoder, clip, logicalSize, drawableSize);
        if (paint.kind == 0) { // rectangle
          drawColoredRectangle(encoder, drawable.texture.device, logicalSize,
            paint.x, paint.y, paint.width, paint.height,
            0.15f, 0.48f, 0.92f, 1.0f);
        } else if (paint.kind == 1) { // border
          const double thickness = 2.0;
          drawColoredRectangle(encoder, drawable.texture.device, logicalSize,
            paint.x, paint.y, paint.width, thickness, 0.15f, 0.48f, 0.92f, 1.0f);
          drawColoredRectangle(encoder, drawable.texture.device, logicalSize,
            paint.x, paint.y + paint.height - thickness, paint.width, thickness,
            0.15f, 0.48f, 0.92f, 1.0f);
          drawColoredRectangle(encoder, drawable.texture.device, logicalSize,
            paint.x, paint.y, thickness, paint.height, 0.15f, 0.48f, 0.92f, 1.0f);
          drawColoredRectangle(encoder, drawable.texture.device, logicalSize,
            paint.x + paint.width - thickness, paint.y, thickness, paint.height,
            0.15f, 0.48f, 0.92f, 1.0f);
        } else if (paint.kind == 2) { // rounded rectangle
          drawRoundedRectangle(encoder, drawable.texture.device, logicalSize,
            paint.x, paint.y, paint.width, paint.height, paint.radius,
            0.15f, 0.48f, 0.92f, 1.0f);
        } else if (paint.kind == 7) { // shadow
          drawColoredRectangle(encoder, drawable.texture.device, logicalSize,
            paint.x + 3.0, paint.y + 3.0, paint.width, paint.height,
            0.0f, 0.0f, 0.0f, 0.35f);
        } else if (paint.kind == 8) { // caret
          drawColoredRectangle(encoder, drawable.texture.device, logicalSize,
            paint.x, paint.y, paint.width, paint.height,
            0.85f, 0.90f, 1.0f, 1.0f);
        } else if (paint.kind == 9) { // selection
          drawColoredRectangle(encoder, drawable.texture.device, logicalSize,
            paint.x, paint.y, paint.width, paint.height,
            0.20f, 0.40f, 0.75f, 0.45f);
        } else if (paint.kind == 10) { // scrollbar
          drawColoredRectangle(encoder, drawable.texture.device, logicalSize,
            paint.x, paint.y, paint.width, paint.height,
            0.45f, 0.50f, 0.58f, 0.85f);
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
    if (g_text_pipeline && g_text_texture) {
      const float textVertices[] = {
        -0.90f, 0.78f, 0.0f, 0.0f,
        -0.45f, 0.78f, 1.0f, 0.0f,
        -0.90f, 0.68f, 0.0f, 1.0f,
        -0.45f, 0.68f, 1.0f, 1.0f,
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

- (void)keyDown:(NSEvent *)event { logInput(@"keyDown", event); [self interpretKeyEvents:@[event]]; }
- (void)keyUp:(NSEvent *)event { logInput(@"keyUp", event); }
- (void)flagsChanged:(NSEvent *)event { logInput(@"flagsChanged", event); }
- (void)mouseDown:(NSEvent *)event { logInput(@"mouseDown", event); }
- (void)mouseUp:(NSEvent *)event { logInput(@"mouseUp", event); }
- (void)mouseMoved:(NSEvent *)event { logInput(@"mouseMoved", event); }
- (void)mouseDragged:(NSEvent *)event { logInput(@"mouseDragged", event); }
- (void)rightMouseDragged:(NSEvent *)event { logInput(@"rightMouseDragged", event); }
- (void)rightMouseDown:(NSEvent *)event { logInput(@"rightMouseDown", event); }
- (void)rightMouseUp:(NSEvent *)event { logInput(@"rightMouseUp", event); }
- (void)scrollWheel:(NSEvent *)event { logInput(@"scrollWheel", event); }
- (BOOL)becomeFirstResponder {
  NSLog(@"Nimculus focus gained");
  return [super becomeFirstResponder];
}
- (BOOL)resignFirstResponder {
  NSLog(@"Nimculus focus lost");
  return [super resignFirstResponder];
}
- (void)viewDidMoveToWindow { [self.window makeFirstResponder:self]; [self updateMetrics]; }

// NSTextInputClient: composition is forwarded to the application editor while
// committed text remains separate until insertText is received.
- (BOOL)hasMarkedText { return self.markedText.length > 0; }
- (NSRange)markedRange { return self.markedTextRange; }
- (NSRange)selectedRange {
  return NSMakeRange(g_editor_selection_start,
                     g_editor_selection_end - g_editor_selection_start);
}
- (NSArray<NSAttributedStringKey> *)validAttributesForMarkedText { return @[]; }
- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range
                                                     actualRange:(NSRangePointer)actualRange {
  NSString *text = g_editor_text ?: @"";
  NSUInteger start = MIN(range.location, text.length);
  NSUInteger end = MIN(NSMaxRange(range), text.length);
  if (end < start) end = start;
  NSRange actual = NSMakeRange(start, end - start);
  if (actualRange) *actualRange = actual;
  return [[NSAttributedString alloc] initWithString:[text substringWithRange:actual]];
}
- (NSAttributedString *)attributedString {
  return [[NSAttributedString alloc] initWithString:self.markedText ?: @""];
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
  // NSTextInputClient ranges are UTF-16 offsets in the document, not offsets
  // relative to the composition string.
  self.markedTextRange = NSMakeRange(g_editor_selection_start, self.markedText.length);
  self.selectedTextRange = selectedRange;
  if (g_text_callback) g_text_callback(self.markedText.UTF8String, true);
}
- (void)unmarkText {
  self.markedText = @"";
  self.markedTextRange = NSMakeRange(NSNotFound, 0);
}
- (void)insertText:(id)string replacementRange:(NSRange)replacementRange {
  NSString *committed = [string isKindOfClass:[NSAttributedString class]]
    ? [string string] : (NSString *)string;
  if (g_text_callback) g_text_callback(committed.UTF8String, false);
  [self unmarkText];
}
- (void)doCommandBySelector:(SEL)selector {
  NSString *name = NSStringFromSelector(selector);
  if ([name isEqualToString:@"moveLeft:"]) { if (g_command_callback) g_command_callback("moveLeft"); }
  else if ([name isEqualToString:@"moveRight:"]) { if (g_command_callback) g_command_callback("moveRight"); }
  else if ([name isEqualToString:@"moveLeftAndModifySelection:"]) { if (g_command_callback) g_command_callback("selectLeft"); }
  else if ([name isEqualToString:@"moveRightAndModifySelection:"]) { if (g_command_callback) g_command_callback("selectRight"); }
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
  CGFloat viewY = self.bounds.size.height - g_editor_cursor[1] - lineHeight;
  NSRect cursor = NSMakeRect(g_editor_cursor[0], MAX(0.0, viewY), 0, lineHeight);
  return [self.window convertRectToScreen:[self convertRect:cursor toView:nil]];
}
- (NSUInteger)characterIndexForPoint:(NSPoint)point {
  NSArray<NSString *> *lines = [g_editor_text componentsSeparatedByString:@"\n"];
  CGFloat fromTop = self.bounds.size.height - point.y;
  NSInteger lineIndex = MAX(0, (NSInteger)floor((fromTop - 4.0) / 18.0));
  lineIndex = MIN(lineIndex, (NSInteger)lines.count - 1);
  NSUInteger prefix = 0;
  for (NSInteger index = 0; index < lineIndex; index++) prefix += lines[index].length + 1;
  NSUInteger column = (NSUInteger)MAX(0, floor((point.x - 8.0) / 8.0));
  return prefix + MIN(column, lines[lineIndex].length);
}
- (CGFloat)baselineDeltaForCharacterAtIndex:(NSUInteger)index { return 18.0; }
- (BOOL)drawsVerticallyForCharacterAtIndex:(NSUInteger)index { return NO; }
- (CGFloat)fractionOfDistanceThroughGlyphForPoint:(NSPoint)point {
  CGFloat remainder = fmod(MAX(0.0, point.x - 8.0), 8.0) / 8.0;
  return MIN(1.0, MAX(0.0, remainder));
}

@end

@interface NimculusAppDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) NimculusMetalView *view;
@property(nonatomic, strong) NSTimer *workspaceSearchTimer;
@end

@implementation NimculusAppDelegate

- (void)setupMainMenu {
  NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@"MainMenu"];
  NSMenuItem *appItem = [[NSMenuItem alloc] initWithTitle:@"Nimculus" action:NULL keyEquivalent:@""];
  NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"Nimculus"];
  [appMenu addItem:[[NSMenuItem alloc] initWithTitle:@"Quit Nimculus" action:@selector(terminate:) keyEquivalent:@"q"]];
  [appItem setSubmenu:appMenu];
  [mainMenu addItem:appItem];

  NSMenuItem *fileItem = [[NSMenuItem alloc] initWithTitle:@"File" action:NULL keyEquivalent:@""];
  NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
  NSMenuItem *newDocument = [[NSMenuItem alloc] initWithTitle:@"New" action:@selector(newDocument:) keyEquivalent:@"n"];
  NSMenuItem *open = [[NSMenuItem alloc] initWithTitle:@"Open…" action:@selector(openDocument:) keyEquivalent:@"o"];
  NSMenuItem *save = [[NSMenuItem alloc] initWithTitle:@"Save" action:@selector(saveDocument:) keyEquivalent:@"s"];
  NSMenuItem *close = [[NSMenuItem alloc] initWithTitle:@"Close Window" action:@selector(performClose:) keyEquivalent:@"w"];
  newDocument.keyEquivalentModifierMask = NSEventModifierFlagCommand;
  open.keyEquivalentModifierMask = NSEventModifierFlagCommand;
  save.keyEquivalentModifierMask = NSEventModifierFlagCommand;
  close.keyEquivalentModifierMask = NSEventModifierFlagCommand;
  [fileMenu addItem:newDocument]; [fileMenu addItem:open]; [fileMenu addItem:save]; [fileMenu addItem:close];
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
  [windowMenu addItem:[[NSMenuItem alloc] initWithTitle:@"Zoom" action:@selector(performZoom:) keyEquivalent:@""]];
  [windowItem setSubmenu:windowMenu];
  [mainMenu addItem:windowItem];
  [NSApp setMainMenu:mainMenu];
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

- (void)cancelWorkspaceSearch:(id)sender {
  (void)sender;
  if (g_command_callback) g_command_callback("cancelWorkspaceSearch");
}

- (void)emitWorkspaceSearchTick:(NSTimer *)timer {
  (void)timer;
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
  NSTextField *field = [self workspacePathField:@"Relative path, e.g. src/new_file.nim"];
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
  NSTextField *field = [self workspacePathField:@"Relative path, e.g. src/new_folder"];
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
  NSTextField *oldField = [self workspacePathField:@"Existing relative path"];
  NSTextField *newField = [self workspacePathField:@"New relative path"];
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
  NSTextField *field = [self workspacePathField:@"Relative path"];
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
  NSSavePanel *panel = [NSSavePanel savePanel];
  if ([panel runModal] == NSModalResponseOK) {
    if (g_file_callback) g_file_callback(panel.URL.path.UTF8String, true);
  }
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
    "vertex V vs(uint id [[vertex_id]], constant float4 *v [[buffer(0)]]) { V o; o.pos=v[id*2]; o.color=v[id*2+1]; return o; }\n"
    "fragment float4 fs(V in [[stage_in]]) { return in.color; }\n"
    "struct TV { float4 pos [[position]]; float2 uv; };\n"
    "vertex TV textVs(uint id [[vertex_id]], constant float4 *v [[buffer(0)]]) { TV o; o.pos=float4(v[id].xy,0,1); o.uv=v[id].zw; return o; }\n"
    "fragment float4 textFs(TV in [[stage_in]], texture2d<float> atlas [[texture(0)]]) { constexpr sampler s(filter::linear); return atlas.sample(s,in.uv); }";
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
    g_text_pipeline = [device newRenderPipelineStateWithDescriptor:textDescriptor error:&error];
    updateEditorTextTexture(device, g_editor_text);
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

void nimculus_platform_get_metrics(NimculusPlatformMetrics *metrics) {
  if (metrics) *metrics = g_metrics;
}

uint64_t nimculus_platform_input_count(void) { return g_input_count; }
void nimculus_platform_set_input_callback(NimculusInputCallback callback) { g_input_callback = callback; }
void nimculus_platform_set_text_callback(NimculusTextCallback callback) { g_text_callback = callback; }
void nimculus_platform_set_file_callback(NimculusFileCallback callback) { g_file_callback = callback; }
void nimculus_platform_set_command_callback(NimculusCommandCallback callback) { g_command_callback = callback; }
void nimculus_platform_set_editor_cursor(double x, double y) {
  g_editor_cursor[0] = x;
  g_editor_cursor[1] = y;
  markSceneFullyDirty();
}
void nimculus_platform_set_editor_selection(uint32_t start_byte, uint32_t end_byte) {
  NSUInteger start = utf16OffsetForUTF8Bytes(g_editor_text ?: @"", start_byte);
  NSUInteger end = utf16OffsetForUTF8Bytes(g_editor_text ?: @"", end_byte);
  g_editor_selection_start = MIN(start, end);
  g_editor_selection_end = MAX(start, end);
  markSceneFullyDirty();
  if (g_active_view) [(NimculusMetalView *)g_active_view drawFrame];
}
void nimculus_platform_set_editor_text(const char *utf8) {
  g_editor_text = utf8 ? [NSString stringWithUTF8String:utf8] : @"";
  markSceneFullyDirty();
  if (g_queue) updateEditorTextTexture(g_queue.device, g_editor_text);
  if (g_active_view) [g_active_view drawFrame];
}
void nimculus_platform_set_editor_composition(const char *utf8) {
  g_marked_text = utf8 ? [NSString stringWithUTF8String:utf8] : @"";
  markSceneFullyDirty();
  if (g_queue) updateEditorTextTexture(g_queue.device, g_editor_text);
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
void nimculus_clipboard_set(const char *utf8) {
  g_clipboard_text = utf8 ? [NSString stringWithUTF8String:utf8] : @"";
  NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
  [pasteboard clearContents];
  [pasteboard setString:g_clipboard_text forType:NSPasteboardTypeString];
}
const char *nimculus_clipboard_get(void) {
  NSString *text = [[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString];
  return text ? text.UTF8String : "";
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
