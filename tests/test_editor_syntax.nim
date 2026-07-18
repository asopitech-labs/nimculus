import std/unittest
import nimculus/editor_syntax

suite "M7 editor syntax integration":
  test "updates syntax state from an editor document":
    let state = newEditorSyntax("main.py", "def main():\n  return 1")
    check state != nil
    check state.visibleHighlights(0, 10).len > 0
    state.update("def main():\n  return 2")
    check state.tree != nil
    check state.tree.source == "def main():\n  return 2"
    state.close()

  test "unsupported files remain plain text":
    check newEditorSyntax("notes.txt", "plain") == nil
