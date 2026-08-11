import std/os
import std/json
import std/strutils
import std/tables
import nimculus/lsp
import nimculus/editor_buffer
import nimculus/editor_view

type
  LspRequestKind* = enum
    lspCompletionRequest, lspHoverRequest, lspDefinitionRequest,
    lspFormattingRequest, lspReferencesRequest, lspSymbolsRequest,
    lspCodeActionsRequest, lspCodeActionResolveRequest,
    lspExecuteCommandRequest, lspRenameRequest, lspSignatureRequest,
    lspSemanticTokensRequest, lspInlayHintsRequest

  LspDocumentState = object
    path: string
    uri: string
    languageId: string
    version: int
    opened: bool
    lastText: string

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
    requests*: Table[LspRequestKind, int]
    completionCursorByte*: int
    completionVersion*: int
    completionVisible*: bool
    hoverCursorByte*: int
    hoverTargetByte*: int
    hoverDelayTicks*: int
    hoverVersion*: int
    hoverText*: string
    hoverVisible*: bool
    definitionCursorByte*: int
    definitionLocations*: seq[LspLocation]
    formattingVersion*: int
    formattingEdits*: seq[LspTextEdit]
    formattingReady*: bool
    referenceLocations*: seq[LspLocation]
    symbols*: seq[LspSymbol]
    codeActions*: seq[LspCodeAction]
    resolvedCodeAction*: LspCodeAction
    commandEdits*: seq[LspWorkspaceEdit]
    renameEdits*: seq[LspWorkspaceEdit]
    signatureHelp*: LspSignatureHelp
    semanticTokens*: seq[LspSemanticToken]
    inlayHintsRequestPath*: string
    inlayHintsRequestVersion*: int
    inlayHintsPath*: string
    inlayHints*: seq[LspInlayHint]
    inlayHintsByUri*: Table[string, seq[LspInlayHint]]
    ## LSP document lifetime is independent of which pane currently owns
    ## requests. Zed keeps buffers open while panes switch focus; doing the
    ## same here preserves diagnostics for both sides of a split editor.
    documents: Table[string, LspDocumentState]

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
  of ".ts", ".mts", ".cts": "typescript"
  of ".tsx": "typescriptreact"
  of ".py": "python"
  of ".json": "json"
  of ".md", ".markdown": "markdown"
  else: "plaintext"

proc initLspRequestTable(): Table[LspRequestKind, int] =
  result = initTable[LspRequestKind, int]()
  for kind in LspRequestKind:
    result[kind] = 0

const allLspRequestKinds = {lspCompletionRequest, lspHoverRequest,
  lspDefinitionRequest, lspFormattingRequest, lspReferencesRequest,
  lspSymbolsRequest, lspCodeActionsRequest, lspCodeActionResolveRequest,
  lspExecuteCommandRequest, lspRenameRequest, lspSignatureRequest,
  lspSemanticTokensRequest, lspInlayHintsRequest}

proc requestId(bridge: LspEditorBridge, kind: LspRequestKind): int =
  if bridge != nil:
    result = bridge.requests.getOrDefault(kind)

proc cancelRequest(bridge: LspEditorBridge, kind: LspRequestKind) =
  if bridge == nil: return
  let requestId = bridge.requestId(kind)
  if requestId > 0 and bridge.session != nil:
    discard bridge.session.takeResponse(requestId)
    discard bridge.session.cancel(requestId)
  bridge.requests[kind] = 0

proc evictRequests*(bridge: LspEditorBridge, kinds: set[LspRequestKind]) =
  if bridge == nil: return
  for kind in kinds:
    bridge.cancelRequest(kind)

proc newLspEditorBridge*(command: string, args: openArray[string] = [],
                         rootUri = ""): LspEditorBridge =
  LspEditorBridge(command: command, args: @args, rootUri: rootUri, version: 0,
    requests: initLspRequestTable(), documents: initTable[string, LspDocumentState]())

proc hideCompletion*(bridge: LspEditorBridge) =
  if bridge == nil: return
  bridge.cancelRequest(lspCompletionRequest)
  bridge.completionItems.setLen(0)
  bridge.completionSelected = 0
  bridge.completionVisible = false

proc hideHover*(bridge: LspEditorBridge) =
  if bridge == nil: return
  bridge.cancelRequest(lspHoverRequest)
  bridge.hoverText = ""
  bridge.hoverVisible = false

proc hideDefinition*(bridge: LspEditorBridge) =
  if bridge == nil: return
  bridge.cancelRequest(lspDefinitionRequest)
  bridge.definitionLocations.setLen(0)

proc hideFormatting*(bridge: LspEditorBridge) =
  if bridge == nil: return
  bridge.cancelRequest(lspFormattingRequest)
  bridge.formattingVersion = 0
  bridge.formattingEdits.setLen(0)
  bridge.formattingReady = false

proc requestReferences*(bridge: LspEditorBridge, buffer: PieceTable,
                        cursorByte: int): bool =
  if bridge == nil or bridge.session == nil or bridge.session.state != lspSessionReady or
      bridge.uri.len == 0: return false
  bridge.cancelRequest(lspReferencesRequest)
  let position = buffer.utf16Position(cursorByte)
  let request = referencesRequest(bridge.uri, LspPosition(line: position.line,
    character: position.character))
  try:
    bridge.requests[lspReferencesRequest] = bridge.session.request(
      request.methodName, request.params).id
    result = true
  except CatchableError: bridge.lastError = getCurrentExceptionMsg()

proc takeReferenceLocations*(bridge: LspEditorBridge): seq[LspLocation] =
  if bridge == nil: return
  result = bridge.referenceLocations
  bridge.referenceLocations.setLen(0)

proc requestSymbols*(bridge: LspEditorBridge): bool =
  if bridge == nil or bridge.session == nil or bridge.session.state != lspSessionReady or
      bridge.uri.len == 0: return false
  bridge.cancelRequest(lspSymbolsRequest)
  let request = documentSymbolRequest(bridge.uri)
  try:
    bridge.requests[lspSymbolsRequest] = bridge.session.request(
      request.methodName, request.params).id
    result = true
  except CatchableError: bridge.lastError = getCurrentExceptionMsg()

proc takeSymbols*(bridge: LspEditorBridge): seq[LspSymbol] =
  if bridge == nil: return
  result = bridge.symbols
  bridge.symbols.setLen(0)

proc requestCodeActions*(bridge: LspEditorBridge, range: LspRange): bool =
  if bridge == nil or bridge.session == nil or bridge.session.state != lspSessionReady or
      bridge.uri.len == 0: return false
  bridge.cancelRequest(lspCodeActionsRequest)
  let request = codeActionRequest(bridge.uri, range)
  try:
    bridge.requests[lspCodeActionsRequest] = bridge.session.request(
      request.methodName, request.params).id
    result = true
  except CatchableError: bridge.lastError = getCurrentExceptionMsg()

proc takeCodeActions*(bridge: LspEditorBridge): seq[LspCodeAction] =
  if bridge == nil: return
  result = bridge.codeActions
  bridge.codeActions.setLen(0)

proc requestCodeActionResolve*(bridge: LspEditorBridge,
                               action: LspCodeAction): bool =
  if bridge == nil or bridge.session == nil or bridge.session.state != lspSessionReady or
      action.raw == nil: return false
  bridge.cancelRequest(lspCodeActionResolveRequest)
  bridge.resolvedCodeAction = LspCodeAction()
  let request = codeActionResolveRequest(action.raw)
  try:
    bridge.requests[lspCodeActionResolveRequest] = bridge.session.request(
      request.methodName, request.params).id
    result = true
  except CatchableError: bridge.lastError = getCurrentExceptionMsg()

proc takeResolvedCodeAction*(bridge: LspEditorBridge): LspCodeAction =
  if bridge == nil: return
  result = bridge.resolvedCodeAction
  bridge.resolvedCodeAction = LspCodeAction()

proc requestExecuteCommand*(bridge: LspEditorBridge, command: string,
                            arguments: seq[JsonNode]): bool =
  if bridge == nil or bridge.session == nil or bridge.session.state != lspSessionReady or
      command.len == 0: return false
  bridge.cancelRequest(lspExecuteCommandRequest)
  bridge.commandEdits.setLen(0)
  let request = executeCommandRequest(command, arguments)
  try:
    bridge.requests[lspExecuteCommandRequest] = bridge.session.request(
      request.methodName, request.params).id
    result = true
  except CatchableError: bridge.lastError = getCurrentExceptionMsg()

proc takeCommandEdits*(bridge: LspEditorBridge): seq[LspWorkspaceEdit] =
  if bridge == nil: return
  result = bridge.commandEdits
  bridge.commandEdits.setLen(0)

proc requestRename*(bridge: LspEditorBridge, buffer: PieceTable,
                    cursorByte: int, newName: string): bool =
  if bridge == nil or bridge.session == nil or bridge.session.state != lspSessionReady or
      bridge.uri.len == 0: return false
  bridge.cancelRequest(lspRenameRequest)
  let position = buffer.utf16Position(cursorByte)
  let request = renameRequest(bridge.uri, LspPosition(line: position.line,
    character: position.character), newName)
  try:
    bridge.requests[lspRenameRequest] = bridge.session.request(
      request.methodName, request.params).id
    result = true
  except CatchableError: bridge.lastError = getCurrentExceptionMsg()

proc takeRenameEdits*(bridge: LspEditorBridge): seq[LspWorkspaceEdit] =
  if bridge == nil: return
  result = bridge.renameEdits
  bridge.renameEdits.setLen(0)

proc requestSignatureHelp*(bridge: LspEditorBridge, buffer: PieceTable,
                           cursorByte: int): bool =
  if bridge == nil or bridge.session == nil or bridge.session.state != lspSessionReady or
      bridge.uri.len == 0: return false
  bridge.cancelRequest(lspSignatureRequest)
  let position = buffer.utf16Position(cursorByte)
  let request = signatureHelpRequest(bridge.uri, LspPosition(line: position.line,
    character: position.character))
  try:
    bridge.requests[lspSignatureRequest] = bridge.session.request(
      request.methodName, request.params).id
    result = true
  except CatchableError: bridge.lastError = getCurrentExceptionMsg()

proc takeSignatureHelp*(bridge: LspEditorBridge): LspSignatureHelp =
  if bridge == nil: return
  result = bridge.signatureHelp
  bridge.signatureHelp = LspSignatureHelp()

proc requestSemanticTokens*(bridge: LspEditorBridge): bool =
  if bridge == nil or bridge.session == nil or bridge.session.state != lspSessionReady or
      bridge.uri.len == 0: return false
  bridge.cancelRequest(lspSemanticTokensRequest)
  let request = semanticTokensRequest(bridge.uri)
  try:
    bridge.requests[lspSemanticTokensRequest] = bridge.session.request(
      request.methodName, request.params).id
    result = true
  except CatchableError: bridge.lastError = getCurrentExceptionMsg()

proc takeSemanticTokens*(bridge: LspEditorBridge): seq[LspSemanticToken] =
  if bridge == nil: return
  result = bridge.semanticTokens
  bridge.semanticTokens.setLen(0)

proc requestInlayHintsForPath*(bridge: LspEditorBridge, path: string,
                               range: LspRange): bool =
  ## Keep the response associated with the buffer that requested it. Split
  ## panes can show different files while sharing one LSP session; routing by
  ## the currently focused pane would allow a late response to decorate the
  ## wrong buffer. This mirrors Zed's per-buffer inlay cache boundary.
  if bridge == nil or bridge.session == nil or bridge.session.state != lspSessionReady or
      path.len == 0: return false
  let uri = fileUri(path)
  bridge.cancelRequest(lspInlayHintsRequest)
  let request = inlayHintRequest(uri, range)
  try:
    bridge.requests[lspInlayHintsRequest] = bridge.session.request(
      request.methodName, request.params).id
    bridge.inlayHintsRequestPath = uri
    bridge.inlayHintsRequestVersion = bridge.documents.getOrDefault(uri).version
    result = true
  except CatchableError: bridge.lastError = getCurrentExceptionMsg()

proc requestInlayHints*(bridge: LspEditorBridge, range: LspRange): bool =
  if bridge == nil: return false
  bridge.requestInlayHintsForPath(bridge.path, range)

proc takeInlayHints*(bridge: LspEditorBridge): seq[LspInlayHint] =
  if bridge == nil: return
  result = bridge.inlayHints
  bridge.inlayHints.setLen(0)
  bridge.inlayHintsPath = ""

proc takeInlayHintsWithPath*(bridge: LspEditorBridge): tuple[path: string,
                                                            hints: seq[LspInlayHint]] =
  if bridge == nil: return
  result.path = filePathFromUri(bridge.inlayHintsPath)
  result.hints = bridge.inlayHints
  bridge.inlayHints.setLen(0)
  bridge.inlayHintsPath = ""

proc inlayHintsForPath*(bridge: LspEditorBridge, path: string): seq[LspInlayHint] =
  if bridge == nil or path.len == 0: return
  result = bridge.inlayHintsByUri.getOrDefault(fileUri(path))

proc cancelDocumentFeatureRequests*(bridge: LspEditorBridge) =
  ## Results tied to a previous text snapshot must never reach the editor.
  ## Zed cancels pending project requests when the buffer generation advances.
  if bridge == nil: return
  bridge.evictRequests(allLspRequestKinds)
  bridge.inlayHintsRequestPath = ""
  bridge.inlayHintsRequestVersion = 0
  bridge.inlayHintsPath = ""
  bridge.inlayHints.setLen(0)
  bridge.referenceLocations.setLen(0)
  bridge.symbols.setLen(0)
  bridge.codeActions.setLen(0)
  bridge.resolvedCodeAction = LspCodeAction()
  bridge.commandEdits.setLen(0)
  bridge.renameEdits.setLen(0)
  bridge.signatureHelp = LspSignatureHelp()
  bridge.semanticTokens.setLen(0)
  bridge.inlayHints.setLen(0)

proc requestFormatting*(bridge: LspEditorBridge): bool =
  if bridge == nil or bridge.session == nil or bridge.session.state != lspSessionReady or
      bridge.uri.len == 0: return false
  bridge.cancelRequest(lspFormattingRequest)
  let request = formattingRequest(bridge.uri)
  try:
    let pending = bridge.session.request(request.methodName, request.params)
    bridge.requests[lspFormattingRequest] = pending.id
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
  bridge.cancelRequest(lspDefinitionRequest)
  let position = buffer.utf16Position(cursorByte)
  let request = definitionRequest(bridge.uri,
    LspPosition(line: position.line, character: position.character))
  try:
    let pending = bridge.session.request(request.methodName, request.params)
    bridge.requests[lspDefinitionRequest] = pending.id
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
      (bridge.hoverDelayTicks > 0 or bridge.requestId(lspHoverRequest) > 0 or
       bridge.hoverVisible):
    return
  bridge.hideHover()
  bridge.hoverTargetByte = target
  bridge.hoverDelayTicks = 5

proc requestHover*(bridge: LspEditorBridge, buffer: PieceTable,
                   cursorByte: int): bool =
  if bridge == nil or bridge.session == nil or bridge.session.state != lspSessionReady or
      bridge.uri.len == 0: return false
  bridge.cancelRequest(lspHoverRequest)
  let position = buffer.utf16Position(cursorByte)
  let request = hoverRequest(bridge.uri,
    LspPosition(line: position.line, character: position.character))
  try:
    let pending = bridge.session.request(request.methodName, request.params)
    bridge.requests[lspHoverRequest] = pending.id
    bridge.hoverCursorByte = max(0, min(cursorByte, buffer.toString().len))
    bridge.hoverVersion = bridge.version
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
  bridge.cancelRequest(lspCompletionRequest)
  let position = buffer.utf16Position(cursorByte)
  let request = completionRequest(bridge.uri,
    LspPosition(line: position.line, character: position.character))
  try:
    let pending = bridge.session.request(request.methodName, request.params)
    bridge.requests[lspCompletionRequest] = pending.id
    bridge.completionCursorByte = max(0, min(cursorByte, buffer.toString().len))
    bridge.completionVersion = bridge.version
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
  if bridge.session != nil and bridge.session.state == lspSessionReady:
    for _, document in bridge.documents:
      if document.opened and document.uri.len > 0:
        try: bridge.session.notify("textDocument/didClose", didCloseNotification(document.uri))
        except CatchableError: discard
  bridge.documents.clear()
  bridge.opened = false
  bridge.uri = ""
  bridge.path = ""
  bridge.languageId = ""
  bridge.lastText = ""
  bridge.version = 0
  bridge.hideHover()
  bridge.hideDefinition()
  bridge.hideFormatting()
  bridge.evictRequests(allLspRequestKinds)
  bridge.referenceLocations.setLen(0)
  bridge.symbols.setLen(0)
  bridge.codeActions.setLen(0)
  bridge.resolvedCodeAction = LspCodeAction()
  bridge.commandEdits.setLen(0)
  bridge.renameEdits.setLen(0)
  bridge.signatureHelp = LspSignatureHelp()
  bridge.semanticTokens.setLen(0)
  bridge.inlayHints.setLen(0)

proc markDocumentsClosed(bridge: LspEditorBridge) =
  ## A restarted server has forgotten every didOpen notification. Retain the
  ## snapshots so focused and visible documents can be reopened safely.
  for uri, document in bridge.documents.pairs:
    var next = document
    next.opened = false
    bridge.documents[uri] = next
  bridge.opened = false

proc syncDocument*(bridge: LspEditorBridge, path, text: string) =
  ## Synchronize a visible document without changing the document that owns
  ## completion, hover, definition, or formatting requests.
  if bridge == nil or bridge.command.len == 0 or path.len == 0: return
  let nextUri = fileUri(path)
  let nextLanguage = languageIdForPath(path)
  var document = bridge.documents.getOrDefault(nextUri)
  if document.uri.len == 0:
    document = LspDocumentState(path: absolutePath(path), uri: nextUri,
      languageId: nextLanguage, version: 1, lastText: text)
  else:
    document.path = absolutePath(path)
    document.languageId = nextLanguage
  if bridge.session == nil:
    try:
      bridge.session = startLspSession(bridge.command, bridge.args, bridge.rootUri, "Nimculus")
    except CatchableError:
      bridge.session = nil
      return
  elif bridge.session.state in {lspSessionStopped, lspSessionFailed}:
    try:
      bridge.session.restart()
      bridge.markDocumentsClosed()
    except CatchableError:
      bridge.lastError = getCurrentExceptionMsg()
      return
  if bridge.session.state != lspSessionReady:
    bridge.documents[nextUri] = document
    return
  try:
    if not document.opened:
      bridge.session.notify("textDocument/didOpen",
        didOpenNotification(document.uri, document.languageId, text, document.version))
      document.opened = true
      document.lastText = text
    elif document.lastText != text:
      inc document.version
      bridge.session.notify("textDocument/didChange",
        didChangeNotification(document.uri, text, document.version))
      document.lastText = text
      bridge.inlayHintsByUri.del(nextUri)
      if bridge.inlayHintsPath == nextUri:
        bridge.inlayHintsPath = ""
  except CatchableError:
    bridge.lastError = getCurrentExceptionMsg()
    bridge.session.state = lspSessionFailed
  bridge.documents[nextUri] = document

proc updateDocument*(bridge: LspEditorBridge, path, text: string) =
  ## Select a document for request-producing editor actions, then synchronize
  ## it. Other pane documents stay open in the same LSP session.
  if bridge == nil or path.len == 0: return
  let nextUri = fileUri(path)
  let textChanged = bridge.uri == nextUri and bridge.lastText != text
  if bridge.uri != nextUri or textChanged:
    bridge.hideCompletion()
    bridge.hideHover()
    bridge.hideDefinition()
    bridge.hideFormatting()
    bridge.cancelDocumentFeatureRequests()
  bridge.uri = nextUri
  bridge.path = absolutePath(path)
  bridge.languageId = languageIdForPath(path)
  bridge.lastText = text
  bridge.syncDocument(path, text)
  let document = bridge.documents.getOrDefault(nextUri)
  bridge.version = document.version
  bridge.opened = document.opened

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
  if bridge.requestId(lspCompletionRequest) > 0:
    let response = bridge.session.takeResponse(bridge.requestId(lspCompletionRequest))
    if response != nil:
      let completion = parseCompletion(response)
      bridge.completionItems = completion.items
      bridge.completionSelected = 0
      bridge.completionVisible = bridge.completionVersion == bridge.version and
        completion.items.len > 0
      bridge.requests[lspCompletionRequest] = 0
      result = true
  if bridge.requestId(lspHoverRequest) > 0:
    let response = bridge.session.takeResponse(bridge.requestId(lspHoverRequest))
    if response != nil:
      let hover = parseHover(response)
      bridge.hoverText = hover.text
      bridge.hoverVisible = bridge.hoverVersion == bridge.version and
        hover.text.len > 0 and bridge.hoverCursorByte == bridge.hoverTargetByte
      bridge.requests[lspHoverRequest] = 0
      result = true
  if bridge.requestId(lspDefinitionRequest) > 0:
    let response = bridge.session.takeResponse(bridge.requestId(lspDefinitionRequest))
    if response != nil:
      bridge.definitionLocations = parseLocations(response)
      bridge.requests[lspDefinitionRequest] = 0
      result = true
  if bridge.requestId(lspFormattingRequest) > 0:
    let response = bridge.session.takeResponse(bridge.requestId(lspFormattingRequest))
    if response != nil:
      if bridge.formattingVersion == bridge.version:
        bridge.formattingEdits = parseTextEdits(response)
        bridge.formattingReady = true
      bridge.requests[lspFormattingRequest] = 0
      result = true
  if bridge.requestId(lspReferencesRequest) > 0:
    let response = bridge.session.takeResponse(bridge.requestId(lspReferencesRequest))
    if response != nil:
      bridge.referenceLocations = parseLocations(response)
      bridge.requests[lspReferencesRequest] = 0
      result = true
  if bridge.requestId(lspSymbolsRequest) > 0:
    let response = bridge.session.takeResponse(bridge.requestId(lspSymbolsRequest))
    if response != nil:
      bridge.symbols = parseSymbols(response)
      bridge.requests[lspSymbolsRequest] = 0
      result = true
  if bridge.requestId(lspCodeActionsRequest) > 0:
    let response = bridge.session.takeResponse(bridge.requestId(lspCodeActionsRequest))
    if response != nil:
      bridge.codeActions = parseCodeActions(response)
      bridge.requests[lspCodeActionsRequest] = 0
      result = true
  if bridge.requestId(lspCodeActionResolveRequest) > 0:
    let response = bridge.session.takeResponse(bridge.requestId(lspCodeActionResolveRequest))
    if response != nil:
      bridge.resolvedCodeAction = parseCodeAction(response)
      bridge.requests[lspCodeActionResolveRequest] = 0
      result = true
  if bridge.requestId(lspExecuteCommandRequest) > 0:
    let response = bridge.session.takeResponse(bridge.requestId(lspExecuteCommandRequest))
    if response != nil:
      bridge.commandEdits = parseWorkspaceEdit(response)
      bridge.requests[lspExecuteCommandRequest] = 0
      result = true
  if bridge.requestId(lspRenameRequest) > 0:
    let response = bridge.session.takeResponse(bridge.requestId(lspRenameRequest))
    if response != nil:
      bridge.renameEdits = parseWorkspaceEdit(response)
      bridge.requests[lspRenameRequest] = 0
      result = true
  if bridge.requestId(lspSignatureRequest) > 0:
    let response = bridge.session.takeResponse(bridge.requestId(lspSignatureRequest))
    if response != nil:
      bridge.signatureHelp = parseSignatureHelp(response)
      bridge.requests[lspSignatureRequest] = 0
      result = true
  if bridge.requestId(lspSemanticTokensRequest) > 0:
    let response = bridge.session.takeResponse(bridge.requestId(lspSemanticTokensRequest))
    if response != nil:
      bridge.semanticTokens = parseSemanticTokens(response)
      bridge.requests[lspSemanticTokensRequest] = 0
      result = true
  if bridge.requestId(lspInlayHintsRequest) > 0:
    let response = bridge.session.takeResponse(bridge.requestId(lspInlayHintsRequest))
    if response != nil:
      let responsePath = bridge.inlayHintsRequestPath
      let hints = parseInlayHints(response)
      bridge.inlayHintsRequestPath = ""
      bridge.inlayHintsPath = responsePath
      let responseDocument = bridge.documents.getOrDefault(responsePath)
      if responsePath.len > 0 and responseDocument.uri.len > 0 and
          responseDocument.version == bridge.inlayHintsRequestVersion:
        bridge.inlayHintsByUri[responsePath] = hints
        bridge.inlayHints = hints
      else:
        bridge.inlayHints.setLen(0)
      bridge.requests[lspInlayHintsRequest] = 0
      bridge.inlayHintsRequestVersion = 0
      result = true
  if bridge.session.state == lspSessionReady and not bridge.opened and
      bridge.path.len > 0:
    bridge.updateDocument(bridge.path, bridge.lastText)
    return bridge.opened or messageCount > 0
  result = result or before != bridge.session.state or messageCount > 0

proc diagnostics*(bridge: LspEditorBridge): seq[LspDiagnostic] =
  if bridge != nil and bridge.session != nil and bridge.uri.len > 0:
    result = bridge.session.diagnosticsFor(bridge.uri)

proc activityProgressText*(bridge: LspEditorBridge): string =
  if bridge != nil and bridge.session != nil:
    result = bridge.session.activityProgressText()

proc diagnosticsForPath*(bridge: LspEditorBridge, path: string): seq[LspDiagnostic] =
  ## Diagnostics are keyed by URI by the LSP transport, not by active pane.
  if bridge != nil and bridge.session != nil and path.len > 0:
    result = bridge.session.diagnosticsFor(fileUri(path))

proc diagnosticSummary*(bridge: LspEditorBridge): DiagnosticSummary =
  if bridge != nil and bridge.session != nil and bridge.uri.len > 0:
    result = bridge.session.diagnosticSummaryFor(bridge.uri)

proc diagnosticSummaryForPath*(bridge: LspEditorBridge, path: string): DiagnosticSummary =
  if bridge != nil and bridge.session != nil and path.len > 0:
    result = bridge.session.diagnosticSummaryFor(fileUri(path))

proc openedDocumentCount*(bridge: LspEditorBridge): int =
  if bridge == nil: return
  for _, document in bridge.documents:
    if document.opened: inc result

proc documentVersion*(bridge: LspEditorBridge, path: string): int =
  if bridge == nil or path.len == 0: return
  let document = bridge.documents.getOrDefault(fileUri(path))
  result = document.version

proc stop*(bridge: LspEditorBridge) =
  if bridge == nil: return
  bridge.closeDocument()
  if bridge.session != nil: bridge.session.stop()
  bridge.session = nil

proc shutdown*(bridge: LspEditorBridge) =
  ## App termination must not write `didClose` or request-cancellation frames:
  ## a stopped or saturated server pipe could otherwise delay Cocoa shutdown.
  ## Stop owns the process group directly, then discard UI-only state.
  if bridge == nil: return
  if bridge.session != nil: bridge.session.stop()
  bridge.session = nil
  bridge.opened = false
  bridge.path = ""
  bridge.uri = ""
  bridge.languageId = ""
  bridge.lastText = ""
  bridge.version = 0
  bridge.completionItems.setLen(0)
  bridge.completionVisible = false
  bridge.hoverText = ""
  bridge.hoverVisible = false
  bridge.definitionLocations.setLen(0)
  bridge.formattingEdits.setLen(0)
  bridge.formattingReady = false
  bridge.referenceLocations.setLen(0)
  bridge.symbols.setLen(0)
  bridge.codeActions.setLen(0)
  bridge.resolvedCodeAction = LspCodeAction()
  bridge.commandEdits.setLen(0)
  bridge.renameEdits.setLen(0)
  bridge.signatureHelp = LspSignatureHelp()
  bridge.semanticTokens.setLen(0)
  bridge.inlayHints.setLen(0)
  bridge.inlayHintsByUri.clear()
  bridge.inlayHintsRequestPath = ""
  bridge.inlayHintsRequestVersion = 0
  bridge.inlayHintsPath = ""
