import std/unittest
import std/random
import nimculus/editor_buffer

suite "M4 editor invariants":
  test "deterministic random edits match a reference string":
    var rng = initRand(42)
    var buffer = initPieceTable("seed")
    var reference = "seed"
    for iteration in 0 ..< 1000:
      let start = rand(rng, reference.len)
      let finish = start + rand(rng, reference.len - start)
      let replacement = if iteration mod 7 == 0: "日本" else: $char(97 + rand(rng, 25))
      buffer.edit(Edit(startByte: start, endByte: finish, text: replacement))
      let prefix = if start > 0: reference[0 ..< start] else: ""
      let suffix = if finish < reference.len: reference[finish .. ^1] else: ""
      reference = prefix & replacement & suffix
      check buffer.toString() == reference

  test "undo restores a long edit sequence":
    var buffer = initPieceTable("start")
    for index in 0 ..< 100:
      buffer.edit(Edit(startByte: buffer.toString().len, endByte: buffer.toString().len, text: $index & "\n"))
    for _ in 0 ..< 100: check buffer.undo()
    check buffer.toString() == "start"
