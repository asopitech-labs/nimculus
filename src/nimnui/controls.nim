import nimnui/geometry
import nimnui/ui_tree
import nimnui/layout
import nimnui/render

type
  ControlKind* = enum
    label, button, scrollView, splitPane, tabBar, contextMenu, popup, tooltip

  Control* = object
    node*: NodeId
    kind*: ControlKind
    text*: string
    layout*: LayoutSpec

  ScrollModel* = object
    offset*, contentSize*, viewportSize*: Pixels

  SplitPaneModel* = object
    ratio*: float32
    dragging*: bool

  OverlayPlacement* = enum
    placeBelow, placeAbove

  OverlayItem* = object
    label*: string
    command*: string
    enabled*: bool
    separator*: bool

  OverlayKeyResult* = object
    handled*: bool
    command*: string

  OverlayModel* = object
    kind*: ControlKind
    owner*: NodeId
    anchor*: Rect
    bounds*: Rect
    viewport*: Rect
    items*: seq[OverlayItem]
    contentText*: string
    itemHeight*: Pixels
    open*: bool
    grabsInput*: bool
    selectedIndex*: int

proc scrollBy*(model: var ScrollModel, delta: Pixels) =
  let maximum = maxPx(px(0), model.contentSize - model.viewportSize)
  model.offset = minPx(maximum, maxPx(px(0), model.offset + delta))

proc beginDrag*(model: var SplitPaneModel) = model.dragging = true
proc endDrag*(model: var SplitPaneModel) = model.dragging = false
proc dragTo*(model: var SplitPaneModel, ratio: float32) =
  if model.dragging: model.ratio = min(1'f32, max(0'f32, ratio))

proc selectable(item: OverlayItem): bool = item.enabled and not item.separator

proc firstSelectable(items: seq[OverlayItem]): int =
  for index, item in items:
    if item.selectable: return index
  -1

proc overlayHeight(model: OverlayModel): Pixels =
  let rows = if model.kind == tooltip: 1 else: max(1, model.items.len)
  model.itemHeight * float32(rows)

proc clampOverlayBounds(anchor, viewport: Rect, size: Size,
                        placement: OverlayPlacement): Rect =
  if float32(viewport.size.width) <= 0 or float32(viewport.size.height) <= 0:
    return Rect()
  var x = anchor.origin.x
  var y = if placement == placeAbove:
    anchor.origin.y - size.height
  else:
    anchor.origin.y + anchor.size.height
  let right = viewport.origin.x + viewport.size.width
  let bottom = viewport.origin.y + viewport.size.height
  x = minPx(maxPx(viewport.origin.x, x), maxPx(viewport.origin.x, right - size.width))
  y = minPx(maxPx(viewport.origin.y, y), maxPx(viewport.origin.y, bottom - size.height))
  Rect(origin: Point(x: x, y: y), size: size)

proc showOverlay*(model: var OverlayModel, kind: ControlKind, owner: NodeId,
                  anchor, viewport: Rect, items: openArray[OverlayItem],
                  contentText = "", itemHeight = px(24'f32),
                  preferredWidth = px(240'f32),
                  placement = placeBelow, grabsInput = true) =
  ## Build an in-window overlay model. Menus grab input and are dismissible;
  ## tooltips are passive. Placement is anchor-relative and clamped to the
  ## current viewport, matching Zed's anchored popup contract.
  model.kind = kind
  model.owner = owner
  model.anchor = anchor
  model.viewport = viewport
  model.items = newSeq[OverlayItem](items.len)
  for index, item in items:
    model.items[index] = item
  model.contentText = contentText
  model.itemHeight = maxPx(px(1), itemHeight)
  model.grabsInput = grabsInput and kind != tooltip
  let width = minPx(maxPx(px(1), preferredWidth), viewport.size.width)
  let height = minPx(maxPx(px(1), model.overlayHeight), viewport.size.height)
  var effectivePlacement = placement
  if placement == placeBelow and
      float32(anchor.origin.y + anchor.size.height + height) >
        float32(viewport.origin.y + viewport.size.height) and
      float32(anchor.origin.y - height) >= float32(viewport.origin.y):
    effectivePlacement = placeAbove
  elif placement == placeAbove and
      float32(anchor.origin.y - height) < float32(viewport.origin.y) and
      float32(anchor.origin.y + anchor.size.height + height) <=
        float32(viewport.origin.y + viewport.size.height):
    effectivePlacement = placeBelow
  model.bounds = clampOverlayBounds(anchor, viewport,
    Size(width: width, height: height), effectivePlacement)
  model.selectedIndex = if kind == tooltip: -1 else: model.items.firstSelectable
  model.open = float32(model.bounds.size.width) > 0 and
    float32(model.bounds.size.height) > 0

proc showContextMenu*(model: var OverlayModel, owner: NodeId, anchor, viewport: Rect,
                      items: openArray[OverlayItem], preferredWidth = px(240'f32)) =
  model.showOverlay(contextMenu, owner, anchor, viewport, items,
    preferredWidth = preferredWidth, grabsInput = true)

proc showPopup*(model: var OverlayModel, owner: NodeId, anchor, viewport: Rect,
                items: openArray[OverlayItem], preferredWidth = px(240'f32)) =
  model.showOverlay(popup, owner, anchor, viewport, items,
    preferredWidth = preferredWidth, grabsInput = true)

proc showTooltip*(model: var OverlayModel, owner: NodeId, anchor, viewport: Rect,
                  text: string, preferredWidth = px(320'f32)) =
  model.showOverlay(tooltip, owner, anchor, viewport, [], contentText = text,
    preferredWidth = preferredWidth, grabsInput = false)

proc dismiss*(model: var OverlayModel) =
  model.open = false
  model.selectedIndex = -1

proc rowBounds*(model: OverlayModel, index: int): Rect =
  if index < 0 or index >= model.items.len or not model.open: return Rect()
  Rect(origin: Point(x: model.bounds.origin.x,
                     y: model.bounds.origin.y + model.itemHeight * float32(index)),
       size: Size(width: model.bounds.size.width, height: model.itemHeight))

proc itemAt*(model: OverlayModel, point: Point): int =
  if not model.open or model.kind == tooltip or not model.bounds.contains(point): return -1
  let relative = float32(point.y) - float32(model.bounds.origin.y)
  let index = int(relative / float32(model.itemHeight))
  if index < 0 or index >= model.items.len or not model.items[index].selectable: return -1
  index

proc selectAt*(model: var OverlayModel, point: Point): bool =
  let index = model.itemAt(point)
  if index < 0: return false
  model.selectedIndex = index
  true

proc moveSelection*(model: var OverlayModel, delta: int): bool =
  if not model.open or model.kind == tooltip or model.items.len == 0: return false
  var index = model.selectedIndex
  if index < 0: index = if delta < 0: model.items.len else: -1
  let direction = if delta < 0: -1 else: 1
  let steps = max(1, abs(delta))
  for _ in 0 ..< steps:
    var attempts = 0
    while attempts < model.items.len:
      index = (index + direction + model.items.len) mod model.items.len
      inc attempts
      if model.items[index].selectable:
        break
    if attempts >= model.items.len and not model.items[index].selectable: return false
  model.selectedIndex = index
  true

proc activateSelected*(model: var OverlayModel): string =
  if not model.open or model.selectedIndex < 0 or
      model.selectedIndex >= model.items.len or
      not model.items[model.selectedIndex].selectable: return ""
  result = model.items[model.selectedIndex].command
  model.dismiss()

proc handleKey*(model: var OverlayModel, keyCode: uint32): OverlayKeyResult =
  if not model.open or model.kind == tooltip: return
  case keyCode
  of 125'u32: result.handled = model.moveSelection(1)
  of 126'u32: result.handled = model.moveSelection(-1)
  of 36'u32, 49'u32:
    result.handled = model.kind != tooltip
    if result.handled: result.command = model.activateSelected()
  of 53'u32:
    result.handled = true
    model.dismiss()
  else: discard

proc handlePointerDown*(model: var OverlayModel, point: Point): OverlayKeyResult =
  if not model.open: return
  let index = model.itemAt(point)
  if index >= 0:
    model.selectedIndex = index
    result.handled = true
    result.command = model.activateSelected()
  elif model.grabsInput:
    result.handled = true
    model.dismiss()

proc handlePointerMove*(model: var OverlayModel, point: Point): bool =
  if not model.open: return false
  if model.kind == tooltip:
    if not model.anchor.contains(point):
      model.dismiss()
      return true
    return false
  model.selectAt(point)

proc paintOverlay*(paint: var PaintList, model: OverlayModel) =
  ## Emit the basic overlay primitives. Text shaping remains the renderer's
  ## responsibility, but the control now has a real paint path rather than an
  ## enum-only placeholder.
  if not model.open: return
  paint.invalidate(model.bounds)
  paint.drawShadow(model.bounds.offset(px(2), px(3)))
  paint.drawRoundedRectangle(model.bounds, px(6))
  paint.drawBorder(model.bounds)
  if model.kind == tooltip:
    paint.drawText(model.bounds.inset(EdgeInsets(top: px(4), right: px(8),
      bottom: px(4), left: px(8))), model.contentText)
    return
  for index, item in model.items:
    let row = model.rowBounds(index)
    if index == model.selectedIndex: paint.drawRectangle(row)
    if not item.separator and item.label.len > 0:
      paint.drawText(row.inset(EdgeInsets(top: px(2), right: px(8),
        bottom: px(2), left: px(8))), item.label)
    elif item.separator:
      paint.drawBorder(row.inset(EdgeInsets(top: px(11), right: px(8),
        bottom: px(11), left: px(8))))

proc makeControl*(tree: var UiTree, parent: NodeId, kind: ControlKind,
                  text = "", focusable = false): Control =
  result.node = tree.addNode(parent, focusable)
  result.kind = kind
  result.text = text
  result.layout = LayoutSpec(direction: stack, size: Size(width: px(0), height: px(0)),
                             minSize: Size(width: px(0), height: px(0)),
                             maxSize: Size(width: px(100000), height: px(100000)))
  tree.setLayoutSpec(result.node, result.layout)
