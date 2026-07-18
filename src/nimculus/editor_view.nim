import std/strutils
import nimculus/editor_buffer

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
