import nimnui/geometry

type
  PaintKind* = enum
    rectangle, border, roundedRectangle, text, image, clip, transform,
    shadow, caret, selection, scrollbar,
    ## Workspace chrome has semantic paint kinds so the Metal backend can use
    ## the active theme rather than the gallery's fixed placeholder blue.
    workspaceBackground, workspacePanel, workspaceSeparator, editorActiveLine, editorBackground,
    ## Zed rules the vertical scrollbar's inner edge in its own lighter role
    ## (`scrollbar.track.border`), distinct from the workspace `border`.
    scrollbarTrack, editorDiagnostic, roundedSelection

  ## The two possible width changes at a row join are kept as data rather
  ## than exposed as path operations. The Metal backend consumes the row
  ## rectangles and emits the concrete Zed-shaped selection directly.
  RoundedSelectionJoin* = enum
    selectionJoinEqual, selectionJoinInset, selectionJoinOutset

  PaintCommand* = object
    kind*: PaintKind
    bounds*: Rect
    sourceBounds*: Rect
    clip*: Rect
    text*: string
    radius*: Pixels
    transform*: Transform2D
    imageId*: uint32
    ## Only populated for roundedSelection. Keeping the rows on the paint
    ## command lets the retained command stay one concrete shape instead of
    ## becoming one rounded rectangle per line.
    selectionRows*: seq[Rect]

  PaintList* = object
    commands*: seq[PaintCommand]
    dirty*: seq[Rect]
    clipStack*: seq[Rect]
    transformStack*: seq[Transform2D]

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

proc add*(paint: var PaintList, command: PaintCommand) =
  let transform = if paint.transformStack.len > 0: paint.transformStack[^1] else: identityTransform()
  let transformedBounds = transform.transformRect(command.bounds)
  for dirty in paint.dirty:
    var visible = intersection(transformedBounds, dirty)
    if paint.clipStack.len > 0:
      visible = intersection(visible, paint.clipStack[^1])
    if float32(visible.size.width) > 0 and float32(visible.size.height) > 0:
      var clipped = command
      clipped.sourceBounds = command.bounds
      clipped.bounds = transformedBounds
      clipped.clip = visible
      clipped.transform = transform
      paint.commands.add(clipped)

proc clear*(paint: var PaintList) =
  paint.commands.setLen(0)
  paint.dirty.setLen(0)
  paint.clipStack.setLen(0)
  paint.transformStack.setLen(0)

proc drawRectangle*(paint: var PaintList, bounds: Rect) =
  paint.add(PaintCommand(kind: rectangle, bounds: bounds, clip: bounds))

proc drawText*(paint: var PaintList, bounds: Rect, text: string) =
  paint.add(PaintCommand(kind: PaintKind.text, bounds: bounds, clip: bounds, text: text))

proc drawBorder*(paint: var PaintList, bounds: Rect) = paint.add(PaintCommand(kind: border,
    bounds: bounds, clip: bounds))
proc drawRoundedRectangle*(paint: var PaintList, bounds: Rect, radius: Pixels) =
  paint.add(PaintCommand(kind: roundedRectangle, bounds: bounds, clip: bounds, radius: radius))
proc drawImage*(paint: var PaintList, bounds: Rect, imageId: uint32 = 0) =
  paint.add(PaintCommand(kind: image, bounds: bounds, clip: bounds, imageId: imageId))
proc pushClip*(paint: var PaintList, bounds: Rect) =
  paint.add(PaintCommand(kind: clip, bounds: bounds, clip: bounds))
  let transform = if paint.transformStack.len > 0: paint.transformStack[^1] else: identityTransform()
  let transformedBounds = transform.transformRect(bounds)
  let effective = if paint.clipStack.len > 0:
    intersection(transformedBounds, paint.clipStack[^1])
  else: transformedBounds
  paint.clipStack.add(effective)
proc popClip*(paint: var PaintList) =
  if paint.clipStack.len > 0: paint.clipStack.setLen(paint.clipStack.len - 1)
proc pushTransform*(paint: var PaintList, transform: Transform2D) =
  let current = if paint.transformStack.len > 0: paint.transformStack[^1] else: identityTransform()
  paint.transformStack.add(current * transform)
proc popTransform*(paint: var PaintList) =
  if paint.transformStack.len > 0: paint.transformStack.setLen(paint.transformStack.len - 1)
proc drawShadow*(paint: var PaintList, bounds: Rect) = paint.add(PaintCommand(kind: shadow,
    bounds: bounds, clip: bounds))
proc drawCaret*(paint: var PaintList, bounds: Rect) = paint.add(PaintCommand(kind: caret,
    bounds: bounds, clip: bounds))
proc drawSelection*(paint: var PaintList, bounds: Rect) = paint.add(PaintCommand(kind: selection,
    bounds: bounds, clip: bounds))
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
proc drawWorkspaceBackground*(paint: var PaintList, bounds: Rect) =
  paint.add(PaintCommand(kind: workspaceBackground, bounds: bounds, clip: bounds))
proc drawWorkspacePanel*(paint: var PaintList, bounds: Rect) =
  paint.add(PaintCommand(kind: workspacePanel, bounds: bounds, clip: bounds))
proc drawWorkspaceSeparator*(paint: var PaintList, bounds: Rect) =
  paint.add(PaintCommand(kind: workspaceSeparator, bounds: bounds, clip: bounds))
proc drawEditorActiveLine*(paint: var PaintList, bounds: Rect) =
  paint.add(PaintCommand(kind: editorActiveLine, bounds: bounds, clip: bounds))
proc drawEditorBackground*(paint: var PaintList, bounds: Rect) =
  paint.add(PaintCommand(kind: editorBackground, bounds: bounds, clip: bounds))
proc drawScrollbarTrack*(paint: var PaintList, bounds: Rect) =
  paint.add(PaintCommand(kind: scrollbarTrack, bounds: bounds, clip: bounds))
proc drawEditorDiagnostic*(paint: var PaintList, bounds: Rect, severity: int) =
  paint.add(PaintCommand(kind: editorDiagnostic, bounds: bounds, clip: bounds,
    imageId: uint32(max(0, severity))))
