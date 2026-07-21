#define WIN32_LEAN_AND_MEAN
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0600
#endif
#include <windows.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

typedef void (*NimculusWorkspaceCallback)(const char *path, void *context);

typedef struct NimculusWorkspaceWatcher {
  HANDLE directory;
  HANDLE thread;
  NimculusWorkspaceCallback callback;
  void *user_context;
  wchar_t *root;
} NimculusWorkspaceWatcher;

static BOOL watcher_path_utf8(const NimculusWorkspaceWatcher *watcher,
                              const FILE_NOTIFY_INFORMATION *change,
                              char *output, int output_capacity) {
  if (!watcher || !watcher->root || !change || !output || output_capacity <= 0) return FALSE;
  size_t root_length = wcslen(watcher->root);
  size_t name_length = change->FileNameLength / sizeof(wchar_t);
  if (root_length + 1 + name_length >= 32768) return FALSE;
  wchar_t full_path[32768];
  memcpy(full_path, watcher->root, root_length * sizeof(wchar_t));
  size_t offset = root_length;
  if (offset > 0 && full_path[offset - 1] != L'\\') full_path[offset++] = L'\\';
  memcpy(full_path + offset, change->FileName, name_length * sizeof(wchar_t));
  full_path[offset + name_length] = L'\0';
  int length = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, full_path,
                                   -1, output, output_capacity, NULL, NULL);
  if (length <= 0) {
    length = WideCharToMultiByte(CP_UTF8, 0, full_path, -1,
                                 output, output_capacity, NULL, NULL);
  }
  return length > 0;
}

static DWORD WINAPI workspace_watcher_thread(void *value) {
  NimculusWorkspaceWatcher *watcher = (NimculusWorkspaceWatcher *)value;
  BYTE buffer[64 * 1024];
  while (watcher && watcher->directory != INVALID_HANDLE_VALUE) {
    DWORD bytes = 0;
    BOOL received = ReadDirectoryChangesW(
        watcher->directory, buffer, sizeof(buffer), TRUE,
        FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_DIR_NAME |
            FILE_NOTIFY_CHANGE_LAST_WRITE | FILE_NOTIFY_CHANGE_SIZE,
        &bytes, NULL, NULL);
    if (!received || bytes == 0) break;
    DWORD offset = 0;
    while (offset < bytes) {
      FILE_NOTIFY_INFORMATION *change =
          (FILE_NOTIFY_INFORMATION *)(buffer + offset);
      char path[32768];
      if (watcher->callback && watcher_path_utf8(watcher, change, path, sizeof(path))) {
        watcher->callback(path, watcher->user_context);
      }
      if (change->NextEntryOffset == 0) break;
      offset += change->NextEntryOffset;
    }
  }
  return 0;
}

void *nimculus_start_workspace_watcher(const char *root,
                                       NimculusWorkspaceCallback callback,
                                       void *context) {
  if (!root || !callback) return NULL;
  int wide_length = MultiByteToWideChar(CP_UTF8, 0, root, -1, NULL, 0);
  if (wide_length <= 0) return NULL;
  NimculusWorkspaceWatcher *watcher =
      (NimculusWorkspaceWatcher *)calloc(1, sizeof(*watcher));
  if (!watcher) return NULL;
  watcher->directory = INVALID_HANDLE_VALUE;
  watcher->root = (wchar_t *)calloc((size_t)wide_length, sizeof(wchar_t));
  if (!watcher->root || MultiByteToWideChar(CP_UTF8, 0, root, -1,
                                            watcher->root, wide_length) <= 0) {
    free(watcher->root);
    free(watcher);
    return NULL;
  }
  watcher->directory = CreateFileW(
      watcher->root, FILE_LIST_DIRECTORY,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
      OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL);
  if (watcher->directory == INVALID_HANDLE_VALUE) {
    free(watcher->root);
    free(watcher);
    return NULL;
  }
  watcher->callback = callback;
  watcher->user_context = context;
  watcher->thread = CreateThread(NULL, 0, workspace_watcher_thread, watcher, 0, NULL);
  if (!watcher->thread) {
    CloseHandle(watcher->directory);
    free(watcher->root);
    free(watcher);
    return NULL;
  }
  return watcher;
}

void nimculus_stop_workspace_watcher(void *value) {
  NimculusWorkspaceWatcher *watcher = (NimculusWorkspaceWatcher *)value;
  if (!watcher) return;
  if (watcher->thread) {
    CancelSynchronousIo(watcher->thread);
    WaitForSingleObject(watcher->thread, INFINITE);
    CloseHandle(watcher->thread);
  }
  if (watcher->directory != INVALID_HANDLE_VALUE) CloseHandle(watcher->directory);
  free(watcher->root);
  free(watcher);
}
