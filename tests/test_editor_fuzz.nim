import std/unittest
import std/random
import std/unicode
import nimculus/editor_buffer

proc utf8Boundaries(text: string): seq[int] =
  result = @[0]
  var offset = 0
  for rune in text.runes:
    offset += rune.size
    result.add(offset)

proc replaceReference(text: string, startByte, endByte: int,
                      replacement: string): string =
  let prefix = if startByte > 0: text[0 ..< startByte] else: ""
  let suffix = if endByte < text.len: text[endByte .. ^1] else: ""
  prefix & replacement & suffix

suite "M4 editor invariants":
  test "deterministic random edits match a reference string":
    var rng = initRand(42)
    var buffer = initPieceTable("seed")
    var reference = "seed"
    for iteration in 0 ..< 1000:
      let boundaries = utf8Boundaries(reference)
      let startIndex = rand(rng, boundaries.high)
      let finishIndex = startIndex + rand(rng, boundaries.high - startIndex)
      let start = boundaries[startIndex]
      let finish = boundaries[finishIndex]
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

  test "random edits with undo and redo match a reference history":
    ## Ported from Zed's buffer random-edit/undo-redo invariant coverage.
    ## Keep an independent snapshot history so undo and redo transitions are
    ## checked as well as the piece table's current contents.
    var rng = initRand(20260723)
    var buffer = initPieceTable("seed 日本🙂\n")
    var reference = "seed 日本🙂\n"
    var undoHistory: seq[string]
    var redoHistory: seq[string]
    let replacements = @["", "x", "日本", "🙂", "\n", "é"]

    for _ in 0 ..< 800:
      case rand(rng, 9)
      of 0, 1:
        let didUndo = buffer.undo()
        check didUndo == (undoHistory.len > 0)
        if undoHistory.len > 0:
          redoHistory.add(reference)
          reference = undoHistory.pop()
      of 2, 3:
        let didRedo = buffer.redo()
        check didRedo == (redoHistory.len > 0)
        if redoHistory.len > 0:
          undoHistory.add(reference)
          reference = redoHistory.pop()
      else:
        let boundaries = utf8Boundaries(reference)
        let startIndex = rand(rng, boundaries.high)
        let finishIndex = startIndex + rand(rng, boundaries.high - startIndex)
        let startByte = boundaries[startIndex]
        let endByte = boundaries[finishIndex]
        let replacement = replacements[rand(rng, replacements.high)]
        undoHistory.add(reference)
        redoHistory.setLen(0)
        buffer.edit(Edit(startByte: startByte, endByte: endByte, text: replacement))
        reference = replaceReference(reference, startByte, endByte, replacement)
      check buffer.toString() == reference

  test "Unicode batch edits round trip as one transaction":
    ## Zed treats a group of disjoint edits as one edit event/transaction.
    ## Verify that an unordered batch preserves original offsets and that both
    ## undo and redo restore the exact UTF-8 contents.
    var buffer = initPieceTable("A日本\nB🙂\nCafé")
    buffer.applyEdits(@[
      Edit(startByte: 9, endByte: 13, text: "🚀"),
      Edit(startByte: 1, endByte: 7, text: "Nim"),
      Edit(startByte: 20, endByte: 20, text: "!"),
    ])
    check buffer.toString() == "ANim\nB🚀\nCafé!"
    check buffer.undo()
    check buffer.toString() == "A日本\nB🙂\nCafé"
    check buffer.redo()
    check buffer.toString() == "ANim\nB🚀\nCafé!"
