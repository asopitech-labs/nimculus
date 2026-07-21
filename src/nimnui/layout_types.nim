import nimnui/geometry

type
  LayoutDirection* = enum
    row, column, stack

  Alignment* = enum
    alignStart, alignCenter, alignEnd, alignStretch

  LayoutSpec* = object
    direction*: LayoutDirection
    size*: Size
    minSize*: Size
    maxSize*: Size
    padding*: EdgeInsets
    gap*: Pixels
    flexGrow*: float32
    alignment*: Alignment
    scrollOffset*: Pixels
    viewport*: Rect

proc defaultLayoutSpec*(): LayoutSpec =
  LayoutSpec(direction: stack)

proc normalizeLayoutSpec*(spec: LayoutSpec): LayoutSpec =
  ## A missing maximum means unbounded in the public style API. Keep the
  ## internal node maximum finite so allocation arithmetic remains stable.
  result = spec
  if float32(result.maxSize.width) <= 0: result.maxSize.width = px(100000)
  if float32(result.maxSize.height) <= 0: result.maxSize.height = px(100000)
