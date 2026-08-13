import nimnui/geometry
import nimnui/ui_tree
import nimnui/layout
import nimnui/render
import nimculus/settings
import std/[strutils, tables]

export render.ScrollbarStyle, render.toPixels, render.scrollbarWidth,
  render.scrollbarStrip

type
  ControlKind* = enum
    label, button, scrollView, splitPane, tabBar, toolbar, statusBar, row, editor,
    contextMenu, popup, tooltip

  Control* = object
    node*: NodeId
    kind*: ControlKind
    text*: string
    layout*: LayoutSpec

  ScrollModel* = object
    offset*, contentSize*, viewportSize*: Pixels

  ## The setting is intentionally the same three-way choice as Zed's
  ## ShowScrollbar setting.  `autohide` is resolved against the platform's
  ## global preference by showBehavior below.
  ShowBehavior* = enum
    always, autohide, never

  ## A track click centers the thumb on the pointer. A thumb drag preserves
  ## the pointer's grab delta, which is why the two input cases are distinct.
  ScrollbarEventKind* = enum
    TrackClick, ThumbDrag

  ScrollbarEvent* = object
    kind*: ScrollbarEventKind
    grabDelta*: Pixels

  ScrollbarLayout* = object
    track*, thumb*: Rect
    visible*: bool

  ## The semantic button variants used by Zed's ButtonLike component.  The
  ## component owns the state-to-colour table; platform controls only consume
  ## the resolved result.
  ButtonStyle* = enum
    filled, tinted, outlined, outlinedGhost, subtle, transparent

  ButtonLikeStyles* = object
    background*, borderColor*, labelColor*, iconColor*: Color

proc themeColor(value: string, fallback: Color): Color =
  ## ThemeColors stores the same #RRGGBB[AA] tokens sent to native backends.
  ## Keep parsing here so button style resolution remains pure and testable.
  var token = value.strip
  if token.len == 0: return fallback
  if token[0] == '#': token = token[1 .. ^1]
  if token.len notin {6, 8}: return fallback
  try:
    let rgb = parseHexInt(token[0 .. 5])
    let alpha = if token.len == 8: parseHexInt(token[6 .. 7]) else: 255
    Color(red: float32((rgb shr 16) and 0xff) / 255'f32,
          green: float32((rgb shr 8) and 0xff) / 255'f32,
          blue: float32(rgb and 0xff) / 255'f32,
          alpha: float32(alpha) / 255'f32)
  except ValueError:
    fallback

proc withAlpha(color: Color, alpha: float32): Color =
  Color(red: color.red, green: color.green, blue: color.blue,
    alpha: max(0'f32, min(1'f32, alpha)))

proc clearColor(): Color = Color(red: 0, green: 0, blue: 0, alpha: 0)

proc visualState*(node: NodeId, tree: UiTree): UiState =
  ## Reading through UiTree is the only state access used by components.
  let index = tree.nodeIndex(node)
  if index >= 0: tree.nodes[index].state else: normal

proc buttonStyles*(node: NodeId, tree: UiTree, style: ButtonStyle,
                   theme: ThemeColors): ButtonLikeStyles =
  ## Resolve ButtonStyle × UiState in one place.  In particular, disabled is
  ## resolved last by UiTree's precedence and cannot be accidentally painted
  ## as hovered or active by a platform event path.
  let foreground = themeColor(theme.foreground,
    Color(red: 1, green: 1, blue: 1, alpha: 1))
  let accent = themeColor(theme.accent, foreground)
  let border = themeColor(theme.border, foreground.withAlpha(0.5'f32))
  let element = themeColor(theme.element, clearColor())
  let hover = themeColor(theme.elementHover, element)
  let activeColor = themeColor(theme.elementActive, hover)
  let disabledText = themeColor(theme.textDisabled,
    foreground.withAlpha(0.45'f32))
  let disabledBackground = element.withAlpha(0.5'f32)
  let disabledBorder = themeColor(theme.borderVariant, border)
  let state = node.visualState(tree)

  result = case style
    of filled:
      ButtonLikeStyles(background: accent, borderColor: accent,
        labelColor: foreground, iconColor: foreground)
    of tinted:
      ButtonLikeStyles(background: accent.withAlpha(0.16'f32),
        borderColor: clearColor(), labelColor: accent, iconColor: accent)
    of outlined:
      ButtonLikeStyles(background: clearColor(), borderColor: border,
        labelColor: foreground, iconColor: foreground)
    of outlinedGhost:
      ButtonLikeStyles(background: clearColor(), borderColor: clearColor(),
        labelColor: foreground, iconColor: foreground)
    of subtle:
      ButtonLikeStyles(background: element, borderColor: clearColor(),
        labelColor: foreground, iconColor: foreground)
    of transparent:
      ButtonLikeStyles(background: clearColor(), borderColor: clearColor(),
        labelColor: foreground, iconColor: foreground)

  case state
  of normal: discard
  of focused:
    result.borderColor = themeColor(theme.borderFocused, accent)
  of hovered:
    result.background = hover
  of active:
    result.background = if style == filled: accent else: activeColor
    if style in {outlined, outlinedGhost}: result.borderColor = accent
  of disabled:
    result.background = disabledBackground
    result.borderColor = disabledBorder
    result.labelColor = disabledText
    result.iconColor = disabledText

## Native AppKit chrome buttons use this small retained tree because their
## views are owned by the platform layer rather than by the demo UiTree.  The
## tree is still the source of truth: callers push flags here and receive the
## precedence-resolved UiState, never a second BOOL state machine.
var chromeButtonTree = newUiTree()
var chromeButtonNodes = initTable[uint64, NodeId]()

proc chromeButtonNode(identity: uint64): NodeId =
  if chromeButtonNodes.hasKey(identity): return chromeButtonNodes[identity]
  let node = chromeButtonTree.addNode(focusable = true)
  chromeButtonNodes[identity] = node
  node

proc nimculus_chrome_button_state*(identity: uint64, hovered, active,
                                  disabled: bool): cint {.exportc,
                                  cdecl.} =
  let node = chromeButtonNode(identity)
  chromeButtonTree.setHovered(node, hovered)
  chromeButtonTree.setActive(node, active)
  chromeButtonTree.setDisabled(node, disabled)
  cint(ord(chromeButtonTree.node(node).state))

proc trackClick*(): ScrollbarEvent =
  ScrollbarEvent(kind: TrackClick, grabDelta: px(0))

proc thumbDrag*(grabDelta: Pixels): ScrollbarEvent =
  ScrollbarEvent(kind: ThumbDrag, grabDelta: grabDelta)

proc showBehavior*(setting: ShowBehavior, osAutoHide: bool): ShowBehavior =
  ## macOS reports the global preference independently from the application
  ## setting.  Auto-hide only takes effect when that global preference also
  ## requests it; Always and Never remain explicit overrides.
  case setting
  of always: return always
  of autohide:
    if osAutoHide: return autohide
    return always
  of never: return never

proc fromSetting*(setting: ShowBehavior, osAutoHide: bool): ShowBehavior =
  setting.showBehavior(osAutoHide)

proc computeClickOffset*(eventPos, trackOrigin, viewportSize, thumbSize,
                         maxOffset: Pixels, event: ScrollbarEvent): Pixels =
  ## This is ScrollbarLayout::compute_click_offset from Zed: position the
  ## thumb in track coordinates, clamp it to its travel, then map that
  ## percentage onto the content offset.  A full-size thumb has no travel.
  let viewport = float32(viewportSize)
  let thumb = float32(thumbSize)
  if viewport <= 0'f32 or thumb >= viewport:
    return px(0)
  let thumbOffset = if event.kind == TrackClick: thumb / 2'f32
    else: float32(event.grabDelta)
  let thumbStart = max(0'f32, min(viewport - thumb,
    float32(eventPos) - float32(trackOrigin) - thumbOffset))
  let percentage = thumbStart / (viewport - thumb)
  px(-float32(maxOffset) * percentage)

proc computeClickOffset*(eventPos, trackOrigin, viewportSize, thumbSize,
                         maxOffset: Pixels, event: ScrollbarEventKind): Pixels =
  ## Convenience overload for callers that only have the event kind. A drag
  ## without a stored grab delta is equivalent to a zero-delta drag.
  computeClickOffset(eventPos, trackOrigin, viewportSize, thumbSize, maxOffset,
    ScrollbarEvent(kind: event, grabDelta: px(0)))

proc scrollbarThumbSize*(model: ScrollModel, trackSize: Pixels): Pixels =
  let track = max(0'f32, float32(trackSize))
  let content = float32(model.contentSize)
  let viewport = max(0'f32, float32(model.viewportSize))
  if track <= 0'f32 or content <= viewport or content <= 0'f32 or viewport <= 0'f32:
    return px(0)
  px(min(track, track * viewport / content))

proc scrollbarLayout*(model: ScrollModel, body: Rect,
                      style: ScrollbarStyle = regular,
                      behavior: ShowBehavior = always,
                      osAutoHide = false, scrolling = false): ScrollbarLayout =
  let strip = body.scrollbarStrip(style)
  let thumbHeight = model.scrollbarThumbSize(strip.size.height)
  let resolved = behavior.showBehavior(osAutoHide)
  result.track = strip
  result.visible = float32(thumbHeight) > 0'f32 and
    (case resolved
      of always: true
      of autohide: scrolling
      of never: false)
  if result.visible:
    let maximum = max(0'f32, float32(model.contentSize - model.viewportSize))
    let offset = if maximum > 0'f32:
      min(maximum, max(0'f32, float32(model.offset)))
    else: 0'f32
    let travel = max(0'f32, float32(strip.size.height) - float32(thumbHeight))
    let percentage = if maximum > 0'f32: offset / maximum else: 0'f32
    result.thumb = Rect(
      origin: Point(x: strip.origin.x,
        y: px(float32(strip.origin.y) + travel * percentage)),
      size: Size(width: strip.size.width, height: thumbHeight))

type
  SplitPaneModel* = object
    ratio*: float32
    dragging*: bool

  OverlayPlacement* = enum
    placeBelow, placeAbove

  OverlayItemKind* = enum
    separator, header, label, entry, customEntry, submenu

  ToggleState* = enum
    off, on, mixed

  OverlayItem* = object
    ## The discriminator keeps menu data independent from its renderer. The
    ## legacy fields remain common fields so old flat records still decode as
    ## entries in itemKind below.
    label*: string
    command*: string
    enabled*: bool
    toggled*: ToggleState
    endSlot*: string
    separator*: bool
    case kind*: OverlayItemKind
    of separator, header, label, entry, customEntry, submenu:
      discard

  OverlayKeyResult* = object
    handled*: bool
    command*: string

  ClickEventKind* = enum
    mouse, keyboard

  ClickEvent* = object
    case kind*: ClickEventKind
    of mouse:
      position*: Point
    of keyboard:
      keyCode*: uint32

  OverlayModel* = object
    kind*: ControlKind
    owner*: NodeId
    anchor*: Rect
    bounds*: Rect
    viewport*: Rect
    items*: seq[OverlayItem]
    contentText*: string
    itemHeight*: Pixels
    elevation*: ElevationIndex
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

proc itemKind(item: OverlayItem): OverlayItemKind =
  ## An omitted discriminator is the zero value (separator) in Nim object
  ## construction. Treat old records with content as entries while keeping an
  ## explicitly empty separator a separator.
  if item.kind == separator and not item.separator and
      (item.label.len > 0 or item.command.len > 0 or item.enabled):
    entry
  else:
    item.kind

proc selectable(item: OverlayItem): bool =
  if item.separator: return false
  case item.itemKind
  of entry, customEntry, submenu:
    item.enabled
  of separator, header, label:
    false

proc rowHeight(model: OverlayModel, item: OverlayItem): Pixels =
  case item.itemKind
  of separator:
    maxPx(px(1), model.itemHeight / px(2))
  of header, label, entry, customEntry, submenu:
    model.itemHeight

proc firstSelectable(items: seq[OverlayItem]): int =
  for index, item in items:
    if item.selectable: return index
  -1

proc overlayHeight(model: OverlayModel): Pixels =
  if model.kind == tooltip: return model.itemHeight
  if model.items.len == 0: return model.itemHeight
  result = px(0)
  for item in model.items:
    result = result + model.rowHeight(item)

func submenuVerticalOffset*(triggerBounds, menuBounds: Rect): Pixels =
  ## Keep the submenu placement contract as a pure geometry operation.
  triggerBounds.origin.y - menuBounds.origin.y

func submenuOffset*(triggerBounds, menuBounds: Rect): Pixels =
  submenuVerticalOffset(triggerBounds, menuBounds)

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
  model.elevation = if kind == contextMenu or kind == popup or kind == tooltip:
    elevatedSurface
  else:
    surface
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
  var y = model.bounds.origin.y
  for preceding in 0 ..< index:
    y = y + model.rowHeight(model.items[preceding])
  Rect(origin: Point(x: model.bounds.origin.x,
                     y: y),
       size: Size(width: model.bounds.size.width,
                  height: model.rowHeight(model.items[index])))

proc itemAt*(model: OverlayModel, point: Point): int =
  if not model.open or model.kind == tooltip or not model.bounds.contains(point): return -1
  for index in 0 ..< model.items.len:
    let row = model.rowBounds(index)
    if row.contains(point):
      if model.items[index].selectable: return index
      return -1
  -1

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

proc activate*(model: var OverlayModel, click: ClickEvent): OverlayKeyResult =
  if not model.open: return
  var shouldActivate = false
  case click.kind
  of mouse:
    let index = model.itemAt(click.position)
    if index >= 0:
      model.selectedIndex = index
      result.handled = true
      shouldActivate = true
    elif model.grabsInput:
      result.handled = true
      model.dismiss()
  of keyboard:
    if model.kind == tooltip: return
    case click.keyCode
    of 125'u32: result.handled = model.moveSelection(1)
    of 126'u32: result.handled = model.moveSelection(-1)
    of 36'u32, 49'u32:
      result.handled = true
      shouldActivate = true
    of 53'u32:
      result.handled = true
      model.dismiss()
    else: discard
  if shouldActivate:
    result.command = model.activateSelected()

proc handleKey*(model: var OverlayModel, keyCode: uint32): OverlayKeyResult =
  model.activate(ClickEvent(kind: keyboard, keyCode: keyCode))

proc handlePointerDown*(model: var OverlayModel, point: Point): OverlayKeyResult =
  model.activate(ClickEvent(kind: mouse, position: point))

proc handlePointerMove*(model: var OverlayModel, point: Point): bool =
  if not model.open: return false
  if model.kind == tooltip:
    if not model.anchor.contains(point):
      model.dismiss()
      return true
    return false
  model.selectAt(point)

proc paintOverlay*(paint: var PaintList, model: OverlayModel, light = true) =
  ## Emit the basic overlay primitives. Text shaping remains the renderer's
  ## responsibility, but the control now has a real paint path rather than an
  ## enum-only placeholder.
  if not model.open: return
  paint.invalidate(model.bounds)
  for boxShadow in shadows(model.elevation, light):
    paint.drawShadow(model.bounds, boxShadow.offset, boxShadow.blurRadius,
      boxShadow.colour)
  paint.drawRoundedRectangle(model.bounds, px(6))
  paint.drawBorder(model.bounds)
  if model.kind == tooltip:
    paint.drawText(model.bounds.inset(EdgeInsets(top: px(4), right: px(8),
      bottom: px(4), left: px(8))), model.contentText)
    return
  for index, item in model.items:
    let row = model.rowBounds(index)
    if index == model.selectedIndex: paint.drawRectangle(row)
    let kind = item.itemKind
    if kind == separator:
      paint.drawBorder(row.inset(EdgeInsets(top: px(3), right: px(8),
        bottom: px(3), left: px(8))))
    elif item.label.len > 0:
      var text = item.label
      if kind == entry:
        case item.toggled
        of on: text = "✓ " & text
        of mixed: text = "− " & text
        of off: discard
      if item.endSlot.len > 0:
        text = text & "  " & item.endSlot
      paint.drawText(row.inset(EdgeInsets(top: px(2), right: px(8),
        bottom: px(2), left: px(8))), text)

proc makeControl*(tree: var UiTree, parent: NodeId, kind: ControlKind,
                  text = "", focusable = false): Control =
  result.node = tree.addNode(parent, focusable)
  result.kind = kind
  result.text = text
  result.layout = LayoutSpec(direction: stack, size: Size(width: px(0), height: px(0)),
                             minSize: Size(width: px(0), height: px(0)),
                             maxSize: Size(width: px(100000), height: px(100000)))
  tree.setLayoutSpec(result.node, result.layout)

proc setControlAccessibility*(tree: var UiTree, control: Control,
                              identifier, title, value: string, action = "") =
  let role = case control.kind
    of label: a11yGroup
    of button: a11yButton
    of scrollView: a11yScrollArea
    of splitPane: a11yGroup
    of tabBar: a11yTabGroup
    of toolbar: a11yToolbar
    of statusBar: a11yStatusBar
    of row: a11yRow
    of editor: a11yTextInput
    of contextMenu, popup, tooltip: a11yGroup
  tree.setA11yInfo(control.node, role, identifier, title, value, action)
