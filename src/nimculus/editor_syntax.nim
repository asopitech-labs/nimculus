import nimculus/tree_sitter
import nimculus/syntax

type
  EditorSyntaxState* = ref object
    parser*: TreeSitterParser
    tree*: SyntaxTree
    grammar*: GrammarKind

proc newEditorSyntax*(path, source: string): EditorSyntaxState =
  try:
    result = EditorSyntaxState(grammar: grammarForPath(path))
    result.parser = newTreeSitterParser(result.grammar)
    result.tree = result.parser.parse(source)
  except ValueError:
    return nil

proc update*(state: EditorSyntaxState, source: string) =
  if state == nil or state.parser == nil: return
  var next = state.parser.parse(source)
  if state.tree != nil: state.tree.close()
  state.tree = next

proc visibleHighlights*(state: EditorSyntaxState, firstByte, lastByte: uint32): seq[HighlightSpan] =
  if state != nil and state.tree != nil:
    return state.tree.highlightVisible(firstByte, lastByte)

proc close*(state: EditorSyntaxState) =
  if state == nil: return
  if state.tree != nil: state.tree.close()
  if state.parser != nil: state.parser.close()
