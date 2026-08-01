## Signed-artifact metadata for the optional macOS extension catalog.
##
## Catalog synchronization is deliberately separate from installation. A
## catalog only supplies validated HTTPS package metadata; the extension
## registry still validates the downloaded manifest and filesystem tree before
## any install mutation is allowed.

import std/json
import std/os
import std/osproc
import std/strutils
import std/times
import nimculus/extension_service

type
  ExtensionCatalogError* = object of CatchableError

  ExtensionCatalogEntry* = object
    id*: string
    name*: string
    version*: string
    archiveUrl*: string
    sha256*: string

const
  SupportedExtensionCatalogVersion* = 1
  MaxExtensionCatalogEntries* = 256
  MaxExtensionCatalogBytes* = 4 * 1024 * 1024
  MaxExtensionPackageBytes* = 256 * 1024 * 1024

proc catalogError(message: string): ref ExtensionCatalogError =
  newException(ExtensionCatalogError, message)

proc isSecureExtensionCatalogUrl*(url: string): bool =
  ## Keep the catalog transport aligned with the update service: no HTTP,
  ## file URLs, credentials, fragments, or whitespace are accepted.
  if not url.startsWith("https://") or url.len <= "https://".len: return false
  let authority = url["https://".len .. ^1].split({'/', '?'}, maxsplit = 1)[0]
  if authority.len == 0 or authority.contains('@') or authority.contains('#'):
    return false
  for ch in url:
    if ch.ord < 0x20 or ch == ' ' or ch == '\\': return false
  true

proc validSha256(value: string): bool =
  value.len == 64 and value.allCharsInSet(HexDigits)

proc parseExtensionCatalog*(contents: string): seq[ExtensionCatalogEntry] =
  let root = try: parseJson(contents)
    except JsonParsingError as error: raise catalogError("invalid catalog: " & error.msg)
  if root.kind != JObject:
    raise catalogError("extension catalog must be an object")
  if not root.hasKey("version") or root["version"].kind != JInt or
      root["version"].getInt != SupportedExtensionCatalogVersion:
    raise catalogError("unsupported extension catalog version")
  if not root.hasKey("extensions") or root["extensions"].kind != JArray:
    raise catalogError("extension catalog requires an extensions array")
  if root["extensions"].len > MaxExtensionCatalogEntries:
    raise catalogError("extension catalog has too many entries")
  for value in root["extensions"]:
    if value.kind != JObject:
      raise catalogError("extension catalog entries must be objects")
    for key in ["id", "name", "version", "archiveUrl", "sha256"]:
      if not value.hasKey(key) or value[key].kind != JString or
          value[key].getStr.strip.len == 0:
        raise catalogError("catalog entry requires string field " & key)
    let entry = ExtensionCatalogEntry(
      id: value["id"].getStr.strip,
      name: value["name"].getStr.strip,
      version: value["version"].getStr.strip,
      archiveUrl: value["archiveUrl"].getStr.strip,
      sha256: value["sha256"].getStr.toLowerAscii)
    if not validExtensionId(entry.id):
      raise catalogError("catalog entry has an unsafe extension id: " & entry.id)
    if not isSecureExtensionCatalogUrl(entry.archiveUrl):
      raise catalogError("catalog entry has an insecure archive URL: " & entry.id)
    if not validSha256(entry.sha256):
      raise catalogError("catalog entry has an invalid SHA-256: " & entry.id)
    for existing in result:
      if existing.id == entry.id:
        raise catalogError("catalog contains a duplicate extension id: " & entry.id)
    result.add(entry)

proc findCatalogEntry*(entries: openArray[ExtensionCatalogEntry],
                       id: string): ExtensionCatalogEntry =
  for entry in entries:
    if entry.id == id: return entry

proc removeCatalogTree(path: string) =
  if not dirExists(path):
    if fileExists(path): removeFile(path)
    return
  for kind, child in walkDir(path):
    case kind
    of pcDir: removeCatalogTree(child)
    of pcFile, pcLinkToFile, pcLinkToDir: removeFile(child)
  removeDir(path)

proc extractCatalogArchive(archivePath, staging: string) =
  if archivePath.len == 0 or not fileExists(archivePath):
    raise catalogError("catalog package is missing")
  if getFileSize(archivePath) > MaxExtensionPackageBytes:
    raise catalogError("catalog package exceeds the size limit")
  if dirExists(staging): raise catalogError("catalog extraction is already in progress")
  createDir(staging)
  when defined(macosx):
    let process = startProcess("/usr/bin/ditto",
      args = @["-x", "-k", archivePath, staging],
      options = {poUsePath, poStdErrToStdOut})
    let exitCode = process.waitForExit(30_000)
    if exitCode < 0:
      process.terminate()
      discard process.waitForExit(1_000)
      if process.running: process.kill()
      discard process.waitForExit(1_000)
    process.close()
    if exitCode != 0:
      raise catalogError("catalog package extraction failed")
  else:
    raise catalogError("catalog package extraction is only available on macOS")

proc inspectCatalogArchive*(archivePath: string): ExtensionManifest =
  ## Validate package contents before a permission sheet or install mutation.
  let staging = getTempDir() / ("nimculus-extension-catalog-inspect-" &
    $int(epochTime() * 1000.0))
  try:
    extractCatalogArchive(archivePath, staging)
    var manifests: seq[string]
    for path in walkDirRec(staging):
      if path.extractFilename == "extension.json": manifests.add(path)
    if manifests.len != 1:
      raise catalogError("catalog package must contain exactly one extension.json")
    result = loadExtensionManifest(manifests[0])
  finally:
    if dirExists(staging): removeCatalogTree(staging)

proc installCatalogArchive*(registry: ExtensionRegistry, archivePath,
                            destinationRoot: string): ExtensionManifest =
  ## A catalog package is a ZIP. Extraction happens in a private temporary
  ## directory, then the registry's existing symlink-free atomic installer
  ## performs the only mutation of the global extension root.
  if registry == nil: raise catalogError("extension registry is nil")
  let staging = getTempDir() / ("nimculus-extension-catalog-install-" &
    $int(epochTime() * 1000.0))
  try:
    extractCatalogArchive(archivePath, staging)
    var manifests: seq[string]
    for path in walkDirRec(staging):
      if path.extractFilename == "extension.json": manifests.add(path)
    if manifests.len != 1:
      raise catalogError("catalog package must contain exactly one extension.json")
    result = registry.installDirectory(parentDir(manifests[0]), destinationRoot)
  finally:
    if dirExists(staging): removeCatalogTree(staging)
