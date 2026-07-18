import std/unittest
import nimculus/tree_sitter
import nimculus/syntax

suite "M7 syntax services":
  test "loads all initial grammars":
    for grammar in availableGrammars():
      let parser = newTreeSitterParser(grammar)
      let source = case grammar
        of grammarJson: "{\"x\": 1}"
        of grammarPython: "def sample():\n  return 1"
        of grammarRust: "fn sample() { 1; }"
        of grammarTypescript: "function sample() { return 1; }"
        of grammarMarkdown: "# title\n\ntext"
        of grammarNim: "proc sample() = discard"
      var tree = parser.parse(source)
      check tree.nodes.len > 0
      check not tree.hasError
      tree.close()
      parser.close()

  test "provides highlighting and bracket matching":
    let parser = newTreeSitterParser(grammarPython)
    var tree = parser.parse("def f():\n  return (1)")
    check tree.highlight.len > 0
    check matchingBracket("(abc)", 0) == 4
    check matchingBracket("(abc)", 4) == 0
    check tree.foldRanges("def f():\n  return (1)").len > 0
    check indentationLevel("def f():\n  return (1)", 12) == 1
    let expanded = tree.expandSelection(14, 15)
    check expanded.endByte >= expanded.startByte
    check tree.nextSyntaxNode(0).endByte > 0
    tree.close()
    parser.close()
