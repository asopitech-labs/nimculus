import std/os
import std/strutils

{.compile: "tree_sitter_core.c".}
{.compile: "tree_sitter_json.c".}
{.compile: "tree_sitter_python.c".}
{.compile: "tree_sitter_rust.c".}
{.compile: "tree_sitter_typescript.c".}
{.compile: "tree_sitter_markdown.c".}
{.compile: "tree_sitter_nim.c".}
{.compile: "tree_sitter_bridge.c".}
{.passC: "-Ireferences/tree-sitter/lib/include -Ireferences/tree-sitter-typescript/typescript/src".}

type
  GrammarKind* = enum grammarJson = "json", grammarPython = "python",
    grammarRust = "rust", grammarTypescript = "typescript", grammarMarkdown = "markdown",
    grammarNim = "nim"
  SyntaxNode* = object
    startByte*, endByte*: uint32
    kind*: string
    hasError*: bool
  SyntaxTree* = ref object
    handle*: pointer
    source*: string
    nodes*: seq[SyntaxNode]
  TreeSitterParser* = ref object
    handle*: pointer
    grammar*: GrammarKind

type TreeNodeCallback = proc(startByte, endByte: uint32, kind: cstring,
                              hasError: bool, context: pointer) {.cdecl.}

proc cParserNew(language: cstring): pointer {.importc: "nim_ts_parser_new", cdecl.}
proc cParserDelete(parser: pointer) {.importc: "nim_ts_parser_delete", cdecl.}
proc cParse(parser, oldTree: pointer, source: cstring, length: uint32): pointer {.importc: "nim_ts_parse", cdecl.}
proc cTreeDelete(tree: pointer) {.importc: "nim_ts_tree_delete", cdecl.}
proc cRootType(tree: pointer): cstring {.importc: "nim_ts_root_type", cdecl.}
proc cHasError(tree: pointer): bool {.importc: "nim_ts_has_error", cdecl.}
proc cWalk(tree: pointer, callback: TreeNodeCallback, context: pointer) {.importc: "nim_ts_walk", cdecl.}
proc cTreeEdit(tree: pointer, startByte, oldEndByte, newEndByte, startRow, startColumn,
               oldEndRow, oldEndColumn, newEndRow, newEndColumn: uint32) {.importc: "nim_ts_tree_edit", cdecl.}

proc newTreeSitterParser*(grammar: GrammarKind): TreeSitterParser =
  result = TreeSitterParser(grammar: grammar, handle: cParserNew(($grammar).cstring))
  if result.handle == nil: raise newException(ValueError, "Tree-sitter grammar unavailable: " & $grammar)

proc availableGrammars*(): seq[GrammarKind] =
  @[grammarNim, grammarRust, grammarTypescript, grammarPython, grammarJson, grammarMarkdown]

proc grammarForPath*(path: string): GrammarKind =
  case path.splitFile.ext.toLowerAscii
  of ".nim": grammarNim
  of ".rs": grammarRust
  of ".ts": grammarTypescript
  of ".py": grammarPython
  of ".json": grammarJson
  of ".md", ".markdown": grammarMarkdown
  else: raise newException(ValueError, "No Tree-sitter grammar for: " & path)

proc close*(parser: TreeSitterParser) =
  if parser != nil and parser.handle != nil:
    cParserDelete(parser.handle)
    parser.handle = nil

proc collectNode(startByte, endByte: uint32, kind: cstring, hasError: bool, context: pointer) {.cdecl.} =
  let tree = cast[SyntaxTree](context)
  tree.nodes.add(SyntaxNode(startByte: startByte, endByte: endByte, kind: $kind, hasError: hasError))

proc parse*(parser: TreeSitterParser, source: string, previous: SyntaxTree = nil): SyntaxTree =
  result = SyntaxTree(source: source)
  result.handle = cParse(parser.handle, if previous == nil: nil else: previous.handle,
                         source.cstring, uint32(source.len))
  if result.handle == nil: raise newException(ValueError, "Tree-sitter parse failed")
  cWalk(result.handle, collectNode, cast[pointer](result))

proc rootType*(tree: SyntaxTree): string = $cRootType(tree.handle)
proc hasError*(tree: SyntaxTree): bool = cHasError(tree.handle)

proc edit*(tree: SyntaxTree, startByte, oldEndByte, newEndByte: uint32,
           startRow, startColumn, oldEndRow, oldEndColumn,
           newEndRow, newEndColumn: uint32) =
  cTreeEdit(tree.handle, startByte, oldEndByte, newEndByte, startRow, startColumn,
            oldEndRow, oldEndColumn, newEndRow, newEndColumn)

proc close*(tree: var SyntaxTree) =
  if tree != nil and tree.handle != nil:
    cTreeDelete(tree.handle)
    tree.handle = nil
