#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <commdlg.h>
#include <imm.h>
#include <stdint.h>
#include <string.h>

#include "../contracts.h"

static NimculusPlatformMetrics g_metrics = {1.0, 0, 0, 0, 0, 0.0, 0};
static uint64_t g_input_count = 0;
static NimculusInputCallback g_input_callback = NULL;
static NimculusTextCallback g_text_callback = NULL;
static HWND g_window = NULL;
static ID3D11Device *g_device = NULL;
static ID3D11DeviceContext *g_context = NULL;
static IDXGISwapChain *g_swap_chain = NULL;
static ID3D11RenderTargetView *g_render_target = NULL;
static char g_clipboard_utf8[4 * 1024 * 1024];
static wchar_t g_dialog_path[32768];
static char g_dialog_utf8[32768];
static wchar_t g_ime_wide[32768];
static char g_ime_utf8[131072];
static double g_editor_cursor_x = 8.0;
static double g_editor_cursor_y = 20.0;

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

static void release_render_target(void) {
  if (g_render_target) {
    g_render_target->lpVtbl->Release(g_render_target);
    g_render_target = NULL;
  }
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
  release_render_target();
  if (g_metrics.width_pixels == 0 || g_metrics.height_pixels == 0) return;
  if (FAILED(g_swap_chain->lpVtbl->ResizeBuffers(
      g_swap_chain, 0, g_metrics.width_pixels, g_metrics.height_pixels,
      DXGI_FORMAT_UNKNOWN, 0))) return;
  create_render_target();
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
  return create_render_target();
}

static void render_frame(void) {
  if (!g_context || !g_render_target || !g_swap_chain) return;
  const FLOAT clear_color[4] = {0.10f, 0.12f, 0.16f, 1.0f};
  g_context->lpVtbl->OMSetRenderTargets(g_context, 1, &g_render_target, NULL);
  g_context->lpVtbl->ClearRenderTargetView(g_context, g_render_target, clear_color);
  if (SUCCEEDED(g_swap_chain->lpVtbl->Present(g_swap_chain, 1, 0))) {
    g_metrics.frame_count++;
  }
}

static void send_input(UINT type, UINT key_code, UINT button, LPARAM lparam) {
  if (!g_input_callback) return;
  NimculusInputEvent event = {0};
  event.type = type;
  event.key_code = key_code;
  event.button = button;
  event.modifiers = 0;
  if (GetKeyState(VK_SHIFT) & 0x8000) event.modifiers |= 1u << 17;
  if (GetKeyState(VK_CONTROL) & 0x8000) event.modifiers |= 1u << 18;
  if (GetKeyState(VK_MENU) & 0x8000) event.modifiers |= 1u << 19;
  event.x = (double)(short)LOWORD(lparam);
  event.y = (double)(short)HIWORD(lparam);
  g_input_count++;
  g_input_callback(&event);
}

static LRESULT CALLBACK window_proc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  switch (message) {
    case WM_SIZE:
      update_metrics();
      resize_render_target();
      InvalidateRect(window, NULL, FALSE);
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
      EndPaint(window, &paint);
      return 0;
    }
    case WM_KEYDOWN:
      send_input(1, (UINT)wparam, 0, 0);
      return 0;
    case WM_LBUTTONDOWN:
      send_input(2, 0, 1, lparam);
      return 0;
    case WM_LBUTTONUP:
      send_input(3, 0, 1, lparam);
      return 0;
    case WM_MOUSEMOVE:
      send_input(4, 0, 0, lparam);
      return 0;
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
      char utf8[8] = {0};
      int length = WideCharToMultiByte(CP_UTF8, 0, &wide, 1, utf8, 7, NULL, NULL);
      if (length > 0 && g_text_callback) g_text_callback(utf8, false);
      return 0;
    }
    case WM_CLOSE:
      DestroyWindow(window);
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
  create_device();
  MSG message;
  while (GetMessageW(&message, NULL, 0, 0) > 0) {
    TranslateMessage(&message);
    DispatchMessageW(&message);
  }
  release_render_target();
  if (g_swap_chain) g_swap_chain->lpVtbl->Release(g_swap_chain);
  if (g_context) g_context->lpVtbl->Release(g_context);
  if (g_device) g_device->lpVtbl->Release(g_device);
  g_swap_chain = NULL;
  g_context = NULL;
  g_device = NULL;
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

void nimculus_platform_set_input_callback(NimculusInputCallback callback) {
  g_input_callback = callback;
}
