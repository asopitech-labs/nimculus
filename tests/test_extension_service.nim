import std/os
import std/tables
import std/unittest

import nimculus/extension_service

suite "M17 extension registry":
  test "parses data-backed registrations and LSP commands":
    let manifest = parseExtensionManifest("""
      {"id":"nim.tools","name":"Nim Tools","version":"1.0.0",
       "languages":["nim"],"grammars":["tree-sitter-nim"],
       "lspServers":{"nim":"nimlangserver"},"themes":["dark.json"],
       "commands":["nim.build"]}
    """, "/tmp/nim-tools")
    check manifest.id == "nim.tools"
    check "nim" in manifest.languages
    check manifest.lspServers["nim"] == "nimlangserver"
    check not manifest.hasPermission("process")

  test "requires explicit process permission for external execution":
    expect ExtensionError:
      discard parseExtensionManifest("""
        {"id":"unsafe","name":"Unsafe","version":"1","externalProcess":"run"}
      """, "/tmp/unsafe")

  test "negotiates API version and validates a wasm container before registration":
    let root = getTempDir() / "nimculus-wasm-extension-test"
    createDir(root)
    let manifest = parseExtensionManifest("""
      {"id":"wasm.tools","name":"Wasm Tools","version":"1",
       "apiVersion":1,"wasmModule":"extension.wasm"}
    """, root)
    writeFile(root / "extension.wasm", "\x00asm\x01\x00\x00\x00")
    check manifest.validateWasmModule()
    writeFile(root / "extension.wasm", "not wasm")
    check not manifest.validateWasmModule()
    expect ExtensionError:
      discard parseExtensionManifest("""
        {"id":"future","name":"Future","version":"1","apiVersion":2}
      """, root)
    removeDir(root)

  test "discovers extension directories and resolves language ownership":
    let root = getTempDir() / "nimculus-extension-test"
    let extensionRoot = root / "markdown"
    createDir(extensionRoot)
    writeFile(extensionRoot / "extension.json", """
      {"id":"markdown","name":"Markdown","version":"1","languages":["markdown"]}
    """)
    let registry = newExtensionRegistry([root])
    check registry.discover() == 1
    check registry.findLanguage("markdown").id == "markdown"
    removeDir(root)

  test "installs a validated local extension into the global root":
    let root = getTempDir() / "nimculus-extension-install-test"
    let source = root / "source"
    let destination = root / "installed"
    createDir(source)
    writeFile(source / "extension.json", """
      {"id":"sample-theme","name":"Sample Theme","version":"1.0.0",
       "apiVersion":1,"themes":["theme.json"],"wasmModule":"extension.wasm"}
    """)
    writeFile(source / "theme.json", "{}")
    writeFile(source / "extension.wasm", "\x00asm\x01\x00\x00\x00")
    let registry = newExtensionRegistry([destination])
    let installed = registry.installDirectory(source, destination)
    check installed.id == "sample-theme"
    check installed.root == destination / "sample-theme"
    check fileExists(installed.root / "extension.json")
    check registry.findLanguage("unknown").id == ""
    removeDir(root)

  test "rejects extension ids that can escape the install root":
    let root = getTempDir() / "nimculus-extension-install-boundary-test"
    let source = root / "source"
    createDir(source)
    writeFile(source / "extension.json", """
      {"id":"../escape","name":"Escape","version":"1.0.0","apiVersion":1}
    """)
    let registry = newExtensionRegistry([root / "installed"])
    expect ExtensionError:
      discard registry.installDirectory(source, root / "installed")
    check not dirExists(root / "escape")
    removeDir(root)
