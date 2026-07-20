import std/json
import std/os
import std/strutils
import std/times

type
  SettingsDiagnostic* = object
    path*: string
    message*: string

  KeyBinding* = object
    key*: string
    command*: string
    whenClause*: string

  ThemeColors* = object
    background*: string
    foreground*: string
    accent*: string
    selection*: string
    border*: string
    syntax*: JsonNode

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
  let insertSpaces = nodeAt(root, "editor.insertSpaces")
  if insertSpaces != nil and insertSpaces.kind != JBool:
    result.add(SettingsDiagnostic(path: "editor.insertSpaces", message: "must be a boolean"))
  for key in ["theme", "iconTheme", "terminal.shell"]:
    let value = jsonStringAt(root, key, "")
    if value.len == 0:
      let node = nodeAt(root, key)
      if node != nil:
        result.add(SettingsDiagnostic(path: key, message: "must be a string"))

proc settingsSchema*(): JsonNode =
  ## Stable schema consumed by editors and future settings UI completion.
  %*{
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "type": "object",
    "properties": {
      "editor": {"type": "object", "properties": {
        "fontSize": {"type": "integer", "minimum": 6, "maximum": 96},
        "tabSize": {"type": "integer", "minimum": 1, "maximum": 16},
        "insertSpaces": {"type": "boolean"}
      }},
      "theme": {"type": "string"},
      "iconTheme": {"type": "string"},
      "terminal": {"type": "object", "properties": {"shell": {"type": "string"}}},
      "lsp": {"type": "object", "properties": {"command": {"type": "string"}}},
      "keymap": {"type": "array", "items": {"type": "object",
        "required": ["key", "command"], "properties": {
          "key": {"type": "string"}, "command": {"type": "string"}, "when": {"type": "string"}
        }}}
    }
  }

proc settingsPaths*(home: string): tuple[globalPath, workspaceName: string] =
  (home / "Library" / "Application Support" / "Nimculus" / "settings.json", ".nimculus" / "settings.json")

proc fileStamp(path: string): int64 =
  if path.len == 0 or not fileExists(path): return 0
  try: getLastModificationTime(path).toUnix
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

proc reload*(store: SettingsStore): bool =
  if store == nil: return false
  let globalStamp = fileStamp(store.globalPath)
  let workspaceStamp = fileStamp(store.workspacePath)
  if globalStamp == store.globalStamp and workspaceStamp == store.workspaceStamp: return false
  store.settings = loadSettings(store.globalPath, store.workspacePath, store.languageId)
  store.globalStamp = globalStamp
  store.workspaceStamp = workspaceStamp
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
    if item.kind != JObject or not item.hasKey("key") or not item.hasKey("command"): continue
    result.add(KeyBinding(key: item["key"].getStr, command: item["command"].getStr,
      whenClause: if item.hasKey("when"): item["when"].getStr else: ""))

proc theme*(store: SettingsStore): ThemeColors =
  result.background = store.stringSetting("themeColors.background", "#1f2329")
  result.foreground = store.stringSetting("themeColors.foreground", "#d7dae0")
  result.accent = store.stringSetting("themeColors.accent", "#4daafc")
  result.selection = store.stringSetting("themeColors.selection", "#264f78")
  result.border = store.stringSetting("themeColors.border", "#3b4048")
  let syntax = nodeAt(store.values, "themeColors.syntax")
  result.syntax = if syntax != nil and syntax.kind == JObject: syntax else: objectNode()
