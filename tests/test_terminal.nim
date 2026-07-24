import std/unittest
import std/os
import std/strutils
import std/times
import nimculus/terminal

when defined(macosx):
  import std/posix

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

  test "compacts scrollback in batches while retaining the newest rows":
    var screen = initTerminalScreen(8, 1, 4)
    screen.feed("1\r\n2\r\n3\r\n4\r\n5\r\n6")
    check screen.scrollback.len <= 4
    check screen.scrollback.len == 3
    check screen.cellText(screen.scrollback[0][0]) == "3"

  test "keeps UTF-8 glyphs in screen cells":
    var screen = initTerminalScreen(8, 1)
    screen.feed("日本語")
    check screen.lineText(0) == "日本語"
    check screen.cursorColumn == 6
    check screen.lines[0][0].width == 2
    check screen.lines[0][1].width == 0

  test "keeps wide glyphs as leading and continuation cells":
    var screen = initTerminalScreen(6, 1)
    screen.feed("A界B")
    check screen.lineText(0) == "A界B"
    check screen.lines[0][1].width == 2
    check screen.lines[0][2].width == 0
    check screen.cursorColumn == 4
    let selection = TerminalSelection(anchor: TerminalPoint(row: 0, column: 1),
      active: TerminalPoint(row: 0, column: 3))
    check screen.selectedText(selection) == "界"

  test "clears a wide glyph continuation when overwriting its leading cell":
    var screen = initTerminalScreen(4, 1)
    screen.feed("界\rA")
    check screen.lineText(0) == "A"
    check screen.lines[0][1].width == 1

  test "keeps terminal cells compact while preserving shared style data":
    check sizeof(TerminalCell) <= 32
    var screen = initTerminalScreen(4, 1)
    screen.feed("\x1b[31mAA")
    check screen.cellStyle(screen.lines[0][0]) == screen.cellStyle(screen.lines[0][1])

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

  test "tracks application cursor and bracketed paste modes":
    var screen = initTerminalScreen(8, 2)
    screen.feed("\x1b[?1h\x1b[?2004h")
    check screen.applicationCursorKeys
    check screen.bracketedPaste
    screen.feed("\x1b[?1l\x1b[?2004l")
    check not screen.applicationCursorKeys
    check not screen.bracketedPaste

  test "supports kitty keyboard enhancement push pop and query":
    var screen = initTerminalScreen(8, 2)
    screen.feed("\x1b[>15u\x1b[?u")
    check screen.kittyKeyboardFlags == 15
    check screen.takeResponses() == @["\x1b[?15u"]
    screen.feed("\x1b[<u")
    check screen.kittyKeyboardFlags == 0
    screen.feed("\x1b[>1u\x1b[>2u\x1b[<2u")
    check screen.kittyKeyboardFlags == 0
    check screen.kittyKeyboardStack.len == 0

  test "consumes OSC metadata without painting its payload":
    var screen = initTerminalScreen(16, 1)
    screen.feed("\x1b]0;Nimculus title\x07ok")
    check screen.lineText(0) == "ok"

  test "tracks OSC 8 hyperlinks on cells and closes them":
    var screen = initTerminalScreen(16, 1)
    screen.feed("\x1b]8;;https://example.com\x07link\x1b]8;;\x07 plain")
    check screen.cellHyperlinkUri(screen.lines[0][0]) == "https://example.com"
    check screen.cellHyperlinkUri(screen.lines[0][3]) == "https://example.com"
    check screen.cellHyperlinkUri(screen.lines[0][5]).len == 0

  test "bounds OSC metadata and reclaims discarded hyperlink values":
    var screen = initTerminalScreen(8, 1, 2)
    for index in 0 ..< 64:
      screen.feed("\x1b]8;;https://example.com/" & $index & "\x07x\r\n")
    let stats = screen.storageStats()
    check stats.hyperlinkCount <= screen.scrollbackLimit + screen.rows + 1
    check stats.hyperlinkBytes < 256

    var oversized = initTerminalScreen(8, 1)
    oversized.feed("\x1b]8;;https://example.com\x07a")
    oversized.feed("\x1b]8;;" & repeat("x", MaxTerminalOscBytes + 1) & "\x07b")
    check oversized.cellHyperlinkUri(oversized.lines[0][0]) == "https://example.com"
    check oversized.cellHyperlinkUri(oversized.lines[0][1]).len == 0
    check oversized.storageStats().hyperlinkCount == 1

  test "rebuilds intern indexes after discarding unique styles and links":
    var screen = initTerminalScreen(8, 1, 2)
    for index in 0 ..< 512:
      let red = index mod 256
      let green = index div 256
      screen.feed("\x1b[38;2;" & $red & ";" & $green & ";127m")
      screen.feed("\x1b]8;;https://example.com/" & $index & "\x07x\r\n")
    let stats = screen.storageStats()
    check stats.styleCount <= screen.scrollbackLimit + screen.rows + 1
    check stats.hyperlinkCount <= screen.scrollbackLimit + screen.rows + 1
    # The active attributes must still resolve through indexes rebuilt by the
    # scrollback compaction, rather than duplicating their retained values.
    screen.feed("z")
    let cell = screen.lines[0][0]
    check screen.cellHyperlinkUri(cell) == "https://example.com/511"
    check screen.cellStyle(cell).foreground.red == 255'u8
    check screen.cellStyle(cell).foreground.green == 1'u8

  test "retains metadata referenced by a saved alternate screen":
    var screen = initTerminalScreen(8, 1, 2)
    screen.feed("\x1b]8;;https://example.com/main\x07m")
    screen.feed("\x1b[?1049h")
    for index in 0 ..< 8:
      screen.feed("\x1b]8;;https://example.com/alt/" & $index & "\x07x\r\n")
    screen.feed("\x1b[?1049l")
    check screen.cellHyperlinkUri(screen.lines[0][0]) == "https://example.com/main"

  test "retains SGR attributes on cells and resets them":
    var screen = initTerminalScreen(8, 1)
    screen.feed("\x1b[1;31;48;2;1;2;3mA\x1b[0mB")
    check screen.cellText(screen.lines[0][0]) == "A"
    check screen.cellStyle(screen.lines[0][0]).bold
    check screen.cellStyle(screen.lines[0][0]).foreground.kind == terminalIndexedColor
    check screen.cellStyle(screen.lines[0][0]).foreground.index == 1
    check screen.cellStyle(screen.lines[0][0]).background.kind == terminalRgbColor
    check screen.cellStyle(screen.lines[0][0]).background.red == 1'u8
    check not screen.cellStyle(screen.lines[0][1]).bold
    check screen.cellStyle(screen.lines[0][1]).foreground.kind == terminalDefaultColor

  test "supports scroll regions and insert/delete character CSI":
    var screen = initTerminalScreen(6, 4)
    screen.feed("one\r\ntwo\r\nthree\r\nfour")
    screen.feed("\x1b[2;3r\x1b[2;1H\x1b[1LXX")
    check screen.lineText(1).startsWith("XX")
    screen.feed("\x1b[2;1H\x1b[1M")
    check screen.lineText(1).startsWith("two")
    var chars = initTerminalScreen(6, 1)
    chars.feed("abcd\x1b[1;1H\x1b[2@XY")
    check chars.lineText(0) == "XYabcd"
    chars.feed("\x1b[1;1H\x1b[1P")
    check chars.lineText(0) == "Yabcd"

  test "encodes DEC mouse reports":
    var screen = initTerminalScreen(20, 10)
    screen.feed("\x1b[?1000h\x1b[?1006h")
    check screen.mouseReporting
    check screen.mouseReport(terminalMousePress, 0, 2, 3) == "\x1b[<0;3;4M"
    check screen.mouseReport(terminalMouseRelease, 0, 2, 3) == "\x1b[<3;3;4m"
    screen.feed("\x1b[?1002h")
    check screen.mouseReport(terminalMouseMove, 0, 2, 3) == "\x1b[<32;3;4M"
    check screen.mouseReport(terminalMouseScroll, 0, 2, 3, -1) == "\x1b[<65;3;4M"
    screen.feed("\x1b[?1006l\x1b[?1005h")
    check screen.mouseReport(terminalMousePress, 0, 300, 4).len > 3
    screen.feed("\x1b[?1000l\x1b[?1002l")
    check not screen.mouseReporting

  when defined(macosx):
    test "macOS PTY rejects missing shell and working directory before fork":
      expect IOError:
        discard newTerminalPty("nimculus-missing-shell", "/tmp", 40, 8)
      expect IOError:
        discard newTerminalPty("/bin/sh", "/tmp/nimculus-missing-directory", 40, 8)

    test "multiple PTYs keep independent screen state":
      let first = newTerminalPty("/bin/sh", "/tmp", 32, 4)
      let second = newTerminalPty("/bin/sh", "/tmp", 32, 4)
      defer:
        first.close()
        second.close()
      check first.writeInput("printf 'first-session\\n'\n") > 0
      check second.writeInput("printf 'second-session\\n'\n") > 0
      var firstOutput = ""
      var secondOutput = ""
      for _ in 0 ..< 100:
        firstOutput.add(first.pollOutput())
        secondOutput.add(second.pollOutput())
        if "first-session" in firstOutput and "second-session" in secondOutput: break
        sleep(10)
      check "first-session" in firstOutput
      check "second-session" in secondOutput
      check first.screen.visibleText() != second.screen.visibleText()

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

    test "macOS PTY close terminates its command process group":
      let pty = newTerminalPty("/bin/sh", "/tmp", 40, 8)
      let childPid = pty.childPid
      check pty.writeInput("sleep 30 & wait\n") > 0
      var accepted = false
      for _ in 0 ..< 20:
        if "sleep 30" in pty.pollOutput():
          accepted = true
          break
        sleep(10)
      check accepted
      pty.close()
      # The shell and its child command share the PTY-owned group. A
      # successful signal probe here would mean a command escaped cleanup.
      check kill(-childPid, 0) == -1
      check errno == ESRCH

    test "macOS PTY close remains bounded when its shell ignores SIGTERM":
      let pty = newTerminalPty("/bin/sh", "/tmp", 40, 8)
      let childPid = pty.childPid
      check pty.writeInput("trap '' TERM; sleep 30 & wait\n") > 0
      var accepted = false
      for _ in 0 ..< 20:
        if "sleep 30" in pty.pollOutput():
          accepted = true
          break
        sleep(10)
      check accepted
      let started = epochTime()
      pty.close()
      check epochTime() - started < 3.0
      check kill(-childPid, 0) == -1
      check errno == ESRCH

    test "macOS PTY releases itself after its shell exits":
      let pty = newTerminalPty("/bin/sh", "/tmp", 40, 8)
      let childPid = pty.childPid
      # `exec` makes the shell's terminal process end after a finite write.
      # Octal escapes keep the command echo distinct from the expected output.
      check pty.writeInput(
        "exec /usr/bin/printf '\\164\\145\\162\\155\\151\\156\\141\\154\\055\\145\\170\\151\\164\\145\\144\\012'\n"
      ) > 0
      var output = ""
      for _ in 0 ..< 100:
        output.add(pty.pollOutput())
        if pty.closed: break
        sleep(10)
      check "terminal-exited" in output
      check pty.closed
      check pty.pendingInputBytes == 0
      check pty.writeInput("ignored") == 0
      check kill(-childPid, 0) == -1
      check errno == ESRCH

    test "macOS PTY queues a large paste after a partial non-blocking write":
      # `cat` reads complete lines and echoes them to the slave. Without a
      # matching poll, its output blocks and the master must retain the input
      # tail instead of relying on a short write to mean success.
      let pty = newTerminalPty("/bin/cat", "/tmp", 40, 8)
      defer: pty.close()
      let paste = repeat("日本\n", 512 * 1024)
      check pty.writeInput(paste) == paste.len
      # A PTY may accept a prefix immediately, but any remainder must be
      # retained instead of being silently lost.
      check pty.pendingInputBytes > 0
