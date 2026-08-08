import std/algorithm
import nimculus/editor_buffer
import nimculus/syntax
import nimnui/text
import nimnui/geometry

type
  TextDecoration* = object
    startByte*, endByte*: int
    kind*: int

  VisibleTextRow* = object
    sourceLine*, displayRow*: int
    sourceStartByte*, segmentStartByte*, segmentEndByte*: int
    layout*: ref LineLayout
    glyphs*: seq[VisibleGlyph]

  VisibleGlyph* = object
    glyph*: ShapedGlyph
    fontId*: uint32

  EditorTextLayout* = object
    rows*: seq[VisibleTextRow]
    totalRows*: int
    widestWidth*: float32

proc lineTextBounds(buffer: PieceTable, line: int): tuple[start, length: int] =
  if buffer.lineStarts.len == 0: return
  let sourceLine = max(0, min(line, buffer.lineStarts.high))
  result.start = buffer.lineStarts[sourceLine]
  result.length = max(0, buffer.lineEndByteOffset(sourceLine) - result.start)

proc lineText(buffer: PieceTable, line: int): string =
  let bounds = buffer.lineTextBounds(line)
  buffer.substring(bounds.start, bounds.start + bounds.length)

proc fontRunsForLine(lineStart, textLength: int,
                     decorations: openArray[TextDecoration],
                     decorationIndex: var int): seq[FontRun] =
  ## This is the app-side equivalent of Zed's `LineWithInvisibles::from_chunks`:
  ## consume the already ordered, non-overlapping highlight chunks once and
  ## extend the previous run when its font identity is unchanged. The syntax
  ## producer supplies chunks in document order, so this path deliberately
  ## does not collect, sort, deduplicate, or rescan boundaries.
  if textLength == 0: return @[FontRun(len: 0, fontId: 0)]
  var cursor = 0
  let lineEnd = lineStart + textLength
  while decorationIndex < decorations.len and
      decorations[decorationIndex].endByte <= lineStart:
    inc decorationIndex

  template appendRun(runLength: int, runFontId: uint32) =
    if runLength <= 0: return
    if result.len > 0 and result[^1].fontId == runFontId:
      result[^1].len += runLength
    else:
      result.add(FontRun(len: runLength, fontId: runFontId))

  var scanIndex = decorationIndex
  while scanIndex < decorations.len:
    let decoration = decorations[scanIndex]
    let start = max(0, decoration.startByte - lineStart)
    let finish = min(textLength, decoration.endByte - lineStart)
    if decoration.startByte >= lineEnd: break
    if finish <= start or finish <= cursor:
      inc scanIndex
      continue
    if start > cursor: appendRun(start - cursor, 0)
    let runStart = max(start, cursor)
    appendRun(finish - runStart, uint32(max(0, decoration.kind + 1)))
    cursor = finish
    if decoration.endByte >= lineEnd: break
    inc scanIndex
    if cursor >= textLength: break
  decorationIndex = scanIndex
  if cursor < textLength: appendRun(textLength - cursor, 0)

proc decorationKindAt*(byteOffset: int, decorations: openArray[TextDecoration]): int =
  for decoration in decorations:
    if byteOffset >= decoration.startByte and byteOffset < decoration.endByte:
      return decoration.kind
  -1

proc glyphByteAt(layout: LineLayout, runIx, glyphIx: int): int =
  if runIx < 0 or runIx >= layout.runs.len: return layout.len
  if glyphIx < 0 or glyphIx >= layout.runs[runIx].glyphs.len: return layout.len
  layout.runs[runIx].glyphs[glyphIx].index

proc xAt(layout: LineLayout, byteOffset: int): float32 =
  for run in layout.runs:
    for glyph in run.glyphs:
      if glyph.index >= byteOffset: return float32(glyph.position.x)
  float32(layout.width)

proc addWrappedRows(result: var EditorTextLayout, sourceLine, displayBase,
                    sourceStart, textLength: int, wrapped: ref WrappedLineLayout,
                    decorations: openArray[TextDecoration]) =
  var starts = @[0]
  for boundary in wrapped.wrapBoundaries:
    starts.add(glyphByteAt(wrapped.unwrappedLayout[], boundary.runIx, boundary.glyphIx))
  starts.sort()
  var unique: seq[int]
  for value in starts:
    if unique.len == 0 or unique[^1] != value: unique.add(value)
  unique.add(textLength)
  for rowIndex in 0 ..< max(1, unique.len - 1):
    let start = max(0, min(textLength, unique[rowIndex]))
    let finish = max(start, min(textLength, unique[rowIndex + 1]))
    let lineStartX = xAt(wrapped.unwrappedLayout[], start)
    var row = VisibleTextRow(sourceLine: sourceLine, displayRow: displayBase + rowIndex,
      sourceStartByte: sourceStart, segmentStartByte: sourceStart + start,
      segmentEndByte: sourceStart + finish, layout: wrapped.unwrappedLayout)
    for shapedRun in wrapped.unwrappedLayout[].runs:
      for glyph in shapedRun.glyphs:
        if glyph.index >= start and glyph.index < finish:
          var positioned = glyph
          positioned.position.x = px(float32(glyph.position.x) - lineStartX)
          positioned.position.y = px(0)
          row.glyphs.add(VisibleGlyph(glyph: positioned, fontId: shapedRun.fontId))
          result.widestWidth = max(result.widestWidth,
            float32(positioned.position.x) + 1'f32)
    result.rows.add(row)

proc buildVisibleEditorLayout*(buffer: PieceTable, firstLine, visibleRows: int,
                               wrap: bool, wrapWidth: float32, fontSize: Pixels,
                               cache: LineLayoutCache,
                               decorations: openArray[TextDecoration],
                               folds: openArray[FoldRange]): EditorTextLayout =
  ## Zed's `layout_lines(rows)`/`LineWithInvisibles::from_chunks` boundary:
  ## consume only the requested display-row window and keep each decoration
  ## local to its source line. No joined document string is formed.
  if buffer.lineStarts.len == 0 or cache == nil: return
  var sourceLine = max(0, min(firstLine, buffer.lineStarts.high))
  var displayRow = 0
  var decorationIndex = 0
  let rowLimit = max(1, visibleRows) + 1
  while sourceLine < buffer.lineStarts.len and result.rows.len < rowLimit:
    var hidden = false
    for fold in folds:
      let foldStart = buffer.lineColumn(int(fold.startByte)).line
      let foldEnd = buffer.lineColumn(max(0, int(fold.endByte) - 1)).line
      if sourceLine > foldStart and sourceLine <= foldEnd:
        hidden = true
        break
    if hidden:
      inc sourceLine
      continue
    let sourceStart = buffer.lineStarts[sourceLine]
    let textLength = buffer.lineTextBounds(sourceLine).length
    let textHash = buffer.lineHash(sourceLine)
    let runs = fontRunsForLine(sourceStart, textLength, decorations, decorationIndex)
    let wrapped = cache.layoutWrappedLineByHash(textHash, textLength, fontSize, runs,
      wrapWidth, proc(): string = lineText(buffer, sourceLine), wrap)
    let rowsBefore = result.rows.len
    addWrappedRows(result, sourceLine, displayRow, sourceStart, textLength, wrapped, decorations)
    let count = wrappedRowCount(wrapped[])
    displayRow += count
    result.totalRows += count
    if result.rows.len == rowsBefore and textLength == 0:
      result.totalRows += 1
    inc sourceLine
  result

proc displayRowsBeforeLine*(buffer: PieceTable, lineLimit: int, wrap: bool,
                            wrapWidth: float32, fontSize: Pixels,
                            cache: LineLayoutCache,
                            decorations: openArray[TextDecoration],
                            folds: openArray[FoldRange]): int =
  ## The display-row answer is produced by the same WrappedLineLayout cache
  ## used by painting. There is no platform-side row-count path.
  let limit = max(0, min(lineLimit, buffer.lineStarts.len))
  var decorationIndex = 0
  for sourceLine in 0 ..< limit:
    var hidden = false
    for fold in folds:
      let foldStart = buffer.lineColumn(int(fold.startByte)).line
      let foldEnd = buffer.lineColumn(max(0, int(fold.endByte) - 1)).line
      if sourceLine > foldStart and sourceLine <= foldEnd:
        hidden = true
        break
    if hidden: continue
    let textLength = buffer.lineTextBounds(sourceLine).length
    let textHash = buffer.lineHash(sourceLine)
    let runs = fontRunsForLine(buffer.lineStarts[sourceLine], textLength, decorations,
      decorationIndex)
    let layout = cache.layoutWrappedLineByHash(textHash, textLength, fontSize, runs,
      wrapWidth, proc(): string = lineText(buffer, sourceLine), wrap)
    result += wrappedRowCount(layout[])

proc displayRowCount*(buffer: PieceTable, wrap: bool, wrapWidth: float32,
                      fontSize: Pixels, cache: LineLayoutCache,
                      decorations: openArray[TextDecoration],
                      folds: openArray[FoldRange]): int =
  displayRowsBeforeLine(buffer, buffer.lineStarts.len, wrap, wrapWidth, fontSize,
    cache, decorations, folds)

proc sourceLineForDisplayRow*(buffer: PieceTable, displayRow: int, wrap: bool,
                             wrapWidth: float32, fontSize: Pixels,
                             cache: LineLayoutCache,
                             decorations: openArray[TextDecoration],
                             folds: openArray[FoldRange]): int =
  var row = max(0, displayRow)
  var decorationIndex = 0
  for sourceLine in 0 ..< buffer.lineStarts.len:
    var hidden = false
    for fold in folds:
      let foldStart = buffer.lineColumn(int(fold.startByte)).line
      let foldEnd = buffer.lineColumn(max(0, int(fold.endByte) - 1)).line
      if sourceLine > foldStart and sourceLine <= foldEnd:
        hidden = true
        break
    if hidden: continue
    let textLength = buffer.lineTextBounds(sourceLine).length
    let textHash = buffer.lineHash(sourceLine)
    let runs = fontRunsForLine(buffer.lineStarts[sourceLine], textLength, decorations,
      decorationIndex)
    let layout = cache.layoutWrappedLineByHash(textHash, textLength, fontSize, runs,
      wrapWidth, proc(): string = lineText(buffer, sourceLine), wrap)
    let count = wrappedRowCount(layout[])
    if row < count: return sourceLine
    row -= count
  max(0, buffer.lineStarts.high)
