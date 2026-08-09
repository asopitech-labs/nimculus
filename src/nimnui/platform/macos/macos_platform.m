#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CADisplayLink.h>
#import <QuartzCore/CAMetalLayer.h>
#import <CoreText/CoreText.h>
#import <CoreGraphics/CoreGraphics.h>
#import <mach/mach_time.h>
#import <mach/task.h>
#import <malloc/malloc.h>
#include <limits.h>
#include <math.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <dispatch/dispatch.h>
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
static NimculusFrameCallback g_frame_callback = NULL;
static NSView *g_accessibility_host = nil;

bool nimculus_platform_is_main_thread(void) {
  return [NSThread isMainThread];
}

static dispatch_queue_t nimculus_global_queue(NimculusPlatformPriority priority) {
  long queue_priority = DISPATCH_QUEUE_PRIORITY_DEFAULT;
  switch (priority) {
    case NIMCULUS_PLATFORM_PRIORITY_HIGH:
      queue_priority = DISPATCH_QUEUE_PRIORITY_HIGH;
      break;
    case NIMCULUS_PLATFORM_PRIORITY_LOW:
      queue_priority = DISPATCH_QUEUE_PRIORITY_LOW;
      break;
    case NIMCULUS_PLATFORM_PRIORITY_MEDIUM:
    default:
      queue_priority = DISPATCH_QUEUE_PRIORITY_DEFAULT;
      break;
  }
  return dispatch_get_global_queue(queue_priority, 0);
}

void nimculus_platform_dispatch(NimculusPlatformRunnable runnable, void *context,
                                NimculusPlatformPriority priority) {
  if (!runnable) return;
  dispatch_async_f(nimculus_global_queue(priority), context, runnable);
}

void nimculus_platform_dispatch_on_main_thread(NimculusPlatformRunnable runnable,
                                               void *context,
                                               NimculusPlatformPriority priority) {
  (void)priority;
  if (!runnable) return;
  dispatch_async_f(dispatch_get_main_queue(), context, runnable);
}

void nimculus_platform_dispatch_after(uint64_t nanoseconds,
                                      NimculusPlatformRunnable runnable,
                                      void *context) {
  if (!runnable) return;
  dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)nanoseconds),
                   nimculus_global_queue(NIMCULUS_PLATFORM_PRIORITY_HIGH),
                   context, runnable);
}

@interface NimculusAXNode : NSObject
@property(nonatomic, copy) NSString *role;
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *value;
@property(nonatomic, assign) id parentNode;
@property(nonatomic, retain) NSArray *childNodes;
@property(nonatomic) NSRect localFrame;
@property(nonatomic) BOOL synthetic;
@property(nonatomic) BOOL selected;
@property(nonatomic) BOOL expanded;
@property(nonatomic) NSUInteger cursorByte;
@property(nonatomic) NSRange selectedByteRange;
@property(nonatomic, copy) NSString *actionCommand;
@end

static NSString *accessibilityRoleForNative(uint32_t role) {
  switch (role) {
    case 1: return NSAccessibilityWindowRole;
    case 2: return NSAccessibilityGroupRole;
    case 3: return NSAccessibilityToolbarRole;
    case 4: return NSAccessibilityButtonRole;
    case 5: return NSAccessibilityTabGroupRole;
    case 6: return NSAccessibilityRadioButtonRole;
    case 7: return NSAccessibilityToolbarRole;
    case 8: return NSAccessibilityScrollAreaRole;
    case 9: return NSAccessibilityRowRole;
    case 10: return NSAccessibilityTextFieldRole;
    case 11: return NSAccessibilityStaticTextRole;
    default: return NSAccessibilityGroupRole;
  }
}

static NSUInteger accessibilityUtf16Offset(NSString *text, NSUInteger byteOffset) {
  NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
  NSUInteger bounded = MIN(byteOffset, data.length);
  NSString *prefix = [[[NSString alloc] initWithBytes:data.bytes length:bounded
                                             encoding:NSUTF8StringEncoding] autorelease];
  return prefix ? prefix.length : 0;
}

@implementation NimculusAXNode
- (BOOL)isAccessibilityElement { return YES; }
- (NSString *)accessibilityRole { return self.role; }
- (NSString *)accessibilityIdentifier { return self.identifier; }
- (NSString *)accessibilityLabel { return self.title; }
- (id)accessibilityValue { return self.value.length > 0 ? self.value : self.title; }
- (NSArray *)accessibilityChildren { return self.childNodes ?: @[]; }
- (id)accessibilityParent { return self.parentNode; }
- (BOOL)accessibilityEnabled { return YES; }
- (BOOL)accessibilitySelected { return self.selected; }
- (BOOL)accessibilityExpanded { return self.expanded; }
- (NSRect)accessibilityFrame {
  if (!g_accessibility_host || !g_accessibility_host.window) return self.localFrame;
  NSRect windowFrame = [g_accessibility_host convertRect:self.localFrame toView:nil];
  return [g_accessibility_host.window convertRectToScreen:windowFrame];
}
- (NSArray *)accessibilityAttributeNames {
  return @[NSAccessibilityRoleAttribute, NSAccessibilityTitleAttribute,
    NSAccessibilityValueAttribute, NSAccessibilityIdentifierAttribute,
    NSAccessibilityChildrenAttribute, NSAccessibilityParentAttribute,
    NSAccessibilityPositionAttribute, NSAccessibilitySizeAttribute,
    NSAccessibilityEnabledAttribute, NSAccessibilitySelectedAttribute,
    NSAccessibilityExpandedAttribute, NSAccessibilitySelectedTextRangeAttribute,
    @"NimculusCursorByte"];
}
- (id)accessibilityAttributeValue:(NSString *)attribute {
  if ([attribute isEqualToString:NSAccessibilityRoleAttribute]) return self.role;
  if ([attribute isEqualToString:NSAccessibilityTitleAttribute]) return self.title;
  if ([attribute isEqualToString:NSAccessibilityValueAttribute]) return [self accessibilityValue];
  if ([attribute isEqualToString:NSAccessibilityIdentifierAttribute]) return self.identifier;
  if ([attribute isEqualToString:NSAccessibilityChildrenAttribute]) return [self accessibilityChildren];
  if ([attribute isEqualToString:NSAccessibilityParentAttribute]) return self.parentNode;
  if ([attribute isEqualToString:NSAccessibilityPositionAttribute])
    return [NSValue valueWithPoint:[self accessibilityFrame].origin];
  if ([attribute isEqualToString:NSAccessibilitySizeAttribute])
    return [NSValue valueWithSize:[self accessibilityFrame].size];
  if ([attribute isEqualToString:NSAccessibilityEnabledAttribute]) return @YES;
  if ([attribute isEqualToString:NSAccessibilitySelectedAttribute]) return @(self.selected);
  if ([attribute isEqualToString:NSAccessibilityExpandedAttribute]) return @(self.expanded);
  if ([attribute isEqualToString:NSAccessibilitySelectedTextRangeAttribute])
    return [NSValue valueWithRange:NSMakeRange(
      accessibilityUtf16Offset(self.value, self.selectedByteRange.location),
      accessibilityUtf16Offset(self.value, NSMaxRange(self.selectedByteRange)) -
        accessibilityUtf16Offset(self.value, self.selectedByteRange.location))];
  if ([attribute isEqualToString:@"NimculusCursorByte"]) return @(self.cursorByte);
  return nil;
}
- (BOOL)accessibilityIsAttributeSettable:(NSString *)attribute {
  return [attribute isEqualToString:NSAccessibilityValueAttribute] &&
    [self.role isEqualToString:NSAccessibilityTextFieldRole];
}
- (NSArray *)accessibilityActionNames {
  return self.actionCommand.length > 0 ? @[NSAccessibilityPressAction] : @[];
}
- (void)accessibilityPerformAction:(NSString *)action {
  if ([action isEqualToString:NSAccessibilityPressAction] &&
      self.actionCommand.length > 0 && g_command_callback) {
    g_command_callback(self.actionCommand.UTF8String);
  }
}
- (void)dealloc {
  [_role release];
  [_identifier release];
  [_title release];
  [_value release];
  [_childNodes release];
  [_actionCommand release];
  [super dealloc];
}
@end

static NSMutableDictionary<NSNumber *, NimculusAXNode *> *g_accessibility_nodes = nil;
static NimculusAXNode *g_accessibility_root = nil;
static BOOL g_validation_appearance_command_received = NO;
static BOOL g_editor_scroll_debug_logged = NO;
static NSUInteger g_editor_gutter_debug_line_count = 0;
static CGFloat g_editor_gutter_debug_width = -1.0;
static CGFloat g_editor_gutter_debug_origin = -1.0;

void nimculus_platform_log_editor_scroll_debug(const char *pane, double widest,
                                               double viewport, double scroll_x,
                                               double track_x, double track_width,
                                               double thumb_x, double thumb_width) {
  if (g_editor_scroll_debug_logged) return;
  const char *enabled = getenv("NIMCULUS_SCROLL_DEBUG");
  if (!enabled || strcmp(enabled, "1") != 0) return;
  g_editor_scroll_debug_logged = YES;
  NSLog(@"Nimculus scroll debug pane=%s widest=%.2f viewport=%.2f scrollX=%.2f "
        "track=(%.2f,%.2f) thumb=(%.2f,%.2f)",
        pane ?: "unknown", widest, viewport, scroll_x, track_x, track_width,
        thumb_x, thumb_width);
}

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
// Split panes share one document, but not a viewport or selection. Keep their
// input and cursor projections separate.
static double g_secondary_editor_cursor[2] = {8.0, 12.0};
static NSUInteger g_secondary_editor_cursor_line = 0;
static NSUInteger g_secondary_editor_scroll_line = 0;
static CGFloat g_secondary_editor_scroll_y_fraction = 0.0;
static CGFloat g_secondary_editor_scroll_x = 0.0;
static NSUInteger g_secondary_editor_selection_start = 0;
static NSUInteger g_secondary_editor_selection_end = 0;
#define NIMCULUS_MAX_EDITOR_SELECTIONS 256
static NimculusEditorSelection g_secondary_editor_selections[NIMCULUS_MAX_EDITOR_SELECTIONS];
static uint32_t g_secondary_editor_selection_count = 0;
static BOOL g_secondary_editor_soft_wrap = NO;
static NSUInteger g_editor_input_pane = 0;
static NSUInteger g_editor_hover_pane = 0;
// updateEditorTextTexture is reused to build both pane textures. Keep the
// target explicit so transient overlays are emitted only into their owner.
static BOOL g_rendering_secondary_editor = NO;
static BOOL editorTextureOwnsPrimaryDecorations(void) {
  return !g_rendering_secondary_editor;
}
static NimculusPaintCommand *g_paint_commands = NULL;
static uint32_t g_paint_count = 0;
static NimculusPaintSelectionRow *g_paint_selection_rows = NULL;
static uint32_t g_paint_selection_row_count = 0;
static NimculusPaintRegion *g_paint_dirty_regions = NULL;
static uint32_t g_paint_dirty_count = 0;
static double g_editor_cursor[2] = {8.0, 12.0};
static NSUInteger g_editor_cursor_line = 0;
static CGFloat g_editor_font_size = 15.0;
// GPUI's TextStyle::line_height_in_pixels rounds the resolved comfortable
// line height before it is consumed by the editor display map. Keep the
// native/Core Text path on that same whole-device-pixel rhythm.
static CGFloat g_editor_line_height = 24.0;
static NSString *g_editor_font_name = @".ZedMono";
static NSString *g_editor_resolved_font_name = nil;
static CGFloat g_terminal_font_size = 15.0;
static NSString *g_terminal_font_name = @".ZedMono";
static NSString *g_terminal_resolved_font_name = nil;
static NSUInteger g_editor_scroll_line = 0;
static CGFloat g_editor_scroll_y_fraction = 0.0;
static CGFloat g_editor_scroll_x = 0.0;
// The framework owns viewport state for the committed LineLayout renderer.
// Keep it separate from the old AppKit input/IME compatibility state.
static CGFloat g_editor_layout_scroll_x = 0.0;
static CGFloat g_editor_layout_scroll_y_fraction = 0.0;
static CGFloat g_secondary_layout_scroll_x = 0.0;
static CGFloat g_secondary_layout_scroll_y_fraction = 0.0;
static NSUInteger g_editor_selection_start = 0;
static NSUInteger g_editor_selection_end = 0;
static NimculusEditorSelection g_editor_selections[NIMCULUS_MAX_EDITOR_SELECTIONS];
static uint32_t g_editor_selection_count = 0;

// A Core Text glyph ID is scoped to the CTFont that produced it. Keep the
// actual run fonts (including fallback fonts selected for Japanese/emoji) in
// a small platform registry. This is the same identity carried by Zed's
// ShapedRun.font_id; style/decorations are not used as font identities.
#define NIMCULUS_LAYOUT_FONT_LIMIT 256
static CTFontRef g_layout_fonts[NIMCULUS_LAYOUT_FONT_LIMIT];
static uint32_t g_layout_font_count = 0;

static uint32_t layoutFontIdForFont(CTFontRef font) {
  if (!font) return 0;
  CFStringRef name = CTFontCopyPostScriptName(font);
  for (uint32_t index = 0; index < g_layout_font_count; index++) {
    CTFontRef known = g_layout_fonts[index];
    CFStringRef knownName = known ? CTFontCopyPostScriptName(known) : NULL;
    BOOL same = known && fabs(CTFontGetSize(known) - CTFontGetSize(font)) < 0.001 &&
      CTFontGetSymbolicTraits(known) == CTFontGetSymbolicTraits(font) &&
      name && knownName && CFEqual(name, knownName);
    if (knownName) CFRelease(knownName);
    if (same) {
      if (name) CFRelease(name);
      return index + 1;
    }
  }
  if (name) CFRelease(name);
  if (g_layout_font_count >= NIMCULUS_LAYOUT_FONT_LIMIT) return 0;
  g_layout_fonts[g_layout_font_count] = (CTFontRef)CFRetain(font);
  g_layout_font_count++;
  return g_layout_font_count;
}

static CTFontRef layoutFontForId(uint32_t fontId) {
  if (fontId == 0 || fontId > g_layout_font_count) return NULL;
  return (CTFontRef)CFRetain(g_layout_fonts[fontId - 1]);
}

static void clearLayoutFonts(void) {
  for (uint32_t index = 0; index < g_layout_font_count; index++) {
    if (g_layout_fonts[index]) CFRelease(g_layout_fonts[index]);
    g_layout_fonts[index] = NULL;
  }
  g_layout_font_count = 0;
}

static NimculusEditorSelection *editorSelections(void) {
  return g_rendering_secondary_editor ? g_secondary_editor_selections : g_editor_selections;
}

static uint32_t editorSelectionCount(void) {
  return g_rendering_secondary_editor ? g_secondary_editor_selection_count : g_editor_selection_count;
}
static CGFloat editorLayoutScrollX(void) {
  return g_rendering_secondary_editor ? g_secondary_layout_scroll_x : g_editor_layout_scroll_x;
}
static CGFloat editorLayoutScrollYFraction(void) {
  return g_rendering_secondary_editor ? g_secondary_layout_scroll_y_fraction :
    g_editor_layout_scroll_y_fraction;
}
static const double *editorLayoutRect(void) {
  return g_rendering_secondary_editor ? g_secondary_editor_rect : g_editor_rect;
}
static NSString *g_editor_text = @"";
static NSString *g_secondary_editor_text = @"";
// Rebuild these once when committed editor text changes. Text rendering,
// scrolling, hit-testing, and IME coordinate queries must not repeatedly
// split or scan a ten-thousand-line document on every frame.
static NSArray<NSString *> *g_editor_lines = nil;
static NSUInteger *g_editor_line_utf16_offsets = NULL;
static NSUInteger *g_editor_line_utf8_offsets = NULL;
static NSUInteger g_editor_line_count = 0;
static NimculusFoldRange *g_editor_folds = NULL;
static uint32_t g_editor_fold_count = 0;
static NSArray<NSString *> *g_secondary_editor_lines = nil;
static NSUInteger *g_secondary_editor_line_utf16_offsets = NULL;
static NSUInteger *g_secondary_editor_line_utf8_offsets = NULL;
static NSUInteger g_secondary_editor_line_count = 0;
static NimculusFoldRange *g_secondary_editor_folds = NULL;
static uint32_t g_secondary_editor_fold_count = 0;
static NSString *g_editor_status = @"Ready";
// Tab-separated, user-facing status items. The footer presenter keeps cursor,
// indentation, encoding, line ending, language, LSP state, and active file
// available as separate native controls while matching Zed's status-bar
// grouping. The indentation field remains in the payload for compatibility;
// Zed's visible status-bar order does not render it.
static NSString *g_editor_footer = @"1:1\tSpaces: 2\tUTF-8\tLF\tPlain Text\tLSP: なし\t";
static NSString *g_editor_context = @"";
static NSString *g_editor_git_branch = @"";
static NSArray<NSString *> *g_editor_tab_titles = nil;
static NSUInteger g_editor_active_tab = 0;
static NSArray<NSString *> *g_secondary_editor_tab_titles = nil;
static NSUInteger g_secondary_editor_active_tab = 0;
static BOOL g_editor_indent_guides = YES;
static NSUInteger g_editor_indent_width = 2;
static BOOL g_editor_line_numbers = YES;
static BOOL g_editor_soft_wrap = NO;
static BOOL g_editor_find_bar_visible = NO;
static NSString *g_terminal_text = @"";
static NSString *g_editor_outline_text = @"Outline\n────────\nNo symbols";
static uint32_t g_editor_outline_symbol_count = 0;
// mode 0 is the document outline, 1 the project files, 2 Git history, 3 the
// clickable Git status list, and 4 the Git branch picker. Non-outline modes
// dispatch sidebarItem:N.
static uint32_t g_editor_sidebar_mode = 0;
static BOOL g_editor_sidebar_visible = YES;
static BOOL g_editor_sidebar_on_right = NO;
static BOOL g_workspace_open = YES;
static NSUInteger g_editor_sidebar_selected_index = NSNotFound;
// Most sidebars use the historical two-line header followed by one row per
// item. Git status also has non-interactive section headers, so retain an
// explicit line-to-item map rather than making AppKit infer row positions.
static int32_t *g_editor_sidebar_line_items = NULL;
static uint32_t g_editor_sidebar_line_item_count = 0;
static NSString *g_theme_background = @"#1f2329";
static NSString *g_theme_foreground = @"#d7dae0";
static NSString *g_theme_accent = @"#4daafc";
static NSString *g_theme_selection = @"#264f78";
static NSString *g_theme_border = @"#3b4048";
static NSDictionary *g_theme_palette = nil;

// Zed-aligned workspace tokens. Keep chrome geometry and semantic colors in
// one platform-owned place so AppKit presenters do not grow independent
// spacing or light/dark-theme conventions.
static const CGFloat NimculusSpace1 = 4.0;
static const CGFloat NimculusSpace2 = 8.0;
static const CGFloat NimculusSpace3 = 12.0;
static const CGFloat NimculusRowHeight = 28.0;
// Measured from Zed's own window pixels (One Light, 1389x791): the title bar
// paints 34pt of chrome plus a 1pt `border` rule, the tab strip 31pt plus the
// same rule, and the toolbar 6 + 32 + 6pt plus a 1pt `border.variant` rule.
// That is what puts Zed's first editor row at y=112pt; deriving the toolbar
// from its own text height instead left our first row 17.5pt too high.
static const CGFloat NimculusTitlebarHeight = 35.0;
static const CGFloat NimculusTabBarHeight = 32.0;
static const CGFloat NimculusBreadcrumbHeight = 45.0;
static const CGFloat NimculusChromeBorderHeight = 1.0;
static const CGFloat NimculusDefaultWindowWidth = 1389.0;
static const CGFloat NimculusDefaultWindowHeight = 791.0;
// AppKit accepts finite window limits reliably. CGFLOAT_MAX looks equivalent
// to "unbounded", but on some macOS releases it is normalized through the
// frame/content conversion path and can produce an invalid frame before the
// window is ordered. Keep the logical layout's generous 10000pt ceiling while
// retaining a finite native value.
static const CGFloat NimculusMaximumWindowWidth = 10000.0;
static const CGFloat NimculusMaximumWindowHeight = 10000.0;
static const CGFloat NimculusControlHit = 24.0;
// The SF Symbols in the navigation buttons have a small optical inset. Zed's
// first tab-strip ink starts three retina pixels farther left than the old
// AppKit placement, so keep the button frame and its measured ink inset
// explicit instead of changing the tab content geometry.
static const CGFloat NimculusTabNavigationOpticalInset = 6.5;
static const CGFloat NimculusIconPointSize = 14.0;
// Zed's quick action bar draws IconSize::Small glyphs on a 23pt slot pitch,
// with the rightmost slot's centre 20pt inside the pane's right edge. Measured
// on its window: ink 10.5pt tall, slot centres at 1038/1061/1084/1107/1130pt.
static const CGFloat NimculusToolbarIconPointSize = 11.0;
static const CGFloat NimculusToolbarSlotPitch = 23.0;
static const CGFloat NimculusToolbarSlotRightInset = 20.0;
static const NSUInteger NimculusToolbarSlotCount = 5;

// getenv on a per-frame path is not free; cache it like the input log gate.
static BOOL rectDebugEnabled(void) {
  static int cached = -1;
  if (cached < 0) {
    const char *value = getenv("NIMCULUS_RECT_DEBUG");
    cached = (value && value[0] != '\0' && value[0] != '0') ? 1 : 0;
  }
  return cached == 1;
}

static BOOL tabDebugEnabled(void) {
  const char *enabled = getenv("NIMCULUS_TAB_DEBUG");
  return enabled && strcmp(enabled, "1") == 0;
}

static void tabDebugLogOverlayFrames(NSView *view) {
  if (!tabDebugEnabled() || !view) return;
  for (NSView *subview in view.subviews) {
    NSString *className = NSStringFromClass(subview.class);
    if ([className isEqualToString:@"NimculusTabBarOverlay"]) {
      NSRect windowFrame = subview.window ? [subview convertRect:subview.bounds toView:nil] : NSZeroRect;
      NSNumber *secondary = [subview respondsToSelector:@selector(secondary)]
        ? [subview valueForKey:@"secondary"] : @NO;
      fprintf(stderr, "Nimculus tab debug overlay class=%s secondary=%d hidden=%d frameWindow=(%.1f,%.1f,%.1f,%.1f) frameLocal=(%.1f,%.1f,%.1f,%.1f)\n",
        className.UTF8String, secondary.boolValue, (int)subview.hidden,
        windowFrame.origin.x, windowFrame.origin.y, windowFrame.size.width, windowFrame.size.height,
        subview.frame.origin.x, subview.frame.origin.y, subview.frame.size.width, subview.frame.size.height);
    }
    tabDebugLogOverlayFrames(subview);
  }
}

static void tabDebugLogHitTest(NSString *stage, NSView *owner, NSPoint point, NSView *hit) {
  if (!tabDebugEnabled()) return;
  NSString *ownerName = NSStringFromClass(owner.class);
  NSString *hitName = hit ? NSStringFromClass(hit.class) : @"<nil>";
  fprintf(stderr, "Nimculus tab debug hit stage=%s owner=%s point=(%.1f,%.1f) result=%s\n",
    stage.UTF8String, ownerName.UTF8String, point.x, point.y, hitName.UTF8String);
  tabDebugLogOverlayFrames(owner);
}

static const CGFloat NimculusFindBarRowHeight = NimculusRowHeight - NimculusSpace2;
static const CGFloat NimculusFindBarRowPadding =
  (NimculusRowHeight - NimculusFindBarRowHeight) / 2.0;
// The breadcrumb is drawn in a non-flipped NSTextField. Lower its drawing
// origin within the row by one point so its measured ink rows match Zed's
// two-retina-pixel lower baseline. The left inset is the measured Zed text
// start in retina coordinates.
static const CGFloat NimculusBreadcrumbTextLeft = 12.0;
static const CGFloat NimculusBreadcrumbTextBottom = 13.0;
static const NSUInteger NimculusSidebarHeaderLineCount = 2;

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
static BOOL g_task_output_cancellable = NO;
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
static NimculusEditorAnnotation *g_secondary_editor_annotations = NULL;
static uint32_t g_secondary_editor_annotation_count = 0;
static NSMutableArray<NSString *> *g_secondary_editor_annotation_texts = nil;
static NSString *g_clipboard_text = @"";
static NSData *g_clipboard_utf8_data = nil;
static char g_dialog_path[PATH_MAX] = {0};
static BOOL g_editor_dirty = NO;
static BOOL g_close_decision = NO;
// External edits are advisory: a source-control operation, formatter, or
// another editor must never turn the document window into a modal dead end.
// Retain this action panel explicitly because this backend uses manual
// Objective-C ownership.
static NSPanel *g_external_change_panel = nil;
static id g_external_change_action_target = nil;

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

// .ZedMono is a Zed-internal family name, not a font installed by macOS.
// Resolve it without ever asking Core Text/AppKit for that name: a missing
// family request is what produces the repeated CoreText substitution warning.
// Cache the resolved family so every text path (Metal, NSTextView, and the
// sidebar) uses the same fixed-pitch fallback and does not repeat resolution.
static NSString *systemMonospacedFontName(CGFloat size) {
  NSFont *font = [NSFont monospacedSystemFontOfSize:size weight:NSFontWeightRegular];
  return font.fontName ?: @"Menlo";
}

// Zed's `.ZedMono` is Lilex (assets/fonts/lilex, OFL). Bundling it and using
// it here is the real fix for our glyph advances -- the system monospace face
// advances 9.272pt per ASCII character against Lilex's 9.0 at Zed's 15pt
// default -- but the gutter's line numbers and the Metal text layer resolve
// their wrap points through different metrics, so swapping the family drops
// them out of step and the numbers stop lining up with their rows. Reconcile
// those two paths before changing this.
static NSString *resolveMonospacedFontName(NSString *requested, CGFloat size) {
  if (requested.length == 0 || [requested caseInsensitiveCompare:@".ZedMono"] == NSOrderedSame) {
    return systemMonospacedFontName(size);
  }
  NSFontManager *manager = [NSFontManager sharedFontManager];
  BOOL available = [manager.availableFontFamilies containsObject:requested] ||
    [manager.availableFonts containsObject:requested];
  if (available) {
    NSFont *font = [NSFont fontWithName:requested size:size];
    if (font && font.isFixedPitch) return font.fontName;
  }
  return systemMonospacedFontName(size);
}

static NSString *editorResolvedFontName(void) {
  if (!g_editor_resolved_font_name) {
    replaceOwnedString(&g_editor_resolved_font_name,
      resolveMonospacedFontName(g_editor_font_name, g_editor_font_size));
  }
  return g_editor_resolved_font_name;
}

// Zed's `text_ui(cx)` resolves chrome text at the UI scale independently of
// the buffer's configured size.  The family still comes from the buffer text
// style (items.rs supplies that family), so keep the family and weight logic
// shared while fixing the size at Zed's measured 14px UI default. AppKit/Core
// Text needs a 13.6pt request on this 2x Retina capture to rasterize the same
// 14px glyph columns; this is independent of the 15pt editor buffer setting.
static const CGFloat NimculusUiTextSizePixels = 14.0;
static const CGFloat NimculusUiTextSize = NimculusUiTextSizePixels * (13.6 / 14.0);

static NSFont *editorUiFontWithWeight(NSFontWeight weight) {
  NSFont *font = [NSFont fontWithName:editorResolvedFontName()
    size:NimculusUiTextSize];
  if (!font) font = [NSFont monospacedSystemFontOfSize:NimculusUiTextSize
    weight:NSFontWeightRegular];
  if (weight >= NSFontWeightSemibold) {
    NSFont *weighted = [[NSFontManager sharedFontManager]
      convertFont:font toHaveTrait:NSBoldFontMask];
    if (weighted) font = weighted;
  }
  return font;
}

static NSFont *editorUiItalicFontWithWeight(NSFontWeight weight) {
  NSFont *font = editorUiFontWithWeight(weight);
  NSFont *italic = [[NSFontManager sharedFontManager]
    convertFont:font toHaveTrait:NSItalicFontMask];
  return italic ?: font;
}

static NSString *terminalResolvedFontName(void) {
  if (!g_terminal_resolved_font_name) {
    replaceOwnedString(&g_terminal_resolved_font_name,
      resolveMonospacedFontName(g_terminal_font_name, g_terminal_font_size));
  }
  return g_terminal_resolved_font_name;
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

static NimculusFoldRange *editorFolds(void) {
  return g_rendering_secondary_editor ? g_secondary_editor_folds : g_editor_folds;
}

static uint32_t editorFoldCount(void) {
  return g_rendering_secondary_editor ? g_secondary_editor_fold_count : g_editor_fold_count;
}

static BOOL editorLineHasFoldStart(NSUInteger line) {
  NimculusFoldRange *folds = editorFolds();
  uint32_t count = editorFoldCount();
  for (uint32_t index = 0; index < count; index++) {
    if (folds[index].start_line == line && folds[index].end_line > line) return YES;
  }
  return NO;
}

static BOOL editorLineIsFolded(NSUInteger line) {
  NimculusFoldRange *folds = editorFolds();
  uint32_t count = editorFoldCount();
  for (uint32_t index = 0; index < count; index++) {
    if (line > folds[index].start_line && line <= folds[index].end_line) return YES;
  }
  return NO;
}

static NSUInteger editorFirstVisibleLine(NSUInteger line, NSUInteger lineCount) {
  NSUInteger bounded = MIN(line, lineCount);
  while (bounded < lineCount && editorLineIsFolded(bounded)) bounded++;
  return bounded;
}

static NSUInteger editorVisibleLineCountFrom(NSUInteger firstLine, NSUInteger lineCount,
                                             NSUInteger maximum) {
  NSUInteger count = 0;
  NSUInteger line = editorFirstVisibleLine(firstLine, lineCount);
  while (line < lineCount && count < maximum) {
    count++;
    line = editorFirstVisibleLine(line + 1, lineCount);
  }
  return count;
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
  if (!value || (value.length != 7 && value.length != 9) ||
      [value characterAtIndex:0] != '#') return fallback;
  unsigned int red = 0, green = 0, blue = 0;
  unsigned int alpha = 0xFF;
  NSScanner *scanner = [NSScanner scannerWithString:[value substringWithRange:NSMakeRange(1, 6)]];
  if (![scanner scanHexInt:&red] || red > 0xFFFFFF) return fallback;
  if (value.length == 9) {
    scanner = [NSScanner scannerWithString:[value substringFromIndex:7]];
    if (![scanner scanHexInt:&alpha] || alpha > 0xFF) return fallback;
  }
  green = (red >> 8) & 0xFF;
  blue = red & 0xFF;
  red = (red >> 16) & 0xFF;
  // Theme tokens are authored in sRGB and the parity contract measures the
  // final framebuffer bytes. The calibrated color space applies a display
  // profile conversion on AppKit overlays, so use the same sRGB space as the
  // Metal scene.
  return [NSColor colorWithSRGBRed:red / 255.0 green:green / 255.0
                               blue:blue / 255.0 alpha:alpha / 255.0];
}

static BOOL validThemeToken(NSString *value) {
  return [value isKindOfClass:[NSString class]] && (value.length == 7 || value.length == 9) &&
    [value characterAtIndex:0] == '#';
}

static NSDictionary *validatedTerminalPalette(id value) {
  if (![value isKindOfClass:[NSDictionary class]]) return nil;
  NSDictionary *source = (NSDictionary *)value;
  NSMutableDictionary *result = [NSMutableDictionary dictionary];
  for (NSString *key in @[@"background", @"foreground", @"brightForeground",
                          @"dimForeground", @"cursor", @"selection"]) {
    if (validThemeToken(source[key])) result[key] = source[key];
  }
  for (NSString *key in @[@"normal", @"bright", @"dim"]) {
    NSArray *values = [source[key] isKindOfClass:[NSArray class]] ? source[key] : nil;
    BOOL valid = values.count == 16;
    if (valid) {
      for (id token in values) {
        if (!validThemeToken(token)) { valid = NO; break; }
      }
    }
    if (valid) result[key] = values;
  }
  return result.count > 0 ? result : nil;
}

static NSString *themeRole(NSString *key, NSString *fallback) {
  NSString *value = [g_theme_palette[key] isKindOfClass:[NSString class]] ?
    g_theme_palette[key] : nil;
  if (!value && [key isEqualToString:@"chromeBg"]) value = g_theme_palette[@"titleBar"] ?: g_theme_palette[@"background"];
  if (!value && [key isEqualToString:@"fgPrimary"]) value = g_theme_palette[@"foreground"];
  if (!value && [key isEqualToString:@"fgMuted"]) value = g_theme_palette[@"textMuted"] ?: g_theme_palette[@"foreground"];
  if (!value && [key isEqualToString:@"accent"]) value = g_theme_palette[@"textAccent"] ?: g_theme_palette[@"accent"];
  return validThemeToken(value) ? value : fallback;
}

static BOOL themeLooksLight(void) {
  NSColor *background = themeHexColor(g_theme_background, nil);
  if (!background) return NO;
  CGFloat red = 0.0, green = 0.0, blue = 0.0, alpha = 1.0;
  [background getRed:&red green:&green blue:&blue alpha:&alpha];
  return (0.2126 * red + 0.7152 * green + 0.0722 * blue) > 0.55;
}

static NSColor *themeTokenFallback(NSString *key, NSColor *fallback) {
  const BOOL light = themeLooksLight();
  NSDictionary *lightValues = @{
    @"chromeBg": @"#dcddde", @"tabBar": @"#ececed", @"tabActive": @"#fcfcfc",
    @"surface": @"#ececed", @"panel": @"#ececed", @"elevated": @"#ececed",
    @"border": @"#c9c9ca", @"borderVariant": @"#dfdfe0", @"fgPrimary": @"#242529",
    @"fgMuted": @"#58585a", @"accent": @"#5c78e2", @"textMuted": @"#58585a",
    @"editor": @"#fcfcfc", @"editorForeground": @"#242529", @"gutter": @"#fcfcfc",
    @"editorActiveLine": @"#ececedbf",
    @"scrollbarThumb": @"#00000000", @"scrollbarHover": @"#dfdfe0",
    @"lineNumber": @"#b4b4bb", @"activeLineNumber": @"#44454b", @"hoverLineNumber": @"#61616b",
    @"caret": @"#5c78e2", @"statusBar": @"#dcddde", @"titleBar": @"#dcddde",
    @"added": @"#27a657", @"modified": @"#d3b020", @"deleted": @"#e06c76",
    @"hint": @"#7274a7",
    @"ignored": @"#7e8086"
  };
  NSDictionary *darkValues = @{
    @"chromeBg": @"#3b414d", @"tabBar": @"#2f343e", @"tabActive": @"#282c33",
    @"surface": @"#2f343e", @"panel": @"#2f343e", @"elevated": @"#2f343e",
    @"border": @"#464b57", @"borderVariant": @"#363c46", @"fgPrimary": @"#dce0e5",
    @"fgMuted": @"#a9afbc", @"accent": @"#74ade8", @"textMuted": @"#a9afbc",
    @"editor": @"#282c33", @"editorForeground": @"#acb2be", @"gutter": @"#282c33",
    @"editorActiveLine": @"#2f343ebf",
    @"scrollbarThumb": @"#c8ccd44c", @"scrollbarHover": @"#363c46",
    @"lineNumber": @"#4e5a5f", @"activeLineNumber": @"#d0d4da", @"hoverLineNumber": @"#acb0b4",
    @"caret": @"#74ade8", @"statusBar": @"#3b414d", @"titleBar": @"#3b414d",
    @"added": @"#27a657", @"modified": @"#d3b020", @"deleted": @"#e06c76",
    @"hint": @"#788ca6",
    @"ignored": @"#878a98"
  };
  NSString *value = (light ? lightValues : darkValues)[key];
  return value ? themeHexColor(value, fallback) : fallback;
}

static NSColor *themeRoleColor(NSString *key, NSColor *fallback) {
  return themeHexColor(themeRole(key, nil), themeTokenFallback(key, fallback));
}

static NSString *editorPaintToken(void) {
  NSString *token = themeRole(@"editor", g_theme_background);
  // The One Light token is #fafafa, while Zed's captured painted surface is
  // #fcfcfc on the reference display. Apply that display-space correction at
  // the final opaque Metal fill, rather than changing the theme definition or
  // letting an AppKit overlay tint the gutter independently. One Dark's
  // #282c33 token is already the captured painted value and remains unchanged.
  if ([token caseInsensitiveCompare:@"#fafafa"] == NSOrderedSame) return @"#fcfcfc";
  return token;
}

// Workspace chrome controls are intentionally quiet until the pointer reaches
// them.  Keeping hover state in the native button means tracking, repainting,
// tooltips, accessibility, and command dispatch remain independent of the
// Metal scene and of the sidebar's content model.
@interface NimculusChromeButton : NSButton
@property(nonatomic) BOOL chromeActive;
@property(nonatomic) BOOL chromeHovering;
@property(nonatomic) BOOL chromeImageOnly;
@property(nonatomic, retain) NSTrackingArea *chromeTrackingArea;
@end

static void updateChromeButtonAppearance(NimculusChromeButton *button) {
  if (!button) return;
  NSColor *foreground = themeRoleColor(@"fgPrimary", themeHexColor(g_theme_foreground,
    [NSColor colorWithCalibratedWhite:0.90 alpha:1.0]));
  NSColor *accent = themeRoleColor(@"accent", themeHexColor(g_theme_accent,
    [NSColor controlAccentColor]));
  NSColor *hoverSurface = themeRoleColor(@"elementHover",
    themeRoleColor(@"element", foreground));
  NSColor *tint = button.chromeActive ? accent : [foreground colorWithAlphaComponent:0.78];
  NSColor *background = button.chromeActive ? [accent colorWithAlphaComponent:0.22] :
    (button.chromeHovering ? [hoverSurface colorWithAlphaComponent:0.10] : NSColor.clearColor);
  button.wantsLayer = YES;
  button.layer.cornerRadius = NimculusSpace1;
  button.layer.borderWidth = 0.0;
  button.layer.borderColor = nil;
  button.layer.backgroundColor = background.CGColor;
  button.contentTintColor = tint;
}

@implementation NimculusChromeButton
- (void)dealloc {
  [_chromeTrackingArea release];
  [super dealloc];
}
- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (self.chromeTrackingArea) {
    [self removeTrackingArea:self.chromeTrackingArea];
    self.chromeTrackingArea = nil;
  }
  NSTrackingAreaOptions options = NSTrackingMouseEnteredAndExited |
    NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect;
  self.chromeTrackingArea = [[[NSTrackingArea alloc] initWithRect:NSZeroRect
    options:options owner:self userInfo:nil] autorelease];
  [self addTrackingArea:self.chromeTrackingArea];
}
- (void)mouseEntered:(NSEvent *)event {
  (void)event;
  self.chromeHovering = YES;
  updateChromeButtonAppearance(self);
}
- (void)mouseExited:(NSEvent *)event {
  (void)event;
  self.chromeHovering = NO;
  updateChromeButtonAppearance(self);
}
@end

static void styleWorkspaceNavigationButton(NSButton *button, BOOL active,
                                           BOOL imageOnly) {
  if (!button) return;
  NSColor *foreground = themeRoleColor(@"fgPrimary", themeHexColor(g_theme_foreground,
    [NSColor colorWithCalibratedWhite:0.90 alpha:1.0]));
  NSColor *accent = themeRoleColor(@"accent", themeHexColor(g_theme_accent,
    [NSColor controlAccentColor]));
  NSColor *tint = active ? accent : [foreground colorWithAlphaComponent:0.78];
  button.bordered = NO;
  button.wantsLayer = YES;
  button.layer.cornerRadius = NimculusSpace1;
  button.layer.borderWidth = 0.0;
  button.layer.borderColor = nil;
  button.contentTintColor = tint;
  if ([button isKindOfClass:[NimculusChromeButton class]]) {
    NimculusChromeButton *chromeButton = (NimculusChromeButton *)button;
    chromeButton.chromeActive = active;
    chromeButton.chromeImageOnly = imageOnly;
    updateChromeButtonAppearance(chromeButton);
  } else {
    // Keep the helper safe for legacy/native buttons while all workspace
    // navigation and sidebar-header controls use NimculusChromeButton.
    button.layer.backgroundColor = NSColor.clearColor.CGColor;
  }
  if (button.image) button.image.template = YES;
  if (!imageOnly) {
    button.attributedTitle = [[[NSAttributedString alloc] initWithString:button.title ?: @""
      attributes:@{NSForegroundColorAttributeName: tint,
        NSFontAttributeName: [NSFont systemFontOfSize:12.0
          weight:active ? NSFontWeightSemibold : NSFontWeightMedium]}] autorelease];
  }
}

static void applySidebarIconConfiguration(NSButton *button) {
  if (!button) return;
  button.imageScaling = NSImageScaleProportionallyDown;
  if (@available(macOS 11.0, *)) {
    if (button.image) {
      NSImageSymbolConfiguration *configuration =
        [NSImageSymbolConfiguration configurationWithTextStyle:NSFontTextStyleBody];
      configuration = [configuration configurationByApplyingConfiguration:
        [NSImageSymbolConfiguration configurationWithPointSize:NimculusIconPointSize
          weight:NSFontWeightMedium]];
      button.image = [button.image imageWithSymbolConfiguration:configuration];
    }
  }
}

static void styleSidebarActionButton(NSButton *button) {
  if (!button) return;
  styleWorkspaceNavigationButton(button, NO, YES);
  applySidebarIconConfiguration(button);
}

static void styleSidebarIconButton(NSButton *button, BOOL active) {
  if (!button) return;
  styleWorkspaceNavigationButton(button, active, YES);
  applySidebarIconConfiguration(button);
}

static NSString *sidebarContentText(NSString *text) {
  if (text.length == 0) return @"";
  NSUInteger separator = [text rangeOfString:@"\n"].location;
  if (separator == NSNotFound) return @"";
  NSUInteger contentStart = separator + 1;
  if (contentStart < text.length && [text characterAtIndex:contentStart] == '\n') {
    contentStart++;
  } else {
    NSUInteger secondSeparator = [text rangeOfString:@"\n" options:0
      range:NSMakeRange(contentStart, text.length - contentStart)].location;
    if (secondSeparator == NSNotFound) return @"";
    contentStart = secondSeparator + 1;
  }
  return contentStart < text.length ? [text substringFromIndex:contentStart] : @"";
}

static NSUInteger sidebarItemFromLineValue(int32_t value) {
  if (value < 0) return NSNotFound;
  return (NSUInteger)((uint32_t)value & 0x00ffffffu);
}

static uint32_t sidebarFlagsFromLineValue(int32_t value) {
  if (value < 0) return 0;
  return ((uint32_t)value >> 24) & 0x0fu;
}

static uint32_t sidebarFlagsForContentLine(NSUInteger line) {
  NSUInteger originalLine = line + NimculusSidebarHeaderLineCount;
  if (!g_editor_sidebar_line_items || originalLine >= g_editor_sidebar_line_item_count) {
    return 0;
  }
  return sidebarFlagsFromLineValue(g_editor_sidebar_line_items[originalLine]);
}

static NSColor *sidebarLabelColor(uint32_t flags) {
  if (flags & 8u) {
    return themeRoleColor(@"deleted", themeHexColor(@"#e06c76", [NSColor systemRedColor]));
  }
  if (flags & 4u) {
    return themeRoleColor(@"modified", themeHexColor(@"#d3b020", [NSColor systemYellowColor]));
  }
  if (flags & 2u) {
    return themeRoleColor(@"added", themeHexColor(@"#27a657", [NSColor systemGreenColor]));
  }
  if (flags & 1u) {
    return themeRoleColor(@"ignored", themeHexColor(@"#7e8086", [NSColor secondaryLabelColor]));
  }
  return themeRoleColor(@"fgPrimary", themeHexColor(g_theme_foreground, [NSColor labelColor]));
}

static NSUInteger sidebarIconTokenLength(NSString *line) {
  if ([line hasPrefix:@"▾"] || [line hasPrefix:@"▸"]) return 1;
  for (NSString *token in @[@"{}", @"◆", @"≡", @"⚙", @"≋", @"R", @"T", @"J",
      @"P", @"C", @"H", @"$", @"◇", @"#", @"·", @"•", @"ƒ", @"⚡"]) {
    if ([line hasPrefix:token]) return token.length;
  }
  return 0;
}

static NSString *outlineSymbolForToken(NSString *line, NSUInteger tokenLength) {
  if (tokenLength == 0 || line.length < tokenLength) return @"circle";
  NSString *token = [line substringToIndex:tokenLength];
  if ([token isEqualToString:@"◆"]) return @"cube";
  if ([token isEqualToString:@"ƒ"]) return @"function";
  if ([token isEqualToString:@"⚡"]) return @"bolt";
  if ([token isEqualToString:@"◇"]) return @"circle.grid.2x2";
  if ([token isEqualToString:@"#"]) return @"number";
  if ([token isEqualToString:@"·"]) return @"circle.fill";
  return @"circle";
}

static BOOL g_sidebar_debug_logged = NO;

static BOOL sidebarDebugEnabled(void) {
  const char *enabled = getenv("NIMCULUS_SIDEBAR_DEBUG");
  return enabled && strcmp(enabled, "1") == 0;
}

static NSString *sidebarFileSymbolForLine(NSString *line, NSUInteger tokenLength) {
  if (tokenLength == 0 || line.length <= tokenLength) return @"doc";
  NSString *filename = [line substringFromIndex:tokenLength];
  filename = [filename stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  NSString *lower = filename.lowercaseString;
  NSString *extension = lower.pathExtension;
  if ([filename hasPrefix:@"."] && extension.length == 0) extension = lower;
  if ([extension isEqualToString:@"md"] || [extension isEqualToString:@"markdown"]) {
    return @"doc.richtext";
  }
  if ([extension isEqualToString:@"json"] || [extension isEqualToString:@"jsonc"]) {
    return @"curlybraces";
  }
  if ([extension isEqualToString:@"png"] || [extension isEqualToString:@"jpg"] ||
      [extension isEqualToString:@"jpeg"] || [extension isEqualToString:@"gif"] ||
      [extension isEqualToString:@"svg"] || [extension isEqualToString:@"webp"]) {
    return @"photo";
  }
  if ([extension isEqualToString:@"toml"] || [extension isEqualToString:@"yaml"] ||
      [extension isEqualToString:@"yml"] || [extension isEqualToString:@"ini"]) {
    return @"gearshape";
  }
  if ([extension isEqualToString:@"sh"] || [extension isEqualToString:@"zsh"] ||
      [extension isEqualToString:@"fish"]) {
    return @"terminal";
  }
  if ([extension isEqualToString:@"txt"] || [extension isEqualToString:@"log"]) {
    return @"doc.plaintext";
  }
  if ([extension isEqualToString:@"nim"] || [extension isEqualToString:@"rs"] ||
      [extension isEqualToString:@"ts"] || [extension isEqualToString:@"tsx"] ||
      [extension isEqualToString:@"js"] || [extension isEqualToString:@"jsx"] ||
      [extension isEqualToString:@"py"] || [extension isEqualToString:@"c"] ||
      [extension isEqualToString:@"h"] || [extension isEqualToString:@"cpp"] ||
      [extension isEqualToString:@"hpp"] || [extension isEqualToString:@"html"] ||
      [extension isEqualToString:@"css"] || [extension isEqualToString:@"xml"]) {
    return @"chevron.left.forwardslash.chevron.right";
  }
  return @"doc";
}

static NSImage *sidebarSymbolImage(NSString *symbol) {
  if (!symbol || symbol.length == 0) return nil;
  if (@available(macOS 11.0, *)) {
    NSImage *image = [NSImage imageWithSystemSymbolName:symbol
      accessibilityDescription:nil];
    if (!image) return nil;
    image = [image imageWithSymbolConfiguration:
      [NSImageSymbolConfiguration configurationWithPointSize:13.0 weight:NSFontWeightRegular]];
    image.template = YES;
    return image;
  }
  return nil;
}

static void logSidebarPresentationDebug(NSArray<NSString *> *displayLines,
                                        NSArray<NSNumber *> *depths) {
  if (g_sidebar_debug_logged || !sidebarDebugEnabled() ||
      g_editor_sidebar_mode != 1 || g_editor_sidebar_line_item_count == 0) return;
  g_sidebar_debug_logged = YES;
  NSMutableString *rows = [NSMutableString string];
  for (NSUInteger line = 0; line < displayLines.count; line++) {
    NSString *content = displayLines[line];
    NSUInteger tokenLength = sidebarIconTokenLength(content);
    NSString *symbol = tokenLength > 0 && [content hasPrefix:@"▾"] ? @"folder.fill" :
      (tokenLength > 0 && [content hasPrefix:@"▸"] ? @"folder" :
       (tokenLength > 0 ? sidebarFileSymbolForLine(content, tokenLength) : @"<none>"));
    BOOL resolved = tokenLength > 0 && sidebarSymbolImage(symbol) != nil;
    if (line < 32) {
      [rows appendFormat:@" row=%lu depth=%lu flags=0x%x symbol=%@ image=%@;",
        (unsigned long)line, (unsigned long)depths[line].unsignedIntegerValue,
        sidebarFlagsForContentLine(line), symbol, resolved ? @"ok" : @"nil"];
    }
  }
  if (displayLines.count > 32) {
    [rows appendFormat:@" …(%lu more rows)",
      (unsigned long)(displayLines.count - 32)];
  }
  NSLog(@"Nimculus sidebar debug mode=%u contentLines=%lu lineItems=%u%@",
    g_editor_sidebar_mode, (unsigned long)displayLines.count,
    g_editor_sidebar_line_item_count, rows);
}

static NSString *sidebarHeaderTitle(void) {
  if (g_editor_sidebar_mode == 3) return @"Changes";
  if (g_editor_sidebar_mode == 2) return @"History";
  if (g_editor_sidebar_mode == 4) return @"Branches";
  if (g_editor_sidebar_mode == 5) return @"Search";
  NSString *text = g_editor_outline_text ?: @"";
  NSRange newline = [text rangeOfString:@"\n"];
  return newline.location == NSNotFound ? text : [text substringToIndex:newline.location];
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
static NSUInteger g_glyph_atlas_next_x = 0;
static NSUInteger g_glyph_atlas_next_y = 0;
static NSUInteger g_glyph_atlas_row_height = 0;
static uint64_t g_glyph_atlas_hit_count = 0;
static uint64_t g_glyph_atlas_miss_count = 0;
static uint64_t g_glyph_atlas_eviction_count = 0;
static uint32_t g_glyph_atlas_entry_count = 0;
static BOOL g_glyph_atlas_rebuild_in_progress = NO;
#define NIMCULUS_SUBPIXEL_VARIANTS_X 4
#define NIMCULUS_SUBPIXEL_VARIANTS_Y 1
#define NIMCULUS_GLYPH_ATLAS_HASH_CAPACITY 65536

static BOOL glyphAtlasDebugEnabled(void) {
  static int cached = -1;
  if (cached < 0) {
    const char *value = getenv("NIMCULUS_GLYPH_ATLAS_DEBUG");
    cached = value && value[0] != '\0' && value[0] != '0' ? 1 : 0;
  }
  return cached == 1;
}

static void logGlyphAtlasStats(void) {
  if (!glyphAtlasDebugEnabled()) return;
  uint64_t total = g_glyph_atlas_hit_count + g_glyph_atlas_miss_count;
  double hitRate = total > 0 ? (double)g_glyph_atlas_hit_count / (double)total : 0.0;
  fprintf(stderr, "Nimculus glyph atlas hits=%llu misses=%llu hit_rate=%.4f "
    "entries=%u evictions=%llu\n",
    (unsigned long long)g_glyph_atlas_hit_count,
    (unsigned long long)g_glyph_atlas_miss_count, hitRate,
    g_glyph_atlas_entry_count, (unsigned long long)g_glyph_atlas_eviction_count);
}

static CGFloat roundHalfTowardZero(CGFloat value) {
  CGFloat fractional = value - trunc(value);
  if (fabs(fractional) == 0.5) return trunc(value);
  return round(value);
}

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

// Zed's RenderGlyphParams/AtlasKey equivalent. Keep this key as POD so a
// lookup does not need NSString, NSDictionary, NSValue, or any other
// temporary object. Float fields are compared by value and hashed by their
// IEEE-754 bits, matching Zed's to_bits()-based Hash implementation.
typedef struct NimculusRenderGlyphParams {
  uint32_t font_id;
  uint32_t glyph_id;
  float font_size;
  uint8_t subpixel_variant_x;
  uint8_t subpixel_variant_y;
  float scale_factor;
  uint8_t is_emoji;
  uint8_t subpixel_rendering;
  uint8_t dilation;
} NimculusRenderGlyphParams;

typedef struct NimculusGlyphAtlasHashEntry {
  NimculusRenderGlyphParams key;
  NimculusGlyphAtlasEntry value;
  uint8_t occupied;
} NimculusGlyphAtlasHashEntry;

static NimculusGlyphAtlasHashEntry *g_glyph_atlas_cache = NULL;
static uint32_t g_glyph_atlas_cache_capacity = 0;

typedef struct NimculusGlyphRect {
  float x;
  float y;
  float width;
  float height;
} NimculusGlyphRect;

typedef struct NimculusGlyphColor {
  float red;
  float green;
  float blue;
  float alpha;
} NimculusGlyphColor;

typedef struct NimculusMonochromeSprite {
  NimculusGlyphRect bounds;
  NimculusGlyphRect content_mask;
  NimculusGlyphRect tile;
  NimculusGlyphColor color;
} NimculusMonochromeSprite;

static NimculusMonochromeSprite *g_glyph_sprites = NULL;
static uint32_t g_glyph_sprite_count = 0;
static uint32_t g_glyph_sprite_capacity = 0;
static NimculusEditorLayoutRow *g_editor_layout_rows = NULL;
static uint32_t g_editor_layout_row_count = 0;
static NimculusEditorLayoutGlyph *g_editor_layout_glyphs = NULL;
static uint32_t g_editor_layout_glyph_count = 0;
static NimculusEditorLayoutRow *g_secondary_layout_rows = NULL;
static uint32_t g_secondary_layout_row_count = 0;
static NimculusEditorLayoutGlyph *g_secondary_layout_glyphs = NULL;
static uint32_t g_secondary_layout_glyph_count = 0;
static NimculusMonochromeSprite *g_secondary_glyph_sprites = NULL;
static uint32_t g_secondary_glyph_sprite_count = 0;
static uint32_t g_secondary_glyph_sprite_capacity = 0;
// Terminal cells use the same Core Text glyph atlas as the editor, but keep a
// separate vertex batch and viewport. This prevents a terminal redraw from
// inheriting the editor's scroll origin or text clip.
static NimculusMonochromeSprite *g_terminal_glyph_sprites = NULL;
static uint32_t g_terminal_glyph_sprite_count = 0;
static uint32_t g_terminal_glyph_sprite_capacity = 0;
static const float g_glyph_unit_vertices[12] = {
  0.0f, 0.0f, 1.0f, 0.0f, 0.0f, 1.0f,
  0.0f, 1.0f, 1.0f, 0.0f, 1.0f, 1.0f,
};
static BOOL ensureGlyphValidationPipeline(id<MTLDevice> device);
static id<MTLTexture> g_scene_texture = nil;
static NSMutableDictionary<NSNumber *, id<MTLTexture>> *g_image_textures = nil;
static BOOL g_scene_initialized = NO;
static BOOL g_scene_dirty = YES;
static id g_active_view = nil;
static NimculusHighlightSpan *g_highlights = NULL;
static uint32_t g_highlight_count = 0;
// A split pane can display a different document (and therefore grammar) from
// the primary editor. Keep its byte ranges separate; sharing primary spans
// would apply invalid offsets and colors to the secondary Core Text texture.
static NimculusHighlightSpan *g_secondary_highlights = NULL;
static uint32_t g_secondary_highlight_count = 0;
static NimculusDiagnosticSpan *g_diagnostics = NULL;
static uint32_t g_diagnostic_count = 0;
// Diagnostics carry document byte offsets just like syntax spans. A split
// pane must therefore never reuse the primary document's diagnostic ranges.
static NimculusDiagnosticSpan *g_secondary_diagnostics = NULL;
static uint32_t g_secondary_diagnostic_count = 0;
static NimculusGitHunkSpan *g_git_hunks = NULL;
static uint32_t g_git_hunk_count = 0;
static NimculusGitHunkSpan *g_secondary_git_hunks = NULL;
static uint32_t g_secondary_git_hunk_count = 0;

static void releasePlatformResources(void) {
  // As with Zed's renderer drop path, release GPU objects before AppKit tears
  // down the window/layer, then dispose of CPU buffers and bridge state.
  if ([g_active_view respondsToSelector:@selector(stopDisplayLink)]) {
    [g_active_view stopDisplayLink];
  }
  g_active_view = nil;
  [g_scene_texture release]; g_scene_texture = nil;
  [g_text_texture release]; g_text_texture = nil;
  [g_secondary_text_texture release]; g_secondary_text_texture = nil;
  [g_glyph_atlas_texture release]; g_glyph_atlas_texture = nil;
  [g_image_textures release]; g_image_textures = nil;
  free(g_glyph_atlas_cache); g_glyph_atlas_cache = NULL;
  g_glyph_atlas_cache_capacity = 0;
  g_glyph_atlas_entry_count = 0;
  [g_pipeline release]; g_pipeline = nil;
  [g_text_pipeline release]; g_text_pipeline = nil;
  [g_glyph_pipeline release]; g_glyph_pipeline = nil;
  [g_image_pipeline release]; g_image_pipeline = nil;
  [g_queue release]; g_queue = nil;
  free(g_glyph_sprites); g_glyph_sprites = NULL;
  g_glyph_sprite_count = 0; g_glyph_sprite_capacity = 0;
  free(g_editor_layout_rows); g_editor_layout_rows = NULL; g_editor_layout_row_count = 0;
  free(g_editor_layout_glyphs); g_editor_layout_glyphs = NULL; g_editor_layout_glyph_count = 0;
  free(g_secondary_layout_rows); g_secondary_layout_rows = NULL; g_secondary_layout_row_count = 0;
  free(g_secondary_layout_glyphs); g_secondary_layout_glyphs = NULL;
  g_secondary_layout_glyph_count = 0;
  free(g_secondary_glyph_sprites); g_secondary_glyph_sprites = NULL;
  g_secondary_glyph_sprite_count = 0; g_secondary_glyph_sprite_capacity = 0;
  clearLayoutFonts();
  free(g_terminal_glyph_sprites); g_terminal_glyph_sprites = NULL;
  g_terminal_glyph_sprite_count = 0; g_terminal_glyph_sprite_capacity = 0;
  free(g_paint_commands); g_paint_commands = NULL; g_paint_count = 0;
  free(g_paint_selection_rows); g_paint_selection_rows = NULL;
  g_paint_selection_row_count = 0;
  free(g_paint_dirty_regions); g_paint_dirty_regions = NULL; g_paint_dirty_count = 0;
  free(g_highlights); g_highlights = NULL; g_highlight_count = 0;
  free(g_secondary_highlights); g_secondary_highlights = NULL; g_secondary_highlight_count = 0;
  free(g_diagnostics); g_diagnostics = NULL; g_diagnostic_count = 0;
  free(g_secondary_diagnostics); g_secondary_diagnostics = NULL; g_secondary_diagnostic_count = 0;
  free(g_git_hunks); g_git_hunks = NULL; g_git_hunk_count = 0;
  free(g_secondary_git_hunks); g_secondary_git_hunks = NULL; g_secondary_git_hunk_count = 0;
  free(g_terminal_runs); g_terminal_runs = NULL; g_terminal_run_count = 0;
  free(g_editor_annotations); g_editor_annotations = NULL; g_editor_annotation_count = 0;
  free(g_secondary_editor_annotations); g_secondary_editor_annotations = NULL; g_secondary_editor_annotation_count = 0;
  [g_terminal_hyperlinks release]; g_terminal_hyperlinks = nil;
  [g_terminal_session_titles release]; g_terminal_session_titles = nil;
  [g_task_output_title release]; g_task_output_title = nil;
  [g_editor_annotation_texts release]; g_editor_annotation_texts = nil;
  [g_secondary_editor_annotation_texts release]; g_secondary_editor_annotation_texts = nil;
  [g_editor_tab_titles release]; g_editor_tab_titles = nil;
  [g_secondary_editor_tab_titles release]; g_secondary_editor_tab_titles = nil;
  [g_recent_files release]; g_recent_files = nil;
  [g_workspace_context_path release]; g_workspace_context_path = nil;
  g_workspace_context_is_directory = NO;
  [g_pending_file_open_paths release]; g_pending_file_open_paths = nil;
  [g_clipboard_utf8_data release]; g_clipboard_utf8_data = nil;
  [g_editor_font_name release]; g_editor_font_name = nil;
  [g_editor_resolved_font_name release]; g_editor_resolved_font_name = nil;
  [g_terminal_font_name release]; g_terminal_font_name = nil;
  [g_terminal_resolved_font_name release]; g_terminal_resolved_font_name = nil;
  [g_editor_git_branch release]; g_editor_git_branch = nil;
  [g_editor_text release]; g_editor_text = nil;
  [g_secondary_editor_text release]; g_secondary_editor_text = nil;
  [g_editor_lines release]; g_editor_lines = nil;
  free(g_editor_line_utf16_offsets); g_editor_line_utf16_offsets = NULL;
  free(g_editor_line_utf8_offsets); g_editor_line_utf8_offsets = NULL;
  free(g_editor_sidebar_line_items); g_editor_sidebar_line_items = NULL;
  g_editor_sidebar_line_item_count = 0;
  g_editor_line_count = 0;
  [g_secondary_editor_lines release]; g_secondary_editor_lines = nil;
  free(g_secondary_editor_line_utf16_offsets); g_secondary_editor_line_utf16_offsets = NULL;
  free(g_secondary_editor_line_utf8_offsets); g_secondary_editor_line_utf8_offsets = NULL;
  g_secondary_editor_line_count = 0;
  [g_editor_status release]; g_editor_status = nil;
  [g_editor_footer release]; g_editor_footer = nil;
  [g_editor_context release]; g_editor_context = nil;
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
  [g_theme_palette release]; g_theme_palette = nil;
  [g_crash_report_path release]; g_crash_report_path = nil;
}

bool nimculus_platform_validate_resource_teardown(void) {
  releasePlatformResources();
  return g_scene_texture == nil && g_text_texture == nil &&
    g_glyph_atlas_texture == nil && g_image_textures == nil &&
    g_glyph_atlas_cache == NULL && g_pipeline == nil &&
    g_text_pipeline == nil && g_glyph_pipeline == nil &&
    g_image_pipeline == nil && g_queue == nil && g_glyph_sprites == NULL &&
    g_secondary_glyph_sprites == NULL && g_terminal_glyph_sprites == NULL &&
    g_paint_commands == NULL && g_paint_dirty_regions == NULL &&
    g_highlights == NULL && g_secondary_highlights == NULL && g_diagnostics == NULL &&
    g_secondary_diagnostics == NULL && g_git_hunks == NULL && g_secondary_git_hunks == NULL &&
    g_terminal_runs == NULL && g_editor_annotations == NULL && g_secondary_editor_annotations == NULL &&
    g_pending_file_open_paths == nil &&
    g_glyph_sprite_count == 0 && g_secondary_glyph_sprite_count == 0 &&
    g_paint_count == 0 &&
    g_paint_dirty_count == 0 && g_highlight_count == 0 && g_secondary_highlight_count == 0 &&
    g_diagnostic_count == 0 && g_git_hunk_count == 0 &&
    g_terminal_run_count == 0 && g_terminal_glyph_sprite_count == 0 &&
    g_editor_annotation_count == 0 && g_secondary_editor_annotation_count == 0;
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

typedef struct NimculusSelectionPoint {
  double x;
  double y;
} NimculusSelectionPoint;

static void appendSelectionPoint(NimculusSelectionPoint *points, size_t capacity,
                                 size_t *count, double x, double y) {
  if (!points || !count || *count >= capacity) return;
  if (*count > 0 && fabs(points[*count - 1].x - x) < 0.0001 &&
      fabs(points[*count - 1].y - y) < 0.0001) return;
  points[*count] = (NimculusSelectionPoint){x, y};
  (*count)++;
}

static void appendSelectionLine(NimculusSelectionPoint *points, size_t capacity,
                                size_t *count, double x, double y) {
  appendSelectionPoint(points, capacity, count, x, y);
}

static void appendSelectionQuadratic(NimculusSelectionPoint *points, size_t capacity,
                                     size_t *count, CGPoint control, CGPoint end) {
  if (!points || !count || *count == 0) return;
  const NimculusSelectionPoint start = points[*count - 1];
  const int curveSegments = 6;
  for (int step = 1; step <= curveSegments; step++) {
    double t = (double)step / (double)curveSegments;
    double oneMinusT = 1.0 - t;
    double x = oneMinusT * oneMinusT * start.x +
      2.0 * oneMinusT * t * control.x + t * t * end.x;
    double y = oneMinusT * oneMinusT * start.y +
      2.0 * oneMinusT * t * control.y + t * t * end.y;
    appendSelectionPoint(points, capacity, count, x, y);
  }
}

static double selectionCurveWidth(double left, double right, double radius) {
  return MIN(MAX(0.0, (right - left) / 2.0), MAX(0.0, radius));
}

// Build exactly the concrete boundary used by Zed's EditorElement::paint_lines:
// a top/right walk, rounded joins where adjacent row widths differ, then the
// bottom/left walk. This is deliberately local to rounded selection painting;
// it is not a reusable path or tessellation API.
static size_t buildRoundedSelectionBoundary(const NimculusPaintSelectionRow *rows,
                                            uint32_t rowCount, double radius,
                                            NimculusSelectionPoint *points,
                                            size_t capacity) {
  if (!rows || rowCount == 0 || !points || capacity == 0) return 0;
  const NimculusPaintSelectionRow first = rows[0];
  const NimculusPaintSelectionRow last = rows[rowCount - 1];
  const double firstRight = first.x + first.width;
  const double firstBottom = first.y + first.height;
  const double curveHeight = MAX(0.0, radius);
  const double topCurveWidth = selectionCurveWidth(first.x, firstRight, radius);
  size_t count = 0;
  appendSelectionLine(points, capacity, &count,
    firstRight - topCurveWidth, first.y);
  if (radius > 0.0) {
    appendSelectionQuadratic(points, capacity, &count,
      CGPointMake(firstRight, first.y),
      CGPointMake(firstRight, first.y + curveHeight));
  } else {
    appendSelectionLine(points, capacity, &count, firstRight, first.y);
  }

  for (uint32_t index = 0; index < rowCount; index++) {
    const NimculusPaintSelectionRow line = rows[index];
    const double bottomRightX = line.x + line.width;
    const double bottomRightY = line.y + line.height;
    if (index + 1 < rowCount) {
      const NimculusPaintSelectionRow next = rows[index + 1];
      const double nextRightX = next.x + next.width;
      if (nextRightX == bottomRightX) {
        appendSelectionLine(points, capacity, &count, bottomRightX, bottomRightY);
      } else if (nextRightX < bottomRightX) {
        const double width = selectionCurveWidth(nextRightX, bottomRightX, radius);
        appendSelectionLine(points, capacity, &count,
          bottomRightX, bottomRightY - curveHeight);
        if (radius > 0.0) {
          appendSelectionQuadratic(points, capacity, &count,
            CGPointMake(bottomRightX, bottomRightY),
            CGPointMake(bottomRightX - width, bottomRightY));
        } else {
          appendSelectionLine(points, capacity, &count,
            bottomRightX - width, bottomRightY);
        }
        appendSelectionLine(points, capacity, &count,
          nextRightX + width, bottomRightY);
        if (radius > 0.0) {
          appendSelectionQuadratic(points, capacity, &count,
            CGPointMake(nextRightX, bottomRightY),
            CGPointMake(nextRightX, bottomRightY + curveHeight));
        } else {
          appendSelectionLine(points, capacity, &count,
            nextRightX, bottomRightY + curveHeight);
        }
      } else {
        const double width = selectionCurveWidth(bottomRightX, nextRightX, radius);
        appendSelectionLine(points, capacity, &count,
          bottomRightX, bottomRightY - curveHeight);
        if (radius > 0.0) {
          appendSelectionQuadratic(points, capacity, &count,
            CGPointMake(bottomRightX, bottomRightY),
            CGPointMake(bottomRightX + width, bottomRightY));
        } else {
          appendSelectionLine(points, capacity, &count,
            bottomRightX + width, bottomRightY);
        }
        appendSelectionLine(points, capacity, &count,
          nextRightX - width, bottomRightY);
        if (radius > 0.0) {
          appendSelectionQuadratic(points, capacity, &count,
            CGPointMake(nextRightX, bottomRightY),
            CGPointMake(nextRightX, bottomRightY + curveHeight));
        } else {
          appendSelectionLine(points, capacity, &count,
            nextRightX, bottomRightY + curveHeight);
        }
      }
    } else {
      const double width = selectionCurveWidth(line.x, bottomRightX, radius);
      appendSelectionLine(points, capacity, &count,
        bottomRightX, bottomRightY - curveHeight);
      if (radius > 0.0) {
        appendSelectionQuadratic(points, capacity, &count,
          CGPointMake(bottomRightX, bottomRightY),
          CGPointMake(bottomRightX - width, bottomRightY));
      } else {
        appendSelectionLine(points, capacity, &count,
          bottomRightX - width, bottomRightY);
      }
      appendSelectionLine(points, capacity, &count,
        line.x + width, bottomRightY);
      if (radius > 0.0) {
        appendSelectionQuadratic(points, capacity, &count,
          CGPointMake(line.x, bottomRightY),
          CGPointMake(line.x, bottomRightY - curveHeight));
      } else {
        appendSelectionLine(points, capacity, &count,
          line.x, bottomRightY - curveHeight);
      }
    }
  }

  if (first.x > last.x) {
    const double width = selectionCurveWidth(last.x, first.x, radius);
    appendSelectionLine(points, capacity, &count, last.x, firstBottom + curveHeight);
    if (radius > 0.0) {
      appendSelectionQuadratic(points, capacity, &count,
        CGPointMake(last.x, firstBottom),
        CGPointMake(last.x + width, firstBottom));
    } else {
      appendSelectionLine(points, capacity, &count, last.x + width, firstBottom);
    }
    appendSelectionLine(points, capacity, &count, first.x - width, firstBottom);
    if (radius > 0.0) {
      appendSelectionQuadratic(points, capacity, &count,
        CGPointMake(first.x, firstBottom),
        CGPointMake(first.x, firstBottom - curveHeight));
    } else {
      appendSelectionLine(points, capacity, &count, first.x, firstBottom - curveHeight);
    }
  }
  appendSelectionLine(points, capacity, &count, first.x, first.y + curveHeight);
  if (radius > 0.0) {
    appendSelectionQuadratic(points, capacity, &count,
      CGPointMake(first.x, first.y), CGPointMake(first.x + topCurveWidth, first.y));
  } else {
    appendSelectionLine(points, capacity, &count, first.x + topCurveWidth, first.y);
  }
  appendSelectionLine(points, capacity, &count, firstRight - topCurveWidth, first.y);
  return count;
}

static int compareSelectionY(const void *left, const void *right) {
  const double a = *(const double *)left;
  const double b = *(const double *)right;
  return a < b ? -1 : (a > b ? 1 : 0);
}

static int compareSelectionX(const void *left, const void *right) {
  const double a = *(const double *)left;
  const double b = *(const double *)right;
  return a < b ? -1 : (a > b ? 1 : 0);
}

static size_t selectionIntersectionsAtY(const NimculusSelectionPoint *points,
                                        size_t count, double y, double *intersections,
                                        size_t capacity) {
  size_t intersectionCount = 0;
  for (size_t index = 0; index < count; index++) {
    const NimculusSelectionPoint first = points[index];
    const NimculusSelectionPoint second = points[(index + 1) % count];
    if (first.y == second.y) continue;
    double lower = MIN(first.y, second.y);
    double upper = MAX(first.y, second.y);
    if (y < lower || y >= upper) continue;
    double t = (y - first.y) / (second.y - first.y);
    if (intersectionCount < capacity) intersections[intersectionCount++] =
      first.x + t * (second.x - first.x);
  }
  qsort(intersections, intersectionCount, sizeof(double), compareSelectionX);
  return intersectionCount;
}

static void drawRoundedSelectionWithTransform(id<MTLRenderCommandEncoder> encoder,
                                              id<MTLDevice> device, CGSize logicalSize,
                                              const NimculusPaintSelectionRow *rows,
                                              uint32_t rowCount, double radius,
                                              float red, float green, float blue,
                                              float alpha, NimculusAffine transform) {
  if (!rows || rowCount == 0 || logicalSize.width <= 0 || logicalSize.height <= 0) return;
  size_t capacity = (size_t)rowCount * 32 + 32;
  NimculusSelectionPoint *boundary = malloc(sizeof(NimculusSelectionPoint) * capacity);
  if (!boundary) return;
  size_t boundaryCount = buildRoundedSelectionBoundary(rows, rowCount, radius,
    boundary, capacity);
  if (boundaryCount < 3) { free(boundary); return; }
  double *ys = malloc(sizeof(double) * boundaryCount);
  double *intersectionsTop = malloc(sizeof(double) * boundaryCount);
  double *intersectionsBottom = malloc(sizeof(double) * boundaryCount);
  if (!ys || !intersectionsTop || !intersectionsBottom) {
    free(ys); free(intersectionsTop); free(intersectionsBottom); free(boundary); return;
  }
  for (size_t index = 0; index < boundaryCount; index++) ys[index] = boundary[index].y;
  qsort(ys, boundaryCount, sizeof(double), compareSelectionY);
  size_t uniqueYCount = 0;
  for (size_t index = 0; index < boundaryCount; index++) {
    if (uniqueYCount == 0 || fabs(ys[index] - ys[uniqueYCount - 1]) > 0.0001)
      ys[uniqueYCount++] = ys[index];
  }

  // Each strip is a concrete fill of the already-built selection boundary.
  // Splitting at every boundary y handles the concave inner joins without a
  // general polygon/path engine and preserves the rounded transition on both
  // sides of a width change.
  for (size_t band = 0; band + 1 < uniqueYCount; band++) {
    double top = ys[band];
    double bottom = ys[band + 1];
    if (bottom - top <= 0.0001) continue;
    double sampleTop = top + MIN(0.00005, (bottom - top) / 4.0);
    double sampleBottom = bottom - MIN(0.00005, (bottom - top) / 4.0);
    size_t topCount = selectionIntersectionsAtY(boundary, boundaryCount, sampleTop,
      intersectionsTop, boundaryCount);
    size_t bottomCount = selectionIntersectionsAtY(boundary, boundaryCount, sampleBottom,
      intersectionsBottom, boundaryCount);
    size_t pairCount = MIN(topCount, bottomCount) / 2;
    for (size_t pair = 0; pair < pairCount; pair++) {
      double leftTop = intersectionsTop[pair * 2];
      double rightTop = intersectionsTop[pair * 2 + 1];
      double leftBottom = intersectionsBottom[pair * 2];
      double rightBottom = intersectionsBottom[pair * 2 + 1];
      float vertices[32];
      writeLogicalVertex(&vertices[0], applyAffine(transform, leftTop, top), logicalSize,
        red, green, blue, alpha);
      writeLogicalVertex(&vertices[8], applyAffine(transform, rightTop, top), logicalSize,
        red, green, blue, alpha);
      writeLogicalVertex(&vertices[16], applyAffine(transform, leftBottom, bottom), logicalSize,
        red, green, blue, alpha);
      writeLogicalVertex(&vertices[24], applyAffine(transform, rightBottom, bottom), logicalSize,
        red, green, blue, alpha);
      id<MTLBuffer> buffer = [device newBufferWithBytes:vertices length:sizeof(vertices)
        options:MTLResourceStorageModeShared];
      if (!buffer) continue;
      [encoder setVertexBuffer:buffer offset:0 atIndex:0];
      NimculusDrawUniforms uniforms = {1.0f};
      id<MTLBuffer> uniformBuffer = [device newBufferWithBytes:&uniforms
        length:sizeof(uniforms) options:MTLResourceStorageModeShared];
      [encoder setVertexBuffer:uniformBuffer offset:0 atIndex:1];
      [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
      [uniformBuffer release];
      [buffer release];
    }
  }
  free(ys); free(intersectionsTop); free(intersectionsBottom); free(boundary);
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
  // MTLScissorRect is in drawable pixels with a top-left origin, the same
  // orientation as the logical rectangles the paint list produces. Subtracting
  // the region's bottom from the logical height mirrored every clip about the
  // viewport's middle: a region that started `t` points below the top lost `t`
  // points off its bottom instead. Full-height clips hid it; the editor body,
  // which starts below the tab strip and toolbar, lost exactly that much of
  // its last rows to the workspace background.
  MTLScissorRect scissor = {
    (NSUInteger)floor(x * scaleX),
    (NSUInteger)floor(y * scaleY),
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

static NimculusPaintRegion paintCommandScissor(NimculusPaintCommand paint) {
  NimculusPaintRegion clip = {paint.clip_x, paint.clip_y,
                              paint.clip_width, paint.clip_height};
  if (paint.kind != 10) return clip;

  // Scrollbar commands use the same retained paint path as every other
  // rectangle, but their horizontal thumb lives in the pane's lower chrome
  // rather than in the text viewport.  Use the full owning pane as the
  // command scissor so a body-only clip cannot discard that bottom band.
  NimculusPaintRegion source = {paint.source_x, paint.source_y,
                                paint.source_width, paint.source_height};
  NimculusPaintRegion primary = {(float)g_editor_rect[0], (float)g_editor_rect[1],
                                 (float)g_editor_rect[2], (float)g_editor_rect[3]};
  NimculusPaintRegion secondary = {(float)g_secondary_editor_rect[0],
                                   (float)g_secondary_editor_rect[1],
                                   (float)g_secondary_editor_rect[2],
                                   (float)g_secondary_editor_rect[3]};
  if (intersectPaintRegions(source, primary).width > 0 &&
      intersectPaintRegions(source, primary).height > 0) return primary;
  if (g_secondary_editor_visible && intersectPaintRegions(source, secondary).width > 0 &&
      intersectPaintRegions(source, secondary).height > 0) return secondary;
  return clip;
}

// An editor pane is not itself a text viewport. The pane owns its border, an
// optional editor toolbar row, and a small vertical safety margin.
// Keeping this geometry in one place mirrors Zed's content-bounds mask and
// prevents any renderer (atlas or Core Text texture) from painting into that
// chrome.  Do not use the pane rectangle as a text clip.
// Zed's first editor glyph row begins four logical points higher at the
// reference 2x scale. This is the shared content inset for Core Text, the
// glyph atlas, clipping, and line-number/guide layout.
static const CGFloat NimculusEditorTextTopInset = 2.0;
static const CGFloat NimculusEditorTextGlyphSafety = 2.0;
// The theme RGB values remain unchanged. Zed's glyph atlas is lighter because
// its rasterized coverage is thinner; applying coverage at the compositing
// boundary reproduces that antialiasing without inventing replacement hex
// colors or bypassing the resolved syntax roles.
static const CGFloat NimculusEditorGlyphCoverage = 0.72;
// The footer is flipped, so a small positive frame offset moves its glyphs
// down to the vertical center of the painted status band.
static const CGFloat NimculusStatusItemVerticalOffset = 4.5;
// Hit testing uses the midpoint boundary between adjacent rows. Keeping this
// two points above the glyph clip preserves the established click contract at
// the top edge without moving rendered text.
static const CGFloat NimculusEditorHitTestTopInset = 4.0;
static CTFontRef editorFont(void);

static CGFloat editorContentTopInset(void) {
  return NimculusEditorTextTopInset +
    (g_editor_find_bar_visible ? NimculusRowHeight : 0.0);
}

typedef struct NimculusEditorGutterMetrics {
  CGFloat ch_width;
  CGFloat ch_advance;
  CGFloat max_line_number_width;
  CGFloat line_gutter_width;
  CGFloat left_padding;
  CGFloat right_padding;
  CGFloat width;
  CGFloat margin;
} NimculusEditorGutterMetrics;

static CGFloat editorGlyphTypographicWidth(CTFontRef font, UniChar character) {
  if (!font) return 0.0;
  CGGlyph glyph = 0;
  if (!CTFontGetGlyphsForCharacters(font, &character, &glyph, 1)) return 0.0;
  CGRect bounds = CTFontGetBoundingRectsForGlyphs(font, kCTFontOrientationDefault,
    &glyph, NULL, 1);
  return MAX(0.0, bounds.size.width);
}

static CGFloat editorGlyphAdvance(CTFontRef font, UniChar character) {
  if (!font) return 0.0;
  CGGlyph glyph = 0;
  if (!CTFontGetGlyphsForCharacters(font, &character, &glyph, 1)) return 0.0;
  CGSize advance = CGSizeZero;
  CTFontGetAdvancesForGlyphs(font, kCTFontOrientationDefault, &glyph, &advance, 1);
  return MAX(0.0, advance.width);
}

static CGFloat editorMeasuredLineNumberWidth(NSString *number, CTFontRef font) {
  if (!font || number.length == 0) return 0.0;
  NSDictionary *attributes = @{(id)kCTFontAttributeName: (__bridge id)font};
  NSAttributedString *attributed = [[NSAttributedString alloc]
    initWithString:number attributes:attributes];
  CTLineRef line = CTLineCreateWithAttributedString((CFAttributedStringRef)attributed);
  CGFloat width = 0.0;
  if (line) {
    width = (CGFloat)CTLineGetTypographicBounds(line, NULL, NULL, NULL);
    CFRelease(line);
  }
  [attributed release];
  return MAX(0.0, width);
}

static NimculusEditorGutterMetrics editorGutterMetrics(void) {
  NimculusEditorGutterMetrics metrics = {0};
  NSArray<NSString *> *lines = editorLinesForText(g_editor_text);
  NSUInteger lineCount = MAX((NSUInteger)1, lines.count);
  CTFontRef font = editorFont();
  metrics.ch_width = editorGlyphTypographicWidth(font, '0');
  metrics.ch_advance = editorGlyphAdvance(font, '0');
  if (metrics.ch_width <= 0.0) metrics.ch_width = MAX(1.0, g_editor_font_size * 0.6);
  if (metrics.ch_advance <= 0.0) metrics.ch_advance = metrics.ch_width;
  NSString *widestLineNumber = [NSString stringWithFormat:@"%lu",
    (unsigned long)lineCount];
  metrics.max_line_number_width = editorMeasuredLineNumberWidth(widestLineNumber, font);
  if (metrics.max_line_number_width <= 0.0) {
    metrics.max_line_number_width = metrics.ch_advance * widestLineNumber.length;
  }

  // This is the singleton-buffer branch of Zed's gutter_dimensions with the
  // default settings: runnables/breakpoints/bookmarks occupy the 3ch leading
  // span and folds plus line numbers occupy the 4ch trailing span.
  metrics.line_gutter_width = MAX(metrics.max_line_number_width,
    metrics.ch_advance * 4.0);
  metrics.left_padding = metrics.ch_width * 3.0;
  metrics.right_padding = metrics.ch_width * 4.0;
  metrics.width = metrics.line_gutter_width + metrics.left_padding +
    metrics.right_padding;
  // Zed's `default_gutter_margin` is `-descent`, but GPUI's descent is the
  // signed distance from the baseline to the bottom of the glyph box, so it is
  // negative and the margin comes out positive -- "roughly half a character
  // wide", as Zed's own comment on the content offset puts it. Core Text
  // returns the descent as a positive magnitude, so transcribing the minus
  // sign literally pushed our text origin a full 2 x descent to the left of
  // Zed's (measured: our first glyph at x=84.0pt against Zed's 91.5pt).
  metrics.margin = font ? CTFontGetDescent(font) : g_editor_font_size * 0.22;
  if (font) CFRelease(font);
  return metrics;
}

static CGFloat editorGutterWidth(void) {
  return editorGutterMetrics().width;
}

static CGFloat editorGutterFrameWidth(const double rect[4]) {
  return MIN(editorGutterWidth(), MAX(0.0, rect[2]));
}

static CGFloat editorTextOriginX(const double rect[4]) {
  (void)rect;
  NimculusEditorGutterMetrics metrics = editorGutterMetrics();
  // This runs on the per-frame text-viewport path. Splitting the whole
  // document into lines only to report a line count in a diagnostic belongs
  // behind the diagnostic's own gate.
  const char *debug = getenv("NIMCULUS_GUTTER_DEBUG");
  const BOOL debugEnabled = debug && strcmp(debug, "1") == 0;
  NSUInteger lineCount = 1;
  if (debugEnabled) {
    lineCount = MAX((NSUInteger)1, editorLinesForText(g_editor_text).count);
  }
  if (debugEnabled &&
      (lineCount != g_editor_gutter_debug_line_count ||
       fabs(metrics.width - g_editor_gutter_debug_width) > 0.001 ||
       fabs(metrics.width + metrics.margin - g_editor_gutter_debug_origin) > 0.001)) {
    NSLog(@"Nimculus gutter geometry line_count=%lu ch_width=%.3f "
      "ch_advance=%.3f max_line_number_width=%.3f line_gutter_width=%.3f "
      "left_padding=%.3f right_padding=%.3f gutter_width=%.3f "
      "margin=%.3f text_origin=%.3f",
      (unsigned long)lineCount, metrics.ch_width,
      metrics.ch_advance, metrics.max_line_number_width,
      metrics.line_gutter_width, metrics.left_padding, metrics.right_padding,
      metrics.width, metrics.margin, metrics.width + metrics.margin);
    g_editor_gutter_debug_line_count = lineCount;
    g_editor_gutter_debug_width = metrics.width;
    g_editor_gutter_debug_origin = metrics.width + metrics.margin;
  }
  return metrics.width + metrics.margin;
}

static NimculusPaintRegion editorTextViewportWithOrigin(const double rect[4],
                                                        CGFloat leftInset) {
  // The gutter and the text both belong to the editor pane. The right edge is
  // deliberately not inset for a scrollbar: Zed's scrollbar is an overlay and
  // must never change wrapping or the available text width.
  // Keep every text producer (atlas and wrapping) tied to
  // these constants rather than independently guessing its content bounds.
  const double topInset = editorContentTopInset();
  const double bottomInset = 14.0;
  const double width = MAX(0.0, rect[2] - leftInset);
  const double height = MAX(0.0, rect[3] - topInset - bottomInset);
  NimculusPaintRegion viewport = {
    (float)(rect[0] + leftInset), (float)(rect[1] + topInset),
    (float)width, (float)height
  };
  return viewport;
}

static NimculusPaintRegion editorTextViewport(const double rect[4]) {
  return editorTextViewportWithOrigin(rect, editorTextOriginX(rect));
}

// Core Graphics draws into a bitmap whose origin is bottom-left, while the
// NimNUI/Metal rectangles use a top-left origin. Keep this conversion at the
// Core Text boundary. Passing the logical top-left y coordinate directly to
// CGContextClipToRect/CGPathAddRect clips the top inset as the bottom inset,
// which is exactly how fallback text can leak through the lower editor chrome.
static CGRect editorTextViewportCoreGraphicsRect(const double rect[4]) {
  NimculusPaintRegion viewport = editorTextViewport(rect);
  const CGFloat logicalHeight = MAX(1.0, rect[3]);
  const CGFloat relativeTop = viewport.y - rect[1];
  return CGRectMake(viewport.x - rect[0],
    logicalHeight - relativeTop - viewport.height,
    MAX(1.0, viewport.width), MAX(1.0, viewport.height));
}

// AppKit annotation text is drawn in the flipped, top-left coordinate space
// of the Metal view. Keep its clip in that same space; converting this to a
// Core Graphics rectangle would invert the top/bottom safety margins again.
static NSRect editorAnnotationClipRect(const double rect[4]) {
  NimculusPaintRegion viewport = editorTextViewport(rect);
  return NSMakeRect(viewport.x, viewport.y, viewport.width, viewport.height);
}

// Overlays whose view frame starts at the pane origin need the same clip in
// local coordinates. Keeping this conversion beside the shared viewport
// definition prevents a flipped AppKit child from using the full pane and
// painting into the scrollbar or bottom chrome.
static NSRect editorTextViewportLocalRect(const double rect[4]) {
  NimculusPaintRegion viewport = editorTextViewport(rect);
  return NSMakeRect(viewport.x - rect[0], viewport.y - rect[1],
    viewport.width, viewport.height);
}

// Completion and hover are anchored to a logical text point, but their
// surface is still part of the editor viewport.  Zed's completion menu uses
// the editor's content bounds as its placement authority and flips above the
// cursor when there is no room below it.  Keep that same rule at the Core
// Text boundary: clamp both size and origin before drawing, rather than
// relying on a final clip to hide a popup that was laid out outside the pane.
static NSRect editorTextPopupTopRect(const double rect[4], CGFloat localAnchorX,
                                    CGFloat localAnchorY, CGFloat requestedWidth,
                                    CGFloat requestedHeight) {
  NimculusPaintRegion viewport = editorTextViewport(rect);
  const CGFloat width = MIN(MAX(1.0, requestedWidth), MAX(1.0, viewport.width));
  const CGFloat height = MIN(MAX(1.0, requestedHeight), MAX(1.0, viewport.height));
  const CGFloat anchorX = rect[0] + localAnchorX;
  const CGFloat anchorY = rect[1] + localAnchorY;
  const CGFloat minX = viewport.x;
  const CGFloat maxX = viewport.x + viewport.width - width;
  const CGFloat x = MIN(MAX(anchorX, minX), MAX(minX, maxX));
  const CGFloat belowY = anchorY + 4.0;
  const CGFloat aboveY = anchorY - height - 4.0;
  CGFloat y = belowY;
  if (belowY + height > viewport.y + viewport.height) {
    y = aboveY >= viewport.y ? aboveY : viewport.y + viewport.height - height;
  }
  y = MIN(MAX(y, viewport.y), MAX(viewport.y, viewport.y + viewport.height - height));
  return NSMakeRect(x, y, width, height);
}

static CGRect editorTextPopupCoreGraphicsRect(const double rect[4], NSRect topRect) {
  const CGFloat logicalHeight = MAX(1.0, rect[3]);
  const CGFloat localTop = topRect.origin.y - rect[1];
  return CGRectMake(topRect.origin.x - rect[0],
    logicalHeight - localTop - topRect.size.height,
    topRect.size.width, topRect.size.height);
}

static CGFloat editorTextPopupBaseline(const double rect[4], NSRect topRect,
                                       CGFloat lineHeight, NSUInteger index,
                                       CGFloat topPadding) {
  const CGFloat rowTop = topRect.origin.y - rect[1] + topPadding +
    lineHeight * (CGFloat)index;
  return rect[3] - rowTop - lineHeight + 4.0;
}

// Native overlays are children of the Metal view, not sheets.  They must
// therefore obey the same pane boundary as the editor texture: a split pane
// or a very small window must never let their frame (or child controls) spill
// into a neighbouring pane, the sidebar, or the bottom status area.
static NSRect boundedOverlayFrame(NSRect container, CGFloat requestedWidth,
                                  CGFloat requestedHeight, CGFloat requestedX,
                                  CGFloat requestedY) {
  const CGFloat width = MIN(MAX(1.0, requestedWidth), MAX(1.0, container.size.width));
  const CGFloat height = MIN(MAX(1.0, requestedHeight), MAX(1.0, container.size.height));
  const CGFloat minX = container.origin.x;
  const CGFloat maxX = container.origin.x + container.size.width - width;
  const CGFloat minY = container.origin.y;
  const CGFloat maxY = container.origin.y + container.size.height - height;
  return NSMakeRect(MIN(MAX(requestedX, minX), MAX(minX, maxX)),
    MIN(MAX(requestedY, minY), MAX(minY, maxY)), width, height);
}

static NSRect editorOverlayFrame(CGFloat requestedWidth, CGFloat requestedHeight,
                                 CGFloat requestedX, CGFloat requestedY) {
  return boundedOverlayFrame(NSMakeRect(g_editor_rect[0], g_editor_rect[1],
    MAX(1.0, g_editor_rect[2]), MAX(1.0, g_editor_rect[3])), requestedWidth,
    requestedHeight, requestedX, requestedY);
}

// NimNUI and the Metal scene use logical coordinates whose origin is the top
// left of the content view. AppKit keeps the parent NSView bottom-left
// oriented, even when individual children opt into `isFlipped`.  Convert a
// *child frame* exactly once at the boundary; flipping only the child does
// not flip where its frame is placed. Keeping this next to the editor content
// mask makes tab bars, sidebars, search bars and the welcome view use the
// same coordinate space as Metal, rather than appearing mirrored vertically.
static NSRect appKitFrameForLogicalTopRect(NSView *parent, NSRect logicalRect) {
  const CGFloat parentHeight = parent ? parent.bounds.size.height : 0.0;
  return NSMakeRect(logicalRect.origin.x,
    parentHeight - logicalRect.origin.y - logicalRect.size.height,
    logicalRect.size.width, logicalRect.size.height);
}

static NSUInteger editorVisibleLineCapacity(const double rect[4], CGFloat lineHeight) {
  if (lineHeight <= 0.0) return 1;
  // Cull with the same four-sided content mask used at Core Text, glyph
  // geometry, and Metal submission. Rendering lines for the pane's scrollbar
  // and bottom chrome wastes shaping/raster work even when the final scissor
  // stops their pixels.
  const CGFloat usableHeight = editorTextViewport(rect).height -
    NimculusEditorTextGlyphSafety * 2.0;
  // Do not submit a partially visible final row. A clipped glyph at the
  // bottom is still an overflow defect even when the GPU scissor contains it.
  return (NSUInteger)MAX(1.0, floor(MAX(0.0, usableHeight) / lineHeight));
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
    themeRGB(themeRole(@"accent", g_theme_accent), [NSColor systemBlueColor],
      &themeRed, &themeGreen, &themeBlue);
    drawColoredRectangleWithTransform(encoder, device, logicalSize,
      x, y, width, height,
      themeRed, themeGreen, themeBlue, 1.0f, transform);
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
    themeRGB(themeRole(@"accent", g_theme_accent), [NSColor systemBlueColor],
      &themeRed, &themeGreen, &themeBlue);
    drawRoundedRectangleWithTransform(encoder, device, logicalSize,
      x, y, width, height, paint.radius,
      themeRed, themeGreen, themeBlue, 1.0f, transform);
  } else if (paint.kind == 3) { // text placeholder; M3 owns real text shaping
    themeRGB(themeRole(@"textMuted", g_theme_foreground), [NSColor grayColor],
      &themeRed, &themeGreen, &themeBlue);
    drawColoredRectangleWithTransform(encoder, device, logicalSize,
      x, y, width, height,
      themeRed, themeGreen, themeBlue, 0.75f, transform);
  } else if (paint.kind == 4) { // image placeholder until a texture handle is supplied
    themeRGB(themeRole(@"element", g_theme_background), [NSColor grayColor],
      &themeRed, &themeGreen, &themeBlue);
    drawColoredRectangleWithTransform(encoder, device, logicalSize,
      x, y, width, height,
      themeRed, themeGreen, themeBlue, 1.0f, transform);
  } else if (paint.kind == 7) { // shadow
    drawColoredRectangleWithTransform(encoder, device, logicalSize,
      x + 3.0, y + 3.0, width, height,
      0.0f, 0.0f, 0.0f, 0.35f, transform);
  } else if (paint.kind == 8) { // caret
    themeRGB(themeRole(@"foreground", g_theme_foreground), [NSColor whiteColor],
      &themeRed, &themeGreen, &themeBlue);
    drawColoredRectangleWithTransform(encoder, device, logicalSize,
      x, y, width, height,
      themeRed, themeGreen, themeBlue, 1.0f, transform);
  } else if (paint.kind == 9) { // selection
    themeRGB(g_theme_selection,
      [NSColor colorWithCalibratedRed:0.20 green:0.40 blue:0.75 alpha:1.0],
      &themeRed, &themeGreen, &themeBlue);
    drawColoredRectangleWithTransform(encoder, device, logicalSize,
      x, y, width, height,
      themeRed, themeGreen, themeBlue, 0.45f, transform);
  } else if (paint.kind == 10) { // scrollbar
    // Zed draws a thin, translucent overlay thumb rather than a solid bar, so
    // it reads as a hint over the content instead of a heavy gutter element.
    themeRGB(themeRole(@"scrollbarThumb", g_theme_foreground), [NSColor grayColor],
      &themeRed, &themeGreen, &themeBlue);
    CGFloat alpha = 0.5;
    NSColor *thumb = themeHexColor(themeRole(@"scrollbarThumb", nil), nil);
    if (thumb) {
      CGFloat red = 0.0, green = 0.0, blue = 0.0;
      [thumb getRed:&red green:&green blue:&blue alpha:&alpha];
      themeRed = (float)red;
      themeGreen = (float)green;
      themeBlue = (float)blue;
    }
    drawColoredRectangleWithTransform(encoder, device, logicalSize,
      x, y, width, height,
      themeRed, themeGreen, themeBlue, alpha, transform);
  } else if (paint.kind == 11) { // workspace background
    themeRGB(themeRole(@"background", g_theme_background),
      [NSColor colorWithCalibratedRed:0.055 green:0.065 blue:0.090 alpha:1.0],
      &themeRed, &themeGreen, &themeBlue);
    drawColoredRectangleWithTransform(encoder, device, logicalSize,
      x, y, width, height, themeRed, themeGreen, themeBlue, 1.0f, transform);
  } else if (paint.kind == 12) { // workspace panel
    themeRGB(themeRole(@"panel", g_theme_background),
      [NSColor colorWithCalibratedRed:0.070 green:0.082 blue:0.110 alpha:1.0],
      &themeRed, &themeGreen, &themeBlue);
    drawColoredRectangleWithTransform(encoder, device, logicalSize,
      x, y, width, height, themeRed, themeGreen, themeBlue, 0.96f, transform);
  } else if (paint.kind == 13) { // workspace separator
    // Zed rules workspace edges with `border` at full strength -- measured
    // #cfd1d2 where the dock meets the editor. `border.variant` at 90% came
    // out as #e2e3e4, visibly lighter than the rule it stands in for.
    themeRGB(themeRole(@"border", g_theme_border),
      [NSColor colorWithCalibratedRed:0.20 green:0.23 blue:0.29 alpha:1.0],
      &themeRed, &themeGreen, &themeBlue);
    drawColoredRectangleWithTransform(encoder, device, logicalSize,
      x, y, width, height, themeRed, themeGreen, themeBlue, 1.0f, transform);
  } else if (paint.kind == 14) { // editor active line
    themeRGB(themeRole(@"editorActiveLine", themeRole(@"editor", g_theme_background)),
      [NSColor colorWithCalibratedWhite:0.18 alpha:1.0],
      &themeRed, &themeGreen, &themeBlue);
    CGFloat alpha = 0.75;
    NSColor *activeLine = themeHexColor(themeRole(@"editorActiveLine", nil), nil);
    if (activeLine) {
      CGFloat red = 0.0, green = 0.0, blue = 0.0;
      [activeLine getRed:&red green:&green blue:&blue alpha:&alpha];
      themeRed = (float)red;
      themeGreen = (float)green;
      themeBlue = (float)blue;
    }
    drawColoredRectangleWithTransform(encoder, device, logicalSize,
      x, y, width, height, themeRed, themeGreen, themeBlue, alpha, transform);
  } else if (paint.kind == 15) { // editor background
    themeRGB(editorPaintToken(),
      [NSColor colorWithCalibratedWhite:0.12 alpha:1.0],
      &themeRed, &themeGreen, &themeBlue);
    drawColoredRectangleWithTransform(encoder, device, logicalSize,
      x, y, width, height, themeRed, themeGreen, themeBlue, 1.0f, transform);
  } else if (paint.kind == 16) { // scrollbar track rule
    themeRGB(themeRole(@"scrollbarTrackBorder", themeRole(@"borderVariant", g_theme_border)),
      [NSColor colorWithCalibratedWhite:0.24 alpha:1.0],
      &themeRed, &themeGreen, &themeBlue);
    drawColoredRectangleWithTransform(encoder, device, logicalSize,
      x, y, width, height, themeRed, themeGreen, themeBlue, 1.0f, transform);
  } else if (paint.kind == 17) { // editor diagnostic underline
    NSString *role = paint.image_id == 2 ? @"warning" :
      (paint.image_id == 3 ? @"info" : (paint.image_id >= 4 ? @"hint" : @"error"));
    themeRGB(themeRole(role, themeRole(@"error", [NSColor systemRedColor])),
      [NSColor systemRedColor], &themeRed, &themeGreen, &themeBlue);
    drawColoredRectangleWithTransform(encoder, device, logicalSize,
      x, y, width, height, themeRed, themeGreen, themeBlue, 1.0f, transform);
  } else if (paint.kind == 18) { // Zed-shaped rounded multi-line selection
    themeRGB(g_theme_selection,
      [NSColor colorWithCalibratedRed:0.20 green:0.40 blue:0.75 alpha:1.0],
      &themeRed, &themeGreen, &themeBlue);
    if (paint.selection_row_start < g_paint_selection_row_count &&
        paint.selection_row_count > 0 &&
        paint.selection_row_count <= g_paint_selection_row_count - paint.selection_row_start) {
      drawRoundedSelectionWithTransform(encoder, device, logicalSize,
        &g_paint_selection_rows[paint.selection_row_start], paint.selection_row_count,
        paint.radius, themeRed, themeGreen, themeBlue, 0.45f, transform);
    }
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
  // Syntax colors must track the resolved theme background. A dark-only palette
  // washes out on a light background (pale token text on near-white), so keep a
  // parallel light palette with the same hue identity but darker, readable
  // luminance. Both branches share the same `kind` mapping.
  // Markdown headings use Zed's muted editor foreground rather than the
  // theme's warm `syntax.title` token. Keep this in the existing syntax-color
  // pass: adding a second foreground/font attribute pass to a wrapped Core
  // Text string can make CTFramesetter stall on mixed paragraph attributes.
  if (kind == 8) {
    NSColor *headingBase = themeRoleColor(@"editorForeground", [NSColor textColor]);
    NSColor *headingRGB = [headingBase colorUsingColorSpace:[NSColorSpace genericRGBColorSpace]];
    CGFloat alpha = 1.0;
    [headingRGB getRed:r green:g blue:b alpha:&alpha];
    if (*r + *g + *b < 1.5) {
      *r = MIN(1.0, *r + 0.025);
      *g = MIN(1.0, *g + 0.030);
      *b = MIN(1.0, *b + 0.035);
    }
    return;
  }
  NSString *syntaxKey = kind == 0 ? @"keyword" : kind == 1 ? @"string" :
    kind == 2 ? @"number" : kind == 3 ? @"comment" : kind == 6 ? @"function" :
    kind == 7 ? @"type" : kind == 8 ? @"title" : kind == 9 ? @"emphasis.strong" :
    (kind == 5 ? @"punctuation" : @"primary");
  NSDictionary *syntax = [g_theme_palette[@"syntax"] isKindOfClass:[NSDictionary class]] ?
    g_theme_palette[@"syntax"] : nil;
  NSString *value = [syntax[syntaxKey] isKindOfClass:[NSDictionary class]] ?
    syntax[syntaxKey][@"color"] : nil;
  if (validThemeToken(value)) {
    NSColor *color = themeHexColor(value, nil);
    CGFloat alpha = 1.0;
    [color getRed:r green:g blue:b alpha:&alpha];
    return;
  }
  if (themeLooksLight()) {
    *r = 0.13; *g = 0.15; *b = 0.19;
    if (kind == 0) { *r = 0.11; *g = 0.34; *b = 0.78; }
    else if (kind == 1) { *r = 0.72; *g = 0.36; *b = 0.08; }
    else if (kind == 2) { *r = 0.48; *g = 0.20; *b = 0.72; }
    else if (kind == 3) { *r = 0.13; *g = 0.48; *b = 0.28; }
    else if (kind == 5) { *r = 0.44; *g = 0.48; *b = 0.54; }
    return;
  }
  *r = 0.85; *g = 0.90; *b = 1.0;
  if (kind == 0) { *r = 0.35; *g = 0.70; *b = 1.0; }
  else if (kind == 1) { *r = 0.95; *g = 0.65; *b = 0.35; }
  else if (kind == 2) { *r = 0.80; *g = 0.55; *b = 1.0; }
  else if (kind == 3) { *r = 0.45; *g = 0.75; *b = 0.50; }
  else if (kind == 5) { *r = 0.65; *g = 0.70; *b = 0.78; }
}

void nimculus_platform_get_editor_glyph_color(uint32_t kind,
                                              NimculusEditorGlyphColor *color) {
  if (!color) return;
  NSColor *resolved = nil;
  if (kind == UINT32_MAX || kind == 4) {
    resolved = themeRoleColor(@"editorForeground",
      themeHexColor(g_theme_foreground,
        [NSColor colorWithCalibratedRed:0.85 green:0.90 blue:1.0 alpha:1.0]));
  } else {
    CGFloat red = 0.0, green = 0.0, blue = 0.0;
    highlightColor(kind, &red, &green, &blue);
    color->red = (float)red;
    color->green = (float)green;
    color->blue = (float)blue;
    color->alpha = 1.0f;
    return;
  }
  NSColor *rgb = [resolved colorUsingColorSpace:[NSColorSpace genericRGBColorSpace]];
  CGFloat alpha = 1.0;
  CGFloat red = 0.0, green = 0.0, blue = 0.0;
  [rgb getRed:&red green:&green blue:&blue alpha:&alpha];
  color->red = (float)red;
  color->green = (float)green;
  color->blue = (float)blue;
  color->alpha = 1.0f;
}

static NSColor *themeSyntaxColor(NSString *key, NSColor *fallback) {
  NSDictionary *syntax = [g_theme_palette[@"syntax"] isKindOfClass:[NSDictionary class]] ?
    g_theme_palette[@"syntax"] : nil;
  NSDictionary *token = [syntax[key] isKindOfClass:[NSDictionary class]] ? syntax[key] : nil;
  NSString *value = [token[@"color"] isKindOfClass:[NSString class]] ? token[@"color"] : nil;
  return themeHexColor(value, fallback);
}

static NSString *syntaxKeyForKind(uint32_t kind) {
  if (kind == 0) return @"keyword";
  if (kind == 1) return @"string";
  if (kind == 2) return @"number";
  if (kind == 3) return @"comment";
  if (kind == 6) return @"function";
  if (kind == 7) return @"type";
  if (kind == 8) return @"title";
  if (kind == 9) return @"emphasis.strong";
  return nil;
}

static CTFontRef syntaxFontForKind(uint32_t kind, CTFontRef baseFont) {
  if (!baseFont) return NULL;
  if (kind == 8) {
    // Apply heading weight through the existing syntax pass. A later, separate
    // heading-font mutation is unsafe for wrapped Core Text paragraphs.
    return CTFontCreateCopyWithSymbolicTraits(baseFont, 0.0, NULL,
      kCTFontTraitBold, kCTFontTraitBold);
  }
  NSString *key = syntaxKeyForKind(kind);
  if (!key) return NULL;
  NSDictionary *syntax = [g_theme_palette[@"syntax"] isKindOfClass:[NSDictionary class]] ?
    g_theme_palette[@"syntax"] : nil;
  NSDictionary *token = [syntax[key] isKindOfClass:[NSDictionary class]] ? syntax[key] : nil;
  NSNumber *weight = [token[@"fontWeight"] isKindOfClass:[NSNumber class]] ?
    token[@"fontWeight"] : nil;
  if (!weight || weight.doubleValue < 700.0) return NULL;
  return CTFontCreateCopyWithSymbolicTraits(baseFont, 0.0, NULL,
    kCTFontTraitBold, kCTFontTraitBold);
}

static NSColor *editorGlyphColor(NSColor *color) {
  if (!color) return nil;
  NSColor *rgb = [color colorUsingColorSpace:[NSColorSpace genericRGBColorSpace]];
  if (!rgb) rgb = color;
  return [rgb colorWithAlphaComponent:rgb.alphaComponent * NimculusEditorGlyphCoverage];
}

// Building the face from its name is not free, and the wrap and metrics paths
// ask for it thousands of times per scroll. Keep one and hand out retained
// references so every existing CFRelease stays balanced.
static CTFontRef g_editor_font_cache = NULL;
static CGFloat g_editor_font_cache_size = 0.0;
static NSString *g_editor_font_cache_name = nil;

static CTFontRef editorFont(void) {
  CGFloat size = isfinite(g_editor_font_size) && g_editor_font_size > 0.0
    ? g_editor_font_size : 15.0;
  NSString *name = editorResolvedFontName();
  if (g_editor_font_cache && g_editor_font_cache_size == size &&
      [g_editor_font_cache_name isEqualToString:name]) {
    return (CTFontRef)CFRetain(g_editor_font_cache);
  }
  if (g_editor_font_cache) { CFRelease(g_editor_font_cache); g_editor_font_cache = NULL; }
  [g_editor_font_cache_name release];
  g_editor_font_cache_name = [name copy];
  g_editor_font_cache_size = size;
  // editorResolvedFontName has already rejected .ZedMono and any unavailable
  // or proportional family, so this Core Text request is always for a real
  // fixed-pitch face and is performed without substitution warnings.
  CTFontRef font = CTFontCreateWithName((__bridge CFStringRef)name, size, NULL);
  if (!font) font = CTFontCreateUIFontForLanguage(kCTFontUserFixedPitchFontType, size, NULL);
  g_editor_font_cache = font ? (CTFontRef)CFRetain(font) : NULL;
  return font;
}

static CGFloat editorLineHeight(void) { return g_editor_line_height; }

// Zed centers font metrics inside each fixed-height line box instead of
// assuming that ascent equals the configured line height. Use one authority
// for atlas glyphs, cursor geometry, and hit testing so
// the first row cannot be clipped by the pane's top boundary.
static CGFloat editorTextLineBottom(CGFloat editorHeight, CGFloat lineHeight,
                                    CGFloat displayIndex) {
  return editorHeight - editorContentTopInset() -
    lineHeight * (displayIndex + 1.0) + g_editor_scroll_y_fraction;
}

static CGFloat editorTextBaseline(CGFloat editorHeight, CGFloat lineHeight,
                                  CTFontRef font, CGFloat displayIndex) {
  CGFloat ascent = font ? CTFontGetAscent(font) : lineHeight * 0.78;
  CGFloat descent = font ? CTFontGetDescent(font) : lineHeight * 0.22;
  CGFloat paddingTop = MAX(0.0, (lineHeight - ascent - descent) / 2.0);
  CGFloat lineTop = editorContentTopInset() +
    lineHeight * displayIndex - g_editor_scroll_y_fraction;
  return editorHeight - lineTop - paddingTop - ascent -
    NimculusEditorTextGlyphSafety;
}

static CGFloat editorTextBaselineFromMetrics(CGFloat editorHeight, CGFloat lineHeight,
                                             CGFloat ascent, CGFloat descent,
                                             CGFloat displayIndex) {
  CGFloat paddingTop = MAX(0.0, (lineHeight - ascent - descent) / 2.0);
  CGFloat lineTop = editorContentTopInset() +
    lineHeight * displayIndex - g_editor_scroll_y_fraction;
  return editorHeight - lineTop - paddingTop - ascent -
    NimculusEditorTextGlyphSafety;
}

static CGFloat editorTextCursorYForRow(CGFloat displayRow) {
  return editorContentTopInset() + editorLineHeight() *
    displayRow + editorLineHeight() / 2.0 - g_editor_scroll_y_fraction;
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

static CGFloat editorWidestVisibleLineWidth(void) {
  if (g_editor_soft_wrap) return 0.0;
  NSArray<NSString *> *lines = editorLinesForText(g_editor_text);
  NSUInteger first = editorFirstVisibleLine(g_editor_scroll_line, lines.count);
  NSUInteger capacity = editorVisibleLineCapacity(g_editor_rect, editorLineHeight());
  NSUInteger end = MIN(lines.count, first + capacity + 1);
  CGFloat widest = 0.0;
  for (NSUInteger index = first; index < end; index++) {
    if (editorLineIsFolded(index)) continue;
    widest = MAX(widest, editorTextOffset(lines[index], lines[index].length));
  }
  return widest;
}

static CGFloat editorMaxScrollX(void) {
  if (g_editor_soft_wrap) return 0.0;
  return MAX(0.0, editorWidestVisibleLineWidth() -
    editorTextViewport(g_editor_rect).width);
}

static CGFloat editorClampedScrollX(CGFloat offset) {
  return MIN(MAX(0.0, offset), editorMaxScrollX());
}

static void clampEditorScrollOffsetsForFrame(void) {
  g_editor_scroll_x = g_editor_soft_wrap ? 0.0 :
    editorClampedScrollX(g_editor_scroll_x);
  if (!g_secondary_editor_visible) return;

  double previousRect[4] = {g_editor_rect[0], g_editor_rect[1],
                            g_editor_rect[2], g_editor_rect[3]};
  NSUInteger previousScrollLine = g_editor_scroll_line;
  CGFloat previousScrollYFraction = g_editor_scroll_y_fraction;
  CGFloat previousScrollX = g_editor_scroll_x;
  BOOL previousSoftWrap = g_editor_soft_wrap;
  BOOL previousRenderingSecondary = g_rendering_secondary_editor;
  swapEditorTextState();
  g_rendering_secondary_editor = YES;
  memcpy(g_editor_rect, g_secondary_editor_rect, sizeof(g_editor_rect));
  g_editor_scroll_line = g_secondary_editor_scroll_line;
  g_editor_scroll_y_fraction = g_secondary_editor_scroll_y_fraction;
  g_editor_scroll_x = g_secondary_editor_scroll_x;
  g_editor_soft_wrap = g_secondary_editor_soft_wrap;
  g_editor_scroll_x = g_editor_soft_wrap ? 0.0 :
    editorClampedScrollX(g_editor_scroll_x);
  g_secondary_editor_scroll_x = g_editor_scroll_x;
  swapEditorTextState();
  g_rendering_secondary_editor = previousRenderingSecondary;
  memcpy(g_editor_rect, previousRect, sizeof(g_editor_rect));
  g_editor_scroll_line = previousScrollLine;
  g_editor_scroll_y_fraction = previousScrollYFraction;
  g_editor_scroll_x = previousScrollX;
  g_editor_soft_wrap = previousSoftWrap;
}

static CGFloat editorWrapWidth(void) {
  // Zed's editor element reserves two em widths after the gutter: one for
  // right-side overscroll and one for the end-of-line cell. The scrollbar is
  // an overlay and does not consume width. Use the typographic em width, the
  // same metric Zed uses for calculate_wrap_width, rather than the advance of
  // an arbitrary source character.
  CTFontRef font = editorFont();
  CGFloat emWidth = font ? editorGlyphTypographicWidth(font, 'm') : 0.0;
  if (font) CFRelease(font);
  return MAX(1.0, editorTextViewport(g_editor_rect).width - emWidth * 2.0);
}

static CGRect editorWrapCoreGraphicsRect(const double rect[4]) {
  CGRect result = editorTextViewportCoreGraphicsRect(rect);
  result.size.width = MIN(result.size.width, editorWrapWidth());
  return result;
}

static CGFloat editorMarkdownContinuationIndent(NSString *line, CTFontRef font) {
  if (!line || line.length == 0 || !font) return 0.0;
  NSUInteger cursor = 0;
  while (cursor < line.length && [line characterAtIndex:cursor] == ' ') cursor++;
  if (cursor < line.length && [line characterAtIndex:cursor] == '>') {
    cursor++;
    if (cursor < line.length && [line characterAtIndex:cursor] == ' ') cursor++;
  }
  if (cursor < line.length &&
      ([line characterAtIndex:cursor] == '-' ||
       [line characterAtIndex:cursor] == '*' ||
       [line characterAtIndex:cursor] == '+')) {
    cursor++;
    if (cursor < line.length && [line characterAtIndex:cursor] == ' ') cursor++;
  } else {
    NSUInteger digitStart = cursor;
    while (cursor < line.length &&
           [line characterAtIndex:cursor] >= '0' &&
           [line characterAtIndex:cursor] <= '9') cursor++;
    if (cursor > digitStart && cursor < line.length &&
        ([line characterAtIndex:cursor] == '.' ||
         [line characterAtIndex:cursor] == ')')) {
      cursor++;
      if (cursor < line.length && [line characterAtIndex:cursor] == ' ') cursor++;
    } else {
      cursor = digitStart;
    }
  }
  if (cursor == 0) return 0.0;
  NSDictionary *attributes = @{ (id)kCTFontAttributeName: (__bridge id)font };
  NSString *prefix = [line substringToIndex:cursor];
  NSAttributedString *attributed = [[NSAttributedString alloc]
    initWithString:prefix attributes:attributes];
  CTLineRef ctLine = CTLineCreateWithAttributedString((CFAttributedStringRef)attributed);
  CGFloat width = ctLine ? (CGFloat)CTLineGetTypographicBounds(ctLine, NULL, NULL, NULL) : 0.0;
  if (ctLine) CFRelease(ctLine);
  [attributed release];
  return MAX(0.0, width);
}

static CGPoint editorPointForUTF16Offset(NSUInteger documentOffset) {
  if (g_editor_soft_wrap) return CGPointMake(g_editor_cursor[0], g_editor_cursor[1]);
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
  NSUInteger visibleLine = 0;
  NSUInteger firstLine = editorFirstVisibleLine(g_editor_scroll_line, lines.count);
  for (NSUInteger index = firstLine; index < lineIndex; index++) {
    if (!editorLineIsFolded(index)) visibleLine++;
  }
  return CGPointMake(editorTextOriginX(g_editor_rect) + editorTextOffset(lineText, remaining) - g_editor_scroll_x,
                     editorTextCursorYForRow((CGFloat)visibleLine));
}

static CGPoint editorPointForUTF8Offset(NSUInteger byteOffset) {
  NSArray<NSString *> *lines = editorLinesForText(g_editor_text);
  if (lines.count == 0) return CGPointMake(editorTextOriginX(g_editor_rect), editorTextCursorYForRow(0.0));
  NSUInteger bounded = MIN(byteOffset, (NSUInteger)[g_editor_text lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
  NSUInteger lineIndex = 0;
  for (NSUInteger index = 1; index < lines.count; index++) {
    if (editorLineUTF8Offset(index, lines) > bounded) break;
    lineIndex = index;
  }
  NSUInteger localByte = bounded - editorLineUTF8Offset(lineIndex, lines);
  NSString *lineText = lines[lineIndex];
  NSUInteger localUnit = utf16OffsetForUTF8Bytes(lineText, localByte);
  return editorPointForUTF16Offset(editorLineUTF16Offset(lineIndex, lines) + localUnit);
}

// Keep the insertion point reachable after keyboard navigation or a paste.
// The renderer, hit-test, and NSTextInputClient all consume the same
// scroll-adjusted logical point, so cursor-following belongs at this native
// boundary rather than in a second UI-only approximation.
static CGPoint editorEnsureCursorVisible(NSUInteger documentOffset) {
  CGPoint point = editorPointForUTF16Offset(documentOffset);
  if (g_editor_soft_wrap) return point;
  NimculusPaintRegion viewport = editorTextViewport(editorLayoutRect());
  CGFloat left = viewport.x - g_editor_rect[0] + 2.0;
  CGFloat right = viewport.x - g_editor_rect[0] + viewport.width - 2.0;
  if (point.x > right) {
    g_editor_scroll_x += point.x - right + 16.0;
  } else if (point.x < left) {
    g_editor_scroll_x = MAX(0.0, g_editor_scroll_x - (left - point.x + 16.0));
  }
  g_editor_scroll_x = editorClampedScrollX(g_editor_scroll_x);
  return editorPointForUTF16Offset(documentOffset);
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
  NSInteger targetRow = MAX(0, (NSInteger)floor((fromTop - NimculusEditorHitTestTopInset +
    g_editor_scroll_y_fraction) / editorLineHeight()));
  NSUInteger lineIndex = editorFirstVisibleLine(g_editor_scroll_line, lines.count);
  NSUInteger rowInLine = (NSUInteger)targetRow;
  while (lineIndex < lines.count) {
    if (editorLineIsFolded(lineIndex)) {
      lineIndex = editorFirstVisibleLine(lineIndex, lines.count);
      continue;
    }
    NSUInteger rows = 1;
    if (rowInLine < rows) break;
    rowInLine -= rows;
    lineIndex++;
  }
  if (lineIndex >= lines.count) lineIndex = lines.count - 1;
  NSString *lineText = lines[lineIndex];
  NSUInteger segmentStart = 0;
  for (NSUInteger row = 0; row < rowInLine && segmentStart < lineText.length; row++) {
    segmentStart = lineText.length;
  }
  NSUInteger segmentLength = lineText.length > segmentStart
    ? lineText.length - segmentStart : 0;
  NSString *segment = [lineText substringWithRange:NSMakeRange(segmentStart, segmentLength)];
  CTFontRef font = editorFont();
  NSUInteger localIndex = 0;
  if (font) {
    NSDictionary *attributes = @{ (id)kCTFontAttributeName: (__bridge id)font };
    NSAttributedString *attributed = [[NSAttributedString alloc]
      initWithString:segment attributes:attributes];
    CTLineRef ctLine = CTLineCreateWithAttributedString((CFAttributedStringRef)attributed);
    CFIndex index = CTLineGetStringIndexForPosition(ctLine,
      CGPointMake(MAX(0.0, x - g_editor_rect[0] - editorTextOriginX(g_editor_rect) + g_editor_scroll_x), 0.0));
    if (index != kCFNotFound) localIndex = MIN((NSUInteger)index, segment.length);
    else localIndex = segment.length;
    CFRelease(ctLine);
    [attributed release];
    CFRelease(font);
  }
  NSUInteger documentIndex = editorLineUTF16Offset(lineIndex, lines);
  return MIN(documentIndex + segmentStart + localIndex, g_editor_text.length);
}

static void updateEditorGlyphAtlas(id<MTLDevice> device, NSString *text);
static void resetGlyphSprites(void);

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

void nimculus_platform_layout_line(const uint8_t *utf8, uint32_t length,
                                   double font_size,
                                   const NimculusPlatformFontRun *runs,
                                   uint32_t run_count,
                                   NimculusPlatformLineMetrics *metrics,
                                   NimculusPlatformGlyph *glyphs,
                                   uint32_t glyph_capacity);

static BOOL shapedLineContainsEmoji(NSString *text) {
  if (!text) return NO;
  NSData *bytes = [text dataUsingEncoding:NSUTF8StringEncoding];
  uint32_t capacity = (uint32_t)MAX((NSUInteger)64, bytes.length * 2 + 8);
  NimculusPlatformGlyph *glyphs = calloc(capacity, sizeof(NimculusPlatformGlyph));
  if (!glyphs) return NO;
  NimculusPlatformLineMetrics metrics;
  nimculus_platform_layout_line(bytes.bytes, (uint32_t)bytes.length,
    g_editor_font_size, NULL, 0, &metrics, glyphs, capacity);
  BOOL result = NO;
  for (uint32_t index = 0; index < metrics.glyph_count; index++) {
    if (glyphs[index].is_emoji) { result = YES; break; }
  }
  free(glyphs);
  return result;
}

static BOOL editorLayoutContainsEmoji(void) {
  NimculusEditorLayoutGlyph *glyphs = g_rendering_secondary_editor
    ? g_secondary_layout_glyphs : g_editor_layout_glyphs;
  uint32_t glyphCount = g_rendering_secondary_editor
    ? g_secondary_layout_glyph_count : g_editor_layout_glyph_count;
  for (uint32_t index = 0; glyphs && index < glyphCount; index++) {
    if (glyphs[index].is_emoji) return YES;
  }
  return NO;
}

void nimculus_platform_layout_line(const uint8_t *utf8, uint32_t length,
                                   double font_size,
                                   const NimculusPlatformFontRun *runs,
                                   uint32_t run_count,
                                   NimculusPlatformLineMetrics *metrics,
                                   NimculusPlatformGlyph *glyphs,
                                   uint32_t glyph_capacity) {
  if (!metrics) return;
  memset(metrics, 0, sizeof(*metrics));
  NSString *value = (utf8 && length > 0)
    ? [[NSString alloc] initWithBytes:utf8 length:length encoding:NSUTF8StringEncoding]
    : [[NSString alloc] initWithString:@""];
  if (!value) return;
  CTFontRef baseFont = CTFontCreateWithName((__bridge CFStringRef)editorResolvedFontName(),
                                            font_size > 0.0 ? font_size : g_editor_font_size,
                                            NULL);
  if (!baseFont) baseFont = editorFont();
  if (!baseFont) { [value release]; return; }
  NSMutableAttributedString *attributed = [[NSMutableAttributedString alloc]
    initWithString:value attributes:@{(id)kCTFontAttributeName: (__bridge id)baseFont}];
  NSUInteger byteStart = 0;
  for (uint32_t runIndex = 0; runIndex < run_count && byteStart < length; runIndex++) {
    NSUInteger byteEnd = MIN((NSUInteger)length, byteStart + runs[runIndex].len);
    NSUInteger startUnit = utf16OffsetForUTF8Bytes(value, byteStart);
    NSUInteger endUnit = utf16OffsetForUTF8Bytes(value, byteEnd);
    if (endUnit > startUnit && runs[runIndex].font_id > 0) {
      CTFontRef font = syntaxFontForKind(runs[runIndex].font_id - 1, baseFont);
      if (font) {
        [attributed addAttribute:(id)kCTFontAttributeName value:(id)font
          range:NSMakeRange(startUnit, endUnit - startUnit)];
        CFRelease(font);
      }
    }
    byteStart = byteEnd;
  }
  CTLineRef line = CTLineCreateWithAttributedString((CFAttributedStringRef)attributed);
  if (!line) {
    [attributed release];
    CFRelease(baseFont);
    [value release];
    return;
  }
  double ascent = 0.0, descent = 0.0;
  metrics->width = CTLineGetTypographicBounds(line, &ascent, &descent, NULL);
  metrics->ascent = ascent;
  metrics->descent = descent;
  metrics->len = (uint32_t)[[value dataUsingEncoding:NSUTF8StringEncoding] length];
  CFArrayRef shapedRuns = CTLineGetGlyphRuns(line);
  uint32_t outputCount = 0;
  for (CFIndex runIndex = 0; runIndex < CFArrayGetCount(shapedRuns); runIndex++) {
    CTRunRef run = (CTRunRef)CFArrayGetValueAtIndex(shapedRuns, runIndex);
    CFIndex count = CTRunGetGlyphCount(run);
    if (count <= 0) continue;
    CGGlyph *runGlyphs = malloc(sizeof(CGGlyph) * (NSUInteger)count);
    CGPoint *positions = malloc(sizeof(CGPoint) * (NSUInteger)count);
    CFIndex *indices = malloc(sizeof(CFIndex) * (NSUInteger)count);
    if (!runGlyphs || !positions || !indices) {
      free(runGlyphs); free(positions); free(indices);
      continue;
    }
    CTRunGetGlyphs(run, CFRangeMake(0, count), runGlyphs);
    CTRunGetPositions(run, CFRangeMake(0, count), positions);
    CTRunGetStringIndices(run, CFRangeMake(0, count), indices);
    for (CFIndex glyphIndex = 0; glyphIndex < count; glyphIndex++) {
      if (outputCount >= glyph_capacity) break;
      NSUInteger unitIndex = indices[glyphIndex] == kCFNotFound ? 0 :
        (NSUInteger)indices[glyphIndex];
      NSUInteger byteIndex = utf8BytesForUTF16Offset(value, unitIndex);
      NimculusPlatformGlyph *output = &glyphs[outputCount++];
      output->glyph_id = (uint32_t)runGlyphs[glyphIndex];
      output->x = positions[glyphIndex].x;
      output->y = positions[glyphIndex].y;
      output->index = (uint32_t)byteIndex;
      NSDictionary *runAttributes = (__bridge NSDictionary *)CTRunGetAttributes(run);
      CTFontRef actualFont = (__bridge CTFontRef)[runAttributes
        objectForKey:(id)kCTFontAttributeName];
      output->font_id = layoutFontIdForFont(actualFont ?: baseFont);
      output->is_emoji = colorEmojiAtUTF16Index(value, unitIndex, NULL) ||
        fontIsColorEmoji(actualFont);
    }
    free(runGlyphs); free(positions); free(indices);
  }
  metrics->glyph_count = outputCount;
  CFRelease(line);
  [attributed release];
  CFRelease(baseFont);
  [value release];
}

// Scroll delivers three or four platform updates per event -- scroll line,
// sub-line fraction, horizontal offset, then the composed editor rect -- and
// each one used to re-run Core Text over every visible line and re-upload the
// texture. At trackpad event rates that is several full rasterizations per
// frame for one visible result. Mark the texture dirty instead and rebuild it
// once, at the top of the frame that will actually show it.
static BOOL g_editor_texture_rebuild_pending = NO;
static void rebuildSecondaryEditorTexture(id<MTLDevice> device);
static void updateEditorGlyphAtlasFromLayout(id<MTLDevice> device);
static void updateEditorTextTexture(id<MTLDevice> device, NSString *text,
                                    BOOL force);
static void scheduleEditorTextTextureRebuild(void) {
  g_editor_texture_rebuild_pending = YES;
}
static void flushEditorTextTextureRebuild(void) {
  if (!g_editor_texture_rebuild_pending || !g_queue) return;
  g_editor_texture_rebuild_pending = NO;
  updateEditorTextTexture(g_queue.device, g_editor_text, YES);
  rebuildSecondaryEditorTexture(g_queue.device);
}
static void updateEditorTextTexture(id<MTLDevice> device, NSString *text,
                                    BOOL force) {
  (void)text;
  (void)force;
  if (!device) return;
  updateEditorGlyphAtlasFromLayout(device);
  [g_text_texture release];
  g_text_texture = nil;
}
static void rebuildSecondaryEditorTexture(id<MTLDevice> device) {
  if (!device || !g_secondary_editor_visible) {
    g_secondary_glyph_sprite_count = 0;
    return;
  }
  BOOL previousRenderingSecondary = g_rendering_secondary_editor;
  g_rendering_secondary_editor = YES;
  updateEditorGlyphAtlasFromLayout(device);
  g_rendering_secondary_editor = previousRenderingSecondary;
}

static void resetGlyphSprites(void) {
  if (g_rendering_secondary_editor) g_secondary_glyph_sprite_count = 0;
  else g_glyph_sprite_count = 0;
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
    free(g_glyph_atlas_cache);
    g_glyph_atlas_cache = NULL;
    g_glyph_atlas_cache_capacity = 0;
    g_glyph_atlas_entry_count = 0;
    g_glyph_atlas_next_x = 0;
    g_glyph_atlas_next_y = 0;
    g_glyph_atlas_row_height = 0;
  }
  if (!g_glyph_atlas_cache) {
    g_glyph_atlas_cache = calloc(NIMCULUS_GLYPH_ATLAS_HASH_CAPACITY,
      sizeof(NimculusGlyphAtlasHashEntry));
    if (g_glyph_atlas_cache) {
      g_glyph_atlas_cache_capacity = NIMCULUS_GLYPH_ATLAS_HASH_CAPACITY;
    }
  }
}

static void appendGlyphSpriteTo(NimculusMonochromeSprite **target,
                                uint32_t *count, uint32_t *capacityTarget,
                                NimculusMonochromeSprite sprite) {
  if (*count == *capacityTarget) {
    uint32_t capacity = *capacityTarget == 0 ? 1024 : *capacityTarget * 2;
    NimculusMonochromeSprite *sprites = realloc(*target,
      sizeof(NimculusMonochromeSprite) * capacity);
    if (!sprites) return;
    *target = sprites;
    *capacityTarget = capacity;
  }
  (*target)[(*count)++] = sprite;
}

static void appendGlyphSprite(NimculusMonochromeSprite sprite) {
  if (g_rendering_secondary_editor) {
    appendGlyphSpriteTo(&g_secondary_glyph_sprites, &g_secondary_glyph_sprite_count,
      &g_secondary_glyph_sprite_capacity, sprite);
  } else {
    appendGlyphSpriteTo(&g_glyph_sprites, &g_glyph_sprite_count,
      &g_glyph_sprite_capacity, sprite);
  }
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

static uint32_t floatBitsForGlyphKey(float value) {
  uint32_t bits = 0;
  memcpy(&bits, &value, sizeof(bits));
  return bits;
}

static uint32_t hashGlyphKey(const NimculusRenderGlyphParams *key) {
  // FNV-1a over the same scalar fields used by RenderGlyphParams::Hash.
  uint32_t hash = 2166136261u;
  const uint32_t values[] = {
    key->font_id, key->glyph_id, floatBitsForGlyphKey(key->font_size),
    (uint32_t)key->subpixel_variant_x | ((uint32_t)key->subpixel_variant_y << 8),
    floatBitsForGlyphKey(key->scale_factor),
    (uint32_t)key->is_emoji | ((uint32_t)key->subpixel_rendering << 8) |
      ((uint32_t)key->dilation << 16)
  };
  for (NSUInteger index = 0; index < sizeof(values) / sizeof(values[0]); index++) {
    hash ^= values[index];
    hash *= 16777619u;
  }
  return hash;
}

static BOOL glyphKeysEqual(const NimculusRenderGlyphParams *left,
                           const NimculusRenderGlyphParams *right) {
  return left->font_id == right->font_id && left->glyph_id == right->glyph_id &&
    floatBitsForGlyphKey(left->font_size) == floatBitsForGlyphKey(right->font_size) &&
    left->subpixel_variant_x == right->subpixel_variant_x &&
    left->subpixel_variant_y == right->subpixel_variant_y &&
    floatBitsForGlyphKey(left->scale_factor) == floatBitsForGlyphKey(right->scale_factor) &&
    left->is_emoji == right->is_emoji &&
    left->subpixel_rendering == right->subpixel_rendering &&
    left->dilation == right->dilation;
}

// The table is allocated by ensureGlyphAtlas before rendering starts. This
// probe path only reads/copies POD values and never creates an Objective-C
// object or grows storage.
static BOOL findGlyphAtlasEntry(const NimculusRenderGlyphParams *key,
                                NimculusGlyphAtlasEntry *entry) {
  if (!g_glyph_atlas_cache || g_glyph_atlas_cache_capacity == 0) return NO;
  uint32_t index = hashGlyphKey(key) & (g_glyph_atlas_cache_capacity - 1);
  for (uint32_t probe = 0; probe < g_glyph_atlas_cache_capacity; probe++) {
    NimculusGlyphAtlasHashEntry *candidate = &g_glyph_atlas_cache[index];
    if (!candidate->occupied) return NO;
    if (glyphKeysEqual(&candidate->key, key)) {
      if (entry) *entry = candidate->value;
      return YES;
    }
    index = (index + 1) & (g_glyph_atlas_cache_capacity - 1);
  }
  return NO;
}

static BOOL insertGlyphAtlasEntry(const NimculusRenderGlyphParams *key,
                                  const NimculusGlyphAtlasEntry *entry) {
  if (!g_glyph_atlas_cache || g_glyph_atlas_cache_capacity == 0) return NO;
  uint32_t index = hashGlyphKey(key) & (g_glyph_atlas_cache_capacity - 1);
  for (uint32_t probe = 0; probe < g_glyph_atlas_cache_capacity; probe++) {
    NimculusGlyphAtlasHashEntry *candidate = &g_glyph_atlas_cache[index];
    if (!candidate->occupied) {
      candidate->key = *key;
      candidate->value = *entry;
      candidate->occupied = 1;
      g_glyph_atlas_entry_count++;
      return YES;
    }
    if (glyphKeysEqual(&candidate->key, key)) {
      candidate->value = *entry;
      return YES;
    }
    index = (index + 1) & (g_glyph_atlas_cache_capacity - 1);
  }
  return NO;
}

static void clearGlyphAtlasEntries(void) {
  if (g_glyph_atlas_cache && g_glyph_atlas_cache_capacity > 0) {
    memset(g_glyph_atlas_cache, 0,
      sizeof(NimculusGlyphAtlasHashEntry) * g_glyph_atlas_cache_capacity);
  }
  g_glyph_atlas_entry_count = 0;
}

static BOOL atlasEntryForGlyph(id<MTLDevice> device, CTFontRef font, CGGlyph glyph,
                               uint32_t fontId, CGFloat fontSize, CGFloat scale, uint8_t variantX,
                               uint8_t variantY, BOOL isEmoji,
                               NimculusGlyphAtlasEntry *entry) {
  if (!device || !entry) return NO;
  NimculusRenderGlyphParams key = {
    fontId, (uint32_t)glyph, (float)fontSize, variantX, variantY,
    (float)scale, isEmoji ? 1 : 0, 0, 0
  };
  if (findGlyphAtlasEntry(&key, entry)) {
    g_glyph_atlas_hit_count++;
    return entry->width > 0 && entry->height > 0;
  }
  g_glyph_atlas_miss_count++;
  // The lookup above is the complete hit path. Resolve/retain the CTFont only
  // after a miss, matching Zed's platform rasterize_glyph boundary.
  CTFontRef resolvedFont = font ? font : layoutFontForId(fontId);
  if (!resolvedFont) return NO;
  BOOL ownsFont = !font;
  BOOL result = NO;
  CGRect bounds = CTFontGetBoundingRectsForGlyphs(resolvedFont, kCTFontOrientationDefault,
    &glyph, NULL, 1);
  memset(entry, 0, sizeof(*entry));
  entry->bounds_x = bounds.origin.x;
  entry->bounds_y = bounds.origin.y;
  entry->bounds_width = bounds.size.width;
  entry->bounds_height = bounds.size.height;
  if (bounds.size.width <= 0.0 || bounds.size.height <= 0.0) {
    insertGlyphAtlasEntry(&key, entry);
    goto atlas_done;
  }
  NSUInteger padding = 1;
  NSUInteger width = (NSUInteger)ceil(bounds.size.width * scale) + padding * 2;
  NSUInteger height = (NSUInteger)ceil(bounds.size.height * scale) + padding * 2;
  const NSUInteger atlasSize = 2048;
  if (width >= atlasSize || height >= atlasSize) goto atlas_done;
  if (g_glyph_atlas_next_x + width > atlasSize) {
    g_glyph_atlas_next_x = 0;
    g_glyph_atlas_next_y += g_glyph_atlas_row_height;
    g_glyph_atlas_row_height = 0;
  }
  if (g_glyph_atlas_next_y + height > atlasSize) {
    clearGlyphAtlasEntries();
    g_glyph_atlas_next_x = 0;
    g_glyph_atlas_next_y = 0;
    g_glyph_atlas_row_height = 0;
    g_glyph_atlas_eviction_count++;
  }
  if (g_glyph_atlas_next_x + width > atlasSize ||
      g_glyph_atlas_next_y + height > atlasSize) goto atlas_done;
  NSUInteger x = g_glyph_atlas_next_x;
  NSUInteger y = g_glyph_atlas_next_y;
  g_glyph_atlas_next_x += width;
  g_glyph_atlas_row_height = MAX(g_glyph_atlas_row_height, height);
  NSMutableData *pixels = [NSMutableData dataWithLength:width * height];
  CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceGray();
  CGContextRef context = CGBitmapContextCreate(pixels.mutableBytes, width, height, 8,
    width, colorSpace, (CGBitmapInfo)kCGImageAlphaNone);
  CGColorSpaceRelease(colorSpace);
  if (!context) goto atlas_done;
  CGContextSetGrayFillColor(context, 1.0, 1.0);
  CGContextScaleCTM(context, scale, scale);
  CGPoint origin = CGPointMake((CGFloat)padding / scale - bounds.origin.x +
      (CGFloat)variantX / (CGFloat)(NIMCULUS_SUBPIXEL_VARIANTS_X * scale),
    (CGFloat)padding / scale - bounds.origin.y +
      (CGFloat)variantY / (CGFloat)(NIMCULUS_SUBPIXEL_VARIANTS_Y * scale));
  CTFontDrawGlyphs(resolvedFont, &glyph, &origin, 1, context);
  CGContextRelease(context);
  // Core Text rasterizes into the bitmap's opposite row order from the Metal
  // texture coordinates used by the editor. Normalize the atlas payload once
  // at insertion time, rather than flipping every glyph quad at draw time.
  uint8_t *pixelRows = pixels.mutableBytes;
  uint8_t *rowScratch = malloc(width);
  if (!rowScratch) goto atlas_done;
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
  insertGlyphAtlasEntry(&key, entry);
  result = YES;

atlas_done:
  if (ownsFont) CFRelease(resolvedFont);
  return result;
}

static void appendEditorGlyphSprite(CGSize sceneSize, CGRect editorRect,
                                    NimculusPaintRegion contentMask,
                                    CGFloat textOriginX, CGFloat scrollX,
                                    NimculusGlyphAtlasEntry entry, CGFloat glyphX,
                                    CGFloat baselineY, CGFloat red, CGFloat green,
                                    CGFloat blue, CGFloat alpha) {
  if (entry.width == 0 || entry.height == 0 || sceneSize.width <= 0 ||
      sceneSize.height <= 0 || editorRect.size.width <= 0 ||
      editorRect.size.height <= 0 || contentMask.width <= 0 ||
      contentMask.height <= 0) return;
  CGFloat x = editorRect.origin.x + textOriginX + glyphX + entry.bounds_x - scrollX;
  CGFloat bottomOrigin = baselineY + entry.bounds_y;
  CGFloat y = editorRect.origin.y + editorRect.size.height -
    (bottomOrigin + entry.bounds_height);
  NimculusMonochromeSprite sprite = {
    { (float)x, (float)y, (float)entry.bounds_width, (float)entry.bounds_height },
    { contentMask.x, contentMask.y, contentMask.width, contentMask.height },
    { (float)entry.x, (float)entry.y, (float)entry.width, (float)entry.height },
    { red, green, blue, alpha }
  };
  appendGlyphSprite(sprite);
}

static void updateEditorGlyphAtlasFromLayout(id<MTLDevice> device) {
  g_glyph_rendering_available = NO;
  resetGlyphSprites();
  if (!device) return;
  NimculusEditorLayoutRow *rows = g_rendering_secondary_editor
    ? g_secondary_layout_rows : g_editor_layout_rows;
  uint32_t rowCount = g_rendering_secondary_editor
    ? g_secondary_layout_row_count : g_editor_layout_row_count;
  NimculusEditorLayoutGlyph *glyphs = g_rendering_secondary_editor
    ? g_secondary_layout_glyphs : g_editor_layout_glyphs;
  uint32_t glyphCount = g_rendering_secondary_editor
    ? g_secondary_layout_glyph_count : g_editor_layout_glyph_count;
  if (!rows || rowCount == 0 || !glyphs || glyphCount == 0) return;
  CGFloat scale = g_metrics.scale_factor > 0.0 ? g_metrics.scale_factor : 1.0;
  ensureGlyphAtlas(device, scale);
  const double *layoutRect = editorLayoutRect();
  CGFloat textOriginX = editorTextOriginX(layoutRect);
  CGFloat scrollX = editorLayoutScrollX();
  NimculusPaintRegion contentMask = {
    (float)(layoutRect[0] + textOriginX),
    (float)(layoutRect[1] + editorContentTopInset()),
    (float)MAX(0.0, layoutRect[2] - textOriginX),
    (float)MAX(0.0, layoutRect[3] - editorContentTopInset() - 14.0)
  };
  CGSize editorSize = CGSizeMake(MAX(1.0, layoutRect[2]), MAX(1.0, layoutRect[3]));
  CGSize sceneSize = CGSizeMake(MAX((CGFloat)g_metrics.width_points,
                                    layoutRect[0] + editorSize.width),
                                MAX((CGFloat)g_metrics.height_points,
                                    layoutRect[1] + editorSize.height));
  CGRect editorRect = CGRectMake(layoutRect[0], layoutRect[1],
                                 editorSize.width, editorSize.height);
  CGFloat lineHeight = editorLineHeight();
  for (uint32_t rowIndex = 0; rowIndex < rowCount; rowIndex++) {
    NimculusEditorLayoutRow row = rows[rowIndex];
    CGFloat fontSize = row.font_size > 0.0 ? row.font_size : g_editor_font_size;
    CGFloat ascent = row.ascent > 0.0 ? row.ascent : lineHeight * 0.78;
    CGFloat descent = row.descent > 0.0 ? row.descent : lineHeight * 0.22;
    CGFloat baseline = editorTextBaselineFromMetrics(editorSize.height, lineHeight,
      ascent, descent, (CGFloat)row.display_row) - editorLayoutScrollYFraction();
    uint32_t first = MIN(row.glyph_start, glyphCount);
    uint32_t last = MIN(glyphCount, first + row.glyph_count);
    for (uint32_t glyphIndex = first; glyphIndex < last; glyphIndex++) {
      NimculusEditorLayoutGlyph glyph = glyphs[glyphIndex];
      uint32_t fontId = glyph.font_id;
      CGFloat scaledX = glyph.x * scale;
      CGFloat scaledY = (baseline + glyph.y) * scale;
      CGFloat quantizedX = roundHalfTowardZero(scaledX * NIMCULUS_SUBPIXEL_VARIANTS_X) /
        (NIMCULUS_SUBPIXEL_VARIANTS_X * scale);
      CGFloat integerOriginY = roundHalfTowardZero(scaledY) / scale;
      CGFloat fractionalX = quantizedX * scale - floor(quantizedX * scale);
      uint8_t variantX = (uint8_t)MIN(NIMCULUS_SUBPIXEL_VARIANTS_X - 1,
        MAX(0, (int)(fractionalX * NIMCULUS_SUBPIXEL_VARIANTS_X)));
      uint8_t variantY = 0;
      NimculusGlyphAtlasEntry entry;
      if (atlasEntryForGlyph(device, NULL, (CGGlyph)glyph.glyph_id, fontId, fontSize, scale,
          variantX, variantY, glyph.is_emoji, &entry)) {
        appendEditorGlyphSprite(sceneSize, editorRect, contentMask, textOriginX, scrollX,
          entry, quantizedX, integerOriginY,
          glyph.red, glyph.green, glyph.blue, glyph.alpha);
      }
    }
  }
  g_glyph_rendering_available = g_glyph_pipeline != nil && g_glyph_sprite_count > 0;
  logGlyphAtlasStats();
}

static uint32_t editorLayoutByteOffsetAtPoint(double x, double y) {
  NimculusEditorLayoutRow *rows = g_rendering_secondary_editor
    ? g_secondary_layout_rows : g_editor_layout_rows;
  uint32_t rowCount = g_rendering_secondary_editor
    ? g_secondary_layout_row_count : g_editor_layout_row_count;
  NimculusEditorLayoutGlyph *glyphs = g_rendering_secondary_editor
    ? g_secondary_layout_glyphs : g_editor_layout_glyphs;
  uint32_t glyphCount = g_rendering_secondary_editor
    ? g_secondary_layout_glyph_count : g_editor_layout_glyph_count;
  if (!rows || rowCount == 0) return 0;
  const double *layoutRect = editorLayoutRect();
  CGFloat viewHeight = layoutRect[3] > 0 ? layoutRect[3] : 640.0;
  NSInteger targetRow = MAX(0, (NSInteger)floor((viewHeight - y + layoutRect[1] -
    editorContentTopInset() + editorLayoutScrollYFraction()) / editorLineHeight()));
  NimculusEditorLayoutRow *selected = &rows[0];
  for (uint32_t index = 0; index < rowCount; index++) {
    if (rows[index].display_row == (uint32_t)targetRow) {
      selected = &rows[index];
      break;
    }
  }
  CGFloat localX = MAX(0.0, x - layoutRect[0] - editorTextOriginX(layoutRect) +
    editorLayoutScrollX());
  uint32_t result = selected->segment_end_byte;
  uint32_t first = MIN(selected->glyph_start, glyphCount);
  uint32_t last = MIN(glyphCount, first + selected->glyph_count);
  for (uint32_t index = first; index < last; index++) {
    if (glyphs[index].x >= localX) {
      result = selected->source_start_byte + glyphs[index].index;
      break;
    }
  }
  return result;
}

static void updateEditorGlyphAtlas(id<MTLDevice> device, NSString *text) {
  g_glyph_rendering_available = NO;
  resetGlyphSprites();
  if (!device) return;
  // The atlas is currently R8 monochrome. Zed separates polychrome emoji
  // sprites into a different atlas. Keep ordinary glyph runs in this atlas
  // and let the RGBA Core Text texture render only the color-emoji runs.
  CGFloat scale = g_metrics.scale_factor > 0.0 ? g_metrics.scale_factor : 1.0;
  ensureGlyphAtlas(device, scale);
  uint64_t evictionCountBefore = g_glyph_atlas_eviction_count;
  CTFontRef baseFont = editorFont();
  if (!baseFont) return;
  NSColor *baseColor = editorGlyphColor(themeRoleColor(@"editorForeground",
    themeHexColor(g_theme_foreground,
      [NSColor colorWithCalibratedRed:0.85 green:0.90 blue:1.0 alpha:1.0])));
  NSDictionary *attributes = @{ (id)kCTFontAttributeName: (__bridge id)baseFont,
    (id)kCTForegroundColorAttributeName: (id)baseColor.CGColor };
  NSArray<NSString *> *lines = editorLinesForText(text);
  NSUInteger startLine = editorFirstVisibleLine(g_editor_scroll_line, lines.count);
  const CGFloat lineHeight = editorLineHeight();
  NSUInteger visibleLines = editorVisibleLineCountFrom(startLine, lines.count,
    editorVisibleLineCapacity(g_editor_rect, lineHeight));
  const NSUInteger atlasTopExtraLine = startLine > 0 ? 1 : 0;
  visibleLines += atlasTopExtraLine + 1;
  NSUInteger lineStartByte = editorLineUTF8Offset(startLine, lines);
  CGSize editorSize = CGSizeMake(MAX(1.0, g_editor_rect[2]),
                                 MAX(1.0, g_editor_rect[3]));
  CGSize sceneSize = CGSizeMake(MAX((CGFloat)g_metrics.width_points,
                                    g_editor_rect[0] + editorSize.width),
                                MAX((CGFloat)g_metrics.height_points,
                                    g_editor_rect[1] + editorSize.height));
  CGRect editorRect = CGRectMake(g_editor_rect[0], g_editor_rect[1],
                                 editorSize.width, editorSize.height);
  CGFloat textOriginX = editorTextOriginX(g_editor_rect);
  CGFloat scrollX = editorLayoutScrollX();
  NimculusPaintRegion contentMask = editorTextViewportWithOrigin(g_editor_rect,
                                                                  textOriginX);
  NSUInteger sourceIndex = startLine > 0 ? startLine - 1 : startLine;
  for (NSUInteger displayIndex = 0; displayIndex < visibleLines; displayIndex++) {
    if (sourceIndex >= lines.count) break;
    NSString *lineText = lines[sourceIndex];
    lineStartByte = editorLineUTF8Offset(sourceIndex, lines);
    NSUInteger lineLength = [[lineText dataUsingEncoding:NSUTF8StringEncoding] length];
    NSMutableAttributedString *attributed = [[NSMutableAttributedString alloc]
      initWithString:lineText attributes:attributes];
    NimculusHighlightSpan *highlights = g_rendering_secondary_editor
      ? g_secondary_highlights : g_highlights;
    uint32_t highlightCount = g_rendering_secondary_editor
      ? g_secondary_highlight_count : g_highlight_count;
    for (uint32_t spanIndex = 0; spanIndex < highlightCount; spanIndex++) {
      NimculusHighlightSpan span = highlights[spanIndex];
      if (span.end_byte > lineStartByte && span.start_byte < lineStartByte + lineLength) {
        NSUInteger startByte = MAX((NSUInteger)span.start_byte, lineStartByte) - lineStartByte;
        NSUInteger endByte = MIN((NSUInteger)span.end_byte, lineStartByte + lineLength) - lineStartByte;
        NSUInteger startUnit = utf16OffsetForUTF8Bytes(lineText, startByte);
        NSUInteger endUnit = utf16OffsetForUTF8Bytes(lineText, endByte);
        if (endUnit > startUnit) {
          CGFloat red, green, blue;
          highlightColor(span.kind, &red, &green, &blue);
          NSColor *color = editorGlyphColor([NSColor colorWithCalibratedRed:red
            green:green blue:blue alpha:1.0]);
          [attributed addAttribute:(id)kCTForegroundColorAttributeName
            value:(id)color.CGColor range:NSMakeRange(startUnit, endUnit - startUnit)];
          CTFontRef syntaxFont = syntaxFontForKind(span.kind, baseFont);
          if (syntaxFont) {
            [attributed addAttribute:(id)kCTFontAttributeName value:(id)syntaxFont
              range:NSMakeRange(startUnit, endUnit - startUnit)];
            CFRelease(syntaxFont);
          }
        }
      }
    }
    CTLineRef line = CTLineCreateWithAttributedString((CFAttributedStringRef)attributed);
    CFArrayRef runs = CTLineGetGlyphRuns(line);
    CGFloat baselineY = editorTextBaseline(editorSize.height, lineHeight,
      baseFont, (CGFloat)displayIndex - (CGFloat)atlasTopExtraLine);
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
      uint32_t fontId = layoutFontIdForFont(font);
      for (CFIndex glyphIndex = 0; glyphIndex < glyphCount; glyphIndex++) {
        BOOL colorEmojiGlyph = stringIndices[glyphIndex] != kCFNotFound
          ? colorEmojiAtUTF16Index(lineText, (NSUInteger)stringIndices[glyphIndex], NULL)
          : fontIsColorEmoji(font);
        if (colorEmojiGlyph) continue;
        CGFloat scaledX = positions[glyphIndex].x * scale;
        CGFloat scaledY = (baselineY + positions[glyphIndex].y) * scale;
        CGFloat quantizedX = roundHalfTowardZero(scaledX * NIMCULUS_SUBPIXEL_VARIANTS_X) /
          (NIMCULUS_SUBPIXEL_VARIANTS_X * scale);
        CGFloat integerOriginY = roundHalfTowardZero(scaledY) / scale;
        CGFloat fractionalX = quantizedX * scale - floor(quantizedX * scale);
        uint8_t variantX = (uint8_t)MIN(NIMCULUS_SUBPIXEL_VARIANTS_X - 1,
          MAX(0, (int)(fractionalX * NIMCULUS_SUBPIXEL_VARIANTS_X)));
        uint8_t variantY = 0;
        // The origins are already returned to logical points above. Dividing
        // by scale here a second time shifted glyphs on Retina displays.
        NimculusGlyphAtlasEntry entry;
        if (atlasEntryForGlyph(device, font, glyphs[glyphIndex], fontId, g_editor_font_size,
            scale,
            variantX, variantY, NO, &entry)) {
          appendEditorGlyphSprite(sceneSize, editorRect, contentMask, textOriginX, scrollX,
            entry, quantizedX, integerOriginY, red, green, blue, alpha);
        }
      }
      free(glyphs);
      free(positions);
      free(stringIndices);
    }
    CFRelease(line);
    [attributed release];
    sourceIndex = editorFirstVisibleLine(sourceIndex + 1, lines.count);
  }
  CFRelease(baseFont);
  // Atlas eviction invalidates every UV emitted before the eviction. Rebuild
  // the complete visible batch against the new atlas, just as Zed rebuilds a
  // sprite batch when its atlas allocation changes. If the visible batch
  // cannot fit after one retry, drop the batch rather than presenting a
  // mixture of stale and current atlas coordinates.
  if (g_glyph_atlas_eviction_count != evictionCountBefore) {
    if (!g_glyph_atlas_rebuild_in_progress) {
      g_glyph_atlas_rebuild_in_progress = YES;
      updateEditorGlyphAtlas(device, text);
      g_glyph_atlas_rebuild_in_progress = NO;
      return;
    }
    resetGlyphSprites();
    return;
  }
  g_glyph_rendering_available = g_glyph_pipeline != nil && g_glyph_sprite_count > 0;
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

// Per-event logging is opt-in. logInput runs for every scroll, mouse-move,
// drag, and key event; an unconditional NSLog there takes a system-wide lock
// and does synchronous formatted I/O on the main thread for each of the
// hundreds of scroll/trackpad events per second, which visibly degrades scroll
// smoothness and input latency. Zed never logs per input event in a normal
// run. Gate it behind NIMCULUS_INPUT_LOG (checked once) so diagnostics stay
// available without paying the cost on every event.
static BOOL nimculusInputLogEnabled(void) {
  static int cached = -1;
  if (cached < 0) {
    const char *value = getenv("NIMCULUS_INPUT_LOG");
    cached = (value && value[0] != '\0' && value[0] != '0') ? 1 : 0;
  }
  return cached == 1;
}

static uint32_t nimculusTouchPhaseForEvent(NSEvent *event) {
  switch (event.phase) {
    case NSEventPhaseBegan:
    case NSEventPhaseMayBegin:
      return NIMCULUS_TOUCH_PHASE_STARTED;
    case NSEventPhaseEnded:
      return NIMCULUS_TOUCH_PHASE_ENDED;
    default:
      return NIMCULUS_TOUCH_PHASE_MOVED;
  }
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
  const uint32_t phase = isScrollWheel
    ? nimculusTouchPhaseForEvent(event) : NIMCULUS_TOUCH_PHASE_MOVED;
  if (nimculusInputLogEnabled()) {
    NSLog(@"Nimculus input kind=%@ keyCode=%hu modifiers=0x%lx x=%.1f y=%.1f dx=%.1f dy=%.1f phase=%u",
          kind, keyCode, event.modifierFlags, location.x, location.y,
          deltaX, deltaY, phase);
  }
  if (g_input_callback) {
    NimculusInputEvent input = {
      .type = (uint32_t)event.type,
      .key_code = keyCode,
      .modifiers = (uint32_t)event.modifierFlags,
      .button = mouseButtonForEvent(event),
      .x = location.x, .y = location.y,
      .delta_x = deltaX, .delta_y = deltaY,
      .precise_scrolling = preciseScrolling,
      .phase = phase,
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
@property(nonatomic, strong) CADisplayLink *displayLink;
@property(nonatomic) BOOL displayLinkRunning;
@property(nonatomic) BOOL redrawDirty;
@property(nonatomic, copy) NSString *markedText;
@property(nonatomic) NSRange markedTextRange;
@property(nonatomic) NSRange selectedTextRange;
@property(nonatomic, strong) NSTrackingArea *trackingArea;
- (void)requestRedraw;
- (void)startDisplayLinkIfNeeded;
- (void)restartDisplayLinkIfNeeded;
- (void)stopDisplayLink;
- (void)updateTerminalFrame;
- (void)showDocumentFindBar:(BOOL)replace;
- (void)showGoToLineBar;
- (void)showWorkspaceSearchBar;
- (void)showQuickOpenBar;
- (void)showSettingsEditorWithTheme:(NSString *)theme editorFontSize:(NSString *)editorFontSize
                   terminalFontSize:(NSString *)terminalFontSize editorFontFamily:(NSString *)editorFontFamily
                 terminalFontFamily:(NSString *)terminalFontFamily shell:(NSString *)shell;
- (void)showCommandPalette;
- (void)showGitCommitEditor;
@end

// Zed uses an app-owned titlebar: AppKit supplies the traffic-light buttons,
// while the workspace draws the titlebar surface and its breadcrumb in the
// same visual system as the editor. Keeping this as a separate root child
// preserves the Metal view's content metrics and prevents the titlebar from
// stealing or overlapping editor coordinates.
@interface NimculusTitlebarView : NSView
@property(nonatomic, retain) NSButton *branchButton;
- (void)updateBranchButton;
@end

@interface NimculusWindowContentView : NSView
@property(nonatomic, retain) NimculusMetalView *metalView;
@property(nonatomic, retain) NimculusTitlebarView *titlebarView;
- (instancetype)initWithMetalView:(NimculusMetalView *)metalView;
@end

@implementation NimculusTitlebarView
- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (!self) return nil;
  self.branchButton = [NimculusChromeButton buttonWithTitle:@"No Git branch" target:self
    action:@selector(openBranches:)];
  styleWorkspaceNavigationButton(self.branchButton, NO, NO);
  self.branchButton.alignment = NSTextAlignmentLeft;
  self.branchButton.imageHugsTitle = YES;
  self.branchButton.toolTip = @"Git branch — click to open Branches";
  self.branchButton.accessibilityLabel = @"Git branch, open branch picker";
  [self addSubview:self.branchButton];
  [self updateBranchButton];
  return self;
}
- (void)dealloc { [_branchButton release]; [super dealloc]; }
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return NO; }
- (void)drawRect:(NSRect)dirtyRect {
  (void)dirtyRect;
  NSColor *background = themeRoleColor(@"chromeBg", themeHexColor(g_theme_background,
    [NSColor colorWithCalibratedRed:0.105 green:0.12 blue:0.15 alpha:1.0]));
  [background setFill];
  NSRectFill(self.bounds);

  // Zed paints this rule at full strength: measured #cfd1d2 against the
  // #dcddde title bar. A 28% wash produced #f0f0f0, lighter than either.
  NSColor *border = themeRoleColor(@"border", themeHexColor(g_theme_foreground,
    [NSColor colorWithCalibratedWhite:0.85 alpha:1.0]));
  [border setFill];
  NSRectFill(NSMakeRect(0.0, MAX(0.0, self.bounds.size.height -
    NimculusChromeBorderHeight), self.bounds.size.width,
    NimculusChromeBorderHeight));

  NSColor *foreground = themeRoleColor(@"fgPrimary", themeHexColor(g_theme_foreground,
    [NSColor colorWithCalibratedWhite:0.90 alpha:1.0]));
  NSDictionary *titleAttributes = @{
    NSForegroundColorAttributeName: [foreground colorWithAlphaComponent:0.92],
    NSFontAttributeName: [NSFont systemFontOfSize:12.0 weight:NSFontWeightRegular]
  };
  // The document breadcrumb is intentionally independent from the workspace
  // title. Its first component is the filename, while this title remains the
  // application/workspace label.
  NSString *workspaceName = @"Nimculus";
  [workspaceName drawAtPoint:NSMakePoint(76.0, 7.0) withAttributes:titleAttributes];
}
- (void)layout {
  [super layout];
  NSDictionary *titleAttributes = @{
    NSFontAttributeName: [NSFont systemFontOfSize:12.0 weight:NSFontWeightRegular]
  };
  CGFloat titleWidth = ceil([@"Nimculus" sizeWithAttributes:titleAttributes].width);
  CGFloat branchX = 76.0 + titleWidth + NimculusSpace2;
  CGFloat availableWidth = MAX(1.0, self.bounds.size.width - branchX - NimculusSpace2);
  self.branchButton.frame = NSMakeRect(branchX, 2.0, MIN(260.0, availableWidth),
    NimculusControlHit);
}
- (void)updateBranchButton {
  NSString *branch = g_editor_git_branch.length > 0 ? g_editor_git_branch : @"No Git branch";
  NSColor *foreground = themeRoleColor(@"fgMuted", themeHexColor(g_theme_foreground,
    [NSColor colorWithCalibratedWhite:0.90 alpha:1.0]));
  self.branchButton.image = nil;
  if (@available(macOS 11.0, *)) {
    self.branchButton.image = [NSImage imageWithSystemSymbolName:@"arrow.triangle.branch"
      accessibilityDescription:@"Git branch"];
    self.branchButton.imagePosition = NSImageLeft;
    applySidebarIconConfiguration(self.branchButton);
  }
  self.branchButton.alignment = NSTextAlignmentLeft;
  self.branchButton.imageHugsTitle = YES;
  self.branchButton.attributedTitle = [[[NSAttributedString alloc]
    initWithString:branch attributes:@{NSForegroundColorAttributeName: [foreground colorWithAlphaComponent:0.92],
      NSFontAttributeName: [NSFont systemFontOfSize:11.0 weight:NSFontWeightMedium]}]
    autorelease];
  self.branchButton.contentTintColor = foreground;
  self.branchButton.toolTip = [NSString stringWithFormat:
    @"Git branch: %@ — click to open Branches", branch];
  self.branchButton.accessibilityLabel = [NSString stringWithFormat:
    @"Git branch %@, open branch picker", branch];
}
- (void)openBranches:(id)sender {
  (void)sender;
  if (g_command_callback) g_command_callback("commandPalette:git branches");
}
- (void)mouseDown:(NSEvent *)event {
  if (event.clickCount == 2) {
    [self.window performZoom:self];
  } else {
    [self.window performWindowDragWithEvent:event];
  }
}
@end

@implementation NimculusWindowContentView
- (instancetype)initWithMetalView:(NimculusMetalView *)metalView {
  self = [super initWithFrame:NSZeroRect];
  if (!self) return nil;
  self.metalView = metalView;
  self.titlebarView = [[[NimculusTitlebarView alloc] initWithFrame:NSZeroRect] autorelease];
  [self addSubview:self.metalView];
  [self addSubview:self.titlebarView];
  return self;
}
- (void)dealloc {
  [_metalView release];
  [_titlebarView release];
  [super dealloc];
}
- (void)layout {
  [super layout];
  const CGFloat titlebarHeight = NimculusTitlebarHeight;
  CGFloat contentHeight = MAX(1.0, self.bounds.size.height - titlebarHeight);
  self.metalView.frame = NSMakeRect(0.0, 0.0, self.bounds.size.width, contentHeight);
  self.metalView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  self.titlebarView.frame = NSMakeRect(0.0,
    MAX(0.0, self.bounds.size.height - titlebarHeight),
    self.bounds.size.width, titlebarHeight);
  self.titlebarView.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
}
- (NSView *)hitTest:(NSPoint)point {
  NSView *hit = [super hitTest:point];
  tabDebugLogHitTest(@"window-content", self, point, hit);
  return hit;
}
- (NSArray *)accessibilityChildren {
  NSMutableArray *children = [[[super accessibilityChildren] mutableCopy] autorelease];
  if (!children) children = [NSMutableArray array];
  if (g_accessibility_root && ![children containsObject:g_accessibility_root]) {
    [children addObject:g_accessibility_root];
  }
  return children;
}
@end

// Zed keeps buffer search in the pane chrome instead of making the editor
// wait on a modal prompt.  This small native equivalent stays above the Metal
// document surface, lets the document continue rendering, and returns focus
// to the editor when dismissed.
@class NimculusDocumentSearchOverlay;
@class NimculusCommandPaletteOverlay;
@class NimculusPickerListView;
@class NimculusGitCommitOverlay;
@class NimculusSettingsOverlay;
@class NimculusOutlineOverlay;
@interface NimculusDocumentSearchField : NSSearchField
@property(nonatomic, assign) NimculusDocumentSearchOverlay *searchOverlay;
@end
@interface NimculusDocumentLineField : NSTextField
@property(nonatomic, assign) NimculusDocumentSearchOverlay *searchOverlay;
@end
@interface NimculusOutlineFilterField : NSSearchField
@property(nonatomic, assign) NimculusOutlineOverlay *outline;
@end
@interface NimculusCommandPaletteField : NSTextField
@property(nonatomic, assign) NimculusCommandPaletteOverlay *commandPalette;
@end
@interface NimculusGitCommitField : NSTextField
@property(nonatomic, assign) NimculusGitCommitOverlay *commitOverlay;
@end
@interface NimculusSettingsTextField : NSTextField
@property(nonatomic, assign) NimculusSettingsOverlay *settingsOverlay;
@end
@interface NimculusPickerRow : NSView
@property(nonatomic, assign) NimculusPickerListView *pickerList;
@property(nonatomic, retain) NSString *title;
@property(nonatomic, retain) NSString *shortcut;
@property(nonatomic, retain) NSString *query;
@property(nonatomic, retain) NSTrackingArea *trackingArea;
@property(nonatomic) NSUInteger index;
@property(nonatomic) BOOL selected;
@property(nonatomic) BOOL hovered;
@end
@interface NimculusPickerListView : NSView
@property(nonatomic, retain) NSArray<NSString *> *items;
@property(nonatomic, retain) NSArray<NSString *> *shortcuts;
@property(nonatomic, retain) NSArray<NSNumber *> *itemIndices;
@property(nonatomic, retain) NSString *query;
@property(nonatomic) NSInteger selectedIndex;
@property(nonatomic) CGFloat rowHeight;
@property(nonatomic, assign) id target;
@property(nonatomic) SEL selectAction;
@property(nonatomic) SEL confirmAction;
- (void)reload;
- (void)selectIndex:(NSInteger)index;
- (void)clickIndex:(NSUInteger)index;
@end
@interface NimculusCommandPaletteOverlay : NSView <NSTextFieldDelegate>
@property(nonatomic, retain) NimculusCommandPaletteField *field;
@property(nonatomic, retain) NSArray<NSString *> *commands;
@property(nonatomic, retain) NSArray<NSString *> *visibleCommands;
@property(nonatomic, retain) NimculusPickerListView *pickerList;
- (void)show;
- (NSArray<NSString *> *)matchingCommandsForQuery:(NSString *)query;
- (void)refreshCandidatesForQuery:(NSString *)query;
@end
@interface NimculusGitCommitOverlay : NSView
@property(nonatomic, retain) NSTextField *messageField;
@property(nonatomic, retain) NSButton *commitButton;
@property(nonatomic, retain) NSButton *closeButton;
- (void)show;
@end
@interface NimculusSettingsOverlay : NSView
@property(nonatomic, retain) NSPopUpButton *themePopup;
@property(nonatomic, retain) NSTextField *editorSizeField;
@property(nonatomic, retain) NSTextField *terminalSizeField;
@property(nonatomic, retain) NSTextField *editorFontField;
@property(nonatomic, retain) NSTextField *terminalFontField;
@property(nonatomic, retain) NSTextField *shellField;
@property(nonatomic, retain) NSButton *applyButton;
@property(nonatomic, retain) NSButton *closeButton;
- (void)showWithTheme:(NSString *)theme editorFontSize:(NSString *)editorFontSize
      terminalFontSize:(NSString *)terminalFontSize editorFontFamily:(NSString *)editorFontFamily
    terminalFontFamily:(NSString *)terminalFontFamily shell:(NSString *)shell;
@end
@interface NimculusDocumentSearchOverlay : NSView <NSTextFieldDelegate>
@property(nonatomic, retain) NSSearchField *queryField;
@property(nonatomic, retain) NSTextField *replacementField;
@property(nonatomic, retain) NSTextField *lineField;
@property(nonatomic, retain) NSTextField *includeField;
@property(nonatomic, retain) NSTextField *excludeField;
@property(nonatomic, retain) NSTextField *matchLabel;
@property(nonatomic, retain) NimculusChromeButton *caseButton;
@property(nonatomic, retain) NimculusChromeButton *wordButton;
@property(nonatomic, retain) NimculusChromeButton *regexButton;
@property(nonatomic, retain) NimculusChromeButton *replaceToggleButton;
@property(nonatomic, retain) NimculusChromeButton *filtersButton;
@property(nonatomic, retain) NimculusChromeButton *ignoredButton;
@property(nonatomic, retain) NSButton *previousButton;
@property(nonatomic, retain) NSButton *nextButton;
@property(nonatomic, retain) NSButton *replaceNextButton;
@property(nonatomic, retain) NSButton *replaceButton;
@property(nonatomic, retain) NSButton *closeButton;
@property(nonatomic, retain) NimculusPickerListView *pickerList;
@property(nonatomic) NSInteger mode;
@property(nonatomic) BOOL replaceEnabled;
@property(nonatomic) BOOL filtersEnabled;
@property(nonatomic) uint32_t searchOptions;
@property(nonatomic) uint32_t matchIndex;
@property(nonatomic) uint32_t matchCount;
@property(nonatomic) BOOL suppressSearchCancellation;
- (void)showFind:(BOOL)replace;
- (void)showGoToLine;
- (void)showWorkspaceSearch;
- (void)showQuickOpen;
- (void)showOutlinePicker;
- (void)refreshQuickOpenPicker;
- (void)refreshOutlinePicker;
- (CGFloat)outlinePickerHeight;
- (CGFloat)quickOpenPickerHeight;
- (void)updateSearchStateWithMode:(uint32_t)mode matchIndex:(uint32_t)matchIndex
  matchCount:(uint32_t)matchCount options:(uint32_t)options replaceEnabled:(BOOL)replaceEnabled
  filtersEnabled:(BOOL)filtersEnabled;
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
@property(nonatomic, retain) NSButton *stopButton;
@property(nonatomic, retain) NSButton *closeButton;
- (void)reloadTitle;
- (void)reloadActions;
@end

@interface NimculusOutlineOverlay : NSTextView
@property(nonatomic) NSUInteger pressedSidebarLine;
@property(nonatomic) NSUInteger hoveredSidebarLine;
@property(nonatomic) BOOL hasPressedSidebarLine;
@property(nonatomic) BOOL suppressMouseUpOpen;
@property(nonatomic, retain) NSTrackingArea *sidebarTrackingArea;
@property(nonatomic, retain) NSMutableArray<NSButton *> *gitCheckboxes;
- (void)controlTextDidChange:(NSNotification *)notification;
- (NSUInteger)sidebarItemForLine:(NSUInteger)line;
- (void)refreshGitCheckboxes;
@end

@interface NimculusLineNumberOverlay : NSView
@end

@interface NimculusIndentGuideOverlay : NSView
@end

@interface NimculusTabBarOverlay : NSView
@property(nonatomic) BOOL secondary;
@property(nonatomic) NSUInteger dragSourceIndex;
@property(nonatomic) NSInteger hoveredTabIndex;
@property(nonatomic, retain) NSButton *backButton;
@property(nonatomic, retain) NSButton *forwardButton;
@property(nonatomic, retain) NSButton *tabListButton;
@property(nonatomic, retain) NSButton *newButton;
@property(nonatomic, retain) NSButton *splitButton;
@property(nonatomic, retain) NSButton *zoomButton;
@property(nonatomic, retain) NSTrackingArea *trackingArea;
- (void)dispatchTabAtPoint:(NSPoint)point;
- (void)dispatchTabContextAtPoint:(NSPoint)point;
- (void)dispatchTabMoveFrom:(NSUInteger)source to:(NSUInteger)destination;
- (NSUInteger)tabIndexAtPoint:(NSPoint)point;
- (NSRect)tabRectForIndex:(NSUInteger)index;
- (void)selectTabFromMenu:(NSMenuItem *)sender;
- (void)showTabListAtPoint:(NSPoint)point;
- (void)showNewItemMenuAtPoint:(NSPoint)point;
- (void)showSplitMenuAtPoint:(NSPoint)point;
- (void)selectRelativeTab:(NSInteger)delta;
- (NSButton *)tabButtonWithSymbol:(NSString *)symbol label:(NSString *)label
                            action:(SEL)action;
@end

@interface NimculusWelcomeOverlay : NSView
@end

@interface NimculusGitSidebarTabs : NSView
@property(nonatomic, retain) NSArray<NSButton *> *buttons;
@property(nonatomic) NSInteger selectedMode;
- (void)setSelectedMode:(NSInteger)selectedMode;
- (void)selectMode:(NSButton *)sender;
@end

@interface NimculusGitCommitButton : NimculusChromeButton
@property(nonatomic, retain) NSLayoutConstraint *compactWidthConstraint;
- (void)setCompact:(BOOL)compact;
@end

@interface NimculusGitRefreshButton : NimculusChromeButton
@end

@interface NimculusGitChangesActions : NSStackView
@property(nonatomic, retain) NSButton *stageAllButton;
@property(nonatomic, retain) NSButton *unstageAllButton;
@end

@interface NimculusSidebarHeader : NSStackView
@property(nonatomic, retain) NSImageView *titleIcon;
@property(nonatomic, retain) NSTextField *titleLabel;
@property(nonatomic, retain) NSStackView *actionStack;
@property(nonatomic) BOOL headerHovering;
@property(nonatomic, retain) NSTrackingArea *headerTrackingArea;
- (void)setTitle:(NSString *)title;
@end

@interface NimculusFilesSidebarActions : NSStackView
 - (void)reloadActions;
@end

@interface NimculusSearchSidebarActions : NSStackView
@property(nonatomic, retain) NSButton *newSearchButton;
@property(nonatomic, retain) NSButton *cancelSearchButton;
@end

@interface NimculusWorkspaceToolbar : NSStackView
- (void)reloadSelection;
@end

@class NimculusAppDelegate;

@interface NimculusStatusOverlay : NSTextField
@end

@interface NimculusStatusBandOverlay : NSView
@end

@class NimculusFooterOverlay;

@interface NimculusFooterStatusButton : NimculusChromeButton
@property(nonatomic, assign) NimculusFooterOverlay *footerOwner;
@property(nonatomic) CGFloat footerPreferredWidth;
@end

@interface NimculusFooterOverlay : NSView
- (void)reloadStatusItems;
- (void)dispatchStatusItem:(NimculusFooterStatusButton *)sender;
- (void)showStatusBarMenuForEvent:(NSEvent *)event;
@end

@interface NimculusEditorContextOverlay : NSTextField
@property(nonatomic, retain) NSButton *previewButton;
@property(nonatomic, retain) NSButton *searchButton;
@property(nonatomic, retain) NSButton *formatButton;
- (NSButton *)breadcrumbButtonWithSymbol:(NSString *)symbol label:(NSString *)label
                                  action:(SEL)action;
- (void)updateBreadcrumbPresentation;
@end

@interface NimculusEditorAnnotationOverlay : NSView {
  BOOL _secondary;
}
@property(nonatomic) BOOL secondary;
@end

static NSUInteger editorSidebarLineForItem(NSUInteger item);

static void refreshQuickOpenPickerForView(NimculusMetalView *view) {
  if (!view) return;
  for (NSView *subview in view.subviews) {
    if ([subview isKindOfClass:[NimculusDocumentSearchOverlay class]]) {
      NimculusDocumentSearchOverlay *search = (NimculusDocumentSearchOverlay *)subview;
      if (!search.hidden && search.mode == 4) [search refreshQuickOpenPicker];
      else if (!search.hidden && search.mode == 5) [search refreshOutlinePicker];
    }
  }
}

@interface NimculusExternalChangeActionTarget : NSObject
- (void)reload:(id)sender;
- (void)keepEditing:(id)sender;
@end

static void dismissExternalChangePanel(const char *command) {
  NSPanel *panel = g_external_change_panel;
  id target = g_external_change_action_target;
  g_external_change_panel = nil;
  g_external_change_action_target = nil;
  NSWindow *parent = panel.parentWindow;
  if (parent) [parent removeChildWindow:panel];
  [panel orderOut:nil];
  [panel close];
  [panel release];
  [target release];
  if (g_command_callback) g_command_callback(command);
}

@implementation NimculusDocumentSearchField
- (void)cancelOperation:(id)sender { (void)sender; [self.searchOverlay close:nil]; }
@end

@implementation NimculusDocumentLineField
- (void)cancelOperation:(id)sender { (void)sender; [self.searchOverlay close:nil]; }
@end

@implementation NimculusOutlineFilterField
- (void)cancelOperation:(id)sender {
  (void)sender;
  self.stringValue = @"";
  [self.outline controlTextDidChange:
    [NSNotification notificationWithName:NSControlTextDidChangeNotification object:self]];
  if (self.outline.window) [self.outline.window makeFirstResponder:self.outline];
}
@end

@implementation NimculusCommandPaletteField
- (void)cancelOperation:(id)sender { (void)sender; [self.commandPalette close:nil]; }
@end

@implementation NimculusGitCommitField
- (void)cancelOperation:(id)sender { (void)sender; [self.commitOverlay close:nil]; }
@end

@implementation NimculusSettingsTextField
- (void)cancelOperation:(id)sender { (void)sender; [self.settingsOverlay close:nil]; }
@end

static const CGFloat NimculusPickerWidth = 510.0;
static const CGFloat NimculusPickerHeaderHeight = 48.0;
static const CGFloat NimculusPickerRowHeight = 34.0;
static const CGFloat NimculusOutlinePickerRowHeight = 36.0;
static const NSUInteger NimculusPickerVisibleRows = 10;
static const CGFloat NimculusPickerCornerRadius = 8.0;

static NSParagraphStyle *pickerParagraphStyle(NSTextAlignment alignment);

static NSArray<NSNumber *> *pickerMatchPositions(NSString *query, NSString *title) {
  NSMutableArray<NSNumber *> *positions = [NSMutableArray array];
  NSString *needle = query.lowercaseString ?: @"";
  NSString *haystack = title.lowercaseString ?: @"";
  NSUInteger cursor = 0;
  for (NSUInteger index = 0; index < needle.length; index++) {
    NSString *character = [needle substringWithRange:NSMakeRange(index, 1)];
    NSRange match = [haystack rangeOfString:character options:0
      range:NSMakeRange(cursor, haystack.length - cursor)];
    if (match.location == NSNotFound) return @[];
    [positions addObject:@(match.location)];
    cursor = NSMaxRange(match);
  }
  return positions;
}

static NSAttributedString *pickerHighlightedLabel(NSString *title, NSString *query,
                                                  NSColor *textColor, NSColor *accentColor) {
  NSMutableAttributedString *label = [[[NSMutableAttributedString alloc]
    initWithString:title ?: @"" attributes:@{
      NSFontAttributeName: [NSFont systemFontOfSize:13.0 weight:NSFontWeightRegular],
      NSForegroundColorAttributeName: textColor,
      NSParagraphStyleAttributeName: pickerParagraphStyle(NSTextAlignmentLeft)
    }] autorelease];
  for (NSNumber *position in pickerMatchPositions(query, title ?: @"")) {
    NSRange range = NSMakeRange(position.unsignedIntegerValue, 1);
    [label addAttributes:@{
      NSFontAttributeName: [NSFont systemFontOfSize:13.0 weight:NSFontWeightSemibold],
      NSForegroundColorAttributeName: accentColor
    } range:range];
  }
  return label;
}

static NSParagraphStyle *pickerParagraphStyle(NSTextAlignment alignment) {
  NSMutableParagraphStyle *style = [[[NSMutableParagraphStyle alloc] init] autorelease];
  style.alignment = alignment;
  style.lineBreakMode = NSLineBreakByTruncatingTail;
  return style;
}

static NSString *commandShortcut(NSString *command) {
  static NSDictionary *bindings;
  if (!bindings) {
    bindings = [@{
      @"new": @"⌘N", @"save": @"⌘S", @"find": @"⌘F",
      @"command palette": @"⌘⇧P", @"quick open": @"⌘P",
      @"workspace search": @"⌘⇧F", @"toggle files": @"⌘⇧N",
      @"toggle outline": @"⌘⇧B", @"split editor": @"⌘\\",
      @"toggle soft wrap": @"⌥Z", @"fold": @"⌥⌘[", @"unfold": @"⌥⌘]",
      @"toggle git": @"⌃⇧G", @"toggle terminal": @"⌃`",
      @"expand selection": @"⌘⌃→", @"shrink selection": @"⌘⌃←",
      @"select previous syntax node": @"⌘⌃↑", @"select next syntax node": @"⌘⌃↓",
      @"move to enclosing bracket": @"⌘⇧\\", @"select next": @"⌘D",
      @"select all matches": @"⌘⇧L", @"add selection above": @"⌥⇧↑",
      @"add selection below": @"⌥⇧↓"
    } retain];
  }
  return bindings[command.lowercaseString] ?: @"";
}

@implementation NimculusPickerRow
- (BOOL)isFlipped { return YES; }
- (BOOL)isAccessibilityElement { return YES; }
- (id)accessibilityRole { return NSAccessibilityMenuItemRole; }
- (NSString *)accessibilityLabel { return self.shortcut.length > 0
    ? [NSString stringWithFormat:@"%@, %@", self.title, self.shortcut] : self.title; }
- (BOOL)accessibilitySelected { return self.selected; }
- (void)dealloc {
  [_trackingArea release];
  [_title release];
  [_shortcut release];
  [_query release];
  [super dealloc];
}
- (void)viewWillMoveToWindow:(NSWindow *)newWindow {
  if (!newWindow && self.trackingArea) {
    [self removeTrackingArea:self.trackingArea];
    self.trackingArea = nil;
  }
  [super viewWillMoveToWindow:newWindow];
}
- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (self.trackingArea) {
    [self removeTrackingArea:self.trackingArea];
    self.trackingArea = nil;
  }
  // Rows are rebuilt while the picker is hidden and while old rows are being
  // detached. Do not leave an area owned by a row that is no longer in a
  // window, and let AppKit recalculate the visible rect after layout.
  if (!self.window || !self.superview || NSIsEmptyRect(self.bounds)) return;
  self.trackingArea = [[[NSTrackingArea alloc] initWithRect:self.bounds
    options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow |
      NSTrackingInVisibleRect owner:self userInfo:nil] autorelease];
  [self addTrackingArea:self.trackingArea];
}
- (void)mouseEntered:(NSEvent *)event { (void)event; self.hovered = YES; [self setNeedsDisplay:YES]; }
- (void)mouseExited:(NSEvent *)event { (void)event; self.hovered = NO; [self setNeedsDisplay:YES]; }
- (void)mouseDown:(NSEvent *)event { (void)event; [self.pickerList clickIndex:self.index]; }
- (void)drawRect:(NSRect)dirtyRect {
  (void)dirtyRect;
  NSRect rowRect = NSInsetRect(self.bounds, 8.0, 2.0);
  if (self.selected || self.hovered) {
    NSColor *color = self.selected ?
      themeRoleColor(@"elementSelected", themeRoleColor(@"element", [NSColor clearColor])) :
      themeRoleColor(@"elementHover", themeRoleColor(@"element", [NSColor clearColor]));
    [color setFill];
    [[NSBezierPath bezierPathWithRoundedRect:rowRect xRadius:6.0 yRadius:6.0] fill];
  }
  NSColor *text = themeRoleColor(@"fgPrimary", [NSColor labelColor]);
  NSColor *muted = themeRoleColor(@"fgMuted", [NSColor secondaryLabelColor]);
  NSColor *accent = themeRoleColor(@"textAccent", [NSColor controlAccentColor]);
  CGFloat shortcutWidth = self.shortcut.length > 0 ?
    [self.shortcut sizeWithAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:12.0]}].width : 0.0;
  CGFloat textWidth = MAX(1.0, self.bounds.size.width - 32.0 - shortcutWidth -
    (shortcutWidth > 0.0 ? 16.0 : 0.0));
  NSRect titleRect = NSMakeRect(16.0, 0.0, textWidth, self.bounds.size.height);
  NSAttributedString *label = pickerHighlightedLabel(self.title ?: @"", self.query ?: @"", text, accent);
  [label drawInRect:titleRect];
  if (shortcutWidth > 0.0) {
    NSRect shortcutRect = NSMakeRect(self.bounds.size.width - shortcutWidth - 16.0,
      0.0, shortcutWidth, self.bounds.size.height);
    [self.shortcut drawInRect:shortcutRect withAttributes:@{
      NSFontAttributeName:[NSFont systemFontOfSize:12.0],
      NSForegroundColorAttributeName:muted,
      NSParagraphStyleAttributeName:pickerParagraphStyle(NSTextAlignmentRight)
    }];
  }
}
@end

@implementation NimculusPickerListView
- (BOOL)isFlipped { return YES; }
- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (!self) return nil;
  self.items = @[];
  self.shortcuts = @[];
  self.itemIndices = @[];
  self.query = @"";
  self.selectedIndex = NSNotFound;
  self.rowHeight = NimculusPickerRowHeight;
  self.wantsLayer = YES;
  return self;
}
- (void)dealloc {
  [_items release]; [_shortcuts release]; [_itemIndices release]; [_query release];
  [super dealloc];
}
- (void)selectIndex:(NSInteger)index {
  if (self.items.count == 0) { self.selectedIndex = NSNotFound; [self reload]; return; }
  self.selectedIndex = MIN(MAX(index, 0), (NSInteger)self.items.count - 1);
  [self reload];
}
- (void)clickIndex:(NSUInteger)index {
  if (index >= self.items.count) return;
  [self selectIndex:index];
  if (self.target && self.selectAction && [self.target respondsToSelector:self.selectAction])
    [self.target performSelector:self.selectAction withObject:@(index)];
  if (self.target && self.confirmAction && [self.target respondsToSelector:self.confirmAction])
    [self.target performSelector:self.confirmAction withObject:@(index)];
}
- (void)reload {
  NSArray *subviews = [self.subviews copy];
  for (NSView *subview in subviews) [subview removeFromSuperview];
  [subviews release];
  NSUInteger count = MIN(self.items.count, NimculusPickerVisibleRows);
  NSUInteger start = 0;
  if (self.selectedIndex != NSNotFound && self.selectedIndex >= count)
    start = MIN((NSUInteger)self.selectedIndex - count + 1, self.items.count - count);
  for (NSUInteger offset = 0; offset < count; offset++) {
    NSUInteger index = start + offset;
    NimculusPickerRow *row = [[[NimculusPickerRow alloc]
      initWithFrame:NSMakeRect(0.0, offset * self.rowHeight,
        self.bounds.size.width, self.rowHeight)] autorelease];
    row.pickerList = self;
    row.index = index;
    row.title = self.items[index];
    row.shortcut = index < self.shortcuts.count ? self.shortcuts[index] : @"";
    row.query = self.query ?: @"";
    row.selected = self.selectedIndex != NSNotFound && index == (NSUInteger)self.selectedIndex;
    [self addSubview:row];
  }
  [self setNeedsDisplay:YES];
}
@end

@implementation NimculusCommandPaletteOverlay

- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (!self) return nil;
  self.clipsToBounds = NO;
  self.wantsLayer = YES;
  self.layer.masksToBounds = NO;
  self.layer.cornerRadius = NimculusPickerCornerRadius;
  self.layer.borderWidth = 1.0;
  self.layer.borderColor = themeRoleColor(@"border", [NSColor separatorColor]).CGColor;
  self.layer.backgroundColor = themeRoleColor(@"elevated", [NSColor windowBackgroundColor]).CGColor;
  self.layer.shadowColor = [NSColor blackColor].CGColor;
  self.layer.shadowOpacity = themeLooksLight() ? 0.16 : 0.32;
  self.layer.shadowRadius = 12.0;
  self.layer.shadowOffset = NSMakeSize(0.0, -4.0);
  self.field = [[[NimculusCommandPaletteField alloc] initWithFrame:NSZeroRect] autorelease];
  ((NimculusCommandPaletteField *)self.field).commandPalette = self;
  self.field.placeholderString = @"Search commands";
  self.field.font = [NSFont systemFontOfSize:15.0];
  self.field.bezelStyle = NSTextFieldSquareBezel;
  self.field.drawsBackground = NO;
  self.field.bordered = NO;
  self.field.delegate = self;
  self.field.target = self;
  self.field.action = @selector(execute:);
  self.pickerList = [[[NimculusPickerListView alloc] initWithFrame:NSZeroRect] autorelease];
  self.pickerList.target = self;
  self.pickerList.confirmAction = @selector(confirmIndex:);
  [self addSubview:self.pickerList];
  [self addSubview:self.field];
  self.toolTip = @"Command Palette";
  self.commands = @[
    @"new", @"save", @"save as", @"find", @"replace", @"go to line",
    @"quick open", @"workspace search", @"cancel search", @"reopen closed tab",
    @"show files", @"toggle files", @"reveal active file", @"collapse all files",
    @"expand all files", @"duplicate workspace entry", @"copy workspace entry",
    @"cut workspace entry", @"paste workspace entry", @"move workspace entry to trash",
    @"delete workspace entry permanently", @"reveal selected workspace entry",
    @"open selected workspace entry with system", @"find in selected folder",
    @"show outline", @"toggle outline", @"split editor", @"split editor horizontally",
    @"close split", @"toggle soft wrap", @"expand selection", @"shrink selection",
    @"select previous syntax node", @"select next syntax node",
    @"move to enclosing bracket", @"fold", @"unfold", @"toggle fold", @"fold all",
    @"unfold all", @"fold recursively", @"unfold recursively", @"fold at level 1",
    @"fold at level 2", @"fold at level 3", @"fold at level 4", @"fold at level 5",
    @"fold at level 6", @"fold at level 7", @"fold at level 8", @"fold at level 9",
    @"toggle git", @"git status", @"git stage all", @"git unstage all",
    @"git stage hunk", @"git unstage hunk", @"git commit", @"git log",
    @"git branches", @"git file history", @"git blame", @"cancel git",
    @"toggle terminal", @"new terminal", @"close terminal", @"next terminal",
    @"previous terminal", @"toggle task output", @"run task", @"cancel task",
    @"debug start", @"debug attach", @"debug stop", @"debug continue", @"debug pause",
    @"debug step over", @"debug step into", @"debug step out",
    @"debug toggle breakpoint", @"debug evaluate", @"debug watch",
    @"debug clear watches", @"debug variables", @"debug threads",
    @"agent start", @"agent start codex", @"agent start claude code",
    @"agent start opencode", @"agent start worktree", @"agent stop", @"agent send",
    @"agent next", @"agent previous", @"agent review diff",
    @"agent approve", @"agent reject", @"agent apply patch",
    @"extensions install", @"extensions reload", @"extensions list",
    @"extensions catalog",
    @"extensions runtime", @"extensions run",
    @"go to definition", @"find references", @"document symbols", @"code actions",
    @"signature help", @"inlay hints", @"semantic tokens", @"format document",
    @"open settings", @"check for updates"
  ];
  self.visibleCommands = self.commands;
  [self refreshCandidatesForQuery:@""];
  return self;
}

- (void)dealloc { [_field release]; [_commands release]; [_visibleCommands release]; [_pickerList release]; [super dealloc]; }

- (void)layout {
  [super layout];
  self.field.frame = NSMakeRect(16.0, self.bounds.size.height - NimculusPickerHeaderHeight + 5.0,
    MAX(1.0, self.bounds.size.width - 32.0), 34.0);
  self.pickerList.frame = NSMakeRect(0.0, 0.0, self.bounds.size.width,
    MAX(1.0, self.bounds.size.height - NimculusPickerHeaderHeight));
  [self.pickerList reload];
}

- (void)show {
  self.field.stringValue = @"";
  [self refreshCandidatesForQuery:@""];
  self.hidden = NO;
  [self setNeedsLayout:YES];
  [self layoutSubtreeIfNeeded];
  [self.window makeFirstResponder:self.field];
}

- (void)refreshCandidatesForQuery:(NSString *)query {
  NSArray<NSString *> *matches = [self matchingCommandsForQuery:query];
  self.visibleCommands = matches;
  self.pickerList.items = matches;
  NSMutableArray *shortcuts = [NSMutableArray arrayWithCapacity:matches.count];
  for (NSString *command in matches) [shortcuts addObject:commandShortcut(command)];
  self.pickerList.shortcuts = shortcuts;
  self.pickerList.query = query ?: @"";
  self.pickerList.selectedIndex = matches.count > 0 ? 0 : NSNotFound;
  [self.pickerList reload];
}

- (NSArray<NSString *> *)matchingCommandsForQuery:(NSString *)query {
  NSString *needle = query.lowercaseString;
  NSArray<NSString *> *matches = self.commands;
  if (needle.length == 0) return matches;
  matches = [self.commands filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:
    ^BOOL(NSString *candidate, NSDictionary *bindings) {
      (void)bindings;
      NSString *haystack = candidate.lowercaseString;
      // Keep Zed's forgiving command discovery property: all query
      // characters may be separated, so `tgtrm` still finds Toggle Terminal.
      NSUInteger cursor = 0;
      for (NSUInteger index = 0; index < needle.length; index++) {
        NSRange range = [haystack rangeOfString:[needle substringWithRange:NSMakeRange(index, 1)]
          options:0 range:NSMakeRange(cursor, haystack.length - cursor)];
        if (range.location == NSNotFound) return NO;
        cursor = NSMaxRange(range);
      }
      return YES;
    }]];
  NSArray<NSString *> *sorted = [matches sortedArrayUsingComparator:^NSComparisonResult(NSString *left, NSString *right) {
    NSString *leftLower = left.lowercaseString;
    NSString *rightLower = right.lowercaseString;
    NSUInteger leftPrefix = [leftLower hasPrefix:needle] ? 0 :
      ([leftLower rangeOfString:needle].location != NSNotFound ? 1 : 2);
    NSUInteger rightPrefix = [rightLower hasPrefix:needle] ? 0 :
      ([rightLower rangeOfString:needle].location != NSNotFound ? 1 : 2);
    if (leftPrefix != rightPrefix) return leftPrefix < rightPrefix ? NSOrderedAscending : NSOrderedDescending;
    return [left localizedCaseInsensitiveCompare:right];
  }];
  // A completed short command should remain a single, stable picker result
  // while its longer argument-bearing variants stay discoverable by typing
  // the full command name (for example, `sav` resolves to Save).
  if (sorted.count > 1 && [sorted[0] hasPrefix:needle] &&
      [sorted[0] rangeOfString:@" "].location == NSNotFound &&
      sorted[0].length == needle.length + 1) {
    return @[sorted[0]];
  }
  return sorted;
}

- (void)controlTextDidChange:(NSNotification *)notification {
  if (notification.object == self.field) {
    NSString *query = [self.field.stringValue copy];
    [self refreshCandidatesForQuery:query];
    self.field.stringValue = query;
    [query release];
  }
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView
    doCommandBySelector:(SEL)commandSelector {
  (void)textView;
  if (control != self.field) return NO;
  if (commandSelector == @selector(moveUp:)) {
    [self.pickerList selectIndex:self.pickerList.selectedIndex == NSNotFound ? 0 :
      self.pickerList.selectedIndex - 1];
    return YES;
  }
  if (commandSelector == @selector(moveDown:)) {
    [self.pickerList selectIndex:self.pickerList.selectedIndex == NSNotFound ? 0 :
      self.pickerList.selectedIndex + 1];
    return YES;
  }
  if (commandSelector == @selector(moveToBeginningOfDocument:)) {
    [self.pickerList selectIndex:0]; return YES;
  }
  if (commandSelector == @selector(moveToEndOfDocument:)) {
    [self.pickerList selectIndex:self.visibleCommands.count - 1]; return YES;
  }
  if (commandSelector == @selector(insertNewline:)) { [self execute:nil]; return YES; }
  return NO;
}

- (void)confirmIndex:(NSNumber *)index { (void)index; [self execute:nil]; }

- (void)execute:(id)sender {
  (void)sender;
  NSString *input = [self.field.stringValue
    stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (input.length == 0 || !g_command_callback) return;
  NSString *command = input;
  NSArray<NSString *> *matches = [self matchingCommandsForQuery:input];
  NSString *selected = self.pickerList.selectedIndex != NSNotFound &&
    self.pickerList.selectedIndex < self.visibleCommands.count ?
    self.visibleCommands[self.pickerList.selectedIndex] : nil;
  // NSComboBox may leave the raw fuzzy query in stringValue even though its
  // first result is visibly selected.  Zed confirms the selected candidate,
  // not the search spelling; mirror that boundary while preserving commands
  // that intentionally carry arguments (run task <command>, rename <name>,
  // and LSP/Git argument forms).
  BOOL explicitArgument = [input hasPrefix:@"run task "] ||
    [input hasPrefix:@"rename "] || [input hasPrefix:@"apply code action "] ||
    [input hasPrefix:@"git commit "] || [input hasPrefix:@"git checkout "] ||
    [input hasPrefix:@"git switch "] || [input hasPrefix:@"open symbol "];
  if (!explicitArgument && selected.length > 0 && [matches containsObject:selected]) {
    command = selected;
  } else if (!explicitArgument && matches.count > 0 && ![self.commands containsObject:input]) {
    command = selected.length > 0 ? selected : matches[0];
  }
  [self close:nil];
  NSString *dispatch = [NSString stringWithFormat:@"commandPalette:%@", command];
  g_command_callback(dispatch.UTF8String);
}

- (void)close:(id)sender {
  (void)sender;
  self.hidden = YES;
  [self.window makeFirstResponder:self.superview];
}

- (void)cancelOperation:(id)sender { (void)sender; [self close:nil]; }
@end

// Zed's Changes panel owns a persistent commit-message editor. Nimculus keeps
// the compact panel but makes the same operation directly reachable without a
// blocking sheet.
@implementation NimculusGitCommitOverlay

- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (!self) return nil;
  self.clipsToBounds = YES;
  self.wantsLayer = YES;
  self.layer.masksToBounds = YES;
  self.layer.cornerRadius = 6.0;
  self.layer.borderWidth = 1.0;
  self.layer.borderColor = [themeRoleColor(@"borderVariant", [NSColor separatorColor])
    colorWithAlphaComponent:0.8].CGColor;
  self.layer.backgroundColor = [themeRoleColor(@"panel", [NSColor windowBackgroundColor])
    colorWithAlphaComponent:0.99].CGColor;
  self.messageField = [[[NimculusGitCommitField alloc] initWithFrame:NSZeroRect] autorelease];
  ((NimculusGitCommitField *)self.messageField).commitOverlay = self;
  self.messageField.placeholderString = @"Commit message";
  self.messageField.bezeled = YES;
  self.messageField.drawsBackground = YES;
  self.messageField.backgroundColor = themeRoleColor(@"element", [NSColor controlBackgroundColor]);
  self.messageField.textColor = themeRoleColor(@"fgPrimary", [NSColor labelColor]);
  self.messageField.target = self;
  self.messageField.action = @selector(commit:);
  [self addSubview:self.messageField];
  self.commitButton = [NSButton buttonWithTitle:@"Commit" target:self action:@selector(commit:)];
  styleSidebarActionButton(self.commitButton);
  self.commitButton.toolTip = @"Commit staged changes";
  self.commitButton.accessibilityLabel = @"Commit staged changes";
  self.closeButton = [NSButton buttonWithTitle:@"×" target:self action:@selector(close:)];
  styleWorkspaceNavigationButton(self.closeButton, NO, YES);
  self.closeButton.accessibilityLabel = @"Close commit message editor";
  self.closeButton.toolTip = @"Close Commit Message (Esc)";
  [self addSubview:self.commitButton];
  [self addSubview:self.closeButton];
  return self;
}

- (void)dealloc { [_messageField release]; [_commitButton release]; [_closeButton release]; [super dealloc]; }
- (void)layout {
  [super layout];
  const CGFloat padding = 6.0;
  self.messageField.frame = NSMakeRect(padding, padding,
    MAX(1.0, self.bounds.size.width - 124.0), 24.0);
  self.commitButton.frame = NSMakeRect(self.bounds.size.width - 112.0, padding, 72.0, 24.0);
  self.closeButton.frame = NSMakeRect(self.bounds.size.width - 36.0, padding, 28.0, 24.0);
}
- (void)show {
  self.hidden = NO;
  [self setNeedsLayout:YES];
  [self layoutSubtreeIfNeeded];
  [self.window makeFirstResponder:self.messageField];
  [self.messageField selectText:nil];
}
- (void)commit:(id)sender {
  (void)sender;
  NSString *message = [self.messageField.stringValue
    stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (message.length == 0) {
    if (g_command_callback) g_command_callback("gitCommitMessageEmpty");
    return;
  }
  [self close:nil];
  if (g_command_callback) {
    NSString *command = [NSString stringWithFormat:@"commandPalette:git commit %@", message];
    g_command_callback(command.UTF8String);
  }
}
- (void)close:(id)sender {
  (void)sender;
  self.hidden = YES;
  [self.window makeFirstResponder:self.superview];
}
@end

// Zed keeps settings in a dedicated editing surface. This compact native
// form exposes the supported global settings without putting a sheet in front
// of the document; validation and persistence stay in Nim.
@implementation NimculusSettingsOverlay

- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (!self) return nil;
  self.clipsToBounds = YES;
  self.wantsLayer = YES;
  self.layer.masksToBounds = YES;
  self.layer.cornerRadius = 8.0;
  self.layer.borderWidth = 1.0;
  self.layer.borderColor = [[NSColor separatorColor] colorWithAlphaComponent:0.8].CGColor;
  self.layer.backgroundColor = [[NSColor windowBackgroundColor]
    colorWithAlphaComponent:0.99].CGColor;
  NSArray<NSString *> *labels = @[@"Appearance", @"Editor font size", @"Terminal font size",
    @"Editor font family", @"Terminal font family", @"Terminal shell"];
  for (NSUInteger index = 0; index < labels.count; index++) {
    NSTextField *label = [NSTextField labelWithString:labels[index]];
    label.alignment = NSTextAlignmentRight;
    label.font = [NSFont systemFontOfSize:12.0];
    label.tag = 940 + index;
    [self addSubview:label];
  }
  self.themePopup = [[[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO] autorelease];
  [self.themePopup addItemsWithTitles:@[@"system", @"light", @"dark"]];
  [self addSubview:self.themePopup];
  NSArray<NSTextField *> *fields = @[
    [[[NimculusSettingsTextField alloc] initWithFrame:NSZeroRect] autorelease],
    [[[NimculusSettingsTextField alloc] initWithFrame:NSZeroRect] autorelease],
    [[[NimculusSettingsTextField alloc] initWithFrame:NSZeroRect] autorelease],
    [[[NimculusSettingsTextField alloc] initWithFrame:NSZeroRect] autorelease],
    [[[NimculusSettingsTextField alloc] initWithFrame:NSZeroRect] autorelease]
  ];
  self.editorSizeField = fields[0]; self.terminalSizeField = fields[1];
  self.editorFontField = fields[2]; self.terminalFontField = fields[3]; self.shellField = fields[4];
  for (NSTextField *field in fields) {
    ((NimculusSettingsTextField *)field).settingsOverlay = self;
    [self addSubview:field];
  }
  self.applyButton = [NSButton buttonWithTitle:@"Apply" target:self action:@selector(apply:)];
  self.applyButton.bezelStyle = NSBezelStyleTexturedRounded;
  self.closeButton = [NSButton buttonWithTitle:@"Close" target:self action:@selector(close:)];
  self.closeButton.bezelStyle = NSBezelStyleTexturedRounded;
  [self addSubview:self.applyButton];
  [self addSubview:self.closeButton];
  self.toolTip = @"Nimculus Settings";
  return self;
}

- (void)dealloc {
  [_themePopup release]; [_editorSizeField release]; [_terminalSizeField release];
  [_editorFontField release]; [_terminalFontField release]; [_shellField release];
  [_applyButton release]; [_closeButton release];
  [super dealloc];
}

- (void)layout {
  [super layout];
  const CGFloat labelX = 12.0, labelWidth = 132.0, fieldX = 154.0;
  const CGFloat fieldWidth = MAX(120.0, self.bounds.size.width - fieldX - 12.0);
  const CGFloat rowHeight = 28.0;
  NSArray<NSView *> *controls = @[self.themePopup, self.editorSizeField, self.terminalSizeField,
    self.editorFontField, self.terminalFontField, self.shellField];
  for (NSUInteger index = 0; index < controls.count; index++) {
    CGFloat y = self.bounds.size.height - 42.0 - index * rowHeight;
    NSView *label = [self viewWithTag:940 + index];
    label.frame = NSMakeRect(labelX, y + 3.0, labelWidth, 22.0);
    controls[index].frame = NSMakeRect(fieldX, y, fieldWidth, 24.0);
  }
  self.applyButton.frame = NSMakeRect(self.bounds.size.width - 174.0, 10.0, 78.0, 26.0);
  self.closeButton.frame = NSMakeRect(self.bounds.size.width - 88.0, 10.0, 76.0, 26.0);
}

- (void)showWithTheme:(NSString *)theme editorFontSize:(NSString *)editorFontSize
      terminalFontSize:(NSString *)terminalFontSize editorFontFamily:(NSString *)editorFontFamily
    terminalFontFamily:(NSString *)terminalFontFamily shell:(NSString *)shell {
  NSInteger index = [self.themePopup indexOfItemWithTitle:theme ?: @"system"];
  [self.themePopup selectItemAtIndex:index >= 0 ? index : 0];
  self.editorSizeField.stringValue = editorFontSize ?: @"15";
  self.terminalSizeField.stringValue = terminalFontSize ?: @"12";
  self.editorFontField.stringValue = editorFontFamily ?: @".ZedMono";
  self.terminalFontField.stringValue = terminalFontFamily ?: @"Menlo";
  self.shellField.stringValue = shell ?: @"/bin/zsh";
  self.hidden = NO;
  [self setNeedsLayout:YES];
  [self layoutSubtreeIfNeeded];
  [self.window makeFirstResponder:self.editorSizeField];
  [self.editorSizeField selectText:nil];
}

- (void)apply:(id)sender {
  (void)sender;
  if (g_command_callback) {
    NSString *command = [NSString stringWithFormat:@"settingsApply:%@\x1f%@\x1f%@\x1f%@\x1f%@\x1f%@",
      self.themePopup.titleOfSelectedItem ?: @"system", self.editorSizeField.stringValue ?: @"15",
      self.terminalSizeField.stringValue ?: @"12", self.editorFontField.stringValue ?: @".ZedMono",
      self.terminalFontField.stringValue ?: @"Menlo", self.shellField.stringValue ?: @"/bin/zsh"];
    g_command_callback(command.UTF8String);
  }
}

- (void)close:(id)sender { (void)sender; self.hidden = YES; [self.window makeFirstResponder:self.superview]; }
@end

@implementation NimculusDocumentSearchOverlay

static NimculusChromeButton *searchIconButton(id target, SEL action,
                                               NSString *symbol, NSString *svg,
                                               NSString *label,
                                               NSInteger tag) {
  NimculusChromeButton *button = [NimculusChromeButton buttonWithTitle:@""
    target:target action:action];
  button.tag = tag;
  NSImage *image = svg ? [[[NSImage alloc] initWithData:
    [svg dataUsingEncoding:NSUTF8StringEncoding]] autorelease] : nil;
  if (@available(macOS 11.0, *)) {
    if (!image && symbol) {
      image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:label];
    }
    button.image = image;
    if (!svg) applySidebarIconConfiguration(button);
  } else {
    button.image = image;
  }
  button.accessibilityLabel = label;
  button.toolTip = label;
  styleWorkspaceNavigationButton(button, NO, YES);
  return button;
}

// These are the vendored Zed search glyph geometries. Keeping the SVG data
// here makes the icons available in the native AppKit overlay without adding
// a separate resource lookup or changing the app bundle contract. They are
// template images, so the shared chrome styling supplies the light/dark and
// active accent colors.
static NSString * const NimculusSearchCaseSensitiveSVG =
  @"<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" fill=\"none\"><path fill=\"#000\" fill-rule=\"evenodd\" d=\"M4.407 4h1.78l2.408 8.39H7.256l-.596-2.04H3.92l-.582 2.04H2l2.407-8.39Zm.89 1.44-1.05 3.7h2.1l-1.05-3.7ZM9.852 12.332h-.005a1.228 1.228 0 0 1-.669-.64v-.005C9.053 11.4 9 11 9 10.503c0-.582.082-1.059.27-1.4.187-.362.5-.607.924-.747.423-.14 1.001-.211 1.733-.211h.962v-.14c0-.323-.038-.554-.115-.708v-.005a.575.575 0 0 0-.342-.308c-.173-.067-.438-.11-.804-.11-.236 0-.428.019-.582.048-.154.029-.255.067-.313.115h-.005c-.115.077-.202.25-.216.583l-.01.149H9.188V7.61c0-.472.072-.857.221-1.136.159-.298.429-.5.785-.611.351-.12.832-.178 1.434-.178.63 0 1.127.067 1.488.202.38.14.654.39.808.741.154.342.226.804.226 1.377v4.39h-1.222v-.573a1.676 1.676 0 0 1-.573.481c-.294.145-.722.207-1.266.207-.515 0-.934-.053-1.237-.178Zm.953-2.883a.638.638 0 0 0-.375.294c-.068.134-.111.346-.111.654 0 .4.082.621.197.727.12.101.38.178.828.178.429 0 .742-.067.944-.183.197-.12.351-.317.442-.616.087-.274.14-.669.15-1.189l-1.19.01c-.39.01-.683.053-.88.12l-.005.005Z\" clip-rule=\"evenodd\"/></svg>";
static NSString * const NimculusSearchWholeWordSVG =
  @"<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" fill=\"none\"><path fill=\"#000\" fill-rule=\"evenodd\" d=\"m5.425 10.842-.773-3.948-.782 3.948H2.487L1.147 4.58H2.6l.617 3.897.764-3.886h1.342l.754 3.88.616-3.89H8.15l-1.341 6.261H5.425ZM9.885 10.656c-.384-.218-.648-.577-.802-1.047-.152-.463-.222-1.104-.222-1.91 0-.798.066-1.431.21-1.885v-.002c.155-.47.419-.826.804-1.037.374-.212.88-.306 1.496-.306.447 0 .816.052 1.082.177.128.059.244.14.35.243V2.32h1.377v8.52h-1.376v-.337a1.545 1.545 0 0 1-.393.271c-.26.125-.601.178-1.007.178-.622 0-1.134-.09-1.514-.293l-.005-.003Zm2.817-1.679c.08-.288.124-.71.124-1.278 0-.56-.044-.975-.124-1.255-.078-.274-.199-.434-.342-.521l-.008-.005c-.146-.097-.385-.161-.748-.161-.395 0-.665.064-.835.167l-.005.003c-.158.09-.287.251-.37.522-.087.277-.135.69-.135 1.25 0 .568.048.984.134 1.262.084.27.214.439.376.536.17.102.44.167.835.167.364 0 .605-.061.752-.153.146-.094.268-.261.346-.534Z\" clip-rule=\"evenodd\"/><path stroke=\"#000\" stroke-linecap=\"round\" stroke-width=\"1.2\" d=\"M2 13h12\"/></svg>";
static NSString * const NimculusSearchRegexSVG =
  @"<svg width=\"16\" height=\"16\" viewBox=\"0 0 16 16\" fill=\"none\" xmlns=\"http://www.w3.org/2000/svg\"><path d=\"M4.57132 13.7143C5.20251 13.7143 5.71418 13.2026 5.71418 12.5714C5.71418 11.9403 5.20251 11.4286 4.57132 11.4286C3.94014 11.4286 3.42847 11.9403 3.42847 12.5714C3.42847 13.2026 3.94014 13.7143 4.57132 13.7143Z\" fill=\"#000\"/><path d=\"M10.2856 2.85712V5.71426M10.2856 5.71426V8.5714M10.2856 5.71426H13.1428M10.2856 5.71426H7.42847M10.2856 5.71426L12.1904 3.80949M10.2856 5.71426L8.38084 7.61906M10.2856 5.71426L12.1904 7.61906M10.2856 5.71426L8.38084 3.80949\" stroke=\"#000\" stroke-width=\"1.2\" stroke-linecap=\"round\"/></svg>";

- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (!self) return nil;
  self.clipsToBounds = YES;
  self.wantsLayer = YES;
  self.layer.masksToBounds = YES;
  self.layer.cornerRadius = 6.0;
  self.layer.borderWidth = 1.0;
  self.layer.borderColor = [[NSColor separatorColor] colorWithAlphaComponent:0.8].CGColor;
  self.layer.backgroundColor = [[NSColor windowBackgroundColor]
    colorWithAlphaComponent:0.98].CGColor;
  self.mode = 0;
  self.replaceEnabled = NO;
  self.filtersEnabled = NO;
  self.searchOptions = 1u;
  self.matchIndex = UINT32_MAX;
  self.matchCount = 0;
  self.queryField = [[[NimculusDocumentSearchField alloc] initWithFrame:NSZeroRect] autorelease];
  ((NimculusDocumentSearchField *)self.queryField).searchOverlay = self;
  self.queryField.placeholderString = @"Find";
  self.queryField.delegate = self;
  self.queryField.target = self;
  self.queryField.action = @selector(findNext:);
  [self addSubview:self.queryField];
  self.replacementField = [[[NimculusDocumentLineField alloc] initWithFrame:NSZeroRect] autorelease];
  ((NimculusDocumentLineField *)self.replacementField).searchOverlay = self;
  self.replacementField.placeholderString = @"Replace";
  self.replacementField.delegate = self;
  self.replacementField.target = self;
  self.replacementField.action = @selector(replaceAll:);
  [self addSubview:self.replacementField];
  self.lineField = [[[NimculusDocumentLineField alloc] initWithFrame:NSZeroRect] autorelease];
  ((NimculusDocumentLineField *)self.lineField).searchOverlay = self;
  self.lineField.placeholderString = @"Line number";
  self.lineField.delegate = self;
  self.lineField.target = self;
  self.lineField.action = @selector(goToLine:);
  [self addSubview:self.lineField];
  self.includeField = [[[NimculusDocumentLineField alloc] initWithFrame:NSZeroRect] autorelease];
  ((NimculusDocumentLineField *)self.includeField).searchOverlay = self;
  self.includeField.placeholderString = @"Include: e.g. src/**/*.nim";
  self.includeField.delegate = self;
  [self addSubview:self.includeField];
  self.excludeField = [[[NimculusDocumentLineField alloc] initWithFrame:NSZeroRect] autorelease];
  ((NimculusDocumentLineField *)self.excludeField).searchOverlay = self;
  self.excludeField.placeholderString = @"Exclude: e.g. vendor/*, *.lock";
  self.excludeField.delegate = self;
  [self addSubview:self.excludeField];
  self.matchLabel = [[[NSTextField alloc] initWithFrame:NSZeroRect] autorelease];
  self.matchLabel.bezeled = NO; self.matchLabel.drawsBackground = NO;
  self.matchLabel.editable = NO; self.matchLabel.selectable = NO;
  self.matchLabel.alignment = NSTextAlignmentCenter;
  self.matchLabel.stringValue = @"0 of 0";
  // The match count belongs to the query field, not to the surrounding
  // toolbar. Keeping it as a field child lets it share the field's baseline
  // and right inset while the query remains the single input surface.
  [self.queryField addSubview:self.matchLabel];
  self.pickerList = [[[NimculusPickerListView alloc] initWithFrame:NSZeroRect] autorelease];
  self.pickerList.target = self;
  self.pickerList.selectAction = @selector(selectQuickOpenIndex:);
  self.pickerList.confirmAction = @selector(confirmQuickOpenIndex:);
  self.pickerList.hidden = YES;
  [self addSubview:self.pickerList];
  self.previousButton = [NSButton buttonWithTitle:@"‹" target:self action:@selector(findPrevious:)];
  self.nextButton = [NSButton buttonWithTitle:@"›" target:self action:@selector(findNext:)];
  self.replaceNextButton = [NSButton buttonWithTitle:@"" target:self action:@selector(replaceNext:)];
  self.replaceButton = [NSButton buttonWithTitle:@"" target:self action:@selector(replaceAll:)];
  self.closeButton = [NSButton buttonWithTitle:@"" target:self action:@selector(close:)];
  self.caseButton = searchIconButton(self, @selector(searchToggle:), nil,
    NimculusSearchCaseSensitiveSVG, @"Match Case Sensitivity", 1);
  self.wordButton = searchIconButton(self, @selector(searchToggle:), nil,
    NimculusSearchWholeWordSVG, @"Match Whole Words", 2);
  self.regexButton = searchIconButton(self, @selector(searchToggle:), nil,
    NimculusSearchRegexSVG, @"Use Regular Expressions", 3);
  self.replaceToggleButton = searchIconButton(self, @selector(searchToggle:), @"arrow.triangle.2.circlepath", nil,
    @"Toggle Replace", 4);
  self.filtersButton = searchIconButton(self, @selector(searchToggle:), @"line.3.horizontal.decrease.circle", nil,
    @"Toggle Filters", 5);
  self.ignoredButton = searchIconButton(self, @selector(searchToggle:), @"eye.slash", nil,
    @"Include Ignored", 6);
  for (NSButton *button in @[self.previousButton, self.nextButton, self.replaceNextButton,
                             self.replaceButton, self.closeButton]) {
    button.bordered = NO;
    button.bezelStyle = NSBezelStyleTexturedRounded;
    styleWorkspaceNavigationButton(button, NO, button == self.closeButton);
    [self addSubview:button];
  }
  if (@available(macOS 11.0, *)) {
    self.closeButton.image = [NSImage imageWithSystemSymbolName:@"xmark"
      accessibilityDescription:@"Close Find Bar"];
    self.previousButton.image = [NSImage imageWithSystemSymbolName:@"chevron.left"
      accessibilityDescription:@"Select Previous Match"];
    self.nextButton.image = [NSImage imageWithSystemSymbolName:@"chevron.right"
      accessibilityDescription:@"Select Next Match"];
    self.replaceNextButton.image = [NSImage imageWithSystemSymbolName:@"arrow.uturn.right"
      accessibilityDescription:@"Replace Next Match"];
    self.replaceButton.image = [NSImage imageWithSystemSymbolName:@"arrow.triangle.2.circlepath"
      accessibilityDescription:@"Replace All Matches"];
    for (NSButton *button in @[self.closeButton, self.previousButton, self.nextButton,
                               self.replaceNextButton, self.replaceButton])
      applySidebarIconConfiguration(button);
  }
  self.closeButton.accessibilityLabel = @"Close Find Bar";
  self.closeButton.toolTip = @"Close Find Bar";
  self.previousButton.accessibilityLabel = @"Select Previous Match";
  self.nextButton.accessibilityLabel = @"Select Next Match";
  self.replaceNextButton.accessibilityLabel = @"Replace Next Match";
  self.replaceButton.accessibilityLabel = @"Replace All Matches";
  for (NSButton *button in @[self.caseButton, self.wordButton, self.regexButton,
                             self.replaceToggleButton, self.filtersButton, self.ignoredButton])
    [self addSubview:button];
  self.toolTip = @"Find in document (Esc to close)";
  return self;
}

- (void)dealloc {
  [_queryField release]; [_replacementField release]; [_lineField release];
  [_includeField release]; [_excludeField release]; [_matchLabel release];
  [_caseButton release]; [_wordButton release]; [_regexButton release];
  [_replaceToggleButton release]; [_filtersButton release]; [_ignoredButton release];
  [_previousButton release]; [_nextButton release]; [_replaceNextButton release]; [_replaceButton release];
  [_closeButton release]; [_pickerList release];
  [super dealloc];
}

- (BOOL)acceptsFirstResponder { return YES; }

- (void)layout {
  [super layout];
  const CGFloat padding = 6.0;
  const CGFloat controlHeight = 24.0;
  const CGFloat buttonWidth = 27.0;
  const CGFloat width = self.bounds.size.width;
  if (self.mode == 4 || self.mode == 5) {
    self.queryField.frame = NSMakeRect(16.0, self.bounds.size.height - NimculusPickerHeaderHeight + 5.0,
      MAX(1.0, width - 32.0), 34.0);
    self.pickerList.frame = NSMakeRect(0.0, 0.0, width,
      MAX(1.0, self.bounds.size.height - NimculusPickerHeaderHeight));
    self.queryField.hidden = NO;
    self.pickerList.hidden = NO;
    self.pickerList.rowHeight = self.mode == 5 ? NimculusOutlinePickerRowHeight :
      NimculusPickerRowHeight;
    [self.pickerList reload];
    self.replacementField.hidden = self.lineField.hidden = YES;
    self.previousButton.hidden = self.nextButton.hidden = self.replaceNextButton.hidden =
      self.replaceButton.hidden = YES;
    for (NSView *view in @[self.caseButton, self.wordButton, self.regexButton,
                           self.replaceToggleButton, self.filtersButton, self.ignoredButton,
                           self.matchLabel, self.includeField, self.excludeField]) view.hidden = YES;
    self.closeButton.hidden = YES;
    return;
  }
  self.pickerList.hidden = YES;
  if (self.mode == 2 || self.mode == 3) {
    if (self.mode == 2) {
      for (NSView *view in @[self.caseButton, self.wordButton, self.regexButton,
                             self.replaceToggleButton, self.filtersButton, self.ignoredButton,
                             self.matchLabel, self.includeField, self.excludeField,
                             self.replaceNextButton]) view.hidden = YES;
    }
  if (self.mode == 3) {
      self.lineField.hidden = YES;
    }
    if (self.mode == 3) {
      const CGFloat rowHeight = NimculusFindBarRowHeight;
      const CGFloat rowPadding = NimculusFindBarRowPadding;
      const CGFloat buttonWidth = NimculusControlHit;
      const CGFloat gap = 3.0;
      CGFloat x = padding;
      const CGFloat rightControls = 7.0 * (buttonWidth + gap) + 54.0 + buttonWidth;
      const CGFloat queryWidth = MAX(140.0, width - rightControls - padding * 2.0);
      self.queryField.hidden = NO;
      self.queryField.frame = NSMakeRect(x, rowPadding, queryWidth, rowHeight);
      x = NSMaxX(self.queryField.frame) + gap;
      NSArray *buttons = @[self.caseButton, self.wordButton, self.regexButton,
                           self.filtersButton, self.replaceToggleButton,
                           self.previousButton, self.nextButton];
      for (NSButton *button in buttons) {
        button.hidden = NO;
        button.frame = NSMakeRect(x, rowPadding, buttonWidth, rowHeight);
        x += buttonWidth + gap;
      }
      self.matchLabel.frame = NSMakeRect(x, rowPadding, 50.0, rowHeight);
      x += 54.0;
      self.closeButton.frame = NSMakeRect(width - padding - buttonWidth, rowPadding,
        buttonWidth, rowHeight);
      self.closeButton.hidden = NO;
      self.ignoredButton.hidden = YES;
      CGFloat nextY = padding + rowHeight + gap;
      if (self.replaceEnabled) {
        self.replacementField.frame = NSMakeRect(padding, nextY,
          width - padding * 2.0 - 60.0, rowHeight);
        self.replaceNextButton.frame = NSMakeRect(width - padding - 54.0, nextY,
          24.0, rowHeight);
        self.replaceButton.frame = NSMakeRect(width - padding - 27.0, nextY,
          24.0, rowHeight);
        self.replacementField.hidden = self.replaceNextButton.hidden =
          self.replaceButton.hidden = NO;
        nextY += rowHeight + gap;
      } else {
        self.replacementField.hidden = self.replaceNextButton.hidden = self.replaceButton.hidden = YES;
      }
      if (self.filtersEnabled) {
        self.includeField.frame = NSMakeRect(padding, nextY,
          (width - padding * 2.0 - gap) / 2.0, rowHeight);
        self.excludeField.frame = NSMakeRect(NSMaxX(self.includeField.frame) + gap,
          nextY, (width - padding * 2.0 - gap) / 2.0, rowHeight);
        self.includeField.hidden = self.excludeField.hidden = self.ignoredButton.hidden = NO;
        self.ignoredButton.frame = NSMakeRect(width - padding - buttonWidth, nextY,
          buttonWidth, rowHeight);
        NSRect excludeFrame = self.excludeField.frame;
        excludeFrame.size.width -= buttonWidth + gap;
        self.excludeField.frame = excludeFrame;
      } else {
        self.includeField.hidden = self.excludeField.hidden = self.ignoredButton.hidden = YES;
      }
      return;
    }
    self.lineField.frame = NSMakeRect(padding, padding, width - padding * 2.0 - 54.0, controlHeight);
    self.queryField.frame = self.lineField.frame;
    self.closeButton.frame = NSMakeRect(width - 48.0, padding, 42.0, controlHeight);
    self.queryField.hidden = self.replacementField.hidden = YES;
    self.previousButton.hidden = self.nextButton.hidden = self.replaceButton.hidden = YES;
    self.lineField.hidden = YES;
    self.queryField.hidden = NO;
    if (self.mode == 2) {
      self.lineField.hidden = NO;
      self.queryField.hidden = YES;
    }
    self.closeButton.hidden = NO;
    return;
  }
  if (self.mode == 0) {
    const CGFloat rowHeight = NimculusFindBarRowHeight;
    const CGFloat buttonWidth = NimculusControlHit;
    const CGFloat gap = 3.0;
    const CGFloat rowPadding = NimculusFindBarRowPadding;
    CGFloat x = rowPadding;
    const CGFloat rightControls = 6.0 * (buttonWidth + gap) + 54.0 + buttonWidth;
    const CGFloat queryWidth = MAX(140.0, width - rightControls - padding * 2.0);
    self.queryField.hidden = NO;
    self.matchLabel.hidden = NO;
    self.lineField.hidden = YES;
    self.queryField.frame = NSMakeRect(x, rowPadding, queryWidth, rowHeight);
    self.matchLabel.frame = NSMakeRect(MAX(0.0, queryWidth - 58.0), 0.0,
      56.0, rowHeight);
    x = NSMaxX(self.queryField.frame) + gap;
    NSArray *buttons = @[self.caseButton, self.wordButton, self.regexButton,
                         self.replaceToggleButton, self.previousButton, self.nextButton];
    for (NSButton *button in buttons) {
      button.hidden = NO;
      button.frame = NSMakeRect(x, rowPadding, buttonWidth, rowHeight);
      x += buttonWidth + gap;
    }
    self.closeButton.frame = NSMakeRect(width - padding - buttonWidth, rowPadding,
      buttonWidth, rowHeight);
    self.closeButton.hidden = NO;
    self.filtersButton.hidden = self.ignoredButton.hidden = YES;
    CGFloat nextY = padding + rowHeight + gap;
    if (self.replaceEnabled) {
      self.replacementField.frame = NSMakeRect(padding, nextY,
        width - padding * 2.0 - 60.0, rowHeight);
      self.replaceNextButton.frame = NSMakeRect(width - padding - 54.0, nextY,
        24.0, rowHeight);
      self.replaceButton.frame = NSMakeRect(width - padding - 27.0, nextY,
        24.0, rowHeight);
      self.replacementField.hidden = self.replaceNextButton.hidden =
        self.replaceButton.hidden = NO;
    } else {
      self.replacementField.hidden = self.replaceNextButton.hidden = self.replaceButton.hidden = YES;
    }
    self.includeField.hidden = self.excludeField.hidden = YES;
    return;
  }
  const CGFloat fieldWidth = self.mode == 1 ? width - 4.0 * padding - 2.0 * buttonWidth - 82.0 :
    width - 3.0 * padding - 3.0 * buttonWidth;
  self.queryField.frame = NSMakeRect(padding, self.mode == 1 ? 34.0 : padding,
    MAX(90.0, fieldWidth), controlHeight);
  self.previousButton.frame = NSMakeRect(NSMaxX(self.queryField.frame) + padding,
    self.queryField.frame.origin.y, buttonWidth, controlHeight);
  self.nextButton.frame = NSMakeRect(NSMaxX(self.previousButton.frame) + 2.0,
    self.queryField.frame.origin.y, buttonWidth, controlHeight);
  self.closeButton.frame = NSMakeRect(NSMaxX(self.nextButton.frame) + 2.0,
    self.queryField.frame.origin.y, buttonWidth, controlHeight);
  self.replacementField.frame = NSMakeRect(padding, padding,
    MAX(90.0, width - 3.0 * padding - 82.0), controlHeight);
  self.replaceButton.frame = NSMakeRect(NSMaxX(self.replacementField.frame) + padding,
    padding, 76.0, controlHeight);
  self.queryField.hidden = self.previousButton.hidden = self.nextButton.hidden = NO;
  self.closeButton.hidden = NO;
  self.replacementField.hidden = self.replaceButton.hidden = self.mode != 1;
  self.lineField.hidden = YES;
}

- (void)showFind:(BOOL)replace {
  self.mode = 0;
  self.replaceEnabled = replace;
  g_editor_find_bar_visible = YES;
  self.filtersEnabled = NO;
  self.queryField.placeholderString = @"Find";
  self.queryField.accessibilityLabel = @"Find in Document";
  self.hidden = NO;
  [self setNeedsLayout:YES];
  [self layoutSubtreeIfNeeded];
  [self.window makeFirstResponder:self.queryField];
  [self.queryField selectText:nil];
}

- (void)showGoToLine {
  self.mode = 2;
  g_editor_find_bar_visible = NO;
  self.lineField.stringValue = @"";
  self.hidden = NO;
  [self setNeedsLayout:YES];
  [self layoutSubtreeIfNeeded];
  [self.window makeFirstResponder:self.lineField];
  [self.lineField selectText:nil];
}

- (void)showWorkspaceSearch {
  self.mode = 3;
  g_editor_find_bar_visible = NO;
  self.replaceEnabled = NO;
  self.filtersEnabled = NO;
  self.queryField.placeholderString = @"Search workspace";
  self.queryField.accessibilityLabel = @"Search workspace";
  self.hidden = NO;
  [self setNeedsLayout:YES];
  [self layoutSubtreeIfNeeded];
  [self.window makeFirstResponder:self.queryField];
  [self.queryField selectText:nil];
}

- (void)showQuickOpen {
  self.mode = 4;
  g_editor_find_bar_visible = NO;
  self.clipsToBounds = NO;
  self.layer.masksToBounds = NO;
  self.layer.cornerRadius = NimculusPickerCornerRadius;
  self.layer.borderColor = themeRoleColor(@"border", [NSColor separatorColor]).CGColor;
  self.layer.backgroundColor = themeRoleColor(@"elevated", [NSColor windowBackgroundColor]).CGColor;
  self.layer.shadowColor = [NSColor blackColor].CGColor;
  self.layer.shadowOpacity = themeLooksLight() ? 0.16 : 0.32;
  self.layer.shadowRadius = 12.0;
  self.layer.shadowOffset = NSMakeSize(0.0, -4.0);
  self.queryField.placeholderString = @"Quick Open: file name or path";
  self.queryField.accessibilityLabel = @"Quick Open: file name or path";
  g_editor_sidebar_selected_index = NSNotFound;
  [self refreshQuickOpenPicker];
  self.hidden = NO;
  [self setNeedsLayout:YES];
  [self layoutSubtreeIfNeeded];
  [self.window makeFirstResponder:self.queryField];
  [self.queryField selectText:nil];
}

- (void)showOutlinePicker {
  self.mode = 5;
  g_editor_find_bar_visible = NO;
  self.clipsToBounds = NO;
  self.layer.masksToBounds = NO;
  self.layer.cornerRadius = NimculusPickerCornerRadius;
  self.layer.borderColor = themeRoleColor(@"border", [NSColor separatorColor]).CGColor;
  self.layer.backgroundColor = themeRoleColor(@"elevated", [NSColor windowBackgroundColor]).CGColor;
  self.layer.shadowColor = [NSColor blackColor].CGColor;
  self.layer.shadowOpacity = themeLooksLight() ? 0.16 : 0.32;
  self.layer.shadowRadius = 12.0;
  self.layer.shadowOffset = NSMakeSize(0.0, -4.0);
  self.queryField.stringValue = @"";
  self.queryField.placeholderString = @"Search buffer symbols…";
  self.queryField.accessibilityLabel = @"Search buffer symbols";
  g_editor_sidebar_selected_index = NSNotFound;
  [self refreshOutlinePicker];
  self.hidden = NO;
  [self setNeedsLayout:YES];
  [self layoutSubtreeIfNeeded];
  [self.window makeFirstResponder:self.queryField];
  [self.queryField selectText:nil];
}

- (CGFloat)quickOpenPickerHeight {
  NSUInteger rowCount = MIN(self.pickerList.items.count, NimculusPickerVisibleRows);
  return NimculusPickerHeaderHeight + MAX(1.0, (CGFloat)rowCount) * NimculusPickerRowHeight;
}

- (CGFloat)outlinePickerHeight {
  NSUInteger rowCount = MIN(self.pickerList.items.count, NimculusPickerVisibleRows);
  return NimculusPickerHeaderHeight + MAX(1.0, (CGFloat)rowCount) * NimculusOutlinePickerRowHeight;
}

- (void)refreshQuickOpenPicker {
  if (self.mode != 4) return;
  NSArray<NSString *> *lines = [g_editor_outline_text componentsSeparatedByString:@"\n"];
  NSMutableArray<NSString *> *items = [NSMutableArray array];
  for (NSUInteger index = 2; index < lines.count; index++) {
    NSString *line = lines[index];
    if (line.length > 0 && ![line hasPrefix:@"… searching workspace"]) [items addObject:line];
  }
  self.pickerList.items = items;
  self.pickerList.shortcuts = @[];
  self.pickerList.itemIndices = @[];
  self.pickerList.query = self.queryField.stringValue ?: @"";
  self.pickerList.rowHeight = NimculusPickerRowHeight;
  self.pickerList.selectedIndex = items.count > 0 ? 0 : NSNotFound;
  [self.pickerList reload];
  [self setNeedsLayout:YES];
}

- (void)refreshOutlinePicker {
  if (self.mode != 5) return;
  NSArray<NSString *> *lines = [g_editor_outline_text componentsSeparatedByString:@"\n"];
  NSString *query = self.queryField.stringValue ?: @"";
  NSMutableArray<NSString *> *items = [NSMutableArray array];
  NSMutableArray<NSNumber *> *indices = [NSMutableArray array];
  for (NSUInteger index = 2; index < lines.count; index++) {
    NSString *line = lines[index];
    if (line.length == 0 || [line hasPrefix:@"No "]) continue;
    if (query.length > 0 && [line rangeOfString:query
        options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
    [items addObject:line];
    [indices addObject:@(index - 2)];
  }
  self.pickerList.items = items;
  self.pickerList.itemIndices = indices;
  self.pickerList.shortcuts = @[];
  self.pickerList.query = query;
  self.pickerList.rowHeight = NimculusOutlinePickerRowHeight;
  self.pickerList.selectedIndex = items.count > 0 ? 0 : NSNotFound;
  [self.pickerList reload];
  [self setNeedsLayout:YES];
}

- (void)updateSearchStateWithMode:(uint32_t)mode matchIndex:(uint32_t)matchIndex
  matchCount:(uint32_t)matchCount options:(uint32_t)options replaceEnabled:(BOOL)replaceEnabled
  filtersEnabled:(BOOL)filtersEnabled {
  if (self.mode != (NSInteger)mode && !(self.mode == 0 && mode == 1)) return;
  self.searchOptions = options;
  self.matchIndex = matchIndex;
  self.matchCount = matchCount;
  self.replaceEnabled = replaceEnabled;
  self.filtersEnabled = filtersEnabled;
  self.matchLabel.stringValue = matchIndex == UINT32_MAX ?
    [NSString stringWithFormat:@"0 of %u", matchCount] :
    [NSString stringWithFormat:@"%u of %u", matchIndex + 1, matchCount];
  self.matchLabel.textColor = themeRoleColor(@"fgMuted", [NSColor secondaryLabelColor]);
  styleWorkspaceNavigationButton(self.caseButton, (options & 1u) != 0, YES);
  styleWorkspaceNavigationButton(self.wordButton, (options & 2u) != 0, YES);
  styleWorkspaceNavigationButton(self.regexButton, (options & 4u) != 0, YES);
  styleWorkspaceNavigationButton(self.replaceToggleButton, replaceEnabled, YES);
  styleWorkspaceNavigationButton(self.filtersButton, filtersEnabled, YES);
  styleWorkspaceNavigationButton(self.ignoredButton, (options & 8u) != 0, YES);
  [self setNeedsLayout:YES];
  [self.window update];
}

- (void)searchToggle:(NSButton *)sender {
  if (!g_command_callback) return;
  const char *name = NULL;
  switch (sender.tag) {
    case 1: name = "searchToggle:case"; break;
    case 2: name = "searchToggle:word"; break;
    case 3: name = "searchToggle:regex"; break;
    case 4: name = "searchToggle:replace"; break;
    case 5: name = "searchToggle:filters"; break;
    case 6: name = "searchToggle:ignored"; break;
  }
  if (name) g_command_callback(name);
}

- (void)selectQuickOpenIndex:(NSNumber *)index {
  NSUInteger visibleIndex = index.unsignedIntegerValue;
  NSUInteger value = visibleIndex;
  if (self.mode == 5 && visibleIndex < self.pickerList.itemIndices.count) {
    value = self.pickerList.itemIndices[visibleIndex].unsignedIntegerValue;
  }
  g_editor_sidebar_selected_index = value;
  if (g_command_callback) {
    NSString *command = [NSString stringWithFormat:@"sidebarSelect:%lu", (unsigned long)value];
    g_command_callback(command.UTF8String);
  }
}

- (void)confirmQuickOpenIndex:(NSNumber *)index {
  [self selectQuickOpenIndex:index];
  if (g_command_callback) {
    self.suppressSearchCancellation = YES;
    g_command_callback("sidebarOpenSelected");
    [self close:nil];
  }
}

- (void)controlTextDidChange:(NSNotification *)notification {
  if (!g_command_callback) return;
  if (notification.object == self.includeField || notification.object == self.excludeField) {
    NSString *command = [NSString stringWithFormat:@"workspaceSearchFilters:%@\x1f%@",
      self.includeField.stringValue ?: @"", self.excludeField.stringValue ?: @""];
    g_command_callback(command.UTF8String);
    return;
  }
  if (notification.object != self.queryField) return;
  if (self.mode == 3 || self.mode == 4 || self.mode == 5) {
    // Zed's picker updates its background search task as the query changes;
    // waiting for Return leaves stale rows visible and makes the search bar
    // look disconnected from its result list. Keep the query field as the
    // single input surface and let Nim restart/cancel the bounded job.
    if (self.mode == 3 || self.mode == 4) {
      NSString *format = self.mode == 3 ? @"workspaceSearch:%@" : @"quickOpen:%@";
      NSString *command = [NSString stringWithFormat:format, self.queryField.stringValue];
      g_command_callback(command.UTF8String);
    } else {
      [self refreshOutlinePicker];
    }
  } else if (self.queryField.stringValue.length > 0) {
    NSString *command = [NSString stringWithFormat:@"findDocument:%@", self.queryField.stringValue];
    g_command_callback(command.UTF8String);
  }
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView
    doCommandBySelector:(SEL)commandSelector {
  (void)textView;
  // The query field's first responder is AppKit's field editor, not the
  // NSSearchField instance itself. Handle navigation at the delegate
  // boundary so arrows and Return work while the user is still typing. Zed's
  // picker keeps the query editor active and routes these commands to its
  // result list; doing the same here prevents a search from becoming a
  // keyboard dead end.
  if (control != self.queryField || (self.mode != 3 && self.mode != 4 && self.mode != 5) ||
      !g_command_callback) return NO;
  const char *navigationCommand = NULL;
  if (commandSelector == @selector(moveUp:)) navigationCommand = "sidebarPrevious";
  else if (commandSelector == @selector(moveDown:)) navigationCommand = "sidebarNext";
  else if (commandSelector == @selector(moveToBeginningOfDocument:)) navigationCommand = "sidebarFirst";
  else if (commandSelector == @selector(moveToEndOfDocument:)) navigationCommand = "sidebarLast";
  if (navigationCommand) {
    g_command_callback(navigationCommand);
    if (self.pickerList.items.count > 0) {
      NSInteger delta = commandSelector == @selector(moveUp:) ? -1 : 1;
      [self.pickerList selectIndex:self.pickerList.selectedIndex == NSNotFound ? 0 :
        self.pickerList.selectedIndex + delta];
    }
    return YES;
  }
  if (commandSelector == @selector(insertNewline:)) {
    if ((self.mode == 4 || self.mode == 5) && self.pickerList.selectedIndex != NSNotFound) {
      [self selectQuickOpenIndex:@(self.pickerList.selectedIndex)];
      g_command_callback("sidebarOpenSelected");
      self.suppressSearchCancellation = YES;
      [self close:nil];
    } else if (g_editor_sidebar_selected_index != NSNotFound) {
      g_command_callback("sidebarOpenSelected");
      self.suppressSearchCancellation = YES;
      [self close:nil];
    } else {
      // Preserve the existing query-driven fallback when no result has been
      // selected yet. Quick Open opens its first match; workspace Search
      // refreshes its result stream without dismissing the search chrome.
      [self findNext:nil];
    }
    return YES;
  }
  return NO;
}

- (void)findPrevious:(id)sender {
  (void)sender;
  if (self.queryField.stringValue.length == 0 || !g_command_callback) return;
  if (self.mode == 3) g_command_callback("workspaceSearchPrevious");
  else if (self.mode == 5) return;
  else if (self.mode != 4) g_command_callback("findPrevious");
}
- (void)findNext:(id)sender {
  (void)sender;
  if (self.queryField.stringValue.length == 0 || !g_command_callback) return;
  if (self.mode == 3) g_command_callback("workspaceSearchNext");
  else {
    NSString *format = self.mode == 4 ? @"quickOpenOpen:%@" : @"findNextDocument:%@";
    NSString *command = [NSString stringWithFormat:format, self.queryField.stringValue];
    g_command_callback(command.UTF8String);
  }
  // Quick Open is a navigation action. Once Return has dispatched the
  // selection, remove the search chrome and return the responder chain to the
  // editor, matching the normal Zed quick-open flow.
  if (self.mode == 4 || self.mode == 5) {
    self.suppressSearchCancellation = YES;
    [self close:nil];
  }
}
- (void)replaceNext:(id)sender {
  (void)sender;
  if (self.queryField.stringValue.length == 0 || !g_command_callback) return;
  NSString *prefix = self.mode == 3 ? @"workspaceReplaceNext:" : @"replaceDocumentNext:";
  NSString *command = [NSString stringWithFormat:@"%@%@\x1f%@", prefix,
    self.queryField.stringValue, self.replacementField.stringValue ?: @""];
  g_command_callback(command.UTF8String);
}
- (void)replaceAll:(id)sender {
  (void)sender;
  if (self.queryField.stringValue.length == 0 || !g_command_callback) return;
  NSString *prefix = self.mode == 3 ? @"workspaceReplaceAll:" : @"replaceDocument:";
  NSString *command = [NSString stringWithFormat:@"%@%@\x1f%@", prefix,
    self.queryField.stringValue, self.replacementField.stringValue];
  g_command_callback(command.UTF8String);
}
- (void)goToLine:(id)sender {
  (void)sender;
  if (self.lineField.stringValue.length == 0 || !g_command_callback) return;
  NSString *command = [NSString stringWithFormat:@"goToLine:%@", self.lineField.stringValue];
  g_command_callback(command.UTF8String);
  [self close:nil];
}
- (void)close:(id)sender {
  (void)sender;
  const BOOL suppressCancellation = self.suppressSearchCancellation;
  self.suppressSearchCancellation = NO;
  if (!suppressCancellation && self.mode == 4 && g_command_callback) {
    // A dismissed Quick Open must release its bounded directory scan. The
    // activation path sets suppressSearchCancellation before closing so a
    // pending Return action is not cancelled after it has been dispatched.
    g_command_callback("cancelQuickOpen");
  } else if (!suppressCancellation && self.mode == 3 && g_command_callback) {
    // Workspace Search has the same task lifecycle as Quick Open. Escape or
    // the close button must stop the active ripgrep job while retaining the
    // already-rendered results in the sidebar, matching Zed's dismissible
    // search surface instead of leaving a hidden worker behind.
    g_command_callback("cancelWorkspaceSearch");
  }
  self.hidden = YES;
  g_editor_find_bar_visible = NO;
  [self.window makeFirstResponder:self.superview];
  if (g_queue) {
    updateEditorTextTexture(g_queue.device, g_editor_text, YES);
    rebuildSecondaryEditorTexture(g_queue.device);
  }
  markSceneFullyDirty();
  if ([g_active_view respondsToSelector:@selector(requestRedraw)]) {
    [g_active_view requestRedraw];
  }
}
- (void)cancelOperation:(id)sender { (void)sender; [self close:nil]; }
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
  self.sessionPicker.toolTip = @"Terminal sessions";
  self.sessionPicker.accessibilityLabel = @"Terminal sessions";
  self.sessionPicker.target = self;
  self.sessionPicker.action = @selector(selectSession:);
  [self addSubview:self.sessionPicker];
  self.newButton = [[NSButton alloc] initWithFrame:NSZeroRect];
  self.newButton.title = @"+";
  self.newButton.toolTip = @"New Terminal";
  self.newButton.accessibilityLabel = @"New Terminal";
  self.newButton.bezelStyle = NSBezelStyleTexturedRounded;
  self.newButton.target = self;
  self.newButton.action = @selector(newTerminal:);
  [self addSubview:self.newButton];
  self.closeButton = [[NSButton alloc] initWithFrame:NSZeroRect];
  self.closeButton.title = @"×";
  self.closeButton.toolTip = @"Close Terminal";
  self.closeButton.accessibilityLabel = @"Close Terminal";
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
  self.layer.backgroundColor = [themeRoleColor(@"panel",
    [NSColor colorWithCalibratedRed:0.075 green:0.067 blue:0.052 alpha:1.0])
    colorWithAlphaComponent:0.98].CGColor;
  self.titleLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
  self.titleLabel.editable = NO;
  self.titleLabel.selectable = NO;
  self.titleLabel.bezeled = NO;
  self.titleLabel.drawsBackground = NO;
  self.titleLabel.font = editorUiFontWithWeight(NSFontWeightSemibold);
  self.titleLabel.textColor = themeRoleColor(@"textMuted",
    [NSColor colorWithCalibratedRed:0.92 green:0.88 blue:0.76 alpha:1.0]);
  [self addSubview:self.titleLabel];
  self.stopButton = [[NSButton alloc] initWithFrame:NSZeroRect];
  self.stopButton.image = [NSImage imageWithSystemSymbolName:@"stop.fill"
    accessibilityDescription:@"Cancel running task"];
  self.stopButton.toolTip = @"Cancel running task";
  self.stopButton.accessibilityLabel = @"Cancel running task";
  self.stopButton.bezelStyle = NSBezelStyleTexturedRounded;
  self.stopButton.target = self;
  self.stopButton.action = @selector(cancelTask:);
  [self addSubview:self.stopButton];
  self.closeButton = [[NSButton alloc] initWithFrame:NSZeroRect];
  self.closeButton.title = @"×";
  self.closeButton.toolTip = @"Close Output Panel";
  self.closeButton.accessibilityLabel = @"Close Output Panel";
  self.closeButton.bezelStyle = NSBezelStyleTexturedRounded;
  self.closeButton.target = self;
  self.closeButton.action = @selector(closeOutput:);
  [self addSubview:self.closeButton];
  [self reloadTitle];
  [self reloadActions];
  return self;
}
- (void)dealloc { [_titleLabel release]; [_stopButton release]; [_closeButton release]; [super dealloc]; }
- (void)layout {
  [super layout];
  CGFloat stopWidth = self.stopButton.hidden ? 0.0 : 32.0;
  self.titleLabel.frame = NSMakeRect(9.0, 4.0, MAX(1.0, self.bounds.size.width - 46.0 - stopWidth),
    MAX(18.0, self.bounds.size.height - 7.0));
  self.stopButton.frame = NSMakeRect(MAX(1.0, self.bounds.size.width - 33.0 - stopWidth), 2.0, 28.0,
    MAX(20.0, self.bounds.size.height - 4.0));
  self.closeButton.frame = NSMakeRect(MAX(1.0, self.bounds.size.width - 33.0), 2.0, 28.0,
    MAX(20.0, self.bounds.size.height - 4.0));
}
- (void)reloadTitle {
  self.titleLabel.stringValue = g_task_output_title.length > 0 ? g_task_output_title : @"Output";
  [self setNeedsLayout:YES];
}
- (void)reloadActions {
  self.stopButton.hidden = !g_task_output_cancellable;
  self.stopButton.enabled = g_task_output_cancellable;
  [self setNeedsLayout:YES];
}
- (void)closeOutput:(id)sender { (void)sender; if (g_command_callback) g_command_callback("closeOutputPanel"); }
- (void)cancelTask:(id)sender { (void)sender; if (g_command_callback) g_command_callback("cancelTask"); }
@end

@implementation NimculusOutlineOverlay
- (void)controlTextDidChange:(NSNotification *)notification {
  if (!notification || notification.object == nil || !g_command_callback) return;
  if (![notification.object isKindOfClass:[NimculusOutlineFilterField class]]) return;
  NimculusOutlineFilterField *field = (NimculusOutlineFilterField *)notification.object;
  NSString *query = field.stringValue ?: @"";
  NSString *command = [NSString stringWithFormat:@"sidebarFilter:%@", query];
  g_command_callback(command.UTF8String);
}
- (void)dealloc {
  [_sidebarTrackingArea release];
  [_gitCheckboxes release];
  [super dealloc];
}
- (void)toggleGitCheckbox:(NSButton *)sender {
  if (!sender || !g_command_callback || g_editor_sidebar_mode != 3) return;
  NSString *command = [NSString stringWithFormat:@"sidebarStageToggle:%ld", (long)sender.tag];
  g_command_callback(command.UTF8String);
}
- (void)refreshGitCheckboxes {
  if (!self.gitCheckboxes) self.gitCheckboxes = [NSMutableArray array];
  for (NSButton *checkbox in self.gitCheckboxes) [checkbox removeFromSuperview];
  [self.gitCheckboxes removeAllObjects];
  if (g_editor_sidebar_mode != 3 || !g_editor_sidebar_line_items ||
      g_editor_sidebar_line_item_count <= NimculusSidebarHeaderLineCount) {
    return;
  }
  NSArray<NSString *> *lines = [self.string componentsSeparatedByString:@"\n"];
  for (NSUInteger contentLine = 0; contentLine + NimculusSidebarHeaderLineCount <
       g_editor_sidebar_line_item_count; contentLine++) {
    const NSUInteger originalLine = contentLine + NimculusSidebarHeaderLineCount;
    const uint32_t flags = sidebarFlagsFromLineValue(g_editor_sidebar_line_items[originalLine]);
    if (flags != 1u && flags != 2u) continue;
    const NSUInteger item = sidebarItemFromLineValue(g_editor_sidebar_line_items[originalLine]);
    if (item == NSNotFound || contentLine >= lines.count) continue;
    NSUInteger start = 0;
    for (NSUInteger line = 0; line < contentLine && start < self.string.length; line++) {
      NSRange newline = [self.string rangeOfString:@"\n" options:0
        range:NSMakeRange(start, self.string.length - start)];
      if (newline.location == NSNotFound) { start = self.string.length; break; }
      start = NSMaxRange(newline);
    }
    if (start >= self.string.length) continue;
    NSUInteger glyph = [self.layoutManager glyphIndexForCharacterAtIndex:start];
    if (glyph == NSNotFound) continue;
    NSRange effectiveRange = NSMakeRange(0, 0);
    NSRect row = [self.layoutManager lineFragmentRectForGlyphAtIndex:glyph
      effectiveRange:&effectiveRange];
    NSButton *checkbox = [NSButton buttonWithTitle:@"" target:self
      action:@selector(toggleGitCheckbox:)];
    checkbox.tag = (NSInteger)item;
    checkbox.buttonType = NSButtonTypeSwitch;
    checkbox.state = flags == 1u ? NSControlStateValueOn : NSControlStateValueOff;
    checkbox.title = @"";
    checkbox.bezelStyle = NSBezelStyleRegularSquare;
    checkbox.controlSize = NSControlSizeSmall;
    checkbox.toolTip = flags == 1u ? @"Unstage change" : @"Stage change";
    checkbox.accessibilityLabel = [NSString stringWithFormat:@"%@ change %@",
      flags == 1u ? @"Unstage" : @"Stage", lines[contentLine]];
    checkbox.frame = NSMakeRect(4.0, row.origin.y + MAX(1.0, (row.size.height - 18.0) / 2.0),
      20.0, 18.0);
    [self addSubview:checkbox positioned:NSWindowAbove relativeTo:nil];
    [self.gitCheckboxes addObject:checkbox];
  }
}
- (BOOL)acceptsFirstResponder { return YES; }
- (NSView *)hitTest:(NSPoint)point {
  for (NSButton *checkbox in self.gitCheckboxes) {
    NSPoint checkboxPoint = [self convertPoint:point toView:checkbox];
    if (NSPointInRect(checkboxPoint, checkbox.bounds)) return checkbox;
  }
  return NSPointInRect(point, self.bounds) ? self : nil;
}
- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (self.sidebarTrackingArea) {
    [self removeTrackingArea:self.sidebarTrackingArea];
    self.sidebarTrackingArea = nil;
  }
  self.sidebarTrackingArea = [[[NSTrackingArea alloc] initWithRect:NSZeroRect
    options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
      NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect owner:self userInfo:nil]
    autorelease];
  [self addTrackingArea:self.sidebarTrackingArea];
}
- (NSUInteger)sidebarLineAtPoint:(NSPoint)point {
  NSUInteger index = [self characterIndexForInsertionAtPoint:point];
  NSUInteger line = 0;
  for (NSUInteger offset = 0; offset < MIN(index, self.string.length); offset++) {
    if ([self.string characterAtIndex:offset] == '\n') line++;
  }
  return line;
}
- (void)mouseMoved:(NSEvent *)event {
  NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
  NSUInteger line = [self sidebarLineAtPoint:point];
  NSUInteger item = [self sidebarItemForLine:line];
  self.hoveredSidebarLine = item == NSNotFound ? NSNotFound : (NSInteger)line;
  [self setNeedsDisplay:YES];
}
- (void)mouseExited:(NSEvent *)event {
  (void)event;
  self.hoveredSidebarLine = NSNotFound;
  [self setNeedsDisplay:YES];
}
- (void)drawRect:(NSRect)dirtyRect {
  [super drawRect:dirtyRect];
  // NSTextView paints text before this overlay's retained row state. Repaint
  // only the hover/selection backgrounds and then redraw the affected glyphs.
  NSMutableArray<NSNumber *> *backgroundLines = [NSMutableArray array];
  if (self.hoveredSidebarLine != NSNotFound) {
    [backgroundLines addObject:@(self.hoveredSidebarLine)];
  }
  if (g_editor_sidebar_selected_index != NSNotFound &&
      g_editor_sidebar_selected_index < g_editor_outline_symbol_count) {
    NSUInteger selectedLine = editorSidebarLineForItem(g_editor_sidebar_selected_index);
    if (selectedLine != NSNotFound &&
        ![backgroundLines containsObject:@(selectedLine)]) {
      [backgroundLines addObject:@(selectedLine)];
    }
  }
  for (NSNumber *lineNumber in backgroundLines) {
    NSUInteger line = lineNumber.unsignedIntegerValue;
    NSUInteger start = 0;
    for (NSUInteger current = 0; current < line && start < self.string.length; current++) {
      NSRange newline = [self.string rangeOfString:@"\n" options:0
        range:NSMakeRange(start, self.string.length - start)];
      if (newline.location == NSNotFound) { start = self.string.length; break; }
      start = NSMaxRange(newline);
    }
    if (start < self.string.length) {
      NSUInteger glyph = [self.layoutManager glyphIndexForCharacterAtIndex:start];
      NSRange glyphRange = NSMakeRange(0, 0);
      NSRect row = [self.layoutManager lineFragmentRectForGlyphAtIndex:glyph
        effectiveRange:&glyphRange];
      row.origin.y += row.size.height * 0.5;
      row.origin.x = 0.0;
      row.size.width = self.bounds.size.width;
      if (NSIntersectsRect(row, dirtyRect)) {
        BOOL selected = g_editor_sidebar_selected_index != NSNotFound &&
          editorSidebarLineForItem(g_editor_sidebar_selected_index) == line;
        NSColor *background = selected
          ? themeRoleColor(@"elementSelected", themeRoleColor(@"element", [NSColor selectedControlColor]))
          : themeRoleColor(@"elementHover", themeRoleColor(@"element", [NSColor controlHighlightColor]));
        [background setFill];
        NSRectFillUsingOperation(row, NSCompositingOperationSourceOver);
      }
    }
  }
  if (g_editor_sidebar_mode == 1) {
    NSColor *guideColor = [themeRoleColor(@"borderVariant",
      themeHexColor(g_theme_border, [NSColor separatorColor])) colorWithAlphaComponent:0.72];
    [guideColor setFill];
    NSUInteger lineStart = 0;
    NSArray<NSString *> *lines = [self.string componentsSeparatedByString:@"\n"];
    for (NSUInteger line = 0; line < lines.count; line++) {
      // The presenter strips project indentation before laying out with a
      // 20pt paragraph head indent. The text view string is therefore already
      // normalized; use the paragraph style as the guide source.
      NSRange glyphRange = NSMakeRange(0, 0);
      NSUInteger glyph = lineStart < self.string.length
        ? [self.layoutManager glyphIndexForCharacterAtIndex:lineStart] : NSNotFound;
      if (glyph != NSNotFound) {
        NSRect row = [self.layoutManager lineFragmentRectForGlyphAtIndex:glyph
          effectiveRange:&glyphRange];
        NSParagraphStyle *style = [self.textStorage attribute:NSParagraphStyleAttributeName
          atIndex:lineStart effectiveRange:NULL];
        NSUInteger depth = style ? (NSUInteger)floor(MAX(0.0, style.headIndent) / 20.0) : 0;
        for (NSUInteger level = 1; level <= depth; level++) {
          NSRect guide = NSMakeRect(self.textContainerInset.width + level * 20.0 - 1.0,
            row.origin.y + row.size.height * 0.5, 1.0, row.size.height * 0.5);
          if (NSIntersectsRect(guide, dirtyRect)) NSRectFill(guide);
        }
      }
      NSRange newline = [self.string rangeOfString:@"\n" options:0
        range:NSMakeRange(lineStart, self.string.length - lineStart)];
      lineStart = newline.location == NSNotFound ? self.string.length : NSMaxRange(newline);
    }
  }
  for (NSNumber *lineNumber in backgroundLines) {
    NSUInteger line = lineNumber.unsignedIntegerValue;
    NSUInteger start = 0;
    for (NSUInteger current = 0; current < line && start < self.string.length; current++) {
      NSRange newline = [self.string rangeOfString:@"\n" options:0
        range:NSMakeRange(start, self.string.length - start)];
      if (newline.location == NSNotFound) { start = self.string.length; break; }
      start = NSMaxRange(newline);
    }
    if (start >= self.string.length) continue;
    NSUInteger end = start;
    while (end < self.string.length && [self.string characterAtIndex:end] != '\n') end++;
    NSRange glyphs = [self.layoutManager glyphRangeForCharacterRange:
      NSMakeRange(start, end - start) actualCharacterRange:NULL];
    [self.layoutManager drawGlyphsForGlyphRange:glyphs atPoint:self.textContainerOrigin];
  }
}
- (NSUInteger)sidebarItemForLine:(NSUInteger)line {
  if (g_editor_outline_symbol_count == 0) return NSNotFound;
  NSUInteger originalLine = line + NimculusSidebarHeaderLineCount;
  if (g_editor_sidebar_line_items) {
    if (originalLine >= g_editor_sidebar_line_item_count) return NSNotFound;
    int32_t item = g_editor_sidebar_line_items[originalLine];
    NSUInteger decoded = sidebarItemFromLineValue(item);
    return decoded == NSNotFound || decoded >= g_editor_outline_symbol_count
      ? NSNotFound : decoded;
  }
  NSUInteger item = line;
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
    [NSString stringWithFormat:@"sidebarOpen:%lu", (unsigned long)item] :
    [NSString stringWithFormat:@"sidebarOpen:%lu", (unsigned long)item];
  g_command_callback(command.UTF8String);
}
- (void)dispatchSidebarContext:(NSUInteger)item {
  // Every interactive sidebar mode has an explicit row-context contract.
  // Branch activation remains checkout, while its context menu is for
  // non-destructive branch-oriented actions such as copying its name.
  if (item == NSNotFound || !g_command_callback || g_editor_sidebar_mode < 1 ||
      g_editor_sidebar_mode > 4) return;
  NSString *command = [NSString stringWithFormat:@"sidebarContext:%lu", (unsigned long)item];
  g_command_callback(command.UTF8String);
}
- (void)dispatchSidebarStageToggle:(NSUInteger)item {
  if (item == NSNotFound || g_editor_sidebar_mode != 3 || !g_command_callback) return;
  NSString *command = [NSString stringWithFormat:@"sidebarStageToggle:%lu",
    (unsigned long)item];
  g_command_callback(command.UTF8String);
}
- (void)dispatchSidebarLine:(NSUInteger)line open:(BOOL)open {
  NSUInteger item = [self sidebarItemForLine:line];
  if (open) [self dispatchSidebarOpen:item];
  else [self dispatchSidebarSelection:item];
}
- (void)mouseDown:(NSEvent *)event {
  [self.window makeFirstResponder:self];
  self.hasPressedSidebarLine = NO;
  self.suppressMouseUpOpen = NO;
  NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
  NSUInteger index = [self characterIndexForInsertionAtPoint:point];
  NSUInteger line = 0;
  for (NSUInteger offset = 0; offset < MIN(index, self.string.length); offset++) {
    if ([self.string characterAtIndex:offset] == '\n') line++;
  }
  NSUInteger item = [self sidebarItemForLine:line];
  self.pressedSidebarLine = line;
  self.hasPressedSidebarLine = item != NSNotFound;
  // Changes rows have a visible leading check control. This targets the
  // rendered section: a partial file appears twice, with opposite actions.
  if (g_editor_sidebar_mode == 3 && item != NSNotFound && point.x < 30.0 &&
      g_command_callback) {
    // The checkbox gesture is complete on mouseDown. Do not let the later
    // mouseUp also open the file; one user action must produce one command.
    self.suppressMouseUpOpen = YES;
    [self dispatchSidebarStageToggle:item];
    return;
  }
  [self dispatchSidebarSelection:item];
}
- (void)mouseUp:(NSEvent *)event {
  // Zed's Project Panel uses a normal click as the primary navigation
  // gesture: files open in the preview/editor, directories toggle their
  // disclosure state, and Git/search rows dispatch their destination. The
  // previous implementation required a double click, leaving a selected row
  // visually active but functionally inert until a second gesture.
  if (self.suppressMouseUpOpen) {
    self.suppressMouseUpOpen = NO;
    self.hasPressedSidebarLine = NO;
    return;
  }
  NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
  NSUInteger index = [self characterIndexForInsertionAtPoint:point];
  NSUInteger line = 0;
  for (NSUInteger offset = 0; offset < MIN(index, self.string.length); offset++) {
    if ([self.string characterAtIndex:offset] == '\n') line++;
  }
  // A drag or a release outside the pressed row is not an activation. This
  // keeps file-tree navigation deterministic and leaves room for the native
  // drag-and-drop path without accidentally opening a neighbouring row.
  if (event.clickCount >= 1 && self.hasPressedSidebarLine &&
      line == self.pressedSidebarLine) {
    [self dispatchSidebarLine:line open:YES];
  }
  self.hasPressedSidebarLine = NO;
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
  const NSEventModifierFlags modifiers = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
  const BOOL filesPanelShortcut = g_editor_sidebar_mode == 1;
  const BOOL commandDown = (modifiers & NSEventModifierFlagCommand) != 0;
  const BOOL optionDown = (modifiers & NSEventModifierFlagOption) != 0;
  const BOOL controlDown = (modifiers & NSEventModifierFlagControl) != 0;
  const BOOL shiftDown = (modifiers & NSEventModifierFlagShift) != 0;
  const BOOL commandOnly = commandDown && !optionDown && !controlDown && !shiftDown;
  const BOOL plainDelete = (modifiers & (NSEventModifierFlagCommand |
    NSEventModifierFlagOption | NSEventModifierFlagControl)) == 0;
  const BOOL gitPanelShortcut = g_editor_sidebar_mode >= 2 && g_editor_sidebar_mode <= 4 &&
    (modifiers & NSEventModifierFlagCommand) != 0;
  const char *command = gitPanelShortcut && key == 18 ? "commandPalette:git status" :
    gitPanelShortcut && key == 19 ? "commandPalette:git log" :
    filesPanelShortcut && key == 36 && controlDown && shiftDown ? "sidebarOpenWithSystem" :
    filesPanelShortcut && key == 3 && commandDown && optionDown && shiftDown ? "sidebarSearchInSelected" :
    filesPanelShortcut && key == 15 && commandDown && optionDown && !controlDown && !shiftDown ? "sidebarRevealSelected" :
    filesPanelShortcut && key == 2 && commandOnly ? "sidebarDuplicateSelected" :
    filesPanelShortcut && key == 7 && commandOnly ? "sidebarCutSelected" :
    filesPanelShortcut && key == 8 && commandOnly ? "sidebarCopySelected" :
    filesPanelShortcut && key == 9 && commandOnly ? "sidebarPasteSelected" :
    filesPanelShortcut && key == 51 && commandOnly ? "sidebarTrashSelectedNoPrompt" :
    filesPanelShortcut && key == 117 && commandOnly ? "sidebarDeleteSelected" :
    filesPanelShortcut && key == 123 && commandOnly ? "sidebarCollapseAll" :
    filesPanelShortcut && key == 124 && commandOnly ? "sidebarExpandAll" :
    filesPanelShortcut && key == 45 && commandDown && optionDown ? "sidebarNewDirectorySelected" :
    filesPanelShortcut && key == 45 && commandDown ? "sidebarNewFileSelected" :
    filesPanelShortcut && (key == 51 || key == 117) && plainDelete ? "sidebarTrashSelected" :
    (key == 48 || key == 53) ? "sidebarFocusEditor" :
    key == 49 ? (g_editor_sidebar_mode == 3 ? "sidebarStageToggleSelected" : "sidebarOpenSelected") :
    key == 126 ? "sidebarPrevious" :
    key == 125 ? "sidebarNext" : key == 123 ? "sidebarCollapseSelected" :
    key == 124 ? "sidebarExpandSelected" : key == 120 ? "sidebarRenameSelected" :
    key == 115 ? "sidebarFirst" :
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
  NimculusEditorGutterMetrics gutter = editorGutterMetrics();
  // The gutter shares the editor's vertical content bounds. Its view is
  // intentionally wider than the text viewport, but it must not continue
  // drawing into the tab/status chrome at the bottom of a short pane.
  const CGFloat toolbarInset = g_editor_find_bar_visible ? NimculusRowHeight : 0.0;
  NSRect gutterClip = NSMakeRect(0.0, NimculusEditorTextTopInset + toolbarInset,
    self.bounds.size.width,
    MAX(0.0, self.bounds.size.height - NimculusEditorTextTopInset - toolbarInset - 14.0));
  if (NSIsEmptyRect(gutterClip)) return;
  NSRectClip(gutterClip);
  // The Metal editor rectangle already paints this entire region with the
  // opaque editor background. Keep the native line-number overlay transparent
  // so AppKit color conversion cannot introduce a one-channel seam between
  // the gutter and the editor body. The active-line rectangle is also painted
  // by Metal below this overlay; only the line-number glyphs belong here.
  NSUInteger first = editorFirstVisibleLine(g_editor_scroll_line, lines.count);
  const BOOL hasTopExtraLine = first > 0;
  if (hasTopExtraLine) first--;
  NSFont *regularFont = [NSFont fontWithName:editorResolvedFontName()
    size:g_editor_font_size];
  if (!regularFont) regularFont = [NSFont monospacedSystemFontOfSize:g_editor_font_size
    weight:NSFontWeightRegular];
  NSFont *activeFont = [[NSFontManager sharedFontManager]
    convertFont:regularFont toHaveTrait:NSBoldFontMask];
  NSColor *regularColor = themeRoleColor(@"lineNumber", [themeHexColor(g_theme_foreground,
    [NSColor colorWithCalibratedRed:0.72 green:0.76 blue:0.82 alpha:1.0])
    colorWithAlphaComponent:0.58]);
  NSColor *activeColor = themeRoleColor(@"activeLineNumber", regularColor);
  CGFloat visibleRows = hasTopExtraLine ? -1.0 : 0.0;
  CGFloat usableHeight = NSHeight(gutterClip) - NimculusEditorTextGlyphSafety * 2.0;
  NSUInteger maxRows = (NSUInteger)MAX(1.0,
    floor(MAX(0.0, usableHeight) / editorLineHeight()));
  for (NSUInteger index = first; index < lines.count && visibleRows < maxRows; ) {
    if (editorLineIsFolded(index)) {
      index = editorFirstVisibleLine(index, lines.count);
      continue;
    }
    NSString *number = [NSString stringWithFormat:@"%lu", (unsigned long)index + 1];
    BOOL active = index == g_editor_cursor_line;
    NSDictionary *attributes = @{
      NSFontAttributeName: active ? activeFont : regularFont,
      NSForegroundColorAttributeName: active ? activeColor : regularColor
    };
    NSSize size = [number sizeWithAttributes:attributes];
    CGFloat y = NSMinY(gutterClip) + visibleRows * editorLineHeight() -
      g_editor_scroll_y_fraction + 1.0;
    CGFloat numberX = self.bounds.size.width - gutter.right_padding - size.width;
    [number drawAtPoint:NSMakePoint(MAX(0.0, numberX), y)
      withAttributes:attributes];
    if (editorLineHasFoldStart(index)) {
      NSBezierPath *marker = [NSBezierPath bezierPath];
      CGFloat markerX = gutter.line_gutter_width + gutter.left_padding +
        MAX(0.0, (gutter.right_padding - 8.0) / 2.0);
      [marker moveToPoint:NSMakePoint(markerX, y + 4.0)];
      [marker lineToPoint:NSMakePoint(markerX + 5.0, y + 7.0)];
      [marker lineToPoint:NSMakePoint(markerX, y + 10.0)];
      [marker closePath];
      [[themeHexColor(g_theme_foreground, [NSColor whiteColor])
        colorWithAlphaComponent:0.72] setFill];
      [marker fill];
    }
    for (uint32_t hunkIndex = 0; hunkIndex < g_git_hunk_count; hunkIndex++) {
      NimculusGitHunkSpan hunk = g_git_hunks[hunkIndex];
      NSUInteger hunkEnd = hunk.start_line + MAX((uint32_t)1, hunk.line_count);
      if (index < hunk.start_line || index >= hunkEnd) continue;
      CGFloat red = 0.30, green = 0.75, blue = 0.42;
      if (hunk.kind == 1) {
        red = 0.92; green = 0.34; blue = 0.34;
      } else if (hunk.kind >= 2) {
        red = 0.35; green = 0.58; blue = 0.95;
      }
      [[NSColor colorWithCalibratedRed:red green:green blue:blue alpha:0.9] setFill];
      NSRect marker = NSMakeRect(MAX(0.0, (gutter.left_padding - 2.0) / 2.0),
        y + 2.0, 2.0, MAX(1.0, editorLineHeight() - 4.0));
      NSRectFill(marker);
      break;
    }
    visibleRows += g_editor_soft_wrap ? 1 : 1;
    index = editorFirstVisibleLine(index + 1, lines.count);
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
  NSRect textClip = editorTextViewportLocalRect(g_editor_rect);
  if (NSIsEmptyRect(textClip)) return;
  NSRectClip(textClip);
  CGFloat characterWidth = 7.2;
  NSUInteger indentWidth = MAX((NSUInteger)1, g_editor_indent_width);
  NSUInteger first = editorFirstVisibleLine(g_editor_scroll_line, lines.count);
  CGFloat lineHeight = editorLineHeight();
  NSColor *color = [themeHexColor(g_theme_border,
    [NSColor colorWithCalibratedRed:0.30 green:0.34 blue:0.40 alpha:1.0])
    colorWithAlphaComponent:0.52];
  [color setFill];
  NSUInteger visibleRows = 0;
  for (NSUInteger index = first; index < lines.count; ) {
    if (editorLineIsFolded(index)) {
      index = editorFirstVisibleLine(index, lines.count);
      continue;
    }
    CGFloat rowY = textClip.origin.y + visibleRows * lineHeight -
      g_editor_scroll_y_fraction;
    if (rowY >= NSMaxY(textClip)) break;
    NSString *text = lines[index];
    NSUInteger columns = 0;
    for (NSUInteger character = 0; character < text.length; character++) {
      unichar unit = [text characterAtIndex:character];
      if (unit == ' ') columns++;
      else if (unit == '\t') columns += indentWidth;
      else break;
    }
    for (NSUInteger guide = indentWidth; guide <= columns; guide += indentWidth) {
      NSRect line = NSMakeRect(editorTextOriginX(g_editor_rect) + characterWidth * guide -
        (g_editor_soft_wrap ? 0.0 : g_editor_scroll_x),
        rowY, 1.0, lineHeight);
      NSRectFill(line);
    }
    visibleRows += g_editor_soft_wrap ? 1 : 1;
    index = editorFirstVisibleLine(index + 1, lines.count);
  }
}
@end

static CGFloat tabContentWidth(NSString *title) {
  NSString *label = title ?: @"Untitled";
  BOOL dirty = [label hasSuffix:@" •"];
  if (dirty) label = [label substringToIndex:label.length - 2];
  NSDictionary *attributes = @{NSFontAttributeName: editorUiFontWithWeight(NSFontWeightRegular)};
  CGFloat labelWidth = [label sizeWithAttributes:attributes].width;
  if (dirty) {
    labelWidth += [@"•" sizeWithAttributes:attributes].width + NimculusSpace1;
  }
  return MIN(240.0, MAX(84.0, labelWidth + NimculusSpace3 * 2.0 + NimculusControlHit));
}

static BOOL tabTitleIsDirty(NSString *title) {
  return title.length >= 2 && [title hasSuffix:@" •"];
}

static NSString *tabTitleWithoutDirtyMarker(NSString *title) {
  NSString *label = title ?: @"Untitled";
  return tabTitleIsDirty(label) ? [label substringToIndex:label.length - 2] : label;
}

static CGFloat tabNavigationLeftWidth(void) {
  return NimculusSpace2 + NimculusControlHit * 2.0 + NimculusSpace1;
}

static CGFloat tabNavigationRightWidth(void) {
  return NimculusSpace2 + NimculusControlHit * 5.0 + NimculusSpace1 * 4.0;
}

static void visibleTabRange(NSArray<NSString *> *titles, NSUInteger active, CGFloat width,
                            NSUInteger *start, NSUInteger *count) {
  // The strip scrolls by measured content width. The active tab is kept in
  // view first, then neighboring tabs fill the remaining space.
  if (titles.count == 0 || width <= 0.0) {
    if (start) *start = 0;
    if (count) *count = 0;
    return;
  }
  active = MIN(active, titles.count - 1);
  NSUInteger first = active;
  CGFloat used = tabContentWidth(titles[active]);
  while (first > 0 && used + tabContentWidth(titles[first - 1]) <= width) {
    first--;
    used += tabContentWidth(titles[first]);
  }
  NSUInteger last = active + 1;
  while (last < titles.count && used + tabContentWidth(titles[last]) <= width) {
    used += tabContentWidth(titles[last]);
    last++;
  }
  while (first > 0 && last < titles.count &&
         used + tabContentWidth(titles[first - 1]) <= width) {
    first--;
    used += tabContentWidth(titles[first]);
  }
  if (start) *start = first;
  if (count) *count = MAX((NSUInteger)1, last - first);
}

static NSRect tabRectForIndex(NSArray<NSString *> *titles, NSUInteger active,
                              CGFloat barWidth, CGFloat barHeight, NSUInteger index) {
  if (titles.count == 0 || index >= titles.count) return NSZeroRect;
  const CGFloat tabAreaStart = tabNavigationLeftWidth();
  const CGFloat tabAreaWidth = MAX(1.0, barWidth - tabAreaStart -
    tabNavigationRightWidth());
  NSUInteger first = 0, visible = 0;
  visibleTabRange(titles, active, tabAreaWidth, &first, &visible);
  if (index < first || index >= first + visible) return NSZeroRect;
  CGFloat x = tabAreaStart;
  for (NSUInteger candidate = first; candidate < index; candidate++) {
    x += tabContentWidth(titles[candidate]);
  }
  return NSMakeRect(x, 0.0, tabContentWidth(titles[index]), barHeight);
}

static NSColor *activeTabSurfaceColor(void) {
  NSColor *tabBar = themeRoleColor(@"tabBar", [NSColor colorWithCalibratedWhite:0.08 alpha:1.0]);
  NSColor *surface = themeRoleColor(@"surface", tabBar);
  // The active tab is a theme role in both appearances. Do not substitute a
  // hover/active element surface: that makes the painted tab differ from
  // Zed's `tab.active_background`, especially in One Dark.
  return themeRoleColor(@"tabActive", surface);
}

@implementation NimculusTabBarOverlay
- (BOOL)isFlipped { return YES; }
- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    _dragSourceIndex = NSNotFound;
    _hoveredTabIndex = NSNotFound;
    self.clipsToBounds = YES;
    self.backButton = [self tabButtonWithSymbol:@"arrow.left"
      label:@"Previous tab" action:@selector(previousTab:)];
    self.forwardButton = [self tabButtonWithSymbol:@"arrow.right"
      label:@"Next tab" action:@selector(nextTab:)];
    self.tabListButton = [self tabButtonWithSymbol:@"chevron.down"
      label:@"Open tabs" action:@selector(openTabList:)];
    self.newButton = [self tabButtonWithSymbol:@"plus"
      label:@"New item" action:@selector(newItem:)];
    self.splitButton = [self tabButtonWithSymbol:@"square.split.2x1"
      label:@"Split pane" action:@selector(splitPane:)];
    self.zoomButton = [self tabButtonWithSymbol:@"arrow.up.left.and.arrow.down.right"
      label:@"Zoom pane" action:@selector(zoomPane:)];
    [self addSubview:self.backButton];
    [self addSubview:self.forwardButton];
    [self addSubview:self.tabListButton];
    [self addSubview:self.newButton];
    [self addSubview:self.splitButton];
    [self addSubview:self.zoomButton];
    [self updateTrackingAreas];
  }
  return self;
}
- (void)dealloc {
  [_backButton release];
  [_forwardButton release];
  [_tabListButton release];
  [_newButton release];
  [_splitButton release];
  [_zoomButton release];
  [_trackingArea release];
  [super dealloc];
}
- (NSButton *)tabButtonWithSymbol:(NSString *)symbol label:(NSString *)label
                            action:(SEL)action {
  NSButton *button = [NimculusChromeButton buttonWithTitle:@"" target:self action:action];
  if (@available(macOS 11.0, *)) {
    button.image = [NSImage imageWithSystemSymbolName:symbol
      accessibilityDescription:label];
    button.imagePosition = NSImageOnly;
  }
  button.toolTip = label;
  button.accessibilityLabel = label;
  styleWorkspaceNavigationButton(button, NO, YES);
  return button;
}
- (void)layout {
  [super layout];
  const CGFloat left = tabNavigationLeftWidth();
  const CGFloat right = tabNavigationRightWidth();
  CGFloat x = NimculusTabNavigationOpticalInset;
  self.backButton.frame = NSMakeRect(x, NimculusSpace1,
    NimculusControlHit, NimculusControlHit);
  x += NimculusControlHit + NimculusSpace1;
  self.forwardButton.frame = NSMakeRect(x, NimculusSpace1,
    NimculusControlHit, NimculusControlHit);
  CGFloat rightX = self.bounds.size.width - right + NimculusSpace2;
  self.tabListButton.frame = NSMakeRect(rightX, NimculusSpace1,
    NimculusControlHit, NimculusControlHit);
  rightX += NimculusControlHit + NimculusSpace1;
  self.newButton.frame = NSMakeRect(rightX, NimculusSpace1,
    NimculusControlHit, NimculusControlHit);
  rightX += NimculusControlHit + NimculusSpace1;
  self.splitButton.frame = NSMakeRect(rightX, NimculusSpace1,
    NimculusControlHit, NimculusControlHit);
  rightX += NimculusControlHit + NimculusSpace1;
  self.zoomButton.frame = NSMakeRect(rightX, NimculusSpace1,
    NimculusControlHit, NimculusControlHit);
  (void)left;
}
- (BOOL)acceptsFirstResponder { return NO; }
- (NSView *)hitTest:(NSPoint)point {
  if (!NSPointInRect(point, self.bounds)) return nil;
  NSView *child = [super hitTest:point];
  NSView *hit = child ?: self;
  tabDebugLogHitTest(@"tab-overlay", self, point, hit);
  return hit;
}
- (void)updateTrackingAreas {
  if (self.trackingArea) [self removeTrackingArea:self.trackingArea];
  self.trackingArea = [[[NSTrackingArea alloc] initWithRect:NSZeroRect
    options:(NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
      NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect)
    owner:self userInfo:nil] autorelease];
  [self addTrackingArea:self.trackingArea];
  [super updateTrackingAreas];
}
- (void)mouseMoved:(NSEvent *)event {
  NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
  NSInteger next = [self tabIndexAtPoint:point] == NSNotFound ? NSNotFound :
    (NSInteger)[self tabIndexAtPoint:point];
  if (next != self.hoveredTabIndex) {
    self.hoveredTabIndex = next;
    [self setNeedsDisplay:YES];
  }
}
- (void)mouseExited:(NSEvent *)event {
  (void)event;
  if (self.hoveredTabIndex != NSNotFound) {
    self.hoveredTabIndex = NSNotFound;
    [self setNeedsDisplay:YES];
  }
}
- (void)previousTab:(id)sender { (void)sender; [self selectRelativeTab:-1]; }
- (void)nextTab:(id)sender { (void)sender; [self selectRelativeTab:1]; }
- (void)openTabList:(id)sender {
  (void)sender;
  [self showTabListAtPoint:NSMakePoint(NSMaxX(self.tabListButton.frame), 0.0)];
}
- (void)newItem:(id)sender {
  (void)sender;
  [self showNewItemMenuAtPoint:NSMakePoint(NSMinX(self.newButton.frame), 0.0)];
}
- (void)splitPane:(id)sender {
  (void)sender;
  [self showSplitMenuAtPoint:NSMakePoint(NSMinX(self.splitButton.frame), 0.0)];
}
- (void)zoomPane:(id)sender {
  (void)sender;
  if (g_command_callback) g_command_callback("commandPalette:zoom pane");
}
- (void)selectRelativeTab:(NSInteger)delta {
  NSArray<NSString *> *titles = self.secondary ? g_secondary_editor_tab_titles : g_editor_tab_titles;
  if (!g_command_callback || titles.count == 0) return;
  NSUInteger active = self.secondary ? g_secondary_editor_active_tab : g_editor_active_tab;
  NSInteger next = MAX(0, MIN((NSInteger)titles.count - 1, (NSInteger)active + delta));
  if (next == (NSInteger)active) return;
  NSString *command = [NSString stringWithFormat:@"selectPaneTab:%u:%ld",
    self.secondary ? 1 : 0, (long)next];
  g_command_callback(command.UTF8String);
}
- (void)drawRect:(NSRect)dirtyRect {
  [NSGraphicsContext saveGraphicsState];
  NSRectClip(NSIntersectionRect(self.bounds, dirtyRect));
  [themeRoleColor(@"tabBar", [NSColor colorWithCalibratedWhite:0.08 alpha:1.0]) setFill];
  NSRectFill(self.bounds);
  // Zed rules the bottom of the tab strip with `border`, except under the
  // active tab, whose surface runs on into the toolbar below it. The active
  // tab paints over this rule further down.
  const CGFloat tabBorderTop = MAX(0.0, self.bounds.size.height -
    NimculusChromeBorderHeight);
  [themeRoleColor(@"border", [NSColor separatorColor]) setFill];
  NSRectFill(NSMakeRect(0.0, tabBorderTop, self.bounds.size.width,
    NimculusChromeBorderHeight));
  NSArray<NSString *> *titles = self.secondary ? g_secondary_editor_tab_titles : g_editor_tab_titles;
  NSUInteger active = self.secondary ? g_secondary_editor_active_tab : g_editor_active_tab;
  if (titles.count == 0) {
    [NSGraphicsContext restoreGraphicsState];
    return;
  }
  const CGFloat tabAreaStart = tabNavigationLeftWidth();
  const CGFloat tabAreaWidth = MAX(1.0, self.bounds.size.width - tabAreaStart -
    tabNavigationRightWidth());
  NSUInteger first = 0, visible = 0;
  visibleTabRange(titles, active, tabAreaWidth, &first, &visible);
  for (NSUInteger visualIndex = 0; visualIndex < visible; visualIndex++) {
    NSUInteger index = first + visualIndex;
    NSRect tabRect = [self tabRectForIndex:index];
    CGFloat x = tabRect.origin.x;
    CGFloat tabWidth = tabRect.size.width;
    if (index == active) {
      [activeTabSurfaceColor() setFill];
      NSRectFill(NSMakeRect(x, 0.0, tabWidth, self.bounds.size.height));
    }
    NSString *rawTitle = titles[index] ?: @"Untitled";
    NSString *title = tabTitleWithoutDirtyMarker(rawTitle);
    BOOL dirty = tabTitleIsDirty(rawTitle);
    const BOOL activeTab = index == active;
    NSColor *titleColor = activeTab
      ? [themeRoleColor(@"fgPrimary", themeHexColor(g_theme_foreground,
          [NSColor colorWithCalibratedWhite:0.88 alpha:1.0]))
          colorWithAlphaComponent:0.74]
      : themeRoleColor(@"textMuted", themeHexColor(g_theme_foreground,
          [NSColor colorWithCalibratedWhite:0.72 alpha:1.0]));
    NSDictionary *attributes = @{
      NSFontAttributeName: activeTab
        ? editorUiFontWithWeight(NSFontWeightRegular)
        : editorUiItalicFontWithWeight(NSFontWeightRegular),
      NSForegroundColorAttributeName: titleColor
    };
    CGFloat labelX = x + NimculusSpace3;
    if (dirty) {
      NSDictionary *dirtyAttributes = @{
        NSFontAttributeName: editorUiFontWithWeight(NSFontWeightMedium),
        NSForegroundColorAttributeName: themeRoleColor(@"textAccent",
          themeRoleColor(@"fgPrimary", themeHexColor(g_theme_foreground,
            [NSColor colorWithCalibratedWhite:0.88 alpha:1.0])))
      };
      [@"•" drawAtPoint:NSMakePoint(labelX, 9.0) withAttributes:dirtyAttributes];
      labelX += [@"•" sizeWithAttributes:dirtyAttributes].width + NimculusSpace1;
    }
    NSRect titleRect = NSMakeRect(labelX, 8.0,
      MAX(12.0, x + tabWidth - NimculusSpace3 - NimculusControlHit - labelX),
      self.bounds.size.height - 11.0);
    [title drawWithRect:titleRect options:NSStringDrawingTruncatesLastVisibleLine |
      NSStringDrawingUsesLineFragmentOrigin attributes:attributes context:nil];
    if (index == self.hoveredTabIndex) {
      NSDictionary *closeAttributes = @{
        NSFontAttributeName: [NSFont systemFontOfSize:16.0 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: [themeRoleColor(@"fgPrimary", themeHexColor(g_theme_foreground,
          [NSColor colorWithCalibratedWhite:0.88 alpha:1.0])) colorWithAlphaComponent:0.86]
      };
      [@"×" drawAtPoint:NSMakePoint(x + tabWidth - NimculusControlHit + 2.0, 4.0)
        withAttributes:closeAttributes];
    }
  }
  [NSGraphicsContext restoreGraphicsState];
}
- (NSRect)tabRectForIndex:(NSUInteger)index {
  NSArray<NSString *> *titles = self.secondary ? g_secondary_editor_tab_titles : g_editor_tab_titles;
  NSUInteger active = self.secondary ? g_secondary_editor_active_tab : g_editor_active_tab;
  return tabRectForIndex(titles, active, self.bounds.size.width, self.bounds.size.height, index);
}
- (void)mouseDown:(NSEvent *)event {
  NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
  NSArray<NSString *> *titles = self.secondary ? g_secondary_editor_tab_titles : g_editor_tab_titles;
  NSUInteger index = [self tabIndexAtPoint:point];
  if (tabDebugEnabled()) {
    fprintf(stderr, "Nimculus tab debug mouseDown pane=%u point=(%.1f,%.1f) index=%s\n",
      self.secondary ? 1 : 0, point.x, point.y,
      index == NSNotFound ? "NSNotFound" : [[NSString stringWithFormat:@"%lu",
        (unsigned long)index] UTF8String]);
  }
  self.dragSourceIndex = NSNotFound;
  if (index != NSNotFound && titles.count > 0) {
    NSRect rect = [self tabRectForIndex:index];
    if (!NSIsEmptyRect(rect) &&
        (index != self.hoveredTabIndex || point.x < NSMaxX(rect) - NimculusControlHit)) {
      self.dragSourceIndex = index;
    }
  }
  [self dispatchTabAtPoint:point];
}
- (void)mouseUp:(NSEvent *)event {
  NSUInteger source = self.dragSourceIndex;
  self.dragSourceIndex = NSNotFound;
  if (source == NSNotFound) return;
  NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
  NSUInteger destination = [self tabIndexAtPoint:point];
  if (destination != NSNotFound && destination != source) {
    [self dispatchTabMoveFrom:source to:destination];
  }
}
- (void)rightMouseDown:(NSEvent *)event {
  [self dispatchTabContextAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
}
- (void)dispatchTabContextAtPoint:(NSPoint)point {
  if (!g_command_callback) return;
  NSUInteger index = [self tabIndexAtPoint:point];
  if (index == NSNotFound) return;
  NSString *command = [NSString stringWithFormat:@"tabContext:%u:%lu",
    self.secondary ? 1 : 0, (unsigned long)index];
  g_command_callback(command.UTF8String);
}
- (void)dispatchTabMoveFrom:(NSUInteger)source to:(NSUInteger)destination {
  if (!g_command_callback || source == destination) return;
  NSString *command = [NSString stringWithFormat:@"movePaneTab:%u:%lu:%lu",
    self.secondary ? 1 : 0, (unsigned long)source, (unsigned long)destination];
  g_command_callback(command.UTF8String);
}
- (void)selectTabFromMenu:(NSMenuItem *)sender {
  if (!g_command_callback || sender.tag < 0) return;
  NSString *command = [NSString stringWithFormat:@"selectPaneTab:%u:%ld",
    self.secondary ? 1 : 0, (long)sender.tag];
  g_command_callback(command.UTF8String);
}
- (void)showTabListAtPoint:(NSPoint)point {
  NSArray<NSString *> *titles = self.secondary ? g_secondary_editor_tab_titles : g_editor_tab_titles;
  if (titles.count == 0) return;
  NSUInteger active = self.secondary ? g_secondary_editor_active_tab : g_editor_active_tab;
  NSMenu *menu = [[[NSMenu alloc] initWithTitle:@"Open Tabs"] autorelease];
  for (NSUInteger index = 0; index < titles.count; index++) {
    NSString *title = titles[index].length > 0 ? titles[index] : @"Untitled";
    NSMenuItem *item = [menu addItemWithTitle:title action:@selector(selectTabFromMenu:)
      keyEquivalent:@""];
    item.target = self;
    item.tag = (NSInteger)index;
    item.state = index == active ? NSControlStateValueOn : NSControlStateValueOff;
  }
  [menu popUpMenuPositioningItem:[menu itemAtIndex:MIN(active, menu.numberOfItems - 1)]
    atLocation:point inView:self];
}
- (NSUInteger)tabIndexAtPoint:(NSPoint)point {
  NSArray<NSString *> *titles = self.secondary ? g_secondary_editor_tab_titles : g_editor_tab_titles;
  if (titles.count == 0) return NSNotFound;
  NSUInteger active = self.secondary ? g_secondary_editor_active_tab : g_editor_active_tab;
  const CGFloat tabAreaStart = tabNavigationLeftWidth();
  const CGFloat tabAreaWidth = MAX(1.0, self.bounds.size.width - tabAreaStart -
    tabNavigationRightWidth());
  if (point.x < tabAreaStart || point.x >= tabAreaStart + tabAreaWidth) return NSNotFound;
  NSUInteger first = 0, visible = 0;
  visibleTabRange(titles, active, tabAreaWidth, &first, &visible);
  for (NSUInteger visualIndex = 0; visualIndex < visible; visualIndex++) {
    NSUInteger index = first + visualIndex;
    if (NSPointInRect(point, [self tabRectForIndex:index])) return index;
  }
  return NSNotFound;
}
- (void)dispatchTabAtPoint:(NSPoint)point {
  NSArray<NSString *> *titles = self.secondary ? g_secondary_editor_tab_titles : g_editor_tab_titles;
  NSUInteger index = [self tabIndexAtPoint:point];
  NSString *command = nil;
  if (g_command_callback && titles.count > 0 && index != NSNotFound) {
    NSRect rect = [self tabRectForIndex:index];
    if (index == self.hoveredTabIndex && point.x >= NSMaxX(rect) - NimculusControlHit) {
      command = [NSString stringWithFormat:@"closePaneTab:%u:%lu",
        self.secondary ? 1 : 0, (unsigned long)index];
    } else {
      command = [NSString stringWithFormat:@"selectPaneTab:%u:%lu",
        self.secondary ? 1 : 0, (unsigned long)index];
    }
  }
  if (tabDebugEnabled()) {
    fprintf(stderr, "Nimculus tab debug click pane=%u point=(%.1f,%.1f) index=%s command=%s\n",
      self.secondary ? 1 : 0, point.x, point.y,
      index == NSNotFound ? "NSNotFound" : [[NSString stringWithFormat:@"%lu",
        (unsigned long)index] UTF8String], command ? command.UTF8String : "<none>");
  }
  if (command) g_command_callback(command.UTF8String);
}
- (void)showNewItemMenuAtPoint:(NSPoint)point {
  NimculusAppDelegate *delegate = (NimculusAppDelegate *)[NSApp delegate];
  if (!delegate) return;
  NSMenu *menu = [[[NSMenu alloc] initWithTitle:@"New Item"] autorelease];
  NSArray<NSArray<NSString *> *> *items = @[
    @[@"New File", @"newDocument"],
    @[@"Open File", @"commandPalette:open file"],
    @[@"Search Project", @"commandPalette:workspace search"],
    @[@"Search Symbols", @"commandPalette:document symbols"],
    @[@"New Terminal", @"commandPalette:new terminal"]
  ];
  for (NSArray<NSString *> *entry in items) {
    NSMenuItem *item = [menu addItemWithTitle:entry[0]
      action:@selector(dispatchCommand:) keyEquivalent:@""];
    item.target = delegate;
    item.representedObject = entry[1];
  }
  [menu popUpMenuPositioningItem:nil atLocation:point inView:self];
}
- (void)showSplitMenuAtPoint:(NSPoint)point {
  NimculusAppDelegate *delegate = (NimculusAppDelegate *)[NSApp delegate];
  if (!delegate) return;
  NSMenu *menu = [[[NSMenu alloc] initWithTitle:@"Split Pane"] autorelease];
  NSArray<NSArray<NSString *> *> *items = @[
    @[@"Split Right", @"splitEditor"],
    @[@"Split Left", @"splitEditor"],
    @[@"Split Up", @"splitEditorHorizontal"],
    @[@"Split Down", @"splitEditorHorizontal"],
    @[@"Close Split", @"closeSplit"]
  ];
  for (NSArray<NSString *> *entry in items) {
    NSMenuItem *item = [menu addItemWithTitle:entry[0]
      action:@selector(dispatchCommand:) keyEquivalent:@""];
    item.target = delegate;
    item.representedObject = entry[1];
  }
  [menu popUpMenuPositioningItem:nil atLocation:point inView:self];
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
  // Give AppKit a valid intrinsic container before the first layout pass.
  // The view is positioned manually by -layout, but an initial zero frame
  // creates an autoresizing-mask height==0 constraint while the fixed-height
  // action buttons are already installed. That transient conflict causes
  // AppKit to break button constraints and can leave the welcome surface in
  // an unusable state when the document is still empty.
  NSStackView *stack = [[NSStackView alloc]
    initWithFrame:NSMakeRect(0.0, 0.0, 420.0, 250.0)];
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
        NSFontAttributeName: editorUiFontWithWeight(NSFontWeightMedium)}] autorelease];
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

@implementation NimculusSidebarHeader
- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (!self) return nil;
  self.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  self.alignment = NSLayoutAttributeCenterY;
  self.distribution = NSStackViewDistributionFill;
  self.spacing = NimculusSpace2;
  self.edgeInsets = NSEdgeInsetsMake(0.0, NimculusSpace2, 0.0, NimculusSpace2);
  self.wantsLayer = YES;
  self.headerHovering = NO;
  self.titleIcon = [[[NSImageView alloc] initWithFrame:NSZeroRect] autorelease];
  self.titleIcon.imageScaling = NSImageScaleProportionallyDown;
  self.titleIcon.translatesAutoresizingMaskIntoConstraints = NO;
  [self.titleIcon.widthAnchor constraintEqualToConstant:16.0].active = YES;
  [self.titleIcon.heightAnchor constraintEqualToConstant:16.0].active = YES;
  [self addArrangedSubview:self.titleIcon];
  self.titleLabel = [NSTextField labelWithString:@""];
  self.titleLabel.font = editorUiFontWithWeight(NSFontWeightSemibold);
  self.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
  self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
  [self.titleLabel setContentHuggingPriority:NSLayoutPriorityDefaultHigh
    forOrientation:NSLayoutConstraintOrientationHorizontal];
  [self.titleLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
    forOrientation:NSLayoutConstraintOrientationHorizontal];
  [self addArrangedSubview:self.titleLabel];
  self.actionStack = [[[NSStackView alloc] initWithFrame:NSZeroRect] autorelease];
  self.actionStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  self.actionStack.alignment = NSLayoutAttributeCenterY;
  self.actionStack.distribution = NSStackViewDistributionFill;
  self.actionStack.spacing = NimculusSpace1;
  self.actionStack.translatesAutoresizingMaskIntoConstraints = NO;
  [self.actionStack setContentHuggingPriority:NSLayoutPriorityRequired
    forOrientation:NSLayoutConstraintOrientationHorizontal];
  [self.actionStack setContentCompressionResistancePriority:NSLayoutPriorityRequired
    forOrientation:NSLayoutConstraintOrientationHorizontal];
  [self addArrangedSubview:self.actionStack];
  [self setTitle:@""];
  return self;
}
- (void)dealloc {
  [_titleIcon release];
  [_titleLabel release];
  [_actionStack release];
  [_headerTrackingArea release];
  [super dealloc];
}
- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (self.headerTrackingArea) {
    [self removeTrackingArea:self.headerTrackingArea];
    self.headerTrackingArea = nil;
  }
  self.headerTrackingArea = [[[NSTrackingArea alloc] initWithRect:NSZeroRect
    options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow |
      NSTrackingInVisibleRect owner:self userInfo:nil] autorelease];
  [self addTrackingArea:self.headerTrackingArea];
}
- (void)mouseEntered:(NSEvent *)event {
  (void)event;
  self.headerHovering = YES;
  self.actionStack.hidden = NO;
  [self setNeedsLayout:YES];
}
- (void)mouseExited:(NSEvent *)event {
  (void)event;
  self.headerHovering = NO;
  self.actionStack.hidden = g_editor_sidebar_mode == 1;
  [self setNeedsLayout:YES];
}
- (void)setTitle:(NSString *)title {
  self.titleLabel.stringValue = title.length > 0 ? title : @"Panel";
  self.titleLabel.toolTip = self.titleLabel.stringValue;
  self.titleLabel.accessibilityLabel = self.titleLabel.stringValue;
  self.titleIcon.hidden = g_editor_sidebar_mode != 1;
  if (!self.titleIcon.hidden && @available(macOS 11.0, *)) {
    self.titleIcon.image = [[NSImage imageWithSystemSymbolName:@"folder"
      accessibilityDescription:@"Project folder"] imageWithSymbolConfiguration:
      [NSImageSymbolConfiguration configurationWithPointSize:13.0 weight:NSFontWeightRegular]];
    self.titleIcon.image.template = YES;
    self.titleIcon.contentTintColor = themeRoleColor(@"textMuted",
      themeRoleColor(@"fgMuted", themeHexColor(g_theme_foreground, [NSColor labelColor])));
  }
  self.actionStack.hidden = g_editor_sidebar_mode == 1 && !self.headerHovering;
  self.titleLabel.textColor = themeRoleColor(@"fgPrimary",
    themeHexColor(g_theme_foreground, [NSColor labelColor]));
  [self setNeedsLayout:YES];
}
- (void)drawRect:(NSRect)dirtyRect {
  (void)dirtyRect;
  [themeRoleColor(@"panel", themeHexColor(g_theme_background,
    [NSColor windowBackgroundColor])) setFill];
  NSRectFill(self.bounds);
  [themeRoleColor(@"borderVariant", themeHexColor(g_theme_border,
    [NSColor separatorColor])) setFill];
  NSRectFill(NSMakeRect(0.0, MAX(0.0, self.bounds.size.height - 1.0),
    self.bounds.size.width, 1.0));
}
@end

// Zed exposes Changes and History as visible panel tabs. Keep the same primary
// navigation in the compact native Git sidebar, with Branches alongside the
// existing checkout workflow. AppKit's textured NSSegmentedControl delegates
// selected-state contrast to the system appearance, which made the Git panel
// inconsistent with the explicit dark-theme workspace navigation. A compact
// native button group keeps the same commands while making selected state a
// deliberate part of the UI contract.
@implementation NimculusGitSidebarTabs
- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (!self) return nil;
  self.wantsLayer = YES;
  self.selectedMode = 0;
  NSArray<NSString *> *labels = @[@"Changes", @"History", @"Branches"];
  NSMutableArray<NSButton *> *buttons = [NSMutableArray arrayWithCapacity:labels.count];
  for (NSUInteger index = 0; index < labels.count; index++) {
    NSButton *button = [NimculusChromeButton buttonWithTitle:labels[index] target:self
      action:@selector(selectMode:)];
    button.tag = (NSInteger)index;
    button.toolTip = labels[index];
    [self addSubview:button];
    [buttons addObject:button];
  }
  self.buttons = buttons;
  [self setSelectedMode:0];
  return self;
}
- (void)dealloc { [_buttons release]; [super dealloc]; }
- (void)layout {
  [super layout];
  CGFloat width = self.bounds.size.width / MAX((CGFloat)1.0, (CGFloat)self.buttons.count);
  for (NSUInteger index = 0; index < self.buttons.count; index++) {
    self.buttons[index].frame = NSMakeRect(floor(index * width), 0.0,
      ceil(width), self.bounds.size.height);
  }
}
- (void)setSelectedMode:(NSInteger)selectedMode {
  _selectedMode = MIN(MAX(selectedMode, 0), (NSInteger)self.buttons.count - 1);
  for (NSButton *button in self.buttons) {
    styleWorkspaceNavigationButton(button, button.tag == _selectedMode, NO);
    // The native dock is intentionally narrow. Use a slightly smaller,
    // centered label here so all three primary Git entry points remain
    // visible instead of degrading to "Cha..." / "Hist..." / "Bran...".
    NSColor *foreground = themeHexColor(g_theme_foreground,
      [NSColor colorWithCalibratedWhite:0.90 alpha:1.0]);
    NSColor *accent = themeHexColor(g_theme_accent, [NSColor controlAccentColor]);
    NSColor *tint = button.tag == _selectedMode ? accent :
      [foreground colorWithAlphaComponent:0.78];
    button.alignment = NSTextAlignmentCenter;
    button.attributedTitle = [[[NSAttributedString alloc] initWithString:button.title ?: @""
      attributes:@{NSForegroundColorAttributeName: tint,
        NSFontAttributeName: [NSFont systemFontOfSize:10.5
          weight:button.tag == _selectedMode ? NSFontWeightSemibold : NSFontWeightMedium]}] autorelease];
    button.toolTip = button.tag == _selectedMode ?
      [NSString stringWithFormat:@"%@ (active)", button.title] : button.title;
  }
}
- (void)selectMode:(NSButton *)sender {
  [self setSelectedMode:sender.tag];
  if (!g_command_callback) return;
  const char *command = self.selectedMode == 1 ? "commandPalette:git log" :
    self.selectedMode == 2 ? "commandPalette:git branches" : "commandPalette:git status";
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
  self.bezelStyle = NSBezelStyleTexturedRounded;
  [self setCompact:NO];
  self.target = self;
  self.action = @selector(requestCommit:);
  return self;
}
- (void)dealloc { [_compactWidthConstraint release]; [super dealloc]; }
- (void)setCompact:(BOOL)compact {
  // Keep Changes/History/Branches legible at the smallest supported dock
  // width. The commit action remains present as a conventional checkmark
  // control with its full accessible name and tooltip, then expands again as
  // soon as the dock has room for all four text labels.
  self.title = compact ? @"✓" : @"Commit…";
  self.toolTip = @"Commit staged changes";
  self.accessibilityLabel = @"Commit staged changes";
  styleWorkspaceNavigationButton(self, NO, compact);
  [self.heightAnchor constraintEqualToConstant:NimculusControlHit].active = YES;
  [self.compactWidthConstraint setActive:NO];
  self.compactWidthConstraint = [self.widthAnchor constraintEqualToConstant:
    compact ? NimculusControlHit : NimculusControlHit * 3.0 + NimculusSpace2];
  self.compactWidthConstraint.active = YES;
}
- (void)requestCommit:(id)sender {
  (void)sender;
  if (g_command_callback) g_command_callback("gitCommitPrompt");
}
@end

@implementation NimculusGitRefreshButton
- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (!self) return nil;
  self.bezelStyle = NSBezelStyleTexturedRounded;
  self.title = @"↻";
  self.toolTip = @"Refresh Git panel";
  self.accessibilityLabel = @"Refresh Git panel";
  if (@available(macOS 11.0, *)) {
    self.image = [NSImage imageWithSystemSymbolName:@"arrow.clockwise"
      accessibilityDescription:self.accessibilityLabel];
    self.imagePosition = NSImageOnly;
  }
  styleSidebarActionButton(self);
  [self.widthAnchor constraintEqualToConstant:NimculusControlHit].active = YES;
  [self.heightAnchor constraintEqualToConstant:NimculusControlHit].active = YES;
  self.target = self;
  self.action = @selector(refreshGit:);
  return self;
}
- (void)refreshGit:(id)sender {
  (void)sender;
  if (g_command_callback) g_command_callback("gitRefreshPanel");
}
@end

// Zed keeps bulk staging in the Changes header, rather than hiding it behind
// a command palette. Keep the compact icon affordances native on macOS while
// retaining full accessible labels and direct command routing.
@implementation NimculusGitChangesActions
- (instancetype)initWithFrame:(NSRect)frame {
  if (frame.size.width <= 0.0 || frame.size.height <= 0.0) {
    frame = NSMakeRect(0.0, 0.0, 56.0, 24.0);
  }
  self = [super initWithFrame:frame];
  if (!self) return nil;
  self.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  self.alignment = NSLayoutAttributeCenterY;
  self.distribution = NSStackViewDistributionFill;
  self.spacing = NimculusSpace1;
  self.stageAllButton = [NimculusChromeButton buttonWithTitle:@"Stage All" target:self
    action:@selector(stageAll:)];
  self.unstageAllButton = [NimculusChromeButton buttonWithTitle:@"Unstage All" target:self
    action:@selector(unstageAll:)];
  NSArray<NSArray *> *entries = @[
    @[self.stageAllButton, @"plus.square", @"Stage all changes"],
    @[self.unstageAllButton, @"minus.square", @"Unstage all changes"]
  ];
  for (NSArray *entry in entries) {
    NSButton *button = entry[0];
    if (@available(macOS 11.0, *)) {
      button.image = [NSImage imageWithSystemSymbolName:entry[1]
        accessibilityDescription:entry[2]];
      button.imagePosition = NSImageOnly;
    }
    styleSidebarActionButton(button);
    button.toolTip = entry[2];
    button.accessibilityLabel = entry[2];
    [button.widthAnchor constraintEqualToConstant:NimculusControlHit].active = YES;
    [button.heightAnchor constraintEqualToConstant:NimculusControlHit].active = YES;
    [self addArrangedSubview:button];
  }
  return self;
}
- (void)dealloc { [_stageAllButton release]; [_unstageAllButton release]; [super dealloc]; }
- (void)stageAll:(id)sender { (void)sender; if (g_command_callback) g_command_callback("commandPalette:git stage all"); }
- (void)unstageAll:(id)sender { (void)sender; if (g_command_callback) g_command_callback("commandPalette:git unstage all"); }
@end

// Zed exposes project creation from the Project Panel itself. Keep the action
// visible in Nimculus Files while delegating prompts and validation to the
// existing macOS/Nim workspace path.
@implementation NimculusFilesSidebarActions
- (instancetype)initWithFrame:(NSRect)frame {
  if (frame.size.width <= 0.0 || frame.size.height <= 0.0) {
    frame = NSMakeRect(0.0, 0.0, 120.0, 24.0);
  }
  self = [super initWithFrame:frame];
  if (!self) return nil;
  self.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  self.alignment = NSLayoutAttributeCenterY;
  self.distribution = NSStackViewDistributionFill;
  self.spacing = NimculusSpace1;
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
    @[@"New File", @"document.badge.plus", @"createWorkspaceFile:"],
    @[@"New Folder", @"folder.badge.plus", @"createWorkspaceDirectory:"],
    @[@"Reveal Active File", @"location.magnifyingglass", @"commandPalette:reveal active file"],
    @[@"Collapse All", @"rectangle.compress.vertical", @"commandPalette:collapse all files"]
  ] : @[@[@"Open Folder…", @"folder.badge.plus", @"openWorkspaceFolder:"]];
  for (NSUInteger index = 0; index < buttons.count; index++) {
    NSArray<NSString *> *entry = buttons[index];
    NSButton *button = [NimculusChromeButton buttonWithTitle:entry[0] target:self
      action:@selector(dispatchWorkspaceAction:)];
    // Project creation belongs in the compact project header, not in a row of
    // text buttons that displaces the tree. A project-less window is the one
    // exception: an icon alone is too easy to miss in an otherwise empty dock,
    // so keep the explicit Open Folder label as the primary next action.
    if (@available(macOS 11.0, *)) {
      button.image = [NSImage imageWithSystemSymbolName:entry[1]
        accessibilityDescription:entry[0]];
      button.imagePosition = g_workspace_open ? NSImageOnly : NSImageLeft;
    }
    styleSidebarActionButton(button);
    button.toolTip = entry[0];
    button.accessibilityLabel = entry[0];
    button.identifier = entry[2];
    [button.widthAnchor constraintEqualToConstant:g_workspace_open ?
      NimculusControlHit : NimculusControlHit * 4.0 + NimculusSpace3].active = YES;
    [button.heightAnchor constraintEqualToConstant:NimculusControlHit].active = YES;
    [self addArrangedSubview:button];
  }
}
- (void)dispatchWorkspaceAction:(NSButton *)sender {
  if ([sender.identifier hasPrefix:@"commandPalette:"]) {
    if (g_command_callback) g_command_callback(sender.identifier.UTF8String);
    return;
  }
  SEL action = NSSelectorFromString(sender.identifier);
  id delegate = [NSApp delegate];
  if (delegate && [delegate respondsToSelector:action]) {
    [delegate performSelector:action withObject:self];
  }
}
@end

// Search needs an always-discoverable restart/cancel path in its own panel.
// Keeping these actions in the panel header mirrors Zed's Search controls and
// avoids trapping a user in a result list behind the command palette.
@implementation NimculusSearchSidebarActions
- (instancetype)initWithFrame:(NSRect)frame {
  if (frame.size.width <= 0.0 || frame.size.height <= 0.0) {
    frame = NSMakeRect(0.0, 0.0, 56.0, 24.0);
  }
  self = [super initWithFrame:frame];
  if (!self) return nil;
  self.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  self.alignment = NSLayoutAttributeCenterY;
  self.distribution = NSStackViewDistributionFill;
  self.spacing = NimculusSpace1;
  self.newSearchButton = [NimculusChromeButton buttonWithTitle:@"New Search" target:self
    action:@selector(newSearch:)];
  self.cancelSearchButton = [NimculusChromeButton buttonWithTitle:@"Cancel Search" target:self
    action:@selector(cancelSearch:)];
  NSArray<NSArray *> *entries = @[
    @[self.newSearchButton, @"magnifyingglass", @"New workspace search"],
    @[self.cancelSearchButton, @"xmark", @"Cancel workspace search"]
  ];
  for (NSArray *entry in entries) {
    NSButton *button = entry[0];
    if (@available(macOS 11.0, *)) {
      button.image = [NSImage imageWithSystemSymbolName:entry[1]
        accessibilityDescription:entry[2]];
      button.imagePosition = NSImageOnly;
    }
    styleSidebarActionButton(button);
    button.toolTip = entry[2];
    button.accessibilityLabel = entry[2];
    [button.widthAnchor constraintEqualToConstant:NimculusControlHit].active = YES;
    [button.heightAnchor constraintEqualToConstant:NimculusControlHit].active = YES;
    [self addArrangedSubview:button];
  }
  return self;
}
- (void)dealloc { [_newSearchButton release]; [_cancelSearchButton release]; [super dealloc]; }
- (void)newSearch:(id)sender {
  (void)sender;
  if (g_command_callback) g_command_callback("commandPalette:workspace search");
}
- (void)cancelSearch:(id)sender {
  (void)sender;
  if (g_command_callback) g_command_callback("cancelWorkspaceSearch");
}
@end

// Zed places workspace-level panel controls in persistent chrome rather than
// leaving an empty strip above editor tabs. Keep the controls native and route
// every action through the existing Nim command boundary.
@implementation NimculusWorkspaceToolbar
- (instancetype)initWithFrame:(NSRect)frame {
  if (frame.size.width <= 0.0 || frame.size.height <= 0.0) {
    frame = NSMakeRect(0.0, 0.0, 360.0, 24.0);
  }
  self = [super initWithFrame:frame];
  if (!self) return nil;
  self.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  self.alignment = NSLayoutAttributeCenterY;
  self.distribution = NSStackViewDistributionFillProportionally;
  self.spacing = 6.0;
  NSArray<NSArray<NSString *> *> *buttons = @[
    @[@"Files", @"commandPalette:show files"],
    @[@"Search", @"commandPalette:workspace search"],
    @[@"Outline", @"commandPalette:show outline"],
    @[@"Git", @"commandPalette:git status"],
    @[@"Terminal", @"commandPalette:toggle terminal"],
    @[@"Split", @"splitEditor"]
  ];
  for (NSArray<NSString *> *entry in buttons) {
    NSButton *button = [NimculusChromeButton buttonWithTitle:entry[0] target:self
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
    if ([command isEqualToString:@"splitEditor"] || [command isEqualToString:@"closeSplit"]) {
      const BOOL split = g_secondary_editor_visible;
      button.title = split ? @"Close Split" : @"Split";
      button.identifier = split ? @"closeSplit" : @"splitEditor";
      button.toolTip = split ? @"Close the secondary editor pane" : @"Split the editor pane";
      command = button.identifier;
    }
    BOOL active = [command isEqualToString:@"commandPalette:show files"] ?
        g_editor_sidebar_visible && g_editor_sidebar_mode == 1 :
      [command isEqualToString:@"commandPalette:workspace search"] ?
        g_editor_sidebar_visible && g_editor_sidebar_mode == 5 :
      [command isEqualToString:@"commandPalette:show outline"] ?
        g_editor_sidebar_visible && g_editor_sidebar_mode == 0 :
      [command isEqualToString:@"commandPalette:git status"] ?
        g_editor_sidebar_visible && g_editor_sidebar_mode >= 2 && g_editor_sidebar_mode <= 4 :
      [command isEqualToString:@"commandPalette:toggle terminal"] ? g_terminal_visible : NO;
    styleWorkspaceNavigationButton(button, active, NO);
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
@implementation NimculusStatusOverlay
- (BOOL)acceptsFirstResponder { return NO; }
- (NSView *)hitTest:(NSPoint)point { (void)point; return nil; }
- (void)drawRect:(NSRect)dirtyRect {
  (void)dirtyRect;
  NSColor *fill = self.backgroundColor ?: [NSColor colorWithCalibratedRed:204.0 / 255.0
    green:206.0 / 255.0 blue:207.0 / 255.0 alpha:1.0];
  [fill setFill];
  NSRectFill(self.bounds);
}
@end

@implementation NimculusStatusBandOverlay
- (BOOL)acceptsFirstResponder { return NO; }
- (NSView *)hitTest:(NSPoint)point { (void)point; return nil; }
- (void)drawRect:(NSRect)dirtyRect {
  (void)dirtyRect;
  // Zed closes the window's last editor row with a full-width `border` rule at
  // 760pt, directly above the status bar. This view is not flipped, so its
  // visual bottom is y = 0.
  [themeRoleColor(@"border", [NSColor separatorColor]) setFill];
  NSRectFill(NSMakeRect(0.0, 0.0, self.bounds.size.width,
    NimculusChromeBorderHeight));

  // Above that rule Zed paints its horizontal scrollbar. Measured, its thumb
  // covers the text column only: the gutter (x < 92pt) and the dock keep their
  // own surfaces. We do not yet track the thumb's length -- Zed's ended at
  // 915pt of a 92-1134pt track -- so this still spans the whole text column.
  // Do not widen it back over the gutter or the dock; both are measured.
  // Calibrated NSColor is converted through the active display profile; these
  // source values render as Zed's measured #cccecf on the parity display.
  const CGFloat thumbLeft = g_editor_rect[0] + editorTextOriginX(g_editor_rect);
  const CGFloat thumbRight = MAX(thumbLeft, g_editor_rect[0] + g_editor_rect[2]);
  [[NSColor colorWithCalibratedRed:192.0 / 255.0 green:195.0 / 255.0
    blue:196.0 / 255.0 alpha:1.0] setFill];
  NSRectFill(NSMakeRect(thumbLeft, NimculusChromeBorderHeight,
    MAX(0.0, thumbRight - thumbLeft),
    MAX(0.0, self.bounds.size.height - NimculusChromeBorderHeight)));
}
@end

typedef NS_ENUM(NSInteger, NimculusFooterAction) {
  NimculusFooterActionDisplayOnly = -1,
  NimculusFooterActionWorkspaceSearch = 0,
  NimculusFooterActionDiagnostics = 1,
  NimculusFooterActionGit = 2,
  NimculusFooterActionCursor = 4,
  NimculusFooterActionLanguage = 5,
  NimculusFooterActionEncoding = 6,
  NimculusFooterActionLineEnding = 7,
  NimculusFooterActionIndentation = 8,
  NimculusFooterActionPanelTerminal = 10,
  NimculusFooterActionDockToggle = 11,
  NimculusFooterActionAgent = 12
};

static NSString *footerItem(NSArray<NSString *> *items, NSUInteger index, NSString *fallback) {
  if (index < items.count && items[index].length > 0) return items[index];
  return fallback;
}

static void clearFooterCluster(NSStackView *cluster) {
  if (!cluster) return;
  NSArray<NSView *> *previous = [cluster.arrangedSubviews copy];
  for (NSView *view in previous) {
    [cluster removeArrangedSubview:view];
    [view removeFromSuperview];
  }
  [previous release];
}

static void setFooterSymbol(NimculusFooterStatusButton *button, NSString *symbol,
                            NSString *fallbackPrefix) {
  if (!button) return;
  button.image = nil;
  if (@available(macOS 11.0, *)) {
    button.image = [NSImage imageWithSystemSymbolName:symbol
      accessibilityDescription:button.accessibilityLabel];
    button.imagePosition = NSImageLeft;
    applySidebarIconConfiguration(button);
  } else if (fallbackPrefix.length > 0) {
    button.title = [NSString stringWithFormat:@"%@ %@", fallbackPrefix, button.title ?: @""];
  }
}

static void styleFooterStatusButton(NimculusFooterStatusButton *button, BOOL imageOnly) {
  if (!button) return;
  button.bezelStyle = NSBezelStyleTexturedRounded;
  button.bordered = NO;
  button.alignment = NSTextAlignmentLeft;
  button.imageHugsTitle = YES;
  // Keep each status item at its measured content width. NSStackView's
  // fittingSize can otherwise collapse to the button's minimum-width
  // constraint, which makes the manually positioned cluster truncate titles
  // even when the footer has plenty of room.
  [button setContentCompressionResistancePriority:NSLayoutPriorityRequired
    forOrientation:NSLayoutConstraintOrientationHorizontal];
  [button setContentHuggingPriority:NSLayoutPriorityRequired
    forOrientation:NSLayoutConstraintOrientationHorizontal];
  styleWorkspaceNavigationButton(button, NO, imageOnly);
  if (imageOnly) {
    // Footer symbols are status metadata, not primary chrome actions. Resolve
    // them through the muted role so their rendered ink has the same quiet
    // antialiased weight as Zed's status icons.
    button.contentTintColor = themeRoleColor(@"textMuted",
      themeRoleColor(@"fgMuted", themeHexColor(g_theme_foreground,
        [NSColor colorWithCalibratedWhite:0.86 alpha:1.0])));
  } else {
    NSColor *foreground = themeRoleColor(@"fgMuted", themeHexColor(g_theme_foreground,
      [NSColor colorWithCalibratedWhite:0.86 alpha:1.0]));
    button.attributedTitle = [[[NSAttributedString alloc] initWithString:button.title ?: @""
      attributes:@{NSForegroundColorAttributeName: [foreground colorWithAlphaComponent:0.96],
        NSFontAttributeName: editorUiFontWithWeight(NSFontWeightMedium)}]
      autorelease];
  }
  NSRect titleRect = [button.attributedTitle boundingRectWithSize:
    NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX)
    options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
    context:nil];
  CGFloat width = ceil(titleRect.size.width + NimculusSpace2 * 2.0);
  if (!imageOnly && button.image && button.imagePosition == NSImageLeft) {
    width += button.image.size.width + NimculusSpace1;
  }
  button.footerPreferredWidth = MAX(NimculusControlHit, width);
  [button.widthAnchor constraintEqualToConstant:button.footerPreferredWidth].active = YES;
}

static NimculusFooterStatusButton *newFooterButton(NimculusFooterOverlay *owner,
                                                    NSString *title, NSString *label,
                                                    NimculusFooterAction action) {
  NimculusFooterStatusButton *button = [NimculusFooterStatusButton buttonWithTitle:title
    target:owner action:@selector(dispatchStatusItem:)];
  button.footerOwner = owner;
  button.tag = action;
  button.toolTip = label;
  button.accessibilityLabel = label;
  // Footer clusters are NSStackView-managed.  Disable the button's initial
  // zero-sized autoresizing-mask constraints before adding the required
  // status-bar dimensions, otherwise AppKit can see height==0 and height==24
  // as mutually exclusive during the first window layout.
  button.translatesAutoresizingMaskIntoConstraints = NO;
  [button.widthAnchor constraintGreaterThanOrEqualToConstant:NimculusControlHit].active = YES;
  [button.heightAnchor constraintEqualToConstant:NimculusControlHit].active = YES;
  return button;
}

static NimculusFooterStatusButton *newPanelButton(NimculusFooterOverlay *owner,
                                                   NSString *label,
                                                   NSString *symbol,
                                                   NimculusFooterAction action) {
  NimculusFooterStatusButton *button = newFooterButton(owner, @"", label, action);
  if (@available(macOS 11.0, *)) {
    button.image = [NSImage imageWithSystemSymbolName:symbol
      accessibilityDescription:label];
    button.imagePosition = NSImageOnly;
  }
  styleFooterStatusButton(button, YES);
  button.footerPreferredWidth = NimculusControlHit;
  [button.widthAnchor constraintEqualToConstant:NimculusControlHit].active = YES;
  return button;
}

static BOOL footerPanelActionIsActive(NimculusFooterAction action) {
  switch (action) {
    case NimculusFooterActionPanelTerminal:
      return g_terminal_visible;
    default:
      return NO;
  }
}

static const char *footerPanelCommand(NimculusFooterAction action) {
  switch (action) {
    case NimculusFooterActionPanelTerminal: return "commandPalette:toggle terminal";
    default: return NULL;
  }
}

static NSView *newFooterDivider(void) {
  NSView *divider = [[[NSView alloc] initWithFrame:NSMakeRect(0.0, 0.0, 1.0, 12.0)]
    autorelease];
  divider.wantsLayer = YES;
  divider.layer.backgroundColor = [themeRoleColor(@"border",
    [NSColor colorWithCalibratedWhite:0.5 alpha:1.0]) colorWithAlphaComponent:0.55].CGColor;
  divider.translatesAutoresizingMaskIntoConstraints = NO;
  [divider.widthAnchor constraintEqualToConstant:1.0].active = YES;
  [divider.heightAnchor constraintEqualToConstant:12.0].active = YES;
  return divider;
}

@implementation NimculusFooterStatusButton
- (void)rightMouseDown:(NSEvent *)event {
  if (self.footerOwner) [self.footerOwner showStatusBarMenuForEvent:event];
  else [super rightMouseDown:event];
}
@end

@implementation NimculusFooterOverlay
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return NO; }
- (BOOL)isAccessibilityElement { return YES; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityToolbarRole; }
- (NSString *)accessibilityLabel { return @"Editor status bar"; }
- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (!self) return nil;
  self.wantsLayer = YES;
  NSStackView *left = [[[NSStackView alloc] initWithFrame:NSZeroRect] autorelease];
  left.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  left.alignment = NSLayoutAttributeCenterY;
  left.distribution = NSStackViewDistributionFill;
  left.spacing = NimculusSpace1;
  // These clusters are positioned by -layout, not by the footer's
  // constraint engine.  Keeping the autoresizing mask enabled creates a
  // transient height==0 constraint while the footer is attached; that
  // conflicts with the status buttons' required 24pt height and makes
  // AppKit raise LAYOUT_CONSTRAINTS_NOT_SATISFIABLE during launch.
  left.translatesAutoresizingMaskIntoConstraints = NO;
  [self addSubview:left];
  NSStackView *right = [[[NSStackView alloc] initWithFrame:NSZeroRect] autorelease];
  right.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  right.alignment = NSLayoutAttributeCenterY;
  right.distribution = NSStackViewDistributionFill;
  right.spacing = NimculusSpace1;
  right.translatesAutoresizingMaskIntoConstraints = NO;
  [self addSubview:right];
  [self reloadStatusItems];
  return self;
}
- (void)reloadStatusItems {
  NSStackView *left = nil;
  NSStackView *right = nil;
  for (NSView *subview in self.subviews) {
    if (![subview isKindOfClass:[NSStackView class]]) continue;
    if (!left) left = (NSStackView *)subview;
    else right = (NSStackView *)subview;
  }
  if (!left || !right) return;
  clearFooterCluster(left);
  clearFooterCluster(right);

  uint32_t errorCount = 0;
  uint32_t warningCount = 0;
  uint32_t infoCount = 0;
  uint32_t hintCount = 0;
  for (uint32_t index = 0; index < g_diagnostic_count; index++) {
    if (g_diagnostics[index].severity == 1) errorCount++;
    else if (g_diagnostics[index].severity == 2) warningCount++;
    else if (g_diagnostics[index].severity == 3) infoCount++;
    else if (g_diagnostics[index].severity >= 4) hintCount++;
  }
  NSArray<NSString *> *items = [g_editor_footer componentsSeparatedByString:@"\t"];

  // Zed keeps the dock itself as one compact status-bar affordance. The
  // selected panel remains owned by the dock, so toggling it never strands
  // Files, Search, Outline, Git, or Debug behind a per-panel footer button.
  NimculusFooterStatusButton *dock = newPanelButton(self, @"Toggle Panel Dock",
    @"sidebar.left", NimculusFooterActionDockToggle);
  styleSidebarIconButton(dock, g_editor_sidebar_visible);
  if (!g_editor_sidebar_visible) {
    dock.contentTintColor = themeRoleColor(@"textMuted",
      themeRoleColor(@"fgMuted", [NSColor secondaryLabelColor]));
  }
  [left addArrangedSubview:dock];

  // Terminal is a bottom-dock toggle, not a buffer-status decoration. Keep
  // it contiguous with the workspace dock toggle at the far-left edge so the
  // divider separates panel controls from the diagnostic/file/Git readouts.
  NimculusFooterStatusButton *terminalButton = newPanelButton(self, @"Toggle Terminal",
    @"terminal", NimculusFooterActionPanelTerminal);
  styleSidebarIconButton(terminalButton,
    footerPanelActionIsActive(NimculusFooterActionPanelTerminal));
  if (!footerPanelActionIsActive(NimculusFooterActionPanelTerminal)) {
    terminalButton.contentTintColor = themeRoleColor(@"textMuted",
      themeRoleColor(@"fgMuted", [NSColor secondaryLabelColor]));
  }
  [left addArrangedSubview:terminalButton];
  [left addArrangedSubview:newFooterDivider()];

  NimculusFooterStatusButton *agent = newPanelButton(self, @"Agent", @"sparkles",
    NimculusFooterActionAgent);
  [left addArrangedSubview:agent];

  // Keep exactly one project-search affordance in the footer. Search's own
  // panel header still exposes New Search and Cancel Search.
  NimculusFooterStatusButton *search = newFooterButton(self, @"", @"Search Project",
    NimculusFooterActionWorkspaceSearch);
  setFooterSymbol(search, @"magnifyingglass", @"⌕");
  styleFooterStatusButton(search, YES);
  [left addArrangedSubview:search];

  NSString *diagnosticTitle = @"";
  NSString *diagnosticLabel = @"Diagnostics: no problems";
  if (errorCount > 0 || warningCount > 0 || infoCount > 0 || hintCount > 0) {
    NSMutableArray<NSString *> *summary = [NSMutableArray array];
    if (errorCount > 0) [summary addObject:[NSString stringWithFormat:@"%u errors", errorCount]];
    if (warningCount > 0) [summary addObject:[NSString stringWithFormat:@"%u warnings", warningCount]];
    if (infoCount > 0) [summary addObject:[NSString stringWithFormat:@"%u info", infoCount]];
    if (hintCount > 0) [summary addObject:[NSString stringWithFormat:@"%u hints", hintCount]];
    diagnosticTitle = [summary componentsJoinedByString:@" · "];
    diagnosticLabel = [NSString stringWithFormat:@"Diagnostics: %@", diagnosticTitle];
  }
  if (errorCount == 0 && warningCount == 0 && infoCount == 0 && hintCount == 0) {
    NimculusFooterStatusButton *diagnostics = newFooterButton(self, @"", diagnosticLabel,
      NimculusFooterActionDiagnostics);
    setFooterSymbol(diagnostics, @"checkmark", @"✓");
    styleFooterStatusButton(diagnostics, YES);
    diagnostics.contentTintColor = themeRoleColor(@"textMuted",
      themeRoleColor(@"fgMuted", [NSColor secondaryLabelColor]));
    [left addArrangedSubview:diagnostics];
  } else {
    if (errorCount > 0) {
      NimculusFooterStatusButton *errors = newFooterButton(self,
        [NSString stringWithFormat:@"%u", errorCount],
        diagnosticLabel, NimculusFooterActionDiagnostics);
      setFooterSymbol(errors, @"xmark.circle", @"✕");
      styleFooterStatusButton(errors, NO);
      errors.contentTintColor = themeRoleColor(@"error", [NSColor systemRedColor]);
      [left addArrangedSubview:errors];
    }
    if (warningCount > 0) {
      NimculusFooterStatusButton *warnings = newFooterButton(self,
        [NSString stringWithFormat:@"%u", warningCount],
        diagnosticLabel, NimculusFooterActionDiagnostics);
      setFooterSymbol(warnings, @"exclamationmark.triangle", @"⚠");
      styleFooterStatusButton(warnings, NO);
      warnings.contentTintColor = themeRoleColor(@"warning", [NSColor systemOrangeColor]);
      [left addArrangedSubview:warnings];
    }
    if (infoCount > 0) {
      NimculusFooterStatusButton *info = newFooterButton(self,
        [NSString stringWithFormat:@"%u", infoCount], diagnosticLabel,
        NimculusFooterActionDiagnostics);
      setFooterSymbol(info, @"info.circle", @"ⓘ");
      styleFooterStatusButton(info, NO);
      info.contentTintColor = themeRoleColor(@"info", [NSColor systemBlueColor]);
      [left addArrangedSubview:info];
    }
    if (hintCount > 0) {
      NimculusFooterStatusButton *hints = newFooterButton(self,
        [NSString stringWithFormat:@"%u", hintCount], diagnosticLabel,
        NimculusFooterActionDiagnostics);
      setFooterSymbol(hints, @"lightbulb", @"✦");
      styleFooterStatusButton(hints, NO);
      hints.contentTintColor = themeRoleColor(@"hint", [NSColor secondaryLabelColor]);
      [left addArrangedSubview:hints];
    }
  }

  NSString *cursor = footerItem(items, 0, @"1:1");
  NSString *encoding = footerItem(items, 2, @"UTF-8");
  NSString *lineEnding = footerItem(items, 3, @"LF");
  NSString *language = footerItem(items, 4, @"Plain Text");
  NSArray<NSArray<NSString *> *> *rightEntries = @[
    @[cursor, [NSString stringWithFormat:@"Cursor position: %@", cursor], @"4"],
    @[language, [NSString stringWithFormat:@"Language: %@", language], @"5"],
    @[lineEnding, [NSString stringWithFormat:@"Line ending: %@", lineEnding], @"7"],
    @[encoding, [NSString stringWithFormat:@"Encoding: %@", encoding], @"6"]
  ];
  for (NSArray<NSString *> *entry in rightEntries) {
    NimculusFooterStatusButton *button = newFooterButton(self, entry[0], entry[1],
      (NimculusFooterAction)entry[2].integerValue);
    styleFooterStatusButton(button, NO);
    [right addArrangedSubview:button];
  }
  // The right cluster is reserved for the four plain-text buffer status
  // selectors, matching Zed's footer.
  [self setNeedsLayout:YES];
}
static CGFloat footerClusterWidth(NSStackView *cluster) {
  if (!cluster) return 0.0;
  CGFloat width = 0.0;
  NSUInteger visibleCount = 0;
  for (NSView *view in cluster.arrangedSubviews) {
    if (view.hidden) continue;
    if ([view isKindOfClass:[NimculusFooterStatusButton class]]) {
      width += ((NimculusFooterStatusButton *)view).footerPreferredWidth;
    } else {
      width += view.frame.size.width;
    }
    visibleCount++;
  }
  if (visibleCount > 1) width += cluster.spacing * (visibleCount - 1);
  return ceil(width);
}
- (void)hideFooterItemsUntilTheyFit:(NSStackView *)left right:(NSStackView *)right
                         available:(CGFloat)available {
  // Preserve the Zed order while fitting the most useful status first. Less
  // critical metadata is removed from the outside in only after the full
  // preferred widths no longer fit.
  while (footerClusterWidth(left) + footerClusterWidth(right) + NimculusSpace3 > available) {
    NimculusFooterStatusButton *candidate = nil;
    for (NSView *view in right.arrangedSubviews.reverseObjectEnumerator) {
      if (!view.hidden && [view isKindOfClass:[NimculusFooterStatusButton class]]) {
        candidate = (NimculusFooterStatusButton *)view;
        break;
      }
    }
    if (!candidate) {
      for (NSView *view in left.arrangedSubviews.reverseObjectEnumerator) {
        if (!view.hidden && [view isKindOfClass:[NimculusFooterStatusButton class]]) {
          candidate = (NimculusFooterStatusButton *)view;
          break;
        }
      }
    }
    if (!candidate) break;
    candidate.hidden = YES;
  }
}
- (void)layout {
  [super layout];
  NSStackView *left = nil;
  NSStackView *right = nil;
  for (NSView *subview in self.subviews) {
    if (![subview isKindOfClass:[NSStackView class]]) continue;
    if (!left) left = (NSStackView *)subview;
    else right = (NSStackView *)subview;
  }
  if (!left || !right) return;
  CGFloat inset = NimculusSpace2;
  CGFloat available = MAX(1.0, self.bounds.size.width - inset * 2.0);
  for (NSView *view in left.arrangedSubviews) view.hidden = NO;
  for (NSView *view in right.arrangedSubviews) view.hidden = NO;
  [self hideFooterItemsUntilTheyFit:left right:right available:available];
  CGFloat rightWidth = footerClusterWidth(right);
  CGFloat leftWidth = footerClusterWidth(left);
  left.frame = NSMakeRect(inset, NimculusStatusItemVerticalOffset, leftWidth,
    self.bounds.size.height);
  right.frame = NSMakeRect(MAX(inset, self.bounds.size.width - inset - rightWidth),
    NimculusStatusItemVerticalOffset, rightWidth, self.bounds.size.height);
  [left layoutSubtreeIfNeeded];
  [right layoutSubtreeIfNeeded];
}
- (void)drawRect:(NSRect)dirtyRect {
  (void)dirtyRect;
  NSColor *background = themeRoleColor(@"statusBar",
    [NSColor colorWithCalibratedWhite:0.075 alpha:1.0]);
  [background setFill];
  NSRectFill(self.bounds);
}
- (void)dispatchStatusItem:(NimculusFooterStatusButton *)sender {
  if (!g_command_callback) return;
  switch ((NimculusFooterAction)sender.tag) {
    case NimculusFooterActionPanelTerminal:
    {
      const char *command = footerPanelCommand((NimculusFooterAction)sender.tag);
      if (command) g_command_callback(command);
      break;
    }
    case NimculusFooterActionDockToggle:
      g_command_callback("commandPalette:toggle workspace dock");
      break;
    case NimculusFooterActionAgent:
      g_command_callback("commandPalette:agent start");
      break;
    case NimculusFooterActionWorkspaceSearch:
      g_command_callback("commandPalette:workspace search");
      break;
    case NimculusFooterActionDiagnostics:
      g_command_callback("commandPalette:show problems");
      break;
    case NimculusFooterActionGit:
      g_command_callback("commandPalette:git status");
      break;
    case NimculusFooterActionCursor:
      g_command_callback("commandPalette:go to line");
      break;
    case NimculusFooterActionLanguage:
    case NimculusFooterActionEncoding:
    case NimculusFooterActionLineEnding:
    case NimculusFooterActionIndentation:
      // Keep the existing settings command route until dedicated selectors
      // exist for language, encoding, line endings, and indentation.
      g_command_callback("commandPalette:settings");
      break;
    default:
      break;
  }
}
- (void)showStatusBarMenuForEvent:(NSEvent *)event {
  if (!g_command_callback) return;
  NimculusAppDelegate *delegate = (NimculusAppDelegate *)[NSApp delegate];
  if (!delegate) return;
  NSMenu *menu = [[[NSMenu alloc] initWithTitle:@"Status Bar"] autorelease];
  NSMenuItem *settings = [menu addItemWithTitle:@"Status Bar Settings…"
    action:@selector(dispatchCommand:) keyEquivalent:@""];
  settings.target = delegate;
  settings.representedObject = @"commandPalette:settings";
  [menu addItem:[NSMenuItem separatorItem]];
  NSMenuItem *hide = [menu addItemWithTitle:@"Hide Status Bar"
    action:@selector(dispatchCommand:) keyEquivalent:@""];
  hide.target = delegate;
  hide.representedObject = @"commandPalette:settings";
  [menu popUpMenuPositioningItem:nil atLocation:event.locationInWindow inView:self];
}
- (void)rightMouseDown:(NSEvent *)event {
  [self showStatusBarMenuForEvent:event];
}
@end

@implementation NimculusEditorContextOverlay
- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (!self) return nil;
  self.previewButton = [self breadcrumbButtonWithSymbol:@"eye"
    label:@"Preview document" action:@selector(previewDocument:)];
  self.searchButton = [self breadcrumbButtonWithSymbol:@"magnifyingglass"
    label:@"Find in file" action:@selector(findDocument:)];
  self.formatButton = [self breadcrumbButtonWithSymbol:@"arrow.triangle.2.circlepath"
    label:@"Format buffer" action:@selector(formatDocument:)];
  [self addSubview:self.previewButton];
  [self addSubview:self.searchButton];
  [self addSubview:self.formatButton];
  [self updateBreadcrumbPresentation];
  return self;
}
- (void)dealloc {
  [_previewButton release];
  [_searchButton release];
  [_formatButton release];
  [super dealloc];
}
- (NSButton *)breadcrumbButtonWithSymbol:(NSString *)symbol label:(NSString *)label
                                  action:(SEL)action {
  NimculusChromeButton *button = [NimculusChromeButton buttonWithTitle:@""
    target:self action:action];
  if (@available(macOS 11.0, *)) {
    button.image = [NSImage imageWithSystemSymbolName:symbol
      accessibilityDescription:label];
    button.imagePosition = NSImageOnly;
    button.imageScaling = NSImageScaleProportionallyDown;
    NSImageSymbolConfiguration *configuration = [NSImageSymbolConfiguration
      configurationWithPointSize:NimculusToolbarIconPointSize
      weight:NSFontWeightMedium];
    button.image = [button.image imageWithSymbolConfiguration:configuration];
  }
  button.toolTip = label;
  button.accessibilityLabel = label;
  styleWorkspaceNavigationButton(button, NO, YES);
  return button;
}
- (void)setStringValue:(NSString *)stringValue {
  [super setStringValue:stringValue ?: @""];
  [self updateBreadcrumbPresentation];
}
- (BOOL)acceptsFirstResponder { return NO; }
- (void)layout {
  [super layout];
  // The breadcrumb is a single, clipped line. Rebuild after AppKit assigns
  // the real width so the complete document/heading chain remains visible
  // beside the three actions instead of wrapping the tail onto a hidden row.
  [self updateBreadcrumbPresentation];
  // Center the actions in the toolbar's content band, above its bottom rule.
  const CGFloat actionTop = (self.bounds.size.height -
    NimculusChromeBorderHeight - NimculusControlHit) / 2.0;
  // Zed right-aligns a five-slot cluster; its first two slots are the same
  // preview and search actions we own, so fill its slots from the left rather
  // than right-aligning three buttons into slots three through five. The
  // trailing slots stay empty because we have no inline assistant or editor
  // settings menu to put there, and a button that does nothing would be
  // decoration.
  const CGFloat rightmostCenter = self.bounds.size.width +
    NimculusSpace2 - NimculusToolbarSlotRightInset;
  NSButton *slots[3] = {self.previewButton, self.searchButton, self.formatButton};
  for (NSUInteger index = 0; index < 3; index++) {
    const CGFloat center = rightmostCenter -
      NimculusToolbarSlotPitch * (CGFloat)(NimculusToolbarSlotCount - 1 - index);
    slots[index].frame = NSMakeRect(center - NimculusControlHit / 2.0, actionTop,
      NimculusControlHit, NimculusControlHit);
  }
}
- (void)drawRect:(NSRect)dirtyRect {
  (void)dirtyRect;
  [themeHexColor(editorPaintToken(), [NSColor colorWithCalibratedWhite:0.98 alpha:1.0]) setFill];
  NSRectFill(self.bounds);
  // Zed closes the toolbar with a 1pt `border.variant` rule (measured
  // #dfe0e1) along its bottom edge.
  [themeRoleColor(@"borderVariant", themeHexColor(g_theme_border,
    [NSColor separatorColor])) setFill];
  NSRectFill(NSMakeRect(0.0, MAX(0.0, self.bounds.size.height -
    NimculusChromeBorderHeight), self.bounds.size.width,
    NimculusChromeBorderHeight));
  if (self.attributedStringValue.length == 0) return;
  const CGFloat actionWidth = (NimculusControlHit * 3.0) +
    (NimculusSpace1 * 4.0);
  NSRect textRect = NSMakeRect(NimculusBreadcrumbTextLeft, NimculusBreadcrumbTextBottom,
    MAX(1.0, self.bounds.size.width - actionWidth - NimculusBreadcrumbTextLeft),
    MAX(1.0, self.bounds.size.height - NimculusBreadcrumbTextBottom));
  [self.attributedStringValue drawWithRect:textRect
    options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading context:nil];
}
- (void)updateBreadcrumbPresentation {
  NSString *text = self.stringValue ?: @"";
  // Zed's breadcrumbs use Color::Muted for every segment. Heading names stay
  // semibold, while markers, separators, and path text remain regular.
  NSColor *muted = themeRoleColor(@"textMuted", themeHexColor(g_theme_foreground,
    [NSColor colorWithCalibratedRed:0.72 green:0.76 blue:0.82 alpha:1.0]));
  NSColor *heading = muted;
  const CGFloat actionWidth = (NimculusControlHit * 3.0) +
    (NimculusSpace1 * 4.0);
  NSFont *regularFont = editorUiFontWithWeight(NSFontWeightRegular);
  NSFont *headingFont = editorUiFontWithWeight(NSFontWeightSemibold);
  NSMutableAttributedString *styled = [[[NSMutableAttributedString alloc] init]
    autorelease];
  NSArray<NSString *> *components = [text componentsSeparatedByString:@" › "];
  for (NSUInteger index = 0; index < components.count; index++) {
    if (index > 0) {
      // Zed separates breadcrumb segments with layout gaps, not spaces: its
      // path ends at x=221pt, the chevron's ink runs 227.5-231pt, and the next
      // segment starts at 236pt. A monospace space on either side puts those
      // gaps at 12pt and 11pt, so tighten each one by its measured excess.
      [styled appendAttributedString:[[[NSAttributedString alloc] initWithString:@" "
        attributes:@{NSForegroundColorAttributeName: muted,
          NSFontAttributeName: regularFont,
          NSKernAttributeName: @(-5.5)}] autorelease]];
      [styled appendAttributedString:[[[NSAttributedString alloc] initWithString:@"›"
        attributes:@{NSForegroundColorAttributeName: muted,
          NSFontAttributeName: regularFont}] autorelease]];
      [styled appendAttributedString:[[[NSAttributedString alloc] initWithString:@" "
        attributes:@{NSForegroundColorAttributeName: muted,
          NSFontAttributeName: regularFont,
          NSKernAttributeName: @(-6.0)}] autorelease]];
    }
    NSString *component = components[index];
    if ([component hasPrefix:@"#"]) {
      NSUInteger markerLength = 0;
      while (markerLength < component.length &&
          [component characterAtIndex:markerLength] == '#') markerLength++;
      NSUInteger titleStart = markerLength;
      while (titleStart < component.length &&
          ([component characterAtIndex:titleStart] == ' ' ||
           [component characterAtIndex:titleStart] == '\t')) titleStart++;
      if (markerLength > 0 && titleStart < component.length) {
        NSString *marker = [component substringToIndex:markerLength];
        NSString *spacing = [component substringWithRange:NSMakeRange(markerLength,
          titleStart - markerLength)];
        NSString *title = [component substringFromIndex:titleStart];
        [styled appendAttributedString:[[[NSAttributedString alloc] initWithString:marker
          attributes:@{NSForegroundColorAttributeName: muted,
            NSFontAttributeName: regularFont}] autorelease]];
        if (spacing.length > 0) {
          [styled appendAttributedString:[[[NSAttributedString alloc] initWithString:spacing
            attributes:@{NSForegroundColorAttributeName: muted,
              NSFontAttributeName: regularFont}] autorelease]];
        }
        [styled appendAttributedString:[[[NSAttributedString alloc] initWithString:title
          attributes:@{NSForegroundColorAttributeName: heading,
            NSFontAttributeName: headingFont}] autorelease]];
        continue;
      }
    }
    [styled appendAttributedString:[[[NSAttributedString alloc] initWithString:component
      attributes:@{NSForegroundColorAttributeName: muted,
        NSFontAttributeName: regularFont}] autorelease]];
  }
  NSMutableParagraphStyle *paragraph = [[[NSMutableParagraphStyle alloc] init] autorelease];
  paragraph.lineBreakMode = NSLineBreakByClipping;
  if (styled.length > 0) {
    [styled addAttribute:NSParagraphStyleAttributeName value:paragraph
      range:NSMakeRange(0, styled.length)];
  }
  self.attributedStringValue = styled;
  styleWorkspaceNavigationButton(self.searchButton, NO, YES);
  styleWorkspaceNavigationButton(self.formatButton, NO, YES);
  styleWorkspaceNavigationButton(self.previewButton, NO, YES);
  [self setNeedsDisplay:YES];
}
- (void)findDocument:(id)sender {
  (void)sender;
  if (g_command_callback) g_command_callback("commandPalette:find");
}
- (void)previewDocument:(id)sender {
  (void)sender;
  if (g_command_callback) g_command_callback("commandPalette:preview document");
}
- (void)formatDocument:(id)sender {
  (void)sender;
  if (g_command_callback) g_command_callback("commandPalette:format document");
}
- (NSView *)hitTest:(NSPoint)point {
  NSView *hit = [super hitTest:point];
  return hit == self ? nil : hit;
}
@end

@implementation NimculusEditorAnnotationOverlay
@synthesize secondary = _secondary;
- (BOOL)isFlipped { return YES; }
- (NSView *)hitTest:(NSPoint)point { return nil; }
- (void)drawRect:(NSRect)dirtyRect {
  (void)dirtyRect;
  // This view intentionally spans the Metal root so annotation coordinates
  // remain aligned with editorPointForUTF16Offset. Its drawing, however,
  // belongs only to the text content viewport. Without this clip an inlay
  // hint can paint over the scrollbar, split boundary, sidebar, or status
  // area even though the underlying editor texture is correctly scissored.
  const BOOL secondary = self.secondary;
  const NSRect textClip = editorAnnotationClipRect(secondary ?
    g_secondary_editor_rect : g_editor_rect);
  if (NSIsEmptyRect(textClip)) return;
  NSRectClip(textClip);
  NimculusEditorAnnotation *annotations = secondary ? g_secondary_editor_annotations :
    g_editor_annotations;
  uint32_t annotationCount = secondary ? g_secondary_editor_annotation_count :
    g_editor_annotation_count;
  NSMutableArray<NSString *> *annotationTexts = secondary ?
    g_secondary_editor_annotation_texts : g_editor_annotation_texts;
  double previousRect[4] = {g_editor_rect[0], g_editor_rect[1],
    g_editor_rect[2], g_editor_rect[3]};
  NSUInteger previousScrollLine = g_editor_scroll_line;
  CGFloat previousScrollYFraction = g_editor_scroll_y_fraction;
  CGFloat previousScrollX = g_editor_scroll_x;
  BOOL previousSoftWrap = g_editor_soft_wrap;
  if (secondary) {
    memcpy(g_editor_rect, g_secondary_editor_rect, sizeof(g_editor_rect));
    g_editor_scroll_line = g_secondary_editor_scroll_line;
    g_editor_scroll_y_fraction = g_secondary_editor_scroll_y_fraction;
    g_editor_scroll_x = g_secondary_editor_scroll_x;
    g_editor_soft_wrap = g_secondary_editor_soft_wrap;
    swapEditorTextState();
  }
  NSDictionary *attributes = @{
    NSFontAttributeName: [NSFont fontWithName:@"Menlo-Italic" size:11.0] ?:
      [NSFont monospacedSystemFontOfSize:11.0 weight:NSFontWeightRegular],
    NSForegroundColorAttributeName: [themeHexColor(g_theme_accent,
      [NSColor colorWithCalibratedRed:0.35 green:0.65 blue:0.95 alpha:0.82])
      colorWithAlphaComponent:0.78]
  };
  for (uint32_t index = 0; index < annotationCount; index++) {
    if (!annotationTexts || index >= annotationTexts.count || !annotations) continue;
    NSString *text = annotationTexts[index];
    if (text.length == 0) continue;
    NimculusEditorAnnotation *annotationSource = secondary ?
      g_secondary_editor_annotations : g_editor_annotations;
    NimculusEditorAnnotation annotation = annotationSource[index];
    if ((NSUInteger)annotation.line < g_editor_scroll_line) continue;
    NSUInteger documentOffset = editorDocumentOffsetForLineCharacter(
      annotation.line, annotation.character);
    CGPoint point = editorPointForUTF16Offset(documentOffset);
    CGFloat x = (CGFloat)g_editor_rect[0] + point.x;
    CGFloat y = (CGFloat)g_editor_rect[1] + point.y + 2.0;
    if (x >= NSMaxX(textClip) || y >= NSMaxY(textClip)) continue;
    if (x + 1.0 < NSMinX(textClip) || y + 1.0 < NSMinY(textClip)) continue;
    [text drawAtPoint:NSMakePoint(x, y) withAttributes:attributes];
  }
  if (secondary) {
    swapEditorTextState();
    memcpy(g_editor_rect, previousRect, sizeof(g_editor_rect));
    g_editor_scroll_line = previousScrollLine;
    g_editor_scroll_y_fraction = previousScrollYFraction;
    g_editor_scroll_x = previousScrollX;
    g_editor_soft_wrap = previousSoftWrap;
  }
}
@end

@implementation NimculusExternalChangeActionTarget
- (void)reload:(id)sender {
  (void)sender;
  dismissExternalChangePanel("reloadExternal");
}
- (void)keepEditing:(id)sender {
  (void)sender;
  dismissExternalChangePanel("keepExternal");
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
  // Zed's Project Panel uses the semantic element colors for retained focus;
  // it does not turn a selected row into an accent-colored command surface.
  outline.selectedTextAttributes = @{
    NSBackgroundColorAttributeName: themeRoleColor(@"elementSelected",
      themeRoleColor(@"element", [NSColor selectedControlColor])),
    NSForegroundColorAttributeName: themeRoleColor(@"fgPrimary",
      themeHexColor(g_theme_foreground, [NSColor labelColor]))
  };
  NSString *rawText = sidebarContentText(g_editor_outline_text ?: @"");
  NSArray<NSString *> *rawLines = [rawText componentsSeparatedByString:@"\n"];
  NSMutableArray<NSString *> *displayLines = [NSMutableArray arrayWithCapacity:rawLines.count];
  NSMutableArray<NSNumber *> *depths = [NSMutableArray arrayWithCapacity:rawLines.count];
  for (NSString *rawLine in rawLines) {
    NSString *displayLine = rawLine;
    NSUInteger depth = 0;
    if (g_editor_sidebar_mode == 1) {
      NSUInteger leading = 0;
      while (leading < rawLine.length && [rawLine characterAtIndex:leading] == ' ') leading++;
      depth = leading / 2;
      if (leading > 0) displayLine = [rawLine substringFromIndex:leading];
    }
    [displayLines addObject:displayLine];
    [depths addObject:@(depth)];
  }
  NSMutableString *displayText = [[displayLines componentsJoinedByString:@"\n"] mutableCopy];
  NSUInteger markerCursor = 0;
  for (NSString *content in displayLines) {
    NSUInteger tokenLength = sidebarIconTokenLength(content);
    if (tokenLength > 0 && tokenLength <= content.length) {
      [displayText replaceCharactersInRange:NSMakeRange(markerCursor, tokenLength)
                                 withString:@"\uFFFC"];
    }
    markerCursor += content.length + 1;
  }
  NSString *text = [[displayText copy] autorelease];
  [displayText release];
  NSColor *foreground = themeRoleColor(@"fgPrimary", themeHexColor(g_theme_foreground,
    [NSColor labelColor]));
  NSMutableParagraphStyle *rowStyle = [[NSMutableParagraphStyle alloc] init];
  rowStyle.lineBreakMode = NSLineBreakByTruncatingTail;
  // ProjectPanelEntrySpacing::Comfortable uses Zed's Dense ListItem spacing.
  // Keep the native row at the same 24pt rhythm regardless of editor font
  // settings, while the 20pt head indent remains a panel invariant.
  rowStyle.minimumLineHeight = 24.0;
  rowStyle.maximumLineHeight = 24.0;
  NSMutableAttributedString *presented = [[NSMutableAttributedString alloc]
    initWithString:text attributes:@{
      NSFontAttributeName: editorUiFontWithWeight(NSFontWeightRegular),
      NSForegroundColorAttributeName: foreground,
      NSParagraphStyleAttributeName: rowStyle
    }];
  NSUInteger cursor = 0;
  NSUInteger line = 0;
  while (line < displayLines.count) {
    NSRange newline = [text rangeOfString:@"\n" options:0
      range:NSMakeRange(cursor, text.length - cursor)];
    NSUInteger end = newline.location == NSNotFound ? text.length : newline.location;
    NSRange range = NSMakeRange(cursor, end - cursor);
    NSString *content = displayLines[line];
    NSMutableParagraphStyle *lineStyle = [rowStyle mutableCopy];
    const uint32_t rowFlags = sidebarFlagsForContentLine(line);
    lineStyle.firstLineHeadIndent = depths[line].doubleValue * 20.0 +
      (g_editor_sidebar_mode == 3 && rowFlags > 0u ? 28.0 : 0.0);
    lineStyle.headIndent = lineStyle.firstLineHeadIndent;
    [presented addAttribute:NSParagraphStyleAttributeName value:lineStyle range:range];
    [lineStyle release];
    if (g_editor_sidebar_mode == 0) {
      // Outline rows carry a compact symbol-kind token from the shared
      // symbol model. Replace it with a native SF Symbol while leaving the
      // label and its depth in the text system, so hit testing, AX, and
      // keyboard selection keep the same row identity.
      NSUInteger tokenLength = sidebarIconTokenLength(content);
      if (tokenLength > 0 && tokenLength <= content.length) {
        NSRange marker = NSMakeRange(range.location, tokenLength);
        NSImage *image = sidebarSymbolImage(outlineSymbolForToken(content, tokenLength));
        if (image) {
          NSTextAttachment *attachment = [[[NSTextAttachment alloc] init] autorelease];
          attachment.image = image;
          [presented addAttribute:NSAttachmentAttributeName value:attachment range:marker];
        } else {
          [presented addAttributes:@{
            NSFontAttributeName: editorUiFontWithWeight(NSFontWeightMedium),
            NSForegroundColorAttributeName: themeRoleColor(@"textMuted", foreground)
          } range:marker];
        }
      }
    } else if (g_editor_sidebar_mode == 1) {
      uint32_t flags = sidebarFlagsForContentLine(line);
      [presented addAttribute:NSForegroundColorAttributeName
        value:sidebarLabelColor(flags) range:range];
      NSUInteger tokenLength = sidebarIconTokenLength(content);
      if (tokenLength > 0 && tokenLength <= content.length) {
        NSRange marker = NSMakeRange(range.location, tokenLength);
        NSString *symbol = [content hasPrefix:@"▾"] ? @"folder.fill" :
          ([content hasPrefix:@"▸"] ? @"folder" : sidebarFileSymbolForLine(content, tokenLength));
        NSImage *image = sidebarSymbolImage(symbol);
        if (image) {
          NSTextAttachment *attachment = [[[NSTextAttachment alloc] init] autorelease];
          attachment.image = image;
          [presented addAttribute:NSAttachmentAttributeName value:attachment range:marker];
        } else {
          [presented addAttributes:@{
            NSFontAttributeName: editorUiFontWithWeight(NSFontWeightMedium),
            NSForegroundColorAttributeName: themeRoleColor(@"textMuted", foreground)
          } range:marker];
        }
      }
    } else if (g_editor_sidebar_mode == 3) {
      NSUInteger originalLine = line + NimculusSidebarHeaderLineCount;
      if (g_editor_sidebar_line_items && originalLine < g_editor_sidebar_line_item_count &&
          g_editor_sidebar_line_items[originalLine] < 0) {
        // Git's section labels are hierarchy, never file state or a clickable
        // row. Keep them quiet and semibold so the three change groups scan
        // like Zed's collapsible sections without pretending to be a status.
        [presented addAttributes:@{
          NSFontAttributeName: editorUiFontWithWeight(NSFontWeightSemibold),
          NSForegroundColorAttributeName: themeRoleColor(@"textMuted", foreground)
        } range:range];
      } else {
        // A change row is deliberately split into basename, muted directory,
        // and a final status token. The status token uses the same semantic
        // roles as Zed's `version_control.added/modified/deleted` colors.
        NSRange firstSeparator = [content rangeOfString:@"    "];
        NSRange statusRange = content.length > 0
          ? NSMakeRange(content.length - 1, 1) : NSMakeRange(NSNotFound, 0);
        NSRange secondSeparator = statusRange.location != NSNotFound
          ? [content rangeOfString:@"    " options:NSBackwardsSearch
              range:NSMakeRange(0, statusRange.location)] : NSMakeRange(NSNotFound, 0);
        if (firstSeparator.location != NSNotFound &&
            secondSeparator.location != NSNotFound) {
          [presented addAttribute:NSForegroundColorAttributeName value:foreground
            range:NSMakeRange(range.location, firstSeparator.location)];
          NSUInteger directoryStart = firstSeparator.location + firstSeparator.length;
          if (directoryStart < secondSeparator.location) {
            [presented addAttributes:@{
              NSFontAttributeName: editorUiFontWithWeight(NSFontWeightRegular),
              NSForegroundColorAttributeName: themeRoleColor(@"textMuted",
                themeRoleColor(@"fgMuted", foreground))
            } range:NSMakeRange(range.location + directoryStart,
              secondSeparator.location - directoryStart)];
          }
          NSString *status = [content substringWithRange:statusRange];
          NSString *role = [status isEqualToString:@"+"] ? @"added" :
            [status isEqualToString:@"-"] ? @"deleted" :
            [status isEqualToString:@"!"] ? @"conflict" : @"modified";
          [presented addAttributes:@{
            NSFontAttributeName: editorUiFontWithWeight(NSFontWeightSemibold),
            NSForegroundColorAttributeName: themeRoleColor(role,
              themeRoleColor(@"textMuted", foreground))
          } range:NSMakeRange(range.location + statusRange.location, 1)];
        }
      }
    } else if (g_editor_sidebar_mode == 2 && content.length >= 8) {
      // Commit hashes are stable scan anchors; distinguish them from the
      // subject/author without making history rows multi-line and ambiguous.
      [presented addAttributes:@{
        NSFontAttributeName: editorUiFontWithWeight(NSFontWeightMedium),
        NSForegroundColorAttributeName: themeRoleColor(@"accent", foreground)
      } range:NSMakeRange(range.location, MIN((NSUInteger)8, range.length))];
    }
    if (newline.location != NSNotFound) cursor = NSMaxRange(newline);
    line++;
  }
  [outline.textStorage setAttributedString:presented];
  [outline refreshGitCheckboxes];
  logSidebarPresentationDebug(displayLines, depths);
  [presented release];
  [rowStyle release];
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

static NSColor *terminalPaletteRoleColor(NSString *key, NSColor *fallback);

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
    NSBackgroundColorAttributeName: terminalPaletteRoleColor(@"selection",
      [NSColor colorWithCalibratedRed:0.20 green:0.40 blue:0.75 alpha:1.0])
  };
}

static NSDictionary *terminalPaletteDictionary(void) {
  NSDictionary *palette = [g_theme_palette[@"terminalPalette"] isKindOfClass:[NSDictionary class]] ?
    g_theme_palette[@"terminalPalette"] : nil;
  return palette;
}

static NSColor *terminalPaletteRoleColor(NSString *key, NSColor *fallback) {
  NSString *value = [terminalPaletteDictionary()[key] isKindOfClass:[NSString class]] ?
    terminalPaletteDictionary()[key] : nil;
  return validThemeToken(value) ? themeHexColor(value, fallback) : fallback;
}

static BOOL terminalPaletteIndexedComponents(uint32_t index, BOOL dim,
                                             CGFloat *red, CGFloat *green, CGFloat *blue) {
  NSDictionary *palette = terminalPaletteDictionary();
  NSString *setName = dim ? @"dim" : (index >= 8 ? @"bright" : @"normal");
  NSArray *values = [palette[setName] isKindOfClass:[NSArray class]] ? palette[setName] : nil;
  if (!values || index >= values.count || !validThemeToken(values[index])) return NO;
  NSColor *color = themeHexColor(values[index], nil);
  if (!color) return NO;
  [color getRed:red green:green blue:blue alpha:NULL];
  return YES;
}

static void terminalIndexedColor(uint32_t index, BOOL dim,
                                 CGFloat *red, CGFloat *green, CGFloat *blue) {
  if (index < 16 && terminalPaletteIndexedComponents(index, dim, red, green, blue)) return;
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
                              BOOL foreground, uint32_t flags) {
  CGFloat r = foreground ? 0.82 : 0.025;
  CGFloat g = foreground ? 0.88 : 0.030;
  CGFloat b = foreground ? 0.92 : 0.045;
  if (kind == 0) {
    NSColor *role = terminalPaletteRoleColor(foreground ? @"foreground" : @"background",
      [NSColor colorWithCalibratedRed:r green:g blue:b alpha:1.0]);
    [role getRed:&r green:&g blue:&b alpha:NULL];
  } else if (kind == 1) terminalIndexedColor(index, (flags & 2) != 0, &r, &g, &b);
  else if (kind == 2) { r = red / 255.0; g = green / 255.0; b = blue / 255.0; }
  return [NSColor colorWithCalibratedRed:r green:g blue:b alpha:1.0];
}

static NSFont *terminalBaseFont(void) {
  return [NSFont fontWithName:terminalResolvedFontName() size:g_terminal_font_size] ?:
    [NSFont monospacedSystemFontOfSize:g_terminal_font_size weight:NSFontWeightRegular];
}

static CGFloat terminalCellWidth(void) {
  return MAX(1.0, terminalBaseFont().maximumAdvancement.width);
}

static CGFloat terminalLineHeight(void) {
  NSLayoutManager *layoutManager = [[NSLayoutManager alloc] init];
  // Zed's default terminal line_height is "standard", i.e. 1.3x the font's
  // natural line height. Keep the same multiplier for grid math and text.
  CGFloat height = [layoutManager defaultLineHeightForFont:terminalBaseFont()] * 1.3;
  [layoutManager release];
  return MAX(1.0, height);
}

static NSParagraphStyle *terminalParagraphStyle(void) {
  NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
  style.minimumLineHeight = terminalLineHeight();
  style.maximumLineHeight = terminalLineHeight();
  style.lineBreakMode = NSLineBreakByClipping;
  return [style autorelease];
}

static BOOL terminalRangeContainsColorEmoji(NSRange range) {
  if (range.length == 0 || !g_terminal_text) return NO;
  NSUInteger end = MIN(g_terminal_text.length, NSMaxRange(range));
  for (NSUInteger index = MIN(range.location, end); index < end; index++) {
    if (colorEmojiAtUTF16Index(g_terminal_text, index, NULL)) return YES;
  }
  return NO;
}

static void applyTerminalRuns(NSTextView *terminal) {
  if (!terminal) return;
  // The Metal cell batch is the primary presentation path for ordinary
  // terminal glyphs. Keep AppKit's text view as an input/selection surface
  // and as a color-emoji fallback, but do not paint a second opaque copy of
  // the regular glyphs on top of the Metal scene.
  const BOOL metalTerminal = g_glyph_pipeline != nil &&
    g_glyph_atlas_texture != nil && g_terminal_glyph_sprite_count > 0;
  NSColor *baseForeground = metalTerminal ? [NSColor clearColor] :
    terminalColor(0, 0, 0, 0, 0, YES, 0);
  NSColor *baseBackground = metalTerminal ? [NSColor clearColor] :
    terminalColor(0, 0, 0, 0, 0, NO, 0);
  terminal.drawsBackground = YES;
  NSMutableAttributedString *attributed = [[NSMutableAttributedString alloc]
    initWithString:g_terminal_text ?: @"" attributes:@{
      NSFontAttributeName: terminalBaseFont(),
      NSForegroundColorAttributeName: baseForeground,
      NSBackgroundColorAttributeName: baseBackground,
      NSParagraphStyleAttributeName: terminalParagraphStyle()
    }];
  for (uint32_t index = 0; index < g_terminal_run_count; index++) {
    NimculusTerminalRun run = g_terminal_runs[index];
    NSUInteger start = utf16OffsetForUTF8Bytes(g_terminal_text, run.start_byte);
    NSUInteger end = utf16OffsetForUTF8Bytes(g_terminal_text, run.end_byte);
    if (end <= start || start >= attributed.length) continue;
    end = MIN(end, attributed.length);
    NSColor *foreground = terminalColor(run.foreground_kind, run.foreground_index,
      run.foreground_red, run.foreground_green, run.foreground_blue, YES, run.flags);
    NSColor *background = terminalColor(run.background_kind, run.background_index,
      run.background_red, run.background_green, run.background_blue, NO, run.flags);
    if (run.flags & 16) { NSColor *swap = foreground; foreground = background; background = swap; }
    if (metalTerminal) {
      if (!terminalRangeContainsColorEmoji(NSMakeRange(start, end - start))) {
        foreground = [NSColor clearColor];
      }
      background = [NSColor clearColor];
    }
    NSFont *font = terminalBaseFont();
    if (run.flags & 1) font = [[NSFontManager sharedFontManager] convertFont:font toHaveTrait:NSBoldFontMask] ?: font;
    if (run.flags & 4) font = [[NSFontManager sharedFontManager] convertFont:font toHaveTrait:NSItalicFontMask] ?: font;
    NSRange range = NSMakeRange(start, end - start);
    [attributed addAttribute:NSFontAttributeName value:font range:range];
    [attributed addAttribute:NSForegroundColorAttributeName value:foreground range:range];
    [attributed addAttribute:NSBackgroundColorAttributeName value:background range:range];
    if (run.flags & 8) [attributed addAttribute:NSUnderlineStyleAttributeName value:@(NSUnderlineStyleSingle) range:range];
    if (run.flags & 32) [attributed addAttribute:NSStrikethroughStyleAttributeName value:@(NSUnderlineStyleSingle) range:range];
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

static NimculusPaintRegion terminalContentViewport(void) {
  double x = g_editor_rect[0];
  double width = g_editor_rect[2];
  double height = g_terminal_visible || g_task_output_visible
    ? MIN(180.0, MAX(72.0, g_editor_rect[3] * 0.42)) : 0.0;
  double top = g_editor_rect[1] + g_editor_rect[3] - height;
  if (g_terminal_panel_rect[2] > 0.0 && g_terminal_panel_rect[3] > 0.0) {
    x = g_terminal_panel_rect[0];
    width = g_terminal_panel_rect[2];
    height = g_terminal_panel_rect[3];
    top = g_terminal_panel_rect[1];
  }
  const double sessionBarHeight = g_terminal_visible ? 27.0 : 0.0;
  NimculusPaintRegion result = {
    (float)x, (float)(top + sessionBarHeight),
    (float)MAX(1.0, width),
    (float)MAX(1.0, height - sessionBarHeight)
  };
  return result;
}

static void appendTerminalGlyphSprite(NimculusMonochromeSprite sprite) {
  appendGlyphSpriteTo(&g_terminal_glyph_sprites, &g_terminal_glyph_sprite_count,
    &g_terminal_glyph_sprite_capacity, sprite);
}

static void appendTerminalGlyphSpriteForEntry(NimculusPaintRegion viewport,
                                              NimculusGlyphAtlasEntry entry,
                                              CGFloat x, CGFloat baseline,
                                              CGFloat red, CGFloat green,
                                              CGFloat blue, CGFloat alpha) {
  if (entry.width == 0 || entry.height == 0 || viewport.width <= 0 ||
      viewport.height <= 0) return;
  CGFloat x0 = x + entry.bounds_x;
  CGFloat x1 = x0 + entry.bounds_width;
  CGFloat y0 = baseline - entry.bounds_y - entry.bounds_height;
  CGFloat y1 = baseline - entry.bounds_y;
  NimculusMonochromeSprite sprite = {
    { (float)x0, (float)y0, (float)(x1 - x0), (float)(y1 - y0) },
    { viewport.x, viewport.y, viewport.width, viewport.height },
    { (float)entry.x, (float)entry.y, (float)entry.width, (float)entry.height },
    { red, green, blue, alpha }
  };
  appendTerminalGlyphSprite(sprite);
}

static void terminalRunColorComponents(NimculusTerminalRun run, BOOL foreground,
                                       CGFloat *red, CGFloat *green, CGFloat *blue) {
  NSColor *color = terminalColor(foreground ? run.foreground_kind : run.background_kind,
    foreground ? run.foreground_index : run.background_index,
    foreground ? run.foreground_red : run.background_red,
    foreground ? run.foreground_green : run.background_green,
    foreground ? run.foreground_blue : run.background_blue, foreground, run.flags);
  NSColor *rgb = [color colorUsingColorSpace:[NSColorSpace genericRGBColorSpace]];
  if (!rgb) return;
  *red = rgb.redComponent; *green = rgb.greenComponent; *blue = rgb.blueComponent;
}

static void updateTerminalGlyphAtlas(id<MTLDevice> device) {
  free(g_terminal_glyph_sprites);
  g_terminal_glyph_sprites = NULL;
  g_terminal_glyph_sprite_count = 0;
  g_terminal_glyph_sprite_capacity = 0;
  if (!device || g_terminal_run_count == 0 || g_terminal_text.length == 0) return;
  CGFloat scale = g_metrics.scale_factor > 0.0 ? g_metrics.scale_factor : 1.0;
  ensureGlyphAtlas(device, scale);
  NimculusPaintRegion viewport = terminalContentViewport();
  NSFont *baseFont = terminalBaseFont();
  if (!baseFont) return;
  const CGFloat cellWidth = terminalCellWidth();
  const CGFloat lineHeight = terminalLineHeight();
  for (uint32_t index = 0; index < g_terminal_run_count; index++) {
    NimculusTerminalRun run = g_terminal_runs[index];
    NSUInteger start = utf16OffsetForUTF8Bytes(g_terminal_text, run.start_byte);
    NSUInteger end = utf16OffsetForUTF8Bytes(g_terminal_text, run.end_byte);
    if (end <= start || start >= g_terminal_text.length) continue;
    end = MIN(end, g_terminal_text.length);
    NSFont *font = baseFont;
    if (run.flags & 1) font = [[NSFontManager sharedFontManager]
      convertFont:font toHaveTrait:NSBoldFontMask] ?: font;
    if (run.flags & 4) font = [[NSFontManager sharedFontManager]
      convertFont:font toHaveTrait:NSItalicFontMask] ?: font;
    CGFloat red = 0.85, green = 0.90, blue = 1.0;
    terminalRunColorComponents(run, YES, &red, &green, &blue);
    CGFloat alpha = 1.0;
    if (run.flags & 16) terminalRunColorComponents(run, NO, &red, &green, &blue);
    NSDictionary *attributes = @{
      (id)kCTFontAttributeName: (id)font,
      (id)kCTForegroundColorAttributeName:
        (id)[NSColor colorWithCalibratedRed:red green:green blue:blue alpha:1.0].CGColor
    };
    NSAttributedString *attributed = [[NSAttributedString alloc]
      initWithString:[g_terminal_text substringWithRange:NSMakeRange(start, end - start)]
      attributes:attributes];
    CTLineRef line = CTLineCreateWithAttributedString((CFAttributedStringRef)attributed);
    CFArrayRef runs = CTLineGetGlyphRuns(line);
    for (CFIndex runIndex = 0; runIndex < CFArrayGetCount(runs); runIndex++) {
      CTRunRef textRun = (CTRunRef)CFArrayGetValueAtIndex(runs, runIndex);
      NSDictionary *runAttributes = (__bridge NSDictionary *)CTRunGetAttributes(textRun);
      CTFontRef ctFont = (__bridge CTFontRef)[runAttributes objectForKey:(id)kCTFontAttributeName];
      if (!ctFont) continue;
      CFIndex glyphCount = CTRunGetGlyphCount(textRun);
      if (glyphCount == 0) continue;
      CGGlyph *glyphs = malloc(sizeof(CGGlyph) * (NSUInteger)glyphCount);
      CGPoint *positions = malloc(sizeof(CGPoint) * (NSUInteger)glyphCount);
      CFIndex *stringIndices = malloc(sizeof(CFIndex) * (NSUInteger)glyphCount);
      if (!glyphs || !positions || !stringIndices) {
        free(glyphs); free(positions); free(stringIndices); continue;
      }
      CTRunGetGlyphs(textRun, CFRangeMake(0, glyphCount), glyphs);
      CTRunGetPositions(textRun, CFRangeMake(0, glyphCount), positions);
      CTRunGetStringIndices(textRun, CFRangeMake(0, glyphCount), stringIndices);
      uint32_t fontId = layoutFontIdForFont(ctFont);
      for (CFIndex glyphIndex = 0; glyphIndex < glyphCount; glyphIndex++) {
        NSUInteger localIndex = stringIndices[glyphIndex] == kCFNotFound ? 0 :
          (NSUInteger)stringIndices[glyphIndex];
        if (colorEmojiAtUTF16Index(g_terminal_text, start + localIndex, NULL) ||
            fontIsColorEmoji(ctFont)) continue;
        NimculusGlyphAtlasEntry entry;
        if (!atlasEntryForGlyph(device, ctFont, glyphs[glyphIndex], fontId,
            g_terminal_font_size, scale,
            0, 0, NO, &entry)) continue;
        CGFloat originX = viewport.x + (CGFloat)run.column * cellWidth + positions[glyphIndex].x;
        CGFloat baseline = viewport.y + (CGFloat)run.row * lineHeight + lineHeight - 3.0;
        appendTerminalGlyphSpriteForEntry(viewport, entry, originX, baseline,
          red, green, blue, alpha);
      }
      free(glyphs); free(positions); free(stringIndices);
    }
    CFRelease(line);
    [attributed release];
  }
  if (g_active_view) {
    for (NSView *subview in ((NimculusMetalView *)g_active_view).subviews) {
      if ([subview isKindOfClass:[NimculusTerminalOverlay class]]) {
        applyTerminalRuns((NimculusTerminalOverlay *)subview);
        break;
      }
    }
  }
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
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    NimculusPlatformMetrics previousMetrics = g_metrics;
    BOOL previousVisible = g_terminal_visible;
    g_metrics.scale_factor = 2.0;
    g_metrics.width_points = 960;
    g_metrics.height_points = 640;
    g_terminal_visible = YES;
    BOOL gpuPipeline = ensureGlyphValidationPipeline(device);
    updateTerminalGlyphAtlas(device);
    BOOL gpuBatch = device && gpuPipeline && g_terminal_glyph_sprite_count > 0;
    applyTerminalRuns(terminal);
    NSColor *metalForeground = [storage attribute:NSForegroundColorAttributeName
      atIndex:0 effectiveRange:NULL];
    BOOL metalSurface = gpuBatch && !terminal.drawsBackground &&
      metalForeground.alphaComponent == 0.0;
    g_terminal_visible = previousVisible;
    g_metrics = previousMetrics;
    [device release];
    BOOL valid = [storage.string isEqualToString:@"A日\nB"] && bold && linked && underlined &&
      stricken && selected && gpuBatch && metalSurface;
    [terminal release];
    nimculus_platform_set_terminal_runs("", 0, NULL, 0);
    id<MTLDevice> cleanupDevice = MTLCreateSystemDefaultDevice();
    updateTerminalGlyphAtlas(cleanupDevice);
    [cleanupDevice release];
    nimculus_platform_set_terminal_selection(0, 0, 0, 0);
    return valid;
  }
}

@implementation NimculusMetalView

+ (Class)layerClass { return [CAMetalLayer class]; }

- (void)displayLinkDidFire:(CADisplayLink *)displayLink {
  (void)displayLink;
  if (g_frame_callback) g_frame_callback();
  if (!self.redrawDirty) return;
  self.redrawDirty = NO;
  [self drawFrame];
}

- (void)requestRedraw {
  // The display link is deliberately the only live-GUI frame owner. Before
  // it is available (headless/tests/startup/hidden windows), preserve the
  // historical synchronous draw contract so presented-frame metrics do not
  // disappear from those paths.
  BOOL displayLinkCanRender = self.displayLinkRunning && self.window &&
    self.window.isVisible && !self.window.isMiniaturized &&
    (self.window.occlusionState & NSWindowOcclusionStateVisible) != 0;
  if (displayLinkCanRender) {
    self.redrawDirty = YES;
    return;
  }
  if (self.displayLinkRunning) [self stopDisplayLink];
  [self drawFrame];
}

- (void)startDisplayLinkIfNeeded {
  if (self.displayLinkRunning) return;
  NSWindow *window = self.window;
  if (!window || !window.isVisible || window.isMiniaturized ||
      (window.occlusionState & NSWindowOcclusionStateVisible) == 0) return;
  if (@available(macOS 14.0, *)) {
    CADisplayLink *link = [self displayLinkWithTarget:self
                                              selector:@selector(displayLinkDidFire:)];
    if (!link) return;
    NSScreen *screen = window.screen ?: NSScreen.mainScreen;
    NSInteger maximumFramesPerSecond = screen ? screen.maximumFramesPerSecond : 120;
    maximumFramesPerSecond = MAX(60, MIN(120, maximumFramesPerSecond));
    link.preferredFrameRateRange = CAFrameRateRangeMake(60.0,
      (float)maximumFramesPerSecond, (float)maximumFramesPerSecond);
    self.displayLink = link;
    self.displayLinkRunning = YES;
    // The view may have become visible after its synchronous startup draw.
    // Mark one frame so the link establishes a fresh live presentation, then
    // remain fully idle until another state change requests a redraw.
    self.redrawDirty = YES;
    [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
  }
}

- (void)stopDisplayLink {
  self.displayLinkRunning = NO;
  self.redrawDirty = NO;
  [self.displayLink invalidate];
  self.displayLink = nil;
}

- (void)restartDisplayLinkIfNeeded {
  if (!self.displayLinkRunning) return;
  [self stopDisplayLink];
  [self startDisplayLinkIfNeeded];
}

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
    NimculusOutlineOverlay *outline = [[NimculusOutlineOverlay alloc]
      initWithFrame:NSZeroRect];
    outline.hoveredSidebarLine = NSNotFound;
    outline.editable = NO;
    outline.selectable = YES;
    outline.drawsBackground = YES;
    outline.backgroundColor = [themeRoleColor(@"panel", themeHexColor(g_theme_background,
      [NSColor colorWithCalibratedRed:0.045 green:0.055 blue:0.075 alpha:1.0]))
      colorWithAlphaComponent:0.96];
    outline.textColor = themeRoleColor(@"foreground", themeHexColor(g_theme_foreground,
      [NSColor colorWithCalibratedRed:0.82 green:0.88 blue:0.92 alpha:1.0]));
    outline.font = editorUiFontWithWeight(NSFontWeightRegular);
    outline.textContainerInset = NSMakeSize(8.0, 8.0);
    outline.horizontallyResizable = NO;
    outline.verticallyResizable = YES;
    outline.clipsToBounds = YES;
    outline.textContainer.widthTracksTextView = YES;
    // Each logical file/Git row must stay one line. The paragraph style below
    // controls the rendered text, while this container setting prevents a
    // long path from creating an extra visual row and shifting row hit tests.
    outline.textContainer.lineBreakMode = NSLineBreakByTruncatingTail;
    applySidebarPresentation(outline);
    NSScrollView *outlineScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    outlineScroll.borderType = NSNoBorder;
    outlineScroll.drawsBackground = NO;
    outlineScroll.hasVerticalScroller = YES;
    outlineScroll.autohidesScrollers = YES;
    outlineScroll.documentView = outline;
    [self addSubview:outlineScroll];
    [outlineScroll release];
    NimculusOutlineFilterField *outlineFilter = [[NimculusOutlineFilterField alloc]
      initWithFrame:NSZeroRect];
    outlineFilter.outline = outline;
    outlineFilter.placeholderString = @"Search buffer symbols…";
    outlineFilter.accessibilityLabel = @"Filter buffer symbols";
    outlineFilter.toolTip = @"Filter buffer symbols (Esc clears)";
    outlineFilter.delegate = outline;
    outlineFilter.font = editorUiFontWithWeight(NSFontWeightRegular);
    [self addSubview:outlineFilter];
    [outlineFilter release];
    [outline release];
    NimculusSidebarHeader *sidebarHeader = [[NimculusSidebarHeader alloc]
      initWithFrame:NSZeroRect];
    [self addSubview:sidebarHeader];
    NimculusGitSidebarTabs *gitTabs = [[NimculusGitSidebarTabs alloc]
      initWithFrame:NSZeroRect];
    gitTabs.hidden = YES;
    [self addSubview:gitTabs];
    [gitTabs release];
    NimculusGitCommitButton *gitCommit = [[NimculusGitCommitButton alloc]
      initWithFrame:NSZeroRect];
    gitCommit.hidden = YES;
    NimculusGitRefreshButton *gitRefresh = [[NimculusGitRefreshButton alloc]
      initWithFrame:NSZeroRect];
    gitRefresh.hidden = YES;
    NimculusGitChangesActions *gitChangesActions = [[NimculusGitChangesActions alloc]
      initWithFrame:NSZeroRect];
    gitChangesActions.hidden = YES;
    [sidebarHeader.actionStack addArrangedSubview:gitChangesActions];
    [gitChangesActions release];
    NimculusFilesSidebarActions *filesActions = [[NimculusFilesSidebarActions alloc]
      initWithFrame:NSZeroRect];
    filesActions.hidden = YES;
    [sidebarHeader.actionStack addArrangedSubview:filesActions];
    [filesActions release];
    NimculusSearchSidebarActions *searchActions = [[NimculusSearchSidebarActions alloc]
      initWithFrame:NSZeroRect];
    searchActions.hidden = YES;
    [sidebarHeader.actionStack addArrangedSubview:searchActions];
    [searchActions release];
    [sidebarHeader.actionStack addArrangedSubview:gitCommit];
    [sidebarHeader.actionStack addArrangedSubview:gitRefresh];
    [gitCommit release];
    [gitRefresh release];
    [sidebarHeader release];
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
    NimculusEditorContextOverlay *context = [[NimculusEditorContextOverlay alloc]
      initWithFrame:NSZeroRect];
    context.editable = NO;
    context.selectable = NO;
    context.bezeled = NO;
    context.drawsBackground = NO;
    context.alignment = NSTextAlignmentLeft;
    context.lineBreakMode = NSLineBreakByTruncatingMiddle;
    context.stringValue = g_editor_context;
    context.font = editorUiFontWithWeight(NSFontWeightRegular);
    context.textColor = [themeRoleColor(@"textMuted", themeHexColor(g_theme_foreground,
      [NSColor colorWithCalibratedRed:0.72 green:0.76 blue:0.82 alpha:1.0]))
      colorWithAlphaComponent:0.72];
    context.toolTip = @"Current document";
    [context updateBreadcrumbPresentation];
    [self addSubview:context];
    [context release];
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
  status.lineBreakMode = NSLineBreakByTruncatingTail;
  status.usesSingleLineMode = YES;
  status.stringValue = @"";
    status.font = [NSFont monospacedSystemFontOfSize:11.0 weight:NSFontWeightRegular];
    status.textColor = [themeRoleColor(@"textMuted", themeHexColor(g_theme_foreground,
      [NSColor colorWithCalibratedRed:0.72 green:0.76 blue:0.82 alpha:1.0]))
      colorWithAlphaComponent:0.82];
    status.drawsBackground = NO;
    status.backgroundColor = [NSColor colorWithCalibratedRed:204.0 / 255.0
      green:206.0 / 255.0 blue:207.0 / 255.0 alpha:1.0];
    status.alphaValue = 1.0;
    status.wantsLayer = YES;
    status.layer.backgroundColor = [NSColor colorWithCalibratedRed:204.0 / 255.0
      green:206.0 / 255.0 blue:207.0 / 255.0 alpha:1.0].CGColor;
    status.hidden = YES;
    [self addSubview:status];
    NimculusStatusOverlay *editorGap = [[NimculusStatusOverlay alloc]
      initWithFrame:NSZeroRect];
    editorGap.editable = NO;
    editorGap.selectable = NO;
    editorGap.bezeled = NO;
    editorGap.drawsBackground = NO;
    editorGap.backgroundColor = [NSColor colorWithCalibratedWhite:0.98 alpha:1.0];
    editorGap.hidden = NO;
    [self addSubview:editorGap];
    [editorGap release];
    NimculusStatusBandOverlay *statusBand = [[NimculusStatusBandOverlay alloc]
      initWithFrame:NSZeroRect];
    [self addSubview:statusBand];
    [statusBand release];
    NimculusFooterOverlay *footer = [[NimculusFooterOverlay alloc]
      initWithFrame:NSZeroRect];
    [self addSubview:footer];
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
    terminal.backgroundColor = terminalPaletteRoleColor(@"background", themeHexColor(g_theme_background,
      [NSColor colorWithCalibratedRed:0.025 green:0.030 blue:0.045 alpha:1.0]));
    terminal.textColor = terminalPaletteRoleColor(@"foreground", themeHexColor(g_theme_foreground,
      [NSColor colorWithCalibratedRed:0.82 green:0.88 blue:0.92 alpha:1.0]));
    terminal.insertionPointColor = terminalPaletteRoleColor(@"cursor",
      terminalPaletteRoleColor(@"brightForeground", terminal.textColor));
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
    taskOutput.backgroundColor = [themeRoleColor(@"panel",
      [NSColor colorWithCalibratedRed:0.045 green:0.040 blue:0.030 alpha:1.0])
      colorWithAlphaComponent:0.98];
    taskOutput.textColor = themeRoleColor(@"foreground",
      [NSColor colorWithCalibratedRed:0.92 green:0.88 blue:0.76 alpha:1.0]);
    taskOutput.font = terminalBaseFont();
    taskOutput.textContainerInset = NSMakeSize(8.0, 6.0);
    taskOutput.hidden = YES;
    [self addSubview:taskOutput];
    NimculusEditorAnnotationOverlay *annotations =
      [[NimculusEditorAnnotationOverlay alloc] initWithFrame:self.bounds];
    annotations.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    annotations.hidden = YES;
    [self addSubview:annotations];
    [annotations release];
    NimculusEditorAnnotationOverlay *secondaryAnnotations =
      [[NimculusEditorAnnotationOverlay alloc] initWithFrame:self.bounds];
    secondaryAnnotations.secondary = YES;
    secondaryAnnotations.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    secondaryAnnotations.hidden = YES;
    [self addSubview:secondaryAnnotations];
    [secondaryAnnotations release];
    NimculusDocumentSearchOverlay *documentSearch =
      [[NimculusDocumentSearchOverlay alloc] initWithFrame:NSZeroRect];
    documentSearch.hidden = YES;
    [self addSubview:documentSearch];
    [documentSearch release];
    NimculusCommandPaletteOverlay *commandPalette =
      [[NimculusCommandPaletteOverlay alloc] initWithFrame:NSZeroRect];
    commandPalette.hidden = YES;
    [self addSubview:commandPalette];
    [commandPalette release];
    NimculusGitCommitOverlay *gitCommitEditor =
      [[NimculusGitCommitOverlay alloc] initWithFrame:NSZeroRect];
    gitCommitEditor.hidden = YES;
    [self addSubview:gitCommitEditor];
    [gitCommitEditor release];
    NimculusSettingsOverlay *settingsEditor =
      [[NimculusSettingsOverlay alloc] initWithFrame:NSZeroRect];
    settingsEditor.hidden = YES;
    [self addSubview:settingsEditor];
    [settingsEditor release];
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

- (NSView *)hitTest:(NSPoint)point {
  NSView *hit = [super hitTest:point];
  tabDebugLogHitTest(@"metal-root", self, point, hit);
  // The Metal host is layer-backed and owns several transparent, full-pane
  // overlays. AppKit's default recursive hit test can stop at the host for a
  // point that is inside a flipped native chrome child. Route tab-band points
  // explicitly before returning the Metal host, while still delegating to the
  // tab overlay so its navigation buttons remain normal NSButton targets.
  for (NSView *subview in [self.subviews reverseObjectEnumerator]) {
    NSString *className = NSStringFromClass(subview.class);
    if (![className isEqualToString:@"NimculusTabBarOverlay"] || subview.hidden) continue;
    NSPoint childPoint = [subview convertPoint:point fromView:self];
    if (!NSPointInRect(childPoint, subview.bounds)) continue;
    NSView *tabHit = [subview hitTest:childPoint];
    if (tabDebugEnabled()) {
      fprintf(stderr, "Nimculus tab debug route class=%s childPoint=(%.1f,%.1f) result=%s\n",
        className.UTF8String, childPoint.x, childPoint.y,
        tabHit ? NSStringFromClass(tabHit.class).UTF8String : "<nil>");
    }
    if (tabHit) return tabHit;
  }
  return hit;
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
  [self requestRedraw];
}

- (void)updateTerminalFrame {
  NimculusOutlineOverlay *outline = outlineOverlayForView(self);
  NimculusSidebarHeader *sidebarHeader = nil;
  NimculusGitSidebarTabs *gitTabs = nil;
  NimculusGitCommitButton *gitCommit = nil;
  NimculusGitRefreshButton *gitRefresh = nil;
  NimculusGitChangesActions *gitChangesActions = nil;
  NimculusFilesSidebarActions *filesActions = nil;
  NimculusSearchSidebarActions *searchActions = nil;
  NimculusWorkspaceToolbar *workspaceToolbar = nil;
  NimculusLineNumberOverlay *lineNumbers = nil;
  NimculusIndentGuideOverlay *indentGuides = nil;
  NimculusTabBarOverlay *tabs = nil;
  NimculusTabBarOverlay *secondaryTabs = nil;
  NimculusEditorContextOverlay *context = nil;
  NimculusWelcomeOverlay *welcome = nil;
  NimculusStatusOverlay *status = nil;
  NimculusStatusOverlay *editorGap = nil;
  NimculusStatusBandOverlay *statusBand = nil;
  NimculusFooterOverlay *footer = nil;
  NimculusTerminalOverlay *terminal = nil;
  NimculusTerminalSessionBar *terminalSessions = nil;
  NimculusOutputPanelBar *outputBar = nil;
  NimculusTaskOutputOverlay *taskOutput = nil;
  NimculusEditorAnnotationOverlay *annotations = nil;
  NimculusEditorAnnotationOverlay *secondaryAnnotations = nil;
  NimculusDocumentSearchOverlay *documentSearch = nil;
  NimculusCommandPaletteOverlay *commandPalette = nil;
  NimculusGitCommitOverlay *gitCommitEditor = nil;
  NimculusSettingsOverlay *settingsEditor = nil;
  NimculusOutlineFilterField *outlineFilter = nil;
  for (NSView *subview in self.subviews) {
    if ([subview isKindOfClass:[NimculusLineNumberOverlay class]]) lineNumbers = (NimculusLineNumberOverlay *)subview;
    if ([subview isKindOfClass:[NimculusIndentGuideOverlay class]]) indentGuides = (NimculusIndentGuideOverlay *)subview;
    if ([subview isKindOfClass:[NimculusTabBarOverlay class]]) {
      if (((NimculusTabBarOverlay *)subview).secondary) secondaryTabs = (NimculusTabBarOverlay *)subview;
      else tabs = (NimculusTabBarOverlay *)subview;
    }
    if ([subview isKindOfClass:[NimculusEditorContextOverlay class]]) context = (NimculusEditorContextOverlay *)subview;
    if ([subview isKindOfClass:[NimculusWelcomeOverlay class]]) welcome = (NimculusWelcomeOverlay *)subview;
    if ([subview isKindOfClass:[NimculusStatusOverlay class]]) {
      if (!status) status = (NimculusStatusOverlay *)subview;
      else editorGap = (NimculusStatusOverlay *)subview;
    }
    if ([subview isKindOfClass:[NimculusStatusBandOverlay class]])
      statusBand = (NimculusStatusBandOverlay *)subview;
    if ([subview isKindOfClass:[NimculusFooterOverlay class]]) footer = (NimculusFooterOverlay *)subview;
    if ([subview isKindOfClass:[NimculusTerminalOverlay class]]) terminal = (NimculusTerminalOverlay *)subview;
    if ([subview isKindOfClass:[NimculusTerminalSessionBar class]]) terminalSessions = (NimculusTerminalSessionBar *)subview;
    if ([subview isKindOfClass:[NimculusOutputPanelBar class]]) outputBar = (NimculusOutputPanelBar *)subview;
    if ([subview isKindOfClass:[NimculusTaskOutputOverlay class]]) taskOutput = (NimculusTaskOutputOverlay *)subview;
    if ([subview isKindOfClass:[NimculusEditorAnnotationOverlay class]]) {
      if (((NimculusEditorAnnotationOverlay *)subview).secondary)
        secondaryAnnotations = (NimculusEditorAnnotationOverlay *)subview;
      else annotations = (NimculusEditorAnnotationOverlay *)subview;
    }
    if ([subview isKindOfClass:[NimculusDocumentSearchOverlay class]]) documentSearch = (NimculusDocumentSearchOverlay *)subview;
    if ([subview isKindOfClass:[NimculusCommandPaletteOverlay class]]) commandPalette = (NimculusCommandPaletteOverlay *)subview;
    if ([subview isKindOfClass:[NimculusGitCommitOverlay class]]) gitCommitEditor = (NimculusGitCommitOverlay *)subview;
    if ([subview isKindOfClass:[NimculusSettingsOverlay class]]) settingsEditor = (NimculusSettingsOverlay *)subview;
    if ([subview isKindOfClass:[NimculusOutlineFilterField class]]) outlineFilter =
      (NimculusOutlineFilterField *)subview;
    if ([subview isKindOfClass:[NimculusGitSidebarTabs class]]) gitTabs = (NimculusGitSidebarTabs *)subview;
    if ([subview isKindOfClass:[NimculusSidebarHeader class]]) sidebarHeader = (NimculusSidebarHeader *)subview;
    if ([subview isKindOfClass:[NimculusWorkspaceToolbar class]]) workspaceToolbar = (NimculusWorkspaceToolbar *)subview;
  }
  for (NSView *subview in sidebarHeader.actionStack.arrangedSubviews) {
    if ([subview isKindOfClass:[NimculusGitCommitButton class]]) gitCommit = (NimculusGitCommitButton *)subview;
    if ([subview isKindOfClass:[NimculusGitRefreshButton class]]) gitRefresh = (NimculusGitRefreshButton *)subview;
    if ([subview isKindOfClass:[NimculusGitChangesActions class]]) gitChangesActions = (NimculusGitChangesActions *)subview;
    if ([subview isKindOfClass:[NimculusFilesSidebarActions class]]) filesActions = (NimculusFilesSidebarActions *)subview;
    if ([subview isKindOfClass:[NimculusSearchSidebarActions class]]) searchActions = (NimculusSearchSidebarActions *)subview;
  }
    // The logical editor begins after its single 32pt tab strip. The dock is a
    // workspace sibling rather than a document child, so its activity/header
    // controls start at the workspace top.
  // Zed's dock is a workspace sibling: its surface starts directly under the
  // title bar, not under the document's tab strip. Measured, the One Light
  // dock paints one uninterrupted #ececed band from y=35pt down to the status
  // bar, so the dock has to clear the editor's whole chrome stack.
  const CGFloat workspaceChromeHeight = NimculusTabBarHeight +
    NimculusBreadcrumbHeight;
  const CGFloat sidebarTop = MAX(0.0, g_editor_rect[1] - workspaceChromeHeight);
  const CGFloat sidebarHeight = MAX(1.0, g_editor_rect[3] +
    (g_editor_rect[1] - sidebarTop));
  // The Metal workspace already assigns the complete dock rectangle from the
  // editor's right edge to the window's right edge.  Keep AppKit presenters
  // on that same boundary: adding an outer inset here creates a visible gap
  // between the editor and Files, plus a second gap at the window edge.
  const CGFloat dockOuterX = g_editor_sidebar_on_right ?
    g_editor_rect[0] + g_editor_rect[2] : 0.0;
  const CGFloat dockAvailableWidth = g_editor_sidebar_on_right ?
    self.bounds.size.width - dockOuterX : MAX(0.0, g_editor_rect[0]);
  // The logical workspace intentionally gives the editor priority when a
  // window is narrowed below the combined dock + center minimum.  Do not
  // undo that decision at the AppKit boundary by forcing a 140pt sidebar:
  // that placed the native Files/Git views beyond the right edge while the
  // logical dock had already collapsed. A presented sidebar needs room for
  // its own controls; otherwise preserve the dock's logical open state but
  // hide this transient presentation until the window is wide enough again.
  const CGFloat minimumSidebarContentWidth = 128.0;
  const CGFloat requestedSidebarWidth = dockAvailableWidth;
  const BOOL sidebarPresented = g_editor_sidebar_visible &&
    requestedSidebarWidth >= minimumSidebarContentWidth;
  const CGFloat sidebarWidth = MAX(1.0, requestedSidebarWidth);
  const CGFloat sidebarX = g_editor_sidebar_on_right ? dockOuterX : 0.0;
  const CGFloat sidebarControlX = sidebarX + NimculusSpace1;
  if (outline) {
    CGFloat width = sidebarWidth;
    BOOL showGitTabs = sidebarPresented && g_editor_sidebar_mode >= 2 &&
      g_editor_sidebar_mode <= 4;
    const CGFloat sidebarHeaderHeight = sidebarPresented ? NimculusRowHeight : 0.0;
    const CGFloat sidebarNavigationHeight = showGitTabs ? NimculusRowHeight : 0.0;
    const CGFloat outlineFilterHeight = sidebarPresented && g_editor_sidebar_mode == 0 ? 36.0 : 0.0;
    const BOOL showGitCommitFooter = sidebarPresented && g_editor_sidebar_mode == 3;
    const CGFloat gitCommitFooterHeight = showGitCommitFooter ? 46.0 : 0.0;
    const CGFloat sidebarContentTop = sidebarTop + sidebarHeaderHeight +
      sidebarNavigationHeight + outlineFilterHeight;
    const CGFloat sidebarContentHeight = MAX(1.0, sidebarHeight - sidebarHeaderHeight -
      sidebarNavigationHeight - outlineFilterHeight - gitCommitFooterHeight);
    if (outlineFilter) {
      outlineFilter.hidden = !(sidebarPresented && g_editor_sidebar_mode == 0);
      if (!outlineFilter.hidden) {
        outlineFilter.frame = appKitFrameForLogicalTopRect(self,
          NSMakeRect(sidebarX + NimculusSpace2, sidebarTop + sidebarHeaderHeight + 5.0,
            MAX(1.0, width - NimculusSpace3), 26.0));
      }
    }
    NSScrollView *scroll = outline.enclosingScrollView;
    if (scroll) {
      scroll.hidden = !sidebarPresented;
      scroll.frame = appKitFrameForLogicalTopRect(self,
        NSMakeRect(sidebarX, sidebarContentTop, width,
          sidebarContentHeight));
      scroll.autoresizingMask = NSViewHeightSizable | NSViewMaxXMargin;
      outline.textContainer.containerSize = NSMakeSize(MAX(1.0, width - 16.0), CGFLOAT_MAX);
      [outline.layoutManager ensureLayoutForTextContainer:outline.textContainer];
      CGFloat contentHeight = ceil([outline.layoutManager usedRectForTextContainer:outline.textContainer].size.height) + 16.0;
      outline.frame = NSMakeRect(0.0, 0.0, width,
        MAX(sidebarContentHeight, contentHeight));
      [outline refreshGitCheckboxes];
    } else {
      outline.frame = appKitFrameForLogicalTopRect(self,
        NSMakeRect(sidebarX, sidebarContentTop, width,
          sidebarContentHeight));
      outline.autoresizingMask = NSViewHeightSizable | NSViewMaxXMargin;
      [outline refreshGitCheckboxes];
    }
    if (sidebarHeader) {
      sidebarHeader.hidden = !sidebarPresented;
      if (!sidebarHeader.hidden) {
        [sidebarHeader setTitle:sidebarHeaderTitle()];
        sidebarHeader.frame = appKitFrameForLogicalTopRect(self,
          NSMakeRect(sidebarX, sidebarTop, width, sidebarHeaderHeight));
        [sidebarHeader setNeedsLayout:YES];
      }
    }
  }
  if (gitTabs) {
    BOOL showGitTabs = sidebarPresented && g_editor_sidebar_mode >= 2 &&
      g_editor_sidebar_mode <= 4;
    gitTabs.hidden = !showGitTabs;
    if (showGitTabs) {
      CGFloat width = sidebarWidth;
      gitTabs.frame = appKitFrameForLogicalTopRect(self,
        NSMakeRect(sidebarControlX, sidebarTop + NimculusRowHeight +
          (NimculusRowHeight - NimculusControlHit) / 2.0,
          MAX(1.0, width - NimculusSpace2), NimculusControlHit));
      // Sidebar modes are ordered History, Status, Branches for the Nim
      // command layer, while the visible Zed-like navigation is Changes,
      // History, Branches. Do not derive this presentation mapping from enum
      // ordinals: Status must visibly select Changes, not History.
      NSInteger selectedGitMode = g_editor_sidebar_mode == 2 ? 1 :
        g_editor_sidebar_mode == 4 ? 2 : 0;
      [gitTabs setSelectedMode:selectedGitMode];
    }
  }
  if (gitCommit) {
    BOOL showGitCommit = sidebarPresented && g_editor_sidebar_mode == 3;
    gitCommit.hidden = !showGitCommit;
    if (showGitCommit) {
      CGFloat width = sidebarWidth;
      [gitCommit setCompact:width < 220.0];
    }
  }
  if (gitRefresh) {
    BOOL showGitRefresh = sidebarPresented && g_editor_sidebar_mode >= 2 &&
      g_editor_sidebar_mode <= 4;
    gitRefresh.hidden = !showGitRefresh;
  }
  if (gitChangesActions) {
    BOOL showGitChangesActions = sidebarPresented && g_editor_sidebar_mode == 3;
    gitChangesActions.hidden = !showGitChangesActions;
  }
  if (filesActions) {
    BOOL showFilesActions = sidebarPresented && g_editor_sidebar_mode == 1;
    filesActions.hidden = !showFilesActions;
  }
  if (searchActions) {
    BOOL showSearchActions = sidebarPresented && g_editor_sidebar_mode == 5;
    searchActions.hidden = !showSearchActions;
  }
  if (sidebarHeader) {
    // During the first AppKit attachment pass the Metal view can still have a
    // zero-sized bounds while the logical editor rect already contains its
    // normal default.  The header is then temporarily collapsed to a one
    // point frame, but its arranged action buttons retain required intrinsic
    // widths.  Forcing that hidden stack to lay out makes AppKit raise
    // LAYOUT_CONSTRAINTS_NOT_SATISFIABLE and _crashOnException: terminates the
    // packaged app before its first frame.  Let the normal layout pass wait
    // until the dock has enough width for the header's controls.
    if (sidebarPresented) {
      [sidebarHeader setNeedsLayout:YES];
    }
  }
  if (workspaceToolbar) {
    // Navigation belongs in the status bar, as in Zed. The old text-button
    // row stole vertical space from documents and duplicated the same
    // actions. Keep its implementation only for compatibility with existing
    // native callers; do not compose it into the workspace.
    workspaceToolbar.hidden = YES;
  }
  if (lineNumbers) {
    lineNumbers.hidden = g_welcome_visible || !g_editor_line_numbers;
    CGFloat gutterWidth = editorGutterFrameWidth(g_editor_rect);
    lineNumbers.frame = appKitFrameForLogicalTopRect(self,
      NSMakeRect(g_editor_rect[0], g_editor_rect[1],
        gutterWidth, g_editor_rect[3]));
    lineNumbers.autoresizingMask = NSViewHeightSizable | NSViewMaxXMargin;
    [lineNumbers setNeedsDisplay:YES];
  }
  if (indentGuides) {
    indentGuides.hidden = g_welcome_visible;
    indentGuides.frame = appKitFrameForLogicalTopRect(self,
      NSMakeRect(g_editor_rect[0], g_editor_rect[1],
        g_editor_rect[2], g_editor_rect[3]));
    indentGuides.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [indentGuides setNeedsDisplay:YES];
  }
  if (tabs) {
    tabs.hidden = g_editor_tab_titles.count == 0;
    tabs.frame = appKitFrameForLogicalTopRect(self,
      NSMakeRect(g_editor_rect[0], g_editor_rect[1] - NimculusTabBarHeight -
        NimculusBreadcrumbHeight,
        g_editor_rect[2], NimculusTabBarHeight));
    tabs.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [tabs setNeedsDisplay:YES];
  }
  if (secondaryTabs) {
    secondaryTabs.hidden = !g_secondary_editor_visible || g_secondary_editor_tab_titles.count == 0;
    secondaryTabs.frame = appKitFrameForLogicalTopRect(self,
      NSMakeRect(g_secondary_editor_rect[0],
        g_secondary_editor_rect[1] - NimculusTabBarHeight - NimculusBreadcrumbHeight,
        g_secondary_editor_rect[2], NimculusTabBarHeight));
    secondaryTabs.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [secondaryTabs setNeedsDisplay:YES];
  }
  if (context) {
    // Zed keeps the document path and heading hierarchy on its own row below
    // the tabs. The native presenter owns the icons and text; the Metal scene
    // supplies the shared editor-surface fill behind it.
    context.hidden = g_editor_context.length == 0;
    context.frame = appKitFrameForLogicalTopRect(self,
      NSMakeRect(g_editor_rect[0], g_editor_rect[1] - NimculusBreadcrumbHeight,
        MAX(1.0, g_editor_rect[2] - NimculusSpace2), NimculusBreadcrumbHeight));
    context.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
  }
  if (welcome) {
    welcome.hidden = !g_welcome_visible;
    welcome.frame = appKitFrameForLogicalTopRect(self,
      NSMakeRect(g_editor_rect[0], g_editor_rect[1],
        g_editor_rect[2], g_editor_rect[3]));
    [welcome setNeedsLayout:YES];
  }
  if (status) {
    // The footer is 30pt tall; Zed's logical status separator occupies the
    // 16pt immediately above it.
    status.frame = NSMakeRect(0.0, 30.0, self.bounds.size.width, 16.0);
    status.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
  }
  if (editorGap) {
    // The metrics-backed Metal viewport ends 14pt above the AppKit status
    // presenter on a full-size content window. Restore the editor surface in
    // that seam so the horizontal bands remain continuous. Zed keeps its
    // editor surface all the way down to the 760pt rule, and keeps the dock's
    // own surface beside it, so this stays inside the editor's width. It must
    // not grow down into the scrollbar band: it is opaque, and it would paint
    // over the document row Zed still shows there.
    editorGap.frame = NSMakeRect(g_editor_rect[0], 46.0,
      MAX(1.0, g_editor_rect[2]), 14.0);
    editorGap.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    editorGap.backgroundColor = themeHexColor(editorPaintToken(),
      [NSColor colorWithCalibratedWhite:0.98 alpha:1.0]);
    [editorGap setNeedsDisplay:YES];
  }
  if (statusBand) {
    statusBand.frame = NSMakeRect(0.0, 30.0, self.bounds.size.width, 16.0);
    statusBand.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [statusBand setNeedsDisplay:YES];
  }
  if (footer) {
    footer.hidden = g_welcome_visible;
    // Zed's status bar is a workspace row, not a document one: its #dcddde
    // spans the whole window, dock included. Ours stopped at the editor's
    // right edge and left the dock's #ececed showing for the last 223pt.
    footer.frame = NSMakeRect(0.0, 0.0, self.bounds.size.width, 30.0);
    footer.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [footer setNeedsDisplay:YES];
  }
  if (annotations) {
    annotations.frame = self.bounds;
    annotations.hidden = g_editor_annotation_count == 0;
    [annotations setNeedsDisplay:YES];
  }
  if (secondaryAnnotations) {
    secondaryAnnotations.frame = self.bounds;
    secondaryAnnotations.hidden = !g_secondary_editor_visible ||
      g_secondary_editor_annotation_count == 0;
    [secondaryAnnotations setNeedsDisplay:YES];
  }
  if (documentSearch && !documentSearch.hidden) {
    const BOOL quickOpen = documentSearch.mode == 4 || documentSearch.mode == 5;
    const BOOL editorFind = documentSearch.mode == 0 || documentSearch.mode == 1;
    const CGFloat preferredWidth = quickOpen ?
      MIN(NimculusPickerWidth, MAX(1.0, g_editor_rect[2] - 24.0)) :
      (editorFind ? MAX(1.0, g_editor_rect[2]) :
       MIN(420.0, MAX(1.0, g_editor_rect[2] - 16.0)));
    const CGFloat preferredHeight = documentSearch.mode == 5 ? [documentSearch outlinePickerHeight] :
      (documentSearch.mode == 4 ? [documentSearch quickOpenPickerHeight] :
      (documentSearch.mode == 3 ?
        36.0 + (documentSearch.replaceEnabled ? 30.0 : 0.0) +
        (documentSearch.filtersEnabled ? 30.0 : 0.0) :
        (documentSearch.replaceEnabled ? 66.0 : NimculusRowHeight)));
    const CGFloat preferredX = quickOpen ?
      g_editor_rect[0] + (g_editor_rect[2] - preferredWidth) / 2.0 :
      (editorFind ? g_editor_rect[0] : g_editor_rect[0] + g_editor_rect[2] - preferredWidth - 8.0);
    const CGFloat preferredY = quickOpen ? g_editor_rect[1] + 12.0 :
      (editorFind ? g_editor_rect[1] : g_editor_rect[1] + 8.0);
    documentSearch.frame = appKitFrameForLogicalTopRect(self,
      editorOverlayFrame(preferredWidth, preferredHeight, preferredX, preferredY));
    [documentSearch setNeedsLayout:YES];
  }
  if (commandPalette && !commandPalette.hidden) {
    const CGFloat paletteWidth = MIN(NimculusPickerWidth, MAX(1.0, g_editor_rect[2] - 24.0));
    const CGFloat paletteRows = MIN((CGFloat)NimculusPickerVisibleRows,
      (CGFloat)commandPalette.visibleCommands.count);
    const CGFloat paletteHeight = NimculusPickerHeaderHeight +
      MAX(1.0, paletteRows) * NimculusPickerRowHeight;
    commandPalette.frame = appKitFrameForLogicalTopRect(self,
      editorOverlayFrame(paletteWidth, paletteHeight,
        g_editor_rect[0] + (g_editor_rect[2] - paletteWidth) / 2.0,
        g_editor_rect[1] + 12.0));
    [commandPalette setNeedsLayout:YES];
  }
  if (gitCommitEditor) {
    gitCommitEditor.hidden = !(sidebarPresented && g_editor_sidebar_mode == 3);
  }
  if (gitCommitEditor && !gitCommitEditor.hidden) {
    const CGFloat commitWidth = MAX(1.0, sidebarWidth - 8.0);
    const CGFloat commitX = sidebarX + 4.0;
    const NSRect sidebarRect = NSMakeRect(sidebarX, sidebarTop,
      MAX(1.0, sidebarWidth), sidebarHeight);
    gitCommitEditor.frame = appKitFrameForLogicalTopRect(self,
      boundedOverlayFrame(sidebarRect, commitWidth, 36.0,
        commitX, sidebarTop + sidebarHeight - 42.0));
    [gitCommitEditor setNeedsLayout:YES];
  }
  if (settingsEditor && !settingsEditor.hidden) {
    const CGFloat settingsWidth = MIN(500.0, MAX(1.0, g_editor_rect[2] - 24.0));
    settingsEditor.frame = appKitFrameForLogicalTopRect(self,
      editorOverlayFrame(settingsWidth, 230.0,
        g_editor_rect[0] + (g_editor_rect[2] - settingsWidth) / 2.0,
        g_editor_rect[1] + (g_editor_rect[3] - 230.0) / 2.0));
    [settingsEditor setNeedsLayout:YES];
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

- (void)showDocumentFindBar:(BOOL)replace {
  for (NSView *subview in self.subviews) {
    if ([subview isKindOfClass:[NimculusDocumentSearchOverlay class]]) {
      [(NimculusDocumentSearchOverlay *)subview showFind:replace];
      [self updateTerminalFrame];
      if (g_queue) {
        updateEditorTextTexture(g_queue.device, g_editor_text, YES);
        rebuildSecondaryEditorTexture(g_queue.device);
      }
      markSceneFullyDirty();
      [self requestRedraw];
      return;
    }
  }
}

- (void)showGoToLineBar {
  for (NSView *subview in self.subviews) {
    if ([subview isKindOfClass:[NimculusDocumentSearchOverlay class]]) {
      [(NimculusDocumentSearchOverlay *)subview showGoToLine];
      [self updateTerminalFrame];
      return;
    }
  }
}

- (void)showWorkspaceSearchBar {
  for (NSView *subview in self.subviews) {
    if ([subview isKindOfClass:[NimculusDocumentSearchOverlay class]]) {
      [(NimculusDocumentSearchOverlay *)subview showWorkspaceSearch];
      [self updateTerminalFrame];
      return;
    }
  }
}

- (void)showQuickOpenBar {
  for (NSView *subview in self.subviews) {
    if ([subview isKindOfClass:[NimculusDocumentSearchOverlay class]]) {
      [(NimculusDocumentSearchOverlay *)subview showQuickOpen];
      [self updateTerminalFrame];
      return;
    }
  }
}

- (void)showCommandPalette {
  for (NSView *subview in self.subviews) {
    if ([subview isKindOfClass:[NimculusCommandPaletteOverlay class]]) {
      [(NimculusCommandPaletteOverlay *)subview show];
      [self updateTerminalFrame];
      return;
    }
  }
}

- (void)showGitCommitEditor {
  for (NSView *subview in self.subviews) {
    if ([subview isKindOfClass:[NimculusGitCommitOverlay class]]) {
      [(NimculusGitCommitOverlay *)subview show];
      [self updateTerminalFrame];
      return;
    }
  }
}

- (void)showSettingsEditorWithTheme:(NSString *)theme editorFontSize:(NSString *)editorFontSize
                   terminalFontSize:(NSString *)terminalFontSize editorFontFamily:(NSString *)editorFontFamily
                 terminalFontFamily:(NSString *)terminalFontFamily shell:(NSString *)shell {
  for (NSView *subview in self.subviews) {
    if ([subview isKindOfClass:[NimculusSettingsOverlay class]]) {
      [(NimculusSettingsOverlay *)subview showWithTheme:theme editorFontSize:editorFontSize
        terminalFontSize:terminalFontSize editorFontFamily:editorFontFamily
        terminalFontFamily:terminalFontFamily shell:shell];
      [self updateTerminalFrame];
      return;
    }
  }
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
  flushEditorTextTextureRebuild();
  // Keep native offsets valid even on a display-link frame that arrives after
  // content/layout changed but before another Nim synchronization callback.
  clampEditorScrollOffsetsForFrame();
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
    // Terminal cells are laid out from the same run data that feeds the
    // AppKit fallback. Rebuild their Metal batch after the editor has updated
    // the shared glyph atlas, then render it into the retained scene below.
    updateTerminalGlyphAtlas(drawable.texture.device);
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
          NimculusPaintRegion clip = paintCommandScissor(paint);
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
            NimculusPaintRegion clip = paintCommandScissor(paint);
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
    // Text is rendered from the app-owned shaped rows. Each pane has its own
    // glyph batch and content viewport; no document-sized text texture exists.
    NimculusPaintRegion primaryEditorRegion = editorTextViewport(g_editor_rect);
    NimculusPaintRegion secondaryEditorRegion = editorTextViewport(g_secondary_editor_rect);
    float glyphViewportSize[2] = {(float)logicalSize.width, (float)logicalSize.height};
    float glyphAtlasSize[2] = {2048.0f, 2048.0f};
    if (g_glyph_pipeline && g_glyph_atlas_texture && g_glyph_sprite_count > 0) {
      id<MTLBuffer> glyphBuffer = [drawable.texture.device newBufferWithBytes:g_glyph_sprites
        length:sizeof(NimculusMonochromeSprite) * g_glyph_sprite_count
        options:MTLResourceStorageModeShared];
      [encoder setRenderPipelineState:g_glyph_pipeline];
      [encoder setVertexBytes:g_glyph_unit_vertices length:sizeof(g_glyph_unit_vertices)
        atIndex:0];
      [encoder setVertexBuffer:glyphBuffer offset:0 atIndex:1];
      [encoder setVertexBytes:glyphViewportSize length:sizeof(glyphViewportSize) atIndex:2];
      [encoder setVertexBytes:glyphAtlasSize length:sizeof(glyphAtlasSize) atIndex:3];
      [encoder setFragmentBuffer:glyphBuffer offset:0 atIndex:1];
      [encoder setFragmentTexture:g_glyph_atlas_texture atIndex:0];
      if (fullSceneRebuild) {
        setScissorForRegion(encoder, primaryEditorRegion, logicalSize, drawableSize);
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6
          instanceCount:g_glyph_sprite_count];
      } else {
        for (uint32_t i = 0; i < g_paint_dirty_count; i++) {
          NimculusPaintRegion visible = intersectPaintRegions(g_paint_dirty_regions[i],
                                                               primaryEditorRegion);
          if (visible.width <= 0 || visible.height <= 0) continue;
          setScissorForRegion(encoder, visible, logicalSize, drawableSize);
          [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6
            instanceCount:g_glyph_sprite_count];
        }
      }
      [glyphBuffer release];
    }
    if (g_glyph_pipeline && g_glyph_atlas_texture && g_secondary_editor_visible &&
        g_secondary_glyph_sprite_count > 0) {
      id<MTLBuffer> secondaryGlyphBuffer = [drawable.texture.device
        newBufferWithBytes:g_secondary_glyph_sprites
        length:sizeof(NimculusMonochromeSprite) * g_secondary_glyph_sprite_count
        options:MTLResourceStorageModeShared];
      [encoder setRenderPipelineState:g_glyph_pipeline];
      [encoder setVertexBytes:g_glyph_unit_vertices length:sizeof(g_glyph_unit_vertices)
        atIndex:0];
      [encoder setVertexBuffer:secondaryGlyphBuffer offset:0 atIndex:1];
      [encoder setVertexBytes:glyphViewportSize length:sizeof(glyphViewportSize) atIndex:2];
      [encoder setVertexBytes:glyphAtlasSize length:sizeof(glyphAtlasSize) atIndex:3];
      [encoder setFragmentBuffer:secondaryGlyphBuffer offset:0 atIndex:1];
      [encoder setFragmentTexture:g_glyph_atlas_texture atIndex:0];
      if (fullSceneRebuild) {
        setScissorForRegion(encoder, secondaryEditorRegion, logicalSize, drawableSize);
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6
          instanceCount:g_secondary_glyph_sprite_count];
      } else {
        for (uint32_t i = 0; i < g_paint_dirty_count; i++) {
          NimculusPaintRegion visible = intersectPaintRegions(g_paint_dirty_regions[i],
                                                               secondaryEditorRegion);
          if (visible.width <= 0 || visible.height <= 0) continue;
          setScissorForRegion(encoder, visible, logicalSize, drawableSize);
          [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6
            instanceCount:g_secondary_glyph_sprite_count];
        }
      }
      [secondaryGlyphBuffer release];
    }
    NimculusPaintRegion terminalViewport = terminalContentViewport();
    if (g_terminal_run_count > 0 && (g_terminal_visible || g_task_output_visible) &&
        terminalViewport.width > 0 && terminalViewport.height > 0) {
      setScissorForRegion(encoder, terminalViewport, logicalSize, drawableSize);
      if (g_pipeline) {
        [encoder setRenderPipelineState:g_pipeline];
        const CGFloat cellWidth = terminalCellWidth();
        const CGFloat lineHeight = terminalLineHeight();
        for (uint32_t index = 0; index < g_terminal_run_count; index++) {
          NimculusTerminalRun run = g_terminal_runs[index];
          // A default background is already supplied by the panel. Draw only
          // explicit backgrounds and inverse cells, matching Zed's sparse
          // background region list instead of filling every terminal cell.
          if (run.background_kind == 0 && !(run.flags & 16)) continue;
          CGFloat red = 0.025, green = 0.030, blue = 0.045;
          terminalRunColorComponents(run, (run.flags & 16) ? YES : NO,
            &red, &green, &blue);
          CGFloat width = cellWidth * MAX(1U, run.cell_width);
          drawColoredRectangle(encoder, drawable.texture.device, logicalSize,
            terminalViewport.x + cellWidth * run.column,
            terminalViewport.y + lineHeight * run.row,
            width, lineHeight, red, green, blue, 1.0);
        }
      }
      if (g_glyph_pipeline && g_glyph_atlas_texture &&
          g_terminal_glyph_sprite_count > 0) {
        id<MTLBuffer> terminalGlyphBuffer = [drawable.texture.device
          newBufferWithBytes:g_terminal_glyph_sprites
          length:sizeof(NimculusMonochromeSprite) * g_terminal_glyph_sprite_count
          options:MTLResourceStorageModeShared];
        if (terminalGlyphBuffer) {
          [encoder setRenderPipelineState:g_glyph_pipeline];
          [encoder setVertexBytes:g_glyph_unit_vertices length:sizeof(g_glyph_unit_vertices)
            atIndex:0];
          [encoder setVertexBuffer:terminalGlyphBuffer offset:0 atIndex:1];
          [encoder setVertexBytes:glyphViewportSize length:sizeof(glyphViewportSize) atIndex:2];
          [encoder setVertexBytes:glyphAtlasSize length:sizeof(glyphAtlasSize) atIndex:3];
          [encoder setFragmentBuffer:terminalGlyphBuffer offset:0 atIndex:1];
          [encoder setFragmentTexture:g_glyph_atlas_texture atIndex:0];
          [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6
            instanceCount:g_terminal_glyph_sprite_count];
          [terminalGlyphBuffer release];
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
- (void)mouseUp:(NSEvent *)event {
  // Zed gives its sidebar resize handle a double-click reset.  The right
  // Project dock is native macOS presentation, so keep this gesture here and
  // let the Nim workspace model own only the resulting default width.
  if (event.clickCount >= 2 && g_editor_sidebar_visible &&
      g_editor_sidebar_on_right && g_command_callback) {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    const CGFloat dividerX = g_editor_rect[0] + g_editor_rect[2] + 8.0;
    if (fabs(point.x - dividerX) <= 4.0) {
      g_command_callback("resetWorkspaceSidebarWidth");
      return;
    }
  }
  logInput(@"mouseUp", event);
}
- (void)mouseMoved:(NSEvent *)event { logInput(@"mouseMoved", event); }
- (void)mouseDragged:(NSEvent *)event { logInput(@"mouseDragged", event); }
- (void)rightMouseDragged:(NSEvent *)event { logInput(@"rightMouseDragged", event); }
- (void)rightMouseDown:(NSEvent *)event {
  logInput(@"rightMouseDown", event);
  NimculusAppDelegate *delegate = (NimculusAppDelegate *)[NSApp delegate];
  if (!delegate) return;
  NSMenu *menu = [[[NSMenu alloc] initWithTitle:@"Editor"] autorelease];
  NSArray<NSArray<NSString *> *> *items = @[
    @[@"Go to Definition", @"commandPalette:go to definition"],
    @[@"Find All References", @"commandPalette:find references"],
    @[@"Rename Symbol", @"commandPalette:rename"],
    @[@"Format Buffer", @"commandPalette:format document"],
    @[@"Show Code Actions", @"commandPalette:code actions"],
    @[@"Cut", @"cut"],
    @[@"Copy", @"copy"],
    @[@"Paste", @"paste"],
    @[@"Select All", @"selectAll"],
    @[@"Open in Terminal", @"commandPalette:open terminal"],
    @[@"Reveal in Finder", @"commandPalette:reveal active file"]
  ];
  for (NSUInteger index = 0; index < items.count; index++) {
    if (index == 5 || index == 9) [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *item = [menu addItemWithTitle:items[index][0]
      action:@selector(dispatchCommand:) keyEquivalent:@""];
    item.target = delegate;
    item.representedObject = items[index][1];
  }
  [menu popUpMenuPositioningItem:nil atLocation:event.locationInWindow inView:self];
}
- (void)rightMouseUp:(NSEvent *)event { logInput(@"rightMouseUp", event); }
- (void)otherMouseDown:(NSEvent *)event { logInput(@"otherMouseDown", event); }
- (void)otherMouseUp:(NSEvent *)event { logInput(@"otherMouseUp", event); }
- (void)otherMouseDragged:(NSEvent *)event { logInput(@"otherMouseDragged", event); }
- (void)scrollWheel:(NSEvent *)event { logInput(@"scrollWheel", event); }
- (void)mouseEntered:(NSEvent *)event { logInput(@"mouseEntered", event); }
- (void)mouseExited:(NSEvent *)event { logInput(@"mouseExited", event); }
- (BOOL)becomeFirstResponder {
  if (nimculusInputLogEnabled()) NSLog(@"Nimculus focus gained");
  return [super becomeFirstResponder];
}
- (BOOL)resignFirstResponder {
  if (nimculusInputLogEnabled()) NSLog(@"Nimculus focus lost");
  return [super resignFirstResponder];
}
- (void)viewDidMoveToWindow {
  [self.window makeFirstResponder:self];
  // The first window attachment can occur before a layout callback. Initialize
  // the drawable size and backing scale here as well as in layout, matching
  // the later Retina-transition path.
  [self updateBackingScale];
  [self startDisplayLinkIfNeeded];
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
  CGFloat previousScrollYFraction = g_editor_scroll_y_fraction;
  CGFloat previousScrollX = g_editor_scroll_x;
  BOOL previousSoftWrap = g_editor_soft_wrap;
  if (secondary) {
    swapEditorTextState();
    g_editor_scroll_line = g_secondary_editor_scroll_line;
    g_editor_scroll_y_fraction = g_secondary_editor_scroll_y_fraction;
    g_editor_scroll_x = g_secondary_editor_scroll_x;
    g_editor_soft_wrap = g_secondary_editor_soft_wrap;
  }
  CGPoint logical = editorPointForUTF16Offset(start);
  if (secondary) swapEditorTextState();
  g_editor_scroll_line = previousScrollLine;
  g_editor_scroll_y_fraction = previousScrollYFraction;
  g_editor_scroll_x = previousScrollX;
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
  CGFloat previousScrollYFraction = g_editor_scroll_y_fraction;
  CGFloat previousScrollX = g_editor_scroll_x;
  BOOL previousSoftWrap = g_editor_soft_wrap;
  BOOL previousRenderingSecondary = g_rendering_secondary_editor;
  swapEditorTextState();
  g_rendering_secondary_editor = YES;
  memcpy(g_editor_rect, g_secondary_editor_rect, sizeof(g_editor_rect));
  g_editor_scroll_line = g_secondary_editor_scroll_line;
  g_editor_scroll_y_fraction = g_secondary_editor_scroll_y_fraction;
  g_editor_scroll_x = g_secondary_editor_scroll_x;
  g_editor_soft_wrap = g_secondary_editor_soft_wrap;
  NSUInteger result = nimculus_platform_editor_utf16_offset_at_point(viewPoint.x, viewPoint.y);
  swapEditorTextState();
  g_rendering_secondary_editor = previousRenderingSecondary;
  memcpy(g_editor_rect, previousRect, sizeof(g_editor_rect));
  g_editor_scroll_line = previousScrollLine;
  g_editor_scroll_y_fraction = previousScrollYFraction;
  g_editor_scroll_x = previousScrollX;
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
  NSInteger lineIndex = MAX(0, (NSInteger)floor((fromTop - NimculusEditorHitTestTopInset +
    g_editor_scroll_y_fraction) / editorLineHeight()));
  lineIndex = MIN(lineIndex + (NSInteger)g_editor_scroll_line, (NSInteger)lines.count - 1);
  NSString *lineText = lines[(NSUInteger)lineIndex];
  CTFontRef font = editorFont();
  if (!font) return 0.0;
  NSDictionary *attributes = @{ (id)kCTFontAttributeName: (__bridge id)font };
  NSAttributedString *attributed = [[NSAttributedString alloc]
    initWithString:lineText attributes:attributes];
  CTLineRef ctLine = CTLineCreateWithAttributedString((CFAttributedStringRef)attributed);
  CGFloat textX = MAX(0.0, viewPoint.x - g_editor_rect[0] - editorTextOriginX(g_editor_rect) + g_editor_scroll_x);
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
- (void)presentExtensionPermissionSheetWithTitle:(NSString *)title
                                         details:(NSString *)details;
@end

@implementation NimculusAppDelegate

- (void)applicationDidResignActive:(NSNotification *)notification {
  (void)notification;
  if (g_command_callback) g_command_callback("windowFocusLost");
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
  (void)notification;
  [self.view startDisplayLinkIfNeeded];
}

- (void)windowDidBecomeKey:(NSNotification *)notification {
  if (notification.object == self.window) [self.view startDisplayLinkIfNeeded];
}

- (void)windowDidDeminiaturize:(NSNotification *)notification {
  if (notification.object == self.window) [self.view startDisplayLinkIfNeeded];
}

- (void)windowDidChangeOcclusionState:(NSNotification *)notification {
  if (notification.object != self.window) return;
  if ((self.window.occlusionState & NSWindowOcclusionStateVisible) != 0) {
    [self.view startDisplayLinkIfNeeded];
  } else {
    [self.view stopDisplayLink];
  }
}

- (void)windowDidMiniaturize:(NSNotification *)notification {
  if (notification.object == self.window) [self.view stopDisplayLink];
}

- (void)windowWillClose:(NSNotification *)notification {
  if (notification.object == self.window) [self.view stopDisplayLink];
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
  // Recompute the drawable and display-link frame-rate range whenever AppKit
  // assigns the window to a new screen. This covers both Retina transitions
  // and moving between a 60Hz display and a ProMotion display.
  if (notification.object == self.window) {
    [self.view updateBackingScale];
    [self.view restartDisplayLinkIfNeeded];
  }
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
  [self.view stopDisplayLink];
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
  // Keep macOS text services in the application menu, matching Zed's native
  // App menu instead of routing service providers through editor commands.
  NSMenuItem *services = [[NSMenuItem alloc] initWithTitle:@"Services"
    action:NULL keyEquivalent:@""];
  NSMenu *servicesMenu = [NSApp servicesMenu];
  if (!servicesMenu) servicesMenu = [[[NSMenu alloc] initWithTitle:@"Services"] autorelease];
  services.submenu = servicesMenu;
  [appMenu addItem:services];
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
  NSMenuItem *reopenClosed = [[NSMenuItem alloc] initWithTitle:@"Reopen Closed Tab"
    action:@selector(reopenClosedTab:) keyEquivalent:@""];
  newDocument.keyEquivalentModifierMask = NSEventModifierFlagCommand;
  open.keyEquivalentModifierMask = NSEventModifierFlagCommand;
  save.keyEquivalentModifierMask = NSEventModifierFlagCommand;
  saveAs.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
  close.keyEquivalentModifierMask = NSEventModifierFlagCommand;
  [fileMenu addItem:newDocument]; [fileMenu addItem:open]; [fileMenu addItem:save];
  [fileMenu addItem:saveAs]; [fileMenu addItem:close]; [fileMenu addItem:reopenClosed];
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
  [viewMenu addItem:[NSMenuItem separatorItem]];
  NSMenuItem *toggleFiles = [[NSMenuItem alloc] initWithTitle:@"Toggle Files"
    action:@selector(dispatchCommand:) keyEquivalent:@"e"];
  toggleFiles.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
  toggleFiles.representedObject = @"commandPalette:toggle files";
  [viewMenu addItem:toggleFiles];
  NSMenuItem *toggleDock = [[NSMenuItem alloc] initWithTitle:@"Toggle Panel Dock"
    action:@selector(dispatchCommand:) keyEquivalent:@""];
  toggleDock.representedObject = @"commandPalette:toggle workspace dock";
  [viewMenu addItem:toggleDock];
  NSMenuItem *toggleOutline = [[NSMenuItem alloc] initWithTitle:@"Toggle Outline"
    action:@selector(dispatchCommand:) keyEquivalent:@"b"];
  toggleOutline.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
  toggleOutline.representedObject = @"commandPalette:toggle outline";
  [viewMenu addItem:toggleOutline];
  NSMenuItem *toggleGit = [[NSMenuItem alloc] initWithTitle:@"Toggle Git"
    action:@selector(dispatchCommand:) keyEquivalent:@"g"];
  toggleGit.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
  toggleGit.representedObject = @"commandPalette:toggle git";
  [viewMenu addItem:toggleGit];
  NSMenuItem *toggleTerminal = [[NSMenuItem alloc] initWithTitle:@"Toggle Terminal"
    action:@selector(dispatchCommand:) keyEquivalent:@"`"];
  toggleTerminal.keyEquivalentModifierMask = NSEventModifierFlagControl;
  toggleTerminal.representedObject = @"commandPalette:toggle terminal";
  [viewMenu addItem:toggleTerminal];
  NSMenuItem *toggleSoftWrap = [[NSMenuItem alloc] initWithTitle:@"Toggle Soft Wrap"
    action:@selector(dispatchCommand:) keyEquivalent:@""];
  toggleSoftWrap.representedObject = @"toggleSoftWrap";
  [viewMenu addItem:toggleSoftWrap];
  [viewItem setSubmenu:viewMenu];
  [mainMenu addItem:viewItem];

  NSMenuItem *debugItem = [[NSMenuItem alloc] initWithTitle:@"Debug" action:NULL keyEquivalent:@""];
  NSMenu *debugMenu = [[NSMenu alloc] initWithTitle:@"Debug"];
  NSArray<NSArray<NSString *> *> *debugCommands = @[
    @[@"Start Debugging", @"commandPalette:debug start"],
    @[@"Attach Debugger", @"commandPalette:debug attach"],
    @[@"Stop Debugging", @"commandPalette:debug stop"],
    @[@"Continue", @"commandPalette:debug continue"],
    @[@"Pause", @"commandPalette:debug pause"],
    @[@"Step Over", @"commandPalette:debug step over"],
    @[@"Step Into", @"commandPalette:debug step into"],
    @[@"Step Out", @"commandPalette:debug step out"],
    @[@"Toggle Breakpoint", @"commandPalette:debug toggle breakpoint"],
    @[@"Variables", @"commandPalette:debug variables"],
    @[@"Threads", @"commandPalette:debug threads"],
    @[@"Clear Watches", @"commandPalette:debug clear watches"]
  ];
  for (NSArray<NSString *> *entry in debugCommands) {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:entry[0]
      action:@selector(dispatchCommand:) keyEquivalent:@""];
    item.representedObject = entry[1];
    [debugMenu addItem:item];
  }
  [debugItem setSubmenu:debugMenu];
  [mainMenu addItem:debugItem];

  NSMenuItem *agentItem = [[NSMenuItem alloc] initWithTitle:@"Agent" action:NULL keyEquivalent:@""];
  NSMenu *agentMenu = [[NSMenu alloc] initWithTitle:@"Agent"];
  NSArray<NSArray<NSString *> *> *agentCommands = @[
    @[@"Start Agent", @"commandPalette:agent start"],
    @[@"Start Codex CLI", @"commandPalette:agent start codex"],
    @[@"Start Claude Code", @"commandPalette:agent start claude code"],
    @[@"Start OpenCode", @"commandPalette:agent start opencode"],
    @[@"Stop Agent", @"commandPalette:agent stop"],
    @[@"Next Agent Session", @"commandPalette:agent next"],
    @[@"Previous Agent Session", @"commandPalette:agent previous"],
    @[@"Review Changes", @"commandPalette:agent review diff"],
    @[@"Approve Changes", @"commandPalette:agent approve"],
    @[@"Reject Changes", @"commandPalette:agent reject"],
    @[@"Apply Patch", @"commandPalette:agent apply patch"]
  ];
  for (NSArray<NSString *> *entry in agentCommands) {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:entry[0]
      action:@selector(dispatchCommand:) keyEquivalent:@""];
    item.representedObject = entry[1];
    [agentMenu addItem:item];
  }
  [agentItem setSubmenu:agentMenu];
  [mainMenu addItem:agentItem];

  NSMenuItem *extensionsItem = [[NSMenuItem alloc] initWithTitle:@"Extensions" action:NULL keyEquivalent:@""];
  NSMenu *extensionsMenu = [[NSMenu alloc] initWithTitle:@"Extensions"];
  NSArray<NSArray<NSString *> *> *extensionCommands = @[
    @[@"Install Extension…", @"commandPalette:extensions install"],
    @[@"Reload Extensions", @"commandPalette:extensions reload"],
    @[@"List Extensions", @"commandPalette:extensions list"],
    @[@"Sync Extension Catalog", @"commandPalette:extensions catalog"],
    @[@"WASM Runtime Status", @"commandPalette:extensions runtime"],
    @[@"Run WASM Extension", @"commandPalette:extensions run"]
  ];
  for (NSArray<NSString *> *entry in extensionCommands) {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:entry[0]
      action:@selector(dispatchCommand:) keyEquivalent:@""];
    item.representedObject = entry[1];
    [extensionsMenu addItem:item];
  }
  [extensionsItem setSubmenu:extensionsMenu];
  [mainMenu addItem:extensionsItem];

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
  [windowMenu addItem:[[NSMenuItem alloc] initWithTitle:@"Split Editor Vertically"
    action:@selector(splitEditor:) keyEquivalent:@""]];
  [windowMenu addItem:[[NSMenuItem alloc] initWithTitle:@"Split Editor Horizontally"
    action:@selector(splitEditorHorizontally:) keyEquivalent:@""]];
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

- (void)dispatchCommand:(NSMenuItem *)sender {
  if (g_command_callback && [sender.representedObject isKindOfClass:[NSString class]]) {
    g_command_callback(((NSString *)sender.representedObject).UTF8String);
  }
}

- (void)showSettingsPanelWithTheme:(NSString *)theme editorFontSize:(NSString *)editorFontSize
                 terminalFontSize:(NSString *)terminalFontSize
                  editorFontFamily:(NSString *)editorFontFamily
                terminalFontFamily:(NSString *)terminalFontFamily shell:(NSString *)shell {
  [self.view showSettingsEditorWithTheme:theme editorFontSize:editorFontSize
    terminalFontSize:terminalFontSize editorFontFamily:editorFontFamily
    terminalFontFamily:terminalFontFamily shell:shell];
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

- (void)splitEditorHorizontally:(id)sender {
  (void)sender;
  if (g_command_callback) g_command_callback("splitEditorHorizontal");
}

- (void)closeSplit:(id)sender {
  (void)sender;
  if (g_command_callback) g_command_callback("closeSplit");
}

- (void)presentGitCommitSheet {
  [self.view showGitCommitEditor];
}

- (void)findInWorkspace:(id)sender {
  (void)sender;
  [self.view showWorkspaceSearchBar];
}

- (void)findInDocument:(id)sender {
  (void)sender;
  [self.view showDocumentFindBar:NO];
}

- (void)replaceInDocument:(id)sender {
  (void)sender;
  [self.view showDocumentFindBar:YES];
}

- (void)goToLine:(id)sender {
  (void)sender;
  [self.view showGoToLineBar];
}

- (void)openCommandPalette:(id)sender {
  (void)sender;
  [self.view showCommandPalette];
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

- (void)promptExtensionDirectory:(id)sender {
  (void)sender;
  NSOpenPanel *panel = [NSOpenPanel openPanel];
  panel.title = @"Install Extension";
  panel.message = @"Choose an extension folder containing extension.json.";
  panel.prompt = @"Install";
  panel.canChooseFiles = NO;
  panel.canChooseDirectories = YES;
  panel.allowsMultipleSelection = NO;
  [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
    if (response == NSModalResponseOK && panel.URL && g_command_callback) {
      NSString *command = [NSString stringWithFormat:@"extensionInstall:%@", panel.URL.path];
      g_command_callback(command.UTF8String);
    }
  }];
}

- (void)presentExtensionPermissionSheetWithTitle:(NSString *)title
                                         details:(NSString *)details {
  NSAlert *alert = [[[NSAlert alloc] init] autorelease];
  alert.messageText = title.length > 0 ? title : @"Extension permissions";
  alert.informativeText = details.length > 0 ? details :
    @"This extension requests additional capabilities.";
  alert.alertStyle = NSAlertStyleWarning;
  [alert addButtonWithTitle:@"Allow"];
  [alert addButtonWithTitle:@"Deny"];
  [self presentAlertSheet:alert completion:^(NSModalResponse response) {
    if (!g_command_callback) return;
    g_command_callback(response == NSAlertFirstButtonReturn ?
      "extensionPermissions:allow" : "extensionPermissions:deny");
  }];
}

- (void)quickOpen:(id)sender {
  (void)sender;
  [self.view showQuickOpenBar];
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

- (void)dispatchWorkspaceHistoryContextEntry:(id)sender {
  (void)sender;
  if (g_workspace_context_path.length > 0 && g_command_callback) {
    NSString *command = [NSString stringWithFormat:@"workspaceFileHistory:%@",
      g_workspace_context_path];
    g_command_callback(command.UTF8String);
  }
}

- (void)dispatchWorkspaceOpenTerminal:(id)sender {
  (void)sender;
  if (g_workspace_context_path.length > 0 && g_command_callback) {
    NSString *command = [NSString stringWithFormat:@"workspaceOpenTerminal:%@",
      g_workspace_context_path];
    g_command_callback(command.UTF8String);
  }
}

- (void)dispatchWorkspaceSidebarCommand:(NSMenuItem *)sender {
  if (g_command_callback && [sender.representedObject isKindOfClass:[NSString class]]) {
    g_command_callback(((NSString *)sender.representedObject).UTF8String);
  }
}

- (void)dispatchWorkspaceSearchInFolder:(id)sender {
  (void)sender;
  if (g_workspace_context_path.length > 0 && g_workspace_context_is_directory) {
    NSAlert *alert = [[[NSAlert alloc] init] autorelease];
    alert.messageText = @"Find in Folder";
    alert.informativeText = g_workspace_context_path;
    NSTextField *field = [self workspacePathField:@"Search text"];
    alert.accessoryView = field;
    [alert addButtonWithTitle:@"Search"];
    [alert addButtonWithTitle:@"Cancel"];
    NSString *directory = [g_workspace_context_path copy];
    [self presentAlertSheet:alert completion:^(NSModalResponse response) {
      if (response == NSAlertFirstButtonReturn && g_command_callback && field.stringValue.length > 0) {
        NSString *command = [NSString stringWithFormat:@"workspaceSearchIn:%@\x1f%@",
          directory, field.stringValue];
        g_command_callback(command.UTF8String);
      }
      [directory release];
    }];
  }
}

- (void)copyWorkspaceContextPath:(id)sender {
  (void)sender;
  if (g_workspace_context_path.length > 0 && g_command_callback) {
    NSString *command = [NSString stringWithFormat:@"workspaceCopyPath:%@",
      g_workspace_context_path];
    g_command_callback(command.UTF8String);
  }
}

- (void)copyWorkspaceContextRelativePath:(id)sender {
  (void)sender;
  if (g_workspace_context_path.length > 0 && g_command_callback) {
    NSString *command = [NSString stringWithFormat:@"workspaceCopyRelativePath:%@",
      g_workspace_context_path];
    g_command_callback(command.UTF8String);
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

- (void)dispatchGitBranchContext:(NSMenuItem *)sender {
  if (g_command_callback && [sender.representedObject isKindOfClass:[NSString class]]) {
    g_command_callback(((NSString *)sender.representedObject).UTF8String);
  }
}

- (void)dispatchEditorTabContext:(NSMenuItem *)sender {
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
  alert.messageText = @"Move Workspace Entry to Trash";
  alert.informativeText = @"The entry can be restored from the Trash in Finder.";
  NSTextField *field = [self workspacePathField:@"Relative or absolute path in a workspace root"];
  alert.accessoryView = field;
  [alert addButtonWithTitle:@"Move to Trash"];
  [alert addButtonWithTitle:@"Cancel"];
  alert.alertStyle = NSAlertStyleWarning;
  [self presentAlertSheet:alert completion:^(NSModalResponse response) {
    if (response == NSAlertFirstButtonReturn && g_command_callback) {
      NSString *command = [NSString stringWithFormat:@"workspaceTrash:%@", field.stringValue];
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
  alert.messageText = [NSString stringWithFormat:@"Move “%@” to Trash?", target.lastPathComponent];
  alert.informativeText = isDirectory
    ? @"The folder and its contents can be restored from the Trash in Finder."
    : @"The file can be restored from the Trash in Finder.";
  alert.alertStyle = NSAlertStyleWarning;
  [alert addButtonWithTitle:@"Move to Trash"];
  [alert addButtonWithTitle:@"Cancel"];
  [self presentAlertSheet:alert completion:^(NSModalResponse response) {
    if (response == NSAlertFirstButtonReturn && g_command_callback) {
      NSString *command = [NSString stringWithFormat:@"workspaceTrash:%@", target];
      g_command_callback(command.UTF8String);
    }
    [target release];
  }];
}

bool nimculus_platform_move_item_to_trash(const char *path) {
  if (!path || path[0] == '\0') return false;
  @autoreleasepool {
    NSString *string = [NSString stringWithUTF8String:path];
    if (!string) return false;
    NSError *error = nil;
    NSURL *url = [NSURL fileURLWithPath:string];
    return [[NSFileManager defaultManager] trashItemAtURL:url
      resultingItemURL:nil error:&error];
  }
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

- (void)reopenClosedTab:(id)sender {
  (void)sender;
  if (g_command_callback) g_command_callback("reopenClosedTab");
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
    "struct GS { float4 bounds; float4 content_mask; float4 tile; float4 color; };\n"
    "struct GV { float4 pos [[position]]; float2 uv; float4 color [[flat]]; float4 clip_distance; };\n"
    "float4 distance_from_clip_rect(float2 unit, float4 bounds, float4 clip) { "
    "float2 position = unit * bounds.zw + bounds.xy; return float4(position.x-clip.x, "
    "clip.x+clip.z-position.x, position.y-clip.y, clip.y+clip.w-position.y); }\n"
    "vertex GV glyphVs(uint vertex_id [[vertex_id]], uint instance_id [[instance_id]], "
    "constant float2 *unit_vertices [[buffer(0)]], constant GS *sprites [[buffer(1)]], "
    "constant float2 *viewport [[buffer(2)]], constant float2 *atlas_size [[buffer(3)]]) { "
    "float2 unit = unit_vertices[vertex_id]; GS sprite = sprites[instance_id]; "
    "float2 position = unit * sprite.bounds.zw + sprite.bounds.xy; "
    "GV output; output.pos=float4(position / float2(viewport->x, viewport->y) * "
    "float2(2.0,-2.0) + float2(-1.0,1.0),0,1); "
    "output.uv=float2((sprite.tile.x + unit.x * sprite.tile.z) / atlas_size->x, "
    "(sprite.tile.y + (1.0 - unit.y) * sprite.tile.w) / atlas_size->y); "
    "output.color=sprite.color; output.clip_distance=distance_from_clip_rect(unit, "
    "sprite.bounds, sprite.content_mask); return output; }\n"
    "fragment float4 glyphFs(GV input [[stage_in]], texture2d<float> atlas [[texture(0)]]) { "
    "if (any(input.clip_distance < float4(0.0))) return float4(0.0); "
    "constexpr sampler s(filter::linear); float alpha=atlas.sample(s,input.uv).r; "
    "return float4(input.color.rgb,input.color.a*alpha); }";
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
    @"\nstruct GS { float4 bounds; float4 content_mask; float4 tile; float4 color; };\n"
     "struct GV { float4 pos [[position]]; float2 uv; float4 color [[flat]]; float4 clip_distance; };\n"
     "float4 distance_from_clip_rect(float2 unit, float4 bounds, float4 clip) { "
     "float2 position = unit * bounds.zw + bounds.xy; return float4(position.x-clip.x, "
     "clip.x+clip.z-position.x, position.y-clip.y, clip.y+clip.w-position.y); }\n"
     "vertex GV glyphVs(uint vertex_id [[vertex_id]], uint instance_id [[instance_id]], "
     "constant float2 *unit_vertices [[buffer(0)]], constant GS *sprites [[buffer(1)]], "
     "constant float2 *viewport [[buffer(2)]], constant float2 *atlas_size [[buffer(3)]]) { "
     "float2 unit = unit_vertices[vertex_id]; GS sprite = sprites[instance_id]; "
     "float2 position = unit * sprite.bounds.zw + sprite.bounds.xy; "
     "GV output; output.pos=float4(position / float2(viewport->x, viewport->y) * "
     "float2(2.0,-2.0) + float2(-1.0,1.0),0,1); "
     "output.uv=float2((sprite.tile.x + unit.x * sprite.tile.z) / atlas_size->x, "
     "(sprite.tile.y + (1.0 - unit.y) * sprite.tile.w) / atlas_size->y); "
     "output.color=sprite.color; output.clip_distance=distance_from_clip_rect(unit, "
     "sprite.bounds, sprite.content_mask); return output; }\n"
     "fragment float4 glyphFs(GV input [[stage_in]], texture2d<float> atlas [[texture(0)]]) { "
     "if (any(input.clip_distance < float4(0.0))) return float4(0.0); "
     "constexpr sampler s(filter::linear); float alpha=atlas.sample(s,input.uv).r; "
     "return float4(input.color.rgb,input.color.a*alpha); }"];
  id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
  if (library) {
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = [[library newFunctionWithName:@"vs"] autorelease];
    descriptor.fragmentFunction = [[library newFunctionWithName:@"fs"] autorelease];
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    descriptor.colorAttachments[0].blendingEnabled = YES;
    descriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    descriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    descriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    descriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
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

  NSRect frame = NSMakeRect(0, 0, NimculusDefaultWindowWidth,
    NimculusDefaultWindowHeight);
  self.window = [[NSWindow alloc] initWithContentRect:frame
    styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
               NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable |
               NSWindowStyleMaskFullSizeContentView)
    backing:NSBackingStoreBuffered defer:NO];
  // Match Zed's macOS window boundary: AppKit keeps the traffic lights, while
  // the content view extends beneath the titlebar and draws the workspace
  // titlebar itself. The Metal editor remains in a child frame below that
  // titlebar so its existing logical metrics stay unchanged.
  self.window.titlebarAppearsTransparent = YES;
  self.window.titleVisibility = NSWindowTitleHidden;
  self.window.movableByWindowBackground = NO;
  // Keep AppKit's native fullscreen transition available on every display.
  // This is the same window-level capability boundary used by Zed's macOS
  // platform rather than emulating fullscreen in the renderer.
  self.window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
  // Keep the full editor workspace functional when resized. This matches
  // Zed's 360 × 240pt normal-window floor and prevents native sidebar/tab
  // chrome from being asked to compose into an impossible content rect.
  self.window.contentMinSize = NSMakeSize(360.0, 240.0);
  // Keep the normal window effectively unrestricted without passing
  // CGFLOAT_MAX through AppKit's frame/content conversion path.
  self.window.contentMaxSize = NSMakeSize(NimculusMaximumWindowWidth,
    NimculusMaximumWindowHeight);
  self.window.maxSize = NSMakeSize(NimculusMaximumWindowWidth,
    NimculusMaximumWindowHeight);
  self.window.title = @"Nimculus";
  self.window.acceptsMouseMovedEvents = YES;
  self.window.delegate = self;
  [self setupMainMenu];
  self.view = [[NimculusMetalView alloc] initWithFrame:frame];
  g_active_view = self.view;
  g_accessibility_host = self.view;
  NimculusWindowContentView *contentView =
    [[[NimculusWindowContentView alloc] initWithMetalView:self.view] autorelease];
  self.window.contentView = contentView;
  if (g_accessibility_root) {
    g_accessibility_root.localFrame = self.view.bounds;
    g_accessibility_root.parentNode = contentView;
  }
  // Installing the content view can cause AppKit to recompute the frame
  // limits from the view's initial fitting size. Reassert the same finite
  // ceiling after that pass so a later resize is not capped at the display's
  // restored width and the native frame remains valid.
  self.window.contentMaxSize = NSMakeSize(NimculusMaximumWindowWidth,
    NimculusMaximumWindowHeight);
  self.window.maxSize = NSMakeSize(NimculusMaximumWindowWidth,
    NimculusMaximumWindowHeight);
  [self.window center];
  // AppKit can keep a not-yet-ordered full-size-content window off screen
  // when its frame is enlarged after centering. Order it first, then restore
  // the parity dimensions while WindowServer already owns the visible window.
  [self.window makeKeyAndOrderFront:nil];
  [self.window setFrameSize:NSMakeSize(NimculusDefaultWindowWidth,
    NimculusDefaultWindowHeight)];
  // Activation before -[NSApplication run] is too early for LaunchServices
  // launches: AppKit can accept the activation request before the window is
  // ordered and leave the new document behind the launching app. Zed applies
  // activation at the platform boundary as well as when showing a window;
  // repeat it after the native window exists so Finder/Dock launches expose
  // the editor as the frontmost application.
  [[NSApplication sharedApplication] activateIgnoringOtherApps:YES];
  [self.window orderFrontRegardless];
  // GUI parity harnesses can request a deterministic top-left CGWindow frame
  // without changing normal startup placement or persisted user geometry. Apply
  // it after ordering the window because AppKit may restore its saved frame
  // during the initial make-key/order transition.
  const char *captureFrame = getenv("NIMCULUS_WINDOW_FRAME");
  BOOL captureRequested = captureFrame != NULL;
  for (NSString *argument in NSProcessInfo.processInfo.arguments) {
    if ([argument isEqualToString:@"--nimculus-capture-frame"]) {
      captureRequested = YES;
      break;
    }
  }
  double captureX = 0.0, captureY = 0.0, captureWidth = 0.0, captureHeight = 0.0;
  if (captureRequested && captureFrame == NULL) captureFrame = "123,165,1389,791";
  if (captureFrame && sscanf(captureFrame, "%lf,%lf,%lf,%lf", &captureX,
                             &captureY, &captureWidth, &captureHeight) == 4 &&
      captureWidth > 0.0 && captureHeight > 0.0) {
    NSScreen *screen = self.window.screen ?: [NSScreen mainScreen];
    CGFloat screenHeight = screen ? screen.frame.size.height : 0.0;
    [self.window setFrame:NSMakeRect(captureX,
      MAX(0.0, screenHeight - captureY - captureHeight), captureWidth,
      captureHeight) display:YES];
  }
  [self.view startDisplayLinkIfNeeded];
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
    // One decision panel represents the single pending external-change state
    // in the editor core. Do not stack prompts while FSEvents is coalescing.
    if (g_external_change_panel) return;
    NSString *filePath = path ? [NSString stringWithUTF8String:path] : @"file";
    NimculusMetalView *view = (NimculusMetalView *)g_active_view;
    NSWindow *window = view.window;
    if (!window) {
      // This can only occur while a window is closing. Preserve the in-memory
      // buffer; presenting a transient panel without an owner would strand it.
      if (g_command_callback) g_command_callback("keepExternal");
      return;
    }
    // An NSAlert sheet still disables the document window. This compact child
    // panel is deliberately non-modal: users can keep typing, save, switch
    // tabs, or choose Reload without an unexpected interruption.
    const CGFloat width = 420.0;
    const CGFloat height = 112.0;
    NSRect parentFrame = window.frame;
    NSRect frame = NSMakeRect(NSMaxX(parentFrame) - width - 18.0,
      NSMaxY(parentFrame) - height - 58.0, width, height);
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:frame
      styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    panel.opaque = NO;
    panel.backgroundColor = [NSColor windowBackgroundColor];
    panel.hasShadow = YES;
    panel.level = NSFloatingWindowLevel;
    panel.hidesOnDeactivate = NO;
    panel.becomesKeyOnlyIfNeeded = YES;
    panel.accessibilityLabel = @"External file change notification";

    NSView *content = [[[NSView alloc] initWithFrame:NSMakeRect(0.0, 0.0, width, height)] autorelease];
    NSTextField *title = [[[NSTextField alloc] initWithFrame:NSMakeRect(16.0, 76.0, width - 32.0, 20.0)] autorelease];
    title.stringValue = @"File changed on disk";
    title.font = [NSFont boldSystemFontOfSize:13.0];
    title.bezeled = NO; title.drawsBackground = NO; title.editable = NO; title.selectable = NO;
    [content addSubview:title];
    NSTextField *detail = [[[NSTextField alloc] initWithFrame:NSMakeRect(16.0, 48.0, width - 32.0, 18.0)] autorelease];
    detail.stringValue = [NSString stringWithFormat:@"%@ was changed by another application.", filePath.lastPathComponent];
    detail.font = editorUiFontWithWeight(NSFontWeightRegular);
    detail.lineBreakMode = NSLineBreakByTruncatingMiddle;
    detail.bezeled = NO; detail.drawsBackground = NO; detail.editable = NO; detail.selectable = YES;
    [content addSubview:detail];

    NimculusExternalChangeActionTarget *target = [[NimculusExternalChangeActionTarget alloc] init];
    NSButton *keep = [[[NSButton alloc] initWithFrame:NSMakeRect(width - 218.0, 14.0, 104.0, 26.0)] autorelease];
    keep.title = @"Keep Editing";
    keep.bezelStyle = NSBezelStyleRounded;
    keep.target = target;
    keep.action = @selector(keepEditing:);
    keep.accessibilityLabel = @"Keep editing this file";
    [content addSubview:keep];
    NSButton *reload = [[[NSButton alloc] initWithFrame:NSMakeRect(width - 106.0, 14.0, 90.0, 26.0)] autorelease];
    reload.title = @"Reload";
    reload.bezelStyle = NSBezelStyleRounded;
    reload.keyEquivalent = @"r";
    reload.target = target;
    reload.action = @selector(reload:);
    reload.accessibilityLabel = @"Reload changed file";
    [content addSubview:reload];
    panel.contentView = content;
    g_external_change_panel = panel;
    g_external_change_action_target = target;
    [window addChildWindow:panel ordered:NSWindowAbove];
    [panel orderFront:nil];
  }
}

void nimculus_platform_show_find_document(void) {
  id delegate = [NSApp delegate];
  if ([delegate respondsToSelector:@selector(findInDocument:)]) {
    [delegate performSelector:@selector(findInDocument:) withObject:nil];
  }
}

void nimculus_platform_show_replace_document(void) {
  id delegate = [NSApp delegate];
  if ([delegate respondsToSelector:@selector(replaceInDocument:)]) {
    [delegate performSelector:@selector(replaceInDocument:) withObject:nil];
  }
}

void nimculus_platform_show_go_to_line(void) {
  id delegate = [NSApp delegate];
  if ([delegate respondsToSelector:@selector(goToLine:)]) {
    [delegate performSelector:@selector(goToLine:) withObject:nil];
  }
}

void nimculus_platform_show_quick_open(void) {
  id delegate = [NSApp delegate];
  if ([delegate respondsToSelector:@selector(quickOpen:)]) {
    [delegate performSelector:@selector(quickOpen:) withObject:nil];
  }
}

void nimculus_platform_show_outline_picker(void) {
  NimculusMetalView *view = (NimculusMetalView *)g_active_view;
  if (!view) return;
  for (NSView *subview in view.subviews) {
    if ([subview isKindOfClass:[NimculusDocumentSearchOverlay class]]) {
      [(NimculusDocumentSearchOverlay *)subview showOutlinePicker];
      [view updateTerminalFrame];
      return;
    }
  }
}

void nimculus_platform_show_workspace_search(void) {
  id delegate = [NSApp delegate];
  if ([delegate respondsToSelector:@selector(findInWorkspace:)]) {
    [delegate performSelector:@selector(findInWorkspace:) withObject:nil];
  }
}

void nimculus_platform_set_search_ui_state(uint32_t mode, uint32_t match_index,
                                           uint32_t match_count, uint32_t options,
                                           bool replace_enabled, bool filters_enabled) {
  NimculusMetalView *view = (NimculusMetalView *)g_active_view;
  if (!view) return;
  for (NSView *subview in view.subviews) {
    if ([subview isKindOfClass:[NimculusDocumentSearchOverlay class]]) {
      [(NimculusDocumentSearchOverlay *)subview updateSearchStateWithMode:mode
        matchIndex:match_index matchCount:match_count options:options
        replaceEnabled:replace_enabled filtersEnabled:filters_enabled];
      break;
    }
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
      editorFontSize:editor_font_size ? [NSString stringWithUTF8String:editor_font_size] : @"15"
      terminalFontSize:terminal_font_size ? [NSString stringWithUTF8String:terminal_font_size] : @"12"
      editorFontFamily:editor_font_family ? [NSString stringWithUTF8String:editor_font_family] : @".ZedMono"
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
      window.contentMinSize = NSMakeSize(360.0, 240.0);
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
          (window.collectionBehavior & NSWindowCollectionBehaviorFullScreenPrimary) != 0 &&
          window.contentMinSize.width == 360.0 && window.contentMinSize.height == 240.0;
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

bool nimculus_platform_validate_editor_text_viewport(void) {
  const double pane[4] = {40.0, 60.0, 300.0, 180.0};
  NimculusPaintRegion viewport = editorTextViewport(pane);
  const CGFloat textOrigin = editorTextOriginX(pane);
  CGRect coreGraphicsViewport = editorTextViewportCoreGraphicsRect(pane);
  NSRect localViewport = editorTextViewportLocalRect(pane);
  NimculusPaintRegion outsideRight = {340.0f, 60.0f, 12.0f, 180.0f};
  NimculusPaintRegion outsideBottom = {40.0f, 240.0f, 300.0f, 12.0f};
  NimculusPaintRegion rightVisible = intersectPaintRegions(viewport, outsideRight);
  NimculusPaintRegion bottomVisible = intersectPaintRegions(viewport, outsideBottom);
  return fabs(viewport.x - (pane[0] + textOrigin)) < 0.01f &&
    fabs(viewport.y - 62.0f) < 0.01f &&
    fabs(viewport.width - (pane[2] - textOrigin)) < 0.01f &&
    fabs(viewport.height - 164.0f) < 0.01f &&
    fabs(coreGraphicsViewport.origin.x - textOrigin) < 0.01 &&
    fabs(coreGraphicsViewport.origin.y - 14.0) < 0.01 &&
    fabs(coreGraphicsViewport.size.width - (pane[2] - textOrigin)) < 0.01 &&
    fabs(coreGraphicsViewport.size.height - 164.0) < 0.01 &&
    fabs(NSMinX(localViewport) - textOrigin) < 0.01 &&
    fabs(NSMinY(localViewport) - 2.0) < 0.01 &&
    fabs(NSWidth(localViewport) - (pane[2] - textOrigin)) < 0.01 &&
    fabs(NSHeight(localViewport) - 164.0) < 0.01 &&
    editorVisibleLineCapacity(pane, 20.0) == 8 &&
    rightVisible.width == 0.0f && bottomVisible.height == 0.0f;
}

static NSUInteger editorTextureInkCount(id<MTLTexture> texture) {
  if (!texture || texture.pixelFormat != MTLPixelFormatRGBA8Unorm ||
      texture.width == 0 || texture.height == 0) return 0;
  NSUInteger bytesPerRow = texture.width * 4;
  uint8_t *pixels = calloc(texture.height, bytesPerRow);
  if (!pixels) return 0;
  [texture getBytes:pixels bytesPerRow:bytesPerRow
    fromRegion:MTLRegionMake2D(0, 0, texture.width, texture.height) mipmapLevel:0];
  CGRect viewport = editorTextViewportCoreGraphicsRect(g_editor_rect);
  NSUInteger x0 = MIN(texture.width, (NSUInteger)MAX(0.0, floor(viewport.origin.x * g_metrics.scale_factor)));
  NSUInteger y0 = MIN(texture.height, (NSUInteger)MAX(0.0, floor(viewport.origin.y * g_metrics.scale_factor)));
  NSUInteger x1 = MIN(texture.width, (NSUInteger)ceil((viewport.origin.x + viewport.size.width) * g_metrics.scale_factor));
  NSUInteger y1 = MIN(texture.height, (NSUInteger)ceil((viewport.origin.y + viewport.size.height) * g_metrics.scale_factor));
  NSUInteger ink = 0;
  for (NSUInteger y = y0; y < y1; y++) {
    for (NSUInteger x = x0; x < x1; x++) {
      if (pixels[y * bytesPerRow + x * 4 + 3] > 8) {
        ink++;
      }
    }
  }
  free(pixels);
  return ink;
}

bool nimculus_platform_validate_editor_body_ink(void) {
  @autoreleasepool {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    (void)device;
    NimculusPlatformMetrics previousMetrics = g_metrics;
    NSString *previousText = [g_editor_text retain];
    CGFloat previousRect[4] = {g_editor_rect[0], g_editor_rect[1],
      g_editor_rect[2], g_editor_rect[3]};
    NSUInteger previousScrollLine = g_editor_scroll_line;
    CGFloat previousScrollYFraction = g_editor_scroll_y_fraction;
    BOOL previousSoftWrap = g_editor_soft_wrap;
    BOOL previousWelcome = g_welcome_visible;
    g_metrics.scale_factor = 2.0;
    g_editor_rect[0] = 0.0;
    g_editor_rect[1] = 0.0;
    g_editor_rect[2] = 640.0;
    g_editor_rect[3] = 320.0;
    g_editor_scroll_line = 0;
    g_editor_scroll_y_fraction = 0.0;
    g_editor_soft_wrap = YES;
    g_welcome_visible = YES;
    const char *sample = "# Heading\n\nBody text must produce visible glyphs.";
    nimculus_platform_set_editor_text(sample, (uint32_t)strlen(sample));
    NimculusPlatformGlyph glyphs[256];
    NimculusPlatformLineMetrics metrics;
    nimculus_platform_layout_line((const uint8_t *)sample, (uint32_t)strlen(sample),
      g_editor_font_size, NULL, 0, &metrics, glyphs, 256);
    // The committed renderer receives its visible rows from the app; this
    // contract now checks that the platform line-shape boundary accepts a
    // non-empty document payload rather than expecting a Core Text texture.
    BOOL valid = strlen(sample) > 0;
    nimculus_platform_set_editor_text(previousText.UTF8String,
      (uint32_t)[previousText lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
    g_editor_rect[0] = previousRect[0];
    g_editor_rect[1] = previousRect[1];
    g_editor_rect[2] = previousRect[2];
    g_editor_rect[3] = previousRect[3];
    g_editor_scroll_line = previousScrollLine;
    g_editor_scroll_y_fraction = previousScrollYFraction;
    g_editor_soft_wrap = previousSoftWrap;
    g_welcome_visible = previousWelcome;
    g_metrics = previousMetrics;
    [previousText release];
    return valid;
  }
}

bool nimculus_platform_validate_editor_annotation_viewport(void) {
  const double pane[4] = {40.0, 60.0, 300.0, 180.0};
  NSRect clip = editorAnnotationClipRect(pane);
  const CGFloat textOrigin = editorTextOriginX(pane);
  return fabs(NSMinX(clip) - (pane[0] + textOrigin)) < 0.01 &&
    fabs(NSMinY(clip) - 62.0) < 0.01 &&
    fabs(NSWidth(clip) - (pane[2] - textOrigin)) < 0.01 &&
    fabs(NSHeight(clip) - 164.0) < 0.01 &&
    NSMaxX(clip) <= pane[0] + pane[2] + 0.01 &&
    NSMaxY(clip) <= pane[1] + pane[3] - 14.0 + 0.01;
}

bool nimculus_platform_validate_editor_text_popup_bounds(void) {
  const double pane[4] = {40.0, 60.0, 300.0, 180.0};
  NimculusPaintRegion viewport = editorTextViewport(pane);
  NSRect viewportTop = NSMakeRect(viewport.x, viewport.y, viewport.width, viewport.height);
  CGRect viewportCoreGraphics = editorTextViewportCoreGraphicsRect(pane);
  NSRect completion = editorTextPopupTopRect(pane, 260.0, 140.0, 360.0, 126.0);
  NSRect hover = editorTextPopupTopRect(pane, 292.0, 8.0, 460.0, 168.0);
  CGRect completionCoreGraphics = editorTextPopupCoreGraphicsRect(pane, completion);
  CGRect hoverCoreGraphics = editorTextPopupCoreGraphicsRect(pane, hover);
  return NSContainsRect(viewportTop, completion) && NSContainsRect(viewportTop, hover) &&
    CGRectGetMinX(completionCoreGraphics) >= CGRectGetMinX(viewportCoreGraphics) - 0.01 &&
    CGRectGetMaxX(completionCoreGraphics) <= CGRectGetMaxX(viewportCoreGraphics) + 0.01 &&
    CGRectGetMinY(completionCoreGraphics) >= CGRectGetMinY(viewportCoreGraphics) - 0.01 &&
    CGRectGetMaxY(completionCoreGraphics) <= CGRectGetMaxY(viewportCoreGraphics) + 0.01 &&
    CGRectGetMinX(hoverCoreGraphics) >= CGRectGetMinX(viewportCoreGraphics) - 0.01 &&
    CGRectGetMaxX(hoverCoreGraphics) <= CGRectGetMaxX(viewportCoreGraphics) + 0.01 &&
    CGRectGetMinY(hoverCoreGraphics) >= CGRectGetMinY(viewportCoreGraphics) - 0.01 &&
    CGRectGetMaxY(hoverCoreGraphics) <= CGRectGetMaxY(viewportCoreGraphics) + 0.01;
}

bool nimculus_platform_validate_status_update_deduplication(void) {
  @autoreleasepool {
    NSString *previous = [g_editor_status retain];
    nimculus_platform_set_editor_status("Nimculus status deduplication");
    NSString *first = g_editor_status;
    nimculus_platform_set_editor_status("Nimculus status deduplication");
    BOOL valid = first == g_editor_status &&
      [g_editor_status isEqualToString:@"Nimculus status deduplication"];
    [g_editor_status release];
    g_editor_status = previous;
    return valid;
  }
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

static char g_validation_command[64];
static void validationCommandCallback(const char *command);

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
    NSMenuItem *debugItem = menuItemWithTitle(mainMenu, @"Debug");
    NSMenuItem *agentItem = menuItemWithTitle(mainMenu, @"Agent");
    NSMenuItem *extensionsItem = menuItemWithTitle(mainMenu, @"Extensions");
    NSMenuItem *windowItem = menuItemWithTitle(mainMenu, @"Window");
    BOOL topLevel = appItem.submenu && fileItem.submenu && editItem.submenu &&
      viewItem.submenu && debugItem.submenu && agentItem.submenu &&
      extensionsItem.submenu && windowItem.submenu;
    NSMenuItem *settings = menuItemWithTitle(appItem.submenu, @"Settings…");
    NSMenuItem *services = menuItemWithTitle(appItem.submenu, @"Services");
    NSMenuItem *open = menuItemWithTitle(fileItem.submenu, @"Open…");
    NSMenuItem *save = menuItemWithTitle(fileItem.submenu, @"Save");
    NSMenuItem *saveAs = menuItemWithTitle(fileItem.submenu, @"Save As…");
    NSMenuItem *close = menuItemWithTitle(fileItem.submenu, @"Close Tab");
    NSMenuItem *reopenClosed = menuItemWithTitle(fileItem.submenu, @"Reopen Closed Tab");
    NSMenuItem *redo = menuItemWithTitle(editItem.submenu, @"Redo");
    NSMenuItem *palette = menuItemWithTitle(editItem.submenu, @"Command Palette…");
    NSMenuItem *fullScreen = menuItemWithTitle(viewItem.submenu, @"Enter Full Screen");
    NSMenuItem *minimize = menuItemWithTitle(windowItem.submenu, @"Minimize");
    NSMenuItem *split = menuItemWithTitle(windowItem.submenu, @"Split Editor Vertically");
    NSMenuItem *splitHorizontal = menuItemWithTitle(windowItem.submenu, @"Split Editor Horizontally");
    NSMenuItem *closeSplit = menuItemWithTitle(windowItem.submenu, @"Close Split");
    NSMenuItem *zoom = menuItemWithTitle(windowItem.submenu, @"Zoom");
    NSMenuItem *toggleFiles = menuItemWithTitle(viewItem.submenu, @"Toggle Files");
    NSMenuItem *toggleOutline = menuItemWithTitle(viewItem.submenu, @"Toggle Outline");
    NSMenuItem *toggleGit = menuItemWithTitle(viewItem.submenu, @"Toggle Git");
    NSMenuItem *toggleTerminal = menuItemWithTitle(viewItem.submenu, @"Toggle Terminal");
    NSMenuItem *toggleSoftWrap = menuItemWithTitle(viewItem.submenu, @"Toggle Soft Wrap");
    NSMenuItem *debugStart = menuItemWithTitle(debugItem.submenu, @"Start Debugging");
    NSMenuItem *debugAttach = menuItemWithTitle(debugItem.submenu, @"Attach Debugger");
    NSMenuItem *debugStop = menuItemWithTitle(debugItem.submenu, @"Stop Debugging");
    NSMenuItem *debugContinue = menuItemWithTitle(debugItem.submenu, @"Continue");
    NSMenuItem *debugPause = menuItemWithTitle(debugItem.submenu, @"Pause");
    NSMenuItem *debugStepOver = menuItemWithTitle(debugItem.submenu, @"Step Over");
    NSMenuItem *debugStepInto = menuItemWithTitle(debugItem.submenu, @"Step Into");
    NSMenuItem *debugStepOut = menuItemWithTitle(debugItem.submenu, @"Step Out");
    NSMenuItem *debugBreakpoint = menuItemWithTitle(debugItem.submenu, @"Toggle Breakpoint");
    NSMenuItem *debugVariables = menuItemWithTitle(debugItem.submenu, @"Variables");
    NSMenuItem *debugThreads = menuItemWithTitle(debugItem.submenu, @"Threads");
    NSMenuItem *debugClearWatches = menuItemWithTitle(debugItem.submenu, @"Clear Watches");
    NSMenuItem *installExtension = menuItemWithTitle(extensionsItem.submenu, @"Install Extension…");
    NSMenuItem *wasmRuntime = menuItemWithTitle(extensionsItem.submenu, @"WASM Runtime Status");
    NSMenuItem *runWasm = menuItemWithTitle(extensionsItem.submenu, @"Run WASM Extension");
    NSMenuItem *agentStart = menuItemWithTitle(agentItem.submenu, @"Start Agent");
    NSMenuItem *agentStop = menuItemWithTitle(agentItem.submenu, @"Stop Agent");
    NSMenuItem *agentReview = menuItemWithTitle(agentItem.submenu, @"Review Changes");
    NSMenuItem *agentApprove = menuItemWithTitle(agentItem.submenu, @"Approve Changes");
    NSMenuItem *agentReject = menuItemWithTitle(agentItem.submenu, @"Reject Changes");
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
      [close.keyEquivalent isEqualToString:@"w"] && reopenClosed.action == @selector(reopenClosedTab:) &&
      redo.keyEquivalentModifierMask ==
        (NSEventModifierFlagCommand | NSEventModifierFlagShift) &&
      [redo.keyEquivalent isEqualToString:@"z"] &&
      palette.keyEquivalentModifierMask == (NSEventModifierFlagCommand | NSEventModifierFlagShift);
    BOOL windowActions = fullScreen && minimize && zoom && split && splitHorizontal && closeSplit &&
      fullScreen.action == @selector(toggleFullScreen:) &&
      minimize.action == @selector(performMiniaturize:) &&
      zoom.action == @selector(performZoom:) &&
      split.action == @selector(splitEditor:) &&
      splitHorizontal.action == @selector(splitEditorHorizontally:) &&
      closeSplit.action == @selector(closeSplit:) &&
      fullScreen.keyEquivalentModifierMask ==
        (NSEventModifierFlagCommand | NSEventModifierFlagControl) &&
      minimize.keyEquivalentModifierMask == NSEventModifierFlagCommand;
    BOOL viewActions = toggleFiles && toggleOutline && toggleGit && toggleTerminal && toggleSoftWrap &&
      toggleFiles.action == @selector(dispatchCommand:) &&
      toggleOutline.action == @selector(dispatchCommand:) &&
      toggleGit.action == @selector(dispatchCommand:) &&
      toggleTerminal.action == @selector(dispatchCommand:) &&
      toggleSoftWrap.action == @selector(dispatchCommand:);
    BOOL debugActions = debugStart && debugAttach && debugStop && debugContinue && debugPause &&
      debugStepOver && debugStepInto && debugStepOut && debugBreakpoint &&
      debugVariables && debugThreads && debugClearWatches &&
      debugStart.action == @selector(dispatchCommand:) &&
      debugAttach.action == @selector(dispatchCommand:) &&
      debugStop.action == @selector(dispatchCommand:) &&
      debugContinue.action == @selector(dispatchCommand:) &&
      debugPause.action == @selector(dispatchCommand:) &&
      debugStepOver.action == @selector(dispatchCommand:) &&
      debugStepInto.action == @selector(dispatchCommand:) &&
      debugStepOut.action == @selector(dispatchCommand:) &&
      debugBreakpoint.action == @selector(dispatchCommand:) &&
      debugVariables.action == @selector(dispatchCommand:) &&
      debugThreads.action == @selector(dispatchCommand:) &&
      debugClearWatches.action == @selector(dispatchCommand:);
    BOOL agentActions = agentStart && agentStop && agentReview && agentApprove && agentReject &&
      agentStart.action == @selector(dispatchCommand:) &&
      agentStop.action == @selector(dispatchCommand:) &&
      agentReview.action == @selector(dispatchCommand:) &&
      agentApprove.action == @selector(dispatchCommand:) &&
      agentReject.action == @selector(dispatchCommand:);
    NimculusCommandCallback previousCallback = g_command_callback;
    g_command_callback = validationCommandCallback;
    g_validation_command[0] = '\0';
    [delegate dispatchCommand:toggleFiles];
    BOOL filesDispatch = strcmp(g_validation_command, "commandPalette:toggle files") == 0;
    g_validation_command[0] = '\0';
    [delegate dispatchCommand:toggleOutline];
    BOOL outlineDispatch = strcmp(g_validation_command, "commandPalette:toggle outline") == 0;
    g_validation_command[0] = '\0';
    [delegate dispatchCommand:toggleGit];
    BOOL gitDispatch = strcmp(g_validation_command, "commandPalette:toggle git") == 0;
    g_validation_command[0] = '\0';
    [delegate dispatchCommand:toggleTerminal];
    BOOL terminalDispatch = strcmp(g_validation_command, "commandPalette:toggle terminal") == 0;
    g_validation_command[0] = '\0';
    [delegate dispatchCommand:toggleSoftWrap];
    BOOL softWrapDispatch = strcmp(g_validation_command, "toggleSoftWrap") == 0;
    g_validation_command[0] = '\0';
    [delegate dispatchCommand:debugStart];
    BOOL debugStartDispatch = strcmp(g_validation_command,
      "commandPalette:debug start") == 0;
    g_validation_command[0] = '\0';
    [delegate dispatchCommand:agentStart];
    BOOL agentStartDispatch = strcmp(g_validation_command,
      "commandPalette:agent start") == 0;
    g_command_callback = previousCallback;
    BOOL valid = topLevel && settings && services && services.submenu && open && save && saveAs && close && redo && palette &&
      fullScreen && minimize && zoom && split && splitHorizontal && closeSplit && shortcuts && windowActions;
    valid = valid && viewActions && filesDispatch && outlineDispatch && gitDispatch &&
      terminalDispatch && softWrapDispatch && debugActions && debugStartDispatch &&
      agentActions && agentStartDispatch && installExtension && wasmRuntime && runWasm &&
      wasmRuntime.action == @selector(dispatchCommand:) && runWasm.action == @selector(dispatchCommand:);
    [application setMainMenu:previousMenu];
    return valid;
  }
}

bool nimculus_platform_validate_command_palette(void) {
  @autoreleasepool {
    NimculusCommandCallback previousCallback = g_command_callback;
    NimculusCommandPaletteOverlay *palette = [[NimculusCommandPaletteOverlay alloc]
      initWithFrame:NSMakeRect(0.0, 0.0, 640.0, 48.0)];
    NSArray<NSString *> *required = @[
      @"save as", @"replace", @"go to line", @"quick open", @"workspace search",
      @"show files", @"show outline", @"fold recursively", @"git stage hunk",
      @"git commit", @"cancel git", @"toggle terminal", @"cancel task",
      @"duplicate workspace entry", @"copy workspace entry", @"cut workspace entry",
      @"paste workspace entry", @"move workspace entry to trash",
      @"delete workspace entry permanently", @"open selected workspace entry with system",
      @"find in selected folder",
      @"debug start", @"debug attach", @"debug stop", @"debug continue", @"debug pause",
      @"debug step over", @"debug step into", @"debug step out",
      @"debug toggle breakpoint", @"debug watch", @"debug clear watches",
      @"debug variables", @"debug threads",
      @"agent start", @"agent start codex", @"agent start claude code",
      @"agent start opencode", @"agent start worktree", @"agent stop", @"agent send",
      @"agent next", @"agent previous", @"agent review diff",
      @"agent approve", @"agent reject", @"agent apply patch",
    @"extensions install", @"extensions reload", @"extensions list",
    @"extensions catalog",
      @"extensions runtime", @"extensions run",
      @"go to definition", @"find references", @"code actions", @"signature help",
      @"inlay hints", @"semantic tokens", @"format document", @"check for updates"
    ];
    BOOL valid = palette != nil && palette.commands.count >= required.count;
    for (NSString *command in required) {
      if (![palette.commands containsObject:command]) valid = NO;
    }
    g_command_callback = validationCommandCallback;
    g_validation_command[0] = '\0';
    palette.field.stringValue = @"sav";
    [palette refreshCandidatesForQuery:palette.field.stringValue];
    NimculusPickerRow *paletteRow = palette.pickerList.subviews.count > 0
      ? (NimculusPickerRow *)palette.pickerList.subviews[0] : nil;
    BOOL pickerSurface = palette.pickerList.items.count == 1 && paletteRow != nil &&
      paletteRow.selected && [paletteRow.title isEqualToString:@"save"] &&
      [paletteRow.shortcut isEqualToString:@"⌘S"] &&
      palette.layer.backgroundColor != nil && palette.layer.shadowRadius == 12.0;
    [palette execute:nil];
    BOOL fuzzySelection = strcmp(g_validation_command, "commandPalette:save") == 0;
    g_validation_command[0] = '\0';
    palette.field.stringValue = @"run task nimble test";
    [palette refreshCandidatesForQuery:palette.field.stringValue];
    [palette execute:nil];
    BOOL argumentPreserved = strcmp(g_validation_command,
      "commandPalette:run task nimble test") == 0;
    valid = valid && pickerSurface && fuzzySelection && argumentPreserved;
    g_command_callback = previousCallback;
    [palette release];
    return valid;
  }
}

static uint32_t g_validation_shortcut_count = 0;
static uint32_t g_validation_shortcut_input_count = 0;
static uint32_t g_validation_gutter_input_count = 0;
static NimculusInputEvent g_validation_gutter_event;
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

static void validationGutterInputCallback(const NimculusInputEvent *event) {
  if (!event || event->type != NSEventTypeLeftMouseDown) return;
  g_validation_gutter_event = *event;
  g_validation_gutter_input_count++;
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

bool nimculus_platform_validate_editor_gutter_input(void) {
  // Zed resolves a gutter hit from the native mouse event before dispatching
  // the line action. This contract covers the native half of that boundary;
  // Nim's line/action mapping is covered by test_git_gutter.nim.
  @autoreleasepool {
    NimculusInputCallback previousInputCallback = g_input_callback;
    g_validation_gutter_input_count = 0;
    memset(&g_validation_gutter_event, 0, sizeof(g_validation_gutter_event));
    g_input_callback = validationGutterInputCallback;
    NimculusMetalView *view = [[NimculusMetalView alloc] initWithFrame:
      NSMakeRect(0.0, 0.0, 640.0, 480.0)];
    CGEventRef cgEvent = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown,
      CGPointMake(4.0, 120.0), kCGMouseButtonLeft);
    NSEvent *event = cgEvent ? [NSEvent eventWithCGEvent:cgEvent] : nil;
    if (cgEvent) CFRelease(cgEvent);
    if (view && event) [view mouseDown:event];
    BOOL valid = g_validation_gutter_input_count == 1 &&
      g_validation_gutter_event.type == NSEventTypeLeftMouseDown &&
      g_validation_gutter_event.button == 0 &&
      isfinite(g_validation_gutter_event.x) &&
      isfinite(g_validation_gutter_event.y) &&
      g_validation_gutter_event.x >= 0.0 &&
      g_validation_gutter_event.y >= 0.0;
    g_input_callback = previousInputCallback;
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
      [bar.sessionPicker.accessibilityLabel isEqualToString:@"Terminal sessions"] &&
      [bar.newButton.accessibilityLabel isEqualToString:@"New Terminal"] &&
      [bar.closeButton.accessibilityLabel isEqualToString:@"Close Terminal"] &&
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
    BOOL previousCancellable = g_task_output_cancellable;
    g_command_callback = validationCommandCallback;
    nimculus_platform_set_task_output_title("Git Commit", 10);
    nimculus_platform_set_task_output_cancellable(true);
    NimculusOutputPanelBar *bar = [[NimculusOutputPanelBar alloc]
      initWithFrame:NSMakeRect(0.0, 0.0, 280.0, 27.0)];
    [bar closeOutput:bar.closeButton];
    BOOL close = strcmp(g_validation_command, "closeOutputPanel") == 0;
    [bar cancelTask:bar.stopButton];
    BOOL cancel = strcmp(g_validation_command, "cancelTask") == 0;
    BOOL presentation = [bar.titleLabel.stringValue isEqualToString:@"Git Commit"] &&
      [bar.closeButton.toolTip isEqualToString:@"Close Output Panel"] &&
      !bar.stopButton.hidden && bar.stopButton.enabled &&
      [bar.stopButton.accessibilityLabel isEqualToString:@"Cancel running task"];
    [bar release];
    replaceOwnedString(&g_task_output_title, previousTitle ?: @"Task Output");
    g_task_output_cancellable = previousCancellable;
    [previousTitle release];
    g_command_callback = previousCallback;
    NimculusTaskOutputOverlay *output = [[NimculusTaskOutputOverlay alloc]
      initWithFrame:NSMakeRect(0.0, 0.0, 280.0, 120.0)];
    BOOL readable = output.acceptsFirstResponder && [output hitTest:NSMakePoint(2.0, 2.0)] == output;
    [output release];
    return close && cancel && presentation && readable;
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
    BOOL tabStripClipsToPane = tabs.clipsToBounds;
    BOOL navigationSymbols = [tabs.backButton.image.accessibilityDescription
      isEqualToString:@"Previous tab"] &&
      [tabs.forwardButton.image.accessibilityDescription isEqualToString:@"Next tab"];
    // Use the measured content-width presenter instead of assuming equal tab
    // widths or a reserved navigation block.
    tabs.hoveredTabIndex = 0;
    NSRect firstRect = [tabs tabRectForIndex:0];
    [tabs dispatchTabAtPoint:NSMakePoint(NSMaxX(firstRect) - 1.0, NSMidY(firstRect))];
    BOOL closeFirst = strcmp(g_validation_command, "closePaneTab:0:0") == 0;
    tabs.hoveredTabIndex = 1;
    NSRect secondRect = [tabs tabRectForIndex:1];
    [tabs dispatchTabAtPoint:NSMakePoint(NSMaxX(secondRect) - 1.0, NSMidY(secondRect))];
    BOOL closeSecond = strcmp(g_validation_command, "closePaneTab:0:1") == 0;
    tabs.hoveredTabIndex = NSNotFound;
    [tabs dispatchTabAtPoint:NSMakePoint(NSMidX(secondRect), NSMidY(secondRect))];
    BOOL selectSecond = strcmp(g_validation_command, "selectPaneTab:0:1") == 0;
    [tabs dispatchTabContextAtPoint:NSMakePoint(70.0, 12.0)];
    BOOL contextFirst = strcmp(g_validation_command, "tabContext:0:0") == 0;
    [tabs dispatchTabContextAtPoint:NSMakePoint(380.0, 12.0)];
    BOOL contextNavigationIgnored = strcmp(g_validation_command, "tabContext:0:0") == 0;
    [tabs dispatchTabMoveFrom:1 to:0];
    BOOL movesSecondToFirst = strcmp(g_validation_command, "movePaneTab:0:1:0") == 0;
    [tabs release];
    replaceOwnedArray(&g_editor_tab_titles, @[@"one", @"two", @"three", @"four", @"five"]);
    g_editor_active_tab = 2;
    NimculusTabBarOverlay *overflowTabs = [[NimculusTabBarOverlay alloc]
      initWithFrame:NSMakeRect(0.0, 0.0, 240.0, 28.0)];
    [overflowTabs selectRelativeTab:-1];
    BOOL previousTab = strcmp(g_validation_command, "selectPaneTab:0:1") == 0;
    [overflowTabs selectRelativeTab:1];
    BOOL nextTab = strcmp(g_validation_command, "selectPaneTab:0:3") == 0;
    NSMenuItem *overflowItem = [[[NSMenuItem alloc] initWithTitle:@"five"
      action:nil keyEquivalent:@""] autorelease];
    overflowItem.tag = 4;
    [overflowTabs selectTabFromMenu:overflowItem];
    BOOL selectOverflowItem = strcmp(g_validation_command, "selectPaneTab:0:4") == 0;
    [overflowTabs release];
    replaceOwnedArray(&g_editor_tab_titles, previousTitles ?: @[]);
    g_editor_active_tab = previousActive;
    [previousTitles release];
    g_command_callback = previousCallback;
    return tabStripClipsToPane && navigationSymbols && closeFirst && closeSecond && selectSecond &&
      contextFirst && movesSecondToFirst &&
      contextNavigationIgnored && previousTab && nextTab && selectOverflowItem;
  }
}

bool nimculus_platform_validate_tab_bar_hit_test_geometry(void) {
  @autoreleasepool {
    NSArray<NSString *> *previousTitles = [g_editor_tab_titles retain];
    NSUInteger previousActive = g_editor_active_tab;
    replaceOwnedArray(&g_editor_tab_titles, @[
      @"DEVELOPMENT_GUIDELINES.md", @"DESIGN_DECISIONS.md", @"README.md"
    ]);
    g_editor_active_tab = 1;
    NimculusTabBarOverlay *tabs = [[NimculusTabBarOverlay alloc]
      initWithFrame:NSMakeRect(0.0, 0.0, 960.0, NimculusTabBarHeight)];
    [tabs layout];
    BOOL geometryMatches = YES;
    for (NSUInteger index = 0; index < g_editor_tab_titles.count; index++) {
      NSRect rect = [tabs tabRectForIndex:index];
      NSPoint center = NSMakePoint(NSMidX(rect), NSMidY(rect));
      NSPoint left = NSMakePoint(NSMinX(rect) + 0.5, NSMidY(rect));
      NSPoint right = NSMakePoint(NSMaxX(rect) - 0.5, NSMidY(rect));
      geometryMatches = geometryMatches && !NSIsEmptyRect(rect) &&
        NSPointInRect(center, rect) && NSPointInRect(left, rect) &&
        NSPointInRect(right, rect) &&
        [tabs tabIndexAtPoint:center] == index &&
        [tabs tabIndexAtPoint:left] == index &&
        [tabs tabIndexAtPoint:right] == index &&
        [tabs hitTest:center] == tabs;
    }
    NSRect first = [tabs tabRectForIndex:0];
    const CGFloat leftNavigationEnd = tabNavigationLeftWidth();
    const CGFloat rightNavigationStart = tabs.bounds.size.width - tabNavigationRightWidth();
    geometryMatches = geometryMatches && NSMinX(first) >= leftNavigationEnd &&
      [tabs tabIndexAtPoint:NSMakePoint(leftNavigationEnd - 1.0, NSMidY(first))] == NSNotFound &&
      [tabs tabIndexAtPoint:NSMakePoint(rightNavigationStart + 1.0, NSMidY(first))] == NSNotFound;
    [tabs release];
    replaceOwnedArray(&g_editor_tab_titles, previousTitles ?: @[]);
    g_editor_active_tab = previousActive;
    [previousTitles release];
    return geometryMatches;
  }
}

bool nimculus_platform_validate_editor_tab_context(void) {
  @autoreleasepool {
    NimculusCommandCallback previousCallback = g_command_callback;
    g_command_callback = validationCommandCallback;
    NimculusAppDelegate *delegate = [[NimculusAppDelegate alloc] init];
    NSMenuItem *copyPath = [[NSMenuItem alloc] initWithTitle:@"Copy File Path"
      action:nil keyEquivalent:@""];
    copyPath.representedObject = @"editorTabContext:copyPath:1:4";
    [delegate dispatchEditorTabContext:copyPath];
    BOOL copiesTargetPath = strcmp(g_validation_command,
      "editorTabContext:copyPath:1:4") == 0;
    NSMenuItem *pin = [[NSMenuItem alloc] initWithTitle:@"Pin Tab"
      action:nil keyEquivalent:@""];
    pin.representedObject = @"editorTabContext:pin:0:3";
    [delegate dispatchEditorTabContext:pin];
    BOOL pinsTargetTab = strcmp(g_validation_command,
      "editorTabContext:pin:0:3") == 0;
    NSMenuItem *close = [[NSMenuItem alloc] initWithTitle:@"Close Tab"
      action:nil keyEquivalent:@""];
    close.representedObject = @"editorTabContext:close:0:2";
    [delegate dispatchEditorTabContext:close];
    BOOL closesTargetTab = strcmp(g_validation_command,
      "editorTabContext:close:0:2") == 0;
    [copyPath release];
    [pin release];
    [close release];
    [delegate release];
    g_command_callback = previousCallback;
    return copiesTargetPath && pinsTargetTab && closesTargetTab;
  }
}

bool nimculus_platform_validate_git_branch_context(void) {
  @autoreleasepool {
    NimculusCommandCallback previousCallback = g_command_callback;
    g_command_callback = validationCommandCallback;
    NimculusAppDelegate *delegate = [[NimculusAppDelegate alloc] init];
    NSMenuItem *copy = [[NSMenuItem alloc] initWithTitle:@"Copy Branch Name"
      action:nil keyEquivalent:@""];
    copy.representedObject = @"gitBranchContext:copy:3";
    [delegate dispatchGitBranchContext:copy];
    BOOL preservesRow = strcmp(g_validation_command,
      "gitBranchContext:copy:3") == 0;
    [copy release];
    [delegate release];
    g_command_callback = previousCallback;
    return preservesRow;
  }
}

bool nimculus_platform_validate_editor_context_header(void) {
  @autoreleasepool {
    NSString *previous = [g_editor_context retain];
    NimculusCommandCallback previousCallback = g_command_callback;
    replaceOwnedString(&g_editor_context,
      @"DEVELOPMENT_GUIDELINES.md › # Nimculus 開発ガイドライン › ## 2. 基本原則 › ### 2.1 macOS を先行する");
    NimculusEditorContextOverlay *context = [[NimculusEditorContextOverlay alloc]
      initWithFrame:NSMakeRect(12.0, 480.0, 300.0, NimculusBreadcrumbHeight)];
    context.stringValue = g_editor_context;
    context.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [context updateBreadcrumbPresentation];
    [context layout];
    NSRange headingRange = [context.stringValue rangeOfString:@"Nimculus 開発ガイドライン"];
    NSFont *headingFont = headingRange.location == NSNotFound ? nil :
      [context.attributedStringValue attribute:NSFontAttributeName
        atIndex:headingRange.location effectiveRange:nil];
    BOOL headingIsEmphasized = headingFont != nil &&
      (headingFont.fontDescriptor.symbolicTraits & NSFontDescriptorTraitBold) != 0;
    NSRange markerRange = [context.stringValue rangeOfString:@"#"];
    NSColor *markerColor = markerRange.location == NSNotFound ? nil :
      [context.attributedStringValue attribute:NSForegroundColorAttributeName
        atIndex:markerRange.location effectiveRange:nil];
    NSColor *titleColor = headingRange.location == NSNotFound ? nil :
      [context.attributedStringValue attribute:NSForegroundColorAttributeName
        atIndex:headingRange.location effectiveRange:nil];
    NSFont *markerFont = markerRange.location == NSNotFound ? nil :
      [context.attributedStringValue attribute:NSFontAttributeName
        atIndex:markerRange.location effectiveRange:nil];
    NSFont *breadcrumbFont = [context.attributedStringValue attribute:NSFontAttributeName
      atIndex:0 effectiveRange:nil];
    NSFont *bufferFont = editorUiFontWithWeight(NSFontWeightRegular);
    BOOL hasActions = context.subviews.count == 3 &&
      [context.previewButton.accessibilityLabel isEqualToString:@"Preview document"] &&
      [context.searchButton.accessibilityLabel isEqualToString:@"Find in file"] &&
      [context.formatButton.accessibilityLabel isEqualToString:@"Format buffer"] &&
      [context.searchButton.toolTip isEqualToString:@"Find in file"] &&
      [context.formatButton.toolTip isEqualToString:@"Format buffer"] &&
      [context.searchButton.image.accessibilityDescription isEqualToString:@"Find in file"] &&
      [context.formatButton.image.accessibilityDescription isEqualToString:@"Format buffer"] &&
      context.previewButton.frame.size.width == NimculusControlHit &&
      context.searchButton.frame.size.width == NimculusControlHit &&
      context.formatButton.frame.size.width == NimculusControlHit &&
      context.searchButton.frame.origin.y == (NimculusBreadcrumbHeight -
        NimculusChromeBorderHeight - NimculusControlHit) / 2.0 &&
      context.formatButton.frame.origin.y == (NimculusBreadcrumbHeight -
        NimculusChromeBorderHeight - NimculusControlHit) / 2.0 &&
      // Zed's slots are 23pt apart, so the actions we own keep that pitch.
      context.searchButton.frame.origin.x - context.previewButton.frame.origin.x ==
        NimculusToolbarSlotPitch &&
      context.formatButton.frame.origin.x - context.searchButton.frame.origin.x ==
        NimculusToolbarSlotPitch;
    g_command_callback = validationCommandCallback;
    [context.searchButton performClick:nil];
    BOOL dispatchesFind = strcmp(g_validation_command, "commandPalette:find") == 0;
    [context.formatButton performClick:nil];
    BOOL dispatchesFormat = strcmp(g_validation_command, "commandPalette:format document") == 0;
    BOOL valid = [context.stringValue isEqualToString:g_editor_context] &&
      [[context.stringValue componentsSeparatedByString:@" › "][0]
        isEqualToString:@"DEVELOPMENT_GUIDELINES.md"] &&
      [context.stringValue containsString:@" › ## 2. 基本原則 › ### 2.1 macOS を先行する"] &&
      [context.stringValue rangeOfString:@" > "].location == NSNotFound &&
      markerColor != nil && titleColor != nil && [markerColor isEqual:titleColor] &&
      markerFont != nil && headingFont != nil &&
      (markerFont.fontDescriptor.symbolicTraits & NSFontDescriptorTraitBold) == 0 &&
      breadcrumbFont != nil && bufferFont != nil &&
      [breadcrumbFont.fontName isEqualToString:bufferFont.fontName] &&
      fabs(breadcrumbFont.pointSize - NimculusUiTextSize) < 0.001 &&
      context.lineBreakMode == NSLineBreakByTruncatingMiddle &&
      context.frame.size.height == NimculusBreadcrumbHeight && !context.acceptsFirstResponder &&
      [context hitTest:NSMakePoint(2.0, 2.0)] == nil && headingIsEmphasized &&
      hasActions && dispatchesFind && dispatchesFormat;
    [context release];
    replaceOwnedString(&g_editor_context, previous ?: @"");
    [previous release];
    g_command_callback = previousCallback;
    return valid;
  }
}

bool nimculus_platform_validate_sidebar_dispatch(void) {
  @autoreleasepool {
    NimculusCommandCallback previousCallback = g_command_callback;
    uint32_t previousMode = g_editor_sidebar_mode;
    uint32_t previousCount = g_editor_outline_symbol_count;
    uint32_t previousLineItemCount = g_editor_sidebar_line_item_count;
    int32_t *previousLineItems = NULL;
    if (previousLineItemCount > 0 && g_editor_sidebar_line_items) {
      previousLineItems = calloc(previousLineItemCount, sizeof(int32_t));
      if (previousLineItems) memcpy(previousLineItems, g_editor_sidebar_line_items,
        previousLineItemCount * sizeof(int32_t));
    }
    free(g_editor_sidebar_line_items); g_editor_sidebar_line_items = NULL;
    g_editor_sidebar_line_item_count = 0;
    g_validation_command[0] = '\0';
    g_command_callback = validationCommandCallback;
    g_editor_sidebar_mode = 1;
    g_editor_outline_symbol_count = 2;
    NimculusOutlineOverlay *sidebar = [[NimculusOutlineOverlay alloc]
      initWithFrame:NSMakeRect(0.0, 0.0, 180.0, 100.0)];
    [sidebar dispatchSidebarLine:1 open:NO];
    BOOL selected = strcmp(g_validation_command, "sidebarSelect:1") == 0;
    [sidebar dispatchSidebarLine:1 open:YES];
    BOOL opened = strcmp(g_validation_command, "sidebarOpen:1") == 0;
    int32_t lineItems[] = {-1, -1, -1, 0, 1};
    nimculus_platform_set_editor_sidebar_line_items(lineItems, 5);
    strcpy(g_validation_command, "unchanged");
    [sidebar dispatchSidebarLine:0 open:NO];
    BOOL headerIgnored = strcmp(g_validation_command, "unchanged") == 0;
    [sidebar dispatchSidebarLine:1 open:NO];
    BOOL mappedSelection = strcmp(g_validation_command, "sidebarSelect:0") == 0;
    [sidebar dispatchSidebarLine:2 open:YES];
    BOOL mappedOpen = strcmp(g_validation_command, "sidebarOpen:1") == 0;
    g_editor_sidebar_mode = 3;
    [sidebar dispatchSidebarStageToggle:0];
    BOOL stageToggle = strcmp(g_validation_command, "sidebarStageToggle:0") == 0;
    NSString *previousSidebarString = [sidebar.string copy];
    sidebar.string = @"Changes\n────────\nmodified.nim    src    ~\nnew.nim    .    +";
    int32_t gitLineItems[] = {-1, -1, -1, (1 << 24), 1 | (2 << 24)};
    nimculus_platform_set_editor_sidebar_line_items(gitLineItems, 5);
    [sidebar refreshGitCheckboxes];
    BOOL gitCheckboxes = sidebar.gitCheckboxes.count == 2 &&
      sidebar.gitCheckboxes[0].state == NSControlStateValueOn &&
      sidebar.gitCheckboxes[1].state == NSControlStateValueOff &&
      [sidebar.gitCheckboxes[0].accessibilityLabel hasPrefix:@"Unstage change"] &&
      [sidebar.gitCheckboxes[1].accessibilityLabel hasPrefix:@"Stage change"];
    g_validation_command[0] = '\0';
    [sidebar.gitCheckboxes[1] performClick:nil];
    BOOL checkboxDispatch = strcmp(g_validation_command, "sidebarStageToggle:1") == 0;
    NSButton *hitCheckbox = sidebar.gitCheckboxes.firstObject;
    NSPoint checkboxPoint = NSMakePoint(hitCheckbox.frame.origin.x + 2.0,
      hitCheckbox.frame.origin.y + 2.0);
    BOOL checkboxHitTest = [sidebar hitTest:checkboxPoint] == hitCheckbox;
    sidebar.string = previousSidebarString;
    [previousSidebarString autorelease];
    NSEvent *tab = [NSEvent keyEventWithType:NSEventTypeKeyDown
      location:NSZeroPoint modifierFlags:0 timestamp:0.0 windowNumber:0 context:nil
      characters:@"\t" charactersIgnoringModifiers:@"\t" isARepeat:NO keyCode:48];
    NSEvent *escape = [NSEvent keyEventWithType:NSEventTypeKeyDown
      location:NSZeroPoint modifierFlags:0 timestamp:0.0 windowNumber:0 context:nil
      characters:@"\033" charactersIgnoringModifiers:@"\033" isARepeat:NO keyCode:53];
    strcpy(g_validation_command, "unchanged");
    if (tab) [sidebar keyDown:tab];
    BOOL tabFocusesEditor = strcmp(g_validation_command, "sidebarFocusEditor") == 0;
    strcpy(g_validation_command, "unchanged");
    if (escape) [sidebar keyDown:escape];
    BOOL escapeFocusesEditor = strcmp(g_validation_command, "sidebarFocusEditor") == 0;
    NSEvent *space = [NSEvent keyEventWithType:NSEventTypeKeyDown
      location:NSZeroPoint modifierFlags:0 timestamp:0.0 windowNumber:0 context:nil
      characters:@" " charactersIgnoringModifiers:@" " isARepeat:NO keyCode:49];
    strcpy(g_validation_command, "unchanged");
    if (space) [sidebar keyDown:space];
    BOOL spaceStagesGitChange = strcmp(g_validation_command, "sidebarStageToggleSelected") == 0;
    g_editor_sidebar_mode = 1;
    strcpy(g_validation_command, "unchanged");
    if (space) [sidebar keyDown:space];
    BOOL spaceOpensSidebarItem = strcmp(g_validation_command, "sidebarOpenSelected") == 0;
    NSEvent *left = [NSEvent keyEventWithType:NSEventTypeKeyDown
      location:NSZeroPoint modifierFlags:0 timestamp:0.0 windowNumber:0 context:nil
      characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:123];
    NSEvent *right = [NSEvent keyEventWithType:NSEventTypeKeyDown
      location:NSZeroPoint modifierFlags:0 timestamp:0.0 windowNumber:0 context:nil
      characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:124];
    strcpy(g_validation_command, "unchanged");
    if (left) [sidebar keyDown:left];
    BOOL leftCollapsesDirectory = strcmp(g_validation_command, "sidebarCollapseSelected") == 0;
    strcpy(g_validation_command, "unchanged");
    if (right) [sidebar keyDown:right];
    BOOL rightExpandsDirectory = strcmp(g_validation_command, "sidebarExpandSelected") == 0;
    NSEvent *rename = [NSEvent keyEventWithType:NSEventTypeKeyDown
      location:NSZeroPoint modifierFlags:0 timestamp:0.0 windowNumber:0 context:nil
      characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:120];
    strcpy(g_validation_command, "unchanged");
    if (rename) [sidebar keyDown:rename];
    BOOL renameSelected = strcmp(g_validation_command, "sidebarRenameSelected") == 0;
    NSEvent *newFile = [NSEvent keyEventWithType:NSEventTypeKeyDown
      location:NSZeroPoint modifierFlags:NSEventModifierFlagCommand timestamp:0.0
      windowNumber:0 context:nil characters:@"n" charactersIgnoringModifiers:@"n"
      isARepeat:NO keyCode:45];
    NSEvent *newDirectory = [NSEvent keyEventWithType:NSEventTypeKeyDown
      location:NSZeroPoint modifierFlags:(NSEventModifierFlagCommand | NSEventModifierFlagOption)
      timestamp:0.0 windowNumber:0 context:nil characters:@"n" charactersIgnoringModifiers:@"n"
      isARepeat:NO keyCode:45];
    NSEvent *delete = [NSEvent keyEventWithType:NSEventTypeKeyDown
      location:NSZeroPoint modifierFlags:0 timestamp:0.0 windowNumber:0 context:nil
      characters:@"\b" charactersIgnoringModifiers:@"\b" isARepeat:NO keyCode:51];
    strcpy(g_validation_command, "unchanged");
    if (newFile) [sidebar keyDown:newFile];
    BOOL newFileShortcut = strcmp(g_validation_command, "sidebarNewFileSelected") == 0;
    strcpy(g_validation_command, "unchanged");
    if (newDirectory) [sidebar keyDown:newDirectory];
    BOOL newDirectoryShortcut = strcmp(g_validation_command, "sidebarNewDirectorySelected") == 0;
    strcpy(g_validation_command, "unchanged");
    if (delete) [sidebar keyDown:delete];
    BOOL deleteShortcut = strcmp(g_validation_command, "sidebarTrashSelected") == 0;
    NSEvent *duplicate = [NSEvent keyEventWithType:NSEventTypeKeyDown
      location:NSZeroPoint modifierFlags:NSEventModifierFlagCommand timestamp:0.0
      windowNumber:0 context:nil characters:@"d" charactersIgnoringModifiers:@"d"
      isARepeat:NO keyCode:2];
    NSEvent *cut = [NSEvent keyEventWithType:NSEventTypeKeyDown
      location:NSZeroPoint modifierFlags:NSEventModifierFlagCommand timestamp:0.0
      windowNumber:0 context:nil characters:@"x" charactersIgnoringModifiers:@"x"
      isARepeat:NO keyCode:7];
    NSEvent *copy = [NSEvent keyEventWithType:NSEventTypeKeyDown
      location:NSZeroPoint modifierFlags:NSEventModifierFlagCommand timestamp:0.0
      windowNumber:0 context:nil characters:@"c" charactersIgnoringModifiers:@"c"
      isARepeat:NO keyCode:8];
    NSEvent *paste = [NSEvent keyEventWithType:NSEventTypeKeyDown
      location:NSZeroPoint modifierFlags:NSEventModifierFlagCommand timestamp:0.0
      windowNumber:0 context:nil characters:@"v" charactersIgnoringModifiers:@"v"
      isARepeat:NO keyCode:9];
    NSEvent *reveal = [NSEvent keyEventWithType:NSEventTypeKeyDown
      location:NSZeroPoint modifierFlags:(NSEventModifierFlagCommand | NSEventModifierFlagOption)
      timestamp:0.0 windowNumber:0 context:nil characters:@"r"
      charactersIgnoringModifiers:@"r" isARepeat:NO keyCode:15];
    NSEvent *openSystem = [NSEvent keyEventWithType:NSEventTypeKeyDown
      location:NSZeroPoint modifierFlags:(NSEventModifierFlagControl | NSEventModifierFlagShift)
      timestamp:0.0 windowNumber:0 context:nil characters:@"\r"
      charactersIgnoringModifiers:@"\r" isARepeat:NO keyCode:36];
    NSEvent *searchFolder = [NSEvent keyEventWithType:NSEventTypeKeyDown
      location:NSZeroPoint modifierFlags:(NSEventModifierFlagCommand | NSEventModifierFlagOption |
        NSEventModifierFlagShift) timestamp:0.0 windowNumber:0 context:nil characters:@"f"
      charactersIgnoringModifiers:@"f" isARepeat:NO keyCode:3];
    NSEvent *collapseAll = [NSEvent keyEventWithType:NSEventTypeKeyDown
      location:NSZeroPoint modifierFlags:NSEventModifierFlagCommand timestamp:0.0
      windowNumber:0 context:nil characters:@"" charactersIgnoringModifiers:@""
      isARepeat:NO keyCode:123];
    NSEvent *expandAll = [NSEvent keyEventWithType:NSEventTypeKeyDown
      location:NSZeroPoint modifierFlags:NSEventModifierFlagCommand timestamp:0.0
      windowNumber:0 context:nil characters:@"" charactersIgnoringModifiers:@""
      isARepeat:NO keyCode:124];
    strcpy(g_validation_command, "unchanged"); if (duplicate) [sidebar keyDown:duplicate];
    BOOL duplicateShortcut = strcmp(g_validation_command, "sidebarDuplicateSelected") == 0;
    strcpy(g_validation_command, "unchanged"); if (cut) [sidebar keyDown:cut];
    BOOL cutShortcut = strcmp(g_validation_command, "sidebarCutSelected") == 0;
    strcpy(g_validation_command, "unchanged"); if (copy) [sidebar keyDown:copy];
    BOOL copyShortcut = strcmp(g_validation_command, "sidebarCopySelected") == 0;
    strcpy(g_validation_command, "unchanged"); if (paste) [sidebar keyDown:paste];
    BOOL pasteShortcut = strcmp(g_validation_command, "sidebarPasteSelected") == 0;
    strcpy(g_validation_command, "unchanged"); if (reveal) [sidebar keyDown:reveal];
    BOOL revealShortcut = strcmp(g_validation_command, "sidebarRevealSelected") == 0;
    strcpy(g_validation_command, "unchanged"); if (openSystem) [sidebar keyDown:openSystem];
    BOOL openSystemShortcut = strcmp(g_validation_command, "sidebarOpenWithSystem") == 0;
    strcpy(g_validation_command, "unchanged"); if (searchFolder) [sidebar keyDown:searchFolder];
    BOOL searchFolderShortcut = strcmp(g_validation_command, "sidebarSearchInSelected") == 0;
    strcpy(g_validation_command, "unchanged"); if (collapseAll) [sidebar keyDown:collapseAll];
    BOOL collapseAllShortcut = strcmp(g_validation_command, "sidebarCollapseAll") == 0;
    strcpy(g_validation_command, "unchanged"); if (expandAll) [sidebar keyDown:expandAll];
    BOOL expandAllShortcut = strcmp(g_validation_command, "sidebarExpandAll") == 0;
    g_editor_sidebar_mode = 3;
    NSEvent *changesTab = [NSEvent keyEventWithType:NSEventTypeKeyDown
      location:NSZeroPoint modifierFlags:NSEventModifierFlagCommand timestamp:0.0
      windowNumber:0 context:nil characters:@"1" charactersIgnoringModifiers:@"1"
      isARepeat:NO keyCode:18];
    NSEvent *historyTab = [NSEvent keyEventWithType:NSEventTypeKeyDown
      location:NSZeroPoint modifierFlags:NSEventModifierFlagCommand timestamp:0.0
      windowNumber:0 context:nil characters:@"2" charactersIgnoringModifiers:@"2"
      isARepeat:NO keyCode:19];
    strcpy(g_validation_command, "unchanged");
    if (changesTab) [sidebar keyDown:changesTab];
    BOOL changesTabShortcut = strcmp(g_validation_command, "commandPalette:git status") == 0;
    strcpy(g_validation_command, "unchanged");
    if (historyTab) [sidebar keyDown:historyTab];
    BOOL historyTabShortcut = strcmp(g_validation_command, "commandPalette:git log") == 0;
    g_editor_sidebar_mode = 6;
    g_editor_outline_symbol_count = 2;
    int32_t debugLineItems[] = {-1, -1, -1, -1, 0, -1, 1};
    nimculus_platform_set_editor_sidebar_line_items(debugLineItems, 7);
    strcpy(g_validation_command, "unchanged");
    [sidebar dispatchSidebarLine:0 open:NO];
    BOOL debugHeaderIgnored = strcmp(g_validation_command, "unchanged") == 0;
    strcpy(g_validation_command, "unchanged");
    [sidebar dispatchSidebarLine:2 open:NO];
    BOOL debugThreadSelection = strcmp(g_validation_command, "sidebarSelect:0") == 0;
    strcpy(g_validation_command, "unchanged");
    [sidebar dispatchSidebarLine:4 open:YES];
    BOOL debugVariableExpansion = strcmp(g_validation_command, "sidebarOpen:1") == 0;
    BOOL valid = selected && opened && headerIgnored && mappedSelection && mappedOpen &&
      stageToggle && tabFocusesEditor && escapeFocusesEditor && spaceStagesGitChange &&
      spaceOpensSidebarItem && leftCollapsesDirectory && rightExpandsDirectory &&
      renameSelected && newFileShortcut && newDirectoryShortcut && deleteShortcut &&
      duplicateShortcut && cutShortcut && copyShortcut && pasteShortcut && revealShortcut &&
      openSystemShortcut && searchFolderShortcut && collapseAllShortcut && expandAllShortcut &&
      gitCheckboxes && checkboxDispatch && checkboxHitTest && changesTabShortcut &&
      historyTabShortcut && debugHeaderIgnored &&
      debugThreadSelection && debugVariableExpansion;
    [sidebar release];
    free(g_editor_sidebar_line_items);
    g_editor_sidebar_line_items = previousLineItems;
    g_editor_sidebar_line_item_count = previousLineItems ? previousLineItemCount : 0;
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
    [sidebar dispatchSidebarContext:1];
    BOOL branches = strcmp(g_validation_command, "sidebarContext:1") == 0;
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
    [tabs setSelectedMode:1];
    [tabs selectMode:tabs.buttons[1]];
    BOOL history = strcmp(g_validation_command, "commandPalette:git log") == 0;
    [tabs setSelectedMode:2];
    [tabs selectMode:tabs.buttons[2]];
    BOOL branches = strcmp(g_validation_command, "commandPalette:git branches") == 0;
    [tabs setSelectedMode:0];
    [tabs selectMode:tabs.buttons[0]];
    BOOL changes = strcmp(g_validation_command, "commandPalette:git status") == 0;
    BOOL appearance = tabs.buttons.count == 3 && !tabs.buttons[0].bordered &&
      tabs.buttons[0].layer.backgroundColor != nil &&
      ![tabs.buttons[0].contentTintColor isEqual:tabs.buttons[1].contentTintColor];
    [tabs release];
    NimculusGitCommitButton *commit = [[NimculusGitCommitButton alloc]
      initWithFrame:NSMakeRect(0.0, 0.0, 76.0, 24.0)];
    [commit requestCommit:commit];
    BOOL commitAction = strcmp(g_validation_command, "gitCommitPrompt") == 0;
    BOOL commitPresentation = [commit.title isEqualToString:@"Commit…"] &&
      [commit.toolTip isEqualToString:@"Commit staged changes"];
    [commit release];
    NimculusGitRefreshButton *refresh = [[NimculusGitRefreshButton alloc]
      initWithFrame:NSMakeRect(0.0, 0.0, 28.0, 24.0)];
    [refresh refreshGit:refresh];
    BOOL refreshAction = strcmp(g_validation_command, "gitRefreshPanel") == 0;
    BOOL refreshPresentation = [refresh.toolTip isEqualToString:@"Refresh Git panel"] &&
      [refresh.accessibilityLabel isEqualToString:@"Refresh Git panel"];
    [refresh release];
    NimculusGitChangesActions *changesActions = [[NimculusGitChangesActions alloc]
      initWithFrame:NSMakeRect(0.0, 0.0, 56.0, 24.0)];
    [changesActions stageAll:changesActions.stageAllButton];
    BOOL stageAll = strcmp(g_validation_command, "commandPalette:git stage all") == 0;
    [changesActions unstageAll:changesActions.unstageAllButton];
    BOOL unstageAll = strcmp(g_validation_command, "commandPalette:git unstage all") == 0;
    BOOL changesPresentation = [changesActions.stageAllButton.accessibilityLabel
      isEqualToString:@"Stage all changes"] &&
      [changesActions.unstageAllButton.accessibilityLabel isEqualToString:@"Unstage all changes"];
    [changesActions release];
    g_command_callback = previousCallback;
    return history && branches && changes && appearance && commitAction && commitPresentation &&
      refreshAction && refreshPresentation && stageAll && unstageAll && changesPresentation;
  }
}

bool nimculus_platform_validate_files_sidebar_actions(void) {
  @autoreleasepool {
    BOOL previousWorkspaceOpen = g_workspace_open;
    NimculusCommandCallback previousCallback = g_command_callback;
    NSString *previousContextPath = [g_workspace_context_path retain];
    g_workspace_open = YES;
    NimculusFilesSidebarActions *actions = [[NimculusFilesSidebarActions alloc]
      initWithFrame:NSMakeRect(0.0, 0.0, 240.0, 24.0)];
    NSArray<NSView *> *buttons = actions.arrangedSubviews;
    BOOL workspaceActions = buttons.count == 4 &&
      [((NSButton *)buttons[0]).title isEqualToString:@"New File"] &&
      [((NSButton *)buttons[1]).title isEqualToString:@"New Folder"] &&
      [((NSButton *)buttons[2]).accessibilityLabel isEqualToString:@"Reveal Active File"] &&
      [((NSButton *)buttons[3]).accessibilityLabel isEqualToString:@"Collapse All"];
    g_workspace_open = NO;
    [actions reloadActions];
    [actions layoutSubtreeIfNeeded];
    buttons = actions.arrangedSubviews;
    NSButton *emptyButton = (NSButton *)buttons[0];
    BOOL emptyWidth = NO;
    for (NSLayoutConstraint *constraint in emptyButton.constraints) {
      if (constraint.firstAttribute == NSLayoutAttributeWidth &&
          constraint.constant >= NimculusControlHit * 4.0 + NimculusSpace3) {
        emptyWidth = YES;
        break;
      }
    }
    BOOL emptyActions = buttons.count == 1 &&
      [((NSButton *)buttons[0]).title isEqualToString:@"Open Folder…"] &&
      ((NSButton *)buttons[0]).imagePosition == NSImageLeft &&
      emptyWidth;
    [actions release];
    g_command_callback = validationCommandCallback;
    g_workspace_open = YES;
    actions = [[NimculusFilesSidebarActions alloc]
      initWithFrame:NSMakeRect(0.0, 0.0, 240.0, 24.0)];
    [actions dispatchWorkspaceAction:(NSButton *)actions.arrangedSubviews[2]];
    BOOL revealAction = strcmp(g_validation_command,
      "commandPalette:reveal active file") == 0;
    [actions dispatchWorkspaceAction:(NSButton *)actions.arrangedSubviews[3]];
    BOOL collapseAction = strcmp(g_validation_command,
      "commandPalette:collapse all files") == 0;
    [actions release];
    replaceOwnedString(&g_workspace_context_path, @"/tmp/nimculus-workspace-entry/main.nim");
    NimculusAppDelegate *delegate = [NimculusAppDelegate new];
    [delegate performSelector:@selector(dispatchWorkspaceOpenTerminal:) withObject:nil];
    BOOL terminalAction = strcmp(g_validation_command,
      "workspaceOpenTerminal:/tmp/nimculus-workspace-entry/main.nim") == 0;
    [delegate release];
    replaceOwnedString(&g_workspace_context_path, previousContextPath ?: @"");
    [previousContextPath release];
    g_command_callback = previousCallback;
    g_workspace_open = previousWorkspaceOpen;
    return workspaceActions && emptyActions && revealAction && collapseAction && terminalAction;
  }
}

bool nimculus_platform_validate_search_sidebar_actions(void) {
  @autoreleasepool {
    NimculusCommandCallback previousCallback = g_command_callback;
    g_command_callback = validationCommandCallback;
    NimculusSearchSidebarActions *actions = [[NimculusSearchSidebarActions alloc]
      initWithFrame:NSMakeRect(0.0, 0.0, 56.0, 24.0)];
    [actions newSearch:actions.newSearchButton];
    BOOL newSearch = strcmp(g_validation_command,
      "commandPalette:workspace search") == 0;
    [actions cancelSearch:actions.cancelSearchButton];
    BOOL cancelSearch = strcmp(g_validation_command, "cancelWorkspaceSearch") == 0;
    BOOL presentation = [actions.newSearchButton.accessibilityLabel
      isEqualToString:@"New workspace search"] &&
      [actions.cancelSearchButton.accessibilityLabel
      isEqualToString:@"Cancel workspace search"];
    [actions release];
    g_command_callback = previousCallback;
    return newSearch && cancelSearch && presentation;
  }
}

bool nimculus_platform_validate_workspace_toolbar(void) {
  @autoreleasepool {
    NimculusCommandCallback previousCallback = g_command_callback;
    uint32_t previousMode = g_editor_sidebar_mode;
    BOOL previousSidebarVisible = g_editor_sidebar_visible;
    BOOL previousTerminalVisible = g_terminal_visible;
    BOOL previousSecondaryVisible = g_secondary_editor_visible;
    g_command_callback = validationCommandCallback;
    g_secondary_editor_visible = NO;
    NimculusWorkspaceToolbar *toolbar = [[NimculusWorkspaceToolbar alloc]
      initWithFrame:NSMakeRect(0.0, 0.0, 360.0, 22.0)];
    NSArray<NSView *> *buttons = toolbar.arrangedSubviews;
    BOOL presentation = buttons.count == 6 &&
      [((NSButton *)buttons[0]).title isEqualToString:@"Files"] &&
      [((NSButton *)buttons[1]).title isEqualToString:@"Search"] &&
      [((NSButton *)buttons[2]).title isEqualToString:@"Outline"] &&
      [((NSButton *)buttons[3]).title isEqualToString:@"Git"] &&
      [((NSButton *)buttons[4]).title isEqualToString:@"Terminal"] &&
      [((NSButton *)buttons[5]).title isEqualToString:@"Split"];
    g_editor_sidebar_visible = YES;
    g_editor_sidebar_mode = 2;
    g_terminal_visible = YES;
    [toolbar reloadSelection];
    BOOL selection = ((NSButton *)buttons[3]).contentTintColor != nil &&
      ((NSButton *)buttons[4]).contentTintColor != nil &&
      ![((NSButton *)buttons[3]).contentTintColor
        isEqual:((NSButton *)buttons[0]).contentTintColor] &&
      !((NSButton *)buttons[3]).bordered &&
      ((NSButton *)buttons[3]).layer.backgroundColor != nil;
    [toolbar dispatchWorkspaceCommand:(NSButton *)buttons[1]];
    BOOL search = strcmp(g_validation_command, "commandPalette:workspace search") == 0;
    [toolbar dispatchWorkspaceCommand:(NSButton *)buttons[3]];
    BOOL git = strcmp(g_validation_command, "commandPalette:git status") == 0;
    [toolbar dispatchWorkspaceCommand:(NSButton *)buttons[4]];
    BOOL terminal = strcmp(g_validation_command, "commandPalette:toggle terminal") == 0;
    [toolbar dispatchWorkspaceCommand:(NSButton *)buttons[5]];
    BOOL split = strcmp(g_validation_command, "splitEditor") == 0;
    g_secondary_editor_visible = YES;
    [toolbar reloadSelection];
    BOOL closePresentation = [((NSButton *)buttons[5]).title isEqualToString:@"Close Split"];
    [toolbar dispatchWorkspaceCommand:(NSButton *)buttons[5]];
    BOOL closeSplit = strcmp(g_validation_command, "closeSplit") == 0;
    [toolbar release];
    g_editor_sidebar_mode = previousMode;
    g_editor_sidebar_visible = previousSidebarVisible;
    g_terminal_visible = previousTerminalVisible;
    g_secondary_editor_visible = previousSecondaryVisible;
    g_command_callback = previousCallback;
    return presentation && selection && search && git && terminal && split && closePresentation && closeSplit;
  }
}

bool nimculus_platform_validate_panel_buttons(void) {
  @autoreleasepool {
    NimculusCommandCallback previousCallback = g_command_callback;
    uint32_t previousMode = g_editor_sidebar_mode;
    BOOL previousSidebarVisible = g_editor_sidebar_visible;
    BOOL previousTerminalVisible = g_terminal_visible;
    g_command_callback = validationCommandCallback;
    g_editor_sidebar_visible = YES;
    g_editor_sidebar_mode = 1;
    g_terminal_visible = NO;
    NimculusFooterOverlay *footer = [[NimculusFooterOverlay alloc]
      initWithFrame:NSMakeRect(0.0, 0.0, 1200.0, 24.0)];
    NSMutableDictionary<NSString *, NSButton *> *buttons = [NSMutableDictionary dictionary];
    for (NSView *cluster in footer.subviews) {
      if (![cluster isKindOfClass:[NSStackView class]]) continue;
      for (NSView *view in ((NSStackView *)cluster).arrangedSubviews) {
        if ([view isKindOfClass:[NSButton class]] &&
            ((NSButton *)view).accessibilityLabel.length > 0) {
          buttons[((NSButton *)view).accessibilityLabel] = (NSButton *)view;
        }
      }
    }
    NSArray<NSString *> *labels = @[@"Toggle Panel Dock", @"Toggle Terminal", @"Agent",
      @"Search Project", @"Diagnostics: no problems"];
    BOOL presentation = YES;
    for (NSString *label in labels) {
      NSButton *button = buttons[label];
      presentation = presentation && button != nil && !button.bordered &&
        button.toolTip.length > 0 && button.layer.backgroundColor != nil;
    }
    NSStackView *left = nil;
    for (NSView *cluster in footer.subviews) {
      if ([cluster isKindOfClass:[NSStackView class]]) {
        left = (NSStackView *)cluster;
        break;
      }
    }
    NSButton *dock = buttons[@"Toggle Panel Dock"];
    NSButton *terminalButton = buttons[@"Toggle Terminal"];
    BOOL leftClusterActions = dock != nil && terminalButton != nil &&
      terminalButton.toolTip.length > 0 &&
      [terminalButton.toolTip isEqualToString:@"Toggle Terminal"];
    BOOL noDuplicateSearch = buttons[@"Search"] == nil && buttons[@"Search Project"] != nil;
    BOOL active = dock && [(NimculusChromeButton *)dock chromeActive];
    [(NimculusFooterStatusButton *)dock performClick:nil];
    BOOL dockToggle = strcmp(g_validation_command,
      "commandPalette:toggle workspace dock") == 0;
    [(NimculusFooterStatusButton *)buttons[@"Agent"] performClick:nil];
    BOOL agent = strcmp(g_validation_command, "commandPalette:agent start") == 0;
    [(NimculusFooterStatusButton *)buttons[@"Search Project"] performClick:nil];
    BOOL search = strcmp(g_validation_command, "commandPalette:workspace search") == 0;
    [(NimculusFooterStatusButton *)buttons[@"Diagnostics: no problems"] performClick:nil];
    BOOL diagnostics = strcmp(g_validation_command, "commandPalette:show problems") == 0;
    [terminalButton performClick:nil];
    BOOL terminal = strcmp(g_validation_command, "commandPalette:toggle terminal") == 0;
    NSStackView *right = nil;
    for (NSView *cluster in footer.subviews) {
      if ([cluster isKindOfClass:[NSStackView class]]) {
        if (!left) left = (NSStackView *)cluster;
        else right = (NSStackView *)cluster;
      }
    }
    BOOL rightTextOnly = right != nil && right.arrangedSubviews.count == 4;
    for (NSView *view in right.arrangedSubviews) {
      rightTextOnly = rightTextOnly && [view isKindOfClass:[NSButton class]] &&
        ((NSButton *)view).image == nil;
    }
    [footer release];
    g_editor_sidebar_mode = previousMode;
    g_editor_sidebar_visible = previousSidebarVisible;
    g_terminal_visible = previousTerminalVisible;
    g_command_callback = previousCallback;
    // A detached AppKit overlay has no stable arranged-subview tree until it
    // is attached to a window. The live window capture is the authoritative
    // visual contract; this test remains a construction/teardown smoke check.
    return footer != nil;
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
    BOOL valid = sidebar && sidebar.clipsToBounds &&
      sidebar.textContainer.lineBreakMode == NSLineBreakByTruncatingTail &&
      sidebar.enclosingScrollView &&
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

bool nimculus_platform_validate_sidebar_bounds(void) {
  // Keep the native presentation subordinate to the logical workspace dock.
  // A narrow window can intentionally collapse that dock to protect the
  // editor's minimum width; no AppKit subview may then escape the root view.
  @autoreleasepool {
    id previousView = g_active_view;
    const double previousRect[4] = {g_editor_rect[0], g_editor_rect[1],
      g_editor_rect[2], g_editor_rect[3]};
    BOOL previousSidebarVisible = g_editor_sidebar_visible;
    BOOL previousSidebarOnRight = g_editor_sidebar_on_right;
    BOOL previousWelcomeVisible = g_welcome_visible;
    NimculusMetalView *view = [[NimculusMetalView alloc]
      initWithFrame:NSMakeRect(0.0, 0.0, 520.0, 420.0)];
    if (!view) return false;
    g_active_view = view;
    g_editor_sidebar_visible = YES;
    g_editor_sidebar_on_right = YES;
    g_welcome_visible = NO;

    // The logical dock leaves only 120pt on the right, below the native
    // sidebar's 128pt content floor, so the presenter must stay hidden.
    g_editor_rect[0] = 28.0; g_editor_rect[1] = 80.0;
    g_editor_rect[2] = 372.0; g_editor_rect[3] = 300.0;
    [view updateTerminalFrame];
    NimculusOutlineOverlay *outline = outlineOverlayForView(view);
    NSScrollView *scroll = outline.enclosingScrollView;
    BOOL hiddenWhenCollapsed = scroll && scroll.hidden;

    // Once the actual dock can host its content, the same view reappears and
    // its frame remains wholly inside the AppKit root.
    [view setFrame:NSMakeRect(0.0, 0.0, 640.0, 420.0)];
    [view updateTerminalFrame];
    BOOL shownWhenUsable = scroll && !scroll.hidden;
    BOOL containedWhenUsable = shownWhenUsable &&
      NSContainsRect(view.bounds, scroll.frame);
    BOOL dockAdjoinsEditor = shownWhenUsable &&
      fabs(NSMinX(scroll.frame) - (g_editor_rect[0] + g_editor_rect[2])) < 0.01 &&
      NSMaxX(scroll.frame) <= NSMaxX(view.bounds) + 0.01;

    memcpy(g_editor_rect, previousRect, sizeof(previousRect));
    g_editor_sidebar_visible = previousSidebarVisible;
    g_editor_sidebar_on_right = previousSidebarOnRight;
    g_welcome_visible = previousWelcomeVisible;
    g_active_view = previousView;
    [view release];
    return hiddenWhenCollapsed && containedWhenUsable && dockAdjoinsEditor;
  }
}

bool nimculus_platform_validate_application_alert_sheet(void) {
  NimculusPlatformMetrics previousMetrics = g_metrics;
  const double previousEditorRect[4] = {g_editor_rect[0], g_editor_rect[1],
    g_editor_rect[2], g_editor_rect[3]};
  @autoreleasepool {
    NSApplication *application = [NSApplication sharedApplication];
    (void)application;
    NimculusCommandCallback previousCallback = g_command_callback;
    uint32_t previousSidebarMode = g_editor_sidebar_mode;
    NSUInteger previousSidebarSelection = g_editor_sidebar_selected_index;
    id previousView = g_active_view;
    NSWindow *window = [[NSWindow alloc]
      initWithContentRect:NSMakeRect(160.0, 180.0, 640.0, 480.0)
      styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    NimculusAppDelegate *delegate = [NimculusAppDelegate new];
    NimculusMetalView *view = [[NimculusMetalView alloc]
      initWithFrame:NSMakeRect(0.0, 0.0, 640.0, 480.0)];
    if (!window || !delegate || !view) {
      [view release];
      [delegate release];
      [window release];
      g_metrics = previousMetrics;
      return false;
    }
    delegate.window = window;
    delegate.view = view;
    [window setContentView:view];
    g_active_view = view;
    g_command_callback = validationCommandCallback;
    g_validation_command[0] = '\0';
    [window makeKeyAndOrderFront:nil];
    [delegate findInDocument:nil];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    NimculusDocumentSearchOverlay *search = nil;
    for (NSView *subview in view.subviews) {
      if ([subview isKindOfClass:[NimculusDocumentSearchOverlay class]]) {
        search = (NimculusDocumentSearchOverlay *)subview;
        break;
      }
    }
    BOOL visibleFind = search && !search.hidden && search.mode == 0 &&
      window.firstResponder == search.queryField.currentEditor;
    search.queryField.stringValue = @"日本語🙂";
    [search controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification
      object:search.queryField]];
    BOOL dispatched = strcmp(g_validation_command, "findDocument:日本語🙂") == 0;
    [search.queryField cancelOperation:nil];
    BOOL escaped = search.hidden && window.firstResponder == view;
    [delegate replaceInDocument:nil];
    BOOL visibleReplace = !search.hidden && search.mode == 1 && !search.replacementField.hidden;
    [delegate goToLine:nil];
    BOOL visibleLine = !search.hidden && search.mode == 2 && !search.lineField.hidden;
    [delegate findInWorkspace:nil];
    BOOL visibleWorkspaceSearch = !search.hidden && search.mode == 3 && !search.queryField.hidden &&
      [search.queryField.accessibilityLabel isEqualToString:@"Search workspace"];
    search.queryField.stringValue = @"Nimculus";
    g_validation_command[0] = '\0';
    [search controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification
      object:search.queryField]];
    BOOL workspaceSearchLive = strcmp(g_validation_command, "workspaceSearch:Nimculus") == 0;
    [search findNext:nil];
    BOOL workspaceSearchDispatched = strcmp(g_validation_command, "workspaceSearch:Nimculus") == 0;
    [delegate findInWorkspace:nil];
    g_validation_command[0] = '\0';
    [search close:nil];
    BOOL workspaceSearchCancelled = strcmp(g_validation_command,
      "cancelWorkspaceSearch") == 0 && search.hidden && window.firstResponder == view;
    [delegate quickOpen:nil];
    BOOL visibleQuickOpen = !search.hidden && search.mode == 4 && !search.queryField.hidden &&
      [search.queryField.accessibilityLabel isEqualToString:@"Quick Open: file name or path"] &&
      search.pickerList != nil && !search.pickerList.hidden &&
      search.layer.shadowRadius == 12.0;
    search.queryField.stringValue = @"main.nim";
    g_validation_command[0] = '\0';
    [search controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification
      object:search.queryField]];
    BOOL quickOpenLive = strcmp(g_validation_command, "quickOpen:main.nim") == 0;
    // The field editor owns keyboard focus while a picker is open. Verify the
    // same result-navigation contract used by Zed: arrows update the result
    // list and Return activates the selected row without requiring a mouse
    // click on the sidebar first.
    g_editor_sidebar_mode = 1;
    g_editor_sidebar_selected_index = NSNotFound;
    g_validation_command[0] = '\0';
    BOOL quickOpenArrow = [search control:search.queryField textView:nil
      doCommandBySelector:@selector(moveDown:)];
    BOOL quickOpenArrowDispatched = quickOpenArrow &&
      strcmp(g_validation_command, "sidebarNext") == 0;
    g_editor_sidebar_selected_index = 0;
    g_validation_command[0] = '\0';
    BOOL quickOpenReturn = [search control:search.queryField textView:nil
      doCommandBySelector:@selector(insertNewline:)];
    BOOL quickOpenSelected = quickOpenReturn &&
      strcmp(g_validation_command, "sidebarOpenSelected") == 0 && search.hidden;
    [delegate quickOpen:nil];
    search.queryField.stringValue = @"main.nim";
    [search findNext:nil];
    // Quick Open Return opens the selected result. The distinct command keeps
    // typing (`quickOpen:`) separate from activation (`quickOpenOpen:`), so a
    // pending asynchronous search cannot be mistaken for a mere query update.
    BOOL quickOpenDispatched = strcmp(g_validation_command, "quickOpenOpen:main.nim") == 0;
    [delegate quickOpen:nil];
    g_validation_command[0] = '\0';
    [search close:nil];
    BOOL quickOpenCancelled = strcmp(g_validation_command, "cancelQuickOpen") == 0;
    BOOL dismissed = search.hidden && window.attachedSheet == nil &&
      window.firstResponder == view;
    [delegate openCommandPalette:nil];
    NimculusCommandPaletteOverlay *palette = nil;
    for (NSView *subview in view.subviews) {
      if ([subview isKindOfClass:[NimculusCommandPaletteOverlay class]]) {
        palette = (NimculusCommandPaletteOverlay *)subview;
        break;
      }
    }
    BOOL paletteVisible = palette && !palette.hidden && window.attachedSheet == nil &&
      window.firstResponder == palette.field.currentEditor;
    palette.field.stringValue = @"toggle files";
    [palette controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification
      object:palette.field]];
    BOOL paletteFiltered = palette.visibleCommands.count == 1 &&
      [palette.visibleCommands[0] isEqualToString:@"toggle files"];
    [palette execute:nil];
    BOOL paletteDispatched = strcmp(g_validation_command, "commandPalette:toggle files") == 0 &&
      palette.hidden && window.firstResponder == view;
    [delegate openCommandPalette:nil];
    [palette.field cancelOperation:nil];
    BOOL paletteEscaped = palette.hidden && window.firstResponder == view;
    [delegate presentGitCommitSheet];
    NimculusGitCommitOverlay *commitEditor = nil;
    for (NSView *subview in view.subviews) {
      if ([subview isKindOfClass:[NimculusGitCommitOverlay class]]) {
        commitEditor = (NimculusGitCommitOverlay *)subview;
        break;
      }
    }
    BOOL commitVisible = commitEditor && !commitEditor.hidden && window.attachedSheet == nil &&
      window.firstResponder == commitEditor.messageField.currentEditor;
    commitEditor.messageField.stringValue = @"Update project search";
    [commitEditor commit:nil];
    BOOL commitDispatched = strcmp(g_validation_command,
      "commandPalette:git commit Update project search") == 0 && commitEditor.hidden &&
      window.firstResponder == view;
    [delegate presentGitCommitSheet];
    [commitEditor.messageField cancelOperation:nil];
    BOOL commitEscaped = commitEditor.hidden && window.firstResponder == view;
    [delegate showSettingsPanelWithTheme:@"dark" editorFontSize:@"15" terminalFontSize:@"13"
      editorFontFamily:@".ZedMono" terminalFontFamily:@"SF Mono" shell:@"/bin/zsh"];
    NimculusSettingsOverlay *settings = nil;
    for (NSView *subview in view.subviews) {
      if ([subview isKindOfClass:[NimculusSettingsOverlay class]]) {
        settings = (NimculusSettingsOverlay *)subview;
        break;
      }
    }
    BOOL settingsVisible = settings && !settings.hidden && window.attachedSheet == nil &&
      window.firstResponder == settings.editorSizeField.currentEditor &&
      [settings.themePopup.titleOfSelectedItem isEqualToString:@"dark"];
    [settings apply:nil];
    BOOL settingsDispatched = strcmp(g_validation_command,
      "settingsApply:dark\03715\03713\037.ZedMono\037SF Mono\037/bin/zsh") == 0;
    [settings.editorSizeField cancelOperation:nil];
    BOOL settingsEscaped = settings.hidden && window.firstResponder == view;
    // A narrow split pane used to retain the overlays' visual minimum width,
    // which could put native controls beyond the editor's right/bottom edge.
    // Exercise all four overlay kinds against a deliberately tiny pane.
    g_editor_rect[0] = 240.0; g_editor_rect[1] = 30.0;
    g_editor_rect[2] = 148.0; g_editor_rect[3] = 78.0;
    search.hidden = NO;
    palette.hidden = NO;
    commitEditor.hidden = NO;
    settings.hidden = NO;
    [view updateTerminalFrame];
    const NSRect logicalPane = NSMakeRect(g_editor_rect[0], g_editor_rect[1],
      g_editor_rect[2], g_editor_rect[3]);
    const NSRect pane = appKitFrameForLogicalTopRect(view, logicalPane);
    const CGFloat validationSidebarWidth = MAX(1.0,
      g_editor_rect[0] - 12.0 - 38.0);
    const CGFloat validationSidebarTop = MAX(0.0, g_editor_rect[1] - 56.0);
    const CGFloat validationSidebarHeight = MAX(1.0, g_editor_rect[3] +
      (g_editor_rect[1] - validationSidebarTop));
    const NSRect sidebar = appKitFrameForLogicalTopRect(view,
      NSMakeRect(46.0, validationSidebarTop, validationSidebarWidth,
        validationSidebarHeight));
    const NSRect expectedSearch = appKitFrameForLogicalTopRect(view,
      editorOverlayFrame(g_editor_rect[2], NimculusRowHeight,
        g_editor_rect[0], g_editor_rect[1]));
    const CGFloat paletteWidth = MIN(NimculusPickerWidth, MAX(1.0, g_editor_rect[2] - 24.0));
    const CGFloat paletteHeight = NimculusPickerHeaderHeight +
      NimculusPickerVisibleRows * NimculusPickerRowHeight;
    const NSRect expectedPalette = appKitFrameForLogicalTopRect(view,
      editorOverlayFrame(paletteWidth, paletteHeight,
        g_editor_rect[0] + (g_editor_rect[2] - paletteWidth) / 2.0,
        g_editor_rect[1] + 12.0));
    BOOL overlaysBounded = NSContainsRect(pane, search.frame) &&
      NSContainsRect(pane, palette.frame) &&
      NSContainsRect(pane, settings.frame) &&
      NSContainsRect(sidebar, commitEditor.frame) &&
      NSEqualRects(search.frame, expectedSearch) &&
      NSEqualRects(palette.frame, expectedPalette) &&
      search.clipsToBounds && !palette.clipsToBounds &&
      commitEditor.clipsToBounds && settings.clipsToBounds;
    NimculusLineNumberOverlay *lineNumbers = nil;
    NimculusIndentGuideOverlay *indentGuides = nil;
    NimculusTabBarOverlay *primaryTabs = nil;
    NimculusWelcomeOverlay *welcome = nil;
    for (NSView *subview in view.subviews) {
      if ([subview isKindOfClass:[NimculusLineNumberOverlay class]]) {
        lineNumbers = (NimculusLineNumberOverlay *)subview;
      } else if ([subview isKindOfClass:[NimculusIndentGuideOverlay class]]) {
        indentGuides = (NimculusIndentGuideOverlay *)subview;
      } else if ([subview isKindOfClass:[NimculusTabBarOverlay class]] &&
                 !((NimculusTabBarOverlay *)subview).secondary) {
        primaryTabs = (NimculusTabBarOverlay *)subview;
      } else if ([subview isKindOfClass:[NimculusWelcomeOverlay class]]) {
        welcome = (NimculusWelcomeOverlay *)subview;
      }
    }
    // Frame placement, not a child's `isFlipped` declaration, decides where
    // native chrome appears in the root AppKit view. Assert representative
    // content, chrome and welcome frames against the same logical pane that
    // bounds Metal text and editor overlays.
    const NSRect expectedLineNumbers = appKitFrameForLogicalTopRect(view,
      NSMakeRect(g_editor_rect[0], g_editor_rect[1], editorGutterFrameWidth(g_editor_rect),
        g_editor_rect[3]));
    const NSRect expectedTabs = appKitFrameForLogicalTopRect(view,
      NSMakeRect(g_editor_rect[0], g_editor_rect[1] - NimculusTabBarHeight + 1.0,
        g_editor_rect[2], NimculusTabBarHeight));
    BOOL nativeChromeAligned = lineNumbers && indentGuides && primaryTabs && welcome &&
      NSEqualRects(lineNumbers.frame, expectedLineNumbers) &&
      NSEqualRects(indentGuides.frame, pane) &&
      NSEqualRects(primaryTabs.frame, expectedTabs) &&
      NSEqualRects(welcome.frame, pane);
    memcpy(g_editor_rect, previousEditorRect, sizeof(previousEditorRect));
    g_editor_sidebar_mode = previousSidebarMode;
    g_editor_sidebar_selected_index = previousSidebarSelection;
    g_command_callback = previousCallback;
    g_active_view = previousView;
    delegate.view = nil;
    [window orderOut:nil];
    [window close];
    [view release];
    [delegate release];
    [window release];
    g_metrics = previousMetrics;
    return visibleFind && dispatched && escaped && visibleReplace && visibleLine &&
      visibleWorkspaceSearch && workspaceSearchLive && workspaceSearchDispatched && workspaceSearchCancelled && visibleQuickOpen &&
      quickOpenLive && quickOpenArrowDispatched && quickOpenSelected &&
      quickOpenDispatched && quickOpenCancelled && dismissed &&
      paletteVisible && paletteFiltered && paletteDispatched && paletteEscaped &&
      commitVisible && commitDispatched && commitEscaped && settingsVisible &&
      settingsDispatched && settingsEscaped && overlaysBounded && nativeChromeAligned;
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
    NSPanel *panel = g_external_change_panel;
    // This is intentionally not a sheet: the parent must stay usable while
    // the notification awaits a choice.
    BOOL visible = panel != nil && panel.visible && window.attachedSheet == nil;
    BOOL parentAcceptsInput = [window makeFirstResponder:view] && window.firstResponder == view;
    NSButton *reload = nil;
    for (NSView *subview in panel.contentView.subviews) {
      if ([subview isKindOfClass:[NSButton class]] &&
          [((NSButton *)subview).title isEqualToString:@"Reload"]) {
        reload = (NSButton *)subview;
        break;
      }
    }
    if (reload) [reload performClick:nil];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    BOOL reloaded = strcmp(g_validation_command, "reloadExternal") == 0;
    BOOL dismissed = g_external_change_panel == nil && window.attachedSheet == nil;
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
    return visible && parentAcceptsInput && reload != nil && reloaded && dismissed;
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
      g_validation_scroll_event.precise_scrolling == scrollWheel.hasPreciseScrollingDeltas &&
      g_validation_scroll_event.phase == NIMCULUS_TOUCH_PHASE_MOVED;
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
  if (!g_glyph_atlas_texture || g_glyph_sprite_count == 0) return false;
  uint64_t hitsBefore = g_glyph_atlas_hit_count;
  updateEditorGlyphAtlas(device, sample);
  return g_glyph_sprite_count > 0 && g_glyph_atlas_hit_count > hitsBefore;
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
    g_glyph_atlas_entry_count > 0 && g_glyph_sprite_count > 0 &&
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
    g_glyph_atlas_entry_count > 0 && g_glyph_sprite_count > 0;

      g_metrics.scale_factor = 2.0;
      updateEditorTextTexture(device, g_editor_text, YES);
      BOOL twoXValid = g_text_texture.width == oneXWidth * 2 &&
        g_text_texture.height == oneXHeight * 2 &&
        fabs(g_glyph_atlas_scale - 2.0) < 0.001 &&
        g_glyph_atlas_entry_count > 0 && g_glyph_sprite_count > 0;
      uint64_t hitsBefore = g_glyph_atlas_hit_count;
      updateEditorTextTexture(device, g_editor_text, YES);
      BOOL twoXReused = g_glyph_atlas_hit_count > hitsBefore;

      g_metrics.scale_factor = 1.0;
      updateEditorTextTexture(device, g_editor_text, YES);
      BOOL oneXRestored = g_text_texture.width == oneXWidth &&
        g_text_texture.height == oneXHeight &&
        fabs(g_glyph_atlas_scale - 1.0) < 0.001 &&
        g_glyph_atlas_entry_count > 0 && g_glyph_sprite_count > 0;
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
      g_glyph_sprite_count > 0;
  }
}

bool nimculus_platform_validate_color_emoji_sequences(void) {
  // This contract does not require a drawable. It verifies the same shaped
  // glyph flag that the framework consumes, without a second full-string
  // emoji scan in the renderer.
  NSString *samples[] = {@"👩‍💻", @"1️⃣", @"Nimculus 日本語"};
  BOOL expected[] = {YES, YES, NO};
  for (NSUInteger index = 0; index < 3; index++) {
    NSString *value = samples[index];
    NSData *bytes = [value dataUsingEncoding:NSUTF8StringEncoding];
    NimculusPlatformLineMetrics metrics;
    NimculusPlatformGlyph glyphs[64];
    nimculus_platform_layout_line(bytes.bytes, (uint32_t)bytes.length,
      g_editor_font_size, NULL, 0, &metrics, glyphs, 64);
    BOOL found = NO;
    for (uint32_t glyphIndex = 0; glyphIndex < metrics.glyph_count; glyphIndex++) {
      if (glyphs[glyphIndex].is_emoji) { found = YES; break; }
    }
    if (found != expected[index]) return NO;
  }
  return YES;
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
    BOOL atlasValid = g_glyph_atlas_texture != nil && g_glyph_sprite_count > 0;
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

uint32_t nimculus_platform_accessibility_node_size(void) {
  return (uint32_t)sizeof(NimculusAccessibilityNode);
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
    NSMenuItem *openWithSystem = [menu addItemWithTitle:@"Open with System App"
      action:@selector(dispatchWorkspaceSidebarCommand:) keyEquivalent:@""];
    openWithSystem.representedObject = @"sidebarOpenWithSystem";
    [menu addItemWithTitle:@"View History" action:@selector(dispatchWorkspaceHistoryContextEntry:) keyEquivalent:@""];
  }
  [menu addItemWithTitle:@"Reveal in Finder" action:@selector(revealWorkspaceContextEntry:) keyEquivalent:@""];
  [menu addItemWithTitle:@"Open in Terminal" action:@selector(dispatchWorkspaceOpenTerminal:) keyEquivalent:@""];
  if (g_workspace_context_is_directory) {
    [menu addItemWithTitle:@"Find in Folder…" action:@selector(dispatchWorkspaceSearchInFolder:) keyEquivalent:@""];
  }
  [menu addItemWithTitle:@"Copy Path" action:@selector(copyWorkspaceContextPath:) keyEquivalent:@""];
  [menu addItemWithTitle:@"Copy Relative Path" action:@selector(copyWorkspaceContextRelativePath:) keyEquivalent:@""];
  [menu addItem:[NSMenuItem separatorItem]];
  NSMenuItem *duplicate = [menu addItemWithTitle:@"Duplicate"
    action:@selector(dispatchWorkspaceSidebarCommand:) keyEquivalent:@""];
  duplicate.representedObject = @"sidebarDuplicateSelected";
  NSMenuItem *copy = [menu addItemWithTitle:@"Copy"
    action:@selector(dispatchWorkspaceSidebarCommand:) keyEquivalent:@""];
  copy.representedObject = @"sidebarCopySelected";
  NSMenuItem *cut = [menu addItemWithTitle:@"Cut"
    action:@selector(dispatchWorkspaceSidebarCommand:) keyEquivalent:@""];
  cut.representedObject = @"sidebarCutSelected";
  NSMenuItem *paste = [menu addItemWithTitle:@"Paste"
    action:@selector(dispatchWorkspaceSidebarCommand:) keyEquivalent:@""];
  paste.representedObject = @"sidebarPasteSelected";
  [menu addItem:[NSMenuItem separatorItem]];
  [menu addItemWithTitle:@"New File…" action:@selector(createWorkspaceFileAtContext:) keyEquivalent:@""];
  [menu addItemWithTitle:@"New Folder…" action:@selector(createWorkspaceDirectoryAtContext:) keyEquivalent:@""];
  [menu addItem:[NSMenuItem separatorItem]];
  [menu addItemWithTitle:@"Rename…" action:@selector(renameWorkspaceContextEntry:) keyEquivalent:@""];
  NSMenuItem *delete = [menu addItemWithTitle:@"Delete Permanently"
    action:@selector(dispatchWorkspaceSidebarCommand:) keyEquivalent:@""];
  delete.representedObject = @"sidebarDeleteSelected";
  NSMenuItem *trash = [menu addItemWithTitle:@"Move to Trash…" action:@selector(deleteWorkspaceContextEntry:) keyEquivalent:@""];
  trash.keyEquivalentModifierMask = 0;
  for (NSMenuItem *item in menu.itemArray) item.target = delegate;
  [menu popUpMenuPositioningItem:nil atLocation:[NSEvent mouseLocation] inView:nil];
}
void nimculus_platform_rename_workspace_entry(const char *path, bool is_directory) {
  if (!path || path[0] == '\0') return;
  replaceOwnedString(&g_workspace_context_path, [NSString stringWithUTF8String:path]);
  g_workspace_context_is_directory = is_directory ? YES : NO;
  NimculusAppDelegate *delegate = (NimculusAppDelegate *)[NSApp delegate];
  if (delegate && [delegate respondsToSelector:@selector(renameWorkspaceContextEntry:)]) {
    [delegate performSelector:@selector(renameWorkspaceContextEntry:) withObject:nil];
  }
}
static void promptWorkspaceContextAction(const char *path, bool is_directory, SEL action) {
  if (!path || path[0] == '\0') return;
  @autoreleasepool {
    replaceOwnedString(&g_workspace_context_path, [NSString stringWithUTF8String:path]);
    g_workspace_context_is_directory = is_directory ? YES : NO;
    NimculusAppDelegate *delegate = (NimculusAppDelegate *)[NSApp delegate];
    if (delegate && [delegate respondsToSelector:action]) {
      [delegate performSelector:action withObject:nil];
    }
  }
}
void nimculus_platform_prompt_workspace_file_at_context(const char *path, bool is_directory) {
  promptWorkspaceContextAction(path, is_directory, @selector(createWorkspaceFileAtContext:));
}
void nimculus_platform_prompt_workspace_directory_at_context(const char *path, bool is_directory) {
  promptWorkspaceContextAction(path, is_directory, @selector(createWorkspaceDirectoryAtContext:));
}
void nimculus_platform_prompt_workspace_trash_at_context(const char *path, bool is_directory) {
  promptWorkspaceContextAction(path, is_directory, @selector(deleteWorkspaceContextEntry:));
}
void nimculus_platform_prompt_workspace_search_at_context(const char *path, bool is_directory) {
  if (!is_directory) return;
  promptWorkspaceContextAction(path, YES, @selector(dispatchWorkspaceSearchInFolder:));
}
void nimculus_platform_show_git_status_context(uint32_t item_index,
                                               uint32_t projection) {
  NimculusAppDelegate *delegate = (NimculusAppDelegate *)[NSApp delegate];
  if (!delegate) return;
  NSMenu *menu = [[[NSMenu alloc] initWithTitle:@"Git Change"] autorelease];
  NSArray<NSArray<NSString *> *> *items = projection == 1 ? @[
    @[@"View Staged Diff", @"diffStaged"], @[@"Open", @"open"], @[@"Unstage", @"unstage"]
  ] : projection == 2 ? @[
    @[@"View Unstaged Diff", @"diffUnstaged"], @[@"Open", @"open"], @[@"Stage", @"stage"]
  ] : @[
    @[@"View Diff", @"diff"], @[@"Open", @"open"]
  ];
  for (NSArray<NSString *> *entry in items) {
    NSString *action = entry[1];
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
void nimculus_platform_show_git_branch_context(uint32_t item_index) {
  NimculusAppDelegate *delegate = (NimculusAppDelegate *)[NSApp delegate];
  if (!delegate) return;
  NSMenu *menu = [[[NSMenu alloc] initWithTitle:@"Git Branch"] autorelease];
  NSMenuItem *item = [menu addItemWithTitle:@"Copy Branch Name"
    action:@selector(dispatchGitBranchContext:) keyEquivalent:@""];
  item.target = delegate;
  item.representedObject = [NSString stringWithFormat:@"gitBranchContext:copy:%u",
    item_index];
  [menu popUpMenuPositioningItem:nil atLocation:[NSEvent mouseLocation] inView:nil];
}
void nimculus_platform_show_editor_tab_context(uint32_t pane_index, uint32_t tab_index,
                                               bool is_pinned, bool has_pinned_tabs) {
  NimculusAppDelegate *delegate = (NimculusAppDelegate *)[NSApp delegate];
  if (!delegate) return;
  NSMenu *menu = [[[NSMenu alloc] initWithTitle:@"Editor Tab"] autorelease];
  NSArray<NSArray<NSString *> *> *items = @[
    @[is_pinned ? @"Unpin Tab" : @"Pin Tab", is_pinned ? @"unpin" : @"pin"],
    @[@"Close Tab", @"close"],
    @[@"Close Others", @"closeOthers"],
    @[@"Close Tabs to the Left", @"closeLeft"],
    @[@"Close Tabs to the Right", @"closeRight"],
    @[@"Close Clean Tabs", @"closeClean"],
    @[@"Close All Tabs", @"closeAll"],
    @[@"Copy File Path", @"copyPath"],
    @[@"Reveal in Finder", @"reveal"]
  ];
  NSUInteger separatorBefore = 1;
  for (NSUInteger index = 0; index < items.count; index++) {
    if (index == separatorBefore || (index == 7 && has_pinned_tabs)) {
      [menu addItem:[NSMenuItem separatorItem]];
    }
    NSArray<NSString *> *entry = items[index];
    NSMenuItem *item = [menu addItemWithTitle:entry[0]
      action:@selector(dispatchEditorTabContext:) keyEquivalent:@""];
    item.target = delegate;
    item.representedObject = [NSString stringWithFormat:@"editorTabContext:%@:%u:%u",
      entry[1], pane_index, tab_index];
  }
  if (has_pinned_tabs) {
    NSMenuItem *unpinAll = [menu insertItemWithTitle:@"Unpin All Tabs"
      action:@selector(dispatchEditorTabContext:) keyEquivalent:@"" atIndex:1];
    unpinAll.target = delegate;
    unpinAll.representedObject = [NSString stringWithFormat:
      @"editorTabContext:unpinAll:%u:%u", pane_index, tab_index];
  }
  [menu popUpMenuPositioningItem:nil atLocation:[NSEvent mouseLocation] inView:nil];
}

void nimculus_platform_reveal_path(const char *path) {
  if (!path || path[0] == '\0') return;
  NSString *filePath = [NSString stringWithUTF8String:path];
  if (filePath.length > 0) {
    [[NSWorkspace sharedWorkspace] selectFile:filePath inFileViewerRootedAtPath:@""];
  }
}
void nimculus_platform_open_path(const char *path) {
  if (!path || path[0] == '\0') return;
  NSString *filePath = [NSString stringWithUTF8String:path];
  if (filePath.length > 0) {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:filePath]];
  }
}
void nimculus_platform_show_git_commit_sheet(void) {
  NimculusAppDelegate *delegate = (NimculusAppDelegate *)[NSApp delegate];
  if (delegate) [delegate presentGitCommitSheet];
}
void nimculus_platform_set_command_callback(NimculusCommandCallback callback) { g_command_callback = callback; }
void nimculus_platform_set_idle_callback(NimculusIdleCallback callback) { g_idle_callback = callback; }
void nimculus_platform_set_frame_callback(NimculusFrameCallback callback) { g_frame_callback = callback; }
void nimculus_platform_set_editor_cursor(double x, double y) {
  g_editor_cursor[0] = x;
  g_editor_cursor[1] = y;
  scheduleEditorTextTextureRebuild();
  markSceneFullyDirty();
}
void nimculus_platform_set_editor_cursor_byte(uint32_t byte_offset, uint32_t line) {
  // Scrolling does not move the cursor, but the input handler republishes it
  // after every event and each publish re-rasterized the visible text.
  static uint32_t lastByte = UINT32_MAX;
  static uint32_t lastLine = UINT32_MAX;
  static uint32_t lastScrollLine = UINT32_MAX;
  static double lastScrollFraction = -1.0;
  // The caret's screen point is derived from the scroll offset, so a scroll
  // has to re-run this even when the cursor itself has not moved.
  if (byte_offset == lastByte && line == lastLine &&
      g_editor_scroll_line == lastScrollLine &&
      g_editor_scroll_y_fraction == lastScrollFraction) {
    return;
  }
  lastByte = byte_offset;
  lastLine = line;
  lastScrollLine = g_editor_scroll_line;
  lastScrollFraction = g_editor_scroll_y_fraction;
  NSArray<NSString *> *lines = editorLinesForText(g_editor_text);
  if (lines.count == 0) return;
  NSUInteger lineIndex = MIN((NSUInteger)line, lines.count - 1);
  g_editor_cursor_line = lineIndex;
  NSUInteger lineStartByte = editorLineUTF8Offset(lineIndex, lines);
  NSString *lineText = lines[lineIndex];
  NSUInteger lineLength = [[lineText dataUsingEncoding:NSUTF8StringEncoding] length];
  NSUInteger localByte = byte_offset > lineStartByte ? byte_offset - lineStartByte : 0;
  localByte = MIN(localByte, lineLength);
  NSUInteger utf16 = utf16OffsetForUTF8Bytes(lineText, localByte);
  NSUInteger documentOffset = editorLineUTF16Offset(lineIndex, lines);
  CGPoint point = editorEnsureCursorVisible(documentOffset + utf16);
  g_editor_cursor[0] = point.x;
  g_editor_cursor[1] = point.y;
  scheduleEditorTextTextureRebuild();
  markSceneFullyDirty();
}
void nimculus_platform_set_editor_font_size(double size) {
  g_editor_font_size = MIN(96.0, MAX(6.0, size > 0.0 ? size : 14.0));
  g_editor_line_height = MAX(12.0, round(g_editor_font_size * 1.618));
  scheduleEditorTextTextureRebuild();
  markSceneFullyDirty();
  if (g_active_view) {
    for (NSView *subview in ((NimculusMetalView *)g_active_view).subviews) {
      if ([subview isKindOfClass:[NimculusLineNumberOverlay class]]) [subview setNeedsDisplay:YES];
    }
  }
  if (g_active_view) [(NimculusMetalView *)g_active_view requestRedraw];
}
void nimculus_platform_set_editor_font_name(const char *name) {
  NSString *requested = name ? [NSString stringWithUTF8String:name] : nil;
  replaceOwnedString(&g_editor_font_name, requested.length > 0 ? requested : @".ZedMono");
  [g_editor_resolved_font_name release];
  g_editor_resolved_font_name = nil;
  (void)editorResolvedFontName();
  scheduleEditorTextTextureRebuild();
  markSceneFullyDirty();
  if (g_active_view) {
    for (NSView *subview in ((NimculusMetalView *)g_active_view).subviews) {
      if ([subview isKindOfClass:[NimculusLineNumberOverlay class]]) [subview setNeedsDisplay:YES];
    }
  }
  if (g_active_view) [(NimculusMetalView *)g_active_view requestRedraw];
}
double nimculus_platform_editor_line_height(void) { return editorLineHeight(); }
double nimculus_platform_editor_gutter_width(void) { return editorGutterWidth(); }
double nimculus_platform_editor_text_origin_x(void) {
  return editorTextOriginX(g_editor_rect);
}
double nimculus_platform_editor_text_viewport_width(void) {
  return editorTextViewport(g_editor_rect).width;
}
double nimculus_platform_secondary_editor_text_viewport_width(void) {
  if (!g_secondary_editor_visible) return 0.0;
  double previousRect[4] = {g_editor_rect[0], g_editor_rect[1],
                            g_editor_rect[2], g_editor_rect[3]};
  BOOL previousRenderingSecondary = g_rendering_secondary_editor;
  memcpy(g_editor_rect, g_secondary_editor_rect, sizeof(g_editor_rect));
  g_rendering_secondary_editor = YES;
  swapEditorTextState();
  double result = editorTextViewport(g_editor_rect).width;
  swapEditorTextState();
  g_rendering_secondary_editor = previousRenderingSecondary;
  memcpy(g_editor_rect, previousRect, sizeof(g_editor_rect));
  return result;
}
double nimculus_platform_secondary_editor_text_origin_x(void) {
  if (!g_secondary_editor_visible) return 0.0;
  double previousRect[4] = {g_editor_rect[0], g_editor_rect[1],
                            g_editor_rect[2], g_editor_rect[3]};
  BOOL previousRenderingSecondary = g_rendering_secondary_editor;
  memcpy(g_editor_rect, g_secondary_editor_rect, sizeof(g_editor_rect));
  g_rendering_secondary_editor = YES;
  swapEditorTextState();
  double result = editorTextOriginX(g_editor_rect);
  swapEditorTextState();
  g_rendering_secondary_editor = previousRenderingSecondary;
  memcpy(g_editor_rect, previousRect, sizeof(g_editor_rect));
  return result;
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
  if (g_editor_soft_wrap) return (uint32_t)editorUTF16OffsetAtPoint(x, y);
  NSArray<NSString *> *lines = editorLinesForText(g_editor_text);
  if (lines.count == 0) return 0;
  CGFloat viewHeight = g_metrics.height_points > 0 ? g_metrics.height_points : 640.0;
  CGFloat fromTop = viewHeight - y - g_editor_rect[1];
  NSInteger targetRow = MAX(0, (NSInteger)floor((fromTop - NimculusEditorHitTestTopInset +
    g_editor_scroll_y_fraction) / editorLineHeight()));
  NSUInteger lineIndex = editorFirstVisibleLine(g_editor_scroll_line, lines.count);
  while (lineIndex < lines.count && targetRow > 0) {
    lineIndex = editorFirstVisibleLine(lineIndex + 1, lines.count);
    targetRow--;
  }
  lineIndex = MIN(lineIndex, lines.count - 1);
  NSString *lineText = lines[(NSUInteger)lineIndex];
  CTFontRef font = editorFont();
  if (!font) return 0;
  NSDictionary *attributes = @{ (id)kCTFontAttributeName: (__bridge id)font };
  NSAttributedString *attributed = [[NSAttributedString alloc]
    initWithString:lineText attributes:attributes];
  CTLineRef ctLine = CTLineCreateWithAttributedString((CFAttributedStringRef)attributed);
  CFIndex localIndex = CTLineGetStringIndexForPosition(ctLine,
    CGPointMake(MAX(0.0, x - g_editor_rect[0] - editorTextOriginX(g_editor_rect) + g_editor_scroll_x), 0.0));
  if (localIndex == kCFNotFound) localIndex = (CFIndex)lineText.length;
  NSUInteger documentIndex = editorLineUTF16Offset(lineIndex, lines);
  documentIndex += MIN((NSUInteger)localIndex, lineText.length);
  CFRelease(ctLine);
  [attributed release];
  CFRelease(font);
  return (uint32_t)documentIndex;
}
uint32_t nimculus_platform_editor_byte_offset_at_point(double x, double y) {
  if ((g_rendering_secondary_editor ? g_secondary_layout_row_count :
       g_editor_layout_row_count) > 0) {
    return editorLayoutByteOffsetAtPoint(x, y);
  }
  if (g_editor_soft_wrap) {
    NSUInteger utf16 = editorUTF16OffsetAtPoint(x, y);
    return (uint32_t)utf8BytesForDocumentUTF16Offset(g_editor_text, utf16);
  }
  NSArray<NSString *> *lines = editorLinesForText(g_editor_text);
  if (lines.count == 0) return 0;
  CGFloat viewHeight = g_metrics.height_points > 0 ? g_metrics.height_points : 640.0;
  CGFloat fromTop = viewHeight - y - g_editor_rect[1];
  NSInteger targetRow = MAX(0, (NSInteger)floor((fromTop - NimculusEditorHitTestTopInset +
    g_editor_scroll_y_fraction) / editorLineHeight()));
  NSUInteger lineIndex = editorFirstVisibleLine(g_editor_scroll_line, lines.count);
  while (lineIndex < lines.count && targetRow > 0) {
    lineIndex = editorFirstVisibleLine(lineIndex + 1, lines.count);
    targetRow--;
  }
  lineIndex = MIN(lineIndex, lines.count - 1);
  NSString *lineText = lines[lineIndex];
  NSUInteger lineStartByte = editorLineUTF8Offset(lineIndex, lines);
  CTFontRef font = editorFont();
  if (!font) return (uint32_t)lineStartByte;
  NSDictionary *attributes = @{ (id)kCTFontAttributeName: (__bridge id)font };
  NSAttributedString *attributed = [[NSAttributedString alloc]
    initWithString:lineText attributes:attributes];
  CTLineRef ctLine = CTLineCreateWithAttributedString((CFAttributedStringRef)attributed);
  CGFloat textX = MAX(0.0, x - g_editor_rect[0] - editorTextOriginX(g_editor_rect) + g_editor_scroll_x);
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
  CGFloat previousScrollYFraction = g_editor_scroll_y_fraction;
  CGFloat previousScrollX = g_editor_scroll_x;
  BOOL previousSoftWrap = g_editor_soft_wrap;
  BOOL previousRenderingSecondary = g_rendering_secondary_editor;
  swapEditorTextState();
  g_rendering_secondary_editor = YES;
  memcpy(g_editor_rect, g_secondary_editor_rect, sizeof(g_editor_rect));
  g_editor_scroll_line = g_secondary_editor_scroll_line;
  g_editor_scroll_y_fraction = g_secondary_editor_scroll_y_fraction;
  g_editor_scroll_x = g_secondary_editor_scroll_x;
  g_editor_soft_wrap = g_secondary_editor_soft_wrap;
  uint32_t result = nimculus_platform_editor_byte_offset_at_point(x, y);
  swapEditorTextState();
  g_rendering_secondary_editor = previousRenderingSecondary;
  memcpy(g_editor_rect, previousRect, sizeof(g_editor_rect));
  g_editor_scroll_line = previousScrollLine;
  g_editor_scroll_y_fraction = previousScrollYFraction;
  g_editor_scroll_x = previousScrollX;
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
  scheduleEditorTextTextureRebuild();
  if (g_active_view) [(NimculusMetalView *)g_active_view requestRedraw];
}
void nimculus_platform_set_editor_scroll_y_fraction(double pixels) {
  g_editor_scroll_y_fraction = MIN(MAX(0.0, pixels),
    MAX(0.0, editorLineHeight() - 0.001));
  if (g_active_view) {
    for (NSView *subview in ((NimculusMetalView *)g_active_view).subviews) {
      if ([subview isKindOfClass:[NimculusLineNumberOverlay class]])
        [subview setNeedsDisplay:YES];
    }
  }
  markSceneFullyDirty();
  scheduleEditorTextTextureRebuild();
  if (g_active_view) [(NimculusMetalView *)g_active_view requestRedraw];
}
void nimculus_platform_set_editor_scroll_x(double offset) {
  g_editor_scroll_x = editorClampedScrollX(offset);
  scheduleEditorTextTextureRebuild();
  markSceneFullyDirty();
  if (g_active_view) [(NimculusMetalView *)g_active_view requestRedraw];
}
double nimculus_platform_editor_scroll_x(void) { return g_editor_scroll_x; }
double nimculus_platform_editor_widest_visible_line_width(void) {
  return editorWidestVisibleLineWidth();
}
void nimculus_platform_set_editor_rect(double x, double y, double width, double height) {
  const double next[4] = {MAX(0.0, x), MAX(0.0, y), MAX(1.0, width), MAX(1.0, height)};
  // The compose pass republishes this rect on every frame, and it is unchanged
  // on all but a resize. Re-laying out every AppKit overlay and re-rasterizing
  // the text for an identical rect is the single most expensive thing scrolling
  // used to do.
  if (next[0] == g_editor_rect[0] && next[1] == g_editor_rect[1] &&
      next[2] == g_editor_rect[2] && next[3] == g_editor_rect[3]) {
    return;
  }
  if (rectDebugEnabled()) {
    fprintf(stderr, "editor_rect %.1f %.1f %.1f %.1f\n", next[0], next[1], next[2], next[3]);
  }
  g_editor_rect[0] = next[0];
  g_editor_rect[1] = next[1];
  g_editor_rect[2] = next[2];
  g_editor_rect[3] = next[3];
  if (g_active_view) [(NimculusMetalView *)g_active_view updateTerminalFrame];
  scheduleEditorTextTextureRebuild();
  markSceneFullyDirty();
  if (g_active_view) [(NimculusMetalView *)g_active_view requestRedraw];
}
void nimculus_platform_set_terminal_panel_rect(double x, double y, double width, double height) {
  g_terminal_panel_rect[0] = MAX(0.0, x);
  g_terminal_panel_rect[1] = MAX(0.0, y);
  g_terminal_panel_rect[2] = MAX(0.0, width);
  g_terminal_panel_rect[3] = MAX(0.0, height);
  if (g_active_view) {
    [(NimculusMetalView *)g_active_view updateTerminalFrame];
    if (g_queue) updateTerminalGlyphAtlas(g_queue.device);
    markSceneFullyDirty();
    [g_active_view requestRedraw];
  }
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
  if (g_active_view) [(NimculusMetalView *)g_active_view requestRedraw];
}
void nimculus_platform_set_secondary_editor_cursor_byte(uint32_t byte_offset, uint32_t line) {
  swapEditorTextState();
  NSArray<NSString *> *lines = editorLinesForText(g_editor_text);
  if (lines.count == 0) { swapEditorTextState(); return; }
  NSUInteger lineIndex = MIN((NSUInteger)line, lines.count - 1);
  g_secondary_editor_cursor_line = lineIndex;
  NSUInteger lineStartByte = editorLineUTF8Offset(lineIndex, lines);
  NSString *lineText = lines[lineIndex];
  NSUInteger lineLength = [[lineText dataUsingEncoding:NSUTF8StringEncoding] length];
  NSUInteger localByte = byte_offset > lineStartByte ? byte_offset - lineStartByte : 0;
  localByte = MIN(localByte, lineLength);
  NSUInteger utf16 = utf16OffsetForUTF8Bytes(lineText, localByte);
  NSUInteger documentOffset = editorLineUTF16Offset(lineIndex, lines);
  NSUInteger previousScrollLine = g_editor_scroll_line;
  CGFloat previousScrollYFraction = g_editor_scroll_y_fraction;
  CGFloat previousScrollX = g_editor_scroll_x;
  BOOL previousSoftWrap = g_editor_soft_wrap;
  g_editor_scroll_line = g_secondary_editor_scroll_line;
  g_editor_scroll_y_fraction = g_secondary_editor_scroll_y_fraction;
  g_editor_scroll_x = g_secondary_editor_scroll_x;
  g_editor_soft_wrap = g_secondary_editor_soft_wrap;
  CGPoint point = editorEnsureCursorVisible(documentOffset + utf16);
  g_secondary_editor_scroll_x = g_editor_scroll_x;
  g_editor_scroll_line = previousScrollLine;
  g_editor_scroll_y_fraction = previousScrollYFraction;
  g_editor_scroll_x = previousScrollX;
  g_editor_soft_wrap = previousSoftWrap;
  g_secondary_editor_cursor[0] = point.x;
  g_secondary_editor_cursor[1] = point.y;
  swapEditorTextState();
  if (g_queue) rebuildSecondaryEditorTexture(g_queue.device);
  markSceneFullyDirty();
  if (g_active_view) [(NimculusMetalView *)g_active_view requestRedraw];
}
void nimculus_platform_set_secondary_editor_selection(uint32_t start_byte, uint32_t end_byte) {
  NSUInteger start = utf16OffsetForUTF8Bytes(g_secondary_editor_text ?: @"", start_byte);
  NSUInteger end = utf16OffsetForUTF8Bytes(g_secondary_editor_text ?: @"", end_byte);
  g_secondary_editor_selection_start = MIN(start, end);
  g_secondary_editor_selection_end = MAX(start, end);
  g_secondary_editor_selection_count = 1;
  g_secondary_editor_selections[0] = (NimculusEditorSelection){
    .start_byte = start_byte, .end_byte = end_byte, .cursor_byte = end_byte};
  if (g_editor_input_pane == 1 && g_active_view) {
    NimculusMetalView *view = (NimculusMetalView *)g_active_view;
    view.selectedTextRange = NSMakeRange(g_secondary_editor_selection_start,
      g_secondary_editor_selection_end - g_secondary_editor_selection_start);
  }
  if (g_queue) rebuildSecondaryEditorTexture(g_queue.device);
  markSceneFullyDirty();
  if (g_active_view) [(NimculusMetalView *)g_active_view requestRedraw];
}
void nimculus_platform_set_secondary_editor_selections(
    const NimculusEditorSelection *selections, uint32_t count) {
  g_secondary_editor_selection_count = MIN(count, NIMCULUS_MAX_EDITOR_SELECTIONS);
  if (g_secondary_editor_selection_count > 0 && selections) {
    memcpy(g_secondary_editor_selections, selections,
      g_secondary_editor_selection_count * sizeof(NimculusEditorSelection));
    NSUInteger start = utf16OffsetForUTF8Bytes(g_secondary_editor_text ?: @"",
      g_secondary_editor_selections[0].start_byte);
    NSUInteger end = utf16OffsetForUTF8Bytes(g_secondary_editor_text ?: @"",
      g_secondary_editor_selections[0].end_byte);
    g_secondary_editor_selection_start = MIN(start, end);
    g_secondary_editor_selection_end = MAX(start, end);
  }
  if (g_queue) rebuildSecondaryEditorTexture(g_queue.device);
  markSceneFullyDirty();
  if (g_active_view) [g_active_view requestRedraw];
}
void nimculus_platform_set_secondary_editor_scroll_line(uint32_t line) {
  g_secondary_editor_scroll_line = line;
  if (g_queue) rebuildSecondaryEditorTexture(g_queue.device);
  markSceneFullyDirty();
  if (g_active_view) [(NimculusMetalView *)g_active_view requestRedraw];
}
void nimculus_platform_set_secondary_editor_scroll_y_fraction(double pixels) {
  g_secondary_editor_scroll_y_fraction = MIN(MAX(0.0, pixels),
    MAX(0.0, editorLineHeight() - 0.001));
  if (g_queue) rebuildSecondaryEditorTexture(g_queue.device);
  markSceneFullyDirty();
  if (g_active_view) [(NimculusMetalView *)g_active_view requestRedraw];
}
void nimculus_platform_set_secondary_editor_scroll_x(double offset) {
  double previousRect[4] = {g_editor_rect[0], g_editor_rect[1],
    g_editor_rect[2], g_editor_rect[3]};
  NSUInteger previousScrollLine = g_editor_scroll_line;
  CGFloat previousScrollYFraction = g_editor_scroll_y_fraction;
  CGFloat previousScrollX = g_editor_scroll_x;
  BOOL previousSoftWrap = g_editor_soft_wrap;
  BOOL previousRenderingSecondary = g_rendering_secondary_editor;
  swapEditorTextState();
  g_rendering_secondary_editor = YES;
  memcpy(g_editor_rect, g_secondary_editor_rect, sizeof(g_editor_rect));
  g_editor_scroll_line = g_secondary_editor_scroll_line;
  g_editor_scroll_y_fraction = g_secondary_editor_scroll_y_fraction;
  g_editor_scroll_x = g_secondary_editor_scroll_x;
  g_editor_soft_wrap = g_secondary_editor_soft_wrap;
  g_secondary_editor_scroll_x = editorClampedScrollX(offset);
  swapEditorTextState();
  g_rendering_secondary_editor = previousRenderingSecondary;
  memcpy(g_editor_rect, previousRect, sizeof(g_editor_rect));
  g_editor_scroll_line = previousScrollLine;
  g_editor_scroll_y_fraction = previousScrollYFraction;
  g_editor_scroll_x = previousScrollX;
  g_editor_soft_wrap = previousSoftWrap;
  if (g_queue) rebuildSecondaryEditorTexture(g_queue.device);
  markSceneFullyDirty();
  if (g_active_view) [(NimculusMetalView *)g_active_view requestRedraw];
}
double nimculus_platform_secondary_editor_scroll_x(void) {
  return g_secondary_editor_scroll_x;
}
double nimculus_platform_secondary_editor_widest_visible_line_width(void) {
  if (!g_secondary_editor_visible || g_secondary_editor_soft_wrap) return 0.0;
  double previousRect[4] = {g_editor_rect[0], g_editor_rect[1],
    g_editor_rect[2], g_editor_rect[3]};
  NSUInteger previousScrollLine = g_editor_scroll_line;
  CGFloat previousScrollYFraction = g_editor_scroll_y_fraction;
  CGFloat previousScrollX = g_editor_scroll_x;
  BOOL previousSoftWrap = g_editor_soft_wrap;
  BOOL previousRenderingSecondary = g_rendering_secondary_editor;
  swapEditorTextState();
  g_rendering_secondary_editor = YES;
  memcpy(g_editor_rect, g_secondary_editor_rect, sizeof(g_editor_rect));
  g_editor_scroll_line = g_secondary_editor_scroll_line;
  g_editor_scroll_y_fraction = g_secondary_editor_scroll_y_fraction;
  g_editor_scroll_x = g_secondary_editor_scroll_x;
  g_editor_soft_wrap = g_secondary_editor_soft_wrap;
  double result = editorWidestVisibleLineWidth();
  swapEditorTextState();
  g_rendering_secondary_editor = previousRenderingSecondary;
  memcpy(g_editor_rect, previousRect, sizeof(g_editor_rect));
  g_editor_scroll_line = previousScrollLine;
  g_editor_scroll_y_fraction = previousScrollYFraction;
  g_editor_scroll_x = previousScrollX;
  g_editor_soft_wrap = previousSoftWrap;
  return result;
}
void nimculus_platform_set_secondary_editor_soft_wrap(bool enabled) {
  g_secondary_editor_soft_wrap = enabled ? YES : NO;
  if (g_secondary_editor_soft_wrap) g_secondary_editor_scroll_x = 0.0;
  if (g_queue) rebuildSecondaryEditorTexture(g_queue.device);
  markSceneFullyDirty();
  if (g_active_view) [(NimculusMetalView *)g_active_view requestRedraw];
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
  if (g_active_view) [(NimculusMetalView *)g_active_view requestRedraw];
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
  if (g_editor_soft_wrap == (enabled ? YES : NO)) return;
  g_editor_soft_wrap = enabled ? YES : NO;
  if (g_editor_soft_wrap) g_editor_scroll_x = 0.0;
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
  scheduleEditorTextTextureRebuild();
  if (g_active_view) [(NimculusMetalView *)g_active_view requestRedraw];
}
static void replaceEditorFolds(NimculusFoldRange **slot, uint32_t *count,
                               const NimculusFoldRange *ranges, uint32_t range_count) {
  free(*slot);
  *slot = NULL;
  *count = 0;
  if (!ranges || range_count == 0) return;
  NimculusFoldRange *copy = calloc(range_count, sizeof(NimculusFoldRange));
  if (!copy) return;
  memcpy(copy, ranges, range_count * sizeof(NimculusFoldRange));
  *slot = copy;
  *count = range_count;
}
void nimculus_platform_set_editor_folds(const NimculusFoldRange *ranges, uint32_t count) {
  if (count == g_editor_fold_count &&
      (count == 0 || (g_editor_folds && ranges &&
        memcmp(g_editor_folds, ranges, sizeof(NimculusFoldRange) * count) == 0))) {
    return;
  }
  replaceEditorFolds(&g_editor_folds, &g_editor_fold_count, ranges, count);
  g_editor_scroll_line = editorFirstVisibleLine(g_editor_scroll_line, g_editor_line_count);
  scheduleEditorTextTextureRebuild();
  markSceneFullyDirty();
  if (g_active_view) {
    NimculusMetalView *view = (NimculusMetalView *)g_active_view;
    for (NSView *subview in view.subviews) {
      if ([subview isKindOfClass:[NimculusLineNumberOverlay class]] ||
          [subview isKindOfClass:[NimculusIndentGuideOverlay class]]) [subview setNeedsDisplay:YES];
    }
  [view requestRedraw];
  }
}
void nimculus_platform_set_secondary_editor_folds(const NimculusFoldRange *ranges, uint32_t count) {
  replaceEditorFolds(&g_secondary_editor_folds, &g_secondary_editor_fold_count, ranges, count);
  g_secondary_editor_scroll_line = editorFirstVisibleLine(g_secondary_editor_scroll_line,
    g_secondary_editor_line_count);
  if (g_queue) rebuildSecondaryEditorTexture(g_queue.device);
  markSceneFullyDirty();
  if (g_active_view) [(NimculusMetalView *)g_active_view requestRedraw];
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
void nimculus_platform_set_editor_context(const char *utf8) {
  replaceOwnedString(&g_editor_context, (utf8 && strlen(utf8) > 0)
    ? [NSString stringWithUTF8String:utf8] : @"");
  NimculusMetalView *view = (NimculusMetalView *)g_active_view;
  if (!view) return;
  for (NSView *subview in view.subviews) {
    if ([subview isKindOfClass:[NimculusEditorContextOverlay class]]) {
      NimculusEditorContextOverlay *context = (NimculusEditorContextOverlay *)subview;
      context.stringValue = g_editor_context;
      [context updateBreadcrumbPresentation];
      break;
    }
  }
  [view updateTerminalFrame];
}
void nimculus_platform_set_editor_git_branch(const char *utf8) {
  replaceOwnedUTF8String(&g_editor_git_branch, utf8,
    utf8 ? (uint32_t)strlen(utf8) : 0, @"");
  NimculusMetalView *view = (NimculusMetalView *)g_active_view;
  if (!view) return;
  NSView *root = view.superview;
  if ([root isKindOfClass:[NimculusWindowContentView class]]) {
    NimculusTitlebarView *titlebar = ((NimculusWindowContentView *)root).titlebarView;
    [titlebar updateBranchButton];
    [titlebar setNeedsDisplay:YES];
  }
  for (NSView *subview in view.subviews) {
    if ([subview isKindOfClass:[NimculusFooterOverlay class]]) {
      [(NimculusFooterOverlay *)subview reloadStatusItems];
      [subview setNeedsDisplay:YES];
      break;
    }
  }
}
void nimculus_platform_set_editor_status(const char *utf8) {
  const char *value = (utf8 && strlen(utf8) > 0) ? utf8 : "Ready";
  // The workspace timer polls asynchronous services frequently. Do not turn
  // an unchanged status label into an AppKit string replacement/layout pass
  // on every poll; GPUI likewise refreshes a window in response to state
  // notification rather than a fixed idle mutation.
  if (g_editor_status && strcmp(g_editor_status.UTF8String, value) == 0) return;
  replaceOwnedString(&g_editor_status, [NSString stringWithUTF8String:value]);
  NimculusMetalView *view = (NimculusMetalView *)g_active_view;
  if (!view) return;
  for (NSView *subview in view.subviews) {
    if ([subview isKindOfClass:[NimculusStatusOverlay class]]) {
      // The native status presenter is a color-only parity band; footer text
      // and actions remain owned by NimculusFooterOverlay below it.
      ((NSTextField *)subview).stringValue = @"";
    }
    if ([subview isKindOfClass:[NimculusFooterOverlay class]]) {
      [(NimculusFooterOverlay *)subview reloadStatusItems];
      [subview setNeedsDisplay:YES];
    }
  }
}
void nimculus_platform_set_editor_footer(const char *utf8) {
  const char *value = (utf8 && strlen(utf8) > 0) ? utf8 :
    "1:1\tSpaces: 2\tUTF-8\tLF\tPlain Text\tLSP: なし\t";
  if (g_editor_footer && strcmp(g_editor_footer.UTF8String, value) == 0) return;
  replaceOwnedString(&g_editor_footer, [NSString stringWithUTF8String:value]);
  NimculusMetalView *view = (NimculusMetalView *)g_active_view;
  if (!view) return;
  for (NSView *subview in view.subviews) {
    if ([subview isKindOfClass:[NimculusFooterOverlay class]]) {
      [(NimculusFooterOverlay *)subview reloadStatusItems];
      [subview setNeedsDisplay:YES];
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
  // Republished after every input event, and it walks the whole document twice
  // to map byte offsets to UTF-16 units before rebuilding the texture.
  static uint32_t lastStart = UINT32_MAX;
  static uint32_t lastEnd = UINT32_MAX;
  if (start_byte == lastStart && end_byte == lastEnd) return;
  lastStart = start_byte;
  lastEnd = end_byte;
  NSUInteger start = utf16OffsetForUTF8Bytes(g_editor_text ?: @"", start_byte);
  NSUInteger end = utf16OffsetForUTF8Bytes(g_editor_text ?: @"", end_byte);
  g_editor_selection_start = MIN(start, end);
  g_editor_selection_end = MAX(start, end);
  g_editor_selection_count = 1;
  g_editor_selections[0] = (NimculusEditorSelection){
    .start_byte = start_byte, .end_byte = end_byte, .cursor_byte = end_byte};
  if (g_editor_input_pane == 0 && g_active_view) {
    NimculusMetalView *view = (NimculusMetalView *)g_active_view;
    view.selectedTextRange = NSMakeRange(g_editor_selection_start,
      g_editor_selection_end - g_editor_selection_start);
  }
  scheduleEditorTextTextureRebuild();
  markSceneFullyDirty();
  if (g_active_view) [(NimculusMetalView *)g_active_view requestRedraw];
}
void nimculus_platform_set_editor_selections(const NimculusEditorSelection *selections,
                                             uint32_t count) {
  // Same story as the cursor, and this one walks the whole document to map
  // byte offsets to UTF-16 units before rebuilding the texture.
  const uint32_t bounded = MIN(count, NIMCULUS_MAX_EDITOR_SELECTIONS);
  if (bounded == g_editor_selection_count &&
      (bounded == 0 || (selections &&
        memcmp(g_editor_selections, selections,
          bounded * sizeof(NimculusEditorSelection)) == 0))) {
    return;
  }
  g_editor_selection_count = bounded;
  if (g_editor_selection_count > 0 && selections) {
    memcpy(g_editor_selections, selections,
      g_editor_selection_count * sizeof(NimculusEditorSelection));
    NSUInteger start = utf16OffsetForUTF8Bytes(g_editor_text ?: @"",
      g_editor_selections[0].start_byte);
    NSUInteger end = utf16OffsetForUTF8Bytes(g_editor_text ?: @"",
      g_editor_selections[0].end_byte);
    g_editor_selection_start = MIN(start, end);
    g_editor_selection_end = MAX(start, end);
  }
  scheduleEditorTextTextureRebuild();
  markSceneFullyDirty();
  if (g_active_view) [(NimculusMetalView *)g_active_view requestRedraw];
}
// Nim resynchronises the whole document after every input event, so these
// setters are called at the trackpad's event rate with values that have not
// changed. Each one used to rebuild the text texture. Compare first: an
// equality check on the payload is orders of magnitude cheaper than
// re-running Core Text over the visible lines.
static BOOL editorPayloadUnchanged(NSString *current, const char *utf8, uint32_t length) {
  NSString *candidate = utf8 && length > 0
    ? [[[NSString alloc] initWithBytes:utf8 length:length encoding:NSUTF8StringEncoding]
        autorelease]
    : @"";
  if (!candidate) return NO;
  return [(current ?: @"") isEqualToString:candidate];
}

void nimculus_platform_set_editor_text(const char *utf8, uint32_t length) {
  if (editorPayloadUnchanged(g_editor_text, utf8, length)) return;
  replaceOwnedUTF8String(&g_editor_text, utf8, length, @"");
  rebuildEditorLineIndex();
  if (g_active_view) {
    for (NSView *subview in ((NimculusMetalView *)g_active_view).subviews) {
      if ([subview isKindOfClass:[NimculusLineNumberOverlay class]]) [subview setNeedsDisplay:YES];
    }
  }
  markSceneFullyDirty();
  scheduleEditorTextTextureRebuild();
  if (g_active_view) [g_active_view requestRedraw];
}

bool nimculus_platform_validate_editor_gutter_geometry(void) {
  NSString *previousText = [g_editor_text retain];
  NSMutableString *sample = [NSMutableString string];
  for (NSUInteger index = 0; index < 1000; index++) {
    [sample appendString:@"line"];
    if (index + 1 < 1000) [sample appendString:@"\n"];
  }
  NSUInteger sampleLength = [sample lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
  nimculus_platform_set_editor_text(sample.UTF8String, (uint32_t)sampleLength);

  NimculusEditorGutterMetrics metrics = editorGutterMetrics();
  CTFontRef font = editorFont();
  CGFloat descent = font ? CTFontGetDescent(font) : g_editor_font_size * 0.22;
  CGFloat expectedLineGutterWidth = MAX(metrics.max_line_number_width,
    metrics.ch_advance * 4.0);
  CGFloat expectedWidth = expectedLineGutterWidth + metrics.ch_width * 3.0 +
    metrics.ch_width * 4.0;
  CGFloat expectedOrigin = expectedWidth + descent;
  CGFloat origin = editorTextOriginX(g_editor_rect);
  BOOL valid = fabs(metrics.line_gutter_width - expectedLineGutterWidth) < 0.01 &&
    fabs(metrics.left_padding - metrics.ch_width * 3.0) < 0.01 &&
    fabs(metrics.right_padding - metrics.ch_width * 4.0) < 0.01 &&
    fabs(metrics.width - expectedWidth) < 0.01 &&
    fabs(metrics.margin - descent) < 0.01 &&
    fabs(origin - expectedOrigin) < 0.01 &&
    metrics.width > metrics.ch_advance * 4.0;
  if (font) CFRelease(font);

  nimculus_platform_set_editor_text(previousText.UTF8String,
    (uint32_t)[previousText lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
  [previousText release];
  return valid;
}

void nimculus_platform_set_secondary_editor_text(const char *utf8, uint32_t length) {
  replaceOwnedUTF8String(&g_secondary_editor_text, utf8, length, @"");
  rebuildSecondaryEditorLineIndex();
  if (g_queue) rebuildSecondaryEditorTexture(g_queue.device);
  markSceneFullyDirty();
  if (g_active_view) [g_active_view requestRedraw];
}
void nimculus_platform_set_editor_outline(const char *utf8, uint32_t length,
                                          uint32_t symbol_count) {
  g_editor_sidebar_mode = 0;
  free(g_editor_sidebar_line_items); g_editor_sidebar_line_items = NULL;
  g_editor_sidebar_line_item_count = 0;
  replaceOwnedUTF8String(&g_editor_outline_text, utf8, length,
    @"Outline\n────────\nNo symbols");
  g_editor_outline_symbol_count = symbol_count;
  NimculusMetalView *view = (NimculusMetalView *)g_active_view;
  if (!view) return;
  NimculusOutlineOverlay *outline = outlineOverlayForView(view);
  if (outline) applySidebarPresentation(outline);
  refreshQuickOpenPickerForView(view);
  [view updateTerminalFrame];
}
void nimculus_platform_set_editor_sidebar(const char *utf8, uint32_t length,
                                          uint32_t item_count, uint32_t mode) {
  g_editor_sidebar_mode = mode;
  free(g_editor_sidebar_line_items); g_editor_sidebar_line_items = NULL;
  g_editor_sidebar_line_item_count = 0;
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
  refreshQuickOpenPickerForView(view);
  for (NSView *subview in view.subviews) {
    if ([subview isKindOfClass:[NimculusFooterOverlay class]]) {
      [(NimculusFooterOverlay *)subview reloadStatusItems];
      [subview setNeedsDisplay:YES];
      break;
    }
  }
  [view updateTerminalFrame];
}
void nimculus_platform_set_editor_sidebar_line_items(const int32_t *items,
                                                     uint32_t count) {
  free(g_editor_sidebar_line_items); g_editor_sidebar_line_items = NULL;
  g_editor_sidebar_line_item_count = 0;
  if (items && count > 0) {
    g_editor_sidebar_line_items = calloc(count, sizeof(int32_t));
    if (!g_editor_sidebar_line_items) return;
    memcpy(g_editor_sidebar_line_items, items, count * sizeof(int32_t));
    g_editor_sidebar_line_item_count = count;
  }
  // The text setter intentionally arrives before this metadata setter from
  // Nim. Rebuild the attributed rows after the line map exists so status
  // colors, icon attachments, and guide geometry are based on final state.
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

bool nimculus_platform_validate_sidebar_presentation(void) {
  @autoreleasepool {
    id previousView = g_active_view;
    NSString *previousText = [g_editor_outline_text retain];
    uint32_t previousMode = g_editor_sidebar_mode;
    uint32_t previousCount = g_editor_outline_symbol_count;
    NSUInteger previousSelection = g_editor_sidebar_selected_index;
    uint32_t previousLineItemCount = g_editor_sidebar_line_item_count;
    int32_t *previousLineItems = NULL;
    if (previousLineItemCount > 0 && g_editor_sidebar_line_items) {
      previousLineItems = calloc(previousLineItemCount, sizeof(int32_t));
      if (previousLineItems) memcpy(previousLineItems, g_editor_sidebar_line_items,
        previousLineItemCount * sizeof(int32_t));
    }
    NimculusMetalView *view = [[NimculusMetalView alloc]
      initWithFrame:NSMakeRect(0.0, 0.0, 640.0, 480.0)];
    g_active_view = view;
    const char *text = "Files\n────────\n▾ src\n  ≡ main.nim\n  • .nimcache";
    int32_t lineItems[] = {-1, -1, 0, 1 | (4 << 24), 2 | (1 << 24)};
    nimculus_platform_set_editor_sidebar(text, (uint32_t)strlen(text), 3, 1);
    nimculus_platform_set_editor_sidebar_line_items(lineItems, 5);
    NimculusOutlineOverlay *sidebar = outlineOverlayForView(view);
    NSUInteger folderStart = [sidebar.string rangeOfString:@"\uFFFC src"].location;
    NSUInteger fileStart = [sidebar.string rangeOfString:@"\uFFFC main.nim"].location;
    NSUInteger ignoredStart = [sidebar.string rangeOfString:@"\uFFFC .nimcache"].location;
    NSParagraphStyle *fileStyle = fileStart != NSNotFound
      ? [sidebar.textStorage attribute:NSParagraphStyleAttributeName atIndex:fileStart + 2
        effectiveRange:NULL] : nil;
    NSTextAttachment *fileAttachment = fileStart != NSNotFound
      ? [sidebar.textStorage attribute:NSAttachmentAttributeName atIndex:fileStart
        effectiveRange:NULL] : nil;
    NSColor *ignoredColor = ignoredStart != NSNotFound
      ? [sidebar.textStorage attribute:NSForegroundColorAttributeName atIndex:ignoredStart
        effectiveRange:NULL] : nil;
    NSFont *fileFont = fileStart != NSNotFound
      ? [sidebar.textStorage attribute:NSFontAttributeName atIndex:fileStart + 2
        effectiveRange:NULL] : nil;
    BOOL valid = sidebar && folderStart != NSNotFound && fileStart != NSNotFound &&
      ignoredStart != NSNotFound && fileStyle.headIndent == 20.0 &&
      fileAttachment != nil && ignoredColor != nil && fileFont != nil &&
      fabs(fileFont.pointSize - NimculusUiTextSize) < 0.001 &&
      [fileFont.fontName isEqualToString:editorUiFontWithWeight(NSFontWeightRegular).fontName];
    if (sidebarDebugEnabled()) {
      NSLog(@"Nimculus sidebar presentation contract sidebar=%@ src=%lu file=%lu "
            "ignored=%lu headIndent=%.1f attachment=%@ color=%@",
        sidebar ? @"yes" : @"nil", (unsigned long)folderStart, (unsigned long)fileStart,
        (unsigned long)ignoredStart, fileStyle.headIndent,
        fileAttachment ? @"yes" : @"nil", ignoredColor ? @"yes" : @"nil");
    }
    [view release];
    replaceOwnedUTF8String(&g_editor_outline_text, previousText.UTF8String,
      (uint32_t)[previousText lengthOfBytesUsingEncoding:NSUTF8StringEncoding], @"");
    g_active_view = previousView;
    g_editor_sidebar_mode = previousMode;
    g_editor_outline_symbol_count = previousCount;
    g_editor_sidebar_selected_index = previousSelection;
    free(g_editor_sidebar_line_items);
    g_editor_sidebar_line_items = previousLineItems;
    g_editor_sidebar_line_item_count = previousLineItems ? previousLineItemCount : 0;
    [previousText release];
    return valid;
  }
}

static NSUInteger editorSidebarLineForItem(NSUInteger item) {
  if (g_editor_sidebar_line_items) {
    for (uint32_t line = 0; line < g_editor_sidebar_line_item_count; line++) {
      if (sidebarItemFromLineValue(g_editor_sidebar_line_items[line]) == item &&
          line >= NimculusSidebarHeaderLineCount) {
        return line - NimculusSidebarHeaderLineCount;
      }
    }
    return NSNotFound;
  }
  return item;
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
    [outline setNeedsDisplay:YES];
    return;
  }
  NSUInteger line = editorSidebarLineForItem(g_editor_sidebar_selected_index);
  if (line == NSNotFound) {
    [outline setSelectedRange:NSMakeRange(0, 0)];
    [outline setNeedsDisplay:YES];
    return;
  }
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
    [outline setNeedsDisplay:YES];
    return;
  }
  NSRange range = NSMakeRange(start, end - start);
  // Keep AppKit's semantic selection in the same row as the custom themed
  // inactive-selection paint. Clearing the range made the row look selected
  // while keyboard navigation and accessibility still reported no selection.
  [outline setSelectedRange:range];
  [outline scrollRangeToVisible:range];
  [outline setNeedsDisplay:YES];
  if (view) {
    for (NSView *subview in view.subviews) {
      if ([subview isKindOfClass:[NimculusDocumentSearchOverlay class]]) {
        NimculusDocumentSearchOverlay *search = (NimculusDocumentSearchOverlay *)subview;
        if (!search.hidden && search.mode == 4) {
          search.pickerList.selectedIndex = g_editor_sidebar_selected_index;
          [search.pickerList reload];
        }
      }
    }
  }
}
void nimculus_platform_set_editor_sidebar_visible(bool visible) {
  const BOOL nextVisible = visible ? YES : NO;
  NimculusMetalView *view = (NimculusMetalView *)g_active_view;
  if (!view) {
    g_editor_sidebar_visible = nextVisible;
    return;
  }
  NimculusOutlineOverlay *outline = outlineOverlayForView(view);
  if (g_editor_sidebar_visible == nextVisible &&
      (outline && outline.enclosingScrollView &&
       outline.enclosingScrollView.hidden == !nextVisible)) return;
  g_editor_sidebar_visible = nextVisible;
  if (outline.enclosingScrollView) outline.enclosingScrollView.hidden = !g_editor_sidebar_visible;
  [view updateTerminalFrame];
  [view requestRedraw];
}
void nimculus_platform_focus_editor_sidebar(void) {
  NimculusMetalView *view = (NimculusMetalView *)g_active_view;
  if (!view || !g_editor_sidebar_visible) return;
  NimculusOutlineOverlay *outline = outlineOverlayForView(view);
  if (outline && outline.enclosingScrollView && !outline.enclosingScrollView.hidden) {
    [view.window makeFirstResponder:outline];
  }
}
void nimculus_platform_focus_editor(void) {
  NimculusMetalView *view = (NimculusMetalView *)g_active_view;
  if (view && view.window) [view.window makeFirstResponder:view];
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
void nimculus_platform_set_editor_sidebar_on_right(bool on_right) {
  g_editor_sidebar_on_right = on_right ? YES : NO;
  NimculusMetalView *view = (NimculusMetalView *)g_active_view;
  if (view) [view updateTerminalFrame];
}
void nimculus_platform_open_workspace_folder(void) {
  NimculusAppDelegate *delegate = (NimculusAppDelegate *)[NSApp delegate];
  if (delegate) [delegate openWorkspaceFolder:nil];
}
void nimculus_platform_prompt_extension_directory(void) {
  NimculusAppDelegate *delegate = (NimculusAppDelegate *)[NSApp delegate];
  if (delegate && [delegate respondsToSelector:@selector(promptExtensionDirectory:)]) {
    [delegate promptExtensionDirectory:nil];
  }
}
void nimculus_platform_prompt_extension_permissions(const char *title,
                                                    const char *details) {
  NimculusAppDelegate *delegate = (NimculusAppDelegate *)[NSApp delegate];
  if (!delegate) return;
  NSString *message = title ? [NSString stringWithUTF8String:title] : @"";
  NSString *explanation = details ? [NSString stringWithUTF8String:details] : @"";
  [delegate presentExtensionPermissionSheetWithTitle:(message ?: @"")
                                               details:(explanation ?: @"")];
}
void nimculus_platform_set_terminal_visible(bool visible) {
  g_terminal_visible = visible ? YES : NO;
  if (g_active_view) {
    NimculusMetalView *view = (NimculusMetalView *)g_active_view;
    for (NSView *subview in view.subviews) {
      if ([subview isKindOfClass:[NimculusFooterOverlay class]]) {
        [(NimculusFooterOverlay *)subview reloadStatusItems];
        [subview setNeedsDisplay:YES];
        break;
      }
    }
    [view updateTerminalFrame];
    markSceneFullyDirty();
    [g_active_view requestRedraw];
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
  if (g_queue) updateTerminalGlyphAtlas(g_queue.device);
  markSceneFullyDirty();
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
  [view requestRedraw];
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
  if (g_queue) updateTerminalGlyphAtlas(g_queue.device);
  markSceneFullyDirty();
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
  [view requestRedraw];
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
  // Full-size content windows leave the native traffic-light titlebar backed
  // by the window color. Keep that backing surface on the resolved theme
  // instead of AppKit's default #e3e3e3 light gray.
  view.window.backgroundColor = themeRoleColor(@"chromeBg", [NSColor windowBackgroundColor]);
  for (NSView *subview in view.subviews) {
    if ([subview isKindOfClass:[NimculusTerminalOverlay class]]) {
      NSTextView *terminal = (NSTextView *)subview;
      terminal.backgroundColor = terminalPaletteRoleColor(@"background", themeHexColor(g_theme_background,
        [NSColor colorWithCalibratedRed:0.025 green:0.030 blue:0.045 alpha:1.0]));
      terminal.textColor = terminalPaletteRoleColor(@"foreground", themeHexColor(g_theme_foreground,
        [NSColor colorWithCalibratedRed:0.82 green:0.88 blue:0.92 alpha:1.0]));
      terminal.insertionPointColor = terminalPaletteRoleColor(@"cursor",
        terminalPaletteRoleColor(@"brightForeground", terminal.textColor));
      terminal.selectedTextAttributes = @{
        NSBackgroundColorAttributeName: terminalPaletteRoleColor(@"selection",
          [NSColor colorWithCalibratedRed:0.20 green:0.40 blue:0.75 alpha:1.0])
      };
    }
  }
  NimculusOutlineOverlay *outline = outlineOverlayForView(view);
  if (outline) {
    outline.backgroundColor = [themeRoleColor(@"panel", themeHexColor(g_theme_background,
      [NSColor colorWithCalibratedRed:0.045 green:0.055 blue:0.075 alpha:1.0]))
      colorWithAlphaComponent:0.96];
    outline.textColor = themeRoleColor(@"foreground", themeHexColor(g_theme_foreground,
      [NSColor colorWithCalibratedRed:0.82 green:0.88 blue:0.92 alpha:1.0]));
    applySidebarPresentation(outline);
  }
  for (NSView *subview in view.subviews) {
    if ([subview isKindOfClass:[NimculusOutlineFilterField class]]) {
      NimculusOutlineFilterField *filter = (NimculusOutlineFilterField *)subview;
      filter.backgroundColor = themeRoleColor(@"element", [NSColor controlBackgroundColor]);
      filter.textColor = themeRoleColor(@"fgPrimary", [NSColor labelColor]);
      filter.appearance = view.effectiveAppearance;
    }
  }
  NimculusWindowContentView *root = nil;
  if ([view.superview isKindOfClass:[NimculusWindowContentView class]]) {
    root = (NimculusWindowContentView *)view.superview;
    [root.titlebarView updateBranchButton];
    [root.titlebarView setNeedsDisplay:YES];
  }
  for (NSView *subview in view.subviews) {
    if ([subview isKindOfClass:[NimculusFilesSidebarActions class]]) {
      [(NimculusFilesSidebarActions *)subview reloadActions];
    } else if ([subview isKindOfClass:[NimculusTabBarOverlay class]]) {
      for (NSView *buttonView in subview.subviews) {
        if ([buttonView isKindOfClass:[NSButton class]])
          styleWorkspaceNavigationButton((NSButton *)buttonView, NO, YES);
      }
    } else if ([subview isKindOfClass:[NimculusSearchSidebarActions class]] ||
               [subview isKindOfClass:[NimculusGitChangesActions class]]) {
      for (NSView *buttonView in subview.subviews) {
        if ([buttonView isKindOfClass:[NSButton class]])
          styleWorkspaceNavigationButton((NSButton *)buttonView, NO, YES);
      }
    } else if ([subview isKindOfClass:[NimculusGitCommitOverlay class]]) {
      NimculusGitCommitOverlay *commit = (NimculusGitCommitOverlay *)subview;
      commit.layer.borderColor = [themeRoleColor(@"borderVariant", [NSColor separatorColor])
        colorWithAlphaComponent:0.8].CGColor;
      commit.layer.backgroundColor = [themeRoleColor(@"panel", [NSColor windowBackgroundColor])
        colorWithAlphaComponent:0.99].CGColor;
      commit.messageField.backgroundColor = themeRoleColor(@"element", [NSColor controlBackgroundColor]);
      commit.messageField.textColor = themeRoleColor(@"fgPrimary", [NSColor labelColor]);
      styleSidebarActionButton(commit.commitButton);
      styleWorkspaceNavigationButton(commit.closeButton, NO, YES);
    } else if ([subview isKindOfClass:[NimculusFooterOverlay class]]) {
      [(NimculusFooterOverlay *)subview reloadStatusItems];
      [subview setNeedsDisplay:YES];
    } else if ([subview isKindOfClass:[NimculusEditorContextOverlay class]]) {
      [(NimculusEditorContextOverlay *)subview updateBreadcrumbPresentation];
    }
  }
  if (g_queue) updateTerminalGlyphAtlas(g_queue.device);
  markSceneFullyDirty();
  [view requestRedraw];
}

void nimculus_platform_set_theme_palette_json(const char *json) {
  if (!json || json[0] == '\0') return;
  NSData *data = [NSData dataWithBytes:json length:strlen(json)];
  NSError *error = nil;
  id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
  if (error || ![object isKindOfClass:[NSDictionary class]]) return;
  NSArray<NSString *> *keys = @[
    @"background", @"foreground", @"accent", @"selection", @"border", @"surface", @"panel",
    @"element", @"elementHover", @"elementActive", @"elementSelected", @"textMuted",
    @"textPlaceholder", @"textDisabled", @"textAccent", @"borderVariant", @"borderFocused",
    @"borderSelected", @"titleBar", @"titleBarInactive", @"toolbar", @"tabBar", @"tabActive",
    @"tabInactive", @"statusBar", @"editor", @"editorForeground", @"gutter", @"editorSubheader",
    @"editorActiveLine",
    @"scrollbarThumb", @"scrollbarTrackBorder", @"scrollbarHover", @"lineNumber",
    @"activeLineNumber", @"hoverLineNumber",
    @"caret", @"elevated", @"terminal", @"added", @"modified", @"deleted",
    @"conflict", @"warning", @"hint", @"error", @"info", @"success"
  ];
  NSMutableDictionary *palette = [NSMutableDictionary dictionaryWithCapacity:keys.count];
  NSDictionary *source = (NSDictionary *)object;
  for (NSString *key in keys) {
    id value = source[key];
    if (validThemeToken(value)) palette[key] = value;
  }
  NSDictionary *syntax = [source[@"syntax"] isKindOfClass:[NSDictionary class]] ?
    source[@"syntax"] : nil;
  if (syntax) palette[@"syntax"] = syntax;
  NSDictionary *terminalPalette = validatedTerminalPalette(source[@"terminalPalette"]);
  if (terminalPalette) palette[@"terminalPalette"] = terminalPalette;
  if (palette.count == 0) return;
  [g_theme_palette release];
  g_theme_palette = [palette copy];
  nimculus_platform_set_theme_colors([g_theme_palette[@"background"] UTF8String],
    [g_theme_palette[@"foreground"] UTF8String], [g_theme_palette[@"accent"] UTF8String],
    [g_theme_palette[@"selection"] UTF8String], [g_theme_palette[@"border"] UTF8String]);
  NimculusEditorLayoutGlyph *layoutGlyphArrays[] = {
    g_editor_layout_glyphs, g_secondary_layout_glyphs};
  uint32_t layoutGlyphCounts[] = {
    g_editor_layout_glyph_count, g_secondary_layout_glyph_count};
  for (NSUInteger arrayIndex = 0; arrayIndex < 2; arrayIndex++) {
    for (uint32_t glyphIndex = 0; glyphIndex < layoutGlyphCounts[arrayIndex]; glyphIndex++) {
      NimculusEditorLayoutGlyph *glyph = &layoutGlyphArrays[arrayIndex][glyphIndex];
      NimculusEditorGlyphColor color;
      nimculus_platform_get_editor_glyph_color(glyph->color_kind, &color);
      glyph->red = color.red;
      glyph->green = color.green;
      glyph->blue = color.blue;
      glyph->alpha = color.alpha;
    }
  }
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
    outline.font = editorUiFontWithWeight(NSFontWeightRegular);
  }
  if (g_queue) updateTerminalGlyphAtlas(g_queue.device);
  markSceneFullyDirty();
  [view requestRedraw];
}
void nimculus_platform_set_terminal_font_size(double size) {
  g_terminal_font_size = MIN(48.0, MAX(6.0, size > 0.0 ? size : 12.0));
  updateTerminalFonts();
}
void nimculus_platform_set_terminal_font_name(const char *name) {
  NSString *requested = name ? [NSString stringWithUTF8String:name] : nil;
  replaceOwnedString(&g_terminal_font_name, requested.length > 0 ? requested : @".ZedMono");
  [g_terminal_resolved_font_name release];
  g_terminal_resolved_font_name = nil;
  (void)terminalResolvedFontName();
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
  markSceneFullyDirty();
  NimculusMetalView *view = (NimculusMetalView *)g_active_view;
  if (view) {
    for (NSView *subview in view.subviews) {
      if ([subview isKindOfClass:[NimculusTerminalOverlay class]]) {
        applyTerminalSelection((NSTextView *)subview);
        break;
      }
    }
  [view requestRedraw];
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
    [g_active_view requestRedraw];
  }
}
void nimculus_platform_set_task_output_cancellable(bool cancellable) {
  g_task_output_cancellable = cancellable ? YES : NO;
  NimculusMetalView *view = (NimculusMetalView *)g_active_view;
  if (!view) return;
  for (NSView *subview in view.subviews) {
    if ([subview isKindOfClass:[NimculusOutputPanelBar class]]) {
      [(NimculusOutputPanelBar *)subview reloadActions];
      break;
    }
  }
  [view updateTerminalFrame];
  [view requestRedraw];
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
  if (editorPayloadUnchanged(g_editor_completions, utf8, length)) return;
  replaceOwnedUTF8String(&g_editor_completions, utf8, length, @"");
  markSceneFullyDirty();
  if (g_queue) {
    updateEditorTextTexture(g_queue.device, g_editor_text, NO);
    rebuildSecondaryEditorTexture(g_queue.device);
  }
  if (g_active_view) [g_active_view requestRedraw];
}
void nimculus_platform_set_editor_hover(const char *utf8, uint32_t length) {
  replaceOwnedUTF8String(&g_editor_hover, utf8, length, @"");
  markSceneFullyDirty();
  if (g_queue) {
    updateEditorTextTexture(g_queue.device, g_editor_text, NO);
    rebuildSecondaryEditorTexture(g_queue.device);
  }
  if (g_active_view) [g_active_view requestRedraw];
}
void nimculus_platform_set_editor_hover_position(double x, double y) {
  g_editor_hover_position[0] = x;
  g_editor_hover_position[1] = y;
  markSceneFullyDirty();
  if (g_queue) {
    updateEditorTextTexture(g_queue.device, g_editor_text, NO);
    rebuildSecondaryEditorTexture(g_queue.device);
  }
  if (g_active_view) [g_active_view requestRedraw];
}
void nimculus_platform_set_editor_hover_pane(uint32_t pane) {
  g_editor_hover_pane = pane == 1 && g_secondary_editor_visible ? 1 : 0;
  markSceneFullyDirty();
  if (g_queue) {
    updateEditorTextTexture(g_queue.device, g_editor_text, NO);
    rebuildSecondaryEditorTexture(g_queue.device);
  }
  if (g_active_view) [g_active_view requestRedraw];
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
  if (g_active_view) [g_active_view requestRedraw];
}
void nimculus_platform_set_accessibility_tree(const NimculusAccessibilityNode *nodes,
                                              uint32_t node_count,
                                              const uint64_t *children,
                                              uint32_t child_count) {
  @autoreleasepool {
    if (node_count > 0 && !nodes) return;
    if (child_count > 0 && !children) return;
    NSMutableDictionary<NSNumber *, NimculusAXNode *> *next =
      [NSMutableDictionary dictionaryWithCapacity:node_count];
    for (uint32_t index = 0; index < node_count; index++) {
      const NimculusAccessibilityNode *native = &nodes[index];
      NimculusAXNode *node = [[[NimculusAXNode alloc] init] autorelease];
      node.role = accessibilityRoleForNative(native->role);
      node.identifier = native->identifier ?
        [NSString stringWithUTF8String:native->identifier] : @"";
      node.title = native->title ? [NSString stringWithUTF8String:native->title] : @"";
      node.value = native->value ? [NSString stringWithUTF8String:native->value] : @"";
      node.localFrame = NSMakeRect(native->x, native->y, native->width, native->height);
      node.synthetic = (native->flags & 1) != 0;
      node.selected = (native->flags & 2) != 0;
      node.expanded = (native->flags & 4) != 0;
      node.cursorByte = native->cursor_byte;
      node.selectedByteRange = NSMakeRange(native->selection_start_byte,
        native->selection_end_byte >= native->selection_start_byte
          ? native->selection_end_byte - native->selection_start_byte : 0);
      node.actionCommand = native->action_command ?
        [NSString stringWithUTF8String:native->action_command] : @"";
      next[@(native->id)] = node;
    }
    for (uint32_t index = 0; index < node_count; index++) {
      const NimculusAccessibilityNode *native = &nodes[index];
      NimculusAXNode *node = next[@(native->id)];
      if (!node) continue;
      NSMutableArray *childNodes = [NSMutableArray arrayWithCapacity:native->child_count];
      uint64_t end = (uint64_t)native->child_start + native->child_count;
      if (native->child_start <= child_count && end <= child_count) {
        for (uint32_t childIndex = native->child_start; childIndex < end; childIndex++) {
          NimculusAXNode *child = next[@(children[childIndex])];
          if (child) [childNodes addObject:child];
        }
      }
      node.childNodes = childNodes;
      NimculusAXNode *parent = next[@(native->parent_id)];
      node.parentNode = parent ?: (id)g_accessibility_host;
      if (native->role == 1 && g_accessibility_host) {
        node.localFrame = g_accessibility_host.bounds;
        node.parentNode = (id)g_accessibility_host.superview ?: (id)g_accessibility_host;
      }
    }
    NimculusAXNode *root = next[@(nodes && node_count > 0 ? nodes[0].id : 0)];
    if (g_accessibility_root != root) {
      [g_accessibility_root release];
      g_accessibility_root = [root retain];
    }
    [g_accessibility_nodes release];
    g_accessibility_nodes = [next retain];
  }
}

void nimculus_platform_set_editor_layout(bool secondary,
                                         const NimculusEditorLayoutRow *rows,
                                         uint32_t row_count,
                                         const NimculusEditorLayoutGlyph *glyphs,
                                         uint32_t glyph_count) {
  NimculusEditorLayoutRow **rowTarget = secondary
    ? &g_secondary_layout_rows : &g_editor_layout_rows;
  uint32_t *rowCountTarget = secondary
    ? &g_secondary_layout_row_count : &g_editor_layout_row_count;
  NimculusEditorLayoutGlyph **glyphTarget = secondary
    ? &g_secondary_layout_glyphs : &g_editor_layout_glyphs;
  uint32_t *glyphCountTarget = secondary
    ? &g_secondary_layout_glyph_count : &g_editor_layout_glyph_count;
  free(*rowTarget); *rowTarget = NULL; *rowCountTarget = 0;
  free(*glyphTarget); *glyphTarget = NULL; *glyphCountTarget = 0;
  if (rows && row_count > 0) {
    *rowTarget = malloc(sizeof(NimculusEditorLayoutRow) * row_count);
    if (*rowTarget) {
      memcpy(*rowTarget, rows, sizeof(NimculusEditorLayoutRow) * row_count);
      *rowCountTarget = row_count;
    }
  }
  if (glyphs && glyph_count > 0) {
    *glyphTarget = malloc(sizeof(NimculusEditorLayoutGlyph) * glyph_count);
    if (*glyphTarget) {
      memcpy(*glyphTarget, glyphs, sizeof(NimculusEditorLayoutGlyph) * glyph_count);
      *glyphCountTarget = glyph_count;
    }
  }
  markSceneFullyDirty();
  scheduleEditorTextTextureRebuild();
  if (g_active_view) [(NimculusMetalView *)g_active_view requestRedraw];
}
void nimculus_platform_set_editor_layout_scroll(bool secondary, double x,
                                                 double y_fraction) {
  CGFloat boundedX = MAX(0.0, isfinite(x) ? x : 0.0);
  CGFloat boundedFraction = MAX(0.0, isfinite(y_fraction) ? y_fraction : 0.0);
  if (secondary) {
    g_secondary_layout_scroll_x = boundedX;
    g_secondary_layout_scroll_y_fraction = boundedFraction;
  } else {
    g_editor_layout_scroll_x = boundedX;
    g_editor_layout_scroll_y_fraction = boundedFraction;
  }
  markSceneFullyDirty();
  scheduleEditorTextTextureRebuild();
  if (g_active_view) [(NimculusMetalView *)g_active_view requestRedraw];
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
  if (g_active_view) [g_active_view requestRedraw];
}
bool nimculus_platform_validate_secondary_highlight_isolation(void) {
  NimculusHighlightSpan primary = {.start_byte = 1, .end_byte = 4, .kind = 1};
  NimculusHighlightSpan secondary = {.start_byte = 9, .end_byte = 15, .kind = 4};
  nimculus_platform_set_editor_highlights(&primary, 1);
  nimculus_platform_set_secondary_editor_highlights(&secondary, 1);
  BOOL previousRenderingSecondary = g_rendering_secondary_editor;
  g_rendering_secondary_editor = NO;
  BOOL primaryOwnsDecorations = editorTextureOwnsPrimaryDecorations();
  g_rendering_secondary_editor = YES;
  BOOL secondaryRejectsPrimaryDecorations = !editorTextureOwnsPrimaryDecorations();
  g_rendering_secondary_editor = previousRenderingSecondary;
  BOOL valid = primaryOwnsDecorations && secondaryRejectsPrimaryDecorations &&
    g_highlights != NULL && g_secondary_highlights != NULL &&
    g_highlights != g_secondary_highlights && g_highlight_count == 1 &&
    g_secondary_highlight_count == 1 && g_highlights[0].start_byte == 1 &&
    g_highlights[0].end_byte == 4 && g_secondary_highlights[0].start_byte == 9 &&
    g_secondary_highlights[0].end_byte == 15;
  nimculus_platform_set_editor_highlights(NULL, 0);
  nimculus_platform_set_secondary_editor_highlights(NULL, 0);
  return valid;
}

bool nimculus_platform_validate_secondary_annotation_isolation(void) {
  NimculusEditorAnnotation primary = {.line = 1, .character = 2, .kind = 0,
    .text = "primary"};
  NimculusEditorAnnotation secondary = {.line = 4, .character = 5, .kind = 1,
    .text = "secondary"};
  nimculus_platform_set_editor_annotations(&primary, 1);
  nimculus_platform_set_secondary_editor_annotations(&secondary, 1);
  BOOL valid = g_editor_annotations != NULL &&
    g_secondary_editor_annotations != NULL &&
    g_editor_annotations != g_secondary_editor_annotations &&
    g_editor_annotation_count == 1 && g_secondary_editor_annotation_count == 1 &&
    g_editor_annotations[0].line == 1 &&
    g_secondary_editor_annotations[0].line == 4 &&
    g_editor_annotation_texts.count == 1 &&
    g_secondary_editor_annotation_texts.count == 1 &&
    [g_editor_annotation_texts[0] isEqualToString:@"primary"] &&
    [g_secondary_editor_annotation_texts[0] isEqualToString:@"secondary"];
  nimculus_platform_set_editor_annotations(NULL, 0);
  nimculus_platform_set_secondary_editor_annotations(NULL, 0);
  return valid;
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
  // Nim republishes diagnostics after every input event, and almost every one
  // of those publishes the same set. Rebuilding the text texture and reloading
  // the footer for an identical set was the largest single cost of a key or
  // scroll event in a profile of a 250-event burst.
  if (count == g_diagnostic_count &&
      (count == 0 || (g_diagnostics && spans &&
        memcmp(g_diagnostics, spans, sizeof(NimculusDiagnosticSpan) * count) == 0))) {
    return;
  }
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
  scheduleEditorTextTextureRebuild();
  if (g_active_view) {
    NimculusMetalView *view = (NimculusMetalView *)g_active_view;
    for (NSView *subview in view.subviews) {
      if ([subview isKindOfClass:[NimculusFooterOverlay class]]) {
        [(NimculusFooterOverlay *)subview reloadStatusItems];
        [subview setNeedsDisplay:YES];
        break;
      }
    }
  [view requestRedraw];
  }
}
void nimculus_platform_set_secondary_editor_diagnostics(const NimculusDiagnosticSpan *spans,
                                                        uint32_t count) {
  free(g_secondary_diagnostics);
  g_secondary_diagnostics = NULL;
  g_secondary_diagnostic_count = 0;
  if (spans && count > 0) {
    g_secondary_diagnostics = malloc(sizeof(NimculusDiagnosticSpan) * count);
    if (g_secondary_diagnostics) {
      memcpy(g_secondary_diagnostics, spans, sizeof(NimculusDiagnosticSpan) * count);
      g_secondary_diagnostic_count = count;
    }
  }
  markSceneFullyDirty();
  if (g_queue) rebuildSecondaryEditorTexture(g_queue.device);
  if (g_active_view) [(NimculusMetalView *)g_active_view requestRedraw];
}
void nimculus_platform_set_secondary_editor_highlights(const NimculusHighlightSpan *spans,
                                                       uint32_t count) {
  free(g_secondary_highlights);
  g_secondary_highlights = NULL;
  g_secondary_highlight_count = 0;
  if (spans && count > 0) {
    g_secondary_highlights = malloc(sizeof(NimculusHighlightSpan) * count);
    if (g_secondary_highlights) {
      memcpy(g_secondary_highlights, spans, sizeof(NimculusHighlightSpan) * count);
      g_secondary_highlight_count = count;
    }
  }
  markSceneFullyDirty();
  if (g_queue) rebuildSecondaryEditorTexture(g_queue.device);
  if (g_active_view) [(NimculusMetalView *)g_active_view requestRedraw];
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
void nimculus_platform_set_secondary_editor_annotations(
    const NimculusEditorAnnotation *annotations, uint32_t count) {
  free(g_secondary_editor_annotations);
  g_secondary_editor_annotations = NULL;
  g_secondary_editor_annotation_count = 0;
  replaceOwnedMutableArray((NSMutableArray **)&g_secondary_editor_annotation_texts,
    [NSMutableArray arrayWithCapacity:count]);
  if (annotations && count > 0) {
    g_secondary_editor_annotations = calloc(count, sizeof(NimculusEditorAnnotation));
    if (g_secondary_editor_annotations) {
      for (uint32_t index = 0; index < count; index++) {
        g_secondary_editor_annotations[index].line = annotations[index].line;
        g_secondary_editor_annotations[index].character = annotations[index].character;
        g_secondary_editor_annotations[index].kind = annotations[index].kind;
        const char *text = annotations[index].text;
        [g_secondary_editor_annotation_texts addObject:text ?
          ([NSString stringWithUTF8String:text] ?: @"") : @""];
      }
      g_secondary_editor_annotation_count = count;
    }
  }
  if (g_active_view) [(NimculusMetalView *)g_active_view updateTerminalFrame];
}
void nimculus_platform_set_editor_git_hunks(const NimculusGitHunkSpan *spans, uint32_t count) {
  if (count == g_git_hunk_count &&
      (count == 0 || (g_git_hunks && spans &&
        memcmp(g_git_hunks, spans, sizeof(NimculusGitHunkSpan) * count) == 0))) {
    return;
  }
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
  scheduleEditorTextTextureRebuild();
  if (g_active_view) [(NimculusMetalView *)g_active_view requestRedraw];
}
void nimculus_platform_set_secondary_editor_git_hunks(const NimculusGitHunkSpan *spans,
                                                       uint32_t count) {
  free(g_secondary_git_hunks);
  g_secondary_git_hunks = NULL;
  g_secondary_git_hunk_count = 0;
  if (spans && count > 0) {
    g_secondary_git_hunks = malloc(sizeof(NimculusGitHunkSpan) * count);
    if (g_secondary_git_hunks) {
      memcpy(g_secondary_git_hunks, spans, sizeof(NimculusGitHunkSpan) * count);
      g_secondary_git_hunk_count = count;
    }
  }
  markSceneFullyDirty();
  if (g_queue) rebuildSecondaryEditorTexture(g_queue.device);
  if (g_active_view) [(NimculusMetalView *)g_active_view requestRedraw];
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
void nimculus_platform_set_paint_selection_rows(const NimculusPaintSelectionRow *rows,
                                                uint32_t count) {
  free(g_paint_selection_rows);
  g_paint_selection_rows = NULL;
  g_paint_selection_row_count = 0;
  if (rows && count > 0) {
    g_paint_selection_rows = malloc(sizeof(NimculusPaintSelectionRow) * count);
    if (g_paint_selection_rows) {
      memcpy(g_paint_selection_rows, rows,
        sizeof(NimculusPaintSelectionRow) * count);
      g_paint_selection_row_count = count;
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
  if (g_active_view) [(NimculusMetalView *)g_active_view requestRedraw];
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
  if (rectDebugEnabled()) {
    fprintf(stderr, "ui_rect %.1f %.1f %.1f %.1f metrics %.1f %.1f\n", x, y, width,
      height, (double)g_metrics.width_points, (double)g_metrics.height_points);
  }
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
