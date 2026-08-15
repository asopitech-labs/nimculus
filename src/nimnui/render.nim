import std/algorithm
import std/math
import std/options
import std/tables
import nimnui/geometry
import nimculus/settings

type
  Color* = object
    red*, green*, blue*, alpha*: float32

  ## British spelling is kept as an alias because the paint API describes
  ## this as a colour payload while the rest of the renderer uses `Color`.
  Colour* = Color

  ElevationIndex* = enum
    background, surface, editorSurface, elevatedSurface, modalSurface

  ## Zed uses a narrow scrollbar for ordinary panels and a wider strip for an
  ## editor.  Keep this as a semantic style rather than making callers repeat
  ## the pixel values at every layout site.
  ScrollbarStyle* = enum
    regular, editor

  ## Zed's Divider has three semantic color choices. The native renderer
  ## resolves these names against the same theme palette as the rest of the
  ## UI; keeping the choice on the retained command prevents all dividers
  ## from collapsing into the workspace separator's default color.
  DividerColor* = enum
    dividerBorder, dividerBorderFaded, dividerBorderVariant

  DividerStyle* = enum
    dividerSolid, dividerDashed

  BoxShadow* = object
    offset*: Point
    blurRadius*: Pixels
    color*: Color
    colour*: Color

  PaintKind* = enum
    rectangle, border, roundedRectangle, text, image, clip, transform,
    shadow, caret, selection, scrollbar,
    ## Workspace chrome has semantic paint kinds so the Metal backend can use
    ## the active theme rather than the gallery's fixed placeholder blue.
    workspaceBackground, workspacePanel, workspaceSeparator, editorActiveLine, editorBackground,
    ## Zed rules the vertical scrollbar's inner edge in its own lighter role
    ## (`scrollbar.track.border`), distinct from the workspace `border`.
    scrollbarTrack, editorDiagnostic, roundedSelection,
    ## A one-pixel path command. The macOS backend currently lowers this
    ## small path vocabulary to pixel-aligned quads, which preserves the
    ## retained paint ABI while supporting Zed's dashed divider.
    strokedPath

  ## The draw-order streams mirror GPUI's scene primitive streams.  The
  ## declaration order is intentional: it is the tie-break when two streams
  ## have the same order.
  PrimitiveKind* = enum
    pkShadow, pkQuad, pkPath, pkUnderline,
    pkMonochromeSprite, pkSubpixelSprite, pkPolychromeSprite, pkSurface

  ## The two possible width changes at a row join are kept as data rather
  ## than exposed as path operations. The Metal backend consumes the row
  ## rectangles and emits the concrete Zed-shaped selection directly.
  RoundedSelectionJoin* = enum
    selectionJoinEqual, selectionJoinInset, selectionJoinOutset

  PaintCommand* = object
    kind*: PaintKind
    ## Zed gets this from BoundsTree.  Nimculus uses a monotonically assigned
    ## counter until BoundsTree is ported.
    order*: uint32
    bounds*: Rect
    sourceBounds*: Rect
    clip*: Rect
    text*: string
    radius*: Pixels
    blurRadius*: Pixels
    strokeWidth*: Pixels
    color*: Color
    colour*: Color
    transform*: Transform2D
    imageId*: uint32
    ## Sprite atlas identity used by batching.  imageId remains the native
    ## command payload; these fields make the future atlas split explicit.
    tileId*: uint32
    textureId*: uint32
    dividerColor*: DividerColor
    dividerStyle*: DividerStyle
    dashArray*: seq[Pixels]
    ## Only populated for roundedSelection. Keeping the rows on the paint
    ## command lets the retained command stay one concrete shape instead of
    ## becoming one rounded rectangle per line.
    selectionRows*: seq[Rect]

  ## Per-element data that survives a frame only when the element is accessed
  ## again.  The first retained field is the scroll offset used by the
  ## editor; more element-local fields can be added without changing the
  ## frame lifecycle.
  ElementState* = object
    offset*: Pixels

  PaintList* = object
    commands*: seq[PaintCommand]
    ## Per-primitive streams are sorted by finish() and consumed by batches().
    shadows*: seq[PaintCommand]
    quads*: seq[PaintCommand]
    paths*: seq[PaintCommand]
    underlines*: seq[PaintCommand]
    monochromeSprites*: seq[PaintCommand]
    subpixelSprites*: seq[PaintCommand]
    polychromeSprites*: seq[PaintCommand]
    surfaces*: seq[PaintCommand]
    dirty*: seq[Rect]
    clipStack*: seq[Rect]
    transformStack*: seq[Transform2D]
    ## Element offsets are ambient prepaint translations. Unlike an affine
    ## transform they are pixel-snapped when a command is resolved, matching
    ## GPUI's `element_offset` rather than changing layout geometry.
    elementOffsetStack*: seq[Point]
    scaleFactor*: float32
    elementStates*: Table[string, ElementState]
    nextOrder: uint32

  ## A batch points into one of PaintList's sorted streams.  Sprite batches
  ## additionally identify the atlas texture whose state must be bound.
  PrimitiveBatch* = object
    range*: HSlice[int, int]
    case kind*: PrimitiveKind
    of pkMonochromeSprite, pkSubpixelSprite, pkPolychromeSprite:
      textureId*: uint32
    else:
      discard

  ## A Frame is the retained paint list plus the per-element state touched by
  ## that frame.  Keeping the alias preserves the existing paint API while
  ## allowing Window to own two independently buffered frames.
  Frame* = PaintList

proc intersects*(a, b: Rect): bool =
  float32(a.origin.x) < float32(b.origin.x + b.size.width) and
  float32(b.origin.x) < float32(a.origin.x + a.size.width) and
  float32(a.origin.y) < float32(b.origin.y + b.size.height) and
  float32(b.origin.y) < float32(a.origin.y + a.size.height)

proc intersection*(a, b: Rect): Rect =
  let left = max(float32(a.origin.x), float32(b.origin.x))
  let top = max(float32(a.origin.y), float32(b.origin.y))
  let right = min(float32(a.origin.x + a.size.width), float32(b.origin.x + b.size.width))
  let bottom = min(float32(a.origin.y + a.size.height), float32(b.origin.y + b.size.height))
  Rect(origin: Point(x: px(left), y: px(top)), size: Size(width: px(max(0'f32, right - left)),
    height: px(max(0'f32, bottom - top))))

proc unionRect(a, b: Rect): Rect =
  let left = min(float32(a.origin.x), float32(b.origin.x))
  let top = min(float32(a.origin.y), float32(b.origin.y))
  let right = max(float32(a.origin.x + a.size.width),
    float32(b.origin.x + b.size.width))
  let bottom = max(float32(a.origin.y + a.size.height),
    float32(b.origin.y + b.size.height))
  Rect(origin: Point(x: px(left), y: px(top)),
    size: Size(width: px(right - left), height: px(bottom - top)))

proc currentElementOffset*(paint: PaintList): Point =
  if paint.elementOffsetStack.len > 0: paint.elementOffsetStack[^1]
  else: Point()

proc effectiveScaleFactor(paint: PaintList): float32 =
  if paint.scaleFactor > 0: paint.scaleFactor else: 1.0'f32

proc pixelSnap*(value: Pixels, scaleFactor: float32): Pixels =
  ## Snap an ambient offset to the nearest device pixel. Midpoint ties use
  ## Zed's round-half-toward-zero rule: 0.5 becomes 0, while 0.5001 becomes
  ## 1 (and the negative values mirror those results).
  let scale = if scaleFactor > 0: scaleFactor else: 1.0'f32
  let scaled = float32(value) * scale
  let magnitude = ceil(abs(scaled) - 0.5'f32)
  let snapped = if scaled < 0: -magnitude else: magnitude
  px(snapped / scale)

proc pixelSnapPoint*(point: Point, scaleFactor: float32): Point =
  Point(x: pixelSnap(point.x, scaleFactor), y: pixelSnap(point.y, scaleFactor))

proc resolvedBounds(paint: PaintList, bounds: Rect, transform: Transform2D): Rect =
  let transformed = transform.transformRect(bounds)
  let offset = pixelSnapPoint(paint.currentElementOffset(), paint.effectiveScaleFactor())
  transformed.offset(offset.x, offset.y)

proc invalidate*(paint: var PaintList, rect: Rect) =
  if float32(rect.size.width) <= 0 or float32(rect.size.height) <= 0: return
  var merged = rect
  var index = 0
  while index < paint.dirty.len:
    if intersects(merged, paint.dirty[index]):
      merged = unionRect(merged, paint.dirty[index])
      paint.dirty.delete(index)
      index = 0
    else:
      inc index
  paint.dirty.add(merged)

proc primitiveKindFor(kind: PaintKind): PrimitiveKind =
  case kind
  of shadow: pkShadow
  of text: pkMonochromeSprite
  of image: pkPolychromeSprite
  of strokedPath: pkPath
  else: pkQuad

proc streamLen(paint: PaintList, kind: PrimitiveKind): int =
  case kind
  of pkShadow: paint.shadows.len
  of pkQuad: paint.quads.len
  of pkPath: paint.paths.len
  of pkUnderline: paint.underlines.len
  of pkMonochromeSprite: paint.monochromeSprites.len
  of pkSubpixelSprite: paint.subpixelSprites.len
  of pkPolychromeSprite: paint.polychromeSprites.len
  of pkSurface: paint.surfaces.len

proc streamCommand(paint: PaintList, kind: PrimitiveKind, index: int): PaintCommand =
  case kind
  of pkShadow: paint.shadows[index]
  of pkQuad: paint.quads[index]
  of pkPath: paint.paths[index]
  of pkUnderline: paint.underlines[index]
  of pkMonochromeSprite: paint.monochromeSprites[index]
  of pkSubpixelSprite: paint.subpixelSprites[index]
  of pkPolychromeSprite: paint.polychromeSprites[index]
  of pkSurface: paint.surfaces[index]

proc appendToStream(paint: var PaintList, command: PaintCommand) =
  case primitiveKindFor(command.kind)
  of pkShadow: paint.shadows.add(command)
  of pkQuad: paint.quads.add(command)
  of pkPath: paint.paths.add(command)
  of pkUnderline: paint.underlines.add(command)
  of pkMonochromeSprite: paint.monochromeSprites.add(command)
  of pkSubpixelSprite: paint.subpixelSprites.add(command)
  of pkPolychromeSprite: paint.polychromeSprites.add(command)
  of pkSurface: paint.surfaces.add(command)

proc appendCommand(paint: var PaintList, command: PaintCommand, order: uint32) =
  let transform = if paint.transformStack.len > 0: paint.transformStack[^1] else: identityTransform()
  let transformedBounds = paint.resolvedBounds(command.bounds, transform)
  var effectiveClip = transformedBounds
  if paint.clipStack.len > 0:
    effectiveClip = intersection(effectiveClip, paint.clipStack[^1])
  for dirty in paint.dirty:
    let visible = intersection(effectiveClip, dirty)
    if float32(visible.size.width) > 0 and float32(visible.size.height) > 0:
      var clipped = command
      clipped.order = order
      clipped.sourceBounds = command.bounds
      clipped.bounds = transformedBounds
      ## Damage filtering decides whether a command is emitted; it is not a
      ## content mask. Keep `clip` equal to the effective content clip.
      clipped.clip = effectiveClip
      clipped.transform = transform
      paint.commands.add(clipped)
      paint.appendToStream(clipped)

proc add*(paint: var PaintList, command: PaintCommand) =
  let order = paint.nextOrder
  if paint.nextOrder < high(uint32): inc paint.nextOrder
  paint.appendCommand(command, order)

proc add*(paint: var PaintList, command: PaintCommand, order: uint32) =
  ## Explicit order is used by callers that already have a shared layer order
  ## (and by tests); ordinary insertion uses the counter overload above.
  if order < high(uint32) and paint.nextOrder <= order:
    paint.nextOrder = order + 1
  paint.appendCommand(command, order)

proc spriteTileId(command: PaintCommand): uint32 =
  if command.tileId != 0: command.tileId else: command.imageId

proc spriteTextureId(command: PaintCommand): uint32 =
  if command.textureId != 0: command.textureId else: command.imageId

proc compareOrder(left, right: PaintCommand): int = cmp(left.order, right.order)

proc compareSpriteOrder(left, right: PaintCommand): int =
  result = cmp(left.order, right.order)
  if result == 0:
    result = cmp(left.spriteTileId, right.spriteTileId)

proc finish*(paint: var PaintList) =
  ## Sort each stream exactly once before constructing the merge iterator.
  ## Sprite tile order groups atlas tiles, while textureId remains the batch
  ## break, matching GPUI's `(order, tile_id)` sort and texture check.
  paint.shadows.sort(compareOrder)
  paint.quads.sort(compareOrder)
  paint.paths.sort(compareOrder)
  paint.underlines.sort(compareOrder)
  paint.monochromeSprites.sort(compareSpriteOrder)
  paint.subpixelSprites.sort(compareSpriteOrder)
  paint.polychromeSprites.sort(compareSpriteOrder)
  paint.surfaces.sort(compareOrder)

proc isSpriteKind(kind: PrimitiveKind): bool =
  kind in {pkMonochromeSprite, pkSubpixelSprite, pkPolychromeSprite}

proc before(leftOrder: uint32, leftKind: PrimitiveKind,
            rightOrder: uint32, rightKind: PrimitiveKind): bool =
  leftOrder < rightOrder or
    (leftOrder == rightOrder and ord(leftKind) < ord(rightKind))

type
  BatchHead = object
    valid: bool
    order: uint32
    kind: PrimitiveKind

proc makeBatch(kind: PrimitiveKind, range: HSlice[int, int], textureId: uint32): PrimitiveBatch =
  case kind
  of pkMonochromeSprite, pkSubpixelSprite, pkPolychromeSprite:
    PrimitiveBatch(range: range, kind: kind, textureId: textureId)
  else:
    PrimitiveBatch(range: range, kind: kind)

proc len*(batch: PrimitiveBatch): int = batch.range.len

iterator batches*(paint: PaintList): PrimitiveBatch =
  ## Merge the eight sorted streams by `(order, PrimitiveKind)`.  The second
  ## head is the exclusive upper bound for the current batch; sprite streams
  ## also stop when their atlas texture changes.
  var starts: array[PrimitiveKind, int]
  while true:
    var first = BatchHead(valid: false, order: high(uint32), kind: pkShadow)
    var second = BatchHead(valid: false, order: high(uint32), kind: pkShadow)
    for kind in PrimitiveKind:
      let index = starts[kind]
      if index >= paint.streamLen(kind): continue
      let command = paint.streamCommand(kind, index)
      let head = BatchHead(valid: true, order: command.order, kind: kind)
      if not first.valid or head.order < first.order or
          (head.order == first.order and ord(head.kind) < ord(first.kind)):
        second = first
        first = head
      elif not second.valid or head.order < second.order or
          (head.order == second.order and ord(head.kind) < ord(second.kind)):
        second = head
    if not first.valid: break

    let maxOrder = if second.valid: second.order else: high(uint32)
    let maxKind = if second.valid: second.kind else: pkShadow
    let batchKind = first.kind
    let batchStart = starts[batchKind]
    var batchEnd = batchStart + 1
    let firstCommand = paint.streamCommand(batchKind, batchStart)
    let textureId = firstCommand.spriteTextureId
    while batchEnd < paint.streamLen(batchKind):
      let command = paint.streamCommand(batchKind, batchEnd)
      if not before(command.order, batchKind, maxOrder, maxKind): break
      if batchKind.isSpriteKind and command.spriteTextureId != textureId: break
      inc batchEnd
    starts[batchKind] = batchEnd
    yield makeBatch(batchKind, batchStart ..< batchEnd, textureId)

proc newFrame*(): Frame =
  result.elementStates = initTable[string, ElementState]()

proc lookupElementState*(frame: var Frame, key: string): Option[ElementState] =
  ## Frame is a value type containing command sequences and tables. Keep this
  ## read-only lookup on a var parameter so callers do not deep-copy a frame.
  if frame.elementStates.hasKey(key): some(frame.elementStates[key])
  else: none(ElementState)

proc accessElementState*(frame: var Frame, key: string,
                         defaultState = ElementState()): var ElementState =
  ## mgetOrPut also initializes a zero-valued Table. Once initialized, the
  ## Table storage is retained across frame reuse; an empty table is not
  ## reinitialized on every access.
  frame.elementStates.mgetOrPut(key, defaultState)

proc accessElementState*(frame: var Frame, previous: var Frame, key: string,
                         defaultState = ElementState()): var ElementState =
  ## `previous` must stay a var parameter: passing a Frame by value copies its
  ## retained command storage before the element-state lookup runs.
  if not frame.elementStates.hasKey(key):
    let carried = previous.lookupElementState(key)
    if carried.isSome:
      frame.elementStates[key] = carried.get
  frame.accessElementState(key, defaultState)

proc finishFrame*(frame: var Frame, previous: var Frame) =
  ## State is inserted into `frame` only through accessElementState, so the
  ## frame table is already exactly the set of states touched by this frame.
  ## Empty the old rendered frame in place before the swap. Table.clear keeps
  ## its bucket storage, avoiding both a per-frame allocation and a later
  ## rehash when the same element is accessed again.
  previous.elementStates.clear()

proc clear*(paint: var PaintList) =
  paint.commands.setLen(0)
  paint.shadows.setLen(0)
  paint.quads.setLen(0)
  paint.paths.setLen(0)
  paint.underlines.setLen(0)
  paint.monochromeSprites.setLen(0)
  paint.subpixelSprites.setLen(0)
  paint.polychromeSprites.setLen(0)
  paint.surfaces.setLen(0)
  paint.dirty.setLen(0)
  paint.clipStack.setLen(0)
  paint.transformStack.setLen(0)
  paint.elementOffsetStack.setLen(0)
  paint.nextOrder = 0
  ## Element state intentionally survives clear. finishFrame clears the old
  ## rendered frame after the new frame has performed its carryover lookups;
  ## retaining this table here preserves its bucket storage for the next use.

proc drawRectangle*(paint: var PaintList, bounds: Rect) =
  paint.add(PaintCommand(kind: rectangle, bounds: bounds, clip: bounds))

proc drawText*(paint: var PaintList, bounds: Rect, text: string) =
  paint.add(PaintCommand(kind: PaintKind.text, bounds: bounds, clip: bounds, text: text))

proc drawBorder*(paint: var PaintList, bounds: Rect) = paint.add(PaintCommand(kind: border,
    bounds: bounds, clip: bounds))
proc drawRoundedRectangle*(paint: var PaintList, bounds: Rect, radius: Pixels) =
  paint.add(PaintCommand(kind: roundedRectangle, bounds: bounds, clip: bounds, radius: radius))
proc drawImage*(paint: var PaintList, bounds: Rect, imageId: uint32 = 0) =
  paint.add(PaintCommand(kind: image, bounds: bounds, clip: bounds, imageId: imageId,
    tileId: imageId, textureId: imageId))
proc pushClip*(paint: var PaintList, bounds: Rect) =
  paint.add(PaintCommand(kind: clip, bounds: bounds, clip: bounds))
  let transform = if paint.transformStack.len > 0: paint.transformStack[^1] else: identityTransform()
  let transformedBounds = paint.resolvedBounds(bounds, transform)
  let effective = if paint.clipStack.len > 0:
    intersection(transformedBounds, paint.clipStack[^1])
  else: transformedBounds
  paint.clipStack.add(effective)
proc popClip*(paint: var PaintList) =
  if paint.clipStack.len > 0: paint.clipStack.setLen(paint.clipStack.len - 1)

proc currentContentMask*(paint: PaintList, fallback: Rect): Rect =
  ## The mask active at prepaint insertion time. A caller outside a clip
  ## region uses its own bounds as the finite fallback mask.
  if paint.clipStack.len > 0: paint.clipStack[^1] else: fallback
proc pushTransform*(paint: var PaintList, transform: Transform2D) =
  let current = if paint.transformStack.len > 0: paint.transformStack[^1] else: identityTransform()
  paint.transformStack.add(current * transform)
proc popTransform*(paint: var PaintList) =
  if paint.transformStack.len > 0: paint.transformStack.setLen(paint.transformStack.len - 1)

proc pushElementOffset*(paint: var PaintList, offset: Point) =
  let current = paint.currentElementOffset()
  paint.elementOffsetStack.add(Point(x: current.x + offset.x, y: current.y + offset.y))

proc pushAbsoluteElementOffset*(paint: var PaintList, offset: Point) =
  paint.elementOffsetStack.add(offset)

proc popElementOffset*(paint: var PaintList) =
  if paint.elementOffsetStack.len > 0:
    paint.elementOffsetStack.setLen(paint.elementOffsetStack.len - 1)
proc packedShadowColour(colour: Colour): uint32 =
  let packedColor = proc(value: float32): uint32 =
    uint32(max(0'f32, min(1'f32, value)) * 255'f32 + 0.5'f32)
  packedColor(colour.red) or
    (packedColor(colour.green) shl 8) or
    (packedColor(colour.blue) shl 16) or
    (packedColor(colour.alpha) shl 24)

proc drawShadow*(paint: var PaintList, bounds: Rect, offset: Point,
                 blurRadius: Pixels, colour: Colour)
proc drawShadow*(paint: var PaintList, bounds: Rect) =
  paint.drawShadow(bounds, Point(), px(0), Colour(red: 0, green: 0, blue: 0, alpha: 0.35))
proc drawShadow*(paint: var PaintList, bounds: Rect, offset: Point,
                 blurRadius: Pixels, colour: Colour) =
  ## `radius` and `imageId` mirror the two new shadow values through the
  ## existing native command ABI. The typed fields remain the retained paint
  ## representation and are what tests and non-native renderers consume.
  let shadowColour = Colour(red: colour.red, green: colour.green,
    blue: colour.blue, alpha: colour.alpha)
  paint.add(PaintCommand(kind: shadow, bounds: bounds.offset(offset.x, offset.y),
    clip: bounds.offset(offset.x, offset.y), radius: blurRadius,
    blurRadius: blurRadius, color: shadowColour, colour: shadowColour,
    imageId: packedShadowColour(shadowColour)))

proc shadows*(e: ElevationIndex, light: bool): seq[BoxShadow] =
  let elevatedAmbientAlpha = if light: 0.03 else: 0.06
  let modalFirstAlpha = if light: 0.06 else: 0.12
  let modalSecondAlpha = if light: 0.06 else: 0.08
  let modalLastAlpha = if light: 0.04 else: 0.12
  case e
  of background, surface, editorSurface:
    discard
  of elevatedSurface:
    result = @[
      BoxShadow(offset: Point(x: px(0), y: px(2)), blurRadius: px(3),
        color: Color(red: 0, green: 0, blue: 0, alpha: 0.12),
        colour: Color(red: 0, green: 0, blue: 0, alpha: 0.12)),
      BoxShadow(offset: Point(x: px(0), y: px(1)), blurRadius: px(0),
        color: Color(red: 0, green: 0, blue: 0, alpha: elevatedAmbientAlpha),
        colour: Color(red: 0, green: 0, blue: 0, alpha: elevatedAmbientAlpha))]
  of modalSurface:
    result = @[
      BoxShadow(offset: Point(x: px(0), y: px(2)), blurRadius: px(3),
        color: Color(red: 0, green: 0, blue: 0, alpha: modalFirstAlpha),
        colour: Color(red: 0, green: 0, blue: 0, alpha: modalFirstAlpha)),
      BoxShadow(offset: Point(x: px(0), y: px(3)), blurRadius: px(6),
        color: Color(red: 0, green: 0, blue: 0, alpha: modalSecondAlpha),
        colour: Color(red: 0, green: 0, blue: 0, alpha: modalSecondAlpha)),
      BoxShadow(offset: Point(x: px(0), y: px(6)), blurRadius: px(12),
        color: Color(red: 0, green: 0, blue: 0, alpha: 0.04),
        colour: Color(red: 0, green: 0, blue: 0, alpha: 0.04)),
      BoxShadow(offset: Point(x: px(0), y: px(1)), blurRadius: px(0),
        color: Color(red: 0, green: 0, blue: 0, alpha: modalLastAlpha),
        colour: Color(red: 0, green: 0, blue: 0, alpha: modalLastAlpha))]
proc drawCaret*(paint: var PaintList, bounds: Rect) = paint.add(PaintCommand(kind: caret,
    bounds: bounds, clip: bounds))
proc drawSelection*(paint: var PaintList, bounds: Rect) = paint.add(PaintCommand(kind: selection,
    bounds: bounds, clip: bounds))

proc toPixels*(style: ScrollbarStyle): Pixels =
  case style
  of regular: px(6'f32)
  of editor: px(15'f32)

proc scrollbarWidth*(style: ScrollbarStyle): Pixels = style.toPixels

proc scrollbarStrip*(body: Rect, style: ScrollbarStyle): Rect =
  ## Return the vertical strip at the body's trailing edge.  A zero-sized
  ## body stays zero-sized so an unavailable viewport cannot create a paint
  ## command by accident.
  let width = minPx(body.size.width, style.toPixels)
  Rect(origin: Point(x: body.origin.x + body.size.width - width, y: body.origin.y),
    size: Size(width: width, height: body.size.height))
proc roundedSelectionBounds*(rows: openArray[Rect]): Rect =
  if rows.len == 0: return
  result = rows[0]
  for index in 1 ..< rows.len:
    result = unionRect(result, rows[index])

proc roundedSelectionCurveWidth*(left, right, radius: Pixels): Pixels =
  ## This is Zed's `curve_width`: a corner cannot consume more than half of
  ## the horizontal span of the row, nor more than the configured radius.
  let span = max(0'f32, float32(right) - float32(left))
  px(min(span / 2'f32, max(0'f32, float32(radius))))

proc roundedSelectionJoin*(upper, lower: Rect): RoundedSelectionJoin =
  let upperRight = float32(upper.origin.x + upper.size.width)
  let lowerRight = float32(lower.origin.x + lower.size.width)
  if upperRight == lowerRight: selectionJoinEqual
  elif lowerRight < upperRight: selectionJoinInset
  else: selectionJoinOutset

proc drawRoundedSelection*(paint: var PaintList, rows: openArray[Rect], radius: Pixels) =
  if rows.len == 0: return
  paint.add(PaintCommand(kind: roundedSelection, bounds: roundedSelectionBounds(rows),
    clip: roundedSelectionBounds(rows), radius: radius, selectionRows: @rows))
proc drawScrollbar*(paint: var PaintList, bounds: Rect) = paint.add(PaintCommand(kind: scrollbar,
    bounds: bounds, clip: bounds))
proc drawScrollbar*(paint: var PaintList, body: Rect, style: ScrollbarStyle) =
  paint.drawScrollbar(body.scrollbarStrip(style))
proc drawWorkspaceBackground*(paint: var PaintList, bounds: Rect) =
  paint.add(PaintCommand(kind: workspaceBackground, bounds: bounds, clip: bounds))
proc drawWorkspacePanel*(paint: var PaintList, bounds: Rect) =
  paint.add(PaintCommand(kind: workspacePanel, bounds: bounds, clip: bounds))

proc dividerUiColor*(color: DividerColor): UiColor =
  ## Resolve the Divider choice through the shared semantic UiColor table.
  case color
  of dividerBorder, dividerBorderFaded: uiBorder
  of dividerBorderVariant: uiBorderVariant

proc dividerUiColorRole*(color: DividerColor): string =
  ## These are the serialized role keys consumed by the native theme resolver.
  case color
  of dividerBorder, dividerBorderFaded: "border"
  of dividerBorderVariant: "borderVariant"

proc dividerMetadata(color: DividerColor, style: DividerStyle): uint32 =
  ## NativePaintCommand predates path/color payloads. Keep the wire contract
  ## stable and use the otherwise-unused image slot for divider-only metadata.
  uint32(1 + ord(color) * 2 + ord(style))

proc drawDivider*(paint: var PaintList, bounds: Rect,
                  color: DividerColor = dividerBorder,
                  style: DividerStyle = dividerSolid) =
  let dashArray = if style == dividerDashed: @[px(4), px(2)] else: @[]
  paint.add(PaintCommand(kind: strokedPath, bounds: bounds, clip: bounds,
    strokeWidth: px(1), dividerColor: color, dividerStyle: style,
    dashArray: dashArray, imageId: dividerMetadata(color, style)))

proc drawWorkspaceSeparator*(paint: var PaintList, bounds: Rect,
                             color: DividerColor = dividerBorder,
                             style: DividerStyle = dividerSolid) =
  ## Preserve the existing semantic kind for solid workspace chrome while
  ## allowing callers to request the full Divider path behavior.
  if style == dividerDashed:
    paint.drawDivider(bounds, color, style)
  else:
    paint.add(PaintCommand(kind: workspaceSeparator, bounds: bounds, clip: bounds,
      strokeWidth: px(1), dividerColor: color, dividerStyle: style,
      imageId: dividerMetadata(color, style)))
proc drawEditorActiveLine*(paint: var PaintList, bounds: Rect) =
  paint.add(PaintCommand(kind: editorActiveLine, bounds: bounds, clip: bounds))
proc drawEditorBackground*(paint: var PaintList, bounds: Rect) =
  paint.add(PaintCommand(kind: editorBackground, bounds: bounds, clip: bounds))
proc drawScrollbarTrack*(paint: var PaintList, bounds: Rect) =
  paint.add(PaintCommand(kind: scrollbarTrack, bounds: bounds, clip: bounds))
proc drawScrollbarTrack*(paint: var PaintList, body: Rect, style: ScrollbarStyle) =
  paint.drawScrollbarTrack(body.scrollbarStrip(style))
proc drawEditorDiagnostic*(paint: var PaintList, bounds: Rect, severity: int) =
  paint.add(PaintCommand(kind: editorDiagnostic, bounds: bounds, clip: bounds,
    imageId: uint32(max(0, severity))))
