import std/unittest
import std/os
when defined(posix):
  import std/files
import std/strutils
import nimculus/editor_buffer
import nimculus/editor_diagnostics
import nimculus/lsp
import nimculus/editor_app
import nimculus/editor_view
import nimculus/session
import nimculus/atomic_io

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

  test "edits reject invalid UTF-8 and partial codepoint ranges":
    var buffer = initPieceTable("é🙂")
    expect ValueError:
      buffer.edit(Edit(startByte: 4, endByte: 4, text: "x"))
    check buffer.toString() == "é🙂"
    expect ValueError:
      buffer.edit(Edit(startByte: 0, endByte: 0, text: "\xC3\x28"))
    check buffer.toString() == "é🙂"

  test "line and UTF-16 positions handle Japanese and astral characters":
    var buffer = initPieceTable("A\n😀日本")
    check buffer.lineColumn(2) == (line: 1, column: 0)
    check buffer.lineColumn(6) == (line: 1, column: 1)
    check buffer.lineColumn(12) == (line: 1, column: 3)
    check buffer.utf16Position(6) == (line: 1, character: 2)
    check buffer.byteOffsetAtUtf16Position(1, 0) == 2
    check buffer.byteOffsetAtUtf16Position(1, 1) == 2
    check buffer.byteOffsetAtUtf16Position(1, 2) == 6
    check buffer.byteOffsetAtUtf16Position(1, 3) == 9
    check buffer.byteOffsetAtUtf16Position(1, 99) == 12
    check buffer.byteOffsetAtLineColumn(1, 0) == 2
    check buffer.byteOffsetAtLineColumn(1, 1) == 6
    check buffer.byteOffsetAtLineColumn(1, 2) == 9
    let graphemeBuffer = initPieceTable("é😀日本")
    check graphemeBuffer.byteOffsetAtLineColumn(0, 0) == 0
    check graphemeBuffer.byteOffsetAtLineColumn(0, 1) == 3
    check graphemeBuffer.byteOffsetAtLineColumn(0, 2) == 7
    check graphemeBuffer.byteOffsetAtLineColumn(0, 4) == 13
    check previousWordBoundary("hello 世界", 12) == 6
    check nextWordBoundary("hello 世界", 0) == 5

  test "startup paths accept Japanese files and ignore editor flags":
    let root = getTempDir() / "nimculus-日本語-startup-paths"
    if dirExists(root): removeDir(root)
    createDir(root)
    let source = root / "日本語🙂.nim"
    let dashed = root / "-日本語.txt"
    defer:
      if fileExists(source): removeFile(source)
      if fileExists(dashed): removeFile(dashed)
      if dirExists(root): removeDir(root)
    writeFile(source, "echo \"日本語\"")
    let resolved = startupOpenPaths(@["--safe-mode", source, root, source])
    check resolved == @[canonicalOpenPath(source), canonicalOpenPath(root)]
    writeFile(dashed, "ok")
    let originalDir = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(originalDir)
    check startupOpenPaths(@["-日本語.txt"]).len == 0
    let escaped = startupOpenPaths(@["--", "-日本語.txt"])
    check escaped.len == 1
    check sameFile(escaped[0], dashed)
    check canonicalOpenPath(source) == expandFilename(source)

  test "opening an existing Japanese path resolves its current tab":
    let path = getTempDir() / "nimculus-日本語-existing-tab🙂.txt"
    writeFile(path, "日本語")
    defer:
      if fileExists(path): removeFile(path)
    var session: EditorSession
    session.addTab(openDocument(path))
    check session.tabIndexForPath(path) == 0
    check session.tabIndexForPath(path & ".missing") == -1

  test "resolves LSP diagnostics from UTF-16 positions to byte ranges":
    let buffer = initPieceTable("A\n😀日本")
    let diagnostic = LspDiagnostic(
      range: LspRange(start: LspPosition(line: 1, character: 2),
        finish: LspPosition(line: 1, character: 3)),
      severity: 1, message: "bad name", source: "nim")
    let resolved = buffer.resolveDiagnostics([diagnostic])
    check resolved.len == 1
    check resolved[0].startByte == 6
    check resolved[0].endByte == 9
    check resolved[0].message == "bad name"

  test "line end stops before the line terminator":
    let buffer = initPieceTable("one\ntwo\n")
    check buffer.lineEndByteOffset(0) == 3
    check buffer.lineEndByteOffset(1) == 7
    check buffer.lineEndByteOffset(2) == 8

  test "saved state tracks edits":
    var buffer = initPieceTable("content")
    buffer.markSaved()
    buffer.edit(Edit(startByte: 7, endByte: 7, text: "!"))
    check buffer.isDirty
    buffer.markSaved()
    check not buffer.isDirty

  test "undoing back to the saved content clears dirty state":
    var buffer = initPieceTable("content")
    buffer.markSaved()
    buffer.edit(Edit(startByte: 7, endByte: 7, text: "!"))
    check buffer.isDirty
    check buffer.undo()
    check not buffer.isDirty
    check buffer.redo()
    check buffer.isDirty
    check buffer.undo()
    check not buffer.isDirty

  test "cursor and deletion boundaries preserve grapheme clusters":
    let text = "é🙂‍💻"
    check previousGraphemeBoundary(text, text.len) == 3
    check nextGraphemeBoundary(text, 0) == 3
    check previousGraphemeBoundary(text, 3) == 0
    check nextGraphemeBoundary(text, 3) == text.len

  test "word movement recognizes Unicode whitespace":
    let text = "alpha　beta\ngamma"
    check previousWordBoundary(text, text.len) == 13
    check nextWordBoundary(text, 0) == 5
    check previousWordBoundary("é project", 4) == 0

  test "word movement separates punctuation like macOS Option movement":
    check previousWordBoundary("foo.bar", 7) == 4
    check previousWordBoundary("foo.", 4) == 0
    check nextWordBoundary("foo.bar", 0) == 3
    check nextWordBoundary(".hello", 0) == 6

suite "M5 editor services":
  test "open save search replace and external change":
    let path = getTempDir() / "nimculus-m5-日本語🙂.txt"
    writeFile(path, "one\r\n日本語🙂\r\none")
    var document = openDocument(path)
    check document.lineEnding == crlf
    check document.search("one").len == 2
    check document.replaceAll("one", "1") == 2
    document.save()
    check readFile(path) == "1\r\n日本語🙂\r\n1"
    for candidate in walkFiles(path & ".tmp." & $getCurrentProcessId() & ".*"):
      check not fileExists(candidate)
    when defined(posix):
      let originalPermissions = getFilePermissions(path)
      setFilePermissions(path, originalPermissions + {fpUserExec})
      document.buffer.edit(Edit(startByte: 0, endByte: 1, text: "x"))
      document.save()
      check fpUserExec in getFilePermissions(path)
    check not document.externallyChanged
    writeFile(path, "changed")
    check document.externallyChanged
    removeFile(path)

  test "failed save does not change the document path":
    let path = getTempDir() / "nimculus-m5-save-source.txt"
    writeFile(path, "source")
    var document = openDocument(path)
    let invalidPath = getTempDir() / "nimculus-m5-missing-dir" / "target.txt"
    expect IOError:
      document.save(invalidPath)
    check document.path == path
    removeFile(path)
    check document.externallyChanged

  test "external deletion is detected for an empty file":
    let path = getTempDir() / "nimculus-m5-empty-external.txt"
    writeFile(path, "")
    let document = openDocument(path)
    check not document.externallyChanged
    removeFile(path)
    check document.externallyChanged

  test "atomic replacement is detected even when the file size is unchanged":
    let path = getTempDir() / "nimculus-m5-identity.txt"
    writeFile(path, "first")
    var document = openDocument(path)
    check document.externalIdentity.len > 0
    atomicWriteFile(path, "second")
    check document.externallyChanged
    document.acceptExternalState()
    check not document.externallyChanged
    removeFile(path)

  test "keeping edits after external deletion records deleted disk state":
    let path = getTempDir() / "nimculus-m5-keep-deleted.txt"
    writeFile(path, "content")
    var document = openDocument(path)
    removeFile(path)
    check document.externallyChanged
    document.acceptExternalState()
    check not document.externallyChanged

  test "tabs and split sessions":
    var session: EditorSession
    var view = newEditorView()
    session.addTab(newDocument())
    session.addTab(newDocument())
    check session.activeTab == 1
    view.moveCursor(5)
    check session.switchTab(view, -1)
    check session.activeTab == 0
    check view.cursor == 0
    view.moveCursor(3)
    check session.switchTab(view, 1)
    check session.activeTab == 1
    check view.cursor == 5
    session.saveActiveView(view)
    session.addTab(newDocument())
    check session.tabs[1].view.cursor == 5
    session.splitEditor(splitVertical)
    check session.tabs.len == 3
    check session.split
    check session.closeActiveTab()
    check session.tabs.len == 2

  test "dirty tab close requires an explicit discard":
    var session: EditorSession
    var document = newDocument()
    document.buffer.edit(Edit(startByte: 0, endByte: 0, text: "unsaved"))
    session.addTab(document)
    check session.hasDirtyTabs()
    check not session.closeActiveTab()
    check session.tabs.len == 1
    check session.closeActiveTab(forceDirty = true)
    check session.tabs.len == 0
    check not session.hasDirtyTabs()

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

  test "selection clamps to grapheme boundaries after document shrink":
    var view = newEditorView()
    view.selection.anchor = 100
    view.selection.active = 4
    view.clampSelectionToText("A🙂")
    check view.selection.anchor == "A🙂".len
    check view.selection.active == 1

  test "session and recovery round trip":
    let path = getTempDir() / "nimculus-m5-session.txt"
    let recoveryPath = getTempDir() / "nimculus-m5-recovery.txt"
    writeFile(path, "session\none\ntwo\nthree")
    var session: EditorSession
    session.addTab(openDocument(path))
    session.tabs[0].view.moveCursor(3)
    session.tabs[0].view.scrollLine = 2
    session.splitEditor(splitHorizontal)
    session.workspaceRoots = @[getTempDir()]
    let sessionPath = getTempDir() / "nimculus-m5-session.json"
    session.saveSession(sessionPath)
    for candidate in walkFiles(sessionPath & ".tmp." & $getCurrentProcessId() & ".*"):
      check not fileExists(candidate)
    let restored = loadSession(sessionPath)
    check restored.tabs.len == 1
    check restored.workspaceRoots == @[getTempDir()]
    check restored.tabs[0].view.cursor == 3
    check restored.tabs[0].view.scrollLine == 2
    check restored.splitDirection == splitHorizontal
    restored.tabs[0].document.writeRecovery(recoveryPath)
    for candidate in walkFiles(recoveryPath & ".tmp." & $getCurrentProcessId() & ".*"):
      check not fileExists(candidate)
    let recovered = recoverDocument(recoveryPath)
    check recovered.buffer.toString() == "session\none\ntwo\nthree"
    check recovered.buffer.isDirty
    removeFile(path); removeFile(sessionPath); removeFile(recoveryPath)

  test "session restores dirty untitled tabs":
    var session: EditorSession
    var untitled = newDocument()
    untitled.buffer.edit(Edit(startByte: 0, endByte: 0, text: "draft🙂"))
    session.addTab(untitled)
    let sessionPath = getTempDir() / "nimculus-m5-untitled-session.json"
    session.saveSession(sessionPath)
    let restored = loadSession(sessionPath)
    check restored.tabs.len == 1
    check restored.tabs[0].document.path == ""
    check restored.tabs[0].document.buffer.toString() == "draft🙂"
    check restored.tabs[0].document.buffer.isDirty
    removeFile(sessionPath)

  test "session restores dirty named tab content after a crash":
    let path = getTempDir() / "nimculus-m5-dirty-session.txt"
    writeFile(path, "on disk")
    var session: EditorSession
    var document = openDocument(path)
    document.buffer.edit(Edit(startByte: 0, endByte: document.buffer.toString().len,
      text: "unsaved🙂"))
    session.addTab(document)
    let sessionPath = getTempDir() / "nimculus-m5-dirty-session.json"
    session.saveSession(sessionPath)
    let restored = loadSession(sessionPath)
    check restored.tabs.len == 1
    check restored.tabs[0].document.path == path
    check restored.tabs[0].document.buffer.toString() == "unsaved🙂"
    check restored.tabs[0].document.buffer.isDirty
    check readFile(path) == "on disk"
    removeFile(path)
    removeFile(sessionPath)

  test "session restores dirty named tab after the disk file is deleted":
    let path = getTempDir() / "nimculus-m5-deleted-dirty-session.txt"
    writeFile(path, "on disk")
    var session: EditorSession
    var document = openDocument(path)
    document.buffer.edit(Edit(startByte: 0, endByte: document.buffer.toString().len,
      text: "recover me"))
    session.addTab(document)
    let sessionPath = getTempDir() / "nimculus-m5-deleted-dirty-session.json"
    session.saveSession(sessionPath)
    removeFile(path)
    let restored = loadSession(sessionPath)
    check restored.tabs.len == 1
    check restored.tabs[0].document.path == path
    check restored.tabs[0].document.buffer.toString() == "recover me"
    check restored.tabs[0].document.buffer.isDirty
    var writable = restored.tabs[0].document
    writable.save()
    check readFile(path) == "recover me"
    removeFile(path)
    removeFile(sessionPath)

  test "session restores dirty named tab when its path becomes a directory":
    let path = getTempDir() / "nimculus-m5-directory-dirty-session.txt"
    writeFile(path, "on disk")
    var session: EditorSession
    var document = openDocument(path)
    document.buffer.edit(Edit(startByte: 0, endByte: document.buffer.toString().len,
      text: "recover me"))
    session.addTab(document)
    let sessionPath = getTempDir() / "nimculus-m5-directory-dirty-session.json"
    session.saveSession(sessionPath)
    removeFile(path)
    createDir(path)
    let restored = loadSession(sessionPath)
    check restored.tabs.len == 1
    check restored.tabs[0].document.path == path
    check restored.tabs[0].document.buffer.toString() == "recover me"
    check restored.tabs[0].document.buffer.isDirty
    removeDir(path)
    removeFile(sessionPath)

  test "discarded session omits dirty buffers":
    let namedPath = getTempDir() / "nimculus-m5-discarded.txt"
    writeFile(namedPath, "on disk")
    var session: EditorSession
    var named = openDocument(namedPath)
    named.buffer.edit(Edit(startByte: 0, endByte: named.buffer.toString().len, text: "discard me"))
    session.addTab(named)
    var untitled = newDocument()
    untitled.buffer.edit(Edit(startByte: 0, endByte: 0, text: "discard too"))
    session.addTab(untitled)
    let sessionPath = getTempDir() / "nimculus-m5-discarded.json"
    session.saveSession(sessionPath, preserveDirty = false)
    let restored = loadSession(sessionPath)
    check restored.tabs.len == 1
    check restored.tabs[0].document.path == namedPath
    check restored.tabs[0].document.buffer.toString() == "on disk"
    check not restored.tabs[0].document.buffer.isDirty
    removeFile(namedPath)
    removeFile(sessionPath)

  test "external reload preserves view state and clamps selection":
    let path = getTempDir() / "nimculus-m5-reload.txt"
    writeFile(path, "before🙂\nsecond")
    var session: EditorSession
    session.addTab(openDocument(path))
    var view = newEditorView()
    view.selection.anchor = "before🙂".len
    view.selection.active = "before🙂".len
    view.scrollLine = 4
    view.softWrap = true
    writeFile(path, "after")
    check session.reloadActiveDocument(view)
    check session.tabs[0].document.buffer.toString() == "after"
    check view.cursor == "after".len
    check view.scrollLine == 0
    check view.softWrap
    removeFile(path)

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

    let malformedPath = getTempDir() / "nimculus-m5-malformed-session.json"
    writeFile(malformedPath,
      "{\"activeTab\":\"bad\",\"split\":\"bad\",\"splitDirection\":7," &
      "\"tabs\":[{\"path\":7}]}")
    let malformed = loadSession(malformedPath)
    check malformed.activeTab == -1
    check not malformed.split
    check malformed.tabs.len == 0
    removeFile(malformedPath)
