## Debug Adapter Protocol transport and session core.
##
## The adapter boundary deliberately mirrors the useful part of Zed's DAP
## client: a bounded Content-Length transport, monotonically increasing
## request sequences, explicit pending-request ownership, and a session that
## can be stopped without touching unrelated process groups.  UI code consumes
## the decoded messages; this module never blocks the editor waiting for an
## adapter response.

import std/json
import std/os
import std/osproc
import std/streams
import std/strutils
import std/tables
import std/times
when defined(posix):
  import std/posix

when defined(posix):
  ## FileStream keeps its File field private.  This layout-compatible view is
  ## the same bounded non-blocking read boundary used by the LSP transport.
  type
    DapFileStreamObj = object of Stream
      f: File
    DapFileStream = ref DapFileStreamObj

type
  DapProtocolError* = object of CatchableError

  DapFrameDecoder* = object
    buffer*: string

  DapMessageType* = enum
    dapRequestMessage
    dapResponseMessage
    dapEventMessage

  DapMessage* = object
    messageType*: DapMessageType
    seq*: int
    command*: string
    arguments*: JsonNode
    requestSeq*: int
    success*: bool
    responseMessage*: string
    body*: JsonNode
    event*: string

  DapPendingRequest* = object
    seq*: int
    command*: string
    startedAtMs*: int64
    cancelled*: bool

  DapRequestTracker* = object
    nextSeq*: int
    pending*: Table[int, DapPendingRequest]

  DapSessionState* = enum
    dapStarting
    dapRunning
    dapStopped
    dapFailed

  DapSession* = ref object
    command*: string
    args*: seq[string]
    workingDir*: string
    state*: DapSessionState
    process: Process
    input: Stream
    output: Stream
    decoder*: DapFrameDecoder
    tracker*: DapRequestTracker

const
  MaxDapFrameBytes* = 16 * 1024 * 1024
  MaxDapHeaderBytes* = 64 * 1024
  MaxDapMessagesPerPoll* = 128
  DefaultDapRequestTimeoutMs* = 30_000'i64

proc protocolError(message: string): ref DapProtocolError =
  newException(DapProtocolError, message)

proc nowMs(): int64 = int64(epochTime() * 1000.0)

proc encodeDapMessage*(payload: JsonNode): string =
  ## DAP uses the same byte-counted framing as LSP.
  let body = $payload
  "Content-Length: " & $body.len & "\r\n\r\n" & body

proc parseContentLength(headers: string): int =
  var found = false
  for line in headers.split("\r\n"):
    let separator = line.find(':')
    if separator < 0: continue
    if line[0 ..< separator].strip.toLowerAscii != "content-length": continue
    if found: raise protocolError("duplicate Content-Length header")
    try:
      result = parseInt(line[separator + 1 .. ^1].strip)
    except ValueError:
      raise protocolError("invalid Content-Length header")
    if result < 0: raise protocolError("negative Content-Length header")
    found = true
  if not found: raise protocolError("missing Content-Length header")

proc feed*(decoder: var DapFrameDecoder, bytes: string,
           maxMessages = MaxDapMessagesPerPoll): seq[JsonNode] =
  ## Retain partial headers/bodies and cap one foreground poll's work.
  decoder.buffer.add(bytes)
  while result.len < max(1, maxMessages):
    let headerEnd = decoder.buffer.find("\r\n\r\n")
    if headerEnd < 0:
      if decoder.buffer.len > MaxDapHeaderBytes:
        raise protocolError("DAP headers exceed the maximum size")
      break
    let bodyLength = parseContentLength(decoder.buffer[0 ..< headerEnd])
    if bodyLength > MaxDapFrameBytes:
      raise protocolError("DAP frame exceeds the maximum size")
    let bodyStart = headerEnd + 4
    if decoder.buffer.len - bodyStart < bodyLength: break
    let bodyEnd = bodyStart + bodyLength
    try:
      result.add(parseJson(decoder.buffer[bodyStart ..< bodyEnd]))
    except JsonParsingError as error:
      raise protocolError("invalid DAP JSON body: " & error.msg)
    if bodyEnd == decoder.buffer.len:
      decoder.buffer.setLen(0)
    else:
      decoder.buffer = decoder.buffer[bodyEnd .. ^1]

proc initDapRequestTracker*(): DapRequestTracker =
  DapRequestTracker(nextSeq: 1, pending: initTable[int, DapPendingRequest]())

proc beginRequest*(tracker: var DapRequestTracker,
                   command: string): DapPendingRequest =
  result = DapPendingRequest(seq: tracker.nextSeq, command: command,
    startedAtMs: nowMs())
  inc tracker.nextSeq
  tracker.pending[result.seq] = result

proc finishRequest*(tracker: var DapRequestTracker, requestSeq: int): bool =
  if requestSeq notin tracker.pending: return false
  tracker.pending.del(requestSeq)
  true

proc acceptResponse*(tracker: var DapRequestTracker, requestSeq: int): bool =
  ## Consume a response only when its request is still current.  Cancelled or
  ## expired responses are deliberately dropped at the protocol boundary so
  ## stale stack/variables data cannot reach the editor UI.
  if requestSeq notin tracker.pending: return false
  let cancelled = tracker.pending[requestSeq].cancelled
  tracker.pending.del(requestSeq)
  not cancelled

proc pendingCount*(tracker: DapRequestTracker): int = tracker.pending.len

proc cancelRequest*(tracker: var DapRequestTracker, requestSeq: int): bool =
  if requestSeq notin tracker.pending: return false
  tracker.pending[requestSeq].cancelled = true
  true

proc expireRequests*(tracker: var DapRequestTracker, now: int64,
                     timeoutMs = DefaultDapRequestTimeoutMs): seq[int] =
  if timeoutMs <= 0: return
  for requestSeq, request in tracker.pending.mpairs:
    if not request.cancelled and now - request.startedAtMs >= timeoutMs:
      request.cancelled = true
      result.add(requestSeq)

proc parseMessage*(node: JsonNode): DapMessage =
  if node == nil or node.kind != JObject:
    raise protocolError("DAP message is not an object")
  let messageType = if node.hasKey("type"): node["type"].getStr else: ""
  result.seq = if node.hasKey("seq"): node["seq"].getInt else: 0
  case messageType
  of "request":
    result.messageType = dapRequestMessage
    result.command = if node.hasKey("command"): node["command"].getStr else: ""
    result.arguments = if node.hasKey("arguments"): node["arguments"] else: nil
  of "response":
    result.messageType = dapResponseMessage
    result.command = if node.hasKey("command"): node["command"].getStr else: ""
    result.requestSeq = if node.hasKey("request_seq"): node["request_seq"].getInt else: 0
    result.success = node.hasKey("success") and node["success"].getBool
    result.responseMessage = if node.hasKey("message"): node["message"].getStr else: ""
    result.body = if node.hasKey("body"): node["body"] else: nil
  of "event":
    result.messageType = dapEventMessage
    result.event = if node.hasKey("event"): node["event"].getStr else: ""
    result.body = if node.hasKey("body"): node["body"] else: nil
  else:
    raise protocolError("unsupported DAP message type: " & messageType)

proc requestJson*(request: DapPendingRequest, arguments: JsonNode = nil): JsonNode =
  result = %*{"seq": request.seq, "type": "request", "command": request.command}
  if arguments != nil: result["arguments"] = arguments

proc notificationJson*(command: string, arguments: JsonNode = nil): JsonNode =
  ## DAP calls client-originated notifications "requests" on the wire, but
  ## they still carry a monotonically increasing client sequence.  The caller
  ## allocates that sequence without retaining a pending response.
  result = %*{"seq": 0, "type": "request", "command": command}
  if arguments != nil: result["arguments"] = arguments

proc initializeArguments*(clientName = "Nimculus", adapterId = "nimculus",
                          linesStartAt1 = false, columnsStartAt1 = false): JsonNode =
  %*{
    "clientID": adapterId,
    "clientName": clientName,
    "adapterID": adapterId,
    "linesStartAt1": linesStartAt1,
    "columnsStartAt1": columnsStartAt1,
    "supportsRunInTerminalRequest": true,
    "supportsMemoryReferences": false
  }

proc configurationDoneArguments*(): JsonNode = %*{}
proc launchArguments*(program, cwd: string, args: seq[string] = @[]): JsonNode =
  result = %*{"program": program, "cwd": cwd}
  var values = newJArray()
  for arg in args: values.add(newJString(arg))
  result["args"] = values

proc attachArguments*(processId: int, cwd = ""): JsonNode =
  result = %*{"processId": processId}
  if cwd.len > 0: result["cwd"] = newJString(cwd)

proc setBreakpointsArguments*(source: string, lines: openArray[int]): JsonNode =
  result = %*{"source": {"path": source}}
  var breakpoints = newJArray()
  for line in lines: breakpoints.add(%*{"line": line})
  result["breakpoints"] = breakpoints

proc stackTraceArguments*(threadId: int, levels = 0): JsonNode =
  result = %*{"threadId": threadId}
  if levels > 0: result["levels"] = newJInt(levels)

proc scopesArguments*(frameId: int): JsonNode = %*{"frameId": frameId}
proc threadsArguments*(): JsonNode = %*{}
proc variablesArguments*(variablesReference: int): JsonNode =
  %*{"variablesReference": variablesReference}
proc continueArguments*(threadId: int): JsonNode = %*{"threadId": threadId}
proc evaluateArguments*(expression: string, frameId = 0): JsonNode =
  result = %*{"expression": expression, "context": "repl"}
  if frameId > 0: result["frameId"] = newJInt(frameId)

proc processOptions(): set[ProcessOption] = {poUsePath, poInteractive}

proc startDapSession*(command: string, args: openArray[string] = [],
                      workingDir = ""): DapSession =
  if command.strip.len == 0: raise protocolError("DAP command is empty")
  try:
    let process = startProcess(command, workingDir, args, options = processOptions())
    result = DapSession(command: command, args: @args, workingDir: workingDir,
      state: dapRunning, process: process, input: process.inputStream,
      output: process.peekableOutputStream(), tracker: initDapRequestTracker())
  except CatchableError as error:
    raise protocolError("could not start DAP adapter: " & error.msg)

proc startDapRemoteSession*(host: string, port: int, workingDir = ""): DapSession =
  ## Keep the UI/client contract identical for a TCP adapter.  `nc` is only a
  ## byte-stream bridge; DAP framing, request tracking, and bounded cleanup
  ## remain owned by this module.  This mirrors Zed's TCP transport without
  ## adding a second decoder or an unbounded socket reader.
  if host.strip.len == 0 or port <= 0 or port > 65535:
    raise protocolError("invalid remote DAP endpoint")
  let netcat = findExe("nc")
  if netcat.len == 0: raise protocolError("nc is required for remote DAP")
  startDapSession(netcat, [host, $port], workingDir)

proc isRunning*(session: DapSession): bool =
  session != nil and session.state == dapRunning and session.process != nil and
    session.process.peekExitCode() < 0

proc sendJson*(session: DapSession, payload: JsonNode) =
  if session == nil or not session.isRunning: raise protocolError("DAP session is not running")
  session.input.write(encodeDapMessage(payload))
  session.input.flush()

proc sendRequest*(session: DapSession, command: string,
                  arguments: JsonNode = nil): DapPendingRequest =
  if session == nil: raise protocolError("DAP session is nil")
  result = session.tracker.beginRequest(command)
  try:
    session.sendJson(result.requestJson(arguments))
  except CatchableError:
    discard session.tracker.finishRequest(result.seq)
    raise

proc sendNotification*(session: DapSession, command: string,
                       arguments: JsonNode = nil) =
  if session == nil: raise protocolError("DAP session is nil")
  let request = session.tracker.beginRequest(command)
  discard session.tracker.finishRequest(request.seq)
  session.sendJson(request.requestJson(arguments))

when defined(posix):
  proc outputReadable(session: DapSession): bool =
    if session == nil or session.process == nil: return false
    let stream = cast[DapFileStream](session.output)
    if stream == nil or stream.f == nil: return false
    let fd = cint(getOsFileHandle(stream.f))
    if fd < 0: return false
    var readSet: TFdSet = default(TFdSet)
    FD_ZERO(readSet)
    FD_SET(fd, readSet)
    var timeout = Timeval(tv_sec: posix.Time(0), tv_usec: Suseconds(0))
    let ready = posix.select(fd + 1, addr(readSet), nil, nil, addr(timeout))
    ready > 0 and FD_ISSET(fd, readSet) != 0

proc readMessages*(session: DapSession): seq[JsonNode] =
  if session == nil or session.process == nil or session.state != dapRunning: return
  result.add(session.decoder.feed("", MaxDapMessagesPerPoll))
  if result.len >= MaxDapMessagesPerPoll: return
  when defined(posix):
    let readable = session.outputReadable()
  else:
    let readable = session.process.hasData()
  if not readable: return
  when defined(posix):
    let stream = cast[DapFileStream](session.output)
    let fd = cint(getOsFileHandle(stream.f))
    var bytes: array[8192, char]
    while result.len < MaxDapMessagesPerPoll:
      let count = posix.read(fd, addr bytes[0], bytes.len)
      if count <= 0: break
      var chunk = newString(count)
      copyMem(addr chunk[0], addr bytes[0], count)
      let messages = session.decoder.feed(chunk, MaxDapMessagesPerPoll - result.len)
      for message in messages: result.add(message)
      if count < bytes.len: break
  else:
    let chunk = session.output.readStr(8192)
    if chunk.len > 0: result.add(session.decoder.feed(chunk, MaxDapMessagesPerPoll))

proc poll*(session: DapSession): seq[DapMessage] =
  if session == nil: return
  for node in session.readMessages():
    let message = node.parseMessage()
    if message.messageType == dapResponseMessage:
      if not session.tracker.acceptResponse(message.requestSeq): continue
    result.add(message)
  discard session.tracker.expireRequests(nowMs())
  if session.process != nil and session.process.peekExitCode() >= 0:
    let code = session.process.peekExitCode()
    session.state = if code == 0: dapStopped else: dapFailed

proc stop*(session: DapSession) =
  if session == nil: return
  if session.process != nil:
    if session.process.running:
      session.process.terminate()
      let exitCode = session.process.waitForExit(1_000)
      if exitCode < 0:
        session.process.kill()
        discard session.process.waitForExit(1_000)
    session.process.close()
  session.process = nil
  session.input = nil
  session.output = nil
  session.state = dapStopped
  session.tracker.pending.clear()

proc pendingCount*(session: DapSession): int =
  if session == nil: 0 else: session.tracker.pending.len
