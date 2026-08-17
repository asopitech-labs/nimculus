import std/json
import std/strutils
import std/unittest

import nimculus/repl_session
import nimculus/sha256

suite "REPL v5 message layer":
  test "SHA-256 NIST fixtures and RFC 4231 HMAC fixtures":
    let longMessage = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
    check sha256Hex("") ==
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    check sha256Hex("abc") ==
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    check sha256Hex(longMessage) ==
      "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
    check hmacSha256Hex(repeat("\x0b", 20), "Hi There") ==
      "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
    check hmacSha256Hex("Jefe", "what do ya want for nothing?") ==
      "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"

  test "signed multipart message round-trips and detects content mutation":
    let key = "test-secret"
    let frames = encodeReplMessage(
      %*{"msg_id": "request-1", "msg_type": "execute_request"},
      %*{}, %*{"path": "/tmp/main.nim", "line": 10},
      %*{"code": "1 + 1"}, key)
    check frames.len == ReplWireFrameCount
    let decoded = decodeReplMessage(frames, key)
    check decoded.valid
    check verifyReplMessage(frames, key)
    check decoded.message.content["code"].getStr == "1 + 1"
    var mutated = frames
    mutated[5][mutated[5].high] = if mutated[5][mutated[5].high] == '}': ']' else: '}'
    check not verifyReplMessage(mutated, key)
    let rejected = decodeReplMessage(mutated, key)
    check not rejected.valid

  test "execute and output message sequencing increments execution count":
    let session = newReplSession()
    for count in 1 .. 3:
      let request = ReplMessage(header: %*{"msg_id": "request-" & $count,
        "msg_type": "execute_request"}, parentHeader: %*{},
        metadata: %*{"path": "/tmp/main.nim", "line": 10},
        content: %*{"code": $count})
      check session.handleReplMessage(request)
      check session.executionCount == count
      check session.handleReplMessage(ReplMessage(
        header: %*{"msg_type": "execute_reply"}, parentHeader: %*{},
        metadata: %*{}, content: %*{"execution_count": count}))
      check session.handleReplMessage(ReplMessage(
        header: %*{"msg_type": "stream"},
        parentHeader: %*{"msg_id": "request-" & $count},
        metadata: %*{}, content: %*{"name": "stdout", "text": $count}))
      check session.handleReplMessage(ReplMessage(
        header: %*{"msg_type": "display_data"},
        parentHeader: %*{"msg_id": "request-" & $count},
        metadata: %*{}, content: %*{"data": {"text/plain": $count}}))

  test "result store is line keyed and replaces a re-execution":
    let session = newReplSession()
    let request = ReplMessage(header: %*{"msg_id": "line-10",
      "msg_type": "execute_request"}, parentHeader: %*{},
      metadata: %*{"path": "/tmp/main.nim", "line": 10}, content: %*{})
    discard session.handleReplMessage(request)
    discard session.handleReplMessage(ReplMessage(header: %*{"msg_type": "stream"},
      parentHeader: %*{"msg_id": "line-10"}, metadata: %*{},
      content: %*{"text": "first"}))
    check session.results.outputCount("/tmp/main.nim", 10) == 1
    check session.results.outputCount("/tmp/main.nim", 11) == 0
    discard session.handleReplMessage(request)
    discard session.handleReplMessage(ReplMessage(header: %*{"msg_type": "stream"},
      parentHeader: %*{"msg_id": "line-10"}, metadata: %*{},
      content: %*{"text": "second"}))
    check session.results.outputCount("/tmp/main.nim", 10) == 1
    check session.results.outputsAt("/tmp/main.nim", 10)[0].content["text"].getStr == "second"

  test "oversized frame is rejected before message processing":
    let frames = @[ReplMessageDelimiter, "", "", "", "", ""]
    check not replFrameLengthAllowed(9, 8)
    check not verifyReplMessage(frames, "key", 8)
    let decoded = decodeReplMessage(frames, "key", 8)
    check not decoded.valid
