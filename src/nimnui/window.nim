import nimnui/geometry
import nimnui/layout
import nimnui/render
import nimnui/ui_tree

type
  DrawPhase* = enum
    dpNone, dpPrepaint, dpPaint, dpFocus

  HitboxId* = distinct uint64

  Hitbox* = object
    id*: HitboxId
    bounds*: Rect

  FrameDirtyAccumulator* = object
    ## Lightweight Nim equivalent of GPUI's per-frame dirty profiler state.
    invalidations*: uint64

  NodePainter* = proc(paint: var PaintList, node: UiNode) {.closure.}

  Window* = object
    ## This is the retained UI-side part of a Zed window. Platform window
    ## lifecycle remains in the platform modules; this object owns the
    ## invalidation state machine as well as the retained paint list.
    paint*: PaintList
    scaleFactor*: float32
    dirty*: bool
    phase*: DrawPhase
    ## Kept as an explicit set so repeated invalidations of one view are
    ## coalesced before the next draw, just like GPUI's dirty_views.
    dirtyViews*: seq[NodeId]
    updateCount*: int
    frameDirty*: FrameDirtyAccumulator
    phaseHistory*: seq[DrawPhase]
    hitboxes*: seq[Hitbox]
    nextHitboxId: uint64

  ## The invalidator is intentionally the same public value as Window for now.
  ## This keeps the state-machine API usable in isolation while the platform
  ## window remains outside nimnui's ownership boundary.
  WindowInvalidator* = Window

proc newWindow*(scaleFactor: float32 = 1.0): Window =
  result.scaleFactor = if scaleFactor > 0: scaleFactor else: 1.0'f32
  result.paint.scaleFactor = result.scaleFactor
  result.dirty = true
  result.phase = dpNone
  result.nextHitboxId = 1

proc newWindowInvalidator*(): WindowInvalidator = newWindow()

proc setPhase*(window: var Window, phase: DrawPhase) =
  window.phase = phase
  window.phaseHistory.add(phase)

proc drawPhase*(window: Window): DrawPhase = window.phase

proc debugAssertPaint*(window: Window) =
  when defined(debug):
    doAssert window.phase == dpPaint,
      "this method can only be called during paint"

proc debugAssertPrepaint*(window: Window) =
  when defined(debug):
    doAssert window.phase == dpPrepaint,
      "this method can only be called during prepaint"

proc debugAssertPaintOrPrepaint*(window: Window) =
  when defined(debug):
    doAssert window.phase in {dpPrepaint, dpPaint},
      "this method can only be called during prepaint or paint"

proc invalidateView*(window: var Window, id: NodeId): bool =
  ## Invalidation raised while drawing is recorded for the current update but
  ## cannot restart the frame that is already in progress.
  inc window.updateCount
  inc window.frameDirty.invalidations
  var known = false
  for dirtyId in window.dirtyViews:
    if dirtyId == id:
      known = true
      break
  if not known: window.dirtyViews.add(id)
  if window.phase == dpNone:
    window.dirty = true
    result = true

proc markLayoutDirty*(window: var Window, id: NodeId): bool =
  window.invalidateView(id)

proc markLayoutDirty*(window: var Window, tree: var UiTree, id: NodeId): bool =
  tree.markLayoutDirty(id)
  window.markLayoutDirty(id)

proc clearDirty*(window: var Window) =
  window.dirty = false
  window.dirtyViews.setLen(0)

proc takeDirtyViews*(window: var Window): seq[NodeId] =
  result = window.dirtyViews
  window.dirtyViews.setLen(0)

proc beginDraw*(window: var Window) =
  window.phaseHistory.setLen(0)
  window.clearDirty()
  window.setPhase(dpPrepaint)

proc endDraw*(window: var Window) =
  if window.phase == dpPrepaint: window.setPhase(dpPaint)
  if window.phase == dpPaint: window.setPhase(dpFocus)
  if window.phase == dpFocus: window.setPhase(dpNone)

proc draw*(window: var Window, action: proc() {.closure.} = nil) =
  ## Run one complete draw. A callback can advance to a later phase itself
  ## (the main composition does this between layout and painting); otherwise
  ## the state machine supplies the remaining phases for small callers/tests.
  window.beginDraw()
  try:
    if action != nil: action()
  finally:
    window.endDraw()

proc insertHitbox*(window: var Window, bounds: Rect): Hitbox =
  window.debugAssertPrepaint()
  result = Hitbox(id: HitboxId(window.nextHitboxId), bounds: bounds)
  inc window.nextHitboxId
  window.hitboxes.add(result)

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
