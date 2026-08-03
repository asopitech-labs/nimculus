import std/algorithm
import nimculus/tree_sitter
import nimculus/syntax

type
  EditorSyntaxState* = ref object
    parser*: TreeSitterParser
    tree*: SyntaxTree
    grammar*: GrammarKind

  HighlightByteRange* = tuple[firstByte, lastByte: uint32]

proc utf8Continuation(value: char): bool = (ord(value) and 0xC0) == 0x80

proc pointAt(source: string, offset: int): tuple[row, column: uint32] =
  var row = 0'u32
  var lineStart = 0
  let limit = max(0, min(offset, source.len))
  for index in 0 ..< limit:
    if source[index] == '\n':
      inc row
      lineStart = index + 1
  (row: row, column: uint32(limit - lineStart))

proc newEditorSyntax*(path, source: string): EditorSyntaxState =
  try:
    result = EditorSyntaxState(grammar: grammarForPath(path))
    result.parser = newTreeSitterParser(result.grammar)
    result.tree = result.parser.parse(source)
  except ValueError:
    return nil

proc update*(state: EditorSyntaxState, source: string) =
  if state == nil or state.parser == nil: return
  if state.tree == nil:
    state.tree = state.parser.parse(source)
    return
  let oldSource = state.tree.source
  if oldSource == source: return
  var prefix = 0
  while prefix < oldSource.len and prefix < source.len and oldSource[prefix] == source[
      prefix]: inc prefix
  while prefix > 0 and
        ((prefix < oldSource.len and utf8Continuation(oldSource[prefix])) or
         (prefix < source.len and utf8Continuation(source[prefix]))):
    dec prefix
  var suffix = 0
  while suffix < oldSource.len - prefix and suffix < source.len - prefix and
        oldSource[oldSource.len - 1 - suffix] == source[source.len - 1 - suffix]: inc suffix
  var oldEnd = oldSource.len - suffix
  var newEnd = source.len - suffix
  while oldEnd < oldSource.len and utf8Continuation(oldSource[oldEnd]): inc oldEnd
  while newEnd < source.len and utf8Continuation(source[newEnd]): inc newEnd
  let startPoint = pointAt(oldSource, prefix)
  let oldEndPoint = pointAt(oldSource, oldEnd)
  let newEndPoint = pointAt(source, newEnd)
  state.tree.edit(uint32(prefix), uint32(oldEnd), uint32(newEnd),
    startPoint.row, startPoint.column, oldEndPoint.row, oldEndPoint.column,
    newEndPoint.row, newEndPoint.column)
  var next = state.parser.parse(source, state.tree)
  state.tree.close()
  state.tree = next

proc visibleHighlights*(state: EditorSyntaxState, firstByte, lastByte: uint32): seq[HighlightSpan] =
  if state != nil and state.tree != nil:
    return state.tree.highlightVisible(firstByte, lastByte)

proc visibleHighlights*(state: EditorSyntaxState,
                        ranges: openArray[HighlightByteRange]): seq[HighlightSpan] =
  ## Split editors can have disjoint visible byte ranges. Merge overlapping
  ## requests first so each pane gets its syntax spans without expanding work
  ## to the bytes between two distant viewports.
  if state == nil or state.tree == nil: return
  var requested: seq[HighlightByteRange]
  for byteRange in ranges:
    if byteRange.lastByte > byteRange.firstByte:
      requested.add(byteRange)
  requested.sort(proc(a, b: HighlightByteRange): int =
    let firstOrder = cmp(a.firstByte, b.firstByte)
    if firstOrder != 0: firstOrder else: cmp(a.lastByte, b.lastByte))
  var merged: seq[HighlightByteRange]
  for byteRange in requested:
    if merged.len > 0 and byteRange.firstByte <= merged[^1].lastByte:
      merged[^1].lastByte = max(merged[^1].lastByte, byteRange.lastByte)
    else:
      merged.add(byteRange)
  var spans: seq[HighlightSpan]
  for byteRange in merged:
    spans.add(state.tree.highlightVisible(byteRange.firstByte, byteRange.lastByte))
  result = spans

proc close*(state: EditorSyntaxState) =
  if state == nil: return
  if state.tree != nil: state.tree.close()
  if state.parser != nil: state.parser.close()
