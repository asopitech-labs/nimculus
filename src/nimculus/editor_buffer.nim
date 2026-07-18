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
  PieceTable* = object
    original*, additions*: string
    pieces*: seq[Piece]
    lineStarts*: seq[int]
    undoStack*, redoStack*: seq[EditTransaction]
    savedVersion*, version*: uint64

proc rebuildIndex*(table: var PieceTable)

proc initPieceTable*(text = ""): PieceTable =
  result.original = text
  if text.len > 0: result.pieces.add(Piece(source: original, start: 0, length: text.len))
  result.lineStarts = @[0]
  result.rebuildIndex()

proc sourceText(table: PieceTable, piece: Piece): string =
  let source = if piece.source == original: table.original else: table.additions
  source.substr(piece.start, piece.start + piece.length - 1)

proc toString*(table: PieceTable): string =
  result = newStringOfCap(table.original.len + table.additions.len)
  for piece in table.pieces: result.add(table.sourceText(piece))

proc rebuildIndex*(table: var PieceTable) =
  table.lineStarts = @[0]
  var offset = 0
  for piece in table.pieces:
    let text = table.sourceText(piece)
    for index, character in text:
      if character == '\n': table.lineStarts.add(offset + index + 1)
    offset += text.len

proc splitAt(table: var PieceTable, offset: int): int =
  let target = max(0, min(offset, table.toString().len))
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
  let text = table.toString()
  let start = max(0, min(startByte, text.len))
  let finish = max(start, min(endByte, text.len))
  if finish <= start: return ""
  text.substr(start, finish - 1)

proc edit*(table: var PieceTable, edit: Edit, recordUndo = true) =
  let start = max(0, min(edit.startByte, table.toString().len))
  let finish = max(start, min(edit.endByte, table.toString().len))
  let oldText = table.substring(start, finish)
  table.replaceInternal(start, finish, edit.text)
  if recordUndo:
    table.undoStack.add(EditTransaction(records: @[EditRecord(startByte: start, before: oldText, after: edit.text)]))
    table.redoStack.setLen(0)
  inc table.version

proc applyEdits*(table: var PieceTable, edits: seq[Edit]) =
  if edits.len == 0: return
  let contentLength = table.toString().len
  var ordered = edits
  for edit in ordered:
    if edit.startByte < 0 or edit.endByte < edit.startByte or edit.endByte > contentLength:
      raise newException(ValueError, "edit range is outside the buffer")
  ordered.sort(proc(a, b: Edit): int = cmp(a.startByte, b.startByte))
  for index in 1 ..< ordered.len:
    if ordered[index - 1].endByte > ordered[index].startByte:
      raise newException(ValueError, "overlapping edits are not atomic")
  ordered.reverse()
  var transaction = EditTransaction(records: newSeq[EditRecord](edits.len))
  for index, edit in edits:
    transaction.records[index] = EditRecord(startByte: edit.startByte,
      before: table.substring(edit.startByte, edit.endByte), after: edit.text)
  for edit in ordered:
    table.replaceInternal(edit.startByte, edit.endByte, edit.text)
  table.undoStack.add(transaction)
  table.redoStack.setLen(0)
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
  table.redoStack.add(redo)
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
  table.undoStack.add(undo)
  inc table.version
  true

proc markSaved*(table: var PieceTable) = table.savedVersion = table.version
proc isDirty*(table: PieceTable): bool = table.version != table.savedVersion

proc lineByteColumn(table: PieceTable, byteOffset: int): tuple[line, column: int] =
  let offset = max(0, min(byteOffset, table.toString().len))
  var line = 0
  for index, start in table.lineStarts:
    if start > offset: break
    line = index
  (line: line, column: offset - table.lineStarts[line])

proc lineColumn*(table: PieceTable, byteOffset: int): tuple[line, column: int] =
  ## Return a line and grapheme column, never a UTF-8 byte column.
  let location = table.lineByteColumn(byteOffset)
  let lineEnd = if location.line + 1 < table.lineStarts.len:
    table.lineStarts[location.line + 1]
  else: table.toString().len
  let positions = textPositions(table.substring(table.lineStarts[location.line], lineEnd))
  var column = 0
  for position in positions:
    if position.byteOffset > location.column: break
    column = position.graphemeIndex
  (line: location.line, column: column)

proc utf16Position*(table: PieceTable, byteOffset: int): tuple[line, character: int] =
  let location = table.lineByteColumn(byteOffset)
  let lineText = table.substring(table.lineStarts[location.line],
    if location.line + 1 < table.lineStarts.len: table.lineStarts[location.line + 1] else: table.toString().len)
  var units = 0
  let prefixLength = min(location.column, lineText.len)
  if prefixLength > 0:
    for rune in lineText.substr(0, prefixLength - 1).runes:
      units += (if int(rune) > 0xFFFF: 2 else: 1)
  (line: location.line, character: units)

proc graphemePosition*(table: PieceTable, byteOffset: int): TextPosition =
  let location = table.lineByteColumn(byteOffset)
  let start = table.lineStarts[location.line]
  let lineEnd = if location.line + 1 < table.lineStarts.len: table.lineStarts[location.line + 1] else: table.toString().len
  let positions = textPositions(table.substring(start, lineEnd))
  for position in positions:
    if position.byteOffset <= location.column: result = position
