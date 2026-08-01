import std/strutils
import std/algorithm
import std/unicode
import std/math
import nimculus/editor_buffer
import nimnui/text
import nimculus/syntax

type
  EditorViewState* = object
    selection*: Selection
    ## Zed keeps selections as an ordered collection owned by the editor item.
    ## `selection` remains the primary selection for compatibility with the
    ## existing pane/session boundary; additional selections are all edited
    ## atomically with it.
    additionalSelections*: seq[Selection]
    scrollLine*: int
    scrollX*: float32
    showLineNumbers*, softWrap*, showIndentGuides*: bool
    indentWidth*: int
    ## Fold state is byte anchored to the document, while the native backend
    ## receives a derived line map. Keeping it on the view matches Zed's
    ## item-owned display map and lets split panes fold independently.
    foldedRanges*: seq[FoldRange]
    commandPaletteOpen*: bool
    statusMessage*: string

proc newEditorView*(): EditorViewState =
  # macOS currently has no horizontal editor scrollbar. Keep long lines
  # visible inside the content viewport by default; an explicitly persisted
  # false value still lets users choose the Zed-style unwrapped view.
  EditorViewState(showLineNumbers: true, softWrap: true,
    showIndentGuides: true, indentWidth: 2)

proc cursor*(view: EditorViewState): int = view.selection.active

proc selections*(view: EditorViewState): seq[Selection] =
  result = @[view.selection]
  result.add(view.additionalSelections)

proc selectionRanges*(view: EditorViewState): seq[tuple[startByte, endByte: int]] =
  ## Return disjoint, document-order ranges. The editor buffer rejects
  ## overlaps, so collapse duplicate/overlapping carets before every edit.
  var ranges: seq[tuple[startByte, endByte: int]]
  for selection in view.selections:
    let startByte = min(selection.anchor, selection.active)
    let endByte = max(selection.anchor, selection.active)
    ranges.add((startByte: startByte, endByte: endByte))
  ranges.sort(proc(a, b: tuple[startByte, endByte: int]): int =
    if a.startByte != b.startByte: cmp(a.startByte, b.startByte)
    else: cmp(a.endByte, b.endByte))
  for range in ranges:
    if result.len == 0 or range.startByte > result[^1].endByte:
      result.add(range)
    elif range.endByte > result[^1].endByte:
      result[^1].endByte = range.endByte

proc clearAdditionalSelections*(view: var EditorViewState) =
  view.additionalSelections.setLen(0)

proc floorGraphemeBoundary*(text: string, offset: int): int

proc addCaret*(view: var EditorViewState, byteOffset: int, text: string): bool =
  ## Add a collapsed caret without disturbing the primary selection. This is
  ## the Option-click entry point used by Zed-like editors.
  let offset = floorGraphemeBoundary(text, max(0, min(byteOffset, text.len)))
  for selection in view.selections:
    if selection.anchor == offset and selection.active == offset: return false
  view.additionalSelections.add(Selection(anchor: offset, active: offset))
  true

proc makeSingleSelection*(view: var EditorViewState, anchor, active: int) =
  view.selection = Selection(anchor: anchor, active: active)
  view.clearAdditionalSelections()

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

proc isWordSpace(cluster: string): bool =
  ## Zed's word movement classifies Unicode whitespace, not only ASCII bytes.
  if cluster.len == 0: return false
  for rune in cluster.runes:
    if not rune.isWhiteSpace: return false
  true

type
  WordClass = enum wordWhitespace, wordText, wordPunctuation
  GraphemeInfo = object
    startByte, endByte: int
    kind: WordClass

proc firstRune(cluster: string): Rune =
  for rune in cluster.runes:
    return rune
  Rune(0)

proc classifyWordGrapheme(cluster: string): WordClass =
  if cluster.isWordSpace: return wordWhitespace
  let rune = cluster.firstRune
  let value = int(rune)
  if rune.isAlpha or (value >= ord('0') and value <= ord('9')) or value == ord('_'):
    wordText
  else:
    wordPunctuation

proc graphemeInfo(text: string): seq[GraphemeInfo] =
  let positions = textPositions(text)
  if positions.len < 2: return
  for index in 0 ..< positions.len - 1:
    let startByte = positions[index].byteOffset
    let endByte = positions[index + 1].byteOffset
    result.add(GraphemeInfo(startByte: startByte, endByte: endByte,
      kind: classifyWordGrapheme(text[startByte ..< endByte])))

proc previousGraphemeBoundary*(text: string, offset: int): int =
  let bounded = max(0, min(offset, text.len))
  let positions = textPositions(text)
  for index in countdown(positions.high, 0):
    if positions[index].byteOffset < bounded: return positions[index].byteOffset
  0

proc nextGraphemeBoundary*(text: string, offset: int): int =
  let bounded = max(0, min(offset, text.len))
  for position in textPositions(text):
    if position.byteOffset > bounded: return position.byteOffset
  text.len

proc floorGraphemeBoundary*(text: string, offset: int): int =
  ## Clamp an externally supplied byte position without moving a position
  ## that is already a valid grapheme boundary. Native text systems report
  ## UTF-16/codepoint positions, while editor deletion and selection use
  ## extended grapheme clusters.
  let bounded = max(0, min(offset, text.len))
  let positions = textPositions(text)
  for index in countdown(positions.high, 0):
    if positions[index].byteOffset <= bounded:
      return positions[index].byteOffset
  0

proc previousWordBoundary*(text: string, offset: int): int =
  let clusters = text.graphemeInfo
  if clusters.len == 0: return 0
  let cursor = max(0, min(offset, text.len))
  var nextIndex = 0
  while nextIndex < clusters.len and clusters[nextIndex].endByte <= cursor: inc nextIndex
  var rightIndex = nextIndex - 1
  while rightIndex >= 0 and clusters[rightIndex].kind == wordWhitespace: dec rightIndex
  if rightIndex < 0: return 0
  var firstIteration = true
  while rightIndex > 0:
    let right = clusters[rightIndex]
    let left = clusters[rightIndex - 1]
    if left.kind != right.kind and right.kind != wordWhitespace:
      # Match Zed's Alt-left behavior: punctuation immediately before a word
      # is crossed together with that word's preceding text.
      if firstIteration and right.kind == wordPunctuation and left.kind != wordPunctuation:
        firstIteration = false
      else:
        return right.startByte
    firstIteration = false
    dec rightIndex
  0

proc nextWordBoundary*(text: string, offset: int): int =
  let clusters = text.graphemeInfo
  if clusters.len == 0: return 0
  let cursor = max(0, min(offset, text.len))
  var index = 0
  while index < clusters.len and clusters[index].endByte <= cursor: inc index
  while index < clusters.len and clusters[index].kind == wordWhitespace: inc index
  if index >= clusters.len: return text.len
  var firstIteration = true
  while index + 1 < clusters.len:
    let left = clusters[index]
    let right = clusters[index + 1]
    if left.kind != right.kind and left.kind != wordWhitespace:
      # Match Zed's Alt-right behavior: a leading punctuation run is skipped
      # before stopping at the next word boundary.
      if firstIteration and left.kind == wordPunctuation and right.kind != wordPunctuation:
        firstIteration = false
      else:
        return right.startByte
    firstIteration = false
    inc index
  text.len

proc scrollLineDelta*(remainder: var float32, deltaY: float32,
                      precise: bool, lineHeight = 18'f32): int =
  ## Convert AppKit/Zed-style scroll deltas into whole logical lines while
  ## retaining sub-line precise trackpad motion for the next event.
  let units = if precise: -deltaY / max(1'f32, lineHeight) else: -deltaY
  remainder += units
  let whole = if remainder >= 0'f32: floor(remainder) else: ceil(remainder)
  result = int(whole)
  remainder -= float32(result)

proc selectedRange*(view: EditorViewState): tuple[startByte, endByte: int] =
  (startByte: min(view.selection.anchor, view.selection.active),
   endByte: max(view.selection.anchor, view.selection.active))

proc clampSelectionToText*(view: var EditorViewState, text: string) =
  ## Keep selection endpoints valid after a document-wide replacement or
  ## external buffer update. Endpoints are byte offsets, but must still land
  ## on extended grapheme boundaries before they are sent to AppKit.
  view.selection.anchor = floorGraphemeBoundary(text,
    min(max(0, view.selection.anchor), text.len))
  view.selection.active = floorGraphemeBoundary(text,
    min(max(0, view.selection.active), text.len))
  for index in 0 ..< view.additionalSelections.len:
    view.additionalSelections[index].anchor = floorGraphemeBoundary(text,
      min(max(0, view.additionalSelections[index].anchor), text.len))
    view.additionalSelections[index].active = floorGraphemeBoundary(text,
      min(max(0, view.additionalSelections[index].active), text.len))
  var unique: seq[Selection]
  for selection in view.additionalSelections:
    var duplicate = false
    for existing in unique:
      if existing.anchor == selection.anchor and existing.active == selection.active:
        duplicate = true
        break
    if not duplicate and not (selection.anchor == view.selection.anchor and
        selection.active == view.selection.active):
      unique.add(selection)
  view.additionalSelections = unique

proc lineNumber*(buffer: PieceTable, line: int): string = $(line + 1)

proc statusBarText*(view: EditorViewState, buffer: PieceTable): string =
  let location = buffer.lineColumn(view.cursor)
  let dirty = if buffer.isDirty: " • Unsaved" else: ""
  let message = view.statusMessage.strip()
  let prefix = if message.len > 0: message & "  •  " else: ""
  prefix & "Ln " & $(location.line + 1) & ", Col " & $(location.column + 1) & dirty

proc openCommandPalette*(view: var EditorViewState) = view.commandPaletteOpen = true
proc closeCommandPalette*(view: var EditorViewState) = view.commandPaletteOpen = false

proc visibleLines*(buffer: PieceTable, firstLine, count: int): seq[string] =
  let text = buffer.toString().splitLines()
  for line in firstLine ..< min(text.len, firstLine + count): result.add(text[line])
