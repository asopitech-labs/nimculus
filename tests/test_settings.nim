import std/os
import std/json
import std/unittest
import nimculus/settings
import nimnui/commands

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

  test "publishes a machine-readable settings schema":
    let schema = settingsSchema()
    check schema["$schema"].kind == JString
    check schema["properties"]["editor"]["properties"]["fontSize"]["minimum"].getInt == 6
    check schema["properties"]["editor"]["properties"]["fontFamily"]["type"].getStr == "string"
    check schema["properties"]["terminal"]["properties"]["fontSize"]["maximum"].getInt == 48
    check schema["properties"]["keymap"]["items"]["required"].len == 2

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
    let shortcut = shortcutFromKeyBinding("cmd+shift+p")
    check shortcut.keyCode == 35
    check commandModifier in shortcut.modifiers
    check shiftModifier in shortcut.modifiers
    removeFile(path)
    removeDir(root)

  test "reloads changed files without replacing unchanged state":
    let root = getTempDir() / "nimculus-settings-reload"
    createDir(root)
    let path = root / "settings.json"
    writeFile(path, """{"editor":{"tabSize":2}}""")
    let store = newSettingsStore(path, "", "")
    check not store.reload()
    writeFile(path, """{"editor":{"tabSize":8}}""")
    check store.reload()
    check store.intSetting("editor.tabSize", 0) == 8
    removeFile(path)
    removeDir(root)

  test "ignores malformed keymap entries without raising":
    let root = getTempDir() / "nimculus-settings-keymap-types"
    createDir(root)
    let path = root / "settings.json"
    writeFile(path, """{"keymap":[{"key":12,"command":"save"},{"key":"cmd+s"},{"key":"cmd+p","command":"commandPalette","when":false},"bad"]}""")
    let store = newSettingsStore(path, "", "")
    check store.keyBindings().len == 0
    check store.diagnostics.len == 4
    removeFile(path)
    removeDir(root)
