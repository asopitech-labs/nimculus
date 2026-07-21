#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#include <d2d1.h>
#include <dwrite.h>
#include <dxgi.h>
#include <commdlg.h>
#include <imm.h>
#include <shellapi.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#include "../contracts.h"

static NimculusPlatformMetrics g_metrics = {1.0, 0, 0, 0, 0, 0.0, 0};
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
static ID3D11InputLayout *g_quad_input_layout = NULL;
static ID3D11Buffer *g_quad_vertex_buffer = NULL;
static ID3D11RasterizerState *g_quad_rasterizer = NULL;
static ID3D11BlendState *g_quad_blend_state = NULL;
static ID3D11SamplerState *g_image_sampler = NULL;
static ID2D1Factory *g_d2d_factory = NULL;
static ID2D1RenderTarget *g_d2d_target = NULL;
static ID2D1SolidColorBrush *g_d2d_text_brush = NULL;
static IDWriteFactory *g_dwrite_factory = NULL;
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

static void release_quad_pipeline(void) {
  if (g_quad_blend_state) g_quad_blend_state->lpVtbl->Release(g_quad_blend_state);
  if (g_quad_rasterizer) g_quad_rasterizer->lpVtbl->Release(g_quad_rasterizer);
  if (g_quad_vertex_buffer) g_quad_vertex_buffer->lpVtbl->Release(g_quad_vertex_buffer);
  if (g_quad_input_layout) g_quad_input_layout->lpVtbl->Release(g_quad_input_layout);
  if (g_quad_pixel_shader) g_quad_pixel_shader->lpVtbl->Release(g_quad_pixel_shader);
  if (g_image_pixel_shader) g_image_pixel_shader->lpVtbl->Release(g_image_pixel_shader);
  if (g_quad_vertex_shader) g_quad_vertex_shader->lpVtbl->Release(g_quad_vertex_shader);
  if (g_image_sampler) g_image_sampler->lpVtbl->Release(g_image_sampler);
  g_quad_rasterizer = NULL;
  g_quad_vertex_buffer = NULL;
  g_quad_input_layout = NULL;
  g_quad_blend_state = NULL;
  g_quad_pixel_shader = NULL;
  g_image_pixel_shader = NULL;
  g_image_sampler = NULL;
  g_quad_vertex_shader = NULL;
}

static bool create_quad_pipeline(void) {
  ID3DBlob *vertex_blob = NULL;
  ID3DBlob *pixel_blob = NULL;
  ID3DBlob *image_pixel_blob = NULL;
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
  if (g_dwrite_factory) return true;
  HRESULT hr = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED,
      &IID_IDWriteFactory, (IUnknown **)&g_dwrite_factory);
  return SUCCEEDED(hr);
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
  if (!create_render_target()) return false;
  create_directwrite_target();
  if (!create_quad_pipeline()) return false;
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
  float left = (float)(268.0 * scale);
  float top = (float)(128.0 * scale);
  float right = (float)g_metrics.width_pixels - (float)(24.0 * scale);
  float bottom = (float)g_metrics.height_pixels - (float)(48.0 * scale);
  if (right <= left || bottom <= top) return false;
  if (!ensure_directwrite_factory()) return false;
  IDWriteFactory *factory = g_dwrite_factory;
  HRESULT hr;
  IDWriteTextFormat *format = NULL;
  hr = factory->lpVtbl->CreateTextFormat(factory, g_editor_font_name, NULL,
      DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STYLE_NORMAL,
      DWRITE_FONT_STRETCH_NORMAL, (FLOAT)(g_editor_font_size * scale),
      L"", &format);
  if (FAILED(hr)) {
    return false;
  }
  format->lpVtbl->SetWordWrapping(format, g_editor_soft_wrap
      ? DWRITE_WORD_WRAPPING_WRAP : DWRITE_WORD_WRAPPING_NO_WRAP);
  format->lpVtbl->SetTextAlignment(format, DWRITE_TEXT_ALIGNMENT_LEADING);
  format->lpVtbl->SetParagraphAlignment(format, DWRITE_PARAGRAPH_ALIGNMENT_NEAR);
  ID2D1SolidColorBrush *selection_brush = NULL;
  D2D1_COLOR_F selection_color = {0.22f, 0.30f, 0.44f, 1.0f};
  hr = g_d2d_target->lpVtbl->CreateSolidColorBrush(g_d2d_target,
      &selection_color, NULL, &selection_brush);
  if (FAILED(hr)) {
    format->lpVtbl->Release(format);
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
      format->lpVtbl->Release(format);
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
  format->lpVtbl->Release(format);
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
  HRESULT present = g_swap_chain->lpVtbl->Present(g_swap_chain, 1, 0);
  if (SUCCEEDED(present)) {
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
  LONG left = (LONG)(268.0 * scale);
  LONG top = (LONG)(128.0 * scale);
  LONG right = client.right - (LONG)(24.0 * scale);
  LONG bottom = client.bottom - (LONG)(48.0 * scale);
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
  LONG editor_left = (LONG)(268.0 * scale);
  LONG editor_top = (LONG)(128.0 * scale);
  LONG editor_right = client.right - (LONG)(24.0 * scale);
  LONG editor_bottom = client.bottom - (LONG)(48.0 * scale);
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
  create_device();
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
  if (g_d2d_factory) {
    g_d2d_factory->lpVtbl->Release(g_d2d_factory);
    g_d2d_factory = NULL;
  }
  if (g_dwrite_factory) {
    g_dwrite_factory->lpVtbl->Release(g_dwrite_factory);
    g_dwrite_factory = NULL;
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

bool nimculus_platform_validate_native(void) {
  return g_device != NULL && g_swap_chain != NULL;
}

uint64_t nimculus_platform_input_count(void) { return g_input_count; }

void nimculus_platform_get_metrics(NimculusPlatformMetrics *metrics) {
  if (metrics) *metrics = g_metrics;
}

void nimculus_platform_set_input_callback(NimculusInputCallback callback) {
  g_input_callback = callback;
}

void nimculus_platform_set_editor_cursor(double x, double y) {
  g_editor_cursor_x = x;
  g_editor_cursor_y = y;
  update_ime_position();
}

void nimculus_platform_set_editor_font_size(double size) {
  if (size < 6.0) size = 6.0;
  if (size > 48.0) size = 48.0;
  g_editor_font_size = size;
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
