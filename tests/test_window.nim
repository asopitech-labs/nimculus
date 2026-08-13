import std/unittest
import std/sets
import nimnui/geometry
import nimnui/ui_tree
import nimnui/window

suite "Window invalidation and draw phases":
  test "layout invalidation records a dirty view in dpNone":
    var window = newWindow()
    var tree = newUiTree()
    let root = tree.addNode()
    let node = tree.addNode(root)
    tree.onLayoutDirty = proc(id: NodeId) = window.markLayoutDirty(id)
    tree.markLayoutDirty(node)
    check window.dirty
    check window.dirtyViews.contains(node)

  test "tree layout invalidation reaches the sidebar view":
    var window = newWindow()
    var tree = newUiTree()
    let root = tree.addNode()
    let sidebar = tree.addNode(root)
    window.registerSidebarView(sidebar)
    tree.onLayoutDirty = proc(id: NodeId) = window.markLayoutDirty(id)
    tree.markLayoutDirty(sidebar)
    check window.sidebarRedrawRequested
    check window.dirtyViews.contains(sidebar)

  test "layout invalidation during prepaint and paint is deferred":
    var window = newWindow()
    window.beginDraw()
    window.markLayoutDirty(NodeId(1))
    check not window.dirty
    check window.updateCount == 1
    window.setPhase(dpPaint)
    window.markLayoutDirty(NodeId(2))
    check not window.dirty
    check window.updateCount == 2
    window.setPhase(dpFocus)
    window.endDraw()

  test "one draw visits every phase once in order":
    var window = newWindow()
    window.draw(nil, nil, nil)
    check window.phaseHistory == @[dpPrepaint, dpPaint, dpFocus, dpNone]

  test "repeated invalidation coalesces dirty views and counts updates":
    var window = newWindow()
    let node = NodeId(11)
    const N = 9
    for _ in 0 ..< N:
      window.markLayoutDirty(node)
    check window.dirtyViews.len == 1
    check window.updateCount == N

  test "insertHitbox is prepaint-only":
    var window = newWindow()
    expect AssertionDefect:
      window.insertHitbox(NodeId(3), Rect(size: Size(width: px(10), height: px(10))))
