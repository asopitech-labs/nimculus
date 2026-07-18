import nimnui/geometry

type
  NodeId* = distinct uint64

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

  UiTree* = object
    nodes*: seq[UiNode]
    nextId*: uint64
    focused*: NodeId

proc `==`*(a, b: NodeId): bool = uint64(a) == uint64(b)

proc newUiTree*(): UiTree = UiTree(nextId: 1, focused: NodeId(0))

proc addNode*(tree: var UiTree, parent: NodeId = NodeId(0), focusable = false): NodeId =
  let id = NodeId(tree.nextId)
  inc tree.nextId
  tree.nodes.add(UiNode(id: id, parent: parent, state: normal,
                        layoutDirty: true, paintDirty: true, focusable: focusable))
  if parent != NodeId(0):
    for node in tree.nodes.mitems:
      if node.id == parent:
        node.children.add(id)
        node.layoutDirty = true
        node.paintDirty = true
        break
  id

proc nodeIndex(tree: UiTree, id: NodeId): int =
  for index, node in tree.nodes:
    if node.id == id: return index
  -1

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
    tree.nodes[index].state = state
    tree.nodes[index].paintDirty = true

proc focus*(tree: var UiTree, id: NodeId): bool =
  let index = nodeIndex(tree, id)
  if index < 0 or not tree.nodes[index].focusable: return false
  if tree.focused != NodeId(0):
    let oldIndex = nodeIndex(tree, tree.focused)
    if oldIndex >= 0: tree.nodes[oldIndex].state = normal
  tree.focused = id
  tree.nodes[index].state = focused
  tree.nodes[index].paintDirty = true
  true
