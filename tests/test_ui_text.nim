import std/unittest
import std/unicode
import nimnui/nimnui
import nimculus/editor_view

suite "M2 UI foundation":
  test "macOS modifier flags map to shortcut modifiers":
    let flags = (1'u32 shl 17) or (1'u32 shl 18) or
      (1'u32 shl 19) or (1'u32 shl 20)
    check macOSModifiers(flags) == {
      commandModifier, optionModifier, controlModifier, shiftModifier}
    check macOSModifiers(1'u32 shl 16) == {}
    let event = UiEvent(kind: keyDown, shortcutModifiers: macOSModifiers(flags))
    check event.shortcutModifiers == {commandModifier, optionModifier,
      controlModifier, shiftModifier}

  test "AppKit pointer and modifier event types preserve routing":
    check nativeEventKind(1) == pointerDown
    check nativeEventKind(6) == pointerMove
    check nativeEventKind(8) == pointerEnter
    check nativeEventKind(9) == pointerExit
    check nativeEventKind(10) == keyDown
    check nativeEventKind(11) == keyUp
    check nativeEventKind(12) == modifiersChanged
    check nativeEventKind(22) == scroll
    check nativeEventButton(1) == 0
    check nativeEventButton(3) == 1
    check nativeEventButton(25) == 2

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

  test "ordered key bindings use the later binding":
    var registry: CommandRegistry
    var invoked = ""
    let shortcut = Shortcut(keyCode: 0, modifiers: {commandModifier})
    registry.register(Command(name: "first", shortcut: shortcut,
      action: proc() = invoked = "first"))
    registry.register(Command(name: "second", shortcut: shortcut,
      action: proc() = invoked = "second"))
    check registry.dispatchShortcut(shortcut)
    check invoked == "second"

  test "settings keymap recognizes standard macOS keys":
    check shortcutFromKeyBinding("cmd+left").keyCode == 123
    check shortcutFromKeyBinding("option+right").keyCode == 124
    check shortcutFromKeyBinding("cmd+shift+home").keyCode == 115
    check shortcutFromKeyBinding("cmd+backspace").keyCode == 51
    check shortcutFromKeyBinding("cmd+shift+f12").keyCode == 111
    check shortcutFromKeyBinding("cmd+comma").keyCode == 43

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

  test "stretch alignment fills the cross axis within constraints":
    var tree = newUiTree()
    let root = tree.addNode()
    let child = tree.addNode(root)
    tree.setSizeConstraints(child, Size(width: px(0), height: px(8)),
      Size(width: px(0), height: px(4)), Size(width: px(1000), height: px(30)))
    tree.layoutNode(root, Rect(size: Size(width: px(100), height: px(40))),
      LayoutSpec(direction: row, alignment: alignStretch,
        maxSize: Size(width: px(1000), height: px(1000))))
    check tree.node(child).bounds.size.height == px(30)

  test "stack layout overlays children in the content rectangle":
    var tree = newUiTree()
    let root = tree.addNode()
    let first = tree.addNode(root)
    let second = tree.addNode(root)
    let bounds = Rect(origin: Point(x: px(10), y: px(20)),
      size: Size(width: px(300), height: px(200)))
    tree.layoutNode(root, bounds, LayoutSpec(direction: stack,
      padding: EdgeInsets(top: px(8), right: px(12), bottom: px(16), left: px(10))))
    let expected = Rect(origin: Point(x: px(20), y: px(28)),
      size: Size(width: px(278), height: px(176)))
    check tree.node(first).bounds == expected
    check tree.node(second).bounds == expected

  test "layout recursively applies each descendant's layout spec":
    var tree = newUiTree()
    let root = tree.addNode()
    let panel = tree.addNode(root)
    let first = tree.addNode(panel)
    let second = tree.addNode(panel)
    tree.setLayoutSpec(panel, LayoutSpec(direction: row, gap: px(4)))
    tree.setSizeConstraints(first, Size(width: px(20), height: px(10)),
      Size(width: px(20), height: px(10)), Size(width: px(20), height: px(10)))
    tree.setSizeConstraints(second, Size(width: px(20), height: px(10)),
      Size(width: px(20), height: px(10)), Size(width: px(20), height: px(10)))
    tree.layoutNode(root, Rect(size: Size(width: px(100), height: px(30))),
      LayoutSpec(direction: stack))
    check tree.node(panel).bounds.size == Size(width: px(100), height: px(30))
    check tree.node(first).bounds.origin.x == px(0)
    check tree.node(second).bounds.origin.x == px(24)
    check tree.node(second).bounds.size == Size(width: px(20), height: px(10))

  test "layout spec size constraints affect the parent allocation":
    var tree = newUiTree()
    let root = tree.addNode()
    let fixed = tree.addNode(root)
    let flexible = tree.addNode(root)
    tree.setLayoutSpec(fixed, LayoutSpec(direction: stack,
      size: Size(width: px(30), height: px(10)),
      minSize: Size(width: px(20), height: px(8)),
      maxSize: Size(width: px(40), height: px(20))))
    tree.setFlexGrow(flexible, 1.0)
    tree.layoutNode(root, Rect(size: Size(width: px(100), height: px(20))),
      LayoutSpec(direction: row, gap: px(4)))
    check tree.node(fixed).bounds.size.width == px(30)
    check tree.node(flexible).bounds.origin.x == px(34)
    check tree.node(flexible).bounds.size.width == px(66)

  test "root layout spec resolves its containing bounds":
    var tree = newUiTree()
    let root = tree.addNode()
    tree.layoutNode(root, Rect(size: Size(width: px(100), height: px(100))),
      LayoutSpec(direction: stack,
        size: Size(width: px(60), height: px(40)),
        minSize: Size(width: px(50), height: px(30)),
        maxSize: Size(width: px(80), height: px(70))))
    check tree.node(root).bounds.size == Size(width: px(60), height: px(40))

  test "replacing a layout spec clears prior size constraints":
    var tree = newUiTree()
    let root = tree.addNode()
    let child = tree.addNode(root)
    tree.setLayoutSpec(child, LayoutSpec(direction: stack,
      size: Size(width: px(30), height: px(10))))
    tree.setLayoutSpec(child, LayoutSpec(direction: stack))
    tree.layoutNode(root, Rect(size: Size(width: px(100), height: px(20))),
      LayoutSpec(direction: row))
    check tree.node(child).bounds.size.width == px(100)

  test "viewport clipping remains active when only height is nonzero":
    var tree = newUiTree()
    let root = tree.addNode()
    let child = tree.addNode(root)
    tree.layoutNode(root, Rect(size: Size(width: px(100), height: px(100))),
      LayoutSpec(direction: stack,
        viewport: Rect(origin: Point(x: px(10), y: px(20)),
          size: Size(width: px(0), height: px(40)))))
    check tree.node(child).bounds.size.width == px(0)
    check tree.node(child).bounds.size.height == px(40)

  test "rect hit testing uses half-open edges":
    var tree = newUiTree()
    let root = tree.addNode()
    let first = tree.addNode(root)
    let second = tree.addNode(root)
    tree.node(root).bounds = Rect(size: Size(width: px(100), height: px(20)))
    tree.node(first).bounds = Rect(size: Size(width: px(50), height: px(20)))
    tree.node(second).bounds = Rect(origin: Point(x: px(50), y: px(0)),
      size: Size(width: px(50), height: px(20)))
    check tree.hitTest(Point(x: px(50), y: px(10))) == second
    check tree.hitTest(Point(x: px(100), y: px(10))) == NodeId(0)

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

  test "focus, hover, active, and disabled states coexist":
    var tree = newUiTree()
    let root = tree.addNode()
    let button = tree.addNode(root, focusable = true)
    check tree.focus(button)
    tree.setHovered(button, true)
    tree.setActive(button, true)
    check tree.node(button).focusedState
    check tree.node(button).hoveredState
    check tree.node(button).activeState
    check tree.node(button).state == active
    tree.setActive(button, false)
    check tree.node(button).state == focused
    tree.setDisabled(button, true)
    check tree.node(button).state == disabled
    check tree.focused == NodeId(0)
    check not tree.node(button).focusedState
    check not tree.focus(button)
    tree.node(root).bounds = Rect(size: Size(width: px(100), height: px(40)))
    tree.node(button).bounds = Rect(size: Size(width: px(100), height: px(40)))
    check tree.hitTest(Point(x: px(10), y: px(10))) != button
    tree.setDisabled(root, true)
    check tree.hitTest(Point(x: px(10), y: px(10))) == NodeId(0)

  test "disabling a focused ancestor clears descendant focus":
    var tree = newUiTree()
    let root = tree.addNode()
    let panel = tree.addNode(root)
    let button = tree.addNode(panel, focusable = true)
    check tree.focus(button)
    tree.setDisabled(panel, true)
    check tree.focused == NodeId(0)
    check not tree.node(button).focusedState

  test "node handles carry a generation":
    var tree = newUiTree()
    let node = tree.addNode()
    let handle = tree.handle(node)
    check handle.generation > 0
    check tree.isValid(handle)
    check not tree.isValid(NodeHandle(id: node, generation: handle.generation + 1))

  test "focus traversal skips disabled controls":
    var tree = newUiTree()
    let root = tree.addNode()
    let disabledButton = tree.addNode(root, focusable = true)
    let enabledButton = tree.addNode(root, focusable = true)
    tree.setDisabled(disabledButton, true)
    check tree.focusNext() == enabledButton

  test "focus rejects controls below a disabled ancestor":
    var tree = newUiTree()
    let root = tree.addNode()
    let panel = tree.addNode(root)
    let button = tree.addNode(panel, focusable = true)
    tree.setDisabled(panel, true)
    check not tree.focus(button)
    check tree.focused == NodeId(0)

  test "focus traversal skips controls below a disabled ancestor":
    var tree = newUiTree()
    let root = tree.addNode()
    let panel = tree.addNode(root)
    let disabledButton = tree.addNode(panel, focusable = true)
    let enabledButton = tree.addNode(root, focusable = true)
    tree.setDisabled(panel, true)
    check tree.isDisabledPath(disabledButton)
    check tree.focusNext() == enabledButton
    check tree.focused == enabledButton

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

  test "hit testing respects ancestor viewport bounds":
    var tree = newUiTree()
    let root = tree.addNode()
    let scroll = tree.addNode(root)
    let child = tree.addNode(scroll)
    tree.node(root).bounds = Rect(size: Size(width: px(100), height: px(100)))
    tree.node(scroll).bounds = Rect(size: Size(width: px(40), height: px(40)))
    tree.node(child).bounds = Rect(origin: Point(x: px(30), y: px(30)),
      size: Size(width: px(40), height: px(40)))
    check tree.hitTest(Point(x: px(35), y: px(35))) == child
    check tree.hitTest(Point(x: px(60), y: px(60))) == root

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

  test "positions follow Unicode TR29 beyond basic combining and emoji":
    let text = "؀Aक्\u0915가👩🏻‍💻"
    let positions = textPositions(text)
    check positions.len == 5
    check positions[^1].byteOffset == text.len

  test "external byte positions clamp to grapheme boundaries":
    let text = "a\u0301🙂b"
    let positions = textPositions(text)
    check floorGraphemeBoundary(text, positions[1].byteOffset) == positions[1].byteOffset
    check floorGraphemeBoundary(text, positions[1].byteOffset + 1) == positions[1].byteOffset
    check floorGraphemeBoundary(text, text.len) == text.len

  test "glyph atlas reuses glyphs":
    var atlas = newGlyphAtlas(64, 64)
    let first = atlas.insertGlyph(Rune(65), 8, 12)
    let second = atlas.insertGlyph(Rune(65), 8, 12)
    check atlas.glyphs.len == 1
    check first.atlasX == second.atlasX

  test "glyph atlas separates font scale and subpixel variants":
    var atlas = newGlyphAtlas(128, 64)
    let base = GlyphKey(codepoint: Rune(65), fontId: "Menlo", fontSize: 14.0,
      scaleFactor: 2.0, subpixelX: 0, subpixelY: 0)
    let fractional = GlyphKey(codepoint: Rune(65), fontId: "Menlo", fontSize: 14.0,
      scaleFactor: 2.0, subpixelX: 1, subpixelY: 0)
    let otherFont = GlyphKey(codepoint: Rune(65), fontId: "SF Mono", fontSize: 14.0,
      scaleFactor: 2.0, subpixelX: 0, subpixelY: 0)
    discard atlas.insertGlyphVariant(base, 8, 12)
    let fractionalGlyph = atlas.insertGlyphVariant(fractional, 8, 12)
    let otherFontGlyph = atlas.insertGlyphVariant(otherFont, 8, 12)
    check atlas.glyphs.len == 3
    check fractionalGlyph.atlasX != atlas.glyphs[0].atlasX
    check otherFontGlyph.atlasX != atlas.glyphs[0].atlasX
    check atlas.insertGlyphVariant(fractional, 8, 12).atlasX == fractionalGlyph.atlasX

  test "glyph atlas separates glyph and rendering variants":
    var atlas = newGlyphAtlas(128, 64)
    let base = GlyphKey(codepoint: Rune(65), glyphId: 10, fontId: "Menlo",
      fontSize: 14.0, scaleFactor: 2.0)
    let ligature = GlyphKey(codepoint: Rune(65), glyphId: 11, fontId: "Menlo",
      fontSize: 14.0, scaleFactor: 2.0)
    let emoji = GlyphKey(codepoint: Rune(65), glyphId: 10, fontId: "Menlo",
      fontSize: 14.0, scaleFactor: 2.0, isEmoji: true)
    discard atlas.insertGlyphVariant(base, 8, 12)
    discard atlas.insertGlyphVariant(ligature, 8, 12)
    discard atlas.insertGlyphVariant(emoji, 8, 12)
    check atlas.glyphs.len == 3

  test "glyph atlas rejects invalid dimensions without corrupting placement":
    var atlas = newGlyphAtlas(32, 32)
    let key = GlyphKey(codepoint: Rune(66), fontId: "Menlo", fontSize: 14.0,
      scaleFactor: 2.0)
    discard atlas.insertGlyphVariant(key, 0, 8)
    discard atlas.insertGlyphVariant(key, -1, 8)
    discard atlas.insertGlyphVariant(key, 33, 8)
    discard atlas.insertGlyphVariant(key, 8, 33)
    check atlas.glyphs.len == 0
    let valid = atlas.insertGlyphVariant(key, 8, 8)
    check valid.atlasX == 0
    check valid.atlasY == 0

  test "paint list emits only commands intersecting dirty regions":
    var paint: PaintList
    paint.invalidate(Rect(origin: Point(x: px(0), y: px(0)), size: Size(width: px(10), height: px(10))))
    paint.drawRectangle(Rect(origin: Point(x: px(2), y: px(2)), size: Size(width: px(4), height: px(4))))
    paint.drawRectangle(Rect(origin: Point(x: px(20), y: px(20)), size: Size(width: px(4), height: px(4))))
    check paint.commands.len == 1

  test "paint damage merges overlapping regions":
    var paint: PaintList
    paint.invalidate(Rect(origin: Point(x: px(0), y: px(0)),
      size: Size(width: px(10), height: px(10))))
    paint.invalidate(Rect(origin: Point(x: px(5), y: px(5)),
      size: Size(width: px(10), height: px(10))))
    check paint.dirty.len == 1
    check paint.dirty[0] == Rect(size: Size(width: px(15), height: px(15)))
    paint.drawRectangle(Rect(origin: Point(x: px(2), y: px(2)),
      size: Size(width: px(4), height: px(4))))
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
    check paint.commands[0].sourceBounds == Rect(size: Size(width: px(20), height: px(10)))
    check paint.commands[0].transform.tx == 10.0
    check paint.commands[0].transform.ty == 12.0
    check paint.commands[1].imageId == 0

    paint.clear()
    paint.invalidate(Rect(size: Size(width: px(100), height: px(100))))
    paint.drawImage(Rect(size: Size(width: px(12), height: px(12))), imageId = 7)
    check paint.commands.len == 1
    check paint.commands[0].imageId == 7

  test "scroll and split models clamp interaction":
    var scroll = ScrollModel(contentSize: px(100), viewportSize: px(30))
    scroll.scrollBy(px(80))
    check scroll.offset == px(70)
    var split = SplitPaneModel(ratio: 0.5)
    split.beginDrag()
    split.dragTo(0.8)
    split.endDrag()
    check abs(split.ratio - 0.8'f32) < 0.001'f32

  test "precise scroll accumulates sub-line trackpad deltas":
    var remainder = 0'f32
    check scrollLineDelta(remainder, 9'f32, true) == 0
    check remainder < 0'f32
    check scrollLineDelta(remainder, 9'f32, true) == -1
    check scrollLineDelta(remainder, -18'f32, true) == 1
    check remainder == 0'f32

  test "IME state separates composition from committed text":
    var ime = newImeState()
    ime.receiveText("にほ", true)
    check ime.composition == "にほ"
    ime.receiveText("日本", false)
    check ime.composition.len == 0
    check ime.committed == "日本"
    ime.receiveText("語", false)
    check ime.committed == "語"

  test "visible text layout limits work to the requested range":
    let visible = layoutVisibleText("0123456789", 2, 5)
    check visible.glyphs.len == 3

  test "visible text layout keeps grapheme clusters intact":
    let visible = layoutVisibleText("é👩‍💻x", 1, 2)
    check visible.glyphs.len == 3

when defined(macosx):
  suite "M3 Core Text bridge":
    test "Core Text measures a system font":
      var metrics: NativeTextMetrics
      nativeMeasureText("日本語", "Hiragino Sans", 14, addr metrics)
      check metrics.width > 0
      check metrics.ascent > 0
      check metrics.glyphCount > 0

    test "font availability does not accept fallback fonts":
      check not nativeFontAvailable("Nimculus Font That Does Not Exist", 14)
      check not nativeFontAvailable("Hiragino Sans", 0)

    test "Core Text measurement preserves embedded NUL bytes":
      var metrics, prefix: NativeTextMetrics
      let text = "A\0B"
      nativeMeasureTextUtf8("A", 1, "Hiragino Sans", 14, addr prefix)
      nativeMeasureTextUtf8(text.cstring, uint32(text.len), "Hiragino Sans", 14,
                            addr metrics)
      check metrics.width > prefix.width
      check metrics.glyphCount > prefix.glyphCount
