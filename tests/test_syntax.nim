import std/unittest
import std/sequtils
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
        of grammarTsx: "const sample = () => <main>Hello</main>;"
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
    check tree.highlightVisible(0, 8).len < tree.highlight.len
    check matchingBracket("(abc)", 0) == 4
    check matchingBracket("(abc)", 4) == 0
    check tree.foldRanges("def f():\n  return (1)").len > 0
    check indentationLevel("def f():\n  return (1)", 12) == 1
    let expanded = tree.expandSelection(14, 15)
    check expanded.endByte >= expanded.startByte
    let larger = tree.largerSelection(14, 15)
    check larger.startByte <= 14
    check larger.endByte >= 15
    let smaller = tree.smallerSelection(larger.startByte, larger.endByte, 14)
    check smaller.startByte >= larger.startByte
    check smaller.endByte <= larger.endByte
    check tree.nextSyntaxNode(0).endByte > 0
    let items = tree.outline
    check items.len > 0
    check items.anyIt(it.name == "f")
    tree.close()
    parser.close()

  test "extracts Nim declarations for the native outline":
    let parser = newTreeSitterParser(grammarNim)
    var tree = parser.parse("type EditorState = object\nproc updateState(value: int) = discard\nproc 日本語(value: int) = discard\n")
    let items = tree.outline
    check items.anyIt(it.name == "EditorState")
    check items.anyIt(it.name == "updateState")
    check items.anyIt(it.name == "日本語")
    tree.close()
    parser.close()
