import nimnui/geometry
import nimnui/layout
import nimnui/render
import nimnui/ui_tree
import std/sets

type
  NodePainter* = proc(paint: var PaintList, node: UiNode) {.closure.}

  DrawPhase* = enum
    dpNone, dpPrepaint, dpPaint, dpFocus

  Hitbox* = object
    node*: NodeId
    bounds*: Rect

  WindowInvalidator* = object
    ## Window-owned invalidation state. The platform owns scheduling and
    ## presentation; this state decides whether the Nim tree must compose.
    dirty*: bool
    phase*: DrawPhase
    dirtyViews*: HashSet[NodeId]
    sidebarViews*: HashSet[NodeId]
    sidebarRedrawRequested*: bool
    updateCount*: int
    phaseHistory*: seq[DrawPhase]
    hitboxes*: seq[Hitbox]
    onInvalidate*: proc() {.closure.}
    ## This is the retained UI-side part of a Zed window. Platform window
    ## lifecycle remains in the platform modules; this object owns only the
    ## per-frame content mask, invalidation state, and prepaint state.
    paint*: PaintList
    scaleFactor*: float32

  Window* = WindowInvalidator

proc newWindow*(scaleFactor: float32 = 1.0): Window =
  result.dirtyViews = initHashSet[NodeId]()
  result.sidebarViews = initHashSet[NodeId]()
  result.phase = dpNone
  result.scaleFactor = if scaleFactor > 0: scaleFactor else: 1.0'f32
  result.paint.scaleFactor = result.scaleFactor

proc newWindowInvalidator*(scaleFactor: float32 = 1.0): WindowInvalidator =
  newWindow(scaleFactor)

proc invalidateView*(window: var Window, id: NodeId, sidebar = false) =
  inc window.updateCount
  if window.phase == dpNone:
    window.dirty = true
    window.dirtyViews.incl(id)
    if sidebar or id in window.sidebarViews:
      window.sidebarRedrawRequested = true
    if window.onInvalidate != nil: window.onInvalidate()

proc markLayoutDirty*(window: var Window, id: NodeId, sidebar = false) =
  window.invalidateView(id, sidebar)

proc registerSidebarView*(window: var Window, id: NodeId) =
  window.sidebarViews.incl(id)

proc setPhase*(window: var Window, phase: DrawPhase) =
  window.phase = phase
  window.phaseHistory.add(phase)

proc beginDraw*(window: var Window) =
  doAssert window.phase == dpNone, "a draw must begin in dpNone"
  window.dirty = false
  window.dirtyViews.clear()
  window.sidebarRedrawRequested = false
  window.phaseHistory.setLen(0)
  window.hitboxes.setLen(0)
  window.setPhase(dpPrepaint)

proc endDraw*(window: var Window) =
  doAssert window.phase == dpFocus, "a draw must finish from dpFocus"
  window.setPhase(dpNone)

proc draw*(window: var Window, prepaint, paint, focus: proc() {.closure.}) =
  window.beginDraw()
  try:
    if prepaint != nil: prepaint()
    window.setPhase(dpPaint)
    if paint != nil: paint()
    window.setPhase(dpFocus)
    if focus != nil: focus()
  finally:
    if window.phase != dpNone: window.setPhase(dpNone)

proc insertHitbox*(window: var Window, id: NodeId, bounds: Rect) =
  doAssert window.phase == dpPrepaint, "hitboxes may only be inserted during prepaint"
  window.hitboxes.add(Hitbox(node: id, bounds: bounds))

proc debugAssertPrepaint*(window: Window) =
  doAssert window.phase == dpPrepaint, "expected prepaint phase"

proc debugAssertPaint*(window: Window) =
  doAssert window.phase == dpPaint, "expected paint phase"

proc debugAssertPaintOrPrepaint*(window: Window) =
  doAssert window.phase in {dpPrepaint, dpPaint}, "expected paint or prepaint phase"

proc setScaleFactor*(window: var Window, scaleFactor: float32) =
  window.scaleFactor = if scaleFactor > 0: scaleFactor else: 1.0'f32
  window.paint.scaleFactor = window.scaleFactor

proc beginFrame*(window: var Window, dirty: Rect) =
  window.paint.clear()
  window.paint.scaleFactor = window.scaleFactor
  window.paint.invalidate(dirty)

proc withContentMask*(window: var Window, bounds: Rect, action: proc() {.closure.}) =
  ## Content masks intersect with the current mask in pushClip, exactly as
  ## Window::with_content_mask does in GPUI.
  window.paint.pushClip(bounds)
  try:
    action()
  finally:
    window.paint.popClip()

proc withElementOffset*(window: var Window, offset: Point,
                        action: proc() {.closure.}) =
  window.paint.pushElementOffset(offset)
  try:
    action()
  finally:
    window.paint.popElementOffset()

proc withAbsoluteElementOffset*(window: var Window, offset: Point,
                                action: proc() {.closure.}) =
  window.paint.pushAbsoluteElementOffset(offset)
  try:
    action()
  finally:
    window.paint.popElementOffset()

proc paintNode*(window: var Window, node: UiNode, painter: NodePainter) =
  ## Every node enters the paint list with the same effective mask exposed by
  ## layout. This prevents input and paint from consulting different clips.
  window.paint.pushClip(node.nodeClip())
  try:
    painter(window.paint, node)
  finally:
    window.paint.popClip()

proc paintNodeRecursive(window: var Window, tree: UiTree, id: NodeId,
                        painter: NodePainter) =
  let index = tree.nodeIndex(id)
  if index < 0: return
  let node = tree.nodes[index]
  window.paintNode(node, painter)

  ## A scroll offset belongs to the container's content, so it starts after
  ## the container itself and is ambient for all descendants.
  let scroll = node.layoutSpec.scrollOffset
  let hasScroll = float32(scroll) != 0
  if hasScroll:
    window.paint.pushElementOffset(Point(x: px(0), y: px(-float32(scroll))))
  try:
    for child in node.children:
      window.paintNodeRecursive(tree, child, painter)
  finally:
    if hasScroll: window.paint.popElementOffset()

proc paintTree*(window: var Window, tree: UiTree, root: NodeId,
                painter: NodePainter) =
  window.paintNodeRecursive(tree, root, painter)

proc layoutTree*(window: Window, tree: var UiTree, root: NodeId,
                 bounds: Rect, spec: LayoutSpec) =
  ## Layout deliberately does not depend on the window's pixel scale. Scale
  ## is consulted only when ambient element offsets resolve during paint.
  tree.layoutNode(root, bounds, spec)
