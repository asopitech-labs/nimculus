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
