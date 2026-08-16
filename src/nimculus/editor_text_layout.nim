import std/algorithm
import std/strutils
import nimculus/editor_buffer
import nimculus/syntax
import nimnui/text
import nimnui/geometry

type
  ## Coordinate domains used by the display-map layers.  These are deliberately
  ## distinct even though each one is represented by an integer at runtime.
  SourceRow* = distinct int
  FoldPoint* = distinct int
  TabPoint* = distinct int
  WrapRow* = distinct int
  DisplayRow* = distinct int

  ## The display-map edit type is separate from editor_buffer.Edit.  The latter
  ## describes byte edits in the piece table; this type describes edits between
  ## coordinate domains and is therefore generic over its coordinate type.
  Edit[T] = object
    start*, finish*: T
    text*: string

  TabEdit*[T] = Edit[T]

  ## The first-stage implementation has no fold map yet.  FoldSnapshot is the
  ## stable boundary that the tab map consumes, and can be populated directly
  ## by the future fold layer.
  FoldSnapshot* = object
    text*: string
    lines*: seq[string]
    version*: uint64

  TabLineSnapshot = object
    foldToTab: seq[int]
    tabToFold: seq[int]
    expandedText: string

  TabSnapshot* = object
    tabSize*: int
    maxExpansionColumn*: int
    lines*: seq[TabLineSnapshot]
    foldToTab: seq[int]
    tabToFold: seq[int]
    version*: uint64

  TabMap* = object
    tabSize*: int
    maxExpansionColumn*: int
    snapshot*: TabSnapshot

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

proc sourceRow*(value: int): SourceRow = SourceRow(value)
proc foldPoint*(value: int): FoldPoint = FoldPoint(value)
proc tabPoint*(value: int): TabPoint = TabPoint(value)
proc wrapRow*(value: int): WrapRow = WrapRow(value)
proc displayRow*(value: int): DisplayRow = DisplayRow(value)

proc toInt*(value: SourceRow): int = int(value)
proc toInt*(value: FoldPoint): int = int(value)
proc toInt*(value: TabPoint): int = int(value)
proc toInt*(value: WrapRow): int = int(value)
proc toInt*(value: DisplayRow): int = int(value)

proc `==`*(left, right: SourceRow): bool = left.toInt == right.toInt
proc `==`*(left, right: FoldPoint): bool = left.toInt == right.toInt
proc `==`*(left, right: TabPoint): bool = left.toInt == right.toInt
proc `==`*(left, right: WrapRow): bool = left.toInt == right.toInt
proc `==`*(left, right: DisplayRow): bool = left.toInt == right.toInt

proc initFoldSnapshot*(text: string; version = 0'u64): FoldSnapshot =
  result.text = text
  result.lines = text.split('\n')
  result.version = version

proc initFoldSnapshot*(lines: seq[string]; version = 0'u64): FoldSnapshot =
  result.lines = lines
  result.text = lines.join("\n")
  result.version = version

proc snapshotText(fold: FoldSnapshot): string =
  if fold.text.len > 0 or fold.lines.len == 0: fold.text
  else: fold.lines.join("\n")

proc normalizedTabSize(tabSize: int): int = max(1, tabSize)
proc normalizedMaxExpansionColumn(maxExpansionColumn: int): int =
  max(0, maxExpansionColumn)

proc expandedTabWidth(column, tabSize, maxExpansionColumn: int): int =
  if column >= maxExpansionColumn: return 1
  let width = tabSize - (column mod tabSize)
  min(width, maxExpansionColumn - column)

proc buildTabSnapshot(tabSize, maxExpansionColumn: int; text: string;
                      version: uint64): TabSnapshot =
  result.tabSize = normalizedTabSize(tabSize)
  result.maxExpansionColumn = normalizedMaxExpansionColumn(maxExpansionColumn)
  result.version = version
  result.foldToTab = @[0]
  result.tabToFold = @[0]
  var documentColumn = 0
  var lineColumn = 0
  var lineSourceOffset = 0
  var line = TabLineSnapshot(foldToTab: @[0], tabToFold: @[0])
  for sourceOffset in 0 ..< text.len:
    let character = text[sourceOffset]
    let width = if character == '\t':
      expandedTabWidth(lineColumn, result.tabSize, result.maxExpansionColumn)
    else: 1
    if character == '\n':
      line.expandedText.add(character)
    elif character == '\t' and lineColumn - width < result.maxExpansionColumn:
      line.expandedText.add(repeat(' ', width))
    else:
      line.expandedText.add(character)

    lineColumn += width
    documentColumn += width
    line.foldToTab.add(lineColumn)
    for tabOffset in line.tabToFold.len ..< lineColumn:
      line.tabToFold.add(lineSourceOffset)
    line.tabToFold.add(lineSourceOffset + 1)
    result.foldToTab.add(documentColumn)
    for tabOffset in (result.tabToFold.len) ..< documentColumn:
      result.tabToFold.add(sourceOffset)
    result.tabToFold.add(sourceOffset + 1)

    if character == '\n':
      result.lines.add(line)
      line = TabLineSnapshot(foldToTab: @[0], tabToFold: @[0])
      lineColumn = 0
      lineSourceOffset = 0
    else:
      inc lineSourceOffset
  result.lines.add(line)

  ## foldToTab/tabToFold above are document-linear maps.  A newline is one
  ## document position and its tab coordinate is also one position; tab stops
  ## restart in the next line's line-local map.
  if result.foldToTab.len != text.len + 1:
    result.foldToTab.setLen(text.len + 1)
  if result.tabToFold.len == 0:
    result.tabToFold = @[0]

proc initTabMap*(tabSize = 4; maxExpansionColumn = 256): TabMap =
  result.tabSize = normalizedTabSize(tabSize)
  result.maxExpansionColumn = normalizedMaxExpansionColumn(maxExpansionColumn)

proc initTabSnapshot*(fold: FoldSnapshot; tabSize = 4;
                      maxExpansionColumn = 256): TabSnapshot =
  buildTabSnapshot(tabSize, maxExpansionColumn, snapshotText(fold), fold.version)

proc expandedColumns*(line: string; tabSize = 4;
                      maxExpansionColumn = 256): seq[int] =
  ## Column at every source-text boundary, including the initial boundary.
  let size = normalizedTabSize(tabSize)
  let limit = normalizedMaxExpansionColumn(maxExpansionColumn)
  result = @[0]
  var column = 0
  for sourceOffset in 0 ..< line.len:
    let character = line[sourceOffset]
    let width = if character == '\t': expandedTabWidth(column, size, limit) else: 1
    column += width
    result.add(column)

proc expandedColumns*(snapshot: TabSnapshot; line: SourceRow): seq[int] =
  let index = line.toInt
  if index < 0 or index >= snapshot.lines.len: return @[0]
  snapshot.lines[index].foldToTab

proc expandedLength*(line: string; tabSize = 4;
                     maxExpansionColumn = 256): int =
  expandedColumns(line, tabSize, maxExpansionColumn)[^1]

proc expandedLength*(snapshot: TabSnapshot; line: SourceRow): int =
  snapshot.expandedColumns(line)[^1]

proc expandTabs*(line: string; tabSize = 4;
                 maxExpansionColumn = 256): string =
  let size = normalizedTabSize(tabSize)
  let limit = normalizedMaxExpansionColumn(maxExpansionColumn)
  var column = 0
  for sourceOffset in 0 ..< line.len:
    let character = line[sourceOffset]
    let width = if character == '\t': expandedTabWidth(column, size, limit) else: 1
    if character == '\t' and column < limit:
      result.add(repeat(' ', width))
    else:
      result.add(character)
    column += width

proc expandTabs*(snapshot: TabSnapshot; line: SourceRow): string =
  let index = line.toInt
  if index < 0 or index >= snapshot.lines.len: return ""
  snapshot.lines[index].expandedText

proc lineLocalColumns(snapshot: TabSnapshot; line: SourceRow): seq[int] =
  let index = line.toInt
  if index < 0 or index >= snapshot.lines.len: return @[0]
  snapshot.lines[index].foldToTab

proc foldPointToTabPoint*(snapshot: TabSnapshot; point: FoldPoint): TabPoint =
  let offset = max(0, min(point.toInt, snapshot.foldToTab.high))
  tabPoint(snapshot.foldToTab[offset])

proc tabPointToFoldPoint*(snapshot: TabSnapshot; point: TabPoint): FoldPoint =
  if snapshot.tabToFold.len == 0: return foldPoint(0)
  let offset = max(0, min(point.toInt, snapshot.tabToFold.high))
  foldPoint(snapshot.tabToFold[offset])

proc foldPointToTabPoint*(snapshot: TabSnapshot; line: SourceRow;
                         point: FoldPoint): TabPoint =
  let columns = snapshot.lineLocalColumns(line)
  let offset = max(0, min(point.toInt, columns.high))
  tabPoint(columns[offset])

proc tabPointToFoldPoint*(snapshot: TabSnapshot; line: SourceRow;
                         point: TabPoint): FoldPoint =
  let columns = snapshot.lineLocalColumns(line)
  if columns.len == 0: return foldPoint(0)
  var best = 0
  for index, column in columns:
    if column <= point.toInt: best = index
    else: break
  foldPoint(best)

proc foldPointToTabPoint*(map: TabMap; point: FoldPoint): TabPoint =
  map.snapshot.foldPointToTabPoint(point)

proc tabPointToFoldPoint*(map: TabMap; point: TabPoint): FoldPoint =
  map.snapshot.tabPointToFoldPoint(point)

proc sync*(map: var TabMap; fold: FoldSnapshot;
           foldEdits: seq[Edit[FoldPoint]]):
           (TabSnapshot, seq[Edit[TabPoint]]) =
  let next = buildTabSnapshot(map.tabSize, map.maxExpansionColumn,
    snapshotText(fold), fold.version)
  for edit in foldEdits:
    let start = next.foldPointToTabPoint(edit.start)
    let finish = next.foldPointToTabPoint(edit.finish)
    result[1].add(Edit[TabPoint](start: start, finish: finish, text: edit.text))
  map.snapshot = next
  result[0] = next

proc inlineBlameStartX*(lineEnd, emWidth, spaceWidth: float32; padding, minColumn: int;
                        scrollX = 0'f32): float32 =
  ## Both candidates are measured before scrolling; apply the viewport offset
  ## once at the final text-rendering boundary.
  let paddedLineEnd = lineEnd + float32(max(0, padding)) * max(0'f32, emWidth)
  let minStart = float32(max(0, minColumn)) * max(0'f32, spaceWidth)
  max(paddedLineEnd, minStart) - max(0'f32, scrollX)

proc lineTextBounds(buffer: PieceTable; line: int): tuple[start, length: int] =
  if buffer.lineStarts.len == 0: return
  let sourceLine = max(0, min(line, buffer.lineStarts.high))
  result.start = buffer.lineStarts[sourceLine]
  result.length = max(0, buffer.lineEndByteOffset(sourceLine) - result.start)

proc lineText(buffer: PieceTable; line: int): string =
  let bounds = buffer.lineTextBounds(line)
  buffer.substring(bounds.start, bounds.start + bounds.length)

proc fontRunsForLine(lineStart, textLength: int;
                     decorations: openArray[TextDecoration];
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

  template appendRun(runLength: int; runFontId: uint32) =
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

proc decorationKindAt*(byteOffset: int; decorations: openArray[TextDecoration]): int =
  for decoration in decorations:
    if byteOffset >= decoration.startByte and byteOffset < decoration.endByte:
      return decoration.kind
  -1

proc glyphByteAt(layout: LineLayout; runIx, glyphIx: int): int =
  if runIx < 0 or runIx >= layout.runs.len: return layout.len
  if glyphIx < 0 or glyphIx >= layout.runs[runIx].glyphs.len: return layout.len
  layout.runs[runIx].glyphs[glyphIx].index

proc xAt(layout: LineLayout; byteOffset: int): float32 =
  for run in layout.runs:
    for glyph in run.glyphs:
      if glyph.index >= byteOffset: return float32(glyph.position.x)
  float32(layout.width)

proc addWrappedRows(result: var EditorTextLayout; sourceLine, displayBase,
                    sourceStart, textLength: int; wrapped: ref WrappedLineLayout;
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

proc buildVisibleEditorLayout*(buffer: PieceTable; firstLine, visibleRows: int;
                               wrap: bool; wrapWidth: float32; fontSize: Pixels;
                               cache: LineLayoutCache;
                               decorations: openArray[TextDecoration];
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

proc displayRowsBeforeLine*(buffer: PieceTable; lineLimit: int; wrap: bool;
                            wrapWidth: float32; fontSize: Pixels;
                            cache: LineLayoutCache;
                            decorations: openArray[TextDecoration];
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

proc displayRowCount*(buffer: PieceTable; wrap: bool; wrapWidth: float32;
                      fontSize: Pixels; cache: LineLayoutCache;
                      decorations: openArray[TextDecoration];
                      folds: openArray[FoldRange]): int =
  displayRowsBeforeLine(buffer, buffer.lineStarts.len, wrap, wrapWidth, fontSize,
    cache, decorations, folds)

proc sourceLineForDisplayRow*(buffer: PieceTable; displayRow: int; wrap: bool;
                             wrapWidth: float32; fontSize: Pixels;
                             cache: LineLayoutCache;
                             decorations: openArray[TextDecoration];
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
