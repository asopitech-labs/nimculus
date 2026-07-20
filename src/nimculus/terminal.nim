import std/os
import std/strutils
import std/unicode

type
  TerminalCell* = object
    text*: string

  TerminalPoint* = object
    row*, column*: int

  TerminalSelection* = object
    anchor*, active*: TerminalPoint

  TerminalScreen* = object
    columns*, rows*: int
    scrollbackLimit*: int
    lines*: seq[seq[TerminalCell]]
    scrollback*: seq[seq[TerminalCell]]
    cursorRow*, cursorColumn*: int
    cursorVisible*: bool
    alternateScreen*: bool
    savedLines: seq[seq[TerminalCell]]
    savedScrollback: seq[seq[TerminalCell]]
    savedCursorRow*, savedCursorColumn*: int
    parserState*: char
    csiParams*: string

proc blankRow(screen: TerminalScreen): seq[TerminalCell] =
  newSeq(result, max(1, screen.columns))

proc initTerminalScreen*(columns = 80, rows = 24,
                         scrollbackLimit = 10_000): TerminalScreen =
  result.columns = max(1, columns)
  result.rows = max(1, rows)
  result.scrollbackLimit = max(0, scrollbackLimit)
  result.cursorVisible = true
  result.lines = newSeq[seq[TerminalCell]](result.rows)
  for row in 0 ..< result.rows: result.lines[row] = result.blankRow()

proc clearLine(screen: var TerminalScreen, row: int) =
  if row < 0 or row >= screen.lines.len: return
  screen.lines[row] = screen.blankRow()

proc scrollUp(screen: var TerminalScreen) =
  if screen.lines.len == 0: return
  screen.scrollback.add(screen.lines[0])
  if screen.scrollback.len > screen.scrollbackLimit:
    for _ in 0 ..< screen.scrollback.len - screen.scrollbackLimit:
      screen.scrollback.delete(0)
  screen.lines.delete(0)
  screen.lines.add(screen.blankRow())
  screen.cursorRow = max(0, screen.cursorRow - 1)

proc resize*(screen: var TerminalScreen, columns, rows: int) =
  let nextColumns = max(1, columns)
  let nextRows = max(1, rows)
  if nextColumns != screen.columns:
    for row in screen.lines.mitems:
      row.setLen(nextColumns)
      for cell in row.mitems:
        if cell.text.len == 0: cell.text = " "
    for row in screen.scrollback.mitems:
      row.setLen(nextColumns)
  if nextRows > screen.lines.len:
    for _ in screen.lines.len ..< nextRows: screen.lines.add(screen.blankRow())
  elif nextRows < screen.lines.len:
    let removed = screen.lines.len - nextRows
    for _ in 0 ..< removed: screen.scrollback.add(screen.lines[0]); screen.lines.delete(0)
  screen.columns = nextColumns
  screen.rows = nextRows
  screen.cursorRow = min(screen.cursorRow, screen.rows - 1)
  screen.cursorColumn = min(screen.cursorColumn, screen.columns - 1)

proc csiNumbers(screen: TerminalScreen): seq[int] =
  if screen.csiParams.len == 0: return @[1]
  for part in screen.csiParams.split(';'):
    result.add(if part.len == 0: 1 else:
      try: parseInt(part) except ValueError: 1)

proc enterAlternateScreen(screen: var TerminalScreen) =
  if screen.alternateScreen: return
  screen.savedLines = screen.lines
  screen.savedScrollback = screen.scrollback
  screen.savedCursorRow = screen.cursorRow
  screen.savedCursorColumn = screen.cursorColumn
  screen.lines = newSeq[seq[TerminalCell]](screen.rows)
  for row in 0 ..< screen.rows: screen.lines[row] = screen.blankRow()
  screen.scrollback.setLen(0)
  screen.cursorRow = 0
  screen.cursorColumn = 0
  screen.alternateScreen = true

proc leaveAlternateScreen(screen: var TerminalScreen) =
  if not screen.alternateScreen: return
  screen.lines = screen.savedLines
  screen.scrollback = screen.savedScrollback
  screen.cursorRow = min(screen.savedCursorRow, screen.rows - 1)
  screen.cursorColumn = min(screen.savedCursorColumn, screen.columns - 1)
  screen.savedLines.setLen(0)
  screen.savedScrollback.setLen(0)
  screen.alternateScreen = false

proc eraseDisplay(screen: var TerminalScreen, mode: int) =
  case mode
  of 2:
    for row in 0 ..< screen.lines.len: screen.clearLine(row)
    screen.cursorRow = 0
    screen.cursorColumn = 0
  else:
    for row in screen.cursorRow ..< screen.lines.len: screen.clearLine(row)

proc handleCsi*(screen: var TerminalScreen, finalByte: char) =
  let params = screen.csiNumbers()
  if screen.csiParams.startsWith("?") and finalByte in {'h', 'l'}:
    let enabled = finalByte == 'h'
    if screen.csiParams.contains("1049"):
      if enabled: screen.enterAlternateScreen()
      else: screen.leaveAlternateScreen()
    if screen.csiParams.contains("25"):
      screen.cursorVisible = enabled
    screen.csiParams.setLen(0)
    screen.parserState = '\0'
    return
  case finalByte
  of 'A': screen.cursorRow = max(0, screen.cursorRow - params[0])
  of 'B', 'e': screen.cursorRow = min(screen.rows - 1, screen.cursorRow + params[0])
  of 'C', 'a': screen.cursorColumn = min(screen.columns - 1, screen.cursorColumn + params[0])
  of 'D': screen.cursorColumn = max(0, screen.cursorColumn - params[0])
  of 'G': screen.cursorColumn = min(screen.columns - 1, max(0, params[0] - 1))
  of 'H', 'f':
    screen.cursorRow = min(screen.rows - 1, max(0, params[0] - 1))
    screen.cursorColumn = min(screen.columns - 1,
      max(0, (if params.len > 1: params[1] else: 1) - 1))
  of 'J': screen.eraseDisplay(params[0])
  of 'K':
    if params[0] == 2:
      screen.clearLine(screen.cursorRow)
    elif screen.cursorRow >= 0 and screen.cursorRow < screen.rows:
      for column in screen.cursorColumn ..< screen.columns:
        screen.lines[screen.cursorRow][column].text = " "
  of 's':
    screen.savedCursorRow = screen.cursorRow
    screen.savedCursorColumn = screen.cursorColumn
  of 'u':
    screen.cursorRow = min(screen.rows - 1, max(0, screen.savedCursorRow))
    screen.cursorColumn = min(screen.columns - 1, max(0, screen.savedCursorColumn))
  else: discard # SGR and unsupported private modes are harmless here.
  screen.csiParams.setLen(0)
  screen.parserState = '\0'

proc putGlyph(screen: var TerminalScreen, glyph: string) =
  if screen.cursorRow >= screen.rows: screen.scrollUp()
  if screen.cursorColumn >= screen.columns:
    screen.cursorColumn = 0
    inc screen.cursorRow
    if screen.cursorRow >= screen.rows: screen.scrollUp()
  screen.lines[screen.cursorRow][screen.cursorColumn].text = glyph
  inc screen.cursorColumn

proc feed*(screen: var TerminalScreen, data: string) =
  var index = 0
  while index < data.len:
    let byte = data[index]
    case screen.parserState
    of '\0':
      case byte
      of '\x1B': screen.parserState = 'e'
      of '\r': screen.cursorColumn = 0
      of '\n':
        inc screen.cursorRow
        if screen.cursorRow >= screen.rows: screen.scrollUp()
      of '\b': screen.cursorColumn = max(0, screen.cursorColumn - 1)
      of '\t': screen.cursorColumn = min(screen.columns - 1,
        ((screen.cursorColumn div 8) + 1) * 8)
      of '\x07': discard
      else:
        let length = max(1, runeLenAt(data, index))
        screen.putGlyph(data.substr(index, min(data.high, index + length - 1)))
        index += length - 1
    of 'e':
      if byte == '[':
        screen.parserState = 'c'
        screen.csiParams.setLen(0)
      elif byte == ']':
        # OSC titles and hyperlinks are metadata; do not leak their payload
        # into the terminal cell stream.
        screen.parserState = 'o'
      elif byte == '7':
        screen.savedCursorRow = screen.cursorRow
        screen.savedCursorColumn = screen.cursorColumn
        screen.parserState = '\0'
      elif byte == '8':
        screen.cursorRow = min(screen.rows - 1, max(0, screen.savedCursorRow))
        screen.cursorColumn = min(screen.columns - 1, max(0, screen.savedCursorColumn))
        screen.parserState = '\0'
      else:
        screen.parserState = '\0'
    of 'c':
      if byte in {'0'..'9', ';', '?', '>', ':'}:
        screen.csiParams.add(byte)
      elif byte >= '@' and byte <= '~':
        screen.handleCsi(byte)
      else:
        screen.parserState = '\0'
    of 'o':
      if byte == '\x07': screen.parserState = '\0'
      elif byte == '\x1B': screen.parserState = 'O'
    of 'O':
      if byte == '\\': screen.parserState = '\0'
      elif byte != '\x1B': screen.parserState = 'o'
    else: screen.parserState = '\0'
    inc index

proc lineText*(screen: TerminalScreen, row: int): string =
  if row < 0 or row >= screen.lines.len: return
  for cell in screen.lines[row]: result.add(if cell.text.len == 0: " " else: cell.text)
  if result.strip.len == 0: result = ""
  else: result = result.strip(leading = false, trailing = true)

proc visibleText*(screen: TerminalScreen): seq[string] =
  for row in 0 ..< screen.lines.len: result.add(screen.lineText(row))

proc lineCount*(screen: TerminalScreen): int =
  screen.scrollback.len + screen.lines.len

proc lineAt(screen: TerminalScreen, absoluteRow: int): seq[TerminalCell] =
  if absoluteRow < 0: return
  if absoluteRow < screen.scrollback.len: return screen.scrollback[absoluteRow]
  let row = absoluteRow - screen.scrollback.len
  if row >= 0 and row < screen.lines.len: result = screen.lines[row]

proc normalizedSelection*(screen: TerminalScreen,
                          selection: TerminalSelection): TerminalSelection =
  result = selection
  result.anchor.row = max(0, min(screen.lineCount() - 1, result.anchor.row))
  result.active.row = max(0, min(screen.lineCount() - 1, result.active.row))
  result.anchor.column = max(0, min(screen.columns, result.anchor.column))
  result.active.column = max(0, min(screen.columns, result.active.column))
  if result.anchor.row > result.active.row or
      (result.anchor.row == result.active.row and
       result.anchor.column > result.active.column):
    swap(result.anchor, result.active)

proc selectedText*(screen: TerminalScreen,
                   selection: TerminalSelection): string =
  ## Convert a cell selection, including scrollback, into clipboard text.
  ## Trailing blank cells are not copied, matching terminal copy behavior.
  if screen.lineCount() == 0: return
  let range = screen.normalizedSelection(selection)
  if range.anchor == range.active: return
  for row in range.anchor.row .. range.active.row:
    let cells = screen.lineAt(row)
    let first = if row == range.anchor.row: range.anchor.column else: 0
    let last = if row == range.active.row: range.active.column else: cells.len
    var line = ""
    for column in first ..< min(last, cells.len):
      line.add(if cells[column].text.len == 0: " " else: cells[column].text)
    result.add(line.strip(leading = false, trailing = true))
    if row < range.active.row: result.add("\n")

when defined(macosx):
  import std/posix
  type
    TerminalWinSize {.bycopy.} = object
      rows, columns, xPixels, yPixels: cushort

  var terminalSetWindowSize {.importc: "TIOCSWINSZ", header: "<sys/ioctl.h>".}: culong
  proc terminalIoctl(fd: cint, request: culong, value: ptr TerminalWinSize): cint
      {.importc: "ioctl", header: "<sys/ioctl.h>", varargs.}

  type
    TerminalPty* = ref object
      masterFd*: cint
      childPid*: Pid
      screen*: TerminalScreen
      closed*: bool

  proc forkpty(amaster: ptr cint, name: cstring, termp, winp: pointer): Pid
      {.importc, header: "<util.h>".}
  proc execl(path, arg0: cstring): cint {.varargs, importc, header: "<unistd.h>".}
  proc chdir(path: cstring): cint {.importc, header: "<unistd.h>".}

  proc newTerminalPty*(shell = "/bin/zsh", workingDirectory = "",
                       columns = 80, rows = 24): TerminalPty =
    new(result)
    result.screen = initTerminalScreen(columns, rows)
    var size = TerminalWinSize(rows: cushort(rows), columns: cushort(columns),
      xPixels: 0, yPixels: 0)
    var master: cint
    let pid = forkpty(addr master, nil, nil, addr size)
    if pid < 0: raiseOSError(osLastError())
    result.masterFd = master
    result.childPid = pid
    if pid == 0:
      if workingDirectory.len > 0: discard chdir(workingDirectory.cstring)
      discard execl(shell.cstring, shell.cstring, "-l".cstring, nil)
      quit(127)
    discard fcntl(result.masterFd, F_SETFL, fcntl(result.masterFd, F_GETFL) or O_NONBLOCK)

  proc writeInput*(pty: TerminalPty, input: string): int =
    if pty == nil or pty.closed or input.len == 0: return 0
    posix.write(pty.masterFd, input.cstring, input.len)

  proc pollOutput*(pty: TerminalPty): string =
    if pty == nil or pty.closed: return
    var buffer = newString(8192)
    let count = posix.read(pty.masterFd, addr buffer[0], buffer.len)
    if count > 0:
      buffer.setLen(count)
      pty.screen.feed(buffer)
      result = buffer

  proc resize*(pty: TerminalPty, columns, rows: int) =
    if pty == nil or pty.closed: return
    var size = TerminalWinSize(rows: cushort(max(1, rows)),
      columns: cushort(max(1, columns)), xPixels: 0, yPixels: 0)
    discard terminalIoctl(pty.masterFd, terminalSetWindowSize, addr size)
    pty.screen.resize(columns, rows)

  proc close*(pty: TerminalPty) =
    if pty == nil or pty.closed: return
    discard kill(pty.childPid, SIGTERM)
    var status: cint
    discard waitpid(pty.childPid, status, 0)
    discard posix.close(pty.masterFd)
    pty.closed = true
