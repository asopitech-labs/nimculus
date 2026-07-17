#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <mach/mach_time.h>
#include "platform.h"

static uint64_t g_input_count = 0;
static NimculusPlatformMetrics g_metrics = {1.0, 0, 0, 0, 0, 0.0, 0};

static id<MTLRenderPipelineState> g_pipeline = nil;
static id<MTLCommandQueue> g_queue = nil;

static double millisecondsSince(uint64_t start) {
  mach_timebase_info_data_t timebase;
  mach_timebase_info(&timebase);
  uint64_t nanos = (mach_absolute_time() - start) * timebase.numer / timebase.denom;
  return (double)nanos / 1000000.0;
}

static void logInput(NSString *kind, NSEvent *event) {
  g_input_count++;
  NSPoint location = event.locationInWindow;
  NSLog(@"Nimculus input kind=%@ keyCode=%hu modifiers=0x%lx x=%.1f y=%.1f dx=%.1f dy=%.1f",
        kind, event.keyCode, event.modifierFlags, location.x, location.y,
        event.deltaX, event.deltaY);
}

@interface NimculusMetalView : NSView <NSTextInputClient>
@property(nonatomic, strong) CAMetalLayer *metalLayer;
@property(nonatomic, copy) NSString *markedText;
@property(nonatomic) NSRange markedTextRange;
@property(nonatomic) NSRange selectedTextRange;
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
    self.metalLayer.framebufferOnly = YES;
    self.markedText = @"";
    self.markedTextRange = NSMakeRange(NSNotFound, 0);
    self.selectedTextRange = NSMakeRange(0, 0);
  }
  return self;
}

- (BOOL)acceptsFirstResponder { return YES; }

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
  [self drawFrame];
}

- (void)drawFrame {
  uint64_t start = mach_absolute_time();
  id<CAMetalDrawable> drawable = [self.metalLayer nextDrawable];
  if (!drawable || !g_queue) return;

  MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
  pass.colorAttachments[0].texture = drawable.texture;
  pass.colorAttachments[0].loadAction = MTLLoadActionClear;
  pass.colorAttachments[0].storeAction = MTLStoreActionStore;
  pass.colorAttachments[0].clearColor = MTLClearColorMake(0.055, 0.067, 0.090, 1.0);

  id<MTLCommandBuffer> command = [g_queue commandBuffer];
  id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
  if (g_pipeline) {
    [encoder setRenderPipelineState:g_pipeline];
    static const float vertices[] = {
      -0.72f, -0.18f, 0.0f, 1.0f, 0.15f, 0.48f, 0.92f, 1.0f,
       0.72f, -0.18f, 0.0f, 1.0f, 0.15f, 0.48f, 0.92f, 1.0f,
      -0.72f,  0.18f, 0.0f, 1.0f, 0.15f, 0.48f, 0.92f, 1.0f,
       0.72f,  0.18f, 0.0f, 1.0f, 0.15f, 0.48f, 0.92f, 1.0f,
    };
    id<MTLBuffer> buffer = [drawable.texture.device newBufferWithBytes:vertices
      length:sizeof(vertices) options:MTLResourceStorageModeShared];
    [encoder setVertexBuffer:buffer offset:0 atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
  }
  [encoder endEncoding];
  [command presentDrawable:drawable];
  [command commit];
  g_metrics.last_frame_time_ms = millisecondsSince(start);
  g_metrics.frame_count++;
}

- (void)keyDown:(NSEvent *)event { logInput(@"keyDown", event); }
- (void)keyUp:(NSEvent *)event { logInput(@"keyUp", event); }
- (void)flagsChanged:(NSEvent *)event { logInput(@"flagsChanged", event); }
- (void)mouseDown:(NSEvent *)event { logInput(@"mouseDown", event); }
- (void)mouseUp:(NSEvent *)event { logInput(@"mouseUp", event); }
- (void)mouseMoved:(NSEvent *)event { logInput(@"mouseMoved", event); }
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

// NSTextInputClient: this is the native IME boundary used by the future editor
// buffer. The M3 core keeps composition state separate from committed text.
- (BOOL)hasMarkedText { return self.markedText.length > 0; }
- (NSRange)markedRange { return self.markedTextRange; }
- (NSRange)selectedRange { return self.selectedTextRange; }
- (NSArray<NSAttributedStringKey> *)validAttributesForMarkedText { return @[]; }
- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range
                                                     actualRange:(NSRangePointer)actualRange {
  if (actualRange) *actualRange = range;
  return nil;
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
  self.markedTextRange = NSMakeRange(0, self.markedText.length);
  self.selectedTextRange = selectedRange;
  NSLog(@"Nimculus IME composition update length=%lu selection={%lu,%lu}",
        self.markedText.length, selectedRange.location, selectedRange.length);
}
- (void)unmarkText {
  self.markedText = @"";
  self.markedTextRange = NSMakeRange(NSNotFound, 0);
}
- (void)insertText:(id)string replacementRange:(NSRange)replacementRange {
  NSString *committed = [string isKindOfClass:[NSAttributedString class]]
    ? [string string] : (NSString *)string;
  NSLog(@"Nimculus IME committed text=%@", committed);
  [self unmarkText];
}
- (void)doCommandBySelector:(SEL)selector { NSLog(@"Nimculus IME command=%@", NSStringFromSelector(selector)); }
- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
  if (actualRange) *actualRange = range;
  NSRect cursor = NSMakeRect(0, 0, 1, 20);
  return [self.window convertRectToScreen:[self convertRect:cursor toView:nil]];
}
- (NSUInteger)characterIndexForPoint:(NSPoint)point { return 0; }

@end

@interface NimculusAppDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) NimculusMetalView *view;
@end

@implementation NimculusAppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  g_queue = [device newCommandQueue];
  NSError *error = nil;
  NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "struct V { float4 pos [[position]]; float4 color; };\n"
    "vertex V vs(uint id [[vertex_id]], constant float4 *v [[buffer(0)]]) { V o; o.pos=v[id*2]; o.color=v[id*2+1]; return o; }\n"
    "fragment float4 fs(V in [[stage_in]]) { return in.color; }";
  id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
  if (library) {
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = [library newFunctionWithName:@"vs"];
    descriptor.fragmentFunction = [library newFunctionWithName:@"fs"];
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    g_pipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
  }

  NSRect frame = NSMakeRect(0, 0, 960, 640);
  self.window = [[NSWindow alloc] initWithContentRect:frame
    styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
               NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
    backing:NSBackingStoreBuffered defer:NO];
  self.window.title = @"Nimculus";
  self.view = [[NimculusMetalView alloc] initWithFrame:frame];
  self.window.contentView = self.view;
  [self.window center];
  [self.window makeKeyAndOrderFront:nil];
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return YES; }
@end

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

void nimculus_platform_get_metrics(NimculusPlatformMetrics *metrics) {
  if (metrics) *metrics = g_metrics;
}

uint64_t nimculus_platform_input_count(void) { return g_input_count; }
