## Framework-neutral implementation glue for PlatformDispatcher.
##
## Native backends provide the four C ABI operations declared in contracts.h.
## This module owns only runnable lifetime and the portable test stub; it does
## not contain UI policy.

import std/os
import nimnui/platform/contracts

type
  NativeRunnable* = proc(context: pointer) {.cdecl, gcsafe.}
  NativeIsMainThread* = proc(): bool {.cdecl, gcsafe.}
  NativeDispatch* = proc(runnable: NativeRunnable, context: pointer,
                         priority: PlatformPriority) {.cdecl, gcsafe.}
  NativeDispatchAfter* = proc(durationNanoseconds: uint64,
                               runnable: NativeRunnable,
                               context: pointer) {.cdecl, gcsafe.}

  RunnableBox = ref object
    callback: Runnable

proc runRunnableBox(context: pointer) {.cdecl, gcsafe.} =
  let box = cast[RunnableBox](context)
  if box == nil: return
  try:
    box.callback()
  finally:
    GC_unref(box)

proc nativeContext(runnable: Runnable): pointer =
  var box = RunnableBox(callback: runnable)
  GC_ref(box)
  cast[pointer](box)

proc newNativePlatformDispatcher*(isMainThread: NativeIsMainThread,
                                  dispatch: NativeDispatch,
                                  dispatchOnMain: NativeDispatch,
                                  dispatchAfter: NativeDispatchAfter): PlatformDispatcher =
  result = PlatformDispatcher()
  result.mainThread = proc(): bool {.gcsafe.} = isMainThread()
  result.background = proc(runnable: Runnable, priority: PlatformPriority) {.gcsafe.} =
    dispatch(runRunnableBox, nativeContext(runnable), priority)
  result.mainQueue = proc(runnable: Runnable, priority: PlatformPriority) {.gcsafe.} =
    dispatchOnMain(runRunnableBox, nativeContext(runnable), priority)
  result.delayed = proc(durationNanoseconds: uint64, runnable: Runnable) {.gcsafe.} =
    dispatchAfter(durationNanoseconds, runRunnableBox, nativeContext(runnable))

when compileOption("threads"):
  import std/[locks, threadpool]

  var portableMainQueueLock: Lock
  type PortableMainQueue = object
    items: seq[pointer]
  var portableMainQueue: ptr PortableMainQueue
  initLock(portableMainQueueLock)
  portableMainQueue = cast[ptr PortableMainQueue](allocShared0(sizeof(PortableMainQueue)))

  proc portableBackground(runnable: Runnable) {.gcsafe.} = runnable()

  proc portableMain(runnable: Runnable) {.gcsafe.} =
    var box = RunnableBox(callback: runnable)
    GC_ref(box)
    acquire(portableMainQueueLock)
    portableMainQueue[].items.add(cast[pointer](box))
    release(portableMainQueueLock)

  proc portableDelayed(durationNanoseconds: uint64, runnable: Runnable) {.gcsafe.} =
    sleep(int(durationNanoseconds div 1_000_000))
    portableMain(runnable)

  proc newPortablePlatformDispatcher*(): PlatformDispatcher =
    result = PlatformDispatcher()
    result.mainThread = proc(): bool {.gcsafe.} = true
    result.background = proc(runnable: Runnable, priority: PlatformPriority) {.gcsafe.} =
      discard priority
      spawn portableBackground(runnable)
    result.mainQueue = proc(runnable: Runnable, priority: PlatformPriority) {.gcsafe.} =
      discard priority
      portableMain(runnable)
    result.delayed = proc(durationNanoseconds: uint64, runnable: Runnable) {.gcsafe.} =
      spawn portableDelayed(durationNanoseconds, runnable)

  proc pollPortableMainThread*() =
    while true:
      var context: pointer
      acquire(portableMainQueueLock)
      if portableMainQueue[].items.len > 0:
        context = portableMainQueue[].items[0]
        portableMainQueue[].items.delete(0)
      release(portableMainQueueLock)
      if context == nil: break
      runRunnableBox(context)
else:
  proc newPortablePlatformDispatcher*(): PlatformDispatcher =
    result = PlatformDispatcher()
    result.mainThread = proc(): bool = true
    result.background = proc(runnable: Runnable, priority: PlatformPriority) =
      discard priority
      runnable()
    result.mainQueue = proc(runnable: Runnable, priority: PlatformPriority) =
      discard priority
      runnable()
    result.delayed = proc(durationNanoseconds: uint64, runnable: Runnable) =
      discard durationNanoseconds
      runnable()

  proc pollPortableMainThread*() = discard
