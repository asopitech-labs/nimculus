import std/algorithm
import std/monotimes
import std/sequtils
import std/tables
import std/times
import std/unicode
import nimnui/text

type
  PieceSource* = enum original, add
  Piece* = object
    source*: PieceSource
    start*, length*: int
  Edit* = object
    startByte*, endByte*: int
    text*: string
  Selection* = object
    anchor*, active*: int
  EditRecord = object
    beforeStartByte, afterStartByte: int
    before*, after*: string
  EditTransaction = object
    records*: seq[EditRecord]
    beforeContentVersion, afterContentVersion: uint64
    selectionsBefore, selectionsAfter: seq[Selection]
    lastEditAt: MonoTime
  PieceTable* = object
    original*, additions*: string
    pieces*: seq[Piece]
    lineStarts*: seq[int]
    undoStack*, redoStack*: seq[EditTransaction]
    undoSelections*, redoSelections*: seq[Selection]
    savedVersion*, version*: uint64
    savedContentVersion, contentVersion, nextContentVersion: uint64
    lastEditAt: MonoTime
    canGroupUndo: bool
  Excerpt* = object
    ## Source ranges use Nim's inclusive Slice representation. The aggregate
    ## offset space treats the end as `b + 1`, so context length is
    ## `max(0, b - a + 1)`.
    bufferId*: int
    context*, primary*: Slice[int]
  BufferOffset* = tuple[bufferId, offset: int]
  MultiBuffer* = ref object
    buffers*: Table[int, PieceTable]
    excerpts*: seq[Excerpt]
    ## Prefix boundaries are [0, context length, ... total length]. This
    ## first-stage port intentionally uses a rebuilt seq instead of Zed's
    ## SumTree; the linear excerpt list is the accepted singleton substitute.
    prefix*: seq[int]
    singleton*: bool
    editCount*: int
    nonTextStateUpdateCount*: int
    trailingExcerptUpdateCount*: int
  MultiBufferSnapshot* = object
    editCount*, nonTextStateUpdateCount*, trailingExcerptUpdateCount*: int
    ## Snapshot owns a value copy of the excerpt sequence, so later aggregate
    ## edits or appends cannot mutate the snapshot's address space.
    excerpts*: seq[Excerpt]
    prefix*: seq[int]
    singleton*: bool

proc rebuildIndex*(table: var PieceTable)

proc initPieceTable*(text = ""): PieceTable =
  if validateUtf8(text) >= 0:
    raise newException(ValueError, "PieceTable requires valid UTF-8")
  result.original = text
  if text.len > 0: result.pieces.add(Piece(source: original, start: 0, length: text.len))
  result.lineStarts = @[0]
  result.rebuildIndex()

proc sourceText(table: PieceTable, piece: Piece): string =
  let source = if piece.source == original: table.original else: table.additions
  source.substr(piece.start, piece.start + piece.length - 1)

proc contentLength*(table: PieceTable): int =
  ## Query logical document size without materializing the piece table. This is
  ## the safe length boundary for large-file callers and benchmarks.
  for piece in table.pieces:
    result += piece.length

proc byteAt(table: PieceTable, offset: int): char =
  var cursor = 0
  for piece in table.pieces:
    if offset < cursor + piece.length:
      let source = if piece.source == original: table.original else: table.additions
      return source[piece.start + offset - cursor]
    cursor += piece.length
  '\x00'

proc toString*(table: PieceTable): string =
  result = newStringOfCap(table.original.len + table.additions.len)
  for piece in table.pieces: result.add(table.sourceText(piece))

proc rebuildIndex*(table: var PieceTable) =
  table.lineStarts = @[0]
  var offset = 0
  for piece in table.pieces:
    let source = if piece.source == original: table.original else: table.additions
    for index in 0 ..< piece.length:
      if source[piece.start + index] == '\n':
        table.lineStarts.add(offset + index + 1)
    offset += piece.length

proc splitAt(table: var PieceTable, offset: int): int =
  let target = max(0, min(offset, table.contentLength))
  var cursor = 0
  for index in 0 ..< table.pieces.len:
    let piece = table.pieces[index]
    if target == cursor: return index
    if target < cursor + piece.length:
      let left = target - cursor
      table.pieces[index] = Piece(source: piece.source, start: piece.start, length: left)
      table.pieces.insert(Piece(source: piece.source, start: piece.start + left,
                                length: piece.length - left), index + 1)
      return index + 1
    cursor += piece.length
  table.pieces.len

proc replaceInternal(table: var PieceTable, startByte, endByte: int, replacement: string) =
  let start = table.splitAt(startByte)
  let finish = table.splitAt(endByte)
  if finish > start:
    for index in countdown(finish - 1, start): table.pieces.delete(index)
  if replacement.len > 0:
    let addStart = table.additions.len
    table.additions.add(replacement)
    table.pieces.insert(Piece(source: add, start: addStart, length: replacement.len), start)
  table.rebuildIndex()

proc substring*(table: PieceTable, startByte, endByte: int): string =
  let length = table.contentLength
  let start = max(0, min(startByte, length))
  let finish = max(start, min(endByte, length))
  if finish <= start: return ""
  var cursor = 0
  for piece in table.pieces:
    let pieceEnd = cursor + piece.length
    if pieceEnd <= start:
      cursor = pieceEnd
      continue
    if cursor >= finish: break
    let localStart = max(0, start - cursor)
    let localEnd = min(piece.length, finish - cursor)
    let source = if piece.source == original: table.original else: table.additions
    result.add(source.substr(piece.start + localStart, piece.start + localEnd - 1))
    cursor = pieceEnd

proc rangeHash*(table: PieceTable, startByte, endByte: int): uint64 =
  let length = table.contentLength
  let start = max(0, min(startByte, length))
  let finish = max(start, min(endByte, length))
  var cursor = 0
  result = 14695981039346656037'u64
  for piece in table.pieces:
    let pieceEnd = cursor + piece.length
    if pieceEnd <= start:
      cursor = pieceEnd
      continue
    if cursor >= finish: break
    let localStart = max(0, start - cursor)
    let localEnd = min(piece.length, finish - cursor)
    let source = if piece.source == original: table.original else: table.additions
    for index in localStart ..< localEnd:
      result = (result xor uint64(ord(source[piece.start + index]))) *
        1099511628211'u64
    cursor = pieceEnd

proc lineHash*(table: PieceTable, line: int): uint64 =
  if table.lineStarts.len == 0: return 14695981039346656037'u64
  let targetLine = max(0, min(line, table.lineStarts.high))
  let start = table.lineStarts[targetLine]
  let finish = if targetLine + 1 < table.lineStarts.len:
    table.lineStarts[targetLine + 1] else: table.contentLength
  let endByte = if finish > start and table.byteAt(finish - 1) == '\n':
    finish - 1 else: finish
  table.rangeHash(start, endByte)

proc isUtf8Boundary(table: PieceTable, offset: int): bool =
  let length = table.contentLength
  if offset < 0 or offset > length: return false
  offset == 0 or offset == length or
    (ord(table.byteAt(offset)) and 0xC0) != 0x80

proc validateEditRange(table: PieceTable, startByte, endByte: int, replacement: string) =
  if validateUtf8(replacement) >= 0:
    raise newException(ValueError, "edit replacement must be valid UTF-8")
  if startByte < 0 or endByte < startByte or endByte > table.contentLength or
      not table.isUtf8Boundary(startByte) or not table.isUtf8Boundary(endByte):
    raise newException(ValueError, "edit range must use UTF-8 boundaries")

const
  ## Zed groups edits through Editor::transact/start_transaction_at/end_transaction_at
  ## at crates/editor/src/editor.rs:8286, :8299, and :8321.
  EDIT_TRANSACTION_GROUPING_INTERVAL* = initDuration(milliseconds = 300)

proc transactionSelections(edits: seq[Edit], after: bool): seq[Selection] =
  var cumulativeShift = 0
  for edit in edits:
    let offset = edit.startByte + (if after: cumulativeShift + edit.text.len else: 0)
    if after:
      result.add(Selection(anchor: offset, active: offset))
    else:
      result.add(Selection(anchor: edit.startByte, active: edit.endByte))
    cumulativeShift += edit.text.len - (edit.endByte - edit.startByte)

proc effectiveTransactionSelections(edits: seq[Edit], selections: seq[Selection],
                                    after: bool): seq[Selection] =
  if selections.len > 0: return selections
  edits.transactionSelections(after)

proc canGroupTransaction(table: PieceTable, beforeContentVersion: uint64,
                         at: MonoTime): bool =
  table.canGroupUndo and table.undoStack.len > 0 and
    table.undoStack[^1].afterContentVersion == beforeContentVersion and
    at - table.lastEditAt <= EDIT_TRANSACTION_GROUPING_INTERVAL

proc edit*(table: var PieceTable, edit: Edit, recordUndo = true,
           at = MonoTime(), selectionsBefore: seq[Selection] = @[],
           selectionsAfter: seq[Selection] = @[]) =
  let hasExplicitTimestamp = at != MonoTime()
  let editAt = if hasExplicitTimestamp: at else: getMonoTime()
  table.validateEditRange(edit.startByte, edit.endByte, edit.text)
  let start = edit.startByte
  let finish = edit.endByte
  let oldText = table.substring(start, finish)
  let beforeContentVersion = table.contentVersion
  inc table.nextContentVersion
  let afterContentVersion = table.nextContentVersion
  table.replaceInternal(start, finish, edit.text)
  if recordUndo:
    let edits = @[edit]
    let beforeSelections = edits.effectiveTransactionSelections(selectionsBefore, false)
    let afterSelections = edits.effectiveTransactionSelections(selectionsAfter, true)
    let record = EditRecord(beforeStartByte: start, afterStartByte: start,
      before: oldText, after: edit.text)
    if hasExplicitTimestamp and table.canGroupTransaction(beforeContentVersion, editAt):
      var transaction = table.undoStack[^1]
      transaction.records.add(record)
      transaction.afterContentVersion = afterContentVersion
      transaction.selectionsAfter = afterSelections
      transaction.lastEditAt = editAt
      table.undoStack[^1] = transaction
    else:
      table.undoStack.add(EditTransaction(records: @[record],
        beforeContentVersion: beforeContentVersion,
        afterContentVersion: afterContentVersion,
        selectionsBefore: beforeSelections,
        selectionsAfter: afterSelections,
        lastEditAt: editAt))
    table.redoStack.setLen(0)
    table.canGroupUndo = true
    table.lastEditAt = editAt
  else:
    table.canGroupUndo = false
  table.contentVersion = afterContentVersion
  inc table.version

proc applyEdits*(table: var PieceTable, edits: seq[Edit],
                 at = getMonoTime(), selectionsBefore: seq[Selection] = @[],
                 selectionsAfter: seq[Selection] = @[]) =
  if edits.len == 0: return
  var ordered = edits
  for edit in ordered:
    table.validateEditRange(edit.startByte, edit.endByte, edit.text)
  ordered.sort(proc(a, b: Edit): int = cmp(a.startByte, b.startByte))
  for index in 1 ..< ordered.len:
    if ordered[index - 1].endByte > ordered[index].startByte:
      raise newException(ValueError, "overlapping edits are not atomic")
  let beforeContentVersion = table.contentVersion
  inc table.nextContentVersion
  let afterContentVersion = table.nextContentVersion
  var transaction = EditTransaction(records: newSeq[EditRecord](edits.len))
  transaction.beforeContentVersion = beforeContentVersion
  transaction.afterContentVersion = afterContentVersion
  transaction.selectionsBefore = effectiveTransactionSelections(ordered, selectionsBefore, false)
  transaction.selectionsAfter = effectiveTransactionSelections(ordered, selectionsAfter, true)
  transaction.lastEditAt = at
  ordered.reverse()
  var cumulativeShift = 0
  var recordsByStart = ordered
  recordsByStart.reverse()
  for index, edit in recordsByStart:
    transaction.records[index] = EditRecord(beforeStartByte: edit.startByte,
      afterStartByte: edit.startByte + cumulativeShift,
      before: table.substring(edit.startByte, edit.endByte), after: edit.text)
    cumulativeShift += edit.text.len - (edit.endByte - edit.startByte)
  for edit in ordered:
    table.replaceInternal(edit.startByte, edit.endByte, edit.text)
  if table.canGroupTransaction(beforeContentVersion, at):
    var grouped = table.undoStack[^1]
    grouped.records.add(transaction.records)
    grouped.afterContentVersion = transaction.afterContentVersion
    grouped.selectionsAfter = transaction.selectionsAfter
    grouped.lastEditAt = at
    table.undoStack[^1] = grouped
  else:
    table.undoStack.add(transaction)
  table.redoStack.setLen(0)
  table.canGroupUndo = true
  table.lastEditAt = at
  table.contentVersion = afterContentVersion
  inc table.version

proc undo*(table: var PieceTable): bool =
  if table.undoStack.len == 0: return false
  let transaction = table.undoStack.pop()
  var records = transaction.records
  records.sort(proc(a, b: EditRecord): int = cmp(b.afterStartByte, a.afterStartByte))
  for record in records:
    table.replaceInternal(record.afterStartByte, record.afterStartByte + record.after.len,
      record.before)
  table.redoStack.add(transaction)
  table.undoSelections = transaction.selectionsBefore
  table.canGroupUndo = false
  table.contentVersion = transaction.beforeContentVersion
  inc table.version
  true

proc redo*(table: var PieceTable): bool =
  if table.redoStack.len == 0: return false
  let transaction = table.redoStack.pop()
  var records = transaction.records
  records.sort(proc(a, b: EditRecord): int = cmp(b.beforeStartByte, a.beforeStartByte))
  for record in records:
    table.replaceInternal(record.beforeStartByte, record.beforeStartByte + record.before.len,
      record.after)
  table.undoStack.add(transaction)
  table.redoSelections = transaction.selectionsAfter
  table.canGroupUndo = false
  table.contentVersion = transaction.afterContentVersion
  inc table.version
  true

proc selectionsAfterUndo*(table: PieceTable): seq[Selection] =
  table.undoSelections

proc selectionsAfterRedo*(table: PieceTable): seq[Selection] =
  table.redoSelections

proc markSaved*(table: var PieceTable) =
  table.savedVersion = table.version
  table.savedContentVersion = table.contentVersion

proc markDirty*(table: var PieceTable) =
  ## Restore a serialized unsaved document without manufacturing an undo edit.
  inc table.nextContentVersion
  table.contentVersion = table.nextContentVersion
  inc table.version

proc isDirty*(table: PieceTable): bool =
  table.contentVersion != table.savedContentVersion

proc lineByteColumn(table: PieceTable, byteOffset: int): tuple[line, column: int] =
  let offset = max(0, min(byteOffset, table.contentLength))
  var low = 0
  var high = table.lineStarts.len
  while low + 1 < high:
    let middle = (low + high) div 2
    if table.lineStarts[middle] <= offset: low = middle
    else: high = middle
  let line = low
  (line: line, column: offset - table.lineStarts[line])

proc lineColumn*(table: PieceTable, byteOffset: int): tuple[line, column: int] =
  ## Return a line and grapheme column, never a UTF-8 byte column.
  let location = table.lineByteColumn(byteOffset)
  let lineEnd = if location.line + 1 < table.lineStarts.len:
    table.lineStarts[location.line + 1]
  else: table.contentLength
  let positions = textPositions(table.substring(table.lineStarts[location.line], lineEnd))
  var column = 0
  for position in positions:
    if position.byteOffset > location.column: break
    column = position.graphemeIndex
  (line: location.line, column: column)

proc lineEndByteOffset*(table: PieceTable, line: int): int =
  ## Return the cursor position immediately before the line terminator.
  ## Internal storage uses LF, while the saved file may use CRLF later.
  if table.lineStarts.len == 0: return 0
  let targetLine = max(0, min(line, table.lineStarts.high))
  let start = table.lineStarts[targetLine]
  let finish = if targetLine + 1 < table.lineStarts.len:
    table.lineStarts[targetLine + 1]
  else: table.contentLength
  if finish > start:
    if table.byteAt(finish - 1) == '\n': return finish - 1
  finish

proc utf16Position*(table: PieceTable, byteOffset: int): tuple[line, character: int] =
  let location = table.lineByteColumn(byteOffset)
  let lineText = table.substring(table.lineStarts[location.line],
    if location.line + 1 < table.lineStarts.len: table.lineStarts[location.line +
        1] else: table.contentLength)
  var units = 0
  let prefixLength = min(location.column, lineText.len)
  if prefixLength > 0:
    for rune in lineText.substr(0, prefixLength - 1).runes:
      units += (if int(rune) > 0xFFFF: 2 else: 1)
  (line: location.line, character: units)

proc byteOffsetAtUtf16Position*(table: PieceTable, line, character: int): int =
  ## Convert an LSP UTF-16 position to a UTF-8 byte boundary. Positions that
  ## split a surrogate pair, or exceed the line, clamp to the preceding safe
  ## rune boundary instead of creating an invalid editor range.
  if table.lineStarts.len == 0: return 0
  let targetLine = max(0, min(line, table.lineStarts.high))
  let start = table.lineStarts[targetLine]
  let finish = if targetLine + 1 < table.lineStarts.len:
    table.lineStarts[targetLine + 1]
  else: table.contentLength
  let text = table.substring(start, finish)
  let targetUnits = max(0, character)
  var byte = 0
  var units = 0
  for rune in text.runes:
    let runeBytes = rune.toUTF8.len
    let runeUnits = if int(rune) > 0xFFFF: 2 else: 1
    if units + runeUnits > targetUnits: break
    units += runeUnits
    byte += runeBytes
  min(start + byte, finish)

proc graphemePosition*(table: PieceTable, byteOffset: int): TextPosition =
  let location = table.lineByteColumn(byteOffset)
  let start = table.lineStarts[location.line]
  let lineEnd = if location.line + 1 < table.lineStarts.len: table.lineStarts[location.line +
      1] else: table.contentLength
  let positions = textPositions(table.substring(start, lineEnd))
  for position in positions:
    if position.byteOffset <= location.column: result = position

proc sliceLength(value: Slice[int]): int =
  if value.b < value.a: 0 else: value.b - value.a + 1

proc validateExcerpt(multiBuffer: MultiBuffer, excerpt: Excerpt) =
  if not multiBuffer.buffers.hasKey(excerpt.bufferId):
    raise newException(KeyError, "excerpt refers to an unknown buffer")
  let length = multiBuffer.buffers[excerpt.bufferId].contentLength
  if excerpt.context.a < 0 or excerpt.context.b >= length or
      excerpt.context.b < excerpt.context.a:
    raise newException(ValueError, "excerpt context is outside its buffer")
  if excerpt.primary.a < excerpt.context.a or
      excerpt.primary.b > excerpt.context.b or
      excerpt.primary.b < excerpt.primary.a:
    raise newException(ValueError, "excerpt primary is outside its context")

proc refreshSingleton(multiBuffer: MultiBuffer) =
  multiBuffer.singleton = false
  if multiBuffer.buffers.len != 1 or multiBuffer.excerpts.len != 1: return
  let excerpt = multiBuffer.excerpts[0]
  let bufferId = toSeq(multiBuffer.buffers.keys)[0]
  let length = multiBuffer.buffers[bufferId].contentLength
  multiBuffer.singleton = excerpt.bufferId == bufferId and
    excerpt.context.a == 0 and excerpt.context.b == length - 1 and
    excerpt.primary == excerpt.context

proc rebuildIndex*(multiBuffer: MultiBuffer) =
  ## Rebuild the aggregate offset index after a structural or buffer edit.
  ## This is deliberately the seq/prefix alternative to Zed's SumTree for
  ## the first singleton-equivalent migration step.
  multiBuffer.prefix = newSeq[int](multiBuffer.excerpts.len + 1)
  for index, excerpt in multiBuffer.excerpts:
    multiBuffer.prefix[index + 1] = multiBuffer.prefix[index] +
      excerpt.context.sliceLength
  multiBuffer.refreshSingleton()

proc initMultiBuffer*(): MultiBuffer =
  new(result)
  result.buffers = initTable[int, PieceTable]()
  result.prefix = @[0]

proc initMultiBuffer*(buffer: PieceTable, bufferId = 0): MultiBuffer =
  result = initMultiBuffer()
  result.buffers[bufferId] = buffer
  let fullRange = Slice[int](a: 0, b: buffer.contentLength - 1)
  result.excerpts.add(Excerpt(bufferId: bufferId, context: fullRange,
    primary: fullRange))
  result.rebuildIndex()

proc initMultiBuffer*(bufferId: int, buffer: PieceTable): MultiBuffer =
  initMultiBuffer(buffer, bufferId)

proc newMultiBuffer*(): MultiBuffer = initMultiBuffer()

proc newMultiBuffer*(buffer: PieceTable, bufferId = 0): MultiBuffer =
  initMultiBuffer(buffer, bufferId)

proc addBuffer*(multiBuffer: MultiBuffer, bufferId: int, buffer: PieceTable) =
  multiBuffer.buffers[bufferId] = buffer
  multiBuffer.refreshSingleton()

proc addExcerpt*(multiBuffer: MultiBuffer, excerpt: Excerpt) =
  multiBuffer.validateExcerpt(excerpt)
  multiBuffer.excerpts.add(excerpt)
  multiBuffer.trailingExcerptUpdateCount.inc
  multiBuffer.rebuildIndex()

proc appendExcerpt*(multiBuffer: MultiBuffer, excerpt: Excerpt) =
  multiBuffer.addExcerpt(excerpt)

proc addExcerpt*(multiBuffer: MultiBuffer, bufferId: int, context: Slice[int],
    primary: Slice[int]) =
  multiBuffer.addExcerpt(Excerpt(bufferId: bufferId, context: context,
    primary: primary))

proc addExcerpt*(multiBuffer: MultiBuffer, bufferId: int, context: Slice[int]) =
  multiBuffer.addExcerpt(bufferId, context, context)

proc contentLength*(multiBuffer: MultiBuffer): int =
  if multiBuffer.prefix.len > 0: result = multiBuffer.prefix[^1]

proc snapshot*(multiBuffer: MultiBuffer): MultiBufferSnapshot =
  result.editCount = multiBuffer.editCount
  result.nonTextStateUpdateCount = multiBuffer.nonTextStateUpdateCount
  result.trailingExcerptUpdateCount = multiBuffer.trailingExcerptUpdateCount
  result.excerpts = newSeq[Excerpt](multiBuffer.excerpts.len)
  for index, excerpt in multiBuffer.excerpts:
    result.excerpts[index] = excerpt
  result.prefix = newSeq[int](multiBuffer.prefix.len)
  for index, value in multiBuffer.prefix:
    result.prefix[index] = value
  result.singleton = multiBuffer.singleton

proc takeSnapshot*(multiBuffer: MultiBuffer): MultiBufferSnapshot =
  multiBuffer.snapshot()

proc contentLength*(snapshot: MultiBufferSnapshot): int =
  if snapshot.prefix.len > 0: result = snapshot.prefix[^1]

proc toBufferOffset*(snapshot: MultiBufferSnapshot, mbOffset: int): BufferOffset =
  if snapshot.excerpts.len == 0:
    return (bufferId: -1, offset: 0)
  let aggregateOffset = max(0, min(mbOffset, snapshot.contentLength))
  var excerptIndex = 0
  while excerptIndex + 1 < snapshot.prefix.len and
      snapshot.prefix[excerptIndex + 1] <= aggregateOffset:
    inc excerptIndex
  if excerptIndex >= snapshot.excerpts.len:
    excerptIndex = snapshot.excerpts.high
  let excerpt = snapshot.excerpts[excerptIndex]
  let localOffset = if aggregateOffset == snapshot.contentLength:
    excerpt.context.sliceLength
  else:
    aggregateOffset - snapshot.prefix[excerptIndex]
  (bufferId: excerpt.bufferId, offset: excerpt.context.a + localOffset)

proc toBufferOffset*(multiBuffer: MultiBuffer, mbOffset: int): BufferOffset =
  multiBuffer.snapshot().toBufferOffset(mbOffset)

proc toMultiBufferOffset*(snapshot: MultiBufferSnapshot, bufferId,
    bufferOffset: int): int =
  var nearest = high(int)
  var nearestDistance = high(int)
  for index, excerpt in snapshot.excerpts:
    if excerpt.bufferId != bufferId: continue
    let start = excerpt.context.a
    let finish = excerpt.context.b + 1
    let resolved = max(start, min(bufferOffset, finish))
    let distance = abs(bufferOffset - resolved)
    if distance < nearestDistance:
      nearestDistance = distance
      nearest = snapshot.prefix[index] + resolved - start
  if nearest == high(int):
    raise newException(KeyError, "offset refers to an unknown buffer excerpt")
  nearest

proc toMultiBufferOffset*(snapshot: MultiBufferSnapshot,
    location: BufferOffset): int =
  snapshot.toMultiBufferOffset(location.bufferId, location.offset)

proc toMultiBufferOffset*(multiBuffer: MultiBuffer, bufferId,
    bufferOffset: int): int =
  multiBuffer.snapshot().toMultiBufferOffset(bufferId, bufferOffset)

proc toMultiBufferOffset*(multiBuffer: MultiBuffer,
    location: BufferOffset): int =
  multiBuffer.snapshot().toMultiBufferOffset(location)

proc lineColumn*(multiBuffer: MultiBuffer, mbOffset: int): tuple[line, column: int] =
  let location = multiBuffer.toBufferOffset(mbOffset)
  if location.bufferId < 0: return (line: 0, column: 0)
  multiBuffer.buffers[location.bufferId].lineColumn(location.offset)

proc transformBoundary(boundary, startByte, endByte, replacementLength: int): int =
  if boundary < startByte: return boundary
  if boundary >= endByte: return boundary + replacementLength - (endByte - startByte)
  startByte + replacementLength

proc transformExcerptRange(value: Slice[int], edit: Edit): Slice[int] =
  let oldEnd = value.b + 1
  let replacementLength = edit.text.len
  let newStart = transformBoundary(value.a, edit.startByte, edit.endByte,
    replacementLength)
  let newEnd = transformBoundary(oldEnd, edit.startByte, edit.endByte,
    replacementLength)
  Slice[int](a: newStart, b: max(newStart, newEnd) - 1)

proc edit*(multiBuffer: MultiBuffer, bufferId: int, edit: Edit) =
  if not multiBuffer.buffers.hasKey(bufferId):
    raise newException(KeyError, "edit refers to an unknown buffer")
  var buffer = multiBuffer.buffers[bufferId]
  buffer.edit(edit)
  multiBuffer.buffers[bufferId] = buffer
  for index in 0 ..< multiBuffer.excerpts.len:
    if multiBuffer.excerpts[index].bufferId != bufferId: continue
    multiBuffer.excerpts[index].context =
      multiBuffer.excerpts[index].context.transformExcerptRange(edit)
    multiBuffer.excerpts[index].primary =
      multiBuffer.excerpts[index].primary.transformExcerptRange(edit)
  multiBuffer.editCount.inc
  multiBuffer.rebuildIndex()

proc edit*(multiBuffer: MultiBuffer, edit: Edit) =
  if multiBuffer.buffers.len != 1:
    raise newException(ValueError, "bufferId is required for a multi-buffer edit")
  let bufferId = toSeq(multiBuffer.buffers.keys)[0]
  multiBuffer.edit(bufferId, edit)

proc markNonTextStateUpdated*(multiBuffer: MultiBuffer) =
  multiBuffer.nonTextStateUpdateCount.inc
