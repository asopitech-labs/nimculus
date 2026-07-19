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
    discard bridge.session.cancel(bridge.completionRequestId)
  bridge.completionRequestId = 0
  bridge.completionItems.setLen(0)
  bridge.completionSelected = 0
  bridge.completionVisible = false

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
