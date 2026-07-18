import std/os
import std/times
import std/strutils
import nimculus/editor_syntax

let targetBytes = parseInt(getEnv("NIMCULUS_SYNTAX_BENCH_BYTES", "1000000"))
var source = newStringOfCap(targetBytes)
while source.len < targetBytes:
  source.add("proc render(value: int): int =\n  let result = value + 1\n  result\n\n")

let parseStart = cpuTime()
let state = newEditorSyntax("benchmark.nim", source)
let parseElapsed = cpuTime() - parseStart
let highlightStart = cpuTime()
let highlights = state.visibleHighlights(0, uint32(min(source.len, 65536)))
let highlightElapsed = cpuTime() - highlightStart
echo "syntax bytes: ", source.len
echo "syntax parse: ", parseElapsed, "s"
echo "syntax visible highlights: ", highlights.len, " in ", highlightElapsed, "s"
if state != nil: state.close()
