import std/unittest
import std/os
import nimculus/editor_buffer
import nimculus/editor_diagnostics
import nimculus/lsp_editor_bridge

suite "LSP editor bridge":
  test "encodes file URIs and language IDs":
    check fileUri("/tmp/a b.nim") == "file:///tmp/a%20b.nim"
    check filePathFromUri("file:///tmp/a%20b.nim") == "/tmp/a b.nim"
    check languageIdForPath("main.rs") == "rust"
    check languageIdForPath("README.md") == "markdown"
    check languageIdForPath("notes.txt") == "plaintext"

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
