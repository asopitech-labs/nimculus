import std/unittest
import nimnui/accessibility
import nimnui/controls
import nimnui/ui_tree

suite "NimNUI accessibility tree":
  test "omits role-less nodes and adds editor synthetic text":
    var tree = newUiTree()
    let root = tree.addNode()
    let hidden = makeControl(tree, root, ControlKind.label, "layout-only")
    let editor = makeControl(tree, root, ControlKind.editor, "Editor")
    setControlAccessibility(tree, hidden, "", "", "")
    setControlAccessibility(tree, editor, "editor.content", "Editor", "")

    let accessibility = buildAccessibilityTree(tree, "日本語", 3, 1, 3)
    var hasEditor = false
    var hasSynthetic = false
    var hasRolelessIdentifier = false
    for node in accessibility.nodes:
      if node.identifier == "editor.content":
        hasEditor = true
        check node.value == "日本語"
        check node.cursorByte == 3
        check node.selectionStartByte == 1
        check node.selectionEndByte == 3
      if node.synthetic:
        hasSynthetic = true
        check node.role == a11yTextRun
        check node.value == "日本語"
      if not node.synthetic and node.identifier.len == 0:
        hasRolelessIdentifier = true
    check hasEditor
    check hasSynthetic
    check not hasRolelessIdentifier
