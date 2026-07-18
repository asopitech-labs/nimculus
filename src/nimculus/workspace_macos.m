#import <CoreServices/CoreServices.h>
#import <Foundation/Foundation.h>
#include "../nimnui/platform/macos/platform.h"

typedef void (*NimculusWorkspaceCallback)(const char *path, void *context);
typedef struct NimculusWorkspaceWatcher {
  FSEventStreamRef stream;
  NimculusWorkspaceCallback callback;
  void *userContext;
} NimculusWorkspaceWatcher;

static void workspaceEventCallback(ConstFSEventStreamRef stream, void *info,
  size_t count, void *eventPaths, const FSEventStreamEventFlags flags[],
  const FSEventStreamEventId ids[]) {
  NimculusWorkspaceWatcher *watcher = (NimculusWorkspaceWatcher *)info;
  NSArray *paths = (__bridge NSArray *)eventPaths;
  for (NSUInteger i = 0; i < count; i++) {
    NSString *path = paths[i];
    if (watcher->callback) watcher->callback(path.UTF8String, watcher->userContext);
  }
}

void *nimculus_start_workspace_watcher(const char *root, NimculusWorkspaceCallback callback, void *context) {
  if (!root || !callback) return NULL;
  NimculusWorkspaceWatcher *watcher = calloc(1, sizeof(*watcher));
  watcher->callback = callback;
  watcher->userContext = context;
  NSString *path = [NSString stringWithUTF8String:root];
  NSArray *paths = @[path];
  FSEventStreamContext streamContext = {0, watcher, NULL, NULL, NULL};
  watcher->stream = FSEventStreamCreate(NULL, workspaceEventCallback, &streamContext,
    (__bridge CFArrayRef)paths, kFSEventStreamEventIdSinceNow, 0.2,
    kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer);
  FSEventStreamScheduleWithRunLoop(watcher->stream, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
  FSEventStreamStart(watcher->stream);
  return watcher;
}

void nimculus_stop_workspace_watcher(void *value) {
  NimculusWorkspaceWatcher *watcher = value;
  if (!watcher) return;
  FSEventStreamStop(watcher->stream);
  FSEventStreamInvalidate(watcher->stream);
  FSEventStreamRelease(watcher->stream);
  free(watcher);
}
