import std/[os, strutils, unittest]
import nimculus/editor_buffer
import nimculus/editor_view
import nimculus/settings
import nimculus/status_bar
import nimculus/vim
import nimnui/commands

const vimBufferText = ".....\n.....\n.....\n.....\n....."

proc enabledSettings(): tuple[root, path: string, store: SettingsStore] =
  let root = getTempDir() / ("nimculus-vim-test-" & $getCurrentProcessId())
  createDir(root)
  let path = root / "settings.json"
  writeFile(path, "{\"vim\":{\"enabled\":true}}")
  (root: root, path: path, store: newSettingsStore(path, "", ""))

proc newVimState(store: SettingsStore): tuple[view: EditorViewState, buffer: PieceTable] =
  result.buffer = initPieceTable(vimBufferText)
  result.view = newEditorView()
  result.view.configureVim(store)

suite "Vim normal and insert modes":
  test "normal motions do not mutate a fixed five by five buffer":
    let setup = enabledSettings()
    var state = newVimState(setup.store)
    let start = state.buffer.byteOffsetAtLineColumn(2, 1)
    state.view.moveCursor(start)
    let length = state.buffer.contentLength
    check state.view.dispatchVimKey(state.buffer, 'h')
    check state.buffer.lineColumn(state.view.cursor) == (line: 2, column: 0)
    check state.view.dispatchVimKey(state.buffer, 'j')
    check state.buffer.lineColumn(state.view.cursor) == (line: 3, column: 0)
    check state.view.dispatchVimKey(state.buffer, 'k')
    check state.buffer.lineColumn(state.view.cursor) == (line: 2, column: 0)
    check state.view.dispatchVimKey(state.buffer, 'l')
    check state.buffer.lineColumn(state.view.cursor) == (line: 2, column: 1)
    check state.view.vimMode == vimNormal
    check state.buffer.contentLength == length
    check state.buffer.lineColumn(state.view.cursor) == (line: 2, column: 1)
    removeFile(setup.path)
    removeDir(setup.root)

  test "horizontal and vertical motions stay inside the buffer":
    let setup = enabledSettings()
    var state = newVimState(setup.store)
    state.view.moveCursor(state.buffer.byteOffsetAtLineColumn(0, 4))
    discard state.view.dispatchVimKey(state.buffer, 'l')
    check state.buffer.lineColumn(state.view.cursor) == (line: 0, column: 4)
    state.view.moveCursor(state.buffer.byteOffsetAtLineColumn(0, 0))
    discard state.view.dispatchVimKey(state.buffer, 'h')
    check state.buffer.lineColumn(state.view.cursor) == (line: 0, column: 0)
    state.view.moveCursor(state.buffer.byteOffsetAtLineColumn(4, 4))
    discard state.view.dispatchVimKey(state.buffer, 'j')
    check state.buffer.lineColumn(state.view.cursor) == (line: 4, column: 4)
    removeFile(setup.path)
    removeDir(setup.root)

  test "counted motions and pending counts are exact":
    let setup = enabledSettings()
    var state = newVimState(setup.store)
    state.view.moveCursor(state.buffer.byteOffsetAtLineColumn(0, 1))
    discard state.view.dispatchVimKey(state.buffer, '3')
    check state.buffer.lineColumn(state.view.cursor) == (line: 0, column: 1)
    let pendingBinding = Shortcut(keystrokes: state.view.vimPendingKeystrokes & @[vimKey('l')])
    check pendingBinding.matchKeystrokes(state.view.vimPendingKeystrokes).pending
    check state.view.vimPendingMotionMatch('l').pending
    discard state.view.dispatchVimKey(state.buffer, 'l')
    check state.buffer.lineColumn(state.view.cursor) == (line: 0, column: 4)
    discard state.view.dispatchVimKey(state.buffer, '2')
    discard state.view.dispatchVimKey(state.buffer, 'j')
    check state.buffer.lineColumn(state.view.cursor) == (line: 2, column: 4)
    removeFile(setup.path)
    removeDir(setup.root)

  test "insert entry, literal insertion, and escape return to normal":
    let setup = enabledSettings()
    var state = newVimState(setup.store)
    state.view.moveCursor(state.buffer.byteOffsetAtLineColumn(0, 0))
    let length = state.buffer.contentLength
    discard state.view.dispatchVimKey(state.buffer, 'i')
    check state.view.vimMode == vimInsert
    check state.view.dispatchVimText(state.buffer, "abc")
    check state.buffer.contentLength == length + 3
    check state.buffer.toString().startsWith("abc")
    discard state.view.dispatchVimKey(state.buffer, '\x1b')
    check state.view.vimMode == vimNormal
    check state.buffer.lineColumn(state.view.cursor).column == 2
    state.view.moveCursor(state.buffer.byteOffsetAtLineColumn(0, 0))
    discard state.view.dispatchVimKey(state.buffer, 'i')
    discard state.view.dispatchVimKey(state.buffer, '\x1b')
    check state.buffer.lineColumn(state.view.cursor).column == 0
    removeFile(setup.path)
    removeDir(setup.root)

  test "mode indicator follows the setting and per-view mode":
    let setup = enabledSettings()
    var state = newVimState(setup.store)
    let normal = serializeStatusBarFooter(statusBarFooter(setup.store, "1:1", "UTF-8",
      "LF", "Nim", "main.nim", vimMode = state.view.vimMode))
    check normal.count("vim-mode=NORMAL") == 1
    discard state.view.dispatchVimKey(state.buffer, 'i')
    let insert = serializeStatusBarFooter(statusBarFooter(setup.store, "1:1", "UTF-8",
      "LF", "Nim", "main.nim", vimMode = state.view.vimMode))
    check insert.count("vim-mode=INSERT") == 1
    removeFile(setup.path)
    removeDir(setup.root)

    let disabled = newSettingsStore("", "", "")
    let off = serializeStatusBarFooter(statusBarFooter(disabled, "1:1", "UTF-8", "LF",
      "Nim", "main.nim"))
    check "vim-mode=" notin off
