#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <CoreText/CoreText.h>
#import <CoreGraphics/CoreGraphics.h>
#import <mach/mach_time.h>
#import <mach/task.h>
#import <malloc/malloc.h>
#include <limits.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include "platform.h"

static uint64_t g_input_count = 0;
static uint64_t g_first_input_time = 0;
// Keep a bounded recent history rather than a process-lifetime unbounded
// allocation. Zed similarly reports input-to-frame latency as a distribution,
// not just the last completed sample.
#define NIMCULUS_INPUT_LATENCY_HISTORY 256
static double g_input_latency_history[NIMCULUS_INPUT_LATENCY_HISTORY];
static uint64_t g_input_events_per_frame_history[NIMCULUS_INPUT_LATENCY_HISTORY];
static uint64_t g_input_latency_sample_count = 0;
static uint64_t g_input_latency_event_count = 0;
static uint64_t g_pending_input_event_count = 0;
// Frame timing uses the same bounded history as input latency. It measures
// CPU-side render-through-submit time, not display-vsync interval.
#define NIMCULUS_FRAME_TIMING_HISTORY 256
static double g_frame_timing_history[NIMCULUS_FRAME_TIMING_HISTORY];
static uint64_t g_frame_timing_sample_count = 0;
static NimculusPlatformMetrics g_metrics = {1.0, 0, 0, 0, 0, 0.0, 0, 0.0};
static NimculusInputCallback g_input_callback = NULL;
static NimculusShortcutCallback g_shortcut_callback = NULL;
static NimculusTextCallback g_text_callback = NULL;
static NimculusSelectionCallback g_selection_callback = NULL;
static NimculusFileCallback g_file_callback = NULL;
// LaunchServices may deliver Finder/Open With events while NSApplication is
// starting, before Nim has installed its callback. Retain those paths until
// the application layer is ready instead of silently losing the initial
// workspace or document.
static NSMutableArray<NSString *> *g_pending_file_open_paths = nil;
static NimculusCommandCallback g_command_callback = NULL;
static NimculusIdleCallback g_idle_callback = NULL;
static BOOL g_validation_appearance_command_received = NO;

static void validateAppearanceCommand(const char *command) {
  g_validation_appearance_command_received = command &&
    strcmp(command, "appearanceChanged") == 0;
}
static double g_ui_rect[4] = {360.0, 260.0, 240.0, 120.0};
static double g_editor_rect[4] = {48.0, 128.0, 828.0, 432.0};
// WorkspaceUiState owns this top-left logical rectangle. Keeping it separate
// from g_editor_rect prevents terminal/task panels from deriving geometry from
// a legacy editor-height heuristic.
static double g_terminal_panel_rect[4] = {0.0, 0.0, 0.0, 0.0};
// The primary renderer remains the active editing surface.  Keep the second
// pane's geometry separately so input dispatch can select it before the
// independent Core Text/Metal resources are attached.
static double g_secondary_editor_rect[4] = {0.0, 0.0, 0.0, 0.0};
static BOOL g_secondary_editor_visible = NO;
// Split panes share one document, but not a viewport or selection.  Keep the
// secondary Core Text fallback state separate from the active NSTextInputClient
// state used by the primary editing surface.
static double g_secondary_editor_cursor[2] = {8.0, 12.0};
static NSUInteger g_secondary_editor_scroll_line = 0;
static NSUInteger g_secondary_editor_selection_start = 0;
static NSUInteger g_secondary_editor_selection_end = 0;
static BOOL g_secondary_editor_soft_wrap = NO;
static NSUInteger g_editor_input_pane = 0;
static NSUInteger g_editor_hover_pane = 0;
// updateEditorTextTexture is reused to build both pane textures. Keep the
// target explicit so transient overlays are emitted only into their owner.
static BOOL g_rendering_secondary_editor = NO;
static NimculusPaintCommand *g_paint_commands = NULL;
static uint32_t g_paint_count = 0;
static NimculusPaintRegion *g_paint_dirty_regions = NULL;
static uint32_t g_paint_dirty_count = 0;
static double g_editor_cursor[2] = {8.0, 12.0};
static CGFloat g_editor_font_size = 14.0;
static CGFloat g_editor_line_height = 18.0;
static NSString *g_editor_font_name = @"Menlo";
static CGFloat g_terminal_font_size = 12.0;
static NSString *g_terminal_font_name = @"Menlo";
static NSUInteger g_editor_scroll_line = 0;
static NSUInteger g_editor_selection_start = 0;
static NSUInteger g_editor_selection_end = 0;
static NSString *g_editor_text = @"";
static NSString *g_secondary_editor_text = @"";
// Rebuild these once when committed editor text changes. Text rendering,
// scrolling, hit-testing, and IME coordinate queries must not repeatedly
// split or scan a ten-thousand-line document on every frame.
static NSArray<NSString *> *g_editor_lines = nil;
static NSUInteger *g_editor_line_utf16_offsets = NULL;
static NSUInteger *g_editor_line_utf8_offsets = NULL;
static NSUInteger g_editor_line_count = 0;
static NSArray<NSString *> *g_secondary_editor_lines = nil;
static NSUInteger *g_secondary_editor_line_utf16_offsets = NULL;
static NSUInteger *g_secondary_editor_line_utf8_offsets = NULL;
static NSUInteger g_secondary_editor_line_count = 0;
static NSString *g_editor_status = @"Ready";
static NSArray<NSString *> *g_editor_tab_titles = nil;
static NSUInteger g_editor_active_tab = 0;
static NSArray<NSString *> *g_secondary_editor_tab_titles = nil;
static NSUInteger g_secondary_editor_active_tab = 0;
static BOOL g_editor_indent_guides = YES;
static NSUInteger g_editor_indent_width = 2;
static BOOL g_editor_line_numbers = YES;
static BOOL g_editor_soft_wrap = NO;
static NSString *g_terminal_text = @"";
static NSString *g_editor_outline_text = @"Outline\n────────\nNo symbols";
static uint32_t g_editor_outline_symbol_count = 0;
// mode 0 is the document outline, 1 the project files, 2 Git history, 3 the
// clickable Git status list, and 4 the Git branch picker. Non-outline modes
// dispatch sidebarItem:N.
static uint32_t g_editor_sidebar_mode = 0;
static BOOL g_editor_sidebar_visible = YES;
static BOOL g_workspace_open = YES;
static NSUInteger g_editor_sidebar_selected_index = NSNotFound;
static NSString *g_theme_background = @"#1f2329";
static NSString *g_theme_foreground = @"#d7dae0";
static NSString *g_theme_accent = @"#4daafc";
static NSString *g_theme_selection = @"#264f78";
static NSString *g_theme_border = @"#3b4048";
static NSString *g_crash_report_path = nil;
static NimculusTerminalRun *g_terminal_runs = NULL;
static uint32_t g_terminal_run_count = 0;
static NSMutableArray<NSString *> *g_terminal_hyperlinks = nil;
static BOOL g_terminal_visible = NO;
static NSArray<NSString *> *g_terminal_session_titles = nil;
static NSUInteger g_terminal_active_session = 0;
static NSString *g_task_output_text = @"";
static NSString *g_task_output_title = @"Task Output";
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
static NimculusEditorAnnotation *g_editor_annotations = NULL;
static uint32_t g_editor_annotation_count = 0;
static NSMutableArray<NSString *> *g_editor_annotation_texts = nil;
static NSString *g_clipboard_text = @"";
static NSData *g_clipboard_utf8_data = nil;
static char g_dialog_path[PATH_MAX] = {0};
static BOOL g_editor_dirty = NO;
static BOOL g_close_decision = NO;

// This backend is compiled with manual Objective-C ownership. Globals below
// outlive an autorelease pool, so every replacement must retain its new value
// and release the previous one. Keeping this at the C boundary avoids making
// individual editor/terminal update paths responsible for paired ownership.
static void replaceOwnedObject(id *slot, id value) {
  id previous = *slot;
  *slot = [value retain];
  [previous release];
}

static void dispatchOrQueueFileOpenPath(NSString *path) {
  if (path.length == 0) return;
  if (g_file_callback) {
    g_file_callback(path.UTF8String, false);
    return;
  }
  if (!g_pending_file_open_paths) {
    g_pending_file_open_paths = [[NSMutableArray alloc] init];
  }
  [g_pending_file_open_paths addObject:path];
}

static void flushPendingFileOpenPaths(void) {
  if (!g_file_callback || g_pending_file_open_paths.count == 0) return;
  NSArray<NSString *> *paths = [[g_pending_file_open_paths copy] autorelease];
  [g_pending_file_open_paths removeAllObjects];
  for (NSString *path in paths) {
    g_file_callback(path.UTF8String, false);
  }
}

static void replaceOwnedString(NSString **slot, NSString *value) {
  replaceOwnedObject((id *)slot, value ?: @"");
}

static void replaceOwnedUTF8String(NSString **slot, const char *utf8,
                                   uint32_t length, NSString *fallback) {
  NSString *value = (utf8 && length > 0)
    ? [[[NSString alloc] initWithBytes:utf8 length:length encoding:NSUTF8StringEncoding] autorelease]
    : fallback;
  replaceOwnedString(slot, value ?: fallback ?: @"");
}

static void replaceOwnedArray(NSArray **slot, NSArray *value) {
  NSArray *previous = *slot;
  *slot = [value copy] ?: [[NSArray alloc] init];
  [previous release];
}

static void replaceOwnedMutableArray(NSMutableArray **slot, NSArray *value) {
  NSMutableArray *previous = *slot;
  *slot = [value mutableCopy] ?: [[NSMutableArray alloc] init];
  [previous release];
}

static void replaceOwnedData(NSData **slot, NSData *value) {
  NSData *previous = *slot;
  *slot = [value copy] ?: [[NSData alloc] init];
  [previous release];
}

static void rebuildEditorLineIndex(void) {
  NSArray<NSString *> *lines = [g_editor_text componentsSeparatedByString:@"\n"];
  replaceOwnedArray(&g_editor_lines, lines);
  free(g_editor_line_utf16_offsets); g_editor_line_utf16_offsets = NULL;
  free(g_editor_line_utf8_offsets); g_editor_line_utf8_offsets = NULL;
  g_editor_line_count = g_editor_lines.count;
  if (g_editor_line_count == 0) return;
  g_editor_line_utf16_offsets = calloc(g_editor_line_count, sizeof(NSUInteger));
  g_editor_line_utf8_offsets = calloc(g_editor_line_count, sizeof(NSUInteger));
  if (!g_editor_line_utf16_offsets || !g_editor_line_utf8_offsets) {
    free(g_editor_line_utf16_offsets); g_editor_line_utf16_offsets = NULL;
    free(g_editor_line_utf8_offsets); g_editor_line_utf8_offsets = NULL;
    return;
  }
  NSUInteger utf16Offset = 0;
  NSUInteger utf8Offset = 0;
  for (NSUInteger index = 0; index < g_editor_line_count; index++) {
    NSString *line = g_editor_lines[index];
    g_editor_line_utf16_offsets[index] = utf16Offset;
    g_editor_line_utf8_offsets[index] = utf8Offset;
    utf16Offset += line.length + 1;
    utf8Offset += [[line dataUsingEncoding:NSUTF8StringEncoding] length] + 1;
  }
}

static void swapEditorTextState(void) {
  NSString *text = g_editor_text; g_editor_text = g_secondary_editor_text; g_secondary_editor_text = text;
  NSArray *lines = g_editor_lines; g_editor_lines = g_secondary_editor_lines; g_secondary_editor_lines = lines;
  NSUInteger *utf16 = g_editor_line_utf16_offsets; g_editor_line_utf16_offsets = g_secondary_editor_line_utf16_offsets; g_secondary_editor_line_utf16_offsets = utf16;
  NSUInteger *utf8 = g_editor_line_utf8_offsets; g_editor_line_utf8_offsets = g_secondary_editor_line_utf8_offsets; g_secondary_editor_line_utf8_offsets = utf8;
  NSUInteger count = g_editor_line_count; g_editor_line_count = g_secondary_editor_line_count; g_secondary_editor_line_count = count;
}

static void rebuildSecondaryEditorLineIndex(void) {
  swapEditorTextState();
  rebuildEditorLineIndex();
  swapEditorTextState();
}

static NSArray<NSString *> *editorLinesForText(NSString *text) {
  NSString *value = text ?: @"";
  if ([value isEqualToString:g_editor_text] && g_editor_lines) return g_editor_lines;
  return [value componentsSeparatedByString:@"\n"];
}

static NSUInteger editorLineUTF16Offset(NSUInteger lineIndex,
                                        NSArray<NSString *> *lines) {
  if (g_editor_line_utf16_offsets && lines == g_editor_lines &&
      lineIndex < g_editor_line_count) return g_editor_line_utf16_offsets[lineIndex];
  NSUInteger offset = 0;
  for (NSUInteger index = 0; index < lineIndex && index < lines.count; index++) {
    offset += lines[index].length + 1;
  }
  return offset;
}

static NSUInteger editorLineUTF8Offset(NSUInteger lineIndex,
                                       NSArray<NSString *> *lines) {
  if (g_editor_line_utf8_offsets && lines == g_editor_lines &&
      lineIndex < g_editor_line_count) return g_editor_line_utf8_offsets[lineIndex];
  NSUInteger offset = 0;
  for (NSUInteger index = 0; index < lineIndex && index < lines.count; index++) {
    offset += [[lines[index] dataUsingEncoding:NSUTF8StringEncoding] length] + 1;
  }
  return offset;
}

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

static void themeRGB(NSString *value, NSColor *fallback,
                     float *red, float *green, float *blue) {
  NSColor *color = themeHexColor(value, fallback);
  CGFloat r = 0.0, g = 0.0, b = 0.0, a = 1.0;
  [color getRed:&r green:&g blue:&b alpha:&a];
  *red = (float)r;
  *green = (float)g;
  *blue = (float)b;
}

static void nimculus_uncaught_exception_handler(NSException *exception) {
  if (!g_crash_report_path || g_crash_report_path.length == 0) return;
  NSDictionary *report = @{
    @"kind": @"uncaughtObjectiveCException",
    @"name": exception.name ?: @"NSException",
    @"reason": exception.reason ?: @"unknown",
    @"timestamp": [[[NSISO8601DateFormatter new] autorelease] stringFromDate:[NSDate date]]
  };
  NSError *error = nil;
  NSData *data = [NSJSONSerialization dataWithJSONObject:report options:0 error:&error];
  if (data && !error) [data writeToFile:g_crash_report_path atomically:YES];
}
static BOOL g_terminate_decision = NO;
static NSArray<NSString *> *g_recent_files = nil;
static NSString *g_workspace_context_path = nil;
static BOOL g_workspace_context_is_directory = NO;
static BOOL g_welcome_visible = NO;
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
static id<MTLTexture> g_secondary_text_texture = nil;
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
static BOOL g_glyph_atlas_rebuild_in_progress = NO;
#define NIMCULUS_SUBPIXEL_VARIANTS_X 4
#define NIMCULUS_SUBPIXEL_VARIANTS_Y 4

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

static void releasePlatformResources(void) {
  // As with Zed's renderer drop path, release GPU objects before AppKit tears
  // down the window/layer, then dispose of CPU buffers and bridge state.
  g_active_view = nil;
  [g_scene_texture release]; g_scene_texture = nil;
  [g_text_texture release]; g_text_texture = nil;
  [g_secondary_text_texture release]; g_secondary_text_texture = nil;
  [g_glyph_atlas_texture release]; g_glyph_atlas_texture = nil;
  [g_image_textures release]; g_image_textures = nil;
  [g_glyph_atlas_entries release]; g_glyph_atlas_entries = nil;
  [g_pipeline release]; g_pipeline = nil;
  [g_text_pipeline release]; g_text_pipeline = nil;
  [g_glyph_pipeline release]; g_glyph_pipeline = nil;
  [g_image_pipeline release]; g_image_pipeline = nil;
  [g_queue release]; g_queue = nil;
  free(g_glyph_vertices); g_glyph_vertices = NULL;
  g_glyph_vertex_count = 0; g_glyph_vertex_capacity = 0;
  free(g_paint_commands); g_paint_commands = NULL; g_paint_count = 0;
  free(g_paint_dirty_regions); g_paint_dirty_regions = NULL; g_paint_dirty_count = 0;
  free(g_highlights); g_highlights = NULL; g_highlight_count = 0;
  free(g_diagnostics); g_diagnostics = NULL; g_diagnostic_count = 0;
  free(g_git_hunks); g_git_hunks = NULL; g_git_hunk_count = 0;
  free(g_terminal_runs); g_terminal_runs = NULL; g_terminal_run_count = 0;
  free(g_editor_annotations); g_editor_annotations = NULL; g_editor_annotation_count = 0;
  [g_terminal_hyperlinks release]; g_terminal_hyperlinks = nil;
  [g_terminal_session_titles release]; g_terminal_session_titles = nil;
  [g_task_output_title release]; g_task_output_title = nil;
  [g_editor_annotation_texts release]; g_editor_annotation_texts = nil;
  [g_editor_tab_titles release]; g_editor_tab_titles = nil;
  [g_secondary_editor_tab_titles release]; g_secondary_editor_tab_titles = nil;
  [g_recent_files release]; g_recent_files = nil;
  [g_workspace_context_path release]; g_workspace_context_path = nil;
  g_workspace_context_is_directory = NO;
  [g_pending_file_open_paths release]; g_pending_file_open_paths = nil;
  [g_clipboard_utf8_data release]; g_clipboard_utf8_data = nil;
  [g_editor_font_name release]; g_editor_font_name = nil;
  [g_terminal_font_name release]; g_terminal_font_name = nil;
  [g_editor_text release]; g_editor_text = nil;
  [g_secondary_editor_text release]; g_secondary_editor_text = nil;
  [g_editor_lines release]; g_editor_lines = nil;
  free(g_editor_line_utf16_offsets); g_editor_line_utf16_offsets = NULL;
  free(g_editor_line_utf8_offsets); g_editor_line_utf8_offsets = NULL;
  g_editor_line_count = 0;
  [g_secondary_editor_lines release]; g_secondary_editor_lines = nil;
  free(g_secondary_editor_line_utf16_offsets); g_secondary_editor_line_utf16_offsets = NULL;
  free(g_secondary_editor_line_utf8_offsets); g_secondary_editor_line_utf8_offsets = NULL;
  g_secondary_editor_line_count = 0;
  [g_editor_status release]; g_editor_status = nil;
  [g_editor_outline_text release]; g_editor_outline_text = nil;
  [g_terminal_text release]; g_terminal_text = nil;
  [g_task_output_text release]; g_task_output_text = nil;
  [g_marked_text release]; g_marked_text = nil;
  [g_editor_completions release]; g_editor_completions = nil;
  [g_editor_hover release]; g_editor_hover = nil;
  [g_clipboard_text release]; g_clipboard_text = nil;
  [g_theme_background release]; g_theme_background = nil;
  [g_theme_foreground release]; g_theme_foreground = nil;
  [g_theme_accent release]; g_theme_accent = nil;
  [g_theme_selection release]; g_theme_selection = nil;
  [g_theme_border release]; g_theme_border = nil;
  [g_crash_report_path release]; g_crash_report_path = nil;
}

bool nimculus_platform_validate_resource_teardown(void) {
  releasePlatformResources();
  return g_scene_texture == nil && g_text_texture == nil &&
    g_glyph_atlas_texture == nil && g_image_textures == nil &&
    g_glyph_atlas_entries == nil && g_pipeline == nil &&
    g_text_pipeline == nil && g_glyph_pipeline == nil &&
    g_image_pipeline == nil && g_queue == nil && g_glyph_vertices == NULL &&
    g_paint_commands == NULL && g_paint_dirty_regions == NULL &&
    g_highlights == NULL && g_diagnostics == NULL && g_git_hunks == NULL &&
    g_terminal_runs == NULL && g_editor_annotations == NULL &&
    g_pending_file_open_paths == nil &&
    g_glyph_vertex_count == 0 && g_paint_count == 0 &&
    g_paint_dirty_count == 0 && g_highlight_count == 0 &&
    g_diagnostic_count == 0 && g_git_hunk_count == 0 &&
    g_terminal_run_count == 0 && g_editor_annotation_count == 0;
}

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
  // The encoder retains resources referenced by this command until the command
  // buffer completes, so these per-draw buffers must not accumulate per frame.
  [uniformBuffer release];
  [buffer release];
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
  [buffer release];
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
  [uniformBuffer release];
  [buffer release];
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
  float themeRed = 0.15f, themeGreen = 0.48f, themeBlue = 0.92f;
  if (paint.kind == 0) { // rectangle
    drawColoredRectangleWithTransform(encoder, device, logicalSize,
      x, y, width, height,
      0.15f, 0.48f, 0.92f, 1.0f, transform);
  } else if (paint.kind == 1) { // border
    themeRGB(g_theme_border,
      [NSColor colorWithCalibratedRed:0.15 green:0.48 blue:0.92 alpha:1.0],
      &themeRed, &themeGreen, &themeBlue);
    const double thickness = 2.0;
    drawColoredRectangleWithTransform(encoder, device, logicalSize,
      x, y, width, thickness, themeRed, themeGreen, themeBlue, 1.0f, transform);
    drawColoredRectangleWithTransform(encoder, device, logicalSize,
      x, y + height - thickness, width, thickness,
      themeRed, themeGreen, themeBlue, 1.0f, transform);
    drawColoredRectangleWithTransform(encoder, device, logicalSize,
      x, y, thickness, height, themeRed, themeGreen, themeBlue, 1.0f, transform);
    drawColoredRectangleWithTransform(encoder, device, logicalSize,
      x + width - thickness, y, thickness, height,
      themeRed, themeGreen, themeBlue, 1.0f, transform);
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
    themeRGB(g_theme_selection,
      [NSColor colorWithCalibratedRed:0.20 green:0.40 blue:0.75 alpha:1.0],
      &themeRed, &themeGreen, &themeBlue);
    drawColoredRectangleWithTransform(encoder, device, logicalSize,
      x, y, width, height,
      themeRed, themeGreen, themeBlue, 0.45f, transform);
  } else if (paint.kind == 10) { // scrollbar
    drawColoredRectangleWithTransform(encoder, device, logicalSize,
      x, y, width, height,
      0.45f, 0.50f, 0.58f, 0.85f, transform);
  } else if (paint.kind == 11) { // workspace background
    themeRGB(g_theme_background,
      [NSColor colorWithCalibratedRed:0.055 green:0.065 blue:0.090 alpha:1.0],
      &themeRed, &themeGreen, &themeBlue);
    drawColoredRectangleWithTransform(encoder, device, logicalSize,
      x, y, width, height, themeRed, themeGreen, themeBlue, 1.0f, transform);
  } else if (paint.kind == 12) { // workspace panel
    themeRGB(g_theme_background,
      [NSColor colorWithCalibratedRed:0.070 green:0.082 blue:0.110 alpha:1.0],
      &themeRed, &themeGreen, &themeBlue);
    drawColoredRectangleWithTransform(encoder, device, logicalSize,
      x, y, width, height, themeRed, themeGreen, themeBlue, 0.96f, transform);
  } else if (paint.kind == 13) { // workspace separator
    themeRGB(g_theme_border,
      [NSColor colorWithCalibratedRed:0.20 green:0.23 blue:0.29 alpha:1.0],
      &themeRed, &themeGreen, &themeBlue);
    drawColoredRectangleWithTransform(encoder, device, logicalSize,
      x, y, width, height, themeRed, themeGreen, themeBlue, 0.9f, transform);
  } else if (paint.kind == 14) { // active workspace affordance
    themeRGB(g_theme_accent,
      [NSColor colorWithCalibratedRed:0.30 green:0.66 blue:0.98 alpha:1.0],
      &themeRed, &themeGreen, &themeBlue);
    drawColoredRectangleWithTransform(encoder, device, logicalSize,
      x, y, width, height, themeRed, themeGreen, themeBlue, 0.78f, transform);
  }
}

static id<MTLTexture> sceneTextureForDevice(id<MTLDevice> device, CGSize drawableSize) {
  if (drawableSize.width <= 0 || drawableSize.height <= 0) return nil;
  if (g_scene_texture && (g_scene_texture.device != device ||
                          g_scene_texture.width != (NSUInteger)drawableSize.width ||
                          g_scene_texture.height != (NSUInteger)drawableSize.height)) {
    // `newTextureWithDescriptor:` returns an owned Metal object. Keep the
    // retained render target bounded to one texture as drawable dimensions
    // change (for example when moving between Retina displays or resizing).
    [g_scene_texture release];
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

static BOOL sceneNeedsFullRebuild(BOOL initialized, uint32_t dirtyCount) {
  return !initialized || dirtyCount == 0;
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
  NSString *fontName = g_editor_font_name.length > 0 ? g_editor_font_name : @"Menlo";
  CGFloat size = isfinite(g_editor_font_size) && g_editor_font_size > 0.0
    ? g_editor_font_size : 14.0;
  CTFontRef font = CTFontCreateWithName((__bridge CFStringRef)fontName, size, NULL);
  if (!font) font = CTFontCreateUIFontForLanguage(kCTFontSystemFontType, size, NULL);
  return font;
}

static CGFloat editorLineHeight(void) { return g_editor_line_height; }

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
  NSUInteger index = MIN(utf16Index, value.length);
  CGFloat offset = CTLineGetOffsetForStringIndex(ctLine, index, NULL);
  // Some fallback-font runs report a zero string-index offset at their run
  // boundary. Measuring the prefix keeps NSTextInputClient candidate windows
  // and pointer hit testing aligned with the visible Core Text layout.
  if (index > 0 && offset <= 0.0) {
    NSAttributedString *prefix = [[NSAttributedString alloc]
      initWithString:[value substringToIndex:index] attributes:attributes];
    CTLineRef prefixLine = CTLineCreateWithAttributedString((CFAttributedStringRef)prefix);
    offset = (CGFloat)CTLineGetTypographicBounds(prefixLine, NULL, NULL, NULL);
    CFRelease(prefixLine);
    [prefix release];
  }
  CFRelease(ctLine);
  [attributed release];
  CFRelease(font);
  return offset;
}

static CGFloat editorWrapWidth(void) {
  return MAX(1.0, g_editor_rect[2] - 16.0);
}

static NSUInteger editorSoftWrapBreakLength(NSString *line, NSUInteger start) {
  NSString *value = line ?: @"";
  if (start >= value.length) return 0;
  CTFontRef font = editorFont();
  if (!font) return value.length - start;
  NSDictionary *attributes = @{ (id)kCTFontAttributeName: (__bridge id)font };
  NSAttributedString *attributed = [[NSAttributedString alloc]
    initWithString:value attributes:attributes];
  CTTypesetterRef typesetter = CTTypesetterCreateWithAttributedString(
    (CFAttributedStringRef)attributed);
  CFIndex length = typesetter
    ? CTTypesetterSuggestLineBreak(typesetter, (CFIndex)start, editorWrapWidth())
    : (CFIndex)(value.length - start);
  if (typesetter) CFRelease(typesetter);
  [attributed release];
  CFRelease(font);
  NSUInteger result = (NSUInteger)MAX(1, MIN(length, (CFIndex)(value.length - start)));
  return result;
}

static NSUInteger editorSoftWrapRowCount(NSString *line) {
  NSString *value = line ?: @"";
  if (value.length == 0) return 1;
  NSUInteger rows = 0;
  NSUInteger start = 0;
  while (start < value.length) {
    start += editorSoftWrapBreakLength(value, start);
    rows++;
  }
  return MAX(1, rows);
}

static NSUInteger editorSoftWrapRowsBeforeLine(NSArray<NSString *> *lines,
                                                NSUInteger lineIndex) {
  NSUInteger rows = 0;
  NSUInteger limit = MIN(lineIndex, lines.count);
  for (NSUInteger index = 0; index < limit; index++) {
    rows += editorSoftWrapRowCount(lines[index]);
  }
  return rows;
}

static CGPoint editorSoftWrapPointForUTF16Offset(NSUInteger documentOffset) {
  NSArray<NSString *> *lines = editorLinesForText(g_editor_text);
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

  NSUInteger displayRow = editorSoftWrapRowsBeforeLine(lines, lineIndex);
  NSUInteger scrollRow = editorSoftWrapRowsBeforeLine(lines, g_editor_scroll_line);
  NSUInteger segmentStart = 0;
  NSUInteger rowInLine = 0;
  while (segmentStart < lineText.length) {
    NSUInteger segmentLength = editorSoftWrapBreakLength(lineText, segmentStart);
    if (remaining <= segmentStart + segmentLength ||
        segmentStart + segmentLength >= lineText.length) {
      NSString *segment = [lineText substringWithRange:NSMakeRange(
        segmentStart, segmentLength)];
      NSUInteger localOffset = remaining >= segmentStart
        ? MIN(remaining - segmentStart, segment.length) : 0;
      NSInteger visibleRow = displayRow + rowInLine >= scrollRow
        ? (NSInteger)(displayRow + rowInLine - scrollRow) : 0;
      return CGPointMake(8.0 + editorTextOffset(segment, localOffset),
        12.0 + visibleRow * editorLineHeight());
    }
    segmentStart += segmentLength;
    rowInLine++;
  }
  NSInteger visibleRow = displayRow + rowInLine >= scrollRow
    ? (NSInteger)(displayRow + rowInLine - scrollRow) : 0;
  return CGPointMake(8.0 + editorTextOffset(@"", 0),
    12.0 + visibleRow * editorLineHeight());
}

static CGPoint editorPointForUTF16Offset(NSUInteger documentOffset) {
  if (g_editor_soft_wrap) return editorSoftWrapPointForUTF16Offset(documentOffset);
  NSArray<NSString *> *lines = editorLinesForText(g_editor_text);
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
                     12.0 + visibleLine * editorLineHeight());
}

static NSUInteger editorDocumentOffsetForLineCharacter(NSUInteger lineIndex,
                                                       NSUInteger character) {
  NSArray<NSString *> *lines = editorLinesForText(g_editor_text);
  if (lines.count == 0) return 0;
  NSUInteger line = MIN(lineIndex, lines.count - 1);
  NSUInteger offset = 0;
  for (NSUInteger index = 0; index < line; index++) offset += lines[index].length + 1;
  return MIN(offset + MIN(character, lines[line].length), g_editor_text.length);
}

static NSUInteger editorUTF16OffsetAtPoint(double x, double y) {
  NSArray<NSString *> *lines = editorLinesForText(g_editor_text);
  if (lines.count == 0) return 0;
  CGFloat viewHeight = g_metrics.height_points > 0 ? g_metrics.height_points : 640.0;
  CGFloat fromTop = viewHeight - y - g_editor_rect[1];
  NSInteger targetRow = MAX(0, (NSInteger)floor((fromTop - 4.0) / editorLineHeight()));
  NSUInteger lineIndex = g_editor_scroll_line;
  NSUInteger rowInLine = (NSUInteger)targetRow;
  while (lineIndex < lines.count) {
    NSUInteger rows = g_editor_soft_wrap ? editorSoftWrapRowCount(lines[lineIndex]) : 1;
    if (rowInLine < rows) break;
    rowInLine -= rows;
    lineIndex++;
  }
  if (lineIndex >= lines.count) lineIndex = lines.count - 1;
  NSString *lineText = lines[lineIndex];
  NSUInteger segmentStart = 0;
  for (NSUInteger row = 0; row < rowInLine && segmentStart < lineText.length; row++) {
    segmentStart += editorSoftWrapBreakLength(lineText, segmentStart);
  }
  NSUInteger segmentLength = lineText.length > segmentStart
    ? editorSoftWrapBreakLength(lineText, segmentStart) : 0;
  NSString *segment = [lineText substringWithRange:NSMakeRange(segmentStart, segmentLength)];
  CTFontRef font = editorFont();
  NSUInteger localIndex = 0;
  if (font) {
    NSDictionary *attributes = @{ (id)kCTFontAttributeName: (__bridge id)font };
    NSAttributedString *attributed = [[NSAttributedString alloc]
      initWithString:segment attributes:attributes];
    CTLineRef ctLine = CTLineCreateWithAttributedString((CFAttributedStringRef)attributed);
    CFIndex index = CTLineGetStringIndexForPosition(ctLine,
      CGPointMake(MAX(0.0, x - g_editor_rect[0] - 8.0), 0.0));
    if (index != kCFNotFound) localIndex = MIN((NSUInteger)index, segment.length);
    else localIndex = segment.length;
    CFRelease(ctLine);
    [attributed release];
    CFRelease(font);
  }
  NSUInteger documentIndex = 0;
  for (NSUInteger index = 0; index < lineIndex; index++) documentIndex += lines[index].length + 1;
  return MIN(documentIndex + segmentStart + localIndex, g_editor_text.length);
}

static void updateEditorGlyphAtlas(id<MTLDevice> device, NSString *text);
static void resetGlyphVertices(void);

static BOOL scalarIsColorEmoji(uint32_t scalar) {
  return (scalar >= 0x1F000 && scalar <= 0x1FAFF) ||
    (scalar >= 0x2600 && scalar <= 0x27BF);
}

static BOOL colorEmojiAtUTF16Index(NSString *text, NSUInteger index,
                                   NSUInteger *unitLength) {
  if (!text || index >= text.length) return NO;
  uint32_t scalar = [text characterAtIndex:index];
  NSUInteger length = 1;
  if (scalar >= 0xD800 && scalar <= 0xDBFF && index + 1 < text.length) {
    uint32_t low = [text characterAtIndex:index + 1];
    if (low >= 0xDC00 && low <= 0xDFFF) {
      scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00);
      length = 2;
    }
  }
  if (unitLength) *unitLength = length;
  return scalarIsColorEmoji(scalar);
}

static BOOL fontIsColorEmoji(CTFontRef font) {
  if (!font) return NO;
  NSString *postScriptName = (__bridge_transfer NSString *)CTFontCopyPostScriptName(font);
  return [postScriptName isEqualToString:@"AppleColorEmoji"] ||
    [postScriptName isEqualToString:@".AppleColorEmojiUI"];
}

static BOOL textContainsColorEmoji(NSString *text) {
  if (!text) return NO;
  CTFontRef baseFont = editorFont();
  if (!baseFont) return NO;
  NSDictionary *attributes = @{ (id)kCTFontAttributeName: (__bridge id)baseFont };
  NSAttributedString *attributed = [[NSAttributedString alloc]
    initWithString:text attributes:attributes];
  CTLineRef line = CTLineCreateWithAttributedString((CFAttributedStringRef)attributed);
  BOOL result = NO;
  CFArrayRef runs = line ? CTLineGetGlyphRuns(line) : NULL;
  for (CFIndex index = 0; runs && index < CFArrayGetCount(runs); index++) {
    CTRunRef run = (CTRunRef)CFArrayGetValueAtIndex(runs, index);
    NSDictionary *runAttributes = (__bridge NSDictionary *)CTRunGetAttributes(run);
    CTFontRef font = (__bridge CTFontRef)[runAttributes objectForKey:(id)kCTFontAttributeName];
    if (fontIsColorEmoji(font)) {
      result = YES;
      break;
    }
  }
  if (line) CFRelease(line);
  [attributed release];
  CFRelease(baseFont);
  return result;
}

static void maskNonColorEmojiRuns(NSMutableAttributedString *attributed) {
  if (!attributed) return;
  NSColor *transparent = [NSColor colorWithCalibratedWhite:1.0 alpha:0.0];
  CTLineRef line = CTLineCreateWithAttributedString((CFAttributedStringRef)attributed);
  CFArrayRef runs = line ? CTLineGetGlyphRuns(line) : NULL;
  for (CFIndex index = 0; runs && index < CFArrayGetCount(runs); index++) {
    CTRunRef run = (CTRunRef)CFArrayGetValueAtIndex(runs, index);
    NSDictionary *runAttributes = (__bridge NSDictionary *)CTRunGetAttributes(run);
    CTFontRef font = (__bridge CTFontRef)[runAttributes objectForKey:(id)kCTFontAttributeName];
    if (!fontIsColorEmoji(font)) {
      CFRange range = CTRunGetStringRange(run);
      if (range.location != kCFNotFound && range.length > 0) {
        [attributed addAttribute:(id)kCTForegroundColorAttributeName
          value:(id)transparent.CGColor
          range:NSMakeRange((NSUInteger)range.location, (NSUInteger)range.length)];
      }
    }
  }
  if (line) CFRelease(line);
}

static void updateEditorTextTexture(id<MTLDevice> device, NSString *text,
                                    BOOL updateAtlas) {
  if (!device) return;
  // The atlas is the primary committed-text renderer. The Core Text texture
  // remains an overlay for selection, marked composition, and caret, with a
  // complete-text fallback only when atlas generation is unavailable.
  if (updateAtlas) updateEditorGlyphAtlas(device, text);
  const BOOL drawFallbackText = !g_glyph_rendering_available || g_editor_soft_wrap;
  const BOOL drawColorEmojiFallback = textContainsColorEmoji(text) &&
    g_glyph_rendering_available && !g_editor_soft_wrap;
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
  NSArray<NSString *> *lines = editorLinesForText(text);
  NSUInteger startLine = MIN(g_editor_scroll_line, lines.count);
  const CGFloat lineHeight = editorLineHeight();
  NSUInteger visibleLines = MIN(lines.count - startLine,
    (NSUInteger)MAX(1.0, ceil(g_editor_rect[3] / lineHeight)));
  NSUInteger lineStartByte = editorLineUTF8Offset(startLine, lines);
  NSUInteger lineStartUnit = editorLineUTF16Offset(startLine, lines);
  if (g_editor_soft_wrap) {
    NSArray<NSString *> *visible = [lines subarrayWithRange:NSMakeRange(startLine, lines.count - startLine)];
    NSString *wrappedText = [visible componentsJoinedByString:@"\n"];
    NSUInteger wrappedByteLength = [[wrappedText dataUsingEncoding:NSUTF8StringEncoding] length];
    NSMutableAttributedString *wrappedAttributed = [[NSMutableAttributedString alloc]
      initWithString:wrappedText attributes:attributes];
    NSUInteger wrappedLineUnit = 0;
    for (NSUInteger visibleIndex = 0; visibleIndex < visible.count; visibleIndex++) {
      NSString *visibleLine = visible[visibleIndex];
      NSUInteger documentLine = startLine + visibleIndex;
      for (uint32_t hunkIndex = 0; hunkIndex < g_git_hunk_count; hunkIndex++) {
        NimculusGitHunkSpan hunk = g_git_hunks[hunkIndex];
        NSUInteger hunkStart = hunk.start_line;
        NSUInteger hunkEnd = hunkStart + MAX((uint32_t)1, hunk.line_count);
        if (documentLine < hunkStart || documentLine >= hunkEnd || visibleLine.length == 0) continue;
        CGFloat red = 0.30, green = 0.75, blue = 0.42;
        if (hunk.kind == 1) {
          red = 0.92; green = 0.34; blue = 0.34;
        } else if (hunk.kind >= 2) {
          red = 0.35; green = 0.58; blue = 0.95;
        }
        NSColor *diffColor = [NSColor colorWithCalibratedRed:red green:green
          blue:blue alpha:0.10];
        [wrappedAttributed addAttribute:(id)kCTBackgroundColorAttributeName
          value:(id)diffColor.CGColor range:NSMakeRange(wrappedLineUnit, visibleLine.length)];
        break;
      }
      wrappedLineUnit += visibleLine.length + 1;
    }
    for (uint32_t spanIndex = 0; spanIndex < g_highlight_count; spanIndex++) {
      NimculusHighlightSpan span = g_highlights[spanIndex];
      if (span.end_byte <= lineStartByte || span.start_byte >= lineStartByte + wrappedByteLength) continue;
      NSUInteger startByte = MAX((NSUInteger)span.start_byte, lineStartByte) - lineStartByte;
      NSUInteger endByte = MIN((NSUInteger)span.end_byte, lineStartByte + wrappedByteLength) - lineStartByte;
      NSUInteger startUnit = utf16OffsetForUTF8Bytes(wrappedText, startByte);
      NSUInteger endUnit = utf16OffsetForUTF8Bytes(wrappedText, endByte);
      if (endUnit <= startUnit) continue;
      CGFloat red, green, blue;
      highlightColor(span.kind, &red, &green, &blue);
      NSColor *color = [NSColor colorWithCalibratedRed:red green:green blue:blue alpha:1.0];
      [wrappedAttributed addAttribute:(id)kCTForegroundColorAttributeName
        value:(id)color.CGColor range:NSMakeRange(startUnit, endUnit - startUnit)];
    }
    if (g_editor_selection_end > g_editor_selection_start &&
        g_editor_selection_end > lineStartByte &&
        g_editor_selection_start < lineStartByte + wrappedByteLength) {
      NSUInteger startByte = MAX(g_editor_selection_start, lineStartByte) - lineStartByte;
      NSUInteger endByte = MIN(g_editor_selection_end, lineStartByte + wrappedByteLength) - lineStartByte;
      NSUInteger startUnit = utf16OffsetForUTF8Bytes(wrappedText, startByte);
      NSUInteger endUnit = utf16OffsetForUTF8Bytes(wrappedText, endByte);
      if (endUnit > startUnit) {
        NSColor *selectionColor = [themeHexColor(g_theme_selection,
          [NSColor colorWithCalibratedRed:0.20 green:0.40 blue:0.75 alpha:1.0])
          colorWithAlphaComponent:0.45];
        [wrappedAttributed addAttribute:(id)kCTBackgroundColorAttributeName
          value:(id)selectionColor.CGColor range:NSMakeRange(startUnit, endUnit - startUnit)];
      }
    }
    for (uint32_t diagnosticIndex = 0; diagnosticIndex < g_diagnostic_count; diagnosticIndex++) {
      NimculusDiagnosticSpan diagnostic = g_diagnostics[diagnosticIndex];
      if (diagnostic.end_byte <= lineStartByte ||
          diagnostic.start_byte >= lineStartByte + wrappedByteLength) continue;
      NSUInteger startByte = MAX((NSUInteger)diagnostic.start_byte, lineStartByte) - lineStartByte;
      NSUInteger endByte = MIN((NSUInteger)diagnostic.end_byte,
        lineStartByte + wrappedByteLength) - lineStartByte;
      NSUInteger startUnit = utf16OffsetForUTF8Bytes(wrappedText, startByte);
      NSUInteger endUnit = utf16OffsetForUTF8Bytes(wrappedText, endByte);
      if (endUnit <= startUnit) continue;
      [wrappedAttributed addAttribute:(id)kCTUnderlineStyleAttributeName
        value:@(NSUnderlineStyleSingle) range:NSMakeRange(startUnit, endUnit - startUnit)];
    }
    CTFramesetterRef framesetter = CTFramesetterCreateWithAttributedString(
      (CFAttributedStringRef)wrappedAttributed);
    CGMutablePathRef path = CGPathCreateMutable();
    CGPathAddRect(path, NULL, CGRectMake(8.0, 0.0,
      MAX(1.0, g_editor_rect[2] - 8.0), logicalHeight));
    CTFrameRef frame = CTFramesetterCreateFrame(framesetter,
      CFRangeMake(0, wrappedText.length), path, NULL);
    if (frame) {
      CTFrameDraw(frame, context);
      CFRelease(frame);
    }
    CGPathRelease(path);
    CFRelease(framesetter);
    [wrappedAttributed release];
  } else for (NSUInteger displayIndex = 0; displayIndex < visibleLines; displayIndex++) {
    NSUInteger index = startLine + displayIndex;
    NSString *lineText = lines[index];
    NSUInteger lineLength = [[lineText dataUsingEncoding:NSUTF8StringEncoding] length];
    NSUInteger lineEndUnit = lineStartUnit + lineText.length;
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
      // Keep the gutter marker and the document highlight separate, like
      // Zed's diff map: the low-alpha body fill remains readable below text.
      CGContextSetRGBFillColor(context, red, green, blue, 0.10);
      CGContextFillRect(context, CGRectMake(8.0,
        logicalHeight - lineHeight * (displayIndex + 1) - 4.0,
        MAX(1.0, g_editor_rect[2] - 8.0), 20.0));
      break;
    }
    if (g_editor_selection_end > g_editor_selection_start &&
        g_editor_selection_end > lineStartUnit && g_editor_selection_start < lineEndUnit) {
      NSUInteger startUnit = MAX(g_editor_selection_start, lineStartUnit) - lineStartUnit;
      NSUInteger endUnit = MIN(g_editor_selection_end, lineEndUnit) - lineStartUnit;
      NSColor *selectionColor = [themeHexColor(g_theme_selection,
        [NSColor colorWithCalibratedRed:0.20 green:0.40 blue:0.75 alpha:1.0])
        colorWithAlphaComponent:0.45];
      CGContextSetFillColorWithColor(context, selectionColor.CGColor);
      CGContextFillRect(context, CGRectMake(8.0 + editorTextOffset(lineText, startUnit),
        logicalHeight - lineHeight * (displayIndex + 1) - 4.0,
        MAX(1.0, editorTextOffset(lineText, endUnit) - editorTextOffset(lineText, startUnit)), 20.0));
    }
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
    if (drawColorEmojiFallback) maskNonColorEmojiRuns(attributed);
    if (drawFallbackText || drawColorEmojiFallback) {
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
    [attributed release];
    lineStartByte += lineLength + 1;
    lineStartUnit = lineEndUnit + 1;
  }
  BOOL renderingInputPane = (g_editor_input_pane == 1) == g_rendering_secondary_editor;
  BOOL renderingHoverPane = (g_editor_hover_pane == 1) == g_rendering_secondary_editor;
  if (g_marked_text.length > 0 && renderingInputPane) {
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
    [marked release];
  }
  if (g_editor_completions.length > 0 && renderingInputPane) {
    NSArray<NSString *> *completionLines = [g_editor_completions componentsSeparatedByString:@"\n"];
    NSUInteger visibleCount = MIN((NSUInteger)6, completionLines.count);
    CGFloat popupTop = logicalHeight - g_editor_cursor[1] - 4.0;
    CGFloat popupHeight = visibleCount * editorLineHeight() + 6.0;
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
        popupTop - editorLineHeight() * (index + 1) + 3.0);
      CTLineDraw(completionLine, context);
      CFRelease(completionLine);
      [line release];
    }
  }
  if (g_editor_hover.length > 0 && renderingHoverPane) {
    NSArray<NSString *> *hoverLines = [g_editor_hover componentsSeparatedByString:@"\n"];
    NSUInteger visibleCount = MIN((NSUInteger)8, hoverLines.count);
    CGFloat popupTop = logicalHeight - g_editor_hover_position[1] - 4.0;
    CGFloat popupHeight = visibleCount * editorLineHeight() + 8.0;
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
        popupTop - editorLineHeight() * (index + 1) + 4.0);
      CTLineDraw(hoverLine, context);
      CFRelease(hoverLine);
      [line release];
    }
  }
  // A welcome page is a workspace entry surface, not an empty editable
  // buffer. Suppress the text-presenter caret until an actual document opens.
  if (renderingInputPane && !g_welcome_visible) {
    CGContextSetStrokeColorWithColor(context, [NSColor colorWithCalibratedRed:0.85
      green:0.90 blue:1.0 alpha:1.0].CGColor);
    CGContextSetLineWidth(context, 1.0);
    CGFloat caretY = logicalHeight - g_editor_cursor[1] - 4.0;
    CGContextMoveToPoint(context, g_editor_cursor[0], caretY);
    CGContextAddLineToPoint(context, g_editor_cursor[0], caretY + 20.0);
    CGContextStrokePath(context);
  }
  CFRelease(font);
  CGContextRelease(context);
  MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
    width:width height:height mipmapped:NO];
  descriptor.usage = MTLTextureUsageShaderRead;
  [g_text_texture release];
  g_text_texture = [device newTextureWithDescriptor:descriptor];
  [g_text_texture replaceRegion:MTLRegionMake2D(0, 0, width, height)
    mipmapLevel:0 withBytes:pixels.bytes bytesPerRow:width * 4];
  g_text_texture_scale = scale;
}

static void rebuildSecondaryEditorTexture(id<MTLDevice> device) {
  if (!device || !g_secondary_editor_visible) {
    [g_secondary_text_texture release]; g_secondary_text_texture = nil;
    return;
  }
  // Keep primary GPU glyphs untouched. The secondary pane starts with the
  // complete Core Text fallback; its independent atlas is introduced only
  // once pane-local styling and invalidation are fully separated.
  double previousRect[4] = {g_editor_rect[0], g_editor_rect[1],
    g_editor_rect[2], g_editor_rect[3]};
  double previousCursor[2] = {g_editor_cursor[0], g_editor_cursor[1]};
  NSUInteger previousScrollLine = g_editor_scroll_line;
  NSUInteger previousSelectionStart = g_editor_selection_start;
  NSUInteger previousSelectionEnd = g_editor_selection_end;
  BOOL previousSoftWrap = g_editor_soft_wrap;
  BOOL previousGlyphRendering = g_glyph_rendering_available;
  id<MTLTexture> primaryTexture = [g_text_texture retain];
  memcpy(g_editor_rect, g_secondary_editor_rect, sizeof(g_editor_rect));
  memcpy(g_editor_cursor, g_secondary_editor_cursor, sizeof(g_editor_cursor));
  g_editor_scroll_line = g_secondary_editor_scroll_line;
  g_editor_selection_start = g_secondary_editor_selection_start;
  g_editor_selection_end = g_secondary_editor_selection_end;
  g_editor_soft_wrap = g_secondary_editor_soft_wrap;
  g_glyph_rendering_available = NO;
  BOOL previousRenderingSecondary = g_rendering_secondary_editor;
  g_rendering_secondary_editor = YES;
  swapEditorTextState();
  updateEditorTextTexture(device, g_editor_text, NO);
  swapEditorTextState();
  g_rendering_secondary_editor = previousRenderingSecondary;
  [g_secondary_text_texture release];
  g_secondary_text_texture = [g_text_texture retain];
  [g_text_texture release];
  g_text_texture = primaryTexture;
  g_glyph_rendering_available = previousGlyphRendering;
  memcpy(g_editor_rect, previousRect, sizeof(g_editor_rect));
  memcpy(g_editor_cursor, previousCursor, sizeof(g_editor_cursor));
  g_editor_scroll_line = previousScrollLine;
  g_editor_selection_start = previousSelectionStart;
  g_editor_selection_end = previousSelectionEnd;
  g_editor_soft_wrap = previousSoftWrap;
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
    [g_glyph_atlas_texture release];
    g_glyph_atlas_texture = [device newTextureWithDescriptor:descriptor];
    g_glyph_atlas_scale = scale;
    [g_glyph_atlas_entries release];
    g_glyph_atlas_entries = [[NSMutableDictionary alloc] init];
    g_glyph_atlas_next_x = 0;
    g_glyph_atlas_next_y = 0;
    g_glyph_atlas_row_height = 0;
  }
  if (!g_glyph_atlas_entries) g_glyph_atlas_entries = [[NSMutableDictionary alloc] init];
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
                               CGFloat scale, uint8_t variantX, uint8_t variantY,
                               NimculusGlyphAtlasEntry *entry) {
  if (!device || !font || !entry) return NO;
  NSString *fontName = (__bridge_transfer NSString *)CTFontCopyPostScriptName(font);
  NSString *key = [NSString stringWithFormat:@"%@|%.3f|%.3f|%u|%u|%u",
    fontName ?: @"system", CTFontGetSize(font), scale, (unsigned)glyph,
    (unsigned)variantX, (unsigned)variantY];
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
  CGPoint origin = CGPointMake((CGFloat)padding / scale - bounds.origin.x +
      (CGFloat)variantX / (CGFloat)(NIMCULUS_SUBPIXEL_VARIANTS_X * scale),
    (CGFloat)padding / scale - bounds.origin.y +
      (CGFloat)variantY / (CGFloat)(NIMCULUS_SUBPIXEL_VARIANTS_Y * scale));
  CTFontDrawGlyphs(font, &glyph, &origin, 1, context);
  CGContextRelease(context);
  // Core Text rasterizes into the bitmap's opposite row order from the Metal
  // texture coordinates used by the editor. Normalize the atlas payload once
  // at insertion time, rather than flipping every glyph quad at draw time.
  uint8_t *pixelRows = pixels.mutableBytes;
  uint8_t *rowScratch = malloc(width);
  if (!rowScratch) return NO;
  for (NSUInteger row = 0; row < height / 2; row++) {
    uint8_t *top = pixelRows + row * width;
    uint8_t *bottom = pixelRows + (height - row - 1) * width;
    memcpy(rowScratch, top, width);
    memcpy(top, bottom, width);
    memcpy(bottom, rowScratch, width);
  }
  free(rowScratch);
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
  // CGBitmapContext stores the baseline-facing rows at the beginning of the
  // uploaded texture. Metal texture coordinates address that row at v = 0,
  // so map the screen-bottom vertices to the atlas start without flipping.
  float v0 = (float)entry.y / 2048.0f;
  float v1 = (float)(entry.y + entry.height) / 2048.0f;
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
  resetGlyphVertices();
  if (!device) return;
  // The atlas is currently R8 monochrome. Zed separates polychrome emoji
  // sprites into a different atlas. Keep ordinary glyph runs in this atlas
  // and let the RGBA Core Text texture render only the color-emoji runs.
  CGFloat scale = g_metrics.scale_factor > 0.0 ? g_metrics.scale_factor : 1.0;
  ensureGlyphAtlas(device, scale);
  uint64_t evictionCountBefore = g_glyph_atlas_eviction_count;
  CTFontRef baseFont = editorFont();
  if (!baseFont) return;
  NSColor *baseColor = themeHexColor(g_theme_foreground,
    [NSColor colorWithCalibratedRed:0.85 green:0.90 blue:1.0 alpha:1.0]);
  NSDictionary *attributes = @{ (id)kCTFontAttributeName: (__bridge id)baseFont,
    (id)kCTForegroundColorAttributeName: (id)baseColor.CGColor };
  NSArray<NSString *> *lines = editorLinesForText(text);
  NSUInteger startLine = MIN(g_editor_scroll_line, lines.count);
  const CGFloat lineHeight = editorLineHeight();
  NSUInteger visibleLines = MIN(lines.count - startLine,
    (NSUInteger)MAX(1.0, ceil(g_editor_rect[3] / lineHeight)));
  NSUInteger lineStartByte = editorLineUTF8Offset(startLine, lines);
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
      CFIndex *stringIndices = malloc(sizeof(CFIndex) * (NSUInteger)glyphCount);
      if (!glyphs || !positions || !stringIndices) {
        free(glyphs); free(positions); free(stringIndices); continue;
      }
      CTRunGetGlyphs(run, CFRangeMake(0, glyphCount), glyphs);
      CTRunGetPositions(run, CFRangeMake(0, glyphCount), positions);
      CTRunGetStringIndices(run, CFRangeMake(0, glyphCount), stringIndices);
      for (CFIndex glyphIndex = 0; glyphIndex < glyphCount; glyphIndex++) {
        BOOL colorEmojiGlyph = stringIndices[glyphIndex] != kCFNotFound
          ? colorEmojiAtUTF16Index(lineText, (NSUInteger)stringIndices[glyphIndex], NULL)
          : fontIsColorEmoji(font);
        if (colorEmojiGlyph) continue;
        CGFloat scaledX = positions[glyphIndex].x * scale;
        CGFloat scaledY = (baselineY + positions[glyphIndex].y) * scale;
        CGFloat quantizedX = round(scaledX * NIMCULUS_SUBPIXEL_VARIANTS_X) /
          (NIMCULUS_SUBPIXEL_VARIANTS_X * scale);
        CGFloat quantizedY = round(scaledY * NIMCULUS_SUBPIXEL_VARIANTS_Y) /
          (NIMCULUS_SUBPIXEL_VARIANTS_Y * scale);
        CGFloat fractionalX = quantizedX * scale - floor(quantizedX * scale);
        CGFloat fractionalY = quantizedY * scale - floor(quantizedY * scale);
        uint8_t variantX = (uint8_t)MIN(NIMCULUS_SUBPIXEL_VARIANTS_X - 1,
          MAX(0, (int)round(fractionalX * NIMCULUS_SUBPIXEL_VARIANTS_X)));
        uint8_t variantY = (uint8_t)MIN(NIMCULUS_SUBPIXEL_VARIANTS_Y - 1,
          MAX(0, (int)round(fractionalY * NIMCULUS_SUBPIXEL_VARIANTS_Y)));
        // quantizedX/Y are already returned to logical points above. Dividing
        // by scale here a second time shifted glyphs on Retina displays.
        CGPoint quantizedPosition = CGPointMake(quantizedX,
          quantizedY - baselineY);
        NimculusGlyphAtlasEntry entry;
        if (atlasEntryForGlyph(device, font, glyphs[glyphIndex], scale,
            variantX, variantY, &entry)) {
          appendGlyphQuad(sceneSize, editorRect, scale, entry, quantizedPosition, baselineY,
            red, green, blue, alpha);
        }
      }
      free(glyphs);
      free(positions);
      free(stringIndices);
    }
    CFRelease(line);
    [attributed release];
    lineStartByte += lineLength + 1;
  }
  CFRelease(baseFont);
  // Atlas eviction invalidates every UV emitted before the eviction. Rebuild
  // the complete visible batch against the new atlas, just as Zed rebuilds a
  // sprite batch when its atlas allocation changes. If the visible batch
  // cannot fit after one retry, use the established Core Text fallback rather
  // than presenting a mixture of stale and current atlas coordinates.
  if (g_glyph_atlas_eviction_count != evictionCountBefore) {
    if (!g_glyph_atlas_rebuild_in_progress) {
      g_glyph_atlas_rebuild_in_progress = YES;
      updateEditorGlyphAtlas(device, text);
      g_glyph_atlas_rebuild_in_progress = NO;
      return;
    }
    resetGlyphVertices();
    return;
  }
  g_glyph_rendering_available = g_glyph_pipeline != nil && g_glyph_vertex_count > 0;
}

static double millisecondsSince(uint64_t start) {
  mach_timebase_info_data_t timebase;
  mach_timebase_info(&timebase);
  uint64_t nanos = (mach_absolute_time() - start) * timebase.numer / timebase.denom;
  return (double)nanos / 1000000.0;
}

static void recordInputLatencySample(double milliseconds, uint64_t eventCount) {
  if (milliseconds < 0.0) return;
  uint64_t index = g_input_latency_sample_count % NIMCULUS_INPUT_LATENCY_HISTORY;
  g_input_latency_history[index] = milliseconds;
  g_input_events_per_frame_history[index] = eventCount;
  g_input_latency_sample_count++;
}

static void recordFrameTimingSample(double milliseconds) {
  if (milliseconds < 0.0) return;
  uint64_t index = g_frame_timing_sample_count % NIMCULUS_FRAME_TIMING_HISTORY;
  g_frame_timing_history[index] = milliseconds;
  g_frame_timing_sample_count++;
}

static BOOL logInput(NSString *kind, NSEvent *event) {
  if (g_first_input_time == 0) g_first_input_time = mach_absolute_time();
  g_input_count++;
  g_input_latency_event_count++;
  g_pending_input_event_count++;
  NSPoint location = event.locationInWindow;
  if (g_active_view) {
    location = [(NSView *)g_active_view convertPoint:event.locationInWindow fromView:nil];
  }
  // AppKit only defines keyCode for keyboard events. Reading it for tracking
  // or mouse events raises an NSInternalInconsistencyException on recent
  // macOS versions (notably for MouseEntered/MouseExited).
  const BOOL hasKeyCode = event.type == NSEventTypeKeyDown ||
    event.type == NSEventTypeKeyUp || event.type == NSEventTypeFlagsChanged;
  const unsigned short keyCode = hasKeyCode ? event.keyCode : 0;
  // deltaX/deltaY and hasPreciseScrollingDeltas are defined only for scroll
  // wheel events. AppKit raises NSInternalInconsistencyException when a
  // synthetic or live key event is asked for scrolling properties.
  const BOOL isScrollWheel = event.type == NSEventTypeScrollWheel;
  // AppKit's scrollingDelta values are the canonical scroll-wheel values.
  // For ordinary wheels they are line-oriented; for trackpads they preserve
  // the precise pixel delta advertised by hasPreciseScrollingDeltas.
  const CGFloat deltaX = isScrollWheel ? event.scrollingDeltaX : 0.0;
  const CGFloat deltaY = isScrollWheel ? event.scrollingDeltaY : 0.0;
  const BOOL preciseScrolling = isScrollWheel && event.hasPreciseScrollingDeltas;
  NSLog(@"Nimculus input kind=%@ keyCode=%hu modifiers=0x%lx x=%.1f y=%.1f dx=%.1f dy=%.1f",
        kind, keyCode, event.modifierFlags, location.x, location.y,
        deltaX, deltaY);
  if (g_input_callback) {
    NimculusInputEvent input = {
      .type = (uint32_t)event.type,
      .key_code = keyCode,
      .modifiers = (uint32_t)event.modifierFlags,
      .button = mouseButtonForEvent(event),
      .x = location.x, .y = location.y,
      .delta_x = deltaX, .delta_y = deltaY,
      .precise_scrolling = preciseScrolling,
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

@interface NimculusTerminalSessionBar : NSView
@property(nonatomic, retain) NSPopUpButton *sessionPicker;
@property(nonatomic, retain) NSButton *newButton;
@property(nonatomic, retain) NSButton *closeButton;
- (void)reloadSessions;
@end

@interface NimculusTaskOutputOverlay : NSTextView
@end

@interface NimculusOutputPanelBar : NSView
@property(nonatomic, retain) NSTextField *titleLabel;
@property(nonatomic, retain) NSButton *closeButton;
- (void)reloadTitle;
@end

@interface NimculusOutlineOverlay : NSTextView
@end

@interface NimculusLineNumberOverlay : NSView
@end

@interface NimculusIndentGuideOverlay : NSView
@end

@interface NimculusTabBarOverlay : NSView
@property(nonatomic) BOOL secondary;
- (void)dispatchTabAtPoint:(NSPoint)point;
@end

@interface NimculusWelcomeOverlay : NSView
@end

@interface NimculusGitSidebarTabs : NSSegmentedControl
@end

@interface NimculusGitCommitButton : NSButton
@end

@interface NimculusFilesSidebarActions : NSStackView
 - (void)reloadActions;
@end

@interface NimculusWorkspaceToolbar : NSStackView
- (void)reloadSelection;
@end

@interface NimculusActivityBar : NSStackView
- (void)reloadSelection;
- (void)dispatchWorkspaceCommand:(NSButton *)sender;
@end

@interface NimculusStatusOverlay : NSTextField
@end

@interface NimculusEditorAnnotationOverlay : NSView
@end

@implementation NimculusTerminalOverlay
- (BOOL)acceptsFirstResponder { return NO; }
- (NSView *)hitTest:(NSPoint)point { return nil; }
@end

// Zed keeps terminal creation and pane selection in the terminal tab bar.
// Nimculus has one terminal pane today, so a native popup scales to any number
// of sessions while keeping creation and closing continuously reachable.
@implementation NimculusTerminalSessionBar
- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (!self) return nil;
  self.wantsLayer = YES;
  self.layer.backgroundColor = [themeHexColor(g_theme_background,
    [NSColor colorWithCalibratedRed:0.045 green:0.055 blue:0.075 alpha:1.0]) CGColor];
  self.sessionPicker = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
  self.sessionPicker.bezelStyle = NSBezelStyleTexturedRounded;
  self.sessionPicker.target = self;
  self.sessionPicker.action = @selector(selectSession:);
  [self addSubview:self.sessionPicker];
  self.newButton = [[NSButton alloc] initWithFrame:NSZeroRect];
  self.newButton.title = @"+";
  self.newButton.toolTip = @"New Terminal";
  self.newButton.bezelStyle = NSBezelStyleTexturedRounded;
  self.newButton.target = self;
  self.newButton.action = @selector(newTerminal:);
  [self addSubview:self.newButton];
  self.closeButton = [[NSButton alloc] initWithFrame:NSZeroRect];
  self.closeButton.title = @"×";
  self.closeButton.toolTip = @"Close Terminal";
  self.closeButton.bezelStyle = NSBezelStyleTexturedRounded;
  self.closeButton.target = self;
  self.closeButton.action = @selector(closeTerminal:);
  [self addSubview:self.closeButton];
  [self reloadSessions];
  return self;
}
- (void)dealloc {
  [_sessionPicker release]; [_newButton release]; [_closeButton release];
  [super dealloc];
}
- (void)layout {
  [super layout];
  CGFloat buttonWidth = 28.0, inset = 5.0;
  CGFloat height = MAX(20.0, self.bounds.size.height - 4.0);
  CGFloat pickerWidth = MAX(96.0, self.bounds.size.width - inset * 2.0 - buttonWidth * 2.0 - 8.0);
  self.sessionPicker.frame = NSMakeRect(inset, 2.0, pickerWidth, height);
  self.newButton.frame = NSMakeRect(inset + pickerWidth + 4.0, 2.0, buttonWidth, height);
  self.closeButton.frame = NSMakeRect(inset + pickerWidth + buttonWidth + 8.0, 2.0, buttonWidth, height);
}
- (void)reloadSessions {
  [self.sessionPicker removeAllItems];
  for (NSString *title in g_terminal_session_titles ?: @[]) {
    [self.sessionPicker addItemWithTitle:title.length > 0 ? title : @"Terminal"];
  }
  if (g_terminal_session_titles.count > 0) {
    [self.sessionPicker selectItemAtIndex:MIN(g_terminal_active_session,
      g_terminal_session_titles.count - 1)];
  }
  self.sessionPicker.enabled = g_terminal_session_titles.count > 0;
  self.closeButton.enabled = g_terminal_session_titles.count > 0;
  [self setNeedsLayout:YES];
}
- (void)selectSession:(id)sender {
  (void)sender;
  if (g_command_callback && self.sessionPicker.indexOfSelectedItem >= 0) {
    NSString *command = [NSString stringWithFormat:@"terminalSession:%ld", (long)self.sessionPicker.indexOfSelectedItem];
    g_command_callback(command.UTF8String);
  }
}
- (void)newTerminal:(id)sender { (void)sender; if (g_command_callback) g_command_callback("terminalNew"); }
- (void)closeTerminal:(id)sender { (void)sender; if (g_command_callback) g_command_callback("terminalClose"); }
@end

@implementation NimculusTaskOutputOverlay
// Unlike the live terminal, an output/commit inspector has no PTY input to
// protect. Keep it read-only but let AppKit own selection, copy, and wheel
// scrolling so users can actually inspect a long commit diff or task result.
- (BOOL)acceptsFirstResponder { return YES; }
- (NSView *)hitTest:(NSPoint)point {
  return NSPointInRect(point, self.bounds) ? self : nil;
}
@end

// Output is shared by tasks, Git commit details, and LSP result lists. Give
// that presenter an explicit identity and dismissal affordance instead of
// making it look like anonymous terminal text.
@implementation NimculusOutputPanelBar
- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (!self) return nil;
  self.wantsLayer = YES;
  self.layer.backgroundColor = [NSColor colorWithCalibratedRed:0.075 green:0.067 blue:0.052 alpha:0.98].CGColor;
  self.titleLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
  self.titleLabel.editable = NO;
  self.titleLabel.selectable = NO;
  self.titleLabel.bezeled = NO;
  self.titleLabel.drawsBackground = NO;
  self.titleLabel.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightSemibold];
  self.titleLabel.textColor = [NSColor colorWithCalibratedRed:0.92 green:0.88 blue:0.76 alpha:1.0];
  [self addSubview:self.titleLabel];
  self.closeButton = [[NSButton alloc] initWithFrame:NSZeroRect];
  self.closeButton.title = @"×";
  self.closeButton.toolTip = @"Close Output Panel";
  self.closeButton.bezelStyle = NSBezelStyleTexturedRounded;
  self.closeButton.target = self;
  self.closeButton.action = @selector(closeOutput:);
  [self addSubview:self.closeButton];
  [self reloadTitle];
  return self;
}
- (void)dealloc { [_titleLabel release]; [_closeButton release]; [super dealloc]; }
- (void)layout {
  [super layout];
  self.titleLabel.frame = NSMakeRect(9.0, 4.0, MAX(1.0, self.bounds.size.width - 46.0),
    MAX(18.0, self.bounds.size.height - 7.0));
  self.closeButton.frame = NSMakeRect(MAX(1.0, self.bounds.size.width - 33.0), 2.0, 28.0,
    MAX(20.0, self.bounds.size.height - 4.0));
}
- (void)reloadTitle {
  self.titleLabel.stringValue = g_task_output_title.length > 0 ? g_task_output_title : @"Output";
  [self setNeedsLayout:YES];
}
- (void)closeOutput:(id)sender { (void)sender; if (g_command_callback) g_command_callback("closeOutputPanel"); }
@end

@implementation NimculusOutlineOverlay
- (BOOL)acceptsFirstResponder { return YES; }
- (NSView *)hitTest:(NSPoint)point {
  return NSPointInRect(point, self.bounds) ? self : nil;
}
- (NSUInteger)sidebarItemForLine:(NSUInteger)line {
  if (g_editor_outline_symbol_count == 0 || line < 2) return NSNotFound;
  NSUInteger item = line - 2;
  return item < g_editor_outline_symbol_count ? item : NSNotFound;
}
- (void)dispatchSidebarSelection:(NSUInteger)item {
  if (item == NSNotFound || !g_command_callback) return;
  NSString *command = [NSString stringWithFormat:@"sidebarSelect:%lu", (unsigned long)item];
  g_command_callback(command.UTF8String);
}
- (void)dispatchSidebarOpen:(NSUInteger)item {
  if (item == NSNotFound || !g_command_callback) return;
  NSString *command = g_editor_sidebar_mode == 0 ?
    [NSString stringWithFormat:@"commandPalette:open symbol %lu", (unsigned long)item + 1] :
    [NSString stringWithFormat:@"sidebarOpen:%lu", (unsigned long)item];
  g_command_callback(command.UTF8String);
}
- (void)dispatchSidebarContext:(NSUInteger)item {
  // Files, History, and Status have explicit row menus. Branches deliberately
  // switch on activation only, so right-click must not emit a dead command.
  if (item == NSNotFound || !g_command_callback || g_editor_sidebar_mode < 1 ||
      g_editor_sidebar_mode > 3) return;
  NSString *command = [NSString stringWithFormat:@"sidebarContext:%lu", (unsigned long)item];
  g_command_callback(command.UTF8String);
}
- (void)dispatchSidebarLine:(NSUInteger)line open:(BOOL)open {
  NSUInteger item = [self sidebarItemForLine:line];
  if (open) [self dispatchSidebarOpen:item];
  else [self dispatchSidebarSelection:item];
}
- (void)mouseDown:(NSEvent *)event {
  [self.window makeFirstResponder:self];
  NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
  NSUInteger index = [self characterIndexForInsertionAtPoint:point];
  NSUInteger line = 0;
  for (NSUInteger offset = 0; offset < MIN(index, self.string.length); offset++) {
    if ([self.string characterAtIndex:offset] == '\n') line++;
  }
  [self dispatchSidebarLine:line open:NO];
}
- (void)mouseUp:(NSEvent *)event {
  if (event.clickCount < 2) return;
  NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
  NSUInteger index = [self characterIndexForInsertionAtPoint:point];
  NSUInteger line = 0;
  for (NSUInteger offset = 0; offset < MIN(index, self.string.length); offset++) {
    if ([self.string characterAtIndex:offset] == '\n') line++;
  }
  [self dispatchSidebarLine:line open:YES];
}
- (void)rightMouseDown:(NSEvent *)event {
  [self.window makeFirstResponder:self];
  NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
  NSUInteger index = [self characterIndexForInsertionAtPoint:point];
  NSUInteger line = 0;
  for (NSUInteger offset = 0; offset < MIN(index, self.string.length); offset++) {
    if ([self.string characterAtIndex:offset] == '\n') line++;
  }
  NSUInteger item = [self sidebarItemForLine:line];
  [self dispatchSidebarSelection:item];
  [self dispatchSidebarContext:item];
}
- (void)keyDown:(NSEvent *)event {
  if (!g_command_callback) { [super keyDown:event]; return; }
  const unsigned short key = event.keyCode;
  const char *command = key == 126 ? "sidebarPrevious" :
    key == 125 ? "sidebarNext" : key == 115 ? "sidebarFirst" :
    key == 119 ? "sidebarLast" : (key == 36 || key == 76) ? "sidebarOpenSelected" : NULL;
  if (command) {
    g_command_callback(command);
    return;
  }
  [super keyDown:event];
}
@end

@implementation NimculusLineNumberOverlay
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return NO; }
- (NSView *)hitTest:(NSPoint)point { (void)point; return nil; }
- (void)drawRect:(NSRect)dirtyRect {
  (void)dirtyRect;
  NSArray<NSString *> *lines = editorLinesForText(g_editor_text);
  if (lines.count == 0) return;
  NSUInteger first = MIN(g_editor_scroll_line, lines.count - 1);
  NSDictionary *attributes = @{
    NSFontAttributeName: [NSFont monospacedSystemFontOfSize:11.0 weight:NSFontWeightRegular],
    NSForegroundColorAttributeName: [themeHexColor(g_theme_foreground,
      [NSColor colorWithCalibratedRed:0.72 green:0.76 blue:0.82 alpha:1.0])
      colorWithAlphaComponent:0.58]
  };
  NSUInteger visibleRows = 0;
  NSUInteger maxRows = (NSUInteger)MAX(1.0, ceil(self.bounds.size.height / editorLineHeight()));
  for (NSUInteger index = first; index < lines.count && visibleRows < maxRows; index++) {
    NSString *number = [NSString stringWithFormat:@"%lu", (unsigned long)index + 1];
    NSSize size = [number sizeWithAttributes:attributes];
    CGFloat y = visibleRows * editorLineHeight() + 1.0;
    [number drawAtPoint:NSMakePoint(MAX(2.0, self.bounds.size.width - size.width - 6.0), y)
      withAttributes:attributes];
    visibleRows += g_editor_soft_wrap ? editorSoftWrapRowCount(lines[index]) : 1;
  }
}
@end

@implementation NimculusIndentGuideOverlay
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return NO; }
- (NSView *)hitTest:(NSPoint)point { (void)point; return nil; }
- (void)drawRect:(NSRect)dirtyRect {
  (void)dirtyRect;
  if (!g_editor_indent_guides) return;
  NSArray<NSString *> *lines = editorLinesForText(g_editor_text);
  if (lines.count == 0) return;
  CGFloat characterWidth = 7.2;
  NSUInteger indentWidth = MAX((NSUInteger)1, g_editor_indent_width);
  NSUInteger first = MIN(g_editor_scroll_line, lines.count - 1);
  CGFloat lineHeight = editorLineHeight();
  NSColor *color = [themeHexColor(g_theme_border,
    [NSColor colorWithCalibratedRed:0.30 green:0.34 blue:0.40 alpha:1.0])
    colorWithAlphaComponent:0.52];
  [color setFill];
  NSUInteger visibleRows = 0;
  for (NSUInteger index = first; index < lines.count; index++) {
    if (visibleRows * lineHeight >= self.bounds.size.height) break;
    NSString *text = lines[index];
    NSUInteger columns = 0;
    for (NSUInteger character = 0; character < text.length; character++) {
      unichar unit = [text characterAtIndex:character];
      if (unit == ' ') columns++;
      else if (unit == '\t') columns += indentWidth;
      else break;
    }
    for (NSUInteger guide = indentWidth; guide <= columns; guide += indentWidth) {
      NSRect line = NSMakeRect(8.0 + characterWidth * guide,
        visibleRows * lineHeight, 1.0, lineHeight);
      NSRectFill(line);
    }
    visibleRows += g_editor_soft_wrap ? editorSoftWrapRowCount(text) : 1;
  }
}
@end

@implementation NimculusTabBarOverlay
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return NO; }
- (NSView *)hitTest:(NSPoint)point { return NSPointInRect(point, self.bounds) ? self : nil; }
- (void)drawRect:(NSRect)dirtyRect {
  (void)dirtyRect;
  [[NSColor colorWithCalibratedWhite:0.08 alpha:0.98] setFill];
  NSRectFill(self.bounds);
  NSArray<NSString *> *titles = self.secondary ? g_secondary_editor_tab_titles : g_editor_tab_titles;
  NSUInteger active = self.secondary ? g_secondary_editor_active_tab : g_editor_active_tab;
  if (titles.count == 0) return;
  CGFloat tabWidth = MAX(120.0, self.bounds.size.width / titles.count);
  NSDictionary *attributes = @{
    NSFontAttributeName: [NSFont systemFontOfSize:12.0],
    NSForegroundColorAttributeName: [themeHexColor(g_theme_foreground,
      [NSColor colorWithCalibratedWhite:0.88 alpha:1.0]) colorWithAlphaComponent:0.92]
  };
  for (NSUInteger index = 0; index < titles.count; index++) {
    CGFloat x = index * tabWidth;
    if (index == active) {
      [[themeHexColor(g_theme_accent,
        [NSColor colorWithCalibratedRed:0.25 green:0.62 blue:0.95 alpha:1.0])
        colorWithAlphaComponent:0.20] setFill];
      NSRectFill(NSMakeRect(x, 0.0, tabWidth, self.bounds.size.height));
    }
    NSString *title = titles[index] ?: @"Untitled";
    NSRect titleRect = NSMakeRect(x + 10.0, 5.0, MAX(12.0, tabWidth - 34.0),
      self.bounds.size.height - 8.0);
    [title drawWithRect:titleRect options:NSStringDrawingTruncatesLastVisibleLine |
      NSStringDrawingUsesLineFragmentOrigin attributes:attributes context:nil];
    // Zed exposes a close target for every closable tab (normally on hover).
    // A lightweight custom AppKit tab bar has no hover renderer yet, so keep
    // the target visible with a muted inactive treatment rather than hiding
    // the only discoverable close affordance on background documents.
    NSDictionary *closeAttributes = @{
      NSFontAttributeName: [NSFont systemFontOfSize:16.0 weight:NSFontWeightMedium],
      NSForegroundColorAttributeName: [themeHexColor(g_theme_foreground,
        [NSColor colorWithCalibratedWhite:0.88 alpha:1.0])
        colorWithAlphaComponent:index == active ? 0.86 : 0.52]
    };
    [@"×" drawAtPoint:NSMakePoint(x + tabWidth - 21.0, 4.0) withAttributes:closeAttributes];
  }
}
- (void)mouseDown:(NSEvent *)event {
  [self dispatchTabAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
}
- (void)dispatchTabAtPoint:(NSPoint)point {
  NSArray<NSString *> *titles = self.secondary ? g_secondary_editor_tab_titles : g_editor_tab_titles;
  if (!g_command_callback || titles.count == 0) return;
  CGFloat tabWidth = MAX(120.0, self.bounds.size.width / titles.count);
  NSUInteger index = MIN(titles.count - 1,
    (NSUInteger)MAX(0.0, floor(point.x / tabWidth)));
  if (point.x >= (index + 1) * tabWidth - 28.0) {
    NSString *command = [NSString stringWithFormat:@"closePaneTab:%u:%lu",
      self.secondary ? 1 : 0, (unsigned long)index];
    g_command_callback(command.UTF8String);
    return;
  }
  NSString *command = [NSString stringWithFormat:@"selectPaneTab:%u:%lu",
    self.secondary ? 1 : 0, (unsigned long)index];
  g_command_callback(command.UTF8String);
}
@end

@implementation NimculusWelcomeOverlay
- (BOOL)isFlipped { return YES; }
- (void)layout {
  [super layout];
  NSView *stack = self.subviews.firstObject;
  CGFloat width = MIN(420.0, MAX(280.0, self.bounds.size.width - 48.0));
  CGFloat height = 250.0;
  stack.frame = NSMakeRect(floor((self.bounds.size.width - width) * 0.5),
    MAX(24.0, floor((self.bounds.size.height - height) * 0.40)), width, height);
}
- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (!self) return nil;
  self.wantsLayer = YES;
  NSStackView *stack = [[NSStackView alloc] initWithFrame:NSZeroRect];
  stack.orientation = NSUserInterfaceLayoutOrientationVertical;
  stack.alignment = NSLayoutAttributeCenterX;
  stack.spacing = 12.0;
  NSTextField *title = [NSTextField labelWithString:@"Welcome to Nimculus"];
  title.font = [NSFont systemFontOfSize:25.0 weight:NSFontWeightSemibold];
  title.textColor = themeHexColor(g_theme_foreground,
    [NSColor colorWithCalibratedWhite:0.90 alpha:1.0]);
  NSTextField *subtitle = [NSTextField labelWithString:@"Open a project or start editing a file."];
  subtitle.textColor = [themeHexColor(g_theme_foreground,
    [NSColor colorWithCalibratedWhite:0.72 alpha:1.0]) colorWithAlphaComponent:0.78];
  [stack addArrangedSubview:title];
  [stack addArrangedSubview:subtitle];
  [stack setCustomSpacing:24.0 afterView:subtitle];
  NSArray<NSArray *> *buttons = @[
    @[@"Open Folder…", @"openFolder:"], @[@"Open File…", @"openFile:"],
    @[@"New File", @"newFile:"], @[@"Open Recent…", @"openRecentFile:"]
  ];
  for (NSUInteger index = 0; index < buttons.count; index++) {
    NSArray *entry = buttons[index];
    NSButton *button = [NSButton buttonWithTitle:entry[0] target:self
      action:NSSelectorFromString(entry[1])];
    button.bordered = NO;
    button.wantsLayer = YES;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.layer.cornerRadius = 6.0;
    const BOOL primary = index == 0;
    button.layer.backgroundColor = [(primary
      ? themeHexColor(g_theme_accent,
          [NSColor colorWithCalibratedRed:0.25 green:0.62 blue:0.95 alpha:1.0])
      : [themeHexColor(g_theme_foreground,
          [NSColor colorWithCalibratedWhite:0.88 alpha:1.0]) colorWithAlphaComponent:0.11]) CGColor];
    button.attributedTitle = [[[NSAttributedString alloc] initWithString:entry[0]
      attributes:@{NSForegroundColorAttributeName: primary ? NSColor.whiteColor :
          themeHexColor(g_theme_foreground, [NSColor colorWithCalibratedWhite:0.90 alpha:1.0]),
        NSFontAttributeName: [NSFont systemFontOfSize:13.0 weight:NSFontWeightMedium]}] autorelease];
    [stack addArrangedSubview:button];
    [[button.widthAnchor constraintEqualToConstant:260.0] setActive:YES];
    [[button.heightAnchor constraintEqualToConstant:34.0] setActive:YES];
  }
  [self addSubview:stack];
  [stack release];
  return self;
}
- (void)newFile:(id)sender { (void)sender; if (g_command_callback) g_command_callback("newDocument"); }
- (void)openFile:(id)sender { (void)sender; [[NSApp delegate] openDocument:nil]; }
- (void)openFolder:(id)sender { (void)sender; [[NSApp delegate] openWorkspaceFolder:nil]; }
- (void)openRecentFile:(id)sender { (void)sender; [[NSApp delegate] openRecent:nil]; }
@end

// Zed exposes Changes and History as visible panel tabs. Keep the same primary
// navigation in the compact native Git sidebar, with Branches alongside the
// existing checkout workflow.
@implementation NimculusGitSidebarTabs
- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (!self) return nil;
  self.segmentCount = 3;
  [self setLabel:@"Changes" forSegment:0];
  [self setLabel:@"History" forSegment:1];
  [self setLabel:@"Branches" forSegment:2];
  self.segmentStyle = NSSegmentStyleTexturedRounded;
  self.trackingMode = NSSegmentSwitchTrackingSelectOne;
  self.target = self;
  self.action = @selector(selectGitSidebarMode:);
  return self;
}
- (void)selectGitSidebarMode:(id)sender {
  (void)sender;
  if (!g_command_callback) return;
  const char *command = self.selectedSegment == 1 ? "commandPalette:git log" :
    self.selectedSegment == 2 ? "commandPalette:git branches" : "commandPalette:git status";
  g_command_callback(command);
}
@end

// Commit is a primary Changes-panel operation in Zed. Keep the compact
// equivalent beside the Changes/History/Branches selector rather than making
// users reopen the command palette just to enter a message.
@implementation NimculusGitCommitButton
- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (!self) return nil;
  self.title = @"Commit…";
  self.bezelStyle = NSBezelStyleTexturedRounded;
  self.toolTip = @"Commit staged changes";
  self.target = self;
  self.action = @selector(requestCommit:);
  return self;
}
- (void)requestCommit:(id)sender {
  (void)sender;
  if (g_command_callback) g_command_callback("gitCommitPrompt");
}
@end

// Zed exposes project creation from the Project Panel itself. Keep the action
// visible in Nimculus Files while delegating prompts and validation to the
// existing macOS/Nim workspace path.
@implementation NimculusFilesSidebarActions
- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (!self) return nil;
  self.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  self.alignment = NSLayoutAttributeCenterY;
  self.distribution = NSStackViewDistributionFillEqually;
  self.spacing = 6.0;
  [self reloadActions];
  return self;
}
- (void)reloadActions {
  NSArray<NSView *> *previous = [self.arrangedSubviews copy];
  for (NSView *view in previous) {
    [self removeArrangedSubview:view];
    [view removeFromSuperview];
  }
  [previous release];
  NSArray<NSArray<NSString *> *> *buttons = g_workspace_open ? @[
    @[@"New File", @"createWorkspaceFile:"], @[@"New Folder", @"createWorkspaceDirectory:"]
  ] : @[@[@"Open Folder…", @"openWorkspaceFolder:"]];
  for (NSArray<NSString *> *entry in buttons) {
    NSButton *button = [NSButton buttonWithTitle:entry[0] target:self
      action:@selector(dispatchWorkspaceAction:)];
    button.bezelStyle = NSBezelStyleTexturedRounded;
    button.identifier = entry[1];
    [self addArrangedSubview:button];
  }
}
- (void)dispatchWorkspaceAction:(NSButton *)sender {
  SEL action = NSSelectorFromString(sender.identifier);
  id delegate = [NSApp delegate];
  if (delegate && [delegate respondsToSelector:action]) {
    [delegate performSelector:action withObject:self];
  }
}
@end

// Zed places workspace-level panel controls in persistent chrome rather than
// leaving an empty strip above editor tabs. Keep the controls native and route
// every action through the existing Nim command boundary.
@implementation NimculusWorkspaceToolbar
- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (!self) return nil;
  self.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  self.alignment = NSLayoutAttributeCenterY;
  self.distribution = NSStackViewDistributionFillProportionally;
  self.spacing = 6.0;
  NSArray<NSArray<NSString *> *> *buttons = @[
    @[@"Files", @"commandPalette:show files"],
    @[@"Outline", @"commandPalette:show outline"],
    @[@"Git", @"commandPalette:git status"],
    @[@"Terminal", @"commandPalette:toggle terminal"]
  ];
  for (NSArray<NSString *> *entry in buttons) {
    NSButton *button = [NSButton buttonWithTitle:entry[0] target:self
      action:@selector(dispatchWorkspaceCommand:)];
    button.bezelStyle = NSBezelStyleTexturedRounded;
    button.identifier = entry[1];
    [self addArrangedSubview:button];
  }
  [self reloadSelection];
  return self;
}
- (void)reloadSelection {
  // The workspace toolbar is persistent chrome, not a row of unrelated
  // commands. Match Zed's active-panel affordance so the currently presented
  // sidebar (or bottom terminal) remains legible even after focus moves into
  // the editor.
  for (NSView *view in self.arrangedSubviews) {
    if (![view isKindOfClass:[NSButton class]]) continue;
    NSButton *button = (NSButton *)view;
    NSString *command = button.identifier;
    BOOL active = [command isEqualToString:@"commandPalette:show files"] ?
        g_editor_sidebar_visible && g_editor_sidebar_mode == 1 :
      [command isEqualToString:@"commandPalette:show outline"] ?
        g_editor_sidebar_visible && g_editor_sidebar_mode == 0 :
      [command isEqualToString:@"commandPalette:git status"] ?
        g_editor_sidebar_visible && g_editor_sidebar_mode >= 2 && g_editor_sidebar_mode <= 4 :
      [command isEqualToString:@"commandPalette:toggle terminal"] ? g_terminal_visible : NO;
    button.contentTintColor = active ? themeHexColor(g_theme_accent,
      [NSColor controlAccentColor]) : nil;
    button.toolTip = active ? [NSString stringWithFormat:@"%@ (active)", button.title] :
      button.title;
  }
}
- (void)dispatchWorkspaceCommand:(NSButton *)sender {
  if (g_command_callback && sender.identifier.length > 0) {
    g_command_callback(sender.identifier.UTF8String);
  }
}
@end

// Zed keeps workspace navigation at the left edge, independently of the
// current editor tab. This compact activity bar makes the same destinations
// reachable without consuming document or tree space with text-only controls.
@implementation NimculusActivityBar
- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (!self) return nil;
  self.orientation = NSUserInterfaceLayoutOrientationVertical;
  self.alignment = NSLayoutAttributeCenterX;
  self.distribution = NSStackViewDistributionGravityAreas;
  self.spacing = 7.0;
  NSArray<NSArray<NSString *> *> *buttons = @[
    @[@"folder", @"Files", @"commandPalette:show files"],
    @[@"list.bullet", @"Outline", @"commandPalette:show outline"],
    @[@"arrow.triangle.branch", @"Git", @"commandPalette:git status"],
    @[@"terminal", @"Terminal", @"commandPalette:toggle terminal"]
  ];
  for (NSArray<NSString *> *entry in buttons) {
    NSButton *button = [NSButton buttonWithTitle:entry[1] target:self
      action:@selector(dispatchWorkspaceCommand:)];
    if (@available(macOS 11.0, *)) {
      button.image = [NSImage imageWithSystemSymbolName:entry[0]
        accessibilityDescription:entry[1]];
      button.imagePosition = NSImageOnly;
    }
    button.bezelStyle = NSBezelStyleTexturedRounded;
    button.identifier = entry[2];
    button.toolTip = entry[1];
    [button setFrameSize:NSMakeSize(28.0, 26.0)];
    [self addArrangedSubview:button];
  }
  [self reloadSelection];
  return self;
}
- (void)reloadSelection {
  for (NSView *view in self.arrangedSubviews) {
    if (![view isKindOfClass:[NSButton class]]) continue;
    NSButton *button = (NSButton *)view;
    NSString *command = button.identifier;
    BOOL active = [command isEqualToString:@"commandPalette:show files"] ?
        g_editor_sidebar_visible && g_editor_sidebar_mode == 1 :
      [command isEqualToString:@"commandPalette:show outline"] ?
        g_editor_sidebar_visible && g_editor_sidebar_mode == 0 :
      [command isEqualToString:@"commandPalette:git status"] ?
        g_editor_sidebar_visible && g_editor_sidebar_mode >= 2 && g_editor_sidebar_mode <= 4 :
      [command isEqualToString:@"commandPalette:toggle terminal"] ? g_terminal_visible : NO;
    button.contentTintColor = active ? themeHexColor(g_theme_accent,
      [NSColor controlAccentColor]) : nil;
  }
}
- (void)dispatchWorkspaceCommand:(NSButton *)sender {
  if (g_command_callback && sender.identifier.length > 0) {
    g_command_callback(sender.identifier.UTF8String);
  }
}
@end

@implementation NimculusStatusOverlay
- (BOOL)acceptsFirstResponder { return NO; }
- (NSView *)hitTest:(NSPoint)point { (void)point; return nil; }
@end

@implementation NimculusEditorAnnotationOverlay
- (BOOL)isFlipped { return YES; }
- (NSView *)hitTest:(NSPoint)point { return nil; }
- (void)drawRect:(NSRect)dirtyRect {
  (void)dirtyRect;
  NSDictionary *attributes = @{
    NSFontAttributeName: [NSFont fontWithName:@"Menlo-Italic" size:11.0] ?:
      [NSFont monospacedSystemFontOfSize:11.0 weight:NSFontWeightRegular],
    NSForegroundColorAttributeName: [themeHexColor(g_theme_accent,
      [NSColor colorWithCalibratedRed:0.35 green:0.65 blue:0.95 alpha:0.82])
      colorWithAlphaComponent:0.78]
  };
  for (uint32_t index = 0; index < g_editor_annotation_count; index++) {
    if (!g_editor_annotation_texts || index >= g_editor_annotation_texts.count) continue;
    NSString *text = g_editor_annotation_texts[index];
    if (text.length == 0) continue;
    NimculusEditorAnnotation annotation = g_editor_annotations[index];
    if ((NSUInteger)annotation.line < g_editor_scroll_line) continue;
    NSUInteger documentOffset = editorDocumentOffsetForLineCharacter(
      annotation.line, annotation.character);
    CGPoint point = editorPointForUTF16Offset(documentOffset);
    CGFloat x = (CGFloat)g_editor_rect[0] + point.x;
    CGFloat y = (CGFloat)g_editor_rect[1] + point.y + 2.0;
    if (y < g_editor_rect[1]) continue;
    if (y > self.bounds.size.height || x > self.bounds.size.width) continue;
    [text drawAtPoint:NSMakePoint(x, y) withAttributes:attributes];
  }
}
@end

static NimculusOutlineOverlay *outlineOverlayForView(NSView *view) {
  if (!view) return nil;
  for (NSView *subview in view.subviews) {
    if ([subview isKindOfClass:[NimculusOutlineOverlay class]]) {
      return (NimculusOutlineOverlay *)subview;
    }
    if ([subview isKindOfClass:[NSScrollView class]] &&
        [((NSScrollView *)subview).documentView isKindOfClass:[NimculusOutlineOverlay class]]) {
      return (NimculusOutlineOverlay *)((NSScrollView *)subview).documentView;
    }
  }
  return nil;
}

// The project, outline, and Git presenters currently share an NSTextView so
// keyboard navigation and selection keep one native contract. Give that
// compact presenter the same information hierarchy as a panel rather than
// rendering the workspace as an editor-sized block of plain text.
static void applySidebarPresentation(NimculusOutlineOverlay *outline) {
  if (!outline) return;
  NSString *text = g_editor_outline_text ?: @"";
  NSColor *foreground = themeHexColor(g_theme_foreground,
    [NSColor colorWithCalibratedWhite:0.84 alpha:1.0]);
  NSMutableAttributedString *presented = [[NSMutableAttributedString alloc]
    initWithString:text attributes:@{
      NSFontAttributeName: [NSFont systemFontOfSize:13.0],
      NSForegroundColorAttributeName: [foreground colorWithAlphaComponent:0.88]
    }];
  NSUInteger cursor = 0;
  NSUInteger line = 0;
  while (cursor < text.length) {
    NSRange newline = [text rangeOfString:@"\n" options:0
      range:NSMakeRange(cursor, text.length - cursor)];
    NSUInteger end = newline.location == NSNotFound ? text.length : newline.location;
    NSRange range = NSMakeRange(cursor, end - cursor);
    NSString *content = range.length > 0 ? [text substringWithRange:range] : @"";
    if (line == 0) {
      [presented addAttributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:13.0 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: foreground
      } range:range];
    } else if (line == 1) {
      [presented addAttribute:NSForegroundColorAttributeName
        value:[themeHexColor(g_theme_border,
          [NSColor colorWithCalibratedWhite:0.30 alpha:1.0]) colorWithAlphaComponent:0.70]
        range:range];
    } else if (g_editor_sidebar_mode == 1) {
      // Project rows retain their textual disclosure markers, but make them
      // read as a hierarchy affordance instead of part of a file name.
      NSRange expanded = [content rangeOfString:@"▾"];
      NSRange collapsed = [content rangeOfString:@"▸"];
      NSRange marker = expanded.location != NSNotFound ? expanded : collapsed;
      if (marker.location != NSNotFound) {
        marker.location += range.location;
        [presented addAttributes:@{
          NSFontAttributeName: [NSFont systemFontOfSize:12.0 weight:NSFontWeightSemibold],
          NSForegroundColorAttributeName: [themeHexColor(g_theme_accent,
            [NSColor colorWithCalibratedRed:0.31 green:0.66 blue:0.97 alpha:1.0])
            colorWithAlphaComponent:0.90]
        } range:marker];
      }
    } else if (g_editor_sidebar_mode == 3) {
      // Surface conflicts and Git's two-column porcelain status separately
      // from the file path, following the Git panel's status-first scan.
      NSUInteger prefixLength = [content hasPrefix:@"CONFLICT "] ? 8 :
        MIN((NSUInteger)2, content.length);
      if (prefixLength > 0) {
        NSColor *stateColor = [content hasPrefix:@"CONFLICT "]
          ? [NSColor systemRedColor]
          : themeHexColor(g_theme_accent,
              [NSColor colorWithCalibratedRed:0.31 green:0.66 blue:0.97 alpha:1.0]);
        [presented addAttributes:@{
          NSFontAttributeName: [NSFont monospacedSystemFontOfSize:12.0 weight:NSFontWeightSemibold],
          NSForegroundColorAttributeName: stateColor
        } range:NSMakeRange(range.location, prefixLength)];
      }
    } else if (g_editor_sidebar_mode == 2 && content.length >= 8) {
      // Commit hashes are stable scan anchors; distinguish them from the
      // subject/author without making history rows multi-line and ambiguous.
      [presented addAttributes:@{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:12.0 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: [themeHexColor(g_theme_accent,
          [NSColor colorWithCalibratedRed:0.31 green:0.66 blue:0.97 alpha:1.0])
          colorWithAlphaComponent:0.92]
      } range:NSMakeRange(range.location, MIN((NSUInteger)8, range.length))];
    }
    if (newline.location == NSNotFound) break;
    cursor = NSMaxRange(newline);
    line++;
  }
  [outline.textStorage setAttributedString:presented];
  [presented release];
}

static NSUInteger terminalUTF16OffsetForCell(uint32_t row, uint32_t column) {
  NSData *utf8 = [g_terminal_text dataUsingEncoding:NSUTF8StringEncoding];
  const uint8_t *bytes = utf8.bytes;
  NSUInteger rowStart = 0;
  uint32_t currentRow = 0;
  if (bytes) {
    for (NSUInteger index = 0; index < utf8.length && currentRow < row; index++) {
      if (bytes[index] == '\n') {
        currentRow++;
        rowStart = index + 1;
      }
    }
  }
  rowStart = MIN(rowStart, utf8.length);
  NSUInteger target = rowStart;
  for (uint32_t index = 0; index < g_terminal_run_count; index++) {
    NimculusTerminalRun run = g_terminal_runs[index];
    if (run.row != row) continue;
    uint32_t width = run.cell_width > 0 ? run.cell_width : 1;
    if (column <= run.column) {
      target = run.start_byte;
      break;
    }
    if (column < run.column + width) {
      target = run.end_byte;
      break;
    }
    target = run.end_byte;
  }
  return utf16OffsetForUTF8Bytes(g_terminal_text, target);
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
  terminal.selectedTextAttributes = @{
    NSBackgroundColorAttributeName: [themeHexColor(g_theme_selection,
      [NSColor colorWithCalibratedRed:0.20 green:0.40 blue:0.75 alpha:1.0])
      colorWithAlphaComponent:0.65]
  };
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

static NSFont *terminalBaseFont(void) {
  NSFont *font = [NSFont fontWithName:g_terminal_font_name size:g_terminal_font_size];
  // A terminal is a cell grid. A proportional user selection cannot preserve
  // the PTY's column coordinates, so retain the requested font only when it
  // is fixed pitch and otherwise fall back to AppKit's fixed-pitch face.
  if (!font || !font.isFixedPitch) {
    font = [NSFont monospacedSystemFontOfSize:g_terminal_font_size
                                       weight:NSFontWeightRegular];
  }
  return font;
}

static CGFloat terminalCellWidth(void) {
  return MAX(1.0, terminalBaseFont().maximumAdvancement.width);
}

static CGFloat terminalLineHeight(void) {
  NSLayoutManager *layoutManager = [[NSLayoutManager alloc] init];
  CGFloat height = [layoutManager defaultLineHeightForFont:terminalBaseFont()];
  [layoutManager release];
  return MAX(1.0, height);
}

static void applyTerminalRuns(NSTextView *terminal) {
  if (!terminal) return;
  NSMutableAttributedString *attributed = [[NSMutableAttributedString alloc]
    initWithString:g_terminal_text ?: @"" attributes:@{
      NSFontAttributeName: terminalBaseFont(),
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
    NSFont *font = terminalBaseFont();
    if (run.flags & 1) font = [[NSFontManager sharedFontManager] convertFont:font toHaveTrait:NSBoldFontMask] ?: font;
    if (run.flags & 4) font = [[NSFontManager sharedFontManager] convertFont:font toHaveTrait:NSItalicFontMask] ?: font;
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
  [attributed release];
}

bool nimculus_platform_validate_terminal_overlay_runs(void) {
  // Keep the cell-grid and AppKit text boundaries coupled: a terminal run
  // carries UTF-8 ranges for styling but row/column/cell-width coordinates
  // for selection. This mirrors Zed's separation of terminal cells from the
  // native text presentation layer.
  @autoreleasepool {
    const char *text = "A\xE6\x97\xA5\nB";
    const char *link = "https://example.invalid/terminal";
    NimculusTerminalRun runs[3] = {
      { .start_byte = 0, .end_byte = 1, .flags = 1, .row = 0, .column = 0,
        .cell_width = 1, .foreground_kind = 1, .foreground_index = 9 },
      { .start_byte = 1, .end_byte = 4, .flags = 8, .row = 0, .column = 1,
        .cell_width = 2, .foreground_kind = 2, .foreground_red = 12,
        .foreground_green = 160, .foreground_blue = 220, .hyperlink_uri = link },
      { .start_byte = 5, .end_byte = 6, .flags = 16 | 32, .row = 1, .column = 0,
        .cell_width = 1, .background_kind = 1, .background_index = 4 }
    };
    nimculus_platform_set_terminal_runs(text, 6, runs, 3);
    nimculus_platform_set_terminal_selection(0, 1, 1, 1);
    NimculusTerminalOverlay *terminal = [[NimculusTerminalOverlay alloc]
      initWithFrame:NSMakeRect(0, 0, 320, 120)];
    terminal.editable = NO;
    terminal.selectable = YES;
    applyTerminalRuns(terminal);
    NSAttributedString *storage = terminal.textStorage;
    NSDictionary *wideAttributes = [storage attributesAtIndex:1 effectiveRange:NULL];
    NSDictionary *lastAttributes = [storage attributesAtIndex:3 effectiveRange:NULL];
    NSFont *firstFont = [storage attribute:NSFontAttributeName atIndex:0 effectiveRange:NULL];
    BOOL bold = (firstFont.fontDescriptor.symbolicTraits & NSFontBoldTrait) != 0;
    BOOL linked = [[wideAttributes objectForKey:NSLinkAttributeName] isEqualToString:@(link)];
    BOOL underlined = [[wideAttributes objectForKey:NSUnderlineStyleAttributeName] integerValue] != 0;
    BOOL stricken = [[lastAttributes objectForKey:NSStrikethroughStyleAttributeName] integerValue] != 0;
    BOOL selected = NSEqualRanges(terminal.selectedRange, NSMakeRange(1, 3));
    BOOL valid = [storage.string isEqualToString:@"A日\nB"] && bold && linked && underlined &&
      stricken && selected;
    [terminal release];
    nimculus_platform_set_terminal_runs("", 0, NULL, 0);
    nimculus_platform_set_terminal_selection(0, 0, 0, 0);
    return valid;
  }
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
    NimculusActivityBar *activityBar = [[NimculusActivityBar alloc]
      initWithFrame:NSZeroRect];
    [self addSubview:activityBar];
    [activityBar release];
    NimculusOutlineOverlay *outline = [[NimculusOutlineOverlay alloc]
      initWithFrame:NSZeroRect];
    outline.editable = NO;
    outline.selectable = YES;
    outline.drawsBackground = YES;
    outline.backgroundColor = [themeHexColor(g_theme_background,
      [NSColor colorWithCalibratedRed:0.045 green:0.055 blue:0.075 alpha:1.0])
      colorWithAlphaComponent:0.96];
    outline.textColor = themeHexColor(g_theme_foreground,
      [NSColor colorWithCalibratedRed:0.82 green:0.88 blue:0.92 alpha:1.0]);
    outline.font = [NSFont systemFontOfSize:13.0];
    outline.textContainerInset = NSMakeSize(8.0, 8.0);
    outline.horizontallyResizable = NO;
    outline.verticallyResizable = YES;
    outline.textContainer.widthTracksTextView = YES;
    applySidebarPresentation(outline);
    NSScrollView *outlineScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    outlineScroll.borderType = NSNoBorder;
    outlineScroll.drawsBackground = NO;
    outlineScroll.hasVerticalScroller = YES;
    outlineScroll.autohidesScrollers = YES;
    outlineScroll.documentView = outline;
    [self addSubview:outlineScroll];
    [outlineScroll release];
    [outline release];
    NimculusGitSidebarTabs *gitTabs = [[NimculusGitSidebarTabs alloc]
      initWithFrame:NSZeroRect];
    gitTabs.hidden = YES;
    [self addSubview:gitTabs];
    [gitTabs release];
    NimculusGitCommitButton *gitCommit = [[NimculusGitCommitButton alloc]
      initWithFrame:NSZeroRect];
    gitCommit.hidden = YES;
    [self addSubview:gitCommit];
    [gitCommit release];
    NimculusFilesSidebarActions *filesActions = [[NimculusFilesSidebarActions alloc]
      initWithFrame:NSZeroRect];
    filesActions.hidden = YES;
    [self addSubview:filesActions];
    [filesActions release];
    NimculusWorkspaceToolbar *workspaceToolbar = [[NimculusWorkspaceToolbar alloc]
      initWithFrame:NSZeroRect];
    [self addSubview:workspaceToolbar];
    [workspaceToolbar release];
    NimculusLineNumberOverlay *lineNumbers = [[NimculusLineNumberOverlay alloc]
      initWithFrame:NSZeroRect];
    [self addSubview:lineNumbers];
    NimculusIndentGuideOverlay *indentGuides = [[NimculusIndentGuideOverlay alloc]
      initWithFrame:NSZeroRect];
    [self addSubview:indentGuides];
    NimculusTabBarOverlay *tabs = [[NimculusTabBarOverlay alloc]
      initWithFrame:NSZeroRect];
    tabs.secondary = NO;
    [self addSubview:tabs];
    NimculusTabBarOverlay *secondaryTabs = [[NimculusTabBarOverlay alloc]
      initWithFrame:NSZeroRect];
    secondaryTabs.secondary = YES;
    [self addSubview:secondaryTabs];
    NimculusWelcomeOverlay *welcome = [[NimculusWelcomeOverlay alloc]
      initWithFrame:NSZeroRect];
    welcome.hidden = !g_welcome_visible;
    [self addSubview:welcome];
    [welcome release];
    NimculusStatusOverlay *status = [[NimculusStatusOverlay alloc]
      initWithFrame:NSZeroRect];
    status.editable = NO;
    status.selectable = NO;
    status.bezeled = NO;
    status.drawsBackground = NO;
    status.alignment = NSTextAlignmentLeft;
    status.stringValue = g_editor_status;
    status.font = [NSFont monospacedSystemFontOfSize:11.0 weight:NSFontWeightRegular];
    status.textColor = [themeHexColor(g_theme_foreground,
      [NSColor colorWithCalibratedRed:0.72 green:0.76 blue:0.82 alpha:1.0])
      colorWithAlphaComponent:0.82];
    [self addSubview:status];
    NimculusTerminalSessionBar *terminalSessions = [[NimculusTerminalSessionBar alloc]
      initWithFrame:NSZeroRect];
    terminalSessions.hidden = YES;
    [self addSubview:terminalSessions];
    [terminalSessions release];
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
    terminal.font = terminalBaseFont();
    terminal.textContainerInset = NSMakeSize(8.0, 6.0);
    // Preserve the PTY's explicit row breaks. The terminal grid owns columns;
    // NSTextView must not silently reflow rows when the overlay is resized.
    terminal.textContainer.lineFragmentPadding = 0.0;
    terminal.textContainer.widthTracksTextView = NO;
    terminal.textContainer.containerSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
    terminal.horizontallyResizable = YES;
    terminal.verticallyResizable = NO;
    terminal.hidden = YES;
    [self addSubview:terminal];
    NimculusOutputPanelBar *outputBar = [[NimculusOutputPanelBar alloc]
      initWithFrame:NSZeroRect];
    outputBar.hidden = YES;
    [self addSubview:outputBar];
    [outputBar release];
    NimculusTaskOutputOverlay *taskOutput = [[NimculusTaskOutputOverlay alloc]
      initWithFrame:NSZeroRect];
    taskOutput.editable = NO;
    taskOutput.selectable = YES;
    taskOutput.drawsBackground = YES;
    taskOutput.backgroundColor = [NSColor colorWithCalibratedRed:0.045 green:0.040 blue:0.030 alpha:0.98];
    taskOutput.textColor = [NSColor colorWithCalibratedRed:0.92 green:0.88 blue:0.76 alpha:1.0];
    taskOutput.font = [NSFont fontWithName:g_terminal_font_name size:g_terminal_font_size] ?: [NSFont monospacedSystemFontOfSize:g_terminal_font_size weight:NSFontWeightRegular];
    taskOutput.textContainerInset = NSMakeSize(8.0, 6.0);
    taskOutput.hidden = YES;
    [self addSubview:taskOutput];
    NimculusEditorAnnotationOverlay *annotations =
      [[NimculusEditorAnnotationOverlay alloc] initWithFrame:self.bounds];
    annotations.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    annotations.hidden = YES;
    [self addSubview:annotations];
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
  NimculusOutlineOverlay *outline = outlineOverlayForView(self);
  NimculusGitSidebarTabs *gitTabs = nil;
  NimculusGitCommitButton *gitCommit = nil;
  NimculusActivityBar *activityBar = nil;
  NimculusFilesSidebarActions *filesActions = nil;
  NimculusWorkspaceToolbar *workspaceToolbar = nil;
  NimculusLineNumberOverlay *lineNumbers = nil;
  NimculusIndentGuideOverlay *indentGuides = nil;
  NimculusTabBarOverlay *tabs = nil;
  NimculusTabBarOverlay *secondaryTabs = nil;
  NimculusWelcomeOverlay *welcome = nil;
  NimculusStatusOverlay *status = nil;
  NimculusTerminalOverlay *terminal = nil;
  NimculusTerminalSessionBar *terminalSessions = nil;
  NimculusOutputPanelBar *outputBar = nil;
  NimculusTaskOutputOverlay *taskOutput = nil;
  NimculusEditorAnnotationOverlay *annotations = nil;
  for (NSView *subview in self.subviews) {
    if ([subview isKindOfClass:[NimculusLineNumberOverlay class]]) lineNumbers = (NimculusLineNumberOverlay *)subview;
    if ([subview isKindOfClass:[NimculusIndentGuideOverlay class]]) indentGuides = (NimculusIndentGuideOverlay *)subview;
    if ([subview isKindOfClass:[NimculusTabBarOverlay class]]) {
      if (((NimculusTabBarOverlay *)subview).secondary) secondaryTabs = (NimculusTabBarOverlay *)subview;
      else tabs = (NimculusTabBarOverlay *)subview;
    }
    if ([subview isKindOfClass:[NimculusWelcomeOverlay class]]) welcome = (NimculusWelcomeOverlay *)subview;
    if ([subview isKindOfClass:[NimculusStatusOverlay class]]) status = (NimculusStatusOverlay *)subview;
    if ([subview isKindOfClass:[NimculusTerminalOverlay class]]) terminal = (NimculusTerminalOverlay *)subview;
    if ([subview isKindOfClass:[NimculusTerminalSessionBar class]]) terminalSessions = (NimculusTerminalSessionBar *)subview;
    if ([subview isKindOfClass:[NimculusOutputPanelBar class]]) outputBar = (NimculusOutputPanelBar *)subview;
    if ([subview isKindOfClass:[NimculusTaskOutputOverlay class]]) taskOutput = (NimculusTaskOutputOverlay *)subview;
    if ([subview isKindOfClass:[NimculusEditorAnnotationOverlay class]]) annotations = (NimculusEditorAnnotationOverlay *)subview;
    if ([subview isKindOfClass:[NimculusGitSidebarTabs class]]) gitTabs = (NimculusGitSidebarTabs *)subview;
    if ([subview isKindOfClass:[NimculusGitCommitButton class]]) gitCommit = (NimculusGitCommitButton *)subview;
    if ([subview isKindOfClass:[NimculusFilesSidebarActions class]]) filesActions = (NimculusFilesSidebarActions *)subview;
    if ([subview isKindOfClass:[NimculusWorkspaceToolbar class]]) workspaceToolbar = (NimculusWorkspaceToolbar *)subview;
    if ([subview isKindOfClass:[NimculusActivityBar class]]) activityBar = (NimculusActivityBar *)subview;
  }
  const CGFloat activityBarWidth = 38.0;
  const CGFloat sidebarX = 8.0 + activityBarWidth;
  const CGFloat sidebarControlX = 12.0 + activityBarWidth;
  const CGFloat sidebarWidth = MAX(140.0, g_editor_rect[0] - 12.0 - activityBarWidth);
  if (activityBar) {
    activityBar.hidden = g_welcome_visible || !g_editor_sidebar_visible;
    if (!activityBar.hidden) {
      activityBar.frame = NSMakeRect(4.0, g_editor_rect[1] + 4.0, 30.0,
        MAX(1.0, g_editor_rect[3] - 8.0));
      [activityBar reloadSelection];
    }
  }
  if (outline) {
    CGFloat width = sidebarWidth;
    BOOL showGitTabs = g_editor_sidebar_visible && g_editor_sidebar_mode >= 2 &&
      g_editor_sidebar_mode <= 4;
    BOOL showFilesActions = g_editor_sidebar_visible && g_editor_sidebar_mode == 1;
    CGFloat sidebarToolbarHeight = (showGitTabs || showFilesActions) ? 30.0 : 0.0;
    NSScrollView *scroll = outline.enclosingScrollView;
    if (scroll) {
      scroll.hidden = !g_editor_sidebar_visible;
      scroll.frame = NSMakeRect(sidebarX, g_editor_rect[1], width,
        MAX(1.0, g_editor_rect[3] - sidebarToolbarHeight));
      scroll.autoresizingMask = NSViewHeightSizable | NSViewMaxXMargin;
      outline.textContainer.containerSize = NSMakeSize(MAX(1.0, width - 16.0), CGFLOAT_MAX);
      [outline.layoutManager ensureLayoutForTextContainer:outline.textContainer];
      CGFloat contentHeight = ceil([outline.layoutManager usedRectForTextContainer:outline.textContainer].size.height) + 16.0;
      outline.frame = NSMakeRect(0.0, 0.0, width,
        MAX(g_editor_rect[3] - sidebarToolbarHeight, contentHeight));
    } else {
      outline.frame = NSMakeRect(sidebarX, g_editor_rect[1], width, g_editor_rect[3]);
      outline.autoresizingMask = NSViewHeightSizable | NSViewMaxXMargin;
    }
  }
  if (gitTabs) {
    BOOL showGitTabs = g_editor_sidebar_visible && g_editor_sidebar_mode >= 2 &&
      g_editor_sidebar_mode <= 4;
    gitTabs.hidden = !showGitTabs;
    if (showGitTabs) {
      CGFloat width = sidebarWidth;
      gitTabs.frame = NSMakeRect(sidebarControlX, g_editor_rect[1] + g_editor_rect[3] - 27.0,
        MAX(1.0, width - 86.0), 24.0);
      gitTabs.selectedSegment = (NSInteger)g_editor_sidebar_mode - 2;
    }
  }
  if (gitCommit) {
    BOOL showGitCommit = g_editor_sidebar_visible && g_editor_sidebar_mode >= 2 &&
      g_editor_sidebar_mode <= 4;
    gitCommit.hidden = !showGitCommit;
    if (showGitCommit) {
      CGFloat width = sidebarWidth;
      gitCommit.frame = NSMakeRect(sidebarControlX + width - 80.0,
        g_editor_rect[1] + g_editor_rect[3] - 27.0, 76.0, 24.0);
    }
  }
  if (filesActions) {
    BOOL showFilesActions = g_editor_sidebar_visible && g_editor_sidebar_mode == 1;
    filesActions.hidden = !showFilesActions;
    if (showFilesActions) {
      CGFloat width = sidebarWidth;
      filesActions.frame = NSMakeRect(sidebarControlX, g_editor_rect[1] + g_editor_rect[3] - 27.0,
        MAX(1.0, width - 8.0), 24.0);
    }
  }
  if (workspaceToolbar) {
    workspaceToolbar.hidden = g_welcome_visible;
    [workspaceToolbar reloadSelection];
    workspaceToolbar.frame = NSMakeRect(g_editor_rect[0] + 8.0,
      g_editor_rect[1] + g_editor_rect[3] + 29.0,
      MAX(1.0, g_editor_rect[2] - 16.0), 22.0);
  }
  if (lineNumbers) {
    lineNumbers.hidden = g_welcome_visible || !g_editor_line_numbers;
    lineNumbers.frame = NSMakeRect(0.0, g_editor_rect[1],
      MAX(36.0, g_editor_rect[0] - 8.0), g_editor_rect[3]);
    lineNumbers.autoresizingMask = NSViewHeightSizable | NSViewMaxXMargin;
    [lineNumbers setNeedsDisplay:YES];
  }
  if (indentGuides) {
    indentGuides.hidden = g_welcome_visible;
    indentGuides.frame = NSMakeRect(g_editor_rect[0], g_editor_rect[1],
      g_editor_rect[2], g_editor_rect[3]);
    indentGuides.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [indentGuides setNeedsDisplay:YES];
  }
  if (tabs) {
    tabs.hidden = g_editor_tab_titles.count == 0;
    tabs.frame = NSMakeRect(g_editor_rect[0], g_editor_rect[1] + g_editor_rect[3],
      g_editor_rect[2], 28.0);
    tabs.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [tabs setNeedsDisplay:YES];
  }
  if (secondaryTabs) {
    secondaryTabs.hidden = !g_secondary_editor_visible || g_secondary_editor_tab_titles.count == 0;
    secondaryTabs.frame = NSMakeRect(g_secondary_editor_rect[0],
      g_secondary_editor_rect[1] + g_secondary_editor_rect[3],
      g_secondary_editor_rect[2], 28.0);
    secondaryTabs.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [secondaryTabs setNeedsDisplay:YES];
  }
  if (welcome) {
    welcome.hidden = !g_welcome_visible;
    welcome.frame = NSMakeRect(g_editor_rect[0], g_editor_rect[1],
      g_editor_rect[2], g_editor_rect[3]);
    [welcome setNeedsLayout:YES];
  }
  if (status) {
    status.frame = NSMakeRect(g_editor_rect[0], 2.0, g_editor_rect[2], 20.0);
    status.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
  }
  if (annotations) {
    annotations.frame = self.bounds;
    annotations.hidden = g_editor_annotation_count == 0;
    [annotations setNeedsDisplay:YES];
  }
  if (!terminal || !terminalSessions || !outputBar || !taskOutput) return;
  BOOL panelVisible = g_terminal_visible || g_task_output_visible;
  CGFloat height = panelVisible ? MIN(180.0, MAX(72.0, g_editor_rect[3] * 0.42)) : 0.0;
  CGFloat x = g_editor_rect[0];
  CGFloat width = g_editor_rect[2];
  CGFloat top = g_editor_rect[1] + g_editor_rect[3] - height;
  if (g_terminal_panel_rect[2] > 0.0 && g_terminal_panel_rect[3] > 0.0) {
    x = g_terminal_panel_rect[0];
    width = g_terminal_panel_rect[2];
    height = g_terminal_panel_rect[3];
    top = g_terminal_panel_rect[1];
  }
  terminal.hidden = !g_terminal_visible;
  terminalSessions.hidden = !g_terminal_visible;
  outputBar.hidden = !g_task_output_visible;
  taskOutput.hidden = !g_task_output_visible;
  if (!g_terminal_visible && !g_task_output_visible) return;
  CGFloat y = self.bounds.size.height - top - height;
  CGFloat sessionBarHeight = g_terminal_visible ? 27.0 : 0.0;
  CGFloat outputBarHeight = g_task_output_visible ? 27.0 : 0.0;
  terminalSessions.frame = NSMakeRect(x, y + height - sessionBarHeight, width, sessionBarHeight);
  outputBar.frame = NSMakeRect(x, y + height - outputBarHeight, width, outputBarHeight);
  terminal.frame = NSMakeRect(x, y, width, MAX(1.0, height - sessionBarHeight));
  taskOutput.frame = NSMakeRect(x, y, width, MAX(1.0, height - outputBarHeight));
  terminal.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
  terminalSessions.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
  outputBar.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
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

- (void)viewDidChangeEffectiveAppearance {
  [super viewDidChangeEffectiveAppearance];
  // Match Zed's native appearance callback: a system theme must repaint as
  // soon as AppKit changes this window's effective Light/Dark appearance.
  if (g_command_callback) g_command_callback("appearanceChanged");
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
    // A damage list is meaningful only when the retained scene already has a
    // complete previous frame. On the first frame, after a drawable-size
    // change, or after the Metal device is recreated, the scene texture is
    // new and must be rebuilt in full. Zed's renderer likewise treats a new
    // render target as a full scene submission rather than replaying only the
    // invalidated rectangles.
    const BOOL fullSceneRebuild = sceneNeedsFullRebuild(g_scene_initialized,
                                                        g_paint_dirty_count);
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
      if (fullSceneRebuild) {
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
      if (fullSceneRebuild) {
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
      if (fullSceneRebuild) {
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
      [glyphBuffer release];
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
      if (fullSceneRebuild) {
        MTLScissorRect fullScissor = {0, 0, scene.width, scene.height};
        [encoder setScissorRect:fullScissor];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
      } else {
        for (uint32_t i = 0; i < g_paint_dirty_count; i++) {
          setScissorForRegion(encoder, g_paint_dirty_regions[i], logicalSize, drawableSize);
          [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        }
      }
      [textBuffer release];
    }
    if (g_text_pipeline && g_secondary_text_texture && g_secondary_editor_visible) {
      const float left = (float)(g_secondary_editor_rect[0] / logicalSize.width * 2.0 - 1.0);
      const float right = (float)((g_secondary_editor_rect[0] + g_secondary_editor_rect[2]) / logicalSize.width * 2.0 - 1.0);
      const float top = (float)(1.0 - g_secondary_editor_rect[1] / logicalSize.height * 2.0);
      const float bottom = (float)(1.0 - (g_secondary_editor_rect[1] + g_secondary_editor_rect[3]) / logicalSize.height * 2.0);
      const float vertices[] = {left, top, 0, 0, right, top, 1, 0, left, bottom, 0, 1, right, bottom, 1, 1};
      id<MTLBuffer> buffer = [drawable.texture.device newBufferWithBytes:vertices length:sizeof(vertices) options:MTLResourceStorageModeShared];
      [encoder setRenderPipelineState:g_text_pipeline];
      [encoder setVertexBuffer:buffer offset:0 atIndex:0];
      [encoder setFragmentTexture:g_secondary_text_texture atIndex:0];
      MTLScissorRect scissor = {0, 0, scene.width, scene.height};
      [encoder setScissorRect:scissor];
      [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
      [buffer release];
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
  recordFrameTimingSample(g_metrics.last_frame_time_ms);
  if (g_first_input_time != 0) {
    g_metrics.last_input_latency_ms = millisecondsSince(g_first_input_time);
    recordInputLatencySample(g_metrics.last_input_latency_ms, g_pending_input_event_count);
    g_first_input_time = 0;
    g_pending_input_event_count = 0;
  }
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
  NSString *text = (g_editor_input_pane == 1 ? g_secondary_editor_text : g_editor_text) ?: @"";
  NSRange actual = boundedDocumentRange(range, text.length);
  if (actualRange) *actualRange = actual;
  return [[[NSAttributedString alloc] initWithString:[text substringWithRange:actual]] autorelease];
}
- (NSAttributedString *)attributedString {
  // This optional NSTextInputClient method describes the committed document,
  // not the transient marked composition. Zed does not register the optional
  // selector, but since Nimculus exposes it, return the actual document.
  NSString *text = (g_editor_input_pane == 1 ? g_secondary_editor_text : g_editor_text) ?: @"";
  return [[[NSAttributedString alloc] initWithString:text] autorelease];
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
    ? (g_editor_input_pane == 1
        ? NSMakeRange(g_secondary_editor_selection_start,
                      g_secondary_editor_selection_end - g_secondary_editor_selection_start)
        : NSMakeRange(g_editor_selection_start,
                      g_editor_selection_end - g_editor_selection_start))
    : replacementRange;
  NSString *text = g_editor_input_pane == 1 ? g_secondary_editor_text : g_editor_text;
  NSUInteger textLength = text.length;
  NSRange boundedReplacement = boundedDocumentRange(effectiveReplacement, textLength);
  NSUInteger replacementStart = boundedReplacement.location;
  NSUInteger replacementEnd = NSMaxRange(boundedReplacement);
  uint32_t startByte = (uint32_t)utf8BytesForDocumentUTF16Offset(text, replacementStart);
  uint32_t endByte = (uint32_t)utf8BytesForDocumentUTF16Offset(text, replacementEnd);
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
    NSString *text = g_editor_input_pane == 1 ? g_secondary_editor_text : g_editor_text;
    NSUInteger textLength = text.length;
    NSRange boundedReplacement = boundedDocumentRange(replacementRange, textLength);
    NSUInteger startUnit = boundedReplacement.location;
    NSUInteger endUnit = NSMaxRange(boundedReplacement);
    uint32_t startByte = (uint32_t)utf8BytesForDocumentUTF16Offset(text, startUnit);
    uint32_t endByte = (uint32_t)utf8BytesForDocumentUTF16Offset(text, endUnit);
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
  else if ([name isEqualToString:@"moveToBeginningOfDocumentAndModifySelection:"]) { if (g_command_callback) g_command_callback("selectToBeginningOfDocument"); }
  else if ([name isEqualToString:@"moveToEndOfDocumentAndModifySelection:"]) { if (g_command_callback) g_command_callback("selectToEndOfDocument"); }
  else if ([name isEqualToString:@"insertNewline:"]) { if (g_command_callback) g_command_callback("insertNewline"); }
  else if ([name isEqualToString:@"insertTab:"]) { if (g_command_callback) g_command_callback("insertTab"); }
  else if ([name isEqualToString:@"moveWordLeft:"]) { if (g_command_callback) g_command_callback("moveWordLeft"); }
  else if ([name isEqualToString:@"moveWordRight:"]) { if (g_command_callback) g_command_callback("moveWordRight"); }
  else if ([name isEqualToString:@"moveWordLeftAndModifySelection:"]) { if (g_command_callback) g_command_callback("selectWordLeft"); }
  else if ([name isEqualToString:@"moveWordRightAndModifySelection:"]) { if (g_command_callback) g_command_callback("selectWordRight"); }
  else if ([name isEqualToString:@"deleteBackward:"]) { if (g_command_callback) g_command_callback("deleteBackward"); }
  else if ([name isEqualToString:@"deleteForward:"]) { if (g_command_callback) g_command_callback("deleteForward"); }
  else if ([name isEqualToString:@"deleteWordBackward:"]) { if (g_command_callback) g_command_callback("deleteWordBackward"); }
  else if ([name isEqualToString:@"deleteWordForward:"]) { if (g_command_callback) g_command_callback("deleteWordForward"); }
  else if ([name isEqualToString:@"deleteToBeginningOfLine:"]) { if (g_command_callback) g_command_callback("deleteToBeginningOfLine"); }
  else if ([name isEqualToString:@"deleteToEndOfLine:"]) { if (g_command_callback) g_command_callback("deleteToEndOfLine"); }
  else if ([name isEqualToString:@"cancelOperation:"]) { if (g_command_callback) g_command_callback("cancel"); }
}
- (void)undo:(id)sender { if (g_command_callback) g_command_callback("undo"); }
- (void)redo:(id)sender { if (g_command_callback) g_command_callback("redo"); }
- (void)cut:(id)sender { if (g_command_callback) g_command_callback("cut"); }
- (void)copy:(id)sender { if (g_command_callback) g_command_callback("copy"); }
- (void)paste:(id)sender { if (g_command_callback) g_command_callback("paste"); }
- (void)selectAll:(id)sender { if (g_command_callback) g_command_callback("selectAll"); }
- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
  BOOL secondary = g_editor_input_pane == 1;
  NSString *text = secondary ? g_secondary_editor_text : g_editor_text;
  NSUInteger documentLength = text.length;
  NSUInteger start = MIN(range.location, documentLength);
  NSUInteger length = MIN(range.length, documentLength - start);
  if (actualRange) *actualRange = NSMakeRange(start, length);
  // The editor keeps cursor Y in top-origin logical coordinates, while NSView
  // uses a bottom-origin coordinate system for this protocol callback.
  CGFloat lineHeight = editorLineHeight();
  double *rect = secondary ? g_secondary_editor_rect : g_editor_rect;
  NSUInteger previousScrollLine = g_editor_scroll_line;
  BOOL previousSoftWrap = g_editor_soft_wrap;
  if (secondary) {
    swapEditorTextState();
    g_editor_scroll_line = g_secondary_editor_scroll_line;
    g_editor_soft_wrap = g_secondary_editor_soft_wrap;
  }
  CGPoint logical = editorPointForUTF16Offset(start);
  if (secondary) swapEditorTextState();
  g_editor_scroll_line = previousScrollLine;
  g_editor_soft_wrap = previousSoftWrap;
  CGFloat viewY = self.bounds.size.height - rect[1] - logical.y - lineHeight;
  NSRect cursor = NSMakeRect(rect[0] + logical.x, MAX(0.0, viewY), 0, lineHeight);
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
  if (g_editor_input_pane != 1) {
    return nimculus_platform_editor_utf16_offset_at_point(viewPoint.x, viewPoint.y);
  }
  double previousRect[4] = {g_editor_rect[0], g_editor_rect[1],
    g_editor_rect[2], g_editor_rect[3]};
  NSUInteger previousScrollLine = g_editor_scroll_line;
  BOOL previousSoftWrap = g_editor_soft_wrap;
  swapEditorTextState();
  memcpy(g_editor_rect, g_secondary_editor_rect, sizeof(g_editor_rect));
  g_editor_scroll_line = g_secondary_editor_scroll_line;
  g_editor_soft_wrap = g_secondary_editor_soft_wrap;
  NSUInteger result = nimculus_platform_editor_utf16_offset_at_point(viewPoint.x, viewPoint.y);
  swapEditorTextState();
  memcpy(g_editor_rect, previousRect, sizeof(g_editor_rect));
  g_editor_scroll_line = previousScrollLine;
  g_editor_soft_wrap = previousSoftWrap;
  return result;
}
- (CGFloat)baselineDeltaForCharacterAtIndex:(NSUInteger)index { return editorLineHeight(); }
- (BOOL)drawsVerticallyForCharacterAtIndex:(NSUInteger)index { return NO; }
- (CGFloat)fractionOfDistanceThroughGlyphForPoint:(NSPoint)point {
  NSPoint windowPoint = self.window ? [self.window convertScreenToBase:point] : point;
  NSPoint viewPoint = [self convertPoint:windowPoint fromView:nil];
  NSArray<NSString *> *lines = editorLinesForText(g_editor_text);
  if (lines.count == 0) return 0.0;
  CGFloat fromTop = self.bounds.size.height - viewPoint.y - g_editor_rect[1];
  NSInteger lineIndex = MAX(0, (NSInteger)floor((fromTop - 4.0) / editorLineHeight()));
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
  [attributed release];
  CFRelease(font);
  return MIN(1.0, MAX(0.0, fraction));
}

@end

@interface NimculusAppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) NimculusMetalView *view;
@property(nonatomic, strong) NSTimer *workspaceSearchTimer;
- (void)setupMainMenu;
- (void)presentAlertSheet:(NSAlert *)alert
               completion:(void (^)(NSModalResponse response))completion;
- (void)presentGitCommitSheet;
@end

@implementation NimculusAppDelegate

- (void)applicationDidResignActive:(NSNotification *)notification {
  (void)notification;
  if (g_command_callback) g_command_callback("windowFocusLost");
}

- (BOOL)confirmClose {
  if (!g_editor_dirty) return YES;
  // Window closing must not enter a nested AppKit loop. Normal application
  // startup always installs the command callback, which routes to the
  // asynchronous quit sheet below. Without that bridge, reject the close
  // rather than silently discarding data or blocking Metal presentation.
  if (g_command_callback) g_command_callback("quitRequest");
  return NO;
}

- (BOOL)windowShouldClose:(NSWindow *)window {
  (void)window;
  if (g_command_callback) {
    g_command_callback("quitRequest");
    return NO;
  }
  return [self confirmClose];
}

- (void)windowDidChangeScreen:(NSNotification *)notification {
  // Zed refreshes its display link, scale factor, and drawable whenever
  // AppKit assigns a window to a new screen. Nimculus does not own a display
  // link, but it must still refresh the CAMetalLayer and text resources even
  // when the window bounds did not change (for example, between two Retina
  // displays with a different backing scale).
  if (notification.object == self.window) [self.view updateBackingScale];
}

- (void)presentAlertSheet:(NSAlert *)alert
               completion:(void (^)(NSModalResponse response))completion {
  NSWindow *window = self.window;
  if (window) [alert beginSheetModalForWindow:window completionHandler:completion];
  else [alert beginWithCompletionHandler:completion];
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
  [self.workspaceSearchTimer invalidate];
  self.workspaceSearchTimer = nil;
  releasePlatformResources();
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
  NSMenuItem *saveAs = [[NSMenuItem alloc] initWithTitle:@"Save As…" action:@selector(saveAsDocument:) keyEquivalent:@"S"];
  NSMenuItem *close = [[NSMenuItem alloc] initWithTitle:@"Close Tab" action:@selector(closeDocument:) keyEquivalent:@"w"];
  newDocument.keyEquivalentModifierMask = NSEventModifierFlagCommand;
  open.keyEquivalentModifierMask = NSEventModifierFlagCommand;
  save.keyEquivalentModifierMask = NSEventModifierFlagCommand;
  saveAs.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
  close.keyEquivalentModifierMask = NSEventModifierFlagCommand;
  [fileMenu addItem:newDocument]; [fileMenu addItem:open]; [fileMenu addItem:save];
  [fileMenu addItem:saveAs]; [fileMenu addItem:close];
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
  NSMenuItem *undo = [[NSMenuItem alloc] initWithTitle:@"Undo" action:@selector(undo:)
    keyEquivalent:@"z"];
  undo.keyEquivalentModifierMask = NSEventModifierFlagCommand;
  [editMenu addItem:undo];
  NSMenuItem *redo = [[NSMenuItem alloc] initWithTitle:@"Redo" action:@selector(redo:)
    keyEquivalent:@"z"];
  redo.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
  [editMenu addItem:redo];
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
    if (item != redo && item != workspaceSearch && item != commandPalette) {
      item.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    }
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
  [windowMenu addItem:[NSMenuItem separatorItem]];
  [windowMenu addItem:[[NSMenuItem alloc] initWithTitle:@"Split Editor"
    action:@selector(splitEditor:) keyEquivalent:@""]];
  [windowMenu addItem:[[NSMenuItem alloc] initWithTitle:@"Close Split"
    action:@selector(closeSplit:) keyEquivalent:@""]];
  [windowMenu addItem:[[NSMenuItem alloc] initWithTitle:@"Zoom" action:@selector(performZoom:) keyEquivalent:@""]];
  [windowItem setSubmenu:windowMenu];
  [mainMenu addItem:windowItem];
  [NSApp setMainMenu:mainMenu];
}

- (void)openSettings:(id)sender {
  (void)sender;
  if (g_command_callback) g_command_callback("openSettingsUI");
}

- (void)showSettingsPanelWithTheme:(NSString *)theme editorFontSize:(NSString *)editorFontSize
                 terminalFontSize:(NSString *)terminalFontSize
                  editorFontFamily:(NSString *)editorFontFamily
                terminalFontFamily:(NSString *)terminalFontFamily shell:(NSString *)shell {
  NSAlert *alert = [[[NSAlert alloc] init] autorelease];
  alert.messageText = @"Nimculus Settings";
  alert.informativeText = @"Changes are written to the global settings file and applied immediately.";
  NSStackView *fields = [[[NSStackView alloc] initWithFrame:NSMakeRect(0, 0, 420, 160)] autorelease];
  fields.orientation = NSUserInterfaceLayoutOrientationVertical;
  fields.alignment = NSLayoutAttributeWidth;
  fields.spacing = 8.0;

  NSStackView *(^row)(NSString *, NSView *) = ^NSStackView *(NSString *label, NSView *control) {
    NSTextField *title = [NSTextField labelWithString:label];
    title.alignment = NSTextAlignmentRight;
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [title.widthAnchor constraintEqualToConstant:128.0].active = YES;
    NSStackView *line = [[[NSStackView alloc] initWithFrame:NSMakeRect(0, 0, 420, 24)] autorelease];
    line.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    line.spacing = 8.0;
    [line addArrangedSubview:title];
    [line addArrangedSubview:control];
    return line;
  };

  NSPopUpButton *themePopup = [[[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 270, 24) pullsDown:NO] autorelease];
  [themePopup addItemsWithTitles:@[@"system", @"light", @"dark"]];
  NSInteger themeIndex = [themePopup indexOfItemWithTitle:theme ?: @"system"];
  [themePopup selectItemAtIndex:themeIndex >= 0 ? themeIndex : 0];
  themePopup.identifier = @"theme";
  NSTextField *editorSize = [NSTextField textFieldWithString:editorFontSize ?: @"14"];
  editorSize.identifier = @"editorFontSize";
  NSTextField *terminalSize = [NSTextField textFieldWithString:terminalFontSize ?: @"12"];
  terminalSize.identifier = @"terminalFontSize";
  NSTextField *editorFont = [NSTextField textFieldWithString:editorFontFamily ?: @"Menlo"];
  editorFont.identifier = @"editorFontFamily";
  NSTextField *terminalFont = [NSTextField textFieldWithString:terminalFontFamily ?: @"Menlo"];
  terminalFont.identifier = @"terminalFontFamily";
  NSTextField *shellField = [NSTextField textFieldWithString:shell ?: @"/bin/zsh"];
  shellField.identifier = @"shell";
  [fields addArrangedSubview:row(@"Appearance", themePopup)];
  [fields addArrangedSubview:row(@"Editor font size", editorSize)];
  [fields addArrangedSubview:row(@"Terminal font size", terminalSize)];
  [fields addArrangedSubview:row(@"Editor font family", editorFont)];
  [fields addArrangedSubview:row(@"Terminal font family", terminalFont)];
  [fields addArrangedSubview:row(@"Terminal shell", shellField)];
  alert.accessoryView = fields;
  [alert addButtonWithTitle:@"Apply"];
  [alert addButtonWithTitle:@"Cancel"];
  [self presentAlertSheet:alert completion:^(NSModalResponse response) {
    if (response != NSAlertFirstButtonReturn || !g_command_callback) return;
    NSString *command = [NSString stringWithFormat:@"settingsApply:%@\x1f%@\x1f%@\x1f%@\x1f%@\x1f%@",
      themePopup.titleOfSelectedItem ?: @"system", editorSize.stringValue ?: @"14",
      terminalSize.stringValue ?: @"12", editorFont.stringValue ?: @"Menlo",
      terminalFont.stringValue ?: @"Menlo", shellField.stringValue ?: @"/bin/zsh"];
    g_command_callback(command.UTF8String);
  }];
}

- (void)previousTab:(id)sender {
  (void)sender;
  if (g_command_callback) g_command_callback("previousTab");
}

- (void)nextTab:(id)sender {
  (void)sender;
  if (g_command_callback) g_command_callback("nextTab");
}

- (void)splitEditor:(id)sender {
  (void)sender;
  if (g_command_callback) g_command_callback("splitEditor");
}

- (void)closeSplit:(id)sender {
  (void)sender;
  if (g_command_callback) g_command_callback("closeSplit");
}

- (void)presentGitCommitSheet {
  NSAlert *alert = [[[NSAlert alloc] init] autorelease];
  alert.messageText = @"Commit Changes";
  alert.informativeText = @"Enter a commit message for the staged changes.";
  NSTextField *field = [[[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 360, 24)] autorelease];
  field.placeholderString = @"Commit message";
  alert.accessoryView = field;
  [alert addButtonWithTitle:@"Commit"];
  [alert addButtonWithTitle:@"Cancel"];
  [self presentAlertSheet:alert completion:^(NSModalResponse response) {
    if (response != NSAlertFirstButtonReturn || !g_command_callback) return;
    NSString *message = [field.stringValue
      stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (message.length == 0) {
      g_command_callback("gitCommitMessageEmpty");
      return;
    }
    NSString *command = [NSString stringWithFormat:@"commandPalette:git commit %@", message];
    g_command_callback(command.UTF8String);
  }];
}

- (void)findInWorkspace:(id)sender {
  (void)sender;
  NSAlert *alert = [[[NSAlert alloc] init] autorelease];
  alert.messageText = @"Find in Workspace";
  alert.informativeText = @"Enter text to search in the current workspace.";
  NSTextField *field = [[[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 320, 24)] autorelease];
  field.placeholderString = @"Search text";
  alert.accessoryView = field;
  [alert addButtonWithTitle:@"Find"];
  [alert addButtonWithTitle:@"Cancel"];
  [self presentAlertSheet:alert completion:^(NSModalResponse response) {
    if (response == NSAlertFirstButtonReturn && g_command_callback) {
      NSString *command = [NSString stringWithFormat:@"workspaceSearch:%@", field.stringValue];
      g_command_callback(command.UTF8String);
    }
  }];
}

- (void)findInDocument:(id)sender {
  (void)sender;
  NSAlert *alert = [[[NSAlert alloc] init] autorelease];
  alert.messageText = @"Find in Document";
  NSTextField *field = [[[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 320, 24)] autorelease];
  field.placeholderString = @"Search text";
  alert.accessoryView = field;
  [alert addButtonWithTitle:@"Find"];
  [alert addButtonWithTitle:@"Cancel"];
  [self presentAlertSheet:alert completion:^(NSModalResponse response) {
    if (response == NSAlertFirstButtonReturn && g_command_callback) {
      NSString *command = [NSString stringWithFormat:@"findDocument:%@", field.stringValue];
      g_command_callback(command.UTF8String);
    }
  }];
}

- (void)replaceInDocument:(id)sender {
  (void)sender;
  NSAlert *alert = [[[NSAlert alloc] init] autorelease];
  alert.messageText = @"Replace in Document";
  NSStackView *fields = [[[NSStackView alloc] initWithFrame:NSMakeRect(0, 0, 320, 56)] autorelease];
  fields.orientation = NSUserInterfaceLayoutOrientationVertical;
  fields.spacing = 8;
  NSTextField *query = [[[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 320, 24)] autorelease];
  query.placeholderString = @"Search text";
  NSTextField *replacement = [[[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 320, 24)] autorelease];
  replacement.placeholderString = @"Replacement";
  [fields addArrangedSubview:query];
  [fields addArrangedSubview:replacement];
  alert.accessoryView = fields;
  [alert addButtonWithTitle:@"Replace All"];
  [alert addButtonWithTitle:@"Cancel"];
  [self presentAlertSheet:alert completion:^(NSModalResponse response) {
    if (response == NSAlertFirstButtonReturn && g_command_callback) {
      // Unit Separator is not valid in normal text input and keeps this ABI
      // independent of colons/newlines in either field.
      NSString *command = [NSString stringWithFormat:@"replaceDocument:%@\x1f%@",
        query.stringValue, replacement.stringValue];
      g_command_callback(command.UTF8String);
    }
  }];
}

- (void)goToLine:(id)sender {
  (void)sender;
  NSAlert *alert = [[[NSAlert alloc] init] autorelease];
  alert.messageText = @"Go to Line";
  NSTextField *field = [self workspacePathField:@"Line number"];
  field.stringValue = @"1";
  alert.accessoryView = field;
  [alert addButtonWithTitle:@"Go"];
  [alert addButtonWithTitle:@"Cancel"];
  [self presentAlertSheet:alert completion:^(NSModalResponse response) {
    if (response == NSAlertFirstButtonReturn && g_command_callback) {
      NSString *command = [NSString stringWithFormat:@"goToLine:%@", field.stringValue];
      g_command_callback(command.UTF8String);
    }
  }];
}

- (void)openCommandPalette:(id)sender {
  (void)sender;
  NSAlert *alert = [[[NSAlert alloc] init] autorelease];
  alert.messageText = @"Command Palette";
  alert.informativeText = @"Choose a command or type an exact command.";
  NSComboBox *field = [[[NSComboBox alloc] initWithFrame:NSMakeRect(0, 0, 360, 26)] autorelease];
  field.placeholderString = @"Type to filter commands";
  field.completes = YES;
  field.numberOfVisibleItems = 12;
  [field addItemsWithObjectValues:@[
    @"new", @"save", @"find", @"toggle files", @"reveal active file",
    @"toggle git", @"git status", @"git log", @"git branches", @"git file history",
    @"split editor", @"close split", @"toggle soft wrap", @"open settings",
    @"toggle terminal", @"new terminal", @"toggle task output",
    @"go to definition", @"find references", @"document symbols"
  ]];
  alert.accessoryView = field;
  [alert addButtonWithTitle:@"Run"];
  [alert addButtonWithTitle:@"Cancel"];
  [self presentAlertSheet:alert completion:^(NSModalResponse response) {
    if (response == NSAlertFirstButtonReturn && g_command_callback) {
      NSString *command = [NSString stringWithFormat:@"commandPalette:%@", field.stringValue];
      g_command_callback(command.UTF8String);
    }
  }];
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
  (void)sender;
  NSOpenPanel *panel = [NSOpenPanel openPanel];
  panel.canChooseFiles = YES;
  panel.canChooseDirectories = YES;
  // Keep AppKit and Metal presentation live while the user chooses a file.
  // Zed uses the same completion-handler based panel API rather than a
  // nested runModal loop for application-owned file prompts.
  [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
    if (response == NSModalResponseOK && g_file_callback) {
      g_file_callback(panel.URL.path.UTF8String, false);
    }
  }];
}

- (void)openRecent:(id)sender {
  (void)sender;
  NSAlert *alert = [[[NSAlert alloc] init] autorelease];
  alert.messageText = @"Open Recent";
  if (g_recent_files.count == 0) {
    alert.informativeText = @"No recent files.";
    [alert addButtonWithTitle:@"OK"];
    [self presentAlertSheet:alert completion:^(NSModalResponse response) {
      (void)response;
    }];
    return;
  }
  NSPopUpButton *popup = [[[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 360, 26)
    pullsDown:NO] autorelease];
  [popup addItemsWithTitles:g_recent_files];
  alert.accessoryView = popup;
  [alert addButtonWithTitle:@"Open"];
  [alert addButtonWithTitle:@"Cancel"];
  [self presentAlertSheet:alert completion:^(NSModalResponse response) {
    if (response == NSAlertFirstButtonReturn && g_file_callback) {
      NSString *path = popup.selectedItem.title;
      if (path.length > 0) g_file_callback(path.UTF8String, false);
    }
  }];
}

- (void)addWorkspaceFolder:(id)sender {
  (void)sender;
  NSOpenPanel *panel = [NSOpenPanel openPanel];
  panel.canChooseFiles = NO;
  panel.canChooseDirectories = YES;
  panel.allowsMultipleSelection = YES;
  [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
    if (response == NSModalResponseOK && g_command_callback) {
      for (NSURL *url in panel.URLs) {
        NSString *command = [NSString stringWithFormat:@"workspaceAddRoot:%@", url.path];
        g_command_callback(command.UTF8String);
      }
    }
  }];
}

- (void)openWorkspaceFolder:(id)sender {
  (void)sender;
  NSOpenPanel *panel = [NSOpenPanel openPanel];
  panel.canChooseFiles = NO;
  panel.canChooseDirectories = YES;
  panel.allowsMultipleSelection = NO;
  [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
    if (response == NSModalResponseOK && g_file_callback) {
      g_file_callback(panel.URL.path.UTF8String, false);
    }
  }];
}

- (void)quickOpen:(id)sender {
  (void)sender;
  NSAlert *alert = [[[NSAlert alloc] init] autorelease];
  alert.messageText = @"Quick Open";
  alert.informativeText = @"Enter part of a file name or path.";
  NSTextField *field = [self workspacePathField:@"File name"];
  alert.accessoryView = field;
  [alert addButtonWithTitle:@"Search"];
  [alert addButtonWithTitle:@"Cancel"];
  [self presentAlertSheet:alert completion:^(NSModalResponse response) {
    if (response == NSAlertFirstButtonReturn && g_command_callback) {
      NSString *command = [NSString stringWithFormat:@"quickOpen:%@", field.stringValue];
      g_command_callback(command.UTF8String);
    }
  }];
}

- (void)newDocument:(id)sender {
  (void)sender;
  if (g_command_callback) g_command_callback("newDocument");
}

- (void)dispatchOpenWorkspaceContextEntry:(id)sender {
  (void)sender;
  if (g_workspace_context_path.length > 0 && g_file_callback) {
    g_file_callback(g_workspace_context_path.UTF8String, false);
  }
}

- (void)dispatchGitStatusContext:(NSMenuItem *)sender {
  if (g_command_callback && [sender.representedObject isKindOfClass:[NSString class]]) {
    g_command_callback(((NSString *)sender.representedObject).UTF8String);
  }
}

- (void)dispatchGitHistoryContext:(NSMenuItem *)sender {
  if (g_command_callback && [sender.representedObject isKindOfClass:[NSString class]]) {
    g_command_callback(((NSString *)sender.representedObject).UTF8String);
  }
}

- (NSTextField *)workspacePathField:(NSString *)placeholder {
  NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 320, 24)];
  field.placeholderString = placeholder;
  return field;
}

- (void)createWorkspaceFile:(id)sender {
  (void)sender;
  NSAlert *alert = [[[NSAlert alloc] init] autorelease];
  alert.messageText = @"New File";
  NSTextField *field = [self workspacePathField:@"Relative path, or absolute path in a workspace root"];
  alert.accessoryView = field;
  [alert addButtonWithTitle:@"Create"];
  [alert addButtonWithTitle:@"Cancel"];
  [self presentAlertSheet:alert completion:^(NSModalResponse response) {
    if (response == NSAlertFirstButtonReturn && g_command_callback) {
      NSString *command = [NSString stringWithFormat:@"workspaceCreateFile:%@", field.stringValue];
      g_command_callback(command.UTF8String);
    }
  }];
}

- (void)createWorkspaceFileAtContext:(id)sender {
  (void)sender;
  if (g_workspace_context_path.length == 0) return;
  // The sheet completes asynchronously. Keep the target selected when the
  // menu action began, rather than consulting the mutable context menu state.
  NSString *base = [(g_workspace_context_is_directory ? g_workspace_context_path :
    g_workspace_context_path.stringByDeletingLastPathComponent) copy];
  NSAlert *alert = [[[NSAlert alloc] init] autorelease];
  alert.messageText = @"New File";
  NSTextField *field = [self workspacePathField:@"File name or relative path"];
  alert.accessoryView = field;
  [alert addButtonWithTitle:@"Create"];
  [alert addButtonWithTitle:@"Cancel"];
  [self presentAlertSheet:alert completion:^(NSModalResponse response) {
    if (response == NSAlertFirstButtonReturn && g_command_callback && field.stringValue.length > 0) {
      NSString *path = [base stringByAppendingPathComponent:field.stringValue];
      NSString *command = [NSString stringWithFormat:@"workspaceCreateFile:%@", path];
      g_command_callback(command.UTF8String);
    }
    [base release];
  }];
}

- (void)createWorkspaceDirectory:(id)sender {
  (void)sender;
  NSAlert *alert = [[[NSAlert alloc] init] autorelease];
  alert.messageText = @"New Folder";
  NSTextField *field = [self workspacePathField:@"Relative path, or absolute path in a workspace root"];
  alert.accessoryView = field;
  [alert addButtonWithTitle:@"Create"];
  [alert addButtonWithTitle:@"Cancel"];
  [self presentAlertSheet:alert completion:^(NSModalResponse response) {
    if (response == NSAlertFirstButtonReturn && g_command_callback) {
      NSString *command = [NSString stringWithFormat:@"workspaceCreateDirectory:%@", field.stringValue];
      g_command_callback(command.UTF8String);
    }
  }];
}

- (void)createWorkspaceDirectoryAtContext:(id)sender {
  (void)sender;
  if (g_workspace_context_path.length == 0) return;
  NSString *base = [(g_workspace_context_is_directory ? g_workspace_context_path :
    g_workspace_context_path.stringByDeletingLastPathComponent) copy];
  NSAlert *alert = [[[NSAlert alloc] init] autorelease];
  alert.messageText = @"New Folder";
  NSTextField *field = [self workspacePathField:@"Folder name or relative path"];
  alert.accessoryView = field;
  [alert addButtonWithTitle:@"Create"];
  [alert addButtonWithTitle:@"Cancel"];
  [self presentAlertSheet:alert completion:^(NSModalResponse response) {
    if (response == NSAlertFirstButtonReturn && g_command_callback && field.stringValue.length > 0) {
      NSString *path = [base stringByAppendingPathComponent:field.stringValue];
      NSString *command = [NSString stringWithFormat:@"workspaceCreateDirectory:%@", path];
      g_command_callback(command.UTF8String);
    }
    [base release];
  }];
}

- (void)renameWorkspaceEntry:(id)sender {
  (void)sender;
  NSAlert *alert = [[[NSAlert alloc] init] autorelease];
  alert.messageText = @"Rename Workspace Entry";
  NSStackView *fields = [[[NSStackView alloc] initWithFrame:NSMakeRect(0, 0, 320, 56)] autorelease];
  fields.orientation = NSUserInterfaceLayoutOrientationVertical;
  fields.spacing = 8;
  NSTextField *oldField = [self workspacePathField:@"Existing relative or absolute path"];
  NSTextField *newField = [self workspacePathField:@"New relative or absolute path"];
  [fields addArrangedSubview:oldField];
  [fields addArrangedSubview:newField];
  alert.accessoryView = fields;
  [alert addButtonWithTitle:@"Rename"];
  [alert addButtonWithTitle:@"Cancel"];
  [self presentAlertSheet:alert completion:^(NSModalResponse response) {
    if (response == NSAlertFirstButtonReturn && g_command_callback) {
      NSString *command = [NSString stringWithFormat:@"workspaceRename:%@\x1f%@",
        oldField.stringValue, newField.stringValue];
      g_command_callback(command.UTF8String);
    }
  }];
}

- (void)renameWorkspaceContextEntry:(id)sender {
  (void)sender;
  if (g_workspace_context_path.length == 0) return;
  NSString *target = [g_workspace_context_path copy];
  NSAlert *alert = [[[NSAlert alloc] init] autorelease];
  alert.messageText = @"Rename";
  NSTextField *field = [self workspacePathField:@"New name"];
  field.stringValue = target.lastPathComponent ?: @"";
  alert.accessoryView = field;
  [alert addButtonWithTitle:@"Rename"];
  [alert addButtonWithTitle:@"Cancel"];
  [self presentAlertSheet:alert completion:^(NSModalResponse response) {
    if (response == NSAlertFirstButtonReturn && g_command_callback && field.stringValue.length > 0) {
      NSString *renamed = [target.stringByDeletingLastPathComponent
        stringByAppendingPathComponent:field.stringValue];
      NSString *command = [NSString stringWithFormat:@"workspaceRename:%@\x1f%@", target, renamed];
      g_command_callback(command.UTF8String);
    }
    [target release];
  }];
}

- (void)deleteWorkspaceEntry:(id)sender {
  (void)sender;
  NSAlert *alert = [[[NSAlert alloc] init] autorelease];
  alert.messageText = @"Delete Workspace Entry";
  alert.informativeText = @"Deleting a directory requires it to be empty.";
  NSTextField *field = [self workspacePathField:@"Relative or absolute path in a workspace root"];
  alert.accessoryView = field;
  [alert addButtonWithTitle:@"Delete"];
  [alert addButtonWithTitle:@"Cancel"];
  alert.alertStyle = NSAlertStyleWarning;
  [self presentAlertSheet:alert completion:^(NSModalResponse response) {
    if (response == NSAlertFirstButtonReturn && g_command_callback) {
      NSString *command = [NSString stringWithFormat:@"workspaceDelete:%@", field.stringValue];
      g_command_callback(command.UTF8String);
    }
  }];
}

- (void)deleteWorkspaceContextEntry:(id)sender {
  (void)sender;
  if (g_workspace_context_path.length == 0) return;
  NSString *target = [g_workspace_context_path copy];
  BOOL isDirectory = g_workspace_context_is_directory;
  NSAlert *alert = [[[NSAlert alloc] init] autorelease];
  alert.messageText = [NSString stringWithFormat:@"Delete “%@”?", target.lastPathComponent];
  alert.informativeText = isDirectory
    ? @"Deleting a folder requires it to be empty." : @"This cannot be undone.";
  alert.alertStyle = NSAlertStyleWarning;
  [alert addButtonWithTitle:@"Delete"];
  [alert addButtonWithTitle:@"Cancel"];
  [self presentAlertSheet:alert completion:^(NSModalResponse response) {
    if (response == NSAlertFirstButtonReturn && g_command_callback) {
      NSString *command = [NSString stringWithFormat:@"workspaceDelete:%@", target];
      g_command_callback(command.UTF8String);
    }
    [target release];
  }];
}

- (void)revealWorkspaceContextEntry:(id)sender {
  (void)sender;
  if (g_workspace_context_path.length > 0) {
    [[NSWorkspace sharedWorkspace] selectFile:g_workspace_context_path
      inFileViewerRootedAtPath:@""];
  }
}

- (void)saveDocument:(id)sender {
  (void)sender;
  // Nim decides whether the active document already has a path. Existing
  // files must save directly on Cmd+S; only untitled documents need a panel.
  if (g_command_callback) g_command_callback("save");
}

- (void)saveAsDocument:(id)sender {
  (void)sender;
  if (g_command_callback) g_command_callback("saveAs");
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
  [string release];
  CFRelease(font);
  CGContextRelease(context);

  MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
    width:width height:height mipmapped:NO];
  descriptor.usage = MTLTextureUsageShaderRead;
  [g_text_texture release];
  g_text_texture = [device newTextureWithDescriptor:descriptor];
  [g_text_texture replaceRegion:MTLRegionMake2D(0, 0, width, height)
    mipmapLevel:0 withBytes:pixels.bytes bytesPerRow:width];
}

static id<MTLRenderPipelineState> newGlyphPipeline(id<MTLLibrary> library,
                                                    NSError **error) {
  if (!library) return nil;
  MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
  descriptor.vertexFunction = [[library newFunctionWithName:@"glyphVs"] autorelease];
  descriptor.fragmentFunction = [[library newFunctionWithName:@"glyphFs"] autorelease];
  descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
  descriptor.colorAttachments[0].blendingEnabled = YES;
  descriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
  descriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
  descriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
  descriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
  id<MTLRenderPipelineState> pipeline =
    [library.device newRenderPipelineStateWithDescriptor:descriptor error:error];
  [descriptor release];
  return pipeline;
}

static BOOL ensureGlyphValidationPipeline(id<MTLDevice> device) {
  if (!device) return NO;
  if (g_glyph_pipeline) return YES;
  NSError *error = nil;
  NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "struct GV { float4 pos [[position]]; float2 uv; float4 color; };\n"
    "vertex GV glyphVs(uint id [[vertex_id]], constant float4 *v [[buffer(0)]]) { "
    "GV o; o.pos=float4(v[id*2].xy,0,1); o.uv=v[id*2].zw; o.color=v[id*2+1]; return o; }\n"
    "fragment float4 glyphFs(GV in [[stage_in]], texture2d<float> atlas [[texture(0)]]) { "
    "constexpr sampler s(filter::linear); float alpha=atlas.sample(s,in.uv).r; "
    "return float4(in.color.rgb,in.color.a*alpha); }";
  id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
  g_glyph_pipeline = newGlyphPipeline(library, &error);
  [library release];
  return g_glyph_pipeline != nil;
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
    descriptor.vertexFunction = [[library newFunctionWithName:@"vs"] autorelease];
    descriptor.fragmentFunction = [[library newFunctionWithName:@"fs"] autorelease];
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    g_pipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    MTLRenderPipelineDescriptor *textDescriptor = [MTLRenderPipelineDescriptor new];
    textDescriptor.vertexFunction = [[library newFunctionWithName:@"textVs"] autorelease];
    textDescriptor.fragmentFunction = [[library newFunctionWithName:@"textFs"] autorelease];
    textDescriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    textDescriptor.colorAttachments[0].blendingEnabled = YES;
    textDescriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    textDescriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    textDescriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    textDescriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    g_text_pipeline = [device newRenderPipelineStateWithDescriptor:textDescriptor error:&error];
    g_glyph_pipeline = newGlyphPipeline(library, &error);
    MTLRenderPipelineDescriptor *imageDescriptor = [MTLRenderPipelineDescriptor new];
    imageDescriptor.vertexFunction = [[library newFunctionWithName:@"imageVs"] autorelease];
    imageDescriptor.fragmentFunction = [[library newFunctionWithName:@"imageFs"] autorelease];
    imageDescriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    imageDescriptor.colorAttachments[0].blendingEnabled = YES;
    imageDescriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    imageDescriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    imageDescriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    imageDescriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    g_image_pipeline = [device newRenderPipelineStateWithDescriptor:imageDescriptor error:&error];
    [g_image_textures release];
    g_image_textures = [[NSMutableDictionary alloc] init];
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
    [descriptor release];
    [textDescriptor release];
    [imageDescriptor release];
  }
  [library release];

  NSRect frame = NSMakeRect(0, 0, 960, 640);
  self.window = [[NSWindow alloc] initWithContentRect:frame
    styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
               NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
    backing:NSBackingStoreBuffered defer:NO];
  // Keep AppKit's native fullscreen transition available on every display.
  // This is the same window-level capability boundary used by Zed's macOS
  // platform rather than emulating fullscreen in the renderer.
  self.window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
  self.window.title = @"Nimculus";
  self.window.acceptsMouseMovedEvents = YES;
  self.window.delegate = self;
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
    dispatchOrQueueFileOpenPath(path);
  }
}
- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls {
  (void)application;
  for (NSURL *url in urls) {
    NSString *path = nil;
    if (url.isFileURL) {
      path = url.path;
    } else if ([url.scheme.lowercaseString isEqualToString:@"nimculus"]) {
      // `nimculus:///absolute/path` is the stable URL form. Query-based
      // links are also accepted for callers that cannot emit a path URL.
      path = url.path;
      if (path.length == 0) {
        NSURLComponents *components = [NSURLComponents componentsWithURL:url
          resolvingAgainstBaseURL:NO];
        for (NSURLQueryItem *item in components.queryItems) {
          if ([item.name isEqualToString:@"path"]) { path = item.value; break; }
        }
      }
    }
    dispatchOrQueueFileOpenPath(path);
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
    NimculusMetalView *view = (NimculusMetalView *)g_active_view;
    NSWindow *window = view.window;
    if (!window) {
      // This can only occur while a window is closing. A synchronous modal at
      // that point can strand the main loop, so acknowledge the disk state and
      // keep the in-memory buffer instead.
      [alert release];
      if (g_command_callback) g_command_callback("keepExternal");
      return;
    }
    // This notification is raised from the recurring idle callback. As in
    // Zed's macOS prompt implementation, start a non-blocking window sheet;
    // `runModal` here would suspend Metal frame presentation while waiting for
    // the user's decision.
    [alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse response) {
      if (g_command_callback) {
        g_command_callback(response == NSAlertFirstButtonReturn
          ? "reloadExternal" : "keepExternal");
      }
    }];
    [alert release];
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

void nimculus_platform_show_settings_panel(const char *theme, const char *editor_font_size,
                                           const char *terminal_font_size,
                                           const char *editor_font_family,
                                           const char *terminal_font_family, const char *shell) {
  id delegate = [NSApp delegate];
  if ([delegate respondsToSelector:@selector(showSettingsPanelWithTheme:editorFontSize:terminalFontSize:editorFontFamily:terminalFontFamily:shell:)]) {
    [delegate showSettingsPanelWithTheme:theme ? [NSString stringWithUTF8String:theme] : @"system"
      editorFontSize:editor_font_size ? [NSString stringWithUTF8String:editor_font_size] : @"14"
      terminalFontSize:terminal_font_size ? [NSString stringWithUTF8String:terminal_font_size] : @"12"
      editorFontFamily:editor_font_family ? [NSString stringWithUTF8String:editor_font_family] : @"Menlo"
      terminalFontFamily:terminal_font_family ? [NSString stringWithUTF8String:terminal_font_family] : @"Menlo"
      shell:shell ? [NSString stringWithUTF8String:shell] : @"/bin/zsh"];
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

bool nimculus_platform_validate_appearance_callback(void) {
  // Exercise the same NSView override AppKit invokes when the effective
  // appearance changes. The test callback stays entirely inside the native
  // boundary and restores the application callback before returning.
  BOOL valid = NO;
  @autoreleasepool {
    NimculusMetalView *view = [[NimculusMetalView alloc] initWithFrame:
      NSMakeRect(0.0, 0.0, 1.0, 1.0)];
    NimculusCommandCallback previous = g_command_callback;
    g_validation_appearance_command_received = NO;
    g_command_callback = validateAppearanceCommand;
    [view viewDidChangeEffectiveAppearance];
    valid = g_validation_appearance_command_received;
    g_command_callback = previous;
    [view release];
  }
  return valid;
}

bool nimculus_platform_validate_window_lifecycle(void) {
  NimculusPlatformMetrics previousMetrics = g_metrics;
  BOOL valid = NO;
  @autoreleasepool {
    NSWindow *window = [[NSWindow alloc]
      initWithContentRect:NSMakeRect(0.0, 0.0, 640.0, 480.0)
      styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                 NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
      backing:NSBackingStoreBuffered defer:NO];
    if (window) {
      window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
      NimculusMetalView *view = [[NimculusMetalView alloc] initWithFrame:
        NSMakeRect(0.0, 0.0, 640.0, 480.0)];
      if (view) {
        window.contentView = view;
        [view updateBackingScale];
        CGFloat scale = window.backingScaleFactor;
        BOOL initial = scale > 0.0 &&
          fabs(view.metalLayer.drawableSize.width - view.bounds.size.width * scale) < 0.5 &&
          fabs(view.metalLayer.drawableSize.height - view.bounds.size.height * scale) < 0.5;
        [window setContentSize:NSMakeSize(960.0, 720.0)];
        [view layoutSubtreeIfNeeded];
        [view updateBackingScale];
        BOOL resized = view.bounds.size.width >= 959.0 && view.bounds.size.height >= 719.0 &&
          fabs(view.metalLayer.drawableSize.width - view.bounds.size.width * scale) < 0.5 &&
          fabs(view.metalLayer.drawableSize.height - view.bounds.size.height * scale) < 0.5;
        NSUInteger screenCount = NSScreen.screens.count;
        BOOL screensValid = screenCount > 0;
        for (NSScreen *screen in NSScreen.screens) {
          screensValid = screensValid && screen.frame.size.width > 0.0 &&
            screen.frame.size.height > 0.0 && screen.backingScaleFactor > 0.0;
        }
        NSWindowStyleMask requiredMask = NSWindowStyleMaskResizable |
          NSWindowStyleMaskMiniaturizable;
        BOOL windowStatesValid = (window.styleMask & requiredMask) == requiredMask &&
          (window.collectionBehavior & NSWindowCollectionBehaviorFullScreenPrimary) != 0;
        valid = initial && resized && screensValid && windowStatesValid;
      }
      [window close];
    }
  }
  // AppKit may deliver the final view-detachment callback while the pool is
  // draining, so restore the observable metrics only after that boundary.
  g_metrics = previousMetrics;
  return valid;
}

bool nimculus_platform_validate_window_delegate(void) {
  NimculusPlatformMetrics previousMetrics = g_metrics;
  BOOL valid = NO;
  @autoreleasepool {
    NSWindow *window = [[NSWindow alloc]
      initWithContentRect:NSMakeRect(0.0, 0.0, 640.0, 480.0)
      styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                 NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
      backing:NSBackingStoreBuffered defer:NO];
    NimculusAppDelegate *delegate = [NimculusAppDelegate new];
    NimculusMetalView *view = [[NimculusMetalView alloc] initWithFrame:
      NSMakeRect(0.0, 0.0, 640.0, 480.0)];
    if (window && delegate && view) {
      delegate.window = window;
      delegate.view = view;
      window.contentView = view;
      window.delegate = delegate;
      [view updateBackingScale];
      CGFloat scale = window.backingScaleFactor;
      [delegate windowDidChangeScreen:[NSNotification notificationWithName:
        NSWindowDidChangeScreenNotification object:window]];
      BOOL refreshed = scale > 0.0 &&
        fabs(view.metalLayer.drawableSize.width - view.bounds.size.width * scale) < 0.5 &&
        fabs(view.metalLayer.drawableSize.height - view.bounds.size.height * scale) < 0.5;
      valid = window.delegate == delegate &&
        [delegate respondsToSelector:@selector(windowShouldClose:)] &&
        [delegate respondsToSelector:@selector(windowDidChangeScreen:)] && refreshed;
      window.delegate = nil;
      [window close];
    }
    [view release];
    [delegate release];
    [window release];
  }
  g_metrics = previousMetrics;
  return valid;
}

static BOOL waitForFullscreenStyle(NSWindow *window, BOOL expected, NSTimeInterval timeout) {
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  while ([deadline timeIntervalSinceNow] > 0.0) {
    BOOL fullscreen = (window.styleMask & NSWindowStyleMaskFullScreen) != 0;
    if (fullscreen == expected) return YES;
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
  }
  return ((window.styleMask & NSWindowStyleMaskFullScreen) != 0) == expected;
}

static BOOL waitForFullscreenNotification(BOOL *received, NSTimeInterval timeout) {
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  while (!*received && [deadline timeIntervalSinceNow] > 0.0) {
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
  }
  return *received;
}

bool nimculus_platform_validate_fullscreen_transition(void) {
  // A real fullscreen transition changes the active GUI workspace. Keep this
  // opt-in and run it only on the dedicated, manually dispatched GUI runner.
  // Zed also relies on AppKit's asynchronous toggleFullScreen: lifecycle and
  // distinguishes the entered style state from the restored window state.
  const char *required = getenv("NIMCULUS_REQUIRE_FULLSCREEN_TRANSITION");
  if (!required || strcmp(required, "1") != 0) return false;
  NimculusPlatformMetrics previousMetrics = g_metrics;
  BOOL valid = NO;
  @autoreleasepool {
    NSApplication *application = [NSApplication sharedApplication];
    NSWindow *window = [[NSWindow alloc]
      initWithContentRect:NSMakeRect(80.0, 80.0, 640.0, 480.0)
      styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                 NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
      backing:NSBackingStoreBuffered defer:NO];
    NimculusMetalView *view = [[NimculusMetalView alloc] initWithFrame:
      NSMakeRect(0.0, 0.0, 640.0, 480.0)];
    if (application && window && view) {
      __block BOOL didEnterFullscreen = NO;
      __block BOOL didExitFullscreen = NO;
      NSNotificationCenter *notifications = [NSNotificationCenter defaultCenter];
      id enterObserver = [notifications addObserverForName:NSWindowDidEnterFullScreenNotification
        object:window queue:nil usingBlock:^(NSNotification *notification) {
          (void)notification;
          didEnterFullscreen = YES;
        }];
      id exitObserver = [notifications addObserverForName:NSWindowDidExitFullScreenNotification
        object:window queue:nil usingBlock:^(NSNotification *notification) {
          (void)notification;
          didExitFullscreen = YES;
        }];
      window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
      window.contentView = view;
      [window makeKeyAndOrderFront:nil];
      [application activateIgnoringOtherApps:YES];
      [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.10]];
      [window toggleFullScreen:nil];
      // The fullscreen style bit is set before AppKit completes its space
      // transition. Do not request exit during that intermediate state: Zed
      // likewise uses the native enter/exit lifecycle callbacks to separate
      // its restore work from the toggle request.
      BOOL entered = waitForFullscreenNotification(&didEnterFullscreen, 5.0) &&
        waitForFullscreenStyle(window, YES, 1.0);
      BOOL exited = NO;
      if (entered) {
        [window toggleFullScreen:nil];
        exited = waitForFullscreenNotification(&didExitFullscreen, 5.0) &&
          waitForFullscreenStyle(window, NO, 1.0);
      }
      valid = entered && exited;
      // Do not leave the runner in fullscreen after a timeout or an AppKit
      // transition error. A close must happen only after a best-effort exit.
      if (!exited && (window.styleMask & NSWindowStyleMaskFullScreen) != 0) {
        [window toggleFullScreen:nil];
        (void)waitForFullscreenNotification(&didExitFullscreen, 5.0);
        (void)waitForFullscreenStyle(window, NO, 1.0);
      }
      [notifications removeObserver:enterObserver];
      [notifications removeObserver:exitObserver];
      if ((window.styleMask & NSWindowStyleMaskFullScreen) == 0) {
        [window orderOut:nil];
        [window close];
      }
    }
    [view release];
    [window release];
  }
  g_metrics = previousMetrics;
  return valid;
}

static BOOL editorRectContains(const double rect[4], double x, double y) {
  return x >= rect[0] && y >= rect[1] && x < rect[0] + rect[2] &&
    y < rect[1] + rect[3];
}

bool nimculus_platform_validate_editor_pane_geometry(void) {
  double previousPrimary[4] = {g_editor_rect[0], g_editor_rect[1],
    g_editor_rect[2], g_editor_rect[3]};
  double previousSecondary[4] = {g_secondary_editor_rect[0], g_secondary_editor_rect[1],
    g_secondary_editor_rect[2], g_secondary_editor_rect[3]};
  BOOL previousVisible = g_secondary_editor_visible;
  NSUInteger previousInputPane = g_editor_input_pane;
  NSUInteger previousHoverPane = g_editor_hover_pane;
  NSString *previousText = [g_editor_text retain];
  NSString *previousSecondaryText = [g_secondary_editor_text retain];
  NSUInteger previousPrimaryScroll = g_editor_scroll_line;
  NSUInteger previousSecondaryScroll = g_secondary_editor_scroll_line;
  nimculus_platform_set_editor_rect(40.0, 80.0, 300.0, 240.0);
  nimculus_platform_set_secondary_editor_rect(true, 348.0, 80.0, 300.0, 240.0);
  const char *sample = "zero\none\ntwo";
  nimculus_platform_set_editor_text(sample, (uint32_t)strlen(sample));
  nimculus_platform_set_secondary_editor_text(sample, (uint32_t)strlen(sample));
  nimculus_platform_set_editor_scroll_line(0);
  nimculus_platform_set_secondary_editor_scroll_line(2);
  nimculus_platform_set_editor_input_pane(1);
  nimculus_platform_set_editor_hover_pane(1);
  BOOL valid = nimculus_platform_editor_pane_at_point(40.0, 80.0) == 0 &&
    nimculus_platform_editor_pane_at_point(340.0, 90.0) == UINT32_MAX &&
    nimculus_platform_editor_pane_at_point(348.0, 80.0) == 1 &&
    nimculus_platform_editor_pane_at_point(648.0, 80.0) == UINT32_MAX &&
    nimculus_platform_secondary_editor_byte_offset_at_point(356.0, 556.0) == 9 &&
    g_editor_input_pane == 1 && g_editor_hover_pane == 1;
  memcpy(g_editor_rect, previousPrimary, sizeof(previousPrimary));
  memcpy(g_secondary_editor_rect, previousSecondary, sizeof(previousSecondary));
  g_secondary_editor_visible = previousVisible;
  g_editor_input_pane = previousInputPane;
  g_editor_hover_pane = previousHoverPane;
  nimculus_platform_set_editor_text(previousText.UTF8String, (uint32_t)[previousText lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
  nimculus_platform_set_secondary_editor_text(previousSecondaryText.UTF8String,
    (uint32_t)[previousSecondaryText lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
  g_editor_scroll_line = previousPrimaryScroll;
  g_secondary_editor_scroll_line = previousSecondaryScroll;
  [previousText release];
  [previousSecondaryText release];
  return valid;
}

bool nimculus_platform_validate_damage_rebuild(void) {
  // A new retained target must ignore a stale/partial damage list. Only an
  // initialized scene with at least one damage region may take the partial
  // path.
  return sceneNeedsFullRebuild(NO, 1) &&
    sceneNeedsFullRebuild(YES, 0) &&
    !sceneNeedsFullRebuild(YES, 1) &&
    sceneNeedsFullRebuild(NO, 0);
}

bool nimculus_platform_validate_scroll_clip_pixels(void) {
  // GPUI (Zed) carries the current content mask through each draw and snaps it
  // to backing pixels before submission. Exercise the equivalent Metal
  // scissor boundary directly at 2x: a full logical rectangle must only reach
  // the physical pixels in its scroll viewport clip.
  @autoreleasepool {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) return false;
    id<MTLCommandQueue> queue = [device newCommandQueue];
    NSError *error = nil;
    NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
      "struct V { float4 pos [[position]]; float4 color; };\n"
      "struct U { float opacity; };\n"
      "vertex V vs(uint id [[vertex_id]], constant float4 *v [[buffer(0)]], "
      "constant U& u [[buffer(1)]]) { V o; o.pos=v[id*2]; o.color=v[id*2+1]*u.opacity; return o; }\n"
      "fragment float4 fs(V in [[stage_in]]) { return in.color; }";
    id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
    MTLRenderPipelineDescriptor *pipelineDescriptor = [MTLRenderPipelineDescriptor new];
    pipelineDescriptor.vertexFunction = [library newFunctionWithName:@"vs"];
    pipelineDescriptor.fragmentFunction = [library newFunctionWithName:@"fs"];
    pipelineDescriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    id<MTLRenderPipelineState> pipeline =
      [device newRenderPipelineStateWithDescriptor:pipelineDescriptor error:&error];
    [pipelineDescriptor.vertexFunction release];
    [pipelineDescriptor.fragmentFunction release];
    [pipelineDescriptor release];

    MTLTextureDescriptor *textureDescriptor =
      [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                          width:32 height:32 mipmapped:NO];
    textureDescriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    textureDescriptor.storageMode = MTLStorageModeShared;
    id<MTLTexture> texture = [device newTextureWithDescriptor:textureDescriptor];
    BOOL rendered = queue && library && pipeline && texture;
    if (rendered) {
      MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
      pass.colorAttachments[0].texture = texture;
      pass.colorAttachments[0].loadAction = MTLLoadActionClear;
      pass.colorAttachments[0].storeAction = MTLStoreActionStore;
      pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
      id<MTLCommandBuffer> command = [queue commandBuffer];
      id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
      [encoder setRenderPipelineState:pipeline];
      CGSize logicalSize = CGSizeMake(16.0, 16.0);
      CGSize drawableSize = CGSizeMake(32.0, 32.0);
      NimculusPaintRegion viewport = {4.0f, 4.0f, 4.0f, 4.0f};
      setScissorForRegion(encoder, viewport, logicalSize, drawableSize);
      drawColoredRectangle(encoder, device, logicalSize, 0.0, 0.0, 16.0, 16.0,
                           1.0f, 0.0f, 0.0f, 1.0f);
      [encoder endEncoding];
      [command commit];
      [command waitUntilCompleted];
      uint8_t pixels[32 * 32 * 4] = {0};
      [texture getBytes:pixels bytesPerRow:32 * 4 fromRegion:MTLRegionMake2D(0, 0, 32, 32)
             mipmapLevel:0];
      const NSUInteger inside = ((NSUInteger)20 * 32 + 10) * 4;
      const NSUInteger outsideLeft = ((NSUInteger)20 * 32 + 7) * 4;
      const NSUInteger outsideTop = ((NSUInteger)15 * 32 + 10) * 4;
      // BGRA8: the viewport is x=[8,16), y=[16,24) after 2x conversion.
      rendered = command.status == MTLCommandBufferStatusCompleted &&
        pixels[inside + 2] == 255 && pixels[inside + 1] == 0 &&
        pixels[outsideLeft + 2] == 0 && pixels[outsideTop + 2] == 0;
      if (rendered) {
        // Partial repaint uses the same path as the retained scene: only
        // dirty ∩ viewport may be submitted to the scissor. This ensures a
        // dirty region cannot repaint content outside its scroll container.
        NimculusPaintRegion dirty = {6.0f, 2.0f, 4.0f, 6.0f};
        NimculusPaintRegion visible = intersectPaintRegions(dirty, viewport);
        MTLRenderPassDescriptor *partialPass = [MTLRenderPassDescriptor renderPassDescriptor];
        partialPass.colorAttachments[0].texture = texture;
        partialPass.colorAttachments[0].loadAction = MTLLoadActionClear;
        partialPass.colorAttachments[0].storeAction = MTLStoreActionStore;
        partialPass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
        id<MTLCommandBuffer> partialCommand = [queue commandBuffer];
        id<MTLRenderCommandEncoder> partialEncoder =
          [partialCommand renderCommandEncoderWithDescriptor:partialPass];
        [partialEncoder setRenderPipelineState:pipeline];
        setScissorForRegion(partialEncoder, visible, logicalSize, drawableSize);
        drawColoredRectangle(partialEncoder, device, logicalSize, 0.0, 0.0, 16.0, 16.0,
                             1.0f, 0.0f, 0.0f, 1.0f);
        [partialEncoder endEncoding];
        [partialCommand commit];
        [partialCommand waitUntilCompleted];
        memset(pixels, 0, sizeof(pixels));
        [texture getBytes:pixels bytesPerRow:32 * 4 fromRegion:MTLRegionMake2D(0, 0, 32, 32)
               mipmapLevel:0];
        const NSUInteger partialInside = ((NSUInteger)20 * 32 + 13) * 4;
        const NSUInteger partialOutside = ((NSUInteger)20 * 32 + 11) * 4;
        // dirty ∩ viewport is logical x=[6,8), y=[4,8), or x=[12,16),
        // y=[16,24) on the 2x backing texture.
        rendered = partialCommand.status == MTLCommandBufferStatusCompleted &&
          visible.x == 6.0f && visible.y == 4.0f && visible.width == 2.0f &&
          visible.height == 4.0f && pixels[partialInside + 2] == 255 &&
          pixels[partialOutside + 2] == 0;
      }
    }
    [texture release];
    [pipeline release];
    [library release];
    [queue release];
    return rendered;
  }
}

bool nimculus_platform_validate_scene_texture_replacement(void) {
  BOOL valid = NO;
  @autoreleasepool {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (device) {
      id<MTLTexture> first = sceneTextureForDevice(device, CGSizeMake(320.0, 180.0));
      id<MTLTexture> reused = sceneTextureForDevice(device, CGSizeMake(320.0, 180.0));
      BOOL reusedSameTarget = first && reused == first && reused.width == 320 &&
        reused.height == 180;
      id<MTLTexture> resized = sceneTextureForDevice(device, CGSizeMake(640.0, 360.0));
      BOOL resizedTarget = resized && resized.width == 640 && resized.height == 360;
      id<MTLTexture> restored = sceneTextureForDevice(device, CGSizeMake(320.0, 180.0));
      BOOL restoredTarget = restored && restored.width == 320 && restored.height == 180;
      valid = reusedSameTarget && resizedTarget && restoredTarget;
    }
  }
  return valid;
}

static NSMenuItem *menuItemWithTitle(NSMenu *menu, NSString *title) {
  for (NSMenuItem *item in menu.itemArray) {
    if ([item.title isEqualToString:title]) return item;
  }
  return nil;
}

bool nimculus_platform_validate_main_menu(void) {
  @autoreleasepool {
    NSApplication *application = [NSApplication sharedApplication];
    NSMenu *previousMenu = application.mainMenu;
    NimculusAppDelegate *delegate = [NimculusAppDelegate new];
    [delegate setupMainMenu];
    NSMenu *mainMenu = application.mainMenu;
    NSMenuItem *appItem = menuItemWithTitle(mainMenu, @"Nimculus");
    NSMenuItem *fileItem = menuItemWithTitle(mainMenu, @"File");
    NSMenuItem *editItem = menuItemWithTitle(mainMenu, @"Edit");
    NSMenuItem *viewItem = menuItemWithTitle(mainMenu, @"View");
    NSMenuItem *windowItem = menuItemWithTitle(mainMenu, @"Window");
    BOOL topLevel = appItem.submenu && fileItem.submenu && editItem.submenu &&
      viewItem.submenu && windowItem.submenu;
    NSMenuItem *settings = menuItemWithTitle(appItem.submenu, @"Settings…");
    NSMenuItem *open = menuItemWithTitle(fileItem.submenu, @"Open…");
    NSMenuItem *save = menuItemWithTitle(fileItem.submenu, @"Save");
    NSMenuItem *saveAs = menuItemWithTitle(fileItem.submenu, @"Save As…");
    NSMenuItem *close = menuItemWithTitle(fileItem.submenu, @"Close Tab");
    NSMenuItem *redo = menuItemWithTitle(editItem.submenu, @"Redo");
    NSMenuItem *palette = menuItemWithTitle(editItem.submenu, @"Command Palette…");
    NSMenuItem *fullScreen = menuItemWithTitle(viewItem.submenu, @"Enter Full Screen");
    NSMenuItem *minimize = menuItemWithTitle(windowItem.submenu, @"Minimize");
    NSMenuItem *split = menuItemWithTitle(windowItem.submenu, @"Split Editor");
    NSMenuItem *closeSplit = menuItemWithTitle(windowItem.submenu, @"Close Split");
    NSMenuItem *zoom = menuItemWithTitle(windowItem.submenu, @"Zoom");
    BOOL shortcuts = settings.keyEquivalentModifierMask == NSEventModifierFlagCommand &&
      [settings.keyEquivalent isEqualToString:@","] &&
      open.keyEquivalentModifierMask == NSEventModifierFlagCommand &&
      [open.keyEquivalent isEqualToString:@"o"] &&
      save.keyEquivalentModifierMask == NSEventModifierFlagCommand &&
      [save.keyEquivalent isEqualToString:@"s"] &&
      saveAs.keyEquivalentModifierMask ==
        (NSEventModifierFlagCommand | NSEventModifierFlagShift) &&
      [saveAs.keyEquivalent isEqualToString:@"S"] &&
      close.keyEquivalentModifierMask == NSEventModifierFlagCommand &&
      [close.keyEquivalent isEqualToString:@"w"] &&
      redo.keyEquivalentModifierMask ==
        (NSEventModifierFlagCommand | NSEventModifierFlagShift) &&
      [redo.keyEquivalent isEqualToString:@"z"] &&
      palette.keyEquivalentModifierMask == (NSEventModifierFlagCommand | NSEventModifierFlagShift);
    BOOL windowActions = fullScreen && minimize && zoom && split && closeSplit &&
      fullScreen.action == @selector(toggleFullScreen:) &&
      minimize.action == @selector(performMiniaturize:) &&
      zoom.action == @selector(performZoom:) &&
      split.action == @selector(splitEditor:) &&
      closeSplit.action == @selector(closeSplit:) &&
      fullScreen.keyEquivalentModifierMask ==
        (NSEventModifierFlagCommand | NSEventModifierFlagControl) &&
      minimize.keyEquivalentModifierMask == NSEventModifierFlagCommand;
    BOOL valid = topLevel && settings && open && save && saveAs && close && redo && palette &&
      fullScreen && minimize && zoom && split && closeSplit && shortcuts && windowActions;
    [application setMainMenu:previousMenu];
    return valid;
  }
}

static uint32_t g_validation_shortcut_count = 0;
static uint32_t g_validation_shortcut_input_count = 0;
static BOOL g_validation_scroll_seen = NO;
static NimculusInputEvent g_validation_scroll_event;

static void validationScrollInputCallback(const NimculusInputEvent *event) {
  if (!event || event->type != NSEventTypeScrollWheel) return;
  g_validation_scroll_event = *event;
  g_validation_scroll_seen = YES;
}

static void validationShortcutInputCallback(const NimculusInputEvent *event) {
  if (event && event->type == NSEventTypeKeyDown && event->key_code == 35 &&
      (event->modifiers & NSEventModifierFlagCommand) != 0 &&
      (event->modifiers & NSEventModifierFlagShift) != 0) {
    g_validation_shortcut_input_count++;
  }
}

static bool validationShortcutCallback(const NimculusInputEvent *event) {
  if (!event || event->type != NSEventTypeKeyDown || event->key_code != 35) return false;
  if ((event->modifiers & NSEventModifierFlagCommand) == 0 ||
      (event->modifiers & NSEventModifierFlagShift) == 0) return false;
  g_validation_shortcut_count++;
  return true;
}

bool nimculus_platform_validate_shortcut_dispatch(void) {
  // Standard menu equivalents are resolved by AppKit before this view sees
  // keyDown:. This contract covers the complementary application shortcut
  // path, matching Zed's separation of key-equivalent and key-down events.
  @autoreleasepool {
    NimculusInputCallback previousInputCallback = g_input_callback;
    NimculusShortcutCallback previousShortcutCallback = g_shortcut_callback;
    g_validation_shortcut_count = 0;
    g_validation_shortcut_input_count = 0;
    g_input_callback = validationShortcutInputCallback;
    g_shortcut_callback = validationShortcutCallback;
    NimculusMetalView *view = [[NimculusMetalView alloc] initWithFrame:
      NSMakeRect(0.0, 0.0, 640.0, 480.0)];
    NSEvent *event = [NSEvent keyEventWithType:NSEventTypeKeyDown
      location:NSMakePoint(32.0, 24.0)
      modifierFlags:NSEventModifierFlagCommand | NSEventModifierFlagShift
      timestamp:0.0 windowNumber:0 context:nil characters:@"P"
      charactersIgnoringModifiers:@"p" isARepeat:NO keyCode:35];
    if (view && event) [view keyDown:event];
    BOOL valid = g_validation_shortcut_input_count == 0 &&
      g_validation_shortcut_count == 1;
    g_input_callback = previousInputCallback;
    g_shortcut_callback = previousShortcutCallback;
    [view release];
    return valid;
  }
}

bool nimculus_platform_validate_open_panel_sheet(void) {
  @autoreleasepool {
    NSApplication *application = [NSApplication sharedApplication];
    (void)application;
    NSWindow *window = [[NSWindow alloc]
      initWithContentRect:NSMakeRect(160.0, 180.0, 640.0, 480.0)
      styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    NimculusAppDelegate *delegate = [NimculusAppDelegate new];
    if (!window || !delegate) {
      [delegate release];
      [window release];
      return false;
    }
    delegate.window = window;
    [window makeKeyAndOrderFront:nil];
    [delegate openDocument:nil];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    NSWindow *sheet = window.attachedSheet;
    BOOL attached = [sheet isKindOfClass:[NSOpenPanel class]];
    if (sheet) [window endSheet:sheet returnCode:NSModalResponseCancel];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    BOOL detached = window.attachedSheet == nil;
    // NSOpenPanel finishes its sheet transform asynchronously. Let the
    // animation release its AppKit-owned state before releasing this
    // temporary parent window in the native contract.
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
    [window orderOut:nil];
    [delegate release];
    [window release];
    return attached && detached;
  }
}

static uint32_t g_validation_save_panel_cancel_count = 0;

static void validationSavePanelCommandCallback(const char *command) {
  if (command && strcmp(command, "savePanelCancelled") == 0) {
    g_validation_save_panel_cancel_count++;
  }
}

bool nimculus_platform_validate_save_panel_sheet(void) {
  NimculusPlatformMetrics previousMetrics = g_metrics;
  BOOL previousCloseDecision = g_close_decision;
  @autoreleasepool {
    // NSSavePanel requires an initialized application connection before it
    // creates its auxiliary XPC sheet services. Match the OpenPanel contract
    // so this remains valid in an isolated native test process.
    NSApplication *application = [NSApplication sharedApplication];
    (void)application;
    id previousView = g_active_view;
    NimculusCommandCallback previousCommandCallback = g_command_callback;
    g_validation_save_panel_cancel_count = 0;
    NSWindow *window = [[NSWindow alloc]
      initWithContentRect:NSMakeRect(160.0, 180.0, 640.0, 480.0)
      styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    // This contract verifies only the AppKit sheet and callback boundary.
    // A CAMetalLayer adds an unrelated IOSurface/XPC dependency in isolated
    // GUI test processes, so use the minimal NSView that supplies a window.
    NSView *view = [[NSView alloc] initWithFrame:
      NSMakeRect(0.0, 0.0, 640.0, 480.0)];
    if (!window || !view) {
      [view release];
      [window release];
      g_metrics = previousMetrics;
      return false;
    }
    window.contentView = view;
    g_active_view = view;
    g_command_callback = validationSavePanelCommandCallback;
    [window makeKeyAndOrderFront:nil];
    nimculus_platform_show_save_as_panel("日本語の候補名.nim");
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    NSWindow *sheet = window.attachedSheet;
    BOOL attached = [sheet isKindOfClass:[NSSavePanel class]] &&
      [((NSSavePanel *)sheet).nameFieldStringValue isEqualToString:@"日本語の候補名.nim"];
    if (sheet) [window endSheet:sheet returnCode:NSModalResponseCancel];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    BOOL detached = window.attachedSheet == nil;
    // NSSavePanel uses the same asynchronous sheet transform as NSOpenPanel.
    // Do not tear down the test window while that animation still owns it.
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
    g_active_view = previousView;
    g_command_callback = previousCommandCallback;
    g_close_decision = previousCloseDecision;
    [window orderOut:nil];
    [window close];
    [view release];
    [window release];
    g_metrics = previousMetrics;
    return attached && detached && g_validation_save_panel_cancel_count == 1;
  }
}

bool nimculus_platform_validate_unsaved_close_sheet(void) {
  NimculusPlatformMetrics previousMetrics = g_metrics;
  @autoreleasepool {
    NSApplication *application = [NSApplication sharedApplication];
    (void)application;
    id previousView = g_active_view;
    NSWindow *window = [[NSWindow alloc]
      initWithContentRect:NSMakeRect(160.0, 180.0, 640.0, 480.0)
      styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    NimculusMetalView *view = [[NimculusMetalView alloc] initWithFrame:
      NSMakeRect(0.0, 0.0, 640.0, 480.0)];
    if (!window || !view) {
      [view release];
      [window release];
      g_metrics = previousMetrics;
      return false;
    }
    window.contentView = view;
    g_active_view = view;
    [window makeKeyAndOrderFront:nil];
    // Pane-local callers pass their document's dirty state explicitly instead
    // of relying on the primary editor overlay's global dirty bit.
    nimculus_platform_request_close_tab_with_unsaved(true);
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    NSWindow *sheet = window.attachedSheet;
    // attachedSheet is AppKit's sheet window, not the NSAlert controller.
    BOOL attached = sheet != nil;
    if (sheet) [window endSheet:sheet returnCode:NSAlertThirdButtonReturn];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    BOOL detached = window.attachedSheet == nil;
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
    g_active_view = previousView;
    [window orderOut:nil];
    [window close];
    [view release];
    [window release];
    g_metrics = previousMetrics;
    return attached && detached;
  }
}

static char g_validation_file_path[PATH_MAX];
static BOOL g_validation_file_saving = YES;
static uint32_t g_validation_file_open_count = 0;
static char g_validation_command[64];

static void validationFileCallback(const char *path, bool saving) {
  g_validation_file_open_count++;
  strncpy(g_validation_file_path, path ?: "", sizeof(g_validation_file_path) - 1);
  g_validation_file_path[sizeof(g_validation_file_path) - 1] = '\0';
  g_validation_file_saving = saving;
}

static void validationCommandCallback(const char *command) {
  strncpy(g_validation_command, command ?: "", sizeof(g_validation_command) - 1);
  g_validation_command[sizeof(g_validation_command) - 1] = '\0';
}

bool nimculus_platform_validate_terminal_session_bar(void) {
  @autoreleasepool {
    NimculusCommandCallback previousCallback = g_command_callback;
    NSArray<NSString *> *previousTitles = [g_terminal_session_titles retain];
    NSUInteger previousActive = g_terminal_active_session;
    g_command_callback = validationCommandCallback;
    nimculus_platform_set_terminal_sessions("Terminal 1\nTerminal 2", 21, 1);
    NimculusTerminalSessionBar *bar = [[NimculusTerminalSessionBar alloc]
      initWithFrame:NSMakeRect(0.0, 0.0, 280.0, 27.0)];
    [bar.sessionPicker selectItemAtIndex:0];
    [bar selectSession:bar.sessionPicker];
    BOOL select = strcmp(g_validation_command, "terminalSession:0") == 0;
    [bar newTerminal:bar.newButton];
    BOOL create = strcmp(g_validation_command, "terminalNew") == 0;
    [bar closeTerminal:bar.closeButton];
    BOOL close = strcmp(g_validation_command, "terminalClose") == 0;
    BOOL presentation = bar.sessionPicker.numberOfItems == 2 &&
      [bar.sessionPicker.titleOfSelectedItem isEqualToString:@"Terminal 1"] &&
      bar.newButton.enabled && bar.closeButton.enabled;
    [bar release];
    replaceOwnedArray(&g_terminal_session_titles, previousTitles ?: @[]);
    g_terminal_active_session = previousActive;
    [previousTitles release];
    g_command_callback = previousCallback;
    return select && create && close && presentation;
  }
}

bool nimculus_platform_validate_output_panel_bar(void) {
  @autoreleasepool {
    NimculusCommandCallback previousCallback = g_command_callback;
    NSString *previousTitle = [g_task_output_title retain];
    g_command_callback = validationCommandCallback;
    nimculus_platform_set_task_output_title("Git Commit", 10);
    NimculusOutputPanelBar *bar = [[NimculusOutputPanelBar alloc]
      initWithFrame:NSMakeRect(0.0, 0.0, 280.0, 27.0)];
    [bar closeOutput:bar.closeButton];
    BOOL close = strcmp(g_validation_command, "closeOutputPanel") == 0;
    BOOL presentation = [bar.titleLabel.stringValue isEqualToString:@"Git Commit"] &&
      [bar.closeButton.toolTip isEqualToString:@"Close Output Panel"];
    [bar release];
    replaceOwnedString(&g_task_output_title, previousTitle ?: @"Task Output");
    [previousTitle release];
    g_command_callback = previousCallback;
    NimculusTaskOutputOverlay *output = [[NimculusTaskOutputOverlay alloc]
      initWithFrame:NSMakeRect(0.0, 0.0, 280.0, 120.0)];
    BOOL readable = output.acceptsFirstResponder && [output hitTest:NSMakePoint(2.0, 2.0)] == output;
    [output release];
    return close && presentation && readable;
  }
}

bool nimculus_platform_validate_tab_bar_close_targets(void) {
  @autoreleasepool {
    NimculusCommandCallback previousCallback = g_command_callback;
    NSArray<NSString *> *previousTitles = [g_editor_tab_titles retain];
    NSUInteger previousActive = g_editor_active_tab;
    g_command_callback = validationCommandCallback;
    replaceOwnedArray(&g_editor_tab_titles, @[@"first", @"second"]);
    g_editor_active_tab = 0;
    NimculusTabBarOverlay *tabs = [[NimculusTabBarOverlay alloc]
      initWithFrame:NSMakeRect(0.0, 0.0, 400.0, 28.0)];
    [tabs dispatchTabAtPoint:NSMakePoint(187.0, 12.0)];
    BOOL closeFirst = strcmp(g_validation_command, "closePaneTab:0:0") == 0;
    [tabs dispatchTabAtPoint:NSMakePoint(387.0, 12.0)];
    BOOL closeSecond = strcmp(g_validation_command, "closePaneTab:0:1") == 0;
    [tabs dispatchTabAtPoint:NSMakePoint(260.0, 12.0)];
    BOOL selectSecond = strcmp(g_validation_command, "selectPaneTab:0:1") == 0;
    [tabs release];
    replaceOwnedArray(&g_editor_tab_titles, previousTitles ?: @[]);
    g_editor_active_tab = previousActive;
    [previousTitles release];
    g_command_callback = previousCallback;
    return closeFirst && closeSecond && selectSecond;
  }
}

bool nimculus_platform_validate_sidebar_dispatch(void) {
  @autoreleasepool {
    NimculusCommandCallback previousCallback = g_command_callback;
    uint32_t previousMode = g_editor_sidebar_mode;
    uint32_t previousCount = g_editor_outline_symbol_count;
    g_validation_command[0] = '\0';
    g_command_callback = validationCommandCallback;
    g_editor_sidebar_mode = 1;
    g_editor_outline_symbol_count = 2;
    NimculusOutlineOverlay *sidebar = [[NimculusOutlineOverlay alloc]
      initWithFrame:NSMakeRect(0.0, 0.0, 180.0, 100.0)];
    [sidebar dispatchSidebarLine:3 open:NO];
    BOOL selected = strcmp(g_validation_command, "sidebarSelect:1") == 0;
    [sidebar dispatchSidebarLine:3 open:YES];
    BOOL opened = strcmp(g_validation_command, "sidebarOpen:1") == 0;
    BOOL valid = selected && opened;
    [sidebar release];
    g_editor_outline_symbol_count = previousCount;
    g_editor_sidebar_mode = previousMode;
    g_command_callback = previousCallback;
    return valid;
  }
}

bool nimculus_platform_validate_sidebar_context_dispatch(void) {
  @autoreleasepool {
    NimculusCommandCallback previousCallback = g_command_callback;
    uint32_t previousMode = g_editor_sidebar_mode;
    uint32_t previousCount = g_editor_outline_symbol_count;
    g_validation_command[0] = '\0';
    g_command_callback = validationCommandCallback;
    g_editor_sidebar_mode = 1;
    g_editor_outline_symbol_count = 2;
    NimculusOutlineOverlay *sidebar = [[NimculusOutlineOverlay alloc]
      initWithFrame:NSMakeRect(0.0, 0.0, 180.0, 100.0)];
    [sidebar dispatchSidebarContext:1];
    BOOL files = strcmp(g_validation_command, "sidebarContext:1") == 0;
    g_editor_sidebar_mode = 2;
    [sidebar dispatchSidebarContext:1];
    BOOL history = strcmp(g_validation_command, "sidebarContext:1") == 0;
    g_editor_sidebar_mode = 3;
    [sidebar dispatchSidebarContext:1];
    BOOL status = strcmp(g_validation_command, "sidebarContext:1") == 0;
    g_editor_sidebar_mode = 4;
    strcpy(g_validation_command, "unchanged");
    [sidebar dispatchSidebarContext:1];
    BOOL branches = strcmp(g_validation_command, "unchanged") == 0;
    BOOL valid = files && history && status && branches;
    [sidebar release];
    g_editor_outline_symbol_count = previousCount;
    g_editor_sidebar_mode = previousMode;
    g_command_callback = previousCallback;
    return valid;
  }
}

bool nimculus_platform_validate_git_sidebar_tabs(void) {
  @autoreleasepool {
    NimculusCommandCallback previousCallback = g_command_callback;
    g_command_callback = validationCommandCallback;
    NimculusGitSidebarTabs *tabs = [[NimculusGitSidebarTabs alloc]
      initWithFrame:NSMakeRect(0.0, 0.0, 240.0, 24.0)];
    [tabs setSelectedSegment:1];
    [tabs selectGitSidebarMode:tabs];
    BOOL history = strcmp(g_validation_command, "commandPalette:git log") == 0;
    [tabs setSelectedSegment:2];
    [tabs selectGitSidebarMode:tabs];
    BOOL branches = strcmp(g_validation_command, "commandPalette:git branches") == 0;
    [tabs setSelectedSegment:0];
    [tabs selectGitSidebarMode:tabs];
    BOOL changes = strcmp(g_validation_command, "commandPalette:git status") == 0;
    [tabs release];
    NimculusGitCommitButton *commit = [[NimculusGitCommitButton alloc]
      initWithFrame:NSMakeRect(0.0, 0.0, 76.0, 24.0)];
    [commit requestCommit:commit];
    BOOL commitAction = strcmp(g_validation_command, "gitCommitPrompt") == 0;
    BOOL commitPresentation = [commit.title isEqualToString:@"Commit…"] &&
      [commit.toolTip isEqualToString:@"Commit staged changes"];
    [commit release];
    g_command_callback = previousCallback;
    return history && branches && changes && commitAction && commitPresentation;
  }
}

bool nimculus_platform_validate_files_sidebar_actions(void) {
  @autoreleasepool {
    BOOL previousWorkspaceOpen = g_workspace_open;
    g_workspace_open = YES;
    NimculusFilesSidebarActions *actions = [[NimculusFilesSidebarActions alloc]
      initWithFrame:NSMakeRect(0.0, 0.0, 240.0, 24.0)];
    NSArray<NSView *> *buttons = actions.arrangedSubviews;
    BOOL workspaceActions = buttons.count == 2 &&
      [((NSButton *)buttons[0]).title isEqualToString:@"New File"] &&
      [((NSButton *)buttons[1]).title isEqualToString:@"New Folder"];
    g_workspace_open = NO;
    [actions reloadActions];
    buttons = actions.arrangedSubviews;
    BOOL emptyActions = buttons.count == 1 &&
      [((NSButton *)buttons[0]).title isEqualToString:@"Open Folder…"];
    [actions release];
    g_workspace_open = previousWorkspaceOpen;
    return workspaceActions && emptyActions;
  }
}

bool nimculus_platform_validate_workspace_toolbar(void) {
  @autoreleasepool {
    NimculusCommandCallback previousCallback = g_command_callback;
    uint32_t previousMode = g_editor_sidebar_mode;
    BOOL previousSidebarVisible = g_editor_sidebar_visible;
    BOOL previousTerminalVisible = g_terminal_visible;
    g_command_callback = validationCommandCallback;
    NimculusWorkspaceToolbar *toolbar = [[NimculusWorkspaceToolbar alloc]
      initWithFrame:NSMakeRect(0.0, 0.0, 360.0, 22.0)];
    NSArray<NSView *> *buttons = toolbar.arrangedSubviews;
    BOOL presentation = buttons.count == 4 &&
      [((NSButton *)buttons[0]).title isEqualToString:@"Files"] &&
      [((NSButton *)buttons[1]).title isEqualToString:@"Outline"] &&
      [((NSButton *)buttons[2]).title isEqualToString:@"Git"] &&
      [((NSButton *)buttons[3]).title isEqualToString:@"Terminal"];
    g_editor_sidebar_visible = YES;
    g_editor_sidebar_mode = 2;
    g_terminal_visible = YES;
    [toolbar reloadSelection];
    BOOL selection = ((NSButton *)buttons[2]).contentTintColor != nil &&
      ((NSButton *)buttons[3]).contentTintColor != nil &&
      ((NSButton *)buttons[0]).contentTintColor == nil;
    [toolbar dispatchWorkspaceCommand:(NSButton *)buttons[2]];
    BOOL git = strcmp(g_validation_command, "commandPalette:git status") == 0;
    [toolbar dispatchWorkspaceCommand:(NSButton *)buttons[3]];
    BOOL terminal = strcmp(g_validation_command, "commandPalette:toggle terminal") == 0;
    [toolbar release];
    g_editor_sidebar_mode = previousMode;
    g_editor_sidebar_visible = previousSidebarVisible;
    g_terminal_visible = previousTerminalVisible;
    g_command_callback = previousCallback;
    return presentation && selection && git && terminal;
  }
}

bool nimculus_platform_validate_activity_bar(void) {
  @autoreleasepool {
    NimculusCommandCallback previousCallback = g_command_callback;
    uint32_t previousMode = g_editor_sidebar_mode;
    BOOL previousSidebarVisible = g_editor_sidebar_visible;
    BOOL previousTerminalVisible = g_terminal_visible;
    g_command_callback = validationCommandCallback;
    g_editor_sidebar_visible = YES;
    g_editor_sidebar_mode = 1;
    g_terminal_visible = NO;
    NimculusActivityBar *bar = [[NimculusActivityBar alloc]
      initWithFrame:NSMakeRect(0.0, 0.0, 30.0, 180.0)];
    NSArray<NSView *> *buttons = bar.arrangedSubviews;
    BOOL presentation = buttons.count == 4 &&
      [((NSButton *)buttons[0]).toolTip isEqualToString:@"Files"] &&
      [((NSButton *)buttons[1]).toolTip isEqualToString:@"Outline"] &&
      [((NSButton *)buttons[2]).toolTip isEqualToString:@"Git"] &&
      [((NSButton *)buttons[3]).toolTip isEqualToString:@"Terminal"] &&
      ((NSButton *)buttons[0]).contentTintColor != nil &&
      ((NSButton *)buttons[1]).contentTintColor == nil;
    [bar dispatchWorkspaceCommand:(NSButton *)buttons[2]];
    BOOL git = strcmp(g_validation_command, "commandPalette:git status") == 0;
    g_terminal_visible = YES;
    [bar reloadSelection];
    BOOL terminalSelected = ((NSButton *)buttons[3]).contentTintColor != nil;
    [bar release];
    g_editor_sidebar_mode = previousMode;
    g_editor_sidebar_visible = previousSidebarVisible;
    g_terminal_visible = previousTerminalVisible;
    g_command_callback = previousCallback;
    return presentation && git && terminalSelected;
  }
}

bool nimculus_platform_validate_sidebar_scroll_container(void) {
  @autoreleasepool {
    id previousView = g_active_view;
    NSString *previousText = [g_editor_outline_text retain];
    uint32_t previousMode = g_editor_sidebar_mode;
    uint32_t previousCount = g_editor_outline_symbol_count;
    NSUInteger previousSelection = g_editor_sidebar_selected_index;
    NimculusMetalView *view = [[NimculusMetalView alloc]
      initWithFrame:NSMakeRect(0.0, 0.0, 640.0, 480.0)];
    NimculusOutlineOverlay *sidebar = outlineOverlayForView(view);
    g_active_view = view;
    const char *text = "Files\n────────\nsrc\nmain.nim";
    nimculus_platform_set_editor_sidebar(text, (uint32_t)strlen(text), 2, 1);
    nimculus_platform_set_editor_sidebar_selection(1);
    NSString *selected = sidebar.string && sidebar.selectedRange.location != NSNotFound
      ? [sidebar.string substringWithRange:sidebar.selectedRange] : @"";
    BOOL valid = sidebar && sidebar.enclosingScrollView &&
      sidebar.enclosingScrollView.hasVerticalScroller && [selected isEqualToString:@"main.nim"];
    replaceOwnedUTF8String(&g_editor_outline_text, previousText.UTF8String,
      (uint32_t)[previousText lengthOfBytesUsingEncoding:NSUTF8StringEncoding], @"");
    g_editor_sidebar_mode = previousMode;
    g_editor_outline_symbol_count = previousCount;
    g_editor_sidebar_selected_index = previousSelection;
    g_active_view = previousView;
    [previousText release];
    [view release];
    return valid;
  }
}

bool nimculus_platform_validate_application_alert_sheet(void) {
  NimculusPlatformMetrics previousMetrics = g_metrics;
  @autoreleasepool {
    NSApplication *application = [NSApplication sharedApplication];
    (void)application;
    NimculusCommandCallback previousCallback = g_command_callback;
    NSWindow *window = [[NSWindow alloc]
      initWithContentRect:NSMakeRect(160.0, 180.0, 640.0, 480.0)
      styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    NimculusAppDelegate *delegate = [NimculusAppDelegate new];
    if (!window || !delegate) {
      [delegate release];
      [window release];
      g_metrics = previousMetrics;
      return false;
    }
    delegate.window = window;
    g_command_callback = validationCommandCallback;
    g_validation_command[0] = '\0';
    [window makeKeyAndOrderFront:nil];
    [delegate findInDocument:nil];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    NSWindow *sheet = window.attachedSheet;
    BOOL attached = sheet != nil;
    if (sheet) [window endSheet:sheet returnCode:NSAlertFirstButtonReturn];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    BOOL dispatched = strcmp(g_validation_command, "findDocument:") == 0;
    BOOL detached = window.attachedSheet == nil;
    // Let the AppKit sheet transform release before tearing down the
    // temporary parent window, as in the Open/Save sheet contracts.
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
    g_command_callback = previousCallback;
    [window orderOut:nil];
    [window close];
    [delegate release];
    [window release];
    g_metrics = previousMetrics;
    return attached && dispatched && detached;
  }
}

bool nimculus_platform_validate_file_open_events(void) {
  @autoreleasepool {
    NimculusFileCallback previousCallback = g_file_callback;
    g_file_callback = validationFileCallback;
    g_validation_file_path[0] = '\0';
    g_validation_file_saving = YES;
    g_validation_file_open_count = 0;
    NimculusAppDelegate *delegate = [NimculusAppDelegate new];
    NSString *finderPath = @"/tmp/nimculus-日本語-finder-open.txt";
    NSString *secondFinderPath = @"/tmp/nimculus-emoji-🙂.txt";
    [delegate application:NSApp openFiles:@[finderPath, secondFinderPath]];
    BOOL finderValid = !g_validation_file_saving && g_validation_file_open_count == 2 &&
      [@(g_validation_file_path) isEqualToString:secondFinderPath];
    NSURL *url = [NSURL URLWithString:@"nimculus:///tmp/nimculus-url-open.txt"];
    [delegate application:NSApp openURLs:@[url]];
    BOOL urlValid = !g_validation_file_saving && g_validation_file_open_count == 3 &&
      [@(g_validation_file_path) isEqualToString:@"/tmp/nimculus-url-open.txt"];
    g_file_callback = previousCallback;
    return finderValid && urlValid;
  }
}

bool nimculus_platform_validate_deferred_file_open_events(void) {
  @autoreleasepool {
    NimculusFileCallback previousCallback = g_file_callback;
    NSMutableArray<NSString *> *previousPending = [g_pending_file_open_paths retain];
    [g_pending_file_open_paths release];
    g_pending_file_open_paths = nil;
    g_file_callback = NULL;
    g_validation_file_path[0] = '\0';
    g_validation_file_saving = YES;
    g_validation_file_open_count = 0;
    NimculusAppDelegate *delegate = [NimculusAppDelegate new];
    NSString *folder = @"/tmp/nimculus-finder-project";
    NSString *file = @"/tmp/nimculus-日本語-finder-file.txt";
    [delegate application:NSApp openFiles:@[folder, file]];
    BOOL queued = g_pending_file_open_paths.count == 2 &&
      [g_pending_file_open_paths[0] isEqualToString:folder] &&
      [g_pending_file_open_paths[1] isEqualToString:file];
    nimculus_platform_set_file_callback(validationFileCallback);
    BOOL delivered = !g_validation_file_saving && g_validation_file_open_count == 2 &&
      [@(g_validation_file_path) isEqualToString:file] &&
      g_pending_file_open_paths.count == 0;
    [delegate release];
    g_file_callback = previousCallback;
    [g_pending_file_open_paths release];
    g_pending_file_open_paths = previousPending;
    return queued && delivered;
  }
}

bool nimculus_platform_validate_external_change_sheet(void) {
  NimculusPlatformMetrics previousMetrics = g_metrics;
  @autoreleasepool {
    NSApplication *application = [NSApplication sharedApplication];
    (void)application;
    id previousView = g_active_view;
    NimculusCommandCallback previousCallback = g_command_callback;
    g_validation_command[0] = '\0';
    NSWindow *window = [[NSWindow alloc]
      initWithContentRect:NSMakeRect(160.0, 180.0, 640.0, 480.0)
      styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    NimculusMetalView *view = [[NimculusMetalView alloc] initWithFrame:
      NSMakeRect(0.0, 0.0, 640.0, 480.0)];
    if (!window || !view) {
      [view release];
      [window release];
      g_metrics = previousMetrics;
      return false;
    }
    window.contentView = view;
    g_active_view = view;
    g_command_callback = validationCommandCallback;
    [window makeKeyAndOrderFront:nil];
    nimculus_platform_show_external_change("/tmp/nimculus-external-change.txt");
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    NSWindow *sheet = window.attachedSheet;
    BOOL attached = sheet != nil;
    if (sheet) [window endSheet:sheet returnCode:NSAlertFirstButtonReturn];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    BOOL reloaded = strcmp(g_validation_command, "reloadExternal") == 0;
    // NSAlert also owns a sheet transform until the following run-loop turns.
    // Complete it before the temporary test window is released.
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
    g_command_callback = previousCallback;
    g_active_view = previousView;
    [window orderOut:nil];
    [window close];
    [view release];
    [window release];
    // Temporary view attachment updates shared drawable metrics. Restore them
    // so later platform contracts observe the same global state as production
    // code does after a sheet closes.
    g_metrics = previousMetrics;
    return attached && reloaded;
  }
}

static char g_validation_ime_text[6][128];
static BOOL g_validation_ime_composing[6];
static uint32_t g_validation_ime_text_count = 0;
static uint32_t g_validation_ime_selection_start = 0;
static uint32_t g_validation_ime_selection_end = 0;
static uint32_t g_validation_ime_selection_start2 = 0;
static uint32_t g_validation_ime_selection_end2 = 0;
static uint32_t g_validation_ime_selection_count = 0;

static void validationImeTextCallback(const char *utf8, bool composing) {
  uint32_t index = g_validation_ime_text_count++;
  if (index >= 6) return;
  strncpy(g_validation_ime_text[index], utf8 ?: "", sizeof(g_validation_ime_text[index]) - 1);
  g_validation_ime_text[index][sizeof(g_validation_ime_text[index]) - 1] = '\0';
  g_validation_ime_composing[index] = composing;
}

static void validationImeSelectionCallback(uint32_t startByte, uint32_t endByte) {
  if (g_validation_ime_selection_count == 0) {
    g_validation_ime_selection_start = startByte;
    g_validation_ime_selection_end = endByte;
  } else if (g_validation_ime_selection_count == 1) {
    g_validation_ime_selection_start2 = startByte;
    g_validation_ime_selection_end2 = endByte;
  }
  g_validation_ime_selection_count++;
}

bool nimculus_platform_validate_ime_composition(void) {
  @autoreleasepool {
    NimculusTextCallback previousTextCallback = g_text_callback;
    NimculusSelectionCallback previousSelectionCallback = g_selection_callback;
    NSString *previousText = g_editor_text;
    NSUInteger previousSelectionStart = g_editor_selection_start;
    NSUInteger previousSelectionEnd = g_editor_selection_end;
    g_validation_ime_text_count = 0;
    g_validation_ime_selection_count = 0;
    g_validation_ime_selection_start2 = 0;
    g_validation_ime_selection_end2 = 0;
    memset(g_validation_ime_text, 0, sizeof(g_validation_ime_text));
    g_validation_ime_text[0][0] = '\0';
    g_text_callback = validationImeTextCallback;
    g_selection_callback = validationImeSelectionCallback;
    g_editor_text = @"A日本語";
    g_editor_selection_start = 1;
    g_editor_selection_end = 4;
    NimculusMetalView *view = [[NimculusMetalView alloc] initWithFrame:
      NSMakeRect(0.0, 0.0, 640.0, 480.0)];
    [view setMarkedText:@"にっぽん" selectedRange:NSMakeRange(4, 0)
      replacementRange:NSMakeRange(NSNotFound, 0)];
    BOOL marked = view.hasMarkedText && view.markedRange.location == 1 &&
      view.markedRange.length == 4 && g_validation_ime_text_count == 1 &&
      strcmp(g_validation_ime_text[0], "にっぽん") == 0 &&
      g_validation_ime_composing[0] && g_validation_ime_selection_count == 1 &&
      g_validation_ime_selection_start == 1 && g_validation_ime_selection_end == 10;
    [view insertText:@"日本" replacementRange:NSMakeRange(1, 2)];
    BOOL committed = g_validation_ime_text_count == 3 &&
      strcmp(g_validation_ime_text[1], "日本") == 0 &&
      !g_validation_ime_composing[1] && g_validation_ime_text[2][0] == '\0' &&
      g_validation_ime_composing[2] && g_validation_ime_selection_count == 2 &&
      g_validation_ime_selection_start2 == 1 && g_validation_ime_selection_end2 == 7 &&
      !view.hasMarkedText;
    [view setMarkedText:@"かな" selectedRange:NSMakeRange(1, 0)
      replacementRange:NSMakeRange(NSNotFound, 0)];
    [view unmarkText];
    BOOL cancelled = g_validation_ime_text_count == 5 &&
      strcmp(g_validation_ime_text[3], "かな") == 0 &&
      g_validation_ime_composing[3] && g_validation_ime_text[4][0] == '\0' &&
      g_validation_ime_composing[4] && !view.hasMarkedText &&
      view.markedRange.location == NSNotFound;
    g_text_callback = previousTextCallback;
    g_selection_callback = previousSelectionCallback;
    g_editor_text = previousText;
    g_editor_selection_start = previousSelectionStart;
    g_editor_selection_end = previousSelectionEnd;
    return marked && committed && cancelled;
  }
}

bool nimculus_platform_validate_ime_command_dispatch(void) {
  @autoreleasepool {
    NimculusTextCallback previousTextCallback = g_text_callback;
    NimculusSelectionCallback previousSelectionCallback = g_selection_callback;
    NimculusCommandCallback previousCommandCallback = g_command_callback;
    g_text_callback = NULL;
    g_selection_callback = NULL;
    g_command_callback = validationCommandCallback;
    g_validation_command[0] = '\0';
    NimculusMetalView *view = [[NimculusMetalView alloc] initWithFrame:
      NSMakeRect(0.0, 0.0, 640.0, 480.0)];
    if (!view) {
      g_text_callback = previousTextCallback;
      g_selection_callback = previousSelectionCallback;
      g_command_callback = previousCommandCallback;
      return false;
    }

    // Zed gives an active input handler the first opportunity to consume a
    // key. When it declines, AppKit calls doCommandBySelector:, which must
    // return the editor command without committing or cancelling marked text.
    [view setMarkedText:@"かな" selectedRange:NSMakeRange(1, 0)
      replacementRange:NSMakeRange(NSNotFound, 0)];
    [view doCommandBySelector:@selector(moveLeft:)];
    BOOL moved = strcmp(g_validation_command, "moveLeft") == 0 && view.hasMarkedText;
    [view doCommandBySelector:@selector(deleteBackward:)];
    BOOL deleted = strcmp(g_validation_command, "deleteBackward") == 0 && view.hasMarkedText;
    [view doCommandBySelector:@selector(cancelOperation:)];
    BOOL cancelled = strcmp(g_validation_command, "cancel") == 0 && view.hasMarkedText;
    [view doCommandBySelector:@selector(moveToBeginningOfDocumentAndModifySelection:)];
    BOOL selectDocumentStart = strcmp(g_validation_command, "selectToBeginningOfDocument") == 0 &&
      view.hasMarkedText;
    [view doCommandBySelector:@selector(moveToEndOfDocumentAndModifySelection:)];
    BOOL selectDocumentEnd = strcmp(g_validation_command, "selectToEndOfDocument") == 0 &&
      view.hasMarkedText;
    [view doCommandBySelector:@selector(deleteWordForward:)];
    BOOL wordForward = strcmp(g_validation_command, "deleteWordForward") == 0 && view.hasMarkedText;
    [view doCommandBySelector:@selector(deleteToBeginningOfLine:)];
    BOOL lineStart = strcmp(g_validation_command, "deleteToBeginningOfLine") == 0 && view.hasMarkedText;
    [view doCommandBySelector:@selector(deleteToEndOfLine:)];
    BOOL lineEnd = strcmp(g_validation_command, "deleteToEndOfLine") == 0 && view.hasMarkedText;
    [view unmarkText];
    BOOL unmarked = !view.hasMarkedText && view.markedRange.location == NSNotFound;

    [view release];
    g_text_callback = previousTextCallback;
    g_selection_callback = previousSelectionCallback;
    g_command_callback = previousCommandCallback;
    return moved && deleted && cancelled && selectDocumentStart && selectDocumentEnd &&
      wordForward && lineStart && lineEnd && unmarked;
  }
}

bool nimculus_platform_validate_ime_candidate_rect(void) {
  NimculusPlatformMetrics previousMetrics = g_metrics;
  BOOL valid = NO;
  @autoreleasepool {
    NSString *previousText = g_editor_text;
    NSString *previousSecondaryText = [g_secondary_editor_text retain];
    NSUInteger previousSelectionStart = g_editor_selection_start;
    NSUInteger previousSelectionEnd = g_editor_selection_end;
    NSUInteger previousScrollLine = g_editor_scroll_line;
    CGFloat previousRect[4] = {g_editor_rect[0], g_editor_rect[1],
      g_editor_rect[2], g_editor_rect[3]};
    CGFloat previousSecondaryRect[4] = {g_secondary_editor_rect[0],
      g_secondary_editor_rect[1], g_secondary_editor_rect[2],
      g_secondary_editor_rect[3]};
    BOOL previousSecondaryVisible = g_secondary_editor_visible;
    NSUInteger previousInputPane = g_editor_input_pane;
    NSUInteger previousSecondaryScrollLine = g_secondary_editor_scroll_line;
    g_editor_text = @"A日本語\nB";
    rebuildEditorLineIndex();
    nimculus_platform_set_secondary_editor_text("🙂\n日本語",
      (uint32_t)strlen("🙂\n日本語"));
    g_editor_selection_start = 0;
    g_editor_selection_end = 0;
    g_editor_scroll_line = 0;
    g_editor_rect[0] = 48.0;
    g_editor_rect[1] = 80.0;
    g_editor_rect[2] = 400.0;
    g_editor_rect[3] = 300.0;
    // This validation exercises the primary responder. A previous split-pane
    // test must not route firstRectForCharacterRange: through a stale
    // secondary rectangle.
    g_secondary_editor_visible = NO;
    g_editor_input_pane = 0;
    NSWindow *window = [[NSWindow alloc]
      initWithContentRect:NSMakeRect(120.0, 160.0, 640.0, 480.0)
      styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    NimculusMetalView *view = [[NimculusMetalView alloc] initWithFrame:
      NSMakeRect(0.0, 0.0, 640.0, 480.0)];
    if (window && view) {
      NSApplication *application = [NSApplication sharedApplication];
      [application activateIgnoringOtherApps:YES];
      window.contentView = view;
      [window makeKeyAndOrderFront:nil];
      NSDate *until = [NSDate dateWithTimeIntervalSinceNow:0.02];
      [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:until];
      [view layoutSubtreeIfNeeded];
      NSRange actualFirst = NSMakeRange(NSNotFound, 0);
      NSRange actualSecond = NSMakeRange(NSNotFound, 0);
      NSRange actualSecondary = NSMakeRange(NSNotFound, 0);
      NSRect first = [view firstRectForCharacterRange:NSMakeRange(0, 0)
        actualRange:&actualFirst];
      NSRect second = [view firstRectForCharacterRange:NSMakeRange(1, 0)
        actualRange:&actualSecond];
      g_secondary_editor_rect[0] = 472.0;
      g_secondary_editor_rect[1] = 80.0;
      g_secondary_editor_rect[2] = 320.0;
      g_secondary_editor_rect[3] = 300.0;
      g_secondary_editor_visible = YES;
      g_secondary_editor_scroll_line = 0;
      g_editor_input_pane = 1;
      nimculus_platform_set_secondary_editor_selection(4, 4);
      NSRect secondary = [view firstRectForCharacterRange:NSMakeRange(3, 0)
        actualRange:&actualSecondary];
      NSUInteger secondaryCharacter = [view characterIndexForPoint:secondary.origin];
      valid = actualFirst.location == 0 && actualFirst.length == 0 &&
        actualSecond.location == 1 && actualSecond.length == 0 &&
        actualSecondary.location == 3 && actualSecondary.length == 0 &&
        first.size.height > 0.0 && second.size.height > 0.0 &&
        secondary.size.height > 0.0 && second.origin.x > first.origin.x &&
        secondary.origin.x > second.origin.x && secondary.origin.y < second.origin.y &&
        secondaryCharacter == 3 && view.selectedTextRange.location == 2 &&
        isfinite(first.origin.x) &&
        isfinite(first.origin.y) && isfinite(second.origin.x) &&
        isfinite(second.origin.y) && isfinite(secondary.origin.x) &&
        isfinite(secondary.origin.y);
      [window orderOut:nil];
      window.contentView = nil;
      [view release];
      [window close];
      [window release];
    }
    g_editor_text = previousText;
    rebuildEditorLineIndex();
    nimculus_platform_set_secondary_editor_text(previousSecondaryText.UTF8String,
      (uint32_t)[previousSecondaryText lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
    g_editor_selection_start = previousSelectionStart;
    g_editor_selection_end = previousSelectionEnd;
    g_editor_scroll_line = previousScrollLine;
    g_editor_rect[0] = previousRect[0];
    g_editor_rect[1] = previousRect[1];
    g_editor_rect[2] = previousRect[2];
    g_editor_rect[3] = previousRect[3];
    memcpy(g_secondary_editor_rect, previousSecondaryRect, sizeof(previousSecondaryRect));
    g_secondary_editor_visible = previousSecondaryVisible;
    g_editor_input_pane = previousInputPane;
    g_secondary_editor_scroll_line = previousSecondaryScrollLine;
    [previousSecondaryText release];
  }
  // AppKit may detach the temporary view while the autorelease pool drains.
  // Restore the shared resize metrics after that boundary, as in the native
  // window lifecycle contract.
  g_metrics = previousMetrics;
  return valid;
}

bool nimculus_platform_validate_input_event_fields(void) {
  @autoreleasepool {
    // AppKit's event factories expose different constructors for keyboard,
    // scroll, and tracking events. Exercise each event class through the same
    // field-reading boundary used by the live view.
    NSEvent *mouseMoved = [NSEvent mouseEventWithType:NSEventTypeMouseMoved
      location:NSMakePoint(32.0, 24.0) modifierFlags:0 timestamp:0.0
      windowNumber:0 context:nil eventNumber:0 clickCount:0 pressure:0.0];
    NSEvent *keyDown = [NSEvent keyEventWithType:NSEventTypeKeyDown
      location:NSMakePoint(32.0, 24.0) modifierFlags:0 timestamp:0.0
      windowNumber:0 context:nil characters:@"a" charactersIgnoringModifiers:@"a"
      isARepeat:NO keyCode:0];
    NSEvent *flagsChanged = [NSEvent keyEventWithType:NSEventTypeFlagsChanged
      location:NSMakePoint(32.0, 24.0) modifierFlags:NSEventModifierFlagCommand
      timestamp:0.0 windowNumber:0 context:nil characters:@""
      charactersIgnoringModifiers:@"" isARepeat:NO keyCode:55];
    CGEventRef scrollEvent = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitPixel,
      2, 3, -2, 0);
    NSEvent *scrollWheel = scrollEvent ? [NSEvent eventWithCGEvent:scrollEvent] : nil;
    if (scrollEvent) CFRelease(scrollEvent);
    NSEvent *mouseEntered = [NSEvent enterExitEventWithType:NSEventTypeMouseEntered
      location:NSMakePoint(32.0, 24.0) modifierFlags:0 timestamp:0.0
      windowNumber:0 context:nil eventNumber:1 trackingNumber:1 userData:nil];
    NSEvent *mouseExited = [NSEvent enterExitEventWithType:NSEventTypeMouseExited
      location:NSMakePoint(32.0, 24.0) modifierFlags:0 timestamp:0.0
      windowNumber:0 context:nil eventNumber:2 trackingNumber:1 userData:nil];
    if (!mouseMoved || !keyDown || !flagsChanged || !scrollWheel ||
        !mouseEntered || !mouseExited) return false;
    NimculusInputCallback previousInputCallback = g_input_callback;
    g_validation_scroll_seen = NO;
    memset(&g_validation_scroll_event, 0, sizeof(g_validation_scroll_event));
    g_input_callback = validationScrollInputCallback;
    uint64_t before = g_input_count;
    logInput(@"validationMouseMoved", mouseMoved);
    logInput(@"validationKeyDown", keyDown);
    logInput(@"validationFlagsChanged", flagsChanged);
    logInput(@"validationScrollWheel", scrollWheel);
    logInput(@"validationMouseEntered", mouseEntered);
    logInput(@"validationMouseExited", mouseExited);
    g_input_callback = previousInputCallback;
    // Keep the trackpad/pixel path on AppKit's canonical scrollingDelta API.
    // This tests the exact value and precision flag forwarded to NimNUI, not
    // merely that a scroll event happened to be logged.
    return g_input_count == before + 6 && g_validation_scroll_seen &&
      fabs(g_validation_scroll_event.delta_x - scrollWheel.scrollingDeltaX) < 0.001 &&
      fabs(g_validation_scroll_event.delta_y - scrollWheel.scrollingDeltaY) < 0.001 &&
      g_validation_scroll_event.precise_scrolling == scrollWheel.hasPreciseScrollingDeltas;
  }
}

bool nimculus_platform_validate_glyph_atlas(void) {
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  if (!device) return false;
  if (g_metrics.scale_factor <= 0.0) g_metrics.scale_factor = 2.0;
  if (g_editor_rect[2] <= 0.0) g_editor_rect[2] = 640.0;
  if (g_editor_rect[3] <= 0.0) g_editor_rect[3] = 320.0;
  NSString *sample = @"A日本語";
  updateEditorGlyphAtlas(device, sample);
  if (!g_glyph_atlas_texture || g_glyph_vertex_count == 0) return false;
  uint64_t hitsBefore = g_glyph_atlas_hit_count;
  updateEditorGlyphAtlas(device, sample);
  return g_glyph_vertex_count > 0 && g_glyph_atlas_hit_count > hitsBefore;
}

bool nimculus_platform_validate_glyph_atlas_eviction(void) {
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  if (!device || !ensureGlyphValidationPipeline(device)) return false;
  if (g_metrics.scale_factor <= 0.0) g_metrics.scale_factor = 2.0;
  if (g_editor_rect[2] <= 0.0) g_editor_rect[2] = 640.0;
  if (g_editor_rect[3] <= 0.0) g_editor_rect[3] = 320.0;
  updateEditorGlyphAtlas(device, @"A日本語");
  // Put the shelf at its limit so the next uncached glyph takes the same
  // eviction path as a full atlas without allocating thousands of glyphs.
  g_glyph_atlas_next_x = 2048;
  g_glyph_atlas_next_y = 0;
  g_glyph_atlas_row_height = 2048;
  uint64_t evictionsBefore = g_glyph_atlas_eviction_count;
  updateEditorGlyphAtlas(device, @"Ω日本語");
  return g_glyph_atlas_eviction_count > evictionsBefore &&
    g_glyph_atlas_entries.count > 0 && g_glyph_vertex_count > 0 &&
    g_glyph_rendering_available && !g_glyph_atlas_rebuild_in_progress;
}

bool nimculus_platform_validate_retina_text_scaling(void) {
  NimculusPlatformMetrics previousMetrics = g_metrics;
  NSString *previousText = g_editor_text;
  NSUInteger previousScrollLine = g_editor_scroll_line;
  CGFloat previousRect[4] = {g_editor_rect[0], g_editor_rect[1],
    g_editor_rect[2], g_editor_rect[3]};
  BOOL valid = NO;
  @autoreleasepool {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (device && ensureGlyphValidationPipeline(device)) {
      g_editor_text = @"A日本語🙂";
      rebuildEditorLineIndex();
      g_editor_scroll_line = 0;
      g_editor_rect[0] = 0.0;
      g_editor_rect[1] = 0.0;
      g_editor_rect[2] = 320.0;
      g_editor_rect[3] = 180.0;

      // Prior atlas-eviction validation intentionally fills the current
      // atlas. Start this scale-transition test with a fresh atlas instead
      // of making its result depend on test order.
      g_glyph_atlas_scale = -1.0;

      g_metrics.scale_factor = 1.0;
      updateEditorTextTexture(device, g_editor_text, YES);
      NSUInteger oneXWidth = g_text_texture.width;
      NSUInteger oneXHeight = g_text_texture.height;
      BOOL oneXValid = oneXWidth == 320 && oneXHeight == 180 &&
        fabs(g_glyph_atlas_scale - 1.0) < 0.001 &&
        g_glyph_atlas_entries.count > 0 && g_glyph_vertex_count > 0;

      g_metrics.scale_factor = 2.0;
      updateEditorTextTexture(device, g_editor_text, YES);
      BOOL twoXValid = g_text_texture.width == oneXWidth * 2 &&
        g_text_texture.height == oneXHeight * 2 &&
        fabs(g_glyph_atlas_scale - 2.0) < 0.001 &&
        g_glyph_atlas_entries.count > 0 && g_glyph_vertex_count > 0;
      uint64_t hitsBefore = g_glyph_atlas_hit_count;
      updateEditorTextTexture(device, g_editor_text, YES);
      BOOL twoXReused = g_glyph_atlas_hit_count > hitsBefore;

      g_metrics.scale_factor = 1.0;
      updateEditorTextTexture(device, g_editor_text, YES);
      BOOL oneXRestored = g_text_texture.width == oneXWidth &&
        g_text_texture.height == oneXHeight &&
        fabs(g_glyph_atlas_scale - 1.0) < 0.001 &&
        g_glyph_atlas_entries.count > 0 && g_glyph_vertex_count > 0;
      valid = oneXValid && twoXValid && twoXReused && oneXRestored;
    }
    g_editor_text = previousText;
    rebuildEditorLineIndex();
    g_editor_scroll_line = previousScrollLine;
    g_editor_rect[0] = previousRect[0];
    g_editor_rect[1] = previousRect[1];
    g_editor_rect[2] = previousRect[2];
    g_editor_rect[3] = previousRect[3];
  }
  g_metrics = previousMetrics;
  return valid;
}

bool nimculus_platform_validate_color_emoji_fallback(void) {
  @autoreleasepool {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) return false;
    // Match the visible-text validation setup. These C ABI tests can run
    // before an NSView exists, so establish the same stable viewport state
    // that the production renderer obtains from the active Metal view.
    if (g_metrics.scale_factor <= 0.0) g_metrics.scale_factor = 2.0;
    if (g_editor_rect[2] <= 0.0) g_editor_rect[2] = 640.0;
    if (g_editor_rect[3] <= 0.0) g_editor_rect[3] = 320.0;
    g_editor_scroll_line = 0;
    if (!ensureGlyphValidationPipeline(device)) return false;
    // Ordinary glyphs and color emoji must coexist: the former remains in the
    // R8 atlas while the latter is supplied by the RGBA Core Text texture.
    updateEditorTextTexture(device, @"A🙂 1️⃣", YES);
    return g_text_texture != nil && g_glyph_rendering_available &&
      g_glyph_vertex_count > 0;
  }
}

bool nimculus_platform_validate_color_emoji_sequences(void) {
  // This contract does not require a drawable. It verifies the Core Text
  // classification boundary for a ZWJ sequence and a keycap, while ensuring
  // ordinary text is not routed through the color path.
  return textContainsColorEmoji(@"👩‍💻") &&
    textContainsColorEmoji(@"1️⃣") &&
    !textContainsColorEmoji(@"Nimculus 日本語");
}

bool nimculus_platform_validate_visible_text_assets(void) {
  @autoreleasepool {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) return false;
    if (g_metrics.scale_factor <= 0.0) g_metrics.scale_factor = 2.0;
    if (g_editor_rect[2] <= 0.0) g_editor_rect[2] = 640.0;
    if (g_editor_rect[3] <= 0.0) g_editor_rect[3] = 320.0;

    // Exercise the two text asset paths with the same document: ordinary
    // glyphs use the monochrome atlas, while the emoji remains in the RGBA
    // Core Text texture fallback.
    NSString *mixed = @"A日本語・記号👩‍💻🙂 1️⃣\nnext";
    updateEditorTextTexture(device, mixed, YES);
    BOOL atlasValid = g_glyph_atlas_texture != nil && g_glyph_vertex_count > 0;
    BOOL textureValid = g_text_texture != nil && g_text_texture.width > 0 &&
      g_text_texture.height > 0;
    return atlasValid && textureValid;
  }
}

void nimculus_platform_get_metrics(NimculusPlatformMetrics *metrics) {
  if (metrics) *metrics = g_metrics;
}

static int compareLatencySamples(const void *left, const void *right) {
  const double a = *(const double *)left;
  const double b = *(const double *)right;
  return (a > b) - (a < b);
}

static int compareEventCounts(const void *left, const void *right) {
  const uint64_t a = *(const uint64_t *)left;
  const uint64_t b = *(const uint64_t *)right;
  return (a > b) - (a < b);
}

void nimculus_platform_get_input_latency_stats(NimculusInputLatencyStats *stats) {
  if (!stats) return;
  memset(stats, 0, sizeof(*stats));
  stats->sample_count = g_input_latency_sample_count;
  stats->input_event_count = g_input_latency_event_count;
  uint64_t recent = MIN(g_input_latency_sample_count, (uint64_t)NIMCULUS_INPUT_LATENCY_HISTORY);
  stats->recent_sample_count = recent;
  if (recent == 0) return;

  double ordered[NIMCULUS_INPUT_LATENCY_HISTORY];
  uint64_t orderedEventCounts[NIMCULUS_INPUT_LATENCY_HISTORY];
  uint64_t first = g_input_latency_sample_count - recent;
  double total = 0.0;
  uint64_t eventTotal = 0;
  for (uint64_t index = 0; index < recent; index++) {
    uint64_t historyIndex = (first + index) % NIMCULUS_INPUT_LATENCY_HISTORY;
    double sample = g_input_latency_history[historyIndex];
    ordered[index] = sample;
    uint64_t eventCount = g_input_events_per_frame_history[historyIndex];
    orderedEventCounts[index] = eventCount;
    total += sample;
    eventTotal += eventCount;
  }
  qsort(ordered, (size_t)recent, sizeof(double), compareLatencySamples);
  qsort(orderedEventCounts, (size_t)recent, sizeof(uint64_t), compareEventCounts);
  stats->average_ms = total / (double)recent;
  stats->max_ms = ordered[recent - 1];
  uint64_t p95 = (uint64_t)ceil((double)recent * 0.95);
  stats->p95_ms = ordered[MAX((uint64_t)1, p95) - 1];
  stats->average_events_per_frame = (double)eventTotal / (double)recent;
  stats->p95_events_per_frame = orderedEventCounts[MAX((uint64_t)1, p95) - 1];
  stats->max_events_per_frame = orderedEventCounts[recent - 1];
}

uint32_t nimculus_platform_input_latency_stats_size(void) {
  return (uint32_t)sizeof(NimculusInputLatencyStats);
}

void nimculus_platform_get_frame_timing_stats(NimculusFrameTimingStats *stats) {
  if (!stats) return;
  memset(stats, 0, sizeof(*stats));
  stats->sample_count = g_frame_timing_sample_count;
  uint64_t recent = MIN(g_frame_timing_sample_count, (uint64_t)NIMCULUS_FRAME_TIMING_HISTORY);
  stats->recent_sample_count = recent;
  if (recent == 0) return;

  double ordered[NIMCULUS_FRAME_TIMING_HISTORY];
  uint64_t first = g_frame_timing_sample_count - recent;
  double total = 0.0;
  for (uint64_t index = 0; index < recent; index++) {
    double sample = g_frame_timing_history[(first + index) % NIMCULUS_FRAME_TIMING_HISTORY];
    ordered[index] = sample;
    total += sample;
    if (sample > 16.667) stats->over_60hz_budget_count++;
    if (sample > 33.333) stats->over_30hz_budget_count++;
  }
  qsort(ordered, (size_t)recent, sizeof(double), compareLatencySamples);
  stats->average_ms = total / (double)recent;
  stats->max_ms = ordered[recent - 1];
  uint64_t p95 = (uint64_t)ceil((double)recent * 0.95);
  stats->p95_ms = ordered[MAX((uint64_t)1, p95) - 1];
}

uint32_t nimculus_platform_frame_timing_stats_size(void) {
  return (uint32_t)sizeof(NimculusFrameTimingStats);
}

bool nimculus_platform_validate_frame_timing_tracking(void) {
  double previousHistory[NIMCULUS_FRAME_TIMING_HISTORY];
  memcpy(previousHistory, g_frame_timing_history, sizeof(previousHistory));
  uint64_t previousSamples = g_frame_timing_sample_count;

  memset(g_frame_timing_history, 0, sizeof(g_frame_timing_history));
  g_frame_timing_sample_count = 0;
  recordFrameTimingSample(2.0);
  recordFrameTimingSample(8.0);
  recordFrameTimingSample(20.0);
  NimculusFrameTimingStats stats;
  nimculus_platform_get_frame_timing_stats(&stats);
  bool valid = stats.sample_count == 3 && stats.recent_sample_count == 3 &&
    stats.over_60hz_budget_count == 1 && stats.over_30hz_budget_count == 0 &&
    fabs(stats.average_ms - 10.0) < 0.001 && fabs(stats.p95_ms - 20.0) < 0.001 &&
    fabs(stats.max_ms - 20.0) < 0.001;

  memcpy(g_frame_timing_history, previousHistory, sizeof(g_frame_timing_history));
  g_frame_timing_sample_count = previousSamples;
  return valid;
}

bool nimculus_platform_validate_input_latency_tracking(void) {
  double previousHistory[NIMCULUS_INPUT_LATENCY_HISTORY];
  uint64_t previousEventHistory[NIMCULUS_INPUT_LATENCY_HISTORY];
  memcpy(previousHistory, g_input_latency_history, sizeof(previousHistory));
  memcpy(previousEventHistory, g_input_events_per_frame_history, sizeof(previousEventHistory));
  uint64_t previousSamples = g_input_latency_sample_count;
  uint64_t previousEvents = g_input_latency_event_count;
  uint64_t previousPendingEvents = g_pending_input_event_count;

  memset(g_input_latency_history, 0, sizeof(g_input_latency_history));
  memset(g_input_events_per_frame_history, 0, sizeof(g_input_events_per_frame_history));
  g_input_latency_sample_count = 0;
  g_input_latency_event_count = 6;
  g_pending_input_event_count = 0;
  recordInputLatencySample(2.0, 1);
  recordInputLatencySample(8.0, 3);
  recordInputLatencySample(20.0, 2);
  NimculusInputLatencyStats stats;
  nimculus_platform_get_input_latency_stats(&stats);
  bool valid = stats.sample_count == 3 && stats.recent_sample_count == 3 &&
    stats.input_event_count == 6 && fabs(stats.average_ms - 10.0) < 0.001 &&
    fabs(stats.p95_ms - 20.0) < 0.001 && fabs(stats.max_ms - 20.0) < 0.001 &&
    fabs(stats.average_events_per_frame - 2.0) < 0.001 &&
    stats.p95_events_per_frame == 3 && stats.max_events_per_frame == 3;

  memcpy(g_input_latency_history, previousHistory, sizeof(g_input_latency_history));
  memcpy(g_input_events_per_frame_history, previousEventHistory,
    sizeof(g_input_events_per_frame_history));
  g_input_latency_sample_count = previousSamples;
  g_input_latency_event_count = previousEvents;
  g_pending_input_event_count = previousPendingEvents;
  return valid;
}

uint64_t nimculus_platform_resident_memory_bytes(void) {
  mach_task_basic_info_data_t info;
  mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
  kern_return_t result = task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
    (task_info_t)&info, &count);
  return result == KERN_SUCCESS ? (uint64_t)info.resident_size : 0;
}

uint64_t nimculus_platform_live_allocation_count(void) {
  malloc_statistics_t stats;
  memset(&stats, 0, sizeof(stats));
  malloc_zone_statistics(malloc_default_zone(), &stats);
  return (uint64_t)stats.blocks_in_use;
}

uint64_t nimculus_platform_input_count(void) { return g_input_count; }

uint32_t nimculus_platform_metrics_size(void) {
  return (uint32_t)sizeof(NimculusPlatformMetrics);
}

uint32_t nimculus_platform_input_event_size(void) {
  return (uint32_t)sizeof(NimculusInputEvent);
}

uint32_t nimculus_platform_terminal_run_size(void) {
  return (uint32_t)sizeof(NimculusTerminalRun);
}

uint32_t nimculus_platform_highlight_span_size(void) {
  return (uint32_t)sizeof(NimculusHighlightSpan);
}

uint32_t nimculus_platform_diagnostic_span_size(void) {
  return (uint32_t)sizeof(NimculusDiagnosticSpan);
}

uint32_t nimculus_platform_editor_annotation_size(void) {
  return (uint32_t)sizeof(NimculusEditorAnnotation);
}

uint32_t nimculus_platform_git_hunk_span_size(void) {
  return (uint32_t)sizeof(NimculusGitHunkSpan);
}

uint32_t nimculus_platform_paint_command_size(void) {
  return (uint32_t)sizeof(NimculusPaintCommand);
}

uint32_t nimculus_platform_paint_region_size(void) {
  return (uint32_t)sizeof(NimculusPaintRegion);
}
void nimculus_platform_set_input_callback(NimculusInputCallback callback) { g_input_callback = callback; }
void nimculus_platform_set_shortcut_callback(NimculusShortcutCallback callback) { g_shortcut_callback = callback; }
void nimculus_platform_set_text_callback(NimculusTextCallback callback) { g_text_callback = callback; }
void nimculus_platform_set_selection_callback(NimculusSelectionCallback callback) { g_selection_callback = callback; }
void nimculus_platform_set_file_callback(NimculusFileCallback callback) {
  g_file_callback = callback;
  flushPendingFileOpenPaths();
}
void nimculus_platform_show_workspace_entry_context(const char *path, bool is_directory) {
  if (!path || path[0] == '\0') return;
  replaceOwnedString(&g_workspace_context_path, [NSString stringWithUTF8String:path]);
  g_workspace_context_is_directory = is_directory ? YES : NO;
  NimculusAppDelegate *delegate = (NimculusAppDelegate *)[NSApp delegate];
  if (!delegate) return;
  NSMenu *menu = [[[NSMenu alloc] initWithTitle:@"Workspace Entry"] autorelease];
  if (!g_workspace_context_is_directory) {
    [menu addItemWithTitle:@"Open" action:@selector(dispatchOpenWorkspaceContextEntry:) keyEquivalent:@""];
  }
  [menu addItemWithTitle:@"Reveal in Finder" action:@selector(revealWorkspaceContextEntry:) keyEquivalent:@""];
  [menu addItem:[NSMenuItem separatorItem]];
  [menu addItemWithTitle:@"New File…" action:@selector(createWorkspaceFileAtContext:) keyEquivalent:@""];
  [menu addItemWithTitle:@"New Folder…" action:@selector(createWorkspaceDirectoryAtContext:) keyEquivalent:@""];
  [menu addItem:[NSMenuItem separatorItem]];
  [menu addItemWithTitle:@"Rename…" action:@selector(renameWorkspaceContextEntry:) keyEquivalent:@""];
  NSMenuItem *delete = [menu addItemWithTitle:@"Delete…" action:@selector(deleteWorkspaceContextEntry:) keyEquivalent:@""];
  delete.keyEquivalentModifierMask = 0;
  for (NSMenuItem *item in menu.itemArray) item.target = delegate;
  [menu popUpMenuPositioningItem:nil atLocation:[NSEvent mouseLocation] inView:nil];
}
void nimculus_platform_show_git_status_context(uint32_t item_index, bool can_stage,
                                               bool can_unstage) {
  NimculusAppDelegate *delegate = (NimculusAppDelegate *)[NSApp delegate];
  if (!delegate) return;
  NSMenu *menu = [[[NSMenu alloc] initWithTitle:@"Git Change"] autorelease];
  NSArray<NSArray<NSString *> *> *items = @[
    @[@"Open", @"open"], @[@"Stage", @"stage"], @[@"Unstage", @"unstage"]
  ];
  for (NSArray<NSString *> *entry in items) {
    NSString *action = entry[1];
    if (([action isEqualToString:@"stage"] && !can_stage) ||
        ([action isEqualToString:@"unstage"] && !can_unstage)) continue;
    NSMenuItem *item = [menu addItemWithTitle:entry[0]
      action:@selector(dispatchGitStatusContext:) keyEquivalent:@""];
    item.target = delegate;
    item.representedObject = [NSString stringWithFormat:@"gitStatusContext:%@:%u",
      action, item_index];
  }
  [menu popUpMenuPositioningItem:nil atLocation:[NSEvent mouseLocation] inView:nil];
}
void nimculus_platform_show_git_history_context(uint32_t item_index) {
  NimculusAppDelegate *delegate = (NimculusAppDelegate *)[NSApp delegate];
  if (!delegate) return;
  NSMenu *menu = [[[NSMenu alloc] initWithTitle:@"Git Commit"] autorelease];
  NSArray<NSArray<NSString *> *> *items = @[
    @[@"Open Commit", @"open"], @[@"Copy Commit SHA", @"copy"]
  ];
  for (NSArray<NSString *> *entry in items) {
    NSMenuItem *item = [menu addItemWithTitle:entry[0]
      action:@selector(dispatchGitHistoryContext:) keyEquivalent:@""];
    item.target = delegate;
    item.representedObject = [NSString stringWithFormat:@"gitHistoryContext:%@:%u",
      entry[1], item_index];
  }
  [menu popUpMenuPositioningItem:nil atLocation:[NSEvent mouseLocation] inView:nil];
}
void nimculus_platform_show_git_commit_sheet(void) {
  NimculusAppDelegate *delegate = (NimculusAppDelegate *)[NSApp delegate];
  if (delegate) [delegate presentGitCommitSheet];
}
void nimculus_platform_set_command_callback(NimculusCommandCallback callback) { g_command_callback = callback; }
void nimculus_platform_set_idle_callback(NimculusIdleCallback callback) { g_idle_callback = callback; }
void nimculus_platform_set_editor_cursor(double x, double y) {
  g_editor_cursor[0] = x;
  g_editor_cursor[1] = y;
  if (g_queue) { updateEditorTextTexture(g_queue.device, g_editor_text, NO); rebuildSecondaryEditorTexture(g_queue.device); }
  markSceneFullyDirty();
}
void nimculus_platform_set_editor_cursor_byte(uint32_t byte_offset, uint32_t line) {
  NSArray<NSString *> *lines = editorLinesForText(g_editor_text);
  if (lines.count == 0) return;
  NSUInteger lineIndex = MIN((NSUInteger)line, lines.count - 1);
  NSUInteger lineStartByte = editorLineUTF8Offset(lineIndex, lines);
  NSString *lineText = lines[lineIndex];
  NSUInteger lineLength = [[lineText dataUsingEncoding:NSUTF8StringEncoding] length];
  NSUInteger localByte = byte_offset > lineStartByte ? byte_offset - lineStartByte : 0;
  localByte = MIN(localByte, lineLength);
  NSUInteger utf16 = utf16OffsetForUTF8Bytes(lineText, localByte);
  NSUInteger documentOffset = editorLineUTF16Offset(lineIndex, lines);
  CGPoint point = editorPointForUTF16Offset(documentOffset + utf16);
  g_editor_cursor[0] = point.x;
  g_editor_cursor[1] = point.y;
  if (g_queue) updateEditorTextTexture(g_queue.device, g_editor_text, NO);
  markSceneFullyDirty();
}
void nimculus_platform_set_editor_font_size(double size) {
  g_editor_font_size = MIN(96.0, MAX(6.0, size > 0.0 ? size : 14.0));
  g_editor_line_height = MAX(12.0, ceil(g_editor_font_size * 1.2857142857));
  if (g_queue) { updateEditorTextTexture(g_queue.device, g_editor_text, YES); rebuildSecondaryEditorTexture(g_queue.device); }
  markSceneFullyDirty();
  if (g_active_view) {
    for (NSView *subview in ((NimculusMetalView *)g_active_view).subviews) {
      if ([subview isKindOfClass:[NimculusLineNumberOverlay class]]) [subview setNeedsDisplay:YES];
    }
  }
  if (g_active_view) [(NimculusMetalView *)g_active_view drawFrame];
}
void nimculus_platform_set_editor_font_name(const char *name) {
  NSString *requested = name ? [NSString stringWithUTF8String:name] : nil;
  replaceOwnedString(&g_editor_font_name, requested.length > 0 ? requested : @"Menlo");
  if (g_queue) { updateEditorTextTexture(g_queue.device, g_editor_text, YES); rebuildSecondaryEditorTexture(g_queue.device); }
  markSceneFullyDirty();
  if (g_active_view) {
    for (NSView *subview in ((NimculusMetalView *)g_active_view).subviews) {
      if ([subview isKindOfClass:[NimculusLineNumberOverlay class]]) [subview setNeedsDisplay:YES];
    }
  }
  if (g_active_view) [(NimculusMetalView *)g_active_view drawFrame];
}
double nimculus_platform_editor_line_height(void) { return editorLineHeight(); }
void nimculus_platform_invalidate_ime_coordinates(void) {
  // Zed invalidates NSTextInputContext's cached character coordinates whenever
  // the editor cursor moves. Without this, AppKit can keep placing the IME
  // candidate window at the previous cursor position after navigation or
  // scrolling.
  NSTextInputContext *inputContext = [NSTextInputContext currentInputContext];
  if (inputContext) [inputContext invalidateCharacterCoordinates];
}
uint32_t nimculus_platform_editor_utf16_offset_at_point(double x, double y) {
  if (g_editor_soft_wrap) return (uint32_t)editorUTF16OffsetAtPoint(x, y);
  NSArray<NSString *> *lines = editorLinesForText(g_editor_text);
  if (lines.count == 0) return 0;
  CGFloat viewHeight = g_metrics.height_points > 0 ? g_metrics.height_points : 640.0;
  CGFloat fromTop = viewHeight - y - g_editor_rect[1];
  NSInteger lineIndex = MAX(0, (NSInteger)floor((fromTop - 4.0) / editorLineHeight()));
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
  NSUInteger documentIndex = editorLineUTF16Offset((NSUInteger)lineIndex, lines);
  documentIndex += MIN((NSUInteger)localIndex, lineText.length);
  CFRelease(ctLine);
  [attributed release];
  CFRelease(font);
  return (uint32_t)documentIndex;
}
uint32_t nimculus_platform_editor_byte_offset_at_point(double x, double y) {
  if (g_editor_soft_wrap) {
    NSUInteger utf16 = editorUTF16OffsetAtPoint(x, y);
    return (uint32_t)utf8BytesForDocumentUTF16Offset(g_editor_text, utf16);
  }
  NSArray<NSString *> *lines = editorLinesForText(g_editor_text);
  if (lines.count == 0) return 0;
  CGFloat viewHeight = g_metrics.height_points > 0 ? g_metrics.height_points : 640.0;
  CGFloat fromTop = viewHeight - y - g_editor_rect[1];
  NSInteger lineIndex = MAX(0, (NSInteger)floor((fromTop - 4.0) / editorLineHeight()));
  lineIndex = MIN(lineIndex + (NSInteger)g_editor_scroll_line, (NSInteger)lines.count - 1);
  NSString *lineText = lines[(NSUInteger)lineIndex];
  NSUInteger lineStartByte = editorLineUTF8Offset((NSUInteger)lineIndex, lines);
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
  [attributed release];
  CFRelease(font);
  return (uint32_t)(lineStartByte + localByte);
}
uint32_t nimculus_platform_secondary_editor_byte_offset_at_point(double x, double y) {
  if (!g_secondary_editor_visible) return 0;
  double previousRect[4] = {g_editor_rect[0], g_editor_rect[1],
    g_editor_rect[2], g_editor_rect[3]};
  NSUInteger previousScrollLine = g_editor_scroll_line;
  BOOL previousSoftWrap = g_editor_soft_wrap;
  swapEditorTextState();
  memcpy(g_editor_rect, g_secondary_editor_rect, sizeof(g_editor_rect));
  g_editor_scroll_line = g_secondary_editor_scroll_line;
  g_editor_soft_wrap = g_secondary_editor_soft_wrap;
  uint32_t result = nimculus_platform_editor_byte_offset_at_point(x, y);
  swapEditorTextState();
  memcpy(g_editor_rect, previousRect, sizeof(g_editor_rect));
  g_editor_scroll_line = previousScrollLine;
  g_editor_soft_wrap = previousSoftWrap;
  return result;
}
void nimculus_platform_set_editor_scroll_line(uint32_t line) {
  g_editor_scroll_line = line;
  if (g_active_view) {
    for (NSView *subview in ((NimculusMetalView *)g_active_view).subviews) {
      if ([subview isKindOfClass:[NimculusLineNumberOverlay class]]) [subview setNeedsDisplay:YES];
    }
  }
  markSceneFullyDirty();
  if (g_queue) { updateEditorTextTexture(g_queue.device, g_editor_text, YES); rebuildSecondaryEditorTexture(g_queue.device); }
  if (g_active_view) [(NimculusMetalView *)g_active_view drawFrame];
}
void nimculus_platform_set_editor_rect(double x, double y, double width, double height) {
  g_editor_rect[0] = MAX(0.0, x);
  g_editor_rect[1] = MAX(0.0, y);
  g_editor_rect[2] = MAX(1.0, width);
  g_editor_rect[3] = MAX(1.0, height);
  if (g_active_view) [(NimculusMetalView *)g_active_view updateTerminalFrame];
  if (g_queue) { updateEditorTextTexture(g_queue.device, g_editor_text, YES); rebuildSecondaryEditorTexture(g_queue.device); }
  markSceneFullyDirty();
  if (g_active_view) [(NimculusMetalView *)g_active_view drawFrame];
}
void nimculus_platform_set_terminal_panel_rect(double x, double y, double width, double height) {
  g_terminal_panel_rect[0] = MAX(0.0, x);
  g_terminal_panel_rect[1] = MAX(0.0, y);
  g_terminal_panel_rect[2] = MAX(0.0, width);
  g_terminal_panel_rect[3] = MAX(0.0, height);
  if (g_active_view) [(NimculusMetalView *)g_active_view updateTerminalFrame];
}
void nimculus_platform_set_secondary_editor_rect(bool visible, double x, double y,
                                                 double width, double height) {
  g_secondary_editor_visible = visible ? YES : NO;
  if (!g_secondary_editor_visible) {
    g_editor_input_pane = 0;
    g_editor_hover_pane = 0;
  }
  g_secondary_editor_rect[0] = MAX(0.0, x);
  g_secondary_editor_rect[1] = MAX(0.0, y);
  g_secondary_editor_rect[2] = MAX(1.0, width);
  g_secondary_editor_rect[3] = MAX(1.0, height);
  if (g_queue) rebuildSecondaryEditorTexture(g_queue.device);
  markSceneFullyDirty();
  if (g_active_view) [(NimculusMetalView *)g_active_view drawFrame];
}
void nimculus_platform_set_secondary_editor_cursor_byte(uint32_t byte_offset, uint32_t line) {
  swapEditorTextState();
  NSArray<NSString *> *lines = editorLinesForText(g_editor_text);
  if (lines.count == 0) { swapEditorTextState(); return; }
  NSUInteger lineIndex = MIN((NSUInteger)line, lines.count - 1);
  NSUInteger lineStartByte = editorLineUTF8Offset(lineIndex, lines);
  NSString *lineText = lines[lineIndex];
  NSUInteger lineLength = [[lineText dataUsingEncoding:NSUTF8StringEncoding] length];
  NSUInteger localByte = byte_offset > lineStartByte ? byte_offset - lineStartByte : 0;
  localByte = MIN(localByte, lineLength);
  NSUInteger utf16 = utf16OffsetForUTF8Bytes(lineText, localByte);
  NSUInteger documentOffset = editorLineUTF16Offset(lineIndex, lines);
  NSUInteger previousScrollLine = g_editor_scroll_line;
  BOOL previousSoftWrap = g_editor_soft_wrap;
  g_editor_scroll_line = g_secondary_editor_scroll_line;
  g_editor_soft_wrap = g_secondary_editor_soft_wrap;
  CGPoint point = editorPointForUTF16Offset(documentOffset + utf16);
  g_editor_scroll_line = previousScrollLine;
  g_editor_soft_wrap = previousSoftWrap;
  g_secondary_editor_cursor[0] = point.x;
  g_secondary_editor_cursor[1] = point.y;
  swapEditorTextState();
  if (g_queue) rebuildSecondaryEditorTexture(g_queue.device);
  markSceneFullyDirty();
  if (g_active_view) [(NimculusMetalView *)g_active_view drawFrame];
}
void nimculus_platform_set_secondary_editor_selection(uint32_t start_byte, uint32_t end_byte) {
  NSUInteger start = utf16OffsetForUTF8Bytes(g_secondary_editor_text ?: @"", start_byte);
  NSUInteger end = utf16OffsetForUTF8Bytes(g_secondary_editor_text ?: @"", end_byte);
  g_secondary_editor_selection_start = MIN(start, end);
  g_secondary_editor_selection_end = MAX(start, end);
  if (g_editor_input_pane == 1 && g_active_view) {
    NimculusMetalView *view = (NimculusMetalView *)g_active_view;
    view.selectedTextRange = NSMakeRange(g_secondary_editor_selection_start,
      g_secondary_editor_selection_end - g_secondary_editor_selection_start);
  }
  if (g_queue) rebuildSecondaryEditorTexture(g_queue.device);
  markSceneFullyDirty();
  if (g_active_view) [(NimculusMetalView *)g_active_view drawFrame];
}
void nimculus_platform_set_secondary_editor_scroll_line(uint32_t line) {
  g_secondary_editor_scroll_line = line;
  if (g_queue) rebuildSecondaryEditorTexture(g_queue.device);
  markSceneFullyDirty();
  if (g_active_view) [(NimculusMetalView *)g_active_view drawFrame];
}
void nimculus_platform_set_secondary_editor_soft_wrap(bool enabled) {
  g_secondary_editor_soft_wrap = enabled ? YES : NO;
  if (g_queue) rebuildSecondaryEditorTexture(g_queue.device);
  markSceneFullyDirty();
  if (g_active_view) [(NimculusMetalView *)g_active_view drawFrame];
}
void nimculus_platform_set_editor_input_pane(uint32_t pane) {
  g_editor_input_pane = pane == 1 && g_secondary_editor_visible ? 1 : 0;
  if (g_active_view) {
    NimculusMetalView *view = (NimculusMetalView *)g_active_view;
    NSUInteger start = g_editor_input_pane == 1 ? g_secondary_editor_selection_start
      : g_editor_selection_start;
    NSUInteger end = g_editor_input_pane == 1 ? g_secondary_editor_selection_end
      : g_editor_selection_end;
    view.selectedTextRange = NSMakeRange(start, end - start);
  }
  NSTextInputContext *inputContext = [NSTextInputContext currentInputContext];
  if (inputContext) [inputContext invalidateCharacterCoordinates];
  if (g_queue) {
    updateEditorTextTexture(g_queue.device, g_editor_text, NO);
    rebuildSecondaryEditorTexture(g_queue.device);
  }
  markSceneFullyDirty();
  if (g_active_view) [(NimculusMetalView *)g_active_view drawFrame];
}
uint32_t nimculus_platform_editor_pane_at_point(double x, double y) {
  if (editorRectContains(g_editor_rect, x, y)) return 0;
  if (g_secondary_editor_visible && editorRectContains(g_secondary_editor_rect, x, y)) return 1;
  return UINT32_MAX;
}
void nimculus_platform_set_editor_dirty(bool dirty) { g_editor_dirty = dirty ? YES : NO; }
void nimculus_platform_set_editor_indent_guides(bool visible, uint32_t indent_width) {
  g_editor_indent_guides = visible ? YES : NO;
  g_editor_indent_width = MAX((NSUInteger)1, (NSUInteger)indent_width);
  NimculusMetalView *view = (NimculusMetalView *)g_active_view;
  if (!view) return;
  for (NSView *subview in view.subviews) {
    if ([subview isKindOfClass:[NimculusIndentGuideOverlay class]]) {
      [subview setNeedsDisplay:YES];
      break;
    }
  }
}
void nimculus_platform_set_editor_line_numbers(bool visible) {
  g_editor_line_numbers = visible ? YES : NO;
  NimculusMetalView *view = (NimculusMetalView *)g_active_view;
  if (!view) return;
  for (NSView *subview in view.subviews) {
    if ([subview isKindOfClass:[NimculusLineNumberOverlay class]]) {
      subview.hidden = !g_editor_line_numbers;
      break;
    }
  }
}
void nimculus_platform_set_editor_soft_wrap(bool enabled) {
  g_editor_soft_wrap = enabled ? YES : NO;
  NimculusMetalView *view = (NimculusMetalView *)g_active_view;
  if (view) {
    for (NSView *subview in view.subviews) {
      if ([subview isKindOfClass:[NimculusLineNumberOverlay class]] ||
          [subview isKindOfClass:[NimculusEditorAnnotationOverlay class]]) {
        [subview setNeedsDisplay:YES];
      }
    }
  }
  markSceneFullyDirty();
  if (g_queue) { updateEditorTextTexture(g_queue.device, g_editor_text, YES); rebuildSecondaryEditorTexture(g_queue.device); }
  if (g_active_view) [(NimculusMetalView *)g_active_view drawFrame];
}
void nimculus_platform_set_editor_tabs(const char *utf8, uint32_t length, uint32_t active_index) {
  NSString *value = (utf8 && length > 0)
    ? [[[NSString alloc] initWithBytes:utf8 length:length encoding:NSUTF8StringEncoding] autorelease] : @"";
  replaceOwnedArray((NSArray **)&g_editor_tab_titles, value.length > 0
    ? [value componentsSeparatedByString:@"\n"] : @[]);
  g_editor_active_tab = g_editor_tab_titles.count == 0 ? 0
    : MIN((NSUInteger)active_index, g_editor_tab_titles.count - 1);
  NimculusMetalView *view = (NimculusMetalView *)g_active_view;
  if (!view) return;
  [view updateTerminalFrame];
  for (NSView *subview in view.subviews) {
    if ([subview isKindOfClass:[NimculusTabBarOverlay class]] &&
        !((NimculusTabBarOverlay *)subview).secondary) {
      [subview setNeedsDisplay:YES];
      break;
    }
  }
}
void nimculus_platform_set_secondary_editor_tabs(const char *utf8, uint32_t length,
                                                 uint32_t active_index) {
  NSString *value = (utf8 && length > 0)
    ? [[[NSString alloc] initWithBytes:utf8 length:length encoding:NSUTF8StringEncoding] autorelease] : @"";
  replaceOwnedArray((NSArray **)&g_secondary_editor_tab_titles, value.length > 0
    ? [value componentsSeparatedByString:@"\n"] : @[]);
  g_secondary_editor_active_tab = g_secondary_editor_tab_titles.count == 0 ? 0
    : MIN((NSUInteger)active_index, g_secondary_editor_tab_titles.count - 1);
  NimculusMetalView *view = (NimculusMetalView *)g_active_view;
  if (!view) return;
  [view updateTerminalFrame];
  for (NSView *subview in view.subviews) {
    if ([subview isKindOfClass:[NimculusTabBarOverlay class]] &&
        ((NimculusTabBarOverlay *)subview).secondary) {
      [subview setNeedsDisplay:YES];
      break;
    }
  }
}
void nimculus_platform_set_editor_status(const char *utf8) {
  replaceOwnedString(&g_editor_status, (utf8 && strlen(utf8) > 0)
    ? [NSString stringWithUTF8String:utf8] : @"Ready");
  NimculusMetalView *view = (NimculusMetalView *)g_active_view;
  if (!view) return;
  for (NSView *subview in view.subviews) {
    if ([subview isKindOfClass:[NimculusStatusOverlay class]]) {
      ((NSTextField *)subview).stringValue = g_editor_status;
      break;
    }
  }
}
void nimculus_platform_set_welcome_visible(bool visible) {
  g_welcome_visible = visible ? YES : NO;
  NimculusMetalView *view = (NimculusMetalView *)g_active_view;
  if (view) [view updateTerminalFrame];
}
void nimculus_platform_set_close_decision(bool allow) { g_close_decision = allow ? YES : NO; }
static void showSavePanelWithSuggestedName(const char *suggestedName) {
  NSSavePanel *panel = [NSSavePanel savePanel];
  if (suggestedName && suggestedName[0] != '\0') {
    panel.nameFieldStringValue = [NSString stringWithUTF8String:suggestedName];
  }
  NimculusMetalView *view = (NimculusMetalView *)g_active_view;
  NSWindow *window = view.window;
  void (^complete)(NSModalResponse) = ^(NSModalResponse response) {
    if (response == NSModalResponseOK) {
      if (g_file_callback) g_file_callback(panel.URL.path.UTF8String, true);
    } else if (g_command_callback) {
      // A pending Save All and Quit sequence must be able to abandon its
      // asynchronous queue when this ordinary Save Panel is cancelled.
      g_command_callback("savePanelCancelled");
    }
  };
  if (window) [panel beginSheetModalForWindow:window completionHandler:complete];
  else [panel beginWithCompletionHandler:complete];
}
void nimculus_platform_show_save_panel(void) { showSavePanelWithSuggestedName(NULL); }
void nimculus_platform_show_save_as_panel(const char *suggested_name) {
  showSavePanelWithSuggestedName(suggested_name);
}
static void requestCloseTabWithUnsaved(BOOL unsaved) {
  if (!unsaved) {
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
  NimculusMetalView *view = (NimculusMetalView *)g_active_view;
  NSWindow *window = view.window;
  void (^complete)(NSModalResponse) = ^(NSModalResponse response) {
    if (response == NSAlertSecondButtonReturn) {
      if (g_command_callback) g_command_callback("closeTabConfirmed");
    } else if (response == NSAlertFirstButtonReturn && g_command_callback) {
      // saveAndCloseTab may open its own asynchronous Save Panel. Its
      // completion emits closeTabConfirmed only after the write succeeds.
      g_command_callback("saveAndCloseTab");
    } else if (g_command_callback) {
      g_command_callback("closeTabCancelled");
    }
  };
  if (window) [alert beginSheetModalForWindow:window completionHandler:complete];
  else [alert beginWithCompletionHandler:complete];
  [alert release];
}
void nimculus_platform_request_close_tab(void) {
  requestCloseTabWithUnsaved(g_editor_dirty);
}
void nimculus_platform_request_close_tab_with_unsaved(bool unsaved) {
  requestCloseTabWithUnsaved(unsaved ? YES : NO);
}
void nimculus_platform_show_save_panel_and_close_tab(void) {
  g_close_decision = NO;
  NSSavePanel *panel = [NSSavePanel savePanel];
  NimculusMetalView *view = (NimculusMetalView *)g_active_view;
  NSWindow *window = view.window;
  void (^complete)(NSModalResponse) = ^(NSModalResponse response) {
    if (response != NSModalResponseOK || !g_file_callback) {
      if (g_command_callback) g_command_callback("closeTabCancelled");
      return;
    }
    g_file_callback(panel.URL.path.UTF8String, true);
    // receiveNativeFile synchronously writes the document and sets this only
    // on success. With an asynchronous panel this must happen after the
    // completion handler, not in the original confirmation action.
    if (g_close_decision && g_command_callback) g_command_callback("closeTabConfirmed");
  };
  if (window) [panel beginSheetModalForWindow:window completionHandler:complete];
  else [panel beginWithCompletionHandler:complete];
}
void nimculus_platform_confirm_quit(void);
void nimculus_platform_request_quit(void) {
  // Automated lifecycle probes and a normal quit with no dirty documents do
  // not need an unsaved-changes sheet. Zed's application-level quit path
  // likewise only enters confirmation when there is state to protect.
  if (!g_editor_dirty) {
    nimculus_platform_confirm_quit();
    return;
  }
  g_close_decision = NO;
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = @"Unsaved Changes";
  alert.informativeText = @"One or more tabs have unsaved changes.";
  [alert addButtonWithTitle:@"Save All"];
  [alert addButtonWithTitle:@"Don’t Save"];
  [alert addButtonWithTitle:@"Cancel"];
  NimculusMetalView *view = (NimculusMetalView *)g_active_view;
  NSWindow *window = view.window;
  void (^complete)(NSModalResponse) = ^(NSModalResponse response) {
    if (response == NSAlertSecondButtonReturn) {
      if (g_command_callback) g_command_callback("discardAllAndQuit");
    } else if (response == NSAlertFirstButtonReturn && g_command_callback) {
      // Save All may continue through several asynchronous Save Panels. The
      // final panel completion confirms termination after every write.
      g_command_callback("saveAllAndQuit");
    }
    if (g_close_decision) nimculus_platform_confirm_quit();
  };
  if (window) [alert beginSheetModalForWindow:window completionHandler:complete];
  else [alert beginWithCompletionHandler:complete];
  [alert release];
}
void nimculus_platform_confirm_quit(void) {
  g_terminate_decision = YES;
  [NSApp terminate:nil];
}
void nimculus_platform_show_save_panel_and_close(void) {
  g_close_decision = NO;
  NSSavePanel *panel = [NSSavePanel savePanel];
  NimculusMetalView *view = (NimculusMetalView *)g_active_view;
  NSWindow *window = view.window;
  void (^complete)(NSModalResponse) = ^(NSModalResponse response) {
    if (response != NSModalResponseOK || !g_file_callback) return;
    g_file_callback(panel.URL.path.UTF8String, true);
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
  };
  if (window) [panel beginSheetModalForWindow:window completionHandler:complete];
  else [panel beginWithCompletionHandler:complete];
}
void nimculus_platform_set_editor_selection(uint32_t start_byte, uint32_t end_byte) {
  NSUInteger start = utf16OffsetForUTF8Bytes(g_editor_text ?: @"", start_byte);
  NSUInteger end = utf16OffsetForUTF8Bytes(g_editor_text ?: @"", end_byte);
  g_editor_selection_start = MIN(start, end);
  g_editor_selection_end = MAX(start, end);
  if (g_editor_input_pane == 0 && g_active_view) {
    NimculusMetalView *view = (NimculusMetalView *)g_active_view;
    view.selectedTextRange = NSMakeRange(g_editor_selection_start,
      g_editor_selection_end - g_editor_selection_start);
  }
  if (g_queue) updateEditorTextTexture(g_queue.device, g_editor_text, NO);
  markSceneFullyDirty();
  if (g_active_view) [(NimculusMetalView *)g_active_view drawFrame];
}
void nimculus_platform_set_editor_text(const char *utf8, uint32_t length) {
  replaceOwnedUTF8String(&g_editor_text, utf8, length, @"");
  rebuildEditorLineIndex();
  if (g_active_view) {
    for (NSView *subview in ((NimculusMetalView *)g_active_view).subviews) {
      if ([subview isKindOfClass:[NimculusLineNumberOverlay class]]) [subview setNeedsDisplay:YES];
    }
  }
  markSceneFullyDirty();
  if (g_queue) { updateEditorTextTexture(g_queue.device, g_editor_text, YES); rebuildSecondaryEditorTexture(g_queue.device); }
  if (g_active_view) [g_active_view drawFrame];
}
void nimculus_platform_set_secondary_editor_text(const char *utf8, uint32_t length) {
  replaceOwnedUTF8String(&g_secondary_editor_text, utf8, length, @"");
  rebuildSecondaryEditorLineIndex();
  if (g_queue) rebuildSecondaryEditorTexture(g_queue.device);
  markSceneFullyDirty();
  if (g_active_view) [g_active_view drawFrame];
}
void nimculus_platform_set_editor_outline(const char *utf8, uint32_t length,
                                          uint32_t symbol_count) {
  g_editor_sidebar_mode = 0;
  replaceOwnedUTF8String(&g_editor_outline_text, utf8, length,
    @"Outline\n────────\nNo symbols");
  g_editor_outline_symbol_count = symbol_count;
  NimculusMetalView *view = (NimculusMetalView *)g_active_view;
  if (!view) return;
  NimculusOutlineOverlay *outline = outlineOverlayForView(view);
  if (outline) applySidebarPresentation(outline);
  [view updateTerminalFrame];
}
void nimculus_platform_set_editor_sidebar(const char *utf8, uint32_t length,
                                          uint32_t item_count, uint32_t mode) {
  g_editor_sidebar_mode = mode;
  replaceOwnedUTF8String(&g_editor_outline_text, utf8, length,
    @"Project\n────────\nNo items");
  g_editor_outline_symbol_count = item_count;
  NimculusMetalView *view = (NimculusMetalView *)g_active_view;
  if (!view) return;
  NimculusOutlineOverlay *outline = outlineOverlayForView(view);
  if (outline) {
    applySidebarPresentation(outline);
    nimculus_platform_set_editor_sidebar_selection(
      g_editor_sidebar_selected_index == NSNotFound ? UINT32_MAX :
      (uint32_t)g_editor_sidebar_selected_index);
  }
  [view updateTerminalFrame];
}
void nimculus_platform_set_editor_sidebar_selection(uint32_t item_index) {
  g_editor_sidebar_selected_index = item_index == UINT32_MAX ? NSNotFound : item_index;
  NimculusMetalView *view = (NimculusMetalView *)g_active_view;
  if (!view) return;
  NimculusOutlineOverlay *outline = outlineOverlayForView(view);
  if (!outline) return;
  if (g_editor_sidebar_selected_index == NSNotFound ||
      g_editor_sidebar_selected_index >= g_editor_outline_symbol_count) {
    [outline setSelectedRange:NSMakeRange(0, 0)];
    return;
  }
  NSUInteger line = g_editor_sidebar_selected_index + 2;
  NSUInteger start = 0;
  for (NSUInteger current = 0; current < line && start < outline.string.length; current++) {
    NSRange newline = [outline.string rangeOfString:@"\n" options:0
      range:NSMakeRange(start, outline.string.length - start)];
    if (newline.location == NSNotFound) { start = outline.string.length; break; }
    start = NSMaxRange(newline);
  }
  NSUInteger end = start;
  while (end < outline.string.length && [outline.string characterAtIndex:end] != '\n') end++;
  if (start >= outline.string.length) {
    [outline setSelectedRange:NSMakeRange(0, 0)];
    return;
  }
  NSRange range = NSMakeRange(start, end - start);
  [outline setSelectedRange:range];
  [outline scrollRangeToVisible:range];
}
void nimculus_platform_set_editor_sidebar_visible(bool visible) {
  g_editor_sidebar_visible = visible ? YES : NO;
  NimculusMetalView *view = (NimculusMetalView *)g_active_view;
  if (!view) return;
  NimculusOutlineOverlay *outline = outlineOverlayForView(view);
  if (outline.enclosingScrollView) outline.enclosingScrollView.hidden = !g_editor_sidebar_visible;
  [view updateTerminalFrame];
  [view drawFrame];
}
void nimculus_platform_set_workspace_open(bool open) {
  g_workspace_open = open ? YES : NO;
  NimculusMetalView *view = (NimculusMetalView *)g_active_view;
  if (!view) return;
  for (NSView *subview in view.subviews) {
    if ([subview isKindOfClass:[NimculusFilesSidebarActions class]]) {
      [(NimculusFilesSidebarActions *)subview reloadActions];
      break;
    }
  }
  [view updateTerminalFrame];
}
void nimculus_platform_open_workspace_folder(void) {
  NimculusAppDelegate *delegate = (NimculusAppDelegate *)[NSApp delegate];
  if (delegate) [delegate openWorkspaceFolder:nil];
}
void nimculus_platform_set_terminal_visible(bool visible) {
  g_terminal_visible = visible ? YES : NO;
  if (g_active_view) {
    [(NimculusMetalView *)g_active_view updateTerminalFrame];
    [g_active_view drawFrame];
  }
}
void nimculus_platform_set_terminal_sessions(const char *utf8, uint32_t length,
                                             uint32_t active_index) {
  NSString *raw = (utf8 && length > 0) ? [[[NSString alloc] initWithBytes:utf8 length:length
    encoding:NSUTF8StringEncoding] autorelease] : @"";
  NSArray<NSString *> *titles = raw.length > 0 ? [raw componentsSeparatedByString:@"\n"] : @[];
  replaceOwnedArray(&g_terminal_session_titles, titles);
  g_terminal_active_session = g_terminal_session_titles.count > 0 ?
    MIN((NSUInteger)active_index, g_terminal_session_titles.count - 1) : 0;
  NimculusMetalView *view = (NimculusMetalView *)g_active_view;
  if (!view) return;
  for (NSView *subview in view.subviews) {
    if ([subview isKindOfClass:[NimculusTerminalSessionBar class]]) {
      [(NimculusTerminalSessionBar *)subview reloadSessions];
      break;
    }
  }
  [view updateTerminalFrame];
}
void nimculus_platform_set_terminal_text(const char *utf8, uint32_t length) {
  replaceOwnedUTF8String(&g_terminal_text, utf8, length, @"");
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
  replaceOwnedUTF8String(&g_terminal_text, utf8, length, @"");
  free(g_terminal_runs);
  g_terminal_runs = NULL;
  g_terminal_run_count = 0;
  replaceOwnedMutableArray((NSMutableArray **)&g_terminal_hyperlinks,
    [NSMutableArray arrayWithCapacity:count]);
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
                                        const char *accent, const char *selection,
                                        const char *border) {
  if (background) replaceOwnedString(&g_theme_background, [NSString stringWithUTF8String:background] ?: @"#1f2329");
  if (foreground) replaceOwnedString(&g_theme_foreground, [NSString stringWithUTF8String:foreground] ?: @"#d7dae0");
  if (accent) replaceOwnedString(&g_theme_accent, [NSString stringWithUTF8String:accent] ?: @"#4daafc");
  if (selection) replaceOwnedString(&g_theme_selection, [NSString stringWithUTF8String:selection] ?: @"#264f78");
  if (border) replaceOwnedString(&g_theme_border, [NSString stringWithUTF8String:border] ?: @"#3b4048");
  NimculusMetalView *view = (NimculusMetalView *)g_active_view;
  if (!view) return;
  for (NSView *subview in view.subviews) {
    if ([subview isKindOfClass:[NimculusTerminalOverlay class]]) {
      NSTextView *terminal = (NSTextView *)subview;
      terminal.backgroundColor = [themeHexColor(g_theme_background,
        [NSColor colorWithCalibratedRed:0.025 green:0.030 blue:0.045 alpha:1.0]) colorWithAlphaComponent:0.98];
      terminal.textColor = themeHexColor(g_theme_foreground,
        [NSColor colorWithCalibratedRed:0.82 green:0.88 blue:0.92 alpha:1.0]);
      terminal.selectedTextAttributes = @{
        NSBackgroundColorAttributeName: [themeHexColor(g_theme_selection,
          [NSColor colorWithCalibratedRed:0.20 green:0.40 blue:0.75 alpha:1.0])
          colorWithAlphaComponent:0.65]
      };
    }
  }
  NimculusOutlineOverlay *outline = outlineOverlayForView(view);
  if (outline) {
    outline.backgroundColor = [themeHexColor(g_theme_background,
      [NSColor colorWithCalibratedRed:0.045 green:0.055 blue:0.075 alpha:1.0])
      colorWithAlphaComponent:0.96];
    outline.textColor = themeHexColor(g_theme_foreground,
      [NSColor colorWithCalibratedRed:0.82 green:0.88 blue:0.92 alpha:1.0]);
  }
  [view drawFrame];
}
static void updateTerminalFonts(void) {
  NimculusMetalView *view = (NimculusMetalView *)g_active_view;
  if (!view) return;
  NSFont *font = terminalBaseFont();
  for (NSView *subview in view.subviews) {
    if ([subview isKindOfClass:[NimculusTerminalOverlay class]]) {
      NSTextView *terminal = (NSTextView *)subview;
      terminal.font = font;
      if (g_terminal_run_count > 0) applyTerminalRuns(terminal);
    } else if ([subview isKindOfClass:[NimculusTaskOutputOverlay class]]) {
      ((NSTextView *)subview).font = font;
    }
  }
  NimculusOutlineOverlay *outline = outlineOverlayForView(view);
  if (outline) {
    outline.font = [NSFont fontWithName:g_editor_font_name size:g_editor_font_size] ?:
      [NSFont monospacedSystemFontOfSize:g_editor_font_size weight:NSFontWeightRegular];
  }
}
void nimculus_platform_set_terminal_font_size(double size) {
  g_terminal_font_size = MIN(48.0, MAX(6.0, size > 0.0 ? size : 12.0));
  updateTerminalFonts();
}
void nimculus_platform_set_terminal_font_name(const char *name) {
  NSString *requested = name ? [NSString stringWithUTF8String:name] : nil;
  replaceOwnedString(&g_terminal_font_name, requested.length > 0 ? requested : @"Menlo");
  updateTerminalFonts();
}
double nimculus_platform_terminal_cell_width(void) {
  return terminalCellWidth();
}
double nimculus_platform_terminal_line_height(void) {
  return terminalLineHeight();
}
double nimculus_platform_terminal_inset_x(void) {
  return 8.0;
}
double nimculus_platform_terminal_inset_y(void) {
  return 6.0;
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

bool nimculus_platform_is_dark_appearance(void) {
  NSApplication *app = [NSApplication sharedApplication];
  NSAppearance *appearance = app.effectiveAppearance;
  NSString *match = [appearance bestMatchFromAppearancesWithNames:@[
    NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
  return [match isEqualToString:NSAppearanceNameDarkAqua];
}

void nimculus_platform_install_crash_handler(const char *path) {
  replaceOwnedString(&g_crash_report_path, path ? [NSString stringWithUTF8String:path] : @"");
  NSSetUncaughtExceptionHandler(nimculus_uncaught_exception_handler);
}
void nimculus_platform_set_task_output_visible(bool visible) {
  g_task_output_visible = visible ? YES : NO;
  if (g_active_view) {
    [(NimculusMetalView *)g_active_view updateTerminalFrame];
    [g_active_view drawFrame];
  }
}
void nimculus_platform_set_task_output_title(const char *utf8, uint32_t length) {
  replaceOwnedUTF8String(&g_task_output_title, utf8, length, @"Task Output");
  NimculusMetalView *view = (NimculusMetalView *)g_active_view;
  if (!view) return;
  for (NSView *subview in view.subviews) {
    if ([subview isKindOfClass:[NimculusOutputPanelBar class]]) {
      [(NimculusOutputPanelBar *)subview reloadTitle];
      break;
    }
  }
  [view updateTerminalFrame];
}
void nimculus_platform_set_task_output_text(const char *utf8, uint32_t length) {
  replaceOwnedUTF8String(&g_task_output_text, utf8, length, @"");
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
  replaceOwnedUTF8String(&g_editor_completions, utf8, length, @"");
  markSceneFullyDirty();
  if (g_queue) {
    updateEditorTextTexture(g_queue.device, g_editor_text, NO);
    rebuildSecondaryEditorTexture(g_queue.device);
  }
  if (g_active_view) [g_active_view drawFrame];
}
void nimculus_platform_set_editor_hover(const char *utf8, uint32_t length) {
  replaceOwnedUTF8String(&g_editor_hover, utf8, length, @"");
  markSceneFullyDirty();
  if (g_queue) {
    updateEditorTextTexture(g_queue.device, g_editor_text, NO);
    rebuildSecondaryEditorTexture(g_queue.device);
  }
  if (g_active_view) [g_active_view drawFrame];
}
void nimculus_platform_set_editor_hover_position(double x, double y) {
  g_editor_hover_position[0] = x;
  g_editor_hover_position[1] = y;
  markSceneFullyDirty();
  if (g_queue) {
    updateEditorTextTexture(g_queue.device, g_editor_text, NO);
    rebuildSecondaryEditorTexture(g_queue.device);
  }
  if (g_active_view) [g_active_view drawFrame];
}
void nimculus_platform_set_editor_hover_pane(uint32_t pane) {
  g_editor_hover_pane = pane == 1 && g_secondary_editor_visible ? 1 : 0;
  markSceneFullyDirty();
  if (g_queue) {
    updateEditorTextTexture(g_queue.device, g_editor_text, NO);
    rebuildSecondaryEditorTexture(g_queue.device);
  }
  if (g_active_view) [g_active_view drawFrame];
}
uint32_t nimculus_platform_editor_text_utf8_length(void) {
  NSData *data = [g_editor_text dataUsingEncoding:NSUTF8StringEncoding];
  return data ? (uint32_t)data.length : 0;
}
void nimculus_platform_set_editor_composition(const char *utf8) {
  replaceOwnedString(&g_marked_text, utf8 ? [NSString stringWithUTF8String:utf8] : @"");
  if (g_marked_text.length == 0 && g_active_view) {
    // Empty composition updates are also used by command/menu paths to end
    // composition. Keep the NSTextInputClient state in lockstep instead of
    // leaving a stale marked range behind.
    NimculusMetalView *view = (NimculusMetalView *)g_active_view;
    view.markedText = @"";
    view.markedTextRange = NSMakeRange(NSNotFound, 0);
  }
  markSceneFullyDirty();
  if (g_queue) {
    if (g_editor_input_pane == 1) rebuildSecondaryEditorTexture(g_queue.device);
    else updateEditorTextTexture(g_queue.device, g_editor_text, NO);
  }
  if (g_active_view) [g_active_view drawFrame];
}
void nimculus_platform_clear_editor_composition(void) {
  replaceOwnedString(&g_marked_text, @"");
  if (g_active_view) {
    NimculusMetalView *view = (NimculusMetalView *)g_active_view;
    view.markedText = @"";
    view.markedTextRange = NSMakeRange(NSNotFound, 0);
  }
  markSceneFullyDirty();
  if (g_queue) {
    if (g_editor_input_pane == 1) rebuildSecondaryEditorTexture(g_queue.device);
    else updateEditorTextTexture(g_queue.device, g_editor_text, NO);
  }
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
void nimculus_platform_set_editor_annotations(const NimculusEditorAnnotation *annotations,
                                              uint32_t count) {
  free(g_editor_annotations);
  g_editor_annotations = NULL;
  g_editor_annotation_count = 0;
  replaceOwnedMutableArray((NSMutableArray **)&g_editor_annotation_texts,
    [NSMutableArray arrayWithCapacity:count]);
  if (annotations && count > 0) {
    g_editor_annotations = calloc(count, sizeof(NimculusEditorAnnotation));
    if (g_editor_annotations) {
      for (uint32_t index = 0; index < count; index++) {
        g_editor_annotations[index].line = annotations[index].line;
        g_editor_annotations[index].character = annotations[index].character;
        g_editor_annotations[index].kind = annotations[index].kind;
        const char *text = annotations[index].text;
        [g_editor_annotation_texts addObject:text ?
          ([NSString stringWithUTF8String:text] ?: @"") : @""];
      }
      g_editor_annotation_count = count;
    }
  }
  if (g_active_view) [(NimculusMetalView *)g_active_view updateTerminalFrame];
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
  replaceOwnedArray((NSArray **)&g_recent_files, files);
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
  if (!g_image_textures || !g_queue || image_id == 0) return;
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
  [texture release];
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
static NSString *clipboardTextFromPasteboard(NSPasteboard *pasteboard) {
  if (!pasteboard) return nil;
  // Zed writes the UTF-8 payload as NSPasteboardTypeString data instead of
  // relying on setString's implicit conversion. Reading the data first keeps
  // embedded NULs and non-ASCII text length-preserving; stringForType remains
  // a compatibility fallback for other macOS applications.
  NSData *data = [pasteboard dataForType:NSPasteboardTypeString];
  NSString *text = data ? [[[NSString alloc] initWithData:data
                                                 encoding:NSUTF8StringEncoding] autorelease] : nil;
  return text ?: [pasteboard stringForType:NSPasteboardTypeString];
}

void nimculus_clipboard_set(const char *utf8, uint32_t length) {
  NSData *data = (utf8 && length > 0) ?
    [NSData dataWithBytes:utf8 length:length] : [NSData data];
  NSString *text = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
  replaceOwnedString(&g_clipboard_text, text ?: @"");
  replaceOwnedData(&g_clipboard_utf8_data,
    [g_clipboard_text dataUsingEncoding:NSUTF8StringEncoding]);
  NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
  [pasteboard clearContents];
  [pasteboard setData:g_clipboard_utf8_data ?: [NSData data]
              forType:NSPasteboardTypeString];
}
uint32_t nimculus_clipboard_utf8_length(void) {
  NSString *text = clipboardTextFromPasteboard([NSPasteboard generalPasteboard]);
  replaceOwnedString(&g_clipboard_text, text ?: @"");
  replaceOwnedData(&g_clipboard_utf8_data,
    [g_clipboard_text dataUsingEncoding:NSUTF8StringEncoding]);
  return (uint32_t)g_clipboard_utf8_data.length;
}
const uint8_t *nimculus_clipboard_utf8_bytes(void) {
  return (const uint8_t *)g_clipboard_utf8_data.bytes;
}

bool nimculus_platform_validate_clipboard_roundtrip(void) {
  @autoreleasepool {
    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    NSString *previous = clipboardTextFromPasteboard(pasteboard);
    NSString *sample = @"Nimculus clipboard 日本語 🙂";
    nimculus_clipboard_set(sample.UTF8String, (uint32_t)strlen(sample.UTF8String));
    NSString *roundtrip = clipboardTextFromPasteboard(pasteboard);
    BOOL valid = [roundtrip isEqualToString:sample];
    [pasteboard clearContents];
    if (previous) [pasteboard setString:previous forType:NSPasteboardTypeString];
    return valid;
  }
}

// macOS panels must be presented through the AppDelegate's completion-handler
// based sheet APIs. The historical synchronous ABI remains only so a stale
// third-party caller links successfully; Nimculus itself never calls it.
// Returning an empty selection makes an accidental use fail safely instead of
// entering a nested AppKit run loop that pauses Metal presentation.
const char *nimculus_choose_open_file(void) { g_dialog_path[0] = '\0'; return g_dialog_path; }
const char *nimculus_choose_save_file(void) { g_dialog_path[0] = '\0'; return g_dialog_path; }
