import std/unicode
import nimnui/geometry

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
    glyphs*: seq[Glyph]

  TextLayout* = object
    positions*: seq[TextPosition]
    glyphs*: seq[Glyph]

proc isCombiningMark(rune: Rune): bool =
  let value = int(rune)
  (value >= 0x0300 and value <= 0x036F) or
  (value >= 0x1AB0 and value <= 0x1AFF) or
  (value >= 0x1DC0 and value <= 0x1DFF) or
  (value >= 0x20D0 and value <= 0x20FF) or
  (value >= 0xFE20 and value <= 0xFE2F)

proc textPositions*(text: string): seq[TextPosition] =
  result.add(TextPosition(byteOffset: 0, graphemeIndex: 0))
  var byteOffset = 0
  var grapheme = 0
  var previousWasBase = false
  for rune in text.runes:
    let width = rune.size
    byteOffset += width
    if not isCombiningMark(rune) or not previousWasBase:
      inc grapheme
      result.add(TextPosition(byteOffset: byteOffset, graphemeIndex: grapheme))
    else:
      result[^1].byteOffset = byteOffset
    previousWasBase = not isCombiningMark(rune)

proc layoutText*(text: string, advance = px(8)): TextLayout =
  result.positions = textPositions(text)
  for rune in text.runes:
    result.glyphs.add(Glyph(codepoint: rune, advance: advance))

proc newGlyphAtlas*(width = 1024, height = 1024): GlyphAtlas =
  GlyphAtlas(width: width, height: height)

proc insertGlyph*(atlas: var GlyphAtlas, codepoint: Rune, width, height: int): Glyph =
  for glyph in atlas.glyphs:
    if glyph.codepoint == codepoint: return glyph
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
