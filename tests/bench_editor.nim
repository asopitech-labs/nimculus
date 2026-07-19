import std/times
import std/strutils
import nimculus/editor_buffer

let source = "0123456789abcdef\n".repeat(1024 * 1024 div 17)
let start = cpuTime()
var buffer = initPieceTable(source)
for index in 0 ..< 1000:
  let offset = min(buffer.toString().len, 100 + index * 17)
  buffer.edit(Edit(startByte: offset, endByte: offset, text: "x"))
echo "piece table bytes: ", buffer.toString().len
echo "piece table load+1000 inserts: ", cpuTime() - start, "s"
