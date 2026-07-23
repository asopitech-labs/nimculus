#import <CoreServices/CoreServices.h>
#import <Foundation/Foundation.h>
#include "../nimnui/platform/macos/platform.h"

typedef void (*NimculusWorkspaceCallback)(const char *path, void *context);
typedef struct NimculusWorkspaceWatcher {
  FSEventStreamRef stream;
  NimculusWorkspaceCallback callback;
  void *userContext;
  CFStringRef rootPath;
} NimculusWorkspaceWatcher;

static BOOL workspaceEventNeedsRescan(FSEventStreamEventFlags flags) {
  const FSEventStreamEventFlags rescanFlags =
    kFSEventStreamEventFlagMustScanSubDirs |
    kFSEventStreamEventFlagUserDropped |
    kFSEventStreamEventFlagKernelDropped |
    kFSEventStreamEventFlagEventIdsWrapped |
    kFSEventStreamEventFlagRootChanged;
  return (flags & rescanFlags) != 0;
}

bool nimculus_workspace_validate_rescan_flags(void) {
  return workspaceEventNeedsRescan(kFSEventStreamEventFlagMustScanSubDirs) &&
    workspaceEventNeedsRescan(kFSEventStreamEventFlagUserDropped) &&
    workspaceEventNeedsRescan(kFSEventStreamEventFlagKernelDropped) &&
    workspaceEventNeedsRescan(kFSEventStreamEventFlagEventIdsWrapped) &&
    workspaceEventNeedsRescan(kFSEventStreamEventFlagRootChanged) &&
    !workspaceEventNeedsRescan(kFSEventStreamEventFlagHistoryDone);
}

static void workspaceEventCallback(ConstFSEventStreamRef stream, void *info,
  size_t count, void *eventPaths, const FSEventStreamEventFlags flags[],
  const FSEventStreamEventId ids[]) {
  NimculusWorkspaceWatcher *watcher = (NimculusWorkspaceWatcher *)info;
  NSArray *paths = (__bridge NSArray *)eventPaths;
  for (NSUInteger i = 0; i < count; i++) {
    // FSEvents can explicitly report that one or more paths were dropped or
    // that the event-id history wrapped. Zed treats this as a rescan request;
    // emitting the watched root gives the lazy Nim workspace one stable
    // invalidation boundary instead of trusting an incomplete path list.
    if (workspaceEventNeedsRescan(flags[i])) {
      if (watcher->callback && watcher->rootPath) {
        NSString *rootPath = (__bridge NSString *)watcher->rootPath;
        watcher->callback(rootPath.UTF8String, watcher->userContext);
      }
      continue;
    }
    NSString *path = paths[i];
    if (watcher->callback) watcher->callback(path.UTF8String, watcher->userContext);
  }
}

void *nimculus_start_workspace_watcher(const char *root, NimculusWorkspaceCallback callback, void *context) {
  if (!root || !callback) return NULL;
  NimculusWorkspaceWatcher *watcher = calloc(1, sizeof(*watcher));
  if (!watcher) return NULL;
  watcher->callback = callback;
  watcher->userContext = context;
  NSString *path = [NSString stringWithUTF8String:root];
  if (!path) {
    free(watcher);
    return NULL;
  }
  watcher->rootPath = CFStringCreateCopy(NULL, (__bridge CFStringRef)path);
  if (!watcher->rootPath) {
    free(watcher);
    return NULL;
  }
  NSArray *paths = @[path];
  FSEventStreamContext streamContext = {0, watcher, NULL, NULL, NULL};
  watcher->stream = FSEventStreamCreate(NULL, workspaceEventCallback, &streamContext,
    (__bridge CFArrayRef)paths, kFSEventStreamEventIdSinceNow, 0.2,
    kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer |
      kFSEventStreamCreateFlagUseCFTypes);
  if (!watcher->stream) {
    CFRelease(watcher->rootPath);
    free(watcher);
    return NULL;
  }
  FSEventStreamScheduleWithRunLoop(watcher->stream, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
  if (!FSEventStreamStart(watcher->stream)) {
    FSEventStreamInvalidate(watcher->stream);
    FSEventStreamRelease(watcher->stream);
    CFRelease(watcher->rootPath);
    free(watcher);
    return NULL;
  }
  return watcher;
}

void nimculus_stop_workspace_watcher(void *value) {
  NimculusWorkspaceWatcher *watcher = value;
  if (!watcher) return;
  if (watcher->stream) {
    FSEventStreamStop(watcher->stream);
    FSEventStreamInvalidate(watcher->stream);
    FSEventStreamRelease(watcher->stream);
  }
  if (watcher->rootPath) CFRelease(watcher->rootPath);
  free(watcher);
}
