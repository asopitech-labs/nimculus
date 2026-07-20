import std/json
import std/strutils
import std/unittest
import nimculus/lsp

suite "M8 LSP protocol foundation":
  test "encodes Content-Length as UTF-8 byte length":
    let payload = %*{"jsonrpc": "2.0", "method": "window/logMessage", "params": {"message": "日本語"}}
    let encoded = encodeLspMessage(payload)
    let separator = encoded.find("\r\n\r\n")
    check separator > 0
    let length = parseInt(encoded[16 ..< separator])
    check length == encoded.len - separator - 4
    check encoded.endsWith($payload)

  test "decodes partial and multiple frames":
    let first = encodeLspMessage(%*{"jsonrpc": "2.0", "id": 1, "result": "日本語"})
    let second = encodeLspMessage(%*{"jsonrpc": "2.0", "id": 2, "result": true})
    var decoder: LspFrameDecoder
    check decoder.feed(first[0 ..< 11]).len == 0
    check decoder.feed(first[11 .. ^1] & second).len == 2
    check decoder.buffer.len == 0

  test "rejects malformed framing":
    var decoder: LspFrameDecoder
    expect LspProtocolError:
      discard decoder.feed("Content-Length: nope\r\n\r\n{}")

  test "drops cancelled and stale responses":
    var tracker = initLspRequestTracker()
    let first = tracker.beginRequest("textDocument/completion")
    let second = tracker.beginRequest("textDocument/completion")
    check not tracker.acceptsResponse(first.id)
    check tracker.acceptsResponse(second.id)
    check tracker.cancelRequest(second.id)
    check not tracker.acceptsResponse(second.id)
    check tracker.finishResponse(second.id) == false
    check tracker.pendingCount == 1
    check tracker.finishResponse(first.id) == false
    check tracker.pendingCount == 0

  test "expires requests and emits cancellation notification":
    var tracker = initLspRequestTracker()
    let request = tracker.beginRequest("textDocument/hover")
    let expired = tracker.expireRequests(request.startedAtMs + 1000, 500)
    check expired == @[request.id]
    check not tracker.acceptsResponse(request.id)
    check cancelJson(request.id)["method"].getStr == "$/cancelRequest"

  test "stdio process round trips a framed notification":
    let server = "import sys\n" &
      "h=b''\n" &
      "while b'\\r\\n\\r\\n' not in h:\n" &
      "    h += sys.stdin.buffer.read(1)\n" &
      "n=int(h.split(b':')[1].split()[0])\n" &
      "b=sys.stdin.buffer.read(n)\n" &
      "sys.stdout.buffer.write(h+b)\n" &
      "sys.stdout.buffer.flush()\n"
    let client = startLspProcess("python3", ["-u", "-c", server])
    defer: discard client.stop()
    client.sendNotification("initialized", %*{"message": "日本語"})
    var messages: seq[JsonNode]
    for _ in 0 ..< 8:
      messages = client.readMessages()
      if messages.len > 0: break
    check messages.len == 1
    check messages[0]["method"].getStr == "initialized"
    check messages[0]["params"]["message"].getStr == "日本語"

  test "builds initialize, synchronization, and feature requests":
    let position = LspPosition(line: 3, character: 5)
    let range = LspRange(start: LspPosition(line: 1, character: 2),
      finish: LspPosition(line: 1, character: 8))
    check initializeParams("", "Nimculus")["rootUri"].kind == JNull
    check initializeParams("", "Nimculus")["processId"].getInt > 0
    check didOpenNotification("file:///a.nim", "nim", "echo 1", 1)["method"].getStr == "textDocument/didOpen"
    check didChangeNotification("file:///a.nim", "echo 2", 2)["params"]["contentChanges"].len == 1
    check didCloseNotification("file:///a.nim")["method"].getStr == "textDocument/didClose"
    check completionRequest("file:///a.nim", position).methodName == "textDocument/completion"
    check hoverRequest("file:///a.nim", position).methodName == "textDocument/hover"
    check definitionRequest("file:///a.nim", position).methodName == "textDocument/definition"
    check referencesRequest("file:///a.nim", position).params["context"]["includeDeclaration"].getBool
    check documentSymbolRequest("file:///a.nim").methodName == "textDocument/documentSymbol"
    check renameRequest("file:///a.nim", position, "newName").params["newName"].getStr == "newName"
    check formattingRequest("file:///a.nim").methodName == "textDocument/formatting"
    check codeActionRequest("file:///a.nim", range).methodName == "textDocument/codeAction"
    check signatureHelpRequest("file:///a.nim", position).methodName == "textDocument/signatureHelp"
    check semanticTokensRequest("file:///a.nim").methodName == "textDocument/semanticTokens/full"
    check inlayHintRequest("file:///a.nim", range).methodName == "textDocument/inlayHint"
    let commandRequest = executeCommandRequest("organizeImports", @[%*{"uri": "file:///a.nim"}])
    check commandRequest.methodName == "workspace/executeCommand"
    check commandRequest.params["arguments"][0]["uri"].getStr == "file:///a.nim"

  test "parses diagnostics notification":
    let message = %*{"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics",
      "params": {"uri": "file:///a.nim", "diagnostics": [{
        "range": {"start": {"line": 2, "character": 1}, "end": {"line": 2, "character": 4}},
        "severity": 2, "source": "nim", "message": "warning"}]}}
    let parsed = parseDiagnostics(message)
    check parsed.uri == "file:///a.nim"
    check parsed.diagnostics.len == 1
    check parsed.diagnostics[0].range.start.line == 2
    check parsed.diagnostics[0].severity == 2

  test "parses feature responses and rejects stale responses":
    var tracker = initLspRequestTracker()
    let oldRequest = tracker.beginRequest("textDocument/hover")
    let newRequest = tracker.beginRequest("textDocument/hover")
    let stale = %*{"jsonrpc": "2.0", "id": oldRequest.id,
      "result": {"contents": [{"language": "nim", "value": "old"}]}}
    let current = %*{"jsonrpc": "2.0", "id": newRequest.id,
      "result": {"contents": [{"language": "nim", "value": "new"}],
        "range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 3}}}}
    check not tracker.acceptResponse(stale)
    let hover = parseHover(current)
    check tracker.acceptResponse(current)
    check hover.text == "new"
    check hover.hasRange

    let completion = parseCompletion(%*{"result": {"isIncomplete": true, "items": [
      {"label": "echo", "detail": "keyword", "kind": 14}]}})
    check completion.isIncomplete
    check completion.items[0].insertText == "echo"
    let locations = parseLocations(%*{"result": [{"uri": "file:///b.nim",
      "range": {"start": {"line": 2, "character": 0}, "end": {"line": 2, "character": 4}}}]})
    check locations.len == 1
    check locations[0].uri == "file:///b.nim"
    let nestedSymbols = parseSymbols(%*{"result": [{"name": "Type", "kind": 5,
      "range": {"start": {"line": 0, "character": 0},
        "end": {"line": 4, "character": 0}},
      "children": [{"name": "method", "kind": 6,
        "range": {"start": {"line": 1, "character": 2},
          "end": {"line": 2, "character": 0}}}]}]})
    check nestedSymbols.len == 2
    check nestedSymbols[1].name == "method"
    let edits = parseTextEdits(%*{"result": [{"range": {"start": {"line": 0, "character": 0},
      "end": {"line": 0, "character": 1}}, "newText": "x"}]})
    check edits.len == 1
    check edits[0].newText == "x"
    let actions = parseCodeActions(%*{"result": [{"title": "Fix", "kind": "quickfix",
      "edit": {"changes": {"file:///a.nim": [{"range": {"start": {"line": 0, "character": 0},
        "end": {"line": 0, "character": 1}}, "newText": "y"}]}}}]})
    check actions.len == 1
    check actions[0].edits[0].newText == "y"
    check actions[0].workspaceEdits.len == 1
    check actions[0].workspaceEdits[0].uri == "file:///a.nim"
    let signature = parseSignatureHelp(%*{"result": {"activeSignature": 1,
      "signatures": [{"label": "f(a)", "documentation": "docs"}, {"label": "f(a,b)"}]}})
    check signature.activeSignature == 1
    check signature.signatures[0].documentation == "docs"
    let tokens = parseSemanticTokens(%*{"result": {"data": [0, 2, 3, 1, 0, 0, 4, 2, 2, 1]}})
    check tokens.len == 2
    check tokens[1].startCharacter == 6
    let hints = parseInlayHints(%*{"result": [{"position": {"line": 1, "character": 2},
      "label": ": int", "kind": 1}]})
    check hints.len == 1
    check hints[0].position.line == 1
    let workspaceEdits = parseWorkspaceEdit(%*{"result": {"changes": {
      "file:///a.nim": [{"range": {"start": {"line": 0, "character": 0},
        "end": {"line": 0, "character": 1}}, "newText": "renamed"}]}}})
    check workspaceEdits.len == 1
    check workspaceEdits[0].edits[0].newText == "renamed"
    let multiFileEdit = parseWorkspaceEdit(%*{"result": {"changes": {
      "file:///a.nim": [{"range": {"start": {"line": 0, "character": 0},
        "end": {"line": 0, "character": 1}}, "newText": "a"}],
      "file:///b.nim": [{"range": {"start": {"line": 1, "character": 0},
        "end": {"line": 1, "character": 1}}, "newText": "b"}]}}})
    check multiFileEdit.len == 2
    let documentChanges = parseWorkspaceEdit(%*{"result": {"documentChanges": [{
      "textDocument": {"uri": "file:///c.nim", "version": 7},
      "edits": [{"range": {"start": {"line": 0, "character": 0},
        "end": {"line": 0, "character": 1}}, "newText": "c"}]}]}})
    check documentChanges.len == 1
    check documentChanges[0].uri == "file:///c.nim"
    let commandAction = parseCodeActions(%*{"result": [{"title": "Organize imports",
      "kind": "source.organizeImports", "command": "organizeImports",
      "arguments": [{"uri": "file:///a.nim"}]}]})
    check commandAction.len == 1
    check commandAction[0].command == "organizeImports"
    check commandAction[0].arguments.len == 1
    let deferredAction = parseCodeActions(%*{"result": [{"title": "Extract function",
      "kind": "refactor.extract", "data": {"actionId": "extract-1"}}]})
    check deferredAction.len == 1
    check deferredAction[0].data != nil
    let resolvedAction = parseCodeAction(%*{"result": {"title": "Extract function",
      "edit": {"documentChanges": [{"textDocument": {"uri": "file:///a.nim"},
        "edits": [{"range": {"start": {"line": 0, "character": 0},
          "end": {"line": 0, "character": 1}}, "newText": "fn"}]}]}}})
    check resolvedAction.workspaceEdits.len == 1
    check resolvedAction.workspaceEdits[0].edits[0].newText == "fn"
    let resolveRequest = codeActionResolveRequest(%*{"title": "Extract function",
      "data": {"actionId": "extract-1"}})
    check resolveRequest.methodName == "codeAction/resolve"
    let objectCommandAction = parseCodeActions(%*{"result": [{"title": "Organize imports",
      "command": {"title": "Organize imports", "command": "organizeImports",
        "arguments": [{"uri": "file:///a.nim"}]}}]})
    check objectCommandAction.len == 1
    check objectCommandAction[0].command == "organizeImports"
    check objectCommandAction[0].arguments.len == 1

  test "session initializes and stores diagnostics from a language server":
    let server = "import sys,json,time\n" &
      "def frame(x):\n" &
      "    b=json.dumps(x,separators=(',',':')).encode()\n" &
      "    return ('Content-Length: '+str(len(b))+'\\r\\n\\r\\n').encode()+b\n" &
      "init={'jsonrpc':'2.0','id':1,'result':{'capabilities':{}}}\n" &
      "diag={'jsonrpc':'2.0','method':'textDocument/publishDiagnostics','params':{'uri':'file:///a.nim','diagnostics':[{'range':{'start':{'line':0,'character':0},'end':{'line':0,'character':1}},'severity':1,'message':'error'}]}}\n" &
      "sys.stdout.buffer.write(frame(init)+frame(diag)); sys.stdout.buffer.flush(); time.sleep(2)\n"
    let session = startLspSession("python3", ["-u", "-c", server], "", "Nimculus")
    defer: session.stop()
    var messages = session.poll()
    check messages.len >= 1
    check session.state == lspSessionReady
    check session.diagnosticsFor("file:///a.nim").len == 1
    check session.diagnosticsFor("file:///a.nim")[0].message == "error"
