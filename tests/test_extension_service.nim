import std/os
import std/osproc
import std/tables
import std/strutils
import std/unittest

import nimculus/extension_service
import nimculus/extension_catalog
import nimculus/task_service
import nimculus/wasm_runtime
import wait_support

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

  test "negotiates declared permissions against the versioned host":
    let manifest = parseExtensionManifest("""
      {"id":"write.tools","name":"Write Tools","version":"1",
       "apiVersion":1,"permissions":["filesystem-write"]}
    """, "/tmp/write-tools")
    check manifest.extensionPermissionList == @["filesystem-write"]
    check extensionPermissionRequiresPrompt("filesystem-write")
    check manifest.extensionHostCapabilityString == "filesystem-read,filesystem-write"
    check manifest.validateExtensionHostPermissions().len == 0
    let process = parseExtensionManifest("""
      {"id":"process.tools","name":"Process Tools","version":"1",
       "apiVersion":1,"permissions":["process"]}
    """, "/tmp/process-tools")
    check process.extensionHostCapabilityString == "filesystem-read,process"
    check process.validateExtensionHostPermissions().len == 0
    expect ExtensionError:
      discard parseExtensionManifest("""
        {"id":"future.tools","name":"Future Tools","version":"1",
         "permissions":["camera"]}
      """, "/tmp/future-tools")
    let network = parseExtensionManifest("""
      {"id":"network.tools","name":"Network Tools","version":"1",
       "permissions":["network"]}
    """, "/tmp/network-tools")
    check network.validateExtensionHostPermissions().len > 0

  test "negotiates API version and validates a wasm container before registration":
    let root = getTempDir() / ("nimculus-wasm-extension-test-" & $getCurrentProcessId())
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
    let root = getTempDir() / ("nimculus-wasm-plan-test-" & $getCurrentProcessId())
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
    check "NIMCULUS_EXTENSION_HOST_API_VERSION=1" in plan.args
    check "NIMCULUS_EXTENSION_CAPABILITIES=filesystem-read" in plan.args
    check "--invoke" in plan.args
    check plan.args[^1] == normalizedPath(root / "extension.wasm")
    check not plan.args.join(" ").contains("-c")
    removeDir(root)

  test "rejects an unavailable Wasmtime runtime before starting a process":
    let root = getTempDir() / ("nimculus-wasm-runtime-missing-test-" & $getCurrentProcessId())
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
      let root = getTempDir() / ("nimculus-wasm-execution-test-" & $getCurrentProcessId())
      createDir(root)
      writeFile(root / "extension.wasm", "\x00asm\x01\x00\x00\x00")
      let manifest = parseExtensionManifest("""
        {"id":"runtime.tools","name":"Runtime Tools","version":"1",
         "apiVersion":1,"wasmModule":"extension.wasm"}
      """, root)
      let plan = prepareWasmExecution(manifest)
      let job = startTask(TaskSpec(command: plan.command, args: plan.args,
        workingDirectory: plan.workingDirectory))
      let wait = waitForTest("validated Wasm task completion",
        condition = proc(): bool = job.poll())
      check checkTestWait(wait)
      check job.done
      check job.result.status == taskSucceeded
      removeDir(root)

  test "keeps the optional Component host behind validation and an error boundary":
    let root = getTempDir() / ("nimculus-component-host-boundary-test-" & $getCurrentProcessId())
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

  when defined(macosx):
    test "links the Zed platform WIT import in the native Component host":
      let wasmTools = findExe("wasm-tools")
      let library = getEnv("NIMCULUS_WASMTIME_LIBRARY", "/usr/local/opt/wasmtime/lib/libwasmtime.dylib")
      if wasmTools.len == 0 or not fileExists(library):
        echo "  [SKIP] wasm-tools or the Wasmtime Component library is not installed"
      else:
        let root = getTempDir() / ("nimculus-component-platform-runtime-test-" & $getCurrentProcessId())
        let embedded = root / "extension.embedded.wasm"
        let component = root / "extension.component.wasm"
        createDir(root)
        let wit = normalizedPath(parentDir(currentSourcePath) / "fixtures" /
          "wit_platform_host" / "extension.wit")
        let generator = startProcess(wasmTools, args = @[
          "component", "embed", wit, normalizedPath(parentDir(currentSourcePath) /
            "fixtures" / "wit_platform_host" / "init.wat"), "--world", "extension",
          "-o", embedded
        ], options = {poUsePath, poStdErrToStdOut})
        check generator.waitForExit(10_000) == 0
        generator.close()
        let linker = startProcess(wasmTools, args = @[
          "component", "new", embedded, "-o", component
        ], options = {poUsePath, poStdErrToStdOut})
        check linker.waitForExit(10_000) == 0
        linker.close()
        let oldLibrary = getEnv("NIMCULUS_WASMTIME_LIBRARY", "")
        putEnv("NIMCULUS_WASMTIME_LIBRARY", library)
        let available = wasmComponentHostAvailable()
        var status = 0
        var errorMessage = ""
        if available:
          let manifest = parseExtensionManifest("""
            {"id":"platform.runtime","name":"Platform Runtime","version":"1",
             "apiVersion":1,"wasmModule":"extension.component.wasm",
             "wasmEntrypoint":"init-extension"}
          """, root)
          status = runWasmComponentInProcess(manifest, errorMessage)
        if oldLibrary.len == 0:
          delEnv("NIMCULUS_WASMTIME_LIBRARY")
        else:
          putEnv("NIMCULUS_WASMTIME_LIBRARY", oldLibrary)
        if not available:
          echo "  [SKIP] Wasmtime Component library is unavailable for this architecture"
        else:
          check status == 0
          check errorMessage.len == 0
        removeDir(root)

    test "invokes the Zed process WIT import only with process permission":
      let wasmTools = findExe("wasm-tools")
      let library = getEnv("NIMCULUS_WASMTIME_LIBRARY", "/usr/local/opt/wasmtime/lib/libwasmtime.dylib")
      if wasmTools.len == 0 or not fileExists(library):
        echo "  [SKIP] wasm-tools or the Wasmtime Component library is not installed"
      else:
        let root = getTempDir() / ("nimculus-component-process-runtime-test-" & $getCurrentProcessId())
        let embedded = root / "extension.embedded.wasm"
        let component = root / "extension.component.wasm"
        createDir(root)
        let fixtureRoot = normalizedPath(parentDir(currentSourcePath) / "fixtures" /
          "wit_process_host")
        let generator = startProcess(wasmTools, args = @[
          "component", "embed", fixtureRoot / "extension.wit",
          fixtureRoot / "init.wat", "--world", "extension", "-o", embedded
        ], options = {poUsePath, poStdErrToStdOut})
        check generator.waitForExit(10_000) == 0
        generator.close()
        let linker = startProcess(wasmTools, args = @[
          "component", "new", embedded, "-o", component
        ], options = {poUsePath, poStdErrToStdOut})
        check linker.waitForExit(10_000) == 0
        linker.close()
        let oldLibrary = getEnv("NIMCULUS_WASMTIME_LIBRARY", "")
        putEnv("NIMCULUS_WASMTIME_LIBRARY", library)
        let available = wasmComponentHostAvailable()
        var status = 0
        var errorMessage = ""
        if available:
          let denied = parseExtensionManifest("""
            {"id":"process.denied","name":"Process Denied","version":"1",
             "apiVersion":1,"wasmModule":"extension.component.wasm",
             "wasmEntrypoint":"init-extension"}
          """, root)
          var deniedError = ""
          check runWasmComponentInProcess(denied, deniedError) != 0
          check deniedError.len > 0
          let manifest = parseExtensionManifest("""
            {"id":"process.runtime","name":"Process Runtime","version":"1",
             "apiVersion":1,"wasmModule":"extension.component.wasm",
             "wasmEntrypoint":"init-extension","permissions":["process"]}
          """, root)
          status = runWasmComponentInProcess(manifest, errorMessage)
        if oldLibrary.len == 0:
          delEnv("NIMCULUS_WASMTIME_LIBRARY")
        else:
          putEnv("NIMCULUS_WASMTIME_LIBRARY", oldLibrary)
        if not available:
          echo "  [SKIP] Wasmtime Component library is unavailable for this architecture"
        else:
          check status == 0
          check errorMessage.len == 0
        removeDir(root)

  test "polls an optional Component worker without blocking the caller":
    let root = getTempDir() / ("nimculus-component-worker-boundary-test-" & $getCurrentProcessId())
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
      let wait = waitForTest("Wasm Component worker completion",
        condition = proc(): bool =
          state = pollWasmComponentJob(job, errorMessage)
          state != 0)
      check checkTestWait(wait)
      check state != 0
      check state in [2, 3]
      check errorMessage.len > 0
      deleteWasmComponentJob(job)
    removeDir(root)

  test "discovers extension directories and resolves language ownership":
    let root = getTempDir() / ("nimculus-extension-test-" & $getCurrentProcessId())
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
    let root = getTempDir() / ("nimculus-extension-install-test-" & $getCurrentProcessId())
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
    let root = getTempDir() / ("nimculus-extension-install-boundary-test-" & $getCurrentProcessId())
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

  test "parses a bounded HTTPS extension catalog":
    let catalog = parseExtensionCatalog("""
      {"version":1,"extensions":[
        {"id":"nim.tools","name":"Nim Tools","version":"1.2.0",
         "archiveUrl":"https://example.invalid/nim-tools.zip",
         "sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}
      ]}
    """)
    check catalog.len == 1
    check catalog[0].id == "nim.tools"
    check findCatalogEntry(catalog, "nim.tools").archiveUrl.startsWith("https://")
    check isSecureExtensionCatalogUrl("https://example.invalid/catalog.json")
    check not isSecureExtensionCatalogUrl("http://example.invalid/catalog.json")
    check not isSecureExtensionCatalogUrl("https://user@example.invalid/catalog.json")
    expect ExtensionCatalogError:
      discard parseExtensionCatalog("""
        {"version":1,"extensions":[
          {"id":"bad/id","name":"Bad","version":"1",
           "archiveUrl":"https://example.invalid/bad.zip",
           "sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}
        ]}
      """)

  when defined(macosx):
    test "inspects and installs a catalog ZIP through the safe registry boundary":
      let root = getTempDir() / ("nimculus-extension-catalog-package-test-" & $getCurrentProcessId())
      let source = root / "catalog-ext"
      let destination = root / "installed"
      let archive = root / "catalog-ext.zip"
      createDir(root)
      createDir(source)
      writeFile(source / "extension.json", """
        {"id":"catalog.ext","name":"Catalog Extension","version":"1",
         "apiVersion":1,"wasmModule":"extension.wasm"}
      """)
      writeFile(source / "extension.wasm", "\x00asm\x01\x00\x00\x00")
      let packer = startProcess("/usr/bin/ditto",
        args = @["-c", "-k", source, archive],
        options = {poUsePath, poStdErrToStdOut})
      check packer.waitForExit(10_000) == 0
      packer.close()
      let inspected = inspectCatalogArchive(archive)
      check inspected.id == "catalog.ext"
      let registry = newExtensionRegistry([destination])
      let installed = registry.installCatalogArchive(archive, destination)
      check installed.id == "catalog.ext"
      check fileExists(installed.root / "extension.wasm")
      removeDir(root)
