type
  Pixels* = distinct float32

  Point* = object
    x*, y*: Pixels

  Size* = object
    width*, height*: Pixels

  Rect* = object
    origin*: Point
    size*: Size

  EdgeInsets* = object
    top*, right*, bottom*, left*: Pixels

proc px*(value: float32): Pixels = Pixels(value)
proc `+`*(a, b: Pixels): Pixels = Pixels(float32(a) + float32(b))
proc `-`*(a, b: Pixels): Pixels = Pixels(float32(a) - float32(b))
proc `*`*(a: Pixels, b: float32): Pixels = Pixels(float32(a) * b)
proc `/`*(a: Pixels, b: Pixels): Pixels = Pixels(float32(a) / float32(b))
proc maxPx*(a, b: Pixels): Pixels = (if float32(a) >= float32(b): a else: b)
proc minPx*(a, b: Pixels): Pixels = (if float32(a) <= float32(b): a else: b)

proc inset*(rect: Rect, padding: EdgeInsets): Rect =
  Rect(
    origin: Point(x: rect.origin.x + padding.left, y: rect.origin.y + padding.top),
    size: Size(
      width: maxPx(px(0), rect.size.width - padding.left - padding.right),
      height: maxPx(px(0), rect.size.height - padding.top - padding.bottom)))

proc contains*(rect: Rect, point: Point): bool =
  float32(point.x) >= float32(rect.origin.x) and
  float32(point.y) >= float32(rect.origin.y) and
  float32(point.x) <= float32(rect.origin.x + rect.size.width) and
  float32(point.y) <= float32(rect.origin.y + rect.size.height)
