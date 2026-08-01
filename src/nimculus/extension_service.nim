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
import std/times

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
    wasmEntrypoint*: string
    apiVersion*: int
    externalProcess*: string
    permissions*: seq[string]

  ExtensionRegistry* = ref object
    manifests*: Table[string, ExtensionManifest]
    roots*: seq[string]

const SupportedExtensionApiVersion* = 1

proc register*(registry: ExtensionRegistry, manifest: ExtensionManifest)

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
  if node.hasKey("wasmEntrypoint"):
    if node["wasmEntrypoint"].kind != JString:
      raise extensionError("wasmEntrypoint must be a string")
    result.wasmEntrypoint = node["wasmEntrypoint"].getStr.strip
    if result.wasmEntrypoint.len > 256 or '\0' in result.wasmEntrypoint:
      raise extensionError("wasmEntrypoint is too long or contains NUL")
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
  ## Validate the WebAssembly container before handing it to a host. Both the
  ## core module header and the Component Model header are accepted; the
  ## versioned manifest/API check still happens before this boundary.
  if manifest.wasmModule.len == 0: return true
  let modulePath = normalizedPath(manifest.root / manifest.wasmModule)
  let rootPath = normalizedPath(manifest.root)
  if not (modulePath == rootPath or modulePath.startsWith(rootPath & DirSep)):
    return false
  if not fileExists(modulePath): return false
  let bytes = readFile(modulePath)
  if bytes.len < 8 or bytes[0] != '\0' or bytes[1] != 'a' or bytes[2] != 's' or
      bytes[3] != 'm': return false
  let coreModule = ord(bytes[4]) == 1 and ord(bytes[5]) == 0 and
    ord(bytes[6]) == 0 and ord(bytes[7]) == 0
  let component = ord(bytes[4]) == 0x0d and ord(bytes[5]) == 0 and
    ord(bytes[6]) == 1 and ord(bytes[7]) == 0
  result = coreModule or component

proc validExtensionId(id: string): bool =
  ## An extension id becomes a directory name.  Keep the install boundary
  ## boring and deterministic; this also prevents `..`, separators, and
  ## platform-specific path syntax from escaping the global extension root.
  if id.len == 0 or id in [".", ".."]: return false
  for ch in id:
    if not (ch in {'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.'}): return false
  true

proc copyExtensionTree(source, destination: string) =
  createDir(destination)
  for kind, path in walkDir(source):
    let target = destination / lastPathPart(path)
    case kind
    of pcDir:
      copyExtensionTree(path, target)
    of pcFile:
      copyFile(path, target)
    of pcLinkToFile, pcLinkToDir:
      raise extensionError("extension contains an unsupported filesystem entry: " &
        relativePath(path, source))

proc removeExtensionTree(path: string) =
  if not dirExists(path):
    if fileExists(path): removeFile(path)
    return
  for kind, child in walkDir(path):
    case kind
    of pcDir:
      removeExtensionTree(child)
    of pcFile:
      removeFile(child)
    of pcLinkToFile, pcLinkToDir:
      removeFile(child)
  removeDir(path)

proc installDirectory*(registry: ExtensionRegistry, source, destinationRoot: string): ExtensionManifest =
  ## Install a local extension directory atomically and register the copied
  ## manifest.  The operation intentionally rejects replacement for now: a
  ## second install must be an explicit future update/uninstall action rather
  ## than silently overwriting a user's extension.
  if registry == nil: raise extensionError("extension registry is nil")
  if source.strip.len == 0 or not dirExists(source):
    raise extensionError("extension directory not found: " & source)
  if destinationRoot.strip.len == 0:
    raise extensionError("extension install root is empty")
  let sourcePath = normalizedPath(source)
  let installRoot = normalizedPath(destinationRoot)
  let sourceManifest = loadExtensionManifest(sourcePath / "extension.json")
  if not validExtensionId(sourceManifest.id):
    raise extensionError("extension id is not a safe directory name: " & sourceManifest.id)
  if not sourceManifest.validateWasmModule():
    raise extensionError("extension WASM module is invalid or escapes its root")
  createDir(installRoot)
  let destination = installRoot / sourceManifest.id
  if normalizedPath(sourcePath) == normalizedPath(destination):
    raise extensionError("extension is already installed at the selected destination")
  if dirExists(destination) or fileExists(destination):
    raise extensionError("extension is already installed: " & sourceManifest.id)
  let temporary = installRoot / ("." & sourceManifest.id & ".installing-" &
    $int(epochTime() * 1000.0))
  if dirExists(temporary) or fileExists(temporary):
    raise extensionError("extension install is already in progress: " & sourceManifest.id)
  try:
    copyExtensionTree(sourcePath, temporary)
    result = loadExtensionManifest(temporary / "extension.json")
    if not result.validateWasmModule():
      raise extensionError("installed extension WASM module failed validation")
    moveDir(temporary, destination)
    result.root = destination
    registry.register(result)
  except CatchableError:
    removeExtensionTree(temporary)
    raise

proc newExtensionRegistry*(roots: openArray[string] = []): ExtensionRegistry =
  result = ExtensionRegistry(manifests: initTable[string, ExtensionManifest]())
  for root in roots:
    if root.len > 0: result.roots.add(root)

proc register*(registry: ExtensionRegistry, manifest: ExtensionManifest) =
  if registry == nil: raise extensionError("extension registry is nil")
  if manifest.id.len == 0: raise extensionError("extension id is empty")
  registry.manifests[manifest.id] = manifest

proc find*(registry: ExtensionRegistry, id: string): ExtensionManifest =
  if registry == nil or not registry.manifests.hasKey(id): return
  registry.manifests[id]

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
