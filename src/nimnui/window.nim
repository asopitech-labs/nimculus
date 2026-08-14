import nimnui/geometry
import nimnui/layout
import nimnui/render
import nimnui/ui_tree
import std/options
import std/sets
import std/times

type
  NodePainter* = proc(paint: var PaintList, node: UiNode) {.closure.}

  DrawPhase* = enum
    dpNone, dpPrepaint, dpPaint, dpFocus

  FrameDirtyAccumulator* = object
    ## The first invalidation starts the frame's dirty-to-drawn interval.
    ## Later invalidations are coalesced into the same frame but retained as
    ## a count, matching GPUI's FrameDirtyAccumulator.
    dirtyAt*: Option[float64]
    invalidations*: int

  FrameTiming* = object
    dirtyAt*: Option[float64]
    invalidations*: int
    drawStart*: float64
    drawEnd*: float64

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
    ## Zed keeps the last presented frame and the frame currently being
    ## composed separate.  State is migrated from renderedFrame to
    ## nextFrame only for elements accessed by the new frame.
    renderedFrame*: Frame
    nextFrame*: Frame
    scaleFactor*: float32
    frameDirty*: FrameDirtyAccumulator
    activeFrameDirty*: FrameDirtyAccumulator
    activeFrameDirtyAtDrawStart*: float64
    lastFrameTiming*: Option[FrameTiming]
    onFrameTiming*: proc(timing: FrameTiming) {.closure.}
    needsPresent*: bool
    presentCount*: uint64

  Window* = WindowInvalidator

proc newWindow*(scaleFactor: float32 = 1.0): Window =
  result.dirtyViews = initHashSet[NodeId]()
  result.sidebarViews = initHashSet[NodeId]()
  result.phase = dpNone
  result.renderedFrame = newFrame()
  result.nextFrame = newFrame()
  result.scaleFactor = if scaleFactor > 0: scaleFactor else: 1.0'f32
  result.nextFrame.scaleFactor = result.scaleFactor
  result.renderedFrame.scaleFactor = result.scaleFactor

proc newWindowInvalidator*(scaleFactor: float32 = 1.0): WindowInvalidator =
  newWindow(scaleFactor)

proc recordFrameDirty*(accumulator: var FrameDirtyAccumulator,
                       dirtyAt = epochTime()) =
  if accumulator.dirtyAt.isNone:
    accumulator.dirtyAt = some(float64(dirtyAt))
  inc accumulator.invalidations

proc takeFrameDirty*(accumulator: var FrameDirtyAccumulator): FrameDirtyAccumulator =
  result = accumulator
  accumulator = FrameDirtyAccumulator()

proc dirtyToDrawMs*(timing: FrameTiming): Option[float64] =
  if timing.dirtyAt.isNone: return none(float64)
  some((timing.drawEnd - timing.dirtyAt.get) * 1000.0)

proc dirtyToDrawMs*(window: Window): Option[float64] =
  if window.lastFrameTiming.isNone: return none(float64)
  window.lastFrameTiming.get.dirtyToDrawMs()

proc requestPresent*(window: var Window): bool =
  ## Reserve one platform presentation for the current rendered paint list.
  ## Re-publishing before the corresponding present is deliberately a no-op.
  if window.needsPresent: return false
  window.needsPresent = true
  true

proc publishPaint*(window: var Window): bool =
  ## Reserve the paint-list publication that will be consumed by present.
  window.requestPresent()

proc markNeedsPresent*(window: var Window) =
  discard window.requestPresent()

proc presentIfNeeded*(window: var Window): bool =
  if not window.needsPresent: return false
  window.needsPresent = false
  inc window.presentCount
  true

proc present*(window: var Window): bool =
  window.presentIfNeeded()

proc invalidateView*(window: var Window, id: NodeId, sidebar = false) =
  inc window.updateCount
  window.frameDirty.recordFrameDirty()
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
  window.activeFrameDirty = window.frameDirty.takeFrameDirty()
  window.lastFrameTiming = none(FrameTiming)
  let drawStart = float64(epochTime())
  window.dirty = false
  window.dirtyViews.clear()
  window.sidebarRedrawRequested = false
  window.phaseHistory.setLen(0)
  window.hitboxes.setLen(0)
  window.activeFrameDirtyAtDrawStart = drawStart
  window.setPhase(dpPrepaint)

proc endDraw*(window: var Window) =
  doAssert window.phase == dpFocus, "a draw must finish from dpFocus"
  let timing = FrameTiming(
    dirtyAt: window.activeFrameDirty.dirtyAt,
    invalidations: window.activeFrameDirty.invalidations,
    drawStart: window.activeFrameDirtyAtDrawStart,
    drawEnd: float64(epochTime()))
  window.lastFrameTiming = some(timing)
  if window.onFrameTiming != nil: window.onFrameTiming(timing)
  window.activeFrameDirty = FrameDirtyAccumulator()
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
    if window.phase == dpFocus: window.endDraw()
    elif window.phase != dpNone: window.setPhase(dpNone)

proc insertHitbox*(window: var Window, id: NodeId, bounds: Rect,
                   behavior = hitboxNormal, contentMask = Rect(), enabled = true) =
  doAssert window.phase == dpPrepaint, "hitboxes may only be inserted during prepaint"
  let mask = if float32(contentMask.size.width) == 0 and
      float32(contentMask.size.height) == 0:
    window.nextFrame.currentContentMask(bounds)
  else: contentMask
  window.hitboxes.add(Hitbox(id: id, node: id, bounds: bounds,
    contentMask: mask, behavior: behavior, enabled: enabled))

proc prepaintTree*(window: var Window, tree: UiTree, root: NodeId,
                   behavior = hitboxNormal) =
  ## Record the same rows that the painter sees. `nodeClip` is passed as the
  ## mask explicitly because this retained tree's layout has already resolved
  ## its ancestor clips before prepaint begins.
  ## Keep the traversal iterative: capturing `window` in a nested proc is not
  ## memory-safe for a `var Window` parameter under ARC release compilation.
  var pending = @[root]
  while pending.len > 0:
    let id = pending[^1]
    pending.setLen(pending.len - 1)
    let index = tree.nodeIndex(id)
    if index < 0: continue
    let node = tree.nodes[index]
    window.insertHitbox(node.id, node.bounds, behavior, node.nodeClip(),
      not tree.isDisabledPath(node.id))
    for childIndex in countdown(node.children.high, 0):
      pending.add(node.children[childIndex])

proc hitTest*(window: Window, point: Point,
              kind: HitTestKind = hoverHitTest): HitTestResult =
  hitTestHitboxes(window.hitboxes, point, kind)

proc debugAssertPrepaint*(window: Window) =
  doAssert window.phase == dpPrepaint, "expected prepaint phase"

proc debugAssertPaint*(window: Window) =
  doAssert window.phase == dpPaint, "expected paint phase"

proc debugAssertPaintOrPrepaint*(window: Window) =
  doAssert window.phase in {dpPrepaint, dpPaint}, "expected paint or prepaint phase"

proc setScaleFactor*(window: var Window, scaleFactor: float32) =
  window.scaleFactor = if scaleFactor > 0: scaleFactor else: 1.0'f32
  window.nextFrame.scaleFactor = window.scaleFactor
  window.renderedFrame.scaleFactor = window.scaleFactor

proc beginFrame*(window: var Window, dirty: Rect) =
  window.nextFrame.clear()
  window.nextFrame.scaleFactor = window.scaleFactor
  window.nextFrame.invalidate(dirty)

proc accessElementState*(window: var Window, key: string,
                         defaultState = ElementState()): var ElementState =
  window.nextFrame.accessElementState(window.renderedFrame, key, defaultState)

proc finishFrame*(window: var Window) =
  window.nextFrame.finishFrame(window.renderedFrame)

proc swapFrames*(window: var Window) =
  swap(window.renderedFrame, window.nextFrame)

proc withContentMask*(window: var Window, bounds: Rect, action: proc() {.closure.}) =
  ## Content masks intersect with the current mask in pushClip, exactly as
  ## Window::with_content_mask does in GPUI.
  window.nextFrame.pushClip(bounds)
  try:
    action()
  finally:
    window.nextFrame.popClip()

proc withElementOffset*(window: var Window, offset: Point,
                        action: proc() {.closure.}) =
  window.nextFrame.pushElementOffset(offset)
  try:
    action()
  finally:
    window.nextFrame.popElementOffset()

proc withAbsoluteElementOffset*(window: var Window, offset: Point,
                                action: proc() {.closure.}) =
  window.nextFrame.pushAbsoluteElementOffset(offset)
  try:
    action()
  finally:
    window.nextFrame.popElementOffset()

proc paintNode*(window: var Window, node: UiNode, painter: NodePainter) =
  ## Every node enters the paint list with the same effective mask exposed by
  ## layout. This prevents input and paint from consulting different clips.
  window.nextFrame.pushClip(node.nodeClip())
  try:
    painter(window.nextFrame, node)
  finally:
    window.nextFrame.popClip()

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
    window.nextFrame.pushElementOffset(Point(x: px(0), y: px(-float32(scroll))))
  try:
    for child in node.children:
      window.paintNodeRecursive(tree, child, painter)
  finally:
    if hasScroll: window.nextFrame.popElementOffset()

proc paintTree*(window: var Window, tree: UiTree, root: NodeId,
                painter: NodePainter) =
  window.paintNodeRecursive(tree, root, painter)

proc layoutTree*(window: Window, tree: var UiTree, root: NodeId,
                 bounds: Rect, spec: LayoutSpec) =
  ## Layout deliberately does not depend on the window's pixel scale. Scale
  ## is consulted only when ambient element offsets resolve during paint.
  tree.layoutNode(root, bounds, spec)
