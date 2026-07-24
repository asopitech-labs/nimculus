when defined(windows):
  import std/os
  import nimnui/nimnui
  import nimculus/terminal

  var windowsTerminal*: TerminalPty
  var windowsTerminalVisible* = false
  var windowsTerminalSelection* = TerminalSelection()
  var windowsTerminalSelecting = false

  proc windowsTerminalOverlayHeight(): float32 =
    var metrics: PlatformMetrics
    platformGetMetrics(addr metrics)
    let scale = max(1.0, float32(metrics.scaleFactor))
    min(280'f32 / scale, max(120'f32 / scale, float32(metrics.heightPoints) / 3'f32))

  proc windowsTerminalPointAt(x, y: float32): TerminalPoint =
    if windowsTerminal == nil: return TerminalPoint()
    var metrics: PlatformMetrics
    platformGetMetrics(addr metrics)
    let scale = max(1.0, float32(metrics.scaleFactor))
    let overlayTop = float32(metrics.heightPoints) - windowsTerminalOverlayHeight()
    var cellWidth = 7.2
    var lineHeight = 14.0
    platformGetTerminalCellMetrics(addr cellWidth, addr lineHeight)
    let logicalCellWidth = max(4'f32, float32(cellWidth))
    let logicalLineHeight = max(8'f32, float32(lineHeight))
    TerminalPoint(
      row: max(0, min(windowsTerminal.screen.rows - 1,
        int((y - overlayTop) / logicalLineHeight))),
      column: max(0, min(windowsTerminal.screen.columns,
        int((x * scale - 8'f32 * scale) / (logicalCellWidth * scale)))))

  proc windowsTerminalContains(x, y: float32): bool =
    var metrics: PlatformMetrics
    platformGetMetrics(addr metrics)
    let top = float32(metrics.heightPoints) - windowsTerminalOverlayHeight()
    x >= 0 and x < float32(metrics.widthPoints) and y >= top and
      y < float32(metrics.heightPoints)

  proc syncWindowsTerminalSelection() =
    if windowsTerminal == nil: return
    let selection = windowsTerminal.screen.normalizedSelection(windowsTerminalSelection)
    platformSetTerminalSelection(uint32(selection.anchor.row),
      uint32(selection.anchor.column), uint32(selection.active.row),
      uint32(selection.active.column))

  proc syncWindowsTerminal() =
    if windowsTerminal == nil: return
    let text = windowsTerminal.screen.gridText()
    var runs: seq[NativeTerminalRun]
    var byteOffset = 0
    for rowIndex, row in windowsTerminal.screen.lines:
      for columnIndex, cell in row:
        if cell.width == 0: continue
        let cellText = windowsTerminal.screen.cellText(cell)
        let style = windowsTerminal.screen.cellStyle(cell)
        let hyperlink = windowsTerminal.screen.cellHyperlinkUri(cell)
        let endByte = byteOffset + cellText.len
        let flags = (if style.bold: 1'u32 else: 0'u32) or
          (if style.dim: 2'u32 else: 0'u32) or
          (if style.italic: 4'u32 else: 0'u32) or
          (if style.underline: 8'u32 else: 0'u32) or
          (if style.inverse: 16'u32 else: 0'u32) or
          (if style.strikethrough: 32'u32 else: 0'u32)
        runs.add(NativeTerminalRun(startByte: uint32(byteOffset),
          endByte: uint32(endByte), flags: flags,
          row: uint32(rowIndex), column: uint32(columnIndex),
          cellWidth: uint32(max(1, cell.width)),
          foregroundKind: uint32(ord(style.foreground.kind)),
          foregroundIndex: uint32(max(0, style.foreground.index)),
          foregroundRed: uint32(style.foreground.red),
          foregroundGreen: uint32(style.foreground.green),
          foregroundBlue: uint32(style.foreground.blue),
          backgroundKind: uint32(ord(style.background.kind)),
          backgroundIndex: uint32(max(0, style.background.index)),
          backgroundRed: uint32(style.background.red),
          backgroundGreen: uint32(style.background.green),
          backgroundBlue: uint32(style.background.blue),
          hyperlinkUri: if hyperlink.len > 0: hyperlink.cstring else: nil))
        byteOffset = endByte
      byteOffset += 1
    if runs.len > 0:
      platformSetTerminalRuns(text.cstring, uint32(text.len), addr runs[0], uint32(runs.len))
    else:
      platformSetTerminalRuns(text.cstring, uint32(text.len), nil, 0)

  proc startWindowsTerminal*() =
    if windowsTerminal != nil and not windowsTerminal.closed:
      windowsTerminalVisible = true
      platformSetTerminalVisible(true)
      syncWindowsTerminal()
      return
    try:
      windowsTerminal = newTerminalPty("cmd.exe", getCurrentDir(), 100, 24)
      windowsTerminalVisible = true
      platformSetTerminalVisible(true)
      syncWindowsTerminal()
    except CatchableError:
      windowsTerminal = nil
      windowsTerminalVisible = false
      platformSetTerminalVisible(false)

  proc pollWindowsTerminal*() =
    if windowsTerminal == nil or windowsTerminal.closed: return
    discard windowsTerminal.pollOutput()
    if windowsTerminalVisible: syncWindowsTerminal()

  proc closeWindowsTerminal*() =
    if windowsTerminal != nil: windowsTerminal.close()
    windowsTerminal = nil
    windowsTerminalVisible = false
    windowsTerminalSelection = TerminalSelection()
    windowsTerminalSelecting = false
    platformSetTerminalSelection(0, 0, 0, 0)
    platformSetTerminalVisible(false)

  proc toggleWindowsTerminal*() =
    if windowsTerminalVisible:
      windowsTerminalVisible = false
      platformSetTerminalVisible(false)
    else:
      startWindowsTerminal()

  proc newWindowsTerminal*() =
    closeWindowsTerminal()
    startWindowsTerminal()

  proc writeWindowsTerminalText*(text: string): bool =
    if not windowsTerminalVisible or windowsTerminal == nil or windowsTerminal.closed: return false
    discard windowsTerminal.writeInput(text)
    true

  proc handleWindowsTerminalInput*(event: ptr NimculusInputEvent): bool =
    if not windowsTerminalVisible or windowsTerminal == nil or windowsTerminal.closed or
        event == nil: return false
    if event.kind == 10'u32:
      let control = (event.modifiers and (1'u32 shl 18)) != 0
      let input = case event.keyCode
        of 123'u32: "\x1b[D"
        of 126'u32: "\x1b[A"
        of 124'u32: "\x1b[C"
        of 125'u32: "\x1b[B"
        of 8'u32:
          if control: "\x03" else: ""
        else: ""
      if input.len == 0: return false
      discard writeWindowsTerminalText(input)
      return true
    if not windowsTerminalContains(float32(event.x), float32(event.y)): return false
    let point = windowsTerminalPointAt(float32(event.x), float32(event.y))
    let isPointerDown = event.kind in [1'u32, 3'u32, 25'u32]
    let isPointerUp = event.kind in [2'u32, 4'u32, 26'u32]
    let isPointerMove = event.kind in [5'u32, 6'u32, 7'u32, 27'u32]
    if event.kind == 22'u32 or isPointerDown or isPointerUp or isPointerMove:
      if windowsTerminal.screen.mouseReporting:
        let mouseKind = if event.kind == 22'u32: terminalMouseScroll
          elif isPointerDown: terminalMousePress
          elif isPointerUp: terminalMouseRelease
          else: terminalMouseMove
        let report = windowsTerminal.screen.mouseReport(mouseKind,
          int(event.button), point.column, point.row, float32(event.deltaY),
          event.modifiers)
        if report.len > 0: discard writeWindowsTerminalText(report)
        return true
      if isPointerDown and event.button == 0'u32:
        windowsTerminalSelection.anchor = point
        windowsTerminalSelection.active = point
        windowsTerminalSelecting = true
      elif isPointerMove and windowsTerminalSelecting:
        windowsTerminalSelection.active = point
      elif isPointerUp and windowsTerminalSelecting:
        windowsTerminalSelection.active = point
        windowsTerminalSelecting = false
      elif event.kind != 22'u32:
        return false
      syncWindowsTerminalSelection()
      return true
    false

  proc windowsTerminalSelectedText*(): string =
    if windowsTerminal == nil: return ""
    windowsTerminal.screen.selectedText(windowsTerminalSelection)

  proc selectAllWindowsTerminal*() =
    if windowsTerminal == nil: return
    windowsTerminalSelection = TerminalSelection(
      anchor: TerminalPoint(row: 0, column: 0),
      active: TerminalPoint(row: max(0, windowsTerminal.screen.lineCount() - 1),
        column: windowsTerminal.screen.columns))
    syncWindowsTerminalSelection()

else:
  proc startWindowsTerminal*() = discard
  proc pollWindowsTerminal*() = discard
  proc closeWindowsTerminal*() = discard
  proc toggleWindowsTerminal*() = discard
  proc newWindowsTerminal*() = discard
  proc writeWindowsTerminalText*(text: string): bool = false
  proc handleWindowsTerminalInput*(event: pointer): bool = false
  proc windowsTerminalSelectedText*(): string = ""
  proc selectAllWindowsTerminal*() = discard
