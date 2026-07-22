when defined(windows):
  import std/unittest
  import std/os
  import std/strutils
  import nimculus/terminal

  suite "Windows ConPTY integration":
    test "creates, exchanges UTF-8 output, resizes, and closes":
      let pty = newTerminalPty("cmd.exe", getCurrentDir(), 80, 24)
      defer: pty.close()
      check pty != nil
      var output = ""
      for _ in 0 ..< 100:
        output.add(pty.pollOutput())
        # cmd.exe emits the initial prompt through the ConPTY host, while the
        # prompt text itself is not guaranteed to be present in this pipe.
        # Cursor-visible is the startup-ready sequence we can observe here.
        if "\e[?25h" in output: break
        sleep(10)
      check "\e[?25h" in output
      sleep(250)
      check pty.writeInput("echo NIMCULUS_CONPTY\r") > 0
      for _ in 0 ..< 500:
        output.add(pty.pollOutput())
        if "NIMCULUS_CONPTY" in output: break
        sleep(10)
      check "NIMCULUS_CONPTY" in output
      check "NIMCULUS_CONPTY" in pty.screen.gridText()
      pty.resize(100, 30)
      check pty.screen.columns == 100
      check pty.screen.rows == 30
else:
  echo "[SKIP] Windows ConPTY integration test requires Windows"
