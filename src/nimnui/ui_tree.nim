import nimnui/geometry
import nimnui/layout_types

type
  NodeId* = distinct uint64

  A11yRole* = enum
    a11yNone, a11yWindow, a11yGroup, a11yToolbar, a11yButton, a11yTabGroup,
    a11yTab, a11yStatusBar, a11yScrollArea, a11yRow, a11yTextInput, a11yTextRun

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
    clipBounds*: Rect
    clipChildren*: bool
    clipX*, clipY*: bool
    state*: UiState
    layoutDirty*: bool
    paintDirty*: bool
    focusable*: bool
    generation*: uint32
    focusedState*, hoveredState*, activeState*, disabledState*: bool
    flexGrow*: float32
    preferredSize*, minSize*, maxSize*: Size
    layoutSpec*: LayoutSpec
    a11yRole*: A11yRole
    a11yIdentifier*, a11yTitle*, a11yValue*: string
    a11yAction*: string
    a11ySelected*, a11yExpanded*: bool

  UiTree* = object
    nodes*: seq[UiNode]
    nextId*: uint64
    focused*: NodeId
    nextGeneration*: uint32

proc `==`*(a, b: NodeId): bool = uint64(a) == uint64(b)

proc a11yNodeId*(node: UiNode): uint64 =
  var value = uint64(node.id) xor (uint64(node.generation) * 0x9e3779b97f4a7c15'u64)
  value = (value xor (value shr 30)) * 0xbf58476d1ce4e5b9'u64
  value = (value xor (value shr 27)) * 0x94d049bb133111eb'u64
  value xor (value shr 31)

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
    var current = tree.nodes[index].parent
    var descendant = tree.nodes[index].id
    var visible = true
    while current != NodeId(0):
      let ancestorIndex = tree.nodeIndex(current)
      if ancestorIndex < 0 or tree.nodes[ancestorIndex].disabledState:
        visible = false
        break
      let ancestor = tree.nodes[ancestorIndex]
      let descendantIndex = tree.nodeIndex(descendant)
      let descendantIsAbsolute = descendantIndex >= 0 and
        tree.nodes[descendantIndex].layoutSpec.position == absolute
      let useLegacyBounds = not ancestor.clipChildren and not descendantIsAbsolute
      if ((useLegacyBounds and not ancestor.bounds.contains(point)) or
          (ancestor.clipChildren and ((ancestor.clipX and
          (float32(point.x) < float32(ancestor.clipBounds.origin.x) or
           float32(point.x) >= float32(ancestor.clipBounds.origin.x +
               ancestor.clipBounds.size.width))) or
           (ancestor.clipY and
          (float32(point.y) < float32(ancestor.clipBounds.origin.y) or
           float32(point.y) >= float32(ancestor.clipBounds.origin.y +
               ancestor.clipBounds.size.height)))))):
        visible = false
        break
      descendant = current
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
