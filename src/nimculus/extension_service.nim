## Manifest-driven extension registry for the macOS editor.
##
## Zed keeps extension discovery/metadata separate from the host process and
## treats executable extensions as a permissioned boundary.  Nimculus starts
## with the same safe boundary: manifests can register data-backed language,
## grammar, theme, icon theme, snippet, task and command metadata, while code
## execution is opt-in and never loads a native library into Nimculus.

import std/json
import std/os
import std/strutils
import std/tables

type
  ExtensionError* = object of CatchableError

  ExtensionManifest* = object
    id*: string
    name*: string
    version*: string
    root*: string
    languages*: seq[string]
    grammars*: seq[string]
    lspServers*: Table[string, string]
    themes*: seq[string]
    iconThemes*: seq[string]
    snippets*: seq[string]
    tasks*: seq[string]
    commands*: seq[string]
    wasmModule*: string
    apiVersion*: int
    externalProcess*: string
    permissions*: seq[string]

  ExtensionRegistry* = ref object
    manifests*: Table[string, ExtensionManifest]
    roots*: seq[string]

const SupportedExtensionApiVersion* = 1

proc extensionError(message: string): ref ExtensionError =
  newException(ExtensionError, message)

proc stringList(node: JsonNode, key: string): seq[string] =
  if node == nil or not node.hasKey(key): return
  if node[key].kind != JArray: raise extensionError(key & " must be an array")
  for value in node[key]:
    if value.kind != JString: raise extensionError(key & " entries must be strings")
    result.add(value.getStr)

proc parseExtensionManifest*(contents, root: string): ExtensionManifest =
  let node = try: parseJson(contents)
    except JsonParsingError as error: raise extensionError("invalid manifest: " & error.msg)
  if node.kind != JObject: raise extensionError("extension manifest must be an object")
  for key in ["id", "name", "version"]:
    if not node.hasKey(key) or node[key].kind != JString or node[key].getStr.strip.len == 0:
      raise extensionError("manifest requires string field " & key)
  result.id = node["id"].getStr
  result.name = node["name"].getStr
  result.version = node["version"].getStr
  result.root = root
  result.languages = stringList(node, "languages")
  result.grammars = stringList(node, "grammars")
  result.themes = stringList(node, "themes")
  result.iconThemes = stringList(node, "iconThemes")
  result.snippets = stringList(node, "snippets")
  result.tasks = stringList(node, "tasks")
  result.commands = stringList(node, "commands")
  result.permissions = stringList(node, "permissions")
  result.apiVersion = if node.hasKey("apiVersion"):
    if node["apiVersion"].kind != JInt: raise extensionError("apiVersion must be an integer")
    node["apiVersion"].getInt
    else: SupportedExtensionApiVersion
  if result.apiVersion != SupportedExtensionApiVersion:
    raise extensionError("unsupported extension API version: " & $result.apiVersion)
  if node.hasKey("wasmModule"):
    if node["wasmModule"].kind != JString:
      raise extensionError("wasmModule must be a string")
    result.wasmModule = node["wasmModule"].getStr
  result.lspServers = initTable[string, string]()
  if node.hasKey("lspServers"):
    if node["lspServers"].kind != JObject:
      raise extensionError("lspServers must be an object")
    for language, command in node["lspServers"]:
      if command.kind != JString: raise extensionError("LSP commands must be strings")
      result.lspServers[language] = command.getStr
  if node.hasKey("externalProcess"):
    if node["externalProcess"].kind != JString:
      raise extensionError("externalProcess must be a string")
    result.externalProcess = node["externalProcess"].getStr
  if result.externalProcess.len > 0 and "process" notin result.permissions:
    raise extensionError("externalProcess requires the process permission")

proc loadExtensionManifest*(path: string): ExtensionManifest =
  if not fileExists(path): raise extensionError("manifest not found: " & path)
  parseExtensionManifest(readFile(path), parentDir(path))

proc validateWasmModule*(manifest: ExtensionManifest): bool =
  ## Validate the WebAssembly container before handing it to a future host.
  ## The module must remain under its manifest root and use the WebAssembly 1
  ## binary header. Execution is intentionally not attempted without an
  ## explicitly selected WASM runtime and versioned host API.
  if manifest.wasmModule.len == 0: return true
  let modulePath = normalizedPath(manifest.root / manifest.wasmModule)
  let rootPath = normalizedPath(manifest.root)
  if not (modulePath == rootPath or modulePath.startsWith(rootPath & DirSep)):
    return false
  if not fileExists(modulePath): return false
  let bytes = readFile(modulePath)
  bytes.len >= 8 and bytes[0] == '\0' and bytes[1] == 'a' and bytes[2] == 's' and
    bytes[3] == 'm' and ord(bytes[4]) == 1 and ord(bytes[5]) == 0 and
    ord(bytes[6]) == 0 and ord(bytes[7]) == 0

proc newExtensionRegistry*(roots: openArray[string] = []): ExtensionRegistry =
  result = ExtensionRegistry(manifests: initTable[string, ExtensionManifest]())
  for root in roots:
    if root.len > 0: result.roots.add(root)

proc register*(registry: ExtensionRegistry, manifest: ExtensionManifest) =
  if registry == nil: raise extensionError("extension registry is nil")
  if manifest.id.len == 0: raise extensionError("extension id is empty")
  registry.manifests[manifest.id] = manifest

proc clear*(registry: ExtensionRegistry) =
  if registry != nil: registry.manifests.clear()

iterator items*(registry: ExtensionRegistry): tuple[id: string, manifest: ExtensionManifest] =
  if registry != nil:
    for id, manifest in registry.manifests:
      yield (id, manifest)

proc discover*(registry: ExtensionRegistry): int =
  if registry == nil: return
  for root in registry.roots:
    if not dirExists(root): continue
    for directory in walkDirs(root / "*"):
      let manifestPath = directory / "extension.json"
      if not fileExists(manifestPath): continue
      try:
        let manifest = loadExtensionManifest(manifestPath)
        if manifest.validateWasmModule():
          registry.register(manifest)
          inc result
      except ExtensionError:
        discard

proc findLanguage*(registry: ExtensionRegistry, language: string): ExtensionManifest =
  if registry == nil: return
  for _, manifest in registry.manifests:
    if language in manifest.languages: return manifest

proc hasPermission*(manifest: ExtensionManifest, permission: string): bool =
  permission in manifest.permissions
