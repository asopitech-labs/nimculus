import std/algorithm
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
    startByte*: int
    before*, after*: string
  EditTransaction = object
    records*: seq[EditRecord]
    beforeContentVersion, afterContentVersion: uint64
  PieceTable* = object
    original*, additions*: string
    pieces*: seq[Piece]
    lineStarts*: seq[int]
    undoStack*, redoStack*: seq[EditTransaction]
    savedVersion*, version*: uint64
    savedContentVersion, contentVersion, nextContentVersion: uint64

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

proc contentLength(table: PieceTable): int =
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

proc edit*(table: var PieceTable, edit: Edit, recordUndo = true) =
  table.validateEditRange(edit.startByte, edit.endByte, edit.text)
  let start = edit.startByte
  let finish = edit.endByte
  let oldText = table.substring(start, finish)
  let beforeContentVersion = table.contentVersion
  inc table.nextContentVersion
  let afterContentVersion = table.nextContentVersion
  table.replaceInternal(start, finish, edit.text)
  if recordUndo:
    table.undoStack.add(EditTransaction(
      records: @[EditRecord(startByte: start, before: oldText, after: edit.text)],
      beforeContentVersion: beforeContentVersion,
      afterContentVersion: afterContentVersion))
    table.redoStack.setLen(0)
  table.contentVersion = afterContentVersion
  inc table.version

proc applyEdits*(table: var PieceTable, edits: seq[Edit]) =
  if edits.len == 0: return
  var ordered = edits
  for edit in ordered:
    table.validateEditRange(edit.startByte, edit.endByte, edit.text)
  ordered.sort(proc(a, b: Edit): int = cmp(a.startByte, b.startByte))
  for index in 1 ..< ordered.len:
    if ordered[index - 1].endByte > ordered[index].startByte:
      raise newException(ValueError, "overlapping edits are not atomic")
  ordered.reverse()
  let beforeContentVersion = table.contentVersion
  inc table.nextContentVersion
  let afterContentVersion = table.nextContentVersion
  var transaction = EditTransaction(records: newSeq[EditRecord](edits.len))
  transaction.beforeContentVersion = beforeContentVersion
  transaction.afterContentVersion = afterContentVersion
  for index, edit in edits:
    transaction.records[index] = EditRecord(startByte: edit.startByte,
      before: table.substring(edit.startByte, edit.endByte), after: edit.text)
  for edit in ordered:
    table.replaceInternal(edit.startByte, edit.endByte, edit.text)
  table.undoStack.add(transaction)
  table.redoStack.setLen(0)
  table.contentVersion = afterContentVersion
  inc table.version

proc undo*(table: var PieceTable): bool =
  if table.undoStack.len == 0: return false
  let transaction = table.undoStack.pop()
  var redo = EditTransaction(records: @[])
  var records = transaction.records
  records.sort(proc(a, b: EditRecord): int = cmp(b.startByte, a.startByte))
  for record in records:
    let current = table.substring(record.startByte, record.startByte + record.after.len)
    table.replaceInternal(record.startByte, record.startByte + record.after.len, record.before)
    redo.records.add(EditRecord(startByte: record.startByte, before: record.before, after: current))
  redo.beforeContentVersion = transaction.beforeContentVersion
  redo.afterContentVersion = transaction.afterContentVersion
  table.redoStack.add(redo)
  table.contentVersion = transaction.beforeContentVersion
  inc table.version
  true

proc redo*(table: var PieceTable): bool =
  if table.redoStack.len == 0: return false
  let transaction = table.redoStack.pop()
  var undo = EditTransaction(records: @[])
  var records = transaction.records
  records.sort(proc(a, b: EditRecord): int = cmp(b.startByte, a.startByte))
  for record in records:
    let current = table.substring(record.startByte, record.startByte + record.before.len)
    table.replaceInternal(record.startByte, record.startByte + record.before.len, record.after)
    undo.records.add(EditRecord(startByte: record.startByte, before: current, after: record.after))
  undo.beforeContentVersion = transaction.beforeContentVersion
  undo.afterContentVersion = transaction.afterContentVersion
  table.undoStack.add(undo)
  table.contentVersion = transaction.afterContentVersion
  inc table.version
  true

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
    if location.line + 1 < table.lineStarts.len: table.lineStarts[location.line + 1] else: table.contentLength)
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
  let lineEnd = if location.line + 1 < table.lineStarts.len: table.lineStarts[location.line + 1] else: table.contentLength
  let positions = textPositions(table.substring(start, lineEnd))
  for position in positions:
    if position.byteOffset <= location.column: result = position
