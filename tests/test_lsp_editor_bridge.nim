import std/unittest
import std/os
import std/times
import std/tables
import nimculus/editor_buffer
import nimculus/editor_diagnostics
import nimculus/lsp
import nimculus/lsp_editor_bridge

suite "LSP editor bridge":
  when defined(posix):
    test "shutdown bounds an unresponsive direct server without writing didClose":
      # The application is authorized to stop only the exact LSP process it
      # started.  Do not create a background child here: testing process-group
      # termination both contradicts that boundary and can leak an orphan when
      # the parent ignores TERM.
      let bridge = newLspEditorBridge("/bin/sh", ["-c",
        "trap '' TERM; while :; do sleep 1; done"])
      bridge.updateDocument("/tmp/shutdown.nim", "discard")
      check bridge.session != nil
      bridge.shutdown()
      check bridge.session == nil

  test "encodes file URIs and language IDs":
    check fileUri("/tmp/a b.nim") == "file:///tmp/a%20b.nim"
    check filePathFromUri("file:///tmp/a%20b.nim") == "/tmp/a b.nim"
    check languageIdForPath("main.rs") == "rust"
    check languageIdForPath("component.tsx") == "typescriptreact"
    check languageIdForPath("module.mts") == "typescript"
    check languageIdForPath("README.md") == "markdown"
    check languageIdForPath("notes.txt") == "plaintext"

  when defined(posix):
    test "opens TSX documents with the TypeScript React wire language ID":
      let markerPath = "/tmp/nimculus-test-lsp-tsx-language-id"
      if fileExists(markerPath): removeFile(markerPath)
      defer:
        if fileExists(markerPath): removeFile(markerPath)
      let server = "import sys,json,time\n" &
        "def frame(x):\n" &
        "    b=json.dumps(x,separators=(',',':')).encode()\n" &
        "    return ('Content-Length: '+str(len(b))+'\\r\\n\\r\\n').encode()+b\n" &
        "init={'jsonrpc':'2.0','id':1,'result':{'capabilities':{}}}\n" &
        "sys.stdout.buffer.write(frame(init)); sys.stdout.buffer.flush()\n" &
        "data=b''\n" &
        "while True:\n" &
        "    chunk=sys.stdin.buffer.read(1)\n" &
        "    if not chunk: break\n" &
        "    data += chunk\n" &
        "    if b'\\\"languageId\\\":\\\"typescriptreact\\\"' in data:\n" &
        "        open('" & markerPath & "','w').write('typescriptreact'); break\n" &
        "time.sleep(2)\n"
      let bridge = newLspEditorBridge("python3", ["-u", "-c", server])
      defer: bridge.stop()
      for _ in 0 ..< 40:
        bridge.updateDocument("/tmp/component.tsx", "export const Component = () => <main />")
        discard bridge.poll()
        if fileExists(markerPath): break
        sleep(10)
      check bridge.opened
      check fileExists(markerPath)
      if fileExists(markerPath): check readFile(markerPath) == "typescriptreact"

  test "opens the active document and exposes server diagnostics":
    let server = "import sys,json,time\n" &
      "def frame(x):\n" &
      "    b=json.dumps(x,separators=(',',':')).encode()\n" &
      "    return ('Content-Length: '+str(len(b))+'\\r\\n\\r\\n').encode()+b\n" &
      "init={'jsonrpc':'2.0','id':1,'result':{'capabilities':{}}}\n" &
      "diag={'jsonrpc':'2.0','method':'textDocument/publishDiagnostics','params':{'uri':'file:///tmp/a%20b.nim','diagnostics':[{'range':{'start':{'line':0,'character':1},'end':{'line':0,'character':3}},'severity':2,'message':'warning'}]}}\n" &
      "sys.stdout.buffer.write(frame(init)+frame(diag)); sys.stdout.buffer.flush(); time.sleep(2)\n"
    let bridge = newLspEditorBridge("python3", ["-u", "-c", server])
    defer: bridge.stop()
    bridge.updateDocument("/tmp/a b.nim", "A日本")
    for _ in 0 ..< 20:
      discard bridge.poll()
      if bridge.opened: break
      sleep(10)
    check bridge.opened
    check bridge.version == 1
    check bridge.diagnostics.len == 1
    let buffer = initPieceTable("A日本")
    let resolved = buffer.resolveDiagnostics(bridge.diagnostics())
    check resolved.len == 1
    check resolved[0].startByte == 1
    check resolved[0].endByte == 7
    bridge.updateDocument("/tmp/a b.nim", "A日本語")
    check bridge.version == 2

  when defined(posix):
    test "keeps split-pane documents open with independent versions":
      let server = "import sys,json,time\n" &
        "def frame(x):\n" &
        "    b=json.dumps(x,separators=(',',':')).encode()\n" &
        "    return ('Content-Length: '+str(len(b))+'\\r\\n\\r\\n').encode()+b\n" &
        "init={'jsonrpc':'2.0','id':1,'result':{'capabilities':{}}}\n" &
        "sys.stdout.buffer.write(frame(init)); sys.stdout.buffer.flush(); time.sleep(10)\n"
      let bridge = newLspEditorBridge("python3", ["-u", "-c", server])
      defer: bridge.stop()
      var longestPoll = 0.0
      for _ in 0 ..< 100:
        bridge.updateDocument("/tmp/primary.nim", "let primary = 1")
        bridge.syncDocument("/tmp/secondary.nim", "let secondary = 2")
        let pollStarted = epochTime()
        discard bridge.poll()
        longestPoll = max(longestPoll, epochTime() - pollStarted)
        if bridge.openedDocumentCount == 2: break
        sleep(10)
      check longestPoll < 0.5
      check bridge.openedDocumentCount == 2
      check bridge.documentVersion("/tmp/primary.nim") == 1
      check bridge.documentVersion("/tmp/secondary.nim") == 1
      bridge.updateDocument("/tmp/primary.nim", "let primary = 3")
      check bridge.documentVersion("/tmp/primary.nim") == 2
      check bridge.documentVersion("/tmp/secondary.nim") == 1

  test "keeps inlay hints isolated by document path":
    let bridge = newLspEditorBridge("unused")
    let left = absolutePath("/tmp/left.nim")
    let right = absolutePath("/tmp/right.nim")
    bridge.inlayHintsByUri.mgetOrPut(fileUri(left), @[]) = @[
      LspInlayHint(position: LspPosition(line: 1, character: 2),
        label: "left", kind: 1)]
    bridge.inlayHintsByUri.mgetOrPut(fileUri(right), @[]) = @[
      LspInlayHint(position: LspPosition(line: 4, character: 5),
        label: "right", kind: 2)]
    check bridge.inlayHintsForPath(left).len == 1
    check bridge.inlayHintsForPath(left)[0].label == "left"
    check bridge.inlayHintsForPath(right).len == 1
    check bridge.inlayHintsForPath(right)[0].label == "right"

  test "requests completion at UTF-16 cursor and accepts a stale-safe edit":
    let server = "import sys,json,time\n" &
      "def frame(x):\n" &
      "    b=json.dumps(x,separators=(',',':')).encode()\n" &
      "    return ('Content-Length: '+str(len(b))+'\\r\\n\\r\\n').encode()+b\n" &
      "init={'jsonrpc':'2.0','id':1,'result':{'capabilities':{'completionProvider':{}}}}\n" &
      "completion={'jsonrpc':'2.0','id':2,'result':{'isIncomplete':False,'items':[{'label':'日本語','insertText':'日本語','detail':'word'}]}}\n" &
      "sys.stdout.buffer.write(frame(init)); sys.stdout.buffer.flush()\n" &
      "data=b''\n" &
      "while True:\n" &
      "    chunk=sys.stdin.buffer.read(1)\n" &
      "    if not chunk: break\n" &
      "    data += chunk\n" &
      "    if b'textDocument/completion' in data:\n" &
      "        sys.stdout.buffer.write(frame(completion)); sys.stdout.buffer.flush(); break\n" &
      "time.sleep(2)\n"
    let bridge = newLspEditorBridge("python3", ["-u", "-c", server])
    defer: bridge.stop()
    bridge.updateDocument("/tmp/completion.nim", "x日本")
    for _ in 0 ..< 30:
      discard bridge.poll()
      if bridge.opened: break
      sleep(10)
    check bridge.opened
    let buffer = initPieceTable("x日本")
    check bridge.requestCompletion(buffer, buffer.toString().len)
    for _ in 0 ..< 30:
      discard bridge.poll()
      if bridge.completionVisible: break
      sleep(10)
    check bridge.completionVisible
    check bridge.completionItems[0].label == "日本語"
    let edit = bridge.completionEdit(buffer)
    check edit.startByte == 0
    check edit.endByte == 7
    check edit.text == "日本語"

  test "delays hover and rejects a response for a moved cursor":
    let server = "import sys,json,time\n" &
      "def frame(x):\n" &
      "    b=json.dumps(x,separators=(',',':')).encode()\n" &
      "    return ('Content-Length: '+str(len(b))+'\\r\\n\\r\\n').encode()+b\n" &
      "init={'jsonrpc':'2.0','id':1,'result':{'capabilities':{'hoverProvider':True}}}\n" &
      "hover={'jsonrpc':'2.0','id':2,'result':{'contents':'symbol info'}}\n" &
      "sys.stdout.buffer.write(frame(init)); sys.stdout.buffer.flush()\n" &
      "data=b''\n" &
      "while True:\n" &
      "    chunk=sys.stdin.buffer.read(1)\n" &
      "    if not chunk: break\n" &
      "    data += chunk\n" &
      "    if b'textDocument/hover' in data:\n" &
      "        sys.stdout.buffer.write(frame(hover)); sys.stdout.buffer.flush(); break\n" &
      "time.sleep(2)\n"
    let bridge = newLspEditorBridge("python3", ["-u", "-c", server])
    defer: bridge.stop()
    bridge.updateDocument("/tmp/hover.nim", "symbol")
    for _ in 0 ..< 30:
      discard bridge.poll()
      if bridge.opened: break
      sleep(10)
    let buffer = initPieceTable("symbol")
    bridge.scheduleHover(2)
    check not bridge.tickHover(buffer)
    for _ in 0 ..< 3: check not bridge.tickHover(buffer)
    check bridge.tickHover(buffer)
    for _ in 0 ..< 30:
      discard bridge.poll()
      if bridge.hoverVisible: break
      sleep(10)
    check bridge.hoverVisible
    check bridge.hoverText() == "symbol info"
    bridge.scheduleHover(3)
    check not bridge.hoverVisible

  test "requests definition with UTF-16 cursor and stores locations":
    let server = "import sys,json,time\n" &
      "def frame(x):\n" &
      "    b=json.dumps(x,separators=(',',':')).encode()\n" &
      "    return ('Content-Length: '+str(len(b))+'\\r\\n\\r\\n').encode()+b\n" &
      "init={'jsonrpc':'2.0','id':1,'result':{'capabilities':{'definitionProvider':True}}}\n" &
      "definition={'jsonrpc':'2.0','id':2,'result':[{'uri':'file:///tmp/target.nim','range':{'start':{'line':3,'character':2},'end':{'line':3,'character':5}}}]}\n" &
      "sys.stdout.buffer.write(frame(init)); sys.stdout.buffer.flush()\n" &
      "data=b''\n" &
      "while True:\n" &
      "    chunk=sys.stdin.buffer.read(1)\n" &
      "    if not chunk: break\n" &
      "    data += chunk\n" &
      "    if b'textDocument/definition' in data:\n" &
      "        sys.stdout.buffer.write(frame(definition)); sys.stdout.buffer.flush(); break\n" &
      "time.sleep(2)\n"
    let bridge = newLspEditorBridge("python3", ["-u", "-c", server])
    defer: bridge.stop()
    bridge.updateDocument("/tmp/definition.nim", "x日本")
    for _ in 0 ..< 30:
      discard bridge.poll()
      if bridge.opened: break
      sleep(10)
    let buffer = initPieceTable("x日本")
    check bridge.requestDefinition(buffer, buffer.toString().len)
    for _ in 0 ..< 30:
      discard bridge.poll()
      if bridge.definitionRequestId == 0: break
      sleep(10)
    let locations = bridge.takeDefinitionLocations()
    check locations.len == 1
    check locations[0].uri == "file:///tmp/target.nim"
    check locations[0].range.start.line == 3

  test "requests formatting and returns edits for the current document version":
    let server = "import sys,json,time\n" &
      "def frame(x):\n" &
      "    b=json.dumps(x,separators=(',',':')).encode()\n" &
      "    return ('Content-Length: '+str(len(b))+'\\r\\n\\r\\n').encode()+b\n" &
      "init={'jsonrpc':'2.0','id':1,'result':{'capabilities':{'documentFormattingProvider':True}}}\n" &
      "formatted={'jsonrpc':'2.0','id':2,'result':[{'range':{'start':{'line':0,'character':0},'end':{'line':0,'character':5}},'newText':'world'}]}\n" &
      "sys.stdout.buffer.write(frame(init)); sys.stdout.buffer.flush()\n" &
      "data=b''\n" &
      "while True:\n" &
      "    chunk=sys.stdin.buffer.read(1)\n" &
      "    if not chunk: break\n" &
      "    data += chunk\n" &
      "    if b'textDocument/formatting' in data:\n" &
      "        sys.stdout.buffer.write(frame(formatted)); sys.stdout.buffer.flush(); break\n" &
      "time.sleep(2)\n"
    let bridge = newLspEditorBridge("python3", ["-u", "-c", server])
    defer: bridge.stop()
    bridge.updateDocument("/tmp/format.nim", "hello")
    for _ in 0 ..< 30:
      discard bridge.poll()
      if bridge.opened: break
      sleep(10)
    check bridge.opened
    check bridge.requestFormatting()
    for _ in 0 ..< 30:
      discard bridge.poll()
      if bridge.formattingReady: break
      sleep(10)
    let edits = bridge.takeFormattingEdits()
    check edits.len == 1
    check edits[0].range.start.character == 0
    check edits[0].range.finish.character == 5
    check edits[0].newText == "world"

  test "drops document feature results when the text generation advances":
    let bridge = newLspEditorBridge("python3", [])
    bridge.lastText = "one"
    bridge.uri = "file:///tmp/stale.nim"
    bridge.path = "/tmp/stale.nim"
    bridge.codeActions.add(LspCodeAction(title: "stale"))
    bridge.referenceLocations.add(LspLocation(uri: bridge.uri))
    bridge.symbols.add(LspSymbol(name: "stale"))
    bridge.semanticTokens.add(LspSemanticToken(line: 0, startCharacter: 0, length: 1))
    bridge.cancelDocumentFeatureRequests()
    check bridge.codeActions.len == 0
    check bridge.referenceLocations.len == 0
    check bridge.symbols.len == 0
    check bridge.semanticTokens.len == 0
