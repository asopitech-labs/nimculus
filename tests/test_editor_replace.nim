import std/unittest
import std/os
import nimculus/main
import nimculus/editor_app
import nimculus/editor_buffer
import nimculus/search

proc prepareFile(name, content: string): tuple[root, path: string] =
  result.root = getTempDir() / ("nimculus-editor-replace-" & name & "-" &
    $getCurrentProcessId())
  if dirExists(result.root): removeDir(result.root)
  createDir(result.root)
  result.path = result.root / "sample.txt"
  writeFile(result.path, content)

proc cleanup(root, path: string) =
  if fileExists(path): removeFile(path)
  if dirExists(root): removeDir(root)

suite "workspace replace editor buffers":
  test "replace preserves an unsaved open tab and survives saving it":
    let file = prepareFile("replace", "disk one")
    defer: cleanup(file.root, file.path)
    var session: EditorSession
    session.addTab(openDocument(file.path))
    session.tabs[0].document.buffer.edit(Edit(startByte: 0, endByte: 4,
      text: "draft"))

    let replaced = session.applyWorkspaceReplacement(file.path, "one", "replaced",
      SearchOptions(caseSensitive: true))

    check replaced.count == 1
    check replaced.usedOpenTab
    check session.tabs[0].document.buffer.isDirty()
    check session.tabs[0].document.buffer.toString() == "draft replaced"
    check readFile(file.path) == "disk one"
    session.tabs[0].document.save()
    check readFile(file.path) == "draft replaced"

  test "replaceAll preserves an unsaved open tab and survives saving it":
    let file = prepareFile("replace-all", "disk one one")
    defer: cleanup(file.root, file.path)
    var session: EditorSession
    session.addTab(openDocument(file.path))
    session.tabs[0].document.buffer.edit(Edit(startByte: 0, endByte: 4,
      text: "draft"))

    let replaced = session.applyWorkspaceReplacement(file.path, "one", "many",
      SearchOptions(caseSensitive: true))

    check replaced.count == 2
    check replaced.usedOpenTab
    check session.tabs[0].document.buffer.isDirty()
    check session.tabs[0].document.buffer.toString() == "draft many many"
    check readFile(file.path) == "disk one one"
    session.tabs[0].document.save()
    check readFile(file.path) == "draft many many"
