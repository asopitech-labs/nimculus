import std/strutils
import std/algorithm
import std/unicode
import std/math
import nimculus/editor_buffer
import nimnui/text
import nimnui/nimnui
import nimculus/syntax
import nimculus/editor_scroll

type
  EditorViewState* = object
    selection*: Selection
    ## Zed keeps selections as an ordered collection owned by the editor item.
    ## `selection` remains the primary selection for compatibility with the
    ## existing pane/session boundary; additional selections are all edited
    ## atomically with it.
    additionalSelections*: seq[Selection]
    scrollLine*: int
    ## Continuous top-of-viewport position in logical pixels. This is the
    ## source of truth for rendering; `scrollLine` and `scrollYFraction` are
    ## derived compatibility fields for callers and persisted sessions that
    ## still address the viewport by line.
    scrollYPixels*: float32
    scrollYFraction*: float32
    ## Soft-wrapped Markdown keeps its own continuous display-row position.
    ## `scrollLine` remains the source-line compatibility field used by syntax
    ## requests and persistence.
    scrollDisplayPixels*: float32
    scrollDisplayInitialized*: bool
    scrollX*: float32
    ## Zed's per-editor OngoingScroll state for precise trackpad deltas.
    ongoingScroll*: OngoingScroll
    showLineNumbers*, softWrap*, showIndentGuides*: bool
    indentWidth*: int
    ## Fold state is byte anchored to the document, while the native backend
    ## receives a derived line map. Keeping it on the view matches Zed's
    ## item-owned display map and lets split panes fold independently.
    foldedRanges*: seq[FoldRange]
    commandPaletteOpen*: bool
    statusMessage*: string

proc newEditorView*(): EditorViewState =
  # Zed keeps long lines unwrapped by default. Turning soft-wrap on remains a
  # per-view preference and is restored when a session explicitly saved it.
  EditorViewState(showLineNumbers: true, softWrap: false,
    showIndentGuides: true, indentWidth: 2, ongoingScroll: newOngoingScroll())

proc editorLineHeight*(): float32 =
  ## One metric shared by rendering, scrolling, hit testing, IME placement,
  ## line numbers, Git gutter actions, diagnostics, and session persistence.
  ## Zed resolves comfortable line height as 1.618 times the buffer font and
  ## rounds it to a whole device pixel before laying out consecutive rows.
  float32(max(1.0, platformEditorLineHeight()))

proc editorLineIndex(pixels, lineHeight: float32): int =
  ## Keep exact line multiples on the intended row despite the rounding of
  ## the platform's fractional comfortable line height in float32.
  int(floor(max(0'f32, pixels) / max(1'f32, lineHeight) + 0.0001'f32))

proc reconcileScrollPosition*(view: var EditorViewState, lineHeight = editorLineHeight(),
                              maxScrollPixels = -1'f32) =
  ## Keep the continuous position compatible with old code that assigns
  ## `scrollLine` directly. A disagreement means a legacy caller changed the
  ## row anchor; retain the existing sub-line phase instead of snapping the
  ## viewport to that row boundary.
  let height = max(1'f32, lineHeight)
  let legacyFraction = max(0'f32, min(view.scrollYFraction, height - 0.001'f32))
  let legacyPixels = max(0'f32, float32(max(0, view.scrollLine)) * height +
    legacyFraction)
  if abs(view.scrollYPixels - legacyPixels) > 0.01'f32:
    view.scrollYPixels = legacyPixels
  if maxScrollPixels >= 0'f32:
    view.scrollYPixels = min(view.scrollYPixels, maxScrollPixels)
  view.scrollYPixels = max(0'f32, view.scrollYPixels)
  view.scrollLine = editorLineIndex(view.scrollYPixels, height)
  let fraction = view.scrollYPixels - float32(view.scrollLine) * height
  view.scrollYFraction = if abs(fraction) < 0.001'f32: 0'f32 else: fraction

proc setScrollYPixels*(view: var EditorViewState, pixels, lineHeight: float32,
                       maxScrollPixels = -1'f32) =
  let height = max(1'f32, lineHeight)
  view.scrollDisplayInitialized = false
  view.scrollYPixels = max(0'f32, pixels)
  if maxScrollPixels >= 0'f32:
    view.scrollYPixels = min(view.scrollYPixels, maxScrollPixels)
  view.scrollLine = editorLineIndex(view.scrollYPixels, height)
  let fraction = view.scrollYPixels - float32(view.scrollLine) * height
  view.scrollYFraction = if abs(fraction) < 0.001'f32: 0'f32 else: fraction

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

proc scrollPixelDelta*(deltaY: float32, precise: bool,
                       lineHeight = editorLineHeight(),
                       sensitivity = 1'f32): float32 =
  ## Zed's ScrollDelta::Pixels keeps the native delta in pixels. Its
  ## ScrollDelta::Lines conversion multiplies the native line count by the
  ## line height; neither path applies wheel-unit normalization.
  let effectiveLineHeight = max(1'f32, lineHeight)
  let pixels = if precise: deltaY else: deltaY * effectiveLineHeight
  result = -pixels * sensitivity

proc scrollLineDelta*(remainder: var float32, deltaY: float32,
                      precise: bool, lineHeight = editorLineHeight(),
                      sensitivity = 1'f32): int =
  ## Convert Zed's pixel or line scroll delta into whole logical lines while
  ## retaining sub-line motion for the next event.
  let effectiveLineHeight = max(1'f32, lineHeight)
  remainder += scrollPixelDelta(deltaY, precise, effectiveLineHeight,
    sensitivity) / effectiveLineHeight
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

proc cursorPositionText*(view: EditorViewState, buffer: PieceTable): string =
  ## Zed presents the caret as a one-based line:character position. The
  ## selection suffix is intentionally limited to multiple selections; a
  ## single range does not add noise to the compact status item.
  let location = buffer.lineColumn(view.cursor)
  result = $(location.line + 1) & ":" & $(location.column + 1)
  let selectionCount = view.selections.len
  if selectionCount > 1:
    result.add(" (" & $selectionCount & " selections)")

proc statusBarText*(view: EditorViewState, buffer: PieceTable): string =
  let dirty = if buffer.isDirty: " • Unsaved" else: ""
  let message = view.statusMessage.strip()
  let prefix = if message.len > 0: message & "  •  " else: ""
  prefix & view.cursorPositionText(buffer) & dirty

proc openCommandPalette*(view: var EditorViewState) = view.commandPaletteOpen = true
proc closeCommandPalette*(view: var EditorViewState) = view.commandPaletteOpen = false

proc visibleLines*(buffer: PieceTable, firstLine, count: int): seq[string] =
  let text = buffer.toString().splitLines()
  for line in firstLine ..< min(text.len, firstLine + count): result.add(text[line])
