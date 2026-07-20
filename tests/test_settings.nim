import std/os
import std/unittest
import nimculus/settings

suite "M12 settings foundation":
  test "merges global, workspace, and language settings recursively":
    let root = getTempDir() / "nimculus-settings-test"
    createDir(root)
    let globalPath = root / "global.json"
    let workspacePath = root / "workspace.json"
    writeFile(globalPath, """{"editor":{"fontSize":14,"tabSize":2},"theme":"dark","languages":{"nim":{"editor":{"tabSize":4}}}}""")
    writeFile(workspacePath, """{"editor":{"fontSize":16},"themeColors":{"accent":"#ff00aa"}}""")
    let store = newSettingsStore(globalPath, workspacePath, "nim")
    check store.intSetting("editor.fontSize", 0) == 16
    check store.intSetting("editor.tabSize", 0) == 4
    check store.stringSetting("themeColors.accent") == "#ff00aa"
    removeFile(globalPath)
    removeFile(workspacePath)
    removeDir(root)

  test "validates types and exposes layered keymap and theme":
    let root = getTempDir() / "nimculus-settings-validation"
    createDir(root)
    let path = root / "settings.json"
    writeFile(path, """{"editor":{"fontSize":"large"},"keymap":[{"key":"cmd+s","command":"save"}],"themeColors":{"background":"#000000"}}""")
    let store = newSettingsStore(path, "", "")
    check store.diagnostics.len == 1
    check store.keyBindings().len == 1
    check store.keyBindings()[0].command == "save"
    check store.theme().background == "#000000"
    removeFile(path)
    removeDir(root)

  test "reloads changed files without replacing unchanged state":
    let root = getTempDir() / "nimculus-settings-reload"
    createDir(root)
    let path = root / "settings.json"
    writeFile(path, """{"editor":{"tabSize":2}}""")
    let store = newSettingsStore(path, "", "")
    check not store.reload()
    sleep(1100)
    writeFile(path, """{"editor":{"tabSize":8}}""")
    check store.reload()
    check store.intSetting("editor.tabSize", 0) == 8
    removeFile(path)
    removeDir(root)
