import std/unittest
import std/unicode
import nimnui/nimnui

suite "M2 UI foundation":
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
