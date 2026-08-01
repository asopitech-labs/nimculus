## Sandboxed Wasmtime execution boundary for macOS extensions.
##
## Zed keeps the Wasmtime component host separate from extension discovery and
## only grants the guest the capabilities represented by the host linker.  The
## The macOS host has two explicit execution boundaries: the official
## Wasmtime CLI remains the safe asynchronous fallback, while an
## architecture-compatible Wasmtime C API can provide a bounded in-process
## Component Model/WASI call. The latter is dynamically resolved so the
## editor does not link to Homebrew paths or make development headers a build
## prerequisite.

import std/os
import std/strutils

import nimculus/extension_service

when defined(macosx):
  {.compile: "wasm_component_host.c".}
  proc nimculusWasmtimeComponentAvailable(libraryPath: cstring): cint
      {.importc: "nimculus_wasmtime_component_available", cdecl.}
  proc nimculusWasmtimeComponentRun(libraryPath, modulePath, extensionRoot,
      extensionId: cstring; apiVersion: uint32; entrypoint: cstring;
      allowWrite: cint; errorOut: cstring; errorCapacity: csize_t): cint
      {.importc: "nimculus_wasmtime_component_run", cdecl.}

type
  WasmRuntimeError* = object of ExtensionError

  WasmExecutionPlan* = object
    command*: string
    args*: seq[string]
    workingDirectory*: string
    runtimeSource*: string
    modulePath*: string
    entrypoint*: string
    component*: bool

proc wasmRuntimeError(message: string): ref WasmRuntimeError =
  newException(WasmRuntimeError, message)

proc executableFile(path: string): bool =
  if path.len == 0 or not fileExists(path): return false
  when defined(posix):
    let permissions = getFilePermissions(path)
    return fpUserExec in permissions or fpGroupExec in permissions or fpOthersExec in permissions
  else:
    true

proc resolveWasmRuntime*(configured: string = ""): string =
  ## Resolve only an explicit executable or the well-known Wasmtime binary.
  ## Extension manifests never control this path.
  let requested = if configured.strip.len > 0: configured.strip
    elif getEnv("NIMCULUS_WASMTIME", "").strip.len > 0:
      getEnv("NIMCULUS_WASMTIME", "").strip
    else: "wasmtime"
  if requested.contains(DirSep) or requested.startsWith("."):
    let absolute = normalizedPath(requested)
    if executableFile(absolute): return absolute
    return ""
  let resolved = findExe(requested)
  if executableFile(resolved): resolved else: ""

proc prepareWasmExecution*(manifest: ExtensionManifest;
    configuredRuntime: string = ""): WasmExecutionPlan =
  if manifest.wasmModule.len == 0:
    raise wasmRuntimeError("extension has no wasmModule")
  if not manifest.validateWasmModule():
    raise wasmRuntimeError("extension WASM module is invalid or escapes its root")
  let runtime = resolveWasmRuntime(configuredRuntime)
  if runtime.len == 0:
    raise wasmRuntimeError("Wasmtime runtime is unavailable; install Wasmtime or set NIMCULUS_WASMTIME")
  let modulePath = normalizedPath(manifest.root / manifest.wasmModule)
  result.command = runtime
  result.workingDirectory = normalizedPath(manifest.root)
  result.runtimeSource = if configuredRuntime.strip.len > 0 or
      getEnv("NIMCULUS_WASMTIME", "").strip.len > 0: "configured" else: "PATH"
  result.modulePath = modulePath
  result.entrypoint = manifest.wasmEntrypoint
  let bytes = readFile(modulePath)
  result.component = bytes.len >= 8 and ord(bytes[4]) == 0x0d and
    ord(bytes[5]) == 0 and ord(bytes[6]) == 1 and ord(bytes[7]) == 0
  ## Wasmtime options precede the module.  The guest sees only this extension
  ## tree at /extension; no shell is involved and no host cwd is preopened.
  result.args = @["--dir", result.workingDirectory & "::/extension",
    "--env", "NIMCULUS_EXTENSION_ID=" & manifest.id,
    "--env", "NIMCULUS_EXTENSION_API_VERSION=" & $manifest.apiVersion]
  if manifest.wasmEntrypoint.len > 0:
    result.args.add("--invoke")
    result.args.add(manifest.wasmEntrypoint)
  result.args.add(modulePath)

proc wasmRuntimeStatus*(configuredRuntime: string = ""): string =
  let runtime = resolveWasmRuntime(configuredRuntime)
  if runtime.len == 0: "unavailable (install Wasmtime)" else: runtime

proc wasmComponentHostAvailable*(): bool =
  ## Report the optional in-process host without making it a startup gate.
  ## The C boundary rejects a library with the wrong architecture.
  when defined(macosx):
    nimculusWasmtimeComponentAvailable(
      getEnv("NIMCULUS_WASMTIME_LIBRARY", "").cstring) != 0
  else:
    false

proc runWasmComponentInProcess*(manifest: ExtensionManifest;
    errorMessage: var string): int =
  ## Execute a no-argument Component export. Zed's generated WIT bindings
  ## expose `init-extension`; Nimculus also accepts an explicit manifest
  ## entrypoint such as `run()` and strips only the Wave call suffix at this
  ## boundary. The call is intentionally separate from the CLI plan so the
  ## app can keep async task ownership until the native job adapter is ready.
  when defined(macosx):
    if manifest.wasmModule.len == 0 or not manifest.validateWasmModule():
      errorMessage = "extension WASM module failed manifest validation"
      return 2
    var errorBuffer = newString(4096)
    result = nimculusWasmtimeComponentRun(
      getEnv("NIMCULUS_WASMTIME_LIBRARY", "").cstring,
      normalizedPath(manifest.root / manifest.wasmModule).cstring,
      normalizedPath(manifest.root).cstring,
      manifest.id.cstring,
      uint32(manifest.apiVersion),
      manifest.wasmEntrypoint.cstring,
      (if manifest.hasPermission("filesystem-write"): 1 else: 0),
      errorBuffer.cstring,
      csize_t(errorBuffer.len))
    errorMessage = errorBuffer.strip
  else:
    errorMessage = "in-process Component Model is only available on macOS"
    result = 1
