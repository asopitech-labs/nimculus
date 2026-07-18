import std/os

proc atomicWriteFile*(path, content: string) =
  ## Preserve the previous file until the complete replacement is ready.
  let temporary = path & ".tmp." & $getCurrentProcessId()
  try:
    writeFile(temporary, content)
    moveFile(temporary, path)
  except CatchableError:
    if fileExists(temporary): removeFile(temporary)
    raise
