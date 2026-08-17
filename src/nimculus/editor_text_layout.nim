import std/algorithm
import std/options
import std/strutils
import std/unicode
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
    ## Byte offset in the source line. `glyph.index` remains an offset in the
    ## rendered (possibly replacement-expanded) string used by the shaper.
    sourceIndex*: int

  RuneRange* = tuple[start, finish: Rune]

  InvisibleLine* = object
    ## Display text and the source-byte position at every display-byte
    ## boundary. The final entry is the source end boundary.
    text*: string
    sourceByteAt*: seq[int]

  ## A block is anchored in the wrapped-row coordinate space.  The placement
  ## is deliberately a variant: Replace is the only placement whose anchor
  ## is a range rather than a single row.
  BlockPlacementKind* = enum
    bpAbove, bpBelow, bpNear, bpReplace

  BlockPlacement* = object
    case kind*: BlockPlacementKind
    of bpAbove, bpBelow, bpNear:
      row*: int
    of bpReplace:
      range*: Slice[int]

  BlockStyle* = enum
    bsFixed, bsFlex, bsSpacer, bsSticky

  BlockProperties* = object
    placement*: BlockPlacement
    height*: Option[int]
    style*: BlockStyle
    priority*: int

  ## The multibuffer block kinds are part of the public shape now, although
  ## their payload is intentionally reserved for the multibuffer task.
  ExcerptBoundaryInfo* = object
    discard

  BlockKind* = enum
    bkCustom, bkSpacer, bkFoldedBuffer, bkExcerptBoundary, bkBufferHeader

  Block* = object
    id*: int
    properties*: BlockProperties
    case kind*: BlockKind
    of bkCustom:
      discard
    of bkSpacer:
      discard
    of bkFoldedBuffer, bkExcerptBoundary, bkBufferHeader:
      excerptBoundaryInfo*: ExcerptBoundaryInfo

  TransformKind* = enum
    tkIsomorphic, tkBlock

  ## A transform covers either a contiguous run of wrap rows or a run of
  ## rows belonging to one block.  Both forms retain their display start so
  ## the snapshot can be inspected without reconstructing the map.
  Transform* = object
    displayStart*: int
    wrapStart*: int
    rowCount*: int
    case kind*: TransformKind
    of tkIsomorphic:
      discard
    of tkBlock:
      blockId*: int

  BlockPointKind* = enum
    bpkWrap, bpkBlock

  BlockPoint* = object
    displayRow*: int
    wrapRow*: int
    case kind*: BlockPointKind
    of bpkWrap:
      discard
    of bpkBlock:
      blockId*: int

  BlockRow* = distinct int
  BlockRowToken* = distinct int

  BlockSnapshot* = object
    wrapRowCount*: int
    displayRowCount*: int
    transforms*: seq[Transform]
    blocks*: seq[Block]
    ## These arrays are the compact point map used by the conversion helpers.
    ## A negative wrap value is a reversible token for a block row.
    displayToWrap*: seq[int]
    displayToBlock*: seq[int]
    wrapToDisplay*: seq[int]

  EditorTextLayout* = object
    rows*: seq[VisibleTextRow]
    totalRows*: int
    widestWidth*: float32

proc sourceRow*(value: int): SourceRow = SourceRow(value)
proc foldPoint*(value: int): FoldPoint = FoldPoint(value)
proc tabPoint*(value: int): TabPoint = TabPoint(value)
proc wrapRow*(value: int): WrapRow = WrapRow(value)
proc displayRow*(value: int): DisplayRow = DisplayRow(value)
proc blockRow*(value: int): BlockRow = BlockRow(value)
proc blockRowToken*(value: int): BlockRowToken = BlockRowToken(value)

proc toInt*(value: SourceRow): int = int(value)
proc toInt*(value: FoldPoint): int = int(value)
proc toInt*(value: TabPoint): int = int(value)
proc toInt*(value: WrapRow): int = int(value)
proc toInt*(value: DisplayRow): int = int(value)
proc toInt*(value: BlockRow): int = int(value)
proc toInt*(value: BlockRowToken): int = int(value)

proc `==`*(left, right: SourceRow): bool = left.toInt == right.toInt
proc `==`*(left, right: FoldPoint): bool = left.toInt == right.toInt
proc `==`*(left, right: TabPoint): bool = left.toInt == right.toInt
proc `==`*(left, right: WrapRow): bool = left.toInt == right.toInt
proc `==`*(left, right: DisplayRow): bool = left.toInt == right.toInt
proc `==`*(left, right: BlockRow): bool = left.toInt == right.toInt

proc above*(row: int): BlockPlacement =
  BlockPlacement(kind: bpAbove, row: row)

proc below*(row: int): BlockPlacement =
  BlockPlacement(kind: bpBelow, row: row)

proc near*(row: int): BlockPlacement =
  BlockPlacement(kind: bpNear, row: row)

proc replace*(first, last: int): BlockPlacement =
  BlockPlacement(kind: bpReplace, range: first .. last)

proc initBlockProperties*(placement: BlockPlacement; height: Option[int] = none(int);
                          style = bsFixed; priority = 0): BlockProperties =
  BlockProperties(placement: placement, height: height, style: style,
    priority: priority)

proc initCustomBlock*(id: int; properties: BlockProperties): Block =
  Block(id: id, kind: bkCustom, properties: properties)

proc initSpacerBlock*(id: int; properties: BlockProperties): Block =
  Block(id: id, kind: bkSpacer, properties: properties)

proc effectiveHeight*(item: Block): int =
  if item.properties.height.isSome:
    max(0, item.properties.height.get)
  else:
    0

proc paintsGutter*(style: BlockStyle): bool = style != bsSpacer
proc paintsGutter*(item: Block): bool = item.properties.style.paintsGutter

proc blockId*(item: Block): int = item.id

proc appendIsomorphicTransform(snapshot: var BlockSnapshot;
                               displayStart, wrapStart, rowCount: int) =
  if rowCount <= 0: return
  if snapshot.transforms.len > 0:
    let previous = snapshot.transforms[^1]
    if previous.kind == tkIsomorphic and
        previous.displayStart + previous.rowCount == displayStart and
        previous.wrapStart + previous.rowCount == wrapStart:
      snapshot.transforms[^1].rowCount += rowCount
      return
  snapshot.transforms.add(Transform(kind: tkIsomorphic,
    displayStart: displayStart, wrapStart: wrapStart, rowCount: rowCount))

proc appendBlockTransform(snapshot: var BlockSnapshot;
                          displayStart, rowCount, blockId: int) =
  if rowCount <= 0: return
  snapshot.transforms.add(Transform(kind: tkBlock, displayStart: displayStart,
    wrapStart: -1, rowCount: rowCount, blockId: blockId))

proc blockSort(left, right: Block): int =
  if left.properties.priority != right.properties.priority:
    return cmp(left.properties.priority, right.properties.priority)
  cmp(left.id, right.id)

proc initBlockSnapshot*(wrapRows: int; blocks: openArray[Block]): BlockSnapshot =
  ## Build a display map from the existing wrapped rows.  Source rows are
  ## never copied or mutated; only their display intervals are transformed.
  result.wrapRowCount = max(0, wrapRows)
  result.blocks = @blocks
  result.displayToWrap = @[]
  result.displayToBlock = @[]
  result.wrapToDisplay = newSeq[int](result.wrapRowCount)
  for index in 0 ..< result.wrapToDisplay.len:
    result.wrapToDisplay[index] = -1

  var replacements: seq[int] = @[]
  var aboveAt = newSeq[seq[int]](result.wrapRowCount + 1)
  var belowAt = newSeq[seq[int]](result.wrapRowCount)
  for blockIndex, item in result.blocks:
    let placement = item.properties.placement
    case placement.kind
    of bpAbove:
      let row = max(0, min(result.wrapRowCount, placement.row))
      aboveAt[row].add(blockIndex)
    of bpBelow:
      if result.wrapRowCount > 0:
        let row = max(0, min(result.wrapRowCount - 1, placement.row))
        belowAt[row].add(blockIndex)
    of bpNear:
      let row = max(0, min(result.wrapRowCount, placement.row))
      aboveAt[row].add(blockIndex)
    of bpReplace:
      replacements.add(blockIndex)
  let blockItems = result.blocks
  for row in 0 .. result.wrapRowCount:
    aboveAt[row].sort(proc (left, right: int): int =
      blockSort(blockItems[left], blockItems[right]))
  for row in 0 ..< result.wrapRowCount:
    belowAt[row].sort(proc (left, right: int): int =
      blockSort(blockItems[left], blockItems[right]))
  replacements.sort(proc (left, right: int): int =
    let leftPlacement = blockItems[left].properties.placement.range
    let rightPlacement = blockItems[right].properties.placement.range
    if leftPlacement.a != rightPlacement.a: cmp(leftPlacement.a, rightPlacement.a)
    else: blockSort(blockItems[left], blockItems[right]))

  var replacementAt = newSeq[int](result.wrapRowCount)
  for row in 0 ..< replacementAt.len: replacementAt[row] = -1
  var replacementEnd = newSeq[int](result.wrapRowCount)
  for row in 0 ..< replacementEnd.len: replacementEnd[row] = -1
  for blockIndex in replacements:
    let item = result.blocks[blockIndex]
    let placement = item.properties.placement.range
    let first = max(0, min(result.wrapRowCount, placement.a))
    let last = max(first - 1, min(result.wrapRowCount - 1, placement.b))
    if first >= result.wrapRowCount: continue
    if replacementAt[first] != -1: continue
    replacementAt[first] = blockIndex
    replacementEnd[first] = last

  var displayRow = 0
  var wrapRow = 0
  while wrapRow < result.wrapRowCount:
    for blockIndex in aboveAt[wrapRow]:
      let height = result.blocks[blockIndex].effectiveHeight
      if height > 0:
        result.appendBlockTransform(displayRow, height,
          result.blocks[blockIndex].id)
        for offset in 0 ..< height:
          result.displayToWrap.add(-displayRow - offset - 1)
          result.displayToBlock.add(result.blocks[blockIndex].id)
        displayRow += height

    if replacementAt[wrapRow] != -1:
      let blockIndex = replacementAt[wrapRow]
      let height = result.blocks[blockIndex].effectiveHeight
      if height > 0:
        result.appendBlockTransform(displayRow, height,
          result.blocks[blockIndex].id)
        for offset in 0 ..< height:
          result.displayToWrap.add(-displayRow - offset - 1)
          result.displayToBlock.add(result.blocks[blockIndex].id)
        displayRow += height
      wrapRow = replacementEnd[wrapRow] + 1
      continue

    let startDisplay = displayRow
    result.displayToWrap.add(wrapRow)
    result.displayToBlock.add(-1)
    result.wrapToDisplay[wrapRow] = displayRow
    inc displayRow
    inc wrapRow
    if displayRow - startDisplay > 0:
      result.appendIsomorphicTransform(startDisplay, wrapRow - 1, 1)
    for blockIndex in belowAt[wrapRow - 1]:
      let height = result.blocks[blockIndex].effectiveHeight
      if height > 0:
        result.appendBlockTransform(displayRow, height,
          result.blocks[blockIndex].id)
        for offset in 0 ..< height:
          result.displayToWrap.add(-displayRow - offset - 1)
          result.displayToBlock.add(result.blocks[blockIndex].id)
        displayRow += height

  for blockIndex in aboveAt[result.wrapRowCount]:
    let height = result.blocks[blockIndex].effectiveHeight
    if height > 0:
      result.appendBlockTransform(displayRow, height, result.blocks[blockIndex].id)
      for offset in 0 ..< height:
        result.displayToWrap.add(-displayRow - offset - 1)
        result.displayToBlock.add(result.blocks[blockIndex].id)
      displayRow += height
  result.displayRowCount = displayRow

proc newBlockSnapshot*(wrapRows: int; blocks: openArray[Block]): BlockSnapshot =
  initBlockSnapshot(wrapRows, blocks)

proc blockIdAtDisplayRow*(snapshot: BlockSnapshot; row: int): Option[int] =
  if row < 0 or row >= snapshot.displayToBlock.len: return none(int)
  let id = snapshot.displayToBlock[row]
  if id < 0: none(int) else: some(id)

proc sourceLineAtDisplayRow*(snapshot: BlockSnapshot; row: int): Option[int] =
  if row < 0 or row >= snapshot.displayToWrap.len: return none(int)
  if snapshot.displayToBlock[row] >= 0: return none(int)
  some(snapshot.displayToWrap[row])

proc blockPointAtDisplayRow*(snapshot: BlockSnapshot; row: int): BlockPoint =
  if row < 0 or row >= snapshot.displayToWrap.len:
    return BlockPoint(kind: bpkWrap, displayRow: row, wrapRow: -1)
  let wrap = snapshot.displayToWrap[row]
  let id = snapshot.displayToBlock[row]
  if id >= 0:
    BlockPoint(kind: bpkBlock, displayRow: row, wrapRow: -wrap - 1,
      blockId: id)
  else:
    BlockPoint(kind: bpkWrap, displayRow: row, wrapRow: wrap)

proc wrapRowToBlockPoint*(snapshot: BlockSnapshot; row: int): BlockPoint =
  if row < 0 or row >= snapshot.wrapToDisplay.len:
    return BlockPoint(kind: bpkWrap, displayRow: -1, wrapRow: row)
  BlockPoint(kind: bpkWrap, displayRow: snapshot.wrapToDisplay[row], wrapRow: row)

proc blockRowToWrapRow*(snapshot: BlockSnapshot; row: int): BlockRowToken =
  ## Integer form is a reversible point token.  Text rows carry their wrap
  ## row; block rows carry a negative token so every display row round-trips.
  if row < 0 or row >= snapshot.displayToWrap.len: return blockRowToken(-1)
  blockRowToken(snapshot.displayToWrap[row])

proc wrapRowToBlockPoint*(snapshot: BlockSnapshot; token: BlockRowToken): int =
  ## Inverse of the integer point-token form above.
  let value = token.toInt
  if value < 0:
    return -value - 1
  if value >= 0 and value < snapshot.wrapToDisplay.len:
    return snapshot.wrapToDisplay[value]
  -1

proc blockRowToWrapRow*(snapshot: BlockSnapshot; row: BlockRow): WrapRow =
  wrapRow(snapshot.blockRowToWrapRow(row.toInt).toInt)

proc wrapRowToBlockPoint*(snapshot: BlockSnapshot; row: WrapRow): BlockPoint =
  snapshot.wrapRowToBlockPoint(row.toInt)

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

const FORMAT*: array[21, RuneRange] = [
  (Rune(0xad), Rune(0xad)),
  (Rune(0x600), Rune(0x605)),
  (Rune(0x61c), Rune(0x61c)),
  (Rune(0x6dd), Rune(0x6dd)),
  (Rune(0x70f), Rune(0x70f)),
  (Rune(0x890), Rune(0x891)),
  (Rune(0x8e2), Rune(0x8e2)),
  (Rune(0x180e), Rune(0x180e)),
  (Rune(0x200b), Rune(0x200f)),
  (Rune(0x202a), Rune(0x202e)),
  (Rune(0x2060), Rune(0x2064)),
  (Rune(0x2066), Rune(0x206f)),
  (Rune(0xfeff), Rune(0xfeff)),
  (Rune(0xfff9), Rune(0xfffb)),
  (Rune(0x110bd), Rune(0x110bd)),
  (Rune(0x110cd), Rune(0x110cd)),
  (Rune(0x13430), Rune(0x1343f)),
  (Rune(0x1bca0), Rune(0x1bca3)),
  (Rune(0x1d173), Rune(0x1d17a)),
  (Rune(0xe0001), Rune(0xe0001)),
  (Rune(0xe0020), Rune(0xe007f))]

const OTHER*: array[10, RuneRange] = [
  (Rune(0x34f), Rune(0x34f)),
  (Rune(0x115f), Rune(0x1160)),
  (Rune(0x17b4), Rune(0x17b5)),
  (Rune(0x180b), Rune(0x180d)),
  (Rune(0x2800), Rune(0x2800)),
  (Rune(0x3164), Rune(0x3164)),
  (Rune(0xfe00), Rune(0xfe0d)),
  (Rune(0xffa0), Rune(0xffa0)),
  (Rune(0xfffc), Rune(0xfffc)),
  (Rune(0xe0100), Rune(0xe01ef))]

const PRESERVE*: array[6, RuneRange] = [
  (Rune(0x34f), Rune(0x34f)),
  (Rune(0x200d), Rune(0x200d)),
  (Rune(0x17b4), Rune(0x17b5)),
  (Rune(0x180b), Rune(0x180d)),
  (Rune(0xe0061), Rune(0xe007a)),
  (Rune(0xe007f), Rune(0xe007f))]

proc inRuneRanges(rune: Rune; ranges: openArray[RuneRange]): bool =
  for item in ranges:
    if int(item.start) <= int(rune) and int(rune) <= int(item.finish):
      return true
  false

proc isInvisible*(rune: Rune): bool =
  if int(rune) <= 0x1f:
    return rune != Rune('\t') and rune != Rune('\n') and rune != Rune('\r')
  if int(rune) >= 0x7f:
    return int(rune) <= 0x9f or
      (isWhiteSpace(rune) and rune != Rune(0x3000)) or
      inRuneRanges(rune, FORMAT) or inRuneRanges(rune, OTHER)
  false

proc replacement*(rune: Rune): string =
  if int(rune) <= 0x1f:
    const c0Symbols = [
      "␀", "␁", "␂", "␃", "␄", "␅", "␆", "␇", "␈", "␉", "␊", "␋", "␌",
      "␍", "␎", "␏",
      "␐", "␑", "␒", "␓", "␔", "␕", "␖", "␗", "␘", "␙", "␚", "␛", "␜",
      "␝", "␞", "␟"]
    return c0Symbols[int(rune)]
  if rune == Rune(0x7f): return "␡"
  if inRuneRanges(rune, PRESERVE): return ""
  if isInvisible(rune): return " "
  ""

proc renderInvisibleText*(text: string; sourceStartByte = 0): InvisibleLine =
  result.sourceByteAt.add(sourceStartByte)
  var sourceOffset = 0
  for rune in text.runes:
    let sourceRune = rune.toUTF8
    let replacementText = if isInvisible(rune): replacement(rune) else: ""
    let rendered = if replacementText.len > 0: replacementText else: sourceRune
    result.text.add(rendered)
    for index in 0 ..< rendered.len:
      let boundary = if index + 1 == rendered.len:
        sourceStartByte + sourceOffset + sourceRune.len
      else:
        sourceStartByte + sourceOffset
      result.sourceByteAt.add(boundary)
    sourceOffset += sourceRune.len

proc fontRunsForLine(lineStart, sourceTextLength: int; rendered: InvisibleLine;
                     decorations: openArray[TextDecoration];
                     decorationIndex: var int): seq[FontRun] =
  ## This is the app-side equivalent of Zed's `LineWithInvisibles::from_chunks`:
  ## consume the already ordered, non-overlapping highlight chunks once and
  ## extend the previous run when its font identity is unchanged. The syntax
  ## producer supplies chunks in document order, so this path deliberately
  ## does not collect, sort, deduplicate, or rescan boundaries.
  if sourceTextLength == 0: return @[FontRun(len: 0, fontId: 0)]
  let lineEnd = lineStart + sourceTextLength
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
  var displayOffset = 0
  while displayOffset < rendered.text.len:
    let sourceOffset = rendered.sourceByteAt[displayOffset]
    while scanIndex < decorations.len and decorations[scanIndex].endByte <= sourceOffset:
      inc scanIndex
    let fontId = if scanIndex < decorations.len and
        decorations[scanIndex].startByte <= sourceOffset and
        sourceOffset < decorations[scanIndex].endByte:
      uint32(max(0, decorations[scanIndex].kind + 1))
    else:
      0'u32
    let runeLength = rendered.text[displayOffset .. ^1].runeAt(0).toUTF8.len
    appendRun(runeLength, fontId)
    displayOffset += runeLength
  while scanIndex < decorations.len and decorations[scanIndex].endByte <= lineEnd:
    inc scanIndex
  decorationIndex = scanIndex

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
                    sourceStart, sourceTextLength: int; rendered: InvisibleLine;
                    wrapped: ref WrappedLineLayout;
                    decorations: openArray[TextDecoration]) =
  var displayStarts = @[0]
  for boundary in wrapped.wrapBoundaries:
    displayStarts.add(glyphByteAt(wrapped.unwrappedLayout[], boundary.runIx, boundary.glyphIx))
  displayStarts.sort()
  var uniqueDisplayStarts: seq[int]
  for value in displayStarts:
    if uniqueDisplayStarts.len == 0 or uniqueDisplayStarts[^1] != value:
      uniqueDisplayStarts.add(value)
  uniqueDisplayStarts.add(rendered.text.len)
  for rowIndex in 0 ..< max(1, uniqueDisplayStarts.len - 1):
    let displayStart = max(0, min(rendered.text.len, uniqueDisplayStarts[rowIndex]))
    let displayFinish = max(displayStart,
      min(rendered.text.len, uniqueDisplayStarts[rowIndex + 1]))
    let sourceStartOffset = rendered.sourceByteAt[displayStart] - sourceStart
    let sourceFinishOffset = rendered.sourceByteAt[displayFinish] - sourceStart
    let lineStartX = xAt(wrapped.unwrappedLayout[], displayStart)
    var row = VisibleTextRow(sourceLine: sourceLine, displayRow: displayBase + rowIndex,
      sourceStartByte: sourceStart, segmentStartByte: sourceStart + sourceStartOffset,
      segmentEndByte: sourceStart + sourceFinishOffset, layout: wrapped.unwrappedLayout)
    for shapedRun in wrapped.unwrappedLayout[].runs:
      for glyph in shapedRun.glyphs:
        if glyph.index >= displayStart and glyph.index < displayFinish:
          var positioned = glyph
          positioned.position.x = px(float32(glyph.position.x) - lineStartX)
          positioned.position.y = px(0)
          row.glyphs.add(VisibleGlyph(glyph: positioned, fontId: shapedRun.fontId,
            sourceIndex: rendered.sourceByteAt[glyph.index] - sourceStart))
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
    let sourceText = lineText(buffer, sourceLine)
    let sourceTextLength = sourceText.len
    let rendered = renderInvisibleText(sourceText, sourceStart)
    let textHash = rendered.text.textHash
    let runs = fontRunsForLine(sourceStart, sourceTextLength, rendered,
      decorations, decorationIndex)
    let wrapped = cache.layoutWrappedLineByHash(textHash, rendered.text.len, fontSize, runs,
      wrapWidth, proc(): string = rendered.text, wrap)
    let rowsBefore = result.rows.len
    addWrappedRows(result, sourceLine, displayRow, sourceStart, sourceTextLength,
      rendered, wrapped, decorations)
    let count = wrappedRowCount(wrapped[])
    displayRow += count
    result.totalRows += count
    if result.rows.len == rowsBefore and sourceTextLength == 0:
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
    let sourceStart = buffer.lineStarts[sourceLine]
    let sourceText = lineText(buffer, sourceLine)
    let rendered = renderInvisibleText(sourceText, sourceStart)
    let runs = fontRunsForLine(sourceStart, sourceText.len, rendered,
      decorations, decorationIndex)
    let layout = cache.layoutWrappedLineByHash(rendered.text.textHash,
      rendered.text.len, fontSize, runs, wrapWidth,
      proc(): string = rendered.text, wrap)
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
    let sourceStart = buffer.lineStarts[sourceLine]
    let sourceText = lineText(buffer, sourceLine)
    let rendered = renderInvisibleText(sourceText, sourceStart)
    let runs = fontRunsForLine(sourceStart, sourceText.len, rendered,
      decorations, decorationIndex)
    let layout = cache.layoutWrappedLineByHash(rendered.text.textHash,
      rendered.text.len, fontSize, runs, wrapWidth,
      proc(): string = rendered.text, wrap)
    let count = wrappedRowCount(layout[])
    if row < count: return sourceLine
    row -= count
  max(0, buffer.lineStarts.high)
