## Jupyter v5 message primitives and the editor-independent REPL result store.
##
## A socket adapter can hand this module the already separated multipart
## frames produced by ZeroMQ. This slice intentionally does not own a kernel
## process or a transport; it only validates, signs, decodes, and correlates
## messages.

import std/hashes
import std/json
import std/strutils
import std/tables

import nimculus/sha256

const
  ReplMessageDelimiter* = "<IDS|MSG>"
  MaxReplFrameBytes* = 16 * 1024 * 1024
  ReplPayloadFrameCount* = 5
  ReplWireFrameCount* = ReplPayloadFrameCount + 1

type
  ReplProtocolError* = object of CatchableError

  ReplMessage* = object
    ## The signature is the transmitted lowercase hexadecimal HMAC. The four
    ## JSON members are the Jupyter header, parent_header, metadata, content.
    signature*: string
    header*: JsonNode
    parentHeader*: JsonNode
    metadata*: JsonNode
    content*: JsonNode

  JupyterMessage* = ReplMessage

  ResultKey* = object
    path*: string
    line*: int

  ReplOutput* = object
    kind*: string
    content*: JsonNode

  ResultStore* = ref object
    values: Table[ResultKey, seq[ReplOutput]]

  ReplSession* = ref object
    executionCount*: int
    results*: ResultStore
    activeExecutions: Table[string, ResultKey]
    currentKey: ResultKey
    hasCurrentKey: bool

proc `==`*(left, right: ResultKey): bool =
  left.path == right.path and left.line == right.line

proc hash*(key: ResultKey): Hash =
  var value = hash(key.path)
  value = value !& hash(key.line)
  !$value

proc jsonPart(node: JsonNode): string =
  if node == nil: "{}" else: $node

proc signedPayload*(message: ReplMessage): string =
  ## Jupyter signs the four JSON frame bytes without separators.
  jsonPart(message.header) & jsonPart(message.parentHeader) &
    jsonPart(message.metadata) & jsonPart(message.content)

proc messageSignature*(message: ReplMessage, key: string): string =
  hmacSha256Hex(key, message.signedPayload)

proc encodeReplMessage*(message: ReplMessage, key: string): seq[string] =
  let header = jsonPart(message.header)
  let parentHeader = jsonPart(message.parentHeader)
  let metadata = jsonPart(message.metadata)
  let content = jsonPart(message.content)
  let signature = hmacSha256Hex(key, header & parentHeader & metadata & content)
  @[ReplMessageDelimiter, signature, header, parentHeader, metadata, content]

proc encodeReplMessage*(header, parentHeader, metadata, content: JsonNode,
                        key: string): seq[string] =
  encodeReplMessage(ReplMessage(header: header, parentHeader: parentHeader,
    metadata: metadata, content: content), key)

proc replFrameLengthAllowed*(declaredLength: int,
                             maxFrameBytes = MaxReplFrameBytes): bool =
  ## A socket adapter can call this with the ZMTP frame length before copying
  ## the frame body. It intentionally performs no body allocation.
  declaredLength >= 0 and declaredLength <= maxFrameBytes

proc frameSizesValid(frames: openArray[string], maxFrameBytes: int): bool =
  if maxFrameBytes < 0 or frames.len != ReplWireFrameCount: return false
  for frame in frames:
    if not replFrameLengthAllowed(frame.len, maxFrameBytes): return false
  frames[0] == ReplMessageDelimiter

proc constantTimeEqual(left, right: string): bool =
  if left.len != right.len: return false
  var difference = 0
  for index in 0 ..< left.len:
    difference = difference or (ord(left[index]) xor ord(right[index]))
  difference == 0

proc verifyReplMessage*(frames: openArray[string], key: string,
                        maxFrameBytes = MaxReplFrameBytes): bool =
  ## Verification is deliberately a total operation: malformed or oversized
  ## frame lists are simply untrusted input and return false.
  if not frameSizesValid(frames, maxFrameBytes): return false
  if frames[1].len != 64: return false
  let expected = hmacSha256Hex(key, frames[2] & frames[3] & frames[4] & frames[5])
  constantTimeEqual(frames[1].toLowerAscii, expected)

proc decodeReplMessage*(frames: openArray[string], key: string,
                        maxFrameBytes = MaxReplFrameBytes):
                        tuple[message: ReplMessage, valid: bool] =
  ## HMAC is checked before parsing JSON. A one-byte content mutation therefore
  ## returns `(empty, false)` even when that mutation also makes invalid JSON.
  if not verifyReplMessage(frames, key, maxFrameBytes): return
  try:
    result.message = ReplMessage(signature: frames[1],
      header: parseJson(frames[2]), parentHeader: parseJson(frames[3]),
      metadata: parseJson(frames[4]), content: parseJson(frames[5]))
    result.valid = true
  except CatchableError:
    result.valid = false

proc newResultStore*(): ResultStore =
  ResultStore(values: initTable[ResultKey, seq[ReplOutput]]())

proc resultKey*(path: string, line: int): ResultKey =
  ResultKey(path: path, line: line)

proc clear*(store: ResultStore, path: string, line: int) =
  if store == nil: return
  store.values[resultKey(path, line)] = @[]

proc addOutput*(store: ResultStore, path: string, line: int,
                kind: string, content: JsonNode) =
  if store == nil: return
  let key = resultKey(path, line)
  store.values.mgetOrPut(key, @[]).add(ReplOutput(kind: kind, content: content))

proc outputsAt*(store: ResultStore, path: string, line: int): seq[ReplOutput] =
  if store == nil: return @[]
  store.values.getOrDefault(resultKey(path, line), @[])

proc outputCount*(store: ResultStore, path: string, line: int): int =
  outputsAt(store, path, line).len

proc newReplSession*(): ReplSession =
  ReplSession(executionCount: 0, results: newResultStore(),
    activeExecutions: initTable[string, ResultKey](), hasCurrentKey: false)

proc textValue(node: JsonNode, key: string): string =
  if node != nil and node.kind == JObject and node.hasKey(key) and
      node[key].kind == JString:
    result = node[key].getStr

proc intValue(node: JsonNode, key: string, fallback: int): int =
  if node != nil and node.kind == JObject and node.hasKey(key) and
      node[key].kind == JInt:
    node[key].getInt
  else:
    fallback

proc executionKey(message: ReplMessage): ResultKey =
  let path = if textValue(message.content, "path").len > 0:
      textValue(message.content, "path")
    else: textValue(message.metadata, "path")
  let line = if message.content != nil and message.content.kind == JObject and
      message.content.hasKey("line"):
      intValue(message.content, "line", 0)
    else: intValue(message.metadata, "line", 0)
  resultKey(path, line)

proc messageId(message: ReplMessage): string =
  textValue(message.header, "msg_id")

proc parentMessageId(message: ReplMessage): string =
  textValue(message.parentHeader, "msg_id")

proc handleReplMessage*(session: ReplSession, message: ReplMessage): bool =
  ## Correlate the message classes needed by the first REPL slice. One
  ## execute_request owns one replaceable result bucket, while output messages
  ## append within that execution.
  if session == nil: return false
  let messageType = textValue(message.header, "msg_type")
  case messageType
  of "execute_request":
    inc session.executionCount
    let key = executionKey(message)
    session.results.clear(key.path, key.line)
    session.currentKey = key
    session.hasCurrentKey = true
    let id = messageId(message)
    if id.len > 0: session.activeExecutions[id] = key
    true
  of "execute_reply":
    true
  of "stream", "display_data", "execute_result", "error":
    var key: ResultKey
    let parentId = parentMessageId(message)
    if parentId.len > 0 and parentId in session.activeExecutions:
      key = session.activeExecutions[parentId]
    elif session.hasCurrentKey:
      key = session.currentKey
    else:
      return false
    session.results.addOutput(key.path, key.line, messageType, message.content)
    true
  else:
    false

proc processReplMessage*(session: ReplSession, message: ReplMessage): bool =
  handleReplMessage(session, message)
