#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0A00
#include <windows.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

typedef struct NimculusConPty {
  HPCON pseudo_console;
  HANDLE input_write;
  HANDLE output_read;
  HANDLE process;
} NimculusConPty;

static wchar_t *utf8_to_wide(const char *utf8) {
  if (!utf8 || utf8[0] == '\0') return NULL;
  int length = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, NULL, 0);
  if (length <= 0) return NULL;
  wchar_t *result = (wchar_t *)calloc((size_t)length, sizeof(wchar_t));
  if (!result) return NULL;
  if (MultiByteToWideChar(CP_UTF8, 0, utf8, -1, result, length) <= 0) {
    free(result);
    return NULL;
  }
  return result;
}

static void close_handle(HANDLE *handle) {
  if (*handle && *handle != INVALID_HANDLE_VALUE) {
    CloseHandle(*handle);
    *handle = NULL;
  }
}

NimculusConPty *nimculus_conpty_create(const char *shell, const char *working_directory,
                                       uint16_t columns, uint16_t rows) {
  wchar_t *wide_shell = utf8_to_wide(shell && shell[0] ? shell : "cmd.exe");
  wchar_t *wide_directory = utf8_to_wide(working_directory);
  if (!wide_shell) {
    free(wide_directory);
    return NULL;
  }

  SECURITY_ATTRIBUTES security = {0};
  security.nLength = sizeof(security);
  security.bInheritHandle = TRUE;
  HANDLE input_read = NULL;
  HANDLE input_write = NULL;
  HANDLE output_read = NULL;
  HANDLE output_write = NULL;
  NimculusConPty *pty = NULL;
  if (!CreatePipe(&input_read, &input_write, &security, 0) ||
      !CreatePipe(&output_read, &output_write, &security, 0)) {
    close_handle(&input_read);
    close_handle(&input_write);
    close_handle(&output_read);
    close_handle(&output_write);
    free(wide_shell);
    free(wide_directory);
    return NULL;
  }

  COORD size = {(SHORT)(columns > 0 ? columns : 80),
                (SHORT)(rows > 0 ? rows : 24)};
  HPCON pseudo_console = NULL;
  HRESULT result = CreatePseudoConsole(size, input_read, output_write, 0, &pseudo_console);
  close_handle(&input_read);
  close_handle(&output_write);
  if (FAILED(result)) {
    close_handle(&input_write);
    close_handle(&output_read);
    free(wide_shell);
    free(wide_directory);
    return NULL;
  }
  SetHandleInformation(input_write, HANDLE_FLAG_INHERIT, 0);
  SetHandleInformation(output_read, HANDLE_FLAG_INHERIT, 0);

  size_t shell_length = wcslen(wide_shell);
  wchar_t *command_line = (wchar_t *)calloc(shell_length + 3, sizeof(wchar_t));
  if (!command_line) {
    ClosePseudoConsole(pseudo_console);
    close_handle(&input_write);
    close_handle(&output_read);
    free(wide_shell);
    free(wide_directory);
    return NULL;
  }
  command_line[0] = L'"';
  memcpy(command_line + 1, wide_shell, shell_length * sizeof(wchar_t));
  command_line[shell_length + 1] = L'"';

  SIZE_T attribute_size = 0;
  InitializeProcThreadAttributeList(NULL, 1, 0, &attribute_size);
  LPPROC_THREAD_ATTRIBUTE_LIST attributes =
      (LPPROC_THREAD_ATTRIBUTE_LIST)HeapAlloc(GetProcessHeap(), 0, attribute_size);
  if (!attributes || !InitializeProcThreadAttributeList(attributes, 1, 0, &attribute_size) ||
      !UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
                                 pseudo_console, sizeof(pseudo_console), NULL, NULL)) {
    if (attributes) HeapFree(GetProcessHeap(), 0, attributes);
    free(command_line);
    ClosePseudoConsole(pseudo_console);
    close_handle(&input_write);
    close_handle(&output_read);
    free(wide_shell);
    free(wide_directory);
    return NULL;
  }

  STARTUPINFOEXW startup = {0};
  startup.StartupInfo.cb = sizeof(startup);
  startup.lpAttributeList = attributes;
  PROCESS_INFORMATION process = {0};
  BOOL created = CreateProcessW(NULL, command_line, NULL, NULL, FALSE,
      EXTENDED_STARTUPINFO_PRESENT, NULL, wide_directory, &startup.StartupInfo, &process);
  DeleteProcThreadAttributeList(attributes);
  HeapFree(GetProcessHeap(), 0, attributes);
  free(command_line);
  free(wide_shell);
  free(wide_directory);
  if (!created) {
    ClosePseudoConsole(pseudo_console);
    close_handle(&input_write);
    close_handle(&output_read);
    return NULL;
  }

  CloseHandle(process.hThread);
  pty = (NimculusConPty *)calloc(1, sizeof(NimculusConPty));
  if (!pty) {
    TerminateProcess(process.hProcess, 1);
    CloseHandle(process.hProcess);
    ClosePseudoConsole(pseudo_console);
    close_handle(&input_write);
    close_handle(&output_read);
    return NULL;
  }
  pty->pseudo_console = pseudo_console;
  pty->input_write = input_write;
  pty->output_read = output_read;
  pty->process = process.hProcess;
  return pty;
}

int32_t nimculus_conpty_write(NimculusConPty *pty, const uint8_t *bytes, uint32_t length) {
  if (!pty || !pty->input_write || !bytes || length == 0) return 0;
  DWORD written = 0;
  if (!WriteFile(pty->input_write, bytes, length, &written, NULL)) return -1;
  return (int32_t)written;
}

uint32_t nimculus_conpty_read(NimculusConPty *pty, uint8_t *bytes, uint32_t capacity) {
  if (!pty || !pty->output_read || !bytes || capacity == 0) return 0;
  DWORD available = 0;
  if (!PeekNamedPipe(pty->output_read, NULL, 0, NULL, &available, NULL)) return 0;
  if (available == 0) return 0;
  DWORD read = 0;
  if (!ReadFile(pty->output_read, bytes, min(available, capacity), &read, NULL)) return 0;
  return read;
}

bool nimculus_conpty_resize(NimculusConPty *pty, uint16_t columns, uint16_t rows) {
  if (!pty || !pty->pseudo_console) return false;
  COORD size = {(SHORT)(columns > 0 ? columns : 1),
                (SHORT)(rows > 0 ? rows : 1)};
  return SUCCEEDED(ResizePseudoConsole(pty->pseudo_console, size));
}

void nimculus_conpty_close(NimculusConPty *pty) {
  if (!pty) return;
  if (pty->process) {
    if (WaitForSingleObject(pty->process, 0) == WAIT_TIMEOUT) {
      TerminateProcess(pty->process, 0);
      WaitForSingleObject(pty->process, 1000);
    }
    close_handle(&pty->process);
  }
  close_handle(&pty->input_write);
  close_handle(&pty->output_read);
  if (pty->pseudo_console) ClosePseudoConsole(pty->pseudo_console);
  free(pty);
}
