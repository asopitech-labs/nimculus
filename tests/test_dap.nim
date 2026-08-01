import std/json
import std/os
import std/strutils
import std/unittest

import nimculus/dap

suite "M19 DAP transport":
  test "frames use UTF-8 byte length and decode partial messages":
    let payload = %*{"seq": 1, "type": "event", "event": "output",
      "body": {"output": "日本語"}}
    let encoded = encodeDapMessage(payload)
    check encoded.startsWith("Content-Length: " & $($payload).len & "\r\n\r\n")
    var decoder = DapFrameDecoder()
    let split = encoded.find("日本")
    check decoder.feed(encoded[0 ..< split]).len == 0
    let messages = decoder.feed(encoded[split .. ^1])
    check messages.len == 1
    check parseMessage(messages[0]).event == "output"
    check parseMessage(messages[0]).body["output"].getStr == "日本語"

  test "decoder retains multiple frames and bounds malformed input":
    let first = %*{"seq": 1, "type": "event", "event": "initialized"}
    let second = %*{"seq": 2, "type": "event", "event": "continued"}
    var decoder = DapFrameDecoder()
    let messages = decoder.feed(encodeDapMessage(first) & encodeDapMessage(second))
    check messages.len == 2
    expect DapProtocolError:
      discard decoder.feed("Content-Length: nope\r\n\r\n{}")

  test "request tracker rejects stale completion and expires requests":
    var tracker = initDapRequestTracker()
    let initialize = tracker.beginRequest("initialize")
    let launch = tracker.beginRequest("launch")
    check initialize.seq == 1
    check launch.seq == 2
    check tracker.pendingCount == 2
    check tracker.cancelRequest(launch.seq)
    check not tracker.finishRequest(999)
    let expired = tracker.expireRequests(launch.startedAtMs + DefaultDapRequestTimeoutMs + 1)
    check initialize.seq in expired
    check launch.seq notin expired
    check tracker.finishRequest(initialize.seq)
    let stale = tracker.beginRequest("stackTrace")
    check tracker.cancelRequest(stale.seq)
    check not tracker.acceptResponse(stale.seq)

  test "protocol helpers produce launch and breakpoint arguments":
    let init = initializeArguments()
    check init["clientID"].getStr == "nimculus"
    check launchArguments("/tmp/app", "/tmp", @[
      "--flag", "日本語"])["args"][1].getStr == "日本語"
    let breakpoints = setBreakpointsArguments("/tmp/main.nim", [3, 8])
    check breakpoints["source"]["path"].getStr == "/tmp/main.nim"
    check breakpoints["breakpoints"].len == 2
    check attachArguments(42, "/tmp")["processId"].getInt == 42
    check threadsArguments().kind == JObject

  test "session starts, exchanges a DAP frame, and stops its direct child":
    let server = getTempDir() / "nimculus-dap-test-server.sh"
    let response = "{\"seq\":2,\"type\":\"response\",\"request_seq\":1,\"success\":true,\"command\":\"initialize\"}"
    writeFile(server, "#!/bin/sh\n" &
      "IFS= read -r header\n" &
      "IFS= read -r blank\n" &
      "printf 'Content-Length: " & $response.len & "\\r\\n\\r\\n" & response & "'\\n")
    setFilePermissions(server, {fpUserRead, fpUserWrite, fpUserExec})
    let session = startDapSession("/bin/sh", [server])
    let request = session.sendRequest("initialize", initializeArguments())
    check request.seq == 1
    var messages: seq[DapMessage]
    for _ in 0 .. 20:
      messages = session.poll()
      if messages.len > 0: break
      sleep(10)
    check messages.len == 1
    check messages[0].messageType == dapResponseMessage
    check messages[0].requestSeq == 1
    check session.pendingCount == 0
    session.stop()
    check session.state == dapStopped
    removeFile(server)
