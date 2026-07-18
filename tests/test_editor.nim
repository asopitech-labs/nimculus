import std/unittest
import std/os
import std/strutils
import nimculus/editor_buffer
import nimculus/editor_app
import nimculus/editor_view
import nimculus/session

suite "M4 editor buffer":
  test "piece table edits and undo redo preserve content":
    var buffer = initPieceTable("hello\n世界")
    buffer.edit(Edit(startByte: 6, endByte: 12, text: "Nimculus"))
    check buffer.toString() == "hello\nNimculus"
    check buffer.isDirty
    check buffer.undo()
    check buffer.toString() == "hello\n世界"
    check buffer.redo()
    check buffer.toString() == "hello\nNimculus"

  test "multi cursor edits are one transaction":
    var buffer = initPieceTable("a a a")
    buffer.applyEdits(@[
      Edit(startByte: 0, endByte: 1, text: "x"),
      Edit(startByte: 2, endByte: 3, text: "y"),
      Edit(startByte: 4, endByte: 5, text: "z")])
    check buffer.toString() == "x y z"
    check buffer.undo()
    check buffer.toString() == "a a a"

  test "overlapping edits fail before mutating the buffer":
    var buffer = initPieceTable("abcdef")
    expect ValueError:
      buffer.applyEdits(@[
        Edit(startByte: 1, endByte: 4, text: "x"),
        Edit(startByte: 3, endByte: 5, text: "y")])
    check buffer.toString() == "abcdef"

  test "line and UTF-16 positions handle Japanese and astral characters":
    var buffer = initPieceTable("A\n😀日本")
    check buffer.lineColumn(2) == (line: 1, column: 0)
    check buffer.utf16Position(6) == (line: 1, character: 2)
    check buffer.byteOffsetAtLineColumn(1, 0) == 2
    check buffer.byteOffsetAtLineColumn(1, 1) == 6
    check buffer.byteOffsetAtLineColumn(1, 2) == 9
    check previousWordBoundary("hello 世界", 12) == 6
    check nextWordBoundary("hello 世界", 0) == 5

  test "saved state tracks edits":
    var buffer = initPieceTable("content")
    buffer.markSaved()
    buffer.edit(Edit(startByte: 7, endByte: 7, text: "!"))
    check buffer.isDirty
    buffer.markSaved()
    check not buffer.isDirty

suite "M5 editor services":
  test "open save search replace and external change":
    let path = getTempDir() / "nimculus-m5-test.txt"
    writeFile(path, "one\r\ntwo\r\none")
    var document = openDocument(path)
    check document.lineEnding == crlf
    check document.search("one").len == 2
    check document.replaceAll("one", "1") == 2
    document.save()
    check readFile(path) == "1\r\ntwo\r\n1"
    check not document.externallyChanged
    writeFile(path, "changed")
    check document.externallyChanged
    removeFile(path)
    check document.externallyChanged

  test "tabs and split sessions":
    var session: EditorSession
    session.addTab(newDocument())
    session.addTab(newDocument())
    session.splitEditor(splitVertical)
    check session.tabs.len == 2
    check session.split
    check session.closeActiveTab()
    check session.tabs.len == 1

  test "view state exposes cursor, selection, lines and status":
    var buffer = initPieceTable("one\ntwo")
    var view = newEditorView()
    view.moveCursor(4)
    view.moveCursor(6, selecting = true)
    check view.selectedRange() == (startByte: 4, endByte: 6)
    check buffer.visibleLines(0, 2) == @["one", "two"]
    check view.statusBarText(buffer).contains("Ln 2")
    view.openCommandPalette()
    check view.commandPaletteOpen

  test "session and recovery round trip":
    let path = getTempDir() / "nimculus-m5-session.txt"
    let recoveryPath = getTempDir() / "nimculus-m5-recovery.txt"
    writeFile(path, "session")
    var session: EditorSession
    session.addTab(openDocument(path))
    session.workspaceRoots = @[getTempDir()]
    let sessionPath = getTempDir() / "nimculus-m5-session.json"
    session.saveSession(sessionPath)
    let restored = loadSession(sessionPath)
    check restored.tabs.len == 1
    check restored.workspaceRoots == @[getTempDir()]
    restored.tabs[0].document.writeRecovery(recoveryPath)
    check recoverDocument(recoveryPath).buffer.toString() == "session"
    removeFile(path); removeFile(sessionPath); removeFile(recoveryPath)

  test "session loader tolerates partial metadata":
    let path = getTempDir() / "nimculus-m5-partial-session.json"
    writeFile(path, "{\"tabs\": []}")
    let session = loadSession(path)
    check session.activeTab == -1
    check session.tabs.len == 0
    removeFile(path)

  test "session loader tolerates invalid JSON and out of range active tab":
    let invalidPath = getTempDir() / "nimculus-m5-invalid-session.json"
    writeFile(invalidPath, "not-json")
    check loadSession(invalidPath).activeTab == -1
    removeFile(invalidPath)

    let rangePath = getTempDir() / "nimculus-m5-range-session.json"
    writeFile(rangePath, "{\"activeTab\": 99, \"tabs\": []}")
    check loadSession(rangePath).activeTab == -1
    removeFile(rangePath)
