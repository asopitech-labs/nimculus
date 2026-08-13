import std/strutils

type
  ContextEntry* = object
    key*: string
    value*: string
    hasValue*: bool

  KeyContext* = object
    entries*: seq[ContextEntry]

  KeyBindingContextPredicateKind* = enum
    predicateIdentifier, predicateEqual, predicateNotEqual, predicateAnd,
    predicateOr, predicateNot, predicateDescendant

  KeyBindingContextPredicate* = ref object
    kind*: KeyBindingContextPredicateKind
    identifier*: string
    leftKey*: string
    rightValue*: string
    left*: KeyBindingContextPredicate
    right*: KeyBindingContextPredicate

  PredicateDepth* = tuple[matched: bool, depth: int]

proc contextIdentifier*(name: string): ContextEntry =
  ContextEntry(key: name)

proc contextValue*(key, value: string): ContextEntry =
  ContextEntry(key: key, value: value, hasValue: true)

proc keyContext*(entries: varargs[ContextEntry]): KeyContext =
  result.entries = @entries

proc parseKeyContext*(source: string): KeyContext

proc keyContext*(identifier: string): KeyContext =
  parseKeyContext(identifier)

proc findEntry(context: KeyContext, key: string): int =
  for index, entry in context.entries:
    if entry.key == key: return index
  -1

proc contains*(context: KeyContext, key: string): bool =
  context.findEntry(key) >= 0

proc value*(context: KeyContext, key: string): tuple[found: bool, value: string] =
  let index = context.findEntry(key)
  if index >= 0 and context.entries[index].hasValue:
    (true, context.entries[index].value)
  else:
    (false, "")

proc add*(context: var KeyContext, entry: ContextEntry) =
  if not context.contains(entry.key):
    context.entries.add(entry)

proc add*(context: var KeyContext, identifier: string) =
  context.add(contextIdentifier(identifier))

proc set*(context: var KeyContext, key, value: string) =
  if not context.contains(key):
    context.entries.add(contextValue(key, value))

proc extend*(context: var KeyContext, other: KeyContext) =
  for entry in other.entries:
    context.add(entry)

proc newKeyContextWithDefaults*(): KeyContext =
  when defined(macosx):
    result.set("os", "macos")

proc contextToken(source: string, index: var int): string =
  let start = index
  while index < source.len and source[index] notin {
      ' ', '\t', '\n', '\r', '\v', '\f', '='}:
    inc index
  if index == start: "" else: source[start ..< index]

proc parseKeyContext*(source: string): KeyContext =
  var index = 0
  while true:
    while index < source.len and source[index] in {
        ' ', '\t', '\n', '\r', '\v', '\f'}:
      inc index
    if index >= source.len: break

    let key = contextToken(source, index)
    if key.len == 0: break
    while index < source.len and source[index] in {
        ' ', '\t', '\n', '\r', '\v', '\f'}:
      inc index
    if index < source.len and source[index] == '=':
      inc index
      while index < source.len and source[index] in {
          ' ', '\t', '\n', '\r', '\v', '\f'}:
        inc index
      let value = contextToken(source, index)
      if value.len > 0:
        result.set(key, value)
    else:
      result.add(key)

proc skipWhitespace(source: string): string =
  var index = 0
  while index < source.len and source[index] in {' ', '\t', '\n', '\r', '\v', '\f'}:
    inc index
  if index == source.len: "" else: source[index .. ^1]

proc after(source: string, index: int): string =
  if index >= source.len: "" else: source[index .. ^1]

proc identifierChar(value: char): bool =
  value.isAlphaNumeric or value == '_' or value == '-'

proc vimOperatorChar(value: char): bool =
  value in {'>', '<', '~', '"', '?'}

proc parsePrimary(source: string): tuple[predicate: KeyBindingContextPredicate,
    rest: string, valid: bool]
proc parseExpression(source: string, minimumPrecedence: int): tuple[
    predicate: KeyBindingContextPredicate, rest: string, valid: bool]

proc parsePrimary(source: string): tuple[predicate: KeyBindingContextPredicate,
    rest: string, valid: bool] =
  if source.len == 0: return (nil, source, false)
  let next = source[0]
  if next == '(':
    let parsed = parseExpression(skipWhitespace(source.after(1)), 0)
    if not parsed.valid or parsed.rest.len == 0 or parsed.rest[0] != ')':
      return (nil, source, false)
    return (parsed.predicate, skipWhitespace(parsed.rest.after(1)), true)
  if next == '!':
    let parsed = parseExpression(skipWhitespace(source.after(1)), 5)
    if not parsed.valid: return (nil, source, false)
    return (KeyBindingContextPredicate(kind: predicateNot, left: parsed.predicate),
      parsed.rest, true)

  var length = 0
  while length < source.len and
      (identifierChar(source[length]) or vimOperatorChar(source[length])):
    inc length
  if length == 0: return (nil, source, false)
  let name = source[0 ..< length]
  (KeyBindingContextPredicate(kind: predicateIdentifier, identifier: name),
    skipWhitespace(source[length .. ^1]), true)

proc parseExpression(source: string, minimumPrecedence: int): tuple[
    predicate: KeyBindingContextPredicate, rest: string, valid: bool] =
  let primary = parsePrimary(source)
  if not primary.valid: return (nil, source, false)
  result.predicate = primary.predicate
  result.rest = primary.rest
  result.valid = true

  while result.rest.len > 0:
    var operator = ""
    var precedence = -1
    if result.rest.startsWith(">"):
      operator = ">"
      precedence = 1
    elif result.rest.startsWith("&&"):
      operator = "&&"
      precedence = 3
    elif result.rest.startsWith("||"):
      operator = "||"
      precedence = 2
    elif result.rest.startsWith("=="):
      operator = "=="
      precedence = 4
    elif result.rest.startsWith("!="):
      operator = "!="
      precedence = 4
    else:
      break
    if precedence < minimumPrecedence: break
    let right = parseExpression(skipWhitespace(result.rest.after(operator.len)),
      precedence + 1)
    if not right.valid: return (nil, source, false)
    if operator in ["==", "!="]:
      if result.predicate.kind != predicateIdentifier or
          right.predicate.kind != predicateIdentifier:
        return (nil, source, false)
      result.predicate = KeyBindingContextPredicate(
        kind: if operator == "==": predicateEqual else: predicateNotEqual,
        leftKey: result.predicate.identifier,
        rightValue: right.predicate.identifier)
    else:
      let kind = case operator
        of ">": predicateDescendant
        of "&&": predicateAnd
        else: predicateOr
      result.predicate = KeyBindingContextPredicate(kind: kind,
        left: result.predicate, right: right.predicate)
    result.rest = right.rest

proc parseKeyBindingContextPredicate*(source: string): KeyBindingContextPredicate =
  let trimmed = skipWhitespace(source)
  if trimmed.len == 0: return nil
  let parsed = parseExpression(trimmed, 0)
  if parsed.valid and skipWhitespace(parsed.rest).len == 0:
    parsed.predicate
  else:
    nil

proc evalInner(predicate: KeyBindingContextPredicate, contexts,
               allContexts: openArray[KeyContext]): bool

proc evalInner(predicate: KeyBindingContextPredicate, contexts,
               allContexts: openArray[KeyContext]): bool =
  if predicate == nil or contexts.len == 0: return false
  let context = contexts[^1]
  case predicate.kind
  of predicateIdentifier:
    context.contains(predicate.identifier)
  of predicateEqual:
    let found = context.value(predicate.leftKey)
    found.found and found.value == predicate.rightValue
  of predicateNotEqual:
    let found = context.value(predicate.leftKey)
    not found.found or found.value != predicate.rightValue
  of predicateNot:
    for index in 0 ..< allContexts.len:
      if predicate.left.evalInner(allContexts[0 .. index], allContexts): return false
    true
  of predicateDescendant:
    if contexts.len < 2: return false
    for index in 0 ..< contexts.len - 1:
      if predicate.left.evalInner(contexts[0 .. index], allContexts):
        return predicate.right.evalInner(contexts[index + 1 .. ^1],
          contexts[index + 1 .. ^1])
    false
  of predicateAnd:
    predicate.left.evalInner(contexts, allContexts) and
      predicate.right.evalInner(contexts, allContexts)
  of predicateOr:
    predicate.left.evalInner(contexts, allContexts) or
      predicate.right.evalInner(contexts, allContexts)

proc depthOf*(predicate: KeyBindingContextPredicate,
              contexts: openArray[KeyContext]): PredicateDepth =
  ## An absent predicate is an unconditional binding, not a failed match.
  ## Keep that distinction at the context boundary so callers do not need to
  ## infer it from a sentinel depth.
  if predicate == nil: return (true, contexts.len)
  for depth in countdown(contexts.len, 1):
    if predicate.evalInner(contexts[0 ..< depth], contexts):
      return (true, depth)
  (false, -1)

proc `>=`*(value: PredicateDepth, threshold: int): bool =
  ## Source compatibility for callers that used the old integer sentinel.
  value.matched and value.depth >= threshold

proc `<`*(value: PredicateDepth, threshold: int): bool =
  not value.matched or value.depth < threshold

proc `==`*(value: PredicateDepth, threshold: int): bool =
  value.matched and value.depth == threshold

proc predicatesEqual(left, right: KeyBindingContextPredicate): bool =
  if left == nil or right == nil: return left == right
  if left.kind != right.kind: return false
  case left.kind
  of predicateIdentifier:
    left.identifier == right.identifier
  of predicateEqual, predicateNotEqual:
    left.leftKey == right.leftKey and left.rightValue == right.rightValue
  of predicateAnd, predicateOr, predicateDescendant:
    left.left.predicatesEqual(right.left) and left.right.predicatesEqual(right.right)
  of predicateNot:
    left.left.predicatesEqual(right.left)

proc isSuperset*(a, b: KeyBindingContextPredicate): bool =
  ## Return whether every context matched by `b` is also matched by `a`.
  ## This is the structural relation used by Zed when a disabled binding
  ## applies to another binding with a more specific context.
  if a == nil or b == nil: return a == nil and b == nil
  if a.predicatesEqual(b): return true

  if a.kind == predicateOr:
    return a.left.isSuperset(b) or a.right.isSuperset(b)

  case b.kind
  of predicateDescendant:
    a.isSuperset(b.right)
  of predicateAnd:
    a.isSuperset(b.left) or a.isSuperset(b.right)
  of predicateIdentifier, predicateEqual, predicateNotEqual, predicateNot,
      predicateOr:
    false

proc eval*(predicate: KeyBindingContextPredicate,
           contexts: openArray[KeyContext]): bool =
  predicate != nil and predicate.evalInner(contexts, contexts)
