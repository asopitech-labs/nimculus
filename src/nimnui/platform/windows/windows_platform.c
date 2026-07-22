#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#include <d2d1.h>
#include <dwrite.h>
#include <dwrite_2.h>
#include <dwrite_3.h>
#include <wincodec.h>
#include <dxgi.h>
#include <commdlg.h>
#include <imm.h>
#include <psapi.h>
#include <shellapi.h>
#include <stdint.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#include "../contracts.h"

static NimculusPlatformMetrics g_metrics = {1.0, 0, 0, 0, 0, 0.0, 0, 0.0};
static LARGE_INTEGER g_qpc_frequency = {0};
static LARGE_INTEGER g_first_input_qpc = {0};
static uint64_t g_input_count = 0;
static NimculusInputCallback g_input_callback = NULL;
static NimculusShortcutCallback g_shortcut_callback = NULL;
static NimculusTextCallback g_text_callback = NULL;
static NimculusIdleCallback g_idle_callback = NULL;
static NimculusCommandCallback g_command_callback = NULL;
typedef void (*NimculusFontCallback)(const char *name);
static NimculusFileCallback g_file_callback = NULL;
static NimculusFontCallback g_font_callback = NULL;
static const wchar_t *g_font_query = NULL;
static bool g_font_found = false;
static HWND g_window = NULL;
static ID3D11Device *g_device = NULL;
static ID3D11DeviceContext *g_context = NULL;
static IDXGISwapChain *g_swap_chain = NULL;
static ID3D11RenderTargetView *g_render_target = NULL;
static ID3D11VertexShader *g_quad_vertex_shader = NULL;
static ID3D11PixelShader *g_quad_pixel_shader = NULL;
static ID3D11PixelShader *g_image_pixel_shader = NULL;
static ID3D11PixelShader *g_glyph_pixel_shader = NULL;
static ID3D11InputLayout *g_quad_input_layout = NULL;
static ID3D11Buffer *g_quad_vertex_buffer = NULL;
static ID3D11RasterizerState *g_quad_rasterizer = NULL;
static ID3D11BlendState *g_quad_blend_state = NULL;
static ID3D11SamplerState *g_image_sampler = NULL;
static ID2D1Factory *g_d2d_factory = NULL;
static ID2D1RenderTarget *g_d2d_target = NULL;
static ID2D1SolidColorBrush *g_d2d_text_brush = NULL;
static IDWriteFactory *g_dwrite_factory = NULL;
static IDWriteFactory2 *g_dwrite_factory2 = NULL;
static IDWriteFactory4 *g_dwrite_factory4 = NULL;
static IWICImagingFactory *g_wic_factory = NULL;
static bool g_wic_com_initialized = false;
static IDWriteTextAnalyzer *g_dwrite_analyzer = NULL;
static IDWriteFontFallback *g_dwrite_font_fallback = NULL;
static IDWriteFontFace *g_glyph_font_face = NULL;
static wchar_t g_glyph_font_face_name[LF_FACESIZE];
static uint64_t g_glyph_raster_hit_count = 0;
static uint64_t g_glyph_raster_miss_count = 0;
static IDWriteTextFormat *g_editor_text_format = NULL;
static float g_editor_text_format_size = 0.0f;
static double g_editor_text_format_scale = 0.0;
static bool g_editor_text_format_wrap = false;
static bool g_directwrite_frame = false;
static NimculusPaintCommand *g_paint_commands = NULL;
static uint32_t g_paint_count = 0;
static char g_clipboard_utf8[4 * 1024 * 1024];
static wchar_t g_dialog_path[32768];
static char g_dialog_utf8[32768];
static wchar_t g_terminal_text[262144];
static char *g_terminal_utf8 = NULL;
static uint32_t g_terminal_utf8_length = 0;
static bool g_terminal_visible = false;
static wchar_t g_task_output_text[262144];
static bool g_task_output_visible = false;
static NimculusTerminalRun *g_terminal_runs = NULL;
static uint32_t g_terminal_run_count = 0;
static uint32_t g_terminal_selection_start_row = 0;
static uint32_t g_terminal_selection_start_column = 0;
static uint32_t g_terminal_selection_end_row = 0;
static uint32_t g_terminal_selection_end_column = 0;
static wchar_t *g_editor_text = NULL;
static int g_editor_text_length = 0;
static char *g_editor_utf8 = NULL;
static uint32_t g_editor_utf8_length = 0;
static wchar_t *g_editor_composition = NULL;
static int g_editor_composition_length = 0;
static NimculusHighlightSpan *g_editor_highlights = NULL;
static uint32_t g_editor_highlight_count = 0;
static wchar_t g_editor_font_name[LF_FACESIZE] = L"Consolas";
static double g_editor_font_size = 16.0;
static wchar_t g_terminal_font_name[LF_FACESIZE] = L"Consolas";
static double g_terminal_font_size = 16.0;
static uint32_t g_editor_scroll_line = 0;
static uint32_t g_editor_cursor_byte = 0;
static uint32_t g_editor_cursor_line = 0;
static uint32_t g_editor_selection_start = 0;
static uint32_t g_editor_selection_end = 0;
static bool g_editor_dirty = false;
static bool g_editor_indent_guides = true;
static uint32_t g_editor_indent_width = 2;
static bool g_editor_line_numbers = true;
static bool g_editor_soft_wrap = false;
static wchar_t g_editor_tabs[32768];
static int g_editor_tabs_length = 0;
static uint32_t g_editor_active_tab = 0;
static wchar_t g_editor_status[4096];
static int g_editor_status_length = 0;
static wchar_t g_ime_wide[32768];
static char g_ime_utf8[131072];
static wchar_t g_pending_high_surrogate = 0;
static double g_editor_cursor_x = 8.0;
static double g_editor_cursor_y = 20.0;
/* Logical NimNUI editor bounds. The renderer converts them to device pixels
 * at the same boundary as input coordinates and DPI metrics. */
static double g_editor_rect[4] = {268.0, 128.0, 908.0, 624.0};
static bool g_fullscreen = false;
static LONG_PTR g_saved_style = 0;
static LONG_PTR g_saved_ex_style = 0;
static RECT g_saved_window_rect;
static bool g_suppress_translate = false;
static bool g_tracking_mouse = false;
static bool g_close_request_pending = false;
static HWND g_palette_window = NULL;
static HWND g_palette_edit = NULL;
static WNDPROC g_palette_edit_original = NULL;
static char g_palette_command[131072];

#define NIMCULUS_MAX_GLYPH_RASTERS 1024
#define NIMCULUS_MAX_COLOR_GLYPHS 128
#define NIMCULUS_GLYPH_ATLAS_SIZE 2048
typedef struct NimculusGlyphRaster {
  bool valid;
  uint16_t glyph_id;
  IDWriteFontFace *font_face;
  float font_size;
  double scale;
  uint8_t subpixel_x;
  uint8_t subpixel_y;
  RECT bounds;
  uint32_t length;
  uint8_t *pixels;
  bool atlas_valid;
  uint32_t atlas_x;
  uint32_t atlas_y;
  uint32_t atlas_width;
  uint32_t atlas_height;
  uint64_t last_used;
} NimculusGlyphRaster;

static NimculusGlyphRaster g_glyph_rasters[NIMCULUS_MAX_GLYPH_RASTERS];
static uint64_t g_glyph_raster_clock = 0;
static ID3D11Texture2D *g_glyph_atlas_texture = NULL;
static ID3D11ShaderResourceView *g_glyph_atlas_view = NULL;
static uint32_t g_glyph_atlas_next_x = 0;
static uint32_t g_glyph_atlas_next_y = 0;
static uint32_t g_glyph_atlas_row_height = 0;
static uint64_t g_glyph_atlas_upload_count = 0;

typedef struct NimculusColorGlyphRaster {
  bool valid;
  uint16_t glyph_id;
  IDWriteFontFace *font_face;
  float font_size;
  double scale;
  uint8_t subpixel_x;
  uint8_t subpixel_y;
  RECT bounds;
  uint32_t length;
  uint8_t *pixels;
  bool atlas_valid;
  uint32_t atlas_x;
  uint32_t atlas_y;
  uint32_t atlas_width;
  uint32_t atlas_height;
  uint64_t last_used;
} NimculusColorGlyphRaster;

static NimculusColorGlyphRaster g_color_glyphs[NIMCULUS_MAX_COLOR_GLYPHS];
static ID3D11Texture2D *g_color_glyph_atlas_texture = NULL;
static ID3D11ShaderResourceView *g_color_glyph_atlas_view = NULL;
static uint32_t g_color_glyph_atlas_next_x = 0;
static uint32_t g_color_glyph_atlas_next_y = 0;
static uint32_t g_color_glyph_atlas_row_height = 0;

static LRESULT CALLBACK palette_edit_proc(HWND window, UINT message,
                                          WPARAM wparam, LPARAM lparam);

static void close_command_palette(void) {
  if (g_palette_window) DestroyWindow(g_palette_window);
}

static void submit_command_palette(void) {
  if (!g_palette_edit || !g_command_callback) return;
  wchar_t value[32768];
  int wide_length = GetWindowTextW(g_palette_edit, value,
                                   (int)(sizeof(value) / sizeof(value[0])));
  if (wide_length <= 0) {
    close_command_palette();
    return;
  }
  const char prefix[] = "commandPalette:";
  size_t prefix_length = sizeof(prefix) - 1;
  if (prefix_length >= sizeof(g_palette_command)) return;
  int utf8_length = WideCharToMultiByte(CP_UTF8, 0, value, wide_length,
      g_palette_command + prefix_length,
      (int)(sizeof(g_palette_command) - prefix_length - 1), NULL, NULL);
  if (utf8_length <= 0) return;
  if ((size_t)utf8_length + prefix_length >= sizeof(g_palette_command)) return;
  memcpy(g_palette_command, prefix, prefix_length);
  g_palette_command[prefix_length + (size_t)utf8_length] = '\0';
  close_command_palette();
  g_command_callback(g_palette_command);
}

static LRESULT CALLBACK palette_edit_proc(HWND window, UINT message,
                                          WPARAM wparam, LPARAM lparam) {
  if (message == WM_KEYDOWN) {
    if (wparam == VK_RETURN) {
      submit_command_palette();
      return 0;
    }
    if (wparam == VK_ESCAPE) {
      close_command_palette();
      return 0;
    }
  }
  return g_palette_edit_original
      ? CallWindowProcW(g_palette_edit_original, window, message, wparam, lparam)
      : DefWindowProcW(window, message, wparam, lparam);
}

static LRESULT CALLBACK palette_window_proc(HWND window, UINT message,
                                            WPARAM wparam, LPARAM lparam) {
  switch (message) {
    case WM_CREATE: {
      HFONT font = (HFONT)GetStockObject(DEFAULT_GUI_FONT);
      CreateWindowExW(0, L"STATIC", L"Command palette — type a command and press Enter",
          WS_CHILD | WS_VISIBLE, 12, 10, 450, 22, window, NULL,
          GetModuleHandleW(NULL), NULL);
      g_palette_edit = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"",
          WS_CHILD | WS_VISIBLE | WS_TABSTOP | ES_AUTOHSCROLL,
          12, 36, 450, 28, window, (HMENU)1, GetModuleHandleW(NULL), NULL);
      if (g_palette_edit) {
        SendMessageW(g_palette_edit, WM_SETFONT, (WPARAM)font, TRUE);
        g_palette_edit_original = (WNDPROC)SetWindowLongPtrW(g_palette_edit,
            GWLP_WNDPROC, (LONG_PTR)palette_edit_proc);
        SetFocus(g_palette_edit);
      }
      return 0;
    }
    case WM_CLOSE:
      DestroyWindow(window);
      return 0;
    case WM_DESTROY:
      g_palette_edit = NULL;
      g_palette_edit_original = NULL;
      g_palette_window = NULL;
      return 0;
    default:
      return DefWindowProcW(window, message, wparam, lparam);
  }
}

void nimculus_platform_show_command_palette(void) {
  if (!g_window || g_palette_window) {
    if (g_palette_window) SetFocus(g_palette_edit);
    return;
  }
  HINSTANCE instance = GetModuleHandleW(NULL);
  const wchar_t class_name[] = L"NimculusCommandPalette";
  WNDCLASSEXW klass;
  ZeroMemory(&klass, sizeof(klass));
  klass.cbSize = sizeof(klass);
  klass.hInstance = instance;
  klass.lpfnWndProc = palette_window_proc;
  klass.hCursor = LoadCursor(NULL, IDC_ARROW);
  klass.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
  klass.lpszClassName = class_name;
  if (!RegisterClassExW(&klass) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return;
  RECT owner;
  GetWindowRect(g_window, &owner);
  const int width = 476;
  const int height = 82;
  int x = owner.left + ((owner.right - owner.left) - width) / 2;
  int y = owner.top + ((owner.bottom - owner.top) - height) / 3;
  g_palette_window = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_TOPMOST,
      class_name, L"Nimculus Command Palette", WS_POPUP | WS_CAPTION | WS_SYSMENU,
      x, y, width, height, g_window, NULL, instance, NULL);
  if (!g_palette_window) return;
  ShowWindow(g_palette_window, SW_SHOW);
  UpdateWindow(g_palette_window);
}

typedef struct NimculusImage {
  uint32_t id;
  uint32_t width;
  uint32_t height;
  uint8_t *rgba;
  ID3D11ShaderResourceView *view;
} NimculusImage;

#define NIMCULUS_MAX_IMAGES 64
static NimculusImage g_images[NIMCULUS_MAX_IMAGES];

static LONG font_height(double size, double scale) {
  double points = size > 0.0 ? size : 16.0;
  return -(LONG)(points * (scale > 0.0 ? scale : 1.0));
}

static void editor_byte_position(uint32_t byte_offset, uint32_t *line,
                                 uint32_t *column) {
  uint32_t current_line = 0;
  uint32_t current_column = 0;
  uint32_t limit = byte_offset < g_editor_utf8_length
      ? byte_offset : g_editor_utf8_length;
  for (uint32_t index = 0; index < limit; ++index) {
    unsigned char value = (unsigned char)g_editor_utf8[index];
    if (value == '\n') {
      current_line++;
      current_column = 0;
    } else if ((value & 0xc0) != 0x80) {
      current_column++;
    }
  }
  if (line) *line = current_line;
  if (column) *column = current_column;
}

static uint32_t editor_line_length(uint32_t target_line) {
  uint32_t line = 0;
  uint32_t length = 0;
  for (uint32_t index = 0; index < g_editor_utf8_length; ++index) {
    unsigned char value = (unsigned char)g_editor_utf8[index];
    if (value == '\n') {
      if (line == target_line) return length;
      line++;
      length = 0;
    } else if ((value & 0xc0) != 0x80) {
      length++;
    }
  }
  return line == target_line ? length : 0;
}

/* NimNUI key bindings use the existing AppKit hardware-key code contract.
 * Win32 virtual-key values are semantic (and differ from those codes), so
 * translate the stable US keyboard positions at the platform boundary. Text
 * input still comes from WM_CHAR/IMM32 and therefore remains layout-aware. */
static UINT canonical_key_code(UINT key_code) {
  static const UINT letters[26] = {
    0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46,
    45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6
  };
  if (key_code >= 'A' && key_code <= 'Z') return letters[key_code - 'A'];
  switch (key_code) {
    case '0': return 29; case '1': return 18; case '2': return 19;
    case '3': return 20; case '4': return 21; case '5': return 23;
    case '6': return 22; case '7': return 26; case '8': return 28;
    case '9': return 25;
    case VK_RETURN: return 36; case VK_TAB: return 48;
    case VK_ESCAPE: return 53; case VK_SPACE: return 49;
    case VK_BACK: return 51; case VK_DELETE: return 117;
    case VK_LEFT: return 123; case VK_RIGHT: return 124;
    case VK_DOWN: return 125; case VK_UP: return 126;
    case VK_HOME: return 115; case VK_END: return 119;
    case VK_PRIOR: return 116; case VK_NEXT: return 121;
    case VK_F1: return 122; case VK_F2: return 120; case VK_F3: return 99;
    case VK_F4: return 118; case VK_F5: return 96; case VK_F6: return 97;
    case VK_F7: return 98; case VK_F8: return 100; case VK_F9: return 101;
    case VK_F10: return 109; case VK_F11: return 103; case VK_F12: return 111;
    case VK_OEM_COMMA: return 43; case VK_OEM_PERIOD: return 47;
    case VK_OEM_2: return 44; case VK_OEM_1: return 41;
    case VK_OEM_7: return 39; case VK_OEM_4: return 33;
    case VK_OEM_6: return 30; case VK_OEM_5: return 42;
    case VK_OEM_MINUS: return 27; case VK_OEM_PLUS: return 24;
    case VK_OEM_3: return 50;
    default: return key_code;
  }
}

static int CALLBACK enumerate_font_proc(const LOGFONTW *font, const TEXTMETRICW *metrics,
                                       DWORD font_type, LPARAM data) {
  (void)metrics;
  (void)font_type;
  (void)data;
  if (!font) return 0;
  if (g_font_callback) {
    char name[LF_FACESIZE * 4] = {0};
    int length = WideCharToMultiByte(CP_UTF8, 0, font->lfFaceName, -1,
        name, (int)sizeof(name), NULL, NULL);
    if (length > 0) g_font_callback(name);
  }
  if (g_font_query && _wcsicmp(font->lfFaceName, g_font_query) == 0) {
    g_font_found = true;
    return 0;
  }
  return 1;
}

bool nimculus_font_available(const char *name, double size) {
  (void)size;
  if (!name || name[0] == '\0') return false;
  static wchar_t query[LF_FACESIZE];
  int length = MultiByteToWideChar(CP_UTF8, 0, name, -1, query, LF_FACESIZE);
  if (length <= 0) return false;
  g_font_query = query;
  g_font_found = false;
  LOGFONTW logfont;
  ZeroMemory(&logfont, sizeof(logfont));
  logfont.lfCharSet = DEFAULT_CHARSET;
  EnumFontFamiliesExW(NULL, &logfont, enumerate_font_proc, 0, 0);
  g_font_query = NULL;
  return g_font_found;
}

void nimculus_enumerate_fonts(NimculusFontCallback callback) {
  g_font_callback = callback;
  LOGFONTW logfont;
  ZeroMemory(&logfont, sizeof(logfont));
  logfont.lfCharSet = DEFAULT_CHARSET;
  EnumFontFamiliesExW(NULL, &logfont, enumerate_font_proc, 0, 0);
  g_font_callback = NULL;
}

static void emit_dropped_path(const wchar_t *path) {
  if (!path || !g_file_callback) return;
  int length = WideCharToMultiByte(CP_UTF8, 0, path, -1,
      g_dialog_utf8, (int)sizeof(g_dialog_utf8), NULL, NULL);
  if (length > 1) {
    g_dialog_utf8[length - 1] = '\0';
    g_file_callback(g_dialog_utf8, false);
  }
}

static void update_ime_position(void) {
  if (!g_window) return;
  HIMC context = ImmGetContext(g_window);
  if (!context) return;
  UINT dpi = GetDpiForWindow(g_window);
  if (dpi == 0) dpi = USER_DEFAULT_SCREEN_DPI;
  POINT point;
  point.x = (LONG)(g_editor_cursor_x * (double)dpi / (double)USER_DEFAULT_SCREEN_DPI);
  point.y = (LONG)(g_editor_cursor_y * (double)dpi / (double)USER_DEFAULT_SCREEN_DPI);

  COMPOSITIONFORM composition;
  ZeroMemory(&composition, sizeof(composition));
  composition.dwStyle = CFS_POINT;
  composition.ptCurrentPos = point;
  ImmSetCompositionWindow(context, &composition);

  CANDIDATEFORM candidate;
  ZeroMemory(&candidate, sizeof(candidate));
  candidate.dwIndex = 0;
  candidate.dwStyle = CFS_CANDIDATEPOS;
  candidate.ptCurrentPos = point;
  ImmSetCandidateWindow(context, &candidate);
  ImmReleaseContext(g_window, context);
}

static void emit_ime_string(HIMC context, DWORD kind, bool composing) {
  LONG bytes = ImmGetCompositionStringW(context, kind, NULL, 0);
  if (bytes < 0) return;
  if (bytes == 0) {
    if (composing && g_text_callback) g_text_callback("", true);
    return;
  }
  if (bytes > (LONG)(sizeof(g_ime_wide) - sizeof(wchar_t))) {
    bytes = (LONG)(sizeof(g_ime_wide) - sizeof(wchar_t));
  }
  LONG copied = ImmGetCompositionStringW(context, kind, g_ime_wide, (DWORD)bytes);
  if (copied <= 0) return;
  int wide_chars = (int)(copied / (LONG)sizeof(wchar_t));
  int utf8_length = WideCharToMultiByte(CP_UTF8, 0, g_ime_wide, wide_chars,
      g_ime_utf8, (int)sizeof(g_ime_utf8) - 1, NULL, NULL);
  if (utf8_length <= 0 || !g_text_callback) return;
  g_ime_utf8[utf8_length] = '\0';
  g_text_callback(g_ime_utf8, composing);
}

static void emit_utf16_text(const wchar_t *wide, int wide_chars) {
  if (!wide || wide_chars <= 0 || !g_text_callback) return;
  int utf8_length = WideCharToMultiByte(CP_UTF8, 0, wide, wide_chars,
      g_ime_utf8, (int)sizeof(g_ime_utf8) - 1, NULL, NULL);
  if (utf8_length <= 0) return;
  g_ime_utf8[utf8_length] = '\0';
  g_text_callback(g_ime_utf8, false);
}

static void update_metrics(void) {
  if (!g_window) return;
  RECT rect;
  GetClientRect(g_window, &rect);
  g_metrics.width_pixels = (uint32_t)(rect.right - rect.left);
  g_metrics.height_pixels = (uint32_t)(rect.bottom - rect.top);
  UINT dpi = GetDpiForWindow(g_window);
  if (dpi == 0) dpi = USER_DEFAULT_SCREEN_DPI;
  g_metrics.scale_factor = (double)dpi / (double)USER_DEFAULT_SCREEN_DPI;
  g_metrics.width_points = (uint32_t)((double)g_metrics.width_pixels / g_metrics.scale_factor);
  g_metrics.height_points = (uint32_t)((double)g_metrics.height_pixels / g_metrics.scale_factor);
}

static void resize_render_target(void);
static void release_device(void);
static bool create_device(void);

typedef struct NimculusQuadVertex {
  float x;
  float y;
  float r;
  float g;
  float b;
  float a;
  float local_x;
  float local_y;
  float size_x;
  float size_y;
  float radius;
  float kind;
} NimculusQuadVertex;

static const char g_quad_vertex_source[] =
  "struct VSInput { float2 position : POSITION; float4 color : COLOR; "
  "float2 local : LOCAL; float2 size : SIZE; float radius : RADIUS; float kind : KIND; };"
  "struct VSOutput { float4 position : SV_POSITION; float4 color : COLOR; "
  "float2 local : LOCAL; float2 size : SIZE; float radius : RADIUS; float kind : KIND; };"
  "VSOutput main(VSInput input) { VSOutput output;"
  "output.position = float4(input.position, 0.0, 1.0); output.color = input.color;"
  "output.local = input.local; output.size = input.size; output.radius = input.radius;"
  "output.kind = input.kind; return output; }";

static const char g_quad_pixel_source[] =
  "struct PSInput { float4 position : SV_POSITION; float4 color : COLOR; "
  "float2 local : LOCAL; float2 size : SIZE; float radius : RADIUS; float kind : KIND; };"
  "float rounded_sdf(float2 point, float2 half_size, float radius) {"
  "float2 q = abs(point) - (half_size - radius);"
  "return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius; }"
  "float4 main(PSInput input) : SV_TARGET {"
  "float2 point = input.local * input.size - input.size * 0.5;"
  "float alpha = 1.0;"
  "if (input.kind > 1.5 && input.kind < 2.5) {"
  "float radius = min(input.radius, min(input.size.x, input.size.y) * 0.5);"
  "float distance = rounded_sdf(point, input.size * 0.5, radius);"
  "alpha = 1.0 - smoothstep(-1.0, 1.0, distance);"
  "} else if (input.kind > 0.5 && input.kind < 1.5) {"
  "float2 edge = min(input.local * input.size, (1.0 - input.local) * input.size);"
  "alpha = 1.0 - smoothstep(0.0, 1.5, min(edge.x, edge.y));"
  "} else if (input.kind > 6.5 && input.kind < 7.5) {"
  "alpha = 0.30; }"
  "return float4(input.color.rgb, input.color.a * alpha); }";

static const char g_image_pixel_source[] =
  "struct PSInput { float4 position : SV_POSITION; float4 color : COLOR; "
  "float2 local : LOCAL; float2 size : SIZE; float radius : RADIUS; float kind : KIND; };"
  "Texture2D imageTexture : register(t0);"
  "SamplerState imageSampler : register(s0);"
  "float4 main(PSInput input) : SV_TARGET {"
  "return imageTexture.Sample(imageSampler, input.local) * input.color; }";

static const char g_glyph_pixel_source[] =
  "struct PSInput { float4 position : SV_POSITION; float4 color : COLOR;"
  " float2 local : LOCAL; float2 size : SIZE; float radius : RADIUS; float kind : KIND; };"
  "Texture2D glyphAtlas : register(t0);"
  "SamplerState glyphSampler : register(s0);"
  "float4 main(PSInput input) : SV_TARGET {"
  " float alpha = glyphAtlas.Sample(glyphSampler, input.local).r;"
  " return float4(input.color.rgb, input.color.a * alpha); }";

static void release_quad_pipeline(void) {
  if (g_quad_blend_state) g_quad_blend_state->lpVtbl->Release(g_quad_blend_state);
  if (g_quad_rasterizer) g_quad_rasterizer->lpVtbl->Release(g_quad_rasterizer);
  if (g_quad_vertex_buffer) g_quad_vertex_buffer->lpVtbl->Release(g_quad_vertex_buffer);
  if (g_quad_input_layout) g_quad_input_layout->lpVtbl->Release(g_quad_input_layout);
  if (g_quad_pixel_shader) g_quad_pixel_shader->lpVtbl->Release(g_quad_pixel_shader);
  if (g_image_pixel_shader) g_image_pixel_shader->lpVtbl->Release(g_image_pixel_shader);
  if (g_glyph_pixel_shader) g_glyph_pixel_shader->lpVtbl->Release(g_glyph_pixel_shader);
  if (g_quad_vertex_shader) g_quad_vertex_shader->lpVtbl->Release(g_quad_vertex_shader);
  if (g_image_sampler) g_image_sampler->lpVtbl->Release(g_image_sampler);
  g_quad_rasterizer = NULL;
  g_quad_vertex_buffer = NULL;
  g_quad_input_layout = NULL;
  g_quad_blend_state = NULL;
  g_quad_pixel_shader = NULL;
  g_image_pixel_shader = NULL;
  g_glyph_pixel_shader = NULL;
  g_image_sampler = NULL;
  g_quad_vertex_shader = NULL;
}

static bool create_quad_pipeline(void) {
  ID3DBlob *vertex_blob = NULL;
  ID3DBlob *pixel_blob = NULL;
  ID3DBlob *image_pixel_blob = NULL;
  ID3DBlob *glyph_pixel_blob = NULL;
  ID3DBlob *errors = NULL;
  HRESULT hr = D3DCompile(g_quad_vertex_source, sizeof(g_quad_vertex_source) - 1,
      "nimculus_quad_vs", NULL, NULL, "main", "vs_4_0", 0, 0, &vertex_blob, &errors);
  if (errors) errors->lpVtbl->Release(errors);
  if (FAILED(hr)) return false;
  hr = D3DCompile(g_quad_pixel_source, sizeof(g_quad_pixel_source) - 1,
      "nimculus_quad_ps", NULL, NULL, "main", "ps_4_0", 0, 0, &pixel_blob, &errors);
  if (errors) errors->lpVtbl->Release(errors);
  if (FAILED(hr)) {
    vertex_blob->lpVtbl->Release(vertex_blob);
    return false;
  }
  hr = D3DCompile(g_image_pixel_source, sizeof(g_image_pixel_source) - 1,
      "nimculus_image_ps", NULL, NULL, "main", "ps_4_0", 0, 0,
      &image_pixel_blob, &errors);
  if (errors) errors->lpVtbl->Release(errors);
  if (FAILED(hr)) {
    vertex_blob->lpVtbl->Release(vertex_blob);
    pixel_blob->lpVtbl->Release(pixel_blob);
    return false;
  }
  hr = D3DCompile(g_glyph_pixel_source, sizeof(g_glyph_pixel_source) - 1,
      "nimculus_glyph_ps", NULL, NULL, "main", "ps_4_0", 0, 0,
      &glyph_pixel_blob, &errors);
  if (errors) errors->lpVtbl->Release(errors);
  if (FAILED(hr)) {
    vertex_blob->lpVtbl->Release(vertex_blob);
    pixel_blob->lpVtbl->Release(pixel_blob);
    image_pixel_blob->lpVtbl->Release(image_pixel_blob);
    return false;
  }
  hr = g_device->lpVtbl->CreateVertexShader(g_device, vertex_blob->lpVtbl->GetBufferPointer(vertex_blob),
      vertex_blob->lpVtbl->GetBufferSize(vertex_blob), NULL, &g_quad_vertex_shader);
  if (SUCCEEDED(hr)) {
    hr = g_device->lpVtbl->CreatePixelShader(g_device, pixel_blob->lpVtbl->GetBufferPointer(pixel_blob),
        pixel_blob->lpVtbl->GetBufferSize(pixel_blob), NULL, &g_quad_pixel_shader);
  }
  if (SUCCEEDED(hr)) {
    hr = g_device->lpVtbl->CreatePixelShader(g_device,
        image_pixel_blob->lpVtbl->GetBufferPointer(image_pixel_blob),
        image_pixel_blob->lpVtbl->GetBufferSize(image_pixel_blob), NULL,
        &g_image_pixel_shader);
  }
  if (SUCCEEDED(hr)) {
    hr = g_device->lpVtbl->CreatePixelShader(g_device,
        glyph_pixel_blob->lpVtbl->GetBufferPointer(glyph_pixel_blob),
        glyph_pixel_blob->lpVtbl->GetBufferSize(glyph_pixel_blob), NULL,
        &g_glyph_pixel_shader);
  }
  D3D11_INPUT_ELEMENT_DESC elements[6] = {
    {"POSITION", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 0, D3D11_INPUT_PER_VERTEX_DATA, 0},
    {"COLOR", 0, DXGI_FORMAT_R32G32B32A32_FLOAT, 0, 8, D3D11_INPUT_PER_VERTEX_DATA, 0},
    {"LOCAL", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 24, D3D11_INPUT_PER_VERTEX_DATA, 0},
    {"SIZE", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 32, D3D11_INPUT_PER_VERTEX_DATA, 0},
    {"RADIUS", 0, DXGI_FORMAT_R32_FLOAT, 0, 40, D3D11_INPUT_PER_VERTEX_DATA, 0},
    {"KIND", 0, DXGI_FORMAT_R32_FLOAT, 0, 44, D3D11_INPUT_PER_VERTEX_DATA, 0}
  };
  if (SUCCEEDED(hr)) {
    hr = g_device->lpVtbl->CreateInputLayout(g_device, elements, 6,
        vertex_blob->lpVtbl->GetBufferPointer(vertex_blob),
        vertex_blob->lpVtbl->GetBufferSize(vertex_blob), &g_quad_input_layout);
  }
  vertex_blob->lpVtbl->Release(vertex_blob);
  pixel_blob->lpVtbl->Release(pixel_blob);
  image_pixel_blob->lpVtbl->Release(image_pixel_blob);
  glyph_pixel_blob->lpVtbl->Release(glyph_pixel_blob);
  if (FAILED(hr)) {
    release_quad_pipeline();
    return false;
  }

  D3D11_BUFFER_DESC buffer_desc;
  ZeroMemory(&buffer_desc, sizeof(buffer_desc));
  buffer_desc.ByteWidth = sizeof(NimculusQuadVertex) * 6;
  buffer_desc.Usage = D3D11_USAGE_DYNAMIC;
  buffer_desc.BindFlags = D3D11_BIND_VERTEX_BUFFER;
  buffer_desc.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
  hr = g_device->lpVtbl->CreateBuffer(g_device, &buffer_desc, NULL, &g_quad_vertex_buffer);

  D3D11_RASTERIZER_DESC rasterizer_desc;
  ZeroMemory(&rasterizer_desc, sizeof(rasterizer_desc));
  rasterizer_desc.FillMode = D3D11_FILL_SOLID;
  rasterizer_desc.CullMode = D3D11_CULL_NONE;
  rasterizer_desc.ScissorEnable = TRUE;
  if (SUCCEEDED(hr)) {
    hr = g_device->lpVtbl->CreateRasterizerState(g_device, &rasterizer_desc,
        &g_quad_rasterizer);
  }
  D3D11_BLEND_DESC blend_desc;
  ZeroMemory(&blend_desc, sizeof(blend_desc));
  blend_desc.RenderTarget[0].BlendEnable = TRUE;
  blend_desc.RenderTarget[0].SrcBlend = D3D11_BLEND_SRC_ALPHA;
  blend_desc.RenderTarget[0].DestBlend = D3D11_BLEND_INV_SRC_ALPHA;
  blend_desc.RenderTarget[0].BlendOp = D3D11_BLEND_OP_ADD;
  blend_desc.RenderTarget[0].SrcBlendAlpha = D3D11_BLEND_ONE;
  blend_desc.RenderTarget[0].DestBlendAlpha = D3D11_BLEND_INV_SRC_ALPHA;
  blend_desc.RenderTarget[0].BlendOpAlpha = D3D11_BLEND_OP_ADD;
  blend_desc.RenderTarget[0].RenderTargetWriteMask = D3D11_COLOR_WRITE_ENABLE_ALL;
  if (SUCCEEDED(hr)) {
    hr = g_device->lpVtbl->CreateBlendState(g_device, &blend_desc,
        &g_quad_blend_state);
  }
  D3D11_SAMPLER_DESC sampler_desc;
  ZeroMemory(&sampler_desc, sizeof(sampler_desc));
  sampler_desc.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
  sampler_desc.AddressU = D3D11_TEXTURE_ADDRESS_CLAMP;
  sampler_desc.AddressV = D3D11_TEXTURE_ADDRESS_CLAMP;
  sampler_desc.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
  sampler_desc.ComparisonFunc = D3D11_COMPARISON_ALWAYS;
  sampler_desc.MaxLOD = D3D11_FLOAT32_MAX;
  if (SUCCEEDED(hr)) {
    hr = g_device->lpVtbl->CreateSamplerState(g_device, &sampler_desc,
        &g_image_sampler);
  }
  if (FAILED(hr)) {
    release_quad_pipeline();
    return false;
  }
  return true;
}

static void set_fullscreen(bool enabled) {
  if (!g_window || enabled == g_fullscreen) return;
  if (enabled) {
    g_saved_style = GetWindowLongPtrW(g_window, GWL_STYLE);
    g_saved_ex_style = GetWindowLongPtrW(g_window, GWL_EXSTYLE);
    GetWindowRect(g_window, &g_saved_window_rect);
    MONITORINFO monitor = {0};
    monitor.cbSize = sizeof(monitor);
    HMONITOR display = MonitorFromWindow(g_window, MONITOR_DEFAULTTONEAREST);
    if (!GetMonitorInfoW(display, &monitor)) return;
    SetWindowLongPtrW(g_window, GWL_STYLE, WS_POPUP | WS_VISIBLE);
    SetWindowLongPtrW(g_window, GWL_EXSTYLE, g_saved_ex_style);
    SetWindowPos(g_window, HWND_TOP, monitor.rcMonitor.left, monitor.rcMonitor.top,
                 monitor.rcMonitor.right - monitor.rcMonitor.left,
                 monitor.rcMonitor.bottom - monitor.rcMonitor.top,
                 SWP_FRAMECHANGED | SWP_NOOWNERZORDER | SWP_SHOWWINDOW);
    g_fullscreen = true;
  } else {
    SetWindowLongPtrW(g_window, GWL_STYLE, g_saved_style);
    SetWindowLongPtrW(g_window, GWL_EXSTYLE, g_saved_ex_style);
    SetWindowPos(g_window, HWND_NOTOPMOST, g_saved_window_rect.left,
                 g_saved_window_rect.top,
                 g_saved_window_rect.right - g_saved_window_rect.left,
                 g_saved_window_rect.bottom - g_saved_window_rect.top,
                 SWP_FRAMECHANGED | SWP_NOOWNERZORDER | SWP_SHOWWINDOW);
    g_fullscreen = false;
  }
  update_metrics();
  resize_render_target();
  InvalidateRect(g_window, NULL, FALSE);
}

static void release_render_target(void) {
  if (g_render_target) {
    g_render_target->lpVtbl->Release(g_render_target);
    g_render_target = NULL;
  }
}

static void release_directwrite_target(void) {
  if (g_d2d_text_brush) {
    g_d2d_text_brush->lpVtbl->Release(g_d2d_text_brush);
    g_d2d_text_brush = NULL;
  }
  if (g_d2d_target) {
    g_d2d_target->lpVtbl->Release(g_d2d_target);
    g_d2d_target = NULL;
  }
}

static bool create_directwrite_target(void) {
  if (!g_swap_chain) return false;
  if (!g_d2d_factory) {
    D2D1_FACTORY_OPTIONS options;
    ZeroMemory(&options, sizeof(options));
    HRESULT hr = D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED,
        &IID_ID2D1Factory, &options, (void **)&g_d2d_factory);
    if (FAILED(hr)) return false;
  }
  IDXGISurface *surface = NULL;
  HRESULT hr = g_swap_chain->lpVtbl->GetBuffer(g_swap_chain, 0,
      &IID_IDXGISurface, (void **)&surface);
  if (FAILED(hr)) return false;
  D2D1_RENDER_TARGET_PROPERTIES properties;
  ZeroMemory(&properties, sizeof(properties));
  properties.type = D2D1_RENDER_TARGET_TYPE_DEFAULT;
  properties.pixelFormat.format = DXGI_FORMAT_B8G8R8A8_UNORM;
  properties.pixelFormat.alphaMode = D2D1_ALPHA_MODE_PREMULTIPLIED;
  properties.dpiX = 96.0f;
  properties.dpiY = 96.0f;
  properties.usage = D2D1_RENDER_TARGET_USAGE_NONE;
  properties.minLevel = D2D1_FEATURE_LEVEL_DEFAULT;
  release_directwrite_target();
  hr = g_d2d_factory->lpVtbl->CreateDxgiSurfaceRenderTarget(
      g_d2d_factory, surface, &properties, &g_d2d_target);
  surface->lpVtbl->Release(surface);
  if (FAILED(hr)) return false;
  D2D1_COLOR_F color = {0.84f, 0.86f, 0.90f, 1.0f};
  hr = g_d2d_target->lpVtbl->CreateSolidColorBrush(g_d2d_target, &color,
      NULL, &g_d2d_text_brush);
  if (FAILED(hr)) {
    release_directwrite_target();
    return false;
  }
  return true;
}

static bool ensure_directwrite_factory(void) {
  if (g_dwrite_factory && g_dwrite_factory2 && g_dwrite_analyzer) return true;
  HRESULT hr = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED,
      &IID_IDWriteFactory, (IUnknown **)&g_dwrite_factory);
  if (FAILED(hr) || !g_dwrite_factory) return false;
  hr = g_dwrite_factory->lpVtbl->QueryInterface((IUnknown *)g_dwrite_factory,
      &IID_IDWriteFactory2, (void **)&g_dwrite_factory2);
  if (FAILED(hr) || !g_dwrite_factory2) {
    if (g_dwrite_factory) {
      g_dwrite_factory->lpVtbl->Release(g_dwrite_factory);
      g_dwrite_factory = NULL;
    }
    return false;
  }
  /* Factory4 is optional: Windows 8.1/older SDK environments still have a
   * valid Factory2 COLR path.  Keep the newer image-format path additive. */
  g_dwrite_factory->lpVtbl->QueryInterface((IUnknown *)g_dwrite_factory,
      &IID_IDWriteFactory4, (void **)&g_dwrite_factory4);
  hr = g_dwrite_factory->lpVtbl->CreateTextAnalyzer(g_dwrite_factory,
      &g_dwrite_analyzer);
  if (FAILED(hr) || !g_dwrite_analyzer) {
    if (g_dwrite_factory4) {
      g_dwrite_factory4->lpVtbl->Release(g_dwrite_factory4);
      g_dwrite_factory4 = NULL;
    }
    if (g_dwrite_factory2) {
      g_dwrite_factory2->lpVtbl->Release(g_dwrite_factory2);
      g_dwrite_factory2 = NULL;
    }
    if (g_dwrite_factory) {
      g_dwrite_factory->lpVtbl->Release(g_dwrite_factory);
      g_dwrite_factory = NULL;
    }
    return false;
  }
  hr = g_dwrite_factory2->lpVtbl->GetSystemFontFallback(
      g_dwrite_factory2, &g_dwrite_font_fallback);
  if (FAILED(hr) || !g_dwrite_font_fallback) {
    g_dwrite_analyzer->lpVtbl->Release(g_dwrite_analyzer);
    g_dwrite_analyzer = NULL;
    if (g_dwrite_factory4) {
      g_dwrite_factory4->lpVtbl->Release(g_dwrite_factory4);
      g_dwrite_factory4 = NULL;
    }
    g_dwrite_factory2->lpVtbl->Release(g_dwrite_factory2);
    g_dwrite_factory2 = NULL;
    g_dwrite_factory->lpVtbl->Release(g_dwrite_factory);
    g_dwrite_factory = NULL;
    return false;
  }
  return true;
}

static bool ensure_wic_factory(void) {
  if (g_wic_factory) return true;
  HRESULT hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
  if (SUCCEEDED(hr) || hr == RPC_E_CHANGED_MODE) {
    g_wic_com_initialized = SUCCEEDED(hr);
  } else if (FAILED(hr)) {
    return false;
  }
  hr = CoCreateInstance(&CLSID_WICImagingFactory, NULL,
      CLSCTX_INPROC_SERVER, &IID_IWICImagingFactory,
      (void **)&g_wic_factory);
  if (FAILED(hr) || !g_wic_factory) {
    g_wic_factory = NULL;
    if (g_wic_com_initialized) {
      CoUninitialize();
      g_wic_com_initialized = false;
    }
    return false;
  }
  return true;
}

static bool decode_wic_rgba(const void *encoded, uint32_t encoded_length,
                            uint32_t target_width, uint32_t target_height,
                            uint32_t *width, uint32_t *height,
                            uint8_t **pixels) {
  if (!encoded || encoded_length == 0 || !width || !height || !pixels ||
      !ensure_wic_factory()) return false;
  *width = 0;
  *height = 0;
  *pixels = NULL;
  IWICStream *stream = NULL;
  IWICBitmapDecoder *decoder = NULL;
  IWICBitmapFrameDecode *frame = NULL;
  IWICFormatConverter *converter = NULL;
  IWICBitmapScaler *scaler = NULL;
  bool valid = false;
  HRESULT hr = g_wic_factory->lpVtbl->CreateStream(g_wic_factory, &stream);
  if (SUCCEEDED(hr)) {
    hr = stream->lpVtbl->InitializeFromMemory(stream, (BYTE *)encoded,
        encoded_length);
  }
  if (SUCCEEDED(hr)) {
    hr = g_wic_factory->lpVtbl->CreateDecoderFromStream(g_wic_factory,
        (IStream *)stream, NULL, WICDecodeMetadataCacheOnLoad, &decoder);
  }
  if (SUCCEEDED(hr)) hr = decoder->lpVtbl->GetFrame(decoder, 0, &frame);
  if (SUCCEEDED(hr)) hr = g_wic_factory->lpVtbl->CreateFormatConverter(
      g_wic_factory, &converter);
  if (SUCCEEDED(hr)) {
    hr = converter->lpVtbl->Initialize(converter, (IWICBitmapSource *)frame,
        &GUID_WICPixelFormat32bppRGBA, WICBitmapDitherTypeNone, NULL, 0.0,
        WICBitmapPaletteTypeCustom);
  }
  UINT32 source_width = 0;
  UINT32 source_height = 0;
  if (SUCCEEDED(hr)) hr = converter->lpVtbl->GetSize(converter,
      &source_width, &source_height);
  IWICBitmapSource *source = (IWICBitmapSource *)converter;
  if (SUCCEEDED(hr) && target_width > 0 && target_height > 0 &&
      (target_width != source_width || target_height != source_height)) {
    hr = g_wic_factory->lpVtbl->CreateBitmapScaler(g_wic_factory, &scaler);
    if (SUCCEEDED(hr)) hr = scaler->lpVtbl->Initialize(scaler, source,
        target_width, target_height, WICBitmapInterpolationModeFant);
    if (SUCCEEDED(hr)) source = (IWICBitmapSource *)scaler;
  }
  UINT32 decoded_width = 0;
  UINT32 decoded_height = 0;
  if (SUCCEEDED(hr)) hr = source->lpVtbl->GetSize(source,
      &decoded_width, &decoded_height);
  uint64_t byte_length = (uint64_t)decoded_width * decoded_height * 4;
  uint8_t *decoded = NULL;
  if (SUCCEEDED(hr) && decoded_width > 0 && decoded_height > 0 &&
      byte_length <= UINT32_MAX) decoded = (uint8_t *)malloc((size_t)byte_length);
  if (decoded) {
    hr = source->lpVtbl->CopyPixels(source, NULL, decoded_width * 4,
        (UINT)byte_length, decoded);
    if (SUCCEEDED(hr)) {
      *width = decoded_width;
      *height = decoded_height;
      *pixels = decoded;
      valid = true;
    } else {
      free(decoded);
    }
  }
  if (scaler) scaler->lpVtbl->Release(scaler);
  if (converter) converter->lpVtbl->Release(converter);
  if (frame) frame->lpVtbl->Release(frame);
  if (decoder) decoder->lpVtbl->Release(decoder);
  if (stream) stream->lpVtbl->Release(stream);
  return valid;
}

typedef struct NimculusFallbackSource {
  IDWriteTextAnalysisSource iface;
  ULONG references;
  const wchar_t *text;
  UINT32 length;
  const wchar_t *locale;
} NimculusFallbackSource;

static HRESULT STDMETHODCALLTYPE fallback_source_query(
    IDWriteTextAnalysisSource *interface, REFIID identifier, void **object) {
  if (!object) return E_POINTER;
  *object = NULL;
  if (IsEqualIID(identifier, &IID_IUnknown) ||
      IsEqualIID(identifier, &IID_IDWriteTextAnalysisSource)) {
    *object = interface;
    interface->lpVtbl->AddRef(interface);
    return S_OK;
  }
  return E_NOINTERFACE;
}

static ULONG STDMETHODCALLTYPE fallback_source_addref(
    IDWriteTextAnalysisSource *interface) {
  NimculusFallbackSource *source = (NimculusFallbackSource *)interface;
  return ++source->references;
}

static ULONG STDMETHODCALLTYPE fallback_source_release(
    IDWriteTextAnalysisSource *interface) {
  NimculusFallbackSource *source = (NimculusFallbackSource *)interface;
  if (source->references > 0) source->references--;
  return source->references;
}

static HRESULT STDMETHODCALLTYPE fallback_source_text_at(
    IDWriteTextAnalysisSource *interface, UINT32 position,
    const WCHAR **text, UINT32 *length) {
  NimculusFallbackSource *source = (NimculusFallbackSource *)interface;
  if (!text || !length) return E_POINTER;
  if (position >= source->length) {
    *text = NULL;
    *length = 0;
  } else {
    *text = source->text + position;
    *length = source->length - position;
  }
  return S_OK;
}

static HRESULT STDMETHODCALLTYPE fallback_source_text_before(
    IDWriteTextAnalysisSource *interface, UINT32 position,
    const WCHAR **text, UINT32 *length) {
  NimculusFallbackSource *source = (NimculusFallbackSource *)interface;
  if (!text || !length) return E_POINTER;
  if (position == 0 || position > source->length) {
    *text = NULL;
    *length = 0;
  } else {
    *text = source->text;
    *length = position;
  }
  return S_OK;
}

static DWRITE_READING_DIRECTION STDMETHODCALLTYPE fallback_source_direction(
    IDWriteTextAnalysisSource *interface) {
  (void)interface;
  return DWRITE_READING_DIRECTION_LEFT_TO_RIGHT;
}

static HRESULT STDMETHODCALLTYPE fallback_source_locale(
    IDWriteTextAnalysisSource *interface, UINT32 position,
    UINT32 *length, const WCHAR **locale) {
  NimculusFallbackSource *source = (NimculusFallbackSource *)interface;
  if (!length || !locale) return E_POINTER;
  *locale = source->locale;
  *length = position < source->length ? source->length - position : 0;
  return S_OK;
}

static HRESULT STDMETHODCALLTYPE fallback_source_number_substitution(
    IDWriteTextAnalysisSource *interface, UINT32 position,
    UINT32 *length, IDWriteNumberSubstitution **substitution) {
  NimculusFallbackSource *source = (NimculusFallbackSource *)interface;
  if (!length || !substitution) return E_POINTER;
  *length = position < source->length ? source->length - position : 0;
  *substitution = NULL;
  return S_OK;
}

static const IDWriteTextAnalysisSourceVtbl g_fallback_source_vtable = {
  fallback_source_query,
  fallback_source_addref,
  fallback_source_release,
  fallback_source_text_at,
  fallback_source_text_before,
  fallback_source_direction,
  fallback_source_locale,
  fallback_source_number_substitution
};

typedef struct NimculusScriptSink {
  IDWriteTextAnalysisSink iface;
  ULONG references;
  DWRITE_SCRIPT_ANALYSIS script;
  bool has_script;
  bool consistent;
} NimculusScriptSink;

static HRESULT STDMETHODCALLTYPE script_sink_query(
    IDWriteTextAnalysisSink *interface, REFIID identifier, void **object) {
  if (!object) return E_POINTER;
  *object = NULL;
  if (IsEqualIID(identifier, &IID_IUnknown) ||
      IsEqualIID(identifier, &IID_IDWriteTextAnalysisSink)) {
    *object = interface;
    interface->lpVtbl->AddRef(interface);
    return S_OK;
  }
  return E_NOINTERFACE;
}

static ULONG STDMETHODCALLTYPE script_sink_addref(
    IDWriteTextAnalysisSink *interface) {
  NimculusScriptSink *sink = (NimculusScriptSink *)interface;
  return ++sink->references;
}

static ULONG STDMETHODCALLTYPE script_sink_release(
    IDWriteTextAnalysisSink *interface) {
  NimculusScriptSink *sink = (NimculusScriptSink *)interface;
  if (sink->references > 0) sink->references--;
  return sink->references;
}

static HRESULT STDMETHODCALLTYPE script_sink_set_script(
    IDWriteTextAnalysisSink *interface, UINT32 position, UINT32 length,
    const DWRITE_SCRIPT_ANALYSIS *script) {
  (void)position;
  (void)length;
  NimculusScriptSink *sink = (NimculusScriptSink *)interface;
  if (!script) return E_POINTER;
  if (!sink->has_script) {
    sink->script = *script;
    sink->has_script = true;
  } else if (sink->script.script != script->script ||
             sink->script.shapes != script->shapes) {
    sink->consistent = false;
  }
  return S_OK;
}

static HRESULT STDMETHODCALLTYPE script_sink_set_line_breakpoints(
    IDWriteTextAnalysisSink *interface, UINT32 position, UINT32 length,
    const DWRITE_LINE_BREAKPOINT *points) {
  (void)interface;
  (void)position;
  (void)length;
  (void)points;
  return S_OK;
}

static HRESULT STDMETHODCALLTYPE script_sink_set_bidi_level(
    IDWriteTextAnalysisSink *interface, UINT32 position, UINT32 length,
    UINT8 explicit_level, UINT8 resolved_level) {
  (void)interface;
  (void)position;
  (void)length;
  (void)explicit_level;
  (void)resolved_level;
  return S_OK;
}

static HRESULT STDMETHODCALLTYPE script_sink_set_number_substitution(
    IDWriteTextAnalysisSink *interface, UINT32 position, UINT32 length,
    IDWriteNumberSubstitution *substitution) {
  (void)interface;
  (void)position;
  (void)length;
  (void)substitution;
  return S_OK;
}

static const IDWriteTextAnalysisSinkVtbl g_script_sink_vtable = {
  script_sink_query,
  script_sink_addref,
  script_sink_release,
  script_sink_set_script,
  script_sink_set_line_breakpoints,
  script_sink_set_bidi_level,
  script_sink_set_number_substitution
};

static IDWriteFontFace *map_fallback_font(const wchar_t *text, UINT32 length,
                                          UINT32 *mapped_length, FLOAT *scale) {
  if (!text || length == 0 || !ensure_directwrite_factory() ||
      !g_dwrite_font_fallback) return NULL;
  NimculusFallbackSource source;
  ZeroMemory(&source, sizeof(source));
  source.iface.lpVtbl = &g_fallback_source_vtable;
  source.references = 1;
  source.text = text;
  source.length = length;
  source.locale = L"ja-jp";
  IDWriteFont *font = NULL;
  UINT32 result_length = 0;
  FLOAT result_scale = 1.0f;
  HRESULT hr = g_dwrite_font_fallback->lpVtbl->MapCharacters(
      g_dwrite_font_fallback, &source.iface, 0, length, NULL,
      g_editor_font_name, DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STYLE_NORMAL,
      DWRITE_FONT_STRETCH_NORMAL, &result_length, &font, &result_scale);
  if (mapped_length) *mapped_length = result_length;
  if (scale) *scale = result_scale;
  if (FAILED(hr) || !font) return NULL;
  IDWriteFontFace *font_face = NULL;
  hr = font->lpVtbl->CreateFontFace(font, &font_face);
  font->lpVtbl->Release(font);
  if (FAILED(hr)) return NULL;
  return font_face;
}

static void release_color_glyph_cache(void) {
  for (size_t index = 0; index < NIMCULUS_MAX_COLOR_GLYPHS; ++index) {
    free(g_color_glyphs[index].pixels);
    if (g_color_glyphs[index].font_face)
      g_color_glyphs[index].font_face->lpVtbl->Release(g_color_glyphs[index].font_face);
    ZeroMemory(&g_color_glyphs[index], sizeof(g_color_glyphs[index]));
  }
  g_color_glyph_atlas_next_x = 0;
  g_color_glyph_atlas_next_y = 0;
  g_color_glyph_atlas_row_height = 0;
}

static void release_glyph_raster_cache(void) {
  for (size_t index = 0; index < NIMCULUS_MAX_GLYPH_RASTERS; ++index) {
    free(g_glyph_rasters[index].pixels);
    if (g_glyph_rasters[index].font_face)
      g_glyph_rasters[index].font_face->lpVtbl->Release(g_glyph_rasters[index].font_face);
    ZeroMemory(&g_glyph_rasters[index], sizeof(g_glyph_rasters[index]));
  }
  g_glyph_raster_clock = 0;
  g_glyph_raster_hit_count = 0;
  g_glyph_raster_miss_count = 0;
  g_glyph_atlas_next_x = 0;
  g_glyph_atlas_next_y = 0;
  g_glyph_atlas_row_height = 0;
  release_color_glyph_cache();
}

static void release_glyph_atlas_texture(void) {
  if (g_glyph_atlas_view) {
    g_glyph_atlas_view->lpVtbl->Release(g_glyph_atlas_view);
    g_glyph_atlas_view = NULL;
  }
  if (g_glyph_atlas_texture) {
    g_glyph_atlas_texture->lpVtbl->Release(g_glyph_atlas_texture);
    g_glyph_atlas_texture = NULL;
  }
  if (g_color_glyph_atlas_view) {
    g_color_glyph_atlas_view->lpVtbl->Release(g_color_glyph_atlas_view);
    g_color_glyph_atlas_view = NULL;
  }
  if (g_color_glyph_atlas_texture) {
    g_color_glyph_atlas_texture->lpVtbl->Release(g_color_glyph_atlas_texture);
    g_color_glyph_atlas_texture = NULL;
  }
  g_glyph_atlas_next_x = 0;
  g_glyph_atlas_next_y = 0;
  g_glyph_atlas_row_height = 0;
  g_color_glyph_atlas_next_x = 0;
  g_color_glyph_atlas_next_y = 0;
  g_color_glyph_atlas_row_height = 0;
  for (size_t index = 0; index < NIMCULUS_MAX_GLYPH_RASTERS; ++index) {
    g_glyph_rasters[index].atlas_valid = false;
    g_glyph_rasters[index].atlas_x = 0;
    g_glyph_rasters[index].atlas_y = 0;
    g_glyph_rasters[index].atlas_width = 0;
    g_glyph_rasters[index].atlas_height = 0;
  }
  for (size_t index = 0; index < NIMCULUS_MAX_COLOR_GLYPHS; ++index) {
    g_color_glyphs[index].atlas_valid = false;
    g_color_glyphs[index].atlas_x = 0;
    g_color_glyphs[index].atlas_y = 0;
    g_color_glyphs[index].atlas_width = 0;
    g_color_glyphs[index].atlas_height = 0;
  }
}

static bool ensure_glyph_atlas_texture(void) {
  if (g_glyph_atlas_texture && g_glyph_atlas_view) return true;
  if (!g_device) return false;
  D3D11_TEXTURE2D_DESC description;
  ZeroMemory(&description, sizeof(description));
  description.Width = NIMCULUS_GLYPH_ATLAS_SIZE;
  description.Height = NIMCULUS_GLYPH_ATLAS_SIZE;
  description.MipLevels = 1;
  description.ArraySize = 1;
  description.Format = DXGI_FORMAT_R8_UNORM;
  description.SampleDesc.Count = 1;
  description.Usage = D3D11_USAGE_DEFAULT;
  description.BindFlags = D3D11_BIND_SHADER_RESOURCE;
  HRESULT hr = g_device->lpVtbl->CreateTexture2D(g_device, &description,
      NULL, &g_glyph_atlas_texture);
  if (FAILED(hr) || !g_glyph_atlas_texture) {
    g_glyph_atlas_texture = NULL;
    return false;
  }
  hr = g_device->lpVtbl->CreateShaderResourceView(g_device,
      (ID3D11Resource *)g_glyph_atlas_texture, NULL, &g_glyph_atlas_view);
  if (FAILED(hr) || !g_glyph_atlas_view) {
    release_glyph_atlas_texture();
    return false;
  }
  return true;
}

static bool ensure_color_glyph_atlas_texture(void) {
  if (g_color_glyph_atlas_texture && g_color_glyph_atlas_view) return true;
  if (!g_device) return false;
  D3D11_TEXTURE2D_DESC description;
  ZeroMemory(&description, sizeof(description));
  description.Width = NIMCULUS_GLYPH_ATLAS_SIZE;
  description.Height = NIMCULUS_GLYPH_ATLAS_SIZE;
  description.MipLevels = 1;
  description.ArraySize = 1;
  description.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
  description.SampleDesc.Count = 1;
  description.Usage = D3D11_USAGE_DEFAULT;
  description.BindFlags = D3D11_BIND_SHADER_RESOURCE;
  HRESULT hr = g_device->lpVtbl->CreateTexture2D(g_device, &description,
      NULL, &g_color_glyph_atlas_texture);
  if (FAILED(hr) || !g_color_glyph_atlas_texture) {
    g_color_glyph_atlas_texture = NULL;
    return false;
  }
  hr = g_device->lpVtbl->CreateShaderResourceView(g_device,
      (ID3D11Resource *)g_color_glyph_atlas_texture, NULL,
      &g_color_glyph_atlas_view);
  if (FAILED(hr) || !g_color_glyph_atlas_view) {
    if (g_color_glyph_atlas_texture) {
      g_color_glyph_atlas_texture->lpVtbl->Release(g_color_glyph_atlas_texture);
      g_color_glyph_atlas_texture = NULL;
    }
    return false;
  }
  return true;
}

static bool upload_glyph_raster_to_atlas(NimculusGlyphRaster *raster) {
  if (!raster || !raster->valid || !raster->pixels || raster->length == 0)
    return false;
  if (!g_context || !ensure_glyph_atlas_texture()) return false;
  if (raster->atlas_valid) return true;
  int width = raster->bounds.right - raster->bounds.left;
  int height = raster->bounds.bottom - raster->bounds.top;
  if (width <= 0 || height <= 0 || width + 2 >= NIMCULUS_GLYPH_ATLAS_SIZE ||
      height + 2 >= NIMCULUS_GLYPH_ATLAS_SIZE) return false;
  if (g_glyph_atlas_next_x + (uint32_t)width + 2 > NIMCULUS_GLYPH_ATLAS_SIZE) {
    g_glyph_atlas_next_x = 0;
    g_glyph_atlas_next_y += g_glyph_atlas_row_height;
    g_glyph_atlas_row_height = 0;
  }
  if (g_glyph_atlas_next_y + (uint32_t)height + 2 > NIMCULUS_GLYPH_ATLAS_SIZE) {
    g_glyph_atlas_next_x = 0;
    g_glyph_atlas_next_y = 0;
    g_glyph_atlas_row_height = 0;
    for (size_t index = 0; index < NIMCULUS_MAX_GLYPH_RASTERS; ++index)
      g_glyph_rasters[index].atlas_valid = false;
  }
  uint32_t x = g_glyph_atlas_next_x + 1;
  uint32_t y = g_glyph_atlas_next_y + 1;
  D3D11_BOX box = {x, y, 0, x + (uint32_t)width, y + (uint32_t)height, 1};
  g_context->lpVtbl->UpdateSubresource(g_context,
      (ID3D11Resource *)g_glyph_atlas_texture, 0, &box, raster->pixels,
      (UINT)width, 0);
  g_glyph_atlas_next_x += (uint32_t)width + 2;
  if ((uint32_t)height + 2 > g_glyph_atlas_row_height)
    g_glyph_atlas_row_height = (uint32_t)height + 2;
  raster->atlas_valid = true;
  raster->atlas_x = x;
  raster->atlas_y = y;
  raster->atlas_width = (uint32_t)width;
  raster->atlas_height = (uint32_t)height;
  g_glyph_atlas_upload_count++;
  return true;
}

static bool upload_color_glyph_to_atlas(NimculusColorGlyphRaster *raster) {
  if (!raster || !raster->valid || !raster->pixels || raster->length == 0)
    return false;
  if (!g_context || !ensure_color_glyph_atlas_texture()) return false;
  if (raster->atlas_valid) return true;
  int width = raster->bounds.right - raster->bounds.left;
  int height = raster->bounds.bottom - raster->bounds.top;
  if (width <= 0 || height <= 0 || width + 2 >= NIMCULUS_GLYPH_ATLAS_SIZE ||
      height + 2 >= NIMCULUS_GLYPH_ATLAS_SIZE) return false;
  if (g_color_glyph_atlas_next_x + (uint32_t)width + 2 > NIMCULUS_GLYPH_ATLAS_SIZE) {
    g_color_glyph_atlas_next_x = 0;
    g_color_glyph_atlas_next_y += g_color_glyph_atlas_row_height;
    g_color_glyph_atlas_row_height = 0;
  }
  if (g_color_glyph_atlas_next_y + (uint32_t)height + 2 > NIMCULUS_GLYPH_ATLAS_SIZE) {
    g_color_glyph_atlas_next_x = 0;
    g_color_glyph_atlas_next_y = 0;
    g_color_glyph_atlas_row_height = 0;
    for (size_t index = 0; index < NIMCULUS_MAX_COLOR_GLYPHS; ++index)
      g_color_glyphs[index].atlas_valid = false;
  }
  uint32_t x = g_color_glyph_atlas_next_x + 1;
  uint32_t y = g_color_glyph_atlas_next_y + 1;
  D3D11_BOX box = {x, y, 0, x + (uint32_t)width, y + (uint32_t)height, 1};
  g_context->lpVtbl->UpdateSubresource(g_context,
      (ID3D11Resource *)g_color_glyph_atlas_texture, 0, &box, raster->pixels,
      (UINT)width * 4, 0);
  g_color_glyph_atlas_next_x += (uint32_t)width + 2;
  if ((uint32_t)height + 2 > g_color_glyph_atlas_row_height)
    g_color_glyph_atlas_row_height = (uint32_t)height + 2;
  raster->atlas_valid = true;
  raster->atlas_x = x;
  raster->atlas_y = y;
  raster->atlas_width = (uint32_t)width;
  raster->atlas_height = (uint32_t)height;
  return true;
}

static void release_glyph_font_face(void) {
  if (g_glyph_font_face) {
    g_glyph_font_face->lpVtbl->Release(g_glyph_font_face);
    g_glyph_font_face = NULL;
  }
  ZeroMemory(g_glyph_font_face_name, sizeof(g_glyph_font_face_name));
}

static IDWriteFontFace *ensure_glyph_font_face(void) {
  if (!ensure_directwrite_factory()) return NULL;
  if (g_glyph_font_face &&
      wcscmp(g_glyph_font_face_name, g_editor_font_name) == 0) {
    return g_glyph_font_face;
  }
  release_glyph_raster_cache();
  release_glyph_font_face();
  IDWriteFontCollection *collection = NULL;
  HRESULT hr = g_dwrite_factory->lpVtbl->GetSystemFontCollection(
      g_dwrite_factory, &collection, FALSE);
  if (FAILED(hr) || !collection) return NULL;
  UINT32 family_index = 0;
  BOOL exists = FALSE;
  hr = collection->lpVtbl->FindFamilyName(collection, g_editor_font_name,
      &family_index, &exists);
  if (FAILED(hr) || !exists) {
    collection->lpVtbl->Release(collection);
    return NULL;
  }
  IDWriteFontFamily *family = NULL;
  hr = collection->lpVtbl->GetFontFamily(collection, family_index, &family);
  collection->lpVtbl->Release(collection);
  if (FAILED(hr) || !family) return NULL;
  IDWriteFont *font = NULL;
  hr = family->lpVtbl->GetFirstMatchingFont(family,
      DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STRETCH_NORMAL,
      DWRITE_FONT_STYLE_NORMAL, &font);
  family->lpVtbl->Release(family);
  if (FAILED(hr) || !font) return NULL;
  hr = font->lpVtbl->CreateFontFace(font, &g_glyph_font_face);
  font->lpVtbl->Release(font);
  if (FAILED(hr) || !g_glyph_font_face) {
    release_glyph_font_face();
    return NULL;
  }
  wcsncpy(g_glyph_font_face_name, g_editor_font_name,
      LF_FACESIZE - 1);
  g_glyph_font_face_name[LF_FACESIZE - 1] = L'\0';
  return g_glyph_font_face;
}

static NimculusGlyphRaster *find_glyph_raster(uint16_t glyph_id,
                                               IDWriteFontFace *font_face,
                                               float font_size, double scale,
                                               uint8_t subpixel_x,
                                               uint8_t subpixel_y) {
  for (size_t index = 0; index < NIMCULUS_MAX_GLYPH_RASTERS; ++index) {
    NimculusGlyphRaster *raster = &g_glyph_rasters[index];
    if (!raster->valid || raster->glyph_id != glyph_id ||
        raster->font_face != font_face ||
        fabs((double)raster->font_size - (double)font_size) >= 0.001 ||
        fabs(raster->scale - scale) >= 0.001 ||
        raster->subpixel_x != subpixel_x || raster->subpixel_y != subpixel_y) continue;
    raster->last_used = ++g_glyph_raster_clock;
    g_glyph_raster_hit_count++;
    return raster;
  }
  g_glyph_raster_miss_count++;
  return NULL;
}

static NimculusGlyphRaster *allocate_glyph_raster_slot(void) {
  NimculusGlyphRaster *oldest = &g_glyph_rasters[0];
  for (size_t index = 0; index < NIMCULUS_MAX_GLYPH_RASTERS; ++index) {
    NimculusGlyphRaster *raster = &g_glyph_rasters[index];
    if (!raster->valid) return raster;
    if (raster->last_used < oldest->last_used) oldest = raster;
  }
  free(oldest->pixels);
  if (oldest->font_face) oldest->font_face->lpVtbl->Release(oldest->font_face);
  ZeroMemory(oldest, sizeof(*oldest));
  return oldest;
}

static bool rasterize_glyph_id_for_cache(IDWriteFontFace *font_face,
                                      uint16_t glyph_id, float font_size,
                                      double scale, uint8_t subpixel_x,
                                      uint8_t subpixel_y) {
  if (!font_face || !ensure_directwrite_factory()) return false;
  HRESULT hr;
  if (find_glyph_raster(glyph_id, font_face, font_size, scale, subpixel_x, subpixel_y))
    return true;

  FLOAT advance = 0.0f;
  DWRITE_GLYPH_OFFSET offset;
  ZeroMemory(&offset, sizeof(offset));
  DWRITE_GLYPH_RUN run;
  ZeroMemory(&run, sizeof(run));
  run.fontFace = font_face;
  run.fontEmSize = font_size;
  run.glyphCount = 1;
  run.glyphIndices = &glyph_id;
  run.glyphAdvances = &advance;
  run.glyphOffsets = &offset;
  DWRITE_MATRIX transform = { (FLOAT)scale, 0.0f, 0.0f, (FLOAT)scale,
                              0.0f, 0.0f };
  IDWriteGlyphRunAnalysis *analysis = NULL;
  hr = g_dwrite_factory2->lpVtbl->CreateGlyphRunAnalysis(g_dwrite_factory2,
      &run, &transform, DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC,
      DWRITE_MEASURING_MODE_NATURAL, DWRITE_GRID_FIT_MODE_ENABLED,
      DWRITE_TEXT_ANTIALIAS_MODE_GRAYSCALE,
      (FLOAT)subpixel_x / (4.0f * (FLOAT)scale),
      (FLOAT)subpixel_y / (4.0f * (FLOAT)scale), &analysis);
  if (FAILED(hr) || !analysis) return false;
  RECT bounds;
  ZeroMemory(&bounds, sizeof(bounds));
  hr = analysis->lpVtbl->GetAlphaTextureBounds(analysis,
      DWRITE_TEXTURE_ALIASED_1x1, &bounds);
  if (FAILED(hr) || bounds.right <= bounds.left || bounds.bottom <= bounds.top) {
    analysis->lpVtbl->Release(analysis);
    return false;
  }
  uint64_t width = (uint64_t)(bounds.right - bounds.left);
  uint64_t height = (uint64_t)(bounds.bottom - bounds.top);
  uint64_t length = width * height;
  if (width > UINT32_MAX || height > UINT32_MAX || length > UINT32_MAX) {
    analysis->lpVtbl->Release(analysis);
    return false;
  }
  uint8_t *pixels = (uint8_t *)malloc((size_t)length);
  if (!pixels) {
    analysis->lpVtbl->Release(analysis);
    return false;
  }
  hr = analysis->lpVtbl->CreateAlphaTexture(analysis,
      DWRITE_TEXTURE_ALIASED_1x1, &bounds, pixels, (UINT32)length);
  analysis->lpVtbl->Release(analysis);
  if (FAILED(hr)) {
    free(pixels);
    return false;
  }
  NimculusGlyphRaster *raster = allocate_glyph_raster_slot();
  raster->valid = true;
  raster->glyph_id = glyph_id;
  raster->font_face = font_face;
  font_face->lpVtbl->AddRef(font_face);
  raster->font_size = font_size;
  raster->scale = scale;
  raster->subpixel_x = subpixel_x;
  raster->subpixel_y = subpixel_y;
  raster->bounds = bounds;
  raster->length = (uint32_t)length;
  raster->pixels = pixels;
  raster->last_used = ++g_glyph_raster_clock;
  return true;
}

static bool rasterize_glyph_for_cache(uint32_t codepoint, float font_size,
                                      double scale, uint8_t subpixel_x,
                                      uint8_t subpixel_y) {
  bool owns_font_face = false;
  UINT32 utf16_length = codepoint > 0xffff ? 2 : 1;
  wchar_t utf16[2];
  if (utf16_length == 1) utf16[0] = (wchar_t)codepoint;
  else {
    uint32_t value = codepoint - 0x10000;
    utf16[0] = (wchar_t)(0xd800 + (value >> 10));
    utf16[1] = (wchar_t)(0xdc00 + (value & 0x3ff));
  }
  IDWriteFontFace *font_face = ensure_glyph_font_face();
  if (!font_face) return false;
  UINT16 glyph_id = 0;
  if (FAILED(font_face->lpVtbl->GetGlyphIndices(font_face, &codepoint, 1,
                                                &glyph_id))) return false;
  if (glyph_id == 0) {
    UINT32 mapped_length = 0;
    FLOAT fallback_scale = 1.0f;
    IDWriteFontFace *fallback = map_fallback_font(utf16, utf16_length,
        &mapped_length, &fallback_scale);
    if (!fallback || mapped_length == 0 ||
        FAILED(fallback->lpVtbl->GetGlyphIndices(fallback, &codepoint, 1,
                                                 &glyph_id))) {
      if (fallback) fallback->lpVtbl->Release(fallback);
      return false;
    }
    font_face = fallback;
    owns_font_face = true;
    font_size *= fallback_scale;
  }
  bool result = rasterize_glyph_id_for_cache(font_face, glyph_id, font_size,
      scale, subpixel_x, subpixel_y);
  if (owns_font_face) font_face->lpVtbl->Release(font_face);
  return result;
}

static NimculusGlyphRaster *cached_glyph_for_id(IDWriteFontFace *font_face,
                                                 uint16_t glyph_id,
                                                 float font_size,
                                                 double scale,
                                                 uint8_t subpixel_x,
                                                 uint8_t subpixel_y) {
  return find_glyph_raster(glyph_id, font_face, font_size, scale, subpixel_x, subpixel_y);
}

static NimculusGlyphRaster *cached_glyph_for_codepoint(uint32_t codepoint,
                                                        float font_size,
                                                        double scale,
                                                        uint8_t subpixel_x,
                                                        uint8_t subpixel_y) {
  IDWriteFontFace *font_face = ensure_glyph_font_face();
  if (!font_face) return NULL;
  UINT16 glyph_id = 0;
  if (FAILED(font_face->lpVtbl->GetGlyphIndices(font_face, &codepoint, 1,
                                                &glyph_id))) return NULL;
  bool owns_font_face = false;
  wchar_t utf16[2];
  UINT32 utf16_length = codepoint > 0xffff ? 2 : 1;
  if (utf16_length == 1) utf16[0] = (wchar_t)codepoint;
  else {
    uint32_t value = codepoint - 0x10000;
    utf16[0] = (wchar_t)(0xd800 + (value >> 10));
    utf16[1] = (wchar_t)(0xdc00 + (value & 0x3ff));
  }
  if (glyph_id == 0) {
    UINT32 mapped_length = 0;
    FLOAT fallback_scale = 1.0f;
    IDWriteFontFace *fallback = map_fallback_font(utf16, utf16_length,
        &mapped_length, &fallback_scale);
    if (!fallback || mapped_length == 0 ||
        FAILED(fallback->lpVtbl->GetGlyphIndices(fallback, &codepoint, 1,
                                                 &glyph_id))) {
      if (fallback) fallback->lpVtbl->Release(fallback);
      return NULL;
    }
    font_face = fallback;
    owns_font_face = true;
    font_size *= fallback_scale;
  }
  NimculusGlyphRaster *raster = cached_glyph_for_id(font_face, glyph_id,
      font_size, scale, subpixel_x, subpixel_y);
  if (owns_font_face) font_face->lpVtbl->Release(font_face);
  return raster;
}

/* Warm the device-owned atlas from the same visible editor range that the
 * DirectWrite fallback paints. The atlas remains an independent resource until
 * the sprite pipeline is enabled; keeping this boundary here makes device-loss
 * recovery exercise the real frame path instead of only a test helper. */
static void prepare_visible_glyph_atlas(void) {
  if (!g_device || !g_context || !g_editor_text || g_editor_text_length <= 0)
    return;
  double scale = g_metrics.scale_factor > 0.0 ? g_metrics.scale_factor : 1.0;
  float font_size = (float)g_editor_font_size;
  uint32_t visible_lines = (uint32_t)(g_editor_rect[3] /
      (g_editor_font_size + 2.0)) + 2;
  uint32_t line = 0;
  uint32_t prepared = 0;
  const wchar_t *line_start = g_editor_text;
  const wchar_t *end = g_editor_text + g_editor_text_length;
  while (line_start <= end && line < g_editor_scroll_line + visible_lines) {
    const wchar_t *line_end = line_start;
    while (line_end < end && *line_end != L'\n') line_end++;
    if (line >= g_editor_scroll_line) {
      for (const wchar_t *character = line_start; character < line_end;
           ++character) {
        uint32_t codepoint = (uint32_t)*character;
        if (codepoint < 0x20 || codepoint > 0x7e) continue;
        if (!rasterize_glyph_for_cache(codepoint, font_size, scale, 0, 0))
          continue;
        NimculusGlyphRaster *raster = cached_glyph_for_codepoint(
            codepoint, font_size, scale, 0, 0);
        if (raster && upload_glyph_raster_to_atlas(raster)) prepared++;
        if (prepared >= 4096) return;
      }
    }
    if (line_end >= end) break;
    line_start = line_end + 1;
    line++;
  }
}

static void release_editor_text_format(void) {
  if (g_editor_text_format) {
    g_editor_text_format->lpVtbl->Release(g_editor_text_format);
    g_editor_text_format = NULL;
  }
  g_editor_text_format_size = 0.0f;
  g_editor_text_format_scale = 0.0;
  g_editor_text_format_wrap = false;
}

static IDWriteTextFormat *ensure_editor_text_format(double scale) {
  if (!ensure_directwrite_factory()) return NULL;
  float size = (float)(g_editor_font_size * scale);
  bool wrap = g_editor_soft_wrap;
  if (g_editor_text_format &&
      fabs((double)g_editor_text_format_size - (double)size) < 0.001 &&
      fabs(g_editor_text_format_scale - scale) < 0.001 &&
      g_editor_text_format_wrap == wrap) {
    return g_editor_text_format;
  }
  release_editor_text_format();
  HRESULT hr = g_dwrite_factory->lpVtbl->CreateTextFormat(g_dwrite_factory,
      g_editor_font_name, NULL, DWRITE_FONT_WEIGHT_NORMAL,
      DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, size, L"",
      &g_editor_text_format);
  if (FAILED(hr) || !g_editor_text_format) {
    release_editor_text_format();
    return NULL;
  }
  g_editor_text_format->lpVtbl->SetWordWrapping(g_editor_text_format,
      wrap ? DWRITE_WORD_WRAPPING_WRAP : DWRITE_WORD_WRAPPING_NO_WRAP);
  g_editor_text_format->lpVtbl->SetTextAlignment(g_editor_text_format,
      DWRITE_TEXT_ALIGNMENT_LEADING);
  g_editor_text_format->lpVtbl->SetParagraphAlignment(g_editor_text_format,
      DWRITE_PARAGRAPH_ALIGNMENT_NEAR);
  g_editor_text_format_size = size;
  g_editor_text_format_scale = scale;
  g_editor_text_format_wrap = wrap;
  return g_editor_text_format;
}

static bool create_render_target(void) {
  if (!g_swap_chain || !g_device) return false;
  ID3D11Texture2D *back_buffer = NULL;
  HRESULT hr = g_swap_chain->lpVtbl->GetBuffer(
      g_swap_chain, 0, &IID_ID3D11Texture2D, (void **)&back_buffer);
  if (FAILED(hr)) return false;
  hr = g_device->lpVtbl->CreateRenderTargetView(
      g_device, (ID3D11Resource *)back_buffer, NULL, &g_render_target);
  back_buffer->lpVtbl->Release(back_buffer);
  return SUCCEEDED(hr);
}

static void resize_render_target(void) {
  if (!g_swap_chain || !g_device) return;
  if (g_context) g_context->lpVtbl->OMSetRenderTargets(g_context, 0, NULL, NULL);
  release_directwrite_target();
  release_render_target();
  if (g_metrics.width_pixels == 0 || g_metrics.height_pixels == 0) return;
  if (FAILED(g_swap_chain->lpVtbl->ResizeBuffers(
      g_swap_chain, 0, g_metrics.width_pixels, g_metrics.height_pixels,
      DXGI_FORMAT_UNKNOWN, 0))) return;
  create_render_target();
  create_directwrite_target();
}

static NimculusImage *find_image(uint32_t image_id) {
  if (image_id == 0) return NULL;
  for (size_t index = 0; index < NIMCULUS_MAX_IMAGES; ++index) {
    if (g_images[index].id == image_id) return &g_images[index];
  }
  return NULL;
}

static NimculusImage *get_image_slot(uint32_t image_id) {
  NimculusImage *free_slot = NULL;
  for (size_t index = 0; index < NIMCULUS_MAX_IMAGES; ++index) {
    if (g_images[index].id == image_id) return &g_images[index];
    if (!free_slot && g_images[index].id == 0) free_slot = &g_images[index];
  }
  return free_slot;
}

static void release_image_views(void) {
  for (size_t index = 0; index < NIMCULUS_MAX_IMAGES; ++index) {
    if (g_images[index].view) {
      g_images[index].view->lpVtbl->Release(g_images[index].view);
      g_images[index].view = NULL;
    }
  }
}

static bool upload_image_view(NimculusImage *image) {
  if (!image || !image->rgba || image->width == 0 || image->height == 0) return false;
  if (image->view) {
    image->view->lpVtbl->Release(image->view);
    image->view = NULL;
  }
  if (!g_device) return true;
  D3D11_TEXTURE2D_DESC description;
  ZeroMemory(&description, sizeof(description));
  description.Width = image->width;
  description.Height = image->height;
  description.MipLevels = 1;
  description.ArraySize = 1;
  description.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
  description.SampleDesc.Count = 1;
  description.Usage = D3D11_USAGE_DEFAULT;
  description.BindFlags = D3D11_BIND_SHADER_RESOURCE;
  D3D11_SUBRESOURCE_DATA data;
  ZeroMemory(&data, sizeof(data));
  data.pSysMem = image->rgba;
  data.SysMemPitch = image->width * 4;
  ID3D11Texture2D *texture = NULL;
  HRESULT hr = g_device->lpVtbl->CreateTexture2D(g_device, &description, &data, &texture);
  if (FAILED(hr)) return false;
  hr = g_device->lpVtbl->CreateShaderResourceView(g_device,
      (ID3D11Resource *)texture, NULL, &image->view);
  texture->lpVtbl->Release(texture);
  return SUCCEEDED(hr);
}

static void release_images(void) {
  release_image_views();
  for (size_t index = 0; index < NIMCULUS_MAX_IMAGES; ++index) {
    free(g_images[index].rgba);
    ZeroMemory(&g_images[index], sizeof(g_images[index]));
  }
}

static bool create_device(void) {
  DXGI_SWAP_CHAIN_DESC desc;
  ZeroMemory(&desc, sizeof(desc));
  desc.BufferCount = 2;
  desc.BufferDesc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
  desc.OutputWindow = g_window;
  desc.SampleDesc.Count = 1;
  desc.Windowed = TRUE;
  desc.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;
  D3D_FEATURE_LEVEL level;
  HRESULT hr = D3D11CreateDeviceAndSwapChain(
      NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0,
      D3D11_SDK_VERSION, &desc, &g_swap_chain, &g_device, &level, &g_context);
  if (FAILED(hr)) return false;
  update_metrics();
  if (!create_render_target()) {
    release_device();
    return false;
  }
  create_directwrite_target();
  if (!create_quad_pipeline()) {
    release_device();
    return false;
  }
  for (size_t index = 0; index < NIMCULUS_MAX_IMAGES; ++index) {
    if (g_images[index].id != 0) upload_image_view(&g_images[index]);
  }
  return true;
}

static void release_device(void) {
  if (g_context) g_context->lpVtbl->ClearState(g_context);
  release_directwrite_target();
  release_render_target();
  release_image_views();
  release_glyph_atlas_texture();
  release_quad_pipeline();
  if (g_swap_chain) g_swap_chain->lpVtbl->Release(g_swap_chain);
  if (g_context) g_context->lpVtbl->Release(g_context);
  if (g_device) g_device->lpVtbl->Release(g_device);
  g_swap_chain = NULL;
  g_context = NULL;
  g_device = NULL;
}

static bool recreate_device(void) {
  release_device();
  return create_device();
}

static void paint_color(uint32_t kind, float color[4]) {
  switch (kind) {
    case 1: color[0] = 0.32f; color[1] = 0.38f; color[2] = 0.48f; break; /* border */
    case 2: color[0] = 0.18f; color[1] = 0.22f; color[2] = 0.29f; break; /* rounded */
    case 7: color[0] = 0.05f; color[1] = 0.06f; color[2] = 0.08f; break; /* shadow */
    case 8: color[0] = 0.35f; color[1] = 0.70f; color[2] = 1.0f; break; /* caret */
    case 9: color[0] = 0.16f; color[1] = 0.36f; color[2] = 0.68f; break; /* selection */
    case 10: color[0] = 0.42f; color[1] = 0.48f; color[2] = 0.58f; break; /* scrollbar */
    default: color[0] = 0.14f; color[1] = 0.17f; color[2] = 0.22f; break;
  }
  color[3] = 1.0f;
}

static void draw_paint_quads(void) {
  if (!g_context || !g_quad_vertex_buffer || !g_quad_input_layout ||
      !g_quad_vertex_shader || !g_quad_pixel_shader || !g_quad_rasterizer ||
      !g_quad_blend_state ||
      g_paint_count == 0 || g_metrics.width_pixels == 0 || g_metrics.height_pixels == 0) return;
  UINT stride = sizeof(NimculusQuadVertex);
  UINT offset = 0;
  g_context->lpVtbl->IASetInputLayout(g_context, g_quad_input_layout);
  g_context->lpVtbl->IASetVertexBuffers(g_context, 0, 1, &g_quad_vertex_buffer, &stride, &offset);
  g_context->lpVtbl->IASetPrimitiveTopology(g_context, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
  g_context->lpVtbl->VSSetShader(g_context, g_quad_vertex_shader, NULL, 0);
  g_context->lpVtbl->PSSetShader(g_context, g_quad_pixel_shader, NULL, 0);
  g_context->lpVtbl->RSSetState(g_context, g_quad_rasterizer);
  const FLOAT blend_factor[4] = {0.0f, 0.0f, 0.0f, 0.0f};
  g_context->lpVtbl->OMSetBlendState(g_context, g_quad_blend_state, blend_factor, 0xffffffffu);

  float scale = (float)(g_metrics.scale_factor > 0.0 ? g_metrics.scale_factor : 1.0);
  float width = (float)g_metrics.width_pixels;
  float height = (float)g_metrics.height_pixels;
  for (uint32_t index = 0; index < g_paint_count; ++index) {
    const NimculusPaintCommand *command = &g_paint_commands[index];
    NimculusImage *image = command->kind == 4 ? find_image(command->image_id) : NULL;
    if (command->kind == 3 || command->kind == 5 || command->kind == 6 ||
        (command->kind == 4 && (!image || !image->view)) ||
        command->width <= 0.0f || command->height <= 0.0f) continue;
    float left = command->x * scale;
    float top = command->y * scale;
    float right = (command->x + command->width) * scale;
    float bottom = (command->y + command->height) * scale;
    float color[4];
    paint_color(command->kind, color);
    if (image) {
      color[0] = 1.0f;
      color[1] = 1.0f;
      color[2] = 1.0f;
      color[3] = 1.0f;
    }
    float local[6][2] = {{0.0f, 0.0f}, {1.0f, 0.0f}, {1.0f, 1.0f},
                         {0.0f, 0.0f}, {1.0f, 1.0f}, {0.0f, 1.0f}};
    NimculusQuadVertex vertices[6] = {
      {(left / width) * 2.0f - 1.0f, 1.0f - (top / height) * 2.0f,
        color[0], color[1], color[2], color[3], local[0][0], local[0][1],
        right - left, bottom - top, command->radius * scale, (float)command->kind},
      {(right / width) * 2.0f - 1.0f, 1.0f - (top / height) * 2.0f,
        color[0], color[1], color[2], color[3], local[1][0], local[1][1],
        right - left, bottom - top, command->radius * scale, (float)command->kind},
      {(right / width) * 2.0f - 1.0f, 1.0f - (bottom / height) * 2.0f,
        color[0], color[1], color[2], color[3], local[2][0], local[2][1],
        right - left, bottom - top, command->radius * scale, (float)command->kind},
      {(left / width) * 2.0f - 1.0f, 1.0f - (top / height) * 2.0f,
        color[0], color[1], color[2], color[3], local[3][0], local[3][1],
        right - left, bottom - top, command->radius * scale, (float)command->kind},
      {(right / width) * 2.0f - 1.0f, 1.0f - (bottom / height) * 2.0f,
        color[0], color[1], color[2], color[3], local[4][0], local[4][1],
        right - left, bottom - top, command->radius * scale, (float)command->kind},
      {(left / width) * 2.0f - 1.0f, 1.0f - (bottom / height) * 2.0f,
        color[0], color[1], color[2], color[3], local[5][0], local[5][1],
        right - left, bottom - top, command->radius * scale, (float)command->kind}
    };
    D3D11_MAPPED_SUBRESOURCE mapped;
    if (FAILED(g_context->lpVtbl->Map(g_context, (ID3D11Resource *)g_quad_vertex_buffer,
        0, D3D11_MAP_WRITE_DISCARD, 0, &mapped))) continue;
    memcpy(mapped.pData, vertices, sizeof(vertices));
    g_context->lpVtbl->Unmap(g_context, (ID3D11Resource *)g_quad_vertex_buffer, 0);
    LONG clip_left = (LONG)(command->clip_x * scale);
    LONG clip_top = (LONG)(command->clip_y * scale);
    LONG clip_right = (LONG)((command->clip_x + command->clip_width) * scale);
    LONG clip_bottom = (LONG)((command->clip_y + command->clip_height) * scale);
    if (clip_left < 0) clip_left = 0;
    if (clip_top < 0) clip_top = 0;
    if (clip_right > (LONG)g_metrics.width_pixels) clip_right = (LONG)g_metrics.width_pixels;
    if (clip_bottom > (LONG)g_metrics.height_pixels) clip_bottom = (LONG)g_metrics.height_pixels;
    if (clip_right <= clip_left || clip_bottom <= clip_top) continue;
    D3D11_RECT scissor = {clip_left, clip_top, clip_right, clip_bottom};
    g_context->lpVtbl->RSSetScissorRects(g_context, 1, &scissor);
    if (image) {
      g_context->lpVtbl->PSSetShader(g_context, g_image_pixel_shader, NULL, 0);
      g_context->lpVtbl->PSSetShaderResources(g_context, 0, 1, &image->view);
      g_context->lpVtbl->PSSetSamplers(g_context, 0, 1, &g_image_sampler);
    } else {
      g_context->lpVtbl->PSSetShader(g_context, g_quad_pixel_shader, NULL, 0);
    }
    g_context->lpVtbl->Draw(g_context, 6, 0);
    if (image) {
      ID3D11ShaderResourceView *none = NULL;
      g_context->lpVtbl->PSSetShaderResources(g_context, 0, 1, &none);
    }
  }
}

static float glyph_advance_pixels(IDWriteFontFace *font_face, UINT16 glyph_id,
                                  float font_size, double scale) {
  if (!font_face) return font_size * (float)scale * 0.6f;
  DWRITE_FONT_METRICS font_metrics;
  ZeroMemory(&font_metrics, sizeof(font_metrics));
  DWRITE_GLYPH_METRICS glyph_metrics;
  ZeroMemory(&glyph_metrics, sizeof(glyph_metrics));
  if (FAILED(font_face->lpVtbl->GetMetrics(font_face, &font_metrics)) ||
      font_metrics.designUnitsPerEm == 0 ||
      FAILED(font_face->lpVtbl->GetDesignGlyphMetrics(font_face, &glyph_id, 1,
                                                       &glyph_metrics, FALSE)))
    return font_size * (float)scale * 0.6f;
  return (float)glyph_metrics.advanceWidth /
      (float)font_metrics.designUnitsPerEm * font_size * (float)scale;
}

static NimculusColorGlyphRaster *find_color_glyph_raster(
    IDWriteFontFace *font_face, UINT16 glyph_id, float font_size,
    double scale, uint8_t subpixel_x, uint8_t subpixel_y) {
  for (size_t index = 0; index < NIMCULUS_MAX_COLOR_GLYPHS; ++index) {
    NimculusColorGlyphRaster *raster = &g_color_glyphs[index];
    if (!raster->valid || raster->font_face != font_face ||
        raster->glyph_id != glyph_id ||
        fabs((double)raster->font_size - (double)font_size) >= 0.001 ||
        fabs(raster->scale - scale) >= 0.001 ||
        raster->subpixel_x != subpixel_x || raster->subpixel_y != subpixel_y)
      continue;
    raster->last_used = ++g_glyph_raster_clock;
    return raster;
  }
  return NULL;
}

static NimculusColorGlyphRaster *allocate_color_glyph_raster(void) {
  NimculusColorGlyphRaster *oldest = &g_color_glyphs[0];
  for (size_t index = 0; index < NIMCULUS_MAX_COLOR_GLYPHS; ++index) {
    NimculusColorGlyphRaster *raster = &g_color_glyphs[index];
    if (!raster->valid) return raster;
    if (raster->last_used < oldest->last_used) oldest = raster;
  }
  free(oldest->pixels);
  if (oldest->font_face) oldest->font_face->lpVtbl->Release(oldest->font_face);
  ZeroMemory(oldest, sizeof(*oldest));
  return oldest;
}

typedef struct NimculusColorLayer {
  RECT bounds;
  D2D1_COLOR_F color;
  uint8_t *alpha;
  uint32_t length;
} NimculusColorLayer;

static bool rasterize_color_glyph_for_cache(IDWriteFontFace *font_face,
                                            UINT16 glyph_id, float font_size,
                                            double scale, uint8_t subpixel_x,
                                            uint8_t subpixel_y) {
  if (!font_face || !ensure_directwrite_factory()) return false;
  if (find_color_glyph_raster(font_face, glyph_id, font_size, scale,
                              subpixel_x, subpixel_y)) return true;
  FLOAT advance = glyph_advance_pixels(font_face, glyph_id, font_size, scale);
  DWRITE_GLYPH_OFFSET offset = {0.0f, 0.0f};
  DWRITE_GLYPH_RUN run;
  ZeroMemory(&run, sizeof(run));
  run.fontFace = font_face;
  run.fontEmSize = font_size;
  run.glyphCount = 1;
  run.glyphIndices = &glyph_id;
  run.glyphAdvances = &advance;
  run.glyphOffsets = &offset;
  DWRITE_MATRIX transform = {(FLOAT)scale, 0.0f, 0.0f, (FLOAT)scale,
                             0.0f, 0.0f};
  IDWriteColorGlyphRunEnumerator *enumerator = NULL;
  HRESULT hr = g_dwrite_factory2->lpVtbl->TranslateColorGlyphRun(
      g_dwrite_factory2, 0.0f, 0.0f, &run, NULL, DWRITE_MEASURING_MODE_NATURAL,
      &transform, 0, &enumerator);
  if (hr == DWRITE_E_NOCOLOR || FAILED(hr) || !enumerator) return false;
  NimculusColorLayer layers[64];
  ZeroMemory(layers, sizeof(layers));
  uint32_t layer_count = 0;
  RECT union_bounds = {0, 0, 0, 0};
  bool has_bounds = false;
  for (;;) {
    const DWRITE_COLOR_GLYPH_RUN *color_run = NULL;
    hr = enumerator->lpVtbl->GetCurrentRun(enumerator, &color_run);
    if (FAILED(hr) || !color_run) break;
    /* IDWriteFactory2::TranslateColorGlyphRun returns the legacy
     * DWRITE_COLOR_GLYPH_RUN shape.  Every enumerated run is a COLR layer;
     * glyphImageFormat belongs to the newer DWRITE_COLOR_GLYPH_RUN1 API
     * exposed by IDWriteFactory4, which this backend intentionally does not
     * require yet. */
    if (layer_count < 64) {
      IDWriteGlyphRunAnalysis *analysis = NULL;
      hr = g_dwrite_factory2->lpVtbl->CreateGlyphRunAnalysis(
          g_dwrite_factory2, &color_run->glyphRun, &transform,
          DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC, DWRITE_MEASURING_MODE_NATURAL,
          DWRITE_GRID_FIT_MODE_ENABLED, DWRITE_TEXT_ANTIALIAS_MODE_GRAYSCALE,
          (FLOAT)subpixel_x / (4.0f * (FLOAT)scale),
          (FLOAT)subpixel_y / (4.0f * (FLOAT)scale), &analysis);
      if (SUCCEEDED(hr) && analysis) {
        RECT bounds;
        hr = analysis->lpVtbl->GetAlphaTextureBounds(analysis,
            DWRITE_TEXTURE_ALIASED_1x1, &bounds);
        int width = bounds.right - bounds.left;
        int height = bounds.bottom - bounds.top;
        if (SUCCEEDED(hr) && width > 0 && height > 0 &&
            (uint64_t)width * (uint64_t)height <= UINT32_MAX) {
          uint32_t length = (uint32_t)width * (uint32_t)height;
          uint8_t *alpha = (uint8_t *)malloc(length);
          if (alpha && SUCCEEDED(analysis->lpVtbl->CreateAlphaTexture(
              analysis, DWRITE_TEXTURE_ALIASED_1x1, &bounds, alpha, length))) {
            layers[layer_count].bounds = bounds;
            layers[layer_count].color = color_run->runColor;
            layers[layer_count].alpha = alpha;
            layers[layer_count].length = length;
            if (!has_bounds) union_bounds = bounds;
            else {
              if (bounds.left < union_bounds.left) union_bounds.left = bounds.left;
              if (bounds.top < union_bounds.top) union_bounds.top = bounds.top;
              if (bounds.right > union_bounds.right) union_bounds.right = bounds.right;
              if (bounds.bottom > union_bounds.bottom) union_bounds.bottom = bounds.bottom;
            }
            has_bounds = true;
            layer_count++;
            alpha = NULL;
          }
          free(alpha);
        }
        analysis->lpVtbl->Release(analysis);
      }
    }
    BOOL has_next = FALSE;
    hr = enumerator->lpVtbl->MoveNext(enumerator, &has_next);
    if (FAILED(hr) || !has_next) break;
  }
  enumerator->lpVtbl->Release(enumerator);
  int width = union_bounds.right - union_bounds.left;
  int height = union_bounds.bottom - union_bounds.top;
  if (!has_bounds || width <= 0 || height <= 0 ||
      (uint64_t)width * (uint64_t)height > UINT32_MAX / 4) {
    for (uint32_t index = 0; index < layer_count; ++index) free(layers[index].alpha);
    return false;
  }
  uint32_t rgba_length = (uint32_t)width * (uint32_t)height * 4;
  uint8_t *rgba = (uint8_t *)calloc(1, rgba_length);
  if (!rgba) {
    for (uint32_t index = 0; index < layer_count; ++index) free(layers[index].alpha);
    return false;
  }
  for (uint32_t layer_index = 0; layer_index < layer_count; ++layer_index) {
    NimculusColorLayer *layer = &layers[layer_index];
    int layer_width = layer->bounds.right - layer->bounds.left;
    int layer_height = layer->bounds.bottom - layer->bounds.top;
    for (int y = 0; y < layer_height; ++y) for (int x = 0; x < layer_width; ++x) {
      uint8_t alpha8 = layer->alpha[y * layer_width + x];
      float source_alpha = ((float)alpha8 / 255.0f) * layer->color.a;
      int destination_x = layer->bounds.left - union_bounds.left + x;
      int destination_y = layer->bounds.top - union_bounds.top + y;
      size_t destination = ((size_t)destination_y * (size_t)width +
                            (size_t)destination_x) * 4;
      float destination_alpha = (float)rgba[destination + 3] / 255.0f;
      float output_alpha = source_alpha + destination_alpha * (1.0f - source_alpha);
      if (output_alpha > 0.0f) {
        rgba[destination] = (uint8_t)(((layer->color.r * source_alpha +
            (float)rgba[destination] / 255.0f * destination_alpha *
            (1.0f - source_alpha)) / output_alpha) * 255.0f);
        rgba[destination + 1] = (uint8_t)(((layer->color.g * source_alpha +
            (float)rgba[destination + 1] / 255.0f * destination_alpha *
            (1.0f - source_alpha)) / output_alpha) * 255.0f);
        rgba[destination + 2] = (uint8_t)(((layer->color.b * source_alpha +
            (float)rgba[destination + 2] / 255.0f * destination_alpha *
            (1.0f - source_alpha)) / output_alpha) * 255.0f);
        rgba[destination + 3] = (uint8_t)(output_alpha * 255.0f);
      }
    }
    free(layer->alpha);
  }
  NimculusColorGlyphRaster *raster = allocate_color_glyph_raster();
  raster->valid = true;
  raster->glyph_id = glyph_id;
  raster->font_face = font_face;
  font_face->lpVtbl->AddRef(font_face);
  raster->font_size = font_size;
  raster->scale = scale;
  raster->subpixel_x = subpixel_x;
  raster->subpixel_y = subpixel_y;
  raster->bounds = union_bounds;
  raster->length = rgba_length;
  raster->pixels = rgba;
  raster->last_used = ++g_glyph_raster_clock;
  return true;
}

static bool rasterize_bitmap_glyph_for_cache(IDWriteFontFace *font_face,
                                             UINT16 glyph_id, float font_size,
                                             double scale, uint8_t subpixel_x,
                                             uint8_t subpixel_y,
                                             DWRITE_GLYPH_IMAGE_FORMATS format) {
  if (!font_face || !ensure_directwrite_factory() || !g_dwrite_factory4)
    return false;
  if (find_color_glyph_raster(font_face, glyph_id, font_size, scale,
                              subpixel_x, subpixel_y)) return true;
  IDWriteFontFace4 *font_face4 = NULL;
  HRESULT hr = font_face->lpVtbl->QueryInterface((IUnknown *)font_face,
      &IID_IDWriteFontFace4, (void **)&font_face4);
  if (FAILED(hr) || !font_face4) return false;
  UINT32 requested_ppem = (UINT32)floor((double)font_size * scale + 0.5);
  if (requested_ppem == 0) requested_ppem = 1;
  DWRITE_GLYPH_IMAGE_DATA image_data;
  ZeroMemory(&image_data, sizeof(image_data));
  void *image_context = NULL;
  hr = font_face4->lpVtbl->GetGlyphImageData(font_face4, glyph_id,
      requested_ppem, format, &image_data,
      &image_context);
  if (FAILED(hr) || !image_data.imageData || image_data.imageDataSize == 0 ||
      image_data.pixelsPerEm == 0 || image_data.pixelSize.width == 0 ||
      image_data.pixelSize.height == 0) {
    if (image_context) font_face4->lpVtbl->ReleaseGlyphImageData(font_face4,
        image_context);
    font_face4->lpVtbl->Release(font_face4);
    return false;
  }
  double image_scale = (double)requested_ppem / image_data.pixelsPerEm;
  uint32_t target_width = (uint32_t)floor(
      (double)image_data.pixelSize.width * image_scale + 0.5);
  uint32_t target_height = (uint32_t)floor(
      (double)image_data.pixelSize.height * image_scale + 0.5);
  uint32_t width = 0;
  uint32_t height = 0;
  uint8_t *pixels = NULL;
  bool valid = target_width > 0 && target_height > 0 &&
      decode_wic_rgba(image_data.imageData, image_data.imageDataSize,
                      target_width, target_height, &width, &height, &pixels);
  if (image_context) font_face4->lpVtbl->ReleaseGlyphImageData(font_face4,
      image_context);
  font_face4->lpVtbl->Release(font_face4);
  if (!valid || !pixels || width == 0 || height == 0 ||
      width >= NIMCULUS_GLYPH_ATLAS_SIZE || height >= NIMCULUS_GLYPH_ATLAS_SIZE) {
    free(pixels);
    return false;
  }
  NimculusColorGlyphRaster *raster = allocate_color_glyph_raster();
  raster->valid = true;
  raster->glyph_id = glyph_id;
  raster->font_face = font_face;
  font_face->lpVtbl->AddRef(font_face);
  raster->font_size = font_size;
  raster->scale = scale;
  raster->subpixel_x = subpixel_x;
  raster->subpixel_y = subpixel_y;
  raster->bounds.left = (LONG)floor(
      -(double)image_data.horizontalLeftOrigin.x * image_scale + 0.5);
  raster->bounds.top = (LONG)floor(
      -(double)image_data.horizontalLeftOrigin.y * image_scale + 0.5);
  raster->bounds.right = raster->bounds.left + (LONG)width;
  raster->bounds.bottom = raster->bounds.top + (LONG)height;
  raster->length = width * height * 4;
  raster->pixels = pixels;
  raster->last_used = ++g_glyph_raster_clock;
  return true;
}

static bool rasterize_png_glyph_for_cache(IDWriteFontFace *font_face,
                                          UINT16 glyph_id, float font_size,
                                          double scale, uint8_t subpixel_x,
                                          uint8_t subpixel_y) {
  return rasterize_bitmap_glyph_for_cache(font_face, glyph_id, font_size,
      scale, subpixel_x, subpixel_y, DWRITE_GLYPH_IMAGE_FORMATS_PNG);
}

static bool rasterize_jpeg_glyph_for_cache(IDWriteFontFace *font_face,
                                           UINT16 glyph_id, float font_size,
                                           double scale, uint8_t subpixel_x,
                                           uint8_t subpixel_y) {
  return rasterize_bitmap_glyph_for_cache(font_face, glyph_id, font_size,
      scale, subpixel_x, subpixel_y, DWRITE_GLYPH_IMAGE_FORMATS_JPEG);
}

static bool rasterize_premultiplied_glyph_for_cache(
    IDWriteFontFace *font_face, UINT16 glyph_id, float font_size,
    double scale, uint8_t subpixel_x, uint8_t subpixel_y) {
  if (!font_face || !ensure_directwrite_factory() || !g_dwrite_factory4)
    return false;
  if (find_color_glyph_raster(font_face, glyph_id, font_size, scale,
                              subpixel_x, subpixel_y)) return true;
  IDWriteFontFace4 *font_face4 = NULL;
  HRESULT hr = font_face->lpVtbl->QueryInterface((IUnknown *)font_face,
      &IID_IDWriteFontFace4, (void **)&font_face4);
  if (FAILED(hr) || !font_face4) return false;
  UINT32 requested_ppem = (UINT32)floor((double)font_size * scale + 0.5);
  if (requested_ppem == 0) requested_ppem = 1;
  DWRITE_GLYPH_IMAGE_DATA image_data;
  ZeroMemory(&image_data, sizeof(image_data));
  void *image_context = NULL;
  hr = font_face4->lpVtbl->GetGlyphImageData(font_face4, glyph_id,
      requested_ppem, DWRITE_GLYPH_IMAGE_FORMATS_PREMULTIPLIED_B8G8R8A8,
      &image_data, &image_context);
  bool has_data = SUCCEEDED(hr) && image_data.imageData &&
      image_data.imageDataSize >= (uint64_t)image_data.pixelSize.width *
          image_data.pixelSize.height * 4 && image_data.pixelsPerEm > 0 &&
      image_data.pixelSize.width > 0 && image_data.pixelSize.height > 0;
  if (!has_data) {
    if (image_context) font_face4->lpVtbl->ReleaseGlyphImageData(font_face4,
        image_context);
    font_face4->lpVtbl->Release(font_face4);
    return false;
  }
  double image_scale = (double)requested_ppem / image_data.pixelsPerEm;
  uint32_t width = (uint32_t)floor(
      (double)image_data.pixelSize.width * image_scale + 0.5);
  uint32_t height = (uint32_t)floor(
      (double)image_data.pixelSize.height * image_scale + 0.5);
  bool valid = width > 0 && height > 0 && width < NIMCULUS_GLYPH_ATLAS_SIZE &&
      height < NIMCULUS_GLYPH_ATLAS_SIZE &&
      (uint64_t)width * height <= UINT32_MAX / 4;
  uint8_t *pixels = valid ? (uint8_t *)malloc((size_t)width * height * 4) : NULL;
  const uint8_t *source = (const uint8_t *)image_data.imageData;
  if (pixels) {
    for (uint32_t y = 0; y < height; ++y) {
      uint32_t source_y = (uint32_t)floor((double)y / image_scale);
      if (source_y >= image_data.pixelSize.height)
        source_y = image_data.pixelSize.height - 1;
      for (uint32_t x = 0; x < width; ++x) {
        uint32_t source_x = (uint32_t)floor((double)x / image_scale);
        if (source_x >= image_data.pixelSize.width)
          source_x = image_data.pixelSize.width - 1;
        const uint8_t *source_pixel = source +
            ((size_t)source_y * image_data.pixelSize.width + source_x) * 4;
        uint8_t *destination = pixels + ((size_t)y * width + x) * 4;
        uint32_t alpha = source_pixel[3];
        destination[3] = (uint8_t)alpha;
        if (alpha == 0) {
          destination[0] = destination[1] = destination[2] = 0;
        } else {
          destination[0] = (uint8_t)((source_pixel[2] * 255u + alpha / 2u) /
              alpha);
          destination[1] = (uint8_t)((source_pixel[1] * 255u + alpha / 2u) /
              alpha);
          destination[2] = (uint8_t)((source_pixel[0] * 255u + alpha / 2u) /
              alpha);
        }
      }
    }
  }
  if (image_context) font_face4->lpVtbl->ReleaseGlyphImageData(font_face4,
      image_context);
  font_face4->lpVtbl->Release(font_face4);
  if (!pixels) return false;
  NimculusColorGlyphRaster *raster = allocate_color_glyph_raster();
  raster->valid = true;
  raster->glyph_id = glyph_id;
  raster->font_face = font_face;
  font_face->lpVtbl->AddRef(font_face);
  raster->font_size = font_size;
  raster->scale = scale;
  raster->subpixel_x = subpixel_x;
  raster->subpixel_y = subpixel_y;
  raster->bounds.left = (LONG)floor(
      -(double)image_data.horizontalLeftOrigin.x * image_scale + 0.5);
  raster->bounds.top = (LONG)floor(
      -(double)image_data.horizontalLeftOrigin.y * image_scale + 0.5);
  raster->bounds.right = raster->bounds.left + (LONG)width;
  raster->bounds.bottom = raster->bounds.top + (LONG)height;
  raster->length = width * height * 4;
  raster->pixels = pixels;
  raster->last_used = ++g_glyph_raster_clock;
  return true;
}

static uint8_t quantized_subpixel(double position) {
  double fraction = position - floor(position);
  int variant = (int)floor(fraction * 4.0 + 0.5);
  if (variant >= 4) variant = 0;
  if (variant < 0) variant = 0;
  return (uint8_t)variant;
}

static bool is_rtl_codepoint(uint32_t codepoint) {
  return (codepoint >= 0x0590 && codepoint <= 0x08ff) ||
      (codepoint >= 0xfb1d && codepoint <= 0xfdff) ||
      (codepoint >= 0xfe70 && codepoint <= 0xfeff) ||
      (codepoint >= 0x10800 && codepoint <= 0x10fff);
}

static bool editor_text_is_plain_ascii(void) {
  if (!g_editor_text || g_editor_text_length <= 0 ||
      g_editor_highlight_count != 0 || g_editor_composition_length != 0 ||
      g_editor_soft_wrap) return false;
  for (int index = 0; index < g_editor_text_length; ++index) {
    wchar_t character = g_editor_text[index];
    if (is_rtl_codepoint((uint32_t)character)) return false;
    if (character >= 0xd800 && character <= 0xdbff) {
      if (index + 1 < g_editor_text_length &&
          g_editor_text[index + 1] >= 0xdc00 &&
          g_editor_text[index + 1] <= 0xdfff) {
        index++;
        continue;
      }
      return false;
    }
    if (character >= 0xdc00 && character <= 0xdfff) return false;
    if (character == L'\n' || character == L'\r' ||
        (character >= 0x20 && character <= 0x7e) ||
        (character > 0x7e && character != 0x7f)) continue;
    return false;
  }
  return true;
}

static bool shape_run_with_font(const wchar_t *text, uint32_t text_length,
                                IDWriteFontFace *font_face,
                                const wchar_t *locale, float font_size,
                                UINT16 **glyph_indices,
                                DWRITE_GLYPH_OFFSET **offsets,
                                FLOAT **advances, uint32_t *glyph_count) {
  if (!text || text_length == 0 || !glyph_indices || !offsets || !advances ||
      !glyph_count || !font_face || !ensure_directwrite_factory() ||
      !g_dwrite_analyzer)
    return false;
  uint32_t max_glyphs = text_length * 2 + 16;
  if (max_glyphs > 8192) max_glyphs = 8192;
  UINT16 *cluster_map = (UINT16 *)calloc(text_length, sizeof(UINT16));
  DWRITE_SHAPING_TEXT_PROPERTIES *text_props =
      (DWRITE_SHAPING_TEXT_PROPERTIES *)calloc(text_length,
                                                sizeof(DWRITE_SHAPING_TEXT_PROPERTIES));
  UINT16 *indices = (UINT16 *)calloc(max_glyphs, sizeof(UINT16));
  DWRITE_SHAPING_GLYPH_PROPERTIES *glyph_props =
      (DWRITE_SHAPING_GLYPH_PROPERTIES *)calloc(max_glyphs,
                                                sizeof(DWRITE_SHAPING_GLYPH_PROPERTIES));
  FLOAT *glyph_advances = (FLOAT *)calloc(max_glyphs, sizeof(FLOAT));
  DWRITE_GLYPH_OFFSET *glyph_offsets =
      (DWRITE_GLYPH_OFFSET *)calloc(max_glyphs, sizeof(DWRITE_GLYPH_OFFSET));
  if (!cluster_map || !text_props || !indices || !glyph_props ||
      !glyph_advances || !glyph_offsets) {
    free(cluster_map); free(text_props); free(indices); free(glyph_props);
    free(glyph_advances); free(glyph_offsets);
    return false;
  }
  NimculusFallbackSource source;
  ZeroMemory(&source, sizeof(source));
  source.iface.lpVtbl = &g_fallback_source_vtable;
  source.references = 1;
  source.text = text;
  source.length = text_length;
  source.locale = locale ? locale : L"en-us";
  NimculusScriptSink sink;
  ZeroMemory(&sink, sizeof(sink));
  sink.iface.lpVtbl = &g_script_sink_vtable;
  sink.references = 1;
  sink.consistent = true;
  HRESULT hr = g_dwrite_analyzer->lpVtbl->AnalyzeScript(g_dwrite_analyzer,
      &source.iface, 0, text_length, &sink.iface);
  if (FAILED(hr) || !sink.has_script || !sink.consistent) {
    free(cluster_map); free(text_props); free(indices); free(glyph_props);
    free(glyph_advances); free(glyph_offsets);
    return false;
  }
  DWRITE_SCRIPT_ANALYSIS script = sink.script;
  UINT32 actual_glyphs = 0;
  hr = g_dwrite_analyzer->lpVtbl->GetGlyphs(g_dwrite_analyzer, text,
      text_length, font_face, FALSE, FALSE, &script, locale, NULL, NULL,
      NULL, 0, max_glyphs, cluster_map, text_props, indices, glyph_props,
      &actual_glyphs);
  if (SUCCEEDED(hr)) {
    hr = g_dwrite_analyzer->lpVtbl->GetGlyphPlacements(g_dwrite_analyzer, text,
        cluster_map, text_props, text_length, indices, glyph_props,
        actual_glyphs, font_face, font_size, FALSE, FALSE, &script, locale,
        NULL, NULL, 0, glyph_advances, glyph_offsets);
  }
  free(cluster_map);
  free(text_props);
  free(glyph_props);
  if (FAILED(hr) || actual_glyphs == 0) {
    free(indices); free(glyph_advances); free(glyph_offsets);
    return false;
  }
  *glyph_indices = indices;
  *advances = glyph_advances;
  *offsets = glyph_offsets;
  *glyph_count = actual_glyphs;
  return true;
}

static bool shape_ascii_run(const wchar_t *text, uint32_t text_length,
                            UINT16 **glyph_indices, DWRITE_GLYPH_OFFSET **offsets,
                            FLOAT **advances, uint32_t *glyph_count) {
  if (!text || text_length == 0) return false;
  for (uint32_t index = 0; index < text_length; ++index) {
    if (text[index] < 0x20 || text[index] > 0x7e) return false;
  }
  IDWriteFontFace *font_face = ensure_glyph_font_face();
  if (!font_face) return false;
  return shape_run_with_font(text, text_length, font_face, L"en-us",
      (FLOAT)g_editor_font_size, glyph_indices, offsets, advances, glyph_count);
}

static bool shape_fallback_run(const wchar_t *text, uint32_t text_length,
                               UINT16 **glyph_indices,
                               DWRITE_GLYPH_OFFSET **offsets,
                               FLOAT **advances, uint32_t *glyph_count,
                               IDWriteFontFace **font_face,
                               FLOAT *font_size) {
  if (!text || text_length == 0 || !font_face || !font_size) return false;
  UINT32 mapped_length = 0;
  FLOAT fallback_scale = 1.0f;
  IDWriteFontFace *fallback = map_fallback_font(text, text_length,
      &mapped_length, &fallback_scale);
  if (!fallback || mapped_length != text_length) {
    if (fallback) fallback->lpVtbl->Release(fallback);
    return false;
  }
  FLOAT mapped_size = (FLOAT)g_editor_font_size * fallback_scale;
  bool shaped = shape_run_with_font(text, text_length, fallback, L"ja-jp",
      mapped_size, glyph_indices, offsets, advances, glyph_count);
  if (!shaped) {
    fallback->lpVtbl->Release(fallback);
    return false;
  }
  *font_face = fallback;
  *font_size = mapped_size;
  return true;
}

static void free_shaped_run(UINT16 *glyph_indices, DWRITE_GLYPH_OFFSET *offsets,
                            FLOAT *advances) {
  free(glyph_indices);
  free(offsets);
  free(advances);
}

static void draw_cached_glyph_sprite(NimculusGlyphRaster *raster, float pen_x,
                                     float baseline, float left, float top,
                                     float right, float bottom, float width,
                                     float height, uint32_t *drawn) {
  if (!raster || !raster->atlas_valid || !drawn) return;
  float glyph_left = pen_x + (float)raster->bounds.left;
  float glyph_top = baseline + (float)raster->bounds.top;
  float glyph_right = glyph_left + (float)raster->atlas_width;
  float glyph_bottom = glyph_top + (float)raster->atlas_height;
  if (glyph_right <= left || glyph_left >= right || glyph_bottom <= top ||
      glyph_top >= bottom) return;
  float u0 = (float)raster->atlas_x / NIMCULUS_GLYPH_ATLAS_SIZE;
  float v0 = (float)raster->atlas_y / NIMCULUS_GLYPH_ATLAS_SIZE;
  float u1 = (float)(raster->atlas_x + raster->atlas_width) /
      NIMCULUS_GLYPH_ATLAS_SIZE;
  float v1 = (float)(raster->atlas_y + raster->atlas_height) /
      NIMCULUS_GLYPH_ATLAS_SIZE;
  NimculusQuadVertex vertices[6] = {
    {(glyph_left / width) * 2.0f - 1.0f, 1.0f - (glyph_top / height) * 2.0f,
      1.0f, 1.0f, 1.0f, 1.0f, u0, v0, 0, 0, 0, 0},
    {(glyph_right / width) * 2.0f - 1.0f, 1.0f - (glyph_top / height) * 2.0f,
      1.0f, 1.0f, 1.0f, 1.0f, u1, v0, 0, 0, 0, 0},
    {(glyph_right / width) * 2.0f - 1.0f, 1.0f - (glyph_bottom / height) * 2.0f,
      1.0f, 1.0f, 1.0f, 1.0f, u1, v1, 0, 0, 0, 0},
    {(glyph_left / width) * 2.0f - 1.0f, 1.0f - (glyph_top / height) * 2.0f,
      1.0f, 1.0f, 1.0f, 1.0f, u0, v0, 0, 0, 0, 0},
    {(glyph_right / width) * 2.0f - 1.0f, 1.0f - (glyph_bottom / height) * 2.0f,
      1.0f, 1.0f, 1.0f, 1.0f, u1, v1, 0, 0, 0, 0},
    {(glyph_left / width) * 2.0f - 1.0f, 1.0f - (glyph_bottom / height) * 2.0f,
      1.0f, 1.0f, 1.0f, 1.0f, u0, v1, 0, 0, 0, 0}
  };
  D3D11_MAPPED_SUBRESOURCE mapped;
  if (SUCCEEDED(g_context->lpVtbl->Map(g_context,
      (ID3D11Resource *)g_quad_vertex_buffer, 0, D3D11_MAP_WRITE_DISCARD,
      0, &mapped))) {
    memcpy(mapped.pData, vertices, sizeof(vertices));
    g_context->lpVtbl->Unmap(g_context, (ID3D11Resource *)g_quad_vertex_buffer, 0);
    g_context->lpVtbl->Draw(g_context, 6, 0);
    (*drawn)++;
  }
}

static void draw_cached_color_glyph_sprite(NimculusColorGlyphRaster *raster,
                                           float pen_x, float baseline,
                                           float left, float top, float right,
                                           float bottom, float width, float height,
                                           uint32_t *drawn) {
  if (!raster || !raster->atlas_valid || !drawn || !g_color_glyph_atlas_view)
    return;
  float glyph_left = pen_x + (float)raster->bounds.left;
  float glyph_top = baseline + (float)raster->bounds.top;
  float glyph_right = glyph_left + (float)raster->atlas_width;
  float glyph_bottom = glyph_top + (float)raster->atlas_height;
  if (glyph_right <= left || glyph_left >= right || glyph_bottom <= top ||
      glyph_top >= bottom) return;
  float u0 = (float)raster->atlas_x / NIMCULUS_GLYPH_ATLAS_SIZE;
  float v0 = (float)raster->atlas_y / NIMCULUS_GLYPH_ATLAS_SIZE;
  float u1 = (float)(raster->atlas_x + raster->atlas_width) /
      NIMCULUS_GLYPH_ATLAS_SIZE;
  float v1 = (float)(raster->atlas_y + raster->atlas_height) /
      NIMCULUS_GLYPH_ATLAS_SIZE;
  NimculusQuadVertex vertices[6] = {
    {(glyph_left / width) * 2.0f - 1.0f, 1.0f - (glyph_top / height) * 2.0f,
      1, 1, 1, 1, u0, v0, 0, 0, 0, 0},
    {(glyph_right / width) * 2.0f - 1.0f, 1.0f - (glyph_top / height) * 2.0f,
      1, 1, 1, 1, u1, v0, 0, 0, 0, 0},
    {(glyph_right / width) * 2.0f - 1.0f, 1.0f - (glyph_bottom / height) * 2.0f,
      1, 1, 1, 1, u1, v1, 0, 0, 0, 0},
    {(glyph_left / width) * 2.0f - 1.0f, 1.0f - (glyph_top / height) * 2.0f,
      1, 1, 1, 1, u0, v0, 0, 0, 0, 0},
    {(glyph_right / width) * 2.0f - 1.0f, 1.0f - (glyph_bottom / height) * 2.0f,
      1, 1, 1, 1, u1, v1, 0, 0, 0, 0},
    {(glyph_left / width) * 2.0f - 1.0f, 1.0f - (glyph_bottom / height) * 2.0f,
      1, 1, 1, 1, u0, v1, 0, 0, 0, 0}
  };
  D3D11_MAPPED_SUBRESOURCE mapped;
  if (SUCCEEDED(g_context->lpVtbl->Map(g_context,
      (ID3D11Resource *)g_quad_vertex_buffer, 0, D3D11_MAP_WRITE_DISCARD,
      0, &mapped))) {
    memcpy(mapped.pData, vertices, sizeof(vertices));
    g_context->lpVtbl->Unmap(g_context, (ID3D11Resource *)g_quad_vertex_buffer, 0);
    g_context->lpVtbl->PSSetShader(g_context, g_image_pixel_shader, NULL, 0);
    g_context->lpVtbl->PSSetShaderResources(g_context, 0, 1,
        &g_color_glyph_atlas_view);
    g_context->lpVtbl->PSSetSamplers(g_context, 0, 1, &g_image_sampler);
    g_context->lpVtbl->Draw(g_context, 6, 0);
    g_context->lpVtbl->PSSetShader(g_context, g_glyph_pixel_shader, NULL, 0);
    g_context->lpVtbl->PSSetShaderResources(g_context, 0, 1,
        &g_glyph_atlas_view);
    (*drawn)++;
  }
}

static bool draw_mapped_shaped_runs(const wchar_t *text, uint32_t text_length,
                                    float *pen_x, float baseline,
                                    uint8_t subpixel_y, float left, float top,
                                    float right, float bottom, float width,
                                    float height, float scale, uint32_t *drawn) {
  if (!text || text_length == 0 || !pen_x || !drawn) return false;
  uint32_t offset = 0;
  bool rendered = false;
  while (offset < text_length) {
    UINT32 mapped_length = 0;
    FLOAT run_scale = 1.0f;
    IDWriteFontFace *font_face = map_fallback_font(text + offset,
        text_length - offset, &mapped_length, &run_scale);
    if (!font_face || mapped_length == 0 || mapped_length > text_length - offset) {
      if (font_face) font_face->lpVtbl->Release(font_face);
      return false;
    }
    FLOAT run_font_size = (FLOAT)g_editor_font_size * run_scale;
    UINT16 *indices = NULL;
    DWRITE_GLYPH_OFFSET *offsets = NULL;
    FLOAT *advances = NULL;
    uint32_t glyph_count = 0;
    bool shaped = shape_run_with_font(text + offset, mapped_length, font_face,
        L"ja-jp", run_font_size, &indices, &offsets, &advances,
        &glyph_count);
    if (!shaped) {
      font_face->lpVtbl->Release(font_face);
      free_shaped_run(indices, offsets, advances);
      return false;
    }
    bool run_has_surrogate = false;
    for (uint32_t text_index = 0; text_index < mapped_length; ++text_index) {
      if (text[offset + text_index] >= 0xd800 &&
          text[offset + text_index] <= 0xdfff) {
        run_has_surrogate = true;
        break;
      }
    }
    for (uint32_t index = 0; index < glyph_count; ++index) {
      UINT16 glyph_id = indices[index];
      uint8_t subpixel_x = quantized_subpixel(*pen_x +
          offsets[index].advanceOffset * scale);
      bool rendered_color = false;
      bool color_prepared = false;
      if (run_has_surrogate) {
        color_prepared = rasterize_color_glyph_for_cache(font_face, glyph_id,
            run_font_size, scale, subpixel_x, subpixel_y);
        if (!color_prepared) {
          color_prepared = rasterize_png_glyph_for_cache(font_face, glyph_id,
              run_font_size, scale, subpixel_x, subpixel_y);
        }
        if (!color_prepared) {
          color_prepared = rasterize_jpeg_glyph_for_cache(font_face, glyph_id,
              run_font_size, scale, subpixel_x, subpixel_y);
        }
        if (!color_prepared) {
          color_prepared = rasterize_premultiplied_glyph_for_cache(font_face,
              glyph_id, run_font_size, scale, subpixel_x, subpixel_y);
        }
      }
      if (run_has_surrogate && color_prepared) {
        NimculusColorGlyphRaster *color = find_color_glyph_raster(font_face,
            glyph_id, run_font_size, scale, subpixel_x, subpixel_y);
        if (color && upload_color_glyph_to_atlas(color)) {
          draw_cached_color_glyph_sprite(color,
              *pen_x + offsets[index].advanceOffset * scale,
              baseline - offsets[index].ascenderOffset * scale,
              left, top, right, bottom, width, height, drawn);
          rendered_color = true;
          rendered = true;
        }
      }
      if (!rendered_color && !run_has_surrogate &&
          rasterize_glyph_id_for_cache(font_face, glyph_id, run_font_size,
                                       scale, subpixel_x, subpixel_y)) {
        NimculusGlyphRaster *raster = cached_glyph_for_id(font_face, glyph_id,
            run_font_size, scale, subpixel_x, subpixel_y);
        if (raster && upload_glyph_raster_to_atlas(raster)) {
          draw_cached_glyph_sprite(raster,
              *pen_x + offsets[index].advanceOffset * scale,
              baseline - offsets[index].ascenderOffset * scale,
              left, top, right, bottom, width, height, drawn);
          rendered = true;
        }
      }
      *pen_x += advances[index] * scale;
    }
    free_shaped_run(indices, offsets, advances);
    font_face->lpVtbl->Release(font_face);
    offset += mapped_length;
  }
  return rendered;
}

static bool draw_glyph_atlas_sprites(void) {
  if (!g_context || !g_glyph_atlas_view || !g_glyph_pixel_shader ||
      !g_quad_vertex_buffer || !g_quad_input_layout || !g_quad_vertex_shader ||
      !g_quad_rasterizer || !g_quad_blend_state || !g_image_sampler ||
      !editor_text_is_plain_ascii()) return false;
  double scale = g_metrics.scale_factor > 0.0 ? g_metrics.scale_factor : 1.0;
  float font_size = (float)g_editor_font_size;
  float line_height = (font_size + 2.0f) * (float)scale;
  float left = (float)(g_editor_rect[0] * scale);
  float top = (float)(g_editor_rect[1] * scale);
  float right = (float)((g_editor_rect[0] + g_editor_rect[2]) * scale);
  float bottom = (float)((g_editor_rect[1] + g_editor_rect[3]) * scale);
  float width = (float)g_metrics.width_pixels;
  float height = (float)g_metrics.height_pixels;
  if (right <= left || bottom <= top || width <= 0.0f || height <= 0.0f) return false;
  IDWriteFontFace *font_face = ensure_glyph_font_face();
  if (!font_face) return false;
  UINT stride = sizeof(NimculusQuadVertex);
  UINT offset = 0;
  g_context->lpVtbl->IASetInputLayout(g_context, g_quad_input_layout);
  g_context->lpVtbl->IASetVertexBuffers(g_context, 0, 1, &g_quad_vertex_buffer,
                                         &stride, &offset);
  g_context->lpVtbl->IASetPrimitiveTopology(g_context,
                                             D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
  g_context->lpVtbl->VSSetShader(g_context, g_quad_vertex_shader, NULL, 0);
  g_context->lpVtbl->PSSetShader(g_context, g_glyph_pixel_shader, NULL, 0);
  g_context->lpVtbl->PSSetShaderResources(g_context, 0, 1, &g_glyph_atlas_view);
  g_context->lpVtbl->PSSetSamplers(g_context, 0, 1, &g_image_sampler);
  g_context->lpVtbl->RSSetState(g_context, g_quad_rasterizer);
  const FLOAT blend_factor[4] = {0.0f, 0.0f, 0.0f, 0.0f};
  g_context->lpVtbl->OMSetBlendState(g_context, g_quad_blend_state,
                                     blend_factor, 0xffffffffu);
  LONG clip_left = (LONG)left;
  LONG clip_top = (LONG)top;
  LONG clip_right = (LONG)right;
  LONG clip_bottom = (LONG)bottom;
  if (clip_left < 0) clip_left = 0;
  if (clip_top < 0) clip_top = 0;
  if (clip_right > (LONG)g_metrics.width_pixels) clip_right = (LONG)g_metrics.width_pixels;
  if (clip_bottom > (LONG)g_metrics.height_pixels) clip_bottom = (LONG)g_metrics.height_pixels;
  if (clip_right <= clip_left || clip_bottom <= clip_top) return false;
  D3D11_RECT scissor = {clip_left, clip_top, clip_right, clip_bottom};
  g_context->lpVtbl->RSSetScissorRects(g_context, 1, &scissor);
  uint32_t visible_lines = (uint32_t)(g_editor_rect[3] /
      (g_editor_font_size + 2.0)) + 2;
  uint32_t line = 0;
  uint32_t drawn = 0;
  const wchar_t *line_start = g_editor_text;
  const wchar_t *end = g_editor_text + g_editor_text_length;
  while (line_start <= end && line < g_editor_scroll_line + visible_lines) {
    const wchar_t *line_end = line_start;
    while (line_end < end && *line_end != L'\n') line_end++;
    if (line >= g_editor_scroll_line) {
      float baseline = top + (float)(line - g_editor_scroll_line) * line_height +
          font_size * (float)scale;
      uint8_t subpixel_y = quantized_subpixel(baseline);
      float pen_x = left;
      UINT16 *shaped_indices = NULL;
      DWRITE_GLYPH_OFFSET *shaped_offsets = NULL;
      FLOAT *shaped_advances = NULL;
      uint32_t shaped_count = 0;
      if (shape_ascii_run(line_start, (uint32_t)(line_end - line_start),
                          &shaped_indices, &shaped_offsets, &shaped_advances,
                          &shaped_count)) {
        for (uint32_t glyph_index = 0; glyph_index < shaped_count; ++glyph_index) {
          UINT16 glyph_id = shaped_indices[glyph_index];
          uint8_t subpixel_x = quantized_subpixel(pen_x +
              shaped_offsets[glyph_index].advanceOffset * (float)scale);
          if (rasterize_glyph_id_for_cache(font_face, glyph_id, font_size, scale,
                                           subpixel_x, subpixel_y)) {
            NimculusGlyphRaster *raster = cached_glyph_for_id(font_face, glyph_id,
                font_size, scale, subpixel_x, subpixel_y);
            if (raster && upload_glyph_raster_to_atlas(raster)) {
              draw_cached_glyph_sprite(raster,
                  pen_x + shaped_offsets[glyph_index].advanceOffset * (float)scale,
                  baseline - shaped_offsets[glyph_index].ascenderOffset * (float)scale,
                  left, top, right, bottom, width, height, &drawn);
            }
          }
          pen_x += shaped_advances[glyph_index] * (float)scale;
        }
        free_shaped_run(shaped_indices, shaped_offsets, shaped_advances);
      } else if (!draw_mapped_shaped_runs(line_start,
                  (uint32_t)(line_end - line_start), &pen_x, baseline,
                  subpixel_y, left, top, right, bottom, width, height,
                  (float)scale, &drawn)) {
        for (const wchar_t *character = line_start; character < line_end;
             ++character) {
        uint32_t codepoint = (uint32_t)*character;
        if (codepoint == L'\r') continue;
        if (codepoint >= 0x20 && codepoint != 0x7f &&
            !(codepoint >= 0xd800 && codepoint <= 0xdfff)) {
          uint8_t subpixel_x = quantized_subpixel(pen_x);
          if (!rasterize_glyph_for_cache(codepoint, font_size, scale,
                                         subpixel_x, subpixel_y)) {
            continue;
          }
          NimculusGlyphRaster *raster = cached_glyph_for_codepoint(
              codepoint, font_size, scale, subpixel_x, subpixel_y);
          if (raster) {
            float advance = glyph_advance_pixels(raster->font_face,
                raster->glyph_id, raster->font_size, scale);
            if (upload_glyph_raster_to_atlas(raster)) {
              draw_cached_glyph_sprite(raster, pen_x, baseline, left, top,
                  right, bottom, width, height, &drawn);
            }
            pen_x += advance;
          }
        }
        }
      }
    }
    if (line_end >= end) break;
    line_start = line_end + 1;
    line++;
  }
  ID3D11ShaderResourceView *none = NULL;
  g_context->lpVtbl->PSSetShaderResources(g_context, 0, 1, &none);
  return drawn > 0;
}

static void editor_line_byte_range(uint32_t target_line, uint32_t *start,
                                   uint32_t *end) {
  uint32_t line = 0;
  uint32_t line_start = 0;
  for (uint32_t index = 0; index < g_editor_utf8_length; ++index) {
    if (g_editor_utf8[index] == '\n') {
      if (line == target_line) {
        if (start) *start = line_start;
        if (end) *end = index;
        return;
      }
      line++;
      line_start = index + 1;
    }
  }
  if (line == target_line) {
    if (start) *start = line_start;
    if (end) *end = g_editor_utf8_length;
  } else {
    if (start) *start = g_editor_utf8_length;
    if (end) *end = g_editor_utf8_length;
  }
}

static uint32_t utf16_units_for_utf8(const char *text, uint32_t length) {
  if (!text || length == 0) return 0;
  int units = MultiByteToWideChar(CP_UTF8, 0, text, (int)length, NULL, 0);
  return units > 0 ? (uint32_t)units : 0;
}

static void highlight_color(uint32_t kind, D2D1_COLOR_F *color) {
  if (!color) return;
  color->r = 0.85f;
  color->g = 0.90f;
  color->b = 1.0f;
  color->a = 1.0f;
  switch (kind % 6) {
    case 0: color->r = 0.35f; color->g = 0.70f; color->b = 1.0f; break;
    case 1: color->r = 0.95f; color->g = 0.65f; color->b = 0.35f; break;
    case 2: color->r = 0.80f; color->g = 0.55f; color->b = 1.0f; break;
    case 3: color->r = 0.45f; color->g = 0.75f; color->b = 0.50f; break;
    case 5: color->r = 0.65f; color->g = 0.70f; color->b = 0.78f; break;
    default: break;
  }
}

static bool render_editor_directwrite(void) {
  if (!g_d2d_target || !g_d2d_text_brush || !g_editor_text ||
      g_editor_text_length <= 0) return false;
  double scale = g_metrics.scale_factor > 0.0 ? g_metrics.scale_factor : 1.0;
  float left = (float)(g_editor_rect[0] * scale);
  float top = (float)(g_editor_rect[1] * scale);
  float right = (float)((g_editor_rect[0] + g_editor_rect[2]) * scale);
  float bottom = (float)((g_editor_rect[1] + g_editor_rect[3]) * scale);
  if (right <= left || bottom <= top) return false;
  HRESULT hr;
  IDWriteTextFormat *format = ensure_editor_text_format(scale);
  if (!format) return false;
  ID2D1SolidColorBrush *selection_brush = NULL;
  D2D1_COLOR_F selection_color = {0.22f, 0.30f, 0.44f, 1.0f};
  hr = g_d2d_target->lpVtbl->CreateSolidColorBrush(g_d2d_target,
      &selection_color, NULL, &selection_brush);
  if (FAILED(hr)) {
    return false;
  }
  ID2D1SolidColorBrush *highlight_brushes[6] = {NULL, NULL, NULL, NULL, NULL, NULL};
  for (uint32_t kind = 0; kind < 6; ++kind) {
    D2D1_COLOR_F color;
    highlight_color(kind, &color);
    hr = g_d2d_target->lpVtbl->CreateSolidColorBrush(g_d2d_target, &color,
        NULL, &highlight_brushes[kind]);
    if (FAILED(hr)) {
      for (uint32_t index = 0; index < kind; ++index)
        highlight_brushes[index]->lpVtbl->Release(highlight_brushes[index]);
      selection_brush->lpVtbl->Release(selection_brush);
      return false;
    }
  }
  g_d2d_target->lpVtbl->BeginDraw(g_d2d_target);
  D2D1_RECT_F clip = {left, top, right, bottom};
  g_d2d_target->lpVtbl->PushAxisAlignedClip(g_d2d_target, &clip,
      D2D1_ANTIALIAS_MODE_PER_PRIMITIVE);
  uint32_t selection_start = g_editor_selection_start;
  uint32_t selection_end = g_editor_selection_end;
  if (selection_start > selection_end) {
    uint32_t temporary = selection_start;
    selection_start = selection_end;
    selection_end = temporary;
  }
  uint32_t start_line = 0, start_column = 0, end_line = 0, end_column = 0;
  editor_byte_position(selection_start, &start_line, &start_column);
  editor_byte_position(selection_end, &end_line, &end_column);
  float line_height = (float)((g_editor_font_size + 2.0) * scale);
  if (selection_start < selection_end) {
    for (uint32_t selected_line = start_line; selected_line <= end_line; ++selected_line) {
      if (selected_line < g_editor_scroll_line) continue;
      float line_top = top + (float)(selected_line - g_editor_scroll_line) * line_height;
      if (line_top >= bottom) break;
      uint32_t first_column = selected_line == start_line ? start_column : 0;
      uint32_t last_column = selected_line == end_line
          ? end_column : editor_line_length(selected_line);
      if (last_column > first_column) {
        D2D1_RECT_F selected = {
          left + (float)(8 + first_column * 8) * (float)scale,
          line_top,
          left + (float)(8 + last_column * 8) * (float)scale,
          line_top + line_height};
        g_d2d_target->lpVtbl->FillRectangle(g_d2d_target, &selected,
            (ID2D1Brush *)selection_brush);
      }
    }
  }
  uint32_t line = 0;
  const wchar_t *line_start = g_editor_text;
  const wchar_t *end = g_editor_text + g_editor_text_length;
  while (line_start <= end &&
      (line < g_editor_scroll_line ||
       top + (float)(line - g_editor_scroll_line) * line_height < bottom)) {
    const wchar_t *line_end = line_start;
    while (line_end < end && *line_end != L'\n') line_end++;
    if (line >= g_editor_scroll_line) {
      float line_top = top + (float)(line - g_editor_scroll_line) * line_height;
      if (line_top + line_height > top) {
        D2D1_RECT_F text_rect = {left, line_top, right, line_top + line_height};
        UINT32 length = (UINT32)(line_end - line_start);
        if (length > 0 && line_start[length - 1] == L'\r') length--;
        if (length > 0) {
          IDWriteTextLayout *layout = NULL;
          hr = g_dwrite_factory->lpVtbl->CreateTextLayout(g_dwrite_factory,
              line_start, length, format, text_rect.right - text_rect.left,
              text_rect.bottom - text_rect.top, &layout);
          if (SUCCEEDED(hr) && layout) {
            uint32_t line_start_byte = 0, line_end_byte = 0;
            editor_line_byte_range(line, &line_start_byte, &line_end_byte);
            for (uint32_t span_index = 0; span_index < g_editor_highlight_count;
                 ++span_index) {
              NimculusHighlightSpan span = g_editor_highlights[span_index];
              if (span.end_byte <= line_start_byte ||
                  span.start_byte >= line_end_byte) continue;
              uint32_t start_byte = span.start_byte > line_start_byte
                  ? span.start_byte - line_start_byte : 0;
              uint32_t end_byte = span.end_byte < line_end_byte
                  ? span.end_byte - line_start_byte : line_end_byte - line_start_byte;
              if (end_byte <= start_byte || start_byte > UINT32_MAX) continue;
              if (end_byte > line_end_byte - line_start_byte)
                end_byte = line_end_byte - line_start_byte;
              const char *line_utf8 = g_editor_utf8 + line_start_byte;
              uint32_t start_units = utf16_units_for_utf8(line_utf8, start_byte);
              uint32_t span_units = utf16_units_for_utf8(line_utf8 + start_byte,
                  end_byte - start_byte);
              if (span_units == 0 || start_units >= length) continue;
              if (start_units + span_units > length) span_units = length - start_units;
              DWRITE_TEXT_RANGE range = {start_units, span_units};
              layout->lpVtbl->SetDrawingEffect(layout,
                  (IUnknown *)highlight_brushes[span.kind % 6], range);
            }
            D2D1_POINT_2F origin = {text_rect.left, text_rect.top};
            g_d2d_target->lpVtbl->DrawTextLayout(g_d2d_target, origin, layout,
                (ID2D1Brush *)g_d2d_text_brush, D2D1_DRAW_TEXT_OPTIONS_NO_SNAP);
            layout->lpVtbl->Release(layout);
          }
        }
      }
    }
    if (line_end >= end) break;
    line_start = line_end + 1;
    line++;
  }
  if (g_editor_cursor_line >= g_editor_scroll_line) {
    float cursor_top = top + (float)(g_editor_cursor_line - g_editor_scroll_line) * line_height;
    if (cursor_top < bottom && cursor_top + line_height > top) {
      if (g_editor_composition && g_editor_composition_length > 0) {
        IDWriteTextLayout *composition_layout = NULL;
        float composition_x = (float)(g_editor_cursor_x * scale);
        float composition_width = max(1.0f, right - composition_x);
        hr = g_dwrite_factory->lpVtbl->CreateTextLayout(g_dwrite_factory,
            g_editor_composition, (UINT32)g_editor_composition_length,
            format, composition_width, line_height, &composition_layout);
        if (SUCCEEDED(hr) && composition_layout) {
          DWRITE_TEXT_RANGE composition_range = {0,
              (UINT32)g_editor_composition_length};
          composition_layout->lpVtbl->SetUnderline(composition_layout, TRUE,
              composition_range);
          D2D1_POINT_2F composition_origin = {composition_x, cursor_top};
          g_d2d_target->lpVtbl->DrawTextLayout(g_d2d_target,
              composition_origin, composition_layout,
              (ID2D1Brush *)g_d2d_text_brush, D2D1_DRAW_TEXT_OPTIONS_NO_SNAP);
          composition_layout->lpVtbl->Release(composition_layout);
        }
      }
      D2D1_RECT_F cursor = {(float)(g_editor_cursor_x * scale),
          cursor_top + 2.0f * (float)scale,
          (float)(g_editor_cursor_x * scale) + (float)scale,
          cursor_top + line_height - 2.0f * (float)scale};
      g_d2d_target->lpVtbl->FillRectangle(g_d2d_target, &cursor,
          (ID2D1Brush *)g_d2d_text_brush);
    }
  }
  g_d2d_target->lpVtbl->PopAxisAlignedClip(g_d2d_target);
  hr = g_d2d_target->lpVtbl->EndDraw(g_d2d_target, NULL, NULL);
  for (uint32_t kind = 0; kind < 6; ++kind)
    highlight_brushes[kind]->lpVtbl->Release(highlight_brushes[kind]);
  selection_brush->lpVtbl->Release(selection_brush);
  if (FAILED(hr)) {
    release_directwrite_target();
    return false;
  }
  return true;
}

static COLORREF terminal_indexed_color(uint32_t index, bool background) {
  static const BYTE palette[16][3] = {
    {0, 0, 0}, {205, 49, 49}, {13, 188, 121}, {229, 229, 16},
    {36, 114, 200}, {188, 63, 188}, {17, 168, 205}, {229, 229, 229},
    {102, 102, 102}, {241, 76, 76}, {35, 209, 139}, {245, 245, 67},
    {59, 142, 234}, {214, 112, 214}, {41, 184, 219}, {255, 255, 255}
  };
  if (index < 16) return RGB(palette[index][0], palette[index][1], palette[index][2]);
  if (index >= 232) {
    BYTE value = (BYTE)(8 + (index - 232) * 10);
    return RGB(value, value, value);
  }
  index -= 16;
  BYTE red = (BYTE)((index / 36) * 51);
  BYTE green = (BYTE)(((index / 6) % 6) * 51);
  BYTE blue = (BYTE)((index % 6) * 51);
  return RGB(red, green, blue);
}

static COLORREF terminal_run_color(const NimculusTerminalRun *run, bool foreground) {
  if (!run) return foreground ? RGB(220, 225, 235) : RGB(15, 18, 24);
  bool source_foreground = foreground;
  if ((run->flags & 16u) != 0) source_foreground = !source_foreground;
  uint32_t kind = source_foreground ? run->foreground_kind : run->background_kind;
  uint32_t index = source_foreground ? run->foreground_index : run->background_index;
  COLORREF color;
  if (kind == 2) {
    color = RGB(source_foreground ? run->foreground_red : run->background_red,
        source_foreground ? run->foreground_green : run->background_green,
        source_foreground ? run->foreground_blue : run->background_blue);
  } else if (kind == 1) {
    color = terminal_indexed_color(index, !foreground);
  } else {
    color = source_foreground ? RGB(220, 225, 235) : RGB(15, 18, 24);
  }
  if (foreground && (run->flags & 2u) != 0) {
    color = RGB(GetRValue(color) / 2, GetGValue(color) / 2, GetBValue(color) / 2);
  }
  return color;
}

static void render_terminal_runs(HDC dc, const RECT *rect, HFONT font,
                                 LONG line_height, LONG cell_width) {
  if (!dc || !rect || !font || !g_terminal_utf8 || g_terminal_run_count == 0) return;
  uint32_t selected_start_row = g_terminal_selection_start_row;
  uint32_t selected_end_row = g_terminal_selection_end_row;
  uint32_t selected_start_column = g_terminal_selection_start_column;
  uint32_t selected_end_column = g_terminal_selection_end_column;
  if (selected_start_row > selected_end_row ||
      (selected_start_row == selected_end_row &&
       selected_start_column > selected_end_column)) {
    uint32_t temporary = selected_start_row;
    selected_start_row = selected_end_row;
    selected_end_row = temporary;
    temporary = selected_start_column;
    selected_start_column = selected_end_column;
    selected_end_column = temporary;
  }
  HBRUSH selection_brush = CreateSolidBrush(RGB(55, 76, 112));
  SetBkMode(dc, TRANSPARENT);
  for (uint32_t run_index = 0; run_index < g_terminal_run_count; ++run_index) {
    NimculusTerminalRun *run = &g_terminal_runs[run_index];
    if (run->start_byte >= g_terminal_utf8_length || run->end_byte <= run->start_byte) continue;
    uint32_t start = run->start_byte;
    uint32_t end = min(run->end_byte, g_terminal_utf8_length);
    uint32_t row = run->row;
    uint32_t column = run->column;
    LONG run_cell_width = (LONG)(run->cell_width > 0 ? run->cell_width : 1);
    uint32_t byte_length = end - start;
    wchar_t wide[2048];
    int wide_length = MultiByteToWideChar(CP_UTF8, 0, g_terminal_utf8 + start,
        (int)min(byte_length, (uint32_t)sizeof(wide) / sizeof(wide[0]) - 1),
        wide, (int)(sizeof(wide) / sizeof(wide[0]) - 1));
    if (wide_length <= 0) continue;
    wide[wide_length] = L'\0';
    LONG x = rect->left + (LONG)column * cell_width;
    LONG y = rect->top + (LONG)row * line_height;
    RECT text_rect = {x, y, rect->right - 8, y + line_height};
    if (run->background_kind != 0 || (run->flags & 16u) != 0) {
      HBRUSH background = CreateSolidBrush(terminal_run_color(run, false));
      RECT background_rect = {x, y,
          min(rect->right, x + max(cell_width, run_cell_width * cell_width)),
          y + line_height};
      FillRect(dc, &background_rect, background);
      DeleteObject(background);
    }
    if (row >= selected_start_row && row <= selected_end_row) {
      uint32_t selection_left = row == selected_start_row ? selected_start_column : 0;
      uint32_t selection_right = row == selected_end_row ? selected_end_column : 1000000;
      if (selection_right > selection_left) {
        RECT selected = {rect->left + (LONG)selection_left * cell_width, y,
            rect->left + (LONG)selection_right * cell_width, y + line_height};
        FillRect(dc, &selected, selection_brush);
      }
    }
    HFONT run_font = font;
    if ((run->flags & 1u) != 0 || (run->flags & 4u) != 0) {
      double scale = g_metrics.scale_factor > 0.0 ? g_metrics.scale_factor : 1.0;
      HFONT styled_font = CreateFontW(font_height(g_terminal_font_size, scale), 0, 0, 0,
          (run->flags & 1u) != 0 ? FW_BOLD : FW_NORMAL,
          (run->flags & 4u) != 0, FALSE, FALSE, DEFAULT_CHARSET,
          OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
          FIXED_PITCH | FF_MODERN, g_terminal_font_name);
      if (styled_font) run_font = styled_font;
    }
    HGDIOBJ old_run_font = SelectObject(dc, run_font);
    SetTextColor(dc, terminal_run_color(run, true));
    DrawTextW(dc, wide, wide_length, &text_rect,
        DT_LEFT | DT_TOP | DT_SINGLELINE | DT_NOPREFIX | DT_NOCLIP);
    SelectObject(dc, old_run_font);
    if (run_font != font) DeleteObject(run_font);
    if ((run->flags & 8u) != 0 || (run->flags & 32u) != 0) {
      HPEN pen = CreatePen(PS_SOLID, 1, terminal_run_color(run, true));
      HGDIOBJ old_pen = SelectObject(dc, pen);
      LONG extent = max(cell_width, run_cell_width * cell_width);
      if ((run->flags & 8u) != 0) {
        MoveToEx(dc, x, y + line_height - 2, NULL);
        LineTo(dc, min(rect->right - 8, x + extent), y + line_height - 2);
      }
      if ((run->flags & 32u) != 0) {
        MoveToEx(dc, x, y + line_height / 2, NULL);
        LineTo(dc, min(rect->right - 8, x + extent), y + line_height / 2);
      }
      SelectObject(dc, old_pen);
      DeleteObject(pen);
    }
  }
  DeleteObject(selection_brush);
}

static void render_frame(void) {
  LARGE_INTEGER frame_start;
  QueryPerformanceCounter(&frame_start);
  g_directwrite_frame = false;
  if (!g_context || !g_render_target || !g_swap_chain) return;
  const FLOAT clear_color[4] = {0.10f, 0.12f, 0.16f, 1.0f};
  g_context->lpVtbl->OMSetRenderTargets(g_context, 1, &g_render_target, NULL);
  g_context->lpVtbl->ClearRenderTargetView(g_context, g_render_target, clear_color);
  D3D11_VIEWPORT viewport = {0.0f, 0.0f, (FLOAT)g_metrics.width_pixels,
                             (FLOAT)g_metrics.height_pixels, 0.0f, 1.0f};
  g_context->lpVtbl->RSSetViewports(g_context, 1, &viewport);
  draw_paint_quads();
  g_directwrite_frame = render_editor_directwrite();
  prepare_visible_glyph_atlas();
  if (draw_glyph_atlas_sprites()) g_directwrite_frame = true;
  HRESULT present = g_swap_chain->lpVtbl->Present(g_swap_chain, 1, 0);
  if (SUCCEEDED(present)) {
    if (g_qpc_frequency.QuadPart == 0)
      QueryPerformanceFrequency(&g_qpc_frequency);
    LARGE_INTEGER frame_end;
    QueryPerformanceCounter(&frame_end);
    if (g_qpc_frequency.QuadPart > 0) {
      g_metrics.last_frame_time_ms =
          (double)(frame_end.QuadPart - frame_start.QuadPart) * 1000.0 /
          (double)g_qpc_frequency.QuadPart;
      if (g_first_input_qpc.QuadPart > 0) {
        g_metrics.last_input_latency_ms =
            (double)(frame_end.QuadPart - g_first_input_qpc.QuadPart) *
            1000.0 / (double)g_qpc_frequency.QuadPart;
        g_first_input_qpc.QuadPart = 0;
      }
    }
    g_metrics.frame_count++;
  } else if (present == DXGI_ERROR_DEVICE_REMOVED ||
             present == DXGI_ERROR_DEVICE_RESET ||
             present == DXGI_ERROR_DRIVER_INTERNAL_ERROR) {
    recreate_device();
  }
}

static void render_terminal_overlay(void) {
  if (!g_window || (!g_terminal_visible && !g_task_output_visible)) return;
  bool task_output = !g_terminal_visible && g_task_output_visible;
  HDC dc = GetDC(g_window);
  if (!dc) return;
  RECT rect;
  GetClientRect(g_window, &rect);
  LONG height = min(280L, max(120L, (rect.bottom - rect.top) / 3));
  rect.top = rect.bottom - height;
  double scale = g_metrics.scale_factor > 0.0 ? g_metrics.scale_factor : 1.0;
  HBRUSH background = CreateSolidBrush(task_output ? RGB(22, 24, 30) : RGB(15, 18, 24));
  FillRect(dc, &rect, background);
  DeleteObject(background);
  SetBkMode(dc, TRANSPARENT);
  SetTextColor(dc, task_output ? RGB(232, 235, 242) : RGB(220, 225, 235));
  HFONT font = CreateFontW(font_height(g_terminal_font_size, scale), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
      DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
      FIXED_PITCH | FF_MODERN, g_terminal_font_name);
  HGDIOBJ old_font = SelectObject(dc, font);
  rect.left += 8;
  rect.right -= 8;
  rect.top += 6;
  if (task_output) {
    DrawTextW(dc, g_task_output_text, -1, &rect,
        DT_LEFT | DT_TOP | DT_NOPREFIX | DT_WORDBREAK);
  } else if (g_terminal_run_count > 0 && g_terminal_utf8) {
    TEXTMETRICW metrics;
    GetTextMetricsW(dc, &metrics);
    LONG line_height = max(1L, metrics.tmHeight + (LONG)(2.0 * scale));
    SIZE cell_size;
    GetTextExtentPoint32W(dc, L"M", 1, &cell_size);
    render_terminal_runs(dc, &rect, font, line_height, max(1L, cell_size.cx));
  } else {
    DrawTextW(dc, g_terminal_text, -1, &rect,
        DT_LEFT | DT_TOP | DT_NOPREFIX | DT_WORDBREAK);
  }
  SelectObject(dc, old_font);
  DeleteObject(font);
  ReleaseDC(g_window, dc);
}

static void render_editor_overlay(void) {
  if (!g_window || !g_editor_text || g_editor_text_length <= 0) return;
  HDC dc = GetDC(g_window);
  if (!dc) return;
  RECT client;
  GetClientRect(g_window, &client);
  double scale = g_metrics.scale_factor > 0.0 ? g_metrics.scale_factor : 1.0;
  LONG left = (LONG)(g_editor_rect[0] * scale);
  LONG top = (LONG)(g_editor_rect[1] * scale);
  LONG right = (LONG)((g_editor_rect[0] + g_editor_rect[2]) * scale);
  LONG bottom = (LONG)((g_editor_rect[1] + g_editor_rect[3]) * scale);
  SetBkMode(dc, TRANSPARENT);
  SetTextColor(dc, RGB(215, 218, 224));
  HFONT font = CreateFontW(font_height(g_editor_font_size, scale), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
      DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
      FIXED_PITCH | FF_MODERN, g_editor_font_name);
  HGDIOBJ old_font = SelectObject(dc, font);
  TEXTMETRICW metrics;
  GetTextMetricsW(dc, &metrics);
  LONG line_height = max(1L, metrics.tmHeight + (LONG)(2.0 * scale));
  uint32_t selection_start = g_editor_selection_start;
  uint32_t selection_end = g_editor_selection_end;
  if (selection_start > selection_end) {
    uint32_t temporary = selection_start;
    selection_start = selection_end;
    selection_end = temporary;
  }
  if (selection_start < selection_end && g_editor_utf8) {
    uint32_t start_line = 0, start_column = 0, end_line = 0, end_column = 0;
    editor_byte_position(selection_start, &start_line, &start_column);
    editor_byte_position(selection_end, &end_line, &end_column);
    HBRUSH selection_brush = CreateSolidBrush(RGB(55, 76, 112));
    for (uint32_t selected_line = start_line; selected_line <= end_line; ++selected_line) {
      if (selected_line < g_editor_scroll_line) continue;
      LONG line_top = top + (LONG)(selected_line - g_editor_scroll_line) * line_height;
      if (line_top >= bottom) break;
      uint32_t first_column = selected_line == start_line ? start_column : 0;
      uint32_t last_column = selected_line == end_line
          ? end_column : editor_line_length(selected_line);
      if (last_column > first_column) {
        RECT selection_rect = {
          left + (LONG)((8 + first_column * 8) * scale),
          line_top,
          left + (LONG)((8 + last_column * 8) * scale),
          line_top + line_height};
        FillRect(dc, &selection_rect, selection_brush);
      }
    }
    DeleteObject(selection_brush);
  }
  uint32_t line = 0;
  const wchar_t *line_start = g_editor_text;
  const wchar_t *end = g_editor_text + g_editor_text_length;
  while (line_start <= end &&
      (line < g_editor_scroll_line ||
       top + (LONG)(line - g_editor_scroll_line) * line_height < bottom)) {
    const wchar_t *line_end = line_start;
    while (line_end < end && *line_end != L'\n') line_end++;
    if (line >= g_editor_scroll_line) {
      LONG line_top = top + (LONG)(line - g_editor_scroll_line) * line_height;
      if (line_top + line_height > top) {
        RECT rect = {left, line_top, right, line_top + line_height};
        int length = (int)(line_end - line_start);
        if (length > 0 && line_start[length - 1] == L'\r') length--;
        DrawTextW(dc, line_start, length, &rect,
            DT_LEFT | DT_TOP | DT_SINGLELINE | DT_NOPREFIX | DT_NOCLIP);
      }
    }
    if (line_end >= end) break;
    line_start = line_end + 1;
    line++;
  }
  if (g_editor_cursor_line >= g_editor_scroll_line) {
    LONG cursor_top = top + (LONG)(g_editor_cursor_line - g_editor_scroll_line) * line_height;
    if (cursor_top < bottom && cursor_top + line_height > top) {
      HPEN pen = CreatePen(PS_SOLID, max(1, (int)scale), RGB(230, 235, 245));
      HGDIOBJ old_pen = SelectObject(dc, pen);
      LONG cursor_x = (LONG)(g_editor_cursor_x * scale);
      MoveToEx(dc, cursor_x, cursor_top + (LONG)(2.0 * scale), NULL);
      LineTo(dc, cursor_x, cursor_top + line_height - (LONG)(2.0 * scale));
      SelectObject(dc, old_pen);
      DeleteObject(pen);
    }
  }
  SelectObject(dc, old_font);
  DeleteObject(font);
  ReleaseDC(g_window, dc);
}

static int set_editor_wide_text(wchar_t *destination, int capacity,
                                const char *utf8, uint32_t length) {
  if (!destination || capacity <= 0) return 0;
  destination[0] = L'\0';
  if (!utf8 || length == 0) return 0;
  uint32_t bounded = min(length, (uint32_t)(capacity - 1));
  int converted = MultiByteToWideChar(CP_UTF8, 0, utf8, (int)bounded,
                                      destination, capacity - 1);
  if (converted <= 0) {
    destination[0] = L'\0';
    return 0;
  }
  destination[converted] = L'\0';
  return converted;
}

static void render_editor_chrome(void) {
  if (!g_window) return;
  HDC dc = GetDC(g_window);
  if (!dc) return;
  RECT client;
  GetClientRect(g_window, &client);
  double scale = g_metrics.scale_factor > 0.0 ? g_metrics.scale_factor : 1.0;
  LONG editor_left = (LONG)(g_editor_rect[0] * scale);
  LONG editor_top = (LONG)(g_editor_rect[1] * scale);
  LONG editor_right = (LONG)((g_editor_rect[0] + g_editor_rect[2]) * scale);
  LONG editor_bottom = (LONG)((g_editor_rect[1] + g_editor_rect[3]) * scale);
  SetBkMode(dc, TRANSPARENT);
  HFONT font = CreateFontW(font_height(g_editor_font_size, scale), 0, 0, 0,
      FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
      CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, FIXED_PITCH | FF_MODERN,
      g_editor_font_name);
  HGDIOBJ old_font = font ? SelectObject(dc, font) : NULL;

  if (g_editor_tabs_length > 0) {
    LONG tab_top = (LONG)(88.0 * scale);
    LONG tab_height = (LONG)(32.0 * scale);
    LONG tab_left = (LONG)(24.0 * scale);
    LONG tab_right = client.right - (LONG)(24.0 * scale);
    const wchar_t *start = g_editor_tabs;
    const wchar_t *end = g_editor_tabs + g_editor_tabs_length;
    uint32_t tab_index = 0;
    while (start <= end) {
      const wchar_t *line_end = start;
      while (line_end < end && *line_end != L'\n') line_end++;
      LONG width = max((LONG)(92.0 * scale),
          (LONG)((line_end - start) * 8.0 * scale + 28.0 * scale));
      if (tab_left + width > tab_right) break;
      RECT tab_rect = {tab_left, tab_top, tab_left + width, tab_top + tab_height};
      HBRUSH brush = CreateSolidBrush(tab_index == g_editor_active_tab
          ? RGB(45, 51, 62) : RGB(31, 35, 41));
      FillRect(dc, &tab_rect, brush);
      DeleteObject(brush);
      SetTextColor(dc, tab_index == g_editor_active_tab
          ? RGB(235, 238, 245) : RGB(155, 162, 175));
      RECT text_rect = {tab_left + (LONG)(10.0 * scale), tab_top,
          tab_left + width - (LONG)(8.0 * scale), tab_top + tab_height};
      DrawTextW(dc, start, (int)(line_end - start), &text_rect,
          DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX | DT_END_ELLIPSIS);
      tab_left += width + (LONG)(1.0 * scale);
      if (line_end >= end) break;
      start = line_end + 1;
      tab_index++;
    }
  }

  if (g_editor_line_numbers && g_editor_text && g_editor_text_length > 0) {
    SetTextColor(dc, RGB(125, 132, 145));
    const wchar_t *line_start = g_editor_text;
    const wchar_t *end = g_editor_text + g_editor_text_length;
    uint32_t line = 0;
    LONG line_height = max(1L, (LONG)((g_editor_font_size + 2.0) * scale));
    while (line_start <= end &&
        (line < g_editor_scroll_line ||
         editor_top + (LONG)(line - g_editor_scroll_line) * line_height < editor_bottom)) {
      const wchar_t *line_end = line_start;
      while (line_end < end && *line_end != L'\n') line_end++;
      if (line >= g_editor_scroll_line) {
        LONG line_top = editor_top + (LONG)(line - g_editor_scroll_line) * line_height;
        RECT rect = {editor_left - (LONG)(52.0 * scale), line_top,
            editor_left - (LONG)(10.0 * scale), line_top + line_height};
        wchar_t number[32];
        swprintf(number, sizeof(number) / sizeof(number[0]), L"%u", line + 1);
        DrawTextW(dc, number, -1, &rect,
            DT_RIGHT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
      }
      if (line_end >= end) break;
      line_start = line_end + 1;
      line++;
    }
  }

  if (g_editor_indent_guides && editor_right > editor_left) {
    HPEN pen = CreatePen(PS_DOT, 1, RGB(62, 68, 80));
    HGDIOBJ old_pen = SelectObject(dc, pen);
    LONG cell = max(1L, (LONG)(8.0 * scale));
    LONG indent = max(1L, (LONG)g_editor_indent_width);
    for (LONG x = editor_left + cell * indent; x < editor_right; x += cell * indent) {
      MoveToEx(dc, x, editor_top, NULL);
      LineTo(dc, x, editor_bottom);
    }
    SelectObject(dc, old_pen);
    DeleteObject(pen);
  }

  LONG status_top = client.bottom - (LONG)(40.0 * scale);
  RECT status_rect = {(LONG)(24.0 * scale), status_top,
      client.right - (LONG)(24.0 * scale), client.bottom};
  HBRUSH status_brush = CreateSolidBrush(g_editor_dirty
      ? RGB(55, 47, 35) : RGB(31, 35, 41));
  FillRect(dc, &status_rect, status_brush);
  DeleteObject(status_brush);
  SetTextColor(dc, RGB(190, 197, 210));
  DrawTextW(dc, g_editor_status_length > 0 ? g_editor_status : L"Ready", -1,
      &status_rect, DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX | DT_END_ELLIPSIS);
  if (font) SelectObject(dc, old_font);
  if (font) DeleteObject(font);
  ReleaseDC(g_window, dc);
}

static void send_input(UINT type, UINT key_code, UINT button, LPARAM lparam,
                       bool screen_coordinates) {
  if (!g_input_callback) return;
  NimculusInputEvent event = {0};
  event.type = type;
  event.key_code = canonical_key_code(key_code);
  event.button = button;
  event.modifiers = 0;
  if (GetKeyState(VK_SHIFT) & 0x8000) event.modifiers |= 1u << 17;
  if (GetKeyState(VK_CONTROL) & 0x8000) event.modifiers |= 1u << 18;
  if (GetKeyState(VK_MENU) & 0x8000) event.modifiers |= 1u << 19;
  POINT point = {(LONG)(short)LOWORD(lparam), (LONG)(short)HIWORD(lparam)};
  if (screen_coordinates && g_window) ScreenToClient(g_window, &point);
  double scale = g_metrics.scale_factor > 0.0 ? g_metrics.scale_factor : 1.0;
  event.x = (double)point.x / scale;
  event.y = (double)point.y / scale;
  if (g_first_input_qpc.QuadPart == 0)
    QueryPerformanceCounter(&g_first_input_qpc);
  g_input_count++;
  if (type == 10 && g_shortcut_callback && g_shortcut_callback(&event)) return;
  g_input_callback(&event);
}

static void send_scroll(WPARAM wparam, LPARAM lparam, bool horizontal) {
  if (!g_input_callback) return;
  NimculusInputEvent event = {0};
  event.type = 22; /* NSEventTypeScrollWheel, shared by the NimNUI contract. */
  event.modifiers = 0;
  if (GetKeyState(VK_SHIFT) & 0x8000) event.modifiers |= 1u << 17;
  if (GetKeyState(VK_CONTROL) & 0x8000) event.modifiers |= 1u << 18;
  if (GetKeyState(VK_MENU) & 0x8000) event.modifiers |= 1u << 19;
  POINT point = {(LONG)(short)LOWORD(lparam), (LONG)(short)HIWORD(lparam)};
  if (g_window) ScreenToClient(g_window, &point);
  double scale = g_metrics.scale_factor > 0.0 ? g_metrics.scale_factor : 1.0;
  event.x = (double)point.x / scale;
  event.y = (double)point.y / scale;
  double delta = (double)GET_WHEEL_DELTA_WPARAM(wparam) / (double)WHEEL_DELTA;
  if (horizontal) event.delta_x = delta;
  else event.delta_y = delta;
  event.precise_scrolling = false;
  if (g_first_input_qpc.QuadPart == 0)
    QueryPerformanceCounter(&g_first_input_qpc);
  g_input_count++;
  g_input_callback(&event);
}

static void begin_mouse_tracking(HWND window) {
  if (g_tracking_mouse) return;
  TRACKMOUSEEVENT tracking = {0};
  tracking.cbSize = sizeof(tracking);
  tracking.dwFlags = TME_LEAVE;
  tracking.hwndTrack = window;
  if (TrackMouseEvent(&tracking)) g_tracking_mouse = true;
}

static LRESULT CALLBACK window_proc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  switch (message) {
    case WM_SIZE:
      update_metrics();
      if (wparam == SIZE_MINIMIZED) return 0;
      resize_render_target();
      InvalidateRect(window, NULL, FALSE);
      return 0;
    case WM_SETFOCUS:
      if (g_command_callback) g_command_callback("windowFocusGained");
      return 0;
    case WM_KILLFOCUS:
      if (g_command_callback) g_command_callback("windowFocusLost");
      return 0;
    case WM_DPICHANGED: {
      g_metrics.scale_factor = (double)HIWORD(wparam) / (double)USER_DEFAULT_SCREEN_DPI;
      RECT *suggested = (RECT *)lparam;
      SetWindowPos(window, NULL, suggested->left, suggested->top,
                   suggested->right - suggested->left, suggested->bottom - suggested->top,
                   SWP_NOZORDER | SWP_NOACTIVATE);
      update_metrics();
      resize_render_target();
      return 0;
    }
    case WM_PAINT: {
      PAINTSTRUCT paint;
      BeginPaint(window, &paint);
      render_frame();
      if (!g_directwrite_frame) render_editor_overlay();
      render_editor_chrome();
      render_terminal_overlay();
      EndPaint(window, &paint);
      return 0;
    }
    case WM_TIMER:
      if (g_idle_callback) g_idle_callback();
      return 0;
    case WM_KEYDOWN:
    case WM_SYSKEYDOWN:
      g_suppress_translate = (GetKeyState(VK_CONTROL) & 0x8000) != 0 ||
                             (GetKeyState(VK_MENU) & 0x8000) != 0;
      if (wparam == VK_SHIFT || wparam == VK_CONTROL || wparam == VK_MENU)
        send_input(12, (UINT)wparam, 0, 0, false);
      else
        send_input(10, (UINT)wparam, 0, 0, false);
      return 0;
    case WM_KEYUP:
    case WM_SYSKEYUP:
      if (wparam == VK_SHIFT || wparam == VK_CONTROL || wparam == VK_MENU)
        send_input(12, (UINT)wparam, 0, 0, false);
      else
        send_input(11, (UINT)wparam, 0, 0, false);
      return 0;
    case WM_LBUTTONDOWN:
      SetCapture(window);
      begin_mouse_tracking(window);
      send_input(1, 0, 0, lparam, false);
      return 0;
    case WM_LBUTTONUP:
      send_input(2, 0, 0, lparam, false);
      if (!(GetKeyState(VK_LBUTTON) & 0x8000) &&
          !(GetKeyState(VK_RBUTTON) & 0x8000) &&
          !(GetKeyState(VK_MBUTTON) & 0x8000)) ReleaseCapture();
      return 0;
    case WM_RBUTTONDOWN:
      SetCapture(window);
      begin_mouse_tracking(window);
      send_input(3, 0, 1, lparam, false);
      return 0;
    case WM_RBUTTONUP:
      send_input(4, 0, 1, lparam, false);
      if (!(GetKeyState(VK_LBUTTON) & 0x8000) &&
          !(GetKeyState(VK_RBUTTON) & 0x8000) &&
          !(GetKeyState(VK_MBUTTON) & 0x8000)) ReleaseCapture();
      return 0;
    case WM_MBUTTONDOWN:
      SetCapture(window);
      begin_mouse_tracking(window);
      send_input(25, 0, 2, lparam, false);
      return 0;
    case WM_MBUTTONUP:
      send_input(26, 0, 2, lparam, false);
      if (!(GetKeyState(VK_LBUTTON) & 0x8000) &&
          !(GetKeyState(VK_RBUTTON) & 0x8000) &&
          !(GetKeyState(VK_MBUTTON) & 0x8000)) ReleaseCapture();
      return 0;
    case WM_XBUTTONDOWN:
      SetCapture(window);
      begin_mouse_tracking(window);
      send_input(25, 0, 2, lparam, false);
      return TRUE;
    case WM_XBUTTONUP:
      send_input(26, 0, 2, lparam, false);
      if (!(GetKeyState(VK_LBUTTON) & 0x8000) &&
          !(GetKeyState(VK_RBUTTON) & 0x8000) &&
          !(GetKeyState(VK_MBUTTON) & 0x8000)) ReleaseCapture();
      return TRUE;
    case WM_MOUSEMOVE:
      begin_mouse_tracking(window);
      if (GetKeyState(VK_LBUTTON) & 0x8000)
        send_input(6, 0, 0, lparam, false);
      else if (GetKeyState(VK_RBUTTON) & 0x8000 || GetKeyState(VK_MBUTTON) & 0x8000)
        send_input(27, 0, 1, lparam, false);
      else
        send_input(5, 0, 0, lparam, false);
      return 0;
    case WM_MOUSELEAVE:
    case WM_NCMOUSELEAVE:
      g_tracking_mouse = false;
      send_input(9, 0, 0, 0, false);
      return 0;
    case WM_MOUSEWHEEL:
      send_scroll(wparam, lparam, false);
      return 0;
    case WM_MOUSEHWHEEL:
      send_scroll(wparam, lparam, true);
      return 0;
    case WM_DROPFILES: {
      HDROP drop = (HDROP)wparam;
      UINT count = DragQueryFileW(drop, 0xFFFFFFFF, NULL, 0);
      for (UINT index = 0; index < count; ++index) {
        UINT length = DragQueryFileW(drop, index, NULL, 0);
        if (length == 0 || length >= sizeof(g_dialog_path) / sizeof(g_dialog_path[0])) continue;
        DragQueryFileW(drop, index, g_dialog_path,
                       (UINT)(sizeof(g_dialog_path) / sizeof(g_dialog_path[0])));
        emit_dropped_path(g_dialog_path);
      }
      DragFinish(drop);
      return 0;
    }
    case WM_IME_STARTCOMPOSITION:
      update_ime_position();
      return 0;
    case WM_IME_COMPOSITION: {
      HIMC context = ImmGetContext(window);
      if (context) {
        LPARAM flags = lparam;
        if (flags & GCS_RESULTSTR) emit_ime_string(context, GCS_RESULTSTR, false);
        if (flags & GCS_COMPSTR) emit_ime_string(context, GCS_COMPSTR, true);
        if (flags == 0 && g_text_callback) g_text_callback("", true);
        ImmReleaseContext(window, context);
      }
      return 0;
    }
    case WM_IME_ENDCOMPOSITION:
      if (g_text_callback) g_text_callback("", true);
      return 0;
    case WM_CHAR: {
      wchar_t wide = (wchar_t)wparam;
      if (wide >= 0xD800 && wide <= 0xDBFF) {
        g_pending_high_surrogate = wide;
        return 0;
      }
      if (wide >= 0xDC00 && wide <= 0xDFFF && g_pending_high_surrogate != 0) {
        wchar_t pair[2] = {g_pending_high_surrogate, wide};
        g_pending_high_surrogate = 0;
        emit_utf16_text(pair, 2);
        return 0;
      }
      g_pending_high_surrogate = 0;
      emit_utf16_text(&wide, 1);
      return 0;
    }
    case WM_UNICHAR: {
      if (wparam == UNICODE_NOCHAR) return TRUE;
      uint32_t codepoint = (uint32_t)wparam;
      if (codepoint <= 0xFFFF) {
        wchar_t wide = (wchar_t)codepoint;
        emit_utf16_text(&wide, 1);
      } else if (codepoint <= 0x10FFFF) {
        wchar_t pair[2] = {
          (wchar_t)(0xD800 + ((codepoint - 0x10000) >> 10)),
          (wchar_t)(0xDC00 + ((codepoint - 0x10000) & 0x3FF))
        };
        emit_utf16_text(pair, 2);
      }
      return 0;
    }
    case WM_CLOSE:
      if (g_command_callback) {
        g_close_request_pending = true;
        g_command_callback("quitRequest");
      }
      return 0;
    case WM_DESTROY:
      PostQuitMessage(0);
      return 0;
    default:
      return DefWindowProcW(window, message, wparam, lparam);
  }
}

bool nimculus_platform_run(void) {
  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  HINSTANCE instance = GetModuleHandleW(NULL);
  const wchar_t class_name[] = L"NimculusWindow";
  WNDCLASSEXW klass;
  ZeroMemory(&klass, sizeof(klass));
  klass.cbSize = sizeof(klass);
  klass.hInstance = instance;
  klass.lpfnWndProc = window_proc;
  klass.hCursor = LoadCursor(NULL, IDC_ARROW);
  klass.lpszClassName = class_name;
  if (!RegisterClassExW(&klass) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return false;
  g_window = CreateWindowExW(0, class_name, L"Nimculus",
      WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, 1200, 800,
      NULL, NULL, instance, NULL);
  if (!g_window) return false;
  ShowWindow(g_window, SW_SHOW);
  UpdateWindow(g_window);
  DragAcceptFiles(g_window, TRUE);
  SetTimer(g_window, 1, 16, NULL);
  if (!create_device()) {
    DestroyWindow(g_window);
    g_window = NULL;
    return false;
  }
  MSG message;
  while (GetMessageW(&message, NULL, 0, 0) > 0) {
    DispatchMessageW(&message);
    /* Dispatch first so the shortcut callback can suppress WM_CHAR for
       commands and control-key terminal input. */
    if ((message.message == WM_KEYDOWN || message.message == WM_SYSKEYDOWN) &&
        !g_suppress_translate) {
      TranslateMessage(&message);
    }
  }
  release_device();
  release_glyph_raster_cache();
  release_glyph_font_face();
  release_editor_text_format();
  if (g_d2d_factory) {
    g_d2d_factory->lpVtbl->Release(g_d2d_factory);
    g_d2d_factory = NULL;
  }
  if (g_dwrite_analyzer) {
    g_dwrite_analyzer->lpVtbl->Release(g_dwrite_analyzer);
    g_dwrite_analyzer = NULL;
  }
  if (g_dwrite_font_fallback) {
    g_dwrite_font_fallback->lpVtbl->Release(g_dwrite_font_fallback);
    g_dwrite_font_fallback = NULL;
  }
  if (g_dwrite_factory4) {
    g_dwrite_factory4->lpVtbl->Release(g_dwrite_factory4);
    g_dwrite_factory4 = NULL;
  }
  if (g_dwrite_factory) {
    g_dwrite_factory->lpVtbl->Release(g_dwrite_factory);
    g_dwrite_factory = NULL;
  }
  if (g_dwrite_factory2) {
    g_dwrite_factory2->lpVtbl->Release(g_dwrite_factory2);
    g_dwrite_factory2 = NULL;
  }
  if (g_wic_factory) {
    g_wic_factory->lpVtbl->Release(g_wic_factory);
    g_wic_factory = NULL;
  }
  if (g_wic_com_initialized) {
    CoUninitialize();
    g_wic_com_initialized = false;
  }
  release_images();
  free(g_paint_commands);
  g_paint_commands = NULL;
  g_paint_count = 0;
  free(g_editor_text);
  g_editor_text = NULL;
  g_editor_text_length = 0;
  free(g_editor_utf8);
  g_editor_utf8 = NULL;
  g_editor_utf8_length = 0;
  free(g_editor_composition);
  g_editor_composition = NULL;
  g_editor_composition_length = 0;
  free(g_editor_highlights);
  g_editor_highlights = NULL;
  g_editor_highlight_count = 0;
  free(g_terminal_utf8);
  g_terminal_utf8 = NULL;
  g_terminal_utf8_length = 0;
  free(g_terminal_runs);
  g_terminal_runs = NULL;
  g_terminal_run_count = 0;
  g_window = NULL;
  return true;
}

void nimculus_platform_request_quit(void) {
  PostQuitMessage(0);
}

bool nimculus_platform_validate_native(void) {
  return g_device != NULL && g_swap_chain != NULL;
}

bool nimculus_platform_validate_native_interaction(void) {
  if (!g_window || !g_device || !g_swap_chain || !g_input_callback ||
      !g_text_callback) return false;
  RECT client;
  if (!GetClientRect(g_window, &client) || client.right <= 8 || client.bottom <= 8)
    return false;
  uint64_t input_before = g_input_count;
  SetFocus(g_window);
  SendMessageW(g_window, WM_MOUSEMOVE, 0, MAKELPARAM(4, 4));
  SendMessageW(g_window, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(4, 4));
  SendMessageW(g_window, WM_LBUTTONUP, 0, MAKELPARAM(4, 4));
  POINT screen = {4, 4};
  ClientToScreen(g_window, &screen);
  SendMessageW(g_window, WM_MOUSEWHEEL, MAKEWPARAM(0, WHEEL_DELTA),
      MAKELPARAM(screen.x, screen.y));
  SendMessageW(g_window, WM_KEYDOWN, 'A', 0);
  SendMessageW(g_window, WM_KEYUP, 'A', 0);
  SendMessageW(g_window, WM_CHAR, 'x', 0);
  SendMessageW(g_window, WM_CHAR, 0xd83d, 0);
  SendMessageW(g_window, WM_CHAR, 0xde00, 0);
  LRESULT unichar_result = SendMessageW(g_window, WM_UNICHAR, 0x1f600, 0);
  SendMessageW(g_window, WM_SIZE, SIZE_RESTORED,
      MAKELPARAM((WORD)client.right, (WORD)client.bottom));
  return g_input_count >= input_before + 6 && GetCapture() == NULL &&
      g_metrics.width_pixels > 0 && g_metrics.height_pixels > 0 &&
      unichar_result == TRUE;
}

bool nimculus_platform_validate_text_format_cache(void) {
  double scale = g_metrics.scale_factor > 0.0 ? g_metrics.scale_factor : 1.0;
  IDWriteTextFormat *first = ensure_editor_text_format(scale);
  IDWriteTextFormat *second = ensure_editor_text_format(scale);
  return first != NULL && first == second;
}

bool nimculus_platform_validate_glyph_raster_interface(void) {
  return ensure_directwrite_factory() && g_dwrite_factory2 != NULL;
}

bool nimculus_platform_validate_glyph_raster_cache(void) {
  double scale = g_metrics.scale_factor > 0.0 ? g_metrics.scale_factor : 1.0;
  uint64_t hits_before = g_glyph_raster_hit_count;
  if (!rasterize_glyph_for_cache('A', (float)g_editor_font_size, scale, 0, 0))
    return false;
  if (!rasterize_glyph_for_cache('A', (float)g_editor_font_size, scale, 0, 0))
    return false;
  return g_glyph_raster_hit_count > hits_before;
}

bool nimculus_platform_validate_glyph_subpixel_variants(void) {
  double scale = g_metrics.scale_factor > 0.0 ? g_metrics.scale_factor : 1.0;
  float font_size = (float)g_editor_font_size;
  if (!rasterize_glyph_for_cache('A', font_size, scale, 0, 0) ||
      !rasterize_glyph_for_cache('A', font_size, scale, 1, 0)) return false;
  NimculusGlyphRaster *first = cached_glyph_for_codepoint('A', font_size,
      scale, 0, 0);
  NimculusGlyphRaster *second = cached_glyph_for_codepoint('A', font_size,
      scale, 1, 0);
  if (!first || !second || first == second || first->subpixel_x != 0 ||
      second->subpixel_x != 1) return false;
  if (!rasterize_glyph_for_cache('A', font_size, scale, 0, 1)) return false;
  NimculusGlyphRaster *vertical = cached_glyph_for_codepoint('A', font_size,
      scale, 0, 1);
  return vertical != NULL && vertical != first && vertical->subpixel_y == 1;
}

bool nimculus_platform_validate_glyph_shaping(void) {
  static const wchar_t sample[] = L"office";
  UINT16 *indices = NULL;
  DWRITE_GLYPH_OFFSET *offsets = NULL;
  FLOAT *advances = NULL;
  uint32_t count = 0;
  bool valid = shape_ascii_run(sample, 6, &indices, &offsets, &advances, &count);
  if (valid) {
    valid = count > 0;
    for (uint32_t index = 0; index < count; ++index) {
      if (!(advances[index] >= 0.0f) || !isfinite(advances[index])) valid = false;
    }
  }
  free_shaped_run(indices, offsets, advances);
  return valid;
}

bool nimculus_platform_validate_glyph_fallback(void) {
  static const wchar_t sample[] = L"日";
  double scale_factor = g_metrics.scale_factor > 0.0 ? g_metrics.scale_factor : 1.0;
  float font_size = (float)g_editor_font_size;
  UINT32 mapped_length = 0;
  FLOAT scale = 0.0f;
  IDWriteFontFace *font_face = map_fallback_font(sample, 1,
      &mapped_length, &scale);
  bool valid = font_face != NULL && mapped_length == 1 && scale > 0.0f;
  if (font_face) font_face->lpVtbl->Release(font_face);
  if (!valid || !rasterize_glyph_for_cache(0x65e5, font_size, scale_factor, 0, 0))
    return false;
  NimculusGlyphRaster *raster = cached_glyph_for_codepoint(0x65e5,
      font_size, scale_factor, 0, 0);
  valid = raster != NULL && raster->font_face != g_glyph_font_face &&
      raster->pixels != NULL && raster->length > 0;
  return valid;
}

bool nimculus_platform_validate_glyph_fallback_shaping(void) {
  static const wchar_t sample[] = L"日本";
  UINT16 *indices = NULL;
  DWRITE_GLYPH_OFFSET *offsets = NULL;
  FLOAT *advances = NULL;
  uint32_t count = 0;
  IDWriteFontFace *font_face = NULL;
  FLOAT font_size = 0.0f;
  bool valid = shape_fallback_run(sample, 2, &indices, &offsets, &advances,
      &count, &font_face, &font_size);
  if (valid) {
    valid = font_face != NULL && font_face != g_glyph_font_face &&
        count > 0 && font_size > 0.0f;
    for (uint32_t index = 0; valid && index < count; ++index) {
      if (!(advances[index] >= 0.0f) || !isfinite(advances[index])) valid = false;
    }
  }
  free_shaped_run(indices, offsets, advances);
  if (font_face) font_face->lpVtbl->Release(font_face);
  return valid;
}

bool nimculus_platform_validate_color_glyph_path(void) {
  static const wchar_t sample[] = {0xd83d, 0xde00};
  UINT32 mapped_length = 0;
  FLOAT fallback_scale = 1.0f;
  IDWriteFontFace *font_face = map_fallback_font(sample, 2,
      &mapped_length, &fallback_scale);
  if (!font_face || mapped_length != 2) {
    if (font_face) font_face->lpVtbl->Release(font_face);
    return false;
  }
  UINT32 codepoint = 0x1f600;
  UINT16 glyph_id = 0;
  HRESULT hr = font_face->lpVtbl->GetGlyphIndices(font_face, &codepoint, 1,
      &glyph_id);
  bool valid = SUCCEEDED(hr) && glyph_id != 0 && ensure_directwrite_factory();
  IDWriteColorGlyphRunEnumerator *enumerator = NULL;
  if (valid) {
    FLOAT advance = glyph_advance_pixels(font_face, glyph_id,
        (float)g_editor_font_size * fallback_scale,
        g_metrics.scale_factor > 0.0 ? g_metrics.scale_factor : 1.0);
    DWRITE_GLYPH_OFFSET offset = {0.0f, 0.0f};
    DWRITE_GLYPH_RUN run;
    ZeroMemory(&run, sizeof(run));
    run.fontFace = font_face;
    run.fontEmSize = (FLOAT)g_editor_font_size * fallback_scale;
    run.glyphCount = 1;
    run.glyphIndices = &glyph_id;
    run.glyphAdvances = &advance;
    run.glyphOffsets = &offset;
    hr = g_dwrite_factory2->lpVtbl->TranslateColorGlyphRun(
        g_dwrite_factory2, 0.0f, 0.0f, &run, NULL,
        DWRITE_MEASURING_MODE_NATURAL, NULL, 0, &enumerator);
    if (hr == DWRITE_E_NOCOLOR) {
      /* The platform has no color face for this glyph; D2D remains the
       * documented fallback and this is still a valid non-color path. */
      valid = true;
    } else if (SUCCEEDED(hr) && enumerator) {
      BOOL has_run = FALSE;
      valid = SUCCEEDED(enumerator->lpVtbl->MoveNext(enumerator, &has_run));
    } else {
      valid = false;
    }
  }
  if (enumerator) enumerator->lpVtbl->Release(enumerator);
  font_face->lpVtbl->Release(font_face);
  return valid;
}

bool nimculus_platform_validate_advanced_color_glyph_path(void) {
  if (!g_device || !g_context || !ensure_directwrite_factory()) return false;
  /* Factory4 is available on Windows 10 1607 and later.  Older systems keep
   * using the Factory2 COLR/D2D path and are valid by construction. */
  if (!g_dwrite_factory4) return true;
  static const wchar_t sample[] = {0xd83d, 0xde00};
  UINT32 mapped_length = 0;
  FLOAT fallback_scale = 1.0f;
  IDWriteFontFace *font_face = map_fallback_font(sample, 2,
      &mapped_length, &fallback_scale);
  if (!font_face || mapped_length != 2) {
    if (font_face) font_face->lpVtbl->Release(font_face);
    return false;
  }
  UINT32 codepoint = 0x1f600;
  UINT16 glyph_id = 0;
  HRESULT hr = font_face->lpVtbl->GetGlyphIndices(font_face, &codepoint, 1,
      &glyph_id);
  bool valid = SUCCEEDED(hr) && glyph_id != 0;
  IDWriteColorGlyphRunEnumerator1 *enumerator = NULL;
  if (valid) {
    double scale = g_metrics.scale_factor > 0.0 ? g_metrics.scale_factor : 1.0;
    FLOAT advance = glyph_advance_pixels(font_face, glyph_id,
        (float)g_editor_font_size * fallback_scale, scale);
    DWRITE_GLYPH_OFFSET offset = {0.0f, 0.0f};
    DWRITE_GLYPH_RUN run;
    ZeroMemory(&run, sizeof(run));
    run.fontFace = font_face;
    run.fontEmSize = (FLOAT)g_editor_font_size * fallback_scale;
    run.glyphCount = 1;
    run.glyphIndices = &glyph_id;
    run.glyphAdvances = &advance;
    run.glyphOffsets = &offset;
    DWRITE_MATRIX transform = {(FLOAT)scale, 0.0f, 0.0f, (FLOAT)scale,
                               0.0f, 0.0f};
    D2D1_POINT_2F origin = {0.0f, 0.0f};
    DWRITE_GLYPH_IMAGE_FORMATS formats =
        DWRITE_GLYPH_IMAGE_FORMATS_COLR |
        DWRITE_GLYPH_IMAGE_FORMATS_SVG |
        DWRITE_GLYPH_IMAGE_FORMATS_PNG |
        DWRITE_GLYPH_IMAGE_FORMATS_JPEG |
        DWRITE_GLYPH_IMAGE_FORMATS_PREMULTIPLIED_B8G8R8A8;
    hr = g_dwrite_factory4->lpVtbl->TranslateColorGlyphRun(
        g_dwrite_factory4, origin, &run, NULL, formats,
        DWRITE_MEASURING_MODE_NATURAL, &transform, 0, &enumerator);
    if (hr == DWRITE_E_NOCOLOR) {
      valid = true;
    } else if (SUCCEEDED(hr) && enumerator) {
      uint32_t run_count = 0;
      BOOL has_next = FALSE;
      for (;;) {
        const DWRITE_COLOR_GLYPH_RUN1 *color_run = NULL;
        hr = enumerator->lpVtbl->IDWriteColorGlyphRunEnumerator1_GetCurrentRun(
            enumerator, &color_run);
        if (FAILED(hr) || !color_run) {
          valid = false;
          break;
        }
        DWRITE_GLYPH_IMAGE_FORMATS image_format =
            color_run->glyphImageFormat & ~DWRITE_GLYPH_IMAGE_FORMATS_TRUETYPE;
        if (image_format != DWRITE_GLYPH_IMAGE_FORMATS_COLR &&
            image_format != DWRITE_GLYPH_IMAGE_FORMATS_SVG &&
            image_format != DWRITE_GLYPH_IMAGE_FORMATS_PNG &&
            image_format != DWRITE_GLYPH_IMAGE_FORMATS_JPEG &&
            image_format != DWRITE_GLYPH_IMAGE_FORMATS_PREMULTIPLIED_B8G8R8A8) {
          valid = false;
          break;
        }
        run_count++;
        hr = enumerator->lpVtbl->MoveNext(enumerator, &has_next);
        if (FAILED(hr) || !has_next) break;
      }
      valid = valid && run_count > 0;
    } else {
      valid = false;
    }
  }
  if (enumerator) enumerator->lpVtbl->Release(enumerator);
  font_face->lpVtbl->Release(font_face);
  return valid;
}

static bool validate_bitmap_color_glyph_atlas(
    DWRITE_GLYPH_IMAGE_FORMATS format) {
  if (!g_device || !g_context || !ensure_directwrite_factory()) return false;
  if (!g_dwrite_factory4) return true;
  static const wchar_t sample[] = {0xd83d, 0xde00};
  UINT32 mapped_length = 0;
  FLOAT fallback_scale = 1.0f;
  IDWriteFontFace *font_face = map_fallback_font(sample, 2,
      &mapped_length, &fallback_scale);
  if (!font_face || mapped_length != 2) {
    if (font_face) font_face->lpVtbl->Release(font_face);
    return false;
  }
  UINT32 codepoint = 0x1f600;
  UINT16 glyph_id = 0;
  bool valid = SUCCEEDED(font_face->lpVtbl->GetGlyphIndices(font_face,
      &codepoint, 1, &glyph_id)) && glyph_id != 0;
  IDWriteFontFace4 *font_face4 = NULL;
  if (valid) valid = SUCCEEDED(font_face->lpVtbl->QueryInterface(
      (IUnknown *)font_face, &IID_IDWriteFontFace4, (void **)&font_face4)) &&
      font_face4 != NULL;
  bool has_image = false;
  if (valid) {
    UINT32 requested_ppem = (UINT32)floor(g_editor_font_size *
        (g_metrics.scale_factor > 0.0 ? g_metrics.scale_factor : 1.0) + 0.5);
    if (requested_ppem == 0) requested_ppem = 1;
    DWRITE_GLYPH_IMAGE_DATA image_data;
    ZeroMemory(&image_data, sizeof(image_data));
    void *image_context = NULL;
    HRESULT hr = font_face4->lpVtbl->GetGlyphImageData(font_face4, glyph_id,
        requested_ppem, format, &image_data,
        &image_context);
    has_image = SUCCEEDED(hr) && image_data.imageData &&
        image_data.imageDataSize > 0;
    if (image_context) font_face4->lpVtbl->ReleaseGlyphImageData(font_face4,
        image_context);
  }
  if (font_face4) font_face4->lpVtbl->Release(font_face4);
  if (valid && has_image) {
    double scale = g_metrics.scale_factor > 0.0 ? g_metrics.scale_factor : 1.0;
    if (format == DWRITE_GLYPH_IMAGE_FORMATS_PREMULTIPLIED_B8G8R8A8) {
      valid = rasterize_premultiplied_glyph_for_cache(font_face, glyph_id,
          (float)g_editor_font_size * fallback_scale, scale, 0, 0);
    } else {
      valid = rasterize_bitmap_glyph_for_cache(font_face, glyph_id,
          (float)g_editor_font_size * fallback_scale, scale, 0, 0, format);
    }
    if (valid) {
      NimculusColorGlyphRaster *raster = find_color_glyph_raster(font_face,
          glyph_id, (float)g_editor_font_size * fallback_scale, scale, 0, 0);
      valid = raster && upload_color_glyph_to_atlas(raster) &&
          raster->atlas_valid && raster->length > 0;
    }
  }
  font_face->lpVtbl->Release(font_face);
  return valid;
}

bool nimculus_platform_validate_png_color_glyph_atlas(void) {
  return validate_bitmap_color_glyph_atlas(DWRITE_GLYPH_IMAGE_FORMATS_PNG);
}

bool nimculus_platform_validate_jpeg_color_glyph_atlas(void) {
  return validate_bitmap_color_glyph_atlas(DWRITE_GLYPH_IMAGE_FORMATS_JPEG);
}

bool nimculus_platform_validate_premultiplied_color_glyph_atlas(void) {
  return validate_bitmap_color_glyph_atlas(
      DWRITE_GLYPH_IMAGE_FORMATS_PREMULTIPLIED_B8G8R8A8);
}

bool nimculus_platform_validate_color_glyph_atlas(void) {
  if (!g_device || !g_context || !ensure_directwrite_factory()) return false;
  static const wchar_t sample[] = {0xd83d, 0xde00};
  UINT32 mapped_length = 0;
  FLOAT fallback_scale = 1.0f;
  IDWriteFontFace *font_face = map_fallback_font(sample, 2,
      &mapped_length, &fallback_scale);
  if (!font_face || mapped_length != 2) {
    if (font_face) font_face->lpVtbl->Release(font_face);
    return false;
  }
  UINT32 codepoint = 0x1f600;
  UINT16 glyph_id = 0;
  HRESULT hr = font_face->lpVtbl->GetGlyphIndices(font_face, &codepoint, 1,
      &glyph_id);
  bool valid = SUCCEEDED(hr) && glyph_id != 0;
  if (valid) {
    double scale = g_metrics.scale_factor > 0.0 ? g_metrics.scale_factor : 1.0;
    IDWriteColorGlyphRunEnumerator *enumerator = NULL;
    FLOAT advance = glyph_advance_pixels(font_face, glyph_id,
        (float)g_editor_font_size * fallback_scale, scale);
    DWRITE_GLYPH_OFFSET offset = {0.0f, 0.0f};
    DWRITE_GLYPH_RUN run;
    ZeroMemory(&run, sizeof(run));
    run.fontFace = font_face;
    run.fontEmSize = (FLOAT)g_editor_font_size * fallback_scale;
    run.glyphCount = 1;
    run.glyphIndices = &glyph_id;
    run.glyphAdvances = &advance;
    run.glyphOffsets = &offset;
    DWRITE_MATRIX transform = {(FLOAT)scale, 0.0f, 0.0f, (FLOAT)scale,
                               0.0f, 0.0f};
    hr = g_dwrite_factory2->lpVtbl->TranslateColorGlyphRun(
        g_dwrite_factory2, 0.0f, 0.0f, &run, NULL,
        DWRITE_MEASURING_MODE_NATURAL, &transform, 0, &enumerator);
    if (hr == DWRITE_E_NOCOLOR) {
      /* The installed fallback may not contain a COLR face.  In that case
       * the normal DirectWrite/D2D path remains the supported result. */
      valid = true;
    } else if (SUCCEEDED(hr) && enumerator) {
      valid = rasterize_color_glyph_for_cache(font_face, glyph_id,
          (float)g_editor_font_size * fallback_scale, scale, 0, 0);
      if (valid) {
        NimculusColorGlyphRaster *raster = find_color_glyph_raster(font_face,
            glyph_id, (float)g_editor_font_size * fallback_scale, scale, 0, 0);
        valid = raster && upload_color_glyph_to_atlas(raster) &&
            raster->atlas_valid && raster->length > 0 && raster->pixels != NULL;
      }
    } else {
      valid = false;
    }
    if (enumerator) enumerator->lpVtbl->Release(enumerator);
  }
  font_face->lpVtbl->Release(font_face);
  return valid;
}

bool nimculus_platform_validate_glyph_atlas_upload(void) {
  if (!g_device || !g_context || !g_glyph_pixel_shader ||
      !ensure_glyph_atlas_texture()) return false;
  double scale = g_metrics.scale_factor > 0.0 ? g_metrics.scale_factor : 1.0;
  if (!rasterize_glyph_for_cache('A', (float)g_editor_font_size, scale, 0, 0))
    return false;
  IDWriteFontFace *font_face = ensure_glyph_font_face();
  if (!font_face) return false;
  UINT32 codepoint = 'A';
  UINT16 glyph_id = 0;
  if (FAILED(font_face->lpVtbl->GetGlyphIndices(font_face, &codepoint, 1,
                                                &glyph_id))) return false;
  NimculusGlyphRaster *raster = NULL;
  for (size_t index = 0; index < NIMCULUS_MAX_GLYPH_RASTERS; ++index) {
    NimculusGlyphRaster *candidate = &g_glyph_rasters[index];
    if (candidate->valid && candidate->glyph_id == glyph_id &&
        fabs((double)candidate->font_size - g_editor_font_size) < 0.001 &&
        fabs(candidate->scale - scale) < 0.001 &&
        candidate->subpixel_x == 0 && candidate->subpixel_y == 0) {
      raster = candidate;
      break;
    }
  }
  if (!raster || !upload_glyph_raster_to_atlas(raster) ||
      !g_glyph_atlas_view || !raster->atlas_valid) return false;
  uint64_t uploads = g_glyph_atlas_upload_count;
  if (!upload_glyph_raster_to_atlas(raster)) return false;
  return g_glyph_atlas_upload_count == uploads;
}

uint64_t nimculus_platform_input_count(void) { return g_input_count; }

bool nimculus_platform_validate_visible_glyph_frame(void) {
  if (!g_editor_text || g_editor_text_length <= 0 || !g_device ||
      !g_context || !g_glyph_atlas_view) return false;
  return draw_glyph_atlas_sprites();
}

void nimculus_platform_get_metrics(NimculusPlatformMetrics *metrics) {
  if (metrics) *metrics = g_metrics;
}

uint64_t nimculus_platform_resident_memory_bytes(void) {
  PROCESS_MEMORY_COUNTERS_EX counters;
  memset(&counters, 0, sizeof(counters));
  if (!GetProcessMemoryInfo(GetCurrentProcess(),
      (PROCESS_MEMORY_COUNTERS *)&counters, sizeof(counters))) return 0;
  return (uint64_t)counters.WorkingSetSize;
}

uint64_t nimculus_platform_live_allocation_count(void) {
  DWORD heap_count = GetProcessHeaps(0, NULL);
  if (heap_count == 0) return 0;
  HANDLE *heaps = (HANDLE *)malloc(sizeof(HANDLE) * heap_count);
  if (!heaps) return 0;
  DWORD actual_count = GetProcessHeaps(heap_count, heaps);
  uint64_t blocks = 0;
  for (DWORD i = 0; i < actual_count; i++) {
    if (!HeapLock(heaps[i])) continue;
    PROCESS_HEAP_ENTRY entry;
    memset(&entry, 0, sizeof(entry));
    while (HeapWalk(heaps[i], &entry)) {
      if ((entry.wFlags & PROCESS_HEAP_ENTRY_BUSY) != 0) blocks++;
    }
    HeapUnlock(heaps[i]);
  }
  free(heaps);
  return blocks;
}

void nimculus_platform_set_input_callback(NimculusInputCallback callback) {
  g_input_callback = callback;
}

void nimculus_platform_set_editor_cursor(double x, double y) {
  g_editor_cursor_x = x;
  g_editor_cursor_y = y;
  update_ime_position();
}

void nimculus_platform_set_editor_rect(double x, double y, double width,
                                       double height) {
  g_editor_rect[0] = x >= 0.0 ? x : 0.0;
  g_editor_rect[1] = y >= 0.0 ? y : 0.0;
  g_editor_rect[2] = width > 1.0 ? width : 1.0;
  g_editor_rect[3] = height > 1.0 ? height : 1.0;
  if (g_window) InvalidateRect(g_window, NULL, FALSE);
}

void nimculus_platform_set_editor_font_size(double size) {
  if (size < 6.0) size = 6.0;
  if (size > 48.0) size = 48.0;
  g_editor_font_size = size;
  release_glyph_raster_cache();
  release_editor_text_format();
  if (g_window) InvalidateRect(g_window, NULL, FALSE);
}

void nimculus_platform_set_editor_font_name(const char *name) {
  if (!name || name[0] == '\0') return;
  wchar_t wide[LF_FACESIZE];
  int length = MultiByteToWideChar(CP_UTF8, 0, name, -1, wide, LF_FACESIZE);
  if (length <= 1 || !nimculus_font_available(name, g_editor_font_size)) return;
  wide[LF_FACESIZE - 1] = L'\0';
  wcsncpy(g_editor_font_name, wide, LF_FACESIZE - 1);
  g_editor_font_name[LF_FACESIZE - 1] = L'\0';
  release_glyph_raster_cache();
  release_editor_text_format();
  if (g_window) InvalidateRect(g_window, NULL, FALSE);
}

double nimculus_platform_editor_line_height(void) {
  return g_editor_font_size + 2.0;
}

void nimculus_platform_set_editor_cursor_byte(uint32_t byte_offset, uint32_t line) {
  g_editor_cursor_byte = byte_offset;
  g_editor_cursor_line = line;
  if (g_window) InvalidateRect(g_window, NULL, FALSE);
}

void nimculus_platform_set_editor_scroll_line(uint32_t line) {
  g_editor_scroll_line = line;
  if (g_window) InvalidateRect(g_window, NULL, FALSE);
}

void nimculus_platform_set_editor_selection(uint32_t start_byte, uint32_t end_byte) {
  g_editor_selection_start = start_byte;
  g_editor_selection_end = end_byte;
  if (g_window) InvalidateRect(g_window, NULL, FALSE);
}

void nimculus_platform_set_editor_dirty(bool dirty) {
  g_editor_dirty = dirty;
  if (g_window) InvalidateRect(g_window, NULL, FALSE);
}

void nimculus_platform_set_editor_indent_guides(bool visible, uint32_t indent_width) {
  g_editor_indent_guides = visible;
  g_editor_indent_width = max(1u, indent_width);
  if (g_window) InvalidateRect(g_window, NULL, FALSE);
}

void nimculus_platform_set_editor_line_numbers(bool visible) {
  g_editor_line_numbers = visible;
  if (g_window) InvalidateRect(g_window, NULL, FALSE);
}

void nimculus_platform_set_editor_soft_wrap(bool enabled) {
  g_editor_soft_wrap = enabled;
  release_editor_text_format();
  if (g_window) InvalidateRect(g_window, NULL, FALSE);
}

void nimculus_platform_set_editor_tabs(const char *titles, uint32_t length,
                                       uint32_t active_index) {
  g_editor_tabs_length = set_editor_wide_text(g_editor_tabs,
      (int)(sizeof(g_editor_tabs) / sizeof(g_editor_tabs[0])), titles, length);
  g_editor_active_tab = active_index;
  if (g_window) InvalidateRect(g_window, NULL, FALSE);
}

void nimculus_platform_set_editor_status(const char *text) {
  g_editor_status_length = set_editor_wide_text(g_editor_status,
      (int)(sizeof(g_editor_status) / sizeof(g_editor_status[0])), text,
      text ? (uint32_t)strlen(text) : 0);
  if (g_window) InvalidateRect(g_window, NULL, FALSE);
}

void nimculus_platform_set_close_decision(bool allow) {
  if (!g_close_request_pending) return;
  g_close_request_pending = false;
  if (allow && g_window) DestroyWindow(g_window);
}

void nimculus_platform_invalidate_ime_coordinates(void) {
  update_ime_position();
}

void nimculus_clipboard_set(const char *utf8, uint32_t length) {
  if (!OpenClipboard(g_window)) return;
  EmptyClipboard();
  int wide_length = MultiByteToWideChar(CP_UTF8, 0, utf8, (int)length, NULL, 0);
  if (wide_length <= 0) {
    CloseClipboard();
    return;
  }
  HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, (SIZE_T)(wide_length + 1) * sizeof(wchar_t));
  if (!memory) {
    CloseClipboard();
    return;
  }
  wchar_t *wide = (wchar_t *)GlobalLock(memory);
  if (!wide || MultiByteToWideChar(CP_UTF8, 0, utf8, (int)length, wide, wide_length) <= 0) {
    if (wide) GlobalUnlock(memory);
    GlobalFree(memory);
    CloseClipboard();
    return;
  }
  wide[wide_length] = L'\0';
  GlobalUnlock(memory);
  if (!SetClipboardData(CF_UNICODETEXT, memory)) GlobalFree(memory);
  CloseClipboard();
}

uint32_t nimculus_clipboard_utf8_length(void) {
  g_clipboard_utf8[0] = '\0';
  if (!OpenClipboard(g_window)) return 0;
  HANDLE handle = GetClipboardData(CF_UNICODETEXT);
  if (!handle) {
    CloseClipboard();
    return 0;
  }
  const wchar_t *wide = (const wchar_t *)GlobalLock(handle);
  if (!wide) {
    CloseClipboard();
    return 0;
  }
  int length = WideCharToMultiByte(CP_UTF8, 0, wide, -1, g_clipboard_utf8,
                                   (int)sizeof(g_clipboard_utf8), NULL, NULL);
  GlobalUnlock(handle);
  CloseClipboard();
  if (length <= 0) {
    g_clipboard_utf8[0] = '\0';
    return 0;
  }
  g_clipboard_utf8[length - 1] = '\0';
  return (uint32_t)(length - 1);
}

const uint8_t *nimculus_clipboard_utf8_bytes(void) {
  return (const uint8_t *)g_clipboard_utf8;
}

static const char *run_file_dialog(BOOL save) {
  ZeroMemory(g_dialog_path, sizeof(g_dialog_path));
  OPENFILENAMEW dialog;
  ZeroMemory(&dialog, sizeof(dialog));
  dialog.lStructSize = sizeof(dialog);
  dialog.hwndOwner = g_window;
  dialog.lpstrFile = g_dialog_path;
  dialog.nMaxFile = (DWORD)(sizeof(g_dialog_path) / sizeof(g_dialog_path[0]));
  dialog.lpstrFilter = L"All files\0*.*\0\0";
  dialog.Flags = OFN_EXPLORER | (save ? OFN_OVERWRITEPROMPT : OFN_FILEMUSTEXIST);
  BOOL accepted = save ? GetSaveFileNameW(&dialog) : GetOpenFileNameW(&dialog);
  if (!accepted) {
    g_dialog_utf8[0] = '\0';
    return g_dialog_utf8;
  }
  int length = WideCharToMultiByte(CP_UTF8, 0, g_dialog_path, -1,
                                   g_dialog_utf8, (int)sizeof(g_dialog_utf8), NULL, NULL);
  if (length <= 0) g_dialog_utf8[0] = '\0';
  else g_dialog_utf8[length - 1] = '\0';
  return g_dialog_utf8;
}

const char *nimculus_choose_open_file(void) { return run_file_dialog(FALSE); }
const char *nimculus_choose_save_file(void) { return run_file_dialog(TRUE); }

void nimculus_platform_set_text_callback(NimculusTextCallback callback) {
  g_text_callback = callback;
}

void nimculus_platform_set_idle_callback(NimculusIdleCallback callback) {
  g_idle_callback = callback;
}

void nimculus_platform_set_command_callback(NimculusCommandCallback callback) {
  g_command_callback = callback;
}

void nimculus_platform_set_image_rgba(uint32_t image_id, uint32_t width,
                                      uint32_t height, const uint8_t *rgba,
                                      uint32_t length) {
  NimculusImage *image = get_image_slot(image_id);
  uint64_t required = (uint64_t)width * (uint64_t)height * 4u;
  if (!image || image_id == 0 || width == 0 || height == 0 ||
      required > UINT32_MAX || length < required || !rgba) {
    if (image) {
      if (image->view) image->view->lpVtbl->Release(image->view);
      free(image->rgba);
      ZeroMemory(image, sizeof(*image));
    }
    if (g_window) InvalidateRect(g_window, NULL, FALSE);
    return;
  }
  uint8_t *copy = (uint8_t *)malloc((size_t)required);
  if (!copy) return;
  memcpy(copy, rgba, (size_t)required);
  if (image->view) image->view->lpVtbl->Release(image->view);
  free(image->rgba);
  image->id = image_id;
  image->width = width;
  image->height = height;
  image->rgba = copy;
  image->view = NULL;
  upload_image_view(image);
  if (g_window) InvalidateRect(g_window, NULL, FALSE);
}

void nimculus_platform_set_paint_commands(const NimculusPaintCommand *commands,
                                          uint32_t count) {
  free(g_paint_commands);
  g_paint_commands = NULL;
  g_paint_count = 0;
  if (!commands || count == 0) {
    if (g_window) InvalidateRect(g_window, NULL, FALSE);
    return;
  }
  g_paint_commands = (NimculusPaintCommand *)malloc(sizeof(NimculusPaintCommand) * count);
  if (g_paint_commands) {
    memcpy(g_paint_commands, commands, sizeof(NimculusPaintCommand) * count);
    g_paint_count = count;
  }
  if (g_window) InvalidateRect(g_window, NULL, FALSE);
}

void nimculus_platform_set_editor_text(const char *utf8, uint32_t length) {
  free(g_editor_text);
  g_editor_text = NULL;
  g_editor_text_length = 0;
  free(g_editor_utf8);
  g_editor_utf8 = NULL;
  g_editor_utf8_length = 0;
  if (!utf8 || length == 0) {
    if (g_window) InvalidateRect(g_window, NULL, FALSE);
    return;
  }
  uint32_t bounded_length = min(length, 16u * 1024u * 1024u);
  g_editor_utf8 = (char *)malloc((size_t)bounded_length + 1);
  if (!g_editor_utf8) return;
  memcpy(g_editor_utf8, utf8, bounded_length);
  g_editor_utf8[bounded_length] = '\0';
  g_editor_utf8_length = bounded_length;
  int wide_length = MultiByteToWideChar(CP_UTF8, 0, utf8, (int)bounded_length,
                                        NULL, 0);
  if (wide_length <= 0) {
    free(g_editor_utf8);
    g_editor_utf8 = NULL;
    g_editor_utf8_length = 0;
    return;
  }
  g_editor_text = (wchar_t *)malloc((size_t)(wide_length + 1) * sizeof(wchar_t));
  if (!g_editor_text) {
    free(g_editor_utf8);
    g_editor_utf8 = NULL;
    g_editor_utf8_length = 0;
    return;
  }
  int converted = MultiByteToWideChar(CP_UTF8, 0, utf8, (int)bounded_length,
                                      g_editor_text, wide_length);
  if (converted <= 0) {
    free(g_editor_text);
    g_editor_text = NULL;
    free(g_editor_utf8);
    g_editor_utf8 = NULL;
    g_editor_utf8_length = 0;
    return;
  }
  g_editor_text[converted] = L'\0';
  g_editor_text_length = converted;
  if (g_window) InvalidateRect(g_window, NULL, FALSE);
}

void nimculus_platform_set_editor_highlights(const NimculusHighlightSpan *spans,
                                             uint32_t count) {
  free(g_editor_highlights);
  g_editor_highlights = NULL;
  g_editor_highlight_count = 0;
  if (spans && count > 0) {
    g_editor_highlights = (NimculusHighlightSpan *)malloc(
        sizeof(NimculusHighlightSpan) * (size_t)count);
    if (g_editor_highlights) {
      memcpy(g_editor_highlights, spans,
          sizeof(NimculusHighlightSpan) * (size_t)count);
      g_editor_highlight_count = count;
    }
  }
  if (g_window) InvalidateRect(g_window, NULL, FALSE);
}

void nimculus_platform_set_editor_composition(const char *utf8) {
  free(g_editor_composition);
  g_editor_composition = NULL;
  g_editor_composition_length = 0;
  if (utf8 && utf8[0] != '\0') {
    int wide_length = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, NULL, 0);
    if (wide_length > 1) {
      g_editor_composition = (wchar_t *)malloc(
          (size_t)wide_length * sizeof(wchar_t));
      if (g_editor_composition) {
        int converted = MultiByteToWideChar(CP_UTF8, 0, utf8, -1,
            g_editor_composition, wide_length);
        if (converted > 1) {
          g_editor_composition_length = converted - 1;
        } else {
          free(g_editor_composition);
          g_editor_composition = NULL;
        }
      }
    }
  }
  if (g_window) InvalidateRect(g_window, NULL, FALSE);
}

void nimculus_platform_set_shortcut_callback(NimculusShortcutCallback callback) {
  g_shortcut_callback = callback;
}

void nimculus_platform_toggle_fullscreen(void) {
  set_fullscreen(!g_fullscreen);
}

void nimculus_platform_minimize_window(void) {
  if (g_window) ShowWindow(g_window, SW_MINIMIZE);
}

void nimculus_platform_maximize_window(void) {
  if (g_window) ShowWindow(g_window, SW_MAXIMIZE);
}

void nimculus_platform_restore_window(void) {
  if (g_window) ShowWindow(g_window, SW_RESTORE);
}

void nimculus_platform_set_terminal_visible(bool visible) {
  g_terminal_visible = visible;
  if (g_window) InvalidateRect(g_window, NULL, FALSE);
}

void nimculus_platform_set_task_output_visible(bool visible) {
  g_task_output_visible = visible;
  if (g_window) InvalidateRect(g_window, NULL, FALSE);
}

void nimculus_platform_set_terminal_text(const char *utf8, uint32_t length) {
  free(g_terminal_utf8);
  g_terminal_utf8 = NULL;
  g_terminal_utf8_length = 0;
  ZeroMemory(g_terminal_text, sizeof(g_terminal_text));
  if (utf8 && length > 0) {
    uint32_t bounded = min((uint32_t)(sizeof(g_terminal_text) / sizeof(wchar_t) - 1), length);
    g_terminal_utf8 = (char *)malloc((size_t)bounded + 1);
    if (g_terminal_utf8) {
      memcpy(g_terminal_utf8, utf8, bounded);
      g_terminal_utf8[bounded] = '\0';
      g_terminal_utf8_length = bounded;
    }
    MultiByteToWideChar(CP_UTF8, 0, utf8, (int)bounded, g_terminal_text,
                        (int)(sizeof(g_terminal_text) / sizeof(wchar_t) - 1));
  }
  if (g_window) InvalidateRect(g_window, NULL, FALSE);
}

void nimculus_platform_set_task_output_text(const char *utf8, uint32_t length) {
  ZeroMemory(g_task_output_text, sizeof(g_task_output_text));
  if (utf8 && length > 0) {
    uint32_t bounded = min((uint32_t)(sizeof(g_task_output_text) /
        sizeof(wchar_t) - 1), length);
    MultiByteToWideChar(CP_UTF8, 0, utf8, (int)bounded,
        g_task_output_text,
        (int)(sizeof(g_task_output_text) / sizeof(wchar_t) - 1));
  }
  if (g_window) InvalidateRect(g_window, NULL, FALSE);
}

void nimculus_platform_set_terminal_runs(const char *utf8, uint32_t length,
                                         const NimculusTerminalRun *runs,
                                         uint32_t count) {
  nimculus_platform_set_terminal_text(utf8, length);
  free(g_terminal_runs);
  g_terminal_runs = NULL;
  g_terminal_run_count = 0;
  if (runs && count > 0) {
    g_terminal_runs = (NimculusTerminalRun *)malloc(
        sizeof(NimculusTerminalRun) * (size_t)count);
    if (g_terminal_runs) {
      memcpy(g_terminal_runs, runs,
          sizeof(NimculusTerminalRun) * (size_t)count);
      g_terminal_run_count = count;
    }
  }
  if (g_window) InvalidateRect(g_window, NULL, FALSE);
}

void nimculus_platform_set_terminal_selection(uint32_t start_row,
                                               uint32_t start_column,
                                               uint32_t end_row,
                                               uint32_t end_column) {
  g_terminal_selection_start_row = start_row;
  g_terminal_selection_start_column = start_column;
  g_terminal_selection_end_row = end_row;
  g_terminal_selection_end_column = end_column;
  if (g_window) InvalidateRect(g_window, NULL, FALSE);
}

void nimculus_platform_set_terminal_font_size(double size) {
  if (size < 6.0) size = 6.0;
  if (size > 48.0) size = 48.0;
  g_terminal_font_size = size;
  if (g_window) InvalidateRect(g_window, NULL, FALSE);
}

void nimculus_platform_get_terminal_cell_metrics(double *cell_width,
                                                  double *line_height) {
  double scale = g_metrics.scale_factor > 0.0 ? g_metrics.scale_factor : 1.0;
  double width = 7.2;
  double height = 14.0;
  if (g_window) {
    HDC dc = GetDC(g_window);
    if (dc) {
      HFONT font = CreateFontW(font_height(g_terminal_font_size, scale), 0, 0, 0,
          FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
          CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, FIXED_PITCH | FF_MODERN,
          g_terminal_font_name);
      if (font) {
        HGDIOBJ old_font = SelectObject(dc, font);
        TEXTMETRICW metrics;
        SIZE cell;
        if (GetTextMetricsW(dc, &metrics)) {
          height = ((double)metrics.tmHeight + 2.0 * scale) / scale;
        }
        if (GetTextExtentPoint32W(dc, L"M", 1, &cell) && cell.cx > 0) {
          width = (double)cell.cx / scale;
        }
        SelectObject(dc, old_font);
        DeleteObject(font);
      }
      ReleaseDC(g_window, dc);
    }
  }
  if (cell_width) *cell_width = width;
  if (line_height) *line_height = height;
}

void nimculus_platform_set_terminal_font_name(const char *name) {
  if (!name || name[0] == '\0') return;
  wchar_t wide[LF_FACESIZE];
  int length = MultiByteToWideChar(CP_UTF8, 0, name, -1, wide, LF_FACESIZE);
  if (length <= 1 || !nimculus_font_available(name, g_terminal_font_size)) return;
  wide[LF_FACESIZE - 1] = L'\0';
  wcsncpy(g_terminal_font_name, wide, LF_FACESIZE - 1);
  g_terminal_font_name[LF_FACESIZE - 1] = L'\0';
  if (g_window) InvalidateRect(g_window, NULL, FALSE);
}

void nimculus_platform_set_file_callback(NimculusFileCallback callback) {
  g_file_callback = callback;
}

void nimculus_platform_set_input_callback(NimculusInputCallback callback) {
  g_input_callback = callback;
}
