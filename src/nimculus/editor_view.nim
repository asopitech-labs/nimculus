import std/strutils
import nimculus/editor_buffer
import nimnui/text

type
  EditorViewState* = object
    selection*: Selection
    scrollLine*: int
    showLineNumbers*, softWrap*, showIndentGuides*: bool
    indentWidth*: int
    commandPaletteOpen*: bool
    statusMessage*: string

proc newEditorView*(): EditorViewState =
  EditorViewState(showLineNumbers: true, softWrap: false,
    showIndentGuides: true, indentWidth: 2)

proc cursor*(view: EditorViewState): int = view.selection.active

proc moveCursor*(view: var EditorViewState, byteOffset: int, selecting = false) =
  if not selecting: view.selection.anchor = byteOffset
  view.selection.active = byteOffset

proc byteOffsetAtLineColumn*(buffer: PieceTable, line, column: int): int =
  ## Convert a logical grapheme column into a UTF-8 byte offset.
  let text = buffer.toString()
  if buffer.lineStarts.len == 0: return 0
  let targetLine = max(0, min(line, buffer.lineStarts.high))
  let start = buffer.lineStarts[targetLine]
  let finish = if targetLine + 1 < buffer.lineStarts.len:
    buffer.lineStarts[targetLine + 1]
  else: text.len
  let positions = textPositions(buffer.substring(start, finish))
  let targetColumn = max(0, min(column, positions.high))
  start + positions[targetColumn].byteOffset

proc selectedRange*(view: EditorViewState): tuple[startByte, endByte: int] =
  (startByte: min(view.selection.anchor, view.selection.active),
   endByte: max(view.selection.anchor, view.selection.active))

proc lineNumber*(buffer: PieceTable, line: int): string = $(line + 1)

proc statusBarText*(view: EditorViewState, buffer: PieceTable): string =
  let location = buffer.lineColumn(view.cursor)
  let dirty = if buffer.isDirty: " • Unsaved" else: ""
  view.statusMessage & "Ln " & $(location.line + 1) & ", Col " & $(location.column + 1) & dirty

proc openCommandPalette*(view: var EditorViewState) = view.commandPaletteOpen = true
proc closeCommandPalette*(view: var EditorViewState) = view.commandPaletteOpen = false

proc visibleLines*(buffer: PieceTable, firstLine, count: int): seq[string] =
  let text = buffer.toString().splitLines()
  for line in firstLine ..< min(text.len, firstLine + count): result.add(text[line])
