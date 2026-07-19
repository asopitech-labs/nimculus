import std/os
import std/strutils
import std/unicode

type
  TerminalCell* = object
    text*: string

  TerminalScreen* = object
    columns*, rows*: int
    scrollbackLimit*: int
    lines*: seq[seq[TerminalCell]]
    scrollback*: seq[seq[TerminalCell]]
    cursorRow*, cursorColumn*: int
    parserState*: char
    csiParams*: string

proc blankRow(screen: TerminalScreen): seq[TerminalCell] =
  newSeq(result, max(1, screen.columns))

proc initTerminalScreen*(columns = 80, rows = 24,
                         scrollbackLimit = 10_000): TerminalScreen =
  result.columns = max(1, columns)
  result.rows = max(1, rows)
  result.scrollbackLimit = max(0, scrollbackLimit)
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
      else:
        screen.parserState = '\0'
    of 'c':
      if byte in {'0'..'9', ';', '?', '>', ':'}:
        screen.csiParams.add(byte)
      elif byte >= '@' and byte <= '~':
        screen.handleCsi(byte)
      else:
        screen.parserState = '\0'
    else: screen.parserState = '\0'
    inc index

proc lineText*(screen: TerminalScreen, row: int): string =
  if row < 0 or row >= screen.lines.len: return
  for cell in screen.lines[row]: result.add(if cell.text.len == 0: " " else: cell.text)
  if result.strip.len == 0: result = ""
  else: result = result.strip(leading = false, trailing = true)

proc visibleText*(screen: TerminalScreen): seq[string] =
  for row in 0 ..< screen.lines.len: result.add(screen.lineText(row))

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
