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
  ## FileStream keeps its File field private. The process output stream is a
  ## PipeOutStream<FileStream>; this layout-compatible view lets the macOS /
  ## POSIX LSP transport perform a genuinely non-blocking read on its fd.
  type
    NimculusFileStreamObj = object of Stream
      f: File
    NimculusFileStream = ref NimculusFileStreamObj

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

  LspPosition* = object
    line*: int
    character*: int

  LspRange* = object
    start*: LspPosition
    finish*: LspPosition

  LspDiagnostic* = object
    range*: LspRange
    severity*: int
    message*: string
    source*: string

  LspLocation* = object
    uri*: string
    range*: LspRange

  LspTextEdit* = object
    range*: LspRange
    newText*: string

  LspCompletionItem* = object
    label*: string
    detail*: string
    insertText*: string
    kind*: int

  LspCompletionResult* = object
    items*: seq[LspCompletionItem]
    isIncomplete*: bool

  LspHover* = object
    text*: string
    range*: LspRange
    hasRange*: bool

  LspSymbol* = object
    name*: string
    kind*: int
    range*: LspRange

  LspCodeAction* = object
    title*: string
    kind*: string
    edits*: seq[LspTextEdit]

  LspSignatureInformation* = object
    label*: string
    documentation*: string

  LspSignatureHelp* = object
    signatures*: seq[LspSignatureInformation]
    activeSignature*: int
    activeParameter*: int

  LspSemanticToken* = object
    line*: int
    startCharacter*: int
    length*: int
    tokenType*: int
    tokenModifiers*: int

  LspInlayHint* = object
    position*: LspPosition
    label*: string
    kind*: int

  LspWorkspaceEdit* = object
    uri*: string
    edits*: seq[LspTextEdit]

  LspSessionState* = enum
    lspSessionInitializing, lspSessionReady, lspSessionStopped, lspSessionFailed

  LspSession* = ref object
    process*: LspProcess
    tracker*: LspRequestTracker
    state*: LspSessionState
    rootUri*: string
    clientName*: string
    initializeId: int
    diagnostics: Table[string, seq[LspDiagnostic]]
    responses: Table[int, JsonNode]

proc protocolError(message: string): ref LspProtocolError =
  newException(LspProtocolError, message)

proc acceptsResponse*(tracker: LspRequestTracker, id: int): bool
proc finishResponse*(tracker: var LspRequestTracker, id: int): bool

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

proc positionJson*(position: LspPosition): JsonNode =
  %*{"line": position.line, "character": position.character}

proc rangeJson*(range: LspRange): JsonNode =
  %*{"start": positionJson(range.start), "end": positionJson(range.finish)}

proc textDocumentPositionJson(uri: string, position: LspPosition): JsonNode =
  %*{"textDocument": {"uri": uri}, "position": positionJson(position)}

proc initializeParams*(rootUri, clientName: string): JsonNode =
  result = %*{
    "processId": getCurrentProcessId(),
    "rootUri": rootUri,
    "clientInfo": {"name": clientName},
    "capabilities": {
      "textDocument": {
        "completion": {"completionItem": {"snippetSupport": true}},
        "publishDiagnostics": {"relatedInformation": true},
        "inlayHint": {"dynamicRegistration": false},
        "codeAction": {"codeActionLiteralSupport": {"codeActionKind":
          {"valueSet": ["", "quickfix", "refactor", "source"]}}},
        "semanticTokens": {"dynamicRegistration": false,
          "requests": {"full": true}, "tokenTypes": [], "tokenModifiers": []},
        "signatureHelp": {"signatureInformation": {"documentationFormat": ["plaintext", "markdown"]}},
        "documentSymbol": {"hierarchicalDocumentSymbolSupport": true}
      },
      "workspace": {"workspaceFolders": true, "workspaceEdit": {"documentChanges": true}}
    }
  }
  if rootUri.len == 0: result["rootUri"] = newJNull()

proc initializedNotification*(): JsonNode =
  %*{"jsonrpc": "2.0", "method": "initialized", "params": {}}

proc didOpenNotification*(uri, languageId, text: string, version: int): JsonNode =
  %*{"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": {
    "textDocument": {"uri": uri, "languageId": languageId, "version": version, "text": text}}}

proc didChangeNotification*(uri, text: string, version: int): JsonNode =
  ## Full-document synchronization is explicit until incremental LSP edits are
  ## connected to PieceTable transactions.
  %*{"jsonrpc": "2.0", "method": "textDocument/didChange", "params": {
    "textDocument": {"uri": uri, "version": version},
    "contentChanges": [{"text": text}]}}

proc didCloseNotification*(uri: string): JsonNode =
  %*{"jsonrpc": "2.0", "method": "textDocument/didClose", "params": {
    "textDocument": {"uri": uri}}}

proc completionRequest*(uri: string, position: LspPosition): tuple[methodName: string, params: JsonNode] =
  ("textDocument/completion", textDocumentPositionJson(uri, position))

proc hoverRequest*(uri: string, position: LspPosition): tuple[methodName: string, params: JsonNode] =
  ("textDocument/hover", textDocumentPositionJson(uri, position))

proc definitionRequest*(uri: string, position: LspPosition): tuple[methodName: string, params: JsonNode] =
  ("textDocument/definition", textDocumentPositionJson(uri, position))

proc referencesRequest*(uri: string, position: LspPosition,
                        includeDeclaration = true): tuple[methodName: string, params: JsonNode] =
  var params = textDocumentPositionJson(uri, position)
  params["context"] = %*{"includeDeclaration": includeDeclaration}
  ("textDocument/references", params)

proc documentSymbolRequest*(uri: string): tuple[methodName: string, params: JsonNode] =
  ("textDocument/documentSymbol", %*{"textDocument": {"uri": uri}})

proc renameRequest*(uri: string, position: LspPosition,
                    newName: string): tuple[methodName: string, params: JsonNode] =
  var params = textDocumentPositionJson(uri, position)
  params["newName"] = newJString(newName)
  ("textDocument/rename", params)

proc formattingRequest*(uri: string, tabSize = 2,
                        insertSpaces = true): tuple[methodName: string, params: JsonNode] =
  ("textDocument/formatting", %*{"textDocument": {"uri": uri},
    "options": {"tabSize": tabSize, "insertSpaces": insertSpaces}})

proc codeActionRequest*(uri: string, range: LspRange): tuple[methodName: string, params: JsonNode] =
  ("textDocument/codeAction", %*{"textDocument": {"uri": uri},
    "range": rangeJson(range), "context": {"diagnostics": []}})

proc signatureHelpRequest*(uri: string, position: LspPosition): tuple[methodName: string, params: JsonNode] =
  ("textDocument/signatureHelp", textDocumentPositionJson(uri, position))

proc semanticTokensRequest*(uri: string): tuple[methodName: string, params: JsonNode] =
  ("textDocument/semanticTokens/full", %*{"textDocument": {"uri": uri}})

proc inlayHintRequest*(uri: string, range: LspRange): tuple[methodName: string, params: JsonNode] =
  ("textDocument/inlayHint", %*{"textDocument": {"uri": uri}, "range": rangeJson(range)})

proc parseDiagnostics*(message: JsonNode): tuple[uri: string, diagnostics: seq[LspDiagnostic]] =
  if message == nil or message.kind != JObject or not message.hasKey("params"): return
  let params = message["params"]
  if params.kind != JObject: return
  if params.hasKey("uri"): result.uri = params["uri"].getStr
  if not params.hasKey("diagnostics") or params["diagnostics"].kind != JArray: return
  for item in params["diagnostics"]:
    if item.kind != JObject or not item.hasKey("range") or not item.hasKey("message"): continue
    let source = if item.hasKey("source"): item["source"].getStr else: ""
    let severity = if item.hasKey("severity"): item["severity"].getInt else: 1
    let start = item["range"]["start"]
    let finish = item["range"]["end"]
    result.diagnostics.add(LspDiagnostic(
      range: LspRange(
        start: LspPosition(line: start["line"].getInt, character: start["character"].getInt),
        finish: LspPosition(line: finish["line"].getInt, character: finish["character"].getInt)),
      severity: severity, message: item["message"].getStr, source: source))

proc parseRange(node: JsonNode): LspRange =
  if node == nil or node.kind != JObject: return
  let start = node["start"]
  let finish = node["end"]
  LspRange(start: LspPosition(line: start["line"].getInt,
      character: start["character"].getInt),
    finish: LspPosition(line: finish["line"].getInt,
      character: finish["character"].getInt))

proc parsePosition(node: JsonNode): LspPosition =
  if node == nil or node.kind != JObject: return
  LspPosition(line: if node.hasKey("line"): node["line"].getInt else: 0,
    character: if node.hasKey("character"): node["character"].getInt else: 0)

proc responseId*(message: JsonNode): int =
  if message != nil and message.kind == JObject and message.hasKey("id") and
      message["id"].kind == JInt: message["id"].getInt
  else: -1

proc responseResult*(message: JsonNode): JsonNode =
  if message != nil and message.kind == JObject and message.hasKey("result"):
    result = message["result"]

proc responseError*(message: JsonNode): string =
  if message != nil and message.kind == JObject and message.hasKey("error"):
    let error = message["error"]
    if error.kind == JObject and error.hasKey("message"): return error["message"].getStr
    return $error

proc acceptResponse*(tracker: var LspRequestTracker, message: JsonNode): bool =
  let id = responseId(message)
  if id < 0: return false
  result = tracker.acceptsResponse(id)
  discard tracker.finishResponse(id)

proc parseLocationNode(node: JsonNode): LspLocation =
  if node == nil or node.kind != JObject: return
  if node.hasKey("uri"): result.uri = node["uri"].getStr
  if node.hasKey("range"): result.range = parseRange(node["range"])

proc parseLocations*(message: JsonNode): seq[LspLocation] =
  let value = responseResult(message)
  if value == nil: return
  if value.kind == JObject:
    if value.hasKey("uri"): result.add(parseLocationNode(value))
  elif value.kind == JArray:
    for item in value:
      if item.kind == JObject and item.hasKey("uri"): result.add(parseLocationNode(item))

proc markedStringText(node: JsonNode): string =
  if node == nil: return
  case node.kind
  of JString: result = node.getStr
  of JObject:
    if node.hasKey("value"): result = node["value"].getStr
    elif node.hasKey("language") and node.hasKey("value"): result = node["value"].getStr
  else: result = $node

proc parseHover*(message: JsonNode): LspHover =
  let value = responseResult(message)
  if value == nil or value.kind != JObject or not value.hasKey("contents"): return
  let contents = value["contents"]
  if contents.kind == JArray:
    for item in contents:
      let text = markedStringText(item)
      if result.text.len > 0 and text.len > 0: result.text.add("\n")
      result.text.add(text)
  else:
    result.text = markedStringText(contents)
  if value.hasKey("range"):
    result.range = parseRange(value["range"])
    result.hasRange = true

proc parseCompletion*(message: JsonNode): LspCompletionResult =
  let value = responseResult(message)
  if value == nil: return
  var items = value
  if value.kind == JObject:
    if value.hasKey("isIncomplete"): result.isIncomplete = value["isIncomplete"].getBool
    if value.hasKey("items"): items = value["items"]
  if items.kind != JArray: return
  for item in items:
    if item.kind != JObject or not item.hasKey("label"): continue
    result.items.add(LspCompletionItem(
      label: item["label"].getStr,
      detail: if item.hasKey("detail"): item["detail"].getStr else: "",
      insertText: if item.hasKey("insertText"): item["insertText"].getStr else: item["label"].getStr,
      kind: if item.hasKey("kind"): item["kind"].getInt else: 0))

proc parseTextEdits*(message: JsonNode): seq[LspTextEdit] =
  let value = responseResult(message)
  if value == nil or value.kind != JArray: return
  for item in value:
    if item.kind == JObject and item.hasKey("range") and item.hasKey("newText"):
      result.add(LspTextEdit(range: parseRange(item["range"]), newText: item["newText"].getStr))

proc parseSymbols*(message: JsonNode): seq[LspSymbol] =
  let value = responseResult(message)
  if value == nil or value.kind != JArray: return
  for item in value:
    if item.kind != JObject or not item.hasKey("name"): continue
    let rangeNode = if item.hasKey("range"): item["range"] else: item["location"]["range"]
    result.add(LspSymbol(name: item["name"].getStr,
      kind: if item.hasKey("kind"): item["kind"].getInt else: 0,
      range: parseRange(rangeNode)))

proc parseCodeActions*(message: JsonNode): seq[LspCodeAction] =
  let value = responseResult(message)
  if value == nil or value.kind != JArray: return
  for item in value:
    if item.kind != JObject or not item.hasKey("title"): continue
    var action = LspCodeAction(title: item["title"].getStr,
      kind: if item.hasKey("kind"): item["kind"].getStr else: "")
    if item.hasKey("edit") and item["edit"].kind == JObject:
      if item["edit"].hasKey("changes"):
        for uri, edits in item["edit"]["changes"]:
          if edits.kind != JArray: continue
          for edit in edits:
            if edit.kind == JObject and edit.hasKey("range") and edit.hasKey("newText"):
              action.edits.add(LspTextEdit(range: parseRange(edit["range"]),
                newText: edit["newText"].getStr))
    result.add(action)

proc parseSignatureHelp*(message: JsonNode): LspSignatureHelp =
  let value = responseResult(message)
  if value == nil or value.kind != JObject: return
  result.activeSignature = if value.hasKey("activeSignature"): value["activeSignature"].getInt else: 0
  result.activeParameter = if value.hasKey("activeParameter"): value["activeParameter"].getInt else: 0
  if not value.hasKey("signatures") or value["signatures"].kind != JArray: return
  for signature in value["signatures"]:
    if signature.kind != JObject or not signature.hasKey("label"): continue
    result.signatures.add(LspSignatureInformation(label: signature["label"].getStr,
      documentation: if signature.hasKey("documentation"): markedStringText(signature["documentation"]) else: ""))

proc parseSemanticTokens*(message: JsonNode): seq[LspSemanticToken] =
  let value = responseResult(message)
  if value == nil or value.kind != JObject or not value.hasKey("data") or
      value["data"].kind != JArray: return
  var line = 0
  var start = 0
  let data = value["data"]
  var index = 0
  while index + 4 < data.len:
    let deltaLine = data[index].getInt
    let deltaStart = data[index + 1].getInt
    line += deltaLine
    start = if deltaLine == 0: start + deltaStart else: deltaStart
    result.add(LspSemanticToken(line: line, startCharacter: start,
      length: data[index + 2].getInt, tokenType: data[index + 3].getInt,
      tokenModifiers: data[index + 4].getInt))
    inc index, 5

proc parseInlayHints*(message: JsonNode): seq[LspInlayHint] =
  let value = responseResult(message)
  if value == nil or value.kind != JArray: return
  for item in value:
    if item.kind != JObject or not item.hasKey("position") or not item.hasKey("label"): continue
    let label = if item["label"].kind == JString: item["label"].getStr else: $item["label"]
    result.add(LspInlayHint(position: parsePosition(item["position"]), label: label,
      kind: if item.hasKey("kind"): item["kind"].getInt else: 0))

proc parseWorkspaceEdit*(message: JsonNode): seq[LspWorkspaceEdit] =
  let value = responseResult(message)
  if value == nil or value.kind != JObject or not value.hasKey("changes"): return
  for uri, edits in value["changes"]:
    if edits.kind != JArray: continue
    var workspaceEdit = LspWorkspaceEdit(uri: uri)
    for edit in edits:
      if edit.kind == JObject and edit.hasKey("range") and edit.hasKey("newText"):
        workspaceEdit.edits.add(LspTextEdit(range: parseRange(edit["range"]),
          newText: edit["newText"].getStr))
    result.add(workspaceEdit)

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
    client.process.peekExitCode() < 0

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
  if client == nil or client.process == nil or client.state != lspRunning: return
  ## A pipe read is allowed to block until the requested buffer is filled on
  ## some platforms. Wait for readiness first so a short LSP response is not
  ## held hostage by the 4 KiB scratch buffer.
  if not client.process.hasData():
    # No readable bytes is the normal idle state for a non-blocking poll. Only
    # transition the process when the child has actually exited; otherwise an
    # editor with an idle language server would be marked failed between
    # diagnostics notifications.
    let exitCode = client.process.peekExitCode()
    if exitCode >= 0:
      client.state = if exitCode == 0: lspStopped else: lspFailed
    return
  when defined(posix):
    let stream = cast[NimculusFileStream](client.output)
    if stream == nil or stream.f == nil: return
    let fd = cint(getOsFileHandle(stream.f))
    let flags = fcntl(fd, F_GETFL)
    if flags < 0 or fcntl(fd, F_SETFL, flags or O_NONBLOCK) < 0:
      raise protocolError("cannot configure non-blocking LSP stdout")
    var chunk = newStringOfCap(4096)
    var bytes: array[4096, char]
    while chunk.len < 65536:
      let count = posix.read(fd, addr bytes[0], bytes.len)
      if count > 0:
        let oldLength = chunk.len
        chunk.setLen(oldLength + count)
        copyMem(addr chunk[oldLength], addr bytes[0], count)
      elif count == 0:
        let exitCode = client.process.peekExitCode()
        client.state = if exitCode == 0: lspStopped else: lspFailed
        break
      elif errno == EAGAIN or errno == EWOULDBLOCK:
        break
      else:
        client.state = lspFailed
        break
    if chunk.len > 0:
      result.add(client.decoder.feed(chunk))
  else:
    # Non-POSIX builds retain the portable stream path. The macOS-first
    # implementation above is the non-blocking path used by Nimculus today.
    let chunk = client.output.readStr(1)
    if chunk.len > 0: result.add(client.decoder.feed(chunk))

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

proc startLspSession*(command: string, args: openArray[string],
                      rootUri, clientName: string): LspSession =
  result = LspSession(process: startLspProcess(command, args),
    tracker: initLspRequestTracker(), state: lspSessionInitializing,
    rootUri: rootUri, clientName: clientName,
    diagnostics: initTable[string, seq[LspDiagnostic]](),
    responses: initTable[int, JsonNode]())
  let request = result.process.sendRequest(result.tracker, "initialize",
    initializeParams(rootUri, clientName))
  result.initializeId = request.id

proc poll*(session: LspSession): seq[JsonNode] =
  ## Consume one worker-task read and apply protocol-level session updates.
  ## Feature-specific response decoding remains at the caller boundary.
  if session == nil or session.state in {lspSessionStopped, lspSessionFailed}: return
  for message in session.process.readMessages():
    result.add(message)
    if message.kind != JObject: continue
    if message.hasKey("method") and message["method"].getStr == "textDocument/publishDiagnostics":
      let parsed = parseDiagnostics(message)
      session.diagnostics[parsed.uri] = parsed.diagnostics
    if not message.hasKey("id") or message["id"].kind != JInt: continue
    let id = message["id"].getInt
    if id == session.initializeId and session.tracker.acceptsResponse(id):
      discard session.tracker.finishResponse(id)
      session.state = lspSessionReady
      if session.process.isRunning:
        session.process.send(initializedNotification())
    else:
      if session.tracker.acceptsResponse(id):
        session.responses[id] = message
      discard session.tracker.finishResponse(id)
  if not session.process.isRunning:
    session.state = if session.process.state == lspStopped: lspSessionStopped else: lspSessionFailed

proc request*(session: LspSession, methodName: string,
              params: JsonNode = nil): LspPendingRequest =
  if session == nil or session.state != lspSessionReady:
    raise protocolError("LSP session is not initialized")
  session.process.sendRequest(session.tracker, methodName, params)

proc cancel*(session: LspSession, id: int): bool =
  if session == nil or id <= 0 or session.process == nil: return false
  if not session.tracker.cancelRequest(id): return false
  try:
    session.process.send(cancelJson(id))
    result = true
  except CatchableError:
    discard

proc takeResponse*(session: LspSession, id: int): JsonNode =
  if session == nil or id notin session.responses: return
  result = session.responses[id]
  session.responses.del(id)

proc notify*(session: LspSession, methodName: string, params: JsonNode = nil) =
  if session == nil or session.state != lspSessionReady:
    raise protocolError("LSP session is not initialized")
  session.process.sendNotification(methodName, params)

proc diagnosticsFor*(session: LspSession, uri: string): seq[LspDiagnostic] =
  if session != nil and uri in session.diagnostics: result = session.diagnostics[uri]

proc stop*(session: LspSession) =
  if session == nil: return
  discard session.process.stop()
  session.state = lspSessionStopped

proc restart*(session: LspSession) =
  if session == nil: return
  session.process.restart()
  session.tracker = initLspRequestTracker()
  session.diagnostics.clear()
  session.responses.clear()
  session.state = lspSessionInitializing
  let request = session.process.sendRequest(session.tracker, "initialize",
    initializeParams(session.rootUri, session.clientName))
  session.initializeId = request.id
