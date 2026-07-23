import std/json
import std/os
import std/osproc
import std/streams
import std/strutils
import std/times
when defined(posix):
  import std/posix

when defined(posix):
  type
    UpdateFileStreamObj = object of Stream
      f: File
    UpdateFileStream = ref UpdateFileStreamObj

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
    partialDestination: string
    done*: bool
    success*: bool

const MaxUpdateArtifactBytes* = 1024'i64 * 1024 * 1024
const UpdateProcessGracePeriodMs = 1_000
const UpdateToolTimeoutMs* = 60_000
const MacosUpdateVolumeName* = "Nimculus"

proc artifactWithinLimit(path: string): bool =
  try:
    fileExists(path) and getFileSize(path) <= MaxUpdateArtifactBytes
  except CatchableError:
    false

proc partialUpdatePath(destination: string): string = destination & ".part"

proc macosUpdateMountedAppPath*(mountRoot, appName: string): string =
  ## `hdiutil -mountroot root` mounts a volume at `root/<volname>`, not at
  ## `root` itself. Keep this explicit contract shared by install and tests.
  mountRoot / MacosUpdateVolumeName / appName

proc removeIfPresent(path: string) =
  if path.len == 0 or not fileExists(path): return
  try: removeFile(path)
  except CatchableError: discard

proc appendBoundedOutput(current, chunk: string, limit: int):
    tuple[output: string, truncated: bool] =
  if chunk.len == 0: return (current, false)
  if limit <= 0: return ("", true)
  if current.len >= limit: return (current, true)
  let remaining = limit - current.len
  if chunk.len <= remaining: return (current & chunk, false)
  (current & chunk[0 ..< remaining], true)

proc terminateUpdateProcess(process: Process): int =
  ## Keep an interrupted update from holding the Cocoa shutdown path forever.
  if process == nil: return -1
  if process.running:
    process.terminate()
    result = process.waitForExit(UpdateProcessGracePeriodMs)
    if result < 0:
      process.kill()
      result = process.waitForExit(UpdateProcessGracePeriodMs)
  else:
    result = process.peekExitCode()
  process.close()

proc readAvailable(process: Process, output: Stream): string =
  if process == nil or output == nil: return
  when defined(posix):
    let stream = cast[UpdateFileStream](output)
    if stream == nil or stream.f == nil: return
    let fd = cint(getOsFileHandle(stream.f))
    let flags = fcntl(fd, F_GETFL)
    if flags < 0 or fcntl(fd, F_SETFL, flags or O_NONBLOCK) < 0: return
    var bytes: array[8192, char]
    while true:
      let count = posix.read(fd, addr bytes[0], bytes.len)
      if count > 0:
        let oldLength = result.len
        result.setLen(oldLength + count)
        copyMem(addr result[oldLength], addr bytes[0], count)
      elif count < 0 and (errno == EAGAIN or errno == EWOULDBLOCK):
        break
      else:
        break
  else:
    if process.hasData(): result = output.readStr(8192)

proc runProcessBounded(command: string, args: openArray[string],
                       maxOutputBytes = 64 * 1024,
                       timeoutMs = UpdateToolTimeoutMs):
    tuple[exitCode: int, output: string, truncated: bool] =
  try:
    let process = startProcess(command, args = @args,
      options = {poUsePath, poStdErrToStdOut})
    let outputStream = process.peekableOutputStream()
    let startedAt = epochTime()
    while true:
      let chunk = process.readAvailable(outputStream)
      if chunk.len > 0:
        let bounded = appendBoundedOutput(result.output, chunk, maxOutputBytes)
        result.output = bounded.output
        result.truncated = result.truncated or bounded.truncated
      let exitCode = process.peekExitCode()
      if exitCode >= 0:
        let tail = process.readAvailable(outputStream)
        if tail.len > 0:
          let bounded = appendBoundedOutput(result.output, tail, maxOutputBytes)
          result.output = bounded.output
          result.truncated = result.truncated or bounded.truncated
        result.exitCode = exitCode
        process.close()
        return
      if timeoutMs > 0 and (epochTime() - startedAt) * 1_000.0 >= float64(timeoutMs):
        result.exitCode = terminateUpdateProcess(process)
        let bounded = appendBoundedOutput(result.output,
          "update tool timed out\n", maxOutputBytes)
        result.output = bounded.output
        result.truncated = result.truncated or bounded.truncated
        return
      sleep(1)
  except CatchableError:
    result.exitCode = -1

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
    let checked = runProcessBounded("shasum", ["-a", "256", path])
    if checked.exitCode != 0: return false
    let actual = checked.output.strip.splitWhitespace
    actual.len > 0 and actual[0].toLowerAscii == digest
  except CatchableError: false

proc downloadAndVerify*(release: UpdateRelease, destination: string): bool =
  ## Download an HTTPS artifact without a shell, then verify it before the
  ## caller can hand it to an installer. Failed or mismatched artifacts are
  ## removed so a stale file cannot be mistaken for a verified update.
  let partial = partialUpdatePath(destination)
  removeIfPresent(partial)
  removeIfPresent(destination)
  if not isHttpsUrl(release.url) or release.sha256.len != 64 or
      not release.sha256.allCharsInSet(HexDigits) or destination.len == 0:
    return false
  try:
    let checked = runProcessBounded("curl", ["--fail", "--location", "--silent",
      "--show-error", "--proto", "=https", "--tlsv1.2", "--max-filesize",
      $MaxUpdateArtifactBytes, "--output", partial,
      release.url])
    if checked.exitCode != 0 or not artifactWithinLimit(partial) or
        not verifySha256(partial, release.sha256):
      removeIfPresent(partial)
      return false
    moveFile(partial, destination)
    true
  except CatchableError:
    removeIfPresent(partial)
    removeIfPresent(destination)
    false

proc startUpdateDownload*(release: UpdateRelease, destination: string): UpdateDownloadJob =
  ## Start the HTTPS download without blocking the UI thread. Hash validation is
  ## performed only after curl exits successfully.
  result = UpdateDownloadJob(release: release, destination: destination,
    partialDestination: partialUpdatePath(destination), done: true)
  removeIfPresent(destination)
  removeIfPresent(result.partialDestination)
  if not isHttpsUrl(release.url) or release.sha256.len != 64 or
      not release.sha256.allCharsInSet(HexDigits) or destination.len == 0:
    return
  try:
    result.process = startProcess("curl", args = ["--fail", "--location", "--silent",
      "--show-error", "--proto", "=https", "--tlsv1.2", "--max-filesize",
      $MaxUpdateArtifactBytes, "--output", result.partialDestination,
      release.url], options = {poUsePath, poStdErrToStdOut})
    result.done = false
  except CatchableError:
    result.done = true

proc cancelUpdateDownload*(job: UpdateDownloadJob) =
  ## Cancellation is deliberately idempotent: it is used by both the UI and
  ## the macOS quit path, where a partial DMG must never survive as an update.
  if job == nil or job.done: return
  discard terminateUpdateProcess(job.process)
  job.done = true
  job.success = false
  removeIfPresent(job.partialDestination)
  removeIfPresent(job.destination)

proc pollUpdateDownload*(job: UpdateDownloadJob): bool =
  if job == nil or job.done: return true
  if fileExists(job.partialDestination) and
      not artifactWithinLimit(job.partialDestination):
    job.cancelUpdateDownload()
    return true
  let exitCode = job.process.peekExitCode()
  if exitCode < 0: return false
  job.process.close()
  job.done = true
  job.success = exitCode == 0 and artifactWithinLimit(job.partialDestination) and
    verifySha256(job.partialDestination, job.release.sha256)
  if job.success:
    try:
      moveFile(job.partialDestination, job.destination)
    except CatchableError:
      job.success = false
  if not job.success:
    removeIfPresent(job.partialDestination)
    removeIfPresent(job.destination)
  true

proc runChecked(command: string, args: openArray[string]): bool =
  ## Run a platform verifier without a shell and discard its diagnostic output.
  try:
    runProcessBounded(command, args).exitCode == 0
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
  let mountedVolume = mountRoot / MacosUpdateVolumeName
  let mountedApp = macosUpdateMountedAppPath(mountRoot, appName)
  var mounted = false
  try:
    createDir(temporaryDirectory)
    createDir(mountRoot)
    mounted = runProcessBounded("hdiutil", ["attach", "-nobrowse",
      "-mountroot", mountRoot, downloadedDmg]).exitCode == 0
    if not mounted or not verifyMacosSignedApp(mountedApp): return false
    runProcessBounded("rsync", ["-a", "--delete", "--exclude", "Icon?",
      mountedApp & "/", runningAppPath & "/"]).exitCode == 0
  except CatchableError:
    false
  finally:
    if mounted:
      try:
        discard runProcessBounded("hdiutil", ["detach", "-force", mountedVolume])
      except CatchableError: discard
    try:
      if dirExists(mountRoot): removeDir(mountRoot)
    except CatchableError: discard
    try:
      if fileExists(downloadedDmg): removeFile(downloadedDmg)
    except CatchableError: discard
