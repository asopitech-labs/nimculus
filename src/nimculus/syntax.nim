import std/strutils
import std/unicode
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

proc identifierChar(value: char): bool =
  value in {'a'..'z', 'A'..'Z', '0'..'9', '_'}

proc identifierChar(value: Rune): bool =
  let code = int(value)
  value.isAlpha or (code >= ord('0') and code <= ord('9')) or
    code == ord('_')

proc firstIdentifier(value: string): string =
  var cursor = 0
  while cursor < value.len:
    let rune = value.runeAt(cursor)
    if rune.identifierChar: break
    cursor += value.runeLenAt(cursor)
  let start = cursor
  while cursor < value.len:
    let rune = value.runeAt(cursor)
    if not rune.identifierChar: break
    cursor += value.runeLenAt(cursor)
  if cursor > start: result = value[start ..< cursor]

proc declarationName(source, kind: string, startByte, endByte: uint32): string =
  if source.len == 0 or startByte >= uint32(source.len): return
  let finish = min(int(endByte), source.len)
  if finish <= int(startByte): return
  let declaration = source[int(startByte) ..< finish]
  if kind in ["type_declaration", "type_symbol_declaration"]:
    # Nim's type_declaration node starts at the declared symbol, while some
    # grammars include the `type` keyword in the declaration span.
    var candidate = declaration.strip
    if candidate.startsWith("type "):
      candidate = candidate[5 .. ^1].strip
    return candidate.firstIdentifier
  let keywords = case kind
    of "function_definition", "function_item", "proc_declaration": @[
      "function", "def", "fn", "proc", "func", "method", "template"]
    of "class_definition": @["class"]
    of "struct_item": @["struct"]
    of "proc_decl", "template_declaration": @[
      "proc", "func", "method", "template"]
    else: @[]
  for keyword in keywords:
    var offset = declaration.find(keyword)
    while offset >= 0:
      let beforeIsBoundary = offset == 0 or not identifierChar(declaration[offset - 1])
      let after = offset + keyword.len
      let afterIsBoundary = after >= declaration.len or not identifierChar(declaration[after])
      if beforeIsBoundary and afterIsBoundary:
        let name = declaration.substr(after).firstIdentifier
        if name.len > 0 and not name[0].isDigit:
          return name
      let nextOffset = offset + keyword.len
      if nextOffset >= declaration.len: break
      offset = declaration.find(keyword, nextOffset)

proc outline*(tree: SyntaxTree): seq[OutlineItem] =
  for node in tree.nodes:
    if node.kind in ["function_definition", "function_item", "class_definition",
        "struct_item", "proc_decl", "proc_declaration", "template_declaration",
        "type_declaration", "type_symbol_declaration"]:
      let name = tree.source.declarationName(node.kind, node.startByte, node.endByte)
      result.add(OutlineItem(name: if name.len > 0: name else: node.kind,
        kind: node.kind, startByte: node.startByte, endByte: node.endByte))

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

proc largerSelection*(tree: SyntaxTree, startByte, endByte: uint32): tuple[startByte, endByte: uint32] =
  ## Select the smallest syntax node that strictly contains the current range.
  ## On an empty selection this is the first syntax node at the cursor, which
  ## matches Zed's first Expand Selection action.
  result = (startByte: startByte, endByte: endByte)
  let currentSize = endByte - startByte
  var smallest = high(uint32)
  for node in tree.nodes:
    let size = node.endByte - node.startByte
    if node.startByte <= startByte and node.endByte >= endByte and
        size > currentSize and size < smallest:
      smallest = size
      result = (startByte: node.startByte, endByte: node.endByte)

proc smallerSelection*(tree: SyntaxTree, startByte, endByte: uint32,
                       cursorByte: uint32): tuple[startByte, endByte: uint32] =
  ## Select the largest child node that still contains the cursor and remains
  ## strictly inside the current selection. This is the inverse of the
  ## user-visible expansion action and keeps shrinking bounded at a leaf.
  result = (startByte: startByte, endByte: endByte)
  if endByte <= startByte: return
  let currentSize = endByte - startByte
  var largest = 0'u32
  for node in tree.nodes:
    let size = node.endByte - node.startByte
    if node.startByte >= startByte and node.endByte <= endByte and
        node.startByte <= cursorByte and node.endByte >= cursorByte and
        size > largest and size < currentSize:
      largest = size
      result = (startByte: node.startByte, endByte: node.endByte)

proc nextSyntaxNode*(tree: SyntaxTree, byteOffset: uint32): SyntaxNode =
  var found = false
  for node in tree.nodes:
    if node.startByte >= byteOffset and (not found or node.startByte < result.startByte):
      result = node
      found = true

proc sameRange(left, right: SyntaxNode): bool =
  left.startByte == right.startByte and left.endByte == right.endByte

proc directChildren(tree: SyntaxTree, parent: SyntaxNode): seq[SyntaxNode] =
  ## Tree-sitter's C bridge intentionally exposes a flat node stream. Recover
  ## the immediate children from ranges so editor navigation can preserve the
  ## same hierarchy as Zed's syntax_next_sibling/syntax_prev_sibling without
  ## adding a second native tree-walking API. The bridge emits preorder DFS,
  ## so once a child's end is covered all following nodes until that byte are
  ## descendants and can be skipped in one pass.
  var coveredEnd = parent.startByte
  for candidate in tree.nodes:
    if sameRange(candidate, parent) or candidate.startByte < parent.startByte or
        candidate.endByte > parent.endByte or candidate.endByte <= candidate.startByte:
      continue
    if candidate.startByte >= coveredEnd:
      result.add(candidate)
      coveredEnd = candidate.endByte

proc syntaxSibling*(tree: SyntaxTree, startByte, endByte: uint32,
                    next: bool): tuple[startByte, endByte: uint32] =
  ## Find a sibling range using the same hierarchical fallback as Zed:
  ## search the current parent first, then walk up until a sibling exists.
  result = (startByte: startByte, endByte: endByte)
  if tree == nil or tree.nodes.len == 0: return

  var current: SyntaxNode
  var foundCurrent = false
  var currentSize = high(uint32)
  for node in tree.nodes:
    if node.startByte <= startByte and node.endByte >= endByte and
        node.endByte >= node.startByte:
      let size = node.endByte - node.startByte
      if not foundCurrent or size < currentSize:
        current = node
        currentSize = size
        foundCurrent = true
  if not foundCurrent: return

  while true:
    var parent: SyntaxNode
    var foundParent = false
    var parentSize = high(uint32)
    for node in tree.nodes:
      if sameRange(node, current) or node.startByte > current.startByte or
          node.endByte < current.endByte:
        continue
      let size = node.endByte - node.startByte
      if size > current.endByte - current.startByte and
          (not foundParent or size < parentSize):
        parent = node
        parentSize = size
        foundParent = true
    if not foundParent: return

    let children = tree.directChildren(parent)
    var currentChild: SyntaxNode
    var foundChild = false
    var childSize = high(uint32)
    for child in children:
      if child.startByte <= current.startByte and child.endByte >= current.endByte:
        let size = child.endByte - child.startByte
        if not foundChild or size < childSize:
          currentChild = child
          childSize = size
          foundChild = true
    if foundChild:
      var candidate: SyntaxNode
      var foundCandidate = false
      for child in children:
        if next:
          if child.startByte < currentChild.endByte: continue
          if not foundCandidate or child.startByte < candidate.startByte:
            candidate = child
            foundCandidate = true
        else:
          if child.endByte > currentChild.startByte: continue
          if not foundCandidate or child.endByte > candidate.endByte:
            candidate = child
            foundCandidate = true
      if foundCandidate:
        return (startByte: candidate.startByte, endByte: candidate.endByte)

    current = parent
