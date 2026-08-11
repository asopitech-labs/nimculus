when defined(windows):
  import std/unittest
  import std/os
  import std/strutils
  import nimculus/terminal
  import wait_support

  suite "Windows ConPTY integration":
    test "creates, exchanges UTF-8 output, resizes, and closes":
      let pty = newTerminalPty("cmd.exe", getCurrentDir(), 80, 24)
      defer: pty.close()
      check pty != nil
      var output = ""
      let startupWait = waitForTest("ConPTY startup", condition = proc(): bool =
        output.add(pty.pollOutput())
        # cmd.exe emits the initial prompt through the ConPTY host, while the
        # prompt text itself is not guaranteed to be present in this pipe.
        # Cursor-visible is the startup-ready sequence we can observe here.
        "\e[?25h" in output)
      check checkTestWait(startupWait)
      check "\e[?25h" in output
      sleep(250)
      check pty.writeInput("echo NIMCULUS_CONPTY\r") > 0
      let outputWait = waitForTest("ConPTY command output", condition = proc(): bool =
        output.add(pty.pollOutput())
        "NIMCULUS_CONPTY" in output)
      check checkTestWait(outputWait)
      check "NIMCULUS_CONPTY" in output
      check "NIMCULUS_CONPTY" in pty.screen.gridText()
      pty.resize(100, 30)
      check pty.screen.columns == 100
      check pty.screen.rows == 30
else:
  echo "[SKIP] Windows ConPTY integration test requires Windows"
