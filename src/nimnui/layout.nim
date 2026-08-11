import std/options
import std/sequtils
import nimnui/geometry
import nimnui/ui_tree
import nimnui/layout_types

export layout_types

proc resolveBounds(bounds: Rect, spec: LayoutSpec): Rect =
  var size = bounds.size
  if float32(spec.size.width) > 0: size.width = spec.size.width
  if float32(spec.size.height) > 0: size.height = spec.size.height
  if float32(spec.minSize.width) > 0: size.width = maxPx(size.width, spec.minSize.width)
  if float32(spec.minSize.height) > 0: size.height = maxPx(size.height, spec.minSize.height)
  if float32(spec.maxSize.width) > 0: size.width = minPx(size.width, spec.maxSize.width)
  if float32(spec.maxSize.height) > 0: size.height = minPx(size.height, spec.maxSize.height)
  Rect(origin: bounds.origin, size: size)

proc lengthIsSet(value: Length): bool = value.kind == lengthPixels

proc clippedByOverflow(spec: LayoutSpec): bool =
  spec.overflow.x != visible or spec.overflow.y != visible

proc clipRect(rect, clip: Rect, clipX, clipY: bool): Rect =
  result = rect
  if clipX:
    let left = max(float32(result.origin.x), float32(clip.origin.x))
    let right = min(float32(result.origin.x + result.size.width),
      float32(clip.origin.x + clip.size.width))
    result.origin.x = px(left)
    result.size.width = px(max(0'f32, right - left))
  if clipY:
    let top = max(float32(result.origin.y), float32(clip.origin.y))
    let bottom = min(float32(result.origin.y + result.size.height),
      float32(clip.origin.y + clip.size.height))
    result.origin.y = px(top)
    result.size.height = px(max(0'f32, bottom - top))

proc childClipBounds(parentBounds: Rect, parentSpec: LayoutSpec,
                     inheritedClip: Rect, inheritedClipX, inheritedClipY: bool,
                     hasViewport: bool): tuple[region: Rect, clipX, clipY: bool] =
  result.region = if inheritedClipX or inheritedClipY: inheritedClip else: parentBounds
  result.clipX = inheritedClipX
  result.clipY = inheritedClipY
  if clippedByOverflow(parentSpec):
    result.region = clipRect(result.region, parentBounds,
      parentSpec.overflow.x != visible, parentSpec.overflow.y != visible)
    result.clipX = result.clipX or parentSpec.overflow.x != visible
    result.clipY = result.clipY or parentSpec.overflow.y != visible
  if hasViewport:
    result.region = clipRect(result.region, parentSpec.viewport, true, true)
    result.clipX = true
    result.clipY = true

proc applyParentClip(bounds: Rect, clip: Rect, clipX, clipY: bool): Rect =
  if clipX or clipY: clipRect(bounds, clip, clipX, clipY) else: bounds

proc axisValue(preferred, minimum, maximum: Pixels): Pixels =
  let initial = if float32(preferred) > 0: preferred else: minimum
  minPx(maximum, maxPx(minimum, initial))

proc absoluteBounds(content: Rect, spec: LayoutSpec): Rect =
  let normalized = normalizeLayoutSpec(spec)
  let horizontalMargins = normalized.margin.left + normalized.margin.right
  let verticalMargins = normalized.margin.top + normalized.margin.bottom
  let leftSet = lengthIsSet(normalized.inset.left)
  let rightSet = lengthIsSet(normalized.inset.right)
  let topSet = lengthIsSet(normalized.inset.top)
  let bottomSet = lengthIsSet(normalized.inset.bottom)
  let widthIsExplicit = float32(normalized.size.width) > 0
  let heightIsExplicit = float32(normalized.size.height) > 0
  var width = axisValue(normalized.size.width,
    normalized.minSize.width, normalized.maxSize.width)
  var height = axisValue(normalized.size.height,
    normalized.minSize.height, normalized.maxSize.height)
  if not widthIsExplicit and leftSet and rightSet:
    width = minPx(normalized.maxSize.width, maxPx(normalized.minSize.width,
      content.size.width - normalized.inset.left.value - normalized.inset.right.value -
      horizontalMargins))
  if not heightIsExplicit and topSet and bottomSet:
    height = minPx(normalized.maxSize.height, maxPx(normalized.minSize.height,
      content.size.height - normalized.inset.top.value - normalized.inset.bottom.value -
      verticalMargins))
  let x = if leftSet:
    content.origin.x + normalized.inset.left.value + normalized.margin.left
    elif rightSet:
      content.origin.x + content.size.width - normalized.inset.right.value -
        normalized.margin.right - width
    else: content.origin.x + normalized.margin.left
  let y = if topSet:
    content.origin.y + normalized.inset.top.value + normalized.margin.top
    elif bottomSet:
      content.origin.y + content.size.height - normalized.inset.bottom.value -
        normalized.margin.bottom - height
    else: content.origin.y + normalized.margin.top
  Rect(origin: Point(x: x, y: y), size: Size(width: width, height: height))

proc applyRelativeInset(bounds: Rect, spec: LayoutSpec): Rect =
  result = bounds
  if lengthIsSet(spec.inset.left): result.origin.x = result.origin.x + spec.inset.left.value
  elif lengthIsSet(spec.inset.right): result.origin.x = result.origin.x - spec.inset.right.value
  if lengthIsSet(spec.inset.top): result.origin.y = result.origin.y + spec.inset.top.value
  elif lengthIsSet(spec.inset.bottom): result.origin.y = result.origin.y - spec.inset.bottom.value

proc alignCross(origin, available, extent, leading, trailing: Pixels,
                alignment: Alignment): Pixels =
  let free = maxPx(px(0), available - leading - trailing - extent)
  case alignment
  of alignCenter: origin + leading + free / px(2)
  of alignEnd: origin + available - trailing - extent
  else: origin + leading

proc layoutNodeRecursive(tree: var UiTree, id: NodeId, bounds: Rect,
                         spec: LayoutSpec, inheritedClip: Rect,
                         inheritedClipX, inheritedClipY: bool) =
  let index = tree.nodeIndex(id)
  if index < 0: return
  tree.nodes[index].bounds = bounds
  tree.nodes[index].layoutDirty = false
  tree.nodes[index].clipBounds = if inheritedClipX or inheritedClipY:
    clipRect(inheritedClip, bounds, inheritedClipX, inheritedClipY)
  else: bounds
  let hasViewport = float32(spec.viewport.size.width) > 0 or
    float32(spec.viewport.size.height) > 0
  let ownClipX = spec.overflow.x != visible or hasViewport
  let ownClipY = spec.overflow.y != visible or hasViewport
  tree.nodes[index].clipChildren = ownClipX or ownClipY
  tree.nodes[index].clipX = ownClipX
  tree.nodes[index].clipY = ownClipY
  tree.nodes[index].clipBounds = if ownClipX or ownClipY:
    clipRect(tree.nodes[index].clipBounds,
      if hasViewport: spec.viewport else: bounds, ownClipX, ownClipY)
  else: tree.nodes[index].clipBounds

  let content = bounds.inset(spec.padding)
  let children = tree.nodes[index].children
  if children.len == 0: return
  let parentClip = childClipBounds(bounds, spec, inheritedClip,
    inheritedClipX, inheritedClipY, hasViewport)
  if spec.direction == stack:
    ## Stack children share the content rectangle. Absolute children use the
    ## same content rectangle as their containing block, but do not participate
    ## in the stack's shared placement or sizing.
    for child in children:
      let childIndex = tree.nodeIndex(child)
      if childIndex < 0: continue
      let childSpec = tree.nodes[childIndex].layoutSpec
      var childBounds = if childSpec.position == absolute:
        absoluteBounds(content, childSpec)
      else:
        Rect(origin: Point(x: content.origin.x + childSpec.margin.left,
          y: content.origin.y + childSpec.margin.top),
          size: Size(width: maxPx(px(0), content.size.width - childSpec.margin.left -
              childSpec.margin.right),
            height: maxPx(px(0), content.size.height - childSpec.margin.top -
              childSpec.margin.bottom)))
      if childSpec.position == relative: childBounds = applyRelativeInset(childBounds, childSpec)
      childBounds = applyParentClip(childBounds, parentClip.region,
        parentClip.clipX, parentClip.clipY)
      layoutNodeRecursive(tree, child, childBounds, childSpec, parentClip.region,
        parentClip.clipX, parentClip.clipY)
    return

  let rowDirection = spec.direction == row
  let crossAlignment = if spec.alignItems.isSome: spec.alignItems.get else: spec.alignment
  let mainAlignment = if spec.justifyContent.isSome: spec.justifyContent.get else: alignStart
  let available = if rowDirection: content.size.width else: content.size.height
  let gapTotal = spec.gap * float32(max(0, children.len - 1))
  var extents = newSeq[Pixels](children.len)
  var mainMargins = newSeq[Pixels](children.len)
  var baseTotal = px(0)
  var totalGrow = 0'f32
  for index, child in children:
    let childIndex = tree.nodeIndex(child)
    if childIndex < 0: continue
    let childNode = tree.nodes[childIndex]
    let childSpec = childNode.layoutSpec
    if childSpec.position == absolute: continue
    let margin = if rowDirection: childSpec.margin.left + childSpec.margin.right
      else: childSpec.margin.top + childSpec.margin.bottom
    mainMargins[index] = margin
    extents[index] = if rowDirection:
      axisValue(childNode.preferredSize.width,
        childNode.minSize.width, childNode.maxSize.width)
    else:
      axisValue(childNode.preferredSize.height,
        childNode.minSize.height, childNode.maxSize.height)
    baseTotal = baseTotal + extents[index] + margin
    totalGrow += childNode.flexGrow
  let flowCount = children.countIt(tree.nodes[tree.nodeIndex(it)].layoutSpec.position != absolute)
  var remaining = maxPx(px(0), available - gapTotal - baseTotal)
  if totalGrow > 0:
    for index, child in children:
      let childIndex = tree.nodeIndex(child)
      if childIndex < 0 or tree.nodes[childIndex].layoutSpec.position == absolute: continue
      let childNode = tree.nodes[childIndex]
      extents[index] = extents[index] + remaining * (childNode.flexGrow / totalGrow)
      let minimum = if rowDirection: childNode.minSize.width else: childNode.minSize.height
      let maximum = if rowDirection: childNode.maxSize.width else: childNode.maxSize.height
      extents[index] = minPx(maximum, maxPx(minimum, extents[index]))
    baseTotal = px(0)
    for index in 0 ..< children.len: baseTotal = baseTotal + extents[index] + mainMargins[index]
    remaining = maxPx(px(0), available - gapTotal - baseTotal)
  elif flowCount > 0 and baseTotal == px(0):
    let equalExtent = maxPx(px(0), (available - gapTotal) / px(float32(flowCount)))
    for index, child in children:
      if tree.nodes[tree.nodeIndex(child)].layoutSpec.position != absolute: extents[
          index] = equalExtent
    baseTotal = px(0)
    for index in 0 ..< children.len: baseTotal = baseTotal + extents[index] + mainMargins[index]
    remaining = maxPx(px(0), available - gapTotal - baseTotal)

  ## Scrolling is a prepaint element offset. Keeping it out of the cursor
  ## leaves every node's layout bounds stable while it is scrolled.
  var cursor = if rowDirection: content.origin.x else: content.origin.y
  var distributedGap = spec.gap
  case mainAlignment
  of alignEnd: cursor = cursor + remaining
  of alignCenter: cursor = cursor + remaining / px(2)
  of alignSpaceBetween:
    if flowCount > 1: distributedGap = distributedGap + remaining / px(float32(flowCount - 1))
  of alignSpaceEvenly:
    distributedGap = distributedGap + remaining / px(float32(flowCount + 1))
    cursor = cursor + remaining / px(float32(flowCount + 1))
  of alignSpaceAround:
    if flowCount > 0:
      distributedGap = distributedGap + remaining / px(float32(flowCount))
      cursor = cursor + remaining / px(float32(flowCount * 2))
  else: discard

  for index, child in children:
    let childIndex = tree.nodeIndex(child)
    if childIndex < 0: continue
    let childNode = tree.nodes[childIndex]
    let childSpec = childNode.layoutSpec
    if childSpec.position == absolute:
      var childBounds = absoluteBounds(content, childSpec)
      childBounds = applyParentClip(childBounds, parentClip.region,
        parentClip.clipX, parentClip.clipY)
      layoutNodeRecursive(tree, child, childBounds, childSpec, parentClip.region,
        parentClip.clipX, parentClip.clipY)
      continue
    let leadingMargin = if rowDirection: childSpec.margin.top else: childSpec.margin.left
    let trailingMargin = if rowDirection: childSpec.margin.bottom else: childSpec.margin.right
    let crossAvailable = if rowDirection: content.size.height else: content.size.width
    let crossPreferred = if rowDirection: childNode.preferredSize.height else: childNode.preferredSize.width
    let crossMinimum = if rowDirection: childNode.minSize.height else: childNode.minSize.width
    let crossMaximum = if rowDirection: childNode.maxSize.height else: childNode.maxSize.width
    let crossExtent = if crossAlignment == alignStretch:
      minPx(crossMaximum, maxPx(crossMinimum,
        crossAvailable - leadingMargin - trailingMargin))
      elif float32(crossPreferred) > 0:
        minPx(crossMaximum, maxPx(crossMinimum, crossPreferred))
      else:
        minPx(crossMaximum, maxPx(crossMinimum,
          crossAvailable - leadingMargin - trailingMargin))
    let mainLeading = if rowDirection: childSpec.margin.left else: childSpec.margin.top
    let mainTrailing = if rowDirection: childSpec.margin.right else: childSpec.margin.bottom
    cursor = cursor + mainLeading
    var childSize = if rowDirection:
      Size(width: extents[index], height: crossExtent)
    else:
      Size(width: crossExtent, height: extents[index])
    let childOrigin = if rowDirection:
      Point(x: cursor, y: alignCross(content.origin.y, content.size.height,
        childSize.height, leadingMargin, trailingMargin, crossAlignment))
    else:
      Point(x: alignCross(content.origin.x, content.size.width, childSize.width,
        leadingMargin, trailingMargin, crossAlignment), y: cursor)
    var finalBounds = Rect(origin: childOrigin, size: childSize)
    if childSpec.position == relative: finalBounds = applyRelativeInset(finalBounds, childSpec)
    finalBounds = applyParentClip(finalBounds, parentClip.region,
      parentClip.clipX, parentClip.clipY)
    layoutNodeRecursive(tree, child, finalBounds, childSpec, parentClip.region,
      parentClip.clipX, parentClip.clipY)
    cursor = cursor + extents[index] + mainTrailing + distributedGap

proc layoutNode*(tree: var UiTree, id: NodeId, bounds: Rect, spec: LayoutSpec) =
  ## Layout the requested node and every descendant using each node's own
  ## LayoutSpec. The explicit spec is the root constraint; child specs are
  ## retained on UiNode, matching Zed's hierarchical layout tree.
  let index = tree.nodeIndex(id)
  if index < 0: return
  let normalized = normalizeLayoutSpec(spec)
  tree.nodes[index].layoutSpec = normalized
  tree.nodes[index].preferredSize = normalized.size
  tree.nodes[index].minSize = normalized.minSize
  tree.nodes[index].maxSize = normalized.maxSize
  layoutNodeRecursive(tree, id, resolveBounds(bounds, normalized), normalized,
    Rect(size: Size(width: px(0), height: px(0))), false, false)
