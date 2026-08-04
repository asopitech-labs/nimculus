import std/os
import std/json
import std/strutils
import std/unittest
import std/tables
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
    check schema["properties"]["terminal"]["properties"]["fontFamily"]["type"].getStr == "string"
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

  test "reloads a newly selected workspace settings layer":
    let root = getTempDir() / "nimculus-settings-switch"
    createDir(root)
    let globalPath = root / "global.json"
    let firstPath = root / "first.json"
    let secondPath = root / "second.json"
    writeFile(globalPath, "{\"editor\":{\"fontSize\":14}}")
    writeFile(firstPath, "{\"editor\":{\"fontSize\":16}}")
    writeFile(secondPath, "{\"editor\":{\"fontSize\":20}}")
    let store = newSettingsStore(globalPath, firstPath)
    check store.intSetting("editor.fontSize", 0) == 16
    store.workspacePath = secondPath
    store.workspaceStamp = -1
    check store.reload()
    check store.intSetting("editor.fontSize", 0) == 20
    removeFile(globalPath)
    removeFile(firstPath)
    removeFile(secondPath)
    removeDir(root)

  test "switches the language overlay without a file change":
    let root = getTempDir() / "nimculus-settings-language-switch"
    createDir(root)
    let path = root / "settings.json"
    writeFile(path, """{
      "editor":{"tabSize":2},
      "languages":{
        "nim":{"editor":{"tabSize":4}},
        "rust":{"editor":{"tabSize":8}},
        "tsx":{"editor":{"tabSize":6}}
      }
    }""")
    let store = newSettingsStore(path, "", "nim")
    check store.intSetting("editor.tabSize", 0) == 4
    check store.setLanguageId("rust")
    check store.intSetting("editor.tabSize", 0) == 8
    check store.setLanguageId("tsx")
    check store.intSetting("editor.tabSize", 0) == 6
    check store.setLanguageId("")
    check store.intSetting("editor.tabSize", 0) == 2
    check not store.setLanguageId("")
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

  test "resolves configured theme and icon registries":
    let root = getTempDir() / "nimculus-settings-registry"
    createDir(root)
    let path = root / "settings.json"
    writeFile(path, """{
      "theme":"Ocean",
      "themes":{"Ocean":{"appearance":"dark","colors":{"background":"#001122","foreground":"#eef8ff","selection":"#225577"}}},
      "iconTheme":"Source Icons",
      "iconThemes":{"Source Icons":{"directory":"DIR","file":"FILE","fileIcons":{"nim":"NIM"}}}
    }""")
    let store = newSettingsStore(path, "", "")
    check "Ocean" in store.themeNames()
    check store.theme().background == "#001122"
    check store.theme().foreground == "#eef8ff"
    check store.theme().border == "#464b57"
    check store.theme().panel == "#2f343e"
    check store.theme().tabActive == "#282c33"
    check themePaletteJson(store.theme()).find("tabActive") >= 0
    check store.iconForPath("src/main.nim") == "NIM"
    check store.iconForPath("src", true) == "DIR"
    removeFile(path)
    removeDir(root)

  test "ships distinct default icons for common project files":
    let store = newSettingsStore("", "", "")
    check store.iconForPath("src/main.nim") == "◆"
    check store.iconForPath("README.md") == "≡"
    check store.iconForPath("package.json") == "{}"
    check store.iconForPath("scripts/build.sh") == "$"
    check store.iconForPath("src", true) == "▸"

  test "resolves the system theme without reloading settings":
    let root = getTempDir() / "nimculus-settings-system-theme"
    createDir(root)
    let path = root / "settings.json"
    writeFile(path, "{\"theme\":\"system\"}")
    let store = newSettingsStore(path, "", "")
    check store.resolvedTheme(false).background == "#dcdcdd"
    check store.resolvedTheme(false).foreground == "#242529"
    check store.resolvedTheme(true).background == "#3b414d"
    check store.resolvedTheme(true).foreground == "#dce0e5"
    writeFile(path, "{\"theme\":\"system\",\"themeColors\":{\"background\":\"#123456\"}}")
    check store.reload()
    check store.resolvedTheme(false).background == "#123456"
    check store.resolvedTheme(true).background == "#123456"
    removeFile(path)
    removeDir(root)

  test "built-in One themes publish Zed editor roles and syntax weights":
    let store = newSettingsStore("", "", "")
    let light = store.themeRegistry["light"].colors
    let dark = store.themeRegistry["dark"].colors
    check light.editor == "#fafafa"
    check light.editorForeground == "#242529"
    check light.gutter == light.editor
    check light.editorActiveLine == "#ebebecbf"
    check dark.editor == "#282c33"
    check dark.editorForeground == "#acb2be"
    check dark.gutter == dark.editor
    check dark.editorActiveLine == "#2f343ebf"
    check light.syntax["title"]["color"].getStr == "#d3604f"
    check dark.syntax["emphasis.strong"]["fontWeight"].getInt == 700
    let palette = themePaletteJson(dark)
    check palette.find("\"syntax\"") >= 0
    check palette.find("#74ade8") >= 0

  test "built-in One themes preserve Zed terminal ANSI tables":
    let store = newSettingsStore("", "", "")
    let dark = store.themeRegistry["dark"].colors.terminalPalette
    let light = store.themeRegistry["light"].colors.terminalPalette
    let darkNormal = [
      "#282c34", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#abb2bf",
      "#636d83", "#EA858B", "#AAD581", "#FFD885", "#85C1FF", "#D398EB", "#6ED5DE", "#fafafa"
    ]
    let darkBright = [
      "#636d83", "#EA858B", "#AAD581", "#FFD885", "#85C1FF", "#D398EB", "#6ED5DE", "#fafafa",
      "#636d83", "#EA858B", "#AAD581", "#FFD885", "#85C1FF", "#D398EB", "#6ED5DE", "#fafafa"
    ]
    let darkDim = [
      "#3b3f4a", "#a7545a", "#6d8f59", "#b8985b", "#457cad", "#8d54a0", "#3c818a", "#8f969b",
      "#3b3f4a", "#a7545a", "#6d8f59", "#b8985b", "#457cad", "#8d54a0", "#3c818a", "#8f969b"
    ]
    let lightNormal = [
      "#000000", "#de3e35", "#3f953a", "#d2b67c", "#2f5af3", "#950095", "#0997b3", "#bbbbbb",
      "#000000", "#de3e35", "#3f953a", "#d2b67c", "#2f5af3", "#a00095", "#0bbcd6", "#ffffff"
    ]
    let lightBright = [
      "#000000", "#de3e35", "#3f953a", "#d2b67c", "#2f5af3", "#a00095", "#0bbcd6", "#ffffff",
      "#000000", "#de3e35", "#3f953a", "#d2b67c", "#2f5af3", "#a00095", "#0bbcd6", "#ffffff"
    ]
    let lightDim = [
      "#555555", "#9c2b26", "#2b6927", "#a48c5a", "#2140ab", "#6a006a", "#0a7b92", "#888888",
      "#555555", "#9c2b26", "#2b6927", "#a48c5a", "#2140ab", "#6a006a", "#0a7b92", "#888888"
    ]
    check dark.background == "#282c34"
    check dark.foreground == "#abb2bf"
    check dark.brightForeground == "#dce0e5"
    check dark.dimForeground == "#636d83"
    check dark.cursor == dark.brightForeground
    check dark.selection == dark.dimForeground
    check dark.normal == darkNormal
    check dark.bright == darkBright
    check dark.dim == darkDim
    check light.background == "#fafafa"
    check light.foreground == "#2a2c33"
    check light.brightForeground == "#2a2c33"
    check light.dimForeground == "#bbbbbb"
    check light.cursor == light.brightForeground
    check light.selection == light.dimForeground
    check light.normal == lightNormal
    check light.bright == lightBright
    check light.dim == lightDim
    let systemRoot = getTempDir() / "nimculus-terminal-theme-switch"
    createDir(systemRoot)
    let systemStore = newSettingsStore(systemRoot / "settings.json", "", "")
    writeFile(systemRoot / "settings.json", "{\"theme\":\"system\"}")
    check systemStore.reload()
    check systemStore.resolvedTheme(false).terminalPalette.background == "#fafafa"
    check systemStore.resolvedTheme(true).terminalPalette.background == "#282c34"
    removeFile(systemRoot / "settings.json")
    removeDir(systemRoot)
    let serialized = parseJson(themePaletteJson(store.themeRegistry["light"].colors))
    check serialized["terminalPalette"]["normal"][15].getStr == "#ffffff"
    check serialized["terminalPalette"]["bright"][13].getStr == "#a00095"
    check serialized["terminalPalette"]["dim"][4].getStr == "#2140ab"
