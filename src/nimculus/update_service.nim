import std/json
import std/os
import std/osproc
import std/streams
import std/strutils

type
  UpdateRelease* = object
    version*: string
    url*: string
    sha256*: string
    notes*: string

  UpdateDownloadJob* = ref object
    process: Process
    release*: UpdateRelease
    destination*: string
    done*: bool
    success*: bool

proc isHttpsUrl(url: string): bool =
  url.startsWith("https://")

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
      if isHttpsUrl(url): result.url = url
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
    isHttpsUrl(release.url) and
    release.sha256.len == 64 and release.sha256.allCharsInSet(HexDigits) and
    compareVersions(currentVersion, release.version) < 0

proc verifySha256*(path, expected: string): bool =
  ## Verify a downloaded artifact without invoking a shell. `shasum` ships
  ## with macOS and is also available in the POSIX development environments.
  let digest = expected.toLowerAscii
  if path.len == 0 or digest.len != 64 or not digest.allCharsInSet(HexDigits): return false
  try:
    let process = startProcess("shasum", args = ["-a", "256", path],
      options = {poUsePath, poStdErrToStdOut})
    let output = process.outputStream.readAll()
    let exitCode = process.waitForExit()
    process.close()
    if exitCode != 0: return false
    let actual = output.strip.splitWhitespace
    actual.len > 0 and actual[0].toLowerAscii == digest
  except CatchableError: false

proc downloadAndVerify*(release: UpdateRelease, destination: string): bool =
  ## Download an HTTPS artifact without a shell, then verify it before the
  ## caller can hand it to an installer. Failed or mismatched artifacts are
  ## removed so a stale file cannot be mistaken for a verified update.
  if not isHttpsUrl(release.url) or release.sha256.len != 64 or
      not release.sha256.allCharsInSet(HexDigits) or destination.len == 0:
    return false
  try:
    let process = startProcess("curl", args = ["--fail", "--location", "--silent",
      "--show-error", "--proto", "=https", "--tlsv1.2", "--output", destination,
      release.url], options = {poUsePath, poStdErrToStdOut})
    discard process.outputStream.readAll()
    let exitCode = process.waitForExit()
    process.close()
    if exitCode != 0 or not verifySha256(destination, release.sha256):
      if fileExists(destination): removeFile(destination)
      return false
    true
  except CatchableError:
    if fileExists(destination):
      try: removeFile(destination)
      except CatchableError: discard
    false

proc startUpdateDownload*(release: UpdateRelease, destination: string): UpdateDownloadJob =
  ## Start the HTTPS download without blocking the UI thread. Hash validation is
  ## performed only after curl exits successfully.
  result = UpdateDownloadJob(release: release, destination: destination, done: true)
  if not isHttpsUrl(release.url) or release.sha256.len != 64 or
      not release.sha256.allCharsInSet(HexDigits) or destination.len == 0:
    return
  try:
    result.process = startProcess("curl", args = ["--fail", "--location", "--silent",
      "--show-error", "--proto", "=https", "--tlsv1.2", "--output", destination,
      release.url], options = {poUsePath, poStdErrToStdOut})
    result.done = false
  except CatchableError:
    result.done = true

proc pollUpdateDownload*(job: UpdateDownloadJob): bool =
  if job == nil or job.done: return true
  let exitCode = job.process.peekExitCode()
  if exitCode < 0: return false
  job.process.close()
  job.done = true
  job.success = exitCode == 0 and verifySha256(job.destination, job.release.sha256)
  if not job.success and fileExists(job.destination):
    try: removeFile(job.destination)
    except CatchableError: discard
  true

proc runChecked(command: string, args: openArray[string]): bool =
  ## Run a platform verifier without a shell and discard its diagnostic output.
  try:
    let process = startProcess(command, args = @args,
      options = {poUsePath, poStdErrToStdOut})
    discard process.outputStream.readAll()
    let exitCode = process.waitForExit()
    process.close()
    exitCode == 0
  except CatchableError:
    false

proc verifyMacosSignedApp*(path: string): bool =
  ## Verify the downloaded `.app` before an eventual install step.
  ## `spctl` is intentionally kept separate from artifact hashing: a valid
  ## download is not necessarily an executable accepted by Gatekeeper.
  path.len > 0 and path.endsWith(".app") and dirExists(path) and
    runChecked("codesign", ["--verify", "--deep", "--strict", "--verbose=2", path]) and
    runChecked("spctl", ["--assess", "--type", "execute", "--verbose", path])

proc installMacosDmgUpdate*(downloadedDmg, runningAppPath, temporaryDirectory: string): bool =
  ## Install a verified DMG using the same mount/copy/unmount boundary as Zed.
  ## The mounted app is verified before rsync can overwrite the running app.
  if not downloadedDmg.endsWith(".dmg") or not fileExists(downloadedDmg) or
      not runningAppPath.endsWith(".app") or not dirExists(runningAppPath) or
      temporaryDirectory.len == 0:
    return false
  let mountRoot = temporaryDirectory / "NimculusUpdateMount"
  let appName = splitFile(runningAppPath).name & splitFile(runningAppPath).ext
  let mountedApp = mountRoot / appName
  var mounted = false
  try:
    createDir(temporaryDirectory)
    createDir(mountRoot)
    let attach = startProcess("hdiutil", args = ["attach", "-nobrowse",
      "-mountroot", temporaryDirectory, downloadedDmg],
      options = {poUsePath, poStdErrToStdOut})
    discard attach.outputStream.readAll()
    mounted = attach.waitForExit() == 0
    attach.close()
    if not mounted or not verifyMacosSignedApp(mountedApp): return false
    let copy = startProcess("rsync", args = ["-a", "--delete", "--exclude", "Icon?",
      mountedApp & "/", runningAppPath & "/"],
      options = {poUsePath, poStdErrToStdOut})
    discard copy.outputStream.readAll()
    copy.waitForExit() == 0
  except CatchableError:
    false
  finally:
    if mounted:
      try:
        let detach = startProcess("hdiutil", args = ["detach", "-force", mountRoot],
          options = {poUsePath, poStdErrToStdOut})
        discard detach.outputStream.readAll()
        discard detach.waitForExit()
        detach.close()
      except CatchableError: discard
