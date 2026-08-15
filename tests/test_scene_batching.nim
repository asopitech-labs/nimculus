import std/unittest
import std/sequtils
import nimnui/geometry
import nimnui/render

proc fixtureBounds(): Rect =
  Rect(origin: Point(x: px(0), y: px(0)),
    size: Size(width: px(1), height: px(1)))

proc newPaint(): PaintList =
  result.invalidate(fixtureBounds())

proc quadCommand(): PaintCommand =
  let bounds = fixtureBounds()
  PaintCommand(kind: rectangle, bounds: bounds, clip: bounds)

proc shadowCommand(): PaintCommand =
  let bounds = fixtureBounds()
  PaintCommand(kind: shadow, bounds: bounds, clip: bounds)

proc spriteCommand(textureId, tileId: uint32): PaintCommand =
  let bounds = fixtureBounds()
  PaintCommand(kind: image, bounds: bounds, clip: bounds, imageId: textureId,
    textureId: textureId, tileId: tileId)

proc batchesOf(paint: PaintList): seq[PrimitiveBatch] =
  for batch in paint.batches(): result.add(batch)

suite "scene batching":
  test "ordinary insertion assigns monotonically increasing draw orders":
    var paint = newPaint()
    paint.add(quadCommand())
    paint.add(shadowCommand())
    paint.add(quadCommand())

    check paint.commands[0].order == 0
    check paint.commands[1].order == 1
    check paint.commands[2].order == 2

  test "interleaved quads and sprites produce one-item batches":
    var paint = newPaint()
    for order in 0'u32 ..< 16:
      if order mod 2 == 0:
        paint.add(quadCommand(), order)
      else:
        paint.add(spriteCommand(0, order), order)

    paint.finish()
    let batches = paint.batchesOf()
    check batches.len == 16
    check batches.allIt(it.len == 1)

  test "grouped quads and sprites produce two batches of eight":
    var paint = newPaint()
    for order in 0'u32 ..< 8:
      paint.add(quadCommand(), order)
    for order in 8'u32 ..< 16:
      paint.add(spriteCommand(0, order), order)

    paint.finish()
    let batches = paint.batchesOf()
    check batches.len == 2
    check batches[0].kind == pkQuad
    check batches[1].kind == pkPolychromeSprite
    check batches[0].len == 8
    check batches[1].len == 8

  test "same-order shadow wins the declaration-order tie-break":
    var paint = newPaint()
    paint.add(quadCommand(), 7)
    paint.add(shadowCommand(), 7)

    paint.finish()
    let batches = paint.batchesOf()
    check batches.len == 2
    check batches[0].kind == pkShadow
    check batches[0].len == 1
    check batches[1].kind == pkQuad
    check batches[1].len == 1

  test "same-order sprites split only when their texture changes":
    var twoTextures = newPaint()
    for index in 0'u32 ..< 100:
      let textureId = if index < 50: 1'u32 else: 2'u32
      twoTextures.add(spriteCommand(textureId, index), 11)
    twoTextures.finish()
    let splitBatches = twoTextures.batchesOf()
    check splitBatches.len == 2
    check splitBatches[0].len == 50
    check splitBatches[1].len == 50
    check splitBatches[0].textureId != splitBatches[1].textureId

    var oneTexture = newPaint()
    for index in 0'u32 ..< 100:
      oneTexture.add(spriteCommand(3, index), 11)
    oneTexture.finish()
    let oneBatch = oneTexture.batchesOf()
    check oneBatch.len == 1
    check oneBatch[0].len == 100

  test "randomly ordered primitives are emitted exactly once":
    var paint = newPaint()
    var state = 0x12345678'u32
    for index in 0 ..< 1000:
      state = state * 1664525'u32 + 1013904223'u32
      let order = state mod 257'u32
      case index mod 3
      of 0:
        paint.add(shadowCommand(), order)
      of 1:
        paint.add(spriteCommand(state mod 2'u32, state mod 1000'u32), order)
      else:
        paint.add(quadCommand(), order)

    paint.finish()
    var emitted = 0
    var duplicateCount = 0
    var lastEnd: array[PrimitiveKind, int]
    for batch in paint.batchesOf():
      check batch.len > 0
      if batch.range.a != lastEnd[batch.kind]: inc duplicateCount
      lastEnd[batch.kind] += batch.len
      emitted += batch.len

    check emitted == 1000
    check duplicateCount == 0
