import std/os

var atomicWriteSequence = 0

proc atomicWriteFile*(path, content: string) =
  ## Preserve the previous file until the complete replacement is ready.
  ## The sequence prevents two writes from the same process from sharing a
  ## temporary pathname. The temporary remains in the target directory so the
  ## final rename is an atomic replacement on the same filesystem.
  let sequence = atomicWriteSequence
  inc atomicWriteSequence
  let temporary = path & ".tmp." & $getCurrentProcessId() & "." & $sequence
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
