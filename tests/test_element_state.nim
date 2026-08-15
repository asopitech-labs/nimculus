import std/unittest
import std/tables
import std/strutils
import nimnui/geometry
import nimnui/ui_tree
import nimnui/window

proc beginStateFrame(window: var Window) =
  window.beginFrame(Rect())

suite "per-element retained state":
  test "the same global element keeps state for 100 frames":
    var window = newWindow()
    for frame in 0 ..< 100:
      window.beginStateFrame()
      if frame == 0:
        window.useKeyedState("counter", 0) = 42
      check window.useKeyedState("counter", 0) == 42
      window.finishFrame()
    check len(window.renderedFrame.elementStates) == 1

  test "an unvisited element is collected on the next frame":
    var window = newWindow()
    window.beginStateFrame()
    discard window.useKeyedState("gone", 7)
    window.finishFrame()
    check len(window.renderedFrame.elementStates) == 1

    window.beginStateFrame()
    window.finishFrame()
    check len(window.renderedFrame.elementStates) == 0

  test "the same local id in two namespaces has two entries":
    var window = newWindow()
    window.beginStateFrame()
    window.withElementNamespace("left", proc() =
      discard window.useKeyedState("local", 1))
    window.withElementNamespace("right", proc() =
      discard window.useKeyedState("local", 2))
    window.finishFrame()
    check len(window.renderedFrame.elementStates) == 2

  test "useState uses call sites, not loop iterations, as its key":
    var window = newWindow()
    window.beginStateFrame()
    check window.useState(0) == 0
    check window.useState(0) == 0
    for _ in 0 ..< 10:
      window.useState(0) += 1
    window.finishFrame()
    check len(window.renderedFrame.elementStates) == 3

  test "a second state type for one key is rejected":
    var window = newWindow()
    window.beginStateFrame()
    discard window.useKeyedState("typed", 1)
    var rejected = false
    try:
      discard window.useKeyedState("typed", "wrong type")
    except Defect:
      rejected = true
    check rejected
    window.finishFrame()
    check rejected

  test "reentrant access to one element state is a Defect":
    var window = newWindow()
    window.beginStateFrame()
    var reentrant: proc() {.closure.}
    reentrant = proc() =
      window.withElementState("same", 0, proc(state: var int) =
        discard state)
    var raised: ref Defect
    try:
      window.withElementState("same", 0, proc(state: var int) =
        discard state
        reentrant())
    except Defect as error:
      raised = error
    check raised != nil
    check "re-entrancy" in raised.msg
    window.finishFrame()
