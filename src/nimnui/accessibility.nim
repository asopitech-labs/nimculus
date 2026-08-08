import nimnui/geometry
import nimnui/platform/contracts
import nimnui/ui_tree

type
  AccessibilityNode* = object
    id*, parentId*: uint64
    role*: A11yRole
    identifier*, title*, value*, actionCommand*: string
    bounds*: Rect
    children*: seq[uint64]
    synthetic*: bool
    textStartByte*, textEndByte*, cursorByte*: uint32
    selectionStartByte*, selectionEndByte*: uint32
    selected*, expanded*: bool

  AccessibilityTree* = object
    rootId*: uint64
    nodes*: seq[AccessibilityNode]

  AccessibilityBuilder* = object
    tree*: AccessibilityTree

const AccessibilityRootId* = 0x6e696d63756c7573'u64

proc nodeIndex(tree: AccessibilityTree, id: uint64): int =
  for index, node in tree.nodes:
    if node.id == id: return index
  -1

proc roleForNative*(role: A11yRole): uint32 =
  ord(role).uint32

proc initAccessibilityBuilder*(tree: AccessibilityTree): AccessibilityBuilder =
  result.tree = tree

proc addSyntheticChild*(builder: var AccessibilityBuilder, parentId, key: uint64,
                        value: string, startByte, endByte: uint32): uint64 =
  var id = parentId xor (key * 0x9e3779b97f4a7c15'u64)
  id = (id xor (id shr 30)) * 0xbf58476d1ce4e5b9'u64
  id = (id xor (id shr 27)) * 0x94d049bb133111eb'u64
  id = id xor (id shr 31)
  if id == 0: id = 1
  let parentIndex = builder.tree.nodeIndex(parentId)
  if parentIndex < 0: return 0
  builder.tree.nodes.add(AccessibilityNode(
    id: id, parentId: parentId, role: a11yTextRun, value: value,
    textEndByte: endByte, textStartByte: startByte, synthetic: true))
  builder.tree.nodes[parentIndex].children.add(id)
  id

proc parentAccessibilityId(uiTree: UiTree, node: UiNode,
                           idsByNode: seq[tuple[nodeId: NodeId, a11yId: uint64]]): uint64 =
  var parent = node.parent
  while parent != NodeId(0):
    for item in idsByNode:
      if item.nodeId == parent: return item.a11yId
    let parentIndex = uiTree.nodeIndex(parent)
    if parentIndex < 0: break
    parent = uiTree.nodes[parentIndex].parent
  AccessibilityRootId

proc buildAccessibilityTree*(uiTree: UiTree, editorText: string, cursorByte,
                             selectionStartByte, selectionEndByte: uint32): AccessibilityTree =
  result.rootId = AccessibilityRootId
  result.nodes.add(AccessibilityNode(id: result.rootId, role: a11yWindow,
    identifier: "window", title: "Nimculus"))
  var idsByNode: seq[tuple[nodeId: NodeId, a11yId: uint64]]
  for node in uiTree.nodes:
    if node.a11yRole == a11yNone or node.a11yIdentifier.len == 0: continue
    let a11yId = node.a11yNodeId
    idsByNode.add((node.id, a11yId))
    result.nodes.add(AccessibilityNode(
      id: a11yId, parentId: uiTree.parentAccessibilityId(node, idsByNode),
      role: node.a11yRole, identifier: node.a11yIdentifier,
      title: node.a11yTitle, value: node.a11yValue,
      actionCommand: node.a11yAction, bounds: node.bounds,
      selected: node.a11ySelected, expanded: node.a11yExpanded))
  for index in 1 ..< result.nodes.len:
    let parentIndex = result.nodeIndex(result.nodes[index].parentId)
    if parentIndex >= 0: result.nodes[parentIndex].children.add(result.nodes[index].id)
  var builder = initAccessibilityBuilder(result)
  for node in builder.tree.nodes:
    if node.identifier == "editor.content":
      let editorIndex = builder.tree.nodeIndex(node.id)
      if editorIndex >= 0:
        builder.tree.nodes[editorIndex].value = editorText
        builder.tree.nodes[editorIndex].textEndByte = uint32(editorText.len)
        builder.tree.nodes[editorIndex].cursorByte = cursorByte
        builder.tree.nodes[editorIndex].selectionStartByte = selectionStartByte
        builder.tree.nodes[editorIndex].selectionEndByte = selectionEndByte
        discard builder.addSyntheticChild(node.id, 0, editorText, 0, uint32(editorText.len))
      break
  result = builder.tree

proc toNativeAccessibility*(tree: AccessibilityTree): tuple[
    nodes: seq[NativeAccessibilityNode], children: seq[uint64]] =
  for node in tree.nodes:
    let firstChild = uint32(result.children.len)
    for child in node.children: result.children.add(child)
    var native = NativeAccessibilityNode(
      id: node.id, parentId: node.parentId, role: roleForNative(node.role),
      childStart: firstChild, childCount: uint32(node.children.len),
      x: cfloat(node.bounds.origin.x), y: cfloat(node.bounds.origin.y),
      width: cfloat(node.bounds.size.width), height: cfloat(node.bounds.size.height),
      textStartByte: node.textStartByte, textEndByte: node.textEndByte,
      cursorByte: node.cursorByte, selectionStartByte: node.selectionStartByte,
      selectionEndByte: node.selectionEndByte,
      flags: (if node.synthetic: 1'u32 else: 0'u32) or
        (if node.selected: 2'u32 else: 0'u32) or
        (if node.expanded: 4'u32 else: 0'u32),
      identifier: node.identifier.cstring, title: node.title.cstring,
      value: node.value.cstring, actionCommand: node.actionCommand.cstring)
    result.nodes.add(native)
