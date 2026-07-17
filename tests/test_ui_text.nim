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

  test "glyph atlas reuses glyphs":
    var atlas = newGlyphAtlas(64, 64)
    let first = atlas.insertGlyph(Rune(65), 8, 12)
    let second = atlas.insertGlyph(Rune(65), 8, 12)
    check atlas.glyphs.len == 1
    check first.atlasX == second.atlasX
