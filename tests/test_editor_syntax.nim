import std/unittest
import std/strutils
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
    check state.tree.handle == nil
    check state.parser.handle == nil

  test "unsupported files remain plain text":
    check newEditorSyntax("notes.txt", "plain") == nil

  test "collects syntax spans for disjoint split viewports":
    let source = "def first():\n  return 1\n\ndef second():\n  return 2\n"
    let state = newEditorSyntax("main.py", source)
    let secondStart = source.find("def second")
    let ranges = [
      (firstByte: 0'u32, lastByte: 10'u32),
      (firstByte: uint32(secondStart), lastByte: uint32(source.len))]
    let highlights = state.visibleHighlights(ranges)
    var firstViewport = false
    var secondViewport = false
    var gapViewport = false
    for span in highlights:
      if span.startByte < 10'u32: firstViewport = true
      elif span.startByte >= uint32(secondStart): secondViewport = true
      else: gapViewport = true
    check firstViewport
    check secondViewport
    check not gapViewport
    state.close()

  test "separate split documents keep independent grammar state":
    let primary = newEditorSyntax("main.nim", "proc main() = discard\n")
    let secondary = newEditorSyntax("main.py", "def main():\n  return 1\n")
    check primary != nil
    check secondary != nil
    check primary.grammar != secondary.grammar
    check primary.visibleHighlights(0, 20).len > 0
    check secondary.visibleHighlights(0, 20).len > 0
    primary.update("proc main() = echo \"primary\"\n")
    check secondary.tree.source == "def main():\n  return 1\n"
    primary.close()
    secondary.close()
