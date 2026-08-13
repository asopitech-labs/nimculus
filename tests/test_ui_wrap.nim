import std/unittest
import std/unicode
import std/strutils
import nimnui/geometry
import nimnui/text

proc fixedWidth(ch: Rune): Pixels =
  discard ch
  px(8)

proc fixedShaper(text: string, fontSize: Pixels,
                 runs: openArray[FontRun]): LineLayout =
  result.fontSize = fontSize
  result.ascent = px(12)
  result.descent = px(3)
  result.len = text.len
  var run = ShapedRun(fontId: if runs.len == 0: 0 else: runs[0].fontId)
  var x = 0'f32
  var byteOffset = 0
  for ch in text.runes:
    run.glyphs.add(ShapedGlyph(id: uint32(ch.int),
      position: Point(x: px(x), y: px(0)), index: byteOffset))
    x += 8
    byteOffset += ($ch).len
  result.width = px(x)
  result.runs = @[run]

suite "pooled line wrapper":
  test "CJK is a wrap candidate and is not a word character":
    check not isWordChar(Rune(0x4F60))
    var wrapper = lineWrapper(1, px(14), fixedWidth)
    let boundaries = wrapper.wrapLine("Hello world你好世界", 96'f32)
    var insideCjk = false
    for boundary in boundaries:
      if boundary.offset > 11 and boundary.offset < 23:
        insideCjk = true
    check insideCjk
    wrapper.release()

  test "continuation boundaries preserve a capped indentation":
    var wrapper = lineWrapper(2, px(14), fixedWidth)
    let fourSpaces = wrapper.wrapLine("    alpha beta gamma", 40'f32)
    check fourSpaces.len > 0
    for boundary in fourSpaces:
      check boundary.indent == 4
    wrapper.release()

    var longIndent = lineWrapper(2, px(14), fixedWidth)
    let threeHundredSpaces = longIndent.wrapLine(" ".repeat(300) & "alpha", 2400'f32)
    check threeHundredSpaces.len > 0
    for boundary in threeHundredSpaces:
      check boundary.indent == 256
    longIndent.release()

  test "the pool reuses one wrapper and caches character widths":
    clearWrapperPool()
    var calls = 0
    for index in 0 ..< 1000:
      block:
        let wrapper = lineWrapper(3, px(14), proc(ch: Rune): Pixels =
          inc calls
          px(8))
        discard wrapper.widthForChar(Rune(65 + (index mod 128)))
        discard wrapper.widthForChar(Rune(0x4F60))
        discard wrapper.widthForChar(Rune(0x1F642))
    check wrapperPoolLength(3, px(14)) == 1
    check calls <= 128 + 2

  test "unshaped and shaped wrappers agree for ASCII fixture lines":
    var wrapper = lineWrapper(4, px(14), fixedWidth)
    let runs = @[FontRun(len: 0, fontId: 4)]
    var matching = 0
    for index in 0 ..< 20:
      let line = "alpha beta gamma delta fixture" & $index
      let shaped = fixedShaper(line, px(14), runs)
      let shapedBoundaries = computeWrapBoundaries(shaped, line, 80'f32)
      let unshapedBoundaries = wrapper.wrapLine(line, 80'f32)
      var same = shapedBoundaries.len == unshapedBoundaries.len
      if same:
        for boundaryIndex in 0 ..< shapedBoundaries.len:
          if shapedBoundaries[boundaryIndex].offset !=
              unshapedBoundaries[boundaryIndex].offset:
            same = false
      if same:
        inc matching
    check matching == 20
    wrapper.release()
