import std/times
import nimculus/editor_buffer

const targetSize = 100 * 1024 * 1024
var source = newString(targetSize)
for index in 0 ..< source.len:
  source[index] = if index mod 80 == 79: '\n' else: 'a'
let start = cpuTime()
var buffer = initPieceTable(source)
let loaded = buffer.toString().len
echo "large buffer bytes: ", loaded
echo "large buffer load/index: ", cpuTime() - start, "s"
