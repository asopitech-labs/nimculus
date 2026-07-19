import std/os

proc atomicWriteFile*(path, content: string) =
  ## Preserve the previous file until the complete replacement is ready.
  let temporary = path & ".tmp." & $getCurrentProcessId()
  try:
    let preservePermissions = fileExists(path)
    let permissions = if preservePermissions: getFilePermissions(path) else: {}
    writeFile(temporary, content)
    if preservePermissions:
      setFilePermissions(temporary, permissions)
    moveFile(temporary, path)
  except CatchableError:
    if fileExists(temporary): removeFile(temporary)
    raise
