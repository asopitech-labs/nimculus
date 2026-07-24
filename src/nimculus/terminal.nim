import std/os
import std/strutils
import std/unicode

const
  TerminalReadChunkBytes = 8 * 1024
  ## Keep one Cocoa idle turn bounded while draining substantially more than a
  ## single kernel read. This prevents a chatty build or terminal command from
  ## remaining many frames behind its PTY output.
  MaxTerminalReadBytesPerPoll = 64 * 1024
  ## OSC is terminal metadata, not document content. Keep a malformed or
  ## hostile control sequence from becoming an unbounded transient buffer.
  MaxTerminalOscBytes* = 8 * 1024
  ## OSC 8 URIs survive while a cell is visible or in scrollback. A modest
  ## per-link limit keeps that retained metadata proportional to the grid.
  MaxTerminalHyperlinkUriBytes* = 2 * 1024

type
  TerminalColorKind* = enum
    terminalDefaultColor, terminalIndexedColor, terminalRgbColor

  TerminalColor* = object
    kind*: TerminalColorKind
    index*: int
    red*, green*, blue*: uint8

  TerminalMouseFormat* = enum
    terminalMouseNormal, terminalMouseUtf8, terminalMouseSgr

  TerminalMouseEventKind* = enum
    terminalMousePress, terminalMouseRelease, terminalMouseMove, terminalMouseScroll

  TerminalCell* = object
    ## Keep the hot grid compact like Zed/Alacritty: ordinary glyphs and
    ## style/link references are scalar IDs. Variable UTF-8 data lives once
    ## per distinct combining sequence or hyperlink on TerminalScreen.
    glyph*: uint32
    combiningIndex*: uint32
    hyperlinkIndex*: uint32
    styleIndex*: uint32
    ## 0 is a continuation cell, 1 is a normal cell, and 2 is the leading
    ## cell of a double-width glyph. This follows the cell model used by Zed.
    width*: int

  TerminalStyle* = object
    foreground*, background*: TerminalColor
    bold*, dim*, italic*, underline*, inverse*, strikethrough*: bool

  TerminalStorageStats* = object
    ## Counts exclude the default style and empty link/combining values.
    styleCount*, hyperlinkCount*, combiningCount*: int
    hyperlinkBytes*, combiningBytes*: int

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
    mouseReportClicks*, mouseReportDrag*, mouseReportMotion*: bool
    mouseFormat*: TerminalMouseFormat
    kittyKeyboardFlags*: int
    kittyKeyboardStack*: seq[int]
    pendingResponses*: seq[string]
    sgrForeground*, sgrBackground*: TerminalColor
    sgrBold*, sgrDim*, sgrItalic*, sgrUnderline*, sgrInverse*, sgrStrikethrough*: bool
    scrollTop*, scrollBottom*: int
    savedLines: seq[seq[TerminalCell]]
    savedScrollback: seq[seq[TerminalCell]]
    savedCursorRow*, savedCursorColumn*: int
    savedKittyKeyboardFlags: int
    savedKittyKeyboardStack: seq[int]
    parserState*: char
    csiParams*: string
    oscBuffer*: string
    oscTruncated: bool
    currentHyperlinkUri*: string
    currentHyperlinkIndex: uint32
    styles: seq[TerminalStyle]
    hyperlinks: seq[string]
    combiningGlyphs: seq[string]

proc blankRow(screen: TerminalScreen): seq[TerminalCell] =
  newSeq(result, max(1, screen.columns))
  for cell in result.mitems: cell.width = 1

proc defaultTerminalStyle(): TerminalStyle =
  result.foreground.kind = terminalDefaultColor
  result.background.kind = terminalDefaultColor

proc currentStyle(screen: TerminalScreen): TerminalStyle =
  TerminalStyle(foreground: screen.sgrForeground, background: screen.sgrBackground,
    bold: screen.sgrBold, dim: screen.sgrDim, italic: screen.sgrItalic,
    underline: screen.sgrUnderline, inverse: screen.sgrInverse,
    strikethrough: screen.sgrStrikethrough)

proc internStyle(screen: var TerminalScreen): uint32 =
  let style = screen.currentStyle()
  for index, existing in screen.styles:
    if existing == style: return uint32(index)
  screen.styles.add(style)
  uint32(screen.styles.high)

proc internString(values: var seq[string], value: string): uint32 =
  if value.len == 0: return 0
  for index, existing in values:
    if existing == value: return uint32(index + 1)
  values.add(value)
  uint32(values.len)

proc cellText*(screen: TerminalScreen, cell: TerminalCell): string =
  if cell.glyph == 0: return " "
  result = $Rune(cell.glyph)
  if cell.combiningIndex > 0 and int(cell.combiningIndex) <= screen.combiningGlyphs.len:
    result.add(screen.combiningGlyphs[int(cell.combiningIndex) - 1])

proc cellStyle*(screen: TerminalScreen, cell: TerminalCell): TerminalStyle =
  if int(cell.styleIndex) < screen.styles.len:
    result = screen.styles[int(cell.styleIndex)]

proc cellHyperlinkUri*(screen: TerminalScreen, cell: TerminalCell): string =
  if cell.hyperlinkIndex > 0 and int(cell.hyperlinkIndex) <= screen.hyperlinks.len:
    result = screen.hyperlinks[int(cell.hyperlinkIndex) - 1]

proc initTerminalScreen*(columns = 80, rows = 24,
                         scrollbackLimit = 10_000): TerminalScreen =
  result.columns = max(1, columns)
  result.rows = max(1, rows)
  result.scrollbackLimit = max(0, scrollbackLimit)
  result.cursorVisible = true
  result.scrollTop = 0
  result.scrollBottom = result.rows - 1
  let defaultStyle = defaultTerminalStyle()
  result.sgrForeground = defaultStyle.foreground
  result.sgrBackground = defaultStyle.background
  result.styles.add(defaultStyle)
  result.lines = newSeq[seq[TerminalCell]](result.rows)
  for row in 0 ..< result.rows: result.lines[row] = result.blankRow()

proc clearCell(screen: var TerminalScreen, row, column: int)

proc compactInternedValues(screen: var TerminalScreen) =
  ## Zed delegates the grid's cell lifetime to Alacritty. Mirror that ownership
  ## boundary here: presentation values live only while a visible, scrollback,
  ## or saved-alternate cell still references them.
  let oldStyles = screen.styles
  let oldHyperlinks = screen.hyperlinks
  let oldCombining = screen.combiningGlyphs
  var styleMap = newSeq[uint32](oldStyles.len)
  var hyperlinkMap = newSeq[uint32](oldHyperlinks.len + 1)
  var combiningMap = newSeq[uint32](oldCombining.len + 1)
  var styles = @[if oldStyles.len > 0: oldStyles[0] else: defaultTerminalStyle()]
  var hyperlinks: seq[string]
  var combiningGlyphs: seq[string]

  proc remapCell(cell: var TerminalCell) =
    let style = int(cell.styleIndex)
    if style <= 0 or style >= oldStyles.len:
      cell.styleIndex = 0
    else:
      if styleMap[style] == 0:
        styleMap[style] = uint32(styles.len)
        styles.add(oldStyles[style])
      cell.styleIndex = styleMap[style]

    let hyperlink = int(cell.hyperlinkIndex)
    if hyperlink <= 0 or hyperlink > oldHyperlinks.len:
      cell.hyperlinkIndex = 0
    else:
      if hyperlinkMap[hyperlink] == 0:
        hyperlinkMap[hyperlink] = uint32(hyperlinks.len + 1)
        hyperlinks.add(oldHyperlinks[hyperlink - 1])
      cell.hyperlinkIndex = hyperlinkMap[hyperlink]

    let combining = int(cell.combiningIndex)
    if combining <= 0 or combining > oldCombining.len:
      cell.combiningIndex = 0
    else:
      if combiningMap[combining] == 0:
        combiningMap[combining] = uint32(combiningGlyphs.len + 1)
        combiningGlyphs.add(oldCombining[combining - 1])
      cell.combiningIndex = combiningMap[combining]

  proc remapRows(rows: var seq[seq[TerminalCell]]) =
    for row in rows.mitems:
      for cell in row.mitems: remapCell(cell)

  remapRows(screen.lines)
  remapRows(screen.scrollback)
  remapRows(screen.savedLines)
  remapRows(screen.savedScrollback)

  let activeLink = int(screen.currentHyperlinkIndex)
  if activeLink > 0 and activeLink <= oldHyperlinks.len:
    if hyperlinkMap[activeLink] == 0:
      hyperlinkMap[activeLink] = uint32(hyperlinks.len + 1)
      hyperlinks.add(oldHyperlinks[activeLink - 1])
    screen.currentHyperlinkIndex = hyperlinkMap[activeLink]
  else:
    screen.currentHyperlinkIndex = 0
    screen.currentHyperlinkUri.setLen(0)

  screen.styles = styles
  screen.hyperlinks = hyperlinks
  screen.combiningGlyphs = combiningGlyphs

proc storageStats*(screen: TerminalScreen): TerminalStorageStats =
  result.styleCount = max(0, screen.styles.len - 1)
  result.hyperlinkCount = screen.hyperlinks.len
  result.combiningCount = screen.combiningGlyphs.len
  for uri in screen.hyperlinks: result.hyperlinkBytes += uri.len
  for glyph in screen.combiningGlyphs: result.combiningBytes += glyph.len

proc clearLine(screen: var TerminalScreen, row: int) =
  if row < 0 or row >= screen.lines.len: return
  screen.lines[row] = screen.blankRow()

proc trimScrollback(screen: var TerminalScreen) =
  ## Keep the public seq-backed history compatible while avoiding one
  ## O(n) delete(0) for every line once the limit is reached. Retain a small
  ## reserve below the limit and compact in batches, like a deque-backed
  ## terminal history.
  if screen.scrollbackLimit <= 0:
    let changed = screen.scrollback.len > 0
    screen.scrollback.setLen(0)
    if changed: screen.compactInternedValues()
    return
  if screen.scrollback.len <= screen.scrollbackLimit: return
  let batch = min(256, max(1, screen.scrollbackLimit div 4))
  let keep = max(0, screen.scrollbackLimit - batch)
  if keep == 0:
    screen.scrollback.setLen(0)
  else:
    let first = screen.scrollback.len - keep
    screen.scrollback = screen.scrollback[first .. ^1]
  screen.compactInternedValues()

proc scrollRegionUp(screen: var TerminalScreen, amount = 1) =
  let count = max(1, amount)
  for _ in 0 ..< count:
    if screen.scrollTop == 0 and screen.scrollBottom == screen.rows - 1 and
        not screen.alternateScreen:
      screen.scrollback.add(screen.lines[screen.scrollTop])
      screen.trimScrollback()
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
      let oldLength = row.len
      row.setLen(nextColumns)
      if nextColumns > oldLength:
        for column in oldLength ..< nextColumns:
          row[column].width = 1
    for row in screen.scrollback.mitems:
      let oldLength = row.len
      row.setLen(nextColumns)
      if nextColumns > oldLength:
        for column in oldLength ..< nextColumns:
          row[column].width = 1
  if nextRows > screen.lines.len:
    for _ in screen.lines.len ..< nextRows: screen.lines.add(screen.blankRow())
  elif nextRows < screen.lines.len:
    let removed = screen.lines.len - nextRows
    for _ in 0 ..< removed:
      screen.scrollback.add(screen.lines[0])
      screen.lines.delete(0)
    screen.trimScrollback()
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

proc applyCurrentStyle(screen: var TerminalScreen, cell: var TerminalCell) =
  cell.styleIndex = screen.internStyle()
  cell.hyperlinkIndex = screen.currentHyperlinkIndex

proc finishOsc(screen: var TerminalScreen) =
  ## Parse the OSC 8 hyperlink form: OSC 8 ; params ; URI BEL/ST.
  ## Other OSC metadata remains intentionally non-rendering.
  if screen.oscTruncated:
    # A truncated OSC 8 must not leave the previous hyperlink active for the
    # following text. It is safer to drop an oversized link than to mislabel
    # unrelated terminal output with a stale destination.
    if screen.oscBuffer.startsWith("8;"):
      screen.currentHyperlinkUri.setLen(0)
      screen.currentHyperlinkIndex = 0
  else:
    let parts = screen.oscBuffer.split(';', maxsplit = 2)
    if parts.len >= 3 and parts[0] == "8":
      if parts[2].len <= MaxTerminalHyperlinkUriBytes:
        screen.currentHyperlinkUri = parts[2]
        screen.currentHyperlinkIndex = internString(screen.hyperlinks, parts[2])
      else:
        screen.currentHyperlinkUri.setLen(0)
        screen.currentHyperlinkIndex = 0
  screen.oscBuffer.setLen(0)
  screen.oscTruncated = false
  screen.parserState = '\0'

proc appendOscByte(screen: var TerminalScreen, byte: char) =
  if screen.oscBuffer.len < MaxTerminalOscBytes:
    screen.oscBuffer.add(byte)
  else:
    screen.oscTruncated = true

proc enterAlternateScreen(screen: var TerminalScreen) =
  if screen.alternateScreen: return
  screen.savedLines = screen.lines
  screen.savedScrollback = screen.scrollback
  screen.savedCursorRow = screen.cursorRow
  screen.savedCursorColumn = screen.cursorColumn
  screen.savedKittyKeyboardFlags = screen.kittyKeyboardFlags
  screen.savedKittyKeyboardStack = screen.kittyKeyboardStack
  screen.lines = newSeq[seq[TerminalCell]](screen.rows)
  for row in 0 ..< screen.rows: screen.lines[row] = screen.blankRow()
  screen.scrollback.setLen(0)
  screen.cursorRow = 0
  screen.cursorColumn = 0
  screen.alternateScreen = true
  screen.kittyKeyboardFlags = 0
  screen.kittyKeyboardStack.setLen(0)

proc leaveAlternateScreen(screen: var TerminalScreen) =
  if not screen.alternateScreen: return
  screen.lines = screen.savedLines
  screen.scrollback = screen.savedScrollback
  screen.cursorRow = min(screen.savedCursorRow, screen.rows - 1)
  screen.cursorColumn = min(screen.savedCursorColumn, screen.columns - 1)
  screen.kittyKeyboardFlags = screen.savedKittyKeyboardFlags
  screen.kittyKeyboardStack = screen.savedKittyKeyboardStack
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
  if finalByte == 'u' and rawParams == "?":
    screen.pendingResponses.add("\x1b[?" & $screen.kittyKeyboardFlags & "u")
    screen.csiParams.setLen(0)
    screen.parserState = '\0'
    return
  if finalByte == 'u' and rawParams.startsWith(">"):
    let flags = if rawParams.len > 1:
      try: parseInt(rawParams[1 .. ^1]) except ValueError: 0
    else: 0
    if screen.kittyKeyboardStack.len < 16:
      screen.kittyKeyboardStack.add(screen.kittyKeyboardFlags)
    screen.kittyKeyboardFlags = max(0, flags)
    screen.csiParams.setLen(0)
    screen.parserState = '\0'
    return
  if finalByte == 'u' and rawParams.startsWith("<"):
    let count = if rawParams.len > 1:
      try: max(1, parseInt(rawParams[1 .. ^1])) except ValueError: 1
    else: 1
    for _ in 0 ..< count:
      if screen.kittyKeyboardStack.len == 0:
        screen.kittyKeyboardFlags = 0
      else:
        screen.kittyKeyboardFlags = screen.kittyKeyboardStack.pop()
    screen.csiParams.setLen(0)
    screen.parserState = '\0'
    return
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
        of 1000:
          screen.mouseReportClicks = enabled
        of 1002:
          screen.mouseReportDrag = enabled
        of 1003:
          screen.mouseReportMotion = enabled
        of 1005:
          if enabled: screen.mouseFormat = terminalMouseUtf8
          elif screen.mouseFormat == terminalMouseUtf8: screen.mouseFormat = terminalMouseNormal
        of 1006:
          if enabled: screen.mouseFormat = terminalMouseSgr
          elif screen.mouseFormat == terminalMouseSgr: screen.mouseFormat = terminalMouseNormal
        else: discard
    screen.mouseReporting = screen.mouseReportClicks or screen.mouseReportDrag or
      screen.mouseReportMotion
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
        screen.clearCell(screen.cursorRow, column)
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
        screen.clearCell(screen.cursorRow, column)
  of 'P':
    let count = min(params[0], screen.columns - screen.cursorColumn)
    if count > 0:
      for column in screen.cursorColumn ..< screen.columns - count:
        screen.lines[screen.cursorRow][column] = screen.lines[screen.cursorRow][column + count]
      for column in screen.columns - count ..< screen.columns:
        screen.clearCell(screen.cursorRow, column)
  of 'X':
    let count = min(params[0], screen.columns - screen.cursorColumn)
    for column in screen.cursorColumn ..< screen.cursorColumn + count:
      screen.clearCell(screen.cursorRow, column)
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

  screen.mouseReporting = screen.mouseReportClicks or screen.mouseReportDrag or
    screen.mouseReportMotion

proc takeResponses*(screen: var TerminalScreen): seq[string] =
  result = screen.pendingResponses
  screen.pendingResponses.setLen(0)

proc runeDisplayWidth(rune: Rune): int =
  let code = int(rune)
  if code == 0 or code < 32 or (code >= 0x7f and code < 0xa0): return 0
  # Combining marks and variation selectors occupy the preceding cell.
  if (code >= 0x300 and code <= 0x36f) or
      (code >= 0x1ab0 and code <= 0x1aff) or
      (code >= 0x1dc0 and code <= 0x1dff) or
      (code >= 0xfe00 and code <= 0xfe0f) or
      (code >= 0x200b and code <= 0x200f): return 0
  if (code >= 0x1100 and code <= 0x115f) or
      (code >= 0x2329 and code <= 0x232a) or
      (code >= 0x2e80 and code <= 0xa4cf) or
      (code >= 0xac00 and code <= 0xd7a3) or
      (code >= 0xf900 and code <= 0xfaff) or
      (code >= 0xfe10 and code <= 0xfe19) or
      (code >= 0xfe30 and code <= 0xfe6f) or
      (code >= 0xff00 and code <= 0xff60) or
      (code >= 0xffe0 and code <= 0xffe6) or
      (code >= 0x1f000 and code <= 0x1faff): return 2
  1

proc clearCell(screen: var TerminalScreen, row, column: int) =
  if row < 0 or row >= screen.lines.len or column < 0 or column >= screen.columns: return
  screen.lines[row][column] = TerminalCell(glyph: uint32(ord(' ')), width: 1)

proc putGlyph(screen: var TerminalScreen, glyph: string) =
  if screen.cursorRow > screen.scrollBottom:
    screen.scrollRegionUp()
    screen.cursorRow = screen.scrollBottom
  let width = runeDisplayWidth(runeAt(glyph, 0))
  if width == 0:
    if screen.cursorColumn > 0:
      let cell = addr screen.lines[screen.cursorRow][screen.cursorColumn - 1]
      let previous = if cell[].combiningIndex == 0: "" else:
        screen.combiningGlyphs[int(cell[].combiningIndex) - 1]
      cell[].combiningIndex = internString(screen.combiningGlyphs, previous & glyph)
    return
  if screen.cursorColumn >= screen.columns or (width == 2 and screen.cursorColumn ==
      screen.columns - 1):
    screen.cursorColumn = 0
    inc screen.cursorRow
    if screen.cursorRow > screen.scrollBottom:
      screen.scrollRegionUp()
      screen.cursorRow = screen.scrollBottom
  if screen.insertMode:
    let count = min(width, screen.columns - screen.cursorColumn)
    for column in countdown(screen.columns - 1, screen.cursorColumn + count):
      screen.lines[screen.cursorRow][column] = screen.lines[screen.cursorRow][column - count]
  if screen.cursorColumn > 0 and screen.lines[screen.cursorRow][screen.cursorColumn].width == 0:
    screen.clearCell(screen.cursorRow, screen.cursorColumn - 1)
  if screen.lines[screen.cursorRow][screen.cursorColumn].width == 2 and
      screen.cursorColumn + 1 < screen.columns:
    screen.clearCell(screen.cursorRow, screen.cursorColumn + 1)
  screen.lines[screen.cursorRow][screen.cursorColumn].glyph = uint32(runeAt(glyph, 0))
  screen.lines[screen.cursorRow][screen.cursorColumn].combiningIndex = 0
  screen.lines[screen.cursorRow][screen.cursorColumn].width = width
  screen.applyCurrentStyle(screen.lines[screen.cursorRow][screen.cursorColumn])
  if width == 2:
    screen.lines[screen.cursorRow][screen.cursorColumn + 1] = TerminalCell(width: 0)
    screen.applyCurrentStyle(screen.lines[screen.cursorRow][screen.cursorColumn + 1])
  screen.cursorColumn += width

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
        screen.oscBuffer.setLen(0)
        screen.oscTruncated = false
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
      if byte in {'0'..'9', ';', '?', '>', '<', ':'}:
        screen.csiParams.add(byte)
      elif byte >= '@' and byte <= '~':
        screen.handleCsi(byte)
      else:
        screen.parserState = '\0'
    of 'o':
      if byte == '\x07': screen.finishOsc()
      elif byte == '\x1B': screen.parserState = 'O'
      else: screen.appendOscByte(byte)
    of 'O':
      if byte == '\\': screen.finishOsc()
      elif byte != '\x1B':
        screen.appendOscByte('\x1B')
        screen.appendOscByte(byte)
    else: screen.parserState = '\0'
    inc index

proc appendMouseUtf8(output: var string, value: int) =
  let codepoint = max(0, value)
  if codepoint < 0x80:
    output.add(char(codepoint))
  elif codepoint < 0x800:
    output.add(char(0xc0 or (codepoint shr 6)))
    output.add(char(0x80 or (codepoint and 0x3f)))
  else:
    output.add(char(0xe0 or (codepoint shr 12)))
    output.add(char(0x80 or ((codepoint shr 6) and 0x3f)))
    output.add(char(0x80 or (codepoint and 0x3f)))

proc mouseReport*(screen: TerminalScreen, kind: TerminalMouseEventKind,
                  button, column, row: int, deltaY = 0.0,
                  modifiers: uint32 = 0): string =
  ## Encode a mouse event using the DEC modes selected by the application.
  ## Coordinates are zero-based; terminal protocols are one-based.
  if not screen.mouseReporting: return
  if kind == terminalMouseMove and not screen.mouseReportDrag and
      not screen.mouseReportMotion: return
  var code = 0
  if kind == terminalMouseScroll:
    code = if deltaY > 0: 64 else: 65
  else:
    code = max(0, min(2, button))
    if kind == terminalMouseRelease: code = 3
    if kind == terminalMouseMove: code += 32
  if (modifiers and (1'u32 shl 17)) != 0'u32: code += 4 # Shift
  if (modifiers and (1'u32 shl 19)) != 0'u32: code += 8 # Option
  if (modifiers and (1'u32 shl 18)) != 0'u32: code += 16 # Control
  let x = max(1, column + 1)
  let y = max(1, row + 1)
  if screen.mouseFormat == terminalMouseSgr:
    result = "\x1b[<" & $code & ";" & $x & ";" & $y
    result.add(if kind == terminalMouseRelease: 'm' else: 'M')
  elif screen.mouseFormat == terminalMouseUtf8:
    result = "\x1b[M"
    result.appendMouseUtf8(32 + code)
    result.appendMouseUtf8(32 + x)
    result.appendMouseUtf8(32 + y)
  else:
    # X10/UTF-8 reports use the legacy byte layout. Keep the safe range here;
    # SGR mode is used automatically by modern applications for larger cells.
    if x > 223 or y > 223: return
    result = "\x1b[M" & char(32 + code) & char(32 + x) & char(32 + y)

proc lineText*(screen: TerminalScreen, row: int): string =
  if row < 0 or row >= screen.lines.len: return
  for cell in screen.lines[row]:
    if cell.width != 0:
      result.add(screen.cellText(cell))
  if result.strip.len == 0: result = ""
  else: result = result.strip(leading = false, trailing = true)

proc visibleText*(screen: TerminalScreen): seq[string] =
  for row in 0 ..< screen.lines.len: result.add(screen.lineText(row))

proc gridText*(screen: TerminalScreen): string =
  ## Preserve every visible row and its cell-backed trailing spaces for native
  ## overlays that need stable byte offsets for selection and styling.
  for row in 0 ..< screen.lines.len:
    if row > 0: result.add('\n')
    for cell in screen.lines[row]:
      if cell.width != 0:
        result.add(screen.cellText(cell))

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
      if cells[column].width != 0:
        line.add(screen.cellText(cells[column]))
    result.add(line.strip(leading = false, trailing = true))
    if row < range.active.row: result.add("\n")

when defined(windows):
  {.compile: "windows_pty.c".}

  type
    WindowsConPty* = pointer
    TerminalPty* = ref object
      native*: WindowsConPty
      screen*: TerminalScreen
      closed*: bool

  proc nativeConPtyCreate(shell, workingDirectory: cstring, columns, rows: uint16): WindowsConPty
      {.importc: "nimculus_conpty_create", cdecl.}
  proc nativeConPtyWrite(pty: WindowsConPty, bytes: pointer, length: uint32): int32
      {.importc: "nimculus_conpty_write", cdecl.}
  proc nativeConPtyRead(pty: WindowsConPty, bytes: pointer, capacity: uint32): uint32
      {.importc: "nimculus_conpty_read", cdecl.}
  proc nativeConPtyResize(pty: WindowsConPty, columns, rows: uint16): bool
      {.importc: "nimculus_conpty_resize", cdecl.}
  proc nativeConPtyClose(pty: WindowsConPty) {.importc: "nimculus_conpty_close", cdecl.}

  proc newTerminalPty*(shell = "cmd.exe", workingDirectory = "",
                       columns = 80, rows = 24): TerminalPty =
    new(result)
    result.screen = initTerminalScreen(columns, rows)
    result.native = nativeConPtyCreate(shell.cstring, workingDirectory.cstring,
      uint16(max(1, columns)), uint16(max(1, rows)))
    if result.native == nil: raiseOSError(osLastError())

  proc writeInput*(pty: TerminalPty, input: string): int =
    if pty == nil or pty.closed or input.len == 0: return 0
    int(nativeConPtyWrite(pty.native, input.cstring, uint32(input.len)))

  proc pollOutput*(pty: TerminalPty): string =
    if pty == nil or pty.closed: return
    var buffer = newString(8192)
    let count = nativeConPtyRead(pty.native, addr buffer[0], uint32(buffer.len))
    if count > 0:
      buffer.setLen(int(count))
      pty.screen.feed(buffer)
      result = buffer

  proc resize*(pty: TerminalPty, columns, rows: int) =
    if pty == nil or pty.closed: return
    discard nativeConPtyResize(pty.native, uint16(max(1, columns)), uint16(max(1, rows)))
    pty.screen.resize(columns, rows)

  proc close*(pty: TerminalPty) =
    if pty == nil or pty.closed: return
    nativeConPtyClose(pty.native)
    pty.native = nil
    pty.closed = true

elif defined(macosx):
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
      ## The PTY master is non-blocking. Preserve an unwritten tail instead
      ## of dropping it when a large paste only partially fits in the kernel
      ## buffer.
      pendingInput: string
      pendingInputOffset: int
      closed*: bool

  proc forkpty(amaster: ptr cint, name: cstring, termp, winp: pointer): Pid
      {.importc, header: "<util.h>".}
  proc execl(path, arg0: cstring): cint {.varargs, importc, header: "<unistd.h>".}
  proc chdir(path: cstring): cint {.importc, header: "<unistd.h>".}
  proc setpgid(pid, pgid: Pid): cint {.importc, header: "<unistd.h>".}

  proc newTerminalPty*(shell = "/bin/zsh", workingDirectory = "",
                       columns = 80, rows = 24): TerminalPty =
    ## Resolve configuration errors in the parent. A failed `chdir` or `execl`
    ## in the forked child otherwise looks like a briefly opened, empty
    ## terminal and can silently inherit the editor's working directory.
    let resolvedShell = if shell.isAbsolute: shell else: findExe(shell)
    if resolvedShell.len == 0 or not fileExists(resolvedShell):
      raise newException(IOError, "terminal shell not found: " & shell)
    if workingDirectory.len > 0 and not dirExists(workingDirectory):
      raise newException(IOError, "terminal working directory not found: " & workingDirectory)
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
      # Keep every command started by this terminal in a group distinct from
      # the editor.  `forkpty` normally establishes this already, but doing it
      # explicitly makes the close contract independent of shell behaviour.
      discard setpgid(0, 0)
      if workingDirectory.len > 0: discard chdir(workingDirectory.cstring)
      discard execl(resolvedShell.cstring, resolvedShell.cstring, "-l".cstring, nil)
      quit(127)
    discard fcntl(result.masterFd, F_SETFL, fcntl(result.masterFd, F_GETFL) or O_NONBLOCK)

  proc pendingInputBytes*(pty: TerminalPty): int =
    if pty == nil or pty.closed: return 0
    max(0, pty.pendingInput.len - pty.pendingInputOffset)

  proc flushInput(pty: TerminalPty): int =
    ## Drain as much queued input as the kernel currently accepts. EAGAIN and
    ## other write failures leave the tail queued for the next idle poll.
    if pty == nil or pty.closed: return 0
    while pty.pendingInputOffset < pty.pendingInput.len:
      let remaining = pty.pendingInput.len - pty.pendingInputOffset
      let written = posix.write(pty.masterFd,
        unsafeAddr pty.pendingInput[pty.pendingInputOffset], remaining)
      if written <= 0: break
      pty.pendingInputOffset += written
      result += written
    if pty.pendingInputOffset >= pty.pendingInput.len:
      pty.pendingInput.setLen(0)
      pty.pendingInputOffset = 0

  proc writeInput*(pty: TerminalPty, input: string): int =
    ## Return accepted bytes, not merely the first non-blocking kernel write.
    ## The pending tail is drained by `pollOutput` on following UI idle ticks.
    if pty == nil or pty.closed or input.len == 0: return 0
    pty.pendingInput.add(input)
    result = input.len
    discard pty.flushInput()

  proc terminalChildExited(pid: Pid): bool =
    ## Reap a naturally exited shell without blocking Cocoa's idle path. Keep
    ## the master open until `read` reports EOF/EIO so its final output is
    ## still delivered to the terminal screen.
    if pid <= 0: return true
    var status: cint
    let waited = waitpid(pid, status, WNOHANG)
    waited == pid or (waited < 0 and errno == ECHILD)

  proc terminalProcessGroupExited(pid: Pid): bool =
    ## A login shell can exit while a foreground child still owns the slave.
    ## Do not release on a momentary EAGAIN until the PTY-owned group is gone.
    if pid <= 0: return true
    if kill(-pid, 0) == 0: return false
    errno == ESRCH

  proc releaseTerminalPty(pty: TerminalPty) =
    if pty == nil or pty.closed: return
    if pty.masterFd >= 0:
      discard posix.close(pty.masterFd)
      pty.masterFd = -1
    pty.pendingInput.setLen(0)
    pty.pendingInputOffset = 0
    pty.closed = true

  proc pollOutput*(pty: TerminalPty): string =
    if pty == nil or pty.closed: return
    discard pty.flushInput()
    var remainingBudget = MaxTerminalReadBytesPerPoll
    while remainingBudget > 0:
      let capacity = min(TerminalReadChunkBytes, remainingBudget)
      var buffer = newString(capacity)
      let count = posix.read(pty.masterFd, addr buffer[0], buffer.len)
      if count <= 0:
        # EAGAIN only means the non-blocking master has no output in this
        # frame. EOF and non-retryable errors after the shell exits mean this
        # session cannot produce more output and must not stay in the idle
        # polling set forever.
        if count == 0 or (errno != EAGAIN and errno != EWOULDBLOCK and errno != EINTR):
          if terminalChildExited(pty.childPid): pty.releaseTerminalPty()
        elif terminalChildExited(pty.childPid) and terminalProcessGroupExited(pty.childPid):
          # On macOS a non-blocking master can report EAGAIN briefly after a
          # short-lived child has closed the slave. Once its group is gone,
          # there can be no later output to drain.
          pty.releaseTerminalPty()
        break
      buffer.setLen(count)
      pty.screen.feed(buffer)
      for response in pty.screen.takeResponses():
        discard pty.writeInput(response)
      result.add(buffer)
      remainingBudget -= count

  proc resize*(pty: TerminalPty, columns, rows: int) =
    if pty == nil or pty.closed: return
    var size = TerminalWinSize(rows: cushort(max(1, rows)),
      columns: cushort(max(1, columns)), xPixels: 0, yPixels: 0)
    discard terminalIoctl(pty.masterFd, terminalSetWindowSize, addr size)
    pty.screen.resize(columns, rows)

  proc terminateTerminalProcessGroup(pid: Pid, signal: cint) =
    ## A shell can leave a pipeline running after it receives SIGTERM.  The
    ## terminal owns the whole child group, so signal that group as well as
    ## the leader.  The second call is a safe fallback if a platform's
    ## forkpty/session setup did not retain the expected group id.
    if pid <= 0: return
    discard kill(-pid, signal)
    discard kill(pid, signal)

  proc reapTerminalChild(pid: Pid) =
    var status: cint
    # Give a shell a short grace period, then force-reap it so closing a
    # terminal cannot block the Cocoa termination path indefinitely. In
    # particular, never use blocking waitpid after SIGKILL: a malformed PTY
    # session must not turn app quit into an unbounded kernel wait.
    for _ in 0 ..< 100:
      let waited = waitpid(pid, status, WNOHANG)
      if waited == pid or (waited < 0 and errno == ECHILD): return
      sleep(10)
    terminateTerminalProcessGroup(pid, SIGKILL)
    for _ in 0 ..< 100:
      let waited = waitpid(pid, status, WNOHANG)
      if waited == pid or (waited < 0 and errno == ECHILD): return
      sleep(10)

  proc close*(pty: TerminalPty) =
    if pty == nil or pty.closed: return
    terminateTerminalProcessGroup(pty.childPid, SIGTERM)
    reapTerminalChild(pty.childPid)
    pty.releaseTerminalPty()
