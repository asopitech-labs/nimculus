import std/os
import std/strutils
import std/unittest

import nimculus/agent_service

suite "M18 CLI agent sessions":
  test "bounds agent output at UTF-8 and line boundaries":
    let bounded = appendBoundedAgentOutput("old\n", "日本語\nnew", 8)
    check bounded.truncated
    check bounded.output.len > 0
    check not bounded.output.startsWith("\x80")

  test "runs a session in its worktree, exchanges a prompt, and tracks changes":
    let root = getTempDir() / "nimculus-agent-test-root"
    createDir(root)
    discard execShellCmd("git init -q " & quoteShell(root))
    writeFile(root / "main.txt", "before\n")
    discard execShellCmd("git -C " & quoteShell(root) & " add main.txt")
    discard execShellCmd("git -C " & quoteShell(root) & " -c user.name=test -c user.email=test@example.com commit -qm init")
    let session = newAgentSession(1, "/bin/sh", @[
      "-c", "read line; printf 'agent:%s\\n' \"$line\"; printf changed > main.txt"], root)
    session.sendPrompt("hello")
    var result: AgentPollResult
    for _ in 0 .. 40:
      result = session.poll()
      if result.done: break
      sleep(10)
    check result.done
    check session.retainedOutput.contains("agent:hello")
    check "main.txt" in session.refreshChanges()
    session.stop()
    removeDir(root)

  test "manager supports concurrent sessions and direct-child cleanup":
    let root = getTempDir() / "nimculus-agent-manager-root"
    createDir(root)
    let manager = newAgentManager()
    let first = manager.start("/bin/sh", ["-c", "sleep 10"], root)
    let second = manager.start("/bin/sh", ["-c", "sleep 10"], root)
    check first.id != second.id
    check manager.active.id == second.id
    check manager.activate(first.id)
    check manager.active.id == first.id
    check manager.stop(second.id)
    manager.stopAll()
    check manager.active == nil
    removeDir(root)

