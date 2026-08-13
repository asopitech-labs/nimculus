import std/unicode
import std/tables
import std/options
import std/hashes
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
    color*: array[4, float32]

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
    ## `offset` is a UTF-8 byte offset for the unshaped wrapper. Shaped
    ## boundaries retain the same value from their source glyph.
    offset*, byteOffset*: int
    ## Number of leading spaces to add to this continuation row.
    indent*: int

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
    ## Label metadata is kept on the layout so the renderer does not need to
    ## rediscover the style that produced the glyphs.
    fontSize*: Pixels
    weight*: TextWeight
    lineHeight*: LineHeightStyle
    truncated*: bool

  TextSize* = enum
    ## The UI typography scale used by labels. Values are logical pixels.
    text16, text14, text12, text10

  TextWeight* = enum
    weightRegular, weightMedium, weightSemibold

  TruncationMode* = enum
    truncateEnd, truncateStart, truncateMiddle

  LineHeightStyle* = enum
    textLabel, uiLabel

  LabelSpec* = object
    text*: string
    size*: TextSize
    weight*: TextWeight
    truncation*: TruncationMode
    lineHeight*: LineHeightStyle
    padding*: EdgeInsets

  NativeTextMetrics* {.bycopy.} = object
    width*, ascent*, descent*: cdouble
    glyphCount*: uint32

  FontIdWithSize* = object
    fontId*: uint32
    fontSize*: Pixels

  LineWrapperWidthProc* = proc(ch: Rune): Pixels {.closure.}

  LineWrapperMeasureProc* = proc(fontId: uint32, fontSize: Pixels,
                                 ch: Rune): Pixels {.closure.}

  LineWrapper* = object
    fontId*: uint32
    fontSize*: Pixels
    asciiWidths*: array[128, Option[Pixels]]
    otherWidths*: Table[Rune, Pixels]
    widthProc: LineWrapperWidthProc

  LineWrapperHandleObject = object
    wrapper*: LineWrapper
    poolKey: FontIdWithSize
    active: bool

  LineWrapperHandle* = ref LineWrapperHandleObject

type FontCallback* = proc(name: cstring) {.cdecl.}

const
  ## Short names make a LabelSpec read like the corresponding Zed style.
  textLarge* = text16
  textDefault* = text14
  textSmall* = text12
  textXSmall* = text10
  regular* = weightRegular
  medium* = weightMedium
  semibold* = weightSemibold

const MaxIndent* = 256

var wrapperPool*: Table[FontIdWithSize, seq[LineWrapper]] =
  initTable[FontIdWithSize, seq[LineWrapper]]()

proc hash*(key: FontIdWithSize): Hash =
  result = hash(key.fontId)
  result = result !& hash(float32(key.fontSize))
  result = !$result

proc defaultLineWrapperWidth(ch: Rune): Pixels =
  ## The platform supplies the production callback. This deterministic
  ## fallback keeps the wrapper useful in headless callers and tests.
  discard ch
  px(8)

proc newLineWrapper(fontId: uint32, fontSize: Pixels,
                   widthProc: LineWrapperWidthProc): LineWrapper =
  result.fontId = fontId
  result.fontSize = fontSize
  result.otherWidths = initTable[Rune, Pixels]()
  result.widthProc = if widthProc == nil: defaultLineWrapperWidth else: widthProc

proc returnWrapper(handle: var LineWrapperHandleObject) =
  if handle.active:
    wrapperPool.mgetOrPut(handle.poolKey, @[]).add(handle.wrapper)
    handle.active = false

proc `=destroy`(handle: var LineWrapperHandleObject) =
  handle.returnWrapper()

proc lineWrapper*(fontId: uint32, fontSize: Pixels,
                  widthProc: LineWrapperWidthProc = nil): LineWrapperHandle =
  let key = FontIdWithSize(fontId: fontId, fontSize: fontSize)
  var wrapper: LineWrapper
  if wrapperPool.hasKey(key) and wrapperPool[key].len > 0:
    wrapper = wrapperPool[key].pop()
    wrapper.fontId = fontId
    wrapper.fontSize = fontSize
    if widthProc != nil:
      wrapper.widthProc = widthProc
  else:
    wrapper = newLineWrapper(fontId, fontSize, widthProc)
  new(result)
  result.wrapper = wrapper
  result.poolKey = key
  result.active = true

proc lineWrapper*(fontId: uint32, fontSize: Pixels,
                  widthProc: LineWrapperMeasureProc): LineWrapperHandle =
  lineWrapper(fontId, fontSize, proc(ch: Rune): Pixels =
    widthProc(fontId, fontSize, ch))

proc release*(handle: var LineWrapperHandle) =
  ## Explicit release is useful at ownership boundaries; ARC also invokes
  ## the same return path when the handle goes out of scope.
  if handle != nil and handle.active:
    handle[].returnWrapper()
    handle = nil

proc clearWrapperPool*() =
  wrapperPool.clear()

proc widthForChar*(wrapper: var LineWrapper, ch: Rune): Pixels =
  let value = ch.int
  if value >= 0 and value < 128:
    if wrapper.asciiWidths[value].isSome:
      return wrapper.asciiWidths[value].get
    let measured = if wrapper.widthProc == nil: defaultLineWrapperWidth(ch) else:
      wrapper.widthProc(ch)
    wrapper.asciiWidths[value] = some(measured)
    return measured
  if wrapper.otherWidths.hasKey(ch):
    return wrapper.otherWidths[ch]
  let measured = if wrapper.widthProc == nil: defaultLineWrapperWidth(ch) else:
    wrapper.widthProc(ch)
  wrapper.otherWidths[ch] = measured
  measured

proc widthForChar*(handle: LineWrapperHandle, ch: Rune): Pixels =
  handle.wrapper.widthForChar(ch)

proc wrapperPoolLength*(fontId: uint32, fontSize: Pixels): int =
  let key = FontIdWithSize(fontId: fontId, fontSize: fontSize)
  if wrapperPool.hasKey(key): wrapperPool[key].len else: 0

proc textSizePixels*(size: TextSize): Pixels =
  case size
  of text16: px(16)
  of text14: px(14)
  of text12: px(12)
  of text10: px(10)

proc defaultLabelSpec*(text: string, size = text14, weight = weightRegular,
                       truncation = truncateEnd, lineHeight = uiLabel,
                       padding = EdgeInsets()): LabelSpec =
  LabelSpec(text: text, size: size, weight: weight, truncation: truncation,
    lineHeight: lineHeight, padding: padding)

when defined(macosx) or defined(windows):
  proc nativeFontAvailable*(name: cstring, size: cdouble): bool {.importc: "nimculus_font_available", cdecl.}
  proc nativeEnumerateFonts*(callback: FontCallback) {.importc: "nimculus_enumerate_fonts", cdecl.}

when defined(macosx):
  proc nativeMeasureText*(text, fontName: cstring, size: cdouble,
                          metrics: ptr NativeTextMetrics) {.importc: "nimculus_measure_text", cdecl.}
  proc nativeMeasureTextUtf8*(text: cstring, length: uint32, fontName: cstring,
                              size: cdouble, metrics: ptr NativeTextMetrics)
                              {.importc: "nimculus_measure_text_utf8", cdecl.}

proc wrapperRunes(text: string): tuple[offsets: seq[int], values: seq[Rune]] =
  var byteOffset = 0
  while byteOffset < text.len:
    let ch = text.runeAt(byteOffset)
    result.offsets.add(byteOffset)
    result.values.add(ch)
    byteOffset += ($ch).len

proc leadingIndent(values: openArray[Rune]): int =
  while result < values.len and values[result] == Rune(' '):
    inc result
  min(result, MaxIndent)

proc isWordChar*(ch: Rune): bool

proc wrapLine*(wrapper: var LineWrapper, text: string, wrapWidth: float32,
               maxLines = 0): seq[WrapBoundary] =
  ## Character-level counterpart to computeWrapBoundaries. Widths are cached
  ## by the wrapper, so repeated lines do not invoke the platform measurer.
  let input = wrapperRunes(text)
  if input.values.len == 0 or wrapWidth <= 0: return
  let indent = leadingIndent(input.values)
  let indentWidth = wrapper.widthForChar(Rune(' ')) * float32(indent)
  var lineStart = 0
  var previous = Rune(0)
  var haveFirst = false
  while lineStart < input.values.len:
    var lineWidth = if lineStart == 0: px(0) else: indentWidth
    var candidate = -1
    var index = lineStart
    var wrapped = false
    while index < input.values.len:
      let ch = input.values[index]
      if ch == Rune('\n'):
        inc index
        continue
      let isCandidate = if isWordChar(ch):
        previous == Rune(' ') and ch != Rune(' ') and haveFirst
      else:
        ch != Rune(' ') and haveFirst
      if isCandidate and index > lineStart:
        candidate = index
      lineWidth = lineWidth + wrapper.widthForChar(ch)
      if ch != Rune(' '):
        haveFirst = true
      if float32(lineWidth) > wrapWidth:
        var breakAt = candidate
        if breakAt <= lineStart:
          breakAt = if index > lineStart: index else: index + 1
        if breakAt > lineStart and breakAt <= input.values.len:
          if maxLines > 0 and result.len >= maxLines - 1:
            return
          let offset = if breakAt < input.offsets.len:
            input.offsets[breakAt]
          else:
            text.len
          result.add(WrapBoundary(runIx: 0, glyphIx: breakAt,
            offset: offset, byteOffset: offset, indent: indent))
          lineStart = breakAt
          wrapped = true
        break
      previous = ch
      inc index
    if not wrapped:
      break

proc wrapLine*(handle: LineWrapperHandle, text: string, wrapWidth: float32,
               maxLines = 0): seq[WrapBoundary] =
  handle.wrapper.wrapLine(text, wrapWidth, maxLines)

proc wrapLine*(wrapper: var LineWrapper, text: string, wrapWidth: Pixels,
               maxLines = 0): seq[WrapBoundary] =
  wrapper.wrapLine(text, float32(wrapWidth), maxLines)

proc wrapLine*(handle: LineWrapperHandle, text: string, wrapWidth: Pixels,
               maxLines = 0): seq[WrapBoundary] =
  handle.wrapper.wrapLine(text, float32(wrapWidth), maxLines)

proc shouldTruncateLine*(wrapper: var LineWrapper, text: string,
                         maxWidth: float32): bool =
  var width = px(0)
  for ch in text.runes:
    width = width + wrapper.widthForChar(ch)
  float32(width) > maxWidth

proc shouldTruncateLine*(wrapper: var LineWrapper, text: string,
                         maxWidth: Pixels): bool =
  wrapper.shouldTruncateLine(text, float32(maxWidth))

proc appendRunes(target: var string, values: openArray[Rune]) =
  for ch in values:
    target.add(ch.toUTF8)

proc truncateLine*(wrapper: var LineWrapper, text: string, maxWidth: float32,
                   mode = truncateEnd): string =
  var source: seq[Rune]
  for ch in text.runes:
    source.add(ch)
  if source.len == 0 or not wrapper.shouldTruncateLine(text, maxWidth):
    return text
  let ellipsis = Rune(0x2026)
  let ellipsisWidth = float32(wrapper.widthForChar(ellipsis))
  if maxWidth <= 0 or ellipsisWidth > maxWidth:
    return ""
  let remaining = maxWidth - ellipsisWidth
  var kept: seq[Rune]
  case mode
  of truncateEnd:
    var width = 0'f32
    for ch in source:
      let chWidth = float32(wrapper.widthForChar(ch))
      if width + chWidth > remaining: break
      kept.add(ch)
      width += chWidth
    result.appendRunes(kept)
    result.add(ellipsis.toUTF8)
  of truncateStart:
    var width = 0'f32
    var first = source.len
    while first > 0:
      let chWidth = float32(wrapper.widthForChar(source[first - 1]))
      if width + chWidth > remaining: break
      dec first
      width += chWidth
    result.add(ellipsis.toUTF8)
    result.appendRunes(source[first ..< source.len])
  of truncateMiddle:
    var left = 0
    var right = source.len
    var leftWidth = 0'f32
    var rightWidth = 0'f32
    while left < right:
      if leftWidth <= rightWidth:
        let chWidth = float32(wrapper.widthForChar(source[left]))
        if leftWidth + rightWidth + chWidth > remaining: break
        leftWidth += chWidth
        inc left
      else:
        let chWidth = float32(wrapper.widthForChar(source[right - 1]))
        if leftWidth + rightWidth + chWidth > remaining: break
        rightWidth += chWidth
        dec right
    result.appendRunes(source[0 ..< left])
    result.add(ellipsis.toUTF8)
    result.appendRunes(source[right ..< source.len])

proc truncateLine*(handle: LineWrapperHandle, text: string, maxWidth: float32,
                   mode = truncateEnd): string =
  handle.wrapper.truncateLine(text, maxWidth, mode)

proc truncateLine*(wrapper: var LineWrapper, text: string, maxWidth: Pixels,
                   mode = truncateEnd): string =
  wrapper.truncateLine(text, float32(maxWidth), mode)

proc truncateLine*(handle: LineWrapperHandle, text: string, maxWidth: Pixels,
                   mode = truncateEnd): string =
  handle.wrapper.truncateLine(text, float32(maxWidth), mode)

proc truncateWrappedLine*(wrapper: var LineWrapper, text: string,
                          wrapWidth: float32, maxLines: int,
                          mode = truncateEnd): string =
  let boundaries = wrapper.wrapLine(text, wrapWidth)
  if maxLines <= 0 or boundaries.len < maxLines:
    return text
  let lastStart = boundaries[maxLines - 1].offset
  let prefix = text[0 ..< lastStart]
  let suffix = text[lastStart .. ^1]
  prefix & wrapper.truncateLine(suffix, wrapWidth, mode)

proc truncateWrappedLine*(handle: LineWrapperHandle, text: string,
                          wrapWidth: float32, maxLines: int,
                          mode = truncateEnd): string =
  handle.wrapper.truncateWrappedLine(text, wrapWidth, maxLines, mode)

proc truncateWrappedLine*(wrapper: var LineWrapper, text: string,
                          wrapWidth: Pixels, maxLines: int,
                          mode = truncateEnd): string =
  wrapper.truncateWrappedLine(text, float32(wrapWidth), maxLines, mode)

proc truncateWrappedLine*(handle: LineWrapperHandle, text: string,
                          wrapWidth: Pixels, maxLines: int,
                          mode = truncateEnd): string =
  handle.wrapper.truncateWrappedLine(text, float32(wrapWidth), maxLines, mode)

proc textPositions*(text: string): seq[TextPosition] =
  result.add(TextPosition(byteOffset: 0, graphemeIndex: 0))
  var grapheme = 0
  for bounds in text.graphemeBounds:
    inc grapheme
    result.add(TextPosition(byteOffset: bounds.b + 1, graphemeIndex: grapheme))

proc isWordChar*(ch: Rune): bool =
  let value = int(ch)
  ((value >= ord('A') and value <= ord('Z')) or
    (value >= ord('a') and value <= ord('z')) or
    (value >= ord('0') and value <= ord('9'))) or
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
  var lastCandidateOffset = 0
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
          lastCandidateOffset = glyph.index
      else:
        if ch != Rune(' ') and haveFirst:
          lastCandidate = (boundary.runIx, boundary.glyphIx)
          haveCandidate = true
          lastCandidateX = x
          lastCandidateOffset = glyph.index
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
          lastBoundary = WrapBoundary(runIx: lastCandidate.runIx,
            glyphIx: lastCandidate.glyphIx, offset: lastCandidateOffset,
            byteOffset: lastCandidateOffset)
          lastBoundaryX = lastCandidateX
          haveCandidate = false
        else:
          lastBoundary = WrapBoundary(runIx: boundary.runIx,
            glyphIx: boundary.glyphIx, offset: glyph.index,
            byteOffset: glyph.index)
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

proc appendLabelRune(text: var string, rune: Rune) =
  text.add(rune.toUTF8)

proc layoutLabel*(spec: LabelSpec, availableWidth: Pixels): TextLayout =
  ## Lay out a single-line label and apply its truncation policy before glyph
  ## creation. Padding belongs to the label, so callers pass the full slot
  ## width instead of subtracting chrome-specific constants themselves.
  let advance = textSizePixels(spec.size)
  let contentWidth = max(0'f32, float32(availableWidth) -
    float32(spec.padding.left) - float32(spec.padding.right))
  let capacity = int(contentWidth / max(1'f32, float32(advance)))

  var source: seq[Rune] = @[]
  for rune in spec.text.runes:
    source.add(rune)

  var visible: seq[Rune] = @[]
  result.truncated = source.len > capacity
  if not result.truncated:
    visible = source
  elif capacity <= 0:
    discard
  elif capacity == 1:
    visible.add(Rune(0x2026))
  else:
    let retained = capacity - 1
    case spec.truncation
    of truncateEnd:
      for index in 0 ..< retained:
        visible.add(source[index])
      visible.add(Rune(0x2026))
    of truncateStart:
      visible.add(Rune(0x2026))
      for index in source.len - retained ..< source.len:
        visible.add(source[index])
    of truncateMiddle:
      let leading = retained div 2
      let trailing = retained - leading
      for index in 0 ..< leading:
        visible.add(source[index])
      visible.add(Rune(0x2026))
      for index in source.len - trailing ..< source.len:
        visible.add(source[index])

  var rendered = newStringOfCap(visible.len)
  for rune in visible:
    rendered.appendLabelRune(rune)
  result = layoutText(rendered, advance)
  result.fontSize = advance
  result.weight = spec.weight
  result.lineHeight = spec.lineHeight
  result.truncated = source.len > visible.len

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
