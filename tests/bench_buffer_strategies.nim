import std/times
import std/strformat
import std/strutils
import nimculus/editor_buffer

type
  ChunkedRope = object
    chunks: seq[string]
  GapBuffer = object
    data: seq[char]
    gapStart, gapEnd: int
  PieceTreeNode = ref object
    text: string
    left, right: PieceTreeNode
  PieceTree = object
    root: PieceTreeNode
  HybridBuffer = object
    chunks: seq[string]
    lineStarts: seq[int]

proc chunkText(text: string, chunkSize = 4096): seq[string] =
  var offset = 0
  while offset < text.len:
    let finish = min(text.len, offset + chunkSize)
    result.add(text[offset ..< finish])
    offset = finish

proc initChunkedRope(text: string): ChunkedRope =
  result.chunks = chunkText(text)

proc ropeText(rope: ChunkedRope): string =
  for chunk in rope.chunks: result.add(chunk)

proc ropeInsert(rope: var ChunkedRope, offset: int, text: string) =
  var flattened = rope.ropeText()
  flattened.insert(text, offset)
  rope.chunks = chunkText(flattened)

proc initGapBuffer(text: string): GapBuffer =
  result.data = newSeq[char](text.len + 4096)
  for index, character in text: result.data[index] = character
  result.gapStart = text.len
  result.gapEnd = result.data.len

proc gapMove(gap: var GapBuffer, offset: int) =
  let target = max(0, min(offset, gap.data.len - (gap.gapEnd - gap.gapStart)))
  while gap.gapStart > target:
    dec gap.gapStart; dec gap.gapEnd
    gap.data[gap.gapEnd] = gap.data[gap.gapStart]
  while gap.gapStart < target:
    gap.data[gap.gapStart] = gap.data[gap.gapEnd]
    inc gap.gapStart; inc gap.gapEnd

proc gapInsert(gap: var GapBuffer, offset: int, text: string) =
  gap.gapMove(offset)
  if text.len > gap.gapEnd - gap.gapStart: return
  for character in text:
    gap.data[gap.gapStart] = character
    inc gap.gapStart

proc gapLength(gap: GapBuffer): int = gap.data.len - (gap.gapEnd - gap.gapStart)

proc treeBuild(chunks: seq[string], first, last: int): PieceTreeNode =
  if first >= last: return nil
  let middle = (first + last) div 2
  PieceTreeNode(text: chunks[middle], left: treeBuild(chunks, first, middle),
                right: treeBuild(chunks, middle + 1, last))

proc treeAppend(node: PieceTreeNode, output: var string) =
  if node == nil: return
  node.left.treeAppend(output)
  output.add(node.text)
  node.right.treeAppend(output)

proc treeText(tree: PieceTree): string = tree.root.treeAppend(result)
proc initPieceTree(text: string): PieceTree =
  let chunks = chunkText(text)
  result.root = treeBuild(chunks, 0, chunks.len)
proc treeInsert(tree: var PieceTree, offset: int, text: string) =
  var flattened = tree.treeText()
  flattened.insert(text, offset)
  let chunks = chunkText(flattened)
  tree.root = treeBuild(chunks, 0, chunks.len)

proc initHybrid(text: string): HybridBuffer =
  result.chunks = chunkText(text)
  result.lineStarts = @[0]
  for index, character in text:
    if character == '\n': result.lineStarts.add(index + 1)
proc hybridText(buffer: HybridBuffer): string =
  for chunk in buffer.chunks: result.add(chunk)
proc hybridInsert(buffer: var HybridBuffer, offset: int, text: string) =
  var flattened = buffer.hybridText()
  flattened.insert(text, offset)
  buffer = initHybrid(flattened)

proc elapsed(label: string, action: proc()): float =
  let start = cpuTime()
  action()
  result = cpuTime() - start
  echo &"{label}: {result:.4f}s"

let source = repeat("0123456789abcdef\n", 65536)
let middle = source.len div 2
var piece = initPieceTable(source)
discard elapsed("PieceTable", proc() =
  for index in 0 ..< 100: piece.edit(Edit(startByte: middle + index, endByte: middle + index, text: "x")))
var rope = initChunkedRope(source)
discard elapsed("ChunkedRope", proc() =
  for index in 0 ..< 100: rope.ropeInsert(middle + index, "x"))
var gap = initGapBuffer(source)
discard elapsed("GapBuffer", proc() =
  for index in 0 ..< 100: gap.gapInsert(middle + index, "x"))
var tree = initPieceTree(source)
discard elapsed("PieceTree", proc() =
  for index in 0 ..< 100: tree.treeInsert(middle + index, "x"))
var hybrid = initHybrid(source)
discard elapsed("Hybrid(line-indexed chunks)", proc() =
  for index in 0 ..< 100: hybrid.hybridInsert(middle + index, "x"))
echo &"source bytes: {source.len}, gap logical bytes: {gap.gapLength()}"
