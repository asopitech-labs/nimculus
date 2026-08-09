import std/[asyncdispatch, os, osproc, times, unittest]
import nimnui/platform/headless/platform
import nimnui/executor
import nimculus/git_service

proc tickUntil[T](future: Future[T]) =
  for _ in 0 ..< 400:
    if future.finished: return
    pollAsyncDispatchTick()
    sleep(1)
  pollAsyncDispatchTick()

suite "Zed-shaped async execution":
  test "Future completion is observed by one frame tick":
    let dispatcher = newPlatformDispatcher()
    let executor = newBackgroundExecutor(dispatcher)
    let ownerThread = getThreadId()
    let future = executor.spawn(proc(): int {.gcsafe.} = getThreadId())
    check not future.finished
    tickUntil(future)
    check future.finished
    check future.read != ownerThread

  test "a tick with no pending operations is safe":
    for _ in 0 ..< 4:
      pollAsyncDispatchTick()
    check true

  test "background results complete and callbacks run on the owner thread":
    let dispatcher = newPlatformDispatcher()
    let executor = newBackgroundExecutor(dispatcher)
    let ownerThread = getThreadId()
    var callbackThread = 0
    let future = executor.spawn(proc(): string {.gcsafe.} = "ready")
    future.addCallback(proc() = callbackThread = getThreadId())
    tickUntil(future)
    if callbackThread == 0:
      pollAsyncDispatchTick()
    check future.read == "ready"
    check callbackThread == ownerThread

  test "newGitRepository resolves without blocking its caller":
    let root = getTempDir() / ("nimculus-ui102-git-" & $getCurrentProcessId() &
      "-" & $int(epochTime() * 1_000_000))
    createDir(root)
    defer: removeDir(root)
    discard execCmdEx("git -C " & quoteShell(root) & " init -q")
    let dispatcher = newPlatformDispatcher()
    let executor = newBackgroundExecutor(dispatcher)
    let started = epochTime()
    let future = newGitRepository(root, executor)
    check epochTime() - started < 0.2
    tickUntil(future)
    check future.finished
    check future.read != nil
