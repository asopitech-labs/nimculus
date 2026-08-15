import std/unittest
import std/options
import std/tables
import nimnui/geometry
import nimnui/render
import nimnui/window

proc viewport(): Rect =
  Rect(size: Size(width: px(100), height: px(100)))

suite "Double-buffered frames and element-state carryover":
  test "unaccessed element state is collected and later access gets a default":
    var window = newWindow()

    window.beginFrame(viewport())
    window.accessElementState("editor.scroll",
      ElementState(offset: px(0))).offset = px(40)
    window.finishFrame()
    window.swapFrames()
    window.nextFrame.clear()

    window.beginFrame(viewport())
    check len(window.renderedFrame.elementStates) == 1
    let carried = window.accessElementState("editor.scroll",
      ElementState(offset: px(0)))
    check carried.offset == px(40)
    window.finishFrame()
    window.swapFrames()
    window.nextFrame.clear()

    window.beginFrame(viewport())
    window.finishFrame()
    check len(window.renderedFrame.elementStates) == 0
    check window.renderedFrame.lookupElementState("editor.scroll").isNone
    window.swapFrames()
    window.nextFrame.clear()

    window.beginFrame(viewport())
    let fresh = window.accessElementState("editor.scroll",
      ElementState(offset: px(0)))
    check fresh.offset == px(0)

  test "swapping preserves finished commands and clears the next frame":
    var renderedFrame = newFrame()
    var nextFrame = newFrame()
    nextFrame.invalidate(viewport())
    nextFrame.drawRectangle(Rect(origin: Point(x: px(10), y: px(10)),
      size: Size(width: px(20), height: px(20))))
    let emitted = nextFrame.commands.len
    nextFrame.finishFrame(renderedFrame)

    swap(renderedFrame, nextFrame)
    nextFrame.clear()
    check nextFrame.commands.len == 0
    check renderedFrame.commands.len == emitted

  test "a small dirty region emits fewer commands than full viewport damage":
    proc emitCount(dirty: Rect): int =
      var frame = newFrame()
      frame.invalidate(dirty)
      frame.drawRectangle(Rect(origin: Point(x: px(0), y: px(0)),
        size: Size(width: px(20), height: px(20))))
      frame.drawRectangle(Rect(origin: Point(x: px(80), y: px(80)),
        size: Size(width: px(20), height: px(20))))
      frame.commands.len

    let small = emitCount(Rect(size: Size(width: px(25), height: px(25))))
    let full = emitCount(viewport())
    check small < full
