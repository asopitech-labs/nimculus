import std/[options, times, unittest]
import nimnui/ui_tree
import nimnui/window

suite "Frame dirty timing and presentation":
  test "coalesced invalidations emit first dirty timestamp and count":
    var window = newWindow()
    let firstDirtyAt = epochTime()
    window.markLayoutDirty(NodeId(1))
    window.markLayoutDirty(NodeId(1))
    window.markLayoutDirty(NodeId(2))

    window.draw(nil, nil, nil)
    check window.lastFrameTiming.isSome
    let timing = window.lastFrameTiming.get
    check timing.invalidations == 3
    check timing.dirtyAt.isSome
    check abs(timing.dirtyAt.get - firstDirtyAt) * 1000.0 <= 1.0

    window.draw(nil, nil, nil)
    check window.lastFrameTiming.isSome
    let cleanTiming = window.lastFrameTiming.get
    check cleanTiming.invalidations == 0
    check cleanTiming.dirtyAt.isNone

  test "repeated paint publication presents once until the next draw":
    var window = newWindow()
    check window.publishPaint()
    check window.needsPresent
    check not window.publishPaint()
    check window.needsPresent
    check window.presentIfNeeded()
    check not window.needsPresent
    check window.presentCount == 1'u64
    check not window.presentIfNeeded()
