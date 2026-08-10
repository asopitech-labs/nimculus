import std/unicode
import std/tables
import graphemes
import nimnui/geometry

## The platform boundary deliberately contains only one-line shaping and
## glyph/font operations. Document rows, wrapping, decorations, and the
## two-frame cache live in this module.

when defined(macosx):
  {.compile: "platform/macos/text_platform.m".}
  {.passL: "-framework Cocoa -framework CoreText -framework CoreFoundation".}

  type
    PlatformFontRun* {.bycopy.} = object
      len*: uint32
      fontId*: uint32

    PlatformGlyph* {.bycopy.} = object
      glyphId*: uint32
      x*, y*: cdouble
      index*: uint32
      fontId*: uint32
      isEmoji*: bool

    PlatformLineMetrics* {.bycopy.} = object
      width*, ascent*, descent*: cdouble
      len*: uint32
      glyphCount*: uint32

  proc platformLayoutLineNative(utf8: cstring, length: uint32, fontSize: cdouble,
                           runs: ptr PlatformFontRun, runCount: uint32,
                           metrics: ptr PlatformLineMetrics,
                           glyphs: ptr PlatformGlyph, glyphCapacity: uint32)
                           {.importc: "nimculus_platform_layout_line", cdecl.}

type
  TextPosition* = object
    byteOffset*: int
    graphemeIndex*: int

  FontRun* = object
    ## A contiguous UTF-8 span shaped with one platform font ID.
    len*: int
    fontId*: uint32

  TextRun* = object
    ## App decoration run. `color` is intentionally outside CacheKey.
    len*: int
    fontId*: uint32
    color*: Hsla

  ShapedGlyph* = object
    ## A glyph ready for painting. `index` is a UTF-8 byte boundary.
    id*: uint32
    position*: Point
    index*: int
    isEmoji*: bool

  ShapedRun* = object
    fontId*: uint32
    glyphs*: seq[ShapedGlyph]

  LineLayout* = object
    fontSize*: Pixels
    width*, ascent*, descent*: Pixels
    runs*: seq[ShapedRun]
    len*: int

  WrapBoundary* = object
    runIx*, glyphIx*: int

  WrappedLineLayout* = object
    unwrappedLayout*: ref LineLayout
    wrapBoundaries*: seq[WrapBoundary]
    wrapWidth*: float32
    hasWrapWidth*: bool

  CacheKey* = object
    ## Content-addressable key. Colors, backgrounds, and underlines are
    ## intentionally absent: they are decoration runs assembled by the app.
    textHash*: uint64
    textLen*: int
    fontSize*: Pixels
    runs*: seq[FontRun]
    wrapWidth*: float32
    hasWrapWidth*: bool
    forceWidth*: float32
    hasForceWidth*: bool

  CacheKeyRef* = object
    ## Borrowed lookup key. It contains only the content hash, length, and
    ## layout parameters; a cache probe never materializes the line text.
    textHash*: uint64
    textLen*: int
    fontSize*: Pixels
    runs*: ptr FontRun
    runCount*: int
    wrapWidth*: float32
    hasWrapWidth*: bool
    forceWidth*: float32
    hasForceWidth*: bool

  PlatformLayoutLineProc* = proc(text: string, fontSize: Pixels,
                                 runs: openArray[FontRun]): LineLayout

  LineCacheEntry = object
    key: CacheKey
    layout: ref LineLayout

  WrappedCacheEntry = object
    key: CacheKey
    layout: ref WrappedLineLayout

  FrameCache = object
    linesByHash: Table[uint64, seq[LineCacheEntry]]
    wrappedLinesByHash: Table[uint64, seq[WrappedCacheEntry]]

  LineLayoutCache* = ref object
    previousFrame: FrameCache
    currentFrame: FrameCache
    platformLayoutLine*: PlatformLayoutLineProc

  GlyphKey* = object
    ## Raster configuration used to identify an atlas entry.
    codepoint*: Rune
    glyphId*: uint32
    fontId*: string
    fontSize*: float
    scaleFactor*: float
    subpixelX*, subpixelY*: uint8
    isEmoji*: bool
    subpixelRendering*: bool
    dilation*: uint8

  Glyph* = object
    codepoint*: Rune
    key*: GlyphKey
    advance*: Pixels
    atlasX*, atlasY*, atlasWidth*, atlasHeight*: int

  GlyphAtlas* = object
    width*, height*: int
    nextX*, nextY*, rowHeight*: int
    maxGlyphs*: int
    glyphs*: seq[Glyph]

  TextLayout* = object
    positions*: seq[TextPosition]
    glyphs*: seq[Glyph]

  NativeTextMetrics* {.bycopy.} = object
    width*, ascent*, descent*: cdouble
    glyphCount*: uint32

type FontCallback* = proc(name: cstring) {.cdecl.}

when defined(macosx) or defined(windows):
  proc nativeFontAvailable*(name: cstring, size: cdouble): bool {.importc: "nimculus_font_available", cdecl.}
  proc nativeEnumerateFonts*(callback: FontCallback) {.importc: "nimculus_enumerate_fonts", cdecl.}

when defined(macosx):
  proc nativeMeasureText*(text, fontName: cstring, size: cdouble,
                          metrics: ptr NativeTextMetrics) {.importc: "nimculus_measure_text", cdecl.}
  proc nativeMeasureTextUtf8*(text: cstring, length: uint32, fontName: cstring,
                              size: cdouble, metrics: ptr NativeTextMetrics)
                              {.importc: "nimculus_measure_text_utf8", cdecl.}

proc textPositions*(text: string): seq[TextPosition] =
  result.add(TextPosition(byteOffset: 0, graphemeIndex: 0))
  var grapheme = 0
  for bounds in text.graphemeBounds:
    inc grapheme
    result.add(TextPosition(byteOffset: bounds.b + 1, graphemeIndex: grapheme))

proc isWordChar(ch: Rune): bool =
  let value = int(ch)
  ch.isAlpha or (value >= ord('0') and value <= ord('9')) or
    value in 0x00C0 .. 0x00FF or value in 0x0100 .. 0x017F or
    value in 0x0180 .. 0x024F or value in 0x0300 .. 0x036F or
    value in 0x0400 .. 0x04FF or value in 0x0980 .. 0x09FF or
    value in 0x1E00 .. 0x1EFF or
    value in [0x2D, 0x5F, 0x2E, 0x27, 0x2019, 0x2018, 0x24, 0x25, 0x40,
      0x23, 0x5E, 0x7E, 0x2C, 0x3D, 0x3A, 0x3B, 0x22EF, 0x202F, 0x00A0, 0x2011]

proc sameKey(key: CacheKey, refKey: CacheKeyRef): bool =
  key.textHash == refKey.textHash and key.textLen == refKey.textLen and
    key.fontSize == refKey.fontSize and
    key.hasWrapWidth == refKey.hasWrapWidth and
    (not key.hasWrapWidth or key.wrapWidth == refKey.wrapWidth) and
    key.hasForceWidth == refKey.hasForceWidth and
    (not key.hasForceWidth or key.forceWidth == refKey.forceWidth) and
    (block:
      if refKey.runCount != key.runs.len: false
      else:
        let runs = cast[ptr UncheckedArray[FontRun]](refKey.runs)
        var equal = true
        for index in 0 ..< refKey.runCount:
          if runs[index].len != key.runs[index].len or
              runs[index].fontId != key.runs[index].fontId:
            equal = false
        equal)

proc lineKeyRef(textHash: uint64, textLen: int, fontSize: Pixels,
               runs: openArray[FontRun],
               wrapWidth: float32, hasWrapWidth: bool,
               forceWidth: float32, hasForceWidth: bool): CacheKeyRef =
  result = CacheKeyRef(textHash: textHash, textLen: textLen, fontSize: fontSize,
    wrapWidth: wrapWidth,
    hasWrapWidth: hasWrapWidth, forceWidth: forceWidth, hasForceWidth: hasForceWidth)
  if runs.len > 0:
    result.runs = unsafeAddr runs[0]
    result.runCount = runs.len

proc ownedKey(refKey: CacheKeyRef): CacheKey =
  result = CacheKey(textHash: refKey.textHash, textLen: refKey.textLen,
    fontSize: refKey.fontSize,
    wrapWidth: refKey.wrapWidth, hasWrapWidth: refKey.hasWrapWidth,
    forceWidth: refKey.forceWidth, hasForceWidth: refKey.hasForceWidth)
  for index in 0 ..< refKey.runCount:
    result.runs.add(cast[ptr UncheckedArray[FontRun]](refKey.runs)[index])

proc newLineLayoutCache*(platformLayoutLine: PlatformLayoutLineProc): LineLayoutCache =
  ## The production caller supplies the OS implementation. Tests may supply
  ## an explicit deterministic shaper; there is no fake shaper default.
  LineLayoutCache(platformLayoutLine: platformLayoutLine)

when defined(macosx):
  proc platformTextSystemLayoutLine*(text: string, fontSize: Pixels,
                                     runs: openArray[FontRun]): LineLayout =
    var nativeRuns = newSeq[PlatformFontRun](runs.len)
    for index, run in runs:
      nativeRuns[index] = PlatformFontRun(len: uint32(max(0, run.len)), fontId: run.fontId)
    var nativeMetrics: PlatformLineMetrics
    var nativeGlyphs = newSeq[PlatformGlyph](max(64, text.len * 2 + 8))
    platformLayoutLineNative(text.cstring, uint32(text.len), cdouble(float32(fontSize)),
      if nativeRuns.len > 0: addr nativeRuns[0] else: nil, uint32(nativeRuns.len),
      addr nativeMetrics, if nativeGlyphs.len > 0: addr nativeGlyphs[0] else: nil,
      uint32(nativeGlyphs.len))
    result.fontSize = fontSize
    result.width = px(float32(nativeMetrics.width))
    result.ascent = px(float32(nativeMetrics.ascent))
    result.descent = px(float32(nativeMetrics.descent))
    result.len = int(nativeMetrics.len)
    var shapedByFont: seq[ShapedRun]
    for glyph in nativeGlyphs[0 ..< min(nativeGlyphs.len, int(nativeMetrics.glyphCount))]:
      var runIndex = -1
      for index, run in shapedByFont:
        if run.fontId == glyph.fontId:
          runIndex = index
          break
      if runIndex < 0:
        shapedByFont.add(ShapedRun(fontId: glyph.fontId))
        runIndex = shapedByFont.high
      shapedByFont[runIndex].glyphs.add(ShapedGlyph(id: glyph.glyphId,
        position: Point(x: px(float32(glyph.x)), y: px(float32(glyph.y))),
        index: int(glyph.index), isEmoji: glyph.isEmoji))
    result.runs = shapedByFont

proc findLine(frame: FrameCache, key: CacheKeyRef): int =
  if not frame.linesByHash.hasKey(key.textHash): return -1
  for index, entry in frame.linesByHash[key.textHash]:
    if sameKey(entry.key, key): return index
  -1

proc findWrapped(frame: FrameCache, key: CacheKeyRef): int =
  if not frame.wrappedLinesByHash.hasKey(key.textHash): return -1
  for index, entry in frame.wrappedLinesByHash[key.textHash]:
    if sameKey(entry.key, key): return index
  -1

proc computeWrapBoundaries*(layout: LineLayout, text: string, wrapWidth: float32,
                            maxLines = 0): seq[WrapBoundary] =
  ## Direct port of gpui/src/text_system/line_layout.rs:128. The already
  ## shaped glyph stream is visited once; no candidate-length reshaping occurs.
  var haveFirst = false
  var lastCandidate: tuple[runIx, glyphIx: int]
  var haveCandidate = false
  var lastCandidateX = 0'f32
  var lastBoundary = WrapBoundary(runIx: 0, glyphIx: 0)
  var lastBoundaryX = 0'f32
  var previous = Rune(0)
  for runIx, run in layout.runs:
    for glyphIx, glyph in run.glyphs:
      let boundary = WrapBoundary(runIx: runIx, glyphIx: glyphIx)
      let ch = if glyph.index < text.len: text[glyph.index .. ^1].runeAt(0) else: Rune(0)
      let x = float32(glyph.position.x)
      if ch == Rune('\n'): continue
      if isWordChar(ch):
        if previous == Rune(' ') and ch != Rune(' ') and haveFirst:
          lastCandidate = (boundary.runIx, boundary.glyphIx)
          haveCandidate = true
          lastCandidateX = x
      else:
        if ch != Rune(' ') and haveFirst:
          lastCandidate = (boundary.runIx, boundary.glyphIx)
          haveCandidate = true
          lastCandidateX = x
      if ch != Rune(' ') and not haveFirst:
        haveFirst = true
      var nextX = float32(layout.width)
      if glyphIx + 1 < run.glyphs.len:
        nextX = float32(run.glyphs[glyphIx + 1].position.x)
      else:
        var nextRun = runIx + 1
        while nextRun < layout.runs.len:
          if layout.runs[nextRun].glyphs.len > 0:
            nextX = float32(layout.runs[nextRun].glyphs[0].position.x)
            break
          inc nextRun
      let width = nextX - lastBoundaryX
      let afterLast = boundary.runIx > lastBoundary.runIx or
        (boundary.runIx == lastBoundary.runIx and boundary.glyphIx > lastBoundary.glyphIx)
      if width > wrapWidth and afterLast:
        if maxLines > 0 and result.len >= maxLines - 1: break
        if haveCandidate:
          lastBoundary = WrapBoundary(runIx: lastCandidate.runIx, glyphIx: lastCandidate.glyphIx)
          lastBoundaryX = lastCandidateX
          haveCandidate = false
        else:
          lastBoundary = boundary
          lastBoundaryX = x
        result.add(lastBoundary)
      previous = ch

proc textHash*(text: string): uint64 =
  var hash = 14695981039346656037'u64
  for character in text:
    hash = (hash xor uint64(ord(character))) * 1099511628211'u64
  hash

proc layoutLineByHash*(cache: LineLayoutCache, textHash: uint64, textLen: int,
                       fontSize: Pixels, runs: openArray[FontRun],
                       materializeText: proc(): string,
                       forceWidth: float32 = 0, hasForceWidth = false): ref LineLayout =
  let borrowed = lineKeyRef(textHash, textLen, fontSize, runs, 0, false,
    forceWidth, hasForceWidth)
  let currentIndex = findLine(cache.currentFrame, borrowed)
  if currentIndex >= 0:
    return cache.currentFrame.linesByHash[textHash][currentIndex].layout
  let previousIndex = findLine(cache.previousFrame, borrowed)
  if previousIndex >= 0:
    let entry = cache.previousFrame.linesByHash[textHash][previousIndex]
    cache.currentFrame.linesByHash.mgetOrPut(textHash, @[]).add(entry)
    cache.previousFrame.linesByHash[textHash].delete(previousIndex)
    if cache.previousFrame.linesByHash[textHash].len == 0:
      cache.previousFrame.linesByHash.del(textHash)
    return entry.layout
  if cache.platformLayoutLine == nil:
    raise newException(ValueError, "LineLayoutCache requires a platform shaper")
  let shaped = cache.platformLayoutLine(materializeText(), fontSize, runs)
  var owned = ownedKey(borrowed)
  var layout = new(LineLayout)
  layout[] = shaped
  if hasForceWidth and forceWidth > float32(layout.width): layout.width = px(forceWidth)
  cache.currentFrame.linesByHash.mgetOrPut(textHash, @[]).add(
    LineCacheEntry(key: owned, layout: layout))
  layout

proc layoutLine*(cache: LineLayoutCache, text: string, fontSize: Pixels,
                 runs: openArray[FontRun], forceWidth: float32 = 0,
                 hasForceWidth = false): ref LineLayout =
  let line = text
  cache.layoutLineByHash(line.textHash, line.len, fontSize, runs,
    proc(): string = line, forceWidth, hasForceWidth)

proc layoutWrappedLineByHash*(cache: LineLayoutCache, textHash: uint64,
                              textLen: int, fontSize: Pixels,
                              runs: openArray[FontRun], wrapWidth: float32,
                              materializeText: proc(): string,
                              hasWrapWidth = true, maxLines = 0): ref WrappedLineLayout =
  let borrowed = lineKeyRef(textHash, textLen, fontSize, runs, wrapWidth,
    hasWrapWidth, 0, false)
  let currentIndex = findWrapped(cache.currentFrame, borrowed)
  if currentIndex >= 0:
    return cache.currentFrame.wrappedLinesByHash[textHash][currentIndex].layout
  let previousIndex = findWrapped(cache.previousFrame, borrowed)
  if previousIndex >= 0:
    let entry = cache.previousFrame.wrappedLinesByHash[textHash][previousIndex]
    cache.currentFrame.wrappedLinesByHash.mgetOrPut(textHash, @[]).add(entry)
    cache.previousFrame.wrappedLinesByHash[textHash].delete(previousIndex)
    if cache.previousFrame.wrappedLinesByHash[textHash].len == 0:
      cache.previousFrame.wrappedLinesByHash.del(textHash)
    return entry.layout
  var text = ""
  let unwrapped = if hasWrapWidth:
    text = materializeText()
    cache.layoutLineByHash(textHash, textLen, fontSize, runs,
      proc(): string = text)
  else:
    cache.layoutLineByHash(textHash, textLen, fontSize, runs, materializeText)
  var layout = new(WrappedLineLayout)
  layout.unwrappedLayout = unwrapped
  layout.hasWrapWidth = hasWrapWidth
  layout.wrapWidth = wrapWidth
  if hasWrapWidth:
    layout.wrapBoundaries = computeWrapBoundaries(unwrapped[], text, wrapWidth, maxLines)
  cache.currentFrame.wrappedLinesByHash.mgetOrPut(textHash, @[]).add(
    WrappedCacheEntry(key: ownedKey(borrowed), layout: layout))
  layout

proc layoutWrappedLine*(cache: LineLayoutCache, text: string, fontSize: Pixels,
                        runs: openArray[FontRun], wrapWidth: float32,
                        hasWrapWidth = true, maxLines = 0): ref WrappedLineLayout =
  let line = text
  cache.layoutWrappedLineByHash(line.textHash, line.len, fontSize, runs, wrapWidth,
    proc(): string = line, hasWrapWidth, maxLines)

proc finishFrame*(cache: LineLayoutCache) =
  swap(cache.previousFrame, cache.currentFrame)
  cache.currentFrame.linesByHash.clear()
  cache.currentFrame.wrappedLinesByHash.clear()

proc wrappedRowCount*(layout: WrappedLineLayout): int =
  layout.wrapBoundaries.len + 1

proc newTestLineLayoutCache*(shaper: PlatformLayoutLineProc): LineLayoutCache =
  ## Explicit test-only constructor. Production code must pass the platform
  ## implementation to newLineLayoutCache.
  newLineLayoutCache(shaper)

proc layoutText*(text: string, advance = px(8)): TextLayout =
  result.positions = textPositions(text)
  for rune in text.runes:
    result.glyphs.add(Glyph(codepoint: rune, advance: advance))

proc layoutVisibleText*(text: string, firstGrapheme, lastGrapheme: int,
                        advance = px(8)): TextLayout =
  let positions = textPositions(text)
  if positions.len == 0: return
  let first = max(0, min(firstGrapheme, positions.high))
  let last = max(first, min(lastGrapheme, positions.high))
  let firstByte = positions[first].byteOffset
  let lastByte = positions[last].byteOffset
  let visible = if lastByte > firstByte: text[firstByte ..< lastByte] else: ""
  layoutText(visible, advance)

proc newGlyphAtlas*(width = 1024, height = 1024): GlyphAtlas =
  GlyphAtlas(width: width, height: height, maxGlyphs: 4096)

proc evictGlyphs*(atlas: var GlyphAtlas, keep = 2048) =
  if atlas.glyphs.len <= keep: return
  atlas.glyphs.setLen(0)
  atlas.nextX = 0
  atlas.nextY = 0
  atlas.rowHeight = 0

proc insertGlyphVariant*(atlas: var GlyphAtlas, key: GlyphKey,
                         width, height: int): Glyph =
  if width <= 0 or height <= 0 or width > atlas.width or height > atlas.height:
    return Glyph(codepoint: key.codepoint, key: key)
  for glyph in atlas.glyphs:
    if glyph.key == key: return glyph
  if atlas.glyphs.len >= atlas.maxGlyphs: atlas.evictGlyphs()
  if atlas.nextX + width > atlas.width:
    atlas.nextX = 0
    atlas.nextY += atlas.rowHeight
    atlas.rowHeight = 0
  if atlas.nextY + height > atlas.height: return Glyph(codepoint: key.codepoint, key: key)
  result = Glyph(codepoint: key.codepoint, key: key, atlasX: atlas.nextX, atlasY: atlas.nextY,
                 atlasWidth: width, atlasHeight: height)
  atlas.glyphs.add(result)
  atlas.nextX += width
  atlas.rowHeight = max(atlas.rowHeight, height)

proc insertGlyph*(atlas: var GlyphAtlas, codepoint: Rune, width, height: int): Glyph =
  atlas.insertGlyphVariant(GlyphKey(codepoint: codepoint), width, height)
