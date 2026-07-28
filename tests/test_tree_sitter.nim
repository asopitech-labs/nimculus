import std/unittest
import std/sequtils
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

  test "routes TSX files to the JSX-aware TypeScript grammar":
    check grammarForPath("Component.tsx") == grammarTsx
    check grammarForPath("module.mts") == grammarTypescript
    let parser = newTreeSitterParser(grammarTsx)
    var tree = parser.parse("export const Component = () => <main aria-label=\"example\">Hello</main>;")
    check tree.rootType == "program"
    check not tree.hasError
    check tree.nodes.anyIt(it.kind == "jsx_element")
    tree.close()
    parser.close()
