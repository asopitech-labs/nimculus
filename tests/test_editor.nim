import std/unittest
import std/json
import std/os
when defined(posix):
  import std/files
import std/strutils
import std/options
import std/times
import nimculus/editor_buffer
import nimculus/editor_diagnostics
import nimculus/lsp
import nimculus/editor_app
import nimculus/search
import nimculus/editor_view
import nimculus/editor_scroll
import nimculus/editor_text_layout
import nimnui/geometry
import nimculus/session
import nimculus/atomic_io
import nimculus/persistence_scheduler
import nimculus/poll_scheduler
import nimnui/render

suite "session persistence scheduling":
  test "inline blame padding uses typographic em width":
    let typographicMWidth = 5'f32
    let mAdvance = 9'f32
    check inlineBlameStartX(40'f32, typographicMWidth, mAdvance, 7, 0) == 75'f32
    check inlineBlameStartX(40'f32, typographicMWidth, 18'f32, 7, 0) == 75'f32
    check inlineBlameStartX(40'f32, typographicMWidth, mAdvance, 0, 8) == 72'f32
    check inlineBlameStartX(40'f32, typographicMWidth, mAdvance, 7, 0, 16'f32) == 59'f32

  test "new editor views default to Zed no-wrap":
    check not newEditorView().softWrap

  test "ongoing scroll chooses vertical when absolute y is at least x":
    var ongoing = newOngoingScroll()
    var delta = Point(x: px(4'f32), y: px(-6'f32))
    check ongoing.filter(delta) == some(axisVertical)
    check delta == Point(x: px(0'f32), y: px(-6'f32))

  test "ongoing scroll chooses horizontal when absolute x exceeds y":
    var ongoing = newOngoingScroll()
    var delta = Point(x: px(-7'f32), y: px(4'f32))
    check ongoing.filter(delta) == some(axisHorizontal)
    check delta == Point(x: px(-7'f32), y: px(0'f32))

  test "ongoing scroll unlocks only at Zed's ratio and lower bound":
    var belowRatio = newOngoingScroll(initDuration(milliseconds = 0),
      some(axisVertical))
    var delta = Point(x: px(11'f32), y: px(6'f32))
    check belowRatio.filter(delta) == some(axisVertical)
    check delta == Point(x: px(0'f32), y: px(6'f32))

    var atThreshold = newOngoingScroll(initDuration(milliseconds = 0),
      some(axisVertical))
    delta = Point(x: px(11.4'f32), y: px(6'f32))
    check atThreshold.filter(delta).isNone
    check delta == Point(x: px(11.4'f32), y: px(6'f32))

    var belowLowerBound = newOngoingScroll(initDuration(milliseconds = 0),
      some(axisVertical))
    delta = Point(x: px(5.7'f32), y: px(3'f32))
    check belowLowerBound.filter(delta) == some(axisVertical)
    check delta == Point(x: px(0'f32), y: px(3'f32))

    var horizontal = newOngoingScroll(initDuration(milliseconds = 0),
      some(axisHorizontal))
    delta = Point(x: px(6'f32), y: px(12'f32))
    check horizontal.filter(delta).isNone
    check delta == Point(x: px(6'f32), y: px(12'f32))

  test "ongoing scroll starts a new axis after 28 milliseconds":
    var ongoing = newOngoingScroll(initDuration(milliseconds = 29),
      some(axisVertical))
    var delta = Point(x: px(8'f32), y: px(2'f32))
    check ongoing.filter(delta) == some(axisHorizontal)
    check delta == Point(x: px(8'f32), y: px(0'f32))

  test "wheel deltas bypass ongoing scroll and preserve legacy delta":
    var ongoing = newOngoingScroll(initDuration(milliseconds = 0),
      some(axisVertical))
    var delta = Point(x: px(8'f32), y: px(2'f32))
    check ongoing.applyScrollDelta(delta, precise = false).isNone
    check delta == Point(x: px(8'f32), y: px(2'f32))

  test "wheel pixel conversion remains unchanged":
    let lineHeight = editorLineHeight()
    check abs(scrollPixelDelta(-120'f32, false, lineHeight) -
      120'f32 * lineHeight) < 0.001'f32

  test "horizontal scrollbar geometry clamps and maps scroll positions":
    let bounds = Rect(origin: Point(x: px(20), y: px(40)),
      size: Size(width: px(400), height: px(240)))
    let viewportWidth = editorTextViewportWidth(bounds)
    check viewportWidth == 392'f32
    check clampEditorScrollX(-12'f32, 900'f32, viewportWidth) == 0'f32
    check clampEditorScrollX(999'f32, 900'f32, viewportWidth) == 508'f32
    let scrollbar = horizontalEditorScrollbar(bounds, 900'f32, 999'f32)
    check scrollbar.viewportWidth == viewportWidth
    let hiddenScrollbar = horizontalEditorScrollbar(bounds, viewportWidth - 1'f32, 0'f32)
    check hiddenScrollbar.viewportWidth == viewportWidth
    check hiddenScrollbar.track.size.width == px(0)
    check float32(scrollbar.track.origin.x) == 20'f32
    check float32(scrollbar.track.size.width) == viewportWidth
    check float32(scrollbar.thumb.origin.x + scrollbar.thumb.size.width) <=
      float32(scrollbar.track.origin.x + scrollbar.track.size.width)
    check scrollbar.horizontalScrollbarScrollX(
      float32(scrollbar.track.origin.x) + float32(scrollbar.track.size.width) / 2'f32) > 0'f32
    # Native measurement is zero while soft wrap is active; the geometry
    # layer intentionally has no separate soft-wrap gate.
    check horizontalEditorScrollbar(bounds, 0'f32, 0'f32).track.size.width == px(0)

  test "horizontal scrollbar paint remains in the editor bottom band":
    let bounds = Rect(origin: Point(x: px(20), y: px(40)),
      size: Size(width: px(400), height: px(240)))
    let scrollbar = horizontalEditorScrollbar(bounds, 900'f32, 0'f32)
    var paint: PaintList
    paint.invalidate(bounds)
    paint.drawScrollbar(scrollbar.thumb)
    check paint.commands.len == 1
    let command = paint.commands[0]
    check command.kind == PaintKind.scrollbar
    let commandBottom = float32(command.clip.origin.y + command.clip.size.height)
    let editorBottom = float32(bounds.origin.y + bounds.size.height)
    check float32(command.clip.origin.y) >= editorBottom - 14'f32
    check commandBottom <= editorBottom

  test "legacy sessions default to no-wrap while explicit wrap survives":
    let path = getTempDir() / ("nimculus-soft-wrap-default-session-" & $getCurrentProcessId() & ".json")
    defer: removeFile(path)
    writeFile(path, "{\"activeTab\":0,\"tabs\":[{" &
      "\"path\":\"\",\"content\":\"long line\",\"view\":{}}]}")
    check not loadSession(path).tabs[0].view.softWrap
    writeFile(path, "{\"activeTab\":0,\"tabs\":[{" &
      "\"path\":\"\",\"content\":\"long line\",\"view\":{\"softWrap\":true}}]}")
    check loadSession(path).tabs[0].view.softWrap

  test "edits debounce while bounding crash recovery delay":
    var schedule: PersistenceSchedule
    schedule.schedule(0.0)
    check schedule.pending
    check schedule.startedAt == 0.0
    check schedule.dueAt == 1.0

    schedule.schedule(0.8)
    check schedule.dueAt == 1.8
    check not schedule.isDue(1.79)
    check schedule.isDue(1.8)

    # Continuous input must still flush at most five seconds after the first
    # unsaved edit, rather than continually pushing recovery farther away.
    schedule.schedule(4.8)
    check schedule.dueAt == 5.0
    check not schedule.isDue(4.99)
    check schedule.isDue(5.0)

    schedule.clear()
    check not schedule.pending
    check not schedule.isDue(100.0)

suite "workspace polling schedule":
  test "idle maintenance is bounded while active search remains responsive":
    var schedule: PollSchedule
    check schedule.shouldPoll(0.0, active = false)
    check not schedule.shouldPoll(0.49, active = false)
    check schedule.shouldPoll(0.5, active = false)
    check schedule.shouldPoll(0.51, active = true)
    check schedule.shouldPoll(0.52, active = true)
    check not schedule.shouldPoll(0.75, active = false)
    check schedule.shouldPoll(1.0, active = false)
    schedule.reset()
    check schedule.shouldPoll(0.1, active = false)

suite "M4 editor buffer":
  test "piece table edits and undo redo preserve content":
    var buffer = initPieceTable("hello\n世界")
    check buffer.contentLength == "hello\n世界".len
    buffer.edit(Edit(startByte: 6, endByte: 12, text: "Nimculus"))
    check buffer.contentLength == "hello\nNimculus".len
    check buffer.toString() == "hello\nNimculus"
    check buffer.isDirty
    check buffer.undo()
    check buffer.toString() == "hello\n世界"
    check buffer.redo()
    check buffer.toString() == "hello\nNimculus"

  test "singleton multibuffer preserves piece table offsets and line columns":
    var fixture = newStringOfCap(1_100_000)
    for line in 0 ..< 10_000:
      fixture.add(repeat("x", 99))
      fixture.add('\n')
    let buffer = initPieceTable(fixture)
    let multiBuffer = initMultiBuffer(buffer)
    let snapshot = multiBuffer.snapshot()
    var samples = 0
    var offset = 0
    var mismatches = 0
    while offset <= buffer.contentLength:
      let location = snapshot.toBufferOffset(offset)
      if snapshot.toMultiBufferOffset(location) != offset:
        inc mismatches
      if multiBuffer.lineColumn(offset) != buffer.lineColumn(offset):
        inc mismatches
      inc samples
      offset += 997
    check samples >= 1000
    check mismatches == 0

  test "three excerpts from two buffers form one exact offset space":
    var multiBuffer = initMultiBuffer()
    multiBuffer.addBuffer(1, initPieceTable("abcdefghij"))
    multiBuffer.addBuffer(2, initPieceTable("0123456789"))
    multiBuffer.addExcerpt(Excerpt(bufferId: 1, context: 1 .. 3, primary: 2 .. 2))
    multiBuffer.addExcerpt(Excerpt(bufferId: 2, context: 4 .. 7, primary: 5 .. 6))
    multiBuffer.addExcerpt(Excerpt(bufferId: 1, context: 6 .. 8, primary: 7 .. 7))
    let snapshot = multiBuffer.snapshot()
    check snapshot.contentLength == (snapshot.excerpts[0].context.b -
      snapshot.excerpts[0].context.a + 1) +
      (snapshot.excerpts[1].context.b - snapshot.excerpts[1].context.a + 1) +
      (snapshot.excerpts[2].context.b - snapshot.excerpts[2].context.a + 1)
    for index in 1 ..< snapshot.excerpts.len:
      let boundary = snapshot.prefix[index]
      let previous = snapshot.excerpts[index - 1]
      let current = snapshot.excerpts[index]
      check snapshot.toBufferOffset(boundary - 1) ==
        (bufferId: previous.bufferId, offset: previous.context.b)
      check snapshot.toBufferOffset(boundary) ==
        (bufferId: current.bufferId, offset: current.context.a)
      check snapshot.toBufferOffset(boundary + 1) ==
        (bufferId: current.bufferId, offset: current.context.a + 1)

  test "multibuffer snapshot counters track edits and trailing excerpts":
    var multiBuffer = initMultiBuffer()
    multiBuffer.addBuffer(1, initPieceTable("before excerpt after"))
    multiBuffer.addExcerpt(Excerpt(bufferId: 1, context: 7 .. 13,
      primary: 8 .. 11))
    let beforeEdit = multiBuffer.snapshot()
    multiBuffer.edit(1, Edit(startByte: 9, endByte: 10, text: "XX"))
    let afterEdit = multiBuffer.snapshot()
    check afterEdit.editCount == beforeEdit.editCount + 1
    check afterEdit.nonTextStateUpdateCount == beforeEdit.nonTextStateUpdateCount
    let beforeAppend = afterEdit.trailingExcerptUpdateCount
    multiBuffer.addExcerpt(Excerpt(bufferId: 1, context: 15 .. 19,
      primary: 16 .. 18))
    check multiBuffer.snapshot().trailingExcerptUpdateCount == beforeAppend + 1

  test "primary remains a strict search subrange after an earlier edit":
    var multiBuffer = initMultiBuffer()
    multiBuffer.addBuffer(7, initPieceTable("prefix search hit suffix"))
    multiBuffer.addExcerpt(Excerpt(bufferId: 7, context: 0 .. 22,
      primary: 7 .. 15))
    let before = multiBuffer.snapshot()
    let primaryBefore = before.excerpts[0].primary
    check primaryBefore.a > before.excerpts[0].context.a
    check primaryBefore.b < before.excerpts[0].context.b
    multiBuffer.edit(7, Edit(startByte: 0, endByte: 0, text: "++"))
    let after = multiBuffer.snapshot()
    let primaryAfter = after.excerpts[0].primary
    check primaryAfter.a == primaryBefore.a + 2
    check primaryAfter.b == primaryBefore.b + 2
    check primaryAfter.a > after.excerpts[0].context.a
    check primaryAfter.b < after.excerpts[0].context.b
    for location in [
      (bufferId: 7, offset: primaryAfter.a),
      (bufferId: 7, offset: primaryAfter.b + 1)]:
      let aggregateOffset = after.toMultiBufferOffset(location)
      check after.toBufferOffset(aggregateOffset) == location

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
    let root = getTempDir() / ("nimculus-日本語-startup-paths-" & $getCurrentProcessId())
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
    let path = getTempDir() / ("nimculus-日本語-existing-tab🙂-" & $getCurrentProcessId() & ".txt")
    writeFile(path, "日本語")
    defer:
      if fileExists(path): removeFile(path)
    var session: EditorSession
    session.addTab(openDocument(path))
    check session.tabIndexForPath(canonicalOpenPath(path)) == 0
    check session.tabIndexForPath(canonicalOpenPath(path & ".missing")) == -1
    var untitledSession: EditorSession
    untitledSession.addTab(newDocument())
    check untitledSession.tabIndexForPath("") == -1

  test "Save As canonicalizes identity and detects an open destination":
    let source = getTempDir() / ("nimculus-save-as-日本語-source🙂-" & $getCurrentProcessId() & ".txt")
    let destination = getTempDir() / ("nimculus-save-as-日本語-destination🙂-" & $getCurrentProcessId() & ".txt")
    writeFile(source, "source")
    writeFile(destination, "destination")
    defer:
      if fileExists(source): removeFile(source)
      if fileExists(destination): removeFile(destination)
    var session: EditorSession
    session.addTab(openDocument(source))
    session.addTab(openDocument(destination))
    check session.tabIndexForSaveTarget(destination) == 1
    check session.tabIndexForSaveTarget(source) == 0
    var document = newDocument()
    document.buffer.edit(Edit(startByte: 0, endByte: 0, text: "saved🙂"))
    document.save(destination)
    check document.path == canonicalOpenPath(destination)
    check readFile(destination) == "saved🙂"

  when defined(macosx):
    test "atomic save preserves a document symlink":
      let target = getTempDir() / ("nimculus-save-symlink-target-" & $getCurrentProcessId() & ".txt")
      let link = getTempDir() / ("nimculus-save-symlink-link-" & $getCurrentProcessId() & ".txt")
      writeFile(target, "before")
      if symlinkExists(link): removeFile(link)
      createSymlink(target, link)
      defer:
        if symlinkExists(link): removeFile(link)
        if fileExists(target): removeFile(target)
      var document = openDocument(link)
      var session: EditorSession
      session.addTab(document)
      check session.tabIndexForPath(link) == 0
      check session.tabIndexForPath(target) == 0
      document.buffer.edit(Edit(startByte: 0, endByte: 6, text: "after"))
      document.save()
      check symlinkExists(link)
      check readFile(target) == "after"

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
  test "search options change case, whole-word, and regex matches":
    let text = "Needle needle scatter cat cat2 needle42"
    check findMatches(text, "needle", SearchOptions(caseSensitive: true)).len == 2
    check findMatches(text, "needle", SearchOptions(caseSensitive: false)).len == 3
    check findMatches(text, "cat", SearchOptions(caseSensitive: true,
      wholeWord: true)).len == 1
    check findMatches(text, "needle\\d+", SearchOptions(caseSensitive: true,
      regex: true)).len == 1

  test "open save search replace and external change":
    let path = getTempDir() / ("nimculus-m5-日本語🙂-" & $getCurrentProcessId() & ".txt")
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
    let path = getTempDir() / ("nimculus-m5-save-source-" & $getCurrentProcessId() & ".txt")
    writeFile(path, "source")
    var document = openDocument(path)
    let invalidPath = getTempDir() / ("nimculus-m5-missing-dir-" & $getCurrentProcessId()) / "target.txt"
    expect IOError:
      document.save(invalidPath)
    check document.path == canonicalOpenPath(path)
    removeFile(path)
    check document.externallyChanged

  test "external deletion is detected for an empty file":
    let path = getTempDir() / ("nimculus-m5-empty-external-" & $getCurrentProcessId() & ".txt")
    writeFile(path, "")
    let document = openDocument(path)
    check not document.externallyChanged
    removeFile(path)
    check document.externallyChanged

  test "atomic replacement is detected even when the file size is unchanged":
    let path = getTempDir() / ("nimculus-m5-identity-" & $getCurrentProcessId() & ".txt")
    writeFile(path, "first")
    var document = openDocument(path)
    check document.externalIdentity.len > 0
    atomicWriteFile(path, "second")
    check document.externallyChanged
    document.acceptExternalState()
    check not document.externallyChanged
    removeFile(path)

  test "keeping edits after external deletion records deleted disk state":
    let path = getTempDir() / ("nimculus-m5-keep-deleted-" & $getCurrentProcessId() & ".txt")
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
    session.splitEditor(splitVertical, 0.72)
    check session.tabs.len == 3
    check session.split
    check abs(session.effectiveSplitRatio - 0.72'f32) < 0.001'f32
    session.secondaryView.moveCursor(1)
    session.secondaryView.scrollLine = 4
    check session.activateSplitPane(1)
    check session.splitActivePane == 1
    session.moveActivePaneCursor(view, 4)
    check session.secondaryView.cursor == 4
    check view.cursor == 5
    var secondary = session.secondaryView
    check session.switchTab(view, secondary, -1)
    check session.activeTab == 1
    check secondary.cursor == 0
    secondary.moveCursor(2)
    secondary.scrollLine = 6
    check session.switchTab(view, secondary, 1)
    check session.activeTab == 2
    check secondary.cursor == 4
    check secondary.scrollLine == 4
    session.closeSplit()
    check not session.split
    session.setSplitRatio(4.0)
    check abs(session.effectiveSplitRatio - 0.9'f32) < 0.001'f32
    check session.closeActiveTab()
    check session.tabs.len == 2

  test "duplicate unsaved tab labels remain individually identifiable":
    var session: EditorSession
    session.addTab(newDocument())
    session.addTab(newDocument())
    session.addTab(newDocument())
    check session.displayTitle(0) == "Untitled 1"
    check session.displayTitle(1) == "Untitled 2"
    check session.displayTitle(2) == "Untitled 3"

  test "duplicate file tab labels use directory context":
    check pathForFile("/w/src/main.rs", 1, true) == "src/main.rs"
    check pathForFile("/w/tests/main.rs", 1, true) == "tests/main.rs"
    check pathForFile("/w/a/b/x.nim", 2, true) == "a/b/x.nim"
    check pathForFile("/w/c/b/x.nim", 2, true) == "c/b/x.nim"
    check pathForFile("/w/a/b/x.nim", 3, true) == "/w/a/b/x.nim"

    var session: EditorSession
    var source = newDocument()
    source.path = "/w/src/main.rs"
    var tests = newDocument()
    tests.path = "/w/tests/main.rs"
    session.addTab(source)
    session.addTab(tests)
    check session.displayTitle(0) == "src/main.rs"
    check session.displayTitle(1) == "tests/main.rs"

    var nested: EditorSession
    var left = newDocument()
    left.path = "/w/a/b/x.nim"
    var right = newDocument()
    right.path = "/w/c/b/x.nim"
    nested.addTab(left)
    nested.addTab(right)
    check nested.displayTitle(0) == "a/b/x.nim"
    check nested.displayTitle(1) == "c/b/x.nim"

  test "named tab labels retain their file extension":
    let root = getTempDir() / ("nimculus-editor-named-label-" & $getCurrentProcessId())
    createDir(root)
    let path = root / "DEVELOPMENT_GUIDELINES.md"
    writeFile(path, "# Breadcrumb\n")
    defer:
      if fileExists(path): removeFile(path)
      if dirExists(root): removeDir(root)
    var session: EditorSession
    session.addTab(openDocument(path))
    check session.displayTitle(0) == "DEVELOPMENT_GUIDELINES.md"
    check session.tabDisplayLabel(0) == "DEVELOPMENT_GUIDELINES.md"

  test "pinning tabs preserves pane document identity and session order":
    var session: EditorSession
    var first = newDocument()
    first.buffer.edit(Edit(startByte: 0, endByte: 0, text: "first"))
    var second = newDocument()
    second.buffer.edit(Edit(startByte: 0, endByte: 0, text: "second"))
    var third = newDocument()
    third.buffer.edit(Edit(startByte: 0, endByte: 0, text: "third"))
    session.addTab(first)
    session.addTab(second)
    session.addTab(third)
    session.activeTab = 2
    session.split = true
    session.splitSecondaryTab = 1
    check session.setTabPinned(2, true)
    check session.tabs[0].document.buffer.toString() == "third"
    check session.activeTab == 0
    check session.splitSecondaryTab == 2
    check session.tabDisplayLabel(0).startsWith("📌 ")
    check session.setTabPinned(2, true)
    check session.tabs[0].document.buffer.toString() == "third"
    check session.tabs[1].document.buffer.toString() == "second"
    check session.activeTab == 0
    check session.splitSecondaryTab == 1
    check session.unpinAllTabs()
    check session.pinnedTabCount() == 0
    check not session.tabDisplayLabel(0).startsWith("📌 ")

  test "moving a tab remaps both pane tab identities":
    var session: EditorSession
    for text in ["first", "second", "third"]:
      var document = newDocument()
      document.buffer.edit(Edit(startByte: 0, endByte: 0, text: text))
      session.addTab(document)
    session.activeTab = 2
    session.split = true
    session.splitSecondaryTab = 1
    check session.moveTab(0, 2)
    check session.tabs[0].document.buffer.toString() == "second"
    check session.tabs[1].document.buffer.toString() == "third"
    check session.tabs[2].document.buffer.toString() == "first"
    check session.activeTab == 1
    check session.splitSecondaryTab == 0

  test "pinned tab state survives session restore":
    let path = getTempDir() / ("nimculus-pinned-tab-session-" & $getCurrentProcessId() & ".json")
    defer:
      if fileExists(path): removeFile(path)
    var session: EditorSession
    session.addTab(newDocument())
    session.addTab(newDocument())
    session.tabs[0].title = "first"
    session.tabs[1].title = "second"
    check session.setTabPinned(1, true)
    session.saveSession(path)
    let restored = loadSession(path)
    check restored.tabs.len == 2
    check restored.tabs[0].title == "second"
    check restored.tabs[0].pinned
    check restored.tabs[1].title == "first"
    check not restored.tabs[1].pinned

  test "closing a non-active tab retains the active document":
    var session: EditorSession
    session.addTab(newDocument())
    session.addTab(newDocument())
    session.addTab(newDocument())
    session.activeTab = 2
    check session.closeTabAt(0)
    check session.tabs.len == 2
    check session.activeTab == 1

  test "reopen closed tab reloads the newest clean path without reviving discarded text":
    let root = getTempDir() / ("nimculus-reopen-closed-tab-" & $getCurrentProcessId())
    if dirExists(root): removeDir(root)
    createDir(root)
    defer:
      if dirExists(root): removeDir(root)
    let firstPath = root / "first.nim"
    let secondPath = root / "second.nim"
    writeFile(firstPath, "first disk\n")
    writeFile(secondPath, "second disk\n")
    var session: EditorSession
    session.addTab(openDocument(firstPath))
    session.addTab(openDocument(secondPath))
    check session.setTabPinned(1, true)
    check session.closeTabAt(0)
    check session.tabs.len == 1
    writeFile(secondPath, "second changed on disk\n")
    let reopened = session.reopenClosedTab()
    check reopened == 0
    check session.tabs[0].pinned
    check session.tabs[0].document.buffer.toString() == "second changed on disk\n"
    var dirty = newDocument()
    dirty.buffer.edit(Edit(startByte: 0, endByte: 0, text: "discarded"))
    session.addTab(dirty)
    check session.closeActiveTab(forceDirty = true)
    check session.reopenClosedTab() == -1

  test "closing a dirty non-active tab requires an explicit decision":
    var session: EditorSession
    var document = newDocument()
    document.buffer.edit(Edit(startByte: 0, endByte: 0, text: "unsaved"))
    session.addTab(document)
    session.addTab(newDocument())
    check not session.closeTabAt(0)
    check session.tabs.len == 2
    check session.closeTabAt(0, forceDirty = true)
    check session.tabs.len == 1

  test "background tab preserves primary session activation":
    var session: EditorSession
    session.addTab(newDocument())
    session.addTab(newDocument())
    check session.activeTab == 1
    let background = session.addBackgroundTab(newDocument())
    check background == 2
    check session.tabs.len == 3
    check session.activeTab == 1

  test "each split pane keeps its own cursor visible":
    let buffer = initPieceTable("zero\none\ntwo\nthree\nfour")
    var primary = newEditorView()
    primary.moveCursor(buffer.lineStarts[4])
    primary.ensureCursorVisible(buffer, 2)
    check primary.scrollLine == 3
    var secondary = newEditorView()
    secondary.moveCursor(buffer.lineStarts[1])
    secondary.scrollLine = 3
    secondary.ensureCursorVisible(buffer, 2)
    check secondary.scrollLine == 1
    check primary.scrollLine == 3

  test "wheel scrolling can move past the cursor without re-clamping the viewport":
    var lines: seq[string]
    for line in 0 .. 39:
      lines.add("line " & $line)
    let buffer = initPieceTable(lines.join("\n"))
    var view = newEditorView()
    let lineHeight = editorLineHeight()
    view.moveCursor(buffer.lineStarts[13])
    view.scrollLine = 0
    view.reconcileScrollPosition()
    let cursorLine = buffer.lineColumn(view.cursor).line
    for _ in 0 .. 20:
      view.reconcileScrollPosition(lineHeight, 35'f32 * lineHeight)
      let pixelDelta = scrollPixelDelta(-lineHeight, true)
      view.setScrollYPixels(view.scrollYPixels + pixelDelta, lineHeight, 35'f32 * lineHeight)
    view.reconcileScrollPosition(lineHeight, 35'f32 * lineHeight)
    check view.scrollLine > cursorLine
    check view.scrollYPixels > float32(cursorLine) * lineHeight

  test "forty native wheel events use the unnormalized Zed delta":
    var lines: seq[string]
    for line in 0 .. 399:
      lines.add("line " & $line)
    var view = newEditorView()
    let lineHeight = editorLineHeight()
    let maxScrollPixels = float32(399) * lineHeight
    for _ in 0 ..< 40:
      # A precise event is already a pixel delta in Zed; no wheel threshold or
      # fixed divisor is applied here.
      let pixelDelta = scrollPixelDelta(-120'f32, true, lineHeight)
      view.setScrollYPixels(view.scrollYPixels + pixelDelta, lineHeight,
        maxScrollPixels)
    check abs(view.scrollYPixels - 4800'f32) < 0.001'f32
    check view.scrollLine == 200

  test "focused split pane owns navigation destinations":
    var session: EditorSession
    var primary = newEditorView()
    session.addTab(newDocument())
    session.splitEditor(splitVertical)
    primary.moveCursor(2)
    session.secondaryView.moveCursor(1)
    check session.activateSplitPane(1)
    # Workspace search and LSP definition use this editor-layer boundary.
    # Navigation must not move the primary cursor when the secondary is focused.
    session.moveActivePaneCursor(primary, 7)
    check primary.cursor == 2
    check session.secondaryView.cursor == 7

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
    check view.statusBarText(buffer).contains("2:3")
    view.statusMessage = "Soft wrap disabled"
    check view.statusBarText(buffer).contains("Soft wrap disabled  •  2:3")
    view.openCommandPalette()
    check view.commandPaletteOpen

  test "cursor status uses Zed line:character format for multiple selections":
    let buffer = initPieceTable("one\ntwo")
    var view = newEditorView()
    discard view.addCaret(4, buffer.toString())
    check view.cursorPositionText(buffer) == "1:1 (2 selections)"

  test "selection clamps to grapheme boundaries after document shrink":
    var view = newEditorView()
    view.selection.anchor = 100
    view.selection.active = 4
    view.clampSelectionToText("A🙂")
    check view.selection.anchor == "A🙂".len
    check view.selection.active == 1

  test "Zed-style multiple selections normalize and add carets":
    var view = newEditorView()
    let text = "one one one"
    view.moveCursor(0)
    check view.addCaret(4, text)
    check not view.addCaret(4, text)
    view.additionalSelections.add(Selection(anchor: 8, active: 11))
    check view.selectionRanges == @[
      (startByte: 0, endByte: 0),
      (startByte: 4, endByte: 4),
      (startByte: 8, endByte: 11)]
    view.clampSelectionToText("one one")
    check view.additionalSelections.len == 2
    check view.additionalSelections[1] == Selection(anchor: 7, active: 7)

  test "multiple selections apply one atomic edit transaction":
    var buffer = initPieceTable("a b c")
    var view = newEditorView()
    view.selection = Selection(anchor: 0, active: 1)
    view.additionalSelections = @[
      Selection(anchor: 2, active: 3), Selection(anchor: 4, active: 5)]
    let ranges = view.selectionRanges
    var edits: seq[Edit]
    for range in ranges:
      edits.add(Edit(startByte: range.startByte, endByte: range.endByte, text: "x"))
    buffer.applyEdits(edits)
    check buffer.toString() == "x x x"
    check buffer.undo()
    check buffer.toString() == "a b c"

  test "session and recovery round trip":
    let path = getTempDir() / ("nimculus-m5-session-" & $getCurrentProcessId() & ".txt")
    let recoveryPath = getTempDir() / ("nimculus-m5-recovery-" & $getCurrentProcessId() & ".txt")
    writeFile(path, "session\none\ntwo\nthree")
    var session: EditorSession
    session.addTab(openDocument(path))
    session.tabs[0].view.moveCursor(3)
    session.tabs[0].view.additionalSelections = @[Selection(anchor: 8, active: 8)]
    session.tabs[0].view.scrollLine = 2
    session.tabs[0].view.scrollX = 184.5'f32
    session.splitEditor(splitHorizontal, 0.31)
    session.secondaryView.moveCursor(2)
    session.secondaryView.scrollLine = 1
    session.secondaryView.scrollX = 96.25'f32
    discard session.activateSplitPane(1)
    session.workspaceRoots = @[getTempDir()]
    session.workspaceLeftDockOpen = false
    session.workspaceLeftDockSize = 312'f32
    session.workspaceLeftPanel = 2
    session.workspaceBottomDockOpen = true
    session.workspaceBottomDockSize = 284'f32
    session.workspaceBottomPanel = 4
    session.workspaceRightDockOpen = true
    session.workspaceRightDockSize = 296'f32
    session.workspaceRightPanel = 0
    let sessionPath = getTempDir() / ("nimculus-m5-session-" & $getCurrentProcessId() & ".json")
    session.saveSession(sessionPath)
    for candidate in walkFiles(sessionPath & ".tmp." & $getCurrentProcessId() & ".*"):
      check not fileExists(candidate)
    let restored = loadSession(sessionPath)
    check restored.tabs.len == 1
    check restored.workspaceRoots == @[canonicalOpenPath(getTempDir())]
    check restored.tabs[0].view.cursor == 3
    check restored.tabs[0].view.additionalSelections == @[Selection(anchor: 8, active: 8)]
    check restored.tabs[0].view.scrollLine == 2
    check abs(restored.tabs[0].view.scrollX - 184.5'f32) < 0.001'f32
    check restored.splitDirection == splitHorizontal
    check abs(restored.effectiveSplitRatio - 0.31'f32) < 0.001'f32
    check restored.splitActivePane == 1
    check restored.secondaryView.cursor == 2
    check restored.secondaryView.scrollLine == 1
    check abs(restored.secondaryView.scrollX - 96.25'f32) < 0.001'f32
    check restored.tabs[0].secondaryView.cursor == 2
    check restored.tabs[0].secondaryView.scrollLine == 1
    check abs(restored.tabs[0].secondaryView.scrollX - 96.25'f32) < 0.001'f32
    check not restored.workspaceLeftDockOpen
    check restored.workspaceLeftDockSize == 312'f32
    check restored.workspaceLeftPanel == 2
    check restored.workspaceBottomDockOpen
    check restored.workspaceBottomDockSize == 284'f32
    check restored.workspaceBottomPanel == 4
    check restored.workspaceRightDockOpen
    check restored.workspaceRightDockSize == 296'f32
    check restored.workspaceRightPanel == 0
    restored.tabs[0].document.writeRecovery(recoveryPath)
    for candidate in walkFiles(recoveryPath & ".tmp." & $getCurrentProcessId() & ".*"):
      check not fileExists(candidate)
    let recovered = recoverDocument(recoveryPath)
    check recovered.buffer.toString() == "session\none\ntwo\nthree"
    check recovered.buffer.isDirty
    removeFile(path); removeFile(sessionPath); removeFile(recoveryPath)

  test "session defaults all docks closed when dock state is absent":
    let sessionPath = getTempDir() / ("nimculus-m5-dock-defaults-session-" & $getCurrentProcessId() & ".json")
    writeFile(sessionPath, "{\"activeTab\":-1,\"tabs\":[]}")
    let restored = loadSession(sessionPath)
    check not restored.workspaceLeftDockOpen
    check not restored.workspaceBottomDockOpen
    check not restored.workspaceRightDockOpen
    removeFile(sessionPath)

  test "session restores explicitly saved open state for all docks":
    let sessionPath = getTempDir() / ("nimculus-m5-dock-open-session-" & $getCurrentProcessId() & ".json")
    writeFile(sessionPath, """{
      "activeTab": -1,
      "workspaceLeftDockOpen": true,
      "workspaceBottomDockOpen": true,
      "workspaceRightDockOpen": true,
      "tabs": []
    }""")
    let restored = loadSession(sessionPath)
    check restored.workspaceLeftDockOpen
    check restored.workspaceBottomDockOpen
    check restored.workspaceRightDockOpen
    removeFile(sessionPath)

  test "session restores a secondary pane document independently of primary":
    let sessionPath = getTempDir() / ("nimculus-m5-split-secondary-session-" & $getCurrentProcessId() & ".json")
    if fileExists(sessionPath): removeFile(sessionPath)
    var session: EditorSession
    var first = newDocument()
    first.buffer = initPieceTable("primary\n")
    var second = newDocument()
    second.buffer = initPieceTable("secondary\nline\n")
    session.addTab(first)
    session.addTab(second)
    session.activeTab = 0
    session.splitEditor(splitVertical, 0.42)
    session.splitSecondaryTab = 1
    session.tabs[1].secondaryView.moveCursor("secondary\n".len)
    session.tabs[1].secondaryView.scrollLine = 1
    session.secondaryView = session.tabs[1].secondaryView
    discard session.activateSplitPane(1)
    session.saveSession(sessionPath)
    let restored = loadSession(sessionPath)
    check restored.split
    check restored.activeTab == 0
    check restored.effectiveSplitSecondaryTab() == 1
    check restored.secondaryView.cursor == "secondary\n".len
    check restored.secondaryView.scrollLine == 1
    check restored.tabs[1].secondaryView.cursor == "secondary\n".len
    removeFile(sessionPath)

  test "session restores dirty untitled tabs":
    var session: EditorSession
    var untitled = newDocument()
    untitled.buffer.edit(Edit(startByte: 0, endByte: 0, text: "draft🙂"))
    session.addTab(untitled)
    let sessionPath = getTempDir() / ("nimculus-m5-untitled-session-" & $getCurrentProcessId() & ".json")
    session.saveSession(sessionPath)
    let restored = loadSession(sessionPath)
    check restored.tabs.len == 1
    check restored.tabs[0].document.path == ""
    check restored.tabs[0].document.buffer.toString() == "draft🙂"
    check restored.tabs[0].document.buffer.isDirty
    removeFile(sessionPath)

  test "session restores dirty named tab content after a crash":
    let path = getTempDir() / ("nimculus-m5-dirty-session-" & $getCurrentProcessId() & ".txt")
    writeFile(path, "on disk")
    var session: EditorSession
    var document = openDocument(path)
    document.buffer.edit(Edit(startByte: 0, endByte: document.buffer.toString().len,
      text: "unsaved🙂"))
    session.addTab(document)
    let sessionPath = getTempDir() / ("nimculus-m5-dirty-session-" & $getCurrentProcessId() & ".json")
    session.saveSession(sessionPath)
    let restored = loadSession(sessionPath)
    check restored.tabs.len == 1
    check restored.tabs[0].document.path == canonicalOpenPath(path)
    check restored.tabs[0].document.buffer.toString() == "unsaved🙂"
    check restored.tabs[0].document.buffer.isDirty

  test "session restore coalesces duplicate named tabs without losing dirty active content":
    let path = getTempDir() / ("nimculus-session-duplicate-日本語🙂-" & $getCurrentProcessId() & ".txt")
    let sessionPath = getTempDir() / ("nimculus-session-duplicate-" & $getCurrentProcessId() & ".json")
    defer:
      if fileExists(path): removeFile(path)
      if fileExists(sessionPath): removeFile(sessionPath)
    writeFile(path, "on disk")
    writeFile(sessionPath, $(%*{
      "activeTab": 1,
      "split": false,
      "splitDirection": "splitVertical",
      "recentFiles": newJArray(),
      "workspaceRoots": newJArray(),
      "tabs": [
        {"path": path, "title": "clean", "dirty": false,
         "view": {"anchor": 0, "active": 0, "scrollLine": 0}},
        {"path": canonicalOpenPath(path), "title": "dirty", "dirty": true,
         "content": "unsaved 日本語🙂",
         "lineEnding": "lf",
         "view": {"anchor": 9, "active": 9, "scrollLine": 0}},
        {"path": path, "title": "stale clean", "dirty": false,
         "view": {"anchor": 0, "active": 0, "scrollLine": 0}}
      ]
    }))
    let restored = loadSession(sessionPath)
    check restored.tabs.len == 1
    check restored.activeTab == 0
    check restored.tabs[0].document.path == canonicalOpenPath(path)
    check restored.tabs[0].document.buffer.toString() == "unsaved 日本語🙂"
    check restored.tabs[0].document.buffer.isDirty
    check restored.tabs[0].title == "dirty"
    check restored.tabs[0].view.selection.active == 8
    restored.saveSession(sessionPath)
    let serialized = parseJson(readFile(sessionPath))
    check serialized["tabs"].len == 1
    check readFile(path) == "on disk"
    removeFile(path)
    removeFile(sessionPath)

  test "session save coalesces duplicate named tabs before writing":
    let path = getTempDir() / ("nimculus-save-duplicate-日本語🙂-" & $getCurrentProcessId() & ".txt")
    let sessionPath = getTempDir() / ("nimculus-save-duplicate-" & $getCurrentProcessId() & ".json")
    defer:
      if fileExists(path): removeFile(path)
      if fileExists(sessionPath): removeFile(sessionPath)
    writeFile(path, "on disk")
    var session: EditorSession
    session.addTab(openDocument(path))
    var dirty = openDocument(path)
    dirty.buffer.edit(Edit(startByte: 0, endByte: 0, text: "dirty "))
    session.addTab(dirty)
    session.activeTab = 0
    session.saveSession(sessionPath)
    let serialized = parseJson(readFile(sessionPath))
    check serialized["tabs"].len == 1
    check serialized["activeTab"].getInt == 0
    let restored = loadSession(sessionPath)
    check restored.tabs.len == 1
    check restored.activeTab == 0
    check restored.tabs[0].document.buffer.toString() == "dirty on disk"
    check restored.tabs[0].document.buffer.isDirty

  test "session canonicalizes duplicate recent files and workspace roots":
    let root = getTempDir() / ("nimculus-session-workspace-日本語🙂-" & $getCurrentProcessId())
    let alias = getTempDir() / ("nimculus-session-workspace-alias-" & $getCurrentProcessId())
    let recent = root / "recent.txt"
    let sessionPath = getTempDir() / ("nimculus-session-workspace-" & $getCurrentProcessId() & ".json")
    defer:
      if symlinkExists(alias): removeFile(alias)
      if dirExists(root): removeDir(root)
      if fileExists(sessionPath): removeFile(sessionPath)
    if symlinkExists(alias): removeFile(alias)
    if dirExists(root): removeDir(root)
    createDir(root)
    writeFile(recent, "recent")
    createSymlink(root, alias)
    var session: EditorSession
    session.recentFiles = @[recent, alias / "recent.txt", recent]
    session.workspaceRoots = @[root, alias, root]
    session.saveSession(sessionPath)
    let restored = loadSession(sessionPath)
    check restored.recentFiles == @[canonicalOpenPath(recent)]
    check restored.workspaceRoots == @[canonicalOpenPath(root)]

  test "session restores dirty named tab after the disk file is deleted":
    let path = getTempDir() / ("nimculus-m5-deleted-dirty-session-" & $getCurrentProcessId() & ".txt")
    writeFile(path, "on disk")
    var session: EditorSession
    var document = openDocument(path)
    document.buffer.edit(Edit(startByte: 0, endByte: document.buffer.toString().len,
      text: "recover me"))
    session.addTab(document)
    let sessionPath = getTempDir() / ("nimculus-m5-deleted-dirty-session-" & $getCurrentProcessId() & ".json")
    session.saveSession(sessionPath)
    removeFile(path)
    let restored = loadSession(sessionPath)
    check restored.tabs.len == 1
    check restored.tabs[0].document.path == canonicalOpenPath(path)
    check restored.tabs[0].document.buffer.toString() == "recover me"
    check restored.tabs[0].document.buffer.isDirty
    var writable = restored.tabs[0].document
    writable.save()
    check readFile(path) == "recover me"
    removeFile(path)
    removeFile(sessionPath)

  test "legacy deleted session paths are canonicalized before recovery":
    let sessionPath = getTempDir() / ("nimculus-m5-legacy-deleted-session-" & $getCurrentProcessId() & ".json")
    let legacyPath = "/tmp/nimculus-legacy-日本語-deleted.txt"
    writeFile(sessionPath, "{\"activeTab\":0,\"tabs\":[{\"path\":\"" & legacyPath &
      "\",\"dirty\":true,\"content\":\"recover🙂\",\"lineEnding\":\"lf\"}]}")
    defer: removeFile(sessionPath)
    let restored = loadSession(sessionPath)
    check restored.tabs.len == 1
    check restored.tabs[0].document.path == canonicalOpenPath(legacyPath)
    check restored.tabs[0].document.buffer.toString() == "recover🙂"
    check restored.tabs[0].document.buffer.isDirty

  test "session restores dirty named tab when its path becomes a directory":
    let path = getTempDir() / ("nimculus-m5-directory-dirty-session-" & $getCurrentProcessId() & ".txt")
    writeFile(path, "on disk")
    var session: EditorSession
    var document = openDocument(path)
    document.buffer.edit(Edit(startByte: 0, endByte: document.buffer.toString().len,
      text: "recover me"))
    session.addTab(document)
    let sessionPath = getTempDir() / ("nimculus-m5-directory-dirty-session-" & $getCurrentProcessId() & ".json")
    session.saveSession(sessionPath)
    removeFile(path)
    createDir(path)
    let restored = loadSession(sessionPath)
    check restored.tabs.len == 1
    check restored.tabs[0].document.path == canonicalOpenPath(path)
    check restored.tabs[0].document.buffer.toString() == "recover me"
    check restored.tabs[0].document.buffer.isDirty
    removeDir(path)
    removeFile(sessionPath)

  test "discarded session omits dirty buffers":
    let namedPath = getTempDir() / ("nimculus-m5-discarded-" & $getCurrentProcessId() & ".txt")
    writeFile(namedPath, "on disk")
    var session: EditorSession
    var named = openDocument(namedPath)
    named.buffer.edit(Edit(startByte: 0, endByte: named.buffer.toString().len, text: "discard me"))
    session.addTab(named)
    var untitled = newDocument()
    untitled.buffer.edit(Edit(startByte: 0, endByte: 0, text: "discard too"))
    session.addTab(untitled)
    let sessionPath = getTempDir() / ("nimculus-m5-discarded-" & $getCurrentProcessId() & ".json")
    session.saveSession(sessionPath, preserveDirty = false)
    let restored = loadSession(sessionPath)
    check restored.tabs.len == 1
    check restored.tabs[0].document.path == canonicalOpenPath(namedPath)
    check restored.tabs[0].document.buffer.toString() == "on disk"
    check not restored.tabs[0].document.buffer.isDirty
    removeFile(namedPath)
    removeFile(sessionPath)

  test "external reload preserves view state and clamps selection":
    let path = getTempDir() / ("nimculus-m5-reload-" & $getCurrentProcessId() & ".txt")
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

  test "branch-style refresh reloads clean tabs and retains dirty tabs":
    let root = getTempDir() / ("nimculus-editor-branch-refresh-" & $getCurrentProcessId())
    if dirExists(root): removeDir(root)
    createDir(root)
    defer: removeDir(root)
    let cleanPath = root / "clean.nim"
    let dirtyPath = root / "dirty.nim"
    writeFile(cleanPath, "before clean\n")
    writeFile(dirtyPath, "before dirty\n")
    var session: EditorSession
    session.addTab(openDocument(cleanPath))
    session.addTab(openDocument(dirtyPath))
    session.tabs[1].document.buffer.edit(Edit(startByte: 0, endByte: 0, text: "local "))
    writeFile(cleanPath, "after clean\n")
    writeFile(dirtyPath, "after dirty\n")
    check session.reloadCleanDocumentsUnder(root) == 1
    check session.tabs[0].document.buffer.toString() == "after clean\n"
    check session.tabs[1].document.buffer.toString() == "local before dirty\n"
    check session.tabs[1].document.buffer.isDirty

  test "session loader tolerates partial metadata":
    let path = getTempDir() / ("nimculus-m5-partial-session-" & $getCurrentProcessId() & ".json")
    writeFile(path, "{\"tabs\": []}")
    let session = loadSession(path)
    check session.activeTab == -1
    check session.tabs.len == 0
    removeFile(path)

  test "session loader tolerates invalid JSON and out of range active tab":
    let invalidPath = getTempDir() / ("nimculus-m5-invalid-session-" & $getCurrentProcessId() & ".json")
    writeFile(invalidPath, "not-json")
    check loadSession(invalidPath).activeTab == -1
    removeFile(invalidPath)

    let rangePath = getTempDir() / ("nimculus-m5-range-session-" & $getCurrentProcessId() & ".json")
    writeFile(rangePath, "{\"activeTab\": 99, \"tabs\": []}")
    check loadSession(rangePath).activeTab == -1
    removeFile(rangePath)

    let malformedPath = getTempDir() / ("nimculus-m5-malformed-session-" & $getCurrentProcessId() & ".json")
    writeFile(malformedPath,
      "{\"activeTab\":\"bad\",\"split\":\"bad\",\"splitDirection\":7," &
      "\"tabs\":[{\"path\":7}]}")
    let malformed = loadSession(malformedPath)
    check malformed.activeTab == -1
    check not malformed.split
    check abs(malformed.effectiveSplitRatio - 0.5'f32) < 0.001'f32
    check malformed.tabs.len == 0
    removeFile(malformedPath)
