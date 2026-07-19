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
