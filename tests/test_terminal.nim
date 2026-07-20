import std/unittest
import std/os
import std/strutils
import nimculus/terminal

suite "M10 terminal core":
  test "parses ANSI cursor movement and scrollback":
    var screen = initTerminalScreen(6, 2, 4)
    screen.feed("one\r\ntwo\r\nthree")
    check screen.scrollback.len == 1
    check screen.lineText(0) == "two"
    check screen.lineText(1) == "three"
    screen.feed("\x1b[1;1HX")
    check screen.lineText(0) == "Xwo"
    screen.feed("\x1b[2K")
    check screen.lineText(0) == ""

  test "keeps UTF-8 glyphs in screen cells":
    var screen = initTerminalScreen(8, 1)
    screen.feed("日本語")
    check screen.lineText(0) == "日本語"
    check screen.cursorColumn == 3

  test "resize preserves visible content and clamps cursor":
    var screen = initTerminalScreen(8, 2)
    screen.feed("hello\r\nworld")
    screen.resize(4, 3)
    check screen.lineText(0) == "hell"
    check screen.lineText(1) == "worl"
    check screen.rows == 3
    check screen.columns == 4

  test "copies a normalized selection across visible lines and scrollback":
    var screen = initTerminalScreen(8, 2, 8)
    screen.feed("first\r\nsecond\r\nthird")
    let selection = TerminalSelection(
      anchor: TerminalPoint(row: 0, column: 2),
      active: TerminalPoint(row: 2, column: 3))
    check screen.selectedText(selection) == "rst\nsecond\nthi"
    let reversed = TerminalSelection(
      anchor: TerminalPoint(row: 2, column: 3),
      active: TerminalPoint(row: 0, column: 2))
    check screen.selectedText(reversed) == "rst\nsecond\nthi"

  test "preserves the normal screen around DEC alternate screen":
    var screen = initTerminalScreen(8, 2)
    screen.feed("main")
    screen.feed("\x1b[?1049halt")
    check screen.alternateScreen
    check screen.lineText(0) == "alt"
    screen.feed("\x1b[?1049l")
    check not screen.alternateScreen
    check screen.lineText(0) == "main"

  test "tracks DEC cursor visibility mode":
    var screen = initTerminalScreen(8, 2)
    screen.feed("\x1b[?25l")
    check not screen.cursorVisible
    screen.feed("\x1b[?25h")
    check screen.cursorVisible

  test "consumes OSC metadata without painting its payload":
    var screen = initTerminalScreen(16, 1)
    screen.feed("\x1b]0;Nimculus title\x07ok")
    check screen.lineText(0) == "ok"

  when defined(macosx):
    test "macOS PTY executes a shell and feeds the screen":
      let pty = newTerminalPty("/bin/sh", "/tmp", 40, 8)
      defer: pty.close()
      check pty.writeInput("printf 'nimculus-pty\\n'\n") > 0
      var received = ""
      for _ in 0 ..< 100:
        received.add(pty.pollOutput())
        if "nimculus-pty" in received: break
        sleep(10)
      check "nimculus-pty" in received
      check pty.screen.lineText(0).len > 0
      pty.resize(60, 12)
      check pty.screen.columns == 60
      check pty.screen.rows == 12
