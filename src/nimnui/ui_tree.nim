import nimnui/geometry
import nimnui/layout_types
import nimnui/context
import std/algorithm
import std/tables

type
  NodeId* = distinct uint64

  ## The public EventHandler is declared in events.nim because UiEvent depends
  ## on the command module.  This private bridge is stored on a node;
  ## events.nim adapts the public handler to it without introducing an import
  ## cycle between commands, events, and ui_tree.
  EventHandler = proc(event: pointer) {.closure.}

  ActionHandler* = proc(action: string) {.closure.}

  A11yRole* = enum
    a11yNone, a11yWindow, a11yGroup, a11yToolbar, a11yButton, a11yTabGroup,
    a11yTab, a11yStatusBar, a11yScrollArea, a11yRow, a11yTextInput, a11yTextRun

  NodeHandle* = object
    id*: NodeId
    generation*: uint32
    tabIndex*: int
    tabStop*: bool

  UiState* = enum
    normal, focused, hovered, active, disabled

  UiNode* = object
    id*: NodeId
    parent*: NodeId
    children*: seq[NodeId]
    bounds*: Rect
    clipBounds*: Rect
    clipChildren*: bool
    clipX*, clipY*: bool
    state*: UiState
    layoutDirty*: bool
    paintDirty*: bool
    focusable*: bool
    tabIndex*: int
    tabStop*: bool
    generation*: uint32
    focusedState*, hoveredState*, activeState*, disabledState*: bool
    flexGrow*: float32
    preferredSize*, minSize*, maxSize*: Size
    layoutSpec*: LayoutSpec
    a11yRole*: A11yRole
    a11yIdentifier*, a11yTitle*, a11yValue*: string
    a11yAction*: string
    a11ySelected*, a11yExpanded*: bool
    context*: KeyContext
    keyListeners*: seq[EventHandler]
    modifiersChangedListeners*: seq[EventHandler]
    actionListeners*: seq[tuple[action: string, handler: ActionHandler]]

  UiTree* = object
    nodes*: seq[UiNode]
    index*: Table[NodeId, int]
    nextId*: uint64
    focused*: NodeId
    nextGeneration*: uint32
    recycledIds: seq[NodeId]
    reservedFocusHandles: seq[NodeHandle]

proc `==`*(a, b: NodeId): bool = uint64(a) == uint64(b)

proc a11yNodeId*(node: UiNode): uint64 =
  var value = uint64(node.id) xor (uint64(node.generation) * 0x9e3779b97f4a7c15'u64)
  value = (value xor (value shr 30)) * 0xbf58476d1ce4e5b9'u64
  value = (value xor (value shr 27)) * 0x94d049bb133111eb'u64
  value xor (value shr 31)

proc newUiTree*(): UiTree = UiTree(nextId: 1, nextGeneration: 1,
                                   focused: NodeId(0), index: initTable[NodeId, int]())

proc nodeIndex*(tree: UiTree, id: NodeId): int =
  let index = tree.index.getOrDefault(id, -1)
  if index >= 0 and index < tree.nodes.len and tree.nodes[index].id == id:
    index
  else:
    -1

proc dispatchPath*(tree: UiTree, target: NodeId): seq[NodeId]
proc focusContains*(tree: UiTree, parent, child: NodeId): bool
proc isValid*(tree: UiTree, handle: NodeHandle): bool
proc nodeClip*(node: UiNode): Rect
proc updateVisualState(tree: var UiTree, index: int)

proc nextNodeHandle(tree: var UiTree): NodeHandle =
  if tree.reservedFocusHandles.len > 0:
    result = tree.reservedFocusHandles[0]
    tree.reservedFocusHandles.delete(0)
  else:
    let id = if tree.recycledIds.len > 0:
      let recycledId = tree.recycledIds[^1]
      tree.recycledIds.setLen(tree.recycledIds.len - 1)
      recycledId
    else:
      let next = NodeId(tree.nextId)
      inc tree.nextId
      next
    result.id = id
    result.generation = tree.nextGeneration
    inc tree.nextGeneration
    result.tabStop = true

proc addNodeWithHandle(tree: var UiTree, handle: NodeHandle, parent: NodeId,
                       focusable: bool, tabIndex: int, tabStop: bool): NodeId =
  if handle.id == NodeId(0) or tree.isValid(handle): return NodeId(0)
  for index in countdown(tree.reservedFocusHandles.high, 0):
    if tree.reservedFocusHandles[index].id == handle.id:
      tree.reservedFocusHandles.delete(index)
      break
  let id = handle.id
  let index = tree.nodes.len
  let generation = handle.generation
  tree.nodes.add(UiNode(id: id, parent: parent, state: normal,
                        layoutDirty: true, paintDirty: true, focusable: focusable,
                        tabIndex: tabIndex, tabStop: tabStop,
                        generation: generation,
                        maxSize: Size(width: px(100000), height: px(100000)),
                        layoutSpec: defaultLayoutSpec()))
  tree.index[id] = index
  if parent != NodeId(0):
    for node in tree.nodes.mitems:
      if node.id == parent:
        node.children.add(id)
        node.layoutDirty = true
        node.paintDirty = true
        break
  id

proc addNode*(tree: var UiTree, parent: NodeId = NodeId(0), focusable = false,
              tabIndex = 0, tabStop = true): NodeId =
  let handle = tree.nextNodeHandle()
  tree.addNodeWithHandle(handle, parent, focusable, tabIndex, tabStop)

proc addNode*(tree: var UiTree, handle: NodeHandle,
              parent: NodeId = NodeId(0), focusable = false): NodeId =
  tree.addNodeWithHandle(handle, parent, focusable, handle.tabIndex, handle.tabStop)

proc newFocusHandle*(tree: var UiTree): NodeHandle =
  ## Reserve an identity before its node is attached to the tree.
  result = tree.nextNodeHandle()
  tree.reservedFocusHandles.add(result)

proc removeNode*(tree: var UiTree, id: NodeId): bool =
  ## Remove a node and its descendants, retaining their ids for generation-safe
  ## reuse by a later node allocation.
  let index = tree.nodeIndex(id)
  if index < 0: return false
  var removed: seq[NodeId]
  for node in tree.nodes:
    if tree.focusContains(id, node.id): removed.add(node.id)
  let focusedNode = tree.focused
  if focusedNode != NodeId(0) and tree.focusContains(id, focusedNode):
    let focusedIndex = tree.nodeIndex(focusedNode)
    if focusedIndex >= 0:
      tree.nodes[focusedIndex].focusedState = false
      tree.updateVisualState(focusedIndex)
    tree.focused = NodeId(0)
  let parent = tree.nodes[index].parent
  if parent != NodeId(0):
    let parentIndex = tree.nodeIndex(parent)
    if parentIndex >= 0:
      for childIndex in countdown(tree.nodes[parentIndex].children.high, 0):
        if tree.nodes[parentIndex].children[childIndex] == id:
          tree.nodes[parentIndex].children.delete(childIndex)
          break
  var kept: seq[UiNode]
  for node in tree.nodes:
    var isRemoved = false
    for removedId in removed:
      if node.id == removedId:
        isRemoved = true
        break
    if isRemoved:
      tree.recycledIds.add(node.id)
    else:
      kept.add(node)
  tree.nodes = kept
  tree.index.clear()
  for nodeIndex, node in tree.nodes:
    tree.index[node.id] = nodeIndex
  true

proc markLayoutDirty*(tree: var UiTree, id: NodeId)

proc updateVisualState(tree: var UiTree, index: int) =
  if index < 0 or index >= tree.nodes.len: return
  let node = tree.nodes[index]
  let visual = if node.disabledState: disabled
    elif node.activeState: active
    elif node.focusedState: focused
    elif node.hoveredState: hovered
    else: normal
  if tree.nodes[index].state != visual:
    tree.nodes[index].state = visual
    tree.nodes[index].paintDirty = true

proc setFlexGrow*(tree: var UiTree, id: NodeId, value: float32) =
  let index = tree.nodeIndex(id)
  if index >= 0:
    tree.nodes[index].flexGrow = max(0'f32, value)
    tree.markLayoutDirty(id)

proc setSizeConstraints*(tree: var UiTree, id: NodeId, preferred, minimum, maximum: Size) =
  let index = tree.nodeIndex(id)
  if index >= 0:
    tree.nodes[index].preferredSize = preferred
    tree.nodes[index].minSize = minimum
    tree.nodes[index].maxSize = maximum
    tree.nodes[index].layoutSpec.size = preferred
    tree.nodes[index].layoutSpec.minSize = minimum
    tree.nodes[index].layoutSpec.maxSize = maximum
    tree.markLayoutDirty(id)

proc setLayoutSpec*(tree: var UiTree, id: NodeId, spec: LayoutSpec) =
  let index = tree.nodeIndex(id)
  if index >= 0:
    let normalized = normalizeLayoutSpec(spec)
    tree.nodes[index].layoutSpec = normalized
    tree.nodes[index].preferredSize = normalized.size
    tree.nodes[index].minSize = normalized.minSize
    tree.nodes[index].maxSize = normalized.maxSize
    tree.markLayoutDirty(id)

proc setA11yInfo*(tree: var UiTree, id: NodeId, role: A11yRole,
                  identifier, title, value: string, action = "") =
  let index = tree.nodeIndex(id)
  if index >= 0:
    tree.nodes[index].a11yRole = role
    tree.nodes[index].a11yIdentifier = identifier
    tree.nodes[index].a11yTitle = title
    tree.nodes[index].a11yValue = value
    tree.nodes[index].a11yAction = action

proc setA11yState*(tree: var UiTree, id: NodeId, selected, expanded: bool) =
  let index = tree.nodeIndex(id)
  if index >= 0:
    tree.nodes[index].a11ySelected = selected
    tree.nodes[index].a11yExpanded = expanded

proc hitTest*(tree: UiTree, point: Point): NodeId =
  ## Return the deepest/topmost node containing a point. A node is eligible
  ## only while every clipping ancestor contains the point. `overflow: visible`
  ## therefore allows an absolute child to receive input outside its parent,
  ## while `overflow: hidden` matches the painting clip.
  for index in countdown(tree.nodes.high, 0):
    if tree.nodes[index].disabledState: continue
    if not tree.nodes[index].bounds.contains(point): continue
    let dispatchPath = tree.dispatchPath(tree.nodes[index].id)
    if dispatchPath.len == 0: continue
    var descendant = tree.nodes[index].id
    var visible = true
    if dispatchPath.len > 1:
      for pathIndex in countdown(dispatchPath.high - 1, 0):
        let ancestorIndex = tree.nodeIndex(dispatchPath[pathIndex])
        if ancestorIndex < 0 or tree.nodes[ancestorIndex].disabledState:
          visible = false
          break
        let ancestor = tree.nodes[ancestorIndex]
        let descendantIndex = tree.nodeIndex(descendant)
        let descendantIsAbsolute = descendantIndex >= 0 and
          tree.nodes[descendantIndex].layoutSpec.position == absolute
        let useLegacyBounds = not ancestor.clipChildren and not descendantIsAbsolute
        let clip = ancestor.nodeClip()
        if ((useLegacyBounds and not ancestor.bounds.contains(point)) or
            (ancestor.clipChildren and ((ancestor.clipX and
            (float32(point.x) < float32(clip.origin.x) or
             float32(point.x) >= float32(clip.origin.x + clip.size.width))) or
             (ancestor.clipY and
            (float32(point.y) < float32(clip.origin.y) or
             float32(point.y) >= float32(clip.origin.y + clip.size.height)))))):
          visible = false
          break
        descendant = dispatchPath[pathIndex]
    if visible: return tree.nodes[index].id
  NodeId(0)

proc handle*(tree: UiTree, id: NodeId): NodeHandle =
  let index = tree.nodeIndex(id)
  if index >= 0:
    NodeHandle(id: id, generation: tree.nodes[index].generation,
               tabIndex: tree.nodes[index].tabIndex,
               tabStop: tree.nodes[index].tabStop)
  else:
    NodeHandle(id: NodeId(0), generation: 0, tabStop: true)

proc isValid*(tree: UiTree, handle: NodeHandle): bool =
  let index = tree.nodeIndex(handle.id)
  index >= 0 and tree.nodes[index].generation == handle.generation

proc node*(tree: var UiTree, id: NodeId): var UiNode =
  tree.nodes[nodeIndex(tree, id)]

proc nodeClip*(node: UiNode): Rect =
  ## The single clip value consumed by prepaint and hit testing. Layout keeps
  ## this as the inherited/own content mask intersection; intersecting once
  ## more with bounds makes the invariant explicit for callers that paint a
  ## node directly.
  let left = max(float32(node.clipBounds.origin.x), float32(node.bounds.origin.x))
  let top = max(float32(node.clipBounds.origin.y), float32(node.bounds.origin.y))
  let right = min(float32(node.clipBounds.origin.x + node.clipBounds.size.width),
    float32(node.bounds.origin.x + node.bounds.size.width))
  let bottom = min(float32(node.clipBounds.origin.y + node.clipBounds.size.height),
    float32(node.bounds.origin.y + node.bounds.size.height))
  Rect(origin: Point(x: px(left), y: px(top)),
    size: Size(width: px(max(0'f32, right - left)),
      height: px(max(0'f32, bottom - top))))

proc markLayoutDirty*(tree: var UiTree, id: NodeId) =
  let index = nodeIndex(tree, id)
  if index < 0: return
  tree.nodes[index].layoutDirty = true
  tree.nodes[index].paintDirty = true
  let parent = tree.nodes[index].parent
  if parent != NodeId(0): tree.markLayoutDirty(parent)

proc markPaintClean*(tree: var UiTree, id: NodeId) =
  let index = nodeIndex(tree, id)
  if index >= 0: tree.nodes[index].paintDirty = false

proc setState*(tree: var UiTree, id: NodeId, state: UiState) =
  let index = nodeIndex(tree, id)
  if index >= 0:
    # Preserve the legacy single-state API while keeping the underlying
    # interaction flags independent for native event routing.
    tree.nodes[index].focusedState = state == focused
    tree.nodes[index].hoveredState = state == hovered
    tree.nodes[index].activeState = state == active
    tree.nodes[index].disabledState = state == disabled
    tree.updateVisualState(index)

proc setHovered*(tree: var UiTree, id: NodeId, value: bool) =
  let index = nodeIndex(tree, id)
  if index >= 0:
    tree.nodes[index].hoveredState = value
    tree.updateVisualState(index)

proc setActive*(tree: var UiTree, id: NodeId, value: bool) =
  let index = nodeIndex(tree, id)
  if index >= 0:
    tree.nodes[index].activeState = value
    tree.updateVisualState(index)

proc setDisabled*(tree: var UiTree, id: NodeId, value: bool) =
  let index = nodeIndex(tree, id)
  if index >= 0:
    tree.nodes[index].disabledState = value
    tree.updateVisualState(index)
    if value and tree.focused != NodeId(0):
      # Disabling a focused node, or one of its ancestors, invalidates the
      # current focus path. Keep the focus owner and visual flags in sync so
      # keyboard routing cannot continue targeting disabled UI.
      if tree.focusContains(id, tree.focused):
        let focusedIndex = nodeIndex(tree, tree.focused)
        if focusedIndex >= 0:
          tree.nodes[focusedIndex].focusedState = false
          tree.updateVisualState(focusedIndex)
        tree.focused = NodeId(0)

proc isDisabledPath*(tree: UiTree, id: NodeId): bool =
  ## A node is not focusable while any node on its focus path is disabled.
  for ancestor in tree.dispatchPath(id):
    let index = tree.nodeIndex(ancestor)
    if tree.nodes[index].disabledState: return true
  false

proc focus*(tree: var UiTree, id: NodeId): bool =
  let index = nodeIndex(tree, id)
  if index < 0 or not tree.nodes[index].focusable or tree.isDisabledPath(id): return false
  if tree.focused != NodeId(0):
    let oldIndex = nodeIndex(tree, tree.focused)
    if oldIndex >= 0:
      tree.nodes[oldIndex].focusedState = false
      tree.updateVisualState(oldIndex)
  tree.focused = id
  tree.nodes[index].focusedState = true
  tree.updateVisualState(index)
  true

proc focus*(tree: var UiTree, handle: NodeHandle): bool =
  if not tree.isValid(handle): return false
  let index = tree.nodeIndex(handle.id)
  tree.nodes[index].tabIndex = handle.tabIndex
  tree.nodes[index].tabStop = handle.tabStop
  tree.focus(handle.id)

proc setContext*(tree: var UiTree, id: NodeId, context: KeyContext) =
  let index = tree.nodeIndex(id)
  if index >= 0: tree.nodes[index].context = context

proc contextStack*(tree: UiTree, nodeIndexLookups: var int): seq[KeyContext] =
  ## Collect the focused node's dispatch path, then expose it in Zed's
  ## root-to-focused order so Descendant predicates see parent before child.
  ## The lookup counter is used by tests to assert that this remains an
  ## indexed walk rather than a scan through all nodes for every parent.
  var path: seq[NodeId]
  var current = tree.focused
  while current != NodeId(0):
    inc nodeIndexLookups
    let index = tree.nodeIndex(current)
    if index < 0: return @[]
    path.add(current)
    current = tree.nodes[index].parent
  path.reverse()
  for id in path:
    inc nodeIndexLookups
    let index = tree.nodeIndex(id)
    if tree.nodes[index].context.entries.len > 0:
      result.add(tree.nodes[index].context)

proc contextStack*(tree: UiTree): seq[KeyContext] =
  var ignoredLookups = 0
  tree.contextStack(ignoredLookups)

proc dispatchPath*(tree: UiTree, target: NodeId): seq[NodeId] =
  ## Return the target's parent chain in root-to-target order.
  var current = target
  while current != NodeId(0):
    let index = tree.nodeIndex(current)
    if index < 0: return @[]
    result.add(current)
    current = tree.nodes[index].parent
  result.reverse()

proc focusContains*(tree: UiTree, parent, child: NodeId): bool =
  ## Return whether parent is the focused-path ancestor of child.
  if parent == child: return true
  for id in tree.dispatchPath(child):
    if id == parent: return true
  false
