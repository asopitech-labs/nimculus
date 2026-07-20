import std/unittest
import std/strutils
import nimculus/update_service

suite "M11 update service":
  test "parses a secure release manifest":
    let release = parseUpdateManifest("""{"version":"v0.2.0","url":"https://example.invalid/Nimculus.dmg","sha256":"ABC123","notes":"fixes"}""")
    check release.version == "v0.2.0"
    check release.url.startsWith("https://")
    check release.sha256 == "abc123"
    check isUpdateAvailable("0.1.0", release)

  test "rejects insecure artifacts and compares prereleases":
    let release = parseUpdateManifest("""{"version":"0.2.0","url":"http://example.invalid/Nimculus.dmg"}""")
    check release.url.len == 0
    check compareVersions("1.0.0-beta", "1.0.0") < 0
    check compareVersions("v1.0.0", "1.0.0") == 0
    check not isUpdateAvailable("1.0.0", UpdateRelease(version: "1.0.0", url: "https://example.invalid/a"))
