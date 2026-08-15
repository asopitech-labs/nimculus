import nimnui/geometry
import nimnui/layout
import nimnui/render
import nimnui/ui_tree
import std/options
import std/sets
import std/tables
import std/times
import std/typetraits

type
  NodePainter* = proc(paint: var PaintList, node: UiNode) {.closure.}

  ElementStateKey* = tuple[element: GlobalElementId, stateType: string]

  Frame* = object
    paint: PaintList
    elementStates*: Table[(GlobalElementId, string), ref RootObj]
    accessed*: seq[(GlobalElementId, string)]

  StateBox = object of RootObj
  TypedState[S] = ref object of StateBox
    value: S

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
    elementIdStack*: seq[ElementId]
    activeElementStates*: seq[ElementStateKey]
    scaleFactor*: float32
    frameDirty*: FrameDirtyAccumulator
    activeFrameDirty*: FrameDirtyAccumulator
    activeFrameDirtyAtDrawStart*: float64
    lastFrameTiming*: Option[FrameTiming]
    onFrameTiming*: proc(timing: FrameTiming) {.closure.}
    needsPresent*: bool
    presentCount*: uint64

  Window* = WindowInvalidator

converter toPaintList*(frame: var Frame): var PaintList =
  frame.paint

template commands*(frame: Frame): untyped = frame.paint.commands
template dirty*(frame: Frame): untyped = frame.paint.dirty
template scaleFactor*(frame: Frame): untyped = frame.paint.scaleFactor

proc newElementFrame(): Frame =
  Frame(paint: newFrame(),
        elementStates: initTable[(GlobalElementId, string), ref RootObj]())

proc clear*(frame: var Frame) =
  frame.paint.clear()
  frame.elementStates.clear()
  frame.accessed.setLen(0)

proc newWindow*(scaleFactor: float32 = 1.0): Window =
  result.dirtyViews = initHashSet[NodeId]()
  result.sidebarViews = initHashSet[NodeId]()
  result.phase = dpNone
  result.renderedFrame = newElementFrame()
  result.nextFrame = newElementFrame()
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

proc dirtyToDrawMs*(window: var Window): Option[float64] =
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

proc hitTest*(window: var Window, point: Point,
              kind: HitTestKind = hoverHitTest): HitTestResult =
  ## Window now owns two Frames. Keep the live input path on the var overload;
  ## a value parameter would copy both retained command lists on every event.
  hitTestHitboxes(window.hitboxes, point, kind)

proc hitTest*(window: Window, point: Point,
              kind: HitTestKind = hoverHitTest): HitTestResult =
  ## Keep immutable call sites source-compatible. The var overload is selected
  ## for the live Window, so the input hot path does not copy both Frames.
  hitTestHitboxes(window.hitboxes, point, kind)

proc debugAssertPrepaint*(window: var Window) =
  doAssert window.phase == dpPrepaint, "expected prepaint phase"

proc debugAssertPaint*(window: var Window) =
  doAssert window.phase == dpPaint, "expected paint phase"

proc debugAssertPaintOrPrepaint*(window: var Window) =
  doAssert window.phase in {dpPrepaint, dpPaint}, "expected paint or prepaint phase"

proc setScaleFactor*(window: var Window, scaleFactor: float32) =
  window.scaleFactor = if scaleFactor > 0: scaleFactor else: 1.0'f32
  window.nextFrame.scaleFactor = window.scaleFactor
  window.renderedFrame.scaleFactor = window.scaleFactor

proc beginFrame*(window: var Window, dirty: Rect) =
  window.nextFrame.clear()
  window.activeElementStates.setLen(0)
  window.nextFrame.scaleFactor = window.scaleFactor
  window.nextFrame.invalidate(dirty)

proc stateTypeName[S](): string = name(S)

proc statePath(window: Window, localId: ElementId): GlobalElementId =
  result = window.elementIdStack
  result.add(localId)

proc stateKey(id: GlobalElementId, stateType: string): ElementStateKey =
  (element: id, stateType: stateType)

proc newTypedState[S](value: S): ref RootObj =
  var state: TypedState[S]
  new(state)
  state.value = value
  cast[ref RootObj](state)

proc typedStateValue[S](state: ref RootObj): var S =
  cast[TypedState[S]](state).value

proc lookupElementState*(frame: var Frame, key: string): Option[ElementState] =
  let stateKey = (@[nameElementId(key)], stateTypeName[ElementState]())
  if not frame.elementStates.hasKey(stateKey):
    return none(ElementState)
  some(typedStateValue[ElementState](frame.elementStates[stateKey]))

proc checkStateType(window: Window, id: GlobalElementId, requested: string) =
  var foundInNext = false
  for key in window.nextFrame.elementStates.keys:
    if key[0] == id:
      foundInNext = true
      if key[1] != requested:
        raise newException(Defect, "element state type mismatch: requested " &
          requested & ", existing " & key[1])
  if not foundInNext:
    for key in window.renderedFrame.elementStates.keys:
      if key[0] == id and key[1] != requested:
        raise newException(Defect, "element state type mismatch: requested " &
          requested & ", existing " & key[1])

proc accessState[S](window: var Window, id: GlobalElementId,
                    defaultState: S): var S =
  let requested = stateTypeName[S]()
  window.checkStateType(id, requested)
  let key = stateKey(id, requested)
  if not window.nextFrame.elementStates.hasKey(key):
    if window.renderedFrame.elementStates.hasKey(key):
      window.nextFrame.elementStates[key] = window.renderedFrame.elementStates[key]
    else:
      window.nextFrame.elementStates[key] = newTypedState(defaultState)
  if key notin window.nextFrame.accessed:
    window.nextFrame.accessed.add(key)
  typedStateValue[S](window.nextFrame.elementStates[key])

proc accessElementState*(window: var Window, key: string,
                         defaultState = ElementState()): var ElementState =
  ## Compatibility for the existing paint path. It now uses the same
  ## per-element retained state machinery as the typed APIs.
  let id = @[nameElementId(key)]
  window.accessState(id, defaultState)

proc withElementNamespace*(window: var Window, namespace: ElementId,
                           action: proc() {.closure.}) =
  window.elementIdStack.add(namespace)
  try:
    if action != nil: action()
  finally:
    window.elementIdStack.setLen(window.elementIdStack.len - 1)

proc withElementNamespace*(window: var Window, namespace: GlobalElementId,
                           action: proc() {.closure.}) =
  let oldLength = window.elementIdStack.len
  for part in namespace:
    window.elementIdStack.add(part)
  try:
    if action != nil: action()
  finally:
    window.elementIdStack.setLen(oldLength)

proc withElementNamespace*(window: var Window, namespace: string,
                           action: proc() {.closure.}) =
  window.withElementNamespace(nameElementId(namespace), action)

proc withElementNamespace*(window: var Window, namespace: int64,
                           action: proc() {.closure.}) =
  window.withElementNamespace(integerElementId(namespace), action)

proc useKeyedState*[S](window: var Window, id: ElementId,
                       defaultState: S): var S =
  window.accessState(window.statePath(id), defaultState)

proc useKeyedState*[S](window: var Window, id: string,
                       defaultState: S): var S =
  window.useKeyedState(nameElementId(id), defaultState)

proc useKeyedState*[S](window: var Window, id: int64,
                       defaultState: S): var S =
  window.useKeyedState(integerElementId(id), defaultState)

proc withElementState*[S](window: var Window, id: ElementId,
                          defaultState: S,
                          action: proc(state: var S) {.closure.}) =
  let key = stateKey(window.statePath(id), stateTypeName[S]())
  if key in window.activeElementStates:
    raise newException(Defect, "re-entrancy in withElementState")
  window.activeElementStates.add(key)
  try:
    if action != nil: action(window.useKeyedState(id, defaultState))
  finally:
    window.activeElementStates.delete(window.activeElementStates.high)

proc withElementState*[S](window: var Window, id: ElementId,
                          action: proc(state: var S) {.closure.}) =
  window.withElementState(id, default(S), action)

proc withElementState*[S](window: var Window, id: string,
                          defaultState: S,
                          action: proc(state: var S) {.closure.}) =
  window.withElementState(nameElementId(id), defaultState, action)

proc withElementState*[S](window: var Window, id: string,
                          action: proc(state: var S) {.closure.}) =
  window.withElementState(nameElementId(id), default(S), action)

proc useCodeLocationState[S](window: var Window, file: string, line,
                             column: int, defaultState: S): var S =
  window.accessState(window.statePath(codeLocationElementId(file, line, column)),
    defaultState)

template useState*[S](window: var Window, defaultState: S): var S =
  let location = instantiationInfo()
  useCodeLocationState[S](window, location.filename, location.line,
    location.column, defaultState)

template useState*[S](window: var Window): var S =
  let location = instantiationInfo()
  useCodeLocationState[S](window, location.filename, location.line,
    location.column, default(S))

proc finishFrame*(window: var Window) =
  ## `accessState` inserts only visited keys into nextFrame.elementStates.
  ## Swapping the two complete frames therefore drops every unvisited key in
  ## exactly one frame.
  system.swap(window.renderedFrame, window.nextFrame)

proc swapFrames*(window: var Window) =
  ## Kept for callers written against the earlier two-step API. finishFrame
  ## now performs the swap, matching the retained frame lifecycle.
  discard window

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

proc layoutTree*(window: var Window, tree: var UiTree, root: NodeId,
                 bounds: Rect, spec: LayoutSpec) =
  ## Layout deliberately does not depend on the window's pixel scale. Scale
  ## is consulted only when ambient element offsets resolve during paint.
  tree.layoutNode(root, bounds, spec)
