import std/[monotimes, os, times]

type
  TestWaitResult* = object
    label*: string
    completed*: bool
    elapsedMs*: int64
    timeoutMs*: int

proc waitForTest*(label: string; timeoutMs: int = 10_000;
    pollIntervalMs: int = 10; condition: proc(): bool {.closure.}): TestWaitResult =
  let started = getMonoTime()
  while true:
    if condition():
      return TestWaitResult(label: label, completed: true,
        elapsedMs: inMilliseconds(getMonoTime() - started), timeoutMs: timeoutMs)
    let elapsed = inMilliseconds(getMonoTime() - started)
    if elapsed >= int64(timeoutMs):
      return TestWaitResult(label: label, completed: false,
        elapsedMs: elapsed, timeoutMs: timeoutMs)
    sleep(min(pollIntervalMs, timeoutMs - int(elapsed)))

proc checkTestWait*(wait: TestWaitResult): bool =
  if not wait.completed:
    echo "  [WAIT TIMEOUT] ", wait.label, " after ",
      float64(wait.elapsedMs) / 1000.0, " s (limit ",
      float64(wait.timeoutMs) / 1000.0, " s)"
  wait.completed
