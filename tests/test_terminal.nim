import std/unittest
import std/os
import std/strutils
import nimculus/terminal
import wait_support

when defined(macosx):
  import std/posix

proc checkGridInvariant(screen: TerminalScreen) =
  check screen.columns >= 1
  check screen.rows >= 1
  check screen.lines.len == screen.rows
  check screen.cursorRow >= 0 and screen.cursorRow < screen.rows
  # A terminal keeps the cursor one cell beyond the right margin until the
  # next printable glyph triggers wrap-pending handling.
  check screen.cursorColumn >= 0 and screen.cursorColumn <= screen.columns
  check screen.scrollTop >= 0 and screen.scrollTop < screen.rows
  check screen.scrollBottom >= screen.scrollTop and screen.scrollBottom < screen.rows
  for row in screen.lines:
    check row.len == screen.columns
    for column, cell in row:
      check cell.width in {0, 1, 2}
      if cell.width == 0:
        check column > 0
        check row[column - 1].width == 2
      elif cell.width == 2:
        check column + 1 < row.len
        check row[column + 1].width == 0
  for row in screen.scrollback:
    check row.len == screen.columns

suite "M10 terminal core":
  test "routes macOS editing commands to the terminal without editor fallback":
    var screen = initTerminalScreen()
    check terminalCommandInput(screen, "moveLeft") == (true, "\x1b[D")
    check terminalCommandInput(screen, "moveWordLeft") == (true, "\x1bb")
    check terminalCommandInput(screen, "moveWordRight") == (true, "\x1bf")
    check terminalCommandInput(screen, "deleteWordBackward") == (true, "\x1b\x7f")
    check terminalCommandInput(screen, "deleteWordForward") == (true, "\x1bd")
    check terminalCommandInput(screen, "deleteToBeginningOfLine") == (true, "\x15")
    check terminalCommandInput(screen, "deleteToEndOfLine") == (true, "\x0b")
    check terminalCommandInput(screen, "selectToEndOfDocument") == (true, "")
    check terminalCommandInput(screen, "unknown") == (false, "")
    screen.applicationCursorKeys = true
    check terminalCommandInput(screen, "moveLeft") == (true, "\x1bOD")
    check terminalOwnsInput(true, true)
    check not terminalOwnsInput(true, false)
    check not terminalOwnsInput(false, true)

  test "derives the PTY grid from viewport font metrics and text insets":
    check terminalGridSize(100'f32, 60'f32, 10'f32, 15'f32, 5'f32, 3'f32) == (9, 3)
    check terminalGridSize(4'f32, 4'f32, 0'f32, 0'f32, 8'f32, 8'f32) == (1, 1)

  test "navigates a bounded scrollback viewport without changing the PTY grid":
    check terminalViewportStart(40, 8, 0) == 32
    check terminalViewportStart(40, 8, 7) == 25
    check terminalScrollOffset(0, 40, 8, 5) == 5
    check terminalScrollOffset(5, 40, 8, 100) == 32
    check terminalScrollOffset(5, 40, 8, -100) == 0

  test "matches Zed line-wheel and pixel-trackpad terminal scrolling":
    var trackpadRemainder = 0'f32
    check terminalScrollLineDelta(trackpadRemainder, 9'f32, true, 18'f32) == 0
    check terminalScrollLineDelta(trackpadRemainder, 9'f32, true, 18'f32) == -1
    check trackpadRemainder == 0'f32

    var wheelRemainder = 0'f32
    # A conventional wheel already reports logical lines and must not be
    # divided by the terminal font height.
    check terminalScrollLineDelta(wheelRemainder, -3'f32, false, 18'f32) == 3
    check wheelRemainder == 0'f32
    check terminalScrollLineDelta(wheelRemainder, -1'f32, false, 18'f32, 4'f32) == 4
    check wheelRemainder == 0'f32

  test "scrollback serial advances even when history compaction changes its length":
    var screen = initTerminalScreen(8, 2, 2)
    screen.feed("one\ntwo\nthree\nfour\nfive\nsix\n")
    let serialBefore = screen.scrollbackSerial
    let linesBefore = screen.lineCount()
    screen.feed("seven\n")
    check screen.scrollbackSerial > serialBefore
    check screen.lineCount() <= linesBefore
    check terminalScrollOffset(1, screen.lineCount(), screen.rows,
      int(screen.scrollbackSerial - serialBefore)) >= 1

  test "scrollback discard rebases surviving terminal selection rows":
    let selection = TerminalSelection(anchor: TerminalPoint(row: 1, column: 3),
      active: TerminalPoint(row: 4, column: 2))
    let rebased = terminalSelectionAfterScrollbackDiscard(selection, 2, 6, 8)
    check rebased.anchor == TerminalPoint(row: 0, column: 0)
    check rebased.active == TerminalPoint(row: 2, column: 2)
    let evicted = terminalSelectionAfterScrollbackDiscard(selection, 5, 4, 8)
    check evicted.anchor == TerminalPoint()
    check evicted.active == TerminalPoint()

  test "scrollback compaction records discarded history rows":
    var screen = initTerminalScreen(8, 2, 2)
    screen.feed("one\ntwo\nthree\nfour\nfive\nsix\n")
    check screen.scrollbackDiscardedSerial > 0

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

  test "CSI line edits preserve wide glyph cell pairs":
    # Zed/Alacritty presentation treats a wide glyph's second cell solely as a
    # spacer. Addressing that spacer with CSI must not leave a dangling lead
    # or continuation in Nimculus's compact grid.
    var erase = initTerminalScreen(6, 1)
    erase.feed("A界B\x1b[1;3H\x1b[1X")
    checkGridInvariant(erase)
    check erase.lines[0][1].width == 1
    check erase.lines[0][2].width == 1

    var insert = initTerminalScreen(6, 1)
    insert.feed("A界B\x1b[1;3H\x1b[1@")
    checkGridInvariant(insert)

    var delete = initTerminalScreen(6, 1)
    delete.feed("A界B\x1b[1;3H\x1b[1P")
    checkGridInvariant(delete)

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

  test "resize normalizes truncated wide cells and saved alternate grids":
    var screen = initTerminalScreen(4, 1)
    screen.feed("界")
    screen.resize(1, 1)
    check screen.lines[0].len == 1
    check screen.lines[0][0].width == 1
    check screen.lineText(0) == "界"

    var alternate = initTerminalScreen(4, 1)
    alternate.feed("main")
    alternate.feed("\x1b[?1049halt")
    alternate.resize(2, 1)
    alternate.feed("\x1b[?1049l")
    check alternate.lines[0].len == 2
    check alternate.lineText(0) == "ma"

  test "one-column grids accept wide glyphs without a continuation cell":
    var screen = initTerminalScreen(1, 1)
    screen.feed("界")
    check screen.lineText(0) == "界"
    check screen.lines[0][0].width == 1

  test "representative VT traces retain terminal grid invariants":
    var screen = initTerminalScreen(12, 4, 8)
    let trace = [
      "plain 日本語 text", "\r\n", "\x1b[2;5H界", "\x1b[2K",
      "\x1b[2;3r", "\x1b[2;1H\x1b[1L", "\x1b[1M", "\x1b[3S",
      "\x1b[?1049h", "alternate\r\n界", "\x1b[?1049l", "\x1b[?25l",
      "\x1b[?25h", "\x1b]8;;https://example.invalid\x07link\x1b]8;;\x07",
      "\x1b[38;2;10;20;30mcolor\x1b[0m", "\x1b", "[?2004h", "\x1b[?2004l"
    ]
    for index in 0 ..< 256:
      screen.feed(trace[index mod trace.len])
      if index mod 7 == 0:
        let columns = 1 + (index mod 12)
        let rows = 1 + ((index div 7) mod 4)
        screen.resize(columns, rows)
      checkGridInvariant(screen)

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
      let wait = waitForTest("first and second terminal output", condition = proc(): bool =
        firstOutput.add(first.pollOutput())
        secondOutput.add(second.pollOutput())
        "first-session" in firstOutput and "second-session" in secondOutput)
      check checkTestWait(wait)
      check "first-session" in firstOutput
      check "second-session" in secondOutput
      check first.screen.visibleText() != second.screen.visibleText()

    test "macOS PTY executes a shell and feeds the screen":
      let pty = newTerminalPty("/bin/sh", "/tmp", 40, 8)
      defer: pty.close()
      check pty.writeInput("printf 'nimculus-pty\\n'\n") > 0
      var received = ""
      let wait = waitForTest("terminal printf output", condition = proc(): bool =
        received.add(pty.pollOutput())
        "nimculus-pty" in received)
      check checkTestWait(wait)
      check "nimculus-pty" in received
      check pty.screen.lineText(0).len > 0
      pty.resize(60, 12)
      check pty.screen.columns == 60
      check pty.screen.rows == 12

    test "macOS PTY default zsh login shell keeps its requested directory":
      # The macOS default is intentionally zsh, launched as a login shell.
      # Exercise zsh-specific state rather than assuming /bin/sh coverage
      # proves the configured default works.
      let pty = newTerminalPty(workingDirectory = "/tmp", columns = 40, rows = 8)
      defer: pty.close()
      # Terminal Enter is carriage return. zsh's line editor does not treat a
      # bare line feed as the user command-submission key.
      check pty.writeInput("print -r -- nimculus-zsh:$ZSH_VERSION; pwd\r") > 0
      var received = ""
      # Login-shell startup may load the user's normal macOS profile. Keep a
      # bounded readiness window without imposing a fixed delay on success.
      let wait = waitForTest("login shell startup output", condition = proc(): bool =
        received.add(pty.pollOutput())
        "nimculus-zsh:" in received and "/tmp" in received)
      check checkTestWait(wait)
      check "nimculus-zsh:" in received
      check "/tmp" in received

    test "macOS PTY close terminates its direct shell child":
      let pty = newTerminalPty("/bin/sh", "/tmp", 40, 8)
      let childPid = pty.childPid
      check pty.writeInput("exec sleep 30\n") > 0
      var accepted = false
      let wait = waitForTest("terminal long-running command acceptance",
        condition = proc(): bool =
          accepted = "sleep 30" in pty.pollOutput()
          accepted)
      check checkTestWait(wait)
      check accepted
      pty.close()
      check kill(childPid, 0) == -1
      check errno == ESRCH

    test "macOS PTY close remains bounded when its shell ignores SIGTERM":
      let pty = newTerminalPty("/bin/sh", "/tmp", 40, 8)
      let childPid = pty.childPid
      # Keep this bounded-reap case to the direct shell. A background child
      # would require group ownership and would turn a fallback-path test into
      # a potential orphan on shells that reorganize job-control groups.
      check pty.writeInput("trap '' TERM; read ignored\n") > 0
      var accepted = false
      let wait = waitForTest("terminal stdin-blocked command acceptance",
        condition = proc(): bool =
          accepted = "read ignored" in pty.pollOutput()
          accepted)
      check checkTestWait(wait)
      check accepted
      pty.close()
      check kill(childPid, 0) == -1
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
      let wait = waitForTest("terminal process exit", condition = proc(): bool =
        output.add(pty.pollOutput())
        pty.closed)
      check checkTestWait(wait)
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
