import std/json
import std/strutils

type
  UpdateRelease* = object
    version*: string
    url*: string
    sha256*: string
    notes*: string

proc parseUpdateManifest*(payload: string): UpdateRelease =
  ## Parse the release contract used by the future downloader. Non-HTTPS
  ## artifacts are rejected before a download or install step can see them.
  try:
    let root = parseJson(payload)
    let value = if root.kind == JObject and root.hasKey("release"):
      root["release"] else: root
    if value.kind != JObject: return
    if value.hasKey("version") and value["version"].kind == JString:
      result.version = value["version"].getStr
    if value.hasKey("url") and value["url"].kind == JString:
      let url = value["url"].getStr
      if url.startsWith("https://"): result.url = url
    if value.hasKey("sha256") and value["sha256"].kind == JString:
      result.sha256 = value["sha256"].getStr.toLowerAscii
    if value.hasKey("notes") and value["notes"].kind == JString:
      result.notes = value["notes"].getStr
  except CatchableError: discard

proc compareVersions*(left, right: string): int =
  ## Compare dotted numeric versions, accepting an optional leading `v`.
  ## Stable versions sort after prereleases at the same numeric version.
  let leftParts = left.strip(leading = true, trailing = false,
    chars = {'v', 'V'}).split('-', maxsplit = 1)
  let rightParts = right.strip(leading = true, trailing = false,
    chars = {'v', 'V'}).split('-', maxsplit = 1)
  let leftNumbers = leftParts[0].split('.')
  let rightNumbers = rightParts[0].split('.')
  for index in 0 ..< max(leftNumbers.len, rightNumbers.len):
    let l = if index < leftNumbers.len:
      try: parseInt(leftNumbers[index]) except ValueError: 0
    else: 0
    let r = if index < rightNumbers.len:
      try: parseInt(rightNumbers[index]) except ValueError: 0
    else: 0
    if l != r: return cmp(l, r)
  let leftPre = if leftParts.len > 1: leftParts[1] else: ""
  let rightPre = if rightParts.len > 1: rightParts[1] else: ""
  if leftPre.len == 0 and rightPre.len > 0: return 1
  if leftPre.len > 0 and rightPre.len == 0: return -1
  cmp(leftPre, rightPre)

proc isUpdateAvailable*(currentVersion: string, release: UpdateRelease): bool =
  release.version.len > 0 and release.url.len > 0 and
    compareVersions(currentVersion, release.version) < 0
