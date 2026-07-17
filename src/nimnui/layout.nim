import std/sequtils
import nimnui/geometry
import nimnui/ui_tree

type
  LayoutDirection* = enum
    row, column, stack

  LayoutSpec* = object
    direction*: LayoutDirection
    size*: Size
    minSize*: Size
    maxSize*: Size
    padding*: EdgeInsets
    gap*: Pixels
    flexGrow*: float32

proc layoutNode*(tree: var UiTree, id: NodeId, bounds: Rect, spec: LayoutSpec) =
  let index = tree.nodes.mapIt(it.id).find(id)
  if index < 0: return
  tree.nodes[index].bounds = bounds
  tree.nodes[index].layoutDirty = false
  let content = bounds.inset(spec.padding)
  let children = tree.nodes[index].children
  if children.len == 0: return
  let count = Pixels(children.len.float32)
  var cursor = if spec.direction == row: content.origin.x else: content.origin.y
  let available = if spec.direction == row: content.size.width else: content.size.height
  let gapTotal = spec.gap * float32(max(0, children.len - 1))
  let childExtent = maxPx(px(0), (available - gapTotal) / count)
  for child in children:
    var childSize = if spec.direction == row:
      Size(width: childExtent, height: content.size.height)
    else:
      Size(width: content.size.width, height: childExtent)
    if spec.direction == stack: childSize = content.size
    let childOrigin = if spec.direction == row:
      Point(x: cursor, y: content.origin.y)
    else:
      Point(x: content.origin.x, y: cursor)
    tree.nodes[tree.nodes.mapIt(it.id).find(child)].bounds = Rect(origin: childOrigin, size: childSize)
    if spec.direction != stack: cursor = cursor + childExtent + spec.gap
