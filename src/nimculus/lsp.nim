import std/json
import std/osproc
import std/streams
import std/strutils
import std/tables
import std/times

type
  LspProtocolError* = object of CatchableError

  LspFrameDecoder* = object
    buffer*: string

  LspPendingRequest* = object
    id*: int
    methodName*: string
    generation*: uint64
    cancelled*: bool
    startedAtMs*: int64

  LspRequestTracker* = object
    nextId*: int
    nextGeneration*: uint64
    pending*: Table[int, LspPendingRequest]
    latestByMethod*: Table[string, int]

  LspProcessState* = enum
    lspRunning, lspStopped, lspFailed

  LspProcess* = ref object
    command*: string
    args*: seq[string]
    workingDir*: string
    state*: LspProcessState
    process: Process
    input: Stream
    output: Stream
    decoder*: LspFrameDecoder

proc protocolError(message: string): ref LspProtocolError =
  newException(LspProtocolError, message)

proc nowMs(): int64 = int64(epochTime() * 1000.0)

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
    generation: tracker.nextGeneration + 1, startedAtMs: nowMs())
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

proc expireRequests*(tracker: var LspRequestTracker, now: int64,
                     timeoutMs: int64): seq[int] =
  ## Mark timed-out requests cancelled. The caller can send the returned IDs
  ## as JSON-RPC $/cancelRequest notifications without touching UI state.
  if timeoutMs <= 0: return
  for id, request in tracker.pending.mpairs:
    if not request.cancelled and now - request.startedAtMs >= timeoutMs:
      request.cancelled = true
      result.add(id)

proc cancelJson*(id: int): JsonNode =
  %*{"jsonrpc": "2.0", "method": "$/cancelRequest", "params": {"id": id}}

proc startLspProcess*(command: string, args: openArray[string] = [],
                      workingDir = ""): LspProcess =
  if command.len == 0: raise protocolError("LSP command is empty")
  ## Keep stderr separate from stdout: LSP stdout is a framed protocol and
  ## diagnostic logging must never corrupt it. poInteractive keeps the pipe
  ## responsive for language servers that flush after each response.
  let process = startProcess(command, workingDir, args,
    options = {poUsePath, poInteractive})
  result = LspProcess(command: command, args: @args, workingDir: workingDir,
    state: lspRunning, process: process, input: process.inputStream,
    output: process.peekableOutputStream())

proc isRunning*(client: LspProcess): bool =
  client != nil and client.state == lspRunning and client.process != nil and
    client.process.running

proc send*(client: LspProcess, payload: JsonNode) =
  if client == nil or not client.isRunning: raise protocolError("LSP process is not running")
  client.input.write(encodeLspMessage(payload))
  client.input.flush()

proc sendRequest*(client: LspProcess, tracker: var LspRequestTracker,
                  methodName: string, params: JsonNode = nil): LspPendingRequest =
  result = tracker.beginRequest(methodName)
  try:
    client.send(result.requestJson(params))
  except CatchableError:
    discard tracker.finishResponse(result.id)
    raise

proc sendNotification*(client: LspProcess, methodName: string,
                       params: JsonNode = nil) =
  var request = newJObject()
  request["jsonrpc"] = newJString("2.0")
  request["method"] = newJString(methodName)
  if params != nil: request["params"] = params
  client.send(request)

proc readMessages*(client: LspProcess): seq[JsonNode] =
  ## Read one blocking pipe chunk and decode all complete messages in it.
  ## Call this from the app's worker/event task, never from the rendering
  ## callback; the decoder itself remains incremental and non-lossy.
  if client == nil or not client.isRunning: return
  ## A pipe read is allowed to block until the requested buffer is filled on
  ## some platforms. Wait for readiness first so a short LSP response is not
  ## held hostage by the 4 KiB scratch buffer.
  if not client.process.hasData():
    client.state = if client.process.peekExitCode() == 0: lspStopped else: lspFailed
    return
  let chunk = client.output.readStr(4096)
  if chunk.len == 0:
    client.state = if client.process.peekExitCode() == 0: lspStopped else: lspFailed
    return
  client.decoder.feed(chunk)

proc stop*(client: LspProcess, terminate = true): int =
  if client == nil or client.process == nil: return -1
  if client.process.running and terminate:
    client.process.terminate()
  result = client.process.waitForExit()
  client.process.close()
  client.state = if result == 0: lspStopped else: lspFailed

proc restart*(client: LspProcess) =
  if client == nil: return
  discard client.stop()
  let process = startProcess(client.command, client.workingDir, client.args,
    options = {poUsePath, poInteractive})
  client.process = process
  client.input = process.inputStream
  client.output = process.peekableOutputStream()
  client.decoder = LspFrameDecoder()
  client.state = lspRunning
