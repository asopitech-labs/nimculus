import std/sequtils
import nimnui/geometry
import nimnui/ui_tree
import nimnui/render

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

proc layoutNode*(tree: var UiTree, id: NodeId, bounds: Rect, spec: LayoutSpec) =
  let index = tree.nodes.mapIt(it.id).find(id)
  if index < 0: return
  tree.nodes[index].bounds = bounds
  tree.nodes[index].layoutDirty = false
  let content = bounds.inset(spec.padding)
  let children = tree.nodes[index].children
  if children.len == 0: return
  let count = Pixels(children.len.float32)
  var cursor = if spec.direction == row: content.origin.x - spec.scrollOffset else: content.origin.y - spec.scrollOffset
  let available = if spec.direction == row: content.size.width else: content.size.height
  let gapTotal = spec.gap * float32(max(0, children.len - 1))
  let childExtent = minPx(spec.maxSize.width, maxPx(spec.minSize.width,
    maxPx(px(0), (available - gapTotal) / count)))
  for child in children:
    var childSize = if spec.direction == row:
      Size(width: childExtent, height: content.size.height)
    else:
      Size(width: content.size.width, height: childExtent)
    if spec.direction == stack: childSize = content.size
    let childOrigin = if spec.direction == row:
      Point(x: cursor, y: if spec.alignment == alignCenter: content.origin.y + (content.size.height - childSize.height) / px(2)
        elif spec.alignment == alignEnd: content.origin.y + content.size.height - childSize.height
        else: content.origin.y)
    else:
      Point(x: if spec.alignment == alignCenter: content.origin.x + (content.size.width - childSize.width) / px(2)
        elif spec.alignment == alignEnd: content.origin.x + content.size.width - childSize.width
        else: content.origin.x, y: cursor)
    var finalBounds = Rect(origin: childOrigin, size: childSize)
    if spec.viewport.size.width != px(0) and not intersects(finalBounds, spec.viewport):
      finalBounds.size = Size(width: px(0), height: px(0))
    elif spec.viewport.size.width != px(0):
      finalBounds = intersection(finalBounds, spec.viewport)
    tree.nodes[tree.nodes.mapIt(it.id).find(child)].bounds = finalBounds
    if spec.direction != stack: cursor = cursor + childExtent + spec.gap
