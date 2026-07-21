import std/os
import std/strutils
import std/times
import nimculus/editor_buffer
import nimculus/editor_syntax
import nimculus/terminal
import nimculus/workspace
import nimnui/text
import nimnui/geometry
import nimnui/layout
import nimnui/ui_tree
import nimnui/platform/macos/platform

proc report(name: string, elapsed: float, details: string) =
  # TSV keeps the output stream-friendly for CI artifacts and spreadsheet
  # import while avoiding a dependency on a JSON encoder in benchmark code.
  echo name, "\t", formatFloat(elapsed, ffDecimal, 6), "\tseconds\t", details

let editorBytes = parseInt(getEnv("NIMCULUS_BENCH_EDITOR_BYTES", "1000000"))
let workspaceFiles = parseInt(getEnv("NIMCULUS_BENCH_FILES", "1000"))
let source = "0123456789abcdef\n".repeat(max(1, editorBytes div 17))

block idleMemory:
  let start = cpuTime()
  let bytes = platformResidentMemoryBytes()
  report("idle_memory", cpuTime() - start, "bytes=" & $bytes)

block editorLoad:
  let start = cpuTime()
  var buffer = initPieceTable(source)
  discard buffer.lineStarts.len
  report("editor_load", cpuTime() - start, "bytes=" & $source.len)

block editorEdit:
  var buffer = initPieceTable(source)
  let start = cpuTime()
  for index in 0 ..< 100:
    let offset = min(buffer.toString().len, 100 + index * 17)
    buffer.edit(Edit(startByte: offset, endByte: offset, text: "x"))
  report("editor_edit", cpuTime() - start, "edits=100")

block textPositionBenchmark:
  let start = cpuTime()
  discard textPositions(source)
  report("text_position", cpuTime() - start, "bytes=" & $source.len)

block syntax:
  let syntaxSource = source.replace("0123456789abcdef", "proc render(value: int): int = value")
  let start = cpuTime()
  let state = newEditorSyntax("benchmark.nim", syntaxSource)
  discard state.visibleHighlights(0, uint32(min(syntaxSource.len, 65536)))
  report("syntax_visible", cpuTime() - start, "bytes=" & $syntaxSource.len)
  state.close()

block terminalParser:
  var screen = initTerminalScreen(120, 40)
  let payload = "\e[38;2;80;180;240mNimculus\e[0m\r\n".repeat(1000)
  let start = cpuTime()
  screen.feed(payload)
  report("terminal_parse", cpuTime() - start, "bytes=" & $payload.len)

block layoutTime:
  var tree = newUiTree()
  let root = tree.addNode()
  for index in 0 ..< 256:
    let rowNode = tree.addNode(root)
    tree.setLayoutSpec(rowNode, LayoutSpec(direction: row, gap: px(2)))
    for _ in 0 ..< 4:
      let child = tree.addNode(rowNode)
      tree.setSizeConstraints(child, Size(width: px(24), height: px(18)),
        Size(width: px(8), height: px(8)), Size(width: px(200), height: px(40)))
  let start = cpuTime()
  tree.layoutNode(root, Rect(size: Size(width: px(1024), height: px(4096))),
    LayoutSpec(direction: column, gap: px(1)))
  report("layout_time", cpuTime() - start, "nodes=" & $tree.nodes.len)

block platformFrameMetrics:
  var metrics: PlatformMetrics
  let start = cpuTime()
  for _ in 0 ..< 1000:
    platformGetMetrics(addr metrics)
  report("frame_metrics_read", cpuTime() - start,
    "frames=" & $metrics.frameCount & ";last_frame_ms=" & $metrics.lastFrameTimeMs &
    ";last_input_ms=" & $metrics.lastInputLatencyMs)

block workspaceLoad:
  let root = getTempDir() / ("nimculus-m20-" & $getCurrentProcessId())
  if dirExists(root): removeDir(root)
  createDir(root)
  for index in 0 ..< max(1, workspaceFiles):
    let directory = root / ("group" & $(index div 100))
    if not dirExists(directory): createDir(directory)
    writeFile(directory / ("file" & $index & ".txt"), "workspace")
  let workspace = openWorkspace(root)
  let start = cpuTime()
  let entries = workspace.enumerateFiles()
  report("workspace_load", cpuTime() - start, "files=" & $entries.len)
  removeDir(root)
