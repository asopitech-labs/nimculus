import std/hashes
import std/math

type
  Pixels* = distinct float32

  Rgba* = object
    r*, g*, b*, a*: float32

  ## A hue, saturation, lightness, and alpha color in the ranges 0..1.
  Hsla* = object
    h*, s*, l*, a*: float32

proc unitClamp(value: float32): float32 {.inline.} =
  if value < 0'f32: 0'f32
  elif value > 1'f32: 1'f32
  else: value

proc hsla*(h, s, l, a: float32): Hsla =
  Hsla(h: unitClamp(h), s: unitClamp(s), l: unitClamp(l), a: unitClamp(a))

proc floatBits(value: float32): uint32 {.inline.} = cast[uint32](value)

proc `==`*(left, right: Hsla): bool =
  floatBits(left.h) == floatBits(right.h) and
    floatBits(left.s) == floatBits(right.s) and
    floatBits(left.l) == floatBits(right.l) and
    floatBits(left.a) == floatBits(right.a)

proc hash*(color: Hsla): Hash =
  var resultHash: Hash
  resultHash = resultHash !& hash(floatBits(color.h))
  resultHash = resultHash !& hash(floatBits(color.s))
  resultHash = resultHash !& hash(floatBits(color.l))
  resultHash = resultHash !& hash(floatBits(color.a))
  !$resultHash

proc toRgba*(color: Hsla): Rgba =
  let chroma = (1'f32 - abs(2'f32 * color.l - 1'f32)) * color.s
  let hue = color.h * 6'f32
  let sector = int(floor(hue))
  let fraction = hue - float32(sector)
  let second = chroma * (if sector mod 2 == 0: fraction else: 1'f32 - fraction)
  let matchValue = color.l - chroma / 2'f32
  let chromaMatched = chroma + matchValue
  let secondMatched = second + matchValue
  case sector
  of 0, 6:
    Rgba(r: chromaMatched, g: secondMatched, b: matchValue, a: color.a)
  of 1:
    Rgba(r: secondMatched, g: chromaMatched, b: matchValue, a: color.a)
  of 2:
    Rgba(r: matchValue, g: chromaMatched, b: secondMatched, a: color.a)
  of 3:
    Rgba(r: matchValue, g: secondMatched, b: chromaMatched, a: color.a)
  of 4:
    Rgba(r: secondMatched, g: matchValue, b: chromaMatched, a: color.a)
  else:
    Rgba(r: chromaMatched, g: matchValue, b: secondMatched, a: color.a)

proc toHsla*(color: Rgba): Hsla =
  let maximum = max(color.r, max(color.g, color.b))
  let minimum = min(color.r, min(color.g, color.b))
  let delta = maximum - minimum
  let lightness = (maximum + minimum) / 2'f32
  let saturation = if lightness == 0'f32 or lightness == 1'f32:
    0'f32
  elif lightness < 0.5'f32:
    delta / (2'f32 * lightness)
  else:
    delta / (2'f32 - 2'f32 * lightness)
  let hue = if delta == 0'f32:
    0'f32
  elif maximum == color.r:
    ((color.g - color.b) / delta -
      6'f32 * floor(((color.g - color.b) / delta) / 6'f32)) / 6'f32
  elif maximum == color.g:
    ((color.b - color.r) / delta + 2'f32) / 6'f32
  else:
    ((color.r - color.g) / delta + 4'f32) / 6'f32
  Hsla(h: hue, s: saturation, l: lightness, a: color.a)

proc blend*(color, other: Hsla): Hsla =
  if other.a >= 1'f32:
    other
  elif other.a <= 0'f32:
    color
  else:
    let base = color.toRgba
    let overlay = other.toRgba
    Rgba(
      r: base.r * (1'f32 - overlay.a) + overlay.r * overlay.a,
      g: base.g * (1'f32 - overlay.a) + overlay.g * overlay.a,
      b: base.b * (1'f32 - overlay.a) + overlay.b * overlay.a,
      a: base.a).toHsla

proc opacity*(color: Hsla, factor: float32): Hsla =
  Hsla(h: color.h, s: color.s, l: color.l, a: color.a * unitClamp(factor))

proc alpha*(color: Hsla, value: float32): Hsla =
  Hsla(h: color.h, s: color.s, l: color.l, a: unitClamp(value))

proc fadeOut*(color: var Hsla, factor: float32) =
  color.a *= 1'f32 - unitClamp(factor)

type
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
  float32(point.x) < float32(rect.origin.x + rect.size.width) and
  float32(point.y) < float32(rect.origin.y + rect.size.height)

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
  let left = min(float32(topLeft.x), min(float32(topRight.x), min(float32(bottomLeft.x), float32(
      bottomRight.x))))
  let right = max(float32(topLeft.x), max(float32(topRight.x), max(float32(bottomLeft.x), float32(
      bottomRight.x))))
  let top = min(float32(topLeft.y), min(float32(topRight.y), min(float32(bottomLeft.y), float32(
      bottomRight.y))))
  let bottom = max(float32(topLeft.y), max(float32(topRight.y), max(float32(bottomLeft.y), float32(
      bottomRight.y))))
  Rect(origin: Point(x: px(left), y: px(top)), size: Size(width: px(right - left), height: px(
      bottom - top)))
