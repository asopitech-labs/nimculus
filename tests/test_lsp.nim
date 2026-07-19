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
