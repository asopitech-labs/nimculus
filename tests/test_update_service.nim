import std/unittest
import std/strutils
import std/os
import std/times
when defined(posix):
  import std/[envvars, posix]
import nimculus/update_service

suite "M11 update service":
  test "uses the DMG volume path for mounted update apps":
    check MacosUpdateVolumeName == "Nimculus"
    check macosUpdateMountedAppPath("/tmp/NimculusUpdateMount", "Nimculus.app") ==
      "/tmp/NimculusUpdateMount/Nimculus/Nimculus.app"

  test "defines a bounded update artifact size":
    check MaxUpdateArtifactBytes == 1024'i64 * 1024 * 1024

  test "parses a secure release manifest":
    let release = parseUpdateManifest("""{"version":"v0.2.0","url":"https://example.invalid/Nimculus.dmg","sha256":"0000000000000000000000000000000000000000000000000000000000000000","notes":"fixes"}""")
    check release.version == "v0.2.0"
    check release.url.startsWith("https://")
    check release.sha256 == "0000000000000000000000000000000000000000000000000000000000000000"
    check isUpdateAvailable("0.1.0", release)
    let path = getTempDir() / "nimculus-update-artifact"
    writeFile(path, "hello")
    check verifySha256(path, "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    removeFile(path)
    let invalidDestination = getTempDir() / "nimculus-update-invalid"
    check not downloadAndVerify(UpdateRelease(url: "http://example.invalid/a",
      sha256: "0000000000000000000000000000000000000000000000000000000000000000"),
      invalidDestination)
    check not fileExists(invalidDestination)
    check not verifyMacosSignedApp(getTempDir() / "missing-nimculus.app")
    check not installMacosDmgUpdate(getTempDir() / "missing-nimculus.dmg",
      getTempDir() / "missing-nimculus.app", getTempDir() / "nimculus-update-test")

  test "rejects insecure artifacts and compares prereleases":
    let release = parseUpdateManifest("""{"version":"0.2.0","url":"http://example.invalid/Nimculus.dmg"}""")
    check release.url.len == 0
    check compareVersions("1.0.0-beta", "1.0.0") < 0
    check compareVersions("v1.0.0", "1.0.0") == 0
    check not isUpdateAvailable("1.0.0", UpdateRelease(version: "1.0.0", url: "https://example.invalid/a",
      sha256: "0000000000000000000000000000000000000000000000000000000000000000"))
    let invalidJob = startUpdateDownload(UpdateRelease(url: "http://example.invalid/a",
      sha256: "0000000000000000000000000000000000000000000000000000000000000000"),
      getTempDir() / "nimculus-update-job-invalid")
    check invalidJob.done
    check not invalidJob.success

    let staleDestination = getTempDir() / "nimculus-update-stale"
    writeFile(staleDestination, "stale")
    let rejected = startUpdateDownload(UpdateRelease(url: "http://example.invalid/a",
      sha256: "0000000000000000000000000000000000000000000000000000000000000000"),
      staleDestination)
    check rejected.done
    check not fileExists(staleDestination)

  test "rejects an invalid install target without touching the artifact":
    let artifact = getTempDir() / "nimculus-update-invalid-install.dmg"
    writeFile(artifact, "not a disk image")
    defer:
      if fileExists(artifact): removeFile(artifact)
    check not installMacosDmgUpdate(artifact, getTempDir() / "missing-nimculus.app",
      getTempDir() / "nimculus-update-test")
    check fileExists(artifact)

  when defined(posix):
    test "cancels an active update download within a bounded wait":
      let root = getTempDir() / "nimculus-update-cancel"
      let fakeCurl = root / "curl"
      let destination = root / "Nimculus-update.dmg"
      createDir(root)
      writeFile(fakeCurl, "#!/bin/sh\nsleep 30 & wait\n")
      setFilePermissions(fakeCurl, {fpUserRead, fpUserWrite, fpUserExec})
      let previousPath = getEnv("PATH")
      putEnv("PATH", root & ":" & previousPath)
      defer:
        putEnv("PATH", previousPath)
        if fileExists(destination): removeFile(destination)
        if fileExists(destination & ".part"): removeFile(destination & ".part")
        if fileExists(fakeCurl): removeFile(fakeCurl)
        if dirExists(root): removeDir(root)
      let release = UpdateRelease(url: "https://example.invalid/Nimculus.dmg",
        sha256: repeat("0", 64))
      let job = startUpdateDownload(release, destination)
      check not job.done
      check job.processGroupId > 0
      let started = epochTime()
      let processGroupId = job.processGroupId
      job.cancelUpdateDownload()
      check epochTime() - started < 3.0
      check job.done
      check not job.success
      check not fileExists(destination)
      check not fileExists(destination & ".part")
      check kill(-processGroupId, 0) == -1
      check errno == ESRCH
