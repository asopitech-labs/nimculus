## Sandboxed Wasmtime execution boundary for macOS extensions.
##
## Zed keeps the Wasmtime component host separate from extension discovery and
## only grants the guest the capabilities represented by the host linker.  The
## first Nimculus host slice uses the official Wasmtime CLI as a process
## boundary: it runs a validated module with only the extension directory
## preopened, never inherits a host directory through a shell, and exposes a
## versioned invocation plan to the task service.  A future in-process
## Component Model linker can replace this implementation without changing the
## manifest or UI contract.

import std/os
import std/strutils

import nimculus/extension_service

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
