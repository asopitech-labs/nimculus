import std/json
import std/strutils
import std/tables

type
  LspProtocolError* = object of CatchableError

  LspFrameDecoder* = object
    buffer*: string

  LspPendingRequest* = object
    id*: int
    methodName*: string
    generation*: uint64
    cancelled*: bool

  LspRequestTracker* = object
    nextId*: int
    nextGeneration*: uint64
    pending*: Table[int, LspPendingRequest]
    latestByMethod*: Table[string, int]

proc protocolError(message: string): ref LspProtocolError =
  newException(LspProtocolError, message)

proc encodeLspMessage*(payload: JsonNode): string =
  ## Encode one Language Server Protocol message. Content-Length is the UTF-8
  ## byte count, not the number of Unicode code points.
  let body = $payload
  "Content-Length: " & $body.len & "\r\n\r\n" & body

proc parseContentLength(headers: string): int =
  var found = false
  for line in headers.split("\r\n"):
    let separator = line.find(':')
    if separator < 0: continue
    let name = line[0 ..< separator].strip.toLowerAscii
    if name != "content-length": continue
    if found: raise protocolError("duplicate Content-Length header")
    try:
      result = parseInt(line[separator + 1 .. ^1].strip)
    except ValueError:
      raise protocolError("invalid Content-Length header")
    if result < 0: raise protocolError("negative Content-Length header")
    found = true
  if not found: raise protocolError("missing Content-Length header")

proc feed*(decoder: var LspFrameDecoder, bytes: string): seq[JsonNode] =
  ## Consume as many complete LSP frames as available. Partial headers and
  ## partial UTF-8 JSON bodies remain buffered for the next read.
  decoder.buffer.add(bytes)
  while true:
    let headerEnd = decoder.buffer.find("\r\n\r\n")
    if headerEnd < 0: break
    let bodyLength = parseContentLength(decoder.buffer[0 ..< headerEnd])
    let bodyStart = headerEnd + 4
    if decoder.buffer.len - bodyStart < bodyLength: break
    let bodyEnd = bodyStart + bodyLength
    let body = decoder.buffer[bodyStart ..< bodyEnd]
    try:
      result.add(parseJson(body))
    except JsonParsingError as error:
      raise protocolError("invalid JSON-RPC body: " & error.msg)
    decoder.buffer = decoder.buffer[bodyEnd .. ^1]
    if decoder.buffer.len == 0: break

proc initLspRequestTracker*(): LspRequestTracker =
  LspRequestTracker(nextId: 1, nextGeneration: 0,
    pending: initTable[int, LspPendingRequest](),
    latestByMethod: initTable[string, int]())

proc beginRequest*(tracker: var LspRequestTracker,
                   methodName: string): LspPendingRequest =
  result = LspPendingRequest(id: tracker.nextId, methodName: methodName,
    generation: tracker.nextGeneration + 1)
  inc tracker.nextId
  inc tracker.nextGeneration
  tracker.pending[result.id] = result
  tracker.latestByMethod[methodName] = result.id

proc requestJson*(request: LspPendingRequest, params: JsonNode = nil): JsonNode =
  result = newJObject()
  result["jsonrpc"] = newJString("2.0")
  result["id"] = newJInt(request.id)
  result["method"] = newJString(request.methodName)
  if params != nil: result["params"] = params

proc cancelRequest*(tracker: var LspRequestTracker, id: int): bool =
  if id notin tracker.pending: return false
  tracker.pending[id].cancelled = true
  true

proc acceptsResponse*(tracker: LspRequestTracker, id: int): bool =
  ## Only the newest request for a method may update the associated UI state.
  ## This mirrors Zed's generation/stale-response checks at the store boundary.
  if id notin tracker.pending: return false
  let request = tracker.pending[id]
  not request.cancelled and tracker.latestByMethod.getOrDefault(request.methodName, 0) == id

proc finishResponse*(tracker: var LspRequestTracker, id: int): bool =
  result = tracker.acceptsResponse(id)
  if id in tracker.pending:
    let request = tracker.pending[id]
    tracker.pending.del(id)
    if tracker.latestByMethod.getOrDefault(request.methodName, 0) == id:
      tracker.latestByMethod.del(request.methodName)

proc pendingCount*(tracker: LspRequestTracker): int = tracker.pending.len
