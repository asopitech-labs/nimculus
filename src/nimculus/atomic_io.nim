import std/os

var atomicWriteSequence = 0

proc atomicWriteFile*(path, content: string) =
  ## Preserve the previous file until the complete replacement is ready.
  ## The sequence prevents two writes from the same process from sharing a
  ## temporary pathname. The temporary remains in the target directory so the
  ## final rename is an atomic replacement on the same filesystem. Resolve an
  ## existing symlink first: replacing the link itself would silently turn a
  ## linked document into a regular file.
  let targetPath =
    try:
      expandFilename(path)
    except OSError:
      absolutePath(path)
  let sequence = atomicWriteSequence
  inc atomicWriteSequence
  let temporary = targetPath & ".tmp." & $getCurrentProcessId() & "." & $sequence
  try:
    let preservePermissions = fileExists(targetPath)
    let permissions = if preservePermissions: getFilePermissions(targetPath) else: {}
    writeFile(temporary, content)
    if preservePermissions:
      setFilePermissions(temporary, permissions)
    moveFile(temporary, targetPath)
  except CatchableError:
    if fileExists(temporary): removeFile(temporary)
    raise
