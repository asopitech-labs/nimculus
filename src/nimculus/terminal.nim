import std/os
import std/strutils
import std/unicode

type
  TerminalColorKind* = enum
    terminalDefaultColor, terminalIndexedColor, terminalRgbColor

  TerminalColor* = object
    kind*: TerminalColorKind
    index*: int
    red*, green*, blue*: uint8

  TerminalCell* = object
    text*: string
    foreground*, background*: TerminalColor
    bold*, dim*, italic*, underline*, inverse*, strikethrough*: bool

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
    insertMode*, lineFeedNewLine*: bool
    applicationCursorKeys*, originMode*, bracketedPaste*: bool
    mouseReporting*: bool
    sgrForeground*, sgrBackground*: TerminalColor
    sgrBold*, sgrDim*, sgrItalic*, sgrUnderline*, sgrInverse*, sgrStrikethrough*: bool
    scrollTop*, scrollBottom*: int
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
  result.scrollTop = 0
  result.scrollBottom = result.rows - 1
  result.sgrForeground.kind = terminalDefaultColor
  result.sgrBackground.kind = terminalDefaultColor
  result.lines = newSeq[seq[TerminalCell]](result.rows)
  for row in 0 ..< result.rows: result.lines[row] = result.blankRow()

proc clearLine(screen: var TerminalScreen, row: int) =
  if row < 0 or row >= screen.lines.len: return
  screen.lines[row] = screen.blankRow()

proc scrollRegionUp(screen: var TerminalScreen, amount = 1) =
  let count = max(1, amount)
  for _ in 0 ..< count:
    if screen.scrollTop == 0 and screen.scrollBottom == screen.rows - 1 and
        not screen.alternateScreen:
      screen.scrollback.add(screen.lines[screen.scrollTop])
      if screen.scrollback.len > screen.scrollbackLimit:
        for _ in 0 ..< screen.scrollback.len - screen.scrollbackLimit:
          screen.scrollback.delete(0)
    for row in screen.scrollTop ..< screen.scrollBottom:
      screen.lines[row] = screen.lines[row + 1]
    screen.lines[screen.scrollBottom] = screen.blankRow()

proc scrollRegionDown(screen: var TerminalScreen, amount = 1) =
  let count = max(1, amount)
  for _ in 0 ..< count:
    for row in countdown(screen.scrollBottom, screen.scrollTop + 1):
      screen.lines[row] = screen.lines[row - 1]
    screen.lines[screen.scrollTop] = screen.blankRow()

proc scrollRegionUpAt(screen: var TerminalScreen, row: int) =
  if row < screen.scrollTop or row > screen.scrollBottom: return
  for line in row ..< screen.scrollBottom:
    screen.lines[line] = screen.lines[line + 1]
  screen.lines[screen.scrollBottom] = screen.blankRow()

proc scrollRegionDownAt(screen: var TerminalScreen, row: int) =
  if row < screen.scrollTop or row > screen.scrollBottom: return
  for line in countdown(screen.scrollBottom, row + 1):
    screen.lines[line] = screen.lines[line - 1]
  screen.lines[row] = screen.blankRow()

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
  screen.scrollTop = min(screen.scrollTop, screen.rows - 1)
  screen.scrollBottom = min(max(screen.scrollTop, screen.scrollBottom), screen.rows - 1)
  screen.cursorRow = min(screen.cursorRow, screen.rows - 1)
  screen.cursorColumn = min(screen.cursorColumn, screen.columns - 1)

proc csiNumbers(screen: TerminalScreen): seq[int] =
  if screen.csiParams.len == 0: return @[1]
  for part in screen.csiParams.split(';'):
    result.add(if part.len == 0: 1 else:
      try: parseInt(part) except ValueError: 1)

proc applySgr(screen: var TerminalScreen, raw: string) =
  var values: seq[int]
  for part in raw.split(';'):
    values.add(if part.len == 0: 0 else:
      try: parseInt(part) except ValueError: 0)
  if values.len == 0: values = @[0]
  var index = 0
  while index < values.len:
    let value = values[index]
    case value
    of 0:
      screen.sgrForeground = TerminalColor(kind: terminalDefaultColor)
      screen.sgrBackground = TerminalColor(kind: terminalDefaultColor)
      screen.sgrBold = false; screen.sgrDim = false; screen.sgrItalic = false
      screen.sgrUnderline = false; screen.sgrInverse = false
      screen.sgrStrikethrough = false
    of 1: screen.sgrBold = true
    of 2: screen.sgrDim = true
    of 3: screen.sgrItalic = true
    of 4: screen.sgrUnderline = true
    of 7: screen.sgrInverse = true
    of 9: screen.sgrStrikethrough = true
    of 22: screen.sgrBold = false; screen.sgrDim = false
    of 23: screen.sgrItalic = false
    of 24: screen.sgrUnderline = false
    of 27: screen.sgrInverse = false
    of 29: screen.sgrStrikethrough = false
    of 39: screen.sgrForeground = TerminalColor(kind: terminalDefaultColor)
    of 49: screen.sgrBackground = TerminalColor(kind: terminalDefaultColor)
    of 30 .. 37: screen.sgrForeground = TerminalColor(
      kind: terminalIndexedColor, index: value - 30)
    of 40 .. 47: screen.sgrBackground = TerminalColor(
      kind: terminalIndexedColor, index: value - 40)
    of 90 .. 97: screen.sgrForeground = TerminalColor(
      kind: terminalIndexedColor, index: value - 90 + 8)
    of 100 .. 107: screen.sgrBackground = TerminalColor(
      kind: terminalIndexedColor, index: value - 100 + 8)
    of 38, 48:
      let targetForeground = value == 38
      if index + 1 < values.len and values[index + 1] == 5 and index + 2 < values.len:
        let color = TerminalColor(kind: terminalIndexedColor, index: values[index + 2])
        if targetForeground: screen.sgrForeground = color else: screen.sgrBackground = color
        index += 2
      elif index + 1 < values.len and values[index + 1] == 2 and index + 4 < values.len:
        let color = TerminalColor(kind: terminalRgbColor,
          red: uint8(max(0, min(255, values[index + 2]))),
          green: uint8(max(0, min(255, values[index + 3]))),
          blue: uint8(max(0, min(255, values[index + 4]))))
        if targetForeground: screen.sgrForeground = color else: screen.sgrBackground = color
        index += 4
    else: discard
    inc index

proc applyCurrentStyle(screen: TerminalScreen, cell: var TerminalCell) =
  cell.foreground = screen.sgrForeground
  cell.background = screen.sgrBackground
  cell.bold = screen.sgrBold
  cell.dim = screen.sgrDim
  cell.italic = screen.sgrItalic
  cell.underline = screen.sgrUnderline
  cell.inverse = screen.sgrInverse
  cell.strikethrough = screen.sgrStrikethrough

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
  let rawParams = screen.csiParams
  let params = screen.csiNumbers()
  if rawParams.startsWith("?") and finalByte in {'h', 'l'}:
    let enabled = finalByte == 'h'
    if rawParams.len > 1:
      for part in rawParams[1 .. ^1].split(';'):
        let mode = try: parseInt(part) except ValueError: -1
        case mode
        of 1049:
          if enabled: screen.enterAlternateScreen()
          else: screen.leaveAlternateScreen()
        of 25: screen.cursorVisible = enabled
        of 1: screen.applicationCursorKeys = enabled
        of 6: screen.originMode = enabled
        of 2004: screen.bracketedPaste = enabled
        of 1000, 1002, 1003: screen.mouseReporting = enabled
        else: discard
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
  of 'd': screen.cursorRow = min(screen.rows - 1, max(0, params[0] - 1))
  of 'E':
    screen.cursorRow = min(screen.rows - 1, screen.cursorRow + params[0])
    screen.cursorColumn = 0
  of 'F':
    screen.cursorRow = max(0, screen.cursorRow - params[0])
    screen.cursorColumn = 0
  of 'I':
    screen.cursorColumn = min(screen.columns - 1,
      ((screen.cursorColumn div 8) + params[0]) * 8)
  of 'Z':
    screen.cursorColumn = max(0, screen.cursorColumn - params[0] * 8)
  of 'J': screen.eraseDisplay(params[0])
  of 'K':
    if params[0] == 2:
      screen.clearLine(screen.cursorRow)
    elif screen.cursorRow >= 0 and screen.cursorRow < screen.rows:
      for column in screen.cursorColumn ..< screen.columns:
        screen.lines[screen.cursorRow][column].text = " "
  of 'm': screen.applySgr(rawParams)
  of 'r':
    screen.scrollTop = max(0, min(screen.rows - 1, (if params.len > 0: params[0] else: 1) - 1))
    screen.scrollBottom = max(screen.scrollTop, min(screen.rows - 1,
      (if params.len > 1: params[1] else: screen.rows) - 1))
    screen.cursorRow = if screen.originMode: screen.scrollTop else: 0
    screen.cursorColumn = 0
  of 'S': screen.scrollRegionUp(params[0])
  of 'T': screen.scrollRegionDown(params[0])
  of 'L':
    let count = min(params[0], screen.scrollBottom - screen.cursorRow + 1)
    if screen.cursorRow >= screen.scrollTop and screen.cursorRow <= screen.scrollBottom:
      for _ in 0 ..< count: screen.scrollRegionDownAt(screen.cursorRow)
  of 'M':
    let count = min(params[0], screen.scrollBottom - screen.cursorRow + 1)
    if screen.cursorRow >= screen.scrollTop and screen.cursorRow <= screen.scrollBottom:
      for _ in 0 ..< count: screen.scrollRegionUpAt(screen.cursorRow)
  of '@':
    let count = min(params[0], screen.columns - screen.cursorColumn)
    if count > 0:
      for column in countdown(screen.columns - 1, screen.cursorColumn + count):
        screen.lines[screen.cursorRow][column] = screen.lines[screen.cursorRow][column - count]
      for column in screen.cursorColumn ..< screen.cursorColumn + count:
        screen.lines[screen.cursorRow][column] = TerminalCell(text: " ")
  of 'P':
    let count = min(params[0], screen.columns - screen.cursorColumn)
    if count > 0:
      for column in screen.cursorColumn ..< screen.columns - count:
        screen.lines[screen.cursorRow][column] = screen.lines[screen.cursorRow][column + count]
      for column in screen.columns - count ..< screen.columns:
        screen.lines[screen.cursorRow][column] = TerminalCell(text: " ")
  of 'X':
    let count = min(params[0], screen.columns - screen.cursorColumn)
    for column in screen.cursorColumn ..< screen.cursorColumn + count:
      screen.lines[screen.cursorRow][column] = TerminalCell(text: " ")
  of 'h':
    if rawParams == "4": screen.insertMode = true
    if rawParams == "20": screen.lineFeedNewLine = true
  of 'l':
    if rawParams == "4": screen.insertMode = false
    if rawParams == "20": screen.lineFeedNewLine = false
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
  if screen.cursorRow > screen.scrollBottom:
    screen.scrollRegionUp()
    screen.cursorRow = screen.scrollBottom
  if screen.cursorColumn >= screen.columns:
    screen.cursorColumn = 0
    inc screen.cursorRow
    if screen.cursorRow > screen.scrollBottom:
      screen.scrollRegionUp()
      screen.cursorRow = screen.scrollBottom
  if screen.insertMode:
    for column in countdown(screen.columns - 1, screen.cursorColumn + 1):
      screen.lines[screen.cursorRow][column] = screen.lines[screen.cursorRow][column - 1]
  screen.lines[screen.cursorRow][screen.cursorColumn].text = glyph
  screen.applyCurrentStyle(screen.lines[screen.cursorRow][screen.cursorColumn])
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
        if screen.lineFeedNewLine: screen.cursorColumn = 0
        inc screen.cursorRow
        if screen.cursorRow > screen.scrollBottom:
          screen.scrollRegionUp()
          screen.cursorRow = screen.scrollBottom
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
