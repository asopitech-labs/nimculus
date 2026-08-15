import std/unittest
import nimnui/nimnui

proc appendDeferred(value: int, output: ptr seq[int]): Effect =
  let captured = value
  deferEffect(proc() = output[].add(captured))

suite "effect queue":
  test "coalesces repeated notifications for one entity":
    var app = newApp()
    let entity = app.newEntity(0)
    var runs = 0
    app.observe(entity, proc() = inc runs)

    app.startUpdate()
    for _ in 0 ..< 100:
      app.pushEffect(Effect(kind: efNotify, entityId: entity.id))
    app.finishUpdate()

    check runs == 1
    check app.pendingEffects.len == 0
    check app.pendingNotifications.len == 0

  test "does not coalesce distinct entities":
    var app = newApp()
    var entities: seq[Entity[int]] = @[]
    var runs = 0
    for _ in 0 ..< 100:
      let entity = app.newEntity(0)
      entities.add(entity)
      app.observe(entity, proc() = inc runs)

    app.startUpdate()
    for entity in entities:
      app.pushEffect(Effect(kind: efNotify, entityId: entity.id))
    app.finishUpdate()

    check runs == 100
    check app.pendingEffects.len == 0
    check app.pendingNotifications.len == 0

  test "flushes only after the outermost nested update":
    var app = newApp()
    let entity = app.newEntity(0)
    var runs = 0
    app.observe(entity, proc() = inc runs)

    app.update:
      app.pushEffect(Effect(kind: efNotify, entityId: entity.id))
      check runs == 0
      app.update:
        app.pushEffect(Effect(kind: efNotify, entityId: entity.id))
        check runs == 0
        app.update:
          app.pushEffect(Effect(kind: efNotify, entityId: entity.id))
          check runs == 0
        check runs == 0
      check runs == 0

    check runs == 1
    check app.pendingEffects.len == 0
    check app.pendingNotifications.len == 0

  test "observer effects are reentrant but terminate":
    var app = newApp()
    let first = app.newEntity(0)
    let second = app.newEntity(0)
    var runs = 0
    app.observe(first, proc() =
      inc runs
      app.pushEffect(Effect(kind: efNotify, entityId: second.id)))
    app.observe(second, proc() = inc runs)

    app.startUpdate()
    app.pushEffect(Effect(kind: efNotify, entityId: first.id))
    app.finishUpdate()

    check runs == 2
    check app.pendingEffects.len == 0
    check app.pendingNotifications.len == 0

  test "defer effects preserve FIFO order":
    var app = newApp()
    var order: seq[int] = @[]

    app.startUpdate()
    for value in 1 .. 5:
      app.pushEffect(appendDeferred(value, addr order))
    app.finishUpdate()

    check order == @[1, 2, 3, 4, 5]
    check app.pendingEffects.len == 0
    check app.pendingNotifications.len == 0
