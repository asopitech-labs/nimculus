import std/unittest
import nimnui/geometry
import nimnui/ui_tree
import nimnui/window

const treeKinds = ["single-file", "folder", "git-repo"]

proc hitRect(): Rect = Rect(size: Size(width: px(100), height: px(40)))

proc fixtureNodes(treeKind: string): tuple[tree: UiTree, back, front: NodeId] =
  result.tree = newUiTree()
  let root = result.tree.addNode()
  case treeKind
  of "single-file":
    result.back = result.tree.addNode(root)
    result.front = result.tree.addNode(root)
  of "folder":
    let folder = result.tree.addNode(root)
    result.back = result.tree.addNode(folder)
    result.front = result.tree.addNode(folder)
  of "git-repo":
    let repository = result.tree.addNode(root)
    let sidebarRows = result.tree.addNode(repository)
    result.back = result.tree.addNode(sidebarRows)
    result.front = result.tree.addNode(sidebarRows)
  else:
    doAssert false, "unknown fixture"

proc recordedFixture(treeKind: string, behavior: HitboxBehavior):
    tuple[window: Window, back, front: NodeId] =
  let nodes = fixtureNodes(treeKind)
  result.back = nodes.back
  result.front = nodes.front
  result.window = newWindow()
  result.window.beginDraw()
  result.window.insertHitbox(result.back, hitRect())
  result.window.insertHitbox(result.front, hitRect(), behavior)

suite "Window hitbox blocking behaviors":
  test "BlockMouse removes the sibling behind it for every tree shape":
    for treeKind in treeKinds:
      let fixture = recordedFixture(treeKind, hitboxBlockMouse)
      let result = fixture.window.hitTest(Point(x: px(10), y: px(10)))
      check result.ids == @[fixture.front]
      check result.topmost == fixture.front

  test "BlockMouseExceptScroll splits hover and scroll stacks":
    for treeKind in treeKinds:
      let fixture = recordedFixture(treeKind, hitboxBlockMouseExceptScroll)
      let hover = fixture.window.hitTest(Point(x: px(10), y: px(10)), hoverHitTest)
      let scroll = fixture.window.hitTest(Point(x: px(10), y: px(10)), scrollHitTest)
      check hover.ids == @[fixture.front]
      check scroll.ids == @[fixture.front, fixture.back]
      check hover.hoverHitboxCount == 1

  test "hit testing 200 clipped siblings does not call nodeIndex":
    var tree = newUiTree()
    let root = tree.addNode()
    tree.node(root).bounds = hitRect()
    tree.node(root).clipBounds = hitRect()
    tree.node(root).clipChildren = true
    tree.node(root).clipX = true
    tree.node(root).clipY = true
    for _ in 0 ..< 200:
      let sibling = tree.addNode(root)
      tree.node(sibling).bounds = hitRect()
    when defined(debug):
      resetNodeIndexCallCount()
    let result = tree.hitTest(Point(x: px(10), y: px(10)))
    check result.topmost != NodeId(0)
    when defined(debug):
      check nodeIndexCallCount == 0
