import std/json
import std/os
import std/options
import std/sets
import std/strutils
import std/tables
import std/times
import std/unittest
import nimculus/lsp
import wait_support

suite "M8 LSP protocol foundation":
  test "encodes Content-Length as UTF-8 byte length":
    let payload = %*{"jsonrpc": "2.0", "method": "window/logMessage", "params": {
        "message": "日本語"}}
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

  test "rejects oversized frames and headers":
    var frameDecoder: LspFrameDecoder
    expect LspProtocolError:
      discard frameDecoder.feed("Content-Length: " & $(MaxLspFrameBytes + 1) &
        "\r\n\r\n")
    var headerDecoder: LspFrameDecoder
    expect LspProtocolError:
      discard headerDecoder.feed("X-Header: " & repeat('x', MaxLspHeaderBytes) &
        "\r\n")

  test "limits decoded messages per poll while retaining the remainder":
    var decoder: LspFrameDecoder
    var payload = ""
    for index in 0 ..< (MaxLspMessagesPerPoll + 3):
      payload.add(encodeLspMessage(%*{"jsonrpc": "2.0", "id": index, "result": true}))
    let first = decoder.feed(payload)
    check first.len == MaxLspMessagesPerPoll
    check decoder.buffer.len > 0
    let second = decoder.feed("")
    check second.len == 3
    check decoder.buffer.len == 0

  test "classifies JSON-RPC notifications, server requests, and responses":
    check classifyLspMessage(%*{"jsonrpc": "2.0", "method": "$/progress",
      "id": 7}) == lspServerRequest
    check classifyLspMessage(%*{"jsonrpc": "2.0", "method": "$/progress"}) ==
      lspNotification
    check classifyLspMessage(%*{"jsonrpc": "2.0", "id": 7, "result": nil}) ==
      lspResponse

  test "builds a method-not-found response for an unrecognized request":
    let response = unrecognizedMethodResponse(%*{"jsonrpc": "2.0", "id": 9,
      "method": "workspace/configuration", "params": {}})
    check response["jsonrpc"].getStr == "2.0"
    check response["id"].getInt == 9
    check response["error"]["code"].getInt == -32601
    check response["error"]["message"].getStr ==
      "Unrecognized method `workspace/configuration`"

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
    check DefaultLspRequestTimeoutMs == 30_000

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
    let wait = waitForTest("LSP notification response", condition = proc(): bool =
      messages = client.readMessages()
      messages.len > 0)
    check checkTestWait(wait)
    check messages.len == 1
    check messages[0]["method"].getStr == "initialized"
    check messages[0]["params"]["message"].getStr == "日本語"

  when defined(macosx):
    test "stops an unresponsive language-server child in bounded time":
      let client = startLspProcess("/bin/sh", ["-c", "trap '' TERM; while :; do sleep 1; done"])
      let started = epochTime()
      discard client.stop()
      check epochTime() - started < 3.0

  test "releases an exited language server before restart":
    let client = startLspProcess("/bin/sh", ["-c", "exit 0"])
    let wait = waitForTest("LSP server exit", condition = proc(): bool =
      discard client.readMessages()
      client.state != lspRunning)
    check checkTestWait(wait)
    check client.state == lspStopped
    check not client.isRunning

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
    check referencesRequest("file:///a.nim", position).params["context"][
        "includeDeclaration"].getBool
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

  test "advertises work-done progress without show-message requests":
    let capabilities = initializeParams("", "Nimculus")["capabilities"]
    check capabilities["window"]["workDoneProgress"].getBool
    check not capabilities["window"].hasKey("showMessage")

  test "builds a null response and registers numeric and string progress tokens":
    let request = %*{"jsonrpc": "2.0", "id": 17,
      "method": "window/workDoneProgress/create", "params": {"token": 42}}
    let response = workDoneProgressCreateResponse(request)
    check response["id"].getInt == 17
    check response["result"].kind == JNull
    var tokens: LspSession
    new(tokens)
    tokens.progressTokens = initHashSet[LspProgressToken]()
    check tokens.registerProgressToken(%*{"token": 42})
    check tokens.registerProgressToken(%*{"token": "build"})
    check tokens.hasProgressToken(%*42)
    check tokens.hasProgressToken(%*"build")

  test "tracks registered work-done progress through begin report and end":
    var session: LspSession
    new(session)
    session.progressTokens = initHashSet[LspProgressToken]()
    session.progresses = initTable[LspProgressToken, LspProgress]()
    check session.registerProgressToken(%*{"token": "build"})
    let token = LspProgressToken(kind: lspProgressTokenString, text: "build")
    check not session.handleWorkDoneProgress(%*{
      "jsonrpc": "2.0", "method": "$/progress",
      "params": {"token": "unregistered", "value": {"kind": "begin"}}})
    check token notin session.progresses

    check session.handleWorkDoneProgress(%*{
      "jsonrpc": "2.0", "method": "$/progress",
      "params": {"token": "build", "value": {"kind": "begin",
        "title": "Build", "message": "starting", "percentage": 10,
        "cancellable": true}}})
    check token in session.progressTokens
    check token in session.progresses
    check session.progresses[token].title.get == "Build"
    check session.progresses[token].message.get == "starting"
    check session.progresses[token].percentage.get == 10
    check session.progresses[token].isCancellable
    let beginUpdate = session.progresses[token].lastUpdateAtMs

    check session.handleWorkDoneProgress(%*{
      "jsonrpc": "2.0", "method": "$/progress",
      "params": {"token": "build", "value": {"kind": "report",
        "message": "halfway", "percentage": 50}}})
    check session.progresses[token].title.get == "Build"
    check session.progresses[token].message.get == "halfway"
    check session.progresses[token].percentage.get == 50
    check not session.progresses[token].isCancellable
    check session.progresses[token].lastUpdateAtMs >= beginUpdate

    check session.handleWorkDoneProgress(%*{
      "jsonrpc": "2.0", "method": "$/progress",
      "params": {"token": "build", "value": {"kind": "report"}}})
    check session.progresses[token].title.get == "Build"
    check session.progresses[token].message.isNone
    check session.progresses[token].percentage.isNone

    check session.handleWorkDoneProgress(%*{
      "jsonrpc": "2.0", "method": "$/progress",
      "params": {"token": "build", "value": {"kind": "end"}}})
    check token notin session.progressTokens
    check token notin session.progresses

  test "formats the newest retained progress and counts the rest":
    var session: LspSession
    new(session)
    session.progressTokens = initHashSet[LspProgressToken]()
    session.progresses = initTable[LspProgressToken, LspProgress]()
    let first = LspProgressToken(kind: lspProgressTokenString, text: "first")
    let newest = LspProgressToken(kind: lspProgressTokenString, text: "newest")
    session.progressTokens.incl(first)
    session.progressTokens.incl(newest)
    session.progresses[first] = LspProgress(title: some("Older"),
      message: some("waiting"), percentage: some(10), lastUpdateAtMs: 10)
    session.progresses[newest] = LspProgress(title: some("Build"),
      message: some("working"), percentage: some(50), lastUpdateAtMs: 20)
    check session.activityProgressText() == "Build (50%): working + 1 more"

  test "uses the progress token when the title is absent":
    var session: LspSession
    new(session)
    session.progressTokens = initHashSet[LspProgressToken]()
    session.progresses = initTable[LspProgressToken, LspProgress]()
    let token = LspProgressToken(kind: lspProgressTokenString, text: "indexing")
    session.progressTokens.incl(token)
    session.progresses[token] = LspProgress(message: some("working"), lastUpdateAtMs: 1)
    check session.activityProgressText() == "indexing: working"

  test "tracks work-done progress through a real language-server request":
    let server = "import sys,json,time\n" &
      "def frame(x):\n" &
      "    b=json.dumps(x,separators=(',',':')).encode()\n" &
      "    return ('Content-Length: '+str(len(b))+'\\r\\n\\r\\n').encode()+b\n" &
      "def read_message():\n" &
      "    h=b''\n" &
      "    while b'\\r\\n\\r\\n' not in h: h += sys.stdin.buffer.read(1)\n" &
      "    n=int(h.split(b':')[1].split()[0])\n" &
      "    return json.loads(sys.stdin.buffer.read(n))\n" &
      "initialize=read_message()\n" &
      "response={'jsonrpc':'2.0','id':initialize['id'],'result':{'capabilities':{}}}\n" &
      "create={'jsonrpc':'2.0','id':23,'method':'window/workDoneProgress/create','params':{'token':'server-work'}}\n" &
      "sys.stdout.buffer.write(frame(response)+frame(create)); sys.stdout.buffer.flush()\n" &
      "initialized=read_message(); create_response=read_message()\n" &
      "progress=[]\n" &
      "for kind,extra in [('begin',{'title':'Indexing','percentage':1}),('report',{'message':'working','percentage':50}),('end',{})]:\n" &
      "    value={'kind':kind}; value.update(extra)\n" &
      "    progress.append({'jsonrpc':'2.0','method':'$/progress','params':{'token':'server-work','value':value}})\n" &
      "received={'jsonrpc':'2.0','method':'test/received','params':{'initialized':initialized,'create':create_response}}\n" &
      "sys.stdout.buffer.write(b''.join(frame(x) for x in progress)+frame(received)); sys.stdout.buffer.flush(); time.sleep(2)\n"
    let session = startLspSession("python3", ["-u", "-c", server], "", "Nimculus")
    defer: session.stop()
    var received: JsonNode
    let wait = waitForTest("LSP progress notification response",
      condition = proc(): bool =
        for message in session.poll():
          if message.kind == JObject and message.hasKey("method") and
              message["method"].getStr == "test/received":
            received = message["params"]
        received != nil)
    check checkTestWait(wait)
    check received != nil
    check received["create"]["result"].kind == JNull
    check session.state == lspSessionReady
    let token = LspProgressToken(kind: lspProgressTokenString, text: "server-work")
    check token notin session.progressTokens
    check token notin session.progresses

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

  test "stores diagnostics per server and recomputes path summaries":
    let session = startLspSession("python3", ["-u", "-c", "import time; time.sleep(2)"],
      "", "Nimculus")
    defer: session.stop()
    let uri = "file:///a.nim"
    let payload = proc(diagnostics: JsonNode): JsonNode =
      %*{"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics",
        "params": {"uri": uri, "diagnostics": diagnostics}}
    let diagnostics = %*[{
      "range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 1}},
      "severity": 1, "message": "error 1"}, {
      "range": {"start": {"line": 1, "character": 0}, "end": {"line": 1, "character": 1}},
      "severity": 1, "message": "error 2"}, {
      "range": {"start": {"line": 2, "character": 0}, "end": {"line": 2, "character": 1}},
      "severity": 2, "message": "warning"}, {
      "range": {"start": {"line": 3, "character": 0}, "end": {"line": 3, "character": 1}},
      "severity": 3, "message": "information"}, {
      "range": {"start": {"line": 4, "character": 0}, "end": {"line": 4, "character": 1}},
      "severity": 4, "message": "hint"}]
    session.storeDiagnostics(payload(diagnostics), 1)
    check session.diagnosticSummaryFor(uri) == DiagnosticSummary(errorCount: 2, warningCount: 1)

    session.storeDiagnostics(payload(newJArray()), 1)
    check session.diagnosticSummaryFor(uri) == DiagnosticSummary(errorCount: 0, warningCount: 0)

    let firstServer = %*[{
      "range": {"start": {"line": 5, "character": 0}, "end": {"line": 5, "character": 1}},
      "severity": 1, "message": "server 1"}, {
      "range": {"start": {"line": 6, "character": 0}, "end": {"line": 6, "character": 1}},
      "severity": 2, "message": "server 1 warning"}]
    let secondServer = %*[{
      "range": {"start": {"line": 7, "character": 0}, "end": {"line": 7, "character": 1}},
      "severity": 1, "message": "server 2"}]
    session.storeDiagnostics(payload(firstServer), 1)
    session.storeDiagnostics(payload(secondServer), 2)
    check session.diagnosticsFor(uri).len == firstServer.len + secondServer.len

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
    check nestedSymbols.len == 1
    check nestedSymbols[0].children.len == 1
    check nestedSymbols[0].children[0].name == "method"
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
    var messages: seq[JsonNode]
    let wait = waitForTest("LSP diagnostics response", condition = proc(): bool =
      messages = session.poll()
      messages.len > 0)
    check checkTestWait(wait)
    check messages.len >= 1
    check session.state == lspSessionReady
    check session.diagnosticsFor("file:///a.nim").len == 1
    check session.diagnosticsFor("file:///a.nim")[0].message == "error"

  test "responds to a server request even when its id collides with a client request":
    let server = "import sys,json,time\n" &
      "def frame(x):\n" &
      "    b=json.dumps(x,separators=(',',':')).encode()\n" &
      "    return ('Content-Length: '+str(len(b))+'\\r\\n\\r\\n').encode()+b\n" &
      "def read_message():\n" &
      "    h=b''\n" &
      "    while b'\\r\\n\\r\\n' not in h: h += sys.stdin.buffer.read(1)\n" &
      "    n=int(h.split(b':')[1].split()[0])\n" &
      "    return json.loads(sys.stdin.buffer.read(n))\n" &
      "initialize=read_message()\n" &
      "request={'jsonrpc':'2.0','id':initialize['id'],'method':'workspace/configuration'}\n" &
      "response={'jsonrpc':'2.0','id':initialize['id'],'result':{'capabilities':{}}}\n" &
      "sys.stdout.buffer.write(frame(request)+frame(response)); sys.stdout.buffer.flush()\n" &
      "received=read_message()\n" &
      "notification={'jsonrpc':'2.0','method':'test/received','params':received}\n" &
      "sys.stdout.buffer.write(frame(notification)); sys.stdout.buffer.flush(); time.sleep(2)\n"
    let session = startLspSession("python3", ["-u", "-c", server], "", "Nimculus")
    defer: session.stop()
    var received: JsonNode
    let wait = waitForTest("LSP server-request response",
      condition = proc(): bool =
        for message in session.poll():
          if message.kind == JObject and message.hasKey("method") and
              message["method"].getStr == "test/received":
            received = message["params"]
        received != nil)
    check checkTestWait(wait)
    check received != nil
    check received["id"].getInt == 1
    check received["error"]["code"].getInt == -32601
    check received["error"]["message"].getStr ==
      "Unrecognized method `workspace/configuration`"
    check session.state == lspSessionReady

  test "registers progress tokens from a real language-server request":
    let server = "import sys,json,time\n" &
      "def frame(x):\n" &
      "    b=json.dumps(x,separators=(',',':')).encode()\n" &
      "    return ('Content-Length: '+str(len(b))+'\\r\\n\\r\\n').encode()+b\n" &
      "def read_message():\n" &
      "    h=b''\n" &
      "    while b'\\r\\n\\r\\n' not in h: h += sys.stdin.buffer.read(1)\n" &
      "    n=int(h.split(b':')[1].split()[0])\n" &
      "    return json.loads(sys.stdin.buffer.read(n))\n" &
      "initialize=read_message()\n" &
      "response={'jsonrpc':'2.0','id':initialize['id'],'result':{'capabilities':{}}}\n" &
      "create={'jsonrpc':'2.0','id':23,'method':'window/workDoneProgress/create','params':{'token':'server-work'}}\n" &
      "sys.stdout.buffer.write(frame(response)+frame(create)); sys.stdout.buffer.flush()\n" &
      "received=read_message(); received=read_message()\n" &
      "notification={'jsonrpc':'2.0','method':'test/received','params':received}\n" &
      "sys.stdout.buffer.write(frame(notification)); sys.stdout.buffer.flush(); time.sleep(2)\n"
    let session = startLspSession("python3", ["-u", "-c", server], "", "Nimculus")
    defer: session.stop()
    var received: JsonNode
    let wait = waitForTest("LSP progress-token response",
      condition = proc(): bool =
        for message in session.poll():
          if message.kind == JObject and message.hasKey("method") and
              message["method"].getStr == "test/received":
            received = message["params"]
        received != nil)
    check checkTestWait(wait)
    check received != nil
    check received["id"].getInt == 23
    check received["result"].kind == JNull
    check session.hasProgressToken(%*"server-work")
    check session.state == lspSessionReady

  test "session fails and releases an initialize request after timeout":
    let server = "import time; time.sleep(2)"
    let session = startLspSession("python3", ["-u", "-c", server], "", "Nimculus")
    defer: session.stop()
    session.requestTimeoutMs = 1
    sleep(10)
    discard session.poll()
    check session.state == lspSessionFailed
    check session.tracker.pendingCount == 0
