import std/os
import std/strutils
import nimculus/lsp
import nimculus/editor_buffer
import nimculus/editor_view

type
  LspEditorBridge* = ref object
    command*: string
    args*: seq[string]
    rootUri*: string
    session*: LspSession
    path*: string
    uri*: string
    languageId*: string
    version*: int
    opened*: bool
    lastText*: string
    lastError*: string
    completionItems*: seq[LspCompletionItem]
    completionSelected*: int
    completionRequestId*: int
    completionCursorByte*: int
    completionVisible*: bool
    hoverRequestId*: int
    hoverCursorByte*: int
    hoverTargetByte*: int
    hoverDelayTicks*: int
    hoverText*: string
    hoverVisible*: bool
    definitionRequestId*: int
    definitionCursorByte*: int
    definitionLocations*: seq[LspLocation]
    formattingRequestId*: int
    formattingVersion*: int
    formattingEdits*: seq[LspTextEdit]
    formattingReady*: bool

proc hexDigit(value: int): char =
  if value < 10: char(ord('0') + value)
  else: char(ord('A') + value - 10)

proc fileUri*(path: string): string =
  ## Encode a local path as an RFC 8089-compatible file URI. Keep path
  ## separators readable while escaping bytes that are not URI-safe.
  let absolute = absolutePath(path)
  result = "file://"
  for value in absolute:
    let code = ord(value)
    if value in {'A'..'Z', 'a'..'z', '0'..'9', '/', '-', '_', '.', '~'}:
      result.add(value)
    else:
      result.add('%')
      result.add(hexDigit((code shr 4) and 0xF))
      result.add(hexDigit(code and 0xF))

proc filePathFromUri*(uri: string): string =
  if not uri.startsWith("file://"): return ""
  let encoded = uri[7 .. ^1]
  var index = 0
  while index < encoded.len:
    if encoded[index] == '%' and index + 2 < encoded.len:
      let high = encoded[index + 1].toUpperAscii
      let low = encoded[index + 2].toUpperAscii
      proc nibble(value: char): int =
        if value in {'0'..'9'}: ord(value) - ord('0')
        elif value in {'A'..'F'}: ord(value) - ord('A') + 10
        else: -1
      let highValue = nibble(high)
      let lowValue = nibble(low)
      if highValue >= 0 and lowValue >= 0:
        result.add(char((highValue shl 4) or lowValue))
        index += 3
        continue
    result.add(encoded[index])
    inc index
  result = absolutePath(result)

proc languageIdForPath*(path: string): string =
  case splitFile(path).ext.toLowerAscii
  of ".nim": "nim"
  of ".rs": "rust"
  of ".ts": "typescript"
  of ".py": "python"
  of ".json": "json"
  of ".md", ".markdown": "markdown"
  else: "plaintext"

proc newLspEditorBridge*(command: string, args: openArray[string] = [],
                         rootUri = ""): LspEditorBridge =
  LspEditorBridge(command: command, args: @args, rootUri: rootUri, version: 0)

proc hideCompletion*(bridge: LspEditorBridge) =
  if bridge == nil: return
  if bridge.completionRequestId > 0 and bridge.session != nil:
    discard bridge.session.takeResponse(bridge.completionRequestId)
    discard bridge.session.cancel(bridge.completionRequestId)
  bridge.completionRequestId = 0
  bridge.completionItems.setLen(0)
  bridge.completionSelected = 0
  bridge.completionVisible = false

proc hideHover*(bridge: LspEditorBridge) =
  if bridge == nil: return
  if bridge.hoverRequestId > 0 and bridge.session != nil:
    discard bridge.session.takeResponse(bridge.hoverRequestId)
    discard bridge.session.cancel(bridge.hoverRequestId)
  bridge.hoverRequestId = 0
  bridge.hoverText = ""
  bridge.hoverVisible = false

proc hideDefinition*(bridge: LspEditorBridge) =
  if bridge == nil: return
  if bridge.definitionRequestId > 0 and bridge.session != nil:
    discard bridge.session.takeResponse(bridge.definitionRequestId)
    discard bridge.session.cancel(bridge.definitionRequestId)
  bridge.definitionRequestId = 0
  bridge.definitionLocations.setLen(0)

proc hideFormatting*(bridge: LspEditorBridge) =
  if bridge == nil: return
  if bridge.formattingRequestId > 0 and bridge.session != nil:
    discard bridge.session.takeResponse(bridge.formattingRequestId)
    discard bridge.session.cancel(bridge.formattingRequestId)
  bridge.formattingRequestId = 0
  bridge.formattingVersion = 0
  bridge.formattingEdits.setLen(0)
  bridge.formattingReady = false

proc requestFormatting*(bridge: LspEditorBridge): bool =
  if bridge == nil or bridge.session == nil or bridge.session.state != lspSessionReady or
      bridge.uri.len == 0: return false
  bridge.hideFormatting()
  let request = formattingRequest(bridge.uri)
  try:
    let pending = bridge.session.request(request.methodName, request.params)
    bridge.formattingRequestId = pending.id
    bridge.formattingVersion = bridge.version
    result = true
  except CatchableError:
    bridge.lastError = getCurrentExceptionMsg()

proc takeFormattingEdits*(bridge: LspEditorBridge): seq[LspTextEdit] =
  if bridge == nil or not bridge.formattingReady: return
  result = bridge.formattingEdits
  bridge.formattingEdits.setLen(0)
  bridge.formattingReady = false

proc requestDefinition*(bridge: LspEditorBridge, buffer: PieceTable,
                        cursorByte: int): bool =
  if bridge == nil or bridge.session == nil or bridge.session.state != lspSessionReady or
      bridge.uri.len == 0: return false
  bridge.hideDefinition()
  let position = buffer.utf16Position(cursorByte)
  let request = definitionRequest(bridge.uri,
    LspPosition(line: position.line, character: position.character))
  try:
    let pending = bridge.session.request(request.methodName, request.params)
    bridge.definitionRequestId = pending.id
    bridge.definitionCursorByte = max(0, min(cursorByte, buffer.toString().len))
    result = true
  except CatchableError:
    bridge.lastError = getCurrentExceptionMsg()

proc takeDefinitionLocations*(bridge: LspEditorBridge): seq[LspLocation] =
  if bridge == nil: return
  result = bridge.definitionLocations
  bridge.definitionLocations.setLen(0)

proc scheduleHover*(bridge: LspEditorBridge, cursorByte: int) =
  if bridge == nil: return
  let target = max(0, cursorByte)
  if bridge.hoverTargetByte == target and
      (bridge.hoverDelayTicks > 0 or bridge.hoverRequestId > 0 or
       bridge.hoverVisible):
    return
  bridge.hideHover()
  bridge.hoverTargetByte = target
  bridge.hoverDelayTicks = 5

proc requestHover*(bridge: LspEditorBridge, buffer: PieceTable,
                   cursorByte: int): bool =
  if bridge == nil or bridge.session == nil or bridge.session.state != lspSessionReady or
      bridge.uri.len == 0: return false
  let position = buffer.utf16Position(cursorByte)
  let request = hoverRequest(bridge.uri,
    LspPosition(line: position.line, character: position.character))
  try:
    let pending = bridge.session.request(request.methodName, request.params)
    bridge.hoverRequestId = pending.id
    bridge.hoverCursorByte = max(0, min(cursorByte, buffer.toString().len))
    result = true
  except CatchableError:
    bridge.lastError = getCurrentExceptionMsg()

proc tickHover*(bridge: LspEditorBridge, buffer: PieceTable): bool =
  if bridge == nil or bridge.hoverDelayTicks <= 0: return false
  dec bridge.hoverDelayTicks
  if bridge.hoverDelayTicks == 0:
    result = bridge.requestHover(buffer, bridge.hoverTargetByte)

proc hoverText*(bridge: LspEditorBridge): string =
  if bridge != nil and bridge.hoverVisible: result = bridge.hoverText

proc requestCompletion*(bridge: LspEditorBridge, buffer: PieceTable,
                        cursorByte: int): bool =
  if bridge == nil or bridge.session == nil or bridge.session.state != lspSessionReady or
      bridge.uri.len == 0: return false
  bridge.hideCompletion()
  let position = buffer.utf16Position(cursorByte)
  let request = completionRequest(bridge.uri,
    LspPosition(line: position.line, character: position.character))
  try:
    let pending = bridge.session.request(request.methodName, request.params)
    bridge.completionRequestId = pending.id
    bridge.completionCursorByte = max(0, min(cursorByte, buffer.toString().len))
    result = true
  except CatchableError:
    bridge.lastError = getCurrentExceptionMsg()

proc completionText*(bridge: LspEditorBridge): string =
  if bridge == nil or not bridge.completionVisible: return
  for index, item in bridge.completionItems:
    if index > 0: result.add('\n')
    result.add(if index == bridge.completionSelected: "> " else: "  ")
    result.add(item.label)
    if item.detail.len > 0: result.add(" — " & item.detail)

proc selectedCompletion*(bridge: LspEditorBridge): LspCompletionItem =
  if bridge == nil or bridge.completionItems.len == 0: return
  let index = max(0, min(bridge.completionSelected, bridge.completionItems.high))
  bridge.completionItems[index]

proc completionEdit*(bridge: LspEditorBridge, buffer: PieceTable):
    tuple[startByte, endByte: int, text: string] =
  if bridge == nil or not bridge.completionVisible or bridge.completionItems.len == 0: return
  let item = bridge.selectedCompletion()
  let source = buffer.toString()
  var start = min(max(0, bridge.completionCursorByte), source.len)
  start = previousWordBoundary(source, start)
  (startByte: start, endByte: bridge.completionCursorByte,
   text: if item.insertText.len > 0: item.insertText else: item.label)

proc closeDocument*(bridge: LspEditorBridge) =
  if bridge == nil: return
  bridge.hideCompletion()
  if bridge.session != nil and bridge.opened and bridge.uri.len > 0 and
      bridge.session.state == lspSessionReady:
    try: bridge.session.notify("textDocument/didClose", didCloseNotification(bridge.uri))
    except CatchableError: discard
  bridge.opened = false
  bridge.uri = ""
  bridge.path = ""
  bridge.languageId = ""
  bridge.lastText = ""
  bridge.version = 0
  bridge.hideHover()
  bridge.hideDefinition()
  bridge.hideFormatting()

proc updateDocument*(bridge: LspEditorBridge, path, text: string) =
  if bridge == nil or bridge.command.len == 0 or path.len == 0: return
  let nextUri = fileUri(path)
  let nextLanguage = languageIdForPath(path)
  if bridge.uri != nextUri:
    bridge.closeDocument()
    bridge.uri = nextUri
    bridge.path = absolutePath(path)
    bridge.languageId = nextLanguage
    bridge.lastText = text
    bridge.version = 1
  elif bridge.languageId != nextLanguage:
    bridge.languageId = nextLanguage
  if bridge.session == nil:
    try:
      bridge.session = startLspSession(bridge.command, bridge.args, bridge.rootUri, "Nimculus")
    except CatchableError:
      bridge.session = nil
      return
  elif bridge.session.state in {lspSessionStopped, lspSessionFailed}:
    try:
      bridge.session.restart()
      bridge.opened = false
    except CatchableError:
      bridge.lastError = getCurrentExceptionMsg()
      return
  if bridge.session.state != lspSessionReady: return
  try:
    if not bridge.opened:
      bridge.session.notify("textDocument/didOpen",
        didOpenNotification(bridge.uri, bridge.languageId, text, bridge.version))
      bridge.opened = true
      bridge.lastText = text
    elif bridge.lastText != text:
      bridge.hideCompletion()
      bridge.hideHover()
      bridge.hideDefinition()
      bridge.hideFormatting()
      inc bridge.version
      bridge.session.notify("textDocument/didChange",
        didChangeNotification(bridge.uri, text, bridge.version))
      bridge.lastText = text
  except CatchableError:
    bridge.lastError = getCurrentExceptionMsg()
    bridge.session.state = lspSessionFailed

proc poll*(bridge: LspEditorBridge): bool =
  ## Poll only already-readable bytes; this is safe to call from the UI event
  ## boundary and never waits for a full LSP response.
  if bridge == nil or bridge.session == nil: return false
  if bridge.session.state in {lspSessionStopped, lspSessionFailed} and bridge.path.len > 0:
    bridge.updateDocument(bridge.path, bridge.lastText)
    return bridge.session != nil and bridge.session.state == lspSessionInitializing
  let before = bridge.session.state
  var messageCount = 0
  try:
    messageCount = bridge.session.poll().len
  except CatchableError:
    bridge.lastError = getCurrentExceptionMsg()
    bridge.session.state = lspSessionFailed
    return false
  if bridge.completionRequestId > 0:
    let response = bridge.session.takeResponse(bridge.completionRequestId)
    if response != nil:
      let completion = parseCompletion(response)
      bridge.completionItems = completion.items
      bridge.completionSelected = 0
      bridge.completionVisible = completion.items.len > 0
      bridge.completionRequestId = 0
      result = true
  if bridge.hoverRequestId > 0:
    let response = bridge.session.takeResponse(bridge.hoverRequestId)
    if response != nil:
      let hover = parseHover(response)
      bridge.hoverText = hover.text
      bridge.hoverVisible = hover.text.len > 0 and bridge.hoverCursorByte == bridge.hoverTargetByte
      bridge.hoverRequestId = 0
      result = true
  if bridge.definitionRequestId > 0:
    let response = bridge.session.takeResponse(bridge.definitionRequestId)
    if response != nil:
      bridge.definitionLocations = parseLocations(response)
      bridge.definitionRequestId = 0
      result = true
  if bridge.formattingRequestId > 0:
    let response = bridge.session.takeResponse(bridge.formattingRequestId)
    if response != nil:
      if bridge.formattingVersion == bridge.version:
        bridge.formattingEdits = parseTextEdits(response)
        bridge.formattingReady = true
      bridge.formattingRequestId = 0
      result = true
  if bridge.session.state == lspSessionReady and not bridge.opened and
      bridge.path.len > 0:
    bridge.updateDocument(bridge.path, bridge.lastText)
    return bridge.opened or messageCount > 0
  result = result or before != bridge.session.state or messageCount > 0

proc diagnostics*(bridge: LspEditorBridge): seq[LspDiagnostic] =
  if bridge != nil and bridge.session != nil and bridge.uri.len > 0:
    result = bridge.session.diagnosticsFor(bridge.uri)

proc stop*(bridge: LspEditorBridge) =
  if bridge == nil: return
  bridge.closeDocument()
  if bridge.session != nil: bridge.session.stop()
  bridge.session = nil
