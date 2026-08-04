import std/re
import std/strutils

type
  SearchOptions* = object
    caseSensitive*: bool
    wholeWord*: bool
    regex*: bool
    includeIgnored*: bool
    includePatterns*: string
    excludePatterns*: string

  SearchMatch* = object
    startByte*, endByte*: int

proc isWordByte(value: char): bool {.inline.} =
  value in {'a'..'z', 'A'..'Z', '0'..'9', '_'}

proc isWholeWord(text: string, startByte, endByte: int): bool =
  let beforeIsWord = startByte > 0 and text[startByte - 1].isWordByte
  let afterIsWord = endByte < text.len and text[endByte].isWordByte
  not beforeIsWord and not afterIsWord

proc findMatches*(text, query: string, options: SearchOptions): seq[SearchMatch] =
  ## Match byte ranges using the same independent switches exposed by Zed's
  ## search bar. Regex errors intentionally escape as ValueError so callers
  ## can keep an invalid query visible without silently searching something
  ## else.
  if query.len == 0: return
  if options.regex:
    let flags = if options.caseSensitive: {} else: {reIgnoreCase}
    let pattern = re(query, flags)
    var offset = 0
    while offset <= text.len:
      let bounds = text.findBounds(pattern, offset)
      if bounds.first < 0: break
      let endByte = bounds.last + 1
      if not options.wholeWord or text.isWholeWord(bounds.first, endByte):
        result.add(SearchMatch(startByte: bounds.first, endByte: endByte))
      let nextOffset = if endByte > bounds.first: endByte else: bounds.first + 1
      if nextOffset <= offset: break
      offset = nextOffset
  else:
    let haystack = if options.caseSensitive: text else: text.toLowerAscii
    let needle = if options.caseSensitive: query else: query.toLowerAscii
    var offset = 0
    while true:
      let found = haystack.find(needle, offset)
      if found < 0: break
      let endByte = found + needle.len
      if not options.wholeWord or text.isWholeWord(found, endByte):
        result.add(SearchMatch(startByte: found, endByte: endByte))
      offset = found + max(1, needle.len)

