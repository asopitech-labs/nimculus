import nimnui/geometry
import nimnui/layout_types

type
  NodeId* = distinct uint64
  NodeHandle* = object
    id*: NodeId
    generation*: uint32

  UiState* = enum
    normal, focused, hovered, active, disabled

  UiNode* = object
    id*: NodeId
    parent*: NodeId
    children*: seq[NodeId]
    bounds*: Rect
    state*: UiState
    layoutDirty*: bool
    paintDirty*: bool
    focusable*: bool
    generation*: uint32
    focusedState*, hoveredState*, activeState*, disabledState*: bool
    flexGrow*: float32
    preferredSize*, minSize*, maxSize*: Size
    layoutSpec*: LayoutSpec

  UiTree* = object
    nodes*: seq[UiNode]
    nextId*: uint64
    focused*: NodeId
    nextGeneration*: uint32

proc `==`*(a, b: NodeId): bool = uint64(a) == uint64(b)

proc newUiTree*(): UiTree = UiTree(nextId: 1, nextGeneration: 1, focused: NodeId(0))

proc nodeIndex*(tree: UiTree, id: NodeId): int =
  for index, node in tree.nodes:
    if node.id == id: return index
  -1

proc addNode*(tree: var UiTree, parent: NodeId = NodeId(0), focusable = false): NodeId =
  let id = NodeId(tree.nextId)
  inc tree.nextId
  let generation = tree.nextGeneration
  inc tree.nextGeneration
  tree.nodes.add(UiNode(id: id, parent: parent, state: normal,
                        layoutDirty: true, paintDirty: true, focusable: focusable,
                        generation: generation,
                        maxSize: Size(width: px(100000), height: px(100000)),
                        layoutSpec: defaultLayoutSpec()))
  if parent != NodeId(0):
    for node in tree.nodes.mitems:
      if node.id == parent:
        node.children.add(id)
        node.layoutDirty = true
        node.paintDirty = true
        break
  id

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
    tree.nodes[index].layoutSpec = spec
    if float32(spec.size.width) > 0: tree.nodes[index].preferredSize.width = spec.size.width
    if float32(spec.size.height) > 0: tree.nodes[index].preferredSize.height = spec.size.height
    if float32(spec.minSize.width) > 0: tree.nodes[index].minSize.width = spec.minSize.width
    if float32(spec.minSize.height) > 0: tree.nodes[index].minSize.height = spec.minSize.height
    if float32(spec.maxSize.width) > 0: tree.nodes[index].maxSize.width = spec.maxSize.width
    if float32(spec.maxSize.height) > 0: tree.nodes[index].maxSize.height = spec.maxSize.height
    tree.markLayoutDirty(id)

proc hitTest*(tree: UiTree, point: Point): NodeId =
  ## Return the deepest/topmost node containing a point. A node is eligible
  ## only while every ancestor contains the point, matching viewport clipping
  ## for both painting and pointer routing.
  for index in countdown(tree.nodes.high, 0):
    if tree.nodes[index].disabledState: continue
    if not tree.nodes[index].bounds.contains(point): continue
    var current = tree.nodes[index].parent
    var visible = true
    while current != NodeId(0):
      let ancestorIndex = tree.nodeIndex(current)
      if ancestorIndex < 0 or tree.nodes[ancestorIndex].disabledState or
          not tree.nodes[ancestorIndex].bounds.contains(point):
        visible = false
        break
      current = tree.nodes[ancestorIndex].parent
    if visible: return tree.nodes[index].id
  NodeId(0)

proc handle*(tree: UiTree, id: NodeId): NodeHandle =
  let index = tree.nodeIndex(id)
  if index >= 0: NodeHandle(id: id, generation: tree.nodes[index].generation)
  else: NodeHandle(id: NodeId(0), generation: 0)

proc isValid*(tree: UiTree, handle: NodeHandle): bool =
  let index = tree.nodeIndex(handle.id)
  index >= 0 and tree.nodes[index].generation == handle.generation

proc node*(tree: var UiTree, id: NodeId): var UiNode =
  tree.nodes[nodeIndex(tree, id)]

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
      var current = tree.focused
      var focusMustClear = false
      while current != NodeId(0):
        if current == id:
          focusMustClear = true
          break
        let currentIndex = nodeIndex(tree, current)
        if currentIndex < 0: break
        current = tree.nodes[currentIndex].parent
      if focusMustClear:
        let focusedIndex = nodeIndex(tree, tree.focused)
        if focusedIndex >= 0:
          tree.nodes[focusedIndex].focusedState = false
          tree.updateVisualState(focusedIndex)
        tree.focused = NodeId(0)

proc isDisabledPath*(tree: UiTree, id: NodeId): bool =
  ## A node is not focusable while any node on its focus path is disabled.
  var current = id
  while current != NodeId(0):
    let index = tree.nodeIndex(current)
    if index < 0: return false
    if tree.nodes[index].disabledState: return true
    current = tree.nodes[index].parent
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
