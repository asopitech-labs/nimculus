import std/unittest
import std/os
import nimculus/editor_buffer
import nimculus/editor_diagnostics
import nimculus/lsp_editor_bridge

suite "LSP editor bridge":
  test "encodes file URIs and language IDs":
    check fileUri("/tmp/a b.nim") == "file:///tmp/a%20b.nim"
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
