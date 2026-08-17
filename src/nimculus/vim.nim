import nimculus/editor_buffer
import nimculus/editor_view
import nimculus/settings
import nimnui/commands

const
  VimNormalContext* = "VimNormal"
  VimInsertContext* = "VimInsert"

proc vimEnabled*(settings: SettingsStore): bool =
  ## The setting is intentionally local to this first slice. The settings
  ## schema remains unchanged until the native input wiring lands.
  settings != nil and jsonBoolAt(settings.values, "vim.enabled", false)

proc configureVim*(view: var EditorViewState, settings: SettingsStore) =
  view.vimEnabled = settings.vimEnabled
  view.vimMode = vimNormal
  view.vimPendingKeystrokes.setLen(0)
  view.vimCount = 0

proc vimKey*(key: char): Keystroke =
  Keystroke(keyCode: uint32(ord(key)), modifiers: {})

proc vimModeText*(mode: VimMode): string =
  if mode == vimInsert: "INSERT" else: "NORMAL"

proc vimContextName*(mode: VimMode): string =
  if mode == vimInsert: VimInsertContext else: VimNormalContext

proc vimPendingMotionMatch*(view: EditorViewState,
                            motion: char): tuple[matched, pending: bool] =
  ## Keep counted input on the same Shortcut matcher as the regular command
  ## layer. A count is a strict prefix until its motion key arrives.
  if view.vimPendingKeystrokes.len == 0: return (false, false)
  let binding = Shortcut(keystrokes: view.vimPendingKeystrokes & @[vimKey(motion)])
  binding.matchKeystrokes(view.vimPendingKeystrokes)

proc lineColumnLimit(buffer: PieceTable, line: int): int =
  let endOffset = buffer.lineEndByteOffset(line)
  max(0, buffer.lineColumn(endOffset).column - 1)

proc moveVimCursor*(view: var EditorViewState, buffer: PieceTable,
                    lineDelta, columnDelta: int) =
  let location = buffer.lineColumn(view.cursor)
  let targetLine = max(0, min(buffer.lineStarts.high, location.line + lineDelta))
  let targetColumn = max(0, min(lineColumnLimit(buffer, targetLine),
    location.column + columnDelta))
  view.moveCursor(buffer.byteOffsetAtLineColumn(targetLine, targetColumn))

proc moveVimMotion(view: var EditorViewState, buffer: PieceTable,
                   motion: char, count: int) =
  case motion
  of 'h': view.moveVimCursor(buffer, 0, -count)
  of 'l': view.moveVimCursor(buffer, 0, count)
  of 'j': view.moveVimCursor(buffer, count, 0)
  of 'k': view.moveVimCursor(buffer, -count, 0)
  else: discard

proc clearVimPending(view: var EditorViewState) =
  view.vimPendingKeystrokes.setLen(0)
  view.vimCount = 0

proc dispatchVimKey*(view: var EditorViewState, buffer: var PieceTable,
                     key: char): bool =
  if not view.vimEnabled: return false

  if view.vimMode == vimInsert:
    if key == '\x1b':
      view.vimMode = vimNormal
      view.moveVimCursor(buffer, 0, -1)
      view.clearVimPending()
      return true
    if key notin {'\n', '\r'}:
      let offset = view.cursor
      buffer.edit(Edit(startByte: offset, endByte: offset, text: $key))
      view.moveCursor(offset + ($key).len)
      return true
    return false

  if key == 'i':
    view.vimMode = vimInsert
    view.clearVimPending()
    return true

  if key in {'0'..'9'}:
    view.vimPendingKeystrokes.add(vimKey(key))
    view.vimCount = min(int.high div 10,
      view.vimCount * 10 + (ord(key) - ord('0')))
    return true

  if key notin {'h', 'j', 'k', 'l'}:
    view.clearVimPending()
    return false

  let motionBinding = Shortcut(keystrokes: @[vimKey(key)])
  let motionMatch = motionBinding.matchKeystrokes(@[vimKey(key)])
  if not motionMatch.matched:
    view.clearVimPending()
    return false
  let count = if view.vimCount > 0: view.vimCount else: 1
  view.moveVimMotion(buffer, key, count)
  view.clearVimPending()
  true

proc dispatchVimText*(view: var EditorViewState, buffer: var PieceTable,
                      value: string): bool =
  ## Tests and future input adapters can feed literal text through the same
  ## modal state machine without depending on a platform callback.
  for key in value:
    if not view.dispatchVimKey(buffer, key): return false
  value.len > 0
