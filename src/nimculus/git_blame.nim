import std/unicode
import nimculus/editor_buffer
import nimculus/git_service

type
  GitBlameCacheKey* = object
    repositoryRoot*: string
    documentPath*: string

  GitBlameCache* = object
    key*: GitBlameCacheKey
    valid*: bool
    loaded*: bool
    needsRegeneration: bool
    entries*: seq[GitBlameLine]

proc reset*(cache: var GitBlameCache) =
  cache = GitBlameCache()

proc begin*(cache: var GitBlameCache; repositoryRoot, documentPath: string) =
  cache.key = GitBlameCacheKey(repositoryRoot: repositoryRoot,
    documentPath: documentPath)
  cache.valid = true
  cache.loaded = false
  cache.needsRegeneration = false
  cache.entries.setLen(0)

proc begin*(cache: var GitBlameCache; repositoryRoot, documentPath: string;
            ignoredVersion: uint64) =
  ## Compatibility overload for callers compiled against the versioned API.
  cache.begin(repositoryRoot, documentPath)

proc beginUnavailable*(cache: var GitBlameCache; documentPath: string) =
  ## Remember that this document cannot produce blame without resolving it
  ## again on every status sync. An empty repository root is reserved for this
  ## negative result; real Git repositories always have a resolved root.
  cache.begin("", documentPath)
  cache.loaded = true

proc beginUnavailable*(cache: var GitBlameCache; documentPath: string;
                       ignoredVersion: uint64) =
  ## Compatibility overload for callers compiled against the versioned API.
  cache.beginUnavailable(documentPath)

proc matches*(cache: GitBlameCache; repositoryRoot, documentPath: string): bool =
  cache.valid and cache.key.repositoryRoot == repositoryRoot and
    cache.key.documentPath == documentPath

proc matches*(cache: GitBlameCache; repositoryRoot, documentPath: string;
              ignoredVersion: uint64): bool =
  ## Compatibility overload. Cache identity is repository plus document path.
  cache.matches(repositoryRoot, documentPath)

proc unavailableMatches*(cache: GitBlameCache; documentPath: string): bool =
  cache.matches("", documentPath) and cache.loaded

proc unavailableMatches*(cache: GitBlameCache; documentPath: string;
                          ignoredVersion: uint64): bool =
  cache.unavailableMatches(documentPath)

proc shouldStart*(cache: GitBlameCache; repositoryRoot, documentPath: string;
                  lineEmpty, jobRunning: bool): bool =
  if lineEmpty: return false
  if not cache.matches(repositoryRoot, documentPath): return true
  (not cache.loaded or cache.needsRegeneration) and not jobRunning

proc shouldStart*(cache: GitBlameCache; repositoryRoot, documentPath: string;
                  ignoredVersion: uint64; lineEmpty, jobRunning: bool): bool =
  ## Compatibility overload. Cache identity is repository plus document path.
  cache.shouldStart(repositoryRoot, documentPath, lineEmpty, jobRunning)

proc finish*(cache: var GitBlameCache; entries: seq[GitBlameLine]) =
  cache.entries = entries
  cache.loaded = true
  cache.needsRegeneration = false

proc applyEdit*(cache: var GitBlameCache; startLine, removedLines,
                insertedLines: int) =
  ## Keep unaffected blame rows attached to their document rows after an edit.
  ## Newly inserted rows are deliberately empty until Git regenerates blame.
  if not cache.loaded: return
  let start = max(0, min(startLine, cache.entries.len))
  let removed = max(0, min(removedLines, cache.entries.len - start))
  let inserted = max(0, insertedLines)
  if removed == 0 and inserted == 0:
    if start < cache.entries.len:
      cache.entries[start] = GitBlameLine()
  else:
    for _ in 0 ..< removed:
      cache.entries.delete(start)
    for _ in 0 ..< inserted:
      cache.entries.insert(GitBlameLine(), start)
  cache.needsRegeneration = true

proc lineIsEmpty*(buffer: PieceTable; line: int): bool =
  if buffer.lineStarts.len == 0: return true
  let targetLine = max(0, min(line, buffer.lineStarts.high))
  buffer.lineEndByteOffset(targetLine) == buffer.lineStarts[targetLine]

proc entryAt*(cache: GitBlameCache; line: int): GitBlameLine =
  if not cache.loaded or line < 0 or line >= cache.entries.len: return
  cache.entries[line]

iterator blameForRows*(cache: GitBlameCache; firstRow, lastRow: int): GitBlameLine =
  if cache.loaded and cache.entries.len > 0:
    let first = max(0, firstRow)
    let last = min(lastRow, cache.entries.high)
    if first <= last:
      for row in first .. last:
        yield cache.entries[row]

proc maxAuthorLength*(cache: GitBlameCache): int =
  for entry in cache.entries:
    result = max(result, entry.author.runeLen)

proc shouldShow*(cache: GitBlameCache; buffer: PieceTable; line: int): bool =
  if not cache.loaded or cache.entries.len == 0 or buffer.lineIsEmpty(line): return false
  let entry = cache.entryAt(line)
  entry.hash.len > 0
