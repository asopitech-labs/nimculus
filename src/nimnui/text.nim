import std/unicode
import nimnui/geometry

when defined(macosx):
  {.compile: "platform/macos/text_platform.m".}
  {.passL: "-framework CoreText -framework CoreFoundation".}

type
  TextPosition* = object
    byteOffset*: int
    graphemeIndex*: int

  Glyph* = object
    codepoint*: Rune
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

when defined(macosx):
  proc nativeFontAvailable*(name: cstring, size: cdouble): bool {.importc: "nimculus_font_available", cdecl.}
  type FontCallback* = proc(name: cstring) {.cdecl.}
  proc nativeEnumerateFonts*(callback: FontCallback) {.importc: "nimculus_enumerate_fonts", cdecl.}
  proc nativeMeasureText*(text, fontName: cstring, size: cdouble,
                          metrics: ptr NativeTextMetrics) {.importc: "nimculus_measure_text", cdecl.}

proc isCombiningMark(rune: Rune): bool =
  let value = int(rune)
  (value >= 0x0300 and value <= 0x036F) or
  (value >= 0x1AB0 and value <= 0x1AFF) or
  (value >= 0x1DC0 and value <= 0x1DFF) or
  (value >= 0x20D0 and value <= 0x20FF) or
  (value >= 0xFE20 and value <= 0xFE2F)

proc isGraphemeExtend(rune: Rune): bool =
  let value = int(rune)
  isCombiningMark(rune) or (value >= 0xFE00 and value <= 0xFE0F) or
    (value >= 0x1F3FB and value <= 0x1F3FF)

proc textPositions*(text: string): seq[TextPosition] =
  result.add(TextPosition(byteOffset: 0, graphemeIndex: 0))
  var byteOffset = 0
  var grapheme = 0
  var clusterHasBase = false
  var previousWasJoiner = false
  for rune in text.runes:
    let width = rune.size
    byteOffset += width
    let extend = isGraphemeExtend(rune)
    let joiner = int(rune) == 0x200D
    if not clusterHasBase or (not extend and not previousWasJoiner and not joiner):
      inc grapheme
      result.add(TextPosition(byteOffset: byteOffset, graphemeIndex: grapheme))
    else:
      result[^1].byteOffset = byteOffset
    clusterHasBase = clusterHasBase or not extend
    previousWasJoiner = joiner

proc layoutText*(text: string, advance = px(8)): TextLayout =
  result.positions = textPositions(text)
  for rune in text.runes:
    result.glyphs.add(Glyph(codepoint: rune, advance: advance))

proc layoutVisibleText*(text: string, firstRune, lastRune: int,
                        advance = px(8)): TextLayout =
  var index = 0
  var visible = newStringOfCap(text.len)
  for rune in text.runes:
    if index >= firstRune and index < lastRune: visible.add($rune)
    inc index
  layoutText(visible, advance)

proc newGlyphAtlas*(width = 1024, height = 1024): GlyphAtlas =
  GlyphAtlas(width: width, height: height, maxGlyphs: 4096)

proc evictGlyphs*(atlas: var GlyphAtlas, keep = 2048) =
  if atlas.glyphs.len <= keep: return
  atlas.glyphs.setLen(0)
  atlas.nextX = 0
  atlas.nextY = 0
  atlas.rowHeight = 0

proc insertGlyph*(atlas: var GlyphAtlas, codepoint: Rune, width, height: int): Glyph =
  for glyph in atlas.glyphs:
    if glyph.codepoint == codepoint: return glyph
  if atlas.glyphs.len >= atlas.maxGlyphs: atlas.evictGlyphs()
  if atlas.nextX + width > atlas.width:
    atlas.nextX = 0
    atlas.nextY += atlas.rowHeight
    atlas.rowHeight = 0
  if atlas.nextY + height > atlas.height: return Glyph(codepoint: codepoint)
  result = Glyph(codepoint: codepoint, atlasX: atlas.nextX, atlasY: atlas.nextY,
                 atlasWidth: width, atlasHeight: height)
  atlas.glyphs.add(result)
  atlas.nextX += width
  atlas.rowHeight = max(atlas.rowHeight, height)
