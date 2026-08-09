import nimculus/editor_buffer
import nimculus/git_service

type
  GitBlameCacheKey* = object
    repositoryRoot*: string
    documentPath*: string
    documentVersion*: uint64

  GitBlameCache* = object
    key*: GitBlameCacheKey
    valid*: bool
    loaded*: bool
    entries*: seq[GitBlameLine]

proc reset*(cache: var GitBlameCache) =
  cache = GitBlameCache()

proc begin*(cache: var GitBlameCache; repositoryRoot, documentPath: string;
            documentVersion: uint64) =
  cache.key = GitBlameCacheKey(repositoryRoot: repositoryRoot,
    documentPath: documentPath, documentVersion: documentVersion)
  cache.valid = true
  cache.loaded = false
  cache.entries.setLen(0)

proc matches*(cache: GitBlameCache; repositoryRoot, documentPath: string;
              documentVersion: uint64): bool =
  cache.valid and cache.key.repositoryRoot == repositoryRoot and
    cache.key.documentPath == documentPath and
    cache.key.documentVersion == documentVersion

proc shouldStart*(cache: GitBlameCache; repositoryRoot, documentPath: string;
                  documentVersion: uint64; lineEmpty, jobRunning: bool): bool =
  if lineEmpty: return false
  if not cache.matches(repositoryRoot, documentPath, documentVersion): return true
  not cache.loaded and not jobRunning

proc finish*(cache: var GitBlameCache; entries: seq[GitBlameLine]) =
  cache.entries = entries
  cache.loaded = true

proc lineIsEmpty*(buffer: PieceTable; line: int): bool =
  if buffer.lineStarts.len == 0: return true
  let targetLine = max(0, min(line, buffer.lineStarts.high))
  buffer.lineEndByteOffset(targetLine) == buffer.lineStarts[targetLine]

proc entryAt*(cache: GitBlameCache; line: int): GitBlameLine =
  if not cache.loaded or line < 0 or line >= cache.entries.len: return
  cache.entries[line]

proc shouldShow*(cache: GitBlameCache; buffer: PieceTable; line: int): bool =
  if not cache.loaded or cache.entries.len == 0 or buffer.lineIsEmpty(line): return false
  let entry = cache.entryAt(line)
  entry.hash.len > 0
