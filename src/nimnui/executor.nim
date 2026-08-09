## Zed-shaped framework executors backed by Nim's std Future.
##
## `Task[T]` is deliberately an alias for `Future[T]`. A Future is created,
## completed, and read only on its owner thread. Background work crosses the
## platform boundary as a runnable and returns only its value to the owner
## thread before completion.

import std/asyncdispatch
import std/asyncfutures
import nimnui/platform/contracts
import nimnui/platform/dispatcher

export asyncfutures

type
  Task*[T] = Future[T]

  BackgroundExecutor* = ref object
    dispatcher*: PlatformDispatcher

  ForegroundExecutor* = ref object
    dispatcher*: PlatformDispatcher

proc newBackgroundExecutor*(dispatcher: PlatformDispatcher): BackgroundExecutor =
  BackgroundExecutor(dispatcher: dispatcher)

proc newForegroundExecutor*(dispatcher: PlatformDispatcher): ForegroundExecutor =
  ForegroundExecutor(dispatcher: dispatcher)

proc spawn*[T](executor: BackgroundExecutor, work: proc(): T {.gcsafe.}): Task[T] =
  ## Equivalent to Zed's BackgroundExecutor::spawn: the work is Send-like,
  ## while the Future itself remains owned by the spawning thread.
  let future = newFuture[T]("BackgroundExecutor.spawn")
  let dispatcher = executor.dispatcher
  dispatcher.dispatch(proc() {.gcsafe.} =
    var value: T
    var error: ref CatchableError
    try:
      value = work()
    except CatchableError:
      error = cast[ref CatchableError](getCurrentException())
    dispatcher.dispatchOnMainThread(proc() {.gcsafe.} =
      if error == nil:
        future.complete(value)
      else:
        future.fail(error)
    , platformMedium)
  , platformMedium)
  future

proc spawn*[T](executor: ForegroundExecutor, work: proc(): T {.gcsafe.}): Task[T] =
  ## Equivalent to Zed's ForegroundExecutor::spawn. The work and completion
  ## both run through the main-thread dispatcher.
  let future = newFuture[T]("ForegroundExecutor.spawn")
  executor.dispatcher.dispatchOnMainThread(proc() {.gcsafe.} =
    try:
      future.complete(work())
    except CatchableError:
      future.fail(cast[ref CatchableError](getCurrentException()))
  , platformMedium)
  future

proc isMainThread*(executor: BackgroundExecutor): bool =
  executor.dispatcher.mainThread()

proc isMainThread*(executor: ForegroundExecutor): bool =
  executor.dispatcher.mainThread()

proc pollAsyncDispatchTick*() =
  ## Called once by the live frame owner. poll(0) is guarded because Nim's
  ## async dispatcher raises when no handles/timers/callbacks are registered.
  ## The portable backend drains its main-thread stub queue here first.
  pollPortableMainThread()
  if hasPendingOperations():
    poll(0)
