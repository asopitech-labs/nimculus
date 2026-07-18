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
  if spec.direction == stack:
    ## Stack children share the content rectangle. Do not run the row/column
    ## cursor allocation first: that would leave overlay children at different
    ## positions even though their final sizes are identical.
    for child in children:
      var childBounds = content
      if spec.viewport.size.width != px(0):
        childBounds = intersection(childBounds, spec.viewport)
      tree.nodes[tree.nodeIndex(child)].bounds = childBounds
      tree.nodes[tree.nodeIndex(child)].layoutDirty = false
    return
  var cursor = if spec.direction == row: content.origin.x - spec.scrollOffset else: content.origin.y - spec.scrollOffset
  let available = if spec.direction == row: content.size.width else: content.size.height
  let gapTotal = spec.gap * float32(max(0, children.len - 1))
  var extents = newSeq[Pixels](children.len)
  var baseTotal = px(0)
  var totalGrow = 0'f32
  for index, child in children:
    let childIndex = tree.nodeIndex(child)
    let childNode = tree.nodes[childIndex]
    let preferred = if spec.direction == row: childNode.preferredSize.width else: childNode.preferredSize.height
    let minimum = if spec.direction == row: childNode.minSize.width else: childNode.minSize.height
    let maximum = if spec.direction == row: childNode.maxSize.width else: childNode.maxSize.height
    let initial = if float32(preferred) > 0: preferred else: minimum
    extents[index] = minPx(maximum, maxPx(minimum, initial))
    baseTotal = baseTotal + extents[index]
    totalGrow += childNode.flexGrow
  let remaining = maxPx(px(0), available - gapTotal - baseTotal)
  if totalGrow > 0:
    for index, child in children:
      let childNode = tree.nodes[tree.nodeIndex(child)]
      extents[index] = extents[index] + remaining * (childNode.flexGrow / totalGrow)
      let minimum = if spec.direction == row: childNode.minSize.width else: childNode.minSize.height
      let maximum = if spec.direction == row: childNode.maxSize.width else: childNode.maxSize.height
      extents[index] = minPx(maximum, maxPx(minimum, extents[index]))
  elif children.len > 0 and baseTotal == px(0):
    let equalExtent = maxPx(px(0), (available - gapTotal) / px(float32(children.len)))
    for index in 0 ..< extents.len: extents[index] = equalExtent
  for index, child in children:
    let childNode = tree.nodes[tree.nodeIndex(child)]
    let crossPreferred = if spec.direction == row: childNode.preferredSize.height else: childNode.preferredSize.width
    let crossMinimum = if spec.direction == row: childNode.minSize.height else: childNode.minSize.width
    let crossMaximum = if spec.direction == row: childNode.maxSize.height else: childNode.maxSize.width
    let crossAvailable = if spec.direction == row: content.size.height else: content.size.width
    let crossExtent = if spec.alignment == alignStretch:
      minPx(crossMaximum, maxPx(crossMinimum, crossAvailable))
      elif float32(crossPreferred) > 0:
        minPx(crossMaximum, maxPx(crossMinimum, crossPreferred))
      else:
        minPx(crossMaximum, maxPx(crossMinimum, crossAvailable))
    var childSize = if spec.direction == row:
      Size(width: extents[index], height: crossExtent)
    else:
      Size(width: crossExtent, height: extents[index])
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
    tree.nodes[tree.nodeIndex(child)].bounds = finalBounds
    cursor = cursor + extents[index] + spec.gap
