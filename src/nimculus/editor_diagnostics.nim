import nimculus/editor_buffer
import nimculus/lsp

type
  EditorDiagnostic* = object
    startByte*: int
    endByte*: int
    severity*: int
    message*: string
    source*: string

proc resolveDiagnostics*(buffer: PieceTable,
                         diagnostics: openArray[LspDiagnostic]): seq[EditorDiagnostic] =
  ## LSP ranges use UTF-16 line/character positions. Resolve them once at the
  ## editor boundary so rendering and later navigation can use byte offsets.
  for diagnostic in diagnostics:
    let startByte = buffer.byteOffsetAtUtf16Position(
      diagnostic.range.start.line, diagnostic.range.start.character)
    let endByte = buffer.byteOffsetAtUtf16Position(
      diagnostic.range.finish.line, diagnostic.range.finish.character)
    result.add(EditorDiagnostic(startByte: min(startByte, endByte),
      endByte: max(startByte, endByte), severity: diagnostic.severity,
      message: diagnostic.message, source: diagnostic.source))
