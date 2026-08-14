import std/json
import std/hashes
import std/os
import std/options
import std/strutils
import std/tables
import std/algorithm
import std/times

type
  SettingsDiagnostic* = object
    path*: string
    message*: string

  KeyBinding* = object
    key*: string
    command*: string
    whenClause*: string

  EditorFontFeature* = object
    tag*: string
    enabled*: bool

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
    scrollbarTrackBorder*: string
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

  UiColor* = enum
    ## Semantic colors consumed by the native UI. The three abbreviated arms
    ## preserve the names used by the AppKit role aliases.
    uiBackground, uiForeground, uiAccent, uiSelection, uiBorder, uiSurface,
    uiElevated, uiPanel, uiElement, uiElementHover, uiElementActive,
    uiElementSelected, uiTextMuted, uiTextPlaceholder, uiTextDisabled,
    uiTextAccent, uiBorderVariant, uiBorderFocused, uiBorderSelected,
    uiTitleBar, uiTitleBarInactive, uiToolbar, uiTabBar, uiTabActive,
    uiTabInactive, uiStatusBar, uiEditor, uiEditorForeground, uiGutter,
    uiEditorSubheader, uiEditorActiveLine, uiScrollbarThumb,
    uiScrollbarTrackBorder, uiScrollbarHover, uiLineNumber, uiActiveLineNumber,
    uiHoverLineNumber, uiCaret, uiTerminal, uiAdded, uiModified, uiDeleted,
    uiIgnored, uiConflict, uiWarning, uiHint, uiError, uiInfo, uiSuccess,
    uiChromeBg, uiFgPrimary, uiFgMuted

  ThemeDefinition* = object
    name*: string
    appearance*: string
    colors*: ThemeColors

  IconThemeDefinition* = object
    name*: string
    directoryIcon*: string
    fileIcon*: string
    fileIcons*: Table[string, string]

  Density* = enum
    compact, default, comfortable

  SpacingStep* = enum
    Base00, Base01, Base02, Base03, Base04, Base06, Base08, Base12,
    Base16, Base20, Base24, Base32, Base40, Base48

  ## Zed's density-aware spacing values, in compact/default/comfortable order.
  ## The single-value entries in Zed's table are already expanded here at the
  ## default 16px rem size, which is the native UI's base size.
  NimculusSettings* = object
    values*: JsonNode
    diagnostics*: seq[SettingsDiagnostic]
    uiDensity*: Density

  SettingsStore* = ref object
    globalPath*: string
    workspacePath*: string
    languageId*: string
    globalStamp*: int64
    workspaceStamp*: int64
    settings*: NimculusSettings
    themeRegistry*: Table[string, ThemeDefinition]
    iconThemeRegistry*: Table[string, IconThemeDefinition]

  SettingKind* = enum
    settingBool, settingInt, settingString, settingFloat

  SettingDescriptor* = object
    key*: string
    kind*: SettingKind
    default*: JsonNode
    title*: string

const spacingTable*: array[SpacingStep, array[Density, float32]] = [
  [0'f32, 0'f32, 0'f32],
  [1'f32, 1'f32, 2'f32],
  [1'f32, 2'f32, 4'f32],
  [2'f32, 3'f32, 4'f32],
  [2'f32, 4'f32, 6'f32],
  [3'f32, 6'f32, 8'f32],
  [4'f32, 8'f32, 10'f32],
  [10'f32, 12'f32, 14'f32],
  [14'f32, 16'f32, 18'f32],
  [18'f32, 20'f32, 22'f32],
  [20'f32, 24'f32, 28'f32],
  [28'f32, 32'f32, 36'f32],
  [36'f32, 40'f32, 44'f32],
  [44'f32, 48'f32, 52'f32]
]

proc px*(step: SpacingStep, d: Density): float32 =
  spacingTable[step][d]

proc nimculus_spacing_px*(step, density: cint): cfloat {.exportc, dynlib, cdecl.} =
  ## C bridge used by native presenters. The native side passes the Zed
  ## density ordinal (compact/default/comfortable).
  if step < 0 or step > cint(ord(SpacingStep.high)) or
      density < 0 or density > cint(ord(Density.high)):
    return 0'f32
  cfloat(px(SpacingStep(step), Density(density)))

proc color*(c: UiColor, theme: ThemeColors): string =
  ## Resolve one semantic UI color from the selected theme.
  ## Keep this case exhaustive: adding a UiColor requires a theme mapping.
  case c
  of uiBackground: theme.background
  of uiForeground: theme.foreground
  of uiAccent: theme.accent
  of uiSelection: theme.selection
  of uiBorder: theme.border
  of uiSurface: theme.surface
  of uiElevated: theme.elevated
  of uiPanel: theme.panel
  of uiElement: theme.element
  of uiElementHover: theme.elementHover
  of uiElementActive: theme.elementActive
  of uiElementSelected: theme.elementSelected
  of uiTextMuted: theme.textMuted
  of uiTextPlaceholder: theme.textPlaceholder
  of uiTextDisabled: theme.textDisabled
  of uiTextAccent: theme.textAccent
  of uiBorderVariant: theme.borderVariant
  of uiBorderFocused: theme.borderFocused
  of uiBorderSelected: theme.borderSelected
  of uiTitleBar: theme.titleBar
  of uiTitleBarInactive: theme.titleBarInactive
  of uiToolbar: theme.toolbar
  of uiTabBar: theme.tabBar
  of uiTabActive: theme.tabActive
  of uiTabInactive: theme.tabInactive
  of uiStatusBar: theme.statusBar
  of uiEditor: theme.editor
  of uiEditorForeground: theme.editorForeground
  of uiGutter: theme.gutter
  of uiEditorSubheader: theme.editorSubheader
  of uiEditorActiveLine: theme.editorActiveLine
  of uiScrollbarThumb: theme.scrollbarThumb
  of uiScrollbarTrackBorder: theme.scrollbarTrackBorder
  of uiScrollbarHover: theme.scrollbarHover
  of uiLineNumber: theme.lineNumber
  of uiActiveLineNumber: theme.activeLineNumber
  of uiHoverLineNumber: theme.hoverLineNumber
  of uiCaret: theme.caret
  of uiTerminal: theme.terminal
  of uiAdded: theme.added
  of uiModified: theme.modified
  of uiDeleted: theme.deleted
  of uiIgnored: theme.ignored
  of uiConflict: theme.conflict
  of uiWarning: theme.warning
  of uiHint: theme.hint
  of uiError: theme.error
  of uiInfo: theme.info
  of uiSuccess: theme.success
  of uiChromeBg: theme.titleBar
  of uiFgPrimary: theme.foreground
  of uiFgMuted: theme.textMuted

let settingDescriptors* = @[
  SettingDescriptor(key: "statusBar.showActiveFile", kind: settingBool,
    default: newJBool(false), title: "Show Active File"),
  SettingDescriptor(key: "statusBar.activeLanguageButton", kind: settingBool,
    default: newJBool(true), title: "Show Active Language"),
  SettingDescriptor(key: "statusBar.cursorPositionButton", kind: settingBool,
    default: newJBool(true), title: "Show Cursor Position"),
  SettingDescriptor(key: "statusBar.lineEndingsButton", kind: settingBool,
    default: newJBool(false), title: "Show Line Endings"),
  SettingDescriptor(key: "statusBar.activeEncodingButton", kind: settingString,
    default: newJString("non_utf8"), title: "Encoding Display"),
  SettingDescriptor(key: "editor.fontSize", kind: settingInt,
    default: newJInt(15), title: "Editor Font Size"),
  SettingDescriptor(key: "editor.tabSize", kind: settingInt,
    default: newJInt(2), title: "Tab Size"),
  SettingDescriptor(key: "editor.fontFamily", kind: settingString,
    default: newJString(".ZedMono"), title: "Editor Font Family"),
  SettingDescriptor(key: "terminal.fontSize", kind: settingInt,
    default: newJInt(15), title: "Terminal Font Size"),
  SettingDescriptor(key: "terminal.fontFamily", kind: settingString,
    default: newJString(".ZedMono"), title: "Terminal Font Family"),
  SettingDescriptor(key: "terminal.shell", kind: settingString,
    default: newJString("/bin/zsh"), title: "Terminal Shell"),
  SettingDescriptor(key: "terminal.dock", kind: settingString,
    default: newJString("bottom"), title: "Terminal Dock"),
  SettingDescriptor(key: "terminal.scroll_multiplier", kind: settingFloat,
    default: newJFloat(1.0), title: "Terminal Scroll Multiplier"),
  SettingDescriptor(key: "projectPanel.dock", kind: settingString,
    default: newJString("right"), title: "Project Panel Dock"),
  SettingDescriptor(key: "projectPanel.startsOpen", kind: settingBool,
    default: newJBool(true), title: "Project Panel Starts Open"),
  SettingDescriptor(key: "projectPanel.starts_open", kind: settingBool,
    default: newJBool(true), title: "Project Panel Starts Open (Legacy)"),
  SettingDescriptor(key: "outlinePanel.dock", kind: settingString,
    default: newJString("right"), title: "Outline Panel Dock"),
  SettingDescriptor(key: "gitPanel.dock", kind: settingString,
    default: newJString("right"), title: "Git Panel Dock"),
  SettingDescriptor(key: "agent.dock", kind: settingString,
    default: newJString("left"), title: "Agent Dock"),
  SettingDescriptor(key: "agent.disabled", kind: settingBool,
    default: newJBool(false), title: "Disable Agent"),
  SettingDescriptor(key: "debugger.dock", kind: settingString,
    default: newJString("bottom"), title: "Debugger Dock"),
  SettingDescriptor(key: "diagnostics.button", kind: settingBool,
    default: newJBool(true), title: "Diagnostics Button"),
  SettingDescriptor(key: "search.button", kind: settingBool,
    default: newJBool(true), title: "Search Button"),
  SettingDescriptor(key: "git.inlineBlame.enabled", kind: settingBool,
    default: newJBool(true), title: "Inline Blame"),
  SettingDescriptor(key: "git.inlineBlame.location", kind: settingString,
    default: newJString("inline"), title: "Inline Blame Location"),
  SettingDescriptor(key: "git.inlineBlame.showCommitSummary", kind: settingBool,
    default: newJBool(false), title: "Inline Blame Commit Summary"),
  SettingDescriptor(key: "git.inlineBlame.delayMs", kind: settingInt,
    default: newJInt(0), title: "Inline Blame Delay"),
  SettingDescriptor(key: "git.inlineBlame.padding", kind: settingInt,
    default: newJInt(7), title: "Inline Blame Padding"),
  SettingDescriptor(key: "git.inlineBlame.minColumn", kind: settingInt,
    default: newJInt(0), title: "Inline Blame Minimum Column"),
  SettingDescriptor(key: "soft_wrap", kind: settingString,
    default: newJString("none"), title: "Soft Wrap"),
  SettingDescriptor(key: "scroll_sensitivity", kind: settingFloat,
    default: newJFloat(1.0), title: "Scroll Sensitivity"),
  SettingDescriptor(key: "fast_scroll_sensitivity", kind: settingFloat,
    default: newJFloat(4.0), title: "Fast Scroll Sensitivity"),
  SettingDescriptor(key: "ui_density", kind: settingString,
    default: newJString("default"), title: "UI Density"),
  SettingDescriptor(key: "theme", kind: settingString,
    default: newJString("dark"), title: "Theme"),
  SettingDescriptor(key: "iconTheme", kind: settingString,
    default: newJString("Nimculus Default"), title: "Icon Theme"),
  SettingDescriptor(key: "themeColors.background", kind: settingString,
    default: newJString(""), title: "Theme Background"),
  SettingDescriptor(key: "themeColors.accent", kind: settingString,
    default: newJString(""), title: "Theme Accent"),
  SettingDescriptor(key: "lsp.command", kind: settingString,
    default: newJString(""), title: "LSP Command")
]

proc settingDescriptor*(key: string): SettingDescriptor =
  for descriptor in settingDescriptors:
    if descriptor.key == key: return descriptor
  when not defined(release):
    raise newException(KeyError, "Unknown setting key: " & key)
  else:
    result = SettingDescriptor(key: key)

proc settingDefaultBool(key: string): bool = settingDescriptor(key).default.getBool
proc settingDefaultString(key: string): string = settingDescriptor(key).default.getStr

proc requireSettingKind(key: string, expected: SettingKind): SettingDescriptor =
  result = settingDescriptor(key)
  when not defined(release):
    if result.kind != expected:
      raise newException(ValueError, "Setting kind mismatch for " & key)

proc softWrapEnabledForPath*(path, configuredMode: string): bool =
  ## Zed's global default is `none`, but Markdown has a language-scoped
  ## `editor_width` default. Preserve that distinction at the settings edge.
  if configuredMode in ["editor_width", "bounded"]: return true
  if configuredMode != settingDefaultString("soft_wrap"): return false
  splitFile(path).ext.toLowerAscii in [".md", ".markdown"]

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

proc densityAt(root: JsonNode): Density =
  let node = nodeAt(root, "ui_density")
  if node == nil or node.kind != JString: return Density.default
  case node.getStr
  of "compact": compact
  of "comfortable": comfortable
  else: Density.default

proc jsonStringAt(root: JsonNode, path: string, fallback = ""): string =
  let node = nodeAt(root, path)
  if node != nil and node.kind == JString: return node.getStr
  fallback

proc jsonIntAt*(root: JsonNode, path: string, fallback: int): int =
  let node = nodeAt(root, path)
  if node != nil and node.kind == JInt: return node.getInt
  fallback

proc jsonFloatAt*(root: JsonNode, path: string, fallback: float32): float32 =
  let node = nodeAt(root, path)
  if node == nil: return fallback
  case node.kind
  of JInt: float32(node.getInt)
  of JFloat: float32(node.getFloat)
  else: fallback

proc jsonBoolAt*(root: JsonNode, path: string, fallback: bool): bool =
  let node = nodeAt(root, path)
  if node != nil and node.kind == JBool: return node.getBool
  fallback

proc validFeatureTag(tag: string): bool =
  if tag.len != 4: return false
  for character in tag:
    if ord(character) > 127: return false
  true

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
  let uiDensity = nodeAt(root, "ui_density")
  if uiDensity != nil and (uiDensity.kind != JString or
      uiDensity.getStr notin ["compact", "default", "comfortable"]):
    result.add(SettingsDiagnostic(path: "ui_density",
      message: "must be one of: compact, default, comfortable"))
  for key in ["scroll_sensitivity", "fast_scroll_sensitivity", "terminal.scroll_multiplier"]:
    let value = nodeAt(root, key)
    if value != nil and value.kind notin {JInt, JFloat}:
      result.add(SettingsDiagnostic(path: key, message: "must be a number"))
  let insertSpaces = nodeAt(root, "editor.insertSpaces")
  if insertSpaces != nil and insertSpaces.kind != JBool:
    result.add(SettingsDiagnostic(path: "editor.insertSpaces", message: "must be a boolean"))
  for key in ["git.inlineBlame.enabled", "git.inlineBlame.showCommitSummary"]:
    let value = nodeAt(root, key)
    if value != nil and value.kind != JBool:
      result.add(SettingsDiagnostic(path: key, message: "must be a boolean"))
  for key in ["git.inlineBlame.delayMs", "git.inlineBlame.padding", "git.inlineBlame.minColumn"]:
    let value = nodeAt(root, key)
    if value != nil and value.kind != JInt:
      result.add(SettingsDiagnostic(path: key, message: "must be an integer"))
    elif value != nil and value.getInt < 0:
      result.add(SettingsDiagnostic(path: key, message: "must be non-negative"))
  let inlineBlameLocation = nodeAt(root, "git.inlineBlame.location")
  if inlineBlameLocation != nil and (inlineBlameLocation.kind != JString or
      inlineBlameLocation.getStr notin ["inline", "status_bar"]):
    result.add(SettingsDiagnostic(path: "git.inlineBlame.location",
      message: "must be one of: inline, status_bar"))
  for key in ["projectPanel.startsOpen", "projectPanel.starts_open", "agent.disabled"]:
    let value = nodeAt(root, key)
    if value != nil and value.kind != JBool:
      result.add(SettingsDiagnostic(path: key, message: "must be a boolean"))
  for setting in [
      (path: "projectPanel.dock", allowed: @[
        "left", "bottom", "right"]),
      (path: "outlinePanel.dock", allowed: @[
        "left", "bottom", "right"]),
      (path: "gitPanel.dock", allowed: @[
        "left", "bottom", "right"]),
      (path: "agent.dock", allowed: @[
        "left", "bottom", "right"]),
      (path: "terminal.dock", allowed: @[
        "left", "bottom", "right"]),
      (path: "debugger.dock", allowed: @[
        "left", "bottom", "right"])]:
    let value = nodeAt(root, setting.path)
    if value != nil and (value.kind != JString or value.getStr notin setting.allowed):
      result.add(SettingsDiagnostic(path: setting.path,
        message: "must be one of: " & setting.allowed.join(", ")))
  for key in ["statusBar.showActiveFile", "statusBar.activeLanguageButton",
      "statusBar.cursorPositionButton", "statusBar.lineEndingsButton",
      "diagnostics.button", "search.button"]:
    let value = nodeAt(root, key)
    if value != nil and value.kind != JBool:
      result.add(SettingsDiagnostic(path: key, message: "must be a boolean"))
  let activeEncodingButton = nodeAt(root, "statusBar.activeEncodingButton")
  if activeEncodingButton != nil:
    if activeEncodingButton.kind != JString:
      result.add(SettingsDiagnostic(path: "statusBar.activeEncodingButton",
        message: "must be one of: enabled, non_utf8, disabled"))
    elif activeEncodingButton.getStr notin ["enabled", "non_utf8", "disabled"]:
      result.add(SettingsDiagnostic(path: "statusBar.activeEncodingButton",
        message: "must be one of: enabled, non_utf8, disabled"))
  let fontFeatures = nodeAt(root, "editor.fontFeatures")
  if fontFeatures != nil:
    if fontFeatures.kind != JObject:
      result.add(SettingsDiagnostic(path: "editor.fontFeatures", message: "must be an object"))
    else:
      for tag, value in fontFeatures:
        if not validFeatureTag(tag):
          result.add(SettingsDiagnostic(path: "editor.fontFeatures." & tag,
            message: "feature tags must be four ASCII characters"))
        elif value.kind != JBool:
          result.add(SettingsDiagnostic(path: "editor.fontFeatures." & tag,
            message: "must be a boolean"))
  let fontFallbacks = nodeAt(root, "editor.fontFallbacks")
  if fontFallbacks != nil:
    if fontFallbacks.kind != JArray:
      result.add(SettingsDiagnostic(path: "editor.fontFallbacks", message: "must be an array"))
    else:
      for index in 0 ..< fontFallbacks.len:
        let fallback = fontFallbacks[index]
        if fallback.kind != JString or fallback.getStr.len == 0:
          result.add(SettingsDiagnostic(path: "editor.fontFallbacks[" & $index & "]",
            message: "must be a non-empty string"))
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

proc applySettingDefaults(schema: JsonNode) =
  for descriptor in settingDescriptors:
    var node = schema
    var found = true
    for part in descriptor.key.split('.'):
      if node == nil or node.kind != JObject or not node.hasKey("properties") or
          not node["properties"].hasKey(part):
        found = false
        break
      node = node["properties"][part]
    if found and node != nil and node.kind == JObject:
      node["default"] = descriptor.default.copy()

proc settingsSchema*(): JsonNode =
  ## Stable schema consumed by editors and future settings UI completion.
  result = %*{
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "type": "object",
    "properties": {
      "editor": {"type": "object", "properties": {
        "fontSize": {"type": "integer", "minimum": 6, "maximum": 96},
        "fontFamily": {"type": "string"},
        "fontFeatures": {"type": "object", "additionalProperties": {"type": "boolean"}},
        "fontFallbacks": {"type": "array", "items": {"type": "string"}},
        "tabSize": {"type": "integer", "minimum": 1, "maximum": 16},
        "insertSpaces": {"type": "boolean"}
    }},
    "projectPanel": {"type": "object", "properties": {
      "dock": {"type": "string", "enum": ["left", "bottom", "right"]},
      "startsOpen": {"type": "boolean"},
      "starts_open": {"type": "boolean"}
    }},
    "outlinePanel": {"type": "object", "properties": {
      "dock": {"type": "string", "enum": ["left", "bottom", "right"]}
    }},
    "gitPanel": {"type": "object", "properties": {
      "dock": {"type": "string", "enum": ["left", "bottom", "right"]}
    }},
    "agent": {"type": "object", "properties": {
      "dock": {"type": "string", "enum": ["left", "bottom", "right"]},
      "disabled": {"type": "boolean"}
    }},
    "statusBar": {"type": "object", "properties": {
      "showActiveFile": {"type": "boolean"},
      "activeLanguageButton": {"type": "boolean"},
      "cursorPositionButton": {"type": "boolean"},
      "lineEndingsButton": {"type": "boolean"},
      "activeEncodingButton": {"type": "string",
        "enum": ["enabled", "non_utf8", "disabled"]}
    }},
    "diagnostics": {"type": "object", "properties": {
      "button": {"type": "boolean"}
    }},
    "search": {"type": "object", "properties": {
      "button": {"type": "boolean"}
    }},
    "git": {"type": "object", "properties": {
      "inlineBlame": {"type": "object", "properties": {
        "enabled": {"type": "boolean"},
        "location": {"type": "string", "enum": ["inline", "status_bar"],
      },
        "showCommitSummary": {"type": "boolean"},
        "delayMs": {"type": "integer", "minimum": 0},
        "padding": {"type": "integer", "minimum": 0},
        "minColumn": {"type": "integer", "minimum": 0}
      }}
    }},
    "theme": {"type": "string"},
    "soft_wrap": {"type": "string", "enum": ["none", "editor_width", "bounded"]},
    "scroll_sensitivity": {"type": "number"},
    "fast_scroll_sensitivity": {"type": "number"},
    "ui_density": {"type": "string", "enum": ["compact", "default", "comfortable"]},
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
      "scrollbarTrackBorder": {"type": "string"},
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
      "fontSize": {"type": "integer", "minimum": 6, "maximum": 48},
      "dock": {"type": "string", "enum": ["left", "bottom", "right"]},
      "scroll_multiplier": {"type": "number"}
    }},
    "debugger": {"type": "object", "properties": {
      "dock": {"type": "string", "enum": ["left", "bottom", "right"]}
    }},
    "lsp": {"type": "object", "properties": {"command": {"type": "string"}}},
    "keymap": {"type": "array", "items": {"type": "object",
      "required": ["key", "command"], "properties": {
        "key": {"type": "string"}, "command": {"type": "string"}, "when": {"type": "string"}
      }}}
  }
  }
  applySettingDefaults(result)

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
  result.uiDensity = densityAt(result.values)

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
    scrollbarTrackBorder: "#2e333c",
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
    scrollbarTrackBorder: "#eeeeee",
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
      "scrollbarTrackBorder",
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
      of "scrollbarTrackBorder": result.scrollbarTrackBorder = colors[key].getStr
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

proc stringSetting*(store: SettingsStore, path: string): string =
  let descriptor = requireSettingKind(path, settingString)
  jsonStringAt(store.values, path, descriptor.default.getStr)

proc normalizedDockSetting(store: SettingsStore, path: string,
                           allowed: openArray[string]): string =
  let value = store.stringSetting(path)
  if value in allowed: value else: settingDefaultString(path)

proc projectPanelDock*(store: SettingsStore): string =
  store.normalizedDockSetting("projectPanel.dock", ["left", "bottom", "right"])

proc outlinePanelDock*(store: SettingsStore): string =
  store.normalizedDockSetting("outlinePanel.dock", ["left", "bottom", "right"])

proc gitPanelDock*(store: SettingsStore): string =
  store.normalizedDockSetting("gitPanel.dock", ["left", "bottom", "right"])

proc agentDock*(store: SettingsStore): string =
  store.normalizedDockSetting("agent.dock", ["left", "bottom", "right"])

proc terminalDock*(store: SettingsStore): string =
  store.normalizedDockSetting("terminal.dock", ["left", "bottom", "right"])

proc debuggerDock*(store: SettingsStore): string =
  store.normalizedDockSetting("debugger.dock", ["left", "bottom", "right"])

proc softWrapMode*(store: SettingsStore): string =
  ## Zed's factory default is the explicit string "none". Keep the setting
  ## value visible at the settings boundary instead of inferring it from a
  ## boolean view default.
  let mode = store.stringSetting("soft_wrap")
  if mode in ["none", "editor_width", "bounded"]: mode else: settingDefaultString("soft_wrap")

proc themeForSettingsPanel*(store: SettingsStore): string =
  ## The panel uses `system` as its display-only value when no theme is configured.
  if nodeAt(store.values, "theme") == nil: "system"
  else: store.stringSetting("theme")

proc intSetting*(store: SettingsStore, path: string): int =
  let descriptor = requireSettingKind(path, settingInt)
  jsonIntAt(store.values, path, descriptor.default.getInt)

proc floatSetting*(store: SettingsStore, path: string): float32 =
  let descriptor = requireSettingKind(path, settingFloat)
  jsonFloatAt(store.values, path, float32(descriptor.default.getFloat))

const
  MinimumScrollSensitivity* = 0.01'f32

proc editorScrollSensitivity*(store: SettingsStore, fast: bool): float32 =
  let path = if fast: "fast_scroll_sensitivity" else: "scroll_sensitivity"
  max(MinimumScrollSensitivity, store.floatSetting(path))

proc terminalScrollMultiplier*(store: SettingsStore): float32 =
  max(MinimumScrollSensitivity, store.floatSetting("terminal.scroll_multiplier"))

proc boolSetting*(store: SettingsStore, path: string): bool =
  let descriptor = requireSettingKind(path, settingBool)
  jsonBoolAt(store.values, path, descriptor.default.getBool)

proc projectPanelStartsOpen*(store: SettingsStore): bool =
  let fallback = settingDefaultBool("projectPanel.startsOpen")
  if store == nil: return fallback
  let configured = nodeAt(store.values, "projectPanel.startsOpen")
  if configured != nil:
    return store.boolSetting("projectPanel.startsOpen")
  store.boolSetting("projectPanel.starts_open")

proc agentDisabled*(store: SettingsStore): bool =
  store.boolSetting("agent.disabled")

proc gitInlineBlameEnabled*(store: SettingsStore): bool =
  store.boolSetting("git.inlineBlame.enabled")

proc gitInlineBlameLocation*(store: SettingsStore): string =
  let location = store.stringSetting("git.inlineBlame.location")
  if location in ["inline", "status_bar"]: location else:
    settingDefaultString("git.inlineBlame.location")

proc gitInlineBlameShowCommitSummary*(store: SettingsStore): bool =
  store.boolSetting("git.inlineBlame.showCommitSummary")

proc gitInlineBlameDelayMs*(store: SettingsStore): int =
  max(0, store.intSetting("git.inlineBlame.delayMs"))

proc gitInlineBlameDelay*(store: SettingsStore): Option[Duration] =
  let delayMs = store.gitInlineBlameDelayMs()
  if delayMs == 0: none(Duration)
  else: some(initDuration(milliseconds = delayMs))

proc gitInlineBlamePadding*(store: SettingsStore): int =
  max(0, store.intSetting("git.inlineBlame.padding"))

proc gitInlineBlameMinColumn*(store: SettingsStore): int =
  max(0, store.intSetting("git.inlineBlame.minColumn"))

proc editorFontFeatures*(store: SettingsStore): seq[EditorFontFeature] =
  let node = nodeAt(store.values, "editor.fontFeatures")
  if node == nil or node.kind != JObject: return
  for tag, value in node:
    if validFeatureTag(tag) and value.kind == JBool:
      result.add(EditorFontFeature(tag: tag, enabled: value.getBool))
  result.sort(proc(left, right: EditorFontFeature): int = cmp(left.tag, right.tag))

proc editorFontFallbacks*(store: SettingsStore): seq[string] =
  let node = nodeAt(store.values, "editor.fontFallbacks")
  if node == nil or node.kind != JArray: return
  for fallback in node:
    if fallback.kind == JString and fallback.getStr.len > 0:
      result.add(fallback.getStr)

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
  let requested = store.stringSetting("theme")
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
  let requested = store.stringSetting("theme").toLowerAscii
  let customBackground = store.stringSetting("themeColors.background")
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
    "scrollbarTrackBorder": colors.scrollbarTrackBorder,
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
  let requested = store.stringSetting("iconTheme")
  if store != nil and store.iconThemeRegistry.hasKey(requested): requested else: "Nimculus Default"

proc iconForPath*(store: SettingsStore, path: string; directory = false): string =
  if directory: return store.iconThemeRegistry[store.iconThemeName()].directoryIcon
  let theme = store.iconThemeRegistry[store.iconThemeName()]
  let extension = splitFile(path).ext.strip(chars = {'.'}).toLowerAscii
  if extension.len > 0 and theme.fileIcons.hasKey(extension): return theme.fileIcons[extension]
  theme.fileIcon
