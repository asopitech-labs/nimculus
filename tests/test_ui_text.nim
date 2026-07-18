import std/unittest
import std/unicode
import nimnui/nimnui

suite "M2 UI foundation":
  test "command registry resolves exact macOS-style modifiers":
    var registry: CommandRegistry
    var invoked = false
    registry.register(Command(name: "save",
      shortcut: Shortcut(keyCode: 1, modifiers: {commandModifier, shiftModifier}),
      action: proc() = invoked = true))
    var resolved: Command
    check registry.tryResolve(Shortcut(keyCode: 1,
      modifiers: {commandModifier, shiftModifier}), resolved)
    check resolved.name == "save"
    check registry.dispatchShortcut(Shortcut(keyCode: 1,
      modifiers: {commandModifier, shiftModifier}))
    check invoked
    check not registry.dispatchShortcut(Shortcut(keyCode: 2,
      modifiers: {commandModifier}))

  test "row layout distributes children and preserves parent":
    var tree = newUiTree()
    let root = tree.addNode()
    let first = tree.addNode(root, focusable = true)
    let second = tree.addNode(root, focusable = true)
    let spec = LayoutSpec(direction: row, size: Size(width: px(0), height: px(0)),
      minSize: Size(width: px(0), height: px(0)),
      maxSize: Size(width: px(10000), height: px(10000)), gap: px(4))
    tree.layoutNode(root, Rect(origin: Point(x: px(0), y: px(0)),
      size: Size(width: px(100), height: px(20))), spec)
    check float32(tree.node(first).bounds.size.width) == 48.0
    check float32(tree.node(second).bounds.origin.x) == 52.0

  test "flex grow and child size constraints affect layout":
    var tree = newUiTree()
    let root = tree.addNode()
    let first = tree.addNode(root)
    let second = tree.addNode(root)
    tree.setFlexGrow(first, 1.0)
    tree.setFlexGrow(second, 2.0)
    tree.setSizeConstraints(first, Size(width: px(0), height: px(0)),
      Size(width: px(0), height: px(0)), Size(width: px(1000), height: px(1000)))
    tree.setSizeConstraints(second, Size(width: px(0), height: px(0)),
      Size(width: px(0), height: px(0)), Size(width: px(1000), height: px(1000)))
    let spec = LayoutSpec(direction: row, maxSize: Size(width: px(10000), height: px(10000)))
    tree.layoutNode(root, Rect(size: Size(width: px(90), height: px(20))), spec)
    check float32(tree.node(first).bounds.size.width) == 30.0
    check float32(tree.node(second).bounds.size.width) == 60.0

  test "focus and dirty state are explicit":
    var tree = newUiTree()
    let root = tree.addNode()
    let button = tree.addNode(root, focusable = true)
    check tree.focus(button)
    check tree.node(button).state == focused
    tree.markPaintClean(button)
    check not tree.node(button).paintDirty
    tree.markLayoutDirty(button)
    check tree.node(button).paintDirty

  test "node handles carry a generation":
    var tree = newUiTree()
    let node = tree.addNode()
    let handle = tree.handle(node)
    check handle.generation > 0
    check tree.isValid(handle)
    check not tree.isValid(NodeHandle(id: node, generation: handle.generation + 1))

  test "hit testing selects the topmost node":
    var tree = newUiTree()
    let root = tree.addNode()
    let back = tree.addNode(root)
    let front = tree.addNode(root)
    tree.node(root).bounds = Rect(size: Size(width: px(100), height: px(100)))
    tree.node(back).bounds = Rect(size: Size(width: px(60), height: px(60)))
    tree.node(front).bounds = Rect(size: Size(width: px(60), height: px(60)))
    check tree.hitTest(Point(x: px(20), y: px(20))) == front
    check tree.hitTest(Point(x: px(90), y: px(90))) == root

  test "focus traversal reaches the next focusable node":
    var tree = newUiTree()
    let first = tree.addNode(focusable = true)
    let second = tree.addNode(focusable = true)
    discard tree.focus(first)
    check tree.focusNext() == second

  test "event dispatch follows capture target bubble":
    var tree = newUiTree()
    let root = tree.addNode()
    let child = tree.addNode(root)
    var event = UiEvent(kind: pointerDown, target: child)
    let phases = tree.dispatch(event)
    check phases == @[capture, capture, target, bubble, bubble]

suite "M3 text foundation":
  test "positions handle UTF-8 and combining marks":
    let positions = textPositions("Aé e\u0301")
    check positions[0].byteOffset == 0
    check positions[^1].byteOffset == 7
    check positions[^1].graphemeIndex == 4

  test "positions keep combining sequences and emoji joiners together":
    let positions = textPositions("e\u0301\u0323👩\u200D💻")
    check positions.len == 3
    check positions[^1].graphemeIndex == 2

  test "positions pair regional indicators and keep CRLF together":
    let flagPositions = textPositions("🇯🇵🇺🇸")
    check flagPositions[^1].graphemeIndex == 2
    let newlinePositions = textPositions("a\r\nb")
    check newlinePositions[^1].graphemeIndex == 3

  test "glyph atlas reuses glyphs":
    var atlas = newGlyphAtlas(64, 64)
    let first = atlas.insertGlyph(Rune(65), 8, 12)
    let second = atlas.insertGlyph(Rune(65), 8, 12)
    check atlas.glyphs.len == 1
    check first.atlasX == second.atlasX

  test "paint list emits only commands intersecting dirty regions":
    var paint: PaintList
    paint.invalidate(Rect(origin: Point(x: px(0), y: px(0)), size: Size(width: px(10), height: px(10))))
    paint.drawRectangle(Rect(origin: Point(x: px(2), y: px(2)), size: Size(width: px(4), height: px(4))))
    paint.drawRectangle(Rect(origin: Point(x: px(20), y: px(20)), size: Size(width: px(4), height: px(4))))
    check paint.commands.len == 1

  test "paint list applies nested clip regions":
    var paint: PaintList
    paint.invalidate(Rect(size: Size(width: px(100), height: px(100))))
    paint.pushClip(Rect(size: Size(width: px(20), height: px(20))))
    paint.pushClip(Rect(origin: Point(x: px(10), y: px(10)),
      size: Size(width: px(40), height: px(40))))
    paint.drawRectangle(Rect(size: Size(width: px(80), height: px(80))))
    check paint.commands.len == 3
    check float32(paint.commands[^1].clip.size.width) == 10.0
    paint.popClip()
    paint.popClip()
    paint.drawRectangle(Rect(origin: Point(x: px(40), y: px(40)),
      size: Size(width: px(10), height: px(10))))
    check paint.commands.len == 4

  test "paint list applies affine transforms before dirty filtering":
    var paint: PaintList
    paint.invalidate(Rect(size: Size(width: px(100), height: px(100))))
    paint.pushTransform(translationTransform(px(10), px(12)))
    paint.drawText(Rect(size: Size(width: px(20), height: px(10))), "placeholder")
    paint.drawImage(Rect(origin: Point(x: px(20), y: px(20)),
      size: Size(width: px(10), height: px(10))))
    paint.popTransform()
    check paint.commands.len == 2
    check float32(paint.commands[0].bounds.origin.x) == 10.0
    check float32(paint.commands[0].bounds.origin.y) == 12.0

  test "scroll and split models clamp interaction":
    var scroll = ScrollModel(contentSize: px(100), viewportSize: px(30))
    scroll.scrollBy(px(80))
    check scroll.offset == px(70)
    var split = SplitPaneModel(ratio: 0.5)
    split.beginDrag()
    split.dragTo(0.8)
    split.endDrag()
    check abs(split.ratio - 0.8'f32) < 0.001'f32

  test "IME state separates composition from committed text":
    var ime = newImeState()
    ime.receiveText("にほ", true)
    check ime.composition == "にほ"
    ime.receiveText("日本", false)
    check ime.composition.len == 0
    check ime.committed == "日本"

  test "visible text layout limits work to the requested range":
    let visible = layoutVisibleText("0123456789", 2, 5)
    check visible.glyphs.len == 3

when defined(macosx):
  suite "M3 Core Text bridge":
    test "Core Text measures a system font":
      var metrics: NativeTextMetrics
      nativeMeasureText("日本語", "Hiragino Sans", 14, addr metrics)
      check metrics.width > 0
      check metrics.ascent > 0
      check metrics.glyphCount > 0
