import std/strutils
import nimculus/tree_sitter

type
  HighlightKind* = enum keyword, stringLiteral, numberLiteral, comment, identifier, punctuation
  HighlightSpan* = object
    startByte*, endByte*: uint32
    kind*: HighlightKind
  FoldRange* = object
    startByte*, endByte*: uint32
  OutlineItem* = object
    name*, kind*: string
    startByte*, endByte*: uint32

proc classify(kind: string): HighlightKind =
  let lower = kind.toLowerAscii
  if lower.contains("comment"): return comment
  if lower.contains("string") or lower.contains("template"): return stringLiteral
  if lower.contains("number") or lower.contains("integer") or lower.contains("float"): return numberLiteral
  if lower in ["identifier", "type_identifier", "property_identifier"]: return identifier
  if lower in [";", ",", ".", ":", "(", ")", "[", "]", "{", "}"]: return punctuation
  if lower in ["if", "else", "for", "while", "proc", "func", "let", "var", "const", "type", "return", "import", "from", "fn", "struct", "class", "def", "async", "await"]: return keyword
  return identifier

proc highlight*(tree: SyntaxTree): seq[HighlightSpan] =
  for node in tree.nodes:
    if node.endByte > node.startByte:
      result.add(HighlightSpan(startByte: node.startByte, endByte: node.endByte, kind: classify(node.kind)))

proc highlightVisible*(tree: SyntaxTree, firstByte, lastByte: uint32): seq[HighlightSpan] =
  for span in tree.highlight():
    if span.endByte > firstByte and span.startByte < lastByte:
      result.add(span)

proc matchingBracket*(source: string, position: int): int =
  if position < 0 or position >= source.len: return -1
  let current = source[position]
  let matching = case current
    of '(': ')'
    of '[': ']'
    of '{': '}'
    of ')': '('
    of ']': '['
    of '}': '{'
    else: '\0'
  if matching == '\0': return -1
  if current in {'(', '[', '{'}:
    var depth = 0
    for index in position ..< source.len:
      if source[index] == current: inc depth
      elif source[index] == matching:
        dec depth
        if depth == 0: return index
  else:
    var depth = 0
    var index = position
    while index >= 0:
      if source[index] == current: inc depth
      elif source[index] == matching:
        dec depth
        if depth == 0: return index
      dec index
  -1

proc foldRanges*(tree: SyntaxTree, source: string): seq[FoldRange] =
  for node in tree.nodes:
    if node.endByte <= node.startByte or node.endByte > uint32(source.len): continue
    let lines = source[node.startByte.int ..< node.endByte.int].count('\n')
    if lines > 0: result.add(FoldRange(startByte: node.startByte, endByte: node.endByte))

proc outline*(tree: SyntaxTree): seq[OutlineItem] =
  for node in tree.nodes:
    if node.kind in ["function_definition", "function_item", "class_definition", "struct_item", "proc_decl", "type_declaration"]:
      result.add(OutlineItem(name: node.kind, kind: node.kind, startByte: node.startByte, endByte: node.endByte))

proc indentationLevel*(source: string, byteOffset: int, indentWidth = 2): int =
  if source.len == 0: return 0
  let offset = max(0, min(byteOffset, source.len))
  var lineStart = offset
  while lineStart > 0 and source[lineStart - 1] != '\n': dec lineStart
  var spaces = 0
  while lineStart + spaces < source.len and source[lineStart + spaces] in {' ', '\t'}:
    if source[lineStart + spaces] == '\t': spaces += indentWidth
    else: inc spaces
  spaces div max(1, indentWidth)

proc expandSelection*(tree: SyntaxTree, startByte, endByte: uint32): tuple[startByte, endByte: uint32] =
  result = (startByte: startByte, endByte: endByte)
  var smallest = high(uint32)
  for node in tree.nodes:
    if node.startByte <= startByte and node.endByte >= endByte and
        node.endByte - node.startByte < smallest:
      smallest = node.endByte - node.startByte
      result = (startByte: node.startByte, endByte: node.endByte)

proc nextSyntaxNode*(tree: SyntaxTree, byteOffset: uint32): SyntaxNode =
  var found = false
  for node in tree.nodes:
    if node.startByte >= byteOffset and (not found or node.startByte < result.startByte):
      result = node
      found = true
