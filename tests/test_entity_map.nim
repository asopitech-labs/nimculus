import std/[options, strutils, unittest]
import nimnui/entity

suite "entity map":
  test "reserve and insert values are readable":
    var map = newEntityMap()
    var readCount = 0
    for value in 0 ..< 1000:
      let entity = reserve[int](map)
      discard map.insert(entity, value)
      check map.read(entity) == value
      inc readCount
    check readCount == 1000

  test "recycled slots invalidate stale weak entities":
    var map = newEntityMap()
    var checked = 0
    for value in 0 ..< 1000:
      let old = reserve[int](map)
      discard map.insert(old, value)
      let stale = old.weak()
      let oldGeneration = old.generation
      check map.release(old)

      let fresh = reserve[int](map)
      discard map.insert(fresh, value)
      check fresh.id == old.id
      check fresh.generation == oldGeneration + 1
      check stale.upgrade(map).isNone
      check fresh.weak().upgrade(map).get == fresh
      check map.release(fresh)
      inc checked
    check checked == 1000

  test "same entity cannot be leased twice":
    var map = newEntityMap()
    let entity = reserve[int](map, 0)
    var attempts = 0
    var message = ""
    try:
      discard map.update(entity, proc(value: var int): int =
        inc attempts
        discard map.update(entity, proc(nested: var int): int = nested + 1)
        value)
    except Defect as error:
      message = error.msg
    check attempts == 1
    check message.contains("double lease")

  test "different entities can be updated re-entrantly":
    var map = newEntityMap()
    let first = reserve[int](map, 1)
    let second = reserve[int](map, 2)
    var attempts = 0
    discard map.update(first, proc(value: var int): int =
      inc attempts
      discard map.update(second, proc(other: var int): int =
        inc other
        other)
      inc value
      value)
    check attempts == 1
    check map.read(first) == 2
    check map.read(second) == 3

  test "read rejects a currently leased entity":
    var map = newEntityMap()
    let entity = reserve[int](map, 7)
    var attempts = 0
    var message = ""
    try:
      discard map.update(entity, proc(value: var int): int =
        inc attempts
        map.read(entity))
    except Defect as error:
      message = error.msg
    check attempts == 1
    check message.contains("double lease")
