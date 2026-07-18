import std/unicode
import graphemes
import nimnui/geometry

when defined(macosx):
  {.compile: "platform/macos/text_platform.m".}
  {.passL: "-framework Cocoa -framework CoreText -framework CoreFoundation".}

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

proc textPositions*(text: string): seq[TextPosition] =
  ## Return byte offsets at Unicode extended grapheme boundaries.
  ## Zed uses unicode-segmentation for this same display/navigation contract;
  ## nim-graphemes implements Unicode TR29 rather than a hand-written subset.
  result.add(TextPosition(byteOffset: 0, graphemeIndex: 0))
  var grapheme = 0
  for bounds in text.graphemeBounds:
    inc grapheme
    # graphemeBounds uses inclusive byte slices; TextPosition stores the
    # conventional exclusive end offset used by PieceTable and text slices.
    result.add(TextPosition(byteOffset: bounds.b + 1, graphemeIndex: grapheme))

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
