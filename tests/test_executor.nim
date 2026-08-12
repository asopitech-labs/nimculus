import std/[asyncdispatch, os, osproc, times, unittest]
import nimnui/platform/headless/platform
import nimnui/executor
import nimculus/git_service
import wait_support

proc tickUntil[T](label: string; future: Future[T]): TestWaitResult =
  waitForTest(label, condition = proc(): bool =
    pollAsyncDispatchTick()
    future.finished)

suite "Zed-shaped async execution":
  test "Future completion is observed by one frame tick":
    let dispatcher = newPlatformDispatcher()
    let executor = newBackgroundExecutor(dispatcher)
    let ownerThread = getThreadId()
    let future = executor.spawn(proc(): int {.gcsafe.} = getThreadId())
    check not future.finished
    let wait = tickUntil("background future completion", future)
    check checkTestWait(wait)
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
    let wait = waitForTest("background future and callback completion",
      condition = proc(): bool =
        pollAsyncDispatchTick()
        future.finished and callbackThread != 0)
    check checkTestWait(wait)
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
    let future = newGitRepository(root, executor)
    check not future.finished
    let wait = tickUntil("newGitRepository future completion", future)
    check checkTestWait(wait)
    check future.finished
    check future.read != nil
