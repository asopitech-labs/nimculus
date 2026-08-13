import std/unittest
import nimnui/geometry
import nimnui/ui_tree
import nimnui/window

suite "WindowInvalidator draw phases":
  test "layout invalidation marks the window and its view while idle":
    var window = newWindow()
    window.clearDirty()
    let node = NodeId(7)

    discard window.markLayoutDirty(node)

    check window.dirty
    check window.dirtyViews.len == 1
    check window.dirtyViews[0] == node

  test "draw-time invalidation does not restart the current frame":
    var window = newWindow()
    window.clearDirty()
    let node = NodeId(8)

    window.setPhase(dpPrepaint)
    discard window.markLayoutDirty(node)
    check not window.dirty
    check window.updateCount == 1

    window.setPhase(dpPaint)
    discard window.markLayoutDirty(node)
    check not window.dirty
    check window.updateCount == 2

  test "one draw visits each phase in order exactly once":
    var window = newWindow()

    window.draw(proc() = discard)

    check window.phaseHistory == @[dpPrepaint, dpPaint, dpFocus, dpNone]

  test "repeated invalidation of one view is coalesced":
    var window = newWindow()
    window.clearDirty()
    let node = NodeId(9)

    for _ in 0 ..< 5:
      discard window.markLayoutDirty(node)

    check window.dirtyViews.len == 1
    check window.updateCount == 5

  test "hitboxes are prepaint-only in debug builds":
    var window = newWindow()
    when defined(debug):
      expect AssertionDefect:
        discard window.insertHitbox(Rect(size: Size(width: px(10), height: px(10))))
    else:
      window.setPhase(dpPrepaint)
      discard window.insertHitbox(Rect(size: Size(width: px(10), height: px(10))))
      check window.hitboxes.len == 1
