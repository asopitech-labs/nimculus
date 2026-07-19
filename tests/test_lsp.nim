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
