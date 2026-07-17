type
  MockDrawCommand* = object
    x*, y*, width*, height*: float32

  MockRenderer* = object
    commands*: seq[MockDrawCommand]

proc clear*(renderer: var MockRenderer) =
  renderer.commands.setLen(0)

proc drawRectangle*(renderer: var MockRenderer, x, y, width, height: float32) =
  renderer.commands.add(MockDrawCommand(x: x, y: y, width: width, height: height))
