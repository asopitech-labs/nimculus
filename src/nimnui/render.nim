import nimnui/geometry

type
  PaintKind* = enum
    rectangle, border, roundedRectangle, text, image, clip, transform,
    shadow, caret, selection, scrollbar

  PaintCommand* = object
    kind*: PaintKind
    bounds*: Rect
    clip*: Rect
    text*: string
    radius*: Pixels

  PaintList* = object
    commands*: seq[PaintCommand]
    dirty*: seq[Rect]
    clipStack*: seq[Rect]

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

proc invalidate*(paint: var PaintList, rect: Rect) = paint.dirty.add(rect)

proc add*(paint: var PaintList, command: PaintCommand) =
  for dirty in paint.dirty:
    var visible = intersection(command.bounds, dirty)
    if paint.clipStack.len > 0:
      visible = intersection(visible, paint.clipStack[^1])
    if float32(visible.size.width) > 0 and float32(visible.size.height) > 0:
      var clipped = command
      clipped.clip = visible
      paint.commands.add(clipped)

proc clear*(paint: var PaintList) =
  paint.commands.setLen(0)
  paint.dirty.setLen(0)
  paint.clipStack.setLen(0)

proc drawRectangle*(paint: var PaintList, bounds: Rect) =
  paint.add(PaintCommand(kind: rectangle, bounds: bounds, clip: bounds))

proc drawText*(paint: var PaintList, bounds: Rect, text: string) =
  paint.add(PaintCommand(kind: PaintKind.text, bounds: bounds, clip: bounds, text: text))

proc drawBorder*(paint: var PaintList, bounds: Rect) = paint.add(PaintCommand(kind: border, bounds: bounds, clip: bounds))
proc drawRoundedRectangle*(paint: var PaintList, bounds: Rect, radius: Pixels) =
  paint.add(PaintCommand(kind: roundedRectangle, bounds: bounds, clip: bounds, radius: radius))
proc drawImage*(paint: var PaintList, bounds: Rect) = paint.add(PaintCommand(kind: image, bounds: bounds, clip: bounds))
proc pushClip*(paint: var PaintList, bounds: Rect) =
  paint.add(PaintCommand(kind: clip, bounds: bounds, clip: bounds))
  paint.clipStack.add(bounds)
proc popClip*(paint: var PaintList) =
  if paint.clipStack.len > 0: paint.clipStack.setLen(paint.clipStack.len - 1)
proc drawShadow*(paint: var PaintList, bounds: Rect) = paint.add(PaintCommand(kind: shadow, bounds: bounds, clip: bounds))
proc drawCaret*(paint: var PaintList, bounds: Rect) = paint.add(PaintCommand(kind: caret, bounds: bounds, clip: bounds))
proc drawSelection*(paint: var PaintList, bounds: Rect) = paint.add(PaintCommand(kind: selection, bounds: bounds, clip: bounds))
proc drawScrollbar*(paint: var PaintList, bounds: Rect) = paint.add(PaintCommand(kind: scrollbar, bounds: bounds, clip: bounds))
