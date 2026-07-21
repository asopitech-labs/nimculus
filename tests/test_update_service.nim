import std/unittest
import std/strutils
import std/os
import nimculus/update_service

suite "M11 update service":
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
