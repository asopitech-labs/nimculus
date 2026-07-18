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
