import std/unittest
import nimculus/tree_sitter

suite "M7 Tree-sitter":
  test "parses JSON and exposes syntax nodes":
    let parser = newTreeSitterParser(grammarJson)
    var tree = parser.parse("{\"name\": 1}")
    check tree.rootType == "document"
    check not tree.hasError
    check tree.nodes.len > 1
    tree.close()
    parser.close()

  test "supports incremental tree edits":
    let parser = newTreeSitterParser(grammarJson)
    var tree = parser.parse("{\"name\": 1}")
    tree.edit(9, 10, 10, 0, 9, 0, 10, 0, 10)
    var updated = parser.parse("{\"name\": 2}", tree)
    check not updated.hasError
    check updated.rootType == "document"
    tree.close()
    updated.close()
    parser.close()
