import std/json
import std/os
import std/osproc
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
    check init["pathFormat"].getStr == "path"
    check launchArguments("/tmp/app", "/tmp", @[
      "--flag", "日本語"])["args"][1].getStr == "日本語"
    let breakpoints = setBreakpointsArguments("/tmp/main.nim", [3, 8])
    check breakpoints["source"]["path"].getStr == "/tmp/main.nim"
    check breakpoints["breakpoints"].len == 2
    check attachArguments(42, "/tmp")["processId"].getInt == 42
    check attachArguments(42, "/tmp")["pid"].getInt == 42
    check threadsArguments().kind == JObject

  test "reverse requests produce correlated responses without pending state":
    var tracker = initDapRequestTracker()
    let reverse = parseMessage(%*{"seq": 41, "type": "request",
      "command": "runInTerminal", "arguments": {"args": ["/bin/echo"]}})
    let response = reverse.responseJson(tracker.allocateSequence(), true,
      %*{"processId": 99})
    let parsed = parseMessage(response)
    check parsed.messageType == dapResponseMessage
    check parsed.seq == 1
    check parsed.requestSeq == 41
    check parsed.command == "runInTerminal"
    check parsed.success
    check parsed.body["processId"].getInt == 99
    check tracker.pendingCount == 0

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

  when defined(macosx):
    test "macOS lldb-dap launches a target and returns stopped stack data":
      let xcrun = findExe("xcrun")
      let clang = findExe("clang")
      if xcrun.len == 0 or clang.len == 0:
        skip()
      let source = currentSourcePath().parentDir / "fixtures" / "dap_target.c"
      let target = getTempDir() / "nimculus-dap-target-" & $getCurrentProcessId()
      let compile = startProcess(clang, args = @[
        "-g", "-O0", "-fno-omit-frame-pointer", "-o", target, source],
        options = {poUsePath})
      check compile.waitForExit(10_000) == 0
      defer:
        if fileExists(target): removeFile(target)
      let session = startDapSession(xcrun, ["lldb-dap"], source.parentDir)
      defer: session.stop()

      let initialize = session.sendRequest("initialize", initializeArguments())
      var launch: DapPendingRequest
      var breakpoint: DapPendingRequest
      var configuration: DapPendingRequest
      var stackRequest: DapPendingRequest
      var scopes: DapPendingRequest
      var variables: DapPendingRequest
      var initialized = false
      var launched = false
      var stopped = false
      var stackReceived = false
      var scopesReceived = false
      var variablesReceived = false
      var breakpointVerified = false
      var valueObserved = false
      var threadId = 0
      var frameId = 0
      var variableReference = 0

      for _ in 0 ..< 800:
        for message in session.poll():
          case message.messageType
          of dapResponseMessage:
            if message.requestSeq == initialize.seq and message.success:
              launch = session.sendRequest("launch", launchArguments(target,
                source.parentDir))
            elif launch.seq > 0 and message.requestSeq == launch.seq:
              check message.success
              launched = message.success
            elif breakpoint.seq > 0 and message.requestSeq == breakpoint.seq:
              check message.success
              if message.success and message.body != nil and
                  message.body.hasKey("breakpoints") and
                  message.body["breakpoints"].kind == JArray and
                  message.body["breakpoints"].len > 0:
                let resolved = message.body["breakpoints"][0]
                breakpointVerified = resolved.kind == JObject and
                  (not resolved.hasKey("verified") or resolved["verified"].getBool)
            elif configuration.seq > 0 and message.requestSeq == configuration.seq:
              check message.success
            elif stackRequest.seq > 0 and message.requestSeq == stackRequest.seq:
              check message.success
              if message.success and message.body != nil and
                  message.body.hasKey("stackFrames") and
                  message.body["stackFrames"].kind == JArray and
                  message.body["stackFrames"].len > 0:
                let frame = message.body["stackFrames"][0]
                frameId = if frame.hasKey("id"): frame["id"].getInt else: 0
                stackReceived = frameId > 0
                if stackReceived:
                  scopes = session.sendRequest("scopes", scopesArguments(frameId))
            elif scopes.seq > 0 and message.requestSeq == scopes.seq:
              check message.success
              if message.success and message.body != nil and
                  message.body.hasKey("scopes") and
                  message.body["scopes"].kind == JArray:
                for scope in message.body["scopes"]:
                  if scope.kind == JObject and scope.hasKey("variablesReference"):
                    variableReference = scope["variablesReference"].getInt
                    break
                scopesReceived = variableReference > 0
                if scopesReceived:
                  variables = session.sendRequest("variables",
                    variablesArguments(variableReference))
            elif variables.seq > 0 and message.requestSeq == variables.seq:
              check message.success
              variablesReceived = message.success and message.body != nil and
                message.body.hasKey("variables") and
                message.body["variables"].kind == JArray
              if variablesReceived:
                for variable in message.body["variables"]:
                  if variable.kind == JObject and variable.hasKey("value") and
                      variable["value"].getStr.contains("42"):
                    valueObserved = true
          of dapEventMessage:
            if message.event == "initialized" and not initialized:
              initialized = true
              breakpoint = session.sendRequest("setBreakpoints",
                setBreakpointsArguments(source, [5]))
              configuration = session.sendRequest("configurationDone",
                configurationDoneArguments())
            elif message.event == "stopped" and not stopped:
              stopped = true
              threadId = if message.body != nil and message.body.hasKey("threadId"):
                message.body["threadId"].getInt else: 0
              if threadId > 0:
                stackRequest = session.sendRequest("stackTrace",
                  stackTraceArguments(threadId))
          of dapRequestMessage:
            session.sendResponse(message, false, %*{},
              "reverse request is not part of this integration fixture")
        if variablesReceived: break
        sleep(10)

      check initialized
      check launched
      check stopped
      check breakpointVerified
      check stackReceived
      check scopesReceived
      check variablesReceived
      check valueObserved

    test "macOS lldb-dap attaches to a running target":
      let xcrun = findExe("xcrun")
      let clang = findExe("clang")
      if xcrun.len == 0 or clang.len == 0:
        skip()
      let source = currentSourcePath().parentDir / "fixtures" / "dap_target.c"
      let target = getTempDir() / "nimculus-dap-attach-target-" & $getCurrentProcessId()
      let compile = startProcess(clang, args = @[
        "-g", "-O0", "-fno-omit-frame-pointer", "-o", target, source],
        options = {poUsePath})
      check compile.waitForExit(10_000) == 0
      defer:
        if fileExists(target): removeFile(target)
      let targetProcess = startProcess(target, options = {poUsePath})
      defer:
        try:
          if targetProcess.running:
            targetProcess.terminate()
            discard targetProcess.waitForExit(1_000)
        except OSError:
          discard
        try:
          targetProcess.close()
        except OSError:
          discard
      let session = startDapSession(xcrun, ["lldb-dap"], source.parentDir)
      defer: session.stop()

      let initialize = session.sendRequest("initialize", initializeArguments())
      var attach: DapPendingRequest
      var configuration: DapPendingRequest
      var initialized = false
      var attached = false
      var stopped = false
      for _ in 0 ..< 800:
        for message in session.poll():
          case message.messageType
          of dapResponseMessage:
            if message.requestSeq == initialize.seq and message.success:
              var arguments = attachArguments(targetProcess.processID, source.parentDir)
              arguments["stopOnEntry"] = newJBool(true)
              attach = session.sendRequest("attach", arguments)
            elif attach.seq > 0 and message.requestSeq == attach.seq:
              check message.success
              attached = message.success
            elif configuration.seq > 0 and message.requestSeq == configuration.seq:
              check message.success
          of dapEventMessage:
            if message.event == "initialized" and not initialized:
              initialized = true
              configuration = session.sendRequest("configurationDone",
                configurationDoneArguments())
            elif message.event == "stopped":
              stopped = true
          of dapRequestMessage:
            session.sendResponse(message, false, %*{},
              "reverse request is not part of this integration fixture")
        if stopped: break
        sleep(10)
      check initialized
      check attached
      check stopped
