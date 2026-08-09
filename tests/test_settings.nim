import std/os
import std/json
import std/strutils
import std/unittest
import std/tables
import std/sequtils
import std/options
import nimculus/settings
import nimculus/status_bar
import nimculus/time_format
import nimnui/commands
import std/times

suite "M12 settings foundation":
  test "editor font features and fallbacks parse in stable platform order":
    let root = getTempDir() / "nimculus-font-settings"
    createDir(root)
    let path = root / "settings.json"
    writeFile(path, """{"editor":{"fontFeatures":{"liga":false,"calt":true},"fontFallbacks":["Hiragino Sans","Apple Symbols"]}}""")
    let store = newSettingsStore(path, "", "")
    let features = store.editorFontFeatures()
    check features.len == 2
    check features[0].tag == "calt"
    check features[0].enabled
    check features[1].tag == "liga"
    check not features[1].enabled
    check store.editorFontFallbacks() == @[
      "Hiragino Sans", "Apple Symbols"]
    check store.diagnostics().len == 0
    let schema = settingsSchema()
    check schema["properties"]["editor"]["properties"]["fontFeatures"]["type"].getStr == "object"
    check schema["properties"]["editor"]["properties"]["fontFallbacks"]["type"].getStr == "array"
    removeFile(path)
    removeDir(root)

  test "invalid editor font feature and fallback values are diagnosed":
    let root = getTempDir() / "nimculus-invalid-font-settings"
    createDir(root)
    let path = root / "settings.json"
    writeFile(path, """{"editor":{"fontFeatures":{"liga":1,"tooLong":true,"éééé":false},"fontFallbacks":["",3]}}""")
    let store = newSettingsStore(path, "", "")
    check store.editorFontFeatures().len == 0
    check store.editorFontFallbacks().len == 0
    check store.diagnostics().len == 5
    removeFile(path)
    removeDir(root)

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
    check store.softWrapMode() == DefaultSoftWrapMode
    check store.editorScrollSensitivity(false) == DefaultScrollSensitivity
    check store.editorScrollSensitivity(true) == DefaultFastScrollSensitivity
    check store.terminalScrollMultiplier() == DefaultTerminalScrollMultiplier
    removeFile(globalPath)
    removeFile(workspacePath)
    removeDir(root)

  test "panel dock settings match Zed defaults and read configured positions":
    let store = newSettingsStore("", "", "")
    check store.projectPanelDock() == DefaultProjectPanelDock
    check store.outlinePanelDock() == DefaultOutlinePanelDock
    check store.gitPanelDock() == DefaultGitPanelDock
    check store.agentDock() == DefaultAgentDock
    check store.terminalDock() == DefaultTerminalDock
    check store.debuggerDock() == DefaultDebuggerDock

    let root = getTempDir() / "nimculus-panel-dock-settings"
    createDir(root)
    let path = root / "settings.json"
    writeFile(path, """{
      "projectPanel":{"dock":"left"},
      "outlinePanel":{"dock":"bottom"},
      "gitPanel":{"dock":"left"},
      "agent":{"dock":"right"},
      "terminal":{"dock":"left"},
      "debugger":{"dock":"right"}
    }""")
    let configured = newSettingsStore(path, "", "")
    check configured.projectPanelDock() == "left"
    check configured.outlinePanelDock() == "bottom"
    check configured.gitPanelDock() == "left"
    check configured.agentDock() == "right"
    check configured.terminalDock() == "left"
    check configured.debuggerDock() == "right"
    removeFile(path)
    removeDir(root)

  test "panel dock settings validate their allowed positions":
    let root = getTempDir() / "nimculus-invalid-panel-dock-settings"
    createDir(root)
    let path = root / "settings.json"
    writeFile(path, """{
      "projectPanel":{"dock":"diagonal"},
      "terminal":{"dock":"diagonal"}
    }""")
    let store = newSettingsStore(path, "", "")
    check store.projectPanelDock() == DefaultProjectPanelDock
    check store.terminalDock() == DefaultTerminalDock
    check store.diagnostics().len == 2
    removeFile(path)
    removeDir(root)

  test "Markdown keeps Zed's language-scoped editor-width wrapping":
    check softWrapEnabledForPath("DEVELOPMENT_GUIDELINES.md", "none")
    check not softWrapEnabledForPath("main.nim", "none")
    check softWrapEnabledForPath("main.nim", "editor_width")

  test "scroll sensitivity settings keep Zed's minimum":
    let root = getTempDir() / "nimculus-scroll-settings"
    createDir(root)
    let path = root / "settings.json"
    writeFile(path, """{
      "scroll_sensitivity": 0,
      "fast_scroll_sensitivity": 0.005,
      "terminal": {"scroll_multiplier": 0}
    }""")
    let store = newSettingsStore(path, "", "")
    check store.editorScrollSensitivity(false) == MinimumScrollSensitivity
    check store.editorScrollSensitivity(true) == MinimumScrollSensitivity
    check store.terminalScrollMultiplier() == MinimumScrollSensitivity
    removeFile(path)
    removeDir(root)

  test "publishes a machine-readable settings schema":
    let schema = settingsSchema()
    check schema["$schema"].kind == JString
    check schema["properties"]["editor"]["properties"]["fontSize"]["minimum"].getInt == 6
    check schema["properties"]["editor"]["properties"]["fontFamily"]["type"].getStr == "string"
    check schema["properties"]["terminal"]["properties"]["fontSize"]["maximum"].getInt == 48
    check schema["properties"]["terminal"]["properties"]["fontFamily"]["type"].getStr == "string"
    for panel in ["projectPanel", "outlinePanel", "gitPanel", "agent", "terminal", "debugger"]:
      check schema["properties"][panel]["properties"]["dock"]["enum"].getElems.mapIt(
        it.getStr) == @["left", "bottom", "right"]
    check schema["properties"]["projectPanel"]["properties"]["dock"]["default"].getStr == "right"
    check schema["properties"]["outlinePanel"]["properties"]["dock"]["default"].getStr == "right"
    check schema["properties"]["gitPanel"]["properties"]["dock"]["default"].getStr == "right"
    check schema["properties"]["agent"]["properties"]["dock"]["default"].getStr == "left"
    check schema["properties"]["terminal"]["properties"]["dock"]["default"].getStr == "bottom"
    check schema["properties"]["debugger"]["properties"]["dock"]["default"].getStr == "bottom"
    check schema["properties"]["scroll_sensitivity"]["default"].getFloat == 1.0
    check schema["properties"]["fast_scroll_sensitivity"]["default"].getFloat == 4.0
    check schema["properties"]["terminal"]["properties"]["scroll_multiplier"]["default"].getFloat == 1.0
    check schema["properties"]["keymap"]["items"]["required"].len == 2

  test "validates types and exposes layered keymap and theme":
    let root = getTempDir() / "nimculus-settings-validation"
    createDir(root)
    let path = root / "settings.json"
    writeFile(path, """{"editor":{"fontSize":"large"},"scroll_sensitivity":"fast","keymap":[{"key":"cmd+s","command":"save","when":"Editor && mode == full"}],"themeColors":{"background":"#000000"}}""")
    let store = newSettingsStore(path, "", "")
    check store.diagnostics.len == 2
    check store.keyBindings().len == 1
    check store.keyBindings()[0].command == "save"
    check store.keyBindings()[0].whenClause == "Editor && mode == full"
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
    check light.editor == "#fcfcfc"
    check light.editorForeground == "#242529"
    check light.gutter == light.editor
    check light.editorActiveLine == "#ececedbf"
    check dark.editor == "#282c33"
    check dark.editorForeground == "#acb2be"
    check dark.gutter == dark.editor
    check dark.editorActiveLine == "#2f343ebf"
    # The native gutter overlay inherits the opaque editor fill. Keep both
    # resolved roles equal so a palette change cannot reintroduce a seam.
    let lightPalette = parseJson(themePaletteJson(light))
    let darkPalette = parseJson(themePaletteJson(dark))
    check lightPalette["editor"] == lightPalette["gutter"]
    check darkPalette["editor"] == darkPalette["gutter"]
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

  test "status bar defaults match Zed's two right-side items":
    let store = newSettingsStore("", "", "")
    check statusBarFooter(store, "1:1", "UTF-8", "LF", "Markdown", "main.md") ==
      @[StatusBarFooterItem(kind: "cursor", text: "1:1"),
        StatusBarFooterItem(kind: "language", text: "Markdown")]
    check serializeStatusBarFooter(statusBarFooter(store, "1:1", "UTF-8", "LF", "Markdown",
        "main.md")) ==
      "cursor=1:1\tlanguage=Markdown"

  test "status bar line ending setting shows LF and CRLF":
    let root = getTempDir() / "nimculus-status-bar-line-endings"
    createDir(root)
    let path = root / "settings.json"
    writeFile(path, "{\"statusBar\":{\"lineEndingsButton\":true}}")
    let store = newSettingsStore(path, "", "")
    check statusBarFooter(store, "1:1", "UTF-8", "LF", "Markdown", "main.md") ==
      @[StatusBarFooterItem(kind: "cursor", text: "1:1"),
        StatusBarFooterItem(kind: "line-ending", text: "LF"),
        StatusBarFooterItem(kind: "language", text: "Markdown")]
    check statusBarFooter(store, "1:1", "UTF-8", "CRLF", "Markdown", "main.md") ==
      @[StatusBarFooterItem(kind: "cursor", text: "1:1"),
        StatusBarFooterItem(kind: "line-ending", text: "CRLF"),
        StatusBarFooterItem(kind: "language", text: "Markdown")]
    removeFile(path)
    removeDir(root)

  test "status bar encoding modes follow Zed's should_show":
    let root = getTempDir() / "nimculus-status-bar-encoding"
    createDir(root)
    let path = root / "settings.json"
    writeFile(path, "{\"statusBar\":{\"activeEncodingButton\":\"enabled\"}}")
    let alwaysStore = newSettingsStore(path, "", "")
    check statusBarFooter(alwaysStore, "1:1", "UTF-8", "LF", "Markdown", "main.md") ==
      @[StatusBarFooterItem(kind: "cursor", text: "1:1"),
        StatusBarFooterItem(kind: "encoding", text: "UTF-8"),
        StatusBarFooterItem(kind: "language", text: "Markdown")]
    writeFile(path, "{\"statusBar\":{\"activeEncodingButton\":\"non_utf8\"}}")
    let nonUtf8Store = newSettingsStore(path, "", "")
    check statusBarFooter(nonUtf8Store, "1:1", "UTF-8", "LF", "Markdown", "main.md") ==
      @[StatusBarFooterItem(kind: "cursor", text: "1:1"),
        StatusBarFooterItem(kind: "language", text: "Markdown")]
    check statusBarFooter(nonUtf8Store, "1:1", "Windows-1252", "LF", "Markdown", "main.md",
      isUtf8 = false) == @[StatusBarFooterItem(kind: "cursor", text: "1:1"),
        StatusBarFooterItem(kind: "encoding", text: "Windows-1252"),
        StatusBarFooterItem(kind: "language", text: "Markdown")]
    writeFile(path, "{\"statusBar\":{\"activeEncodingButton\":\"disabled\"}}")
    let disabledStore = newSettingsStore(path, "", "")
    check statusBarFooter(disabledStore, "1:1", "Windows-1252", "LF", "Markdown", "main.md",
      isUtf8 = false) == @[StatusBarFooterItem(kind: "cursor", text: "1:1"),
        StatusBarFooterItem(kind: "language", text: "Markdown")]
    removeFile(path)
    removeDir(root)

  test "status bar encoding appends BOM and active file follows its setting":
    let root = getTempDir() / "nimculus-status-bar-file"
    createDir(root)
    let path = root / "settings.json"
    writeFile(path, "{\"statusBar\":{\"showActiveFile\":true}}")
    let store = newSettingsStore(path, "", "")
    check statusBarFooter(store, "1:1", "UTF-8", "LF", "Markdown", "main.md",
      hasBom = true) == @[StatusBarFooterItem(kind: "cursor", text: "1:1"),
        StatusBarFooterItem(kind: "encoding", text: "UTF-8 (BOM)"),
        StatusBarFooterItem(kind: "language", text: "Markdown"),
        StatusBarFooterItem(kind: "active-file", text: "main.md")]
    check statusBarEncodingShouldShow("non_utf8", true, true)
    check statusBarEncodingText("UTF-8", true) == "UTF-8 (BOM)"
    removeFile(path)
    removeDir(root)

  test "status bar settings are present in schema and reject unknown encoding modes":
    let schema = settingsSchema()
    let encodingSchema = schema["properties"]["statusBar"]["properties"][
      "activeEncodingButton"]
    check encodingSchema["enum"].getElems.mapIt(it.getStr) == @["enabled", "non_utf8", "disabled"]
    let diagnostics = validateSettings(parseJson(
      "{\"statusBar\":{\"activeEncodingButton\":\"unknown\"}}"))
    check diagnostics.len == 1
    check diagnostics[0].path == "statusBar.activeEncodingButton"

  test "search button defaults to visible and follows its setting":
    let root = getTempDir() / "nimculus-search-button-settings"
    createDir(root)
    let path = root / "settings.json"
    let defaults = newSettingsStore(path, "", "")
    check defaults.boolSetting("search.button", DefaultSearchButton)
    writeFile(path, "{\"search\":{\"button\":false}}")
    let hidden = newSettingsStore(path, "", "")
    check not hidden.boolSetting("search.button", DefaultSearchButton)
    check settingsSchema()["properties"]["search"]["properties"]["button"][
      "default"].getBool
    let diagnostics = validateSettings(parseJson("{\"search\":{\"button\":1}}"))
    check diagnostics.len == 1
    check diagnostics[0].path == "search.button"
    removeFile(path)
    removeDir(root)

  test "git blame status bar settings match Zed defaults and validation":
    let defaults = newSettingsStore("", "", "")
    check defaults.gitInlineBlameEnabled()
    check defaults.gitInlineBlameLocation() == "inline"
    check not defaults.gitInlineBlameShowCommitSummary()
    check defaults.gitInlineBlameDelayMs() == DefaultGitInlineBlameDelayMs
    check defaults.gitInlineBlameDelay().isNone
    check defaults.gitInlineBlamePadding() == DefaultGitInlineBlamePadding
    check defaults.gitInlineBlameMinColumn() == DefaultGitInlineBlameMinColumn
    let schema = settingsSchema()["properties"]["git"]["properties"]["inlineBlame"]["properties"]
    check schema["enabled"]["default"].getBool
    check schema["location"]["enum"].getElems.mapIt(it.getStr) == @["inline", "status_bar"]
    check schema["location"]["default"].getStr == "inline"
    check not schema["showCommitSummary"]["default"].getBool
    check schema["delayMs"]["default"].getInt == DefaultGitInlineBlameDelayMs
    check schema["padding"]["default"].getInt == DefaultGitInlineBlamePadding
    check schema["minColumn"]["default"].getInt == DefaultGitInlineBlameMinColumn
    let configuredDiagnostics = validateSettings(parseJson(
      "{\"git\":{\"inlineBlame\":{\"delayMs\":-1,\"padding\":\"7\",\"minColumn\":1.5}}}"))
    check configuredDiagnostics.len == 3
    let diagnostics = validateSettings(parseJson(
      "{\"git\":{\"inlineBlame\":{\"enabled\":1,\"location\":\"footer\",\"showCommitSummary\":\"yes\"}}}"))
    check diagnostics.len == 3
    check diagnostics.anyIt(it.path == "git.inlineBlame.location")
    check diagnostics.anyIt(it.path == "git.inlineBlame.enabled")
    check diagnostics.anyIt(it.path == "git.inlineBlame.showCommitSummary")
    let root = getTempDir() / "nimculus-git-blame-status-settings"
    createDir(root)
    let path = root / "settings.json"
    writeFile(path, "{\"git\":{\"inlineBlame\":{\"delayMs\":120,\"padding\":9,\"minColumn\":24}}}")
    let configuredStore = newSettingsStore(path, "", "")
    check configuredStore.gitInlineBlameDelayMs() == 120
    check configuredStore.gitInlineBlameDelay().get.inMilliseconds == 120
    check configuredStore.gitInlineBlamePadding() == 9
    check configuredStore.gitInlineBlameMinColumn() == 24
    writeFile(path, "{\"git\":{\"inlineBlame\":{\"location\":\"status_bar\"}}}")
    let statusStore = newSettingsStore(path, "", "")
    let statusItems = statusBarFooter(statusStore, "1:1", "UTF-8", "LF", "Nim", "main.nim",
      gitBlameHash = "abc", gitBlameText = "Alice, Today")
    check statusItems.anyIt(it.kind == "git-blame:abc" and it.text == "Alice, Today")
    writeFile(path, "{\"git\":{\"inlineBlame\":{\"enabled\":false,\"location\":\"status_bar\"}}}")
    let disabledStore = newSettingsStore(path, "", "")
    check statusBarFooter(disabledStore, "1:1", "UTF-8", "LF", "Nim", "main.nim",
      gitBlameHash = "abc", gitBlameText = "Alice, Today").allIt(
        it.kind != "git-blame:abc")
    removeFile(path)
    removeDir(root)

  proc testUnixDate(year, month, day: int): int64 =
    dateTime(year, Month(month), day, 12, 0, 0, 0, utc()).toTime.toUnix

  test "relative blame time covers every Zed branch and boundary":
    let now = testUnixDate(2026, 1, 31)
    check formatRelativeTime(now, now) == "Just now"
    check formatRelativeTime(now - 60, now) == "1 minute ago"
    check formatRelativeTime(now - 2 * 60, now) == "2 minutes ago"
    check formatRelativeTime(now - 59 * 60, now) == "59 minutes ago"
    check formatRelativeTime(now - 60 * 60, now) == "1 hour ago"
    check formatRelativeTime(now - 2 * 60 * 60, now) == "2 hours ago"
    check formatRelativeTime(now - 23 * 60 * 60, now) == "23 hours ago"
    check formatRelativeDate(now, now) == "Today"
    check formatRelativeTime(testUnixDate(2026, 1, 30), now) == "Yesterday"
    check formatRelativeTime(testUnixDate(2026, 1, 29), now) == "2 days ago"
    check formatRelativeTime(testUnixDate(2026, 1, 25), now) == "6 days ago"
    check formatRelativeTime(testUnixDate(2026, 1, 24), now) == "1 week ago"
    check formatRelativeTime(testUnixDate(2026, 1, 17), now) == "2 weeks ago"
    check formatRelativeTime(testUnixDate(2026, 1, 3), now) == "4 weeks ago"
    check formatRelativeTime(testUnixDate(2026, 1, 2), now) == "1 month ago"
    check formatRelativeTime(testUnixDate(2025, 12, 31), now) == "1 month ago"
    check formatRelativeTime(testUnixDate(2025, 11, 30), now) == "2 months ago"
    check formatRelativeTime(testUnixDate(2025, 2, 28), now) == "11 months ago"
    check formatRelativeTime(testUnixDate(2025, 1, 31), now) == "1 year ago"
    check formatRelativeTime(testUnixDate(2024, 3, 31), now) == "1 year, 10 months ago"
    check formatRelativeTime(testUnixDate(2021, 2, 28), now) == "4 years, 11 months ago"
    check formatRelativeTime(testUnixDate(2021, 1, 31), now) == "5 years ago"
    check gitBlameStatusText("abcdefghijklmnopqrstu", now - 60, "Summary", false, now) ==
      "abcdefghijklmnopqrst, 1 minute ago"
    check gitBlameStatusText("Alice", now - 60, "Summary", true, now) ==
      "Alice, 1 minute ago - Summary"
    check gitBlameStatusText("Alice", 0, "Summary", false, now, false) ==
      "Alice, Error parsing date"
