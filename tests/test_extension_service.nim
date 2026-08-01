import std/os
import std/tables
import std/strutils
import std/unittest

import nimculus/extension_service
import nimculus/task_service
import nimculus/wasm_runtime

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
    writeFile(root / "extension.wasm", "\x00asm\x0d\x00\x01\x00")
    check manifest.validateWasmModule()
    expect ExtensionError:
      discard parseExtensionManifest("""
        {"id":"future","name":"Future","version":"1","apiVersion":2}
      """, root)
    removeDir(root)

  test "builds a bounded Wasmtime plan without shell interpolation":
    let root = getTempDir() / "nimculus-wasm-plan-test"
    let runtime = root / "wasmtime"
    createDir(root)
    writeFile(runtime, "#!/bin/sh\nexit 0\n")
    setFilePermissions(runtime, {fpUserRead, fpUserWrite, fpUserExec})
    writeFile(root / "extension.wasm", "\x00asm\x0d\x00\x01\x00")
    let manifest = parseExtensionManifest("""
       {"id":"safe.tools","name":"Safe Tools","version":"1",
       "apiVersion":1,"wasmModule":"extension.wasm","wasmEntrypoint":"run()"}
    """, root)
    let plan = prepareWasmExecution(manifest, runtime)
    check plan.command == normalizedPath(runtime)
    check plan.workingDirectory == normalizedPath(root)
    check plan.component
    check plan.args[0 .. 1] == @["--dir", normalizedPath(root) & "::/extension"]
    check "--invoke" in plan.args
    check plan.args[^1] == normalizedPath(root / "extension.wasm")
    check not plan.args.join(" ").contains("-c")
    removeDir(root)

  test "rejects an unavailable Wasmtime runtime before starting a process":
    let root = getTempDir() / "nimculus-wasm-runtime-missing-test"
    createDir(root)
    writeFile(root / "extension.wasm", "\x00asm\x01\x00\x00\x00")
    let manifest = parseExtensionManifest("""
      {"id":"missing.runtime","name":"Missing Runtime","version":"1",
       "apiVersion":1,"wasmModule":"extension.wasm"}
    """, root)
    expect WasmRuntimeError:
      discard prepareWasmExecution(manifest, root / "does-not-exist")
    removeDir(root)

  test "runs a validated wasm module through the direct Wasmtime boundary":
    let runtime = resolveWasmRuntime()
    if runtime.len == 0:
      echo "  [SKIP] Wasmtime runtime is not installed"
    else:
      let root = getTempDir() / "nimculus-wasm-execution-test"
      createDir(root)
      writeFile(root / "extension.wasm", "\x00asm\x01\x00\x00\x00")
      let manifest = parseExtensionManifest("""
        {"id":"runtime.tools","name":"Runtime Tools","version":"1",
         "apiVersion":1,"wasmModule":"extension.wasm"}
      """, root)
      let plan = prepareWasmExecution(manifest)
      let job = startTask(TaskSpec(command: plan.command, args: plan.args,
        workingDirectory: plan.workingDirectory))
      for _ in 0 .. 100:
        if job.poll(): break
        sleep(10)
      check job.done
      check job.result.status == taskSucceeded
      removeDir(root)

  test "keeps the optional Component host behind validation and an error boundary":
    let root = getTempDir() / "nimculus-component-host-boundary-test"
    createDir(root)
    writeFile(root / "extension.wasm", "not a component")
    let manifest = parseExtensionManifest("""
      {"id":"component.tools","name":"Component Tools","version":"1",
       "apiVersion":1,"wasmModule":"extension.wasm","wasmEntrypoint":"run()"}
    """, root)
    var errorMessage = ""
    let status = runWasmComponentInProcess(manifest, errorMessage)
    check status != 0
    check errorMessage.len > 0
    removeDir(root)

  test "polls an optional Component worker without blocking the caller":
    let root = getTempDir() / "nimculus-component-worker-boundary-test"
    createDir(root)
    writeFile(root / "extension.wasm", "\x00asm\x0d\x00\x01\x00")
    let manifest = parseExtensionManifest("""
      {"id":"component.worker","name":"Component Worker","version":"1",
       "apiVersion":1,"wasmModule":"extension.wasm"}
    """, root)
    var startError = ""
    var job = startWasmComponentJob(manifest, startError)
    if job.handle == nil:
      check startError.len > 0
    else:
      var state = 0
      var errorMessage = ""
      for _ in 0 .. 100:
        state = pollWasmComponentJob(job, errorMessage)
        if state != 0: break
        sleep(10)
      check state != 0
      check state in [2, 3]
      check errorMessage.len > 0
      deleteWasmComponentJob(job)
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
