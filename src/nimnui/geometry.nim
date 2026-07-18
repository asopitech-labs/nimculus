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
proc `==`*(a, b: Pixels): bool = float32(a) == float32(b)
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

proc offset*(rect: Rect, dx, dy: Pixels): Rect =
  Rect(origin: Point(x: rect.origin.x + dx, y: rect.origin.y + dy), size: rect.size)

type
  Transform2D* = object
    ## Affine transform in logical UI coordinates.
    a*, b*, c*, d*, tx*, ty*: float32

proc identityTransform*(): Transform2D =
  Transform2D(a: 1, d: 1)

proc translationTransform*(x, y: Pixels): Transform2D =
  Transform2D(a: 1, d: 1, tx: float32(x), ty: float32(y))

proc scaleTransform*(x, y: float32): Transform2D =
  Transform2D(a: x, d: y)

proc `*`*(left, right: Transform2D): Transform2D =
  Transform2D(
    a: left.a * right.a + left.c * right.b,
    b: left.b * right.a + left.d * right.b,
    c: left.a * right.c + left.c * right.d,
    d: left.b * right.c + left.d * right.d,
    tx: left.a * right.tx + left.c * right.ty + left.tx,
    ty: left.b * right.tx + left.d * right.ty + left.ty)

proc apply*(transform: Transform2D, point: Point): Point =
  Point(x: px(transform.a * float32(point.x) + transform.c * float32(point.y) + transform.tx),
        y: px(transform.b * float32(point.x) + transform.d * float32(point.y) + transform.ty))

proc transformRect*(transform: Transform2D, rect: Rect): Rect =
  let topLeft = transform.apply(rect.origin)
  let topRight = transform.apply(Point(x: rect.origin.x + rect.size.width, y: rect.origin.y))
  let bottomLeft = transform.apply(Point(x: rect.origin.x, y: rect.origin.y + rect.size.height))
  let bottomRight = transform.apply(Point(x: rect.origin.x + rect.size.width,
    y: rect.origin.y + rect.size.height))
  let left = min(float32(topLeft.x), min(float32(topRight.x), min(float32(bottomLeft.x), float32(bottomRight.x))))
  let right = max(float32(topLeft.x), max(float32(topRight.x), max(float32(bottomLeft.x), float32(bottomRight.x))))
  let top = min(float32(topLeft.y), min(float32(topRight.y), min(float32(bottomLeft.y), float32(bottomRight.y))))
  let bottom = max(float32(topLeft.y), max(float32(topRight.y), max(float32(bottomLeft.y), float32(bottomRight.y))))
  Rect(origin: Point(x: px(left), y: px(top)), size: Size(width: px(right - left), height: px(bottom - top)))
