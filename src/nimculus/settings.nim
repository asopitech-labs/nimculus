import std/json
import std/hashes
import std/os
import std/strutils
import std/tables
import std/algorithm

type
  SettingsDiagnostic* = object
    path*: string
    message*: string

  KeyBinding* = object
    key*: string
    command*: string
    whenClause*: string

  TerminalPalette* = object
    ## Zed's terminal roles plus the normal, bright, and dim ANSI tables.
    ## The arrays use the terminal's canonical indexes 0..15.
    background*, foreground*, brightForeground*, dimForeground*: string
    cursor*, selection*: string
    normal*, bright*, dim*: array[16, string]

  ThemeColors* = object
    background*: string
    foreground*: string
    accent*: string
    selection*: string
    border*: string
    surface*: string
    elevated*: string
    panel*: string
    element*: string
    elementHover*: string
    elementActive*: string
    elementSelected*: string
    textMuted*: string
    textPlaceholder*: string
    textDisabled*: string
    textAccent*: string
    borderVariant*: string
    borderFocused*: string
    borderSelected*: string
    titleBar*: string
    titleBarInactive*: string
    toolbar*: string
    tabBar*: string
    tabActive*: string
    tabInactive*: string
    statusBar*: string
    editor*: string
    editorForeground*: string
    gutter*: string
    editorSubheader*: string
    editorActiveLine*: string
    scrollbarThumb*: string
    scrollbarHover*: string
    lineNumber*: string
    activeLineNumber*: string
    hoverLineNumber*: string
    caret*: string
    terminal*: string
    added*: string
    modified*: string
    deleted*: string
    ignored*: string
    conflict*: string
    warning*: string
    hint*: string
    error*: string
    info*: string
    success*: string
    syntax*: JsonNode
    terminalPalette*: TerminalPalette

  ThemeDefinition* = object
    name*: string
    appearance*: string
    colors*: ThemeColors

  IconThemeDefinition* = object
    name*: string
    directoryIcon*: string
    fileIcon*: string
    fileIcons*: Table[string, string]

  NimculusSettings* = object
    values*: JsonNode
    diagnostics*: seq[SettingsDiagnostic]

  SettingsStore* = ref object
    globalPath*: string
    workspacePath*: string
    languageId*: string
    globalStamp*: int64
    workspaceStamp*: int64
    settings*: NimculusSettings
    themeRegistry*: Table[string, ThemeDefinition]
    iconThemeRegistry*: Table[string, IconThemeDefinition]

proc objectNode(): JsonNode = newJObject()

proc mergeJson*(base, overlay: JsonNode): JsonNode =
  ## Recursively merge objects, matching Zed's layered settings behavior.
  if base == nil: return if overlay == nil: objectNode() else: overlay
  if overlay == nil: return base
  if base.kind != JObject or overlay.kind != JObject: return overlay
  result = base.copy()
  for key, value in overlay:
    if result.hasKey(key) and result[key].kind == JObject and value.kind == JObject:
      result[key] = mergeJson(result[key], value)
    else:
      result[key] = value

proc loadJsonFile(path: string, diagnostics: var seq[SettingsDiagnostic]): JsonNode =
  if path.len == 0 or not fileExists(path): return objectNode()
  try:
    result = parseJson(readFile(path))
    if result.kind != JObject:
      diagnostics.add(SettingsDiagnostic(path: path, message: "settings root must be an object"))
      result = objectNode()
  except CatchableError as error:
    diagnostics.add(SettingsDiagnostic(path: path, message: error.msg))
    result = objectNode()

proc nodeAt(root: JsonNode, path: string): JsonNode =
  result = root
  for part in path.split('.'):
    if result == nil or result.kind != JObject or not result.hasKey(part): return nil
    result = result[part]

proc jsonStringAt(root: JsonNode, path: string, fallback = ""): string =
  let node = nodeAt(root, path)
  if node != nil and node.kind == JString: return node.getStr
  fallback

proc jsonIntAt*(root: JsonNode, path: string, fallback: int): int =
  let node = nodeAt(root, path)
  if node != nil and node.kind == JInt: return node.getInt
  fallback

proc jsonBoolAt*(root: JsonNode, path: string, fallback: bool): bool =
  let node = nodeAt(root, path)
  if node != nil and node.kind == JBool: return node.getBool
  fallback

proc validateSettings*(root: JsonNode): seq[SettingsDiagnostic] =
  if root == nil or root.kind != JObject:
    result.add(SettingsDiagnostic(path: "", message: "settings root must be an object"))
    return
  let fontSize = nodeAt(root, "editor.fontSize")
  if fontSize != nil and fontSize.kind != JInt:
    result.add(SettingsDiagnostic(path: "editor.fontSize", message: "must be an integer"))
  elif fontSize != nil and (fontSize.getInt < 6 or fontSize.getInt > 96):
    result.add(SettingsDiagnostic(path: "editor.fontSize", message: "must be between 6 and 96"))
  let tabSize = nodeAt(root, "editor.tabSize")
  if tabSize != nil and tabSize.kind != JInt:
    result.add(SettingsDiagnostic(path: "editor.tabSize", message: "must be an integer"))
  elif tabSize != nil and (tabSize.getInt < 1 or tabSize.getInt > 16):
    result.add(SettingsDiagnostic(path: "editor.tabSize", message: "must be between 1 and 16"))
  let terminalFontSize = nodeAt(root, "terminal.fontSize")
  if terminalFontSize != nil and terminalFontSize.kind != JInt:
    result.add(SettingsDiagnostic(path: "terminal.fontSize", message: "must be an integer"))
  elif terminalFontSize != nil and (terminalFontSize.getInt < 6 or terminalFontSize.getInt > 48):
    result.add(SettingsDiagnostic(path: "terminal.fontSize", message: "must be between 6 and 48"))
  let insertSpaces = nodeAt(root, "editor.insertSpaces")
  if insertSpaces != nil and insertSpaces.kind != JBool:
    result.add(SettingsDiagnostic(path: "editor.insertSpaces", message: "must be a boolean"))
  for key in ["theme", "iconTheme", "editor.fontFamily", "terminal.shell", "terminal.fontFamily"]:
    let value = jsonStringAt(root, key, "")
    if value.len == 0:
      let node = nodeAt(root, key)
      if node != nil:
        result.add(SettingsDiagnostic(path: key, message: "must be a string"))
  let keymap = nodeAt(root, "keymap")
  if keymap != nil:
    if keymap.kind != JArray:
      result.add(SettingsDiagnostic(path: "keymap", message: "must be an array"))
    else:
      for index in 0 ..< keymap.len:
        let item = keymap[index]
        let itemPath = "keymap[" & $index & "]"
        if item.kind != JObject:
          result.add(SettingsDiagnostic(path: itemPath, message: "must be an object"))
          continue
        for field in ["key", "command", "when"]:
          if item.hasKey(field) and item[field].kind != JString:
            result.add(SettingsDiagnostic(path: itemPath & "." & field,
              message: "must be a string"))
        for required in ["key", "command"]:
          if not item.hasKey(required):
            result.add(SettingsDiagnostic(path: itemPath,
              message: "missing required field: " & required))

proc settingsSchema*(): JsonNode =
  ## Stable schema consumed by editors and future settings UI completion.
  %*{
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "type": "object",
    "properties": {
      "editor": {"type": "object", "properties": {
        "fontSize": {"type": "integer", "minimum": 6, "maximum": 96},
        "fontFamily": {"type": "string"},
        "tabSize": {"type": "integer", "minimum": 1, "maximum": 16},
        "insertSpaces": {"type": "boolean"}
    }},
    "theme": {"type": "string"},
    "iconTheme": {"type": "string"},
    "themes": {"type": "object", "additionalProperties": {"type": "object"}},
    "iconThemes": {"type": "object", "additionalProperties": {"type": "object"}},
    "themeColors": {"type": "object", "properties": {
      "background": {"type": "string"}, "foreground": {"type": "string"},
      "accent": {"type": "string"}, "selection": {"type": "string"},
      "border": {"type": "string"}, "surface": {"type": "string"},
      "panel": {"type": "string"}, "elevated": {"type": "string"}, "element": {"type": "string"},
      "elementHover": {"type": "string"}, "elementActive": {"type": "string"},
      "elementSelected": {"type": "string"}, "textMuted": {"type": "string"},
      "textPlaceholder": {"type": "string"}, "textDisabled": {"type": "string"},
      "textAccent": {"type": "string"}, "borderVariant": {"type": "string"},
      "borderFocused": {"type": "string"}, "borderSelected": {"type": "string"},
      "titleBar": {"type": "string"}, "titleBarInactive": {"type": "string"},
      "toolbar": {"type": "string"}, "tabBar": {"type": "string"},
      "tabActive": {"type": "string"}, "tabInactive": {"type": "string"},
      "statusBar": {"type": "string"}, "editor": {"type": "string"},
      "editorForeground": {"type": "string"}, "gutter": {"type": "string"},
      "editorActiveLine": {"type": "string"}, "scrollbarThumb": {"type": "string"},
      "scrollbarHover": {"type": "string"}, "lineNumber": {"type": "string"},
      "activeLineNumber": {"type": "string"}, "hoverLineNumber": {"type": "string"},
      "caret": {"type": "string"}, "terminal": {"type": "string"},
      "added": {"type": "string"}, "modified": {"type": "string"},
      "deleted": {"type": "string"}, "conflict": {"type": "string"},
      "warning": {"type": "string"}, "hint": {"type": "string"},
      "error": {"type": "string"},
      "info": {"type": "string"}, "success": {"type": "string"}
    }},
    "terminal": {"type": "object", "properties": {
      "shell": {"type": "string"}, "fontFamily": {"type": "string"},
      "fontSize": {"type": "integer", "minimum": 6, "maximum": 48}
    }},
    "lsp": {"type": "object", "properties": {"command": {"type": "string"}}},
    "keymap": {"type": "array", "items": {"type": "object",
      "required": ["key", "command"], "properties": {
        "key": {"type": "string"}, "command": {"type": "string"}, "when": {"type": "string"}
      }}}
  }
  }

proc settingsPaths*(home: string): tuple[globalPath, workspaceName: string] =
  (home / "Library" / "Application Support" / "Nimculus" / "settings.json", ".nimculus" / "settings.json")

proc registerBuiltinThemes*(store: SettingsStore)
proc registerConfiguredThemes*(store: SettingsStore)

proc fileStamp(path: string): int64 =
  if path.len == 0 or not fileExists(path): return 0
  try:
    # mtime is only second-resolution on some macOS filesystems. Hash the
    # small configuration file content so same-second, same-length edits still
    # trigger the live reload boundary.
    int64(hash(readFile(path)))
  except CatchableError: 0

proc loadSettings*(globalPath, workspacePath: string; languageId = ""): NimculusSettings =
  var diagnostics: seq[SettingsDiagnostic]
  let global = loadJsonFile(globalPath, diagnostics)
  let workspace = loadJsonFile(workspacePath, diagnostics)
  result.values = mergeJson(global, workspace)
  if languageId.len > 0 and result.values.hasKey("languages") and
      result.values["languages"].kind == JObject and result.values["languages"].hasKey(languageId):
    result.values = mergeJson(result.values, result.values["languages"][languageId])
  result.diagnostics = diagnostics
  result.diagnostics.add(validateSettings(result.values))

proc newSettingsStore*(globalPath, workspacePath: string; languageId = ""): SettingsStore =
  new(result)
  result.globalPath = globalPath
  result.workspacePath = workspacePath
  result.languageId = languageId
  result.settings = loadSettings(globalPath, workspacePath, languageId)
  result.globalStamp = fileStamp(globalPath)
  result.workspaceStamp = fileStamp(workspacePath)
  result.themeRegistry = initTable[string, ThemeDefinition]()
  result.iconThemeRegistry = initTable[string, IconThemeDefinition]()
  result.registerBuiltinThemes()
  result.registerConfiguredThemes()

proc themeWithColors(name, appearance: string; colors: ThemeColors): ThemeDefinition =
  ThemeDefinition(name: name, appearance: appearance, colors: colors)

proc oneDarkTerminalPalette(): TerminalPalette =
  result.background = "#282c34"
  result.foreground = "#abb2bf"
  result.brightForeground = "#dce0e5"
  result.dimForeground = "#636d83"
  ## Zed exposes no separate cursor/selection tokens for the One theme. Keep
  ## those terminal affordances on terminal role colors rather than borrowing
  ## editor chrome: bright foreground for the cursor and dim foreground for a
  ## selection background.
  result.cursor = result.brightForeground
  result.selection = result.dimForeground
  result.normal = [
    "#282c34", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#abb2bf",
    "#636d83", "#EA858B", "#AAD581", "#FFD885", "#85C1FF", "#D398EB", "#6ED5DE", "#fafafa"
  ]
  result.bright = [
    "#636d83", "#EA858B", "#AAD581", "#FFD885", "#85C1FF", "#D398EB", "#6ED5DE", "#fafafa",
    "#636d83", "#EA858B", "#AAD581", "#FFD885", "#85C1FF", "#D398EB", "#6ED5DE", "#fafafa"
  ]
  result.dim = [
    "#3b3f4a", "#a7545a", "#6d8f59", "#b8985b", "#457cad", "#8d54a0", "#3c818a", "#8f969b",
    "#3b3f4a", "#a7545a", "#6d8f59", "#b8985b", "#457cad", "#8d54a0", "#3c818a", "#8f969b"
  ]

proc oneLightTerminalPalette(): TerminalPalette =
  result.background = "#fafafa"
  result.foreground = "#2a2c33"
  result.brightForeground = "#2a2c33"
  result.dimForeground = "#bbbbbb"
  result.cursor = result.brightForeground
  result.selection = result.dimForeground
  result.normal = [
    "#000000", "#de3e35", "#3f953a", "#d2b67c", "#2f5af3", "#950095", "#0997b3", "#bbbbbb",
    "#000000", "#de3e35", "#3f953a", "#d2b67c", "#2f5af3", "#a00095", "#0bbcd6", "#ffffff"
  ]
  result.bright = [
    "#000000", "#de3e35", "#3f953a", "#d2b67c", "#2f5af3", "#a00095", "#0bbcd6", "#ffffff",
    "#000000", "#de3e35", "#3f953a", "#d2b67c", "#2f5af3", "#a00095", "#0bbcd6", "#ffffff"
  ]
  result.dim = [
    "#555555", "#9c2b26", "#2b6927", "#a48c5a", "#2140ab", "#6a006a", "#0a7b92", "#888888",
    "#555555", "#9c2b26", "#2b6927", "#a48c5a", "#2140ab", "#6a006a", "#0a7b92", "#888888"
  ]

proc configuredTerminalArray(node: JsonNode; target: var array[16, string]) =
  if node == nil or node.kind != JArray: return
  for index in 0 ..< min(node.len, target.len):
    if node[index].kind == JString: target[index] = node[index].getStr

proc configuredTerminalPalette(node: JsonNode; fallback: TerminalPalette): TerminalPalette =
  result = fallback
  if node == nil or node.kind != JObject: return
  for key in ["background", "foreground", "brightForeground", "dimForeground", "cursor", "selection"]:
    if node.hasKey(key) and node[key].kind == JString:
      case key
      of "background": result.background = node[key].getStr
      of "foreground": result.foreground = node[key].getStr
      of "brightForeground": result.brightForeground = node[key].getStr
      of "dimForeground": result.dimForeground = node[key].getStr
      of "cursor": result.cursor = node[key].getStr
      of "selection": result.selection = node[key].getStr
      else: discard
  if node.hasKey("normal"): configuredTerminalArray(node["normal"], result.normal)
  if node.hasKey("bright"): configuredTerminalArray(node["bright"], result.bright)
  if node.hasKey("dim"): configuredTerminalArray(node["dim"], result.dim)

proc registerBuiltinThemes*(store: SettingsStore) =
  if store == nil: return
  var dark = ThemeColors(
    background: "#3b414d", foreground: "#dce0e5", accent: "#74ade8", selection: "#47679e",
    border: "#464b57", surface: "#2f343e", elevated: "#2f343e", panel: "#2f343e",
    element: "#2e343e",
    elementHover: "#363c46", elementActive: "#454a56", elementSelected: "#454a56",
    textMuted: "#a9afbc", textPlaceholder: "#878a98", textDisabled: "#878a98",
    textAccent: "#74ade8", borderVariant: "#363c46", borderFocused: "#47679e",
    borderSelected: "#293b5b", titleBar: "#3b414d", titleBarInactive: "#2e343e",
    toolbar: "#282c33", tabBar: "#2f343e", tabActive: "#282c33", tabInactive: "#2f343e",
    statusBar: "#3b414d", editor: "#282c33", editorForeground: "#acb2be", gutter: "#282c33",
    editorSubheader: "#2f343e", editorActiveLine: "#2f343ebf", scrollbarThumb: "#c8ccd44c",
    scrollbarHover: "#363c46", lineNumber: "#4e5a5f", activeLineNumber: "#d0d4da",
    hoverLineNumber: "#acb0b4", caret: "#74ade8", terminal: "#282c34", added: "#27a657",
    modified: "#d3b020",
    deleted: "#e06c76", ignored: "#878a98", conflict: "#dec184", warning: "#dec184",
    error: "#d07277", terminalPalette: oneDarkTerminalPalette(),
    info: "#74ade8", hint: "#788ca6", success: "#a1c181", syntax: %*{
      "keyword": {"color": "#b477cf", "fontWeight": 400},
      "string": {"color": "#a1c181", "fontWeight": 400},
      "comment": {"color": "#5d636f", "fontWeight": 400},
      "function": {"color": "#73ade9", "fontWeight": 400},
      "type": {"color": "#6eb4bf", "fontWeight": 400},
      "number": {"color": "#bf956a", "fontWeight": 400},
      "title": {"color": "#d07277", "fontWeight": 400},
      "emphasis.strong": {"color": "#bf956a", "fontWeight": 700}})
  var light = ThemeColors(
    background: "#dcdcdd", foreground: "#242529", accent: "#5c78e2", selection: "#7d82e8",
    border: "#c9c9ca", surface: "#ebebec", elevated: "#ebebec", panel: "#ebebec",
    element: "#ebebec",
    elementHover: "#dfdfe0", elementActive: "#cacaca", elementSelected: "#cacaca",
    textMuted: "#58585a", textPlaceholder: "#7e8086", textDisabled: "#7e8086",
    textAccent: "#5c78e2", borderVariant: "#dfdfe0", borderFocused: "#7d82e8",
    borderSelected: "#cbcdf6", titleBar: "#dcdcdd", titleBarInactive: "#ebebec",
    toolbar: "#fafafa", tabBar: "#ebebec", tabActive: "#fafafa", tabInactive: "#ebebec",
    statusBar: "#dcdcdd", editor: "#fafafa", editorForeground: "#242529", gutter: "#fafafa",
    editorSubheader: "#ebebec", editorActiveLine: "#ebebecbf", scrollbarThumb: "#383a414c",
    scrollbarHover: "#dfdfe0", lineNumber: "#b4b4bb", activeLineNumber: "#44454b",
    hoverLineNumber: "#61616b", caret: "#5c78e2", terminal: "#fafafa", added: "#27a657",
    modified: "#d3b020",
    deleted: "#e06c76", ignored: "#7e8086", conflict: "#a48819", warning: "#a48819",
    error: "#d36151", terminalPalette: oneLightTerminalPalette(),
    info: "#5c78e2", hint: "#7274a7", success: "#669f59", syntax: %*{
      "keyword": {"color": "#a449ab", "fontWeight": 400},
      "string": {"color": "#649f57", "fontWeight": 400},
      "comment": {"color": "#a2a3a7", "fontWeight": 400},
      "function": {"color": "#5b79e3", "fontWeight": 400},
      "type": {"color": "#3882b7", "fontWeight": 400},
      "number": {"color": "#ad6e25", "fontWeight": 400},
      "title": {"color": "#d3604f", "fontWeight": 400},
      "emphasis.strong": {"color": "#ad6e25", "fontWeight": 700}})
  store.themeRegistry["dark"] = themeWithColors("dark", "dark", dark)
  store.themeRegistry["light"] = themeWithColors("light", "light", light)
  # Keep the default tree legible without requiring a separately installed
  # icon font. These compact glyphs are intentionally text-safe (including in
  # the native NSTextView fallback) while still making common source and
  # document types visually distinguishable at a glance.
  var fileIcons = initTable[string, string]()
  for entry in [("nim", "◆"), ("md", "≡"), ("json", "{}"),
      ("toml", "⚙"), ("yaml", "≋"), ("yml", "≋"), ("rs", "R"),
      ("ts", "T"), ("tsx", "T"), ("js", "J"), ("jsx", "J"),
      ("py", "P"), ("c", "C"), ("h", "H"), ("cpp", "C"),
      ("hpp", "H"), ("sh", "$"), ("zsh", "$"), ("fish", "$"),
      ("html", "◇"), ("css", "#"), ("xml", "◇"), ("txt", "·")]:
    fileIcons[entry[0]] = entry[1]
  store.iconThemeRegistry["Nimculus Default"] = IconThemeDefinition(
    name: "Nimculus Default", directoryIcon: "▸", fileIcon: "•",
    fileIcons: fileIcons)

proc configuredThemeColors(node: JsonNode; fallback: ThemeColors): ThemeColors =
  result = fallback
  if node == nil or node.kind != JObject: return
  let colors = if node.hasKey("colors") and node["colors"].kind == JObject:
    node["colors"] else: node
  for key in ["background", "foreground", "accent", "selection", "border", "surface", "panel",
      "element", "elementHover", "elementActive", "elementSelected", "textMuted", "textPlaceholder",
      "textDisabled", "textAccent", "borderVariant", "borderFocused", "borderSelected", "titleBar",
      "titleBarInactive", "toolbar", "tabBar", "tabActive", "tabInactive", "statusBar", "editor",
      "gutter", "editorForeground", "editorSubheader", "editorActiveLine", "scrollbarThumb",
      "scrollbarHover",
      "lineNumber", "activeLineNumber", "hoverLineNumber", "caret", "elevated",
      "terminal",
      "added", "modified", "deleted", "ignored", "conflict", "warning", "hint", "error", "info", "success"]:
    if colors.hasKey(key) and colors[key].kind == JString:
      case key
      of "background": result.background = colors[key].getStr
      of "foreground": result.foreground = colors[key].getStr
      of "accent": result.accent = colors[key].getStr
      of "selection": result.selection = colors[key].getStr
      of "border": result.border = colors[key].getStr
      of "surface": result.surface = colors[key].getStr
      of "elevated": result.elevated = colors[key].getStr
      of "panel": result.panel = colors[key].getStr
      of "element": result.element = colors[key].getStr
      of "elementHover": result.elementHover = colors[key].getStr
      of "elementActive": result.elementActive = colors[key].getStr
      of "elementSelected": result.elementSelected = colors[key].getStr
      of "textMuted": result.textMuted = colors[key].getStr
      of "textPlaceholder": result.textPlaceholder = colors[key].getStr
      of "textDisabled": result.textDisabled = colors[key].getStr
      of "textAccent": result.textAccent = colors[key].getStr
      of "borderVariant": result.borderVariant = colors[key].getStr
      of "borderFocused": result.borderFocused = colors[key].getStr
      of "borderSelected": result.borderSelected = colors[key].getStr
      of "titleBar": result.titleBar = colors[key].getStr
      of "titleBarInactive": result.titleBarInactive = colors[key].getStr
      of "toolbar": result.toolbar = colors[key].getStr
      of "tabBar": result.tabBar = colors[key].getStr
      of "tabActive": result.tabActive = colors[key].getStr
      of "tabInactive": result.tabInactive = colors[key].getStr
      of "statusBar": result.statusBar = colors[key].getStr
      of "editor": result.editor = colors[key].getStr
      of "editorForeground": result.editorForeground = colors[key].getStr
      of "gutter": result.gutter = colors[key].getStr
      of "editorSubheader": result.editorSubheader = colors[key].getStr
      of "editorActiveLine": result.editorActiveLine = colors[key].getStr
      of "scrollbarThumb": result.scrollbarThumb = colors[key].getStr
      of "scrollbarHover": result.scrollbarHover = colors[key].getStr
      of "lineNumber": result.lineNumber = colors[key].getStr
      of "activeLineNumber": result.activeLineNumber = colors[key].getStr
      of "hoverLineNumber": result.hoverLineNumber = colors[key].getStr
      of "caret": result.caret = colors[key].getStr
      of "terminal": result.terminal = colors[key].getStr
      of "added": result.added = colors[key].getStr
      of "modified": result.modified = colors[key].getStr
      of "deleted": result.deleted = colors[key].getStr
      of "ignored": result.ignored = colors[key].getStr
      of "conflict": result.conflict = colors[key].getStr
      of "warning": result.warning = colors[key].getStr
      of "hint": result.hint = colors[key].getStr
      of "error": result.error = colors[key].getStr
      of "info": result.info = colors[key].getStr
      of "success": result.success = colors[key].getStr
      else: discard
  if colors.hasKey("syntax") and colors["syntax"].kind == JObject: result.syntax = colors["syntax"]
  if colors.hasKey("terminalPalette"):
    result.terminalPalette = configuredTerminalPalette(colors["terminalPalette"],
        result.terminalPalette)

proc registerConfiguredThemes*(store: SettingsStore) =
  if store == nil: return
  let themes = nodeAt(store.settings.values, "themes")
  if themes != nil and themes.kind == JObject:
    for name, node in themes:
      let fallback = store.themeRegistry.getOrDefault("dark").colors
      let colors = configuredThemeColors(node, fallback)
      let appearance = if node.kind == JObject: jsonStringAt(node, "appearance",
          "dark") else: "dark"
      store.themeRegistry[name] = themeWithColors(name, appearance, colors)
  let iconThemes = nodeAt(store.settings.values, "iconThemes")
  if iconThemes != nil and iconThemes.kind == JObject:
    for name, node in iconThemes:
      if node.kind != JObject: continue
      var definition = IconThemeDefinition(name: name,
        directoryIcon: jsonStringAt(node, "directory", "▸"),
        fileIcon: jsonStringAt(node, "file", "•"),
        fileIcons: initTable[string, string]())
      let files = if node.hasKey("fileIcons") and node["fileIcons"].kind == JObject:
        node["fileIcons"] else: nil
      if files != nil:
        for extension, icon in files:
          if icon.kind == JString: definition.fileIcons[extension.toLowerAscii] = icon.getStr
      store.iconThemeRegistry[name] = definition

proc reload*(store: SettingsStore): bool =
  if store == nil: return false
  let globalStamp = fileStamp(store.globalPath)
  let workspaceStamp = fileStamp(store.workspacePath)
  if globalStamp == store.globalStamp and workspaceStamp == store.workspaceStamp: return false
  store.settings = loadSettings(store.globalPath, store.workspacePath, store.languageId)
  store.themeRegistry.clear()
  store.iconThemeRegistry.clear()
  store.registerBuiltinThemes()
  store.registerConfiguredThemes()
  store.globalStamp = globalStamp
  store.workspaceStamp = workspaceStamp
  true

proc setLanguageId*(store: SettingsStore, languageId: string): bool =
  ## A document language change must rebuild the merged snapshot even when no
  ## settings file changed. This also removes overlays from the prior language.
  if store == nil or store.languageId == languageId: return false
  store.languageId = languageId
  store.settings = loadSettings(store.globalPath, store.workspacePath, languageId)
  store.themeRegistry.clear()
  store.iconThemeRegistry.clear()
  store.registerBuiltinThemes()
  store.registerConfiguredThemes()
  true

proc values*(store: SettingsStore): JsonNode =
  if store != nil: store.settings.values else: objectNode()

proc stringSetting*(store: SettingsStore, path: string; fallback = ""): string =
  jsonStringAt(store.values, path, fallback)

proc intSetting*(store: SettingsStore, path: string, fallback: int): int =
  jsonIntAt(store.values, path, fallback)

proc boolSetting*(store: SettingsStore, path: string, fallback: bool): bool =
  jsonBoolAt(store.values, path, fallback)

proc diagnostics*(store: SettingsStore): seq[SettingsDiagnostic] =
  if store != nil: result = store.settings.diagnostics

proc keyBindings*(store: SettingsStore): seq[KeyBinding] =
  let value = nodeAt(store.values, "keymap")
  if value == nil or value.kind != JArray: return
  for item in value:
    if item.kind != JObject or not item.hasKey("key") or not item.hasKey("command") or
        item["key"].kind != JString or item["command"].kind != JString: continue
    if item.hasKey("when") and item["when"].kind != JString: continue
    result.add(KeyBinding(key: item["key"].getStr, command: item["command"].getStr,
      whenClause: if item.hasKey("when"): item["when"].getStr else: ""))

proc theme*(store: SettingsStore): ThemeColors =
  let requested = store.stringSetting("theme", "dark")
  let selected = if store != nil and store.themeRegistry.hasKey(requested): requested
    elif store != nil and store.themeRegistry.hasKey(requested.toLowerAscii): requested.toLowerAscii
    else: "dark"
  let definition = store.themeRegistry.getOrDefault(selected)
  result = definition.colors
  let overrides = nodeAt(store.values, "themeColors")
  if overrides != nil and overrides.kind == JObject:
    result = configuredThemeColors(overrides, result)

proc resolvedTheme*(store: SettingsStore, systemDark: bool): ThemeColors =
  ## Resolve the system theme at the settings boundary so a platform appearance
  ## notification can repaint without reloading settings from disk.
  result = store.theme()
  let requested = store.stringSetting("theme", "dark").toLowerAscii
  let customBackground = store.stringSetting("themeColors.background", "")
  if customBackground.len > 0 or requested notin ["light", "dark", "system"]: return
  let dark = if requested == "system": systemDark else: requested == "dark"
  result = store.themeRegistry[if dark: "dark" else: "light"].colors

proc themePaletteJson*(colors: ThemeColors): string =
  ## Serialize semantic roles for the native renderer. Keeping this boundary
  ## data-driven lets AppKit and Metal consume the same theme without
  ## duplicating color defaults in Objective-C.
  $(%*{
    "background": colors.background, "foreground": colors.foreground,
    "accent": colors.accent, "selection": colors.selection, "border": colors.border,
    "surface": colors.surface, "elevated": colors.elevated, "panel": colors.panel,
    "element": colors.element,
    "elementHover": colors.elementHover, "elementActive": colors.elementActive,
    "elementSelected": colors.elementSelected, "textMuted": colors.textMuted,
    "textPlaceholder": colors.textPlaceholder, "textDisabled": colors.textDisabled,
    "textAccent": colors.textAccent, "borderVariant": colors.borderVariant,
    "borderFocused": colors.borderFocused, "borderSelected": colors.borderSelected,
    "titleBar": colors.titleBar, "titleBarInactive": colors.titleBarInactive,
    "toolbar": colors.toolbar, "tabBar": colors.tabBar, "tabActive": colors.tabActive,
    "tabInactive": colors.tabInactive, "statusBar": colors.statusBar,
    "editor": colors.editor, "editorForeground": colors.editorForeground, "gutter": colors.gutter,
    "editorSubheader": colors.editorSubheader,
    "editorActiveLine": colors.editorActiveLine, "scrollbarThumb": colors.scrollbarThumb,
    "scrollbarHover": colors.scrollbarHover, "lineNumber": colors.lineNumber,
    "activeLineNumber": colors.activeLineNumber, "hoverLineNumber": colors.hoverLineNumber,
    "caret": colors.caret, "syntax": colors.syntax, "terminal": colors.terminal,
    "terminalPalette": {
      "background": colors.terminalPalette.background,
      "foreground": colors.terminalPalette.foreground,
      "brightForeground": colors.terminalPalette.brightForeground,
      "dimForeground": colors.terminalPalette.dimForeground,
      "cursor": colors.terminalPalette.cursor,
      "selection": colors.terminalPalette.selection,
      "normal": colors.terminalPalette.normal,
      "bright": colors.terminalPalette.bright,
      "dim": colors.terminalPalette.dim
    },
    "added": colors.added, "modified": colors.modified, "deleted": colors.deleted,
    "ignored": colors.ignored,
    "conflict": colors.conflict, "warning": colors.warning, "hint": colors.hint,
    "error": colors.error,
    "info": colors.info, "success": colors.success
  })

proc themeNames*(store: SettingsStore): seq[string] =
  if store == nil: return
  for name in store.themeRegistry.keys: result.add(name)
  result.sort()

proc iconThemeName*(store: SettingsStore): string =
  let requested = store.stringSetting("iconTheme", "Nimculus Default")
  if store != nil and store.iconThemeRegistry.hasKey(requested): requested else: "Nimculus Default"

proc iconForPath*(store: SettingsStore, path: string; directory = false): string =
  if directory: return store.iconThemeRegistry[store.iconThemeName()].directoryIcon
  let theme = store.iconThemeRegistry[store.iconThemeName()]
  let extension = splitFile(path).ext.strip(chars = {'.'}).toLowerAscii
  if extension.len > 0 and theme.fileIcons.hasKey(extension): return theme.fileIcons[extension]
  theme.fileIcon
